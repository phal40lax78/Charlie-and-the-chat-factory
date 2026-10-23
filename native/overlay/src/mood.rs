// The mood switch, docs/skin-pack.md section 6's third piece: the
// prototype's moodNow and moodFor (design/skippy/proto/index.html, kept
// local), ported. The true mood comes from the snapshot (State::now); the
// face it wears is the skin's fallback hop (Skin::face), which the
// animator plays (Anim::set_mood) - the two kept apart, so what says the
// mood (the hover card, later) says the true one.
//
// moodNow, as the prototype orders it, for what overlay.json says today:
// a usage window at its limit, the cut-off ask, a chat waiting or a job
// needing input, and the 5 minutes after a window reached its limit are
// sad; 7 s after a chat finishes are pleased; chats at work are ready;
// else idle. Left for the pieces that bring them, each in its place
// below: a line's own mood held while it is said, the report card's smug,
// the roast tally's smug on its hover, and a chat stopped in the last 5
// minutes (the snapshot has no stopped state).
//
// moodFor: a line's base mood, unless one of the moodmap's phrases hits
// it - the first that does, in order; under a lock only angry. Nothing
// calls it yet: the line picker will. native/vectors/skin-moodfor.json
// pins it with synthetic phrases; the tests below run it.

use std::collections::BTreeMap;

use regex::Regex;
use serde_json::Value;

use crate::model::{get, is_in, list, s, t};
use crate::selflog;
use crate::skin::{Mood, Moodmap, Skin};

/// How long a finished chat keeps him pleased (the prototype's finish).
pub const PLEASED_MS: i64 = 7_000;
/// How long he stays sad after a usage window reaches its limit
/// (lastSad).
pub const SAD_MS: i64 = 5 * 60_000;
/// A chat at work, as the prototype's ACTIVE: one of these going idle has
/// finished.
const ACTIVE: [&str; 4] = ["busy", "running", "waiting", "needs-input"];

/// The true mood and the prototype's moodWhy for it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Now {
    pub mood: Mood,
    pub why: &'static str,
}

/// What moodNow remembers between snapshots: each row's status at the
/// last look (None before the first), until when a finish keeps him
/// pleased, and when a usage window last reached its limit.
#[derive(Debug, Default)]
pub struct State {
    was: Option<BTreeMap<String, String>>,
    pleased_until: i64,
    limited: bool,
    last_sad: Option<i64>,
}

fn now(mood: Mood, why: &'static str) -> Now {
    Now { mood, why }
}

/// A usage window at its limit, in any provider's usage.
fn limited(snap: &Value) -> bool {
    get(snap, "header").is_some_and(|h| {
        list(h, "usage")
            .iter()
            .any(|u| list(u, "windows").iter().any(|w| t(w, "limited")))
    })
}

impl State {
    /// The true mood at `now_ms`, epoch ms, from the snapshot: its rows
    /// compared with the last look's first, so call it with each snapshot
    /// drawn - a second look at the same one changes nothing.
    pub fn now(&mut self, snap: &Value, now_ms: i64) -> Now {
        let rows: BTreeMap<String, String> = list(snap, "rows")
            .iter()
            .map(|r| (s(r, "key"), s(r, "status").to_lowercase()))
            .collect();
        if let Some(was) = &self.was {
            let finished = rows.iter().any(|(k, st)| {
                st == "idle" && was.get(k).is_some_and(|w| ACTIVE.contains(&w.as_str()))
            });
            if finished {
                self.pleased_until = now_ms + PLEASED_MS;
            }
        }
        self.was = Some(rows);
        let limit = limited(snap);
        if limit && !self.limited {
            self.last_sad = Some(now_ms);
        }
        self.limited = limit;

        // Hook: a line's own mood, held for its hold time or while its
        // beat or question is open (lineMood) - the line picker's.
        // Hook: the report card up wears smug - the card's.
        if limit {
            return now(Mood::Sad, "a usage window is at its limit");
        }
        if get(snap, "header")
            .and_then(|h| get(h, "ask"))
            .is_some_and(|a| crate::clock::truthy(Some(a)))
        {
            return now(Mood::Sad, "cut-off chats wait for your answer");
        }
        let status = |set: &[&str]| {
            list(snap, "rows")
                .iter()
                .any(|r| is_in(&s(r, "status"), set))
        };
        if status(&["waiting", "needs-input"]) {
            return now(Mood::Sad, "a chat waits for your answer");
        }
        // Hook: a chat stopped in the last 5 minutes is sad too, once the
        // snapshot says stopped.
        if self.last_sad.is_some_and(|at| now_ms - at < SAD_MS) {
            return now(Mood::Sad, "a usage window just reached its limit");
        }
        if now_ms < self.pleased_until {
            return now(Mood::Pleased, "a chat just finished");
        }
        // Hook: smug while his own hover card shows the roast tally.
        if status(&["busy", "running"]) {
            return now(Mood::Ready, "chats are working");
        }
        now(Mood::Idle, "nothing is running")
    }
}

