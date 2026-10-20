// M9 spike, step 5: the gate hour (--gate, --ui-only).
//
// Steps 1-4 at once in one process, with real content:
//   windows   the overlay's five (panel, bar, edges, chip, card) glued as in
//             glue.rs, plus a small settings window: all made off-screen,
//             given the overlay's styles while hidden (win32::make_overlay),
//             moved together in one DeferWindowPos batch with SWP_NOSIZE,
//             sized through Slint; the card click-through and layered
//             (win32::layered_opaque), chip and card cloaked until painted
//             on every show; topmost re-asserted every 5 s; a scale or work
//             area change re-places all six for the monitor's DPI (replace)
//   mouse     the panel's click-through toggled every 10 s (winit's
//             set_cursor_hittest) with the bar a window of its own that
//             always takes clicks, each toggle probed by WindowFromPoint;
//             opacity 30-100% from the settings slider; the 120 ms pointer
//             and button poll (reads only)
//   content   data/overlay.json read live and read only (gate/content.rs):
//             usage gauges, tiles with their clocks, the Recent lines, the
//             chip and card text, the tray's dot and tooltip
//   exercise  a 1 s timer drives the chip and card (shown, hidden, new text
//             each time), the settings window and its slider, the opacity,
//             the click-through and the panel's height (the Recent count),
//             so nothing needs the real pointer, which is never moved
//   tray      gate/tray.rs: dot, tooltip, menu, hotkey, balloons
//   readload  gate/readload.rs: the collector's reads, on a worker thread
//             (--gate only)
//   samples   gate/sample.rs: a sample a minute, the summary at exit
//
// --ui-only: the same without the read-load stand-in and with overlay.json
// read once, at the start - the 10-minute side run.

pub mod content;
mod readload;
mod sample;
mod tray;

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::atomic::{AtomicBool, Ordering::SeqCst};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use slint::winit_030::{EventResult, WinitWindowAccessor, winit};
use slint::{Color, ComponentHandle, Model, ModelRc, VecModel};
use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::UI::WindowsAndMessaging::WS_EX_LAYERED;

use crate::glue::Edges;
use crate::mouse::Strip;
use crate::win32::rect_text;
use crate::{later, repeat, selflog, win32};
use content::{Snapshot, View};

