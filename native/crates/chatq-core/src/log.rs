//! [Add-ChatqLogLine](src/queue.ps1) (SPEC 2.3): one stamped line onto
//! `data/logs/<name>`, rolled to `<name>.1` past 1 MB; and the two other lines
//! the logs get, [Write-ChatqReplyLog](src/phone.ps1)'s and alerts.log's
//! ([Send-ChatqAlert](src/alerts.ps1)). Vector: native/vectors/log.json.

use crate::time::{Instant, Zone, stamp_in};
use std::fs;
use std::io;
use std::path::Path;

/// [Add-ChatqLogLine](src/queue.ps1)'s `1MB`: a log longer than this moves
/// to `<name>.1`, over any old one, before the next line.
pub const ROLL_BYTES: u64 = 1024 * 1024;

/// [Add-ChatqLogLine](src/queue.ps1) in the system's zone:
/// `<local o><two spaces><text>\n`, UTF-8 without a BOM, LF on every OS,
/// the text as it came.
pub fn add_log_line(log_dir: &Path, name: &str, text: &str, now: Instant) -> io::Result<()> {
    add_log_line_in(log_dir, name, text, now, Zone::Local)
}

/// [Add-ChatqLogLine](src/queue.ps1) with `zone` the system's, which the
/// stamp is written in.
pub fn add_log_line_in(
    log_dir: &Path,
    name: &str,
    text: &str,
    now: Instant,
    zone: Zone,
) -> io::Result<()> {
    fs::create_dir_all(log_dir)?;
    let p = log_dir.join(name);
    if fs::metadata(&p).is_ok_and(|m| m.len() > ROLL_BYTES) {
        let mut old = p.as_os_str().to_owned();
        old.push(".1");
        fs::rename(&p, old)?;
    }
    crate::fsx::append(&p, &format!("{}  {}\n", stamp_in(now, zone), text))
}

/// [Write-ChatqReplyLog](src/phone.ps1): `text` on one line, each run of
/// line breaks a space, as `phone: <text>` in watcher.log and as itself in
/// replies.log. A write that fails is let go, as PowerShell lets it go.
pub fn write_reply_log(log_dir: &Path, text: &str, now: Instant, zone: Zone) {
    let one = collapse(text, |c| c == '\r' || c == '\n');
    let _ = add_log_line_in(log_dir, "watcher.log", &format!("phone: {one}"), now, zone);
    let _ = add_log_line_in(log_dir, "replies.log", &one, now, zone);
}

/// The line [Send-ChatqAlert](src/alerts.ps1) writes before any channel:
/// `<local o>\t<event>\t<text>\n` onto alerts.log, the text's `-replace
/// '\s+', ' '` (.NET's `\s` is the 25 characters [char::is_whitespace]
/// takes, under both PowerShells) and the event as it came. alerts.log
/// never rolls; PowerShell lets a failed write go.
pub fn add_alert_line(
    log_dir: &Path,
    event: &str,
    text: &str,
    now: Instant,
    zone: Zone,
) -> io::Result<()> {
    fs::create_dir_all(log_dir)?;
    let text = collapse(text, char::is_whitespace);
    crate::fsx::append(
        &log_dir.join("alerts.log"),
        &format!("{}\t{event}\t{text}\n", stamp_in(now, zone)),
    )
}

/// `-replace '<class>+', ' '`, the class being `is`.
fn collapse(s: &str, is: impl Fn(char) -> bool) -> String {
    let mut out = String::with_capacity(s.len());
    let mut run = false;
    for c in s.chars() {
        if !is(c) {
            out.push(c);
        } else if !run {
            out.push(' ');
        }
        run = is(c);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::time::stamp_local;

    #[test]
    fn line_shape_and_roll() {
        let d = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/test-data/core-log");
        let _ = fs::remove_dir_all(&d);
        let now = chrono::Utc::now();
        add_log_line(&d, "watcher.log", "watcher 1 started (0.0.1)", now).unwrap();
        let text = fs::read_to_string(d.join("watcher.log")).unwrap();
        assert_eq!(
            text,
            format!("{}  watcher 1 started (0.0.1)\n", stamp_local(now))
        );
        fs::write(d.join("watcher.log"), vec![b'x'; ROLL_BYTES as usize + 1]).unwrap();
        add_log_line(&d, "watcher.log", "after", now).unwrap();
        assert_eq!(
            fs::metadata(d.join("watcher.log.1")).unwrap().len(),
            ROLL_BYTES + 1
        );
        assert!(
            fs::read_to_string(d.join("watcher.log"))
                .unwrap()
                .ends_with("  after\n")
        );
    }

    #[test]
    fn runs_collapse_to_one_space() {
        let nl = |c| c == '\r' || c == '\n';
        assert_eq!(collapse("a\r\n\r\nb\nc", nl), "a b c");
        assert_eq!(
            collapse("\na\t b\u{a0}\u{2028}", char::is_whitespace),
            " a b "
        );
    }
}
