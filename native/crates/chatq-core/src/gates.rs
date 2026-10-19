//! The cheap per-pass tests the PS loop asks before it acts. In M0 each one
//! that comes out true means the PS first pass would do something chatqd
//! cannot yet do, so chatqd hands over instead (SPEC 7 M0). Vectors:
//! native/vectors/gates.json and due.json.

use crate::culture::Culture;
use crate::json::{self, ieq};
use crate::paths::Paths;
use crate::time::{Flavour, Instant, Zone, parse_stamp_in};
use base64::Engine as _;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use chrono::TimeDelta;
use serde_json::Value;
use std::fs;
use std::path::Path;
use std::time::{Duration, SystemTime};

/// `$script:ChatqStrayHours`: how old a file no prompt links to must be
/// before [Clear-ChatqStrayFiles](src/queue.ps1) takes it.
pub const STRAY_HOURS: u64 = 24;

/// [Update-ChatqBlock](src/watcher.ps1): a waiting lane's limits are read
/// again at most this often (`TotalMinutes -lt 10` skips), unless forced.
pub const RESCAN_MINUTES: i64 = 10;

/// [Get-ChatqDueTime](src/watcher.ps1): a lane is free a minute after its
/// limit resets (`$b.Until.AddSeconds(60)`).
pub const AFTER_RESET_SECONDS: i64 = 60;

/// [Get-ChatqLane](src/watcher.ps1): what a limit or an overload applies to,
/// the provider, and `provider|home` when the job names its own config dir.
/// PS keeps lanes as hashtable keys, so compare them with [ieq].
pub fn lane(job: &Value) -> String {
    let provider = json::to_ps_string(json::get(Some(job), "provider"));
    let home = json::get(Some(job), "home");
    if json::truthy(home) {
        format!("{provider}|{}", json::to_ps_string(home))
    } else {
        provider
    }
}

/// [ConvertTo-ChatqDate](src/queue.ps1) on a job's field, a zoneless stamp
/// read in `zone` as pwsh 7 reads it.
fn date_in(v: Option<&Value>, fl: Flavour, zone: Zone) -> Option<Instant> {
    parse_stamp_in(v?.as_str()?, fl, zone)
}

/// A value as PowerShell passes it on out of a function, a scriptblock or an
/// `if`: a list is unrolled, so a list of one is its element and an empty
/// list is $null. [Read-ChatqJson](src/queue.ps1) does it to a whole file.
fn unroll(v: Option<&Value>) -> Option<&Value> {
    match v {
        Some(Value::Array(a)) if a.len() <= 1 => a.first(),
        v => v,
    }
}

/// [Get-ChatqDueTime](src/watcher.ps1): when the watcher may next pick
/// `job`, None for now. The latest still ahead of `now` of: its lane's limit
/// plus [AFTER_RESET_SECONDS] (`blocked_until`, `$W.blocked[lane].Until`),
/// its lane's next overload check (`outage_next`, `$W.outage[lane].NextCheck`),
/// and the job's notBefore, deferUntil and retryAt.
pub fn due_time(
    blocked_until: Option<Instant>,
    outage_next: Option<Instant>,
    job: &Value,
    now: Instant,
    fl: Flavour,
    zone: Zone,
) -> Option<Instant> {
    let mut times = Vec::new();
    if let Some(u) = blocked_until.filter(|u| *u > now) {
        times.push(u + TimeDelta::seconds(AFTER_RESET_SECONDS));
    }
    times.extend(outage_next.filter(|n| *n > now));
    for k in ["notBefore", "deferUntil", "retryAt"] {
        times.extend(date_in(json::get(Some(job), k), fl, zone).filter(|t| *t > now));
    }
    times.into_iter().max()
}

/// [Update-ChatqBlock](src/watcher.ps1)'s skip rule: does a lane last
/// scanned at `scanned_at` get its limits read again? When forced, never
/// scanned, or scanned [RESCAN_MINUTES] or more ago; a scan stamped ahead of
/// the clock waits. A scan sets the lane's `scannedAt` to `now`.
pub fn rescan_due(scanned_at: Option<Instant>, now: Instant, force: bool) -> bool {
    force || scanned_at.is_none_or(|at| now - at >= TimeDelta::minutes(RESCAN_MINUTES))
}

/// [Test-ChatqReplyOpen](src/phone.ps1): replies on with a topic, a phone
/// paired or a pairing not yet expired, and an alert window open or the
/// standing listen. Never throws; a read that fails is a closed window.
pub fn reply_open(cfg: &Value, replies: &Path, now: Instant, fl: Flavour) -> bool {
    reply_open_in(cfg, replies, now, fl, Zone::Local)
}

