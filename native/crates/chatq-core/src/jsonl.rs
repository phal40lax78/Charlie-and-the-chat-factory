//! A run's stdout as [Invoke-ChatqProcess](src/queue.ps1) reads it - decoded,
//! split as `StreamReader.ReadLine` splits - and as it lands in
//! `data/logs/<jobId>.jsonl` (SPEC 2.3, 2.6). chatqd runs a CLI only from
//! M5; the rules are pinned now. Vector: native/vectors/jsonl.json.

use crate::paths::NEWLINE;
use crate::time::Flavour;
use crate::utf8::{BOM_WINDOW, Decoder, detect_bom};

/// The longest stdout line, in UTF-16 code units, that
/// [Update-ChatqClaudeState](src/queue.ps1) and
/// [Update-ChatqCodexState](src/queue.ps1) parse:
/// `if ($Line.Length -gt 1048576) { return }`.
pub const PARSE_LIMIT: usize = 1_048_576;

/// Whether a line is past [PARSE_LIMIT], counted as
/// [Update-ChatqClaudeState](src/queue.ps1)'s `$Line.Length` counts it
/// (UTF-16 code units, after decoding): such a line is logged in full and
/// never parsed (SPEC 2.6).
pub fn too_long(line: &str) -> bool {
    // a code unit is never more than its UTF-8 bytes
    line.len() > PARSE_LIMIT && line.encode_utf16().count() > PARSE_LIMIT
}

/// A line as [Invoke-ChatqProcess](src/queue.ps1)'s `$log.WriteLine($line)`
/// puts it in the `.jsonl`: the line, then `Environment.NewLine` - CRLF on
/// Windows, LF on macOS (SPEC 2.3). The writer is UTF-8 without a BOM, and a
/// decoded line holds no lone surrogate, so these bytes are the file's.
pub fn log_line(line: &str) -> String {
    format!("{line}{NEWLINE}")
}

/// stdout as [Invoke-ChatqProcess](src/queue.ps1)'s
/// `StandardOutput.ReadLineAsync` hands it out: a `StreamReader` over UTF-8
/// that detects a byte-order mark ([detect_bom]), decodes as `fl`'s .NET
/// does, and splits at `\n`, `\r\n` and a lone `\r`, a `\r\n` cut across two
/// reads included. A last line with no terminator still counts; an empty
/// stream, or one that ends with a terminator, has no empty last line.
#[derive(Debug)]
pub struct LineReader {
    fl: Flavour,
    /// the first bytes, held until [BOM_WINDOW] of them came
    head: Vec<u8>,
    dec: Option<Decoder>,
    text: String,
    line: String,
    /// the last character was a `\r`: a `\n` next belongs to it
    after_cr: bool,
}

impl LineReader {
    /// [Invoke-ChatqProcess](src/queue.ps1)'s reader before stdout's first
    /// byte, decoding as `fl`'s .NET does.
    pub fn new(fl: Flavour) -> LineReader {
        LineReader {
            fl,
            head: Vec::new(),
            dec: None,
            text: String::new(),
            line: String::new(),
            after_cr: false,
        }
    }

    /// The next bytes, as a pipe read hands them over: every line they end
    /// goes onto `lines`, as [Invoke-ChatqProcess](src/queue.ps1)'s
    /// `ReadLineAsync` would hand it out.
    pub fn feed(&mut self, bytes: &[u8], lines: &mut Vec<String>) {
        if self.dec.is_some() {
            self.decode(bytes, lines);
            return;
        }
        self.head.extend_from_slice(bytes);
        if self.head.len() >= BOM_WINDOW {
            self.begin(lines);
        }
    }

    /// stdout's end: what the decoder still held, then the last line, as
    /// [Invoke-ChatqProcess](src/queue.ps1)'s last `ReadLineAsync` calls give
    /// them.
    pub fn finish(mut self, lines: &mut Vec<String>) {
        if self.dec.is_none() {
            self.begin(lines);
        }
        let mut text = String::new();
        if let Some(d) = self.dec.as_mut() {
            d.finish(&mut text);
        }
        self.split(&text, lines);
        if !self.line.is_empty() {
            lines.push(std::mem::take(&mut self.line));
        }
    }

