//! Bytes decoded as each PowerShell's .NET decodes them (SPEC 2.2, 2.6):
//! `StreamReader`'s byte-order-mark detection, then UTF-8 - or the UTF-16 or
//! UTF-32 a mark names - with U+FFFD for whatever does not decode. Both
//! readers chatqd stands in for read this way: `Get-Content -Raw -Encoding
//! UTF8` in [Read-ChatqJson](src/queue.ps1), and the stdout `StreamReader`
//! of [Invoke-ChatqProcess](src/queue.ps1).
//!
//! The two .NETs differ twice, and a [Flavour] picks which one answers:
//! - .NET Framework (Windows PowerShell 5.1) makes ONE U+FFFD of a lead byte
//!   and a second byte that is a continuation byte out of that lead's range
//!   (`E0 80`, `ED A0`, `F0 8F`, `F4 90`), and takes both; .NET (pwsh 7)
//!   makes one of the lead and reads the second byte again, as a stray: two.
//!   Everywhere else both put one U+FFFD per maximal invalid subpart.
//! - At the end of the stream 5.1's `StreamReader` never flushes its decoder,
//!   so an unfinished sequence is dropped; pwsh 7's flushes it, one U+FFFD.
//!
//! Vectors: native/vectors/json-compat.json, native/vectors/jsonl.json.

use crate::time::Flavour;

const REPLACEMENT: char = '\u{FFFD}';

/// What the `StreamReader` of [Read-ChatqJson](src/queue.ps1)'s Get-Content,
/// or of [Invoke-ChatqProcess](src/queue.ps1)'s stdout, decodes with: UTF-8,
/// or what a byte-order mark switched it to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Encoding {
    Utf8,
    Utf16Le,
    Utf16Be,
    Utf32Le,
    Utf32Be,
}

/// How many of a stream's first bytes [detect_bom] needs, as the
/// `StreamReader`s of [Read-ChatqJson](src/queue.ps1) and
/// [Invoke-ChatqProcess](src/queue.ps1) look at four: a reader holds that
/// many (or the whole of a shorter stream) before it decodes.
pub const BOM_WINDOW: usize = 4;

/// `StreamReader.DetectEncoding`, on a stream's first [BOM_WINDOW] bytes, or
/// all of a shorter stream: the encoding, and how many bytes its mark takes.
/// It is the same in both .NETs, for `Get-Content -Encoding UTF8` in
/// [Read-ChatqJson](src/queue.ps1) and for the stdout of
/// [Invoke-ChatqProcess](src/queue.ps1) (`detectEncodingFromByteOrderMarks`).
/// Only the first mark is one: a second is text, U+FEFF.
///
/// .NET looks at the bytes of its first read, so a pipe that hands over a
/// lone first byte would get no detection there; chatqd always looks at the
/// first four, as .NET does whenever the first read brings that many.
pub fn detect_bom(first: &[u8]) -> (Encoding, usize) {
    match first {
        [0xFE, 0xFF, ..] => (Encoding::Utf16Be, 2),
        [0xFF, 0xFE, 0, 0, ..] => (Encoding::Utf32Le, 4),
        [0xFF, 0xFE, ..] => (Encoding::Utf16Le, 2),
        [0xEF, 0xBB, 0xBF, ..] => (Encoding::Utf8, 3),
        [0, 0, 0xFE, 0xFF, ..] => (Encoding::Utf32Be, 4),
        _ => (Encoding::Utf8, 0),
    }
}

/// One .NET flavour's decoder for one [Encoding], fed bytes in any chunks:
/// an unfinished sequence waits for the next call, so the text does not
/// depend on where the chunks were cut - as with .NET's own decoders, which
/// both PowerShells' readers keep across their buffer refills: the stdout
/// reader of [Invoke-ChatqProcess](src/queue.ps1), and Get-Content's in
/// [Read-ChatqJson](src/queue.ps1).
#[derive(Debug)]
pub struct Decoder {
    enc: Encoding,
    fl: Flavour,
    /// UTF-16 / UTF-32: the bytes of an unfinished code unit
    unit: [u8; 4],
    nunit: usize,
    /// UTF-16: a high surrogate waiting for its low half
    high: Option<u16>,
    /// UTF-8: the code point so far, the bytes still due, the range the next
    /// one must fall in, and how many bytes the sequence has taken
    cp: u32,
    need: u8,
    lo: u8,
    hi: u8,
    took: u8,
    replaced: bool,
}

