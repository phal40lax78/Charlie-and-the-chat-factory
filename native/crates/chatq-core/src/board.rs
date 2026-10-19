//! data/queue.md as [Write-ChatqBoard](src/alerts.ps1) writes it while the
//! watcher runs and is not listening for phone replies. chatqd's loop still
//! writes only the board of an empty queue ([is_trivial], [trivial_text])
//! and hands anything more to PowerShell (SPEC 1.1, the empty-queue row);
//! [text] is the whole board, pinned by native/vectors/board.json
//! (tests/vectors/board.ps1).
//!
//! The watcher holds the lock, so the status line says `watcher running`,
//! and [Get-ChatqBlocks](src/alerts.ps1) reads the lanes from the state the
//! watcher saved ([blocks]); a listening watcher's board scans the lanes
//! instead, which is not ported. Wall-clock times are read in a [Zone]. The
//! launcher's [Culture] gives `updated`, an outage's `since` and the phone's
//! `until` their time separator, and the counts their grouping; every other
//! clock time on the board is invariant.

use crate::culture::Culture;
use crate::jobs::{is_continue, lane, state_in};
use crate::json::{self, ieq};
use crate::paths::{self, NEWLINE};
use crate::state::WatchState;
use crate::time::{Flavour, Instant, Zone, date_of, date_of_in, parse_stamp_in};
use chrono::{DateTime, Duration, Local, Offset, Utc};
use regex::Regex;
use serde_json::Value;
use std::fmt::Write as _;
use std::fs;
use std::io;
use std::path::Path;
use std::sync::LazyLock;

/// `" $script:ChatqDot "`: the dot between two parts of a line, spaced.
const DOT: &str = " \u{00B7} ";
/// `$script:ChatqEllipsis`
const ELLIPSIS: char = '\u{2026}';
/// `$script:ChatqContinueText`: what a continue job sends.
const CONTINUE_TEXT: &str = "Continue from where you left off.";

/// Is the board nothing but `_nothing queued_`? No job open (queued,
/// running, needs input, failed), none done or skipped in the last 2 days,
/// and no lane in the status line: [Get-ChatqBlocks](src/alerts.ps1) reads
/// the state this watcher just saved, so a lane limited until later or any
/// outage would be named there.
pub fn is_trivial(jobs: &[Value], w: &WatchState, now: Instant, fl: Flavour) -> bool {
    let two_days = now - Duration::days(2);
    let busy = jobs.iter().any(|j| {
        state_in(j, &["queued", "running", "needs-input", "failed"])
            || (state_in(j, &["done", "skipped"])
                && date_of(json::get(Some(j), "endedAt"), fl).is_some_and(|e| e > two_days))
    });
    !busy && w.outage.is_empty() && !w.blocked.iter().any(|(_, b)| b.until > now)
}

/// The text of that board, each line ending in `Environment.NewLine`. This
/// watcher holds the lock, so the status line says `watcher running`.
pub fn trivial_text(culture: &Culture, now: &DateTime<Local>) -> String {
    let lines = [
        "# chatq".to_string(),
        String::new(),
        format!(
            "chatq{DOT}0 queued{DOT}watcher running{DOT}updated {}",
            culture.hh_mm_ss(now)
        ),
        String::new(),
        "_nothing queued_".to_string(),
    ];
    lines.iter().map(|l| format!("{l}{NEWLINE}")).collect()
}

/// A lane in [Get-ChatqBlocks](src/alerts.ps1)'s answer: a limit or an
/// overload outage.
#[derive(Clone, Debug, PartialEq)]
pub struct Block {
    /// `Until`: when a limit lifts, or an outage's next look (if any)
    pub until: Option<Instant>,
    /// `Type`: a limit's as state.json has it, `overloaded` for an outage
    pub kind: Value,
    /// `Source`: a limit's as state.json has it; what an outage waits on,
    /// `status.claude.com` or (a Codex lane) `backoff`
    pub source: Value,
    /// `Status`: an outage's status page indicator; null for a limit
    pub status: Value,
    /// `Since`: when an outage began; None for a limit
    pub since: Option<Instant>,
}