/// One phrase as moodFor tests it: its `match` substrings, then its
/// regexes, those that compiled.
#[derive(Debug)]
#[cfg_attr(not(test), allow(dead_code))]
struct Phrase {
    mood: Mood,
    matches: Vec<String>,
    regex: Vec<Regex>,
}

/// A skin's moodmap phrases, compiled.
#[derive(Debug, Default)]
#[cfg_attr(not(test), allow(dead_code))]
pub struct Phrases(Vec<Phrase>);

/// A regex error's own words, without the pattern the crate quotes.
fn why(e: &regex::Error) -> String {
    let text = e.to_string();
    text.lines()
        .find_map(|l| l.strip_prefix("error: "))
        .or_else(|| text.lines().last())
        .unwrap_or_default()
        .to_string()
}

impl Phrases {
    /// The moodmap's phrases with their regexes compiled. The prototype
    /// reads a leading `(?i)` as JavaScript's `i` flag; the regex crate
    /// takes it as written, as every other construct it has. One it has
    /// not - a look-around, a backreference - leaves that regex out, the
    /// rest of its phrase kept, with a note each.
    pub fn compile(id: &str, map: &Moodmap) -> (Phrases, Vec<String>) {
        let mut notes = Vec::new();
        let list = map
            .phrases
            .iter()
            .map(|p| Phrase {
                mood: p.mood,
                matches: p.matches.clone(),
                regex: p
                    .regex
                    .iter()
                    .filter_map(|r| {
                        Regex::new(r)
                            .map_err(|e| {
                                notes.push(format!(
                                    "skin {id}: moodmap.json: a regex for {} does not compile: {}; skipped",
                                    p.mood.as_str(),
                                    why(&e)
                                ))
                            })
                            .ok()
                    })
                    .collect(),
            })
            .collect();
        (Phrases(list), notes)
    }

    /// [Phrases::compile] for a skin, its notes to the self log.
    pub fn of(skin: &Skin) -> Phrases {
        let (p, notes) = Phrases::compile(skin.id(), &skin.moodmap);
        for n in &notes {
            selflog::line(n);
        }
        p
    }

