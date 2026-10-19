//! Stamps as PowerShell writes and reads them (SPEC 2.2).
//!
//! chrono has no seven-digit fraction, and .NET's round-trip 'o' format always
//! writes seven, so the formatting here is by hand.
//!
//! Reading is a port of what the two PowerShells do, pinned case by case by
//! native/vectors/stamps.json (tests/vectors/stamps.ps1). A stamp means what
//! [ConvertTo-ChatqDate](src/queue.ps1) makes of what ConvertFrom-Json, in
//! [Read-ChatqJson](src/queue.ps1), made of it. pwsh 7's ConvertFrom-Json
//! (Newtonsoft.Json) has already made a DateTime of most ISO stamps and of
//! `/Date(ms)/`; 5.1's (JavaScriptSerializer) only of `"\/Date(ms)\/"`; and
//! what is still a string goes to `[datetime]::Parse`, whose .NET (pwsh 7)
//! and .NET Framework (5.1) take slightly different shapes. The ports work on
//! UTF-16 code units, as .NET does.

use chrono::{
    DateTime, Datelike, Duration, FixedOffset, Local, MappedLocalTime, NaiveDate, NaiveDateTime,
    Offset, TimeZone, Timelike, Utc,
};
use serde_json::Value;
use std::ops::RangeInclusive;

/// A point in time. Every stamp chatqd reads becomes one of these, so the
/// local/UTC question is settled once, at the read.
pub type Instant = DateTime<Utc>;

/// The zone wall-clock time is read in: the system's, as PowerShell's
/// `Get-Date` and `ToLocalTime` read it, or one the vectors give so that a
/// file means the same on every machine (SPEC 6.1).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Zone {
    Local,
    Fixed(FixedOffset),
    /// `before` until the instant `at` and `after` from it: a real zone
    /// either side of one DST change, as the stamps vectors give it, where
    /// [ConvertTo-ChatqDate](src/queue.ps1) reads a wall-clock time the
    /// change skips or repeats at the offset [resolve_offset] picks.
    Change {
        at: Instant,
        before: FixedOffset,
        after: FixedOffset,
    },
}

impl Zone {
    /// Seconds east of UTC at `t`.
    pub fn offset_at(self, t: Instant) -> i32 {
        match self {
            Zone::Local => t.with_timezone(&Local).offset().fix().local_minus_utc(),
            Zone::Fixed(o) => o.local_minus_utc(),
            Zone::Change { at, before, after } => {
                (if t < at { before } else { after }).local_minus_utc()
            }
        }
    }

    /// The wall-clock time at `t`.
    pub fn wall(self, t: Instant) -> NaiveDateTime {
        t.naive_utc() + Duration::seconds(self.offset_at(t) as i64)
    }

    /// The instant a wall-clock time names. Where a DST change skips or
    /// repeats it, that is at the offset [resolve_offset] picks, as .NET
    /// reads it, not chrono's earliest.
    pub fn instant_of(self, n: &NaiveDateTime) -> Instant {
        let off = match self {
            Zone::Local => match Local.offset_from_local_datetime(n) {
                MappedLocalTime::Single(o) => o,
                MappedLocalTime::Ambiguous(a, b) => resolve_offset(a, b),
                // skipped: the change is within 14 hours of `n` as UTC, so
                // these two are its offsets before and after
                MappedLocalTime::None => resolve_offset(
                    Local.offset_from_utc_datetime(&(*n - Duration::days(1))),
                    Local.offset_from_utc_datetime(&(*n + Duration::days(1))),
                ),
            },
            Zone::Fixed(o) => o,
            Zone::Change { at, before, after } => {
                let (b, a) = (before.local_minus_utc(), after.local_minus_utc());
                let at = at.naive_utc();
                if *n < at + Duration::seconds(b.min(a).into()) {
                    before
                } else if *n >= at + Duration::seconds(b.max(a).into()) {
                    after
                } else {
                    resolve_offset(before, after)
                }
            }
        };
        Utc.from_utc_datetime(&(*n - Duration::seconds(off.local_minus_utc().into())))
    }
}

/// The offset .NET reads a wall-clock time at when a DST change skips or
/// repeats it, from the offsets before and after the change. pwsh 7 reads a
/// zoneless stamp as a DateTime of Kind Unspecified, which
/// [ConvertTo-ChatqDate](src/queue.ps1) returns as is, and TimeZoneInfo takes
/// such a time at the zone's standard offset: the smaller of the two for
/// every change the vectors pin (Pacific, W. Europe and Lord Howe, both
/// ways). A rule whose daylight time is behind its standard time would take
/// the larger; that is not modelled.
/// Deferred: DEFERRED.md "Dates past the shapes the vectors pin"
pub fn resolve_offset(before: FixedOffset, after: FixedOffset) -> FixedOffset {
    if after.local_minus_utc() < before.local_minus_utc() {
        after
    } else {
        before
    }
}

/// Which PowerShell the launcher was, from `--ps`. The two read a stamp with
/// no zone differently, and chatqd behaves as the watcher it stands in for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Flavour {
    /// Windows PowerShell 5.1: such a stamp stays a string, and
    /// [ConvertTo-ChatqDate](src/queue.ps1)'s ToLocalTime takes it as UTC.
    Desktop,
    /// pwsh 7: ConvertFrom-Json has already made it a DateTime of Kind
    /// Unspecified, which ConvertTo-ChatqDate returns as local wall-clock time.
    Core,
}

impl Flavour {
    /// `pwsh` / `pwsh.exe` is 7; anything else is Windows PowerShell.
    pub fn from_exe(path: &str) -> Flavour {
        let name = path
            .rsplit(['\\', '/'])
            .next()
            .unwrap_or("")
            .to_ascii_lowercase();
        if name == "pwsh.exe" || name == "pwsh" {
            Flavour::Core
        } else {
            Flavour::Desktop
        }
    }
}

