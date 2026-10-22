//! The look at the reply topic (SPEC 3.7, 7 "M3: Native listening"):
//! [Invoke-ChatqReplyPoll](src/phone.ps1) as the loop calls it. chatqd
//! fetches, triages and logs a batch of junk itself, and writes where
//! polling got to; a batch with anything worth acting on goes whole to one
//! `reply` step, which acts on it as PowerShell would on a fetch of its own.
//! chatqd never moves `lastId` past a message that checked out.
//!
//! The topic is a secret: it is in the URL and in the `reply` step's `In`,
//! and in no log line ([http::Fail] texts are fixed for that).

use super::Ctx;
use super::step::Outcome;
use crate::http::{self, Fail};
use crate::seams::Seams;
use chatq_core::config::read_config;
use chatq_core::log::write_reply_log;
use chatq_core::replyconfig::{self, ReplyConfig};
use chatq_core::replystate::{self, Error as StateError, ReplyState};
use chatq_core::state::WatchState;
use chatq_core::time::{Instant, Zone};
use chatq_core::wire::{self, Feed, Pass, PollCaches, Save};
use chrono::TimeDelta;
use serde_json::{Value, json};
use zeroize::Zeroizing;

/// The `reply` step's `-MaxMessages`, `-Quick` and `-TimeoutSec`: the
/// loop's own poll (SPEC 3.6 "Ops").
const MAX_MESSAGES: u32 = 10;
const TIMEOUT_SEC: u32 = 8;

/// A step that failed is tried again after this, doubling.
const BACKOFF_FIRST: TimeDelta = TimeDelta::minutes(1);
/// ... up to this.
const BACKOFF_MAX: TimeDelta = TimeDelta::minutes(10);
/// A failed step's watcher.log line, at most this often.
const SAY_EVERY: TimeDelta = TimeDelta::minutes(10);

/// The failed-step policy (accepted 2026-10-20): the next step of its kind
/// held back from 1 minute, doubling to 10, until one answers well; one
/// line at most every 10 minutes. It is no fuse strike.
#[derive(Default)]
struct Backoff {
    until: Option<Instant>,
    wait: TimeDelta,
    said_at: Option<Instant>,
}

impl Backoff {
    fn holds(&self, now: Instant) -> bool {
        self.until.is_some_and(|u| now < u)
    }

    /// A step failed at `now`: the next one waits; says whether to log it.
    fn failed(&mut self, now: Instant) -> bool {
        self.wait = if self.wait.is_zero() {
            BACKOFF_FIRST
        } else {
            (self.wait * 2).min(BACKOFF_MAX)
        };
        self.until = Some(now + self.wait);
        let say = self.said_at.is_none_or(|t| now - t >= SAY_EVERY);
        if say {
            self.said_at = Some(now);
        }
        say
    }

    fn ok(&mut self) {
        self.until = None;
        self.wait = TimeDelta::zero();
    }
}

/// The one HTTPS GET: [http::get], or a test's stand-in.
pub type Fetch = fn(&str) -> Result<String, Fail>;

/// What the poll keeps across the loop's passes, beside the caches `w`
/// carries.
pub struct Poller {
    reply: Backoff,
    board: Backoff,
    ps_only_said: bool,
    proxy_auth_said: bool,
    /// a poll's connect was refused by the system ([Fail::Forbidden])
    forbidden: bool,
    fetch: Fetch,
}

impl Default for Poller {
    fn default() -> Poller {
        Poller {
            reply: Backoff::default(),
            board: Backoff::default(),
            ps_only_said: false,
            proxy_auth_said: false,
            forbidden: false,
            fetch: http::get,
        }
    }
}

/// watcher.log's line when the system refuses chatqd its connect.
pub const FORBIDDEN_LINE: &str = "the firewall blocks chatqd, so the PowerShell watcher listens for phone replies instead - allowing chatqd.exe out saves the memory that watcher takes";

/// A step as the loop runs it: op, W, args.
pub type Step<'a> = dyn FnMut(&str, &WatchState, Value) -> Outcome + 'a;

