// The panel's side of its contract with the headless host (native/SPEC.md
// "M9: the overlay's snapshot"): the snapshot held, the events shown one
// at a time, and overlay-ui.json written. The panel that draws it all is
// app.rs.
//
// - the snapshot is read once a second; one that does not parse (a write
//   under way, a schema it does not know) leaves the last good one drawn;
// - no new snapshot for 20 s and the panel goes: its host has hung or gone,
//   and a host that is alive starts it again;
// - the host's balloons are shown one at a time, the oldest first, each for
//   its ms (6 s when it gives none), and only one shown that long is seen:
//   two in one snapshot are both shown, and one a restart cut short is
//   shown again by the next panel (Hold). A said - a line on the panel
//   (Add-ChatOverlaySaid) - is the app's: none waits its turn, and the one
//   on the panel is seen only once its time is up or another takes its
//   place, so a restart leaves it to the next panel too (pick_said);
// - overlay-ui.json says the events it has seen, the host's commands it
//   has acted on (done), which the host then drops - so a panel it starts
//   again acts on those it had not (Update-ChatOverlayCommands) - and
//   underWay: the pointer
//   on the panel or a press held there, a drag, the settings box open or an
//   open under way, which a memory or code restart in the host waits for
//   (Test-ChatOverlayUiUnderWay). It is written whole, through a rename.

use std::collections::BTreeSet;
use std::path::Path;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use crate::selflog;
use crate::snapshot::{self, Event, Snapshot};

/// How long the panel holds its last snapshot with no newer one.
pub const STALE: Duration = Duration::from_secs(20);
/// How long an event the host gives no ms for is shown: a balloon's own.
pub const SHOW: Duration = Duration::from_secs(6);

/// How long an event stays on show: its ms, or SHOW.
pub(crate) fn shown_for(e: &Event) -> Duration {
    if e.ms > 0 {
        Duration::from_millis(e.ms as u64)
    } else {
        SHOW
    }
}

/// The last good snapshot and when it came (one whose `at` moved on), the
/// event on show and until when, and the events shown through: seen.
pub struct Hold {
    pub last: Option<Snapshot>,
    pub fresh: Instant,
    pub seen: BTreeSet<String>,
    pub showing: Option<(Event, Instant)>,
}

impl Hold {
    pub fn new(now: Instant) -> Self {
        Hold {
            last: None,
            fresh: now,
            seen: BTreeSet::new(),
            showing: None,
        }
    }

    /// Takes the file's bytes read at `now`; true when there is a new
    /// snapshot to draw.
    pub fn take(&mut self, bytes: Option<&[u8]>, now: Instant) -> bool {
        let Some(Ok(s)) = bytes.map(snapshot::parse) else {
            return false;
        };
        if self.last.as_ref().is_some_and(|l| l.at == s.at) {
            return false;
        }
        if !s.deep.is_empty() {
            selflog::line(&format!("snapshot past Depth 6 at {:?}", s.deep));
        }
        // the ids the host still lists: the rest it has dropped
        let listed = |id: &String| s.events.iter().any(|e| &e.id == id);
        self.seen.retain(listed);
        if self.showing.as_ref().is_some_and(|(e, _)| !listed(&e.id)) {
            self.showing = None;
        }
        self.fresh = now;
        self.last = Some(s);
        true
    }

    /// The event on show moved on at `now`: one shown its time is seen,
    /// and the oldest not yet seen goes up in its place. True when what
    /// is on show changed.
    pub fn tick(&mut self, now: Instant) -> bool {
        let mut changed = false;
        if let Some((e, until)) = &self.showing {
            if now < *until {
                return false;
            }
            self.seen.insert(e.id.clone());
            self.showing = None;
            changed = true;
        }
        let next = self.last.as_ref().and_then(|s| {
            s.events
                .iter()
                .filter(|e| e.kind != "said")
                .filter(|e| !self.seen.contains(&e.id))
                .min_by(|a, b| (a.at, &a.id).cmp(&(b.at, &b.id)))
                .cloned()
        });
        if let Some(e) = next {
            let until = now + shown_for(&e);
            self.showing = Some((e, until));
            changed = true;
        }
        changed
    }

