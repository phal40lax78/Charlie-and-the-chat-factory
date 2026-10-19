//! Which watcher a launch starts, and how (SPEC 2.7, 4.2): the loader's
//! version, the engine decision's inputs and records (pending, last,
//! verified, the fuse), and the PowerShell watcher's launch command exactly
//! as [Get-ChatqWatcherLaunch](src/watcher.ps1) builds it.

use crate::fsx::{self, read_json, save_text};
use crate::json::{self, ieq};
use crate::paths::{Paths, SEP, join};
use crate::time::{Flavour, Instant, date_of, stamp_utc};
use base64::Engine as _;
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};

/// The `bin/` folder name (SPEC 4.5), not the compiled triple: both Apple
/// slices of the universal binary say `universal-apple-darwin`.
#[cfg(windows)]
pub const TARGET: &str = "x86_64-pc-windows-msvc";
#[cfg(target_os = "macos")]
pub const TARGET: &str = "universal-apple-darwin";
#[cfg(not(any(windows, target_os = "macos")))]
pub const TARGET: &str = "unsupported";

/// The PowerShell the records (pending, last, verified, the fuse) are read
/// as, whoever reads them: [Get-ChatqWatcherEngine](src/watcher.ps1) runs
/// under either, chatqd under its own, and one decision must not turn on
/// which. chatqd and [Save-ChatqNativeFuse](src/watcher.ps1) write them as
/// strict JSON with no name given twice and no `__type`, which both
/// grammars read alike; neither grammar is the narrower (each takes text
/// the other refuses), so a hand-edited record may read differently.
/// Desktop is picked because its stamps are the ones the decision has
/// always read.
/// Deferred: DEFERRED.md "data/native records read as 5.1 reads them"
const RECORDS: Flavour = Flavour::Desktop;

#[cfg(windows)]
const EXE: &str = "chatqd.exe";
#[cfg(not(windows))]
const EXE: &str = "chatqd";

/// [extension/setup.js](extension/setup.js) `readVersion`:
/// `/^\$script:ChatVersion = '(\d+)\.(\d+)\.(\d+)'/m`, first match. `^` in a
/// JS multiline regex follows CR as well as LF.
pub fn loader_version(text: &str) -> Option<String> {
    const HEAD: &str = "$script:ChatVersion = '";
    text.split(['\n', '\r']).find_map(|line| {
        let rest = line.strip_prefix(HEAD)?;
        let mut parts = Vec::with_capacity(3);
        let mut it = rest;
        for k in 0..3 {
            let n = it.bytes().take_while(u8::is_ascii_digit).count();
            if n == 0 {
                return None;
            }
            parts.push(&it[..n]);
            it = &it[n..];
            let want = if k < 2 { '.' } else { '\'' };
            it = it.strip_prefix(want)?;
        }
        Some(parts.join("."))
    })
}

/// The loader read as setup.js reads it, latin1: None when it cannot be
/// read or holds no version line.
pub fn read_loader_version(path: &Path) -> Option<String> {
    let bytes = fs::read(path).ok()?;
    let text: String = bytes.iter().map(|&b| b as char).collect();
    loader_version(&text)
}

/// `'…'` with `CodeGeneration.EscapeSingleQuotedStringContent`: each of `'`
/// and the curly quotes U+2018-U+201B doubled, since PowerShell's parser
/// takes all five as a single quote.
pub fn ps_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        if matches!(c, '\'' | '\u{2018}' | '\u{2019}' | '\u{201A}' | '\u{201B}') {
            out.push(c);
        }
        out.push(c);
    }
    out.push('\'');
    out
}

/// `Join-Path $Parent $Child` as [Get-ChatqWatcherLaunch](src/watcher.ps1)
/// joins its log file: each `/` and `\` in the parent written as `sep`, and
/// `sep` before the child unless the parent ends with one. Nothing else is
/// changed: doubled separators, `.`, `..`, wildcards and spaces stay. `sep`
/// is `\` on Windows, `/` on a Mac (the Mac's half is unverified).
pub fn join_path(parent: &str, child: &str, sep: char) -> String {
    let mut s: String = parent
        .chars()
        .map(|c| if c == '/' || c == '\\' { sep } else { c })
        .collect();
    if !s.ends_with(sep) {
        s.push(sep);
    }
    s.push_str(child);
    s
}