slint::slint! {
    export struct GateBar { mark: string, percent: float, tint: color }
    export struct GateTile { title: string, project: string, clock: string, mark: string, tint: color, wash: color, unread: bool }
    export struct GateLine { title: string, age: string }

    export component GatePanel inherits Window {
        in property <[GateBar]> bars;
        in property <[GateTile]> tiles;
        in property <[GateLine]> recent;
        in property <string> version;
        in property <string> clock;
        in property <string> foot;
        in property <float> body-opacity: 1;
        out property <length> tiles-y: tl.y;
        out property <length> want-height: vl.preferred-height;
        no-frame: true;
        always-on-top: true;
        background: transparent;
        width: 300px;
        height: vl.preferred-height;

        Rectangle {
            opacity: root.body-opacity;
            border-radius: 8px;
            background: #1e1f24;
            border-width: 1px;
            border-color: #c0a040;
        }
        vl := VerticalLayout {
            padding-left: 11px;
            padding-right: 11px;
            padding-top: 28px;
            padding-bottom: 8px;
            spacing: 4px;
            HorizontalLayout {
                spacing: 6px;
                Text { text: "Charlie"; font-family: "Georgia"; font-size: 15px; color: #f0e0c0; vertical-alignment: center; }
                Text { text: root.version; font-size: 10px; color: #8a8f98; vertical-alignment: center; horizontal-stretch: 1; }
                Text { text: root.clock; font-size: 12px; color: #c0c0c0; vertical-alignment: center; }
            }
            for b in root.bars: HorizontalLayout {
                height: 5px;
                spacing: 4px;
                Text { text: b.mark; width: b.mark == "" ? 0px : 15px; font-size: 8px; color: #8a8f98; vertical-alignment: center; }
                Rectangle {
                    border-radius: 2px;
                    background: #2c2f38;
                    Rectangle { x: 0; y: 0; width: parent.width * clamp(b.percent, 0, 100) / 100; height: parent.height; border-radius: 2px; background: b.tint; }
                }
            }
            Rectangle { height: 1px; background: #3a3d47; }
            tl := VerticalLayout {
                spacing: 4px;
                for t in root.tiles: Rectangle {
                    height: 36px;
                    border-radius: 6px;
                    border-width: 1.5px;
                    border-color: t.tint;
                    background: t.wash;
                    Text { x: 8px; y: 0; height: parent.height; text: t.mark; color: t.tint; font-size: 12px; vertical-alignment: center; }
                    Text { x: 22px; y: 0; width: 46px; height: parent.height; text: t.clock; color: t.tint; font-family: "Consolas"; font-size: 14px; font-weight: 700; vertical-alignment: center; }
                    Text { x: 72px; y: 3px; width: parent.width - 156px; text: t.title; color: #e8e8e8; font-size: 12px; overflow: elide; }
                    Text { x: 72px; y: 19px; width: parent.width - 156px; text: t.project; color: #8a8f98; font-size: 10px; overflow: elide; }
                    if t.unread: Rectangle { x: parent.width - 9px; y: -4px; width: 13px; height: 13px; border-radius: 6.5px; background: #4fa1ff; border-width: 2px; border-color: #1e1f24; }
                }
            }
            if root.tiles.length == 0: Text { text: "no chats open"; font-size: 11px; color: #6b6f78; }
            if root.recent.length > 0: Text { text: "Recent"; font-size: 10px; color: #8a8f98; }
            for r in root.recent: HorizontalLayout {
                spacing: 6px;
                Text { text: r.title; font-size: 11px; color: #c8c8c8; overflow: elide; horizontal-stretch: 1; }
                Text { text: r.age; font-size: 10px; color: #6b6f78; horizontal-stretch: 0; }
            }
            Text { text: root.foot; font-size: 10px; color: #6b6f78; overflow: elide; }
        }
    }

    export component GateChip inherits Window {
        in property <color> tint;
        in property <string> label;
        no-frame: true;
        always-on-top: true;
        background: transparent;
        width: 64px;
        height: 26px;
        Rectangle {
            border-radius: 6px;
            background: #2c2f38;
            border-width: 1px;
            border-color: root.tint;
            Text { text: root.label; color: #f0f0f0; font-size: 11px; font-weight: 700; }
        }
    }

    // A bubble left of the panel, its tail pointing at the row.
    export component GateCard inherits Window {
        in property <string> name;
        in property <string> sub;
        in property <string> body;
        in property <string> reply;
        in property <string> foot;
        in property <color> tint: #c0a040;
        out property <length> want-height: vl.preferred-height;
        no-frame: true;
        always-on-top: true;
        background: transparent;
        width: 337px;
        height: vl.preferred-height;
        Rectangle { x: 0; y: 0; width: 330px; height: parent.height; border-radius: 8px; background: #1e1f24; border-width: 1px; border-color: root.tint; }
        Path { x: 328px; y: 14px; width: 9px; height: 16px; fill: #1e1f24; commands: "M 0 0 L 9 8 L 0 16 Z"; }
        vl := VerticalLayout {
            x: 0;
            y: 0;
            width: 330px;
            padding: 10px;
            spacing: 3px;
            Text { text: root.name; color: #f0f0f0; font-size: 13px; font-weight: 700; overflow: elide; }
            Text { text: root.sub; color: root.tint; font-size: 11px; overflow: elide; }
            Text { text: root.body; color: #d8d8d8; font-size: 12px; wrap: word-wrap; }
            if root.reply != "": Text { text: root.reply; color: #c8c8c8; font-size: 12px; wrap: word-wrap; }
            Text { text: root.foot; color: #8a8f98; font-size: 10px; wrap: word-wrap; }
        }
    }

    // The settings view: an opacity slider, in a window that never
    // activates. A press on it keeps the pointer (TouchArea's grab) past
    // the window's edge.
    export component GateSettings inherits Window {
        in-out property <float> value: 87;
        in property <string> note;
        callback changed(float);
        no-frame: true;
        always-on-top: true;
        background: transparent;
        width: 220px;
        height: 92px;
        Rectangle { border-radius: 8px; background: #1e1f24; border-width: 1px; border-color: #c0a040; }
        Text { x: 12px; y: 8px; text: "Opacity " + round(root.value) + "%"; color: #e8e8e8; font-size: 12px; }
        track := Rectangle {
            x: 12px;
            y: 40px;
            width: parent.width - 24px;
            height: 6px;
            border-radius: 3px;
            background: #3a3d47;
            Rectangle { x: 0; y: 0; height: parent.height; width: parent.width * (root.value - 30) / 70; border-radius: 3px; background: #4fa1ff; }
        }
        Rectangle { x: track.x + track.width * (root.value - 30) / 70 - 8px; y: track.y - 5px; width: 16px; height: 16px; border-radius: 8px; background: #e0e0e0; }
        ta := TouchArea {
            x: track.x - 8px;
            y: 24px;
            width: track.width + 16px;
            height: 40px;
            pointer-event(e) => {
                if e.kind == PointerEventKind.down {
                    root.value = clamp(30 + 70 * (self.mouse-x - 8px) / track.width, 30, 100);
                    root.changed(root.value);
                }
            }
            moved => {
                if self.pressed {
                    root.value = clamp(30 + 70 * (self.mouse-x - 8px) / track.width, 30, 100);
                    root.changed(root.value);
                }
            }
        }
        Text { x: 12px; y: 64px; width: parent.width - 24px; text: root.note; color: #8a8f98; font-size: 10px; overflow: elide; }
    }
}

const PANEL: usize = 0;
const BAR: usize = 1;
const EDGES: usize = 2;
const CHIP: usize = 3;
const CARD: usize = 4;
const SETTINGS: usize = 5;
const COUNT: usize = 6;
const NAMES: [&str; COUNT] = ["panel", "bar", "edges", "chip", "card", "settings"];
const Z_TOP_FIRST: [usize; COUNT] = [CARD, CHIP, SETTINGS, BAR, EDGES, PANEL];

// Logical pixels, as in the .slint above.
const PANEL_W: f32 = 300.0;
/// The tallest the panel gets (6 tiles, 8 Recent lines, 9 gauge bars):
/// home is placed for it, so the panel stays in the work area.
const MAX_PANEL_H: f32 = 560.0;
const BAR_X: f32 = 8.0;
const BAR_Y: f32 = 4.0;
const BAR_W: f32 = 284.0;
const BAR_H: f32 = 20.0;
const EDGE_OUT: f32 = 4.0;
const EDGE_DEEP: f32 = 7.0;
const TILE_STEP: f32 = 40.0;
const CHIP_IN: f32 = 15.0;
const CHIP_W: f32 = 64.0;
const CHIP_H: f32 = 26.0;
const CARD_W: f32 = 337.0;
const CARD_GAP: f32 = 5.0;
const SET_W: f32 = 220.0;
const SET_H: f32 = 92.0;
const MAX_TILES: usize = 6;
const MARGIN: i32 = 24;
const OFF: i32 = -32000;
/// --scale's waits (glue.rs): quiet this long before a re-place, and give
/// up waiting for all six to have the new DPI after this.
const SETTLE: Duration = Duration::from_millis(500);
const GIVE_UP: Duration = Duration::from_secs(15);

/// The real overlay's state colours (tray.rs COLORS), queued and recent added.
fn state_rgb(status: &str) -> u32 {
    match status {
        "busy" => 0x4CC38A,
        "running" => 0x4EA1FF,
        "waiting" | "needsInput" => 0xF5B942,
        "cutoff" => 0xFF8A4C,
        "queued" => 0xB48CFF,
        _ => 0x80868F,
    }
}

fn rgb(c: u32) -> Color {
    Color::from_rgb_u8((c >> 16) as u8, (c >> 8) as u8, c as u8)
}

fn rgba(c: u32, a: u8) -> Color {
    Color::from_argb_u8(a, (c >> 16) as u8, (c >> 8) as u8, c as u8)
}

fn severity_rgb(stale: bool, w: &content::Window) -> u32 {
    if stale {
        0x555A63
    } else if w.limited || w.severity == "critical" {
        0xFF5A5A
    } else if w.severity == "warning" {
        0xF5B942
    } else {
        0x5B9BD5
    }
}

/// Format-ChatOverlayRowClock, not live: hours h minutes from `since`.
fn row_clock(since: i64, now: i64) -> String {
    if since <= 0 {
        return "--:--".to_string();
    }
    let min = (now - since).max(0) / 60_000;
    let (hi, lo, sep) = if min < 6000 { (min / 60, min % 60, 'h') } else { ((min / 60 / 24).min(99), (min / 60) % 24, 'd') };
    let head = if hi >= 10 { format!("{hi:02}") } else { format!(" {hi}") };
    format!("{head}{sep}{lo:02}")
}

fn short(text: &str, n: usize) -> String {
    if text.chars().count() <= n { text.to_string() } else { text.chars().take(n - 1).chain(['…']).collect() }
}

/// What the card shows.
#[derive(Clone, Copy, PartialEq)]
enum Hover {
    Row(usize),
    Usage(usize),
}

#[derive(Default)]
struct Stats {
    applies: u32,
    redraws_view: u32,
    chip_shows: u32,
    card_shows: u32,
    card_height_wrong: u32,
    settings_opens: u32,
    slider_steps: u32,
    toggles: u32,
    probes: u32,
    probes_ok: u32,
    height_checks: u32,
    worst_top_drift: i32,
    worst_height_err: i32,
    worst_helper_err: i32,
    restacks: u32,
    topmost_wrong: u32,
    styles_checks: u32,
    styles_wrong: u32,
    foreground_ours: u32,
    poll_ticks: u32,
    pointer_moves: u32,
    dpi_changes: u32,
    bar_presses: u32,
    /// poll ticks skipped while the input desktop was another, and the spells
    desktop_away: u32,
    away_spells: u32,
    /// card replies from the read-load stand-in: heard, and set on a card shown
    replies_heard: u32,
    replies_shown: u32,
}

struct Gate {
    panel: GatePanel,
    bar: Strip,
    edges: Edges,
    chip: GateChip,
    card: GateCard,
    settings: GateSettings,
    hwnd: Cell<[HWND; COUNT]>,
    made: Cell<usize>,
    shown: Cell<bool>,
    scale: Cell<f32>,
    work: Cell<RECT>,
    dpi: Cell<u32>,
    home: Cell<(i32, i32)>,
    snap: RefCell<Option<Snapshot>>,
    tiles: Rc<VecModel<GateTile>>,
    hover: Cell<Hover>,
    hover_n: Cell<usize>,
    /// steps on row hovers only, so every row gets its turn
    row_n: Cell<usize>,
    /// Claude's newest reply, cut as the card shows it, by session id: what
    /// the read-load stand-in's card tail found (--gate only)
    replies: RefCell<std::collections::HashMap<String, String>>,
    away: Cell<bool>,
    locked: Cell<bool>,
    opacity: Cell<f32>,
    settings_open: Cell<bool>,
    slide_dir: Cell<f32>,
    recent_cut: Cell<bool>,
    tick: Cell<u64>,
    started: Instant,
    age_class: Cell<u8>,
    /// (first message, last message or re-place) of a screen change being handled
    change: Cell<Option<(Instant, Instant)>>,
    press: Cell<Option<(i32, i32, i32, i32)>>,
    poll_was: Cell<(bool, bool)>,
    frame: Cell<u32>,
    closing: Cell<bool>,
    ui_only: bool,
    targets: Arc<Mutex<readload::Targets>>,
    timers: RefCell<Vec<slint::Timer>>,
    stats: RefCell<Stats>,
}

thread_local! {
    static GATE: RefCell<Option<Rc<Gate>>> = const { RefCell::new(None) };
}

fn with_gate(f: impl FnOnce(&Rc<Gate>)) {
    let g = GATE.with(|x| x.borrow().clone());
    if let Some(g) = g {
        f(&g);
    }
}

impl Gate {
    fn window(&self, i: usize) -> &slint::Window {
        match i {
            PANEL => self.panel.window(),
            BAR => self.bar.window(),
            EDGES => self.edges.window(),
            CHIP => self.chip.window(),
            CARD => self.card.window(),
            _ => self.settings.window(),
        }
    }

    fn h(&self, i: usize) -> HWND {
        self.hwnd.get()[i]
    }

    fn r(&self, v: f32) -> i32 {
        (v * self.scale.get()).round() as i32
    }

    /// A logical size as Slint makes it physical (glue.rs, Glue::px).
    fn px(&self, v: f32) -> i32 {
        let (v, s) = (f64::from(v), f64::from(self.scale.get()));
        let mut up = v.ceil().max((((v * s).ceil() - 0.5) / s).ceil());
        if (up * s).round() < v * s {
            up += 1.0;
        }
        (up * s).round() as i32
    }

    fn z_top_first(&self) -> Vec<HWND> {
        Z_TOP_FIRST.iter().map(|&i| self.h(i)).collect()
    }

    fn height_of(&self, i: usize) -> i32 {
        let r = win32::window_rect(self.h(i));
        r.bottom - r.top
    }

    /// Where the chip and the card's tail point: the hovered row's top, in
    /// logical px inside the panel.
    fn hover_y(&self) -> f32 {
        match self.hover.get() {
            Hover::Row(k) => self.panel.get_tiles_y() + k as f32 * TILE_STEP,
            Hover::Usage(_) => 50.0,
        }
    }

    /// Where each window belongs for a panel at `p`.
    fn targets_for(&self, p: RECT) -> [RECT; COUNT] {
        let out = self.r(EDGE_OUT);
        let y = self.hover_y();
        let card_w = self.px(CARD_W);
        [
            p,
            sized(p.left + self.r(BAR_X), p.top + self.r(BAR_Y), self.px(BAR_W), self.px(BAR_H)),
            RECT { left: p.left - out, top: p.top - out, right: p.right + out, bottom: p.bottom + out },
            sized(p.right - self.r(CHIP_IN) - self.px(CHIP_W), p.top + self.r(y + 5.0), self.px(CHIP_W), self.px(CHIP_H)),
            sized(p.left - self.r(CARD_GAP) - card_w, p.top + self.r(y), card_w, self.height_of(CARD)),
            sized(p.right - self.px(SET_W), p.top - self.r(6.0) - self.px(SET_H), self.px(SET_W), self.px(SET_H)),
        ]
    }

    fn targets(&self) -> [RECT; COUNT] {
        self.targets_for(win32::window_rect(self.h(PANEL)))
    }

    /// Each with the panel at home, sized as Slint wants it now.
    fn wanted(&self) -> [RECT; COUNT] {
        let (x, y) = self.home.get();
        let mut t = self.targets_for(sized(x, y, self.px(PANEL_W), self.px(self.panel.get_want_height())));
        t[CARD].bottom = t[CARD].top + self.px(self.card.get_want_height());
        t
    }

    fn home_in(&self, work: RECT) -> (i32, i32) {
        (work.right - MARGIN - self.px(PANEL_W), work.bottom - MARGIN - self.px(MAX_PANEL_H))
    }

    fn edge_strips(&self) -> [RECT; 2] {
        let r = win32::window_rect(self.h(EDGES));
        let (w, height, deep) = (r.right - r.left, r.bottom - r.top, self.r(EDGE_DEEP));
        [RECT { left: 0, top: 0, right: w, bottom: deep }, RECT { left: 0, top: height - deep, right: w, bottom: height }]
    }

    fn cut_edges(&self) {
        win32::set_region(self.h(EDGES), Some(&self.edge_strips()));
    }

    /// The helpers to their places by the panel; the edges sized with it.
    /// Not while a screen change is handled (glue.rs, Glue::follow).
    fn follow(&self) {
        if self.change.get().is_some() || !self.shown.get() {
            return;
        }
        let want = self.targets();
        for i in [BAR, EDGES, CHIP, CARD, SETTINGS] {
            let (h, t) = (self.h(i), want[i]);
            let r = win32::window_rect(h);
            if r == t {
                continue;
            }
            if i == EDGES && (r.right - r.left, r.bottom - r.top) != (t.right - t.left, t.bottom - t.top) {
                win32::set_rect(h, t);
                self.cut_edges();
            } else if (r.left, r.top) != (t.left, t.top) {
                win32::move_window(h, t.left, t.top);
            }
        }
    }

    /// All six to a panel at (x, y), in one batch, positions only.
    fn place_all(&self, x: i32, y: i32) {
        let p = win32::window_rect(self.h(PANEL));
        let want = self.targets_for(sized(x, y, p.right - p.left, p.bottom - p.top));
        let moves: Vec<(HWND, i32, i32)> = (0..COUNT).map(|i| (self.h(i), want[i].left, want[i].top)).collect();
        win32::move_together(&moves);
    }

    /// After a scale or work-area change (glue.rs, Glue::replace): the
    /// monitor's DPI and work area read again; a window Slint already has
    /// at the new scale sized through Slint from its logical size, the rest
    /// only moved (the move brings their WM_DPICHANGED); all six moved in
    /// one batch, SWP_NOSIZE; the edges recut, the z-order restacked.
    fn replace(&self) {
        let (work, _) = win32::monitor_of(self.h(PANEL));
        let dpi = win32::monitor_dpi(self.h(PANEL));
        let s = dpi as f32 / 96.0;
        self.work.set(work);
        self.dpi.set(dpi);
        self.scale.set(s);
        self.home.set(self.home_in(work));
        let want = self.wanted();
        for i in 0..COUNT {
            let w = self.window(i);
            let (width, height) = (want[i].right - want[i].left, want[i].bottom - want[i].top);
            if (w.scale_factor() - s).abs() < 0.001 && (w.size().width as i32, w.size().height as i32) != (width, height) && i != EDGES {
                w.set_size(slint::LogicalSize::new(width as f32 / s, height as f32 / s));
            }
        }
        let moves: Vec<(HWND, i32, i32)> = (0..COUNT).map(|i| (self.h(i), want[i].left, want[i].top)).collect();
        win32::move_together(&moves);
        let e = want[EDGES];
        win32::set_rect(self.h(EDGES), e);
        self.cut_edges();
        let gold = self.edges.get_gold();
        self.edges.set_gold(Color::from_rgb_u8(gold.red(), gold.green(), gold.blue() ^ 1));
        win32::stack_topmost(&self.z_top_first());
    }

    fn behind(&self, dpi: u32) -> Vec<&'static str> {
        (0..COUNT)
            .filter(|&i| win32::dpi(self.h(i)) != dpi || (self.window(i).scale_factor() - dpi as f32 / 96.0).abs() >= 0.001)
            .map(|i| NAMES[i])
            .collect()
    }

    /// A good snapshot from the file: the panel redrawn only when what it
    /// shows changed; the readload's targets and the tray's text kept up.
    fn apply(self: &Rc<Self>, snap: Snapshot) {
        sample::SNAP_AT.store(snap.at, SeqCst);
        self.stats.borrow_mut().applies += 1;
        let same = self.snap.borrow().as_ref().is_some_and(|s| s.sig == snap.sig);
        if same {
            self.snap.borrow_mut().as_mut().unwrap().at = snap.at;
            return;
        }
        self.stats.borrow_mut().redraws_view += 1;
        let v = &snap.view;
        self.draw(v);
        {
            let mut t = self.targets.lock().unwrap();
            t.open = v.rows.iter().filter(|r| !r.session_id.is_empty()).map(|r| (r.session_id.clone(), r.cwd.clone())).collect();
        }
        tray::set_tip(&tooltip(v));
        selflog::line(&format!(
            "content: view {} drawn: {} rows ({} as tiles), {} recent, {} usage providers; {} bytes, written {} s ago",
            self.stats.borrow().redraws_view,
            v.rows.len(),
            v.rows.len().min(MAX_TILES),
            v.recent.len(),
            v.usage.len(),
            snap.bytes,
            (content::epoch_ms() - snap.at) / 1000
        ));
        *self.snap.borrow_mut() = Some(snap);
    }

    /// A reply the card tail found (readload.rs): kept for the chat, and set
    /// on the card at once when it is up for that chat.
    fn on_reply(&self, sid: String, reply: String) {
        self.stats.borrow_mut().replies_heard += 1;
        let showing = win32::is_visible(self.h(CARD))
            && match self.hover.get() {
                Hover::Row(k) => self.snap.borrow().as_ref().and_then(|s| s.view.rows.get(k)).is_some_and(|r| r.session_id == sid),
                Hover::Usage(_) => false,
            };
        if showing && self.card.get_reply().as_str() != reply {
            self.card.set_reply(reply.as_str().into());
            self.stats.borrow_mut().replies_shown += 1;
        }
        self.replies.borrow_mut().insert(sid, reply);
    }

    /// The panel's models from the view.
    fn draw(&self, v: &View) {
        let active: Vec<&content::Usage> =
            v.usage.iter().filter(|u| v.rows.iter().any(|r| r.provider.eq_ignore_ascii_case(&u.provider))).collect();
        let letter = active.len() > 1;
        let mut bars = Vec::new();
        for u in &active {
            for (n, w) in u.windows.iter().enumerate() {
                let mark = if letter && n == 0 {
                    match u.provider.to_ascii_lowercase().as_str() {
                        "claude" => "Cl",
                        "codex" => "Cx",
                        "copilot" => "Cp",
                        _ => "?",
                    }
                } else {
                    ""
                };
                bars.push(GateBar { mark: mark.into(), percent: w.percent as f32, tint: rgb(severity_rgb(u.stale, w)) });
            }
        }
        self.panel.set_bars(ModelRc::new(VecModel::from(bars)));
        let now = content::epoch_ms();
        let tiles: Vec<GateTile> = v
            .rows
            .iter()
            .take(MAX_TILES)
            .map(|r| {
                let c = state_rgb(&r.status);
                let wash = if matches!(r.status.as_str(), "busy" | "waiting" | "needsInput") { rgba(c, 0x30) } else { Color::from_argb_u8(0, 0, 0, 0) };
                let mark = match r.place.as_str() {
                    "vscode" => "◆",
                    "terminal" => "▮",
                    "run" => "▶",
                    _ => "●",
                };
                GateTile {
                    title: short(&r.title, 80).into(),
                    project: r.project.clone().into(),
                    clock: row_clock(r.since, now).into(),
                    mark: mark.into(),
                    tint: rgb(c),
                    wash,
                    unread: r.unread,
                }
            })
            .collect();
        self.tiles.set_vec(tiles);
        self.draw_recent(v);
        self.panel.set_version(format!("v{}", v.version).into());
    }

    fn draw_recent(&self, v: &View) {
        let n = (v.recent_count.max(0) as usize).min(8);
        let n = if self.recent_cut.get() { n.saturating_sub(3) } else { n };
        let lines: Vec<GateLine> =
            v.recent.iter().take(n).map(|r| GateLine { title: short(&r.title, 80).into(), age: r.state_text.clone().into() }).collect();
        self.panel.set_recent(ModelRc::new(VecModel::from(lines)));
    }

    /// The most urgent state of the open rows: the dot's colour.
    fn dot_rgb(&self) -> u32 {
        let snap = self.snap.borrow();
        let Some(s) = snap.as_ref() else { return state_rgb("idle") };
        for st in ["waiting", "needsInput", "cutoff", "busy", "running", "queued"] {
            if s.view.rows.iter().any(|r| r.status == st) {
                return state_rgb(st);
            }
        }
        state_rgb("idle")
    }

    fn recent_titles(&self) -> Vec<String> {
        self.snap.borrow().as_ref().map_or(Vec::new(), |s| s.view.recent.iter().take(8).map(|r| r.title.clone()).collect())
    }

    fn set_opacity(&self, o: f32) {
        self.opacity.set(o);
        self.panel.set_body_opacity(o);
        self.bar.set_paint_opacity(o);
    }

    /// The panel click-through or not; the bar keeps its clicks either way.
    fn set_locked(&self, on: bool) {
        self.locked.set(on);
        self.panel.window().with_winit_window(|w| w.set_cursor_hittest(!on).unwrap());
        if win32::exstyle(self.h(PANEL)) & WS_EX_LAYERED.0 != 0 {
            win32::layered_opaque(self.h(PANEL));
        }
        self.stats.borrow_mut().toggles += 1;
    }

    /// The close by hand's order: the close balloon, 4 s, the icon, the loop.
    fn begin_close(self: &Rc<Self>, why: &str) {
        if self.closing.replace(true) {
            return;
        }
        selflog::line(&format!("gate close: begun ({why}); close balloon, then 4 s"));
        tray::balloon("M9 spike closing", "From the M9 spike gate run: closing in 4 s. Its tray icon goes then.");
        later(4000, || {
            tray::remove_icon();
            selflog::line("gate close: event loop ends");
            let _ = slint::quit_event_loop();
        });
    }

    fn summary(&self) {
        let s = self.stats.borrow();
        selflog::line(&format!(
            "gate summary exercise: snapshots applied {} (views drawn {}); chip shows {}; card shows {} (height wrong {}); settings opens {}, slider steps {}; click-through toggles {}, probes {}/{} as wanted; height checks {} (worst top drift {}px, height error {}px, helper error {}px); restacks {}, topmost wrong {}; styles checks {} wrong {}; foreground ours {}; poll ticks {}, pointer transitions {}, skipped with the input desktop away {} (spells {}); screen changes {}; bar presses {}; card replies heard {}, shown {}; style rewrites undone {}",
            s.applies, s.redraws_view, s.chip_shows, s.card_shows, s.card_height_wrong, s.settings_opens, s.slider_steps, s.toggles, s.probes_ok, s.probes,
            s.height_checks, s.worst_top_drift, s.worst_height_err, s.worst_helper_err, s.restacks, s.topmost_wrong, s.styles_checks, s.styles_wrong,
            s.foreground_ours, s.poll_ticks, s.pointer_moves, s.desktop_away, s.away_spells, s.dpi_changes, s.bar_presses, s.replies_heard,
            s.replies_shown, win32::style_fixes()
        ));
    }
}

/// Format-ChatOverlayTooltip, from the snapshot's counts and Claude's 5h.
fn tooltip(v: &View) -> String {
    let c = &v.counts;
    let mut bits = Vec::new();
    let need = c.waiting + c.needs_input;
    if need > 0 {
        bits.push(format!("{need} need you"));
    }
    if c.unread > 0 {
        bits.push(format!("{} new", c.unread));
    }
    if c.cut_off > 0 {
        bits.push(format!("{} cut off", c.cut_off));
    }
    for (n, w) in [(c.busy, "working"), (c.running, "running"), (c.idle, "idle"), (c.queued, "queued")] {
        if n > 0 {
            bits.push(format!("{n} {w}"));
        }
    }
    if bits.is_empty() {
        bits.push("no chats open".into());
    }
    let mut t = format!("Charlie (M9 spike): {}", bits.join(", "));
    if let Some(w) = v.usage.iter().find(|u| u.provider == "Claude").and_then(|u| u.windows.iter().find(|w| w.label == "5h")) {
        t += &format!(" - 5h {}%", w.percent);
    }
    // the Recent titles after it, so the cut at 127 units is reached
    for r in v.recent.iter().take(3) {
        t += &format!(" · {}", r.title);
    }
    t
}

fn sized(x: i32, y: i32, w: i32, h: i32) -> RECT {
    RECT { left: x, top: y, right: x + w, bottom: y + h }
}

fn side_error(a: RECT, b: RECT) -> i32 {
    [a.left - b.left, a.top - b.top, a.right - b.right, a.bottom - b.bottom].into_iter().map(i32::abs).max().unwrap()
}

/// Runs the gate to its end: the event loop included. `ui_only`: no
/// read-load stand-in, overlay.json read once.
pub fn run(ui_only: bool, seconds: u64) {
    crate::han_fallbacks();
    let stop = Arc::new(AtomicBool::new(false));
    let mut reader = content::Reader::new();
    selflog::line(&format!("gate: {} from {}", if ui_only { "ui-only" } else { "full" }, content::path().display()));
    let first = reader.read();
    let tiles = Rc::new(VecModel::<GateTile>::default());
    let g = Rc::new(Gate {
        panel: GatePanel::new().unwrap(),
        bar: Strip::new().unwrap(),
        edges: Edges::new().unwrap(),
        chip: GateChip::new().unwrap(),
        card: GateCard::new().unwrap(),
        settings: GateSettings::new().unwrap(),
        hwnd: Cell::new([HWND::default(); COUNT]),
        made: Cell::new(0),
        shown: Cell::new(false),
        scale: Cell::new(1.0),
        work: Cell::new(RECT::default()),
        dpi: Cell::new(96),
        home: Cell::new((0, 0)),
        snap: RefCell::new(None),
        tiles: tiles.clone(),
        hover: Cell::new(Hover::Row(0)),
        hover_n: Cell::new(0),
        row_n: Cell::new(0),
        replies: RefCell::new(std::collections::HashMap::new()),
        away: Cell::new(false),
        locked: Cell::new(false),
        opacity: Cell::new(1.0),
        settings_open: Cell::new(false),
        slide_dir: Cell::new(-1.0),
        recent_cut: Cell::new(false),
        tick: Cell::new(0),
        started: Instant::now(),
        age_class: Cell::new(u8::MAX),
        change: Cell::new(None),
        press: Cell::new(None),
        poll_was: Cell::new((false, false)),
        frame: Cell::new(0),
        closing: Cell::new(false),
        ui_only,
        targets: Arc::new(Mutex::new(readload::Targets::default())),
        timers: RefCell::new(Vec::new()),
        stats: RefCell::new(Stats::default()),
    });
    g.panel.set_tiles(ModelRc::from(tiles));
    g.bar.set_w(BAR_W);
    g.bar.set_h(BAR_H);
    g.bar.set_label("Charlie  ·  drag".into());
    let c = g.clone();
    g.bar.on_pointer(move |kind| on_bar(&c, &kind));
    let c = g.clone();
    g.bar.on_dragged(move || on_drag(&c));
    let c = g.clone();
    g.settings.on_changed(move |v| c.set_opacity(v / 100.0));
    GATE.with(|x| *x.borrow_mut() = Some(g.clone()));
    if let Some(snap) = first {
        let o = snap.view.opacity_pct.clamp(30, 100) as f32;
        g.settings.set_value(o);
        g.set_opacity(o / 100.0);
        g.apply(snap);
    } else {
        selflog::line("content: no snapshot at the start; the panel shows none until one reads");
    }

    let content_thread = if ui_only {
        selflog::line("content: --ui-only, overlay.json not polled after the first read");
        None
    } else {
        Some(content::spawn(reader, stop.clone(), |snap| {
            let _ = slint::invoke_from_event_loop(move || with_gate(|g| g.apply(snap)));
        }))
    };
    let readload_thread = if ui_only {
        None
    } else {
        Some(readload::spawn(g.targets.clone(), stop.clone(), |sid, reply| {
            let _ = slint::invoke_from_event_loop(move || with_gate(|g| g.on_reply(sid, reply)));
        }))
    };
    // logs the gate figure itself, at minute 60 or at the stop: neither a
    // frozen UI loop (the tray menu's) nor a worker's panic can lose it
    let sampler = sample::spawn(stop.clone());

    let locked = g.locked.get();
    tray::setup(
        &g.snap.borrow().as_ref().map_or("Charlie (M9 spike): no snapshot".to_string(), |s| tooltip(&s.view)),
        g.dot_rgb(),
        locked,
        &g.recent_titles(),
        |what| {
            with_gate(|g| match what {
                "lock" => g.set_locked(!g.locked.get()),
                "quit" => g.begin_close("Quit in the tray menu"),
                _ => {}
            })
        },
    );
    for i in 0..COUNT {
        adopt(&g, i);
    }
    slint::Timer::single_shot(Duration::from_secs(seconds), || with_gate(|g| g.begin_close("the run's --seconds are up")));
    slint::run_event_loop_until_quit().unwrap();

    stop.store(true, SeqCst);
    g.timers.borrow_mut().clear();
    tray::finish();
    // a worker's panic is in the log already (selflog's hook); the rest of
    // the summary still comes
    if let Some(Ok((reads, failures))) = content_thread.map(|t| t.join()) {
        selflog::line(&format!("gate summary content: {reads} reads after the first, {failures} failed"));
    }
    if let Some(Ok(t)) = readload_thread.map(|t| t.join()) {
        selflog::line(&format!(
            "gate summary readload: {} passes, {} bytes read ({:.1} MB), {} ms in all, slowest {} ms, {} errors",
            t.passes,
            t.bytes,
            t.bytes as f64 / 1048576.0,
            t.ms_total,
            t.ms_max,
            t.errors
        ));
    }
    g.summary();
    let _ = sampler.join();
    GATE.with(|x| x.borrow_mut().take());
}

/// Made off-screen by Slint once the loop runs; the overlay's styles while
/// hidden. Once all six exist they are placed and shown.
fn adopt(g: &Rc<Gate>, i: usize) {
    g.window(i).set_position(slint::PhysicalPosition::new(OFF, OFF));
    let g = g.clone();
    slint::spawn_local(async move {
        let winit_window = g.window(i).winit_window().await.expect("winit window");
        let hwnd = win32::hwnd_of(&winit_window);
        win32::make_overlay(hwnd);
        let mut all = g.hwnd.get();
        all[i] = hwnd;
        g.hwnd.set(all);
        g.made.set(g.made.get() + 1);
        if g.made.get() == COUNT {
            place_and_show(&g);
        }
    })
    .unwrap();
}

fn place_and_show(g: &Rc<Gate>) {
    let panel = g.h(PANEL);
    let (work, monitor) = win32::monitor_of(panel);
    g.work.set(work);
    g.scale.set(g.panel.window().scale_factor());
    g.dpi.set(win32::monitor_dpi(panel));
    g.home.set(g.home_in(work));
    selflog::line(&format!(
        "gate: work area {}, monitor {}, {} dpi, Slint scale {}; home {:?}",
        rect_text(work),
        rect_text(monitor),
        g.dpi.get(),
        g.scale.get(),
        g.home.get()
    ));
    let c = g.clone();
    win32::on_moved(panel, move || c.follow());
    g.card.window().with_winit_window(|w| w.set_cursor_hittest(false).unwrap());
    win32::layered_opaque(g.h(CARD));
    let c = g.clone();
    win32::on_screen_change(move |hwnd, _dpi, text| {
        let who = c.hwnd.get().iter().position(|&h| h == hwnd).map_or("other", |i| NAMES[i]);
        selflog::line(&format!("gate screen: {who}: {text}"));
        heard(&c);
    });
    for i in 0..COUNT {
        let c = g.clone();
        g.window(i).on_winit_window_event(move |w, event| {
            if let winit::event::WindowEvent::ScaleFactorChanged { scale_factor, .. } = event {
                selflog::line(&format!("gate screen: {}: winit ScaleFactorChanged to {scale_factor}; Slint's still {}", NAMES[i], w.scale_factor()));
                heard(&c);
            }
            EventResult::Propagate
        });
    }
    // all six to their places while hidden, in one batch: the panel's
    // height is Slint's preferred one, the helpers from it
    let (x, y) = g.home.get();
    g.place_all(x, y);
    for i in [PANEL, EDGES, BAR] {
        g.window(i).show().unwrap();
    }
    g.shown.set(true);
    g.follow();
    win32::stack_topmost(&g.z_top_first());
    let c = g.clone();
    later(400, move || started(&c));
}

/// The windows up: the placing read back, then every timer.
fn started(g: &Rc<Gate>) {
    let want = g.wanted();
    for i in [PANEL, BAR, EDGES] {
        let r = win32::window_rect(g.h(i));
        selflog::line(&format!(
            "gate shown {}: at {} want {}, error {}px; styles_ok {}",
            NAMES[i],
            rect_text(r),
            rect_text(want[i]),
            side_error(r, want[i]),
            win32::styles_ok(win32::exstyle(g.h(i)))
        ));
    }
    let mut timers = g.timers.borrow_mut();
    let c = g.clone();
    timers.push(repeat(Duration::from_secs(1), move || tick(&c)));
    let c = g.clone();
    timers.push(repeat(Duration::from_millis(250), move || slide(&c)));
    let c = g.clone();
    timers.push(repeat(Duration::from_millis(120), move || poll(&c)));
    let c = g.clone();
    timers.push(repeat(Duration::from_secs(5), move || {
        win32::stack_topmost(&c.z_top_first());
        let wrong = (0..COUNT).filter(|&i| win32::is_visible(c.h(i)) && !win32::is_topmost(c.h(i))).count() as u32;
        let mut s = c.stats.borrow_mut();
        s.restacks += 1;
        s.topmost_wrong += wrong;
    }));
    let c = g.clone();
    timers.push(repeat(Duration::from_secs(2), move || {
        // the dot, a frame of the busy spin's ring in two brightnesses
        let f = c.frame.get() + 1;
        c.frame.set(f);
        let rgb = c.dot_rgb();
        tray::redraw(if f % 2 == 0 { rgb } else { (rgb >> 1) & 0x7F7F7F | 0x404040 });
    }));
    let c = g.clone();
    timers.push(repeat(Duration::from_secs(30), move || tray::rebuild(c.locked.get(), &c.recent_titles())));
    let c = g.clone();
    timers.push(repeat(Duration::from_millis(100), move || screen_poll(&c)));
    let c = g.clone();
    timers.push(repeat(Duration::from_secs(60), move || styles_check(&c)));
    drop(timers);
    later(8000, || tray::balloon("M9 spike gate", "From the M9 spike gate run (overlay-spike), not Charlie. Nothing to do."));
}

/// Every second: the clocks, the snapshot's age, the foreground read, and
/// the exercise's steps.
fn tick(g: &Rc<Gate>) {
    let t = g.tick.get() + 1;
    g.tick.set(t);
    let now = content::epoch_ms();
    g.panel.set_clock(win32::local_hms().into());
    if let Some(snap) = g.snap.borrow().as_ref() {
        for (k, r) in snap.view.rows.iter().take(MAX_TILES).enumerate() {
            if let Some(mut tile) = g.tiles.row_data(k) {
                let clock: slint::SharedString = row_clock(r.since, now).into();
                if tile.clock != clock {
                    tile.clock = clock;
                    g.tiles.set_row_data(k, tile);
                }
            }
        }
    }
    let at = sample::SNAP_AT.load(SeqCst);
    let age = if at > 0 { (now - at) / 1000 } else { -1 };
    // fresh: within the overlay's 10 s rewrite and a pass or two; stale: up
    // to 5 min; old past that
    let class = match age {
        a if a < 0 => 3,
        0..=30 => 0,
        31..=300 => 1,
        _ => 2,
    };
    if class != g.age_class.get() {
        selflog::line(&format!("content: snapshot now {} ({age} s old)", ["fresh", "stale", "old", "none"][class as usize]));
        g.age_class.set(class);
    }
    let up = g.started.elapsed().as_secs();
    g.panel.set_foot(
        format!(
            "{} · snapshot {}s · {} {:02}:{:02}:{:02}",
            if g.locked.get() { "locked" } else { "unlocked" },
            age,
            if g.ui_only { "ui-only" } else { "gate" },
            up / 3600,
            up / 60 % 60,
            up % 60
        )
        .into(),
    );
    if win32::is_ours(win32::foreground()) {
        let mut s = g.stats.borrow_mut();
        s.foreground_ours += 1;
        if s.foreground_ours <= 5 {
            selflog::line("gate: the foreground window is OURS");
        }
    }
    if g.closing.get() || g.change.get().is_some() {
        return;
    }
    exercise(g, t);
}

fn exercise(g: &Rc<Gate>, t: u64) {
    let (rows, usage) = g.snap.borrow().as_ref().map_or((0, 0), |s| (s.view.rows.len().min(MAX_TILES), s.view.usage.len()));
    match t % 12 {
        0 => {
            let n = g.hover_n.get() + 1;
            g.hover_n.set(n);
            // every third hover the card is a usage gauge's
            // the rows by a count of their own, so with 3 or 6 rows each
            // still gets its turn
            g.hover.set(if rows == 0 || (n % 3 == 0 && usage > 0) {
                Hover::Usage((n / 3) % usage.max(1))
            } else {
                let k = g.row_n.get();
                g.row_n.set(k + 1);
                Hover::Row(k % rows)
            });
            if let Hover::Row(k) = g.hover.get() {
                let tint = g.tiles.row_data(k).map_or(Color::from_rgb_u8(0x80, 0x86, 0x8f), |t| t.tint);
                g.chip.set_tint(tint);
                g.chip.set_label(format!("open {}", k + 1).into());
                show_at(g, CHIP);
                g.stats.borrow_mut().chip_shows += 1;
            }
        }
        2 => {
            card_content(g);
            show_at(g, CARD);
            g.stats.borrow_mut().card_shows += 1;
            let c = g.clone();
            later(300, move || {
                let (h, want) = (c.height_of(CARD), c.px(c.card.get_want_height()));
                if h != want {
                    c.stats.borrow_mut().card_height_wrong += 1;
                    selflog::line(&format!("gate card: {h}px high, Slint wants {want}px"));
                }
            });
        }
        7 => g.card.window().hide().unwrap(),
        8 => g.chip.window().hide().unwrap(),
        _ => {}
    }
    if t % 10 == 5 {
        g.set_locked(!g.locked.get());
        let c = g.clone();
        later(300, move || probe(&c));
    }
    match t % 60 {
        20 => {
            g.settings_open.set(true);
            g.settings.set_note(format!("driven by the gate's timer · open {}", g.stats.borrow().settings_opens + 1).into());
            show_at(g, SETTINGS);
            g.stats.borrow_mut().settings_opens += 1;
        }
        32 => {
            g.settings_open.set(false);
            g.settings.window().hide().unwrap();
        }
        _ => {}
    }
    if t % 30 == 15 {
        height_change(g);
    }
}

/// A helper moved to its place for the current hover, cloaked until
/// painted (against the layered card's stale picture), shown, restacked.
fn show_at(g: &Rc<Gate>, i: usize) {
    let want = g.targets()[i];
    let r = win32::window_rect(g.h(i));
    if (r.left, r.top) != (want.left, want.top) {
        win32::move_window(g.h(i), want.left, want.top);
    }
    if i != SETTINGS {
        win32::cloak_until_painted(g.h(i));
    }
    g.window(i).show().unwrap();
    win32::stack_topmost(&g.z_top_first());
}

/// The card's text for the hover: a row's (title, project, state, its
/// prompt as the overlay shows it) or a usage gauge's (windows, resets).
fn card_content(g: &Gate) {
    let snap = g.snap.borrow();
    let Some(s) = snap.as_ref() else {
        g.card.set_name("no snapshot".into());
        return;
    };
    let now = content::epoch_ms();
    match g.hover.get() {
        Hover::Row(k) => {
            let Some(r) = s.view.rows.get(k) else { return };
            g.card.set_tint(rgb(state_rgb(&r.status)));
            g.card.set_name(short(&r.title, 80).into());
            g.card.set_sub(format!("{} · {}", r.project, r.state_text).into());
            g.card.set_body(short(&r.prompt, 240).into());
            // the reply the card tail found last for this chat, if any yet;
            // a new one comes in by on_reply while the card is up
            g.card.set_reply(g.replies.borrow().get(&r.session_id).cloned().unwrap_or_default().into());
            g.card.set_foot(format!("hover {} · {} · since {}", g.hover_n.get(), r.place, row_clock(r.since, now).trim()).into());
        }
        Hover::Usage(k) => {
            let Some(u) = s.view.usage.get(k) else { return };
            g.card.set_tint(rgb(0x5B9BD5));
            g.card.set_name(u.provider.clone().into());
            g.card.set_reply("".into());
            g.card.set_sub(format!("{} · {}", if u.stale { "stale" } else { "live" }, u.status).into());
            let windows: Vec<String> = u.windows.iter().map(|w| format!("{} {}%", w.label, w.percent)).collect();
            g.card.set_body(windows.join(" · ").into());
            let resets: Vec<String> = u
                .windows
                .iter()
                .filter(|w| w.resets_at > now)
                .map(|w| {
                    let m = (w.resets_at - now) / 60_000;
                    format!("{} resets in {}h{:02}", w.label, m / 60, m % 60)
                })
                .collect();
            g.card.set_foot(resets.join(" · ").into());
        }
    }
    if let Hover::Row(_) = g.hover.get() {
        let row = s.view.rows.get(match g.hover.get() {
            Hover::Row(k) => k,
            _ => 0,
        });
        g.targets.lock().unwrap().card = row.map(|r| (r.session_id.clone(), r.cwd.clone()));
    }
}

/// Every 250 ms while the settings window is open: the slider a step on,
/// back and forth over 30-100%, and the opacity with it.
fn slide(g: &Rc<Gate>) {
    if !g.settings_open.get() {
        return;
    }
    let mut v = g.settings.get_value() + 5.0 * g.slide_dir.get();
    if v <= 30.0 || v >= 100.0 {
        v = v.clamp(30.0, 100.0);
        g.slide_dir.set(-g.slide_dir.get());
    }
    g.settings.set_value(v);
    g.set_opacity(v / 100.0);
    g.stats.borrow_mut().slider_steps += 1;
}

/// WindowFromPoint on the panel's body and on the bar: the body ours only
/// while unlocked, the bar ours always.
fn probe(g: &Rc<Gate>) {
    let p = win32::window_rect(g.h(PANEL));
    let b = win32::window_rect(g.h(BAR));
    let body = win32::window_from_point(p.left + g.r(150.0), p.top + g.r(40.0));
    let bar = win32::window_from_point(b.left + g.r(10.0), (b.top + b.bottom) / 2);
    let body_ok = (body == g.h(PANEL)) != g.locked.get() && (!g.locked.get() || !g.hwnd.get().contains(&body));
    let bar_ok = bar == g.h(BAR);
    let mut s = g.stats.borrow_mut();
    s.probes += 2;
    s.probes_ok += u32::from(body_ok) + u32::from(bar_ok);
    if !body_ok || !bar_ok {
        selflog::line(&format!(
            "gate probe WRONG: locked {}; body hit {} ({}), bar hit {} ({})",
            g.locked.get(),
            win32::class_name(body),
            body_ok,
            win32::class_name(bar),
            bar_ok
        ));
    }
}

/// The Recent count cut by 3 or given back: the panel's height follows
/// Slint's preferred height, its top held; read back 400 ms on.
fn height_change(g: &Rc<Gate>) {
    let before = win32::window_rect(g.h(PANEL));
    g.recent_cut.set(!g.recent_cut.get());
    if let Some(s) = g.snap.borrow().as_ref() {
        g.draw_recent(&s.view);
    }
    let c = g.clone();
    later(400, move || {
        let r = win32::window_rect(c.h(PANEL));
        let want = c.px(c.panel.get_want_height());
        let drift = (r.top - before.top).abs().max((r.left - before.left).abs());
        let err = (r.bottom - r.top - want).abs();
        let want_all = c.targets();
        let helper = [BAR, EDGES].into_iter().map(|i| side_error(win32::window_rect(c.h(i)), want_all[i])).max().unwrap();
        let mut s = c.stats.borrow_mut();
        s.height_checks += 1;
        s.worst_top_drift = s.worst_top_drift.max(drift);
        s.worst_height_err = s.worst_height_err.max(err);
        s.worst_helper_err = s.worst_helper_err.max(helper);
        if drift != 0 || err != 0 || helper != 0 || s.height_checks <= 2 {
            selflog::line(&format!(
                "gate height {}: panel {}px -> {}px (Slint wants {want}px), top-left drift {drift}px, helper error {helper}px",
                s.height_checks,
                before.bottom - before.top,
                r.bottom - r.top
            ));
        }
    });
}

/// The 120 ms poll of the pointer and the left button (reads only), as
/// Update-ChatOverlayHover reads them; transitions onto and off the panel
/// counted, the first few logged.
fn poll(g: &Rc<Gate>) {
    let mut s = g.stats.borrow_mut();
    s.poll_ticks += 1;
    if !win32::is_visible(g.h(PANEL)) {
        return;
    }
    // None while the input desktop is another (the PC locked, UAC): the tick
    // skipped, counted, the first of each spell logged
    let Some((x, y)) = win32::cursor_now() else {
        s.desktop_away += 1;
        if !g.away.replace(true) {
            s.away_spells += 1;
            selflog::line(&format!("gate poll: the input desktop is another (locked, UAC?); ticks skipped, spell {}", s.away_spells));
        }
        return;
    };
    if g.away.replace(false) {
        selflog::line(&format!("gate poll: the input desktop is back; {} ticks skipped so far", s.desktop_away));
    }
    let inside = win32::contains(&win32::window_rect(g.h(PANEL)), x, y);
    let (down, _) = win32::left_button();
    let (was_in, was_down) = g.poll_was.get();
    if inside != was_in || (inside && down != was_down) {
        s.pointer_moves += 1;
        if s.pointer_moves <= 20 {
            selflog::line(&format!("gate poll: pointer {} the panel, button {}", if inside { "on" } else { "off" }, if down { "down" } else { "up" }));
        }
    }
    g.poll_was.set((inside, down));
}

/// The styles of all six read back once a minute.
fn styles_check(g: &Rc<Gate>) {
    let wrong: Vec<&str> = (0..COUNT).filter(|&i| !win32::styles_ok(win32::exstyle(g.h(i)))).map(|i| NAMES[i]).collect();
    let mut s = g.stats.borrow_mut();
    s.styles_checks += 1;
    if !wrong.is_empty() {
        s.styles_wrong += 1;
        selflog::line(&format!("gate styles WRONG: {wrong:?}"));
    }
}

/// A screen message: a change opened, or kept open (glue.rs, heard).
fn heard(g: &Gate) {
    let now = Instant::now();
    let first = g.change.get().map_or(now, |c| c.0);
    if g.change.get().is_none() {
        g.stats.borrow_mut().dpi_changes += 1;
    }
    g.change.set(Some((first, now)));
}

/// Every 100 ms: a change no message told of caught by its effect; an open
/// change re-placed once quiet SETTLE, again until all six have the new
/// DPI with Slint's scale to match, or GIVE_UP from its first message.
fn screen_poll(g: &Rc<Gate>) {
    let (work, _) = win32::monitor_of(g.h(PANEL));
    let dpi = win32::monitor_dpi(g.h(PANEL));
    if g.change.get().is_none() {
        if work == g.work.get() && dpi == g.dpi.get() {
            return;
        }
        selflog::line(&format!("gate screen: a change no message told of: {dpi} dpi, work area {}", rect_text(work)));
        heard(g);
    }
    let (first, last) = g.change.get().unwrap();
    if last.elapsed() < SETTLE {
        return;
    }
    let behind = g.behind(dpi);
    if behind.is_empty() || first.elapsed() >= GIVE_UP {
        g.replace();
        selflog::line(&format!(
            "gate screen: change done {:.1} s after its first message, {dpi} dpi, work area {}; {}",
            first.elapsed().as_secs_f32(),
            rect_text(work),
            if behind.is_empty() { "all six at the new DPI".to_string() } else { format!("GAVE UP, not there: {behind:?}") }
        ));
        g.change.set(None);
        return;
    }
    g.replace();
    selflog::line(&format!("gate screen: re-placed for {dpi} dpi; not yet there: {behind:?}"));
    g.change.set(Some((first, Instant::now())));
}

/// The bar's press and release: a drag begins or ends (glue.rs, on_bar).
fn on_bar(g: &Rc<Gate>, kind: &str) {
    if kind == "down" {
        let Some((mx, my)) = win32::cursor_now() else { return };
        let p = win32::window_rect(g.h(PANEL));
        g.press.set(Some((mx, my, p.left, p.top)));
        g.stats.borrow_mut().bar_presses += 1;
        selflog::line(&format!("gate bar: down; foreground ours {}", win32::is_ours(win32::foreground())));
    } else if g.press.take().is_some() {
        let p = win32::window_rect(g.h(PANEL));
        selflog::line(&format!("gate bar: {kind}; panel at {},{}", p.left, p.top));
    }
}

fn on_drag(g: &Rc<Gate>) {
    let Some((mx, my, px, py)) = g.press.get() else { return };
    let Some((cx, cy)) = win32::cursor_now() else { return };
    g.place_all(px + cx - mx, py + cy - my);
}
