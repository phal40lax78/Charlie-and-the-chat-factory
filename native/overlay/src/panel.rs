// The panel's face, as Update-ChatOverlayView draws it
// (src/overlay-windows.ps1): its frame, then a stack of items placed as
// WPF's StackPanel places them, margins and all - the mascot (the native
// panel's own, which the WPF one never had: a frame of the skin's atlas,
// anim.rs), the usage gauges, the header's markers, a rule, a tile a chat,
// the "+N more" line, Recent and its lines, the foot's markers - cut from
// the end to fit the height cap
// as Limit-ChatOverlayRows, Add-ChatOverlayRecent and Test-ChatOverlayFits
// cut them. Folded: the compact line and its gauges, then the markers that
// fit. Out: the prims, the size, and the items the chip and the card go by
// (Get-ChatOverlayRowRects), in logical pixels from the panel's corner.
// Pure but for the measure, which asks Slint how big a text is.
//
// An item's top is put on a whole pixel, which WPF's layout does not do;
// the sizes it adds up, which decide what fits, are WPF's own.

use serde_json::{Value, json};

use crate::art::{self, Xf};
use crate::clock::{self, Wall};
use crate::look::Look;
use crate::model::{self, eq, s};
use crate::scene::{self, Draw, Font, Measure, Prim};

// the frame (New-ChatOverlayWindow): its edge and its padding - the top's
// the bar of buttons' inset, its 20 units and 2 clear under them, less
// the edge
const EDGE: f64 = 1.0;
const PAD_X: f64 = 11.0;
const PAD_TOP: f64 = 4.0 + 20.0 + 2.0 - EDGE;
const PAD_BOTTOM: f64 = 9.0;
const RADIUS: f64 = 8.0;
/// What the frame adds to the stack's height (Test-ChatOverlayFits).
pub const CHROME: f64 = PAD_TOP + PAD_BOTTOM + 2.0 * EDGE;
/// The stack's left edge and top.
pub const X0: f64 = EDGE + PAD_X;
pub const TOP: f64 = EDGE + PAD_TOP;
/// The bar of buttons: six 22-unit buttons and its indent each side.
const BAR: f64 = 6.0 * 22.0 + 2.0 * 8.0;
// a tile (New-ChatOverlayTile): 36 tall, its mark, clock and bin in a row
pub const TILE_H: f64 = 36.0;
const TILE_IN: f64 = 8.5;
const MARK_BOX: (f64, f64) = (16.0, 14.0);
const CLOCK_GAP: f64 = 7.0;
const BIN_GAP: f64 = 6.0;
/// An action's icon box (New-ChatOverlayActionIcon).
pub const ICON: (f64, f64) = (20.0, 14.0);
// a marker (Add-ChatOverlayNotice): a short tile, a margin over and under
pub const MARK_W: f64 = 34.0;
pub const MARK_H: f64 = 20.0;
pub const MARK_MARGIN: f64 = 2.0;
const FAINT: Font = Font::new(11.0);
const LETTER: Font = Font::new(9.0).bold();
/// The clear under the mascot, before the gauges.
const MASCOT_BOTTOM: f64 = 4.0;

/// The mascot on show: the skin's display size in units (skin.json's
/// mascot.w and h), its decoded atlas, and the frame's cell of it.
#[derive(Clone, Debug)]
pub struct Mascot {
    pub w: f64,
    pub h: f64,
    pub img: slint::Image,
    pub clip: [u32; 4],
}

/// The mascot's box: its own size, made smaller to fit inside the frame's
/// edges where it is wider (the default skin's 160 is exactly that room).
fn fit(m: &Mascot) -> (f64, f64) {
    let room = width() - 2.0 * EDGE;
    let k = if m.w > room { room / m.w } else { 1.0 };
    (m.w * k, m.h * k)
}

/// The height the mascot adds to the stack, its clear under it included.
pub fn mascot_tall(m: &Mascot) -> f64 {
    fit(m).1 + MASCOT_BOTTOM
}

/// The least the height cap may be (App::cap): the frame and one row -
/// the drawn row's height, 42 for none - and, opened out, the mascot over
/// it, so the mascot never takes the last row's place.
pub fn cap_floor(row_h: f64, mascot: Option<&Mascot>) -> f64 {
    let row = if row_h > 0.0 { row_h } else { 42.0 };
    row + CHROME + mascot.map_or(0.0, mascot_tall)
}

/// A tile's width: inset 8.5, its mark, its clock and its bin, and the
/// card's gap at its right end.
pub fn tile_width() -> f64 {
    TILE_IN
        + MARK_BOX.0
        + CLOCK_GAP
        + art::seg_dims().width
        + BIN_GAP
        + ICON.0
        + f64::from(model::CARD_GAP)
}

/// Get-ChatOverlayPanelWidth: the bar of buttons or a tile in the frame,
/// whichever is wider.
pub fn width() -> f64 {
    f64::max(BAR, (tile_width() + 2.0 * (PAD_X + EDGE)).ceil())
}

/// The stack's width.
pub fn content_width() -> f64 {
    width() - 2.0 * (PAD_X + EDGE)
}

/// The chip's open, delete or reload, said at the foot ($H.OpenSay).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Said {
    pub kind: String,
    pub tone: String,
    pub text: String,
    pub about: String,
}

/// What the panel is drawn from.
pub struct Input<'a> {
    pub snap: &'a Value,
    pub look: &'static Look,
    pub locked: bool,
    pub collapsed: bool,
    /// config.maxRows and config.recent
    pub max_rows: i64,
    pub recent: i64,
    /// the window's MaxHeight, units (Update-ChatOverlayMaxHeight); None,
    /// or not over 0, for none
    pub cap: Option<f64>,
    pub said: Option<&'a Said>,
    /// the hotkey as its words, '' for none (the unlocked hint)
    pub hotkey: &'a str,
    pub now_ms: i64,
    /// config.opacity, the window's
    pub opacity: f64,
    pub wall: Wall<'a>,
    /// the mascot, at the stack's head opened out; never drawn folded
    pub mascot: Option<&'a Mascot>,
}