/// The command [Get-ChatqWatcherLaunch](src/watcher.ps1) encodes. `claude`
/// and `codex` are `CHATQ_CLAUDE`/`CHATQ_CODEX` from the environment, carried
/// into the command only when set.
pub fn ps_watcher_command(
    script: &str,
    log_dir: &str,
    claude: Option<&str>,
    codex: Option<&str>,
) -> String {
    ps_watcher_command_sep(script, log_dir, claude, codex, SEP)
}

/// [ps_watcher_command] for a system whose separator is `sep`: the command
/// [Get-ChatqWatcherLaunch](src/watcher.ps1) encodes there, its log file
/// [join_path]'s. native/vectors/watcher-launch.json pins it with `\` on
/// every system.
pub fn ps_watcher_command_sep(
    script: &str,
    log_dir: &str,
    claude: Option<&str>,
    codex: Option<&str>,
    sep: char,
) -> String {
    let mut pre = String::from("$env:CHATQ_WATCHER='1'; ");
    for (n, v) in [("CHATQ_CLAUDE", claude), ("CHATQ_CODEX", codex)] {
        if let Some(v) = v.filter(|v| !v.is_empty()) {
            pre.push_str(&format!("$env:{n}={}; ", ps_quote(v)));
        }
    }
    let log = join_path(log_dir, "watcher.log", sep);
    format!(
        "{pre}try {{ . {} }} catch {{ try {{ [void][IO.Directory]::CreateDirectory({}); \
         [IO.File]::AppendAllText({}, (Get-Date).ToString('o') + '  the watcher did not load: ' + $_.Exception.Message + [char]10) }} catch {{}}; exit 1 }}; \
         Remove-Item -LiteralPath 'env:PSExecutionPolicyPreference' -EA SilentlyContinue; Invoke-ChatqWatchLoop",
        ps_quote(script),
        ps_quote(log_dir),
        ps_quote(&log)
    )
}

/// `[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))`
pub fn encode_command(cmd: &str) -> String {
    let bytes: Vec<u8> = cmd.encode_utf16().flat_map(u16::to_le_bytes).collect();
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// The PowerShell watcher's arguments after its exe.
pub fn ps_watcher_args(cmd: &str) -> Vec<String> {
    [
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-EncodedCommand",
    ]
    .iter()
    .map(|s| s.to_string())
    .chain([encode_command(cmd)])
    .collect()
}

/// A native watcher's arguments (SPEC 4.1). The culture block goes on
/// unchanged, so a respawn renders times as its starter did.
pub fn native_args(root: &str, script: &str, ps: &str, culture: Option<&str>) -> Vec<String> {
    let mut a: Vec<String> = ["watch", "--root", root, "--script", script, "--ps", ps]
        .iter()
        .map(|s| s.to_string())
        .collect();
    if let Some(c) = culture {
        a.extend(["--culture".to_string(), c.to_string()]);
    }
    a
}

/// `R/bin/<version>/<target>/chatqd(.exe)`, or `CHATQ_CHATQD` when set.
pub fn binary_path(p: &Paths, version: &str, chatqd_env: Option<&str>) -> PathBuf {
    match chatqd_env.filter(|s| !s.is_empty()) {
        Some(s) => PathBuf::from(s),
        None => PathBuf::from(join(
            &join(&join(&join(&p.root, "bin"), version), TARGET),
            EXE,
        )),
    }
}

/// Whether native may run at all: `CHATQ_ENGINE` wins over config's
/// `watcher`; only "ps" says no. Absent means native whenever the binary is
/// there (decided 2026-10-15).
pub fn native_wanted(engine_env: Option<&str>, cfg: &Value) -> bool {
    let env = engine_env.map(str::trim).filter(|s| !s.is_empty());
    match env {
        Some(e) => !ieq(e, "ps"),
        None => !ieq(
            json::to_ps_string(json::get(Some(cfg), "watcher")).trim(),
            "ps",
        ),
    }
}

/// The lock holder's record, written atomically: `holding` once it has the
/// lock, then `empty`, `stopped` or `handed-over` as it lets go. Only the
/// lock holder writes it, so a crash after `holding` is never overwritten.
pub fn write_last(
    p: &Paths,
    pid: u32,
    version: &str,
    state: &str,
    now: Instant,
) -> std::io::Result<()> {
    let v = json!({"pid": pid, "version": version, "engine": "native", "state": state, "at": stamp_utc(now)});
    save_text(&p.last(), &pretty(&v))
}

/// Every native launch says so before the child can run (SPEC 4.2).
pub fn write_pending(p: &Paths, pid: u32, version: &str, now: Instant) -> std::io::Result<()> {
    save_text(
        &p.pending(),
        &pretty(&json!({"pid": pid, "version": version, "at": stamp_utc(now)})),
    )
}

/// The ack: pending.json deleted, only when it names this process, so a
/// launch still in flight for another one keeps its record.
pub fn ack_pending(p: &Paths, pid: u32) -> bool {
    let named = read_json(&p.pending(), RECORDS)
        .and_then(|v| json::get(Some(&v), "pid").and_then(Value::as_u64))
        .is_some_and(|n| n == pid as u64);
    named && fs::remove_file(p.pending()).is_ok()
}

fn pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

/// fuse.json's strikes and alert flag for `version`; another version's
/// record counts for nothing, as a version change clears the fuse.
fn fuse_for(p: &Paths, version: &str) -> (Vec<Value>, bool) {
    match read_json(&p.fuse(), RECORDS) {
        Some(f) if json::to_ps_string(json::get(Some(&f), "version")) == version => (
            json::get(Some(&f), "strikes")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default(),
            json::truthy(json::get(Some(&f), "alerted")),
        ),
        _ => (Vec::new(), false),
    }
}

/// One strike against `version`, kept with the ones before it.
pub fn record_strike(
    p: &Paths,
    version: &str,
    why: &str,
    pid: Option<u32>,
    now: Instant,
) -> std::io::Result<()> {
    let (mut strikes, alerted) = fuse_for(p, version);
    strikes.push(json!({"at": stamp_utc(now), "why": why, "pid": pid}));
    save_text(
        &p.fuse(),
        &pretty(&json!({"version": version, "strikes": strikes, "alerted": alerted})),
    )
}

/// 3 strikes within 24 h for the same version: PowerShell until the version
/// changes or fuse.json is deleted.
pub fn fuse_blown(p: &Paths, version: &str, now: Instant) -> bool {
    let day = now - chrono::Duration::hours(24);
    let (strikes, _) = fuse_for(p, version);
    strikes
        .iter()
        .filter(|s| date_of(json::get(Some(s), "at"), RECORDS).is_some_and(|t| t > day))
        .count()
        >= 3
}

/// What a decision call asks of the OS, so the rules here stay testable.
pub struct Probes<'a> {
    /// a live process at that pid that is a chatqd
    pub live_chatqd: &'a dyn Fn(u32) -> bool,
    /// any live process at that pid
    pub alive: &'a dyn Fn(u32) -> bool,
}