fn ticks7(nanos: u32) -> u32 {
    // a leap second shows as nanos past 1e9; .NET has none, so it is cut
    nanos.min(999_999_999) / 100
}

/// `.ToUniversalTime().ToString('o')`, as [Get-ChatqStamp](src/queue.ps1):
/// `yyyy-MM-ddTHH:mm:ss.fffffffZ`.
pub fn stamp_utc(t: Instant) -> String {
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:07}Z",
        t.year(),
        t.month(),
        t.day(),
        t.hour(),
        t.minute(),
        t.second(),
        ticks7(t.nanosecond())
    )
}

/// `(Get-Date).ToString('o')`: local time and its offset, as every log line
/// starts ([Add-ChatqLogLine](src/queue.ps1)).
pub fn stamp_local(t: Instant) -> String {
    stamp_in(t, Zone::Local)
}

/// [stamp_local] in a given zone.
pub fn stamp_in(t: Instant, zone: Zone) -> String {
    format_with_offset(zone.wall(t), zone.offset_at(t))
}

/// The 'o' form of a wall-clock time at a given offset from UTC, in seconds.
pub fn format_with_offset(n: NaiveDateTime, offset_secs: i32) -> String {
    let sign = if offset_secs < 0 { '-' } else { '+' };
    let m = offset_secs.unsigned_abs() / 60;
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:07}{}{:02}:{:02}",
        n.year(),
        n.month(),
        n.day(),
        n.hour(),
        n.minute(),
        n.second(),
        ticks7(n.nanosecond()),
        sign,
        m / 60,
        m % 60
    )
}

/// [ConvertTo-ChatqDate](src/queue.ps1) of a string as ConvertFrom-Json read
/// it from a file ([Read-ChatqJson](src/queue.ps1)): the instant it names,
/// or None where PowerShell gives $null. pwsh 7's zoneless DateTimes are
/// read in the local zone.
pub fn parse_stamp(s: &str, flavour: Flavour) -> Option<Instant> {
    parse_stamp_in(s, flavour, Zone::Local)
}

/// [parse_stamp], with pwsh 7's zoneless DateTimes read in `zone`.
///
/// On [Flavour::Core], Newtonsoft.Json goes first. It takes a string of 19
/// to 40 characters that is `yyyy-MM-ddTHH:mm:ss` (hour 24 at 00:00:00 for
/// the next day), up to seven fraction digits, and `Z`, an offset of up to
/// 99 hours and 99 minutes, or nothing (a wall-clock time in `zone`); and
/// `/Date(ms)/`, where an offset after the milliseconds must be digits but
/// changes nothing. On
/// [Flavour::Desktop] only `/Date(ms)/` with nothing, a letter or `±hhmm`
/// after the milliseconds is a DateTime. A `/Date` past DateTime's range
/// fails the whole file.
///
/// Anything else goes to `[datetime]::Parse` (InvariantCulture,
/// RoundtripKind). After white space: a year of 3 to 8 digits, month and day
/// of 1 or 2, split by `-`. Then either `T` and an ISO 8601 time, `HH:mm`
/// with optional `:ss` and fraction, white space allowed around the colons,
/// then `Z`, an offset or nothing, then white space and NULs; or a time
/// `H:m[:s[.f]]` after white space, `.` or `,`, and a zone, where white
/// space, and `.` and `,` that no digit follows, are ignored. An offset is
/// `±h`, `±hh`, `±h:m`, `±hh:mm`, `±hmm` or `±hhmm`, minutes under 60. A
/// fraction rounds to the tick in double precision; a time with no zone is
/// UTC, as ToLocalTime takes Kind Unspecified. The .NETs differ: .NET (pwsh
/// 7) also reads `,` before a fraction and refuses an offset past 14:00;
/// .NET Framework (5.1) skips, unread, the character after an ISO offset.
///
/// Not ported, as nothing writes them: names of months or days, AM/PM, GMT,
/// dates with `/` or `.`, years of 1 or 2 digits, `#`, NULs outside the ISO
/// form, a time before 0001-01-01 or after 9999-12-31 in the local zone
/// (which .NET clamps or refuses), and the escapes of the JSON text, which a
/// parsed value has lost: 5.1 makes a DateTime only of `"\/Date(ms)\/"` (an
/// unescaped `"/Date(ms)/"` stays a string), and pwsh 7 checks the minutes
/// of a `/Date` offset only where the `/` were escaped. This reads both as
/// escaped, as 5.1 writes them.
/// Deferred: DEFERRED.md "Dates past the shapes the vectors pin"
pub fn parse_stamp_in(s: &str, flavour: Flavour, zone: Zone) -> Option<Instant> {
    if s.is_empty() {
        return None; // `if (-not $Text)`
    }
    match json_date(s, None, flavour) {
        Made::Date(d) => d.instant(zone),
        // making it threw, which fails the whole read: $null
        Made::Throws => None,
        Made::Text => net_parse(&s.encode_utf16().collect::<Vec<u16>>(), flavour),
    }
}

/// ConvertTo-ChatqDate on a value read from JSON: only a string can name a
/// time here. (PowerShell parses `[string]` of anything, so a number such as
/// 1.5 names a day of the current year; nothing writes one.)
/// Deferred: DEFERRED.md "Dates past the shapes the vectors pin"
pub fn date_of(v: Option<&Value>, flavour: Flavour) -> Option<Instant> {
    date_of_in(v, flavour, Zone::Local)
}