impl Decoder {
    /// A decoder as the `StreamReader`s of [Read-ChatqJson](src/queue.ps1)
    /// and [Invoke-ChatqProcess](src/queue.ps1) build one: replacement,
    /// never an error.
    pub fn new(enc: Encoding, fl: Flavour) -> Decoder {
        Decoder {
            enc,
            fl,
            unit: [0; 4],
            nunit: 0,
            high: None,
            cp: 0,
            need: 0,
            lo: 0x80,
            hi: 0xBF,
            took: 0,
            replaced: false,
        }
    }

    /// The text of `bytes`, onto `out`: one read of stdout, as
    /// [Invoke-ChatqProcess](src/queue.ps1)'s reader decodes it.
    pub fn decode(&mut self, bytes: &[u8], out: &mut String) {
        match self.enc {
            Encoding::Utf8 => {
                let mut rest = bytes;
                while !rest.is_empty() {
                    if self.need == 0 {
                        let ok = match std::str::from_utf8(rest) {
                            Ok(s) => s.len(),
                            Err(e) => e.valid_up_to(),
                        };
                        out.push_str(std::str::from_utf8(&rest[..ok]).unwrap_or_default());
                        rest = &rest[ok..];
                        if rest.is_empty() {
                            break;
                        }
                    }
                    self.utf8(rest[0], out);
                    rest = &rest[1..];
                }
            }
            _ => {
                let width = if matches!(self.enc, Encoding::Utf16Le | Encoding::Utf16Be) {
                    2
                } else {
                    4
                };
                for &b in bytes {
                    self.unit[self.nunit] = b;
                    self.nunit += 1;
                    if self.nunit == width {
                        self.nunit = 0;
                        self.whole_unit(out);
                    }
                }
            }
        }
    }

    /// The end of the stream - stdout's in [Invoke-ChatqProcess](src/queue.ps1),
    /// the file's in [Read-ChatqJson](src/queue.ps1): what an unfinished
    /// sequence leaves. pwsh 7 flushes its decoder there, one U+FFFD for each
    /// unfinished thing; 5.1's `StreamReader` never does, so the bytes are
    /// dropped.
    pub fn finish(&mut self, out: &mut String) {
        let mut left = 0;
        if self.need > 0 {
            left += 1;
            self.need = 0;
        }
        if self.high.take().is_some() {
            left += 1;
        }
        if self.nunit > 0 {
            left += 1;
            self.nunit = 0;
        }
        if left > 0 {
            self.replaced = true;
            if self.fl == Flavour::Core {
                out.extend(std::iter::repeat_n(REPLACEMENT, left));
            }
        }
    }

    /// Whether any byte so far failed to decode, or was dropped: the text
    /// does not encode back to the bytes - for a file
    /// [Read-ChatqJson](src/queue.ps1) reads, a read that needed a repair
    /// (SPEC 2.2).
    pub fn replaced(&self) -> bool {
        self.replaced
    }

    fn bad(&mut self, out: &mut String) {
        self.replaced = true;
        out.push(REPLACEMENT);
    }

    fn start(&mut self, cp: u8, need: u8, lo: u8, hi: u8) {
        self.cp = u32::from(cp);
        self.need = need;
        self.lo = lo;
        self.hi = hi;
        self.took = 1;
    }

    fn utf8(&mut self, b: u8, out: &mut String) {
        if self.need > 0 {
            if (self.lo..=self.hi).contains(&b) {
                self.cp = (self.cp << 6) | u32::from(b & 0x3F);
                self.need -= 1;
                self.took += 1;
                self.lo = 0x80;
                self.hi = 0xBF;
                if self.need == 0 {
                    out.push(char::from_u32(self.cp).unwrap_or(REPLACEMENT));
                }
                return;
            }
            // the sequence so far is one U+FFFD
            self.need = 0;
            self.bad(out);
            // 5.1 takes a second byte that is a continuation byte, only out
            // of its lead's range, into that U+FFFD; pwsh 7 reads it again
            if self.fl == Flavour::Desktop && self.took == 1 && (0x80..=0xBF).contains(&b) {
                return;
            }
        }
        match b {
            0x00..=0x7F => out.push(char::from(b)),
            0xC2..=0xDF => self.start(b & 0x1F, 1, 0x80, 0xBF),
            0xE0 => self.start(0, 2, 0xA0, 0xBF),
            0xE1..=0xEC | 0xEE | 0xEF => self.start(b & 0x0F, 2, 0x80, 0xBF),
            0xED => self.start(0x0D, 2, 0x80, 0x9F),
            0xF0 => self.start(0, 3, 0x90, 0xBF),
            0xF1..=0xF3 => self.start(b & 0x07, 3, 0x80, 0xBF),
            0xF4 => self.start(4, 3, 0x80, 0x8F),
            _ => self.bad(out),
        }
    }