/// A drawn row, as Get-ChatOverlayRowRects has it: its row - a chat, a
/// Recent line, a marker, a gauge - its rect, the tile the chip rings
/// (a chat's and a Recent line's), and the marker's tooltip.
#[derive(Clone, Debug, PartialEq)]
pub struct Item {
    pub key: String,
    pub row: Value,
    pub rect: [f64; 4],
    pub tile: Option<[f64; 4]>,
    pub tip: String,
}

/// The panel drawn.
pub struct Built {
    pub prims: Vec<Prim>,
    pub width: f64,
    /// the window's height: the stack and the frame, whole, no more than
    /// the cap
    pub height: f64,
    pub items: Vec<Item>,
    /// how many chats' tiles and Recent lines are drawn
    pub rows: usize,
    pub recent: usize,
    /// Get-ChatOverlayRowHeight (0 for no row), -RecentHeight, -LineHeight
    pub row_h: f64,
    pub recent_h: f64,
    pub line: f64,
    /// the mascot's image prim, its index in `prims`, for its frame to be
    /// stepped in place (scene::set_clip)
    pub mascot: Option<usize>,
}

enum What {
    Mascot,
    Gauge {
        usage: Value,
        letter: String,
        lh: f64,
    },
    Mark {
        row: Value,
        tip: String,
    },
    Rule,
    Tile(Value),
    Recent {
        row: Value,
        tw: f64,
        th: f64,
    },
    Line {
        text: String,
        wrap: bool,
        tw: f64,
    },
    Dot {
        dot: &'static str,
        text: String,
        th: f64,
    },
}

struct Block {
    what: What,
    top: f64,
    h: f64,
    bottom: f64,
}

impl Block {
    fn tall(&self) -> f64 {
        self.top + self.h + self.bottom
    }
}

struct Stack {
    blocks: Vec<Block>,
    cap: Option<f64>,
}

impl Stack {
    fn height(&self) -> f64 {
        self.blocks.iter().map(Block::tall).sum()
    }

    /// Test-ChatOverlayFits: the stack and `extra` under it fit the cap.
    fn fits(&self, extra: f64) -> bool {
        self.cap
            .is_none_or(|cap| self.height() + CHROME + extra <= cap)
    }

    fn push(&mut self, b: Block) {
        self.blocks.push(b);
    }

    fn pop(&mut self) {
        self.blocks.pop();
    }

    fn tiles(&self) -> usize {
        self.blocks
            .iter()
            .filter(|b| matches!(b.what, What::Tile(_)))
            .count()
    }
}

/// Get-ChatOverlayLineHeight: a faint line's height, 18 for none.
fn line_height(m: &dyn Measure) -> f64 {
    let h = m.size("+0 more", FAINT, None, 0).1;
    if h > 0.0 { h } else { 18.0 }
}

/// A usage's windows, as `@($Usage.windows)` has them.
fn windows(u: &Value) -> Vec<&Value> {
    match model::get(u, "windows") {
        Some(Value::Array(a)) => a.iter().collect(),
        Some(Value::Null) | None => Vec::new(),
        Some(x) => vec![x],
    }
}

/// Add-ChatOverlayGauge: a bar a window, 4 tall and 2 apart, the letters
/// at the left when `letter`.
fn gauge(u: &Value, letter: bool, m: &dyn Measure) -> Block {
    let who = s(u, "provider");
    let letter = if letter && !who.is_empty() {
        model::gauge_letter(&who)
    } else {
        String::new()
    };
    let lh = if letter.is_empty() {
        0.0
    } else {
        m.size(&letter, LETTER, None, 0).1
    };
    let k = windows(u).len() as f64;
    let bars = if k > 0.0 { 6.0 * k - 2.0 } else { 0.0 };
    let usage = json!({ "key": format!("usage:{}", who.to_lowercase()), "kind": "usage", "provider": who, "usage": u });
    Block {
        what: What::Gauge { usage, letter, lh },
        top: 2.0,
        h: bars.max(lh),
        bottom: 2.0,
    }
}

/// Add-ChatOverlayNotice's marker for `row`, `tip` its tooltip.
fn mark(row: Value, tip: String) -> Block {
    Block {
        what: What::Mark { row, tip },
        top: MARK_MARGIN,
        h: MARK_H,
        bottom: MARK_MARGIN,
    }
}

/// Add-ChatOverlayTileRow: a chat's tile, or a Recent line.
fn row(r: &Value, m: &dyn Measure) -> Block {
    if !eq(&s(r, "kind"), "recent") {
        return Block {
            what: What::Tile(r.clone()),
            top: 3.0,
            h: TILE_H,
            bottom: 3.0,
        };
    }
    let (tw, th) = m.size(&s(r, "stateText"), FAINT, None, 0);
    // the dot and its margin, the text, the bin: the tallest, and the box's
    // padding over and under
    let inner = th.max(ICON.1).max(9.0);
    Block {
        what: What::Recent {
            row: r.clone(),
            tw,
            th,
        },
        top: 1.0,
        h: inner + 4.0,
        bottom: 1.0,
    }
}

/// A faint line, 11 units, wrapped to the stack's width when `wrap`.
fn faint(text: &str, wrap: bool, m: &dyn Measure) -> Block {
    let (tw, th) = m.size(text, FAINT, wrap.then(content_width), 0);
    Block {
        what: What::Line {
            text: text.into(),
            wrap,
            tw,
        },
        top: 0.0,
        h: th,
        bottom: 0.0,
    }
}

