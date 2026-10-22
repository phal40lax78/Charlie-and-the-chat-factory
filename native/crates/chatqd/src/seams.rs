//! CHATQ_NATIVE_SEAMS (SPEC 6.5): a JSON file of test seams. chatqd itself
//! honours `spawn`, `capture`, `panic`, `clock`, `ntfyBase` and
//! `connectForbidden`; the steps
//! get the file too, and any other name is theirs or a later milestone's.

use crate::http::{loopback, url_host};
use chatq_core::fsx::{read_json, save_text};
use chatq_core::json;
use chatq_core::time::{Flavour, Instant, date_of};
use chrono::{TimeDelta, Utc};
use serde_json::Value;
use std::path::PathBuf;

#[derive(Default)]
pub struct Seams {
    /// where launches are recorded instead of started, when `spawn` is on
    pub capture: Option<PathBuf>,
    /// the first pass panics, so the panic strike and handoff are tested
    pub panic: bool,
    /// `clock`: the time quiet hours are judged at, frozen, as
    /// [Get-ChatqNow](src/phone-extras.ps1) gives `ChatqClockSeam`
    pub clock: Option<Instant>,
    /// `ntfyBase`: the reply server when config names none, taken only for
    /// a loopback host, so no test can point a poll at the network
    pub ntfy_base: Option<String>,
    /// an `ntfyBase` given and refused, for its chatqd.log line
    ntfy_refused: bool,
    /// `connectForbidden`: every poll's connect refused as a firewall
    /// refuses it ([http::get_forbidden](crate::http::get_forbidden)), so
    /// nothing reaches any server
    pub connect_forbidden: bool,
}

impl Seams {
    pub fn load() -> Seams {
        let Some(path) = std::env::var_os("CHATQ_NATIVE_SEAMS").filter(|p| !p.is_empty()) else {
            return Seams::default();
        };
        // a test's own file, read before any flavour is known
        let Some(v) = read_json(&PathBuf::from(path), Flavour::Core) else {
            return Seams::default();
        };
        Seams::of(&v, Utc::now())
    }

    /// The seams of file `v`, read at `now`.
    fn of(v: &Value, now: Instant) -> Seams {
        let v = Some(v);
        let capture = json::get(v, "capture")
            .and_then(Value::as_str)
            .filter(|_| json::truthy(json::get(v, "spawn")))
            .map(PathBuf::from);
        let panic = json::truthy(json::get(v, "panic"));
        // native-step.ps1's reading: a number is seconds from now, else a
        // stamp ConvertTo-ChatqDate takes
        let clock = match json::get(v, "clock") {
            Some(Value::Number(n)) => n
                .as_f64()
                .and_then(|s| TimeDelta::try_milliseconds((s * 1000.0) as i64))
                .map(|d| now + d),
            c => date_of(c.filter(|c| !c.is_null()), Flavour::Core),
        };
        // [string]$stepSeams.ntfyBase, as the step takes it
        let base = json::get(v, "ntfyBase").map(|b| json::to_ps_string(Some(b)));
        let ntfy_refused = base.as_deref().is_some_and(|b| !loopback(url_host(b)));
        let ntfy_base = base.filter(|_| !ntfy_refused);
        Seams {
            capture,
            panic,
            clock,
            ntfy_base,
            ntfy_refused,
            connect_forbidden: json::truthy(json::get(v, "connectForbidden")),
        }
    }

    /// One line per honoured seam, for chatqd.log.
    pub fn honoured(&self) -> Vec<String> {
        let mut out = Vec::new();
        if let Some(c) = &self.capture {
            out.push(format!("seam spawn: launches recorded in {}", c.display()));
        }
        if self.panic {
            out.push("seam panic: the first pass panics".into());
        }
        if let Some(c) = self.clock {
            let at = chatq_core::time::stamp_utc(c);
            out.push(format!("seam clock: quiet hours judged at {at}"));
        }
        if let Some(b) = &self.ntfy_base {
            out.push(format!("seam ntfyBase: the default reply server is {b}"));
        }
        if self.ntfy_refused {
            out.push("seam ntfyBase refused: not a loopback host".into());
        }
        if self.connect_forbidden {
            out.push("seam connectForbidden: every poll's connect is refused".into());
        }
        out
    }

    /// Records a launch as `<capture>/spawn-<n>.json` when the seam is on,
    /// and says whether it did, so the caller starts nothing.
    pub fn capture(&self, record: &Value) -> bool {
        let Some(dir) = &self.capture else {
            return false;
        };
        let n = (1..)
            .find(|n| !dir.join(format!("spawn-{n}.json")).exists())
            .unwrap_or(1);
        let text = serde_json::to_string_pretty(record).unwrap_or_default();
        let _ = save_text(&dir.join(format!("spawn-{n}.json")), &text);
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn ntfy_base_is_taken_only_for_a_loopback_host() {
        let now = Utc::now();
        for ok in [
            "http://127.0.0.1:8080",
            "http://localhost:1",
            "http://[::1]:2",
        ] {
            let s = Seams::of(&json!({"ntfyBase": ok}), now);
            assert_eq!(s.ntfy_base.as_deref(), Some(ok));
            assert!(s.honoured()[0].starts_with("seam ntfyBase: "));
        }
        for off in [
            "https://ntfy.sh",
            "http://127.0.0.1.example:80",
            "http://10.0.0.1",
        ] {
            let s = Seams::of(&json!({"ntfyBase": off}), now);
            assert_eq!(s.ntfy_base, None, "{off}");
            assert_eq!(s.honoured(), ["seam ntfyBase refused: not a loopback host"]);
        }
        assert_eq!(Seams::of(&json!({}), now).ntfy_base, None);
    }

    #[test]
    fn connect_forbidden_is_a_switch() {
        let now = Utc::now();
        let s = Seams::of(&json!({"connectForbidden": true}), now);
        assert!(s.connect_forbidden);
        assert_eq!(
            s.honoured(),
            ["seam connectForbidden: every poll's connect is refused"]
        );
        assert!(!Seams::of(&json!({}), now).connect_forbidden);
    }

    #[test]
    fn the_clock_is_seconds_from_now_or_a_stamp() {
        let now = Utc::now();
        let s = Seams::of(&json!({"clock": 90}), now);
        assert_eq!(s.clock, Some(now + TimeDelta::seconds(90)));
        let s = Seams::of(&json!({"clock": "2026-10-15T03:00:00.0000000Z"}), now);
        assert_eq!(
            s.clock.map(chatq_core::time::stamp_utc).as_deref(),
            Some("2026-10-15T03:00:00.0000000Z")
        );
        assert_eq!(Seams::of(&json!({"clock": null}), now).clock, None);
    }
}
