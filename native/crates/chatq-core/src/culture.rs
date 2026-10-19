//! The launcher's culture (SPEC 2.11). PowerShell's `ToString('HH:mm:ss')`
//! puts the culture's time separator where the pattern has `:`, and
//! `'{0:N0}'` groups digits by the culture's separator and sizes, so the
//! launcher passes all of it in `--culture`, and chatqd keeps it for its whole
//! life, as a PS watcher keeps the culture it read once.
//!
//! Lane and provider names are `TextInfo.ToTitleCase` in that culture, which
//! its name alone decides: `tr` and `az` case i and I the Turkish way, and
//! pwsh 7 alone makes a word's leading IJ one letter under `nl-*`.

use crate::time::Flavour;
use base64::Engine as _;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use chrono::Timelike;
use regex::RegexSet;
use std::sync::LazyLock;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Culture {
    pub name: String,
    /// `DateTimeFormat.TimeSeparator`
    pub time_sep: String,
    /// `NumberFormat.NumberGroupSeparator`
    pub group_sep: String,
    /// `NumberFormat.NumberGroupSizes`: the last size repeats, and a 0 leaves
    /// the digits left of it ungrouped
    pub group_sizes: Vec<u32>,
}

/// b64url as the PS side writes it: no padding, though padding is let by.
const B64URL: GeneralPurpose = GeneralPurpose::new(
    &base64::alphabet::URL_SAFE,
    GeneralPurposeConfig::new()
        .with_encode_padding(false)
        .with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

impl Culture {
    /// What a launch with no `--culture` gets: the invariant culture's.
    pub fn invariant() -> Culture {
        Culture {
            name: String::new(),
            time_sep: ":".into(),
            group_sep: ",".into(),
            group_sizes: vec![3],
        }
    }

    /// The block [Get-ChatqWatcherLaunch](src/watcher.ps1) builds:
    /// `{name, timeSep, groupSep, groupSizes}`.
    pub fn from_json(v: &serde_json::Value) -> Option<Culture> {
        let sizes = v
            .get("groupSizes")?
            .as_array()?
            .iter()
            .map(|n| n.as_u64().and_then(|n| u32::try_from(n).ok()))
            .collect::<Option<Vec<u32>>>()?;
        Some(Culture {
            name: v.get("name")?.as_str()?.to_string(),
            time_sep: v.get("timeSep")?.as_str()?.to_string(),
            group_sep: v.get("groupSep")?.as_str()?.to_string(),
            group_sizes: sizes,
        })
    }

    /// `--culture <b64url(JSON)>`, the block above.
    pub fn from_arg(arg: &str) -> Option<Culture> {
        let bytes = B64URL.decode(arg.trim()).ok()?;
        Culture::from_json(&serde_json::from_slice(&bytes).ok()?)
    }

    /// `ToString('HH:mm')` on a wall-clock time.
    pub fn hh_mm<T: Timelike>(&self, t: &T) -> String {
        format!("{:02}{}{:02}", t.hour(), self.time_sep, t.minute())
    }

    /// `ToString('HH:mm:ss')` on a wall-clock time.
    pub fn hh_mm_ss<T: Timelike>(&self, t: &T) -> String {
        let s = &self.time_sep;
        format!("{:02}{s}{:02}{s}{:02}", t.hour(), t.minute(), t.second())
    }

    /// `'{0:N0}' -f $n` for a count, which is never negative.
    pub fn n0(&self, n: u64) -> String {
        let digits = n.to_string();
        let mut groups = Vec::new();
        let mut end = digits.len();
        let mut k = 0;
        loop {
            let size = self.group_sizes.get(k).copied().unwrap_or(0) as usize;
            if size == 0 || end <= size {
                groups.push(&digits[..end]);
                break;
            }
            groups.push(&digits[end - size..end]);
            end -= size;
            if k + 1 < self.group_sizes.len() {
                k += 1;
            }
        }
        groups.reverse();
        groups.join(&self.group_sep)
    }

    /// [Format-ChatqLane](src/watcher.ps1): a lane's provider part
    /// title-cased, then ` (home)` when the home part is not empty. Only the
    /// first `|` splits, and an empty provider part stays empty: `|h` gives
    /// ` (h)`.
    pub fn lane_name(&self, lane: &str, fl: Flavour) -> String {
        let (p, h) = lane.split_once('|').unwrap_or((lane, ""));
        let name = self.title_case(p, fl);
        if h.is_empty() {
            name
        } else {
            format!("{name} ({h})")
        }
    }

    /// [Format-ChatqProvider](src/watcher.ps1): a provider, or a lane's
    /// provider part, title-cased; `Claude` when that part is empty.
    pub fn provider_name(&self, lane: &str, fl: Flavour) -> String {
        let p = lane.split_once('|').map_or(lane, |(p, _)| p);
        self.title_case(if p.is_empty() { "claude" } else { p }, fl)
    }

    /// `TextInfo.ToTitleCase`, as [Format-ChatqLane](src/watcher.ps1) and
    /// [Format-ChatqProvider](src/watcher.ps1) call it on `Get-Culture`. A
    /// word starts at a letter, which goes upper case; the rest of it goes
    /// lower case unless it has no lower case letter (an acronym stays). A
    /// word runs on over letters, marks and digits, and past an apostrophe,
    /// after which it is lower case; any other punctuation or symbol, a space
    /// or a control ends it.
    pub fn title_case(&self, s: &str, fl: Flavour) -> String {
        let cs: Vec<char> = s.chars().collect();
        let dutch = fl == Flavour::Core
            && self
                .name
                .get(..3)
                .is_some_and(|p| p.eq_ignore_ascii_case("nl-"));
        let mut out = String::with_capacity(s.len());
        let mut i = 0;
        while i < cs.len() {
            let first = kind(cs[i]);
            if !matches!(first, Kind::Lower | Kind::Letter) {
                out.push(cs[i]);
                i += 1;
                continue;
            }
            if dutch && matches!(cs[i], 'i' | 'I') && matches!(cs.get(i + 1), Some('j' | 'J')) {
                out.push_str("IJ");
                i += 2;
            } else {
                out.push(self.title_letter(cs[i]));
                i += 1;
            }
            let (mut from, mut lower) = (i, first == Kind::Lower);
            while i < cs.len() {
                match kind(cs[i]) {
                    Kind::Lower => lower = true,
                    Kind::Letter | Kind::Part => {}
                    Kind::Break if cs[i] == '\'' => {
                        self.push_rest(&mut out, &cs[from..=i], lower);
                        (from, lower) = (i + 1, true);
                    }
                    Kind::Break => break,
                }
                i += 1;
            }
            self.push_rest(&mut out, &cs[from..i], lower);
            if let Some(&c) = cs.get(i) {
                out.push(c);
                i += 1;
            }
        }
        out
    }

    /// A word's letters after its first: lower case, unless it has none.
    fn push_rest(&self, out: &mut String, rest: &[char], lower: bool) {
        if lower {
            out.extend(rest.iter().map(|&c| self.lower(c)));
        } else {
            out.extend(rest);
        }
    }

    /// A word's first letter: .NET's own title case for the four Latin
    /// digraphs, else upper case.
    fn title_letter(&self, c: char) -> char {
        match c {
            '\u{1C4}'..='\u{1C6}' => '\u{1C5}',
            '\u{1C7}'..='\u{1C9}' => '\u{1C8}',
            '\u{1CA}'..='\u{1CC}' => '\u{1CB}',
            '\u{1F1}'..='\u{1F3}' => '\u{1F2}',
            _ => self.upper(c),
        }
    }

    /// `TextInfo.ToUpper` on one letter: the one-letter (simple) mapping,
    /// Turkish i, and dotless i kept by the invariant culture.
    fn upper(&self, c: char) -> char {
        match c {
            'i' if self.turkish() => '\u{130}',
            '\u{131}' if self.name.is_empty() => c,
            _ => {
                let mut u = c.to_uppercase();
                match (u.next(), u.next()) {
                    (Some(x), None) => x,
                    _ => greek_upper(c).unwrap_or(c),
                }
            }
        }
    }

    /// `TextInfo.ToLower` on one char: the one-letter mapping, Turkish I, and
    /// dotted I, which is i in every culture but the invariant one.
    fn lower(&self, c: char) -> char {
        match c {
            'I' if self.turkish() => '\u{131}',
            '\u{130}' if self.name.is_empty() => c,
            '\u{130}' => 'i',
            _ => {
                let mut l = c.to_lowercase();
                match (l.next(), l.next()) {
                    (Some(x), None) => x,
                    _ => c,
                }
            }
        }
    }

    /// `tr` and `az`, in any script or region, case i and I the Turkish way.
    fn turkish(&self) -> bool {
        let lang = self.name.split('-').next().unwrap_or("");
        lang.eq_ignore_ascii_case("tr") || lang.eq_ignore_ascii_case("az")
    }
}

/// A char's general category, as far as `ToTitleCase` asks.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    /// Ll
    Lower,
    /// Lu, Lt, Lm, Lo
    Letter,
    /// a space, control, format char, punctuation or symbol: ends a word
    Break,
    /// a mark, digit, private use or unassigned char: inside a word
    Part,
}

