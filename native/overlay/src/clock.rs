// The words the panel and its tray put on a usage window's reset, ported
// from the PowerShell host's so a Rust panel says them as the WPF one does:
// Format-ChatOverlayReset, Format-ChatOverlayResetAt (with
// Format-ChatqClockTime, src/phone-extras.ps1), Get-ChatOverlayResetWindow
// and Format-ChatOverlayTooltip, all in src/overlay-data.ps1. Times are the
// snapshot's epoch ms; `wall` turns one into the wall-clock time of the zone
// the words are said in, as PowerShell's take Get-Date's local time
// (local_wall for the panel's own). Where PowerShell subtracts two local
// times, so do these: across a DST change the countdown is the clocks'
// difference, not the time between.
//
// native/vectors/overlay-clock.json pins them, each case at an instant in a
// named zone (tests/vectors/overlay-clock.ps1); the tests below read it,
// the zone's rules from Windows, the system's own zone left alone.
//
// The panel's usage line and cards say them (panel.rs, card.rs), and the
// tray's tooltip (app.rs, through tooltip).

use chatq_core::time::Zone;
use chrono::{DateTime, NaiveDateTime, Utc};
use serde_json::Value;

/// Epoch ms to the wall-clock time the words are said in.
pub type Wall<'a> = &'a dyn Fn(i64) -> NaiveDateTime;

/// The panel's own wall clock: this PC's zone, as Get-Date reads it.
pub fn local_wall(ms: i64) -> NaiveDateTime {
    Zone::Local.wall(DateTime::<Utc>::from_timestamp_millis(ms).unwrap_or_default())
}

/// PowerShell's truth of a value: what `if ($x)` takes.
pub(crate) fn truthy(v: Option<&Value>) -> bool {
    match v {
        None | Some(Value::Null) => false,
        Some(Value::Bool(b)) => *b,
        Some(Value::Number(n)) => n.as_f64().is_some_and(|f| f != 0.0),
        Some(Value::String(s)) => !s.is_empty(),
        Some(_) => true,
    }
}

/// `[int64]` of a JSON number; None for none or anything else.
pub(crate) fn ms_of(v: Option<&Value>) -> Option<i64> {
    let v = v?;
    v.as_i64().or_else(|| v.as_f64().map(|f| f.round() as i64))
}

/// `[int]` of a field: 0 for none.
pub(crate) fn int(v: &Value, k: &str) -> i64 {
    ms_of(v.get(k)).unwrap_or(0)
}

/// A field as PowerShell puts it in a string: a whole number without a
/// point, the rest as they read.
pub(crate) fn text(v: Option<&Value>) -> String {
    match v {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => match (n.as_i64(), n.as_f64()) {
            (Some(i), _) => i.to_string(),
            (None, Some(f)) => f.to_string(),
            _ => n.to_string(),
        },
        Some(Value::Bool(b)) => (if *b { "True" } else { "False" }).into(),
        Some(other) => other.to_string(),
    }
}

/// Format-ChatqClockTime: 13:00 on the same date, Tue 13:00 any other.
pub(crate) fn clock_time(at: NaiveDateTime, now: NaiveDateTime) -> String {
    let fmt = if at.date() == now.date() {
        "%H:%M"
    } else {
        "%a %H:%M"
    };
    at.format(fmt).to_string()
}

/// Format-ChatOverlayReset: when a usage window resets - a countdown inside
/// a day, the weekday and time after, 'reset' once it is past; '' for none.
/// Held to the vectors only: no line the panel draws says it today.
#[cfg_attr(not(test), allow(dead_code))]
pub fn reset(resets_at: Option<i64>, now_ms: i64, wall: Wall) -> String {
    let Some(at) = resets_at.filter(|&a| a != 0) else {
        return String::new();
    };
    let (at, now) = (wall(at), wall(now_ms));
    let s = (at - now).num_milliseconds() as f64 / 1000.0;
    if s <= 0.0 {
        return "reset".into();
    }
    if s >= 86400.0 {
        return at.format("%a %H:%M").to_string();
    }
    let m = (s / 60.0).floor() as i64;
    if m >= 60 {
        return format!("{}h {}m", m / 60, m % 60);
    }
    if m >= 1 {
        return format!("{m}m");
    }
    format!("{}s", s.ceil() as i64)
}