    pub fn stale(&self, now: Instant) -> bool {
        now.duration_since(self.fresh) > STALE
    }
}

pub(crate) fn epoch_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as i64)
}

/// overlay-ui.json's body: {underWay, seen, done, rect} - done the host's
/// command ids acted on, rect the panel's place, screen pixels, the
/// console takes - its `at` put on as it is written.
pub fn ui_json(
    under_way: bool,
    seen: &BTreeSet<String>,
    done: &BTreeSet<i64>,
    rect: [i32; 4],
) -> serde_json::Value {
    serde_json::json!({ "underWay": under_way, "seen": seen, "done": done, "rect": rect })
}

/// The host's saids in a snapshot: the newest not seen, for the panel
/// (App::saids), and the ids of every other, seen as they come. The newest
/// is left unseen: the panel sees it once it has shown its time, or another
/// has taken its place (App::put_said).
pub(crate) fn pick_said<'a>(
    events: &'a [Event],
    seen: &BTreeSet<String>,
) -> (Option<&'a Event>, Vec<String>) {
    let saids = || events.iter().filter(|e| e.kind == "said");
    let newest = saids()
        .filter(|e| !seen.contains(&e.id))
        .max_by(|a, b| (a.at, &a.id).cmp(&(b.at, &b.id)));
    let rest = saids()
        .filter(|e| newest.is_none_or(|x| x.id != e.id))
        .map(|e| e.id.clone())
        .collect();
    (newest, rest)
}