/// [reply_open] with a zoneless stamp read in `zone` (pwsh 7). Unlike
/// [reply_links], it opens no secret: a topic or a key that is there counts.
pub fn reply_open_in(cfg: &Value, replies: &Path, now: Instant, fl: Flavour, zone: Zone) -> bool {
    let rp = unroll(json::get(Some(cfg), "reply"));
    if !(json::truthy(rp)
        && json::eq_true(json::get(rp, "on"))
        && json::truthy(json::get(rp, "topic")))
    {
        return false;
    }
    let key = json::truthy(json::get(rp, "key"));
    if !key {
        let x = date_in(json::get(json::get(rp, "pairing"), "expires"), fl, zone);
        if !x.is_some_and(|x| x > now) {
            return false;
        }
    }
    let st = crate::fsx::read_json(replies, fl);
    let st = unroll(st.as_ref());
    if key
        && ieq(&json::to_ps_string(json::get(rp, "listen")), "always")
        && json::truthy(st)
        && json::eq_true(json::get(st, "standing"))
    {
        return true;
    }
    date_in(json::get(st, "openUntil"), fl, zone).is_some_and(|u| u > now)
}

/// [Test-ChatqHeldWaiting](src/phone-extras.ps1): held.jsonl is there, or a
/// `held-*.sending` claimed more than 10 minutes ago
/// ([Get-ChatqStaleSending](src/phone-extras.ps1)).
pub fn held_waiting(p: &Paths, now: SystemTime) -> bool {
    if p.held().exists() {
        return true;
    }
    let Ok(rd) = fs::read_dir(&p.data) else {
        return false;
    };
    rd.flatten().any(|e| {
        let n = e.file_name().to_string_lossy().to_lowercase();
        n.starts_with("held-")
            && n.ends_with(".sending")
            && e.metadata().is_ok_and(|m| {
                m.is_file()
                    && m.modified().is_ok_and(|t| {
                        now.duration_since(t)
                            .is_ok_and(|d| d > Duration::from_secs(600))
                    })
            })
    })
}

/// [Get-ChatqAutoContinue](src/queue.ps1): only the word "on" is on.
fn auto_continue_on(cfg: &Value) -> bool {
    match json::get(Some(cfg), "autoContinue") {
        Some(Value::Bool(_)) => false,
        v => json::to_ps_string(v).trim().to_lowercase() == "on",
    }
}

/// [Test-ChatqAutoWanted](src/auto-continue.ps1): the switch on, or one chat
/// in data/auto-continue.json set to always.
pub fn auto_wanted(cfg: &Value, auto_state: Option<&Value>) -> bool {
    if auto_continue_on(cfg) {
        return true;
    }
    let chats = unroll(json::get(unroll(auto_state), "chats"));
    let Some(chats) = chats.and_then(Value::as_object) else {
        return false;
    };
    chats
        .values()
        .any(|c| ieq(&json::to_ps_string(json::get(Some(c), "auto")), "always"))
}

/// [ConvertFrom-ChatqB64Url](src/phone.ps1)'s decode: padding optional, and
/// .NET lets the bits a last character leaves over be anything.
const B64URL: GeneralPurpose = GeneralPurpose::new(
    &base64::alphabet::URL_SAFE,
    GeneralPurposeConfig::new()
        .with_decode_padding_mode(DecodePaddingMode::Indifferent)
        .with_decode_allow_trailing_bits(true),
);

/// [ConvertFrom-ChatqB64Url](src/phone.ps1): None where it gives $null. Its
/// `-cnotmatch '^[A-Za-z0-9_-]*$'` lets a final newline by, as .NET's `$`
/// does, but no such text then decodes, so the check here is exact.
fn b64url(s: &str) -> Option<Vec<u8>> {
    if !s
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
        || s.len() % 4 == 1
    {
        return None;
    }
    B64URL.decode(s).ok()
}