/// Format-ChatOverlayResetAt: a reset still ahead as a clock time, with the
/// day when it is not today; '' for none, or one past.
pub fn reset_at(resets_at: Option<i64>, now_ms: i64, wall: Wall) -> String {
    let Some(at) = resets_at.filter(|&a| a != 0) else {
        return String::new();
    };
    let (at, now) = (wall(at), wall(now_ms));
    if at <= now {
        return String::new();
    }
    clock_time(at, now)
}

/// Format-ChatOverlayAskAt: when the reset ask's limit was over, as a clock
/// time with the day when it is not today; '' for none. No check that it
/// has passed: the ask is about a reset that has.
pub fn ask_at(at: Option<i64>, now_ms: i64, wall: Wall) -> String {
    let Some(at) = at.filter(|&a| a != 0) else {
        return String::new();
    };
    clock_time(wall(at), wall(now_ms))
}

/// Get-ChatOverlayResetWindow: the label of the one usage window whose
/// reset a usage line shows - of those at their limit with a reset ahead,
/// the latest; else 5h while its reset is ahead; else none. By the
/// instant, not the wall clock.
pub fn reset_window(windows: &[Value], now_ms: i64) -> Option<String> {
    let ahead = |w: &Value| ms_of(w.get("resetsAt")).filter(|&r| r != 0 && r > now_ms);
    let mut best: Option<(&Value, i64)> = None;
    for w in windows.iter().filter(|w| truthy(Some(w))) {
        let Some(r) = ahead(w) else { continue };
        if !truthy(w.get("limited")) {
            continue;
        }
        if r > best.map_or(0, |(_, at)| at) {
            best = Some((w, r));
        }
    }
    if let Some((w, _)) = best {
        return Some(text(w.get("label")));
    }
    windows
        .iter()
        .filter(|w| truthy(Some(w)))
        .find(|w| text(w.get("label")).eq_ignore_ascii_case("5h") && ahead(w).is_some())
        .map(|_| "5h".to_string())
}

