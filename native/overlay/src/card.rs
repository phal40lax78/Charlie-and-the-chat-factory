// The hover card: what a row says when the pointer rests on its tile, as
// New-ChatOverlayCardContent (src/overlay-windows.ps1) words it - a usage
// gauge's provider line (Add-ChatOverlayUsage), a marker's words, or a
// chat's whose and what - in the outline Set-ChatOverlayCardShape draws
// (model::card_shape). A chat's card is from its model, which the host
// writes to data/card.json on the panel's `card <key>`
// (Get-ChatOverlayCardModel); a gauge's and a marker's are from their rows.
// Each line goes where WPF's StackPanel and Grid put it; a TextBlock of runs
// in more than one colour is set run by run (line, flow), its runs on one
// baseline.

use serde_json::Value;

use crate::art::Shape;
use crate::clock::{self, Wall};
use crate::look::Look;
use crate::model::{self, ClockSpec, DOT, eq, get, is_in, s, t};
use crate::panel::Said;
use crate::scene::{self, Draw, Font, Measure, Prim};

/// The card window's width: the body's and its tail's.
pub const WIDTH: f64 = model::CARD_WIDTH + model::CARD_TAIL;
const TAIL: f64 = model::CARD_TAIL;
// the body's padding (12, 9, 12, 10), and what it leaves for the words
const PAD_X: f64 = 12.0;
const PAD_TOP: f64 = 9.0;
const PAD_BOTTOM: f64 = 10.0;
const INNER: f64 = model::CARD_WIDTH - 2.0 * PAD_X;
// the grid's word column
const WORD_W: f64 = 64.0;
// a gauge's card: its provider's column, and the status's margin
const NAME_W: f64 = 56.0;
const END_GAP: f64 = 8.0;

/// What a card is for, and when.
pub struct In<'a> {
    pub row: &'a Value,
    /// a chat's model as data/card.json has it (Get-ChatOverlayCardModel)
    pub model: Option<&'a Value>,
    /// the chip's last open or delete, said on the card of the chat it is
    /// about
    pub said: Option<&'a Said>,
    pub look: &'static Look,
    pub opacity: f64,
    pub now_ms: i64,
    pub wall: Wall<'a>,
}

/// A card laid out: its words from the corner of its body's padding, and
/// its window's height.
pub struct Card {
    prims: Vec<Prim>,
    pub height: f64,
    /// a gauge's, under its row (model::card_placement's `below`)
    pub below: bool,
}

/// The card for a row: None for a row no card is for (model::card_row),
/// or a chat's whose model has not come.
pub fn build(inp: &In, m: &dyn Measure) -> Option<Card> {
    let row = inp.row;
    if !model::card_row(row) {
        return None;
    }
    let mut d = Draw::new(inp.opacity);
    let (h, below) = if eq(&s(row, "kind"), "usage") {
        (
            usage(&mut d, m, inp, get(row, "usage").filter(|u| u.is_object())?),
            true,
        )
    } else if let Some((word, tone, text)) = model::notice_model(row) {
        (notice(&mut d, m, inp.look, &word, &tone, &text), false)
    } else {
        (
            chat(&mut d, m, inp, inp.model.filter(|v| v.is_object())?),
            false,
        )
    };
    let tail = if below { TAIL } else { 0.0 };
    Some(Card {
        prims: d.prims,
        height: tail + PAD_TOP + h + PAD_BOTTOM,
        below,
    })
}

/// The card drawn where it was put (model::card_placement): its outline,
/// filled 'frame' and edged 'trim', its tail toward the row - `tip` units
/// down the side that faces it, or across the top or, `above`, the foot of
/// a gauge's - and its words in the body. The tip as drawn comes back too:
/// the outline keeps it off the body's corners.
pub fn face(
    card: &Card,
    look: &Look,
    opacity: f64,
    left: bool,
    above: bool,
    tip: f64,
) -> (Vec<Prim>, f64) {
    let mut d = Draw::new(opacity);
    let mut drawn = tip;
    if let Some((cmds, at)) = model::card_shape(left, tip, card.height, card.below, above) {
        drawn = at;
        d.add_opt(scene::path(
            &Shape::parse(&cmds),
            look.argb("frame"),
            look.argb("trim"),
            1.0,
            false,
            false,
        ));
    }
    // the body at the window's left, but past the tail on the panel's right
    // of it, and under or over a gauge's
    let (bx, by) = if card.below {
        (0.0, if above { 0.0 } else { TAIL })
    } else if left {
        (0.0, 0.0)
    } else {
        (TAIL, 0.0)
    };
    for p in &card.prims {
        let mut p = p.clone();
        p.x += (bx + PAD_X) as f32;
        p.y += (by + PAD_TOP) as f32;
        d.prims.push(p);
    }
    (d.prims, drawn)
}