/// The ask's tooltip: its chats' titles, then the ones it leaves.
fn ask_tip(snap: &Value) -> String {
    let Some(ask) = model::get(snap, "header").and_then(|h| model::get(h, "ask")) else {
        return String::new();
    };
    let mut lines: Vec<String> = model::list(ask, "titles")
        .iter()
        .map(|x| clock::text(Some(x)))
        .collect();
    lines.extend(
        model::list(ask, "left")
            .iter()
            .map(|x| clock::text(Some(x))),
    );
    lines.join("\n")
}

/// Add-ChatOverlayHeadNotices: each note's marker, then the ask's.
fn head_marks(st: &mut Stack, inp: &Input) -> bool {
    let marks = model::head_notices(inp.snap, inp.now_ms, inp.wall);
    let any = !marks.is_empty();
    for n in marks {
        let tip = if eq(&s(&n, "kind"), "ask") {
            ask_tip(inp.snap)
        } else {
            String::new()
        };
        st.push(mark(n, tip));
    }
    any
}

/// The foot's markers: each reload's, the said one, the unlocked hint.
fn foot_marks(st: &mut Stack, inp: &Input) {
    for rl in model::reloads(inp.snap) {
        st.push(mark(model::reload_notice(rl), s(rl, "text")));
    }
    if let Some(say) = inp.said {
        st.push(mark(
            model::said_notice(&say.kind, &say.tone, &say.text, &say.about),
            String::new(),
        ));
    }
    if !inp.locked {
        st.push(mark(model::unlocked_notice(inp.hotkey), String::new()));
    }
}

/// Get-ChatOverlayFootRoom: each reload's marker, the said one always, and
/// unlocked the hint's.
fn foot_room(inp: &Input) -> f64 {
    let n = model::reloads(inp.snap).len() + 1 + usize::from(!inp.locked);
    n as f64 * (MARK_H + 2.0 * MARK_MARGIN)
}

/// Limit-ChatOverlayRows: the tiles just pushed cut from the end until
/// the stack fits with room for the "+N more" line and the foot's markers;
/// how many are left, one at least.
fn limit(st: &mut Stack, more: bool, line: f64, under: f64) -> usize {
    let mut n = st.tiles();
    if n <= 1 || st.cap.is_none() {
        return n;
    }
    if st.fits(under + if more { line } else { 0.0 }) {
        return n;
    }
    while n > 1 && !st.fits(under + line) {
        st.pop();
        n -= 1;
    }
    n
}

/// The panel at `inp`: its stack laid out, cut to the cap, and drawn.
pub fn build(inp: &Input, m: &dyn Measure) -> Built {
    let snap = inp.snap;
    let mut st = Stack {
        blocks: Vec::new(),
        cap: inp.cap.filter(|c| c.is_finite() && *c > 0.0),
    };
    let usage = model::active_usage(snap);
    let letters = usage.len() > 1;
    let line = line_height(m);
    if inp.collapsed {
        let (dot, text) = model::compact(snap);
        let th = m
            .size(&text, Font::new(12.0), Some(content_width() - 15.0), 0)
            .1;
        let bottom = if usage.is_empty() { 0.0 } else { 3.0 };
        st.push(Block {
            what: What::Dot { dot, text, th },
            top: 0.0,
            h: th.max(13.0),
            bottom,
        });
        for u in &usage {
            st.push(gauge(u, letters, m));
        }
        // as many markers as fit: one past the cap is out of reach
        let keep = st.blocks.len();
        head_marks(&mut st, inp);
        foot_marks(&mut st, inp);
        while st.blocks.len() > keep && !st.fits(0.0) {
            st.pop();
        }
        return draw(inp, &st, line);
    }
    // the mascot first, so the cut from the end never reaches it
    if let Some(mm) = inp.mascot {
        st.push(Block {
            what: What::Mascot,
            top: 0.0,
            h: fit(mm).1,
            bottom: MASCOT_BOTTOM,
        });
    }
    for u in &usage {
        st.push(gauge(u, letters, m));
    }
    let marks = head_marks(&mut st, inp);
    if !usage.is_empty() || marks {
        st.push(Block {
            what: What::Rule,
            top: 6.0,
            h: 1.0,
            bottom: 4.0,
        });
    }
    let rows = model::list(snap, "rows");
    let mut shown = rows.len().min(usize::try_from(inp.max_rows).unwrap_or(0));
    for r in &rows[..shown] {
        st.push(row(r, m));
    }
    let under = foot_room(inp);
    shown = shown.min(limit(&mut st, rows.len() > shown, line, under));
    // the "+N more" line: wrapped it can take two, so a row more goes
    // while it does not fit
    while rows.len() > shown {
        st.push(faint(&model::more_line(&rows[shown..]), true, m));
        if shown <= 1 || st.fits(under) {
            break;
        }
        st.pop();
        st.pop();
        shown -= 1;
    }
    if rows.is_empty() {
        st.push(faint("no chats open", false, m));
    }
    // Recent: the snapshot's recent, then recentMore, overlay.recent of
    // them, as many as fit; none, and the header goes too
    let mut recent = model::list(snap, "recent");
    recent.extend(model::list(snap, "recentMore"));
    recent.truncate(usize::try_from(inp.recent).unwrap_or(0));
    if !recent.is_empty() {
        let mut head = faint("Recent", false, m);
        head.top = 6.0;
        head.bottom = 1.0;
        st.push(head);
        for r in &recent {
            st.push(row(r, m));
        }
        let mut k = recent.len();
        while k > 0 && !st.fits(under) {
            st.pop();
            k -= 1;
        }
        if k == 0 {
            st.pop();
        }
    }
    foot_marks(&mut st, inp);
    draw(inp, &st, line)
}