/// [Get-ChatqBlocks](src/alerts.ps1) of a watcher that runs and is not
/// listening, from state.json as [Get-ChatqState](src/alerts.ps1) reads it
/// (None for a file missing or unread): each lane limited until after `now`,
/// then every outage, whatever its next look. Lanes are the keys of a
/// hashtable there, so case-blind: a later lane that differs only in case
/// takes an earlier one's place and keeps its spelling.
pub fn blocks(
    state: Option<&Value>,
    now: Instant,
    fl: Flavour,
    zone: Zone,
) -> Vec<(String, Block)> {
    let field = |v: &Value, name: &str| prop(v, name).cloned().unwrap_or(Value::Null);
    let date = |v: &Value, name: &str| date_of_in(prop(v, name), fl, zone);
    let mut out = Vec::new();
    if let Some(m) = json::get(state, "blocked").and_then(Value::as_object) {
        for (name, v) in m {
            if let Some(u) = date(v, "until").filter(|u| *u > now) {
                let b = Block {
                    until: Some(u),
                    kind: field(v, "type"),
                    source: field(v, "source"),
                    status: Value::Null,
                    since: None,
                };
                put(&mut out, name, b);
            }
        }
    }
    if let Some(m) = json::get(state, "outage").and_then(Value::as_object) {
        for (name, v) in m {
            // a Codex lane's outage waits on no page, only on its backoff
            let codex = name
                .get(..5)
                .is_some_and(|p| p.eq_ignore_ascii_case("codex"));
            let source = if codex {
                "backoff"
            } else {
                "status.claude.com"
            };
            let b = Block {
                until: date(v, "next"),
                kind: "overloaded".into(),
                source: source.into(),
                status: field(v, "status"),
                since: date(v, "since"),
            };
            put(&mut out, name, b);
        }
    }
    out
}

/// [Get-ChatqEta](src/alerts.ps1): what the board's "sends" says of each
/// queued job, keyed by its id, and `running` for a running one. A job with
/// waits of its own sends when the last of them ends - its lane's limit a
/// minute after it lifts, `notBefore`, a deferral, a retry - with an outage,
/// the deferral's reason or the retry saying why; of the jobs whose times
/// read alike, each after the one before it. A job free now waits behind
/// the run in progress and the free jobs queued before it. The keys are a
/// hashtable's, case-blind, an id taken as the string it makes. `-SendAt`
/// is not ported: the board passes none.
pub fn eta(
    jobs: &[Value],
    blocks: &[(String, Block)],
    now: Instant,
    fl: Flavour,
    zone: Zone,
    culture: &Culture,
) -> Vec<(String, String)> {
    let mut eta = Vec::new();
    let mut ahead = jobs.iter().find(|j| is(j, "running"));
    let mut tied: Vec<(String, &Value)> = Vec::new();
    for j in jobs.iter().filter(|j| state_in(j, &["queued", "running"])) {
        let id = str_of(j, "id");
        if is(j, "running") {
            put(&mut eta, &id, "running".to_string());
            continue;
        }
        let lane = lane(j);
        let date = |name: &str| date_of_in(prop(j, name), fl, zone);
        let mut times = Vec::new();
        let mut why: Option<String> = None;
        match find(blocks, &lane) {
            Some(b) if json::eq_str(Some(&b.kind), "overloaded") => why = Some("overloaded".into()),
            Some(Block { until: Some(u), .. }) => times.push(*u + Duration::minutes(1)),
            _ => {}
        }
        if let Some(nb) = date("notBefore") {
            times.push(nb);
        }
        let du = date("deferUntil");
        let mut words = None;
        if let Some(d) = du.filter(|d| *d > now) {
            times.push(d);
            // auto-continue's hold for a chat open in a VS Code panel is no
            // busy chat, nor is a background command or a tab someone is
            // in, whose words (defer_why) stand in for the next look's time
            words = defer_why(j, now, fl, zone);
            if why.is_none() {
                why = Some(if json::eq_str(prop(j, "deferWhy"), "vscode") {
                    "open in VS Code".to_string()
                } else {
                    words.clone().unwrap_or_else(|| "chat busy".to_string())
                });
            }
        }
        if let Some(ra) = date("retryAt").filter(|r| *r > now) {
            times.push(ra);
            if why.is_none() {
                why = Some("retry".to_string());
            }
        }
        let at = times.iter().copied().filter(|t| *t > now).max();
        let said = words
            .as_ref()
            .filter(|w| why.as_deref().is_some_and(|y| ieq(y, w)) && at == du);
        let text = if why.as_deref() == Some("overloaded") {
            format!("when {} is back", culture.provider_name(&lane, fl))
        } else if let Some(w) = said {
            w.clone()
        } else if let Some(at) = at {
            let mut s = clock_time(at, now, zone);
            let before = find(&tied, &s).copied();
            put(&mut tied, &s, j);
            if let Some(b) = before {
                s = format!("after #{}", str_of(b, "seq"));
            }
            match &why {
                Some(w) => format!("{s} ({w})"),
                None => s,
            }
        } else if let Some(a) = ahead {
            format!("after #{}", str_of(a, "seq"))
        } else {
            "next".to_string()
        };
        if at.is_none() && why.is_none() {
            ahead = Some(j);
        }
        put(&mut eta, &id, text);
    }
    eta
}