/// data/card.json's model, when it is for `key`: what the host wrote for
/// the panel's last `card <key>`.
pub fn model_of(json: &str, key: &str) -> Option<Value> {
    let v: Value = serde_json::from_str(json.trim_start_matches('\u{feff}')).ok()?;
    if v.get("key").and_then(Value::as_str) != Some(key) {
        return None;
    }
    v.get("model").filter(|m| m.is_object()).cloned()
}

/// A run of a TextBlock's: its text, colour and font.
struct Run {
    text: String,
    color: u32,
    font: Font,
}

fn run(text: impl Into<String>, color: u32, font: Font) -> Run {
    Run {
        text: text.into(),
        color,
        font,
    }
}

/// Where a run's top goes on a line `line` tall when it is `h`: its
/// baseline on the line's, Segoe UI's ascent 0.811 of its line.
fn sink(line: f64, h: f64) -> f64 {
    0.811 * (line - h).max(0.0)
}

/// A space's width in `font`.
fn space(m: &dyn Measure, font: Font) -> f64 {
    let (a, _) = m.size("x        x", font, None, 0);
    let (b, _) = m.size("xx", font, None, 0);
    ((a - b) / 8.0).max(0.0)
}

/// A text's width with its trailing spaces, which a line keeps before what
/// follows - counted here, as a measure may leave them out.
fn width(m: &dyn Measure, text: &str, font: Font) -> f64 {
    let body = text.trim_end_matches(' ');
    let n = (text.len() - body.len()) as f64;
    let w = if body.is_empty() {
        0.0
    } else {
        m.size(body, font, None, 0).0
    };
    w + n * space(m, font)
}

/// One trimmed TextBlock of runs at (x, y), `w` wide: each run after the
/// last on their baseline, the one that runs past `w` cut there with an
/// ellipsis, any after it gone. Its height: its tallest run's, or a line of
/// its own font, `base`, when it has none.
fn line(d: &mut Draw, m: &dyn Measure, runs: &[Run], base: Font, x: f64, y: f64, w: f64) -> f64 {
    let runs: Vec<&Run> = runs.iter().filter(|r| !r.text.is_empty()).collect();
    let h = if runs.is_empty() {
        m.size("", base, None, 0).1
    } else {
        runs.iter()
            .map(|r| m.size(&r.text, r.font, None, 0).1)
            .fold(0.0, f64::max)
    };
    let mut cx = 0.0;
    for r in runs {
        let room = w - cx;
        if room <= 0.0 {
            break;
        }
        let rh = m.size(&r.text, r.font, None, 0).1;
        d.add(scene::text(
            x + cx,
            y + sink(h, rh),
            room,
            rh,
            &r.text,
            r.color,
            r.font,
            false,
            0,
            0,
        ));
        cx += width(m, &r.text, r.font);
    }
    h
}

/// A text cut into words, each with the spaces after it; spaces that
/// start it a piece of their own.
fn pieces(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut gap = false;
    for (i, c) in text.char_indices() {
        if c == ' ' {
            gap = true;
        } else if gap {
            out.push(&text[start..i]);
            start = i;
            gap = false;
        }
    }
    if start < text.len() {
        out.push(&text[start..]);
    }
    out
}