/// [Get-ChatqReplyConfig](src/phone.ps1)'s Links: alerts carry a reply link.
/// Replies switched on (`on -eq $true`), a topic that opens, and a phone's
/// key that opens and reads back as 32 bytes; a pairing still waiting is not
/// enough. `unprotect` is [Unprotect-ChatqSecret](src/alerts.ps1) on a
/// secret field's value: None where it gives $null.
pub fn reply_links(cfg: &Value, unprotect: &dyn Fn(&Value) -> Option<String>) -> bool {
    let rp = unroll(json::get(Some(cfg), "reply").filter(|v| json::truthy(Some(v))));
    let has = |n: &str| json::get(rp, n).filter(|v| !v.is_null());
    let opens = |n: &str| has(n).and_then(unprotect).filter(|s| !s.is_empty());
    has("on").is_some_and(|v| json::eq_true(Some(v)))
        && opens("topic").is_some()
        && opens("key")
            .and_then(|k| b64url(&k))
            .is_some_and(|m| m.len() == 32)
}

/// SPEC 1.4: does [Send-ChatqAlert](src/alerts.ps1) register this alert as
/// answerable (New-ChatqReplyAlert, then Update-ChatqReplyFull), once past
/// its earlier gates? Every alert not sent `-NoReply` while [reply_links].
/// The watcher sends no pairing push, so `-PairLink` is not here.
pub fn alert_answerable(
    cfg: &Value,
    no_reply: bool,
    unprotect: &dyn Fn(&Value) -> Option<String>,
) -> bool {
    !no_reply && reply_links(cfg, unprotect)
}

/// [Get-ChatqUsageAlertConfig](src/phone-extras.ps1): usage.soonMinutes when
/// unset or not a whole number from 0 to 120.
pub const SOON_DEFAULT_MINUTES: i64 = 10;

/// [Get-ChatqUsageAlertConfig](src/phone-extras.ps1): the largest
/// usage.soonMinutes taken.
pub const SOON_MAX_MINUTES: i64 = 120;

/// [Send-ChatqUsageSoon](src/phone-extras.ps1): a lane blocked for less than
/// this is the watcher's guess at a reset, not one a limit named.
pub const SOON_MIN_WAIT_MINUTES: i64 = 30;

/// [Test-ChatqUsageLimitBlock](src/phone-extras.ps1): block types that are
/// no usage limit (`-notin`, so case-blind).
const NOT_A_LIMIT: [&str; 3] = ["probe failed", "login needed", "overloaded"];

/// [Get-ChatqUsageAlertConfig](src/phone-extras.ps1)'s Reset and SoonMinutes,
/// as [Send-ChatqUsageSoon](src/phone-extras.ps1) reads them: how many
/// minutes before a reset the soon alert goes, None when it is off (reset
/// alerts switched off, or soonMinutes 0). A field changes its default only
/// as PowerShell takes it: reset only when it is a bool, soonMinutes only
/// when `[string]$v -match '^\d{1,3}$'` and no more than 120.
pub fn usage_soon_minutes(cfg: &Value) -> Option<i64> {
    let u = unroll(json::get(Some(cfg), "usage").filter(|v| json::truthy(Some(v))));
    let field = |n: &str| unroll(json::get(u, n));
    if matches!(field("reset"), Some(Value::Bool(false))) {
        return None;
    }
    let soon = field("soonMinutes")
        .filter(|v| !v.is_null())
        .and_then(|v| {
            let s = json::to_ps_string(Some(v));
            let digits = s.strip_suffix('\n').unwrap_or(&s);
            if !(1..=3).contains(&digits.len()) || !digits.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            digits
                .parse::<i64>()
                .ok()
                .filter(|n| *n <= SOON_MAX_MINUTES)
        })
        .unwrap_or(SOON_DEFAULT_MINUTES);
    (soon > 0).then_some(soon)
}

/// A lane in `$W.blocked` as [Send-ChatqUsageSoon](src/phone-extras.ps1)
/// reads it: the key, `Until`, `Type`, and `At`, when the lane was blocked.
#[derive(Clone, Copy, Debug)]
pub struct BlockedLane<'a> {
    pub lane: &'a str,
    pub until: Instant,
    pub kind: &'a str,
    pub at: Option<Instant>,
}

/// What [Send-ChatqUsageSoon](src/phone-extras.ps1) decides on a pass.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct UsageSoon {
    /// The soonest time a soon alert still waits for (its return value), so
    /// the loop wakes for it.
    pub next: Option<Instant>,
    /// The [soon_key] of each lane due its alert now, in `blocked`'s order.
    /// The process records each as sent (`$script:ChatqUsageSent`), and the
    /// alert goes only where data/usage-alerts.json does not have the key
    /// yet, which is added under its lock (Use-ChatqUsageAlertState).
    pub due: Vec<String>,
}