/// [Get-ChatqStatusLine](src/alerts.ps1) of a watcher that runs: how many
/// jobs are queued, the one running, each lane of [blocks]' answer, and
/// `watcher running`. The lanes are sorted as Sort-Object sorts strings,
/// ported as case-blind ordinal, which agrees with it on lane names.
/// Deferred: DEFERRED.md "PowerShell's culture compares, approximated"
pub fn status_line(
    jobs: &[Value],
    blocks: &[(String, Block)],
    now: Instant,
    fl: Flavour,
    zone: Zone,
    culture: &Culture,
) -> String {
    let queued = jobs.iter().filter(|j| is(j, "queued")).count();
    let mut parts = vec![format!("{queued} queued")];
    if let Some(r) = jobs.iter().find(|j| is(j, "running")) {
        parts.push(format!("running #{}", str_of(r, "seq")));
    }
    let mut lanes: Vec<&(String, Block)> = blocks.iter().collect();
    lanes.sort_by_cached_key(|(k, _)| k.to_lowercase());
    for (lane, b) in lanes {
        let name = culture.lane_name(lane, fl);
        if json::eq_str(Some(&b.kind), "overloaded") {
            let since = b
                .since
                .map(|s| format!(" since {}", culture.hh_mm(&zone.wall(s))))
                .unwrap_or_default();
            let st = if json::truthy(Some(&b.status)) {
                let status = json::to_ps_string(Some(&b.status)).replace('_', " ");
                format!(", status.claude.com: {status}")
            } else {
                String::new()
            };
            parts.push(format!("{name} overloaded{since}{st} - retrying"));
            continue;
        }
        let Some(until) = b.until else { continue };
        if json::eq_str(Some(&b.kind), "login needed") {
            // what the CLI said; a watcher from before it was kept says 'probe'
            let src = Some(&b.source);
            let said = if json::truthy(src) && !json::eq_str(src, "probe") {
                json::to_ps_string(src)
            } else {
                "login refused".to_string()
            };
            parts.push(format!(
                "{name} {said} - log in or check the subscription, chatq looks again every 15 min"
            ));
            continue;
        }
        let kind = json::to_ps_string(Some(&b.kind));
        parts.push(format!(
            "{name} limited until {} ({kind})",
            clock_time(until, now, zone)
        ));
    }
    parts.push("watcher running".to_string());
    format!("chatq{DOT}{}", parts.join(DOT))
}