/// A wrapping TextBlock of runs at (x, y), `w` wide: broken after a space,
/// as WPF breaks a line, each line's runs on their baseline. Its height.
fn flow(d: &mut Draw, m: &dyn Measure, runs: &[Run], base: Font, x: f64, y: f64, w: f64) -> f64 {
    // each line's pieces, those of one run together: (run, text)
    let mut lines: Vec<Vec<(usize, String)>> = vec![Vec::new()];
    let mut cx = 0.0;
    for (i, r) in runs.iter().enumerate() {
        for p in pieces(&r.text) {
            let body = p.trim_end_matches(' ');
            let need = if body.is_empty() {
                0.0
            } else {
                m.size(body, r.font, None, 0).0
            };
            if cx > 0.0 && cx + need > w {
                lines.push(Vec::new());
                cx = 0.0;
            }
            let at = lines.last_mut().expect("a line");
            match at.last_mut() {
                Some((j, t)) if *j == i => t.push_str(p),
                _ => at.push((i, p.to_string())),
            }
            cx += width(m, p, r.font);
        }
    }
    let mut y0 = y;
    for segs in lines {
        let h = if segs.is_empty() {
            m.size("", base, None, 0).1
        } else {
            segs.iter()
                .map(|(i, t)| m.size(t, runs[*i].font, None, 0).1)
                .fold(0.0, f64::max)
        };
        let mut cx = 0.0;
        for (i, t) in &segs {
            let r = &runs[*i];
            let rh = m.size(t, r.font, None, 0).1;
            d.add(scene::text(
                x + cx,
                y0 + sink(h, rh),
                (w - cx).max(1.0),
                rh,
                t,
                r.color,
                r.font,
                false,
                0,
                0,
            ));
            cx += width(m, t, r.font);
        }
        y0 += h;
    }
    y0 - y
}

/// A rule across the body: 1 high in 'edge', 7 under what is over it and
/// 6 over what comes next. Where that starts.
fn rule(d: &mut Draw, look: &Look, y: f64) -> f64 {
    d.add(scene::rect(
        0.0,
        y + 7.0,
        INNER,
        1.0,
        0.0,
        look.argb("edge"),
        0,
        0.0,
    ));
    y + 14.0
}

/// Add-ChatOverlayUsage: a gauge's provider in one line - its name, each
/// window's percent and one reset time, and at the end when the figure is
/// from. Its height.
fn usage(d: &mut Draw, m: &dyn Measure, inp: &In, u: &Value) -> f64 {
    let look = inp.look;
    let f12 = Font::new(12.0);
    let stale = t(u, "stale");
    let y = 1.0;
    let name = s(u, "provider");
    let nf = f12.bold();
    let nh = m.size(&name, nf, None, 0).1;
    d.add(scene::text(
        0.0,
        y,
        NAME_W,
        nh,
        &name,
        look.argb(if stale { "faint" } else { "text" }),
        nf,
        false,
        0,
        0,
    ));
    let ef = Font::new(11.0);
    let status = s(u, "status");
    let (sw, sh) = m.size(&status, ef, None, 0);
    let all: &[Value] = match get(u, "windows") {
        Some(Value::Array(a)) => a,
        Some(v) if clock::truthy(Some(v)) => std::slice::from_ref(v),
        _ => &[],
    };
    let resets = clock::reset_window(all, inp.now_ms);
    let mut runs = Vec::new();
    for (i, w) in model::list(u, "windows").into_iter().enumerate() {
        if i > 0 {
            runs.push(run(format!(" {DOT} "), look.argb("faint"), f12));
        }
        runs.push(run(format!("{} ", s(w, "label")), look.argb("dim"), f12));
        // normal reads as plain text; only warning and worse take a colour
        let sev = s(w, "severity");
        let pc = if stale {
            "faint"
        } else if t(w, "limited") {
            "critical"
        } else if is_in(&sev, &["warning", "critical"]) {
            sev.as_str()
        } else {
            "text"
        };
        runs.push(run(
            format!("{}%", s(w, "percent")),
            look.argb(pc),
            f12.bold(),
        ));
        if resets.as_deref().is_some_and(|r| eq(&s(w, "label"), r)) && t(w, "resetsAt") {
            let at = clock::reset_at(clock::ms_of(get(w, "resetsAt")), inp.now_ms, inp.wall);
            if !at.is_empty() {
                let c = if t(w, "limited") { "critical" } else { "dim" };
                runs.push(run(format!(" resets {at}"), look.argb(c), f12));
            }
        }
    }
    let mid = flow(d, m, &runs, f12, NAME_W, y, INNER - NAME_W - END_GAP - sw);
    let h = nh.max(sh).max(mid);
    d.add(scene::text(
        INNER - sw,
        y + (h - sh) / 2.0,
        sw,
        sh,
        &status,
        look.argb("faint"),
        ef,
        false,
        0,
        0,
    ));
    y + h + 1.0
}