/// `"s|$lane|$(Get-ChatqEpochMinutes $b.Until)"`: one lane's one reset, in
/// `$script:ChatqUsageSent` and data/usage-alerts.json.
pub fn soon_key(lane: &str, until: Instant) -> String {
    format!("s|{lane}|{}", until.timestamp().div_euclid(60))
}

/// [Send-ChatqUsageSoon](src/phone-extras.ps1)'s gate. A lane counts when
/// its block is a usage limit, at least [SOON_MIN_WAIT_MINUTES] long when
/// it was set, its reset still ahead, and a job queued in it that its
/// notBefore does not hold past the reset; `sent` holds the keys this
/// process recorded already (compared case-blind, as hashtable keys are).
/// The alert is due once the reset is no more than the lead away.
pub fn usage_soon(
    cfg: &Value,
    blocked: &[BlockedLane],
    queued: &[Value],
    sent: &[String],
    now: Instant,
    fl: Flavour,
    zone: Zone,
) -> UsageSoon {
    let mut out = UsageSoon::default();
    let Some(soon) = usage_soon_minutes(cfg) else {
        return out;
    };
    let lead = TimeDelta::minutes(soon);
    for b in blocked {
        if NOT_A_LIMIT.iter().any(|k| ieq(b.kind, k))
            || !b
                .at
                .is_some_and(|at| b.until - at >= TimeDelta::minutes(SOON_MIN_WAIT_MINUTES))
            || b.until <= now
        {
            continue;
        }
        let waiting = queued.iter().any(|j| {
            ieq(&json::to_ps_string(json::get(Some(j), "state")), "queued")
                && ieq(&lane(j), b.lane)
                && !date_in(json::get(Some(j), "notBefore"), fl, zone)
                    .is_some_and(|nb| nb > b.until)
        });
        let key = soon_key(b.lane, b.until);
        if !waiting || sent.iter().any(|s| ieq(s, &key)) {
            continue;
        }
        if b.until - now > lead {
            let at = b.until - lead;
            if out.next.is_none_or(|n| at < n) {
                out.next = Some(at);
            }
        } else {
            out.due.push(key);
        }
    }
    out
}

/// [Get-ChatqReplyPollSeconds](src/phone-down.ps1): the loop's wait while
/// the phone asked for something in the last 2 minutes (hotUntil).
pub const POLL_HOT_SECONDS: u32 = 6;
/// [Get-ChatqReplyPollSeconds](src/phone-down.ps1): while an alert is out.
pub const POLL_OPEN_SECONDS: u32 = 15;
/// [Get-ChatqReplyPollSeconds](src/phone-down.ps1): only listening.
pub const POLL_IDLE_SECONDS: u32 = 20;
/// [Get-ChatqReplyPollSeconds](src/phone-down.ps1) `-InRun`: from inside a run.
pub const RUN_POLL_SECONDS: u32 = 30;
/// [Get-ChatqReplyPollSeconds](src/phone-down.ps1) `-InRun`, while hot.
pub const RUN_POLL_HOT_SECONDS: u32 = 10;

/// [Get-ChatqReplyPollSeconds](src/phone-down.ps1): how long between two
/// looks at the reply topic, from data/replies.json as read
/// ([crate::fsx::read_json]): hot, then an alert window, then listening.
pub fn reply_poll_seconds(
    replies: Option<&Value>,
    in_run: bool,
    now: Instant,
    fl: Flavour,
    zone: Zone,
) -> u32 {
    let st = unroll(replies);
    let ahead = |k: &str| date_in(json::get(st, k), fl, zone).is_some_and(|t| t > now);
    match (in_run, ahead("hotUntil")) {
        (true, true) => RUN_POLL_HOT_SECONDS,
        (true, false) => RUN_POLL_SECONDS,
        (false, true) => POLL_HOT_SECONDS,
        (false, false) if ahead("openUntil") => POLL_OPEN_SECONDS,
        _ => POLL_IDLE_SECONDS,
    }
}

/// [Get-ChatqReplyListenText](src/phone-down.ps1): the watcher's log line as
/// it starts to listen, "until HH:mm" in `zone` and the launcher's culture,
/// "all the time", or "until". From data/replies.json as read, of which it
/// looks at openUntil and standing only.
pub fn listen_text(
    replies: Option<&Value>,
    now: Instant,
    fl: Flavour,
    zone: Zone,
    culture: &Culture,
) -> String {
    let st = unroll(replies);
    if let Some(u) = date_in(json::get(st, "openUntil"), fl, zone).filter(|u| *u > now) {
        return format!("until {}", culture.hh_mm(&zone.wall(u)));
    }
    if json::eq_true(json::get(st, "standing")) {
        return "all the time".into();
    }
    "until".into()
}