/// Every item drawn where the stack puts it, over the frame.
fn draw(inp: &Input, st: &Stack, line: f64) -> Built {
    let look = inp.look;
    let w = width();
    let mut h = (st.height() + CHROME).ceil();
    if let Some(cap) = st.cap {
        h = h.min(cap.ceil());
    }
    let mut d = Draw::new(inp.opacity);
    let trim = look.argb(if inp.locked { "trim" } else { "unlocked" });
    d.border(0.0, 0.0, w, h, RADIUS, look.argb("frame"), trim, EDGE);
    // the dark look's second line, 3 in from the frame's own
    // (New-ChatOverlayDecor)
    if look.name == "dark" {
        let mut p = scene::rect(
            3.0,
            3.0,
            w - 6.0,
            h - 6.0,
            RADIUS - 3.0 + 0.5,
            0,
            look.argb("trim"),
            1.0,
        );
        p.opacity = 0.45;
        d.add(p);
    }
    // unlocked, a press anywhere moves it (Invoke-ChatOverlayDrag)
    if !inp.locked {
        d.add(scene::hit(
            "frame",
            0.0,
            0.0,
            w,
            h,
            RADIUS + 0.5,
            scene::ARROW,
            0,
        ));
    }
    let mut items = Vec::new();
    let (mut rows, mut recent, mut recent_sum) = (0, 0, 0.0);
    let mut mascot = None;
    let mut y = TOP;
    for b in &st.blocks {
        let top = (y + b.top).round();
        y += b.tall();
        let at = [X0, top, content_width(), b.h];
        match &b.what {
            What::Mascot => {
                if let Some(m) = inp.mascot {
                    let (mw, mh) = fit(m);
                    mascot = Some(d.prims.len());
                    d.add(scene::image((w - mw) / 2.0, top, mw, mh, &m.img, m.clip));
                }
            }
            What::Gauge { usage, letter, lh } => {
                draw_gauge(&mut d, look, usage, letter, *lh, top, b.h);
                items.push(Item {
                    key: s(usage, "key"),
                    row: usage.clone(),
                    rect: at,
                    tile: None,
                    tip: String::new(),
                });
            }
            What::Mark { row, tip } => {
                draw_mark(&mut d, look, row, top);
                if !inp.locked && !tip.is_empty() {
                    d.add(scene::hit(
                        &format!("tip:{}", s(row, "key")),
                        X0,
                        top,
                        MARK_W,
                        MARK_H,
                        5.75,
                        scene::ARROW,
                        0,
                    ));
                }
                items.push(Item {
                    key: s(row, "key"),
                    row: row.clone(),
                    rect: at,
                    tile: None,
                    tip: tip.clone(),
                });
            }
            What::Rule => d.add(scene::rect(
                X0,
                top,
                content_width(),
                1.0,
                0.0,
                look.argb("edge"),
                0,
                0.0,
            )),
            What::Tile(row) => {
                draw_tile(&mut d, look, row, top, inp.now_ms);
                rows += 1;
                let tile = Some([X0, top, tile_width(), TILE_H]);
                items.push(Item {
                    key: s(row, "key"),
                    row: row.clone(),
                    rect: at,
                    tile,
                    tip: String::new(),
                });
            }
            What::Recent { row, tw, th } => {
                draw_recent(&mut d, look, row, top, *tw, *th);
                recent += 1;
                recent_sum += b.tall();
                let tile = Some([X0, top, 52.0 + tw, b.h]);
                items.push(Item {
                    key: s(row, "key"),
                    row: row.clone(),
                    rect: at,
                    tile,
                    tip: String::new(),
                });
            }
            What::Line { text, wrap, tw } => {
                let tw = if *wrap {
                    content_width()
                } else {
                    tw.min(content_width())
                };
                d.add(scene::text(
                    X0,
                    top,
                    tw,
                    b.h,
                    text,
                    look.argb("faint"),
                    FAINT,
                    *wrap,
                    0,
                    0,
                ));
            }
            What::Dot { dot, text, th } => {
                d.add(scene::rect(
                    X0,
                    top + 5.0,
                    8.0,
                    8.0,
                    4.0,
                    look.argb(dot),
                    0,
                    0.0,
                ));
                let tw = content_width() - 15.0;
                d.add(scene::text(
                    X0 + 15.0,
                    top,
                    tw,
                    *th,
                    text,
                    look.argb("text"),
                    Font::new(12.0),
                    true,
                    0,
                    0,
                ));
            }
        }
    }
    // a key or none: a row without one is drawn and never matched
    items.retain(|i| !i.key.is_empty());
    Built {
        prims: d.prims,
        width: w,
        height: h,
        items,
        rows,
        recent,
        row_h: if rows > 0 { TILE_H + 6.0 } else { 0.0 },
        recent_h: if recent > 0 {
            recent_sum / recent as f64
        } else {
            line + 6.0
        },
        line,
        mascot,
    }
}

/// A shape at (x, y), stroked round, as the panel's glyphs are.
fn glyph(d: &mut Draw, shape: &art::Shape, x: f64, y: f64, fill: u32, stroke: u32, sw: f64) {
    d.add_opt(scene::path(
        &shape.xf(Xf::at(x, y)),
        fill,
        stroke,
        sw,
        true,
        true,
    ));
}

