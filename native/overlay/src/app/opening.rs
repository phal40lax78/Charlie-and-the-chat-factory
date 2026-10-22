// The chip's open (Invoke-ChatOverlayOpen, Update-ChatOverlayOpen,
// Start-ChatOverlayRaise and Update-ChatOverlayRaise in
// src/overlay-windows.ps1): the child started at the user's click, after
// VS Code's own processes are let take the front (open::grant); its end
// waited for a tick at a time, 60 s at most; the chat's VS Code window
// brought to the front as its end asks (open.rs). How it went goes to the
// host as `opened <key> <code> <look>` (or behind, late, nostart), which
// says it - a balloon and the panel's line (Get-ChatOverlayOpenSay) - and
// takes the chat's unread dot. Logged as the WPF overlay logs it: in ASCII,
// never a window's title.
// Deferred: DEFERRED.md "The unread dot lives in the overlay's memory"

use std::time::{Duration, Instant};

use serde_json::Value;

use super::{App, SaidSlot};
use crate::model::{self, s};
use crate::{open, panel, selflog};

/// How long an open's child is waited for.
const WAIT: Duration = Duration::from_secs(60);
/// The open's own line once it is over, until the host's comes in its place.
const AFTER: Duration = Duration::from_secs(10);

pub(super) struct Opening {
    child: open::Child,
    at: Instant,
    key: String,
    title: String,
    sid: String,
    sid8: String,
    cwd: String,
    front: isize,
}

/// An end's window looked for: by its folder, or by the name its tab says.
pub(super) struct Raise {
    sid8: String,
    cwd: String,
    name: String,
    code: i64,
    key: String,
    was_front: isize,
    until: Instant,
    profiles: Vec<String>,
}

impl App {
    /// The chip's open clicked: one at a time.
    pub(super) fn open_row(&mut self, row: &Value) {
        if self.opening.is_some() {
            return;
        }
        self.raise = None;
        let (key, cwd, title, sid) = (
            s(row, "key"),
            s(row, "cwd"),
            s(row, "title"),
            s(row, "sessionId"),
        );
        let front = open::foreground();
        open::grant(&open::code_pids());
        let cmd = open::command(
            &self.host.script,
            &sid,
            &cwd,
            &title,
            &self.host.claude_home,
            &open::env_now(),
        );
        let Some(child) = open::spawn(&self.host.script, &cmd) else {
            selflog::line("open: its child did not start");
            self.cmd(&format!("opened {key} nostart"));
            return;
        };
        let sid8: String = sid.chars().take(8).collect();
        selflog::line(&format!("open: {sid8}"));
        self.put_said(SaidSlot {
            id: String::new(),
            said: busy(&title, 0, &key),
            until: Instant::now() + WAIT + AFTER,
        });
        self.chip.say("opening", "dim");
        self.opening = Some(Opening {
            child,
            at: Instant::now(),
            key,
            title,
            sid,
            sid8,
            cwd,
            front,
        });
        self.redraw();
    }

    /// Update-ChatOverlayOpen, every tick.
    pub(super) fn open_tick(&mut self) {
        let Some(o) = self.opening.as_ref() else {
            self.raise_tick();
            return;
        };
        let code = o.child.exited();
        let secs = o.at.elapsed().as_secs() as i64;
        if code.is_none() && o.at.elapsed() < WAIT {
            // only while the line is still the open's: a delete or a reload
            // said meanwhile keeps its words
            let text = model::open_busy_text(&o.title, secs);
            if let Some(x) = self.said.as_mut().filter(|x| x.said.kind == "busy") {
                x.said.text = text;
            }
            if self.chip.hint.0 != "sure?" && !self.chip.key().is_empty() {
                self.chip.say(&format!("opening {secs}s"), "dim");
            }
            return;
        }
        let Some(o) = self.opening.take() else { return };
        match code {
            Some(code) => {
                selflog::line(&format!("open: {} ended {code}", o.sid8));
                let look = self.start_raise(&o, code);
                self.cmd(&format!("opened {} {code} {look}", o.key));
            }
            None => {
                selflog::line(&format!(
                    "open: {} no answer after 60 s - stopped waiting",
                    o.sid8
                ));
                self.cmd(&format!("opened {} late", o.key));
            }
        }
        self.chip.say("", "dim");
        self.hide_chip();
        if let Some(x) = self.said.as_mut().filter(|x| x.said.kind == "busy") {
            x.until = Instant::now() + AFTER;
        }
        self.redraw();
    }