/// [date_of] with pwsh 7's zoneless DateTimes read in `zone`:
/// [ConvertTo-ChatqDate](src/queue.ps1) of a value as
/// [Read-ChatqJson](src/queue.ps1) read it.
pub fn date_of_in(v: Option<&Value>, flavour: Flavour, zone: Zone) -> Option<Instant> {
    parse_stamp_in(v?.as_str()?, flavour, zone)
}

/// DateTime.MaxValue.Ticks: 9999-12-31T23:59:59.9999999.
const MAX_TICKS: i64 = 3_155_378_975_999_999_999;
/// The ticks of 1970-01-01, where `/Date(ms)/` counts from.
const EPOCH_TICKS: i64 = 621_355_968_000_000_000;
const TICKS_PER_SECOND: i64 = 10_000_000;
const TICKS_PER_DAY: i64 = 86_400 * TICKS_PER_SECOND;

/// A DateTime's Kind, as ConvertFrom-Json makes it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Kind {
    Utc,
    Local,
    Unspecified,
}

/// A `[datetime]` ConvertFrom-Json made of a string: its Kind and ticks.
/// For Local, the ticks are the UTC ones, even out of DateTime's range; the
/// machine's offset is added, within range, where it is rendered.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct NetDate {
    kind: Kind,
    ticks: i64,
}

impl NetDate {
    /// `.ToString('o')` with the machine's zone `zone`, as
    /// [Read-ChatqJson](src/queue.ps1)'s caller would print it.
    pub(crate) fn o(self, zone: FixedOffset) -> String {
        let off = i64::from(zone.local_minus_utc());
        match self.kind {
            Kind::Utc => format!("{}Z", ticks_o(self.ticks)),
            Kind::Unspecified => ticks_o(self.ticks),
            Kind::Local => {
                let t = (self.ticks + off * TICKS_PER_SECOND).clamp(0, MAX_TICKS);
                let m = off.unsigned_abs() / 60;
                let sign = if off < 0 { '-' } else { '+' };
                format!("{}{sign}{:02}:{:02}", ticks_o(t), m / 60, m % 60)
            }
        }
    }

    /// The instant [ConvertTo-ChatqDate](src/queue.ps1) takes it for: Utc
    /// and Local by their UTC ticks, Unspecified (pwsh 7's zoneless ISO) as
    /// a wall-clock time in `zone`.
    pub(crate) fn instant(self, zone: Zone) -> Option<Instant> {
        let unix = self.ticks - EPOCH_TICKS;
        let t = DateTime::from_timestamp(
            unix.div_euclid(TICKS_PER_SECOND),
            (unix.rem_euclid(TICKS_PER_SECOND) * 100) as u32,
        )?;
        match self.kind {
            Kind::Unspecified => Some(zone.instant_of(&t.naive_utc())),
            Kind::Utc | Kind::Local => Some(t),
        }
    }
}

/// `yyyy-MM-ddTHH:mm:ss.fffffff` of in-range ticks.
fn ticks_o(t: i64) -> String {
    let days = i32::try_from(t / TICKS_PER_DAY).unwrap_or(0);
    let d = NaiveDate::from_num_days_from_ce_opt(days + 1).unwrap_or_default();
    let in_day = t % TICKS_PER_DAY;
    let s = in_day / TICKS_PER_SECOND;
    format!(
        "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}.{:07}",
        d.year(),
        d.month(),
        d.day(),
        s / 3600,
        s / 60 % 60,
        s % 60,
        in_day % TICKS_PER_SECOND
    )
}

/// What ConvertFrom-Json made of a string value.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Made {
    /// It stayed a string.
    Text,
    Date(NetDate),
    /// The DateTime it tried to make was out of range: the whole read
    /// throws, so [Read-ChatqJson](src/queue.ps1) gives $null.
    Throws,
}

/// What ConvertFrom-Json under `fl` makes of a string value, `decoded` as
/// read; the crate's one reader of JSON dates, for the grammar
/// ([ps_read](crate::json::ps_read)), [parse_stamp_in] and replystate.rs.
/// - 5.1 (JavaScriptSerializer): only `"\/Date(-?digits[letter|±4 digits])\/"`
///   is one, Kind Utc, its offset ignored. With `raw`, the JSON token with
///   its quotes, it must be spelled so there (a single-quoted or unescaped
///   one stays text); without, `decoded` is read as if it were. A number
///   past a long stays text.
/// - pwsh 7 (Newtonsoft's `DateTimeUtils.TryParseDateTime`, RoundtripKind),
///   on `decoded`: `/Date(ms[±hh[mm]])/` (Utc, or Local with an offset; the
///   ms as Int64TryParse reads them, so 20 digits stay text), and ISO
///   `yyyy-MM-ddTHH:mm:ss[.f{1,7}][Z|±hh[[:]mm]]` of 19 to 40 UTF-16 units
///   (Utc, Local made from the offset, or Unspecified; hour 24 the next
///   day). The quotes do not matter. Its unescaped `/Date` offset-minutes
///   quirk, which hangs on the string's place in Newtonsoft's buffer, is
///   read as escaped.
///
/// A date out of DateTime's range throws.
/// Deferred: DEFERRED.md "Dates past the shapes the vectors pin"
pub(crate) fn json_date(decoded: &str, raw: Option<&str>, fl: Flavour) -> Made {
    match fl {
        Flavour::Desktop => {
            let body = match raw {
                Some(r) => r
                    .strip_prefix("\"\\/Date(")
                    .and_then(|r| r.strip_suffix(")\\/\"")),
                None => decoded
                    .strip_prefix("/Date(")
                    .and_then(|r| r.strip_suffix(")/")),
            };
            body.map_or(Made::Text, javascript_ms)
        }
        Flavour::Core => newtonsoft_date(decoded),
    }
}