/// New-ChatOverlayTile: the box in the state's colour - washed in, dashed
/// for a queued job - the mark, the clock over its ghosts, the bin, and
/// the unread dot on the top right corner.
fn draw_tile(d: &mut Draw, look: &Look, row: &Value, top: f64, now_ms: i64) {
    let x = X0;
    let w = tile_width();
    let st = s(row, "status");
    let c = look.argb(&st);
    // a WPF Rectangle strokes its edge's middle, half the stroke in
    if eq(&st, "queued") {
        let wash = look.tile_wash(&st);
        if wash >> 24 != 0 {
            d.add(scene::rect(
                x + 0.75,
                top + 0.75,
                w - 1.5,
                TILE_H - 1.5,
                6.0,
                wash,
                0,
                0.0,
            ));
        }
        let dash = art::dashed_rrect(x + 0.75, top + 0.75, w - 1.5, TILE_H - 1.5, 6.0, 3.0, 2.25);
        d.add_opt(scene::path(&dash, 0, c, 1.5, false, false));
    } else {
        d.add(scene::rect(
            x,
            top,
            w,
            TILE_H,
            6.75,
            look.tile_wash(&st),
            c,
            1.5,
        ));
    }
    let (mark, fill) = art::tile_mark(model::tile_mark(row), eq(&st, "running"));
    let (mx, my) = (x + TILE_IN, top + (TILE_H - MARK_BOX.1) / 2.0);
    glyph(d, &mark, mx, my, 0, c, art::MARK_STROKE);
    if let Some(f) = fill {
        glyph(d, &f, mx, my, c, c, art::MARK_STROKE);
    }
    let seg = art::seg_dims();
    let (cx, cy) = (
        mx + MARK_BOX.0 + CLOCK_GAP,
        top + (TILE_H - seg.height) / 2.0,
    );
    let text = model::format_row_clock(&model::row_clock(row), now_ms);
    let at = Xf::at(cx, cy);
    d.add_opt(scene::path(
        &seg.ghost().xf(at),
        look.argb("ghost"),
        0,
        0.0,
        false,
        true,
    ));
    d.add_opt(scene::path(&seg.lit(&text).xf(at), c, 0, 0.0, false, true));
    bin(
        d,
        look,
        row,
        cx + seg.width + BIN_GAP,
        top + (TILE_H - ICON.1) / 2.0,
    );
    if model::t(row, "unread") {
        let (ux, uy) = (x + w - 13.0 + 4.5, top - 4.5);
        d.add(scene::rect(
            ux,
            uy,
            13.0,
            13.0,
            6.5,
            look.argb("accent"),
            look.argb("frame"),
            2.0,
        ));
    }
}

/// New-ChatOverlayTileBin: the row's delete at (x, y), faint where it
/// cannot; its room kept, empty, on a row with none.
fn bin(d: &mut Draw, look: &Look, row: &Value, x: f64, y: f64) {
    let acts = model::chip_actions(row);
    let Some(a) = acts.iter().find(|a| a.id == "delete") else {
        return;
    };
    let c = look.argb(if a.disabled { "faint" } else { "dim" });
    glyph(
        d,
        &art::action_icon("delete", &a.label),
        x,
        y,
        0,
        c,
        art::ACTION_STROKE,
    );
}

/// A Recent line: a dot in its state's colour, how long ago, its bin, in
/// a box padded 6, 2, 5, 2.
fn draw_recent(d: &mut Draw, look: &Look, row: &Value, top: f64, tw: f64, th: f64) {
    let inner = th.max(ICON.1).max(9.0);
    let y = top + 2.0;
    let dot = scene::rect(
        X0 + 6.0,
        y + 1.0 + (inner - 9.0) / 2.0,
        8.0,
        8.0,
        4.0,
        look.argb(&s(row, "status")),
        0,
        0.0,
    );
    d.add(dot);
    let ago = s(row, "stateText");
    d.add(scene::text(
        X0 + 21.0,
        y + (inner - th) / 2.0,
        tw,
        th,
        &ago,
        look.argb("faint"),
        FAINT,
        false,
        0,
        0,
    ));
    bin(d, look, row, X0 + 27.0 + tw, y + (inner - ICON.1) / 2.0);
}

/// Add-ChatOverlayNotice: a short tile in its tone's colour, washed in
/// unless it only says, its glyph centred.
fn draw_mark(d: &mut Draw, look: &Look, row: &Value, top: f64) {
    let tone = s(row, "tone");
    let c = look.argb(&tone);
    d.border(
        X0,
        top,
        MARK_W,
        MARK_H,
        5.0,
        look.notice_wash(&tone),
        c,
        1.5,
    );
    // the 12 x 12 glyph in the box's inside, 1.5 in: (31 - 12) / 2, (17 - 12) / 2
    let which = tone.to_ascii_lowercase();
    glyph(
        d,
        &art::notice_glyph(&which),
        X0 + 11.0,
        top + 4.0,
        0,
        c,
        art::NOTICE_STROKE,
    );
}