/// The strikes any decision call records when it finds them (SPEC 4.2): a
/// pending launch older than 15 s whose pid is no live chatqd, and a crash -
/// last.json `holding` for a dead pid, the lock free, watcher.pid left (a
/// clean exit deletes it) - once per pid. Returns what it recorded for
/// `version`; a stale record of another version is only cleared.
// Deferred: DEFERRED.md "An unreadable record in data/native"
pub fn find_strikes(p: &Paths, version: &str, now: Instant, probes: &Probes) -> Vec<String> {
    let mut found = Vec::new();
    if let Some(v) = read_json(&p.pending(), RECORDS) {
        let v = Some(&v);
        let pid = json::get(v, "pid")
            .and_then(Value::as_u64)
            .map(|n| n as u32);
        let at = date_of(json::get(v, "at"), RECORDS);
        let old = at.is_none_or(|t| (now - t).num_milliseconds() > 15_000);
        if old && !pid.is_some_and(|n| (probes.live_chatqd)(n)) {
            if json::to_ps_string(json::get(v, "version")) == version {
                let _ = record_strike(p, version, "no ack", pid, now);
                found.push(format!(
                    "a launch was never acked (pid {})",
                    pid.unwrap_or(0)
                ));
            }
            let _ = fs::remove_file(p.pending());
        }
    }
    if let Some(v) = read_json(&p.last(), RECORDS) {
        let v = Some(&v);
        let pid = json::get(v, "pid")
            .and_then(Value::as_u64)
            .map(|n| n as u32);
        if let Some(pid) = pid
            && json::eq_str(json::get(v, "engine"), "native")
            && json::eq_str(json::get(v, "state"), "holding")
            && json::to_ps_string(json::get(v, "version")) == version
            && !(probes.alive)(pid)
            && !fsx::lock_held(&p.lock())
            && p.pid().exists()
        {
            let (strikes, _) = fuse_for(p, version);
            let counted = strikes.iter().any(|s| {
                json::eq_str(json::get(Some(s), "why"), "crash")
                    && json::get(Some(s), "pid").and_then(Value::as_u64) == Some(pid as u64)
            });
            if !counted {
                let _ = record_strike(p, version, "crash", Some(pid), now);
                found.push(format!("the native watcher {pid} died holding the lock"));
            }
        }
    }
    found
}