/// `new DateTime(ms * 10000 + epoch)`, as both serializers make it: C#'s
/// unchecked arithmetic, so a product past a long wraps, then the range
/// check that throws.
fn from_ms(ms: i64, kind: Kind) -> Made {
    let t = ms.wrapping_mul(10_000).wrapping_add(EPOCH_TICKS);
    if (0..=MAX_TICKS).contains(&t) {
        Made::Date(NetDate { kind, ticks: t })
    } else {
        Made::Throws
    }
}

/// JavaScriptSerializer's `\/Date(...)\/` body: an optional `-` and digits,
/// then nothing, one ASCII letter, or a sign and four digits.
fn javascript_ms(body: &str) -> Made {
    let b = body.as_bytes();
    let sign = usize::from(b.first() == Some(&b'-'));
    let end = sign + b[sign..].iter().take_while(|c| c.is_ascii_digit()).count();
    let tail_ok = match &b[end..] {
        [] => true,
        [c] => c.is_ascii_alphabetic(),
        [s, d @ ..] => matches!(s, b'+' | b'-') && d.len() == 4 && d.iter().all(u8::is_ascii_digit),
    };
    if end == sign || !tail_ok {
        return Made::Text;
    }
    match body[..end].parse::<i64>() {
        Ok(ms) => from_ms(ms, Kind::Utc),
        Err(_) => Made::Text,
    }
}

/// Newtonsoft's TryParseDateTime on a string's UTF-16 units.
fn newtonsoft_date(s: &str) -> Made {
    let u: Vec<u16> = s.encode_utf16().collect();
    let n = u.len();
    if is(&u, 0, b'/') {
        if n >= 9 && s.starts_with("/Date(") && s.ends_with(")/") {
            return newtonsoft_ms(&u);
        }
        return Made::Text;
    }
    // a first digit that is not ASCII passes char.IsDigit, but the parser
    // after it takes ASCII alone
    if (19..=40).contains(&n) && digit_at(&u, 0) && is(&u, 10, b'T') {
        return newtonsoft_iso(&u);
    }
    Made::Text
}

/// Newtonsoft's TryParseMicrosoftDate: `/Date(ms)/`. An offset, the first
/// `+` (else `-`) past index 6, is two code units (and two more when there
/// is room) that must read as numbers, and only makes the Kind Local. The
/// room is as for an escaped `\/Date` ([json_date]).
fn newtonsoft_ms(u: &[u16]) -> Made {
    let n = u.len();
    let find = |c: u8| (7..n - 1).find(|&k| is(u, k, c));
    let (kind, end) = match find(b'+').or_else(|| find(b'-')) {
        Some(k) => {
            let hours = net_int(&u[k + 1..k + 3], 10).is_some();
            let minutes = n - k <= 5 || net_int(&u[k + 3..k + 5], 10).is_some();
            if !(hours && minutes) {
                return Made::Text;
            }
            (Kind::Local, k)
        }
        None => (Kind::Utc, n - 2),
    };
    match net_int(&u[6..end], 19) {
        Some(ms) => from_ms(ms, kind),
        None => Made::Text,
    }
}

/// Newtonsoft's `TryParseDateTimeIso`, on a string with `T` at index 10:
/// the date as its zone places it. A Local one keeps its UTC ticks, even out
/// of range ([NetDate]).
fn newtonsoft_iso(u: &[u16]) -> Made {
    let Some((mut t, next_day, zone)) = iso_parts(u) else {
        return Made::Text;
    };
    if next_day {
        // AddDays(1) past 9999-12-31 throws
        t += TICKS_PER_DAY;
        if t > MAX_TICKS {
            return Made::Throws;
        }
    }
    let (kind, ticks) = match zone {
        IsoZone::None => (Kind::Unspecified, t),
        IsoZone::Utc => (Kind::Utc, t),
        IsoZone::East(off) => (Kind::Local, t - off),
    };
    Made::Date(NetDate { kind, ticks })
}

/// Where an ISO date's zone puts it.
enum IsoZone {
    /// none - or, as Newtonsoft has it, minutes with no hours: Unspecified
    None,
    Utc,
    /// `±hh[[:]mm]`, as ticks east of UTC
    East(i64),
}