/// Format-ChatOverlayTooltip: the tray icon's tooltip, cut to the 127
/// UTF-16 units Windows keeps.
pub fn tooltip(snap: &Value, now_ms: i64, wall: Wall) -> String {
    let none = Value::Null;
    let c = snap.get("counts").unwrap_or(&none);
    let header = snap.get("header").unwrap_or(&none);
    let mut bits: Vec<String> = Vec::new();
    let need = int(c, "waiting") + int(c, "needsInput");
    if need != 0 {
        bits.push(format!("{need} need you"));
    }
    let rl = match header.get("reload") {
        Some(Value::Array(a)) => a.iter().filter(|r| truthy(Some(r))).count(),
        other => usize::from(truthy(other)),
    };
    if rl != 0 {
        bits.push(format!(
            "{rl} reload{} asked",
            if rl != 1 { "s" } else { "" }
        ));
    }
    if c.get("unread").is_some() && int(c, "unread") != 0 {
        bits.push(format!("{} new", text(c.get("unread"))));
    }
    let can_go = header
        .get("ask")
        .filter(|a| truthy(Some(a)))
        .map_or(0, |a| int(a, "count"));
    if can_go != 0 {
        bits.push(format!("{can_go} can continue"));
    }
    let cut = if c.get("cutOff").is_some() {
        (int(c, "cutOff") - can_go).max(0)
    } else {
        0
    };
    if cut != 0 {
        bits.push(format!("{cut} cut off"));
    }
    for (k, says) in [
        ("busy", "working"),
        ("running", "running"),
        ("idle", "idle"),
        ("queued", "queued"),
    ] {
        if truthy(c.get(k)) {
            bits.push(format!("{} {says}", text(c.get(k))));
        }
    }
    if bits.is_empty() {
        bits.push("no chats open".into());
    }
    let mut t = format!("Charlie: {}", bits.join(", "));
    let usage = header
        .get("usage")
        .and_then(Value::as_array)
        .and_then(|us| {
            us.iter()
                .find(|u| truthy(Some(u)) && text(u.get("provider")).eq_ignore_ascii_case("Claude"))
        });
    let windows: &[Value] = usage
        .and_then(|u| u.get("windows"))
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice);
    if let Some(w) = windows
        .iter()
        .find(|w| text(w.get("label")).eq_ignore_ascii_case("5h"))
    {
        t += &format!(" - 5h {}%", text(w.get("percent")));
        if reset_window(windows, now_ms).as_deref() == Some("5h") {
            let at = reset_at(ms_of(w.get("resetsAt")), now_ms, wall);
            if !at.is_empty() {
                t += &format!(", resets {at}");
            }
        }
    }
    let units: Vec<u16> = t.encode_utf16().collect();
    if units.len() > 127 {
        t = String::from_utf16_lossy(&units[..126]) + "\u{2026}";
    }
    t
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::NaiveDate;
    use windows::Win32::Foundation::SYSTEMTIME;
    use windows::Win32::System::Time::{
        DYNAMIC_TIME_ZONE_INFORMATION, EnumDynamicTimeZoneInformation,
        SystemTimeToTzSpecificLocalTimeEx,
    };

    /// A zone's rules by its Windows name (TimeZoneKeyName), as .NET's
    /// FindSystemTimeZoneById reads them.
    fn zone(name: &str) -> DYNAMIC_TIME_ZONE_INFORMATION {
        for n in 0.. {
            let mut z = DYNAMIC_TIME_ZONE_INFORMATION::default();
            if unsafe { EnumDynamicTimeZoneInformation(n, &mut z) } != 0 {
                break;
            }
            let key = &z.TimeZoneKeyName;
            let len = key.iter().position(|&u| u == 0).unwrap_or(key.len());
            if String::from_utf16_lossy(&key[..len]) == name {
                return z;
            }
        }
        panic!("no zone {name} on this PC");
    }

    /// Epoch ms to that zone's wall clock, through Windows' own rules.
    fn wall_in(z: &DYNAMIC_TIME_ZONE_INFORMATION, ms: i64) -> NaiveDateTime {
        use chrono::{Datelike, Timelike};
        let t = DateTime::<Utc>::from_timestamp_millis(ms)
            .unwrap()
            .naive_utc();
        let utc = SYSTEMTIME {
            wYear: t.year() as u16,
            wMonth: t.month() as u16,
            wDayOfWeek: 0,
            wDay: t.day() as u16,
            wHour: t.hour() as u16,
            wMinute: t.minute() as u16,
            wSecond: t.second() as u16,
            wMilliseconds: (t.nanosecond() / 1_000_000) as u16,
        };
        let mut local = SYSTEMTIME::default();
        unsafe { SystemTimeToTzSpecificLocalTimeEx(Some(z as *const _), &utc, &mut local) }
            .unwrap();
        NaiveDate::from_ymd_opt(local.wYear.into(), local.wMonth.into(), local.wDay.into())
            .unwrap()
            .and_hms_milli_opt(
                local.wHour.into(),
                local.wMinute.into(),
                local.wSecond.into(),
                local.wMilliseconds.into(),
            )
            .unwrap()
    }

    fn vectors() -> Value {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../vectors/overlay-clock.json");
        let bytes = std::fs::read(path).expect("native/vectors/overlay-clock.json");
        let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes);
        serde_json::from_slice(bytes).unwrap()
    }

    /// Every case says what the PowerShell host said: both editions agree,
    /// so an expectByEdition, were there one, must agree too.
    #[test]
    fn every_clock_case_says_what_powershell_said() {
        let file = vectors();
        let cases = file["cases"].as_array().unwrap();
        assert!(cases.len() >= 30, "cases: {}", cases.len());
        for c in cases {
            let name = c["name"].as_str().unwrap();
            let input = &c["input"];
            let z = zone(input["zone"].as_str().unwrap());
            let wall = |ms: i64| wall_in(&z, ms);
            let now = DateTime::parse_from_rfc3339(input["now"].as_str().unwrap())
                .unwrap()
                .timestamp_millis();
            let got = match input["kind"].as_str().unwrap() {
                "reset" => Value::from(reset(ms_of(input.get("resetsAt")), now, &wall)),
                "resetAt" => Value::from(reset_at(ms_of(input.get("resetsAt")), now, &wall)),
                "window" => reset_window(input["windows"].as_array().unwrap(), now)
                    .map_or(Value::Null, Value::from),
                "tooltip" => Value::from(tooltip(&input["snap"], now, &wall)),
                other => panic!("{name}: a case of kind {other}"),
            };
            let wants: Vec<&Value> = match c.get("expect") {
                Some(w) => vec![w],
                None => c["expectByEdition"].as_object().unwrap().values().collect(),
            };
            for want in wants {
                assert_eq!(&got, want, "{name}");
            }
        }
    }

    /// The panel's own clock is this PC's: the same instant, read by chrono
    /// as Get-Date reads it.
    #[test]
    fn the_local_wall_is_chronos_local() {
        let ms = 1_792_033_200_000;
        let want = DateTime::<Utc>::from_timestamp_millis(ms)
            .unwrap()
            .with_timezone(&chrono::Local)
            .naive_local();
        assert_eq!(local_wall(ms), want);
    }
}