/// [Get-ChatqPermitWaitText](src/permit.ps1): ` · asks the phone: Bash,
/// until 10:17` for a job whose run waits on the phone until a time not yet
/// past, else empty. The time shown is `ToLocalTime()`'s, which takes pwsh
/// 7's stamp with no zone, read as wall-clock time, for UTC.
pub fn permit_wait_text(
    job: &Value,
    now: Instant,
    fl: Flavour,
    zone: Zone,
    culture: &Culture,
) -> String {
    let w = prop(job, "permitWaiting").filter(|w| json::truthy(Some(*w)));
    let until = json::get(w, "until").and_then(Value::as_str).unwrap_or("");
    match (
        parse_stamp_in(until, fl, zone),
        parse_stamp_in(until, fl, Zone::Fixed(Utc.fix())),
    ) {
        (Some(u), Some(shown)) if u >= now => format!(
            "{DOT}asks the phone: {}, until {}",
            json::to_ps_string(json::get(w, "tool")),
            culture.hh_mm(&zone.wall(shown))
        ),
        _ => String::new(),
    }
}

/// [Read-ChatqPrompt](src/queue.ps1): the job's prompt file as it is now,
/// through [remove_prompt_header]; None for a file not there. The path is
/// `Join-Path <queue> <promptFile>`, so a job that names no file reads the
/// queue folder, which throws there: Err here. A UTF-8 BOM goes as
/// ReadAllText drops it; the UTF-16 and UTF-32 BOMs it also reads are not
/// ported (chatq writes UTF-8), and bytes that are not UTF-8 become U+FFFD
/// as Rust replaces them, which no vector holds against .NET's.
pub fn read_prompt(queue_dir: &str, job: &Value) -> io::Result<Option<String>> {
    let path = paths::join(queue_dir, &str_of(job, "promptFile"));
    let path = Path::new(&path);
    if !path.exists() {
        return Ok(None);
    }
    let bytes = fs::read(path)?;
    let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&bytes);
    Ok(Some(remove_prompt_header(&String::from_utf8_lossy(bytes))))
}

/// [Remove-ChatqPromptHeader](src/queue.ps1): BOMs off the front, the
/// `<!-- chatq: ... -->` comment that opens a prompt file taken out, the
/// rest trimmed.
pub fn remove_prompt_header(text: &str) -> String {
    static HEADER: LazyLock<Regex> = LazyLock::new(|| {
        Regex::new(r"(?s)\A\s*<!--\s*chatq:.*?-->").expect("the header pattern is valid")
    });
    let t = text.trim_start_matches('\u{FEFF}');
    HEADER.replace(t, "").trim().to_string()
}

/// What [Get-ChatqPromptStats](src/alerts.ps1) tells the board of a prompt.
/// (Its `Lines` is not ported: the board does not show it.)
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PromptStats {
    /// the first line that is not blank, trimmed
    pub first: String,
    /// the length in UTF-16 code units, as .NET counts it
    pub chars: usize,
}

/// [Get-ChatqPromptStats](src/alerts.ps1): lines split at `\r?\n`, so a
/// lone CR stays within a line.
pub fn prompt_stats(text: &str) -> PromptStats {
    PromptStats {
        first: text
            .split('\n')
            .map(str::trim)
            .find(|l| !l.is_empty())
            .unwrap_or("")
            .to_string(),
        chars: text.encode_utf16().count(),
    }
}

/// [Get-ChatqFence](src/alerts.ps1): a code fence one backtick longer than
/// the longest run of them in the text, and three at least.
pub fn fence(text: &str) -> String {
    let (mut max, mut run) = (2, 0);
    for c in text.chars() {
        run = if c == '`' { run + 1 } else { 0 };
        max = max.max(run);
    }
    "`".repeat(max + 1)
}

