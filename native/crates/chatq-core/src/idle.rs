//! macOS idle time as [Get-ChatqIdleSeconds](src/alerts.ps1) reads it from
//! `ioreg -c IOHIDSystem` (SPEC 3.5). Used from M6. Vector:
//! native/vectors/idle.json.

use crate::time::Flavour;
use regex::Regex;
use std::sync::LazyLock;

/// [Get-ChatqIdleSeconds](src/alerts.ps1) on macOS, from what
/// `ioreg -c IOHIDSystem` printed: the first line that `-match
/// 'HIDIdleTime'` (`names_idle_time`), and in it the first `=\s*(\d+)`,
/// nanoseconds, as seconds. None where that line has none, or where
/// `[double]` cannot read the digits: any but 0-9, or more than a double
/// holds under Windows PowerShell 5.1 (pwsh 7 reads infinity). Only the
/// first such line is tried. 5.1 reads some long digit strings a unit in
/// the last place off, which this does not follow; ioreg's count is 64-bit,
/// 20 digits at most, and those it reads right.
pub fn idle_seconds(ioreg_out: &str, fl: Flavour) -> Option<f64> {
    // \d over UTF-16 code units, as .NET matches: a digit past the BMP is
    // two surrogates there, which \d does not take
    static NANOS: LazyLock<Regex> =
        LazyLock::new(|| Regex::new(r"=\s*([\d&&[\x{0}-\x{FFFF}]]+)").expect("a valid pattern"));
    let line = ps_lines(ioreg_out)
        .into_iter()
        .find(|l| names_idle_time(l))?;
    let digits = NANOS.captures(line)?.get(1)?.as_str();
    if !digits.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let n: f64 = digits.parse().ok()?;
    if n.is_infinite() && fl == Flavour::Desktop {
        return None;
    }
    Some(n / 1e9)
}

/// `$_ -match 'HIDIdleTime'` under en-US, which both PowerShells match
/// case-blind: ASCII letters in either case, and I with a dot above
/// (U+0130) as i - the one other character .NET takes for a letter of the
/// word.
fn names_idle_time(line: &str) -> bool {
    let folded: String = line
        .chars()
        .map(|c| match c {
            '\u{130}' => 'i',
            c => c.to_ascii_lowercase(),
        })
        .collect();
    folded.contains("hididletime")
}

/// A program's output as PowerShell reads it, line by line: split at CR LF,
/// CR or LF, with no empty line after a last line break.
fn ps_lines(s: &str) -> Vec<&str> {
    let b = s.as_bytes();
    let mut out = Vec::new();
    let (mut start, mut i) = (0, 0);
    while i < b.len() {
        match b[i] {
            b'\r' | b'\n' => {
                out.push(&s[start..i]);
                i += if b[i] == b'\r' && b.get(i + 1) == Some(&b'\n') {
                    2
                } else {
                    1
                };
                start = i;
            }
            _ => i += 1,
        }
    }
    if start < b.len() {
        out.push(&s[start..]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines_as_powershell_splits_them() {
        assert_eq!(ps_lines(""), Vec::<&str>::new());
        assert_eq!(ps_lines("a\r\n\r\nb\rc\n"), ["a", "", "b", "c"]);
        assert_eq!(ps_lines("\n"), [""]);
    }

    #[test]
    fn first_line_first_number() {
        let fl = Flavour::Desktop;
        let out = "  \"HIDIdleTimeUnits\" = \"ns\"\n  \"HIDIdleTime\" = 5000000000\n";
        assert_eq!(idle_seconds(out, fl), None);
        assert_eq!(
            idle_seconds("\"HIDIdleTime\"=abc=2500000000", fl),
            Some(2.5)
        );
        assert_eq!(idle_seconds("hididletime = 0", fl), Some(0.0));
        assert_eq!(idle_seconds("\"HIDIdleTime\" = -5", fl), None);
    }

    #[test]
    fn digits_as_dotnet_takes_them() {
        let fl = Flavour::Core;
        assert_eq!(idle_seconds("HIDIdleTime = 25\u{1E950}", fl), Some(2.5e-8));
        assert_eq!(idle_seconds("HIDIdleTime = 25\u{661}", fl), None);
        assert_eq!(
            idle_seconds("H\u{130}DIdleTime = 1000000000", fl),
            Some(1.0)
        );
        assert_eq!(idle_seconds("H\u{131}DIdleTime = 1000000000", fl), None);
    }
}