fn kind(c: char) -> Kind {
    static CATEGORIES: LazyLock<RegexSet> = LazyLock::new(|| {
        RegexSet::new([r"\p{Ll}", r"\p{L}", r"[\p{Z}\p{Cc}\p{Cf}\p{P}\p{S}]"])
            .expect("fixed patterns")
    });
    let m = CATEGORIES.matches(c.encode_utf8(&mut [0; 4]));
    if m.matched(0) {
        Kind::Lower
    } else if m.matched(1) {
        Kind::Letter
    } else if m.matched(2) {
        Kind::Break
    } else {
        Kind::Part
    }
}

/// The one-letter upper case of a Greek letter with ypogegrammeni, which
/// .NET gives where Rust's full mapping gives two letters.
fn greek_upper(c: char) -> Option<char> {
    let n = u32::from(c);
    match n {
        0x1F80..=0x1F87 | 0x1F90..=0x1F97 | 0x1FA0..=0x1FA7 => char::from_u32(n + 8),
        0x1FB3 | 0x1FC3 | 0x1FF3 => char::from_u32(n + 9),
        _ => None,
    }
}

#[cfg(test)]
pub fn encode_arg(json: &str) -> String {
    B64URL.encode(json.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Local, NaiveTime, TimeZone};

    #[test]
    fn reads_the_launch_block() {
        let arg = encode_arg(r#"{"name":"fi-FI","timeSep":".","groupSep":" ","groupSizes":[3]}"#);
        let c = Culture::from_arg(&arg).unwrap();
        assert_eq!(c.name, "fi-FI");
        let t = Local.with_ymd_and_hms(2026, 10, 15, 9, 5, 7).unwrap();
        assert_eq!(c.hh_mm_ss(&t), "09.05.07");
        assert_eq!(c.hh_mm(&t), "09.05");
        assert_eq!(c.n0(1234567), "1\u{a0}234\u{a0}567");
        assert_eq!(Culture::invariant().hh_mm_ss(&t), "09:05:07");
        assert!(Culture::from_arg("%%").is_none());
        // a block from before the number fields is no block
        assert!(Culture::from_arg(&encode_arg(r#"{"name":"x","timeSep":":"}"#)).is_none());
    }

    #[test]
    fn groups_as_dotnet_does() {
        let mut c = Culture::invariant();
        assert_eq!(c.n0(0), "0");
        assert_eq!(c.n0(999), "999");
        assert_eq!(c.n0(1000), "1,000");
        assert_eq!(c.n0(1234567), "1,234,567");
        c.group_sizes = vec![3, 2];
        assert_eq!(c.n0(1234567), "12,34,567");
        assert_eq!(c.n0(123), "123");
        c.group_sizes = vec![3, 0];
        assert_eq!(c.n0(1234567), "1234,567");
        c.group_sizes = vec![];
        assert_eq!(c.n0(1234567), "1234567");
        let t = NaiveTime::from_hms_opt(23, 0, 59).unwrap();
        assert_eq!(c.hh_mm_ss(&t), "23:00:59");
    }

    #[test]
    fn title_cases_as_dotnet_does() {
        // what 5.1 and pwsh 7.6 gave alike for input culture.json leaves out,
        // lest another pwsh's ICU answer differently (SPEC 2.11)
        let named = |n: &str| Culture {
            name: n.into(),
            ..Culture::invariant()
        };
        let (en, inv, d) = (named("en-US"), Culture::invariant(), Flavour::Desktop);
        assert_eq!(en.title_case("\u{131}x", d), "Ix");
        assert_eq!(en.title_case("x\u{130}", d), "Xi");
        assert_eq!(inv.title_case("\u{131}x", d), "\u{131}x");
        assert_eq!(inv.title_case("x\u{130}", d), "X\u{130}");
        assert_eq!(
            named("az-Cyrl-AZ").title_case("icloud gemINI", d),
            "\u{130}cloud Gem\u{131}n\u{131}"
        );
        // one letter where the full mapping has two
        assert_eq!(en.title_case("\u{1FB3}A\u{1FB3}", d), "\u{1FBC}a\u{1FB3}");
        assert_eq!(en.title_case("\u{DF}A", d), "\u{DF}a");
        assert_eq!(en.title_case("\u{149}A", d), "\u{149}a");
        assert_eq!(
            en.title_case("\u{10428}X\u{10400}", d),
            "\u{10400}x\u{10428}"
        );
        // the IJ rule is pwsh 7's, for nl-* and not the neutral nl
        assert_eq!(named("nl-BE").title_case("ijssel", Flavour::Core), "IJssel");
        assert_eq!(named("nl-BE").title_case("ijssel", d), "Ijssel");
        assert_eq!(named("nl").title_case("ijssel", Flavour::Core), "Ijssel");
    }
}