/// `[System.Net.WebUtility]::HtmlEncode`, as [Write-ChatqBoard](src/alerts.ps1)
/// encodes a prompt's summary: `<>"'&` as entities and U+00A0-U+00FF as
/// numbers; a character past U+FFFF as a number too under pwsh 7's .NET,
/// while .NET Framework (5.1) leaves it as it is.
pub fn html_encode(s: &str, fl: Flavour) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&#39;"),
            '&' => out.push_str("&amp;"),
            c if ('\u{A0}'..='\u{FF}').contains(&c) || (fl == Flavour::Core && c > '\u{FFFF}') => {
                let _ = write!(out, "&#{};", u32::from(c));
            }
            c => out.push(c),
        }
    }
    out
}

/// [Write-ChatqBoard](src/alerts.ps1)'s text: the status line and when it
/// was made, then a row for each job open (queued, running, needs input,
/// failed) and each done or skipped whose `endedAt` is later than two days
/// before `now`, the open ones first, each in the order of `jobs` (the
/// queue order [get_jobs](crate::jobs::get_jobs) gives), and each one's
/// prompt folded away; with none, `_nothing queued_`. Every line ends in
/// [NEWLINE], and a prompt's own lines end as its file has them. None where
/// PowerShell throws and its catch writes no board: a prompt file that does
/// not read ([read_prompt]).
/// Deferred: DEFERRED.md "Dates past the shapes the vectors pin"
pub fn text(
    queue_dir: &str,
    jobs: &[Value],
    blocks: &[(String, Block)],
    now: Instant,
    fl: Flavour,
    zone: Zone,
    culture: &Culture,
) -> Option<String> {
    let eta = eta(jobs, blocks, now, fl, zone, culture);
    let two_days = now - Duration::days(2);
    let open = jobs
        .iter()
        .filter(|j| state_in(j, &["queued", "running", "needs-input", "failed"]));
    let recent = jobs.iter().filter(|j| {
        state_in(j, &["done", "skipped"])
            && date_of_in(prop(j, "endedAt"), fl, zone).is_some_and(|e| e > two_days)
    });
    let shown: Vec<&Value> = open.chain(recent).collect();
    // each job's text in the table and in its section: a continue is named
    // in one and sends the continue text in the other
    let mut texts = Vec::with_capacity(shown.len());
    for j in &shown {
        texts.push(if is_continue(prop(j, "kind")) {
            let auto = json::truthy(prop(j, "auto"));
            let named = if auto { "continue (auto)" } else { "continue" };
            (named.to_string(), CONTINUE_TEXT.to_string())
        } else {
            let p = read_prompt(queue_dir, j).ok()?.unwrap_or_default();
            (p.clone(), p)
        });
    }
    let mut out = String::new();
    let mut line = |s: &str| {
        out.push_str(s);
        out.push_str(NEWLINE);
    };
    line("# chatq");
    line("");
    let status = status_line(jobs, blocks, now, fl, zone, culture);
    line(&format!(
        "{status}{DOT}updated {}",
        culture.hh_mm_ss(&zone.wall(now))
    ));
    line("");
    if shown.is_empty() {
        line("_nothing queued_");
        return Some(out);
    }
    line("| # | chat | state | sends | prompt |");
    line("|---|------|-------|-------|--------|");
    for (j, (t, _)) in shown.iter().zip(&texts) {
        let ps = prompt_stats(t);
        let sends = if is(j, "running") {
            let w = permit_wait_text(j, now, fl, zone, culture);
            w.strip_prefix(DOT).unwrap_or(&w).to_string()
        } else if is(j, "queued") {
            find(&eta, &str_of(j, "id")).cloned().unwrap_or_default()
        } else {
            String::new()
        };
        line(&format!(
            "| {} | {} | {} | {} | {} ({} chars) |",
            str_of(j, "seq"),
            cell(&str_of(j, "title")),
            str_of(j, "state"),
            cell(&sends),
            cell(&cut(&ps.first, 60)),
            culture.n0(ps.chars as u64)
        ));
    }
    line("");
    for (j, (_, t)) in shown.iter().zip(&texts) {
        let ps = prompt_stats(t);
        let mode = prop(j, "mode")
            .filter(|m| json::truthy(Some(*m)))
            .or_else(|| prop(j, "modeAtQueue"));
        line(&format!(
            "## #{}{DOT}{}",
            str_of(j, "seq"),
            cell(&str_of(j, "title"))
        ));
        line("");
        line(&format!(
            "{}{DOT}{}{DOT}`{}`{DOT}{}{DOT}picked by {}",
            str_of(j, "provider"),
            json::to_ps_string(mode),
            str_of(j, "cwd"),
            str_of(j, "state"),
            str_of(j, "rule")
        ));
        line("");
        let result = prop(j, "result");
        let (reason, excerpt) = (json::get(result, "reason"), json::get(result, "excerpt"));
        if json::truthy(result) && (json::truthy(reason) || json::truthy(excerpt)) {
            if json::truthy(reason) {
                let kind = json::to_ps_string(json::get(result, "kind"));
                line(&format!(
                    "> **{kind}** {}",
                    cell(&json::to_ps_string(reason))
                ));
            }
            if json::truthy(excerpt) {
                line(&format!("> {}", cell(&json::to_ps_string(excerpt))));
            }
            line("");
            line(&format!("[run log](logs/{}.jsonl)", str_of(j, "id")));
            line("");
        }
        let f = fence(t);
        line(&format!(
            "<details><summary>{}{DOT}{} chars</summary>",
            html_encode(&cut(&ps.first, 80), fl),
            culture.n0(ps.chars as u64)
        ));
        line("");
        line(&format!("{f}text"));
        line(t);
        line(&f);
        line("");
        line("</details>");
        line("");
    }
    Some(out)
}