    fn whole_unit(&mut self, out: &mut String) {
        let u = self.unit;
        match self.enc {
            Encoding::Utf16Le => self.utf16(u16::from_le_bytes([u[0], u[1]]), out),
            Encoding::Utf16Be => self.utf16(u16::from_be_bytes([u[0], u[1]]), out),
            Encoding::Utf32Le => self.utf32(u32::from_le_bytes(u), out),
            Encoding::Utf32Be => self.utf32(u32::from_be_bytes(u), out),
            Encoding::Utf8 => {}
        }
    }

    fn utf16(&mut self, u: u16, out: &mut String) {
        if let Some(h) = self.high.take() {
            if (0xDC00..=0xDFFF).contains(&u) {
                let c = 0x10000 + ((u32::from(h) - 0xD800) << 10) + (u32::from(u) - 0xDC00);
                out.push(char::from_u32(c).unwrap_or(REPLACEMENT));
                return;
            }
            // a high half with no low one is one U+FFFD; this unit is read
            // on its own
            self.bad(out);
        }
        match u {
            0xD800..=0xDBFF => self.high = Some(u),
            0xDC00..=0xDFFF => self.bad(out),
            _ => out.push(char::from_u32(u32::from(u)).unwrap_or(REPLACEMENT)),
        }
    }

    fn utf32(&mut self, c: u32, out: &mut String) {
        // a surrogate or a value past U+10FFFF is one U+FFFD
        match char::from_u32(c) {
            Some(ch) => out.push(ch),
            None => self.bad(out),
        }
    }
}

/// A whole stream as `StreamReader.ReadToEnd` - and so `Get-Content -Raw
/// -Encoding UTF8` in [Read-ChatqJson](src/queue.ps1) - gives it: the mark
/// detected and dropped, the rest decoded, the end flushed as `fl` flushes
/// it. Also whether any byte failed to decode or was dropped (U+FFFD put,
/// or an unfinished sequence lost): the "needed a repair" half of SPEC 2.2
/// that the bytes decide. `Get-Content` hands an empty text on as `$null`.
pub fn read_text(bytes: &[u8], fl: Flavour) -> (String, bool) {
    let (enc, skip) = detect_bom(&bytes[..bytes.len().min(BOM_WINDOW)]);
    let mut d = Decoder::new(enc, fl);
    let mut text = String::with_capacity(bytes.len());
    d.decode(&bytes[skip..], &mut text);
    d.finish(&mut text);
    (text, d.replaced())
}

#[cfg(test)]
mod tests {
    use super::*;
    use Flavour::{Core, Desktop};

    fn fffd(bytes: &[u8], fl: Flavour) -> usize {
        read_text(bytes, fl).0.matches(REPLACEMENT).count()
    }

    #[test]
    fn invalid_sequences_count_as_each_dotnet_counts_them() {
        // (bytes, 5.1's U+FFFD count, pwsh 7's), as probed on both
        let cases: [(&[u8], usize, usize); 10] = [
            (b"\xE0\x80\x80", 2, 3),
            (b"\xED\xA0\x80", 2, 3),
            (b"\xF0\x80\x80\x80", 3, 4),
            (b"\xF4\x90\x80\x80", 3, 4),
            (b"\xED\xA0\xBD\xED\xB8\x80", 4, 6),
            (b"\xC0\x80", 2, 2),
            (b"\xF8\x88\x80\x80\x80", 5, 5),
            (b"\xFC\x84\x80\x80\x80\x80", 6, 6),
            (b"\xC1", 1, 1),
            (b"\x80\xBF", 2, 2),
        ];
        for (b, desk, core) in cases {
            assert_eq!(fffd(b, Desktop), desk, "{b:02x?} on 5.1");
            assert_eq!(fffd(b, Core), core, "{b:02x?} on pwsh 7");
        }
        assert_eq!(read_text(b"\xE0\x80AA", Desktop).0, "\u{FFFD}AA");
        assert_eq!(read_text(b"\xE0\x80AA", Core).0, "\u{FFFD}\u{FFFD}AA");
        assert_eq!(read_text(b"\xF0\x90A", Desktop).0, "\u{FFFD}A");
        assert_eq!(read_text(b"\xE2\xE2\x82\xAC", Core).0, "\u{FFFD}\u{20AC}");
    }