/// A binary as preflight knows it: full path, size, and LastWriteTimeUtc.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Identity {
    pub path: String,
    pub size: u64,
    pub mtime: String,
}

impl Identity {
    /// The path as `Get-Item`'s FullName gives it: made absolute, separators
    /// and `..` resolved (GetFullPathNameW on Windows, as .NET calls it), so
    /// a root passed with forward slashes is the same binary to PS and Rust.
    /// Off Windows `std::path::absolute` keeps `..`, so it is dropped here by
    /// text, symlinks left alone, as .NET's GetFullPath drops it there.
    // Deferred: DEFERRED.md "A relative CHATQ_CHATQD"
    // Deferred: DEFERRED.md "A CHATQ_CHATQD in 8.3 short names"
    pub fn of(path: &Path) -> Option<Identity> {
        let full = std::path::absolute(path).ok()?;
        #[cfg(not(windows))]
        let full = {
            use std::path::{Component, PathBuf};
            let mut n = PathBuf::new();
            for c in full.components() {
                match c {
                    Component::ParentDir => {
                        n.pop();
                    }
                    Component::CurDir => {}
                    c => n.push(c.as_os_str()),
                }
            }
            n
        };
        let m = fs::metadata(&full).ok()?;
        let t: chrono::DateTime<chrono::Utc> = m.modified().ok()?.into();
        Some(Identity {
            path: full.to_string_lossy().into_owned(),
            size: m.len(),
            mtime: stamp_utc(t),
        })
    }
}

/// Has this exact binary passed preflight before? The path is compared
/// case-blind, as PowerShell's `-eq` compares it.
pub fn verified(p: &Paths, id: &Identity) -> bool {
    let Some(v) = read_json(&p.verified(), RECORDS) else {
        return false;
    };
    json::get(Some(&v), "passed")
        .and_then(Value::as_array)
        .is_some_and(|a| {
            a.iter().any(|e| {
                let e = Some(e);
                ieq(&json::to_ps_string(json::get(e, "path")), &id.path)
                    && json::get(e, "size").and_then(Value::as_u64) == Some(id.size)
                    && json::to_ps_string(json::get(e, "mtime")) == id.mtime
            })
        })
}

/// A pass, cached in verified.json so the next launch skips the run. It
/// replaces any earlier pass for the same path, a binary since rebuilt or
/// replaced, so the file holds one entry per path and never grows.
pub fn add_verified(p: &Paths, id: &Identity, now: Instant) -> std::io::Result<()> {
    let mut passed = read_json(&p.verified(), RECORDS)
        .and_then(|v| {
            json::get(Some(&v), "passed")
                .and_then(Value::as_array)
                .cloned()
        })
        .unwrap_or_default();
    passed.retain(|e| !ieq(&json::to_ps_string(json::get(Some(e), "path")), &id.path));
    passed.push(json!({"path": id.path, "size": id.size, "mtime": id.mtime, "at": stamp_utc(now)}));
    save_text(&p.verified(), &pretty(&json!({"passed": passed})))
}

/// What a decision asks besides data/ and the [Probes], so the rules in
/// [decide] stay testable: native/vectors/launch.json drives them here
/// (tests/launch_vectors.rs) and in [Get-ChatqWatcherEngine](src/watcher.ps1).
pub struct Ask<'a> {
    /// `CHATQ_ENGINE`; empty or spaces is unset
    pub engine_env: Option<&'a str>,
    /// config.json as read
    pub cfg: &'a Value,
    /// a Windows PC or a Mac, the systems a native build exists for
    pub native_os: bool,
    /// [binary_path]'s answer
    pub bin: &'a Path,
    /// is the binary there to run
    pub runnable: &'a dyn Fn(&Path) -> bool,
    /// `chatqd version --root R`, asked only of a build not yet verified
    pub preflight: &'a mut dyn FnMut(&Path) -> Result<(), String>,
}

/// A decision: the strikes it recorded, and the binary's full path to
/// start, or why the PowerShell watcher instead.
pub struct Decision {
    pub strikes: Vec<String>,
    pub native: Result<String, String>,
}