/// A marker's card: its word in its tone's colour, then its words in full,
/// a line each, wrapped - the first in the text's colour, the rest dim.
fn notice(d: &mut Draw, m: &dyn Measure, look: &Look, word: &str, tone: &str, text: &str) -> f64 {
    let wf = Font::new(10.0).bold();
    let wh = m.size(word, wf, None, 0).1;
    d.add(scene::text(
        0.0,
        0.0,
        INNER,
        wh,
        word,
        look.argb(tone),
        wf,
        false,
        0,
        0,
    ));
    let mut y = wh;
    for (i, ln) in text.split('\n').filter(|l| !l.is_empty()).enumerate() {
        let first = i == 0;
        let f = Font::new(if first { 12.0 } else { 11.0 });
        y += if first { 2.0 } else { 3.0 };
        let h = m.size(ln, f, Some(INNER), 0).1;
        d.add(scene::text(
            0.0,
            y,
            INNER,
            h,
            ln,
            look.argb(if first { "text" } else { "dim" }),
            f,
            true,
            0,
            0,
        ));
        y += h;
    }
    y
}

/// A line of the chat card's grid: `word` in the word column, in its
/// colour, centred on the line, the value `top` down and `h` tall. The
/// line's height.
#[allow(clippy::too_many_arguments)]
fn grid_word(
    d: &mut Draw,
    m: &dyn Measure,
    look: &Look,
    word: &str,
    color: &str,
    y: f64,
    top: f64,
    h: f64,
) -> f64 {
    let wf = Font::new(10.0).bold();
    let wh = m.size(word, wf, None, 0).1;
    let tall = h.max(if word.is_empty() { 0.0 } else { wh });
    if !word.is_empty() {
        d.add(scene::text(
            0.0,
            y + top + (tall - wh) / 2.0,
            WORD_W,
            wh,
            word,
            look.argb(color),
            wf,
            false,
            0,
            0,
        ));
    }
    top + tall
}