    fn begin(&mut self, lines: &mut Vec<String>) {
        let head = std::mem::take(&mut self.head);
        let (enc, skip) = detect_bom(&head[..head.len().min(BOM_WINDOW)]);
        self.dec = Some(Decoder::new(enc, self.fl));
        self.decode(&head[skip..], lines);
    }

    fn decode(&mut self, bytes: &[u8], lines: &mut Vec<String>) {
        let mut text = std::mem::take(&mut self.text);
        text.clear();
        if let Some(d) = self.dec.as_mut() {
            d.decode(bytes, &mut text);
        }
        self.split(&text, lines);
        self.text = text;
    }

    fn split(&mut self, mut text: &str, lines: &mut Vec<String>) {
        if self.after_cr && !text.is_empty() {
            self.after_cr = false;
            text = text.strip_prefix('\n').unwrap_or(text);
        }
        while let Some(i) = text.find(['\r', '\n']) {
            self.line.push_str(&text[..i]);
            lines.push(std::mem::take(&mut self.line));
            let cr = text.as_bytes()[i] == b'\r';
            text = &text[i + 1..];
            if cr {
                if text.is_empty() {
                    self.after_cr = true;
                } else {
                    text = text.strip_prefix('\n').unwrap_or(text);
                }
            }
        }
        self.line.push_str(text);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn read(bytes: &[u8], fl: Flavour, chunk: usize) -> Vec<String> {
        let mut r = LineReader::new(fl);
        let mut lines = Vec::new();
        for c in bytes.chunks(chunk.max(1)) {
            r.feed(c, &mut lines);
        }
        r.finish(&mut lines);
        lines
    }

    #[test]
    fn splits_as_readline_does() {
        let cases: &[(&[u8], &[&str])] = &[
            (b"", &[]),
            (b"a", &["a"]),
            (b"a\n", &["a"]),
            (b"a\r\n", &["a"]),
            (b"a\rb", &["a", "b"]),
            (b"\n", &[""]),
            (b"\r\r\n", &["", ""]),
            (b"\n\r", &["", ""]),
            (b"a\n\nb", &["a", "", "b"]),
            (b"\xEF\xBB\xBFa\r\n", &["a"]),
            (b"a\xE2\x80\xA8b\xC2\x85c", &["a\u{2028}b\u{85}c"]),
        ];
        for &(bytes, want) in cases {
            for chunk in [1, 2, 3, 64] {
                assert_eq!(
                    read(bytes, Flavour::Core, chunk),
                    want,
                    "{bytes:02x?} by {chunk}"
                );
            }
        }
    }

    #[test]
    fn the_end_differs_by_flavour() {
        assert_eq!(read(b"a\n\xE2\x82", Flavour::Desktop, 64), ["a"]);
        assert_eq!(read(b"a\n\xE2\x82", Flavour::Core, 64), ["a", "\u{FFFD}"]);
        assert_eq!(read(b"a\r\xE2", Flavour::Core, 1), ["a", "\u{FFFD}"]);
    }

    #[test]
    fn the_limit_counts_utf16_units() {
        assert!(!too_long(&"x".repeat(PARSE_LIMIT)));
        assert!(too_long(&"x".repeat(PARSE_LIMIT + 1)));
        // two bytes but one unit each
        assert!(!too_long(&"\u{E9}".repeat(PARSE_LIMIT)));
        // four bytes, two units
        assert!(too_long(&"\u{1F600}".repeat(PARSE_LIMIT / 2 + 1)));
        assert!(!too_long(&"\u{1F600}".repeat(PARSE_LIMIT / 2)));
    }

    #[test]
    fn the_log_line_ends_with_the_platform_newline() {
        assert_eq!(log_line(""), NEWLINE);
        #[cfg(windows)]
        assert_eq!(log_line("a"), "a\r\n");
        #[cfg(not(windows))]
        assert_eq!(log_line("a"), "a\n");
    }
}