/// The decision (SPEC 4.2), the same table as
/// [Get-ChatqWatcherEngine](src/watcher.ps1): strikes are looked for first,
/// by every call, and one found makes this launch the PowerShell watcher's.
/// The PS side looks for the binary before config, which changes no answer.
pub fn decide(p: &Paths, version: &str, now: Instant, probes: &Probes, ask: Ask) -> Decision {
    let strikes = find_strikes(p, version, now, probes);
    let native = pick(p, version, now, &strikes, ask);
    Decision { strikes, native }
}

fn pick(
    p: &Paths,
    version: &str,
    now: Instant,
    strikes: &[String],
    ask: Ask,
) -> Result<String, String> {
    if !native_wanted(ask.engine_env, ask.cfg) {
        return Err("the engine is set to ps".into());
    }
    if !ask.native_os {
        return Err("no native build for this system".into());
    }
    if !(ask.runnable)(ask.bin) {
        return Err(format!("no runnable chatqd at {}", ask.bin.display()));
    }
    if !strikes.is_empty() {
        return Err("a strike was just recorded".into());
    }
    if fuse_blown(p, version, now) {
        return Err(format!("the native watcher failed 3 times for {version}"));
    }
    let Some(id) = Identity::of(ask.bin) else {
        return Err(format!("cannot read {}", ask.bin.display()));
    };
    if !verified(p, &id) {
        if let Err(e) = (ask.preflight)(ask.bin) {
            let _ = record_strike(p, version, "preflight", None, now);
            return Err(format!("preflight failed: {e}"));
        }
        let _ = add_verified(p, &id, now);
    }
    Ok(id.path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::{Duration, Utc};

    #[test]
    fn version_as_setup_js_reads_it() {
        assert_eq!(
            loader_version("x\r\n$script:ChatVersion = '0.10.12'\r\n"),
            Some("0.10.12".into())
        );
        assert_eq!(
            loader_version("x\r$script:ChatVersion = '1.2.3' # note"),
            Some("1.2.3".into())
        );
        assert_eq!(loader_version("  $script:ChatVersion = '1.2.3'"), None);
        assert_eq!(loader_version("$script:ChatVersion = '1.2'"), None);
        assert_eq!(
            loader_version("$script:ChatVersion = '1.2.3.4'\n$script:ChatVersion = '5.6.7'"),
            Some("5.6.7".into())
        );
        assert_eq!(loader_version("$script:ChatVersion = \"1.2.3\""), None);
    }

    #[test]
    fn single_quotes_doubled_with_the_curly_ones() {
        assert_eq!(ps_quote("it's"), "'it''s'");
        assert_eq!(
            ps_quote("a\u{2018}b\u{201B}"),
            "'a\u{2018}\u{2018}b\u{201B}\u{201B}'"
        );
        assert_eq!(ps_quote("a\u{201C}b"), "'a\u{201C}b'");
    }

    #[test]
    fn the_ps_launch_command() {
        let cmd = ps_watcher_command_sep(
            r"C:\t\Charlie-and-the-chat-factory.ps1",
            r"C:\t\data\logs",
            None,
            None,
            '\\',
        );
        assert_eq!(
            cmd,
            "$env:CHATQ_WATCHER='1'; try { . 'C:\\t\\Charlie-and-the-chat-factory.ps1' } catch { try { \
             [void][IO.Directory]::CreateDirectory('C:\\t\\data\\logs'); [IO.File]::AppendAllText('C:\\t\\data\\logs\\watcher.log', \
             (Get-Date).ToString('o') + '  the watcher did not load: ' + $_.Exception.Message + [char]10) } catch {}; exit 1 }; \
             Remove-Item -LiteralPath 'env:PSExecutionPolicyPreference' -EA SilentlyContinue; Invoke-ChatqWatchLoop"
        );
        let with = ps_watcher_command("s", "l", Some("C:\\c'x"), Some(""));
        assert!(
            with.starts_with("$env:CHATQ_WATCHER='1'; $env:CHATQ_CLAUDE='C:\\c''x'; try { . 's' }")
        );
        assert_eq!(encode_command("ab"), "YQBiAA==");
        let args = ps_watcher_args("ab");
        assert_eq!(
            args,
            [
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-EncodedCommand",
                "YQBiAA=="
            ]
        );
    }

    #[test]
    fn log_file_joined_as_join_path() {
        assert_eq!(join_path("a/b", "w", '\\'), r"a\b\w");
        assert_eq!(join_path(r"C:\a\\", "w", '\\'), r"C:\a\\w");
        assert_eq!(join_path("C:", "w", '\\'), r"C:\w");
        assert_eq!(join_path(r"a\b/", "w", '/'), "a/b/w");
    }

    #[test]
    fn engine_switches() {
        assert!(native_wanted(None, &json!({})));
        assert!(!native_wanted(None, &json!({"watcher": "PS"})));
        assert!(native_wanted(Some("native"), &json!({"watcher": "ps"})));
        assert!(!native_wanted(Some("ps"), &json!({"watcher": "native"})));
    }

    fn root(name: &str) -> Paths {
        let r = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../target/test-data/core-launch")
            .join(name);
        let _ = fs::remove_dir_all(&r);
        fs::create_dir_all(r.join("data").join("native")).unwrap();
        Paths::new(r.to_str().unwrap())
    }

    #[test]
    fn fuse_counts_a_day_of_one_version() {
        let p = root("fuse");
        let now = Utc::now();
        record_strike(&p, "1.0.0", "crash", Some(1), now - Duration::hours(30)).unwrap();
        record_strike(&p, "1.0.0", "crash", Some(2), now).unwrap();
        record_strike(&p, "1.0.0", "no ack", Some(3), now).unwrap();
        assert!(!fuse_blown(&p, "1.0.0", now), "one is a day old");
        record_strike(&p, "1.0.0", "preflight", None, now).unwrap();
        assert!(fuse_blown(&p, "1.0.0", now));
        assert!(!fuse_blown(&p, "1.0.1", now), "a new version starts clean");
        record_strike(&p, "1.0.1", "crash", Some(4), now).unwrap();
        assert!(!fuse_blown(&p, "1.0.0", now), "and the old record is gone");
    }

    #[test]
    fn strikes_from_pending_and_crash() {
        let p = root("strikes");
        let now = Utc::now();
        let dead = |_: u32| false;
        let live = |_: u32| true;
        write_pending(&p, 11, "1.0.0", now - Duration::seconds(5)).unwrap();
        let probes = Probes {
            live_chatqd: &dead,
            alive: &dead,
        };
        assert!(
            find_strikes(&p, "1.0.0", now, &probes).is_empty(),
            "under 15 s"
        );
        write_pending(&p, 11, "1.0.0", now - Duration::seconds(20)).unwrap();
        let busy = Probes {
            live_chatqd: &live,
            alive: &live,
        };
        assert!(
            find_strikes(&p, "1.0.0", now, &busy).is_empty(),
            "still running"
        );
        assert_eq!(find_strikes(&p, "1.0.0", now, &probes).len(), 1);
        assert!(!p.pending().exists());
        assert!(!ack_pending(&p, 5), "nothing to ack");
        write_pending(&p, 5, "1.0.0", now).unwrap();
        assert!(!ack_pending(&p, 6));
        assert!(ack_pending(&p, 5));

        write_last(&p, 77, "1.0.0", "holding", now).unwrap();
        assert!(
            find_strikes(&p, "1.0.0", now, &probes).is_empty(),
            "a clean exit left no pid file"
        );
        fs::write(p.pid(), "77\r\n").unwrap();
        assert_eq!(find_strikes(&p, "1.0.0", now, &probes).len(), 1);
        assert!(
            find_strikes(&p, "1.0.0", now, &probes).is_empty(),
            "once per pid"
        );
        write_last(&p, 77, "1.0.0", "empty", now).unwrap();
        assert!(find_strikes(&p, "1.0.0", now, &probes).is_empty());
    }

    #[test]
    fn preflight_cache() {
        let p = root("verified");
        let bin = Path::new(&p.native).join("chatqd.exe");
        fs::write(&bin, "x").unwrap();
        let id = Identity::of(&bin).unwrap();
        assert!(!verified(&p, &id));
        add_verified(&p, &id, Utc::now()).unwrap();
        assert!(verified(&p, &id));
        // the same binary named another way is the same identity
        let other = format!("{}/../native/chatqd.exe", p.native.replace('\\', "/"));
        assert_eq!(Identity::of(Path::new(&other)), Some(id.clone()));
        fs::write(&bin, "xy").unwrap();
        let id2 = Identity::of(&bin).unwrap();
        assert!(!verified(&p, &id2), "a new binary is checked again");
        add_verified(&p, &id2, Utc::now()).unwrap();
        let v = read_json(&p.verified(), RECORDS).unwrap();
        assert_eq!(v["passed"].as_array().unwrap().len(), 1, "one per path");
        assert!(verified(&p, &id2) && !verified(&p, &id));
    }
}