/// `[Uri]::EscapeDataString`: every byte of the UTF-8 but RFC 3986's
/// unreserved characters as `%XX`, upper case.
pub fn escape_data(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
            out.push(char::from(b));
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

/// Where the poll starts: `lastId`, else the state's `since` (0 is none, as
/// PowerShell's `elseif` has it), else a minute ago.
fn since_of(st: &ReplyState, now: Instant) -> String {
    match (&st.last_id, st.since) {
        (Some(id), _) if !id.is_empty() => id.clone(),
        (_, Some(s)) if s != 0 => s.to_string(),
        _ => (now.timestamp() - 60).to_string(),
    }
}

impl Poller {
    /// The live poller: [http::get], or [http::get_forbidden] under the
    /// `connectForbidden` seam.
    pub fn new(seams: &Seams) -> Poller {
        let fetch: Fetch = if seams.connect_forbidden {
            http::get_forbidden
        } else {
            http::get
        };
        Poller {
            fetch,
            ..Poller::default()
        }
    }

    /// A poll's connect was refused by the system: the loop hands the
    /// window to the PS watcher, which that system lets out.
    pub fn forbidden(&self) -> bool {
        self.forbidden
    }

    /// A poller whose fetch is `fetch`, for tests.
    #[cfg(test)]
    fn with_fetch(fetch: Fetch) -> Poller {
        Poller {
            fetch,
            ..Poller::default()
        }
    }

    /// [Invoke-ChatqReplyPoll](src/phone.ps1) `-MinSeconds <min_seconds>`,
    /// the window already found open: how many messages were acted on.
    /// Never fails; a step goes through `step`.
    pub fn poll(
        &mut self,
        ctx: &Ctx,
        w: &mut WatchState,
        min_seconds: u32,
        now: Instant,
        step: &mut Step,
    ) -> u32 {
        let zone = Zone::Local;
        let mut caches = w.poll_caches();
        // (Get-Date) - $script:ChatqReplyPolledAt, by the wall clock
        let min = TimeDelta::seconds(i64::from(min_seconds));
        // a failed step holds back the next step, not the poll: PowerShell
        // polls each pass, so junk is still logged and saved (SPEC 8)
        if caches
            .polled_at
            .is_some_and(|t| zone.wall(now) - zone.wall(t) < min)
        {
            return 0;
        }
        let cfg = read_config(&ctx.p.config(), ctx.fl);
        let rc = replyconfig::read(&cfg, now, ctx.fl);
        if !rc.on {
            return 0;
        }
        let prior = caches.polled_at;
        caches.polled_at = Some(now);
        w.set_poll_caches(&caches);
        let st = match replystate::read(&ctx.p.replies(), ctx.fl, zone) {
            Ok(st) => st,
            Err(e @ StateError::PsOnly(_)) => {
                self.say_ps_only(ctx, &e);
                let args = self.args(json!({"fetch": true}));
                return self.reply_step(ctx, w, args, now, step);
            }
            Err(e) => {
                write_reply_log(&ctx.p.log_dir(), &format!("poll error: {e}"), now, zone);
                return 0;
            }
        };
        let url = self.url(ctx, &rc, &since_of(&st, now));
        let body = (self.fetch)(&url);
        drop(url);
        // the system lets PowerShell out but not chatqd (a firewall that
        // blocks programs by default): this poll did not happen, and the
        // PS watcher the loop hands over to polls at once
        if matches!(body, Err(Fail::Forbidden)) {
            self.forbidden = true;
            caches.polled_at = prior;
            w.set_poll_caches(&caches);
            ctx.wlog(FORBIDDEN_LINE);
            return 0;
        }
        let why;
        let feed = match &body {
            Ok(text) => Feed::Text(text),
            Err(f) => {
                // Deferred: DEFERRED.md "A proxy that asks for credentials"
                if *f == Fail::ProxyAuth && !self.proxy_auth_said {
                    self.proxy_auth_said = true;
                    ctx.dlog("proxy needs authentication");
                }
                why = f.text();
                Feed::Failed(&why)
            }
        };
        // poll_batch moves the caches; a save PowerShell must make takes
        // the batch from the caches as they were
        let before = caches.clone();
        let pass = wire::poll_batch(
            &mut caches,
            &rc.triage(),
            feed,
            now,
            zone,
            &ctx.culture,
            ctx.fl,
        );
        let (log, save) = match pass {
            Pass::Candidate => {
                let text = body.unwrap_or_default();
                let args = self.args(json!({"text": text}));
                return self.reply_step(ctx, w, args, now, step);
            }
            Pass::Done { log, save } => (log, save),
        };
        // the save before the lines: a save PowerShell must make is a step
        // that writes the lines itself
        let failed = match &save {
            Save::LastId { id, tags } => {
                let hours = rc.hours.unwrap_or(0.0);
                let r = replystate::use_state(&ctx.p, hours, now, ctx.fl, zone, |s| {
                    s.last_id = Some(id.clone());
                    s.last_polled_at = Some(now);
                });
                match r {
                    Ok(()) => {
                        caches.saved(tags, now);
                        None
                    }
                    Err(e @ StateError::PsOnly(_)) => {
                        self.say_ps_only(ctx, &e);
                        w.set_poll_caches(&before);
                        let text = body.unwrap_or_default();
                        let args = self.args(json!({"text": text}));
                        return self.reply_step(ctx, w, args, now, step);
                    }
                    Err(e) => Some(format!("could not save where polling got to: {e}")),
                }
            }
            Save::PolledAt => {
                let hours = rc.hours.unwrap_or(0.0);
                let r = replystate::use_state(&ctx.p, hours, now, ctx.fl, zone, |s| {
                    s.last_polled_at = Some(now);
                });
                // any other failure is silent, as PowerShell's; a file only
                // PowerShell reads goes to a step, which saves it there
                if let Err(e @ StateError::PsOnly(_)) = r {
                    self.say_ps_only(ctx, &e);
                    w.set_poll_caches(&before);
                    let text = body.unwrap_or_default();
                    let args = self.args(json!({"text": text}));
                    return self.reply_step(ctx, w, args, now, step);
                }
                None
            }
            Save::None => None,
        };
        let logs = ctx.p.log_dir();
        for line in log.iter().chain(&failed) {
            write_reply_log(&logs, line, now, zone);
        }
        w.set_poll_caches(&caches);
        0
    }

    /// The `reply` step's args: `more` with the loop poll's three.
    fn args(&self, more: Value) -> Value {
        let mut a = json!({"maxMessages": MAX_MESSAGES, "quick": false, "timeoutSec": TIMEOUT_SEC});
        for (k, v) in more.as_object().into_iter().flatten() {
            a[k] = v.clone();
        }
        a
    }

    /// `$rc.Server/$rc.Topic/json?poll=1&since=<since escaped>`, the topic
    /// as it is. The `ntfyBase` seam stands in for the default server only.
    fn url(&self, ctx: &Ctx, rc: &ReplyConfig, since: &str) -> Zeroizing<String> {
        let server = match &ctx.seams.ntfy_base {
            Some(b) if rc.server_default => b.as_str(),
            _ => rc.server.as_str(),
        };
        let topic = rc.topic.as_ref().map_or("", |t| t.as_str());
        let since = escape_data(since);
        Zeroizing::new(format!("{server}/{topic}/json?poll=1&since={since}"))
    }

    /// DEFERRED.md "The reply registry's reads left to PowerShell": said
    /// once in watcher.log.
    fn say_ps_only(&mut self, ctx: &Ctx, e: &StateError) {
        if !self.ps_only_said {
            self.ps_only_said = true;
            ctx.wlog(&format!("{e} - PowerShell steps read the phone's replies"));
        }
    }

    /// One `reply` step over `w`, unless a failed one holds it back: the
    /// batch is then kept, as `lastId` has not moved. Its W is taken whole,
    /// all but `ChatqReplyPolledAt`: chatqd's, set as it polled, stays.
    fn reply_step(
        &mut self,
        ctx: &Ctx,
        w: &mut WatchState,
        args: Value,
        polled_at: Instant,
        step: &mut Step,
    ) -> u32 {
        if self.reply.holds(polled_at) {
            return 0;
        }
        match step("reply", w, args) {
            Outcome::Ok(next, result) => {
                *w = *next;
                let mut c: PollCaches = w.poll_caches();
                c.polled_at = Some(polled_at);
                w.set_poll_caches(&c);
                self.reply.ok();
                let acted = result.get("acted").and_then(Value::as_i64).unwrap_or(0);
                u32::try_from(acted).unwrap_or(0)
            }
            _ => {
                if self.reply.failed(polled_at) {
                    ctx.wlog(
                        "phone replies wait: a reply step failed - tried again in a minute or more",
                    );
                }
                0
            }
        }
    }

    /// [Write-ChatqBoard](src/alerts.ps1) as a `board` step, while only
    /// listening: held back as a failed `reply` step is.
    pub fn board(&mut self, ctx: &Ctx, w: &mut WatchState, now: Instant, step: &mut Step) {
        if self.board.holds(now) {
            return;
        }
        match step("board", w, json!({})) {
            Outcome::Ok(next, _) => {
                *w = *next;
                self.board.ok();
            }
            _ => {
                if self.board.failed(now) {
                    ctx.wlog(
                        "the board waits: a board step failed - tried again in a minute or more",
                    );
                }
            }
        }
    }
}

#[cfg(test)]
#[path = "reply_tests.rs"]
mod tests;