/// Add-ChatOverlayGauge: a track a window and its fill to its percent -
/// faint gone stale, critical at the limit, else the server's colour -
/// the letters at the left.
fn draw_gauge(d: &mut Draw, look: &Look, row: &Value, letter: &str, lh: f64, top: f64, h: f64) {
    let u = model::get(row, "usage").unwrap_or(&Value::Null);
    let stale = model::t(u, "stale");
    let mut x = X0;
    if !letter.is_empty() {
        let c = look.argb(if stale { "faint" } else { "dim" });
        d.add(scene::text(
            X0,
            top + (h - lh) / 2.0,
            15.0,
            lh,
            letter,
            c,
            LETTER,
            false,
            0,
            0,
        ));
        x += 15.0;
    }
    let w = X0 + content_width() - x;
    let ws = windows(u);
    let bars = if ws.is_empty() {
        0.0
    } else {
        6.0 * ws.len() as f64 - 2.0
    };
    let mut y = top + (h - bars) / 2.0;
    for win in ws {
        let pct = model::f(win, "percent").clamp(0.0, 100.0);
        d.add(scene::rect(x, y, w, 4.0, 2.0, look.argb("track"), 0, 0.0));
        let name = if stale {
            "faint".to_string()
        } else if model::t(win, "limited") {
            "critical".to_string()
        } else {
            s(win, "severity")
        };
        let fw = w * pct / 100.0;
        if fw > 0.0 {
            d.add(scene::rect(x, y, fw, 4.0, 2.0, look.argb(&name), 0, 0.0));
        }
        y += 6.0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::look::look;
    use crate::scene::Fixed;
    use chrono::{DateTime, NaiveDateTime, Utc};

    const NOW: i64 = 1_760_000_000_000;

    fn utc(ms: i64) -> NaiveDateTime {
        DateTime::<Utc>::from_timestamp_millis(ms)
            .unwrap()
            .naive_utc()
    }

    fn chat(key: &str, status: &str, at: &str) -> Value {
        json!({ "key": key, "kind": "session", "provider": "claude", "status": status, "where": at,
            "since": NOW - 65_000, "sessionId": "0b5c1a52-7a07-4a51-9b55-1c2a3f4e5d6c", "cwd": "C:/w" })
    }

    fn snap(rows: Vec<Value>) -> Value {
        json!({ "schema": 1, "at": NOW, "header": {}, "counts": { "idle": rows.len() }, "rows": rows })
    }

    fn input<'a>(snap: &'a Value, wall: Wall<'a>) -> Input<'a> {
        Input {
            snap,
            look: look("dark"),
            locked: true,
            collapsed: false,
            max_rows: 8,
            recent: 5,
            cap: None,
            said: None,
            hotkey: "Ctrl+Alt+Shift+O",
            now_ms: NOW,
            opacity: 1.0,
            wall,
            mascot: None,
        }
    }

    /// A mascot of `w` x `h` units on a blank image: its place, not its
    /// pixels.
    fn sized(w: f64, h: f64) -> Mascot {
        Mascot {
            w,
            h,
            img: slint::Image::default(),
            clip: [320, 0, 320, 256],
        }
    }

    fn keys(b: &Built) -> Vec<String> {
        b.items.iter().map(|i| i.key.clone()).collect()
    }

    fn texts(b: &Built) -> Vec<String> {
        b.prims
            .iter()
            .filter(|p| p.kind == 1)
            .map(|p| p.text.to_string())
            .collect()
    }

    #[test]
    fn the_panel_is_as_wide_as_a_tile_in_its_frame() {
        assert!((tile_width() - 137.6724).abs() < 1e-3, "{}", tile_width());
        assert_eq!(width(), 162.0);
        assert_eq!(content_width(), 138.0);
        assert_eq!((CHROME, X0, TOP), (36.0, 12.0, 26.0));
    }

    #[test]
    fn rows_stack_under_the_frame_with_their_margins() {
        let s = snap(vec![
            chat("a", "busy", "vscode"),
            chat("b", "idle", "window"),
        ]);
        let wall = |ms| utc(ms);
        let b = build(&input(&s, &wall), &Fixed);
        assert_eq!(keys(&b), ["a", "b"]);
        assert_eq!(b.items[0].rect, [12.0, 29.0, 138.0, 36.0]);
        assert_eq!(b.items[1].rect[1], 29.0 + 42.0);
        assert_eq!(b.items[0].tile.unwrap()[2], tile_width());
        assert_eq!(b.height, 2.0 * 42.0 + 36.0);
        assert_eq!((b.rows, b.row_h), (2, 42.0));
        // no Recent drawn: a faint line (11 * 4/3, up) and its box's 6
        assert_eq!((b.line, b.recent_h), (15.0, 15.0 + 6.0));
    }

    #[test]
    fn rows_past_the_cap_go_and_the_more_line_says_so() {
        let rows: Vec<Value> = (0..10)
            .map(|i| chat(&format!("r{i}"), "idle", "window"))
            .collect();
        let s = snap(rows);
        let wall = |ms| utc(ms);
        let mut inp = input(&s, &wall);
        // four rows, the more line (15) and the said marker's room (24)
        inp.cap = Some(36.0 + 4.0 * 42.0 + 15.0 + 24.0);
        let b = build(&inp, &Fixed);
        assert_eq!(b.rows, 4);
        assert!(
            texts(&b).contains(&format!("+6 more {} 6 idle", model::DOT)),
            "{:?}",
            texts(&b)
        );
        assert_eq!(b.height, 36.0 + 4.0 * 42.0 + 15.0);
        // a unit less, and a row more goes
        inp.cap = Some(36.0 + 4.0 * 42.0 + 15.0 + 23.0);
        assert_eq!(build(&inp, &Fixed).rows, 3);
        // no cap: maxRows of them, the rest counted
        inp.cap = None;
        let b = build(&inp, &Fixed);
        assert_eq!(b.rows, 8);
        assert!(texts(&b).contains(&format!("+2 more {} 2 idle", model::DOT)));
    }

    #[test]
    fn recent_lines_go_first_and_their_header_with_the_last() {
        let mut s = snap(vec![chat("a", "busy", "vscode")]);
        s["recent"] = json!([{ "key": "r:1", "kind": "recent", "provider": "claude", "status": "recent", "stateText": "2h ago" }]);
        s["recentMore"] = json!([{ "key": "r:2", "kind": "recent", "provider": "claude", "status": "recent", "stateText": "1d ago" }]);
        let wall = |ms| utc(ms);
        let mut inp = input(&s, &wall);
        let b = build(&inp, &Fixed);
        assert_eq!(keys(&b), ["a", "r:1", "r:2"]);
        assert!(texts(&b).contains(&"Recent".to_string()));
        // a line is max(15, 14) + 4 and 2 of margin
        assert_eq!((b.recent, b.recent_h), (2, 21.0));
        // the cap holds the row, the header (15 + 7) and one line, with the
        // foot's room
        inp.cap = Some(36.0 + 42.0 + 22.0 + 21.0 + 24.0);
        let b = build(&inp, &Fixed);
        assert_eq!(keys(&b), ["a", "r:1"]);
        inp.cap = Some(36.0 + 42.0 + 24.0 + 10.0);
        let b = build(&inp, &Fixed);
        assert_eq!(keys(&b), ["a"]);
        assert!(!texts(&b).contains(&"Recent".to_string()));
        inp.recent = 0;
        inp.cap = None;
        assert_eq!(keys(&build(&inp, &Fixed)), ["a"]);
    }

    #[test]
    fn markers_gauges_and_the_rule() {
        let mut s = snap(vec![chat("a", "waiting", "terminal")]);
        s["header"] = json!({
            "usage": [{ "provider": "Claude", "windows": [{ "label": "5h", "percent": 40, "severity": "normal" }, { "label": "week", "percent": 140, "severity": "warning" }] }],
            "notes": [{ "kind": "memory", "tone": "warn", "text": "memory" }, { "kind": "ask", "text": "skipped" }],
            "ask": { "count": 2, "keys": ["k"], "titles": ["One", "Two"], "left": ["Three"], "at": NOW - 60_000 },
            "reload": [{ "pid": 7, "id": "x", "window": "w", "text": "why" }]
        });
        let wall = |ms| utc(ms);
        let mut inp = input(&s, &wall);
        inp.locked = false;
        let b = build(&inp, &Fixed);
        assert_eq!(
            keys(&b),
            [
                "usage:claude",
                "notice:memory",
                "ask",
                "a",
                "reload:7",
                "notice:unlocked"
            ]
        );
        // one provider: no letters, two bars 4 tall and 2 apart
        assert_eq!(b.items[0].rect, [12.0, 28.0, 138.0, 10.0]);
        assert_eq!(b.items[2].tip, "One\nTwo\nThree");
        assert_eq!(b.items[4].tip, "why");
        // the rule after the header's markers: 6 over, 1, 4 under
        let tile_top = 26.0 + 14.0 + 24.0 + 24.0 + 11.0 + 3.0;
        assert_eq!(b.items[3].rect[1], tile_top);
        // unlocked: the frame takes a press, and the markers with a tip
        let hits: Vec<String> = b
            .prims
            .iter()
            .filter(|p| p.kind == 3)
            .map(|p| p.id.to_string())
            .collect();
        assert_eq!(hits, ["frame", "tip:ask", "tip:reload:7"]);
    }

    #[test]
    fn folded_keeps_its_line_and_drops_the_markers_past_the_cap() {
        let mut s = snap(vec![chat("a", "busy", "vscode")]);
        s["counts"] = json!({ "busy": 1 });
        s["header"] = json!({ "notes": [{ "kind": "x", "tone": "error", "text": "e1" }, { "kind": "x", "tone": "warn", "text": "w" }] });
        let wall = |ms| utc(ms);
        let mut inp = input(&s, &wall);
        inp.collapsed = true;
        let b = build(&inp, &Fixed);
        assert_eq!(texts(&b), ["1 working"]);
        assert_eq!(keys(&b), ["notice:error", "notice:note:1"]);
        inp.cap = Some(36.0 + 16.0 + 24.0);
        let b = build(&inp, &Fixed);
        assert_eq!(keys(&b), ["notice:error"]);
        inp.cap = Some(10.0);
        let b = build(&inp, &Fixed);
        assert!(keys(&b).is_empty());
        assert_eq!(b.height, 10.0, "the window is cut at its cap");
    }

    /// The mascot heads the stack opened out, centred inside the frame's
    /// edges, the rows 132 lower for its 128 and its clear; one wider than
    /// that room is made smaller to it. Folded, it is not drawn. The cap
    /// keeps it and a row (cap_floor), and the rows are cut under it.
    #[test]
    fn the_mascot_heads_the_stack_and_folded_drops_it() {
        let s = snap(vec![
            chat("a", "busy", "vscode"),
            chat("b", "idle", "window"),
        ]);
        let wall = |ms| utc(ms);
        let m = sized(160.0, 128.0);
        let mut inp = input(&s, &wall);
        inp.mascot = Some(&m);
        let b = build(&inp, &Fixed);
        let i = b.mascot.unwrap();
        let p = &b.prims[i];
        assert_eq!(p.kind, 4);
        assert_eq!((p.x, p.y, p.w, p.h), (1.0, 26.0, 160.0, 128.0));
        assert_eq!((p.clip_x, p.clip_y, p.clip_w, p.clip_h), (320, 0, 320, 256));
        assert_eq!(b.items[0].rect[1], 29.0 + 132.0);
        assert_eq!(b.height, 132.0 + 2.0 * 42.0 + 36.0);
        assert_eq!(mascot_tall(&m), 132.0);
        // twice as wide: half its size, to the 160 there is
        let big = sized(320.0, 256.0);
        inp.mascot = Some(&big);
        let b = build(&inp, &Fixed);
        let p = &b.prims[b.mascot.unwrap()];
        assert_eq!((p.x, p.w, p.h), (1.0, 160.0, 128.0));
        // the floor: a row, the frame and the mascot; a row cut under it
        inp.mascot = Some(&m);
        assert_eq!(cap_floor(42.0, Some(&m)), 42.0 + 36.0 + 132.0);
        assert_eq!(cap_floor(0.0, None), 42.0 + 36.0);
        inp.cap = Some(cap_floor(42.0, Some(&m)) + 24.0);
        let b = build(&inp, &Fixed);
        assert_eq!((b.rows, keys(&b)), (1, vec!["a".to_string()]));
        assert!(b.mascot.is_some());
        inp.cap = None;
        inp.collapsed = true;
        let b = build(&inp, &Fixed);
        assert!(b.mascot.is_none());
        assert!(b.prims.iter().all(|p| p.kind != 4));
    }

    #[test]
    fn no_rows_says_so_and_a_said_line_comes_at_the_foot() {
        let none = snap(vec![]);
        let wall = |ms| utc(ms);
        let mut inp = input(&none, &wall);
        let said = Said {
            kind: "done".into(),
            tone: "warn".into(),
            text: "t".into(),
            about: "a".into(),
        };
        inp.said = Some(&said);
        let b = build(&inp, &Fixed);
        assert_eq!(texts(&b), ["no chats open"]);
        assert_eq!(keys(&b), ["notice:said"]);
        assert_eq!(s(&b.items[0].row, "word"), "NOT OPENED");
    }

    // ---- golden pictures: the real measure, Slint's software renderer

    fn rich() -> Value {
        let mut rows = vec![
            json!({ "key": "a", "kind": "session", "provider": "claude", "status": "waiting", "where": "vscode",
                "since": NOW - 65_000, "unread": true, "sessionId": "0b5c1a52-7a07-4a51-9b55-1c2a3f4e5d6c", "cwd": "C:/w" }),
            json!({ "key": "b", "kind": "session", "provider": "claude", "status": "busy", "where": "terminal", "since": NOW - 3_700_000 }),
            json!({ "key": "c", "kind": "session", "provider": "codex", "status": "running", "where": "run", "since": NOW - 610_000 }),
            json!({ "key": "d", "kind": "job", "provider": "claude", "status": "queued", "sendAt": NOW + 1_800_000 }),
            json!({ "key": "e", "kind": "cutoff", "provider": "claude", "status": "cutoff", "resetsAt": NOW + 7_260_000 }),
            json!({ "key": "f", "kind": "job", "provider": "claude", "status": "running", "since": NOW - 30_000 }),
        ];
        rows.push(json!({ "key": "g", "kind": "session", "provider": "claude", "status": "idle", "where": "window",
            "since": NOW - 90_000_000, "sessionId": "0b5c1a52-7a07-4a51-9b55-1c2a3f4e5d6c", "cwd": "C:/w" }));
        json!({
            "schema": 1, "at": NOW,
            "header": {
                "usage": [
                    { "provider": "claude", "windows": [
                        { "label": "5h", "percent": 42, "severity": "normal" },
                        { "label": "week", "percent": 81, "severity": "warning" }] },
                    { "provider": "codex", "stale": true, "windows": [{ "label": "5h", "percent": 100, "limited": true }] }
                ],
                "notes": [{ "kind": "memory", "tone": "warn", "text": "memory" }, { "kind": "x", "tone": "error", "text": "e" }],
                "ask": { "count": 2, "keys": ["e"], "titles": ["Fix the build"], "at": NOW - 600_000 },
                "reload": [{ "pid": 4321, "id": "r1", "window": "proj", "text": "Extensions changed" }]
            },
            "counts": { "waiting": 1, "busy": 1, "running": 2, "idle": 1, "queued": 1, "unread": 1, "cutOff": 1 },
            "rows": rows,
            "recent": [{ "key": "r:1", "kind": "recent", "provider": "claude", "status": "recent", "stateText": "2h ago",
                "sessionId": "1b5c1a52-7a07-4a51-9b55-1c2a3f4e5d6c", "cwd": "C:/w" }],
            "recentMore": [{ "key": "r:2", "kind": "recent", "provider": "claude", "status": "recent", "stateText": "yesterday",
                "sessionId": "2b5c1a52-7a07-4a51-9b55-1c2a3f4e5d6c", "cwd": "C:/w" }]
        })
    }

    fn golden(name: &str, set: impl Fn(&mut Input)) {
        let (scene_, win) = scene::golden::scene();
        let m = scene::Measurer::new(&scene_);
        let s = rich();
        let wall = |ms| utc(ms);
        let said = Said {
            kind: "busy".into(),
            tone: "dim".into(),
            text: "opening".into(),
            about: "a".into(),
        };
        // the default skin's idle, decoded as the panel decodes it, stepped
        // to its eighth frame (the second row's second cell)
        let mascot = name.contains("mascot").then(|| {
            let mut a =
                crate::anim::Anim::new(crate::skin::Skin::default(), crate::skin::Mood::Idle);
            for _ in 0..7 {
                a.advance();
            }
            a.mascot()
        });
        let mut inp = input(&s, &wall);
        set(&mut inp);
        if name.contains("said") {
            inp.said = Some(&said);
        }
        inp.mascot = mascot.as_ref();
        let b = build(&inp, &m);
        let (w, h) = (b.width as u32, b.height as u32);
        scene::show(&scene_, b.prims);
        let rgb = scene::golden::render(&scene_, &win, w, h);
        scene::golden::check(name, w, h, &rgb);
    }

    #[test]
    fn golden_panel_dark() {
        golden("panel-dark", |_| {});
    }

    #[test]
    fn golden_panel_light_unlocked_said() {
        golden("panel-light-unlocked-said", |i| {
            i.look = look("light");
            i.locked = false;
        });
    }

    #[test]
    fn golden_panel_folded() {
        golden("panel-folded", |i| i.collapsed = true);
    }

    #[test]
    fn golden_panel_capped() {
        golden("panel-capped", |i| i.cap = Some(300.0));
    }

    #[test]
    fn golden_panel_mascot() {
        golden("panel-mascot", |_| {});
    }

    #[test]
    fn golden_panel_mascot_light_capped() {
        golden("panel-mascot-light-capped", |i| {
            i.look = look("light");
            i.cap = Some(300.0);
        });
    }
}