/// `$i.Extension`: from the last dot of the name, "" when there is none or
/// it ends the name.
fn extension(name: &str) -> &str {
    match name.rfind('.') {
        Some(k) if k + 1 < name.len() => &name[k..],
        _ => "",
    }
}

/// By the newer of creation and write times, as the sweep ages a file.
fn older_than(m: &fs::Metadata, cut: SystemTime) -> bool {
    let w = m.modified().ok();
    let c = m.created().ok();
    match w.max(c) {
        Some(t) => t < cut,
        None => false,
    }
}

fn any_old_inside(dir: &Path, cut: SystemTime) -> bool {
    let Ok(rd) = fs::read_dir(dir) else {
        return false;
    };
    rd.flatten().any(|e| {
        e.metadata()
            .is_ok_and(|m| older_than(&m, cut) || (m.is_dir() && any_old_inside(&e.path(), cut)))
    })
}

/// Could [Clear-ChatqStrayFiles](src/queue.ps1) take anything? Looser than
/// the sweep: it ignores which files a prompt links to, so it errs towards
/// a handoff and never towards a file the PS sweep would have removed.
pub fn stray_maybe(queue: &Path, now: SystemTime) -> bool {
    let Some(cut) = now.checked_sub(Duration::from_secs(STRAY_HOURS * 3600)) else {
        return false;
    };
    let Ok(rd) = fs::read_dir(queue) else {
        return false;
    };
    rd.flatten().any(|e| {
        let Ok(m) = e.metadata() else { return false };
        let name = e.file_name().to_string_lossy().into_owned();
        if !m.is_dir() {
            let ext = extension(&name).to_lowercase();
            return ![".md", ".json", ".cancel", ".tmp"].contains(&ext.as_str())
                && older_than(&m, cut);
        }
        if job_id_shaped(&name) || queue.join(format!("{name}.json")).exists() {
            return false;
        }
        older_than(&m, cut) || any_old_inside(&e.path(), cut)
    })
}

/// `-match '^\d{8}-\d{6}-'`: a folder named as a job id is its job's.
fn job_id_shaped(name: &str) -> bool {
    let b = name.as_bytes();
    b.len() >= 16
        && b[..8].iter().all(u8::is_ascii_digit)
        && b[8] == b'-'
        && b[9..15].iter().all(u8::is_ascii_digit)
        && b[15] == b'-'
}