/// Newtonsoft's `DateTimeParser.Parse`: the ticks as written, whether the
/// hour was 24 (the next day's midnight), and the zone.
fn iso_parts(u: &[u16]) -> Option<(i64, bool, IsoZone)> {
    let end = u.len();
    let two = |i: usize| -> Option<i64> {
        Some(i64::from(digit(*u.get(i)?)? * 10 + digit(*u.get(i + 1)?)?))
    };
    let year = two(0)? * 100 + two(2)?;
    if year < 1 || !is(u, 4, b'-') || !is(u, 7, b'-') {
        return None;
    }
    let month = two(5).filter(|m| (1..=12).contains(m))?;
    let date = NaiveDate::from_ymd_opt(year as i32, month as u32, two(8)? as u32)?;
    let hour = two(11).filter(|&h| h <= 24)?;
    let minute = two(14).filter(|&m| m < 60)?;
    let second = two(17).filter(|&s| s < 60)?;
    if !is(u, 13, b':') || !is(u, 16, b':') || (hour == 24 && (minute != 0 || second != 0)) {
        return None;
    }
    let mut i = 19;
    let mut fraction = 0;
    if is(u, i, b'.') {
        // seven digits at most; what follows is the zone's to read
        let mut n = 0;
        loop {
            i += 1;
            if !(i < end && n < 7) {
                break;
            }
            let Some(d) = digit(u[i]) else { break };
            fraction = fraction * 10 + i64::from(d);
            n += 1;
        }
        if n == 0 || (hour == 24 && fraction != 0) {
            return None;
        }
        fraction *= 10_i64.pow(7 - n);
    }
    // ParseZone: Z, or a sign and two digits; then optionally `:`, then
    // optionally two more, after no sign too (so "0312" ends a time)
    let mut zone = IsoZone::None;
    if is(u, i, b'z') || is(u, i, b'Z') {
        zone = IsoZone::Utc;
        i += 1;
    } else if i < end {
        let mut hours = None;
        if (is(u, i, b'+') || is(u, i, b'-'))
            && i + 2 < end
            && let Some(h) = two(i + 1)
        {
            hours = Some((if is(u, i, b'-') { -1 } else { 1 }, h));
            i += 3;
        }
        if is(u, i, b':') {
            i += 1;
        }
        let mut minutes = 0;
        if i + 1 < end
            && let Some(m) = two(i)
        {
            minutes = m;
            i += 2;
        }
        if let Some((sign, h)) = hours {
            zone = IsoZone::East(sign * (h * 60 + minutes) * 60 * TICKS_PER_SECOND);
        }
    }
    if i != end {
        return None;
    }
    let days = i64::from(date.num_days_from_ce() - 1);
    let ticks = days * TICKS_PER_DAY
        + (hour % 24 * 3600 + minute * 60 + second) * TICKS_PER_SECOND
        + fraction;
    Some((ticks, hour == 24, zone))
}

fn in_range(n: &NaiveDateTime) -> bool {
    (1..=9999).contains(&n.year())
}

fn ws(c: u16) -> bool {
    // char.IsWhiteSpace: the same set as Rust's, on the BMP
    char::from_u32(c.into()).is_some_and(char::is_whitespace)
}

fn digit(c: u16) -> Option<u32> {
    // .NET's DateTimeParse.IsDigit: ASCII only
    (u16::from(b'0')..=u16::from(b'9'))
        .contains(&c)
        .then(|| u32::from(c - u16::from(b'0')))
}

fn is(u: &[u16], i: usize, c: u8) -> bool {
    u.get(i) == Some(&u16::from(c))
}

fn digit_at(u: &[u16], i: usize) -> bool {
    u.get(i).is_some_and(|&c| digit(c).is_some())
}

/// The index of the first code unit from `i` on that is not `skip`.
fn skip(u: &[u16], mut i: usize, skip: impl Fn(u16) -> bool) -> usize {
    while u.get(i).is_some_and(|&c| skip(c)) {
        i += 1;
    }
    i
}

/// The ASCII digits at `*i`, a run of a length in `len`, as a number.
fn number(u: &[u16], i: &mut usize, len: RangeInclusive<usize>) -> Option<u32> {
    let end = skip(u, *i, |c| digit(c).is_some());
    if !len.contains(&(end - *i)) {
        return None;
    }
    let v = u[*i..end]
        .iter()
        .fold(0, |v, &c| v * 10 + digit(c).unwrap_or(0));
    *i = end;
    Some(v)
}

/// An optional `-` and one ASCII digit or more, within a long, as
/// long.TryParse reads it; Newtonsoft's ConvertUtils.Int64TryParse also
/// refuses more than 19 digits, leading zeros or not (`max_digits`).
fn net_int(s: &[u16], max_digits: usize) -> Option<i64> {
    let d = match s.split_first() {
        Some((&c, rest)) if c == u16::from(b'-') => rest,
        _ => s,
    };
    if d.is_empty() || d.len() > max_digits {
        return None;
    }
    let mut v: i128 = 0;
    for &c in d {
        v = v * 10 + i128::from(digit(c)?);
        if v > 1 << 63 {
            return None;
        }
    }
    i64::try_from(if d.len() < s.len() { -v } else { v }).ok()
}

/// A time of day as `[datetime]::Parse` read it, and the zone it named, in
/// minutes east of UTC (`Z` is 0).
struct Time {
    hour: u32,
    minute: u32,
    second: u32,
    fraction: f64,
    offset: Option<i32>,
}

/// `[datetime]::Parse($s, InvariantCulture, RoundtripKind).ToLocalTime()`,
/// in .NET (pwsh 7) or .NET Framework (5.1), as an instant; None where it
/// throws.
fn net_parse(u: &[u16], fl: Flavour) -> Option<Instant> {
    let (date, p) = net_date(u)?;
    let k = skip(u, p, ws);
    let t = if is(u, k, b'T') || is(u, k, b't') {
        net_iso(u, k, fl)?
    } else {
        net_general(u, p, fl)?
    };
    // ParseFraction's double, rounded to the tick as Math.Round does
    let ticks = (t.fraction * TICKS_PER_SECOND as f64).round_ties_even() as i64;
    let wall = date.and_hms_opt(t.hour, t.minute, t.second)? + Duration::nanoseconds(ticks * 100);
    let utc = wall - Duration::minutes(t.offset.unwrap_or(0).into());
    (in_range(&wall) && in_range(&utc)).then(|| utc.and_utc())
}

/// The date Parse reads first, after white space: a year of 3 to 8 digits
/// (any number of 3 or more is a year to its lexer), then month and day of
/// 1 or 2, split by `-`. The date and the index after the day.
fn net_date(u: &[u16]) -> Option<(NaiveDate, usize)> {
    let mut i = skip(u, 0, ws);
    let year = number(u, &mut i, 3..=8)?;
    is(u, i, b'-').then_some(())?;
    i += 1;
    let month = number(u, &mut i, 1..=2)?;
    is(u, i, b'-').then_some(())?;
    i += 1;
    let day = number(u, &mut i, 1..=2)?;
    let date = NaiveDate::from_ymd_opt(i32::try_from(year).ok()?, month, day)?;
    (1..=9999).contains(&date.year()).then_some((date, i))
}