/// `$j.<name>`: a field of a job or of a record in it, case-blind.
fn prop<'a>(v: &'a Value, name: &str) -> Option<&'a Value> {
    json::get(Some(v), name)
}

/// `"$($j.<name>)"`: a field as a string puts it.
fn str_of(v: &Value, name: &str) -> String {
    json::to_ps_string(prop(v, name))
}

/// `$j.state -eq <state>`
fn is(j: &Value, state: &str) -> bool {
    json::eq_str(prop(j, "state"), state)
}

/// `$table[$key] = $value` on a PowerShell hashtable, whose string keys are
/// case-blind: a key already there keeps its spelling and takes the value.
fn put<T>(table: &mut Vec<(String, T)>, key: &str, value: T) {
    match table.iter_mut().find(|(k, _)| ieq(k, key)) {
        Some(slot) => slot.1 = value,
        None => table.push((key.to_string(), value)),
    }
}

/// `$table[$key]`, case-blind.
fn find<'a, T>(table: &'a [(String, T)], key: &str) -> Option<&'a T> {
    table.iter().find(|(k, _)| ieq(k, key)).map(|(_, v)| v)
}

/// [Format-ChatqDeferWhy](src/alerts.ps1): what a deferred job waits for,
/// where the time of its next look says too little - a background command
/// its chat started (since when), or you leaving the chat's tab; None for
/// the rest.
fn defer_why(j: &Value, now: Instant, fl: Flavour, zone: Zone) -> Option<String> {
    let why = str_of(j, "deferWhy");
    if ieq(&why, "background") {
        let w = "waits for a background command";
        return Some(match date_of_in(prop(j, "deferSince"), fl, zone) {
            Some(s) => format!("{w} (since {})", overlay_when(s, now, zone)),
            None => w.to_string(),
        });
    }
    ieq(&why, "in-use").then(|| "waits for you to leave its tab".to_string())
}