/// A chat's card: whose it is - its project, its title held to two lines,
/// what its state says that the state line does not, the chip's last word
/// about it - then a grid of what it does now, the calls before and its
/// todo list's count, each under a word; then your prompt and Claude's
/// reply, each held to a few lines.
fn chat(d: &mut Draw, m: &dyn Measure, inp: &In, md: &Value) -> f64 {
    let look = inp.look;
    let c = |n: &str| look.argb(n);
    let (f12, f11) = (Font::new(12.0), Font::new(11.0));
    let mut y = 0.0;
    let (project, title) = (s(md, "Project"), s(md, "Title"));
    if !project.is_empty() || !title.is_empty() {
        if !project.is_empty() {
            y += line(
                d,
                m,
                &[run(project, c("project"), f12.bold())],
                f12,
                0.0,
                y,
                INNER,
            );
        }
        if !title.is_empty() {
            let h = m.size(&title, f12, Some(INNER), 2).1;
            d.add(scene::text(
                0.0,
                y,
                INNER,
                h,
                &title,
                c("text"),
                f12,
                true,
                2,
                0,
            ));
            y += h;
        }
        let words = model::card_words(inp.row, &s(md, "What"));
        if !words.is_empty() {
            y += 1.0;
            y += line(d, m, &[run(words, c("dim"), f11)], f11, 0.0, y, INNER);
        }
        let key = s(inp.row, "key");
        if let Some(said) = inp
            .said
            .filter(|x| !x.about.is_empty() && eq(&x.about, &key))
        {
            y += 2.0;
            let h = m.size(&said.text, f11, Some(INNER), 0).1;
            d.add(scene::text(
                0.0,
                y,
                INNER,
                h,
                &said.text,
                c(&said.tone),
                f11,
                true,
                0,
                0,
            ));
            y += h;
        }
        y = rule(d, look, y);
    }
    // what it does now: a call at work after a mark in its state's colour,
    // one it asks to make in waiting's; or words; or, done for now, when -
    // a call's clock at the line's end
    let (tone, tool, what, at) = (s(md, "Tone"), s(md, "Tool"), s(md, "What"), s(md, "At"));
    let from = clock::ms_of(get(md, "From"));
    let mut vw = INNER - WORD_W;
    let mut ck = None;
    if !tool.is_empty()
        && let Some(from) = from
    {
        let spec = ClockSpec {
            from: Some(from),
            to: None,
            hold: false,
            live: true,
        };
        let text = model::format_row_clock(&spec, inp.now_ms)
            .trim()
            .to_string();
        let (cw, ch) = m.size(&text, f11, None, 0);
        vw -= cw + END_GAP;
        ck = Some((text, cw, ch));
    }
    let mut runs = Vec::new();
    if !tool.is_empty() {
        if is_in(&tone, &["busy", "running"]) {
            runs.push(run("\u{25B6} ", c(&tone), Font::new(9.0).symbol()));
        }
        runs.push(run(
            tool,
            c(if eq(&tone, "waiting") {
                "waiting"
            } else {
                "text"
            }),
            f12.bold(),
        ));
        if !what.is_empty() {
            runs.push(run(format!("  {what}"), c("text"), f12));
        }
    } else if !what.is_empty() {
        runs.push(run(what, c("text"), f12));
    } else if !at.is_empty() {
        runs.push(run(at, c("dim"), f12));
    }
    let mut h = line(d, m, &runs, f12, WORD_W, y, vw);
    if let Some((text, cw, ch)) = ck {
        h = h.max(ch);
        d.add(scene::text(
            INNER - cw,
            y + (h - ch) / 2.0,
            cw,
            ch,
            &text,
            c("dim"),
            f11,
            false,
            0,
            0,
        ));
    }
    y += grid_word(d, m, look, &s(md, "Label"), &tone, y, 0.0, h);
    for (i, st) in model::list(md, "Steps").into_iter().enumerate() {
        let mut runs = vec![run(s(st, "Tool"), c("dim"), f11.bold())];
        let w = s(st, "What");
        if !w.is_empty() {
            runs.push(run(format!("  {w}"), c("dim"), f11));
        }
        let h = line(d, m, &runs, f11, WORD_W, y + 2.0, INNER - WORD_W);
        y += grid_word(
            d,
            m,
            look,
            if i == 0 { "EARLIER" } else { "" },
            "faint",
            y,
            2.0,
            h,
        );
    }
    let tasks = s(md, "Tasks");
    if !tasks.is_empty() {
        let h = line(
            d,
            m,
            &[run(tasks, c("text"), f12)],
            f12,
            WORD_W,
            y + 2.0,
            INNER - WORD_W,
        );
        y += grid_word(d, m, look, "TASKS", "faint", y, 2.0, h);
    }
    // yours you know; Claude's is the news
    for (i, u) in model::list(md, "Turns").into_iter().enumerate() {
        if i == 0 {
            y = rule(d, look, y);
        } else {
            y += 6.0;
        }
        let (who, when) = (s(u, "Who"), s(u, "At"));
        let head = if when.is_empty() {
            who.clone()
        } else {
            format!("{who} {DOT} {when}")
        };
        let hf = Font::new(10.0).bold();
        let hh = m.size(&head, hf, None, 0).1;
        d.add(scene::text(
            0.0,
            y,
            INNER,
            hh,
            &head,
            c("faint"),
            hf,
            false,
            0,
            0,
        ));
        y += hh + 1.0;
        let you = eq(&who, "YOU");
        let lines = if you { 3 } else { 5 };
        let text = s(u, "Text");
        let th = m.size(&text, f12, Some(INNER), lines).1;
        d.add(scene::text(
            0.0,
            y,
            INNER,
            th,
            &text,
            c(if you { "dim" } else { "text" }),
            f12,
            true,
            lines,
            0,
        ));
        y += th;
    }
    y
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look::look;
    use crate::scene::Fixed;
    use chrono::{DateTime, NaiveDateTime, Utc};
    use serde_json::json;

    const NOW: i64 = 1_760_000_000_000;

    fn utc(ms: i64) -> NaiveDateTime {
        DateTime::<Utc>::from_timestamp_millis(ms)
            .unwrap()
            .naive_utc()
    }

    fn input<'a>(row: &'a Value, model: Option<&'a Value>, wall: Wall<'a>) -> In<'a> {
        In {
            row,
            model,
            said: None,
            look: look("dark"),
            opacity: 1.0,
            now_ms: NOW,
            wall,
        }
    }

    fn texts(c: &Card) -> Vec<String> {
        c.prims
            .iter()
            .filter(|p| p.kind == 1)
            .map(|p| p.text.to_string())
            .collect()
    }

    fn gauge(stale: bool) -> Value {
        json!({ "key": "usage:claude", "kind": "usage", "provider": "Claude", "usage": {
            "provider": "Claude", "status": "2m ago", "stale": stale, "windows": [
                { "label": "5h", "percent": 42, "severity": "normal", "resetsAt": NOW + 3_600_000 },
                { "label": "week", "percent": 100, "severity": "critical", "limited": true, "resetsAt": NOW + 7_200_000 },
                { "label": "opus", "percent": 81, "severity": "warning", "resetsAt": NOW + 600_000 }] } })
    }

    fn chat_row() -> Value {
        json!({ "key": "s:1", "kind": "session", "provider": "claude", "status": "busy", "project": "charlie",
            "title": "Fix the build", "stateWords": "edits card.rs \u{00B7} working", "since": NOW - 65_000 })
    }

    fn chat_model() -> Value {
        json!({ "Project": "charlie", "Title": "Fix the build on the release branch, then ship it to everyone who asked",
            "Label": "NOW", "Tone": "busy", "Tool": "Bash", "What": "cargo test -j 2", "From": NOW - 65_000, "At": "",
            "Steps": [{ "Tool": "Read", "What": "src/main.rs" }, { "Tool": "Edit", "What": "src/card.rs" }],
            "Tasks": "2 of 5 \u{00B7} Write the card",
            "Turns": [
                { "Who": "YOU", "At": "13:02", "Text": "Port the hover card, every kind of it, and test each against a golden picture of its own." },
                { "Who": "CLAUDE", "At": "13:03", "Text": "The card is in card.rs: the usage line, the marker's words and a chat's state, steps and turns, each in WPF's places." }] })
    }

    #[test]
    fn a_gauges_card_hangs_under_it_with_one_reset_time() {
        let row = gauge(false);
        let wall = |ms| utc(ms);
        let c = build(&input(&row, None, &wall), &Fixed).unwrap();
        assert!(c.below);
        // one reset: the latest of those at their limit, NOW being 08:53
        // UTC; the line wraps before opus, 209 units from the name to the
        // status
        assert_eq!(
            texts(&c),
            [
                "Claude",
                "5h ",
                "42%",
                " \u{00B7} ",
                "week ",
                "100%",
                " resets 10:53",
                " \u{00B7} ",
                "opus ",
                "81%",
                "2m ago"
            ]
        );
        let opus = c.prims.iter().find(|p| p.text == "opus ").unwrap();
        assert_eq!((opus.x, opus.y), (56.0, 17.0));
        // the tail's 7, the padding's 19, two lines of 16 and their margins
        assert_eq!(c.height, 7.0 + 19.0 + 1.0 + 32.0 + 1.0);
        // the percent of a window at its limit in critical's colour
        let crit = look("dark").argb("critical");
        assert!(
            c.prims
                .iter()
                .any(|p| p.text == "100%" && p.fill == slint::Color::from_argb_encoded(crit))
        );
    }

    #[test]
    fn a_stale_gauges_card_greys_its_name_and_percents() {
        let row = gauge(true);
        let wall = |ms| utc(ms);
        let c = build(&input(&row, None, &wall), &Fixed).unwrap();
        let faint = slint::Color::from_argb_encoded(look("dark").argb("faint"));
        assert!(
            c.prims
                .iter()
                .filter(|p| p.text.ends_with('%'))
                .all(|p| p.fill == faint)
        );
        assert_eq!(c.prims[0].fill, faint);
    }

    #[test]
    fn a_markers_card_says_its_word_then_each_line() {
        let row = json!({ "key": "notice:memory", "kind": "notice", "word": "MEMORY", "tone": "warn",
            "text": "memory is short\n\nclose a window" });
        let wall = |ms| utc(ms);
        let c = build(&input(&row, None, &wall), &Fixed).unwrap();
        assert!(!c.below);
        assert_eq!(texts(&c), ["MEMORY", "memory is short", "close a window"]);
        // 14 the word, 2 + 16 the first line, 3 + 15 the next
        assert_eq!(c.height, 19.0 + 14.0 + 2.0 + 16.0 + 3.0 + 15.0);
        assert_eq!(c.prims[2].size, 11.0);
    }

    #[test]
    fn a_chats_card_waits_for_its_model() {
        let row = chat_row();
        let wall = |ms| utc(ms);
        assert!(build(&input(&row, None, &wall), &Fixed).is_none());
        let tile = json!({ "key": "x", "kind": "nothing" });
        let md = chat_model();
        assert!(build(&input(&tile, Some(&md), &wall), &Fixed).is_none());
    }

    #[test]
    fn a_chats_card_says_whose_what_and_the_turns() {
        let row = chat_row();
        let md = chat_model();
        let wall = |ms| utc(ms);
        let said = Said {
            kind: "done".into(),
            tone: "dim".into(),
            text: "opened 'Fix the build'".into(),
            about: "s:1".into(),
        };
        let mut inp = input(&row, Some(&md), &wall);
        inp.said = Some(&said);
        let c = build(&inp, &Fixed).unwrap();
        let t = texts(&c);
        assert_eq!(t[0], "charlie");
        assert!(t.contains(&"edits card.rs".to_string()));
        assert!(t.contains(&"opened 'Fix the build'".to_string()));
        // the mark, the call and its words, the clock, the word
        let at = t.iter().position(|x| x == "\u{25B6} ").unwrap();
        assert_eq!(
            &t[at..at + 5],
            ["\u{25B6} ", "Bash", "  cargo test -j 2", "1:05", "NOW"]
        );
        assert_eq!(t.iter().filter(|x| *x == "EARLIER").count(), 1);
        assert!(t.contains(&"TASKS".to_string()));
        assert!(t.contains(&"YOU \u{00B7} 13:02".to_string()));
        let you = c.prims.iter().find(|p| p.text.starts_with("Port")).unwrap();
        assert_eq!(you.lines, 3);
        let claude = c
            .prims
            .iter()
            .find(|p| p.text.starts_with("The card"))
            .unwrap();
        assert_eq!(claude.lines, 5);
        // a said line about another chat stays off this card
        let other = Said {
            about: "s:2".into(),
            ..said.clone()
        };
        inp.said = Some(&other);
        assert!(
            !texts(&build(&inp, &Fixed).unwrap()).contains(&"opened 'Fix the build'".to_string())
        );
    }

    #[test]
    fn a_trimmed_line_cuts_the_run_that_runs_past_it() {
        let mut d = Draw::new(1.0);
        let f = Font::new(12.0);
        let runs = [run("abcd ", 0, f), run("efghijkl", 0, f), run("mn", 0, f)];
        // 30 + 6 for the first, the second at 36 given the 24 left
        let h = line(&mut d, &Fixed, &runs, f, 0.0, 0.0, 60.0);
        assert_eq!(h, 16.0);
        assert_eq!(d.prims.len(), 2);
        assert_eq!((d.prims[1].x, d.prims[1].w), (30.0, 30.0));
    }

    #[test]
    fn a_flow_breaks_after_a_space() {
        let mut d = Draw::new(1.0);
        let f = Font::new(12.0);
        let runs = [run("aa bb ", 0, f), run("cc", 0, f)];
        let h = flow(&mut d, &Fixed, &runs, f, 0.0, 0.0, 40.0);
        // "aa bb " is 36 with its spaces, "cc" goes to the next line
        assert_eq!(h, 32.0);
        let at: Vec<(String, f32, f32)> = d
            .prims
            .iter()
            .map(|p| (p.text.to_string(), p.x, p.y))
            .collect();
        assert_eq!(
            at,
            [
                ("aa bb ".to_string(), 0.0, 0.0),
                ("cc".to_string(), 0.0, 16.0)
            ]
        );
        assert_eq!(pieces(" \u{00B7} x  y"), [" ", "\u{00B7} ", "x  ", "y"]);
    }

    #[test]
    fn the_face_puts_the_body_by_its_tail() {
        let row = json!({ "key": "notice:m", "kind": "notice", "word": "W", "tone": "warn", "text": "t" });
        let wall = |ms| utc(ms);
        let c = build(&input(&row, None, &wall), &Fixed).unwrap();
        let lk = look("dark");
        let (left, _) = face(&c, lk, 1.0, true, false, 20.0);
        let (right, tip) = face(&c, lk, 1.0, false, false, 1.0);
        assert_eq!(left[0].kind, 2);
        assert_eq!(left[1].x, 12.0);
        assert_eq!(right[1].x, 19.0);
        // held off the corner: the radius and the tail's half
        assert_eq!(tip, 14.0);
        let g = gauge(false);
        let u = build(&input(&g, None, &wall), &Fixed).unwrap();
        let (below, _) = face(&u, lk, 1.0, false, false, 100.0);
        let (above, _) = face(&u, lk, 1.0, false, true, 100.0);
        assert_eq!((below[1].x, below[1].y), (12.0, 7.0 + 9.0 + 1.0));
        assert_eq!(above[1].y, 9.0 + 1.0);
    }

    #[test]
    fn the_cards_model_is_the_one_for_its_key() {
        let j = r#"{"key":"s:1","at":1,"model":{"Label":"NOW"}}"#;
        assert_eq!(model_of(j, "s:1").unwrap()["Label"], "NOW");
        assert!(model_of(j, "s:2").is_none());
        assert!(model_of(r#"{"key":"s:1","at":1,"model":null}"#, "s:1").is_none());
        assert!(model_of("not json", "s:1").is_none());
    }

    // ---- the real measure, and golden pictures

    #[test]
    fn slints_measure_counts_a_texts_leading_spaces() {
        // line() and flow() count trailing spaces themselves, and rely on
        // the measure for the leading ones
        let (scene_, _win) = scene::golden::scene();
        let m = scene::Measurer::new(&scene_);
        let f = Font::new(12.0);
        let (a, _) = m.size("x", f, None, 0);
        let (b, _) = m.size("  x", f, None, 0);
        assert!(b > a + 4.0, "{a} {b}");
        assert!(space(&m, f) > 2.0);
    }

    fn golden(
        name: &str,
        row: &Value,
        model: Option<&Value>,
        theme: &str,
        left: bool,
        above: bool,
        tip: f64,
    ) {
        let (scene_, win) = scene::golden::scene();
        let m = scene::Measurer::new(&scene_);
        let wall = |ms| utc(ms);
        let said = Said {
            kind: "done".into(),
            tone: "dim".into(),
            text: "opened 'Fix the build'".into(),
            about: "s:1".into(),
        };
        let mut inp = input(row, model, &wall);
        inp.look = look(theme);
        inp.said = Some(&said);
        let c = build(&inp, &m).unwrap();
        let (prims, _) = face(&c, inp.look, 1.0, left, above, tip);
        let (w, h) = (WIDTH as u32, c.height.ceil() as u32);
        scene::show(&scene_, prims);
        let rgb = scene::golden::render(&scene_, &win, w, h);
        scene::golden::check(name, w, h, &rgb);
    }

    #[test]
    fn golden_card_usage_below() {
        golden(
            "card-usage-below",
            &gauge(false),
            None,
            "dark",
            false,
            false,
            60.0,
        );
    }

    #[test]
    fn golden_card_usage_above_light() {
        golden(
            "card-usage-above-light",
            &gauge(true),
            None,
            "light",
            false,
            true,
            250.0,
        );
    }

    #[test]
    fn golden_card_notice_left() {
        let row = json!({ "key": "ask", "kind": "ask", "word": "CONTINUE?", "tone": "cutoff",
            "text": "the limit was over at 13:00 \u{00B7} 2 can continue\nFix the build\nPort the card" });
        golden("card-notice-left", &row, None, "dark", true, false, 20.0);
    }

    #[test]
    fn golden_card_chat_right() {
        golden(
            "card-chat-right",
            &chat_row(),
            Some(&chat_model()),
            "dark",
            false,
            false,
            30.0,
        );
    }

    #[test]
    fn golden_card_chat_left_light() {
        golden(
            "card-chat-left-light",
            &chat_row(),
            Some(&chat_model()),
            "light",
            true,
            false,
            200.0,
        );
    }
}