/// .NET's ParseTimeZone, from the sign at `s`: hours of 1 or 2 digits, then
/// optionally `:` and minutes of 1 or 2; or 3 or 4 digits as hmm or hhmm.
/// Minutes must be under 60, and on .NET (pwsh 7) the whole no more than
/// 14:00. Minutes east of UTC, and the index after the offset.
fn net_offset(u: &[u16], s: usize, fl: Flavour) -> Option<(i32, usize)> {
    let mut i = s + 1;
    let (h, m) = match skip(u, i, |c| digit(c).is_some()) - i {
        1 | 2 => {
            let h = number(u, &mut i, 1..=2)?;
            let m = if is(u, i, b':') {
                i += 1;
                number(u, &mut i, 1..=2)?
            } else {
                0
            };
            (h, m)
        }
        3 | 4 => {
            let v = number(u, &mut i, 3..=4)?;
            (v / 100, v % 100)
        }
        _ => return None,
    };
    let o = (h * 60 + m) as i32;
    if m > 59 || (fl == Flavour::Core && o > 14 * 60) {
        return None;
    }
    Some((if is(u, s, b'-') { -o } else { o }, i))
}

/// .NET's string as ParseISO8601 walks it: `at` is the last code unit read,
/// and each step looks at the one after.
struct Walk<'a> {
    u: &'a [u16],
    at: usize,
}

impl Walk<'_> {
    fn peek(&self) -> Option<u16> {
        self.u.get(self.at + 1).copied()
    }

    fn skip_ws(&mut self) {
        while self.peek().is_some_and(ws) {
            self.at += 1;
        }
    }

    fn eat(&mut self, c: u8) -> bool {
        let hit = self.peek() == Some(u16::from(c));
        if hit {
            self.at += 1;
        }
        hit
    }

    /// ParseDigits(2): the next two code units, both digits.
    fn two(&mut self) -> Option<u32> {
        let a = digit(*self.u.get(self.at + 1)?)?;
        let b = digit(*self.u.get(self.at + 2)?)?;
        self.at += 2;
        Some(a * 10 + b)
    }

    /// ParseFraction after the point: one digit or more.
    fn fraction(&mut self) -> Option<f64> {
        let mut i = self.at + 1;
        let f = net_fraction(self.u, &mut i);
        if i == self.at + 1 {
            return None;
        }
        self.at = i - 1;
        Some(f)
    }

    fn rest(&self) -> &[u16] {
        self.u.get(self.at + 1..).unwrap_or(&[])
    }
}

/// .NET's ParseISO8601, after the `T` at `t`.
fn net_iso(u: &[u16], t: usize, fl: Flavour) -> Option<Time> {
    let mut w = Walk { u, at: t };
    w.skip_ws();
    let hour = w.two()?;
    w.skip_ws();
    if !w.eat(b':') {
        return None;
    }
    w.skip_ws();
    let minute = w.two()?;
    w.skip_ws();
    let mut time = Time {
        hour,
        minute,
        second: 0,
        fraction: 0.0,
        offset: None,
    };
    if w.eat(b':') {
        w.skip_ws();
        time.second = w.two()?;
        if w.eat(b'.') || (fl == Flavour::Core && w.eat(b',')) {
            time.fraction = w.fraction()?;
        }
        w.skip_ws();
    }
    if let Some(c) = w.peek() {
        if c == u16::from(b'+') || c == u16::from(b'-') {
            let (o, q) = net_offset(u, w.at + 1, fl)?;
            time.offset = Some(o);
            // .NET Framework counts the code unit after the offset as read
            w.at = match fl {
                Flavour::Desktop => q,
                Flavour::Core => q - 1,
            };
        } else if c == u16::from(b'Z') || c == u16::from(b'z') {
            time.offset = Some(0);
            w.at += 1;
        }
        w.skip_ws();
        // then only NULs (a `#` here never pairs with one before the date)
        if w.rest().iter().any(|&c| c != 0) {
            return None;
        }
    }
    (hour < 24 && minute < 60 && time.second < 60).then_some(time)
}

/// .NET's ParseFraction: the digits at `*i` summed as a double the way it
/// sums them, each times a power of 0.1 kept by repeated multiplying, so a
/// fraction rounds to the tick where .NET's does.
fn net_fraction(u: &[u16], i: &mut usize) -> f64 {
    let (mut f, mut base) = (0.0, 0.1);
    while let Some(d) = u.get(*i).and_then(|&c| digit(c)) {
        f += f64::from(d) * base;
        base *= 0.1;
        *i += 1;
    }
    f
}