/// [Format-ChatqClockTime](src/phone-extras.ps1): `13:00` on the day of
/// `now`, `Tue 13:00` on any other, invariant.
fn clock_time(at: Instant, now: Instant, zone: Zone) -> String {
    let (a, n) = (zone.wall(at), zone.wall(now));
    let fmt = if a.date() == n.date() {
        "%H:%M"
    } else {
        "%a %H:%M"
    };
    a.format(fmt).to_string()
}

/// [Format-ChatOverlayWhen](src/overlay-data.ps1): `14:05` on the day of
/// `now`, `Fri 14:05` less than six days before it (or any time after it),
/// `Oct 5` before that, invariant.
fn overlay_when(at: Instant, now: Instant, zone: Zone) -> String {
    let (a, n) = (zone.wall(at), zone.wall(now));
    let fmt = if a.date() == n.date() {
        "%H:%M"
    } else if n - a < Duration::days(6) {
        "%a %H:%M"
    } else {
        "%b %-d"
    };
    a.format(fmt).to_string()
}

/// The board's `$e`, `[string]$s` for a table cell or a heading: each `|`
/// an entity, not `\|` (text that already holds `\|` would end up `\\|` and
/// split the cell), and each run of CRs and LFs one space.
fn cell(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut broken = false;
    for c in s.chars() {
        match c {
            '\r' | '\n' if broken => {}
            '\r' | '\n' => {
                out.push(' ');
                broken = true;
            }
            '|' => {
                out.push_str("&#124;");
                broken = false;
            }
            c => {
                out.push(c);
                broken = false;
            }
        }
    }
    out
}

/// `$s.Substring(0, n) + '…'` for a first line longer than `n` UTF-16 code
/// units. A cut through a surrogate pair leaves half of it, which the UTF-8
/// the board is saved in writes as U+FFFD.
fn cut(s: &str, n: usize) -> String {
    let units: Vec<u16> = s.encode_utf16().collect();
    if units.len() <= n {
        return s.to_string();
    }
    let mut t = String::from_utf16_lossy(&units[..n]);
    t.push(ELLIPSIS);
    t
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::state::Blocked;
    use chrono::TimeZone;
    use serde_json::json;

    #[test]
    fn what_counts_as_more() {
        let now = Utc::now();
        let fl = Flavour::Desktop;
        let w = WatchState::default();
        assert!(is_trivial(&[], &w, now, fl));
        let old = crate::time::stamp_utc(now - Duration::days(3));
        let new = crate::time::stamp_utc(now - Duration::hours(1));
        assert!(is_trivial(
            &[json!({"id": "a", "state": "done", "endedAt": old})],
            &w,
            now,
            fl
        ));
        assert!(!is_trivial(
            &[json!({"id": "a", "state": "done", "endedAt": new})],
            &w,
            now,
            fl
        ));
        assert!(!is_trivial(
            &[json!({"id": "a", "state": "needs-input"})],
            &w,
            now,
            fl
        ));
        assert!(is_trivial(
            &[json!({"id": "a", "state": "cancelled"})],
            &w,
            now,
            fl
        ));
        let mut w = WatchState::default();
        let b = Blocked {
            until: now + Duration::hours(1),
            kind: json!("session"),
            source: json!("probe"),
            at: None,
        };
        w.blocked.push(("claude".into(), b));
        assert!(!is_trivial(&[], &w, now, fl));
    }

    #[test]
    fn empty_board_text() {
        let t = Local.with_ymd_and_hms(2026, 10, 15, 21, 4, 9).unwrap();
        let text = trivial_text(&Culture::invariant(), &t);
        let want = [
            "# chatq",
            "",
            "chatq \u{b7} 0 queued \u{b7} watcher running \u{b7} updated 21:04:09",
            "",
            "_nothing queued_",
        ]
        .map(|l| format!("{l}{NEWLINE}"))
        .concat();
        assert_eq!(text, want);
    }
}