/// Would [Repair-ChatqInterrupted](src/watcher.ps1) do anything? A job left
/// `running`; data/permit there with a job's folder in it, or with
/// replies.json beside it, which [Remove-ChatqPermitLeftovers](src/permit.ps1)
/// then saves again, prune included; or a `data/ask/*.req.json`, the only
/// files [Remove-ChatqAskLeftovers](src/ask.ps1) looks at.
pub fn repair_due(jobs: &[Value], p: &Paths) -> bool {
    if jobs.iter().any(|j| crate::jobs::state_in(j, &["running"])) {
        return true;
    }
    let permit = p.permit_dir();
    if permit.exists() {
        if p.replies().exists() {
            return true;
        }
        let sub = fs::read_dir(&permit)
            .map(|rd| {
                rd.flatten()
                    .any(|e| e.file_type().is_ok_and(|t| t.is_dir()))
            })
            .unwrap_or(false);
        if sub {
            return true;
        }
    }
    fs::read_dir(p.ask_dir())
        .map(|rd| {
            rd.flatten().any(|e| {
                e.file_name()
                    .to_string_lossy()
                    .to_lowercase()
                    .ends_with(".req.json")
            })
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration as Cd, Utc};
    use serde_json::json;

    fn root(name: &str) -> Paths {
        let r = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../target/test-data/core-gates")
            .join(name);
        let _ = fs::remove_dir_all(&r);
        fs::create_dir_all(r.join("data")).unwrap();
        Paths::new(r.to_str().unwrap())
    }

    #[test]
    fn reply_window() {
        let p = root("reply");
        let now = Utc::now();
        let open = crate::time::stamp_utc(now + Cd::minutes(30));
        fs::write(p.replies(), json!({"openUntil": open}).to_string()).unwrap();
        let fl = Flavour::Desktop;
        for on in [json!(true), json!("TRUE"), json!(1)] {
            let cfg = json!({"reply": {"on": on, "topic": "t", "key": {"value": "00"}}});
            assert!(reply_open(&cfg, &p.replies(), now, fl));
        }
        assert!(!reply_open(
            &json!({"reply": {"on": "1", "topic": "t", "key": "k"}}),
            &p.replies(),
            now,
            fl
        ));
        assert!(!reply_open(
            &json!({"reply": {"on": true, "topic": "t"}}),
            &p.replies(),
            now,
            fl
        ));
        let pairing = json!({"reply": {"on": true, "topic": "t",
            "pairing": {"expires": crate::time::stamp_utc(now + Cd::minutes(5))}}});
        assert!(reply_open(&pairing, &p.replies(), now, fl));
        fs::write(p.replies(), json!({"standing": true}).to_string()).unwrap();
        let always = json!({"reply": {"on": true, "topic": "t", "key": "k", "listen": "Always"}});
        assert!(reply_open(&always, &p.replies(), now, fl));
        assert!(!reply_open(
            &json!({"reply": {"on": true, "topic": "t", "key": "k"}}),
            &p.replies(),
            now,
            fl
        ));
        assert!(!reply_open(&json!({}), &p.replies(), now, fl));
    }

    #[test]
    fn auto_switch_and_chats() {
        assert!(auto_wanted(&json!({"autoContinue": " ON "}), None));
        assert!(!auto_wanted(&json!({"autoContinue": true}), None));
        assert!(!auto_wanted(
            &json!({}),
            Some(&json!({"chats": {"a": {"auto": "never"}}}))
        ));
        assert!(auto_wanted(
            &json!({}),
            Some(&json!({"chats": {"a": {"auto": "Always"}}}))
        ));
    }

    #[test]
    fn held_and_repair() {
        let p = root("held");
        let now = SystemTime::now();
        assert!(!held_waiting(&p, now));
        let sending = std::path::Path::new(&p.data).join("held-1.sending");
        fs::write(&sending, "").unwrap();
        assert!(!held_waiting(&p, now), "claimed just now");
        assert!(held_waiting(&p, now + Duration::from_secs(601)));
        fs::write(p.held(), "{}\n").unwrap();
        assert!(held_waiting(&p, now));

        assert!(!repair_due(&[], &p));
        assert!(repair_due(&[json!({"id": "a", "state": "Running"})], &p));
        fs::create_dir_all(p.permit_dir()).unwrap();
        fs::write(p.permit_dir().join("bridge-failed.json"), "{}").unwrap();
        assert!(
            !repair_due(&[], &p),
            "a permit folder with no job folder and no replies.json"
        );
        fs::write(p.replies(), "{}").unwrap();
        assert!(repair_due(&[], &p));
        fs::remove_file(p.replies()).unwrap();
        fs::create_dir_all(p.permit_dir().join("job1")).unwrap();
        assert!(repair_due(&[], &p));
        fs::remove_dir_all(p.permit_dir()).unwrap();
        fs::create_dir_all(p.ask_dir()).unwrap();
        fs::write(p.ask_dir().join("r.ans.json"), "{}").unwrap();
        assert!(!repair_due(&[], &p));
        fs::write(p.ask_dir().join("r.req.json"), "{}").unwrap();
        assert!(repair_due(&[], &p));
    }

    #[test]
    fn stray_candidates() {
        let p = root("stray");
        let q = p.queue_dir();
        fs::create_dir_all(&q).unwrap();
        let later = SystemTime::now() + Duration::from_secs(25 * 3600);
        fs::write(q.join("a.json"), "{}").unwrap();
        fs::write(q.join("a.md"), "x").unwrap();
        fs::create_dir_all(q.join("20261015-101500-ab12")).unwrap();
        fs::write(q.join("20261015-101500-ab12").join("img.png"), "x").unwrap();
        fs::create_dir_all(q.join("a")).unwrap();
        fs::write(q.join("a").join("img.png"), "x").unwrap();
        assert!(
            !stray_maybe(&q, later),
            "only the queue's own files and job folders"
        );
        fs::write(q.join("pasted.png"), "x").unwrap();
        assert!(!stray_maybe(&q, SystemTime::now()), "not a day old yet");
        assert!(stray_maybe(&q, later));
        fs::remove_file(q.join("pasted.png")).unwrap();
        fs::create_dir_all(q.join("loose")).unwrap();
        assert!(stray_maybe(&q, later));
        assert_eq!(extension(".gitignore"), ".gitignore");
        assert_eq!(extension("a."), "");
    }
}