/// What Parse's general lexer reads after the date at `p`, as far as the
/// vectors pin it: a time `H:m[:s[.f]]` after white space, `.` or `,` (white
/// space around the colons; on .NET `,f` too), or none; then `Z`, an offset
/// or nothing, with white space and any `.` or `,` that no digit follows
/// ignored around it.
fn net_general(u: &[u16], p: usize, fl: Flavour) -> Option<Time> {
    let mut t = Time {
        hour: 0,
        minute: 0,
        second: 0,
        fraction: 0.0,
        offset: None,
    };
    let mut i = p;
    let gap = skip(u, p, |c| {
        ws(c) || c == u16::from(b'.') || c == u16::from(b',')
    });
    if gap > p && digit_at(u, gap) {
        i = gap;
        t.hour = number(u, &mut i, 1..=2)?;
        i = skip(u, i, ws);
        is(u, i, b':').then_some(())?;
        i = skip(u, i + 1, ws);
        t.minute = number(u, &mut i, 1..=2)?;
        let j = skip(u, i, ws);
        if is(u, j, b':') {
            i = skip(u, j + 1, ws);
            t.second = number(u, &mut i, 1..=2)?;
            if digit_at(u, i + 1) && (is(u, i, b'.') || is(u, i, b',')) {
                if is(u, i, b',') && fl == Flavour::Desktop {
                    return None;
                }
                i += 1;
                t.fraction = net_fraction(u, &mut i);
            }
        }
    }
    let ignored = |i: usize| {
        let mut i = i;
        while u.get(i).is_some_and(|&c| {
            ws(c) || ((c == u16::from(b'.') || c == u16::from(b',')) && !digit_at(u, i + 1))
        }) {
            i += 1;
        }
        i
    };
    i = ignored(i);
    if let Some(&c) = u.get(i) {
        if c == u16::from(b'Z') || c == u16::from(b'z') {
            t.offset = Some(0);
            i = ignored(i + 1);
        } else if c == u16::from(b'+') || c == u16::from(b'-') {
            let (o, q) = net_offset(u, i, fl)?;
            t.offset = Some(o);
            i = ignored(q);
        } else {
            return None;
        }
    }
    (i == u.len() && t.hour < 24 && t.minute < 60 && t.second < 60).then_some(t)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utc(s: &str) -> Instant {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    fn hours(h: f64) -> FixedOffset {
        FixedOffset::east_opt((h * 3600.0) as i32).unwrap()
    }

    fn wall(s: &str) -> NaiveDateTime {
        NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S%.f").unwrap()
    }

    #[test]
    fn utc_stamp_has_seven_digits() {
        let t = utc("2026-10-15T01:02:03.1234567Z");
        assert_eq!(stamp_utc(t), "2026-10-15T01:02:03.1234567Z");
        assert_eq!(
            stamp_utc(utc("2026-10-15T01:02:03Z")),
            "2026-10-15T01:02:03.0000000Z"
        );
        assert_eq!(
            stamp_utc(utc("2026-01-05T01:02:03.0000400Z")),
            "2026-01-05T01:02:03.0000400Z"
        );
    }

    #[test]
    fn offset_forms() {
        let n = NaiveDate::from_ymd_opt(2026, 3, 8)
            .unwrap()
            .and_hms_nano_opt(3, 0, 0, 500)
            .unwrap();
        assert_eq!(
            format_with_offset(n, 9 * 3600),
            "2026-03-08T03:00:00.0000005+09:00"
        );
        assert_eq!(
            format_with_offset(n, -7 * 3600),
            "2026-03-08T03:00:00.0000005-07:00"
        );
        assert_eq!(
            format_with_offset(n, 0),
            "2026-03-08T03:00:00.0000005+00:00"
        );
        assert_eq!(
            format_with_offset(n, 5 * 3600 + 1800),
            "2026-03-08T03:00:00.0000005+05:30"
        );
    }

    #[test]
    fn offset_form_at_a_dst_change() {
        let pacific = Zone::Change {
            at: utc("2026-03-08T10:00:00Z"),
            before: hours(-8.0),
            after: hours(-7.0),
        };
        assert_eq!(
            stamp_in(utc("2026-03-08T09:59:59.9999999Z"), pacific),
            "2026-03-08T01:59:59.9999999-08:00"
        );
        assert_eq!(
            stamp_in(utc("2026-03-08T10:00:00Z"), pacific),
            "2026-03-08T03:00:00.0000000-07:00"
        );
    }

    #[test]
    fn local_stamp_round_trips() {
        let t = utc("2026-10-15T01:02:03.1234567Z");
        assert_eq!(parse_stamp(&stamp_local(t), Flavour::Desktop), Some(t));
    }

    #[test]
    fn reads_every_shape() {
        let want = utc("2026-10-15T01:02:03.1234567Z");
        assert_eq!(
            parse_stamp("2026-10-15T01:02:03.1234567Z", Flavour::Desktop),
            Some(want)
        );
        assert_eq!(
            parse_stamp("2026-10-15T10:02:03.1234567+09:00", Flavour::Core),
            Some(want)
        );
        assert_eq!(
            parse_stamp("2026-10-15T01:02:03.5Z", Flavour::Desktop),
            Some(utc("2026-10-15T01:02:03.5Z"))
        );
        assert_eq!(
            parse_stamp("2026-10-15T01:02:03Z", Flavour::Desktop),
            Some(utc("2026-10-15T01:02:03Z"))
        );
        assert_eq!(
            parse_stamp("/Date(1760490123000)/", Flavour::Desktop),
            Some(utc("2025-10-15T01:02:03Z"))
        );
        assert_eq!(parse_stamp("", Flavour::Desktop), None);
        assert_eq!(parse_stamp("tomorrow", Flavour::Desktop), None);
        // past seven digits, Parse rounds to the tick
        for fl in [Flavour::Desktop, Flavour::Core] {
            assert_eq!(
                parse_stamp("2026-10-15T01:02:03.12345678Z", fl),
                Some(utc("2026-10-15T01:02:03.1234568Z"))
            );
        }
    }

    #[test]
    fn zoneless_follows_the_flavour() {
        let s = "2026-10-15T01:02:03";
        let kst = Zone::Fixed(hours(9.0));
        assert_eq!(
            parse_stamp_in(s, Flavour::Desktop, kst),
            Some(utc("2026-10-15T01:02:03Z"))
        );
        assert_eq!(
            parse_stamp_in(s, Flavour::Core, kst),
            Some(utc("2026-10-14T16:02:03Z"))
        );
        // a shape Newtonsoft leaves a string is Parse's, and UTC on 7 too
        assert_eq!(
            parse_stamp_in("2026-10-15 01:02:03", Flavour::Core, kst),
            Some(utc("2026-10-15T01:02:03Z"))
        );
    }

    #[test]
    fn a_skipped_or_repeated_time_is_at_the_standard_offset() {
        assert_eq!(resolve_offset(hours(-8.0), hours(-7.0)), hours(-8.0));
        assert_eq!(resolve_offset(hours(-7.0), hours(-8.0)), hours(-8.0));
        assert_eq!(resolve_offset(hours(11.0), hours(10.5)), hours(10.5));
        let spring = Zone::Change {
            at: utc("2026-03-08T10:00:00Z"),
            before: hours(-8.0),
            after: hours(-7.0),
        };
        let fall = Zone::Change {
            at: utc("2026-11-01T09:00:00Z"),
            before: hours(-7.0),
            after: hours(-8.0),
        };
        for (z, w, want) in [
            (
                spring,
                "2026-03-08T01:59:59.9999999",
                "2026-03-08T09:59:59.9999999Z",
            ),
            (spring, "2026-03-08T02:00:00", "2026-03-08T10:00:00Z"),
            (
                spring,
                "2026-03-08T02:59:59.9999999",
                "2026-03-08T10:59:59.9999999Z",
            ),
            (spring, "2026-03-08T03:00:00", "2026-03-08T10:00:00Z"),
            (
                fall,
                "2026-11-01T00:59:59.9999999",
                "2026-11-01T07:59:59.9999999Z",
            ),
            (fall, "2026-11-01T01:00:00", "2026-11-01T09:00:00Z"),
            (
                fall,
                "2026-11-01T01:59:59.9999999",
                "2026-11-01T09:59:59.9999999Z",
            ),
            (fall, "2026-11-01T02:00:00", "2026-11-01T10:00:00Z"),
        ] {
            assert_eq!(z.instant_of(&wall(w)), utc(want), "{w}");
        }
    }

    #[test]
    fn framework_skips_what_follows_an_iso_offset() {
        let s = "2026-10-15T01:02:03+09:00X";
        assert_eq!(
            parse_stamp(s, Flavour::Desktop),
            Some(utc("2026-10-14T16:02:03Z"))
        );
        assert_eq!(parse_stamp(s, Flavour::Core), None);
        for fl in [Flavour::Desktop, Flavour::Core] {
            assert_eq!(parse_stamp("2026-10-15T01:02:03+09:00 X", fl), None);
            assert_eq!(parse_stamp("2026-10-15 01:02:03+09:00X", fl), None);
        }
    }

    #[test]
    fn dotnet_offsets_stop_at_14_hours() {
        let s = "2026-10-15 01:02:03+14:01";
        assert_eq!(
            parse_stamp(s, Flavour::Desktop),
            Some(utc("2026-10-14T11:01:03Z"))
        );
        assert_eq!(parse_stamp(s, Flavour::Core), None);
        for fl in [Flavour::Desktop, Flavour::Core] {
            assert_eq!(
                parse_stamp("2026-10-15 01:02:03-14:00", fl),
                Some(utc("2026-10-15T15:02:03Z"))
            );
        }
        // Newtonsoft goes to 99:99 first
        assert_eq!(
            parse_stamp("2026-10-15T01:02:03+99:99", Flavour::Core),
            Some(utc("2026-10-10T20:23:03Z"))
        );
    }

    #[test]
    fn newtonsoft_reads_hour_24() {
        assert_eq!(
            parse_stamp("2026-10-15T24:00:00Z", Flavour::Core),
            Some(utc("2026-10-16T00:00:00Z"))
        );
        assert_eq!(parse_stamp("2026-10-15T24:00:00Z", Flavour::Desktop), None);
        assert_eq!(parse_stamp("9999-12-31T24:00:00Z", Flavour::Core), None);
    }

    #[test]
    fn ms_dates() {
        for fl in [Flavour::Desktop, Flavour::Core] {
            assert_eq!(
                parse_stamp("/Date(1760490123123-0130)/", fl),
                Some(utc("2025-10-15T01:02:03.123Z"))
            );
            // ms * 10000 wraps past a long
            assert_eq!(
                parse_stamp("/Date(1844674407370955)/", fl),
                Some(utc("1969-12-31T23:59:59.9998384Z"))
            );
            assert_eq!(parse_stamp("/Date(253402300800000)/", fl), None);
        }
        assert!(parse_stamp("/Date(1760490123123+09)/", Flavour::Core).is_some());
        assert_eq!(
            parse_stamp("/Date(1760490123123+09)/", Flavour::Desktop),
            None
        );
        assert!(parse_stamp("/Date(1760490123123Z)/", Flavour::Desktop).is_some());
        assert_eq!(parse_stamp("/Date(1760490123123Z)/", Flavour::Core), None);
    }

    #[test]
    fn only_strings_are_stamps() {
        for v in [serde_json::json!(5), serde_json::json!(true), Value::Null] {
            assert_eq!(date_of(Some(&v), Flavour::Desktop), None);
        }
        assert_eq!(date_of(None, Flavour::Core), None);
    }

    #[test]
    fn flavour_from_the_exe() {
        assert_eq!(
            Flavour::from_exe(r"C:\Program Files\PowerShell\7\pwsh.exe"),
            Flavour::Core
        );
        assert_eq!(Flavour::from_exe("/usr/local/bin/pwsh"), Flavour::Core);
        assert_eq!(
            Flavour::from_exe(r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"),
            Flavour::Desktop
        );
    }
}