    /// Start-ChatOverlayRaise: an end's window looked for, where its plan
    /// asks - front, behind, none, or looking.
    fn start_raise(&mut self, o: &Opening, code: i64) -> &'static str {
        self.raise = None;
        let Some(plan) = model::raise_plan(code) else {
            return "none";
        };
        let mut name = String::new();
        if plan.by_name {
            name = self
                .host
                .tabs
                .iter()
                .find(|(sid, _)| *sid == o.sid)
                .map(|(_, w)| w.clone())
                .unwrap_or_default();
            if name.is_empty() {
                selflog::line(&format!(
                    "open: {} to the front: its window has other folders, and no tab of it is listed - left as it is",
                    o.sid8
                ));
                return "none";
            }
        }
        self.raise = Some(Raise {
            sid8: o.sid8.clone(),
            cwd: o.cwd.clone(),
            name,
            code,
            key: o.key.clone(),
            was_front: o.front,
            until: Instant::now() + Duration::from_secs(plan.seconds.max(0) as u64),
            profiles: open::profiles(),
        });
        self.update_raise()
    }

    /// Update-ChatOverlayRaise: one look for the window.
    fn update_raise(&mut self) -> &'static str {
        let Some(r) = self.raise.as_ref() else {
            return "none";
        };
        let windows = open::windows(&open::code_pids());
        let Some(h) = model::select_window(&r.cwd, &windows, &r.profiles, &r.name) else {
            if Instant::now() < r.until {
                return "looking";
            }
            let of = if r.name.is_empty() {
                "on its folder"
            } else {
                "of its name"
            };
            selflog::line(&format!(
                "open: {} to the front: no one VS Code window {of} - left to VS Code",
                r.sid8
            ));
            self.raise = None;
            return "none";
        };
        let Some(r) = self.raise.take() else {
            return "none";
        };
        let x = open::raise(h, r.was_front);
        let how: Vec<&str> = [(x.restored, "restored"), (x.joined, "joined")]
            .into_iter()
            .filter(|(on, _)| *on)
            .map(|(_, w)| w)
            .collect();
        let mut line = format!(
            "open: {} to the front: {}",
            r.sid8,
            if x.front { "in front" } else { "still behind" }
        );
        if !how.is_empty() {
            line += &format!(" ({})", how.join(", "));
        }
        if let Some(why) = x.why {
            line += &format!(" - {why}");
        }
        selflog::line(&line);
        if x.front { "front" } else { "behind" }
    }

    /// With no child, a window still looked for: one found but left behind
    /// after an open that worked is said so, while the line is still the
    /// open's.
    fn raise_tick(&mut self) {
        let Some((code, key)) = self.raise.as_ref().map(|r| (r.code, r.key.clone())) else {
            return;
        };
        let look = self.update_raise();
        let free = self.said.as_ref().is_none_or(|x| x.said.kind == "done");
        if look == "behind" && code == 0 && free {
            self.cmd(&format!("opened {key} behind"));
        }
    }
}

/// The open's own line while it runs (Get-ChatOverlayOpenSay's busy).
fn busy(title: &str, secs: i64, key: &str) -> panel::Said {
    panel::Said {
        kind: "busy".into(),
        tone: "dim".into(),
        text: model::open_busy_text(title, secs),
        about: key.into(),
    }
}