    /// The prototype's moodFor: the first phrase that hits `text` gives
    /// its mood, else `base`; under `lock` only an angry phrase is tried.
    #[cfg_attr(not(test), allow(dead_code))]
    pub fn mood_for(&self, text: &str, base: Mood, lock: bool) -> Mood {
        self.0
            .iter()
            .filter(|p| !lock || p.mood == Mood::Angry)
            .find(|p| {
                p.matches.iter().any(|m| text.contains(m.as_str()))
                    || p.regex.iter().any(|r| r.is_match(text))
            })
            .map_or(base, |p| p.mood)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::skin::Phrase as Written;
    use serde_json::json;

    const T0: i64 = 1_800_000_000_000;

    fn row(key: &str, status: &str) -> Value {
        json!({ "key": key, "kind": "session", "status": status })
    }

    fn snap(rows: &[Value]) -> Value {
        json!({ "schema": 1, "header": {}, "rows": rows })
    }

    fn limited_snap(rows: &[Value], at_limit: bool) -> Value {
        json!({ "schema": 1, "rows": rows, "header": { "usage": [
            { "provider": "Claude", "windows": [
                { "label": "5h", "percent": if at_limit { 100 } else { 40 }, "limited": at_limit },
                { "label": "week", "percent": 30, "limited": false } ] } ] } })
    }

    fn mood(st: &mut State, snap: &Value, at: i64) -> Mood {
        st.now(snap, at).mood
    }

    /// Nothing running is idle; a chat at work, or a job running, ready.
    #[test]
    fn idle_with_nothing_running_and_ready_while_chats_work() {
        let mut st = State::default();
        assert_eq!(
            st.now(&Value::Null, T0),
            now(Mood::Idle, "nothing is running")
        );
        assert_eq!(mood(&mut st, &snap(&[row("s:1", "idle")]), T0), Mood::Idle);
        assert_eq!(
            st.now(&snap(&[row("s:1", "idle"), row("s:2", "Busy")]), T0),
            now(Mood::Ready, "chats are working")
        );
        assert_eq!(
            mood(&mut st, &snap(&[row("j:3", "running")]), T0),
            Mood::Ready
        );
        assert_eq!(
            mood(&mut st, &snap(&[row("s:4", "queued")]), T0),
            Mood::Idle
        );
        assert_eq!(
            mood(&mut st, &snap(&[row("c:5", "cutoff")]), T0),
            Mood::Idle
        );
    }

    /// A chat busy, then idle: pleased for 7 s from the snapshot that says
    /// so, then the state's mood again. A second look at the same snapshot
    /// does not start the 7 s again.
    #[test]
    fn pleased_for_7_s_after_a_chat_finishes() {
        let mut st = State::default();
        let busy = snap(&[row("s:1", "busy"), row("s:2", "busy")]);
        let one_done = snap(&[row("s:1", "idle"), row("s:2", "busy")]);
        assert_eq!(mood(&mut st, &busy, T0), Mood::Ready);
        assert_eq!(
            st.now(&one_done, T0 + 1000),
            now(Mood::Pleased, "a chat just finished")
        );
        assert_eq!(mood(&mut st, &one_done, T0 + 5000), Mood::Pleased);
        assert_eq!(mood(&mut st, &one_done, T0 + 7999), Mood::Pleased);
        assert_eq!(mood(&mut st, &one_done, T0 + 8000), Mood::Ready);
        let all_done = snap(&[row("s:1", "idle"), row("s:2", "idle")]);
        assert_eq!(mood(&mut st, &all_done, T0 + 9000), Mood::Pleased);
        assert_eq!(mood(&mut st, &all_done, T0 + 15_999), Mood::Pleased);
        assert_eq!(mood(&mut st, &all_done, T0 + 16_000), Mood::Idle);
    }

    /// Only a chat at work going idle has finished: not the first
    /// snapshot's idle chats, not a row that went away, not one cut off,
    /// not a queued one sent. A job needing input that goes idle has.
    #[test]
    fn only_work_going_idle_is_a_finish() {
        let mut st = State::default();
        assert_eq!(mood(&mut st, &snap(&[row("s:1", "idle")]), T0), Mood::Idle);
        assert_eq!(mood(&mut st, &snap(&[row("s:2", "busy")]), T0), Mood::Ready);
        assert_eq!(mood(&mut st, &snap(&[]), T0 + 1000), Mood::Idle, "gone");
        assert_eq!(mood(&mut st, &snap(&[row("s:3", "busy")]), T0), Mood::Ready);
        assert_eq!(
            mood(&mut st, &snap(&[row("s:3", "cutoff")]), T0),
            Mood::Idle
        );
        assert_eq!(mood(&mut st, &snap(&[row("s:3", "idle")]), T0), Mood::Idle);
        assert_eq!(
            mood(&mut st, &snap(&[row("s:4", "queued")]), T0),
            Mood::Idle
        );
        assert_eq!(mood(&mut st, &snap(&[row("s:4", "idle")]), T0), Mood::Idle);
        assert_eq!(
            mood(&mut st, &snap(&[row("j:5", "needs-input")]), T0),
            Mood::Sad
        );
        assert_eq!(
            mood(&mut st, &snap(&[row("j:5", "idle")]), T0),
            Mood::Pleased
        );
    }

    /// A chat waiting, a job needing input, the cut-off ask: sad, before
    /// a finish's pleased and the working chats' ready.
    #[test]
    fn sad_while_a_chat_or_the_ask_waits_for_you() {
        let mut st = State::default();
        let busy = snap(&[row("s:1", "busy"), row("s:2", "busy")]);
        mood(&mut st, &busy, T0);
        let waits = snap(&[row("s:1", "idle"), row("s:2", "waiting")]);
        assert_eq!(
            st.now(&waits, T0),
            now(Mood::Sad, "a chat waits for your answer")
        );
        let mut asked = snap(&[row("s:1", "idle"), row("s:2", "busy")]);
        asked["header"]["ask"] = json!({ "count": 2, "keys": ["k1", "k2"] });
        assert_eq!(
            st.now(&asked, T0 + 1000),
            now(Mood::Sad, "cut-off chats wait for your answer")
        );
        asked["header"]["ask"] = Value::Null;
        assert_eq!(
            mood(&mut st, &asked, T0 + 2000),
            Mood::Pleased,
            "s:1's finish"
        );
        assert_eq!(mood(&mut st, &asked, T0 + 8000), Mood::Ready);
    }

    /// A usage window at its limit is sad while it is, and for 5 minutes
    /// from when it reached it - before everything else.
    #[test]
    fn sad_at_a_limit_and_for_5_minutes_after_it_is_reached() {
        let mut st = State::default();
        let busy = [row("s:1", "busy")];
        assert_eq!(mood(&mut st, &limited_snap(&busy, false), T0), Mood::Ready);
        assert_eq!(
            st.now(&limited_snap(&busy, true), T0 + 1000),
            now(Mood::Sad, "a usage window is at its limit")
        );
        let done = [row("s:1", "idle")];
        assert_eq!(
            mood(&mut st, &limited_snap(&done, true), T0 + 2000),
            Mood::Sad
        );
        assert_eq!(
            st.now(&limited_snap(&done, false), T0 + 3000),
            now(Mood::Sad, "a usage window just reached its limit")
        );
        let late = T0 + 1000 + SAD_MS;
        assert_eq!(
            mood(&mut st, &limited_snap(&done, false), late - 1),
            Mood::Sad
        );
        assert_eq!(mood(&mut st, &limited_snap(&done, false), late), Mood::Idle);
        // still at its limit: the 5 minutes count from when it reached it
        let mut st = State::default();
        mood(&mut st, &limited_snap(&done, true), T0);
        mood(&mut st, &limited_snap(&done, true), T0 + 2 * SAD_MS);
        assert_eq!(
            mood(&mut st, &limited_snap(&done, false), T0 + 2 * SAD_MS + 1),
            Mood::Idle
        );
    }

    fn vectors() -> Value {
        let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../vectors/skin-moodfor.json");
        let text = std::fs::read_to_string(path).expect("native/vectors/skin-moodfor.json");
        serde_json::from_str(&text).unwrap()
    }

    fn strings(v: &Value) -> Vec<String> {
        v.as_array()
            .into_iter()
            .flatten()
            .map(|x| x.as_str().unwrap().to_string())
            .collect()
    }

    fn map_of(v: &Value) -> Moodmap {
        Moodmap {
            phrases: v["phrases"]
                .as_array()
                .unwrap()
                .iter()
                .map(|p| Written {
                    mood: Mood::parse(p["mood"].as_str().unwrap()).unwrap(),
                    matches: strings(&p["match"]),
                    regex: strings(&p["regex"]),
                })
                .collect(),
            ..Moodmap::default()
        }
    }

    /// Every case of skin-moodfor.json: its map's phrases compiled - the
    /// regexes the crate has not left out, as many as the map says - and
    /// moodFor's answer the case's. All mismatches at once.
    #[test]
    fn every_moodfor_vector_answers_as_its_case() {
        let file = vectors();
        let mut maps = BTreeMap::new();
        for (name, m) in file["maps"].as_object().unwrap() {
            let (p, notes) = Phrases::compile("mini", &map_of(m));
            assert_eq!(
                notes.len() as u64,
                m["skipped"].as_u64().unwrap_or(0),
                "{name}: {notes:?}"
            );
            maps.insert(name.clone(), p);
        }
        let cases = file["cases"].as_array().unwrap();
        assert!(cases.len() >= 30, "cases: {}", cases.len());
        let mut bad = Vec::new();
        for c in cases {
            let i = &c["input"];
            let got = maps[i["map"].as_str().unwrap()].mood_for(
                i["text"].as_str().unwrap(),
                Mood::parse(i["base"].as_str().unwrap()).unwrap(),
                i["lock"].as_bool().unwrap_or(false),
            );
            if got.as_str() != c["expect"] {
                bad.push(format!(
                    "'{}': want {} got {}",
                    c["name"].as_str().unwrap(),
                    c["expect"],
                    got.as_str()
                ));
            }
        }
        assert!(bad.is_empty(), "{} differ\n{}", bad.len(), bad.join("\n"));
    }

    /// A regex the crate has not - a look-ahead, a backreference, one that
    /// does not parse - is left out with one note each, naming the mood
    /// and the crate's words but not the pattern; its phrase's other
    /// regexes and its substrings still hit.
    #[test]
    fn a_regex_that_will_not_compile_is_skipped_with_one_note() {
        let map = Moodmap {
            phrases: vec![
                Written {
                    mood: Mood::Angry,
                    matches: vec!["HALT".into()],
                    regex: vec!["calm(?= down)".into(), "(?i)^stop".into()],
                },
                Written {
                    mood: Mood::Sad,
                    matches: vec![],
                    regex: vec!["(ab)\\1".into(), "(xyzzy".into()],
                },
            ],
            ..Moodmap::default()
        };
        let (p, notes) = Phrases::compile("mini", &map);
        assert_eq!(notes.len(), 3, "{notes:?}");
        assert_eq!(
            notes[0],
            "skin mini: moodmap.json: a regex for angry does not compile: \
             look-around, including look-ahead and look-behind, is not supported; skipped"
        );
        assert!(
            notes[1].starts_with("skin mini: moodmap.json: a regex for sad does not compile: ")
        );
        assert!(
            notes[2].ends_with(": unclosed group; skipped"),
            "{}",
            notes[2]
        );
        assert!(
            notes
                .iter()
                .all(|n| !n.contains("xyzzy") && !n.contains("calm") && !n.contains("(ab)"))
        );
        assert_eq!(p.mood_for("Stop it", Mood::Ready, false), Mood::Angry);
        assert_eq!(p.mood_for("HALT", Mood::Ready, true), Mood::Angry);
        assert_eq!(p.mood_for("calm down", Mood::Ready, false), Mood::Ready);
        assert_eq!(p.mood_for("abab", Mood::Idle, false), Mood::Idle);
    }

    /// The default skin's moodmap has no phrases: every line its base.
    #[test]
    fn the_default_skin_has_no_phrases() {
        let p = Phrases::of(&Skin::default());
        assert_eq!(p.0.len(), 0);
        assert_eq!(p.mood_for("No!", Mood::Smug, false), Mood::Smug);
    }
}