    #[test]
    fn the_end_of_the_stream_drops_or_flushes() {
        let cut: [&[u8]; 4] = [b"\xE2", b"\xE2\x82", b"\xF0\x9F\x98", b"\xC2"];
        for b in cut {
            let mut all = b"x".to_vec();
            all.extend_from_slice(b);
            assert_eq!(read_text(&all, Desktop), ("x".into(), true));
            assert_eq!(read_text(&all, Core), ("x\u{FFFD}".into(), true));
        }
        // a literal U+FFFD is text, not a repair
        assert_eq!(
            read_text("a\u{FFFD}".as_bytes(), Core),
            ("a\u{FFFD}".into(), false)
        );
    }

    #[test]
    fn byte_order_marks_switch_the_decoder() {
        let t = |b: &[u8], fl| read_text(b, fl).0;
        assert_eq!(t(b"\xEF\xBB\xBFA", Core), "A");
        assert_eq!(t(b"\xEF\xBB\xBF\xEF\xBB\xBFA", Desktop), "\u{FEFF}A");
        assert_eq!(t(b"\xFF\xFEA\x00", Core), "A");
        assert_eq!(t(b"\xFE\xFF\x00A", Core), "A");
        assert_eq!(t(b"\xFF\xFE\x00\x00A\x00\x00\x00", Core), "A");
        assert_eq!(t(b"\x00\x00\xFE\xFF\x00\x00\x00A", Core), "A");
        assert_eq!(t(b"\xFF\xFE\x3D\xD8\x00\xDE", Core), "\u{1F600}");
        assert_eq!(t(b"\xFF\xFE\x3D\xD8A\x00", Desktop), "\u{FFFD}A");
        assert_eq!(t(b"\xFF\xFE\x00\xDCA\x00", Desktop), "\u{FFFD}A");
        assert_eq!(t(b"\xFF\xFE\x00\x00\x00\xD8\x00\x00", Desktop), "\u{FFFD}");
        assert_eq!(t(b"\xFF\xFE\x00\x00\x00\x00\x11\x00", Core), "\u{FFFD}");
        // unfinished units at the end: dropped by 5.1, one U+FFFD each by 7
        assert_eq!(t(b"\xFF\xFEA", Desktop), "");
        assert_eq!(t(b"\xFF\xFEA", Core), "\u{FFFD}");
        assert_eq!(t(b"\xFE\xFF\x00A\x00", Core), "A\u{FFFD}");
        assert_eq!(t(b"\xFF\xFE\x3D\xD8", Core), "\u{FFFD}");
        assert_eq!(t(b"\xFF\xFE\x3D\xD8\x41", Core), "\u{FFFD}\u{FFFD}");
        assert_eq!(t(b"\xFF\xFE\x00\x00A\x00\x00\x00B", Core), "A\u{FFFD}");
        // too short for a mark: UTF-8
        assert_eq!(t(b"\xFE", Core), "\u{FFFD}");
        assert_eq!(t(b"\x00A", Core), "\u{0}A");
        assert_eq!(t(b"\xEF\xBB", Desktop), "");
        assert_eq!(t(b"\xEF\xBB", Core), "\u{FFFD}");
        assert_eq!(t(b"\xFE\xFF", Core), "");
    }

    #[test]
    fn chunks_do_not_change_the_text() {
        let bytes = b"a\xE0\x80\x80b\xF0\x9F\x98\x80c\xED\xA0\x80\xE2\x82";
        for fl in [Desktop, Core] {
            let whole = read_text(bytes, fl);
            for size in 1..bytes.len() {
                let mut d = Decoder::new(Encoding::Utf8, fl);
                let mut out = String::new();
                for c in bytes.chunks(size) {
                    d.decode(c, &mut out);
                }
                d.finish(&mut out);
                assert_eq!((out, d.replaced()), whole, "chunks of {size}");
            }
        }
    }
}