/// Written beside, then renamed over: the host never reads half of it.
pub(crate) fn save(path: &Path, text: &str) {
    let tmp = path.with_extension("json.tmp");
    let done = std::fs::write(&tmp, text).and_then(|_| std::fs::rename(&tmp, path));
    if let Err(e) = done {
        let name = path
            .file_name()
            .map_or(String::new(), |n| n.to_string_lossy().into_owned());
        selflog::line(&format!("{name} not written: {e}"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn snap(at: i64, events: &str) -> Vec<u8> {
        format!(
            r#"{{"schema":1,"at":{at},"header":{{"usageText":"Claude 5h 42%"}},"ui":{{"spin":true}},
            "rows":[{{"key":"s:1","title":"one","stateText":"idle 3m"}},{{"key":"s:2","title":"two"}}],
            "events":[{events}]}}"#
        )
        .into_bytes()
    }

    fn on_show(h: &Hold) -> Option<&str> {
        h.showing.as_ref().map(|(e, _)| e.id.as_str())
    }

    /// A bad read keeps the last good snapshot; only a new `at` is fresh;
    /// 20 s without one is stale.
    #[test]
    fn the_last_good_snapshot_is_held_until_stale() {
        let t0 = Instant::now();
        let mut h = Hold::new(t0);
        assert!(h.take(Some(&snap(5, "")), t0));
        let t1 = t0 + Duration::from_secs(15);
        assert!(!h.take(Some(b"{\"schema\":1,"), t1), "half a file");
        assert!(!h.take(None, t1), "no file");
        assert!(!h.take(Some(&snap(5, "")), t1), "the same at");
        assert_eq!(h.last.as_ref().unwrap().at, 5);
        assert!(!h.stale(t0 + STALE));
        assert!(h.stale(t0 + STALE + Duration::from_millis(1)));
        assert!(h.take(Some(&snap(6, "")), t1));
        assert!(!h.stale(t0 + STALE + Duration::from_millis(1)));
    }

    /// Two events in one snapshot: both shown, the older first, each for
    /// its ms (SHOW when it has none), and seen only once shown through.
    #[test]
    fn every_event_is_shown_before_it_is_seen() {
        let t = Instant::now();
        let mut h = Hold::new(t);
        h.take(
            Some(&snap(
                1,
                r#"{"id":"9-2","at":2,"kind":"balloon","text":"ask","ms":3000},{"id":"9-1","at":1,"kind":"balloon","text":"memory low"}"#,
            )),
            t,
        );
        assert!(h.tick(t));
        assert_eq!(on_show(&h), Some("9-1"), "the older first");
        assert!(h.seen.is_empty(), "on show is not yet seen");
        assert_eq!(
            ui_json(false, &h.seen, &BTreeSet::new(), [1, 2, 3, 4]).to_string(),
            r#"{"underWay":false,"seen":[],"done":[],"rect":[1,2,3,4]}"#
        );
        assert!(
            !h.tick(t + SHOW - Duration::from_millis(1)),
            "still on show"
        );
        let t2 = t + SHOW;
        assert!(h.tick(t2));
        assert_eq!(on_show(&h), Some("9-2"));
        assert_eq!(h.seen.iter().collect::<Vec<_>>(), ["9-1"]);
        assert!(!h.tick(t2 + Duration::from_millis(2999)));
        assert!(h.tick(t2 + Duration::from_millis(3000)));
        assert_eq!(on_show(&h), None);
        assert_eq!(
            ui_json(true, &h.seen, &BTreeSet::from([3, 1]), [1, 2, 3, 4]).to_string(),
            r#"{"underWay":true,"seen":["9-1","9-2"],"done":[1,3],"rect":[1,2,3,4]}"#
        );
        assert!(!h.tick(t2 + Duration::from_secs(9)), "nothing left to show");
    }

    /// A said is the panel's line, not a balloon: it never waits its turn.
    #[test]
    fn a_said_is_never_on_show() {
        let t = Instant::now();
        let mut h = Hold::new(t);
        h.take(
            Some(&snap(
                1,
                r#"{"id":"9-1","at":1,"kind":"said","said":"done","text":"opened 'x'"}"#,
            )),
            t,
        );
        assert!(!h.tick(t));
        assert_eq!(on_show(&h), None);
    }

    /// The newest said not seen is the panel's, left unseen; every other is
    /// seen as it comes, whether older or seen already. None left: nothing.
    #[test]
    fn the_newest_said_waits_to_be_seen() {
        let t = Instant::now();
        let mut h = Hold::new(t);
        h.take(
            Some(&snap(
                1,
                r#"{"id":"9-1","at":1,"kind":"said","text":"old"},{"id":"9-3","at":3,"kind":"said","text":"new"},
                {"id":"9-2","at":2,"kind":"said","text":"mid"},{"id":"9-4","at":4,"kind":"balloon"}"#,
            )),
            t,
        );
        let events = &h.last.as_ref().unwrap().events;
        let (newest, rest) = pick_said(events, &h.seen);
        assert_eq!(newest.map(|e| e.text.as_str()), Some("new"));
        assert_eq!(rest, ["9-1", "9-2"], "the others, and no balloon");
        let seen = BTreeSet::from(["9-3".to_string()]);
        let (newest, rest) = pick_said(events, &seen);
        assert_eq!(
            newest.map(|e| e.id.as_str()),
            Some("9-2"),
            "the newest not seen"
        );
        assert_eq!(rest, ["9-1", "9-3"]);
        let all = BTreeSet::from(["9-1", "9-2", "9-3"].map(String::from));
        let (newest, rest) = pick_said(events, &all);
        assert!(newest.is_none());
        assert_eq!(rest, ["9-1", "9-3", "9-2"]);
    }

    /// Seen and on show follow the host's list: an id it has dropped goes
    /// from both, and a new one waits its turn.
    #[test]
    fn seen_follows_the_hosts_events() {
        let t = Instant::now();
        let mut h = Hold::new(t);
        h.take(Some(&snap(1, r#"{"id":"9-1","at":1,"kind":"balloon"}"#)), t);
        h.tick(t);
        h.tick(t + SHOW);
        assert_eq!(h.seen.iter().collect::<Vec<_>>(), ["9-1"]);
        h.take(
            Some(&snap(
                2,
                r#"{"id":"9-1","at":1,"kind":"balloon"},{"id":"9-2","at":2,"kind":"balloon"}"#,
            )),
            t + SHOW,
        );
        h.tick(t + SHOW);
        assert_eq!(on_show(&h), Some("9-2"));
        h.take(
            Some(&snap(3, r#"{"id":"9-3","at":3,"kind":"balloon"}"#)),
            t + SHOW,
        );
        assert!(h.seen.is_empty(), "9-1 dropped by the host");
        assert_eq!(on_show(&h), None, "9-2 dropped while on show");
        h.tick(t + SHOW);
        assert_eq!(on_show(&h), Some("9-3"));
    }
}
