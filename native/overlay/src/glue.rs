// M9 spike, step 3: the overlay's five windows glued together (--glued).
//
// The real overlay is five top-level windows, all no-activate and topmost.
// Here each is a Slint window of its own with the same job (overlay-windows.ps1):
//
//   panel  'Charlie'               New-ChatOverlayWindow
//   bar    'chatoverlay controls'  New-ChatOverlayControlsWindow,
//                                  placed by Set-ChatOverlayControlsPlacement
//   edges  'chatoverlay edges'     New-ChatOverlayEdgesWindow, Get-ChatOverlayEdgesRect
//   chip   'chatoverlay open'      New-ChatOverlayChipWindow
//   card   'Charlie card'          New-ChatOverlayCardWindow, Get-ChatOverlayCardPlacement
//
// Top first: card, chip, bar, edges, panel, as Invoke-ChatOverlayTick keeps
// them. The helpers follow the panel from its WM_WINDOWPOSCHANGED (win32.rs,
// on_moved), as the real ones follow its LocationChanged and SizeChanged.
//
// About 86 s hands off, the phase in large letters on the panel:
//   START   each window made off-screen, moved into place, then shown; the
//           placing error read back right after each show
//   GLUE    10 panel moves: the odd ones move the panel alone and the
//           helpers follow, the even ones move all five in one DeferWindowPos
//           batch. A thread reads the screen after DWM frames meanwhile,
//           to catch a frame with the windows apart
//   Z       another topmost window over ours, then ours re-asserted over it
//   FLASH   the chip and the card shown and hidden 200 times each, the
//           content changed while hidden; what the screen shows right after
//           each show is judged fresh, stale, black or see-through. The
//           last 100 of each are cloaked until painted, against the layered
//           card's stale picture
//   HEIGHT  the card 1..8 lines, the panel 1..4 rows: the height is Slint's
//           preferred height, the top edge stays, the edges follow
//   HANDS   until the run ends: drag the bar, watch the chip and the card
//
// The z-order is re-asserted every 5 s and after every show, and checked by
// a walk of the z-order and by WindowFromPoint (the 5 s check just before
// its re-assert). Nothing activates; the
// pointer is only read.
//
// --scale starts the same way, skips GLUE, Z and FLASH, and waits for the
// user to change Windows' display scale (or the work area):
//   CHECKING  the re-place handler run once at the current DPI, which must
//             move nothing, then the checks below
//   SCALE     waiting; every WM_DPICHANGED, winit ScaleFactorChanged,
//             WM_DISPLAYCHANGE and work-area WM_SETTINGCHANGE is logged
//   CHANGE    one of them heard (or the monitor's DPI or work area found
//             changed): a check round still running is dropped at once, the
//             helpers stop following the panel, and each window's
//             WM_DPICHANGED is timed. 500 ms after the last message, the
//             re-place handler (Glue::replace): all five moved for the
//             monitor's new DPI in one batch, which brings the
//             WM_DPICHANGED still to come; then a wait, up to 15 s from the
//             first message, for all five to have the new DPI with Slint's
//             scale to match, and the re-place again, now sizing each
//             through Slint from its logical size; quiet for 500 ms
//   CHECKING  the re-place handler again, which must now move nothing;
//             placement, helper error, all five still in place and what
//             Slint draws, Slint, winit and Windows agreeing 300 ms on,
//             frames painted for 3 s, edges ring, work area, z-order, card
//             alpha, one HEIGHT round, a 20-show FLASH pass (all cloaked);
//             if the wait gave up, nothing from the edges' pixels on
//   PASSED / FAILED  in large letters, with the DPI; back to waiting
// --poke adds a test with no real change: after the self-test, the program
// sends its own windows WM_DPICHANGED to another DPI and straight back, two
// of them first and three 1.5 s later (which drops round 2 in its checks),
// then once more during round 3's FLASH pass (poke).
// --pretend instead pretends Windows' scale changed after the self-test,
// and changed back after the next round (pretend, win32::pretend_dpi).
//
// Windows' own reaction, from the hand runs of 2026-10-20: a scale change
// reaches each window's WM_DPICHANGED (and its GetDpiForWindow) only when
// that window is next moved, sized or (once) restacked - by our re-place,
// by Slint resizing the card or panel, by the 5 s z-order re-assert - not
// when the scale changes, not on a show or hide, and not by itself within
// 8 s. So waiting for the messages waits for nothing: the re-place is what
// delivers them. winit (event_loop.rs, WM_DPICHANGED) then sizes the
// window from its current size and Slint follows, so the re-place must not
// have sized it first (Glue::replace: that made Slint panic). Slint
// (winitwindowadapter.rs, ScaleFactorChanged) only takes the new scale
// factor, and corrects no size under 1 logical px off; winit's sizes, each
// from the last, drift by rounding (chip 64x26 -> 96x40 -> 64x27 -> 96x41),
// which is why the re-place sizes every window from logical once it has
// the new scale.

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use slint::winit_030::{EventResult, WinitWindowAccessor, winit};
use slint::{Color, ComponentHandle};
use windows::Win32::Foundation::{HWND, RECT};

use crate::mouse::Strip;
use crate::win32::rect_text;
use crate::{later, repeat, selflog, win32};

slint::slint! {
    export component GluePanel inherits Window {
        in property <string> phase;
        in property <color> phase-color: #a0a0a0;
        in property <string> hint;
        in property <string> status;
        in property <string> verdict;
        in property <int> rows: 2;
        out property <length> want-height: vl.preferred-height;
        no-frame: true;
        always-on-top: true;
        background: transparent;
        width: 300px;
        height: vl.preferred-height;

        Rectangle {
            border-radius: 8px;
            background: #1e1f24;
            border-width: 1px;
            border-color: #c0a040;
        }
        // Where the glue trace looks for the panel.
        Rectangle { x: 270px; y: 36px; width: 12px; height: 12px; background: #20c0c0; }
        Text { x: 12px; y: 26px; width: 250px; text: root.phase; color: root.phase-color; font-size: 26px; font-weight: 700; }
        Text { x: 12px; y: 64px; width: 276px; text: root.hint; color: #e8e8e8; font-size: 12px; }
        Text { x: 12px; y: 80px; width: 276px; text: root.status; color: #b8b8b8; font-size: 12px; }
        Text { x: 12px; y: 96px; width: 276px; text: root.verdict; color: #f0d090; font-size: 12px; }
        vl := VerticalLayout {
            padding-top: 116px;
            padding-bottom: 10px;
            padding-left: 11px;
            padding-right: 11px;
            spacing: 4px;
            for i in root.rows: Rectangle {
                height: 40px;
                border-radius: 6px;
                background: #3a3d47;
                Text { text: "row " + (i + 1); color: #d0d0d0; font-size: 12px; }
            }
        }
    }

    // No size of its own: the panel's rect plus a margin, set from outside.
    // Its window region keeps only the two strips (glue.rs, follow), so the
    // middle neither covers the panel nor takes its clicks.
    export component Edges inherits Window {
        // Nudged one step after the region is recut deeper (glue.rs, replace).
        in property <color> gold: #c0a040;
        no-frame: true;
        always-on-top: true;
        background: transparent;
        Rectangle { x: 0; y: 0; width: parent.width; height: 7px; background: root.gold; }
        Rectangle { x: 0; y: parent.height - 7px; width: parent.width; height: 7px; background: root.gold; }
    }

    export component Chip inherits Window {
        in property <color> swatch;
        in property <string> label;
        no-frame: true;
        always-on-top: true;
        background: transparent;
        width: 64px;
        height: 26px;
        Rectangle {
            border-radius: 6px;
            background: root.swatch;
            Text { x: 34px; text: root.label; color: #101010; font-size: 12px; font-weight: 700; }
        }
    }

    // A bubble left of the panel, its tail pointing at row 1.
    export component Card inherits Window {
        in property <color> swatch;
        in property <string> label;
        in property <int> lines: 1;
        out property <length> want-height: vl.preferred-height;
        no-frame: true;
        always-on-top: true;
        background: transparent;
        width: 337px;
        height: vl.preferred-height;
        Rectangle {
            x: 0;
            y: 0;
            width: 330px;
            height: parent.height;
            border-radius: 8px;
            background: #1e1f24;
            border-width: 1px;
            border-color: #c0a040;
        }
        Path { x: 328px; y: 14px; width: 9px; height: 16px; fill: #1e1f24; commands: "M 0 0 L 9 8 L 0 16 Z"; }
        vl := VerticalLayout {
            x: 0;
            y: 0;
            width: 330px;
            padding: 10px;
            spacing: 3px;
            Rectangle {
                height: 24px;
                border-radius: 4px;
                background: root.swatch;
                Text { x: 220px; text: root.label; color: #101010; font-size: 12px; font-weight: 700; }
            }
            for i in root.lines: Text { text: "card line " + (i + 1) + " of " + root.lines; color: #e0e0e0; font-size: 12px; }
        }
    }
}

const PANEL: usize = 0;
const BAR: usize = 1;
const EDGES: usize = 2;
const CHIP: usize = 3;
const CARD: usize = 4;
const NAMES: [&str; 5] = ["panel", "bar", "edges", "chip", "card"];
const Z_TOP_FIRST: [usize; 5] = [CARD, CHIP, BAR, EDGES, PANEL];
const SHOW_ORDER: [usize; 5] = [PANEL, EDGES, BAR, CHIP, CARD];

// Logical pixels, as in the .slint above.
const PANEL_W: f32 = 300.0;
/// 4 rows: 116 + 4 * 40 + 3 * 4 + 10. Home is placed for this, so the
/// panel stays inside the work area at any row count.
const MAX_PANEL_H: f32 = 298.0;
const BAR_X: f32 = 8.0;
const BAR_Y: f32 = 4.0;
const BAR_W: f32 = 284.0;
const BAR_H: f32 = 20.0;
const EDGE_OUT: f32 = 4.0;
const EDGE_DEEP: f32 = 7.0;
const ROW1_Y: f32 = 116.0;
/// The chip sits on row 1's right end, centred on it.
const CHIP_IN: f32 = 15.0;
const CHIP_Y: f32 = 123.0;
const CHIP_W: f32 = 64.0;
const CHIP_H: f32 = 26.0;
const CARD_W: f32 = 337.0;
const CARD_GAP: f32 = 5.0;
const MARGIN: i32 = 24;
/// Where windows are made: off every screen.
const OFF: i32 = -32000;

// Screen colours as COLORREF (0x00BBGGRR), as win32::capture reads them.
const MARK: u32 = 0x00c0_c020; // #20c0c0, the panel's marker
const BLUE: u32 = 0x00a8_6f3d; // #3d6fa8, mouse.rs Strip
const GOLD: u32 = 0x0040_a0c0; // #c0a040, the edges
/// The chip's and card's content colours, one per show in turn. Before
/// FLASH both show the last one, so show k's stale colour is always k - 1's.
const PALETTE: [u32; 6] = [
    0x0030_30e0,
    0x0040_c030,
    0x00f0_6030,
    0x0020_d0f0,
    0x00d0_40c0,
    0x0020_80f0,
];

const MOVES: u32 = 10;
/// Shows per window in FLASH, in four runs of 50 (segment).
const SHOWS: usize = 200;
/// Shows per window in the FLASH pass after a scale change (segment).
const SCALE_SHOWS: usize = 20;
/// --scale: how long after the last screen message the re-place and the
/// checks wait, and the longest, from the first message, they wait for all
/// five windows and Slint to agree on the new DPI.
const SETTLE: Duration = Duration::from_millis(500);
const GIVE_UP: Duration = Duration::from_secs(15);
/// FLASH's tallies, by window and by whether it was cloaked until painted.
const SLOTS: [&str; 4] = ["chip", "card", "chip cloaked", "card cloaked"];
/// At most this many frames per traced show (it stops at the hide anyway).
const TRACE_FRAMES: usize = 6;
/// Frames read per forced show, the UI thread blocked throughout: one alone
/// could be DWM not composing the newly shown window yet, which reads as
/// see-through whatever the window holds.
const FORCED_FRAMES: usize = 3;
/// A frame's kind: Fresh, Stale (the last show's content), Black, Under
/// (see-through: what is behind), Other.
const KINDS: [char; 5] = ['F', 'S', 'B', 'U', 'O'];

struct Glue {
    panel: GluePanel,
    bar: Strip,
    edges: Edges,
    chip: Chip,
    card: Card,
    hwnd: Cell<[HWND; 5]>,
    made: Cell<usize>,
    /// The panel's scale, read once: follow runs inside window messages,
    /// where Slint is best left alone.
    scale: Cell<f32>,
    work: Cell<RECT>,
    home: Cell<(i32, i32)>,
    intruder: Cell<HWND>,
    /// z-order checks run, and how many found something wrong
    z: Cell<(u32, u32)>,
    glue_worst: Cell<i32>,
    /// HEIGHT: worst top-left drift, worst height error, worst helper error
    height_worst: Cell<[i32; 3]>,
    /// a bar press: the pointer and the panel where it began
    press: Cell<Option<(i32, i32, i32, i32)>>,
    /// the drag so far: steps, worst helper error
    drag: Cell<(u32, i32)>,
    timers: RefCell<Vec<slint::Timer>>,
    /// --scale given
    scale_test: bool,
    /// --poke given
    poke: bool,
    /// --pretend given
    pretend: bool,
    /// the monitor's DPI when last re-placed
    dpi: Cell<u32>,
    /// the screen change being handled, until its check round starts; the
    /// helpers do not follow the panel meanwhile
    change: Cell<Option<Change>>,
    /// a check round is running
    busy: Cell<bool>,
    /// bumped when a check round is dropped: the steps it scheduled (after)
    /// then do nothing
    epoch: Cell<u32>,
    rounds: Cell<u32>,
    /// what failed in this check round
    fails: RefCell<Vec<String>>,
    /// stale or black shows in the last FLASH pass
    flash_bad: Cell<u32>,
    /// the scale poll's reads that found one of ours in the foreground
    focus_ours: Cell<u32>,
    /// Slint's preferred heights (panel, card), logical px, at the first round
    first_heights: Cell<(f32, f32)>,
}

/// One screen change, from its first message until its check round starts.
#[derive(Clone, Copy)]
struct Change {
    first: Instant,
    /// the last message, or the last re-place
    last: Instant,
    /// per window, its last WM_DPICHANGED: s after `first`, the DPI, and
    /// the call of ours it came inside
    got: [Option<(f32, u32, &'static str)>; 5],
    /// what the five were last re-placed for in this change: DPI, work
    /// area, and whether all five had that DPI then
    placed: Option<(u32, RECT, bool)>,
}

impl Change {
    fn new() -> Change {
        let now = Instant::now();
        Change {
            first: now,
            last: now,
            got: [None; 5],
            placed: None,
        }
    }
}

/// GLUE, per mode (follow, batch): moves traced, moves seen apart, frames
/// apart, moves done before the first frame (nothing to see), moves whose
/// last frame did not show all five in place. Written by the trace threads.
static MOVE_TRACES: Mutex<[[u32; 5]; 2]> = Mutex::new([[0; 5]; 2]);

/// FLASH, one per SLOTS entry. Written by the UI and trace threads.
#[derive(Clone, Default)]
struct Flash {
    shows: u32,
    /// shows where what is behind looks like the fresh, stale or black colour
    ambiguous: u32,
    traced: u32,
    /// traced shows with a stale or black frame before the first fresh one
    flashes: u32,
    stale_frames: u32,
    black_frames: u32,
    never_fresh: u32,
    /// ms from the show to the first fresh frame read, the slowest
    worst_to_fresh: u32,
    /// (flash frames, ms to fresh) of the worst traced show, and its trace
    worst_key: (u32, u32),
    worst: String,
    /// forced shows by the worst kind among the frames composed before Slint can paint
    forced: [u32; 5],
    settled_wrong: u32,
    wrong_height: u32,
    foreground_ours: u32,
}

static FLASH: Mutex<Vec<Flash>> = Mutex::new(Vec::new());

impl Glue {
    fn window(&self, i: usize) -> &slint::Window {
        match i {
            PANEL => self.panel.window(),
            BAR => self.bar.window(),
            EDGES => self.edges.window(),
            CHIP => self.chip.window(),
            _ => self.card.window(),
        }
    }

    fn h(&self, i: usize) -> HWND {
        self.hwnd.get()[i]
    }

    fn who(&self, hwnd: HWND) -> String {
        match self.hwnd.get().iter().position(|&h| h == hwnd) {
            Some(i) => NAMES[i].to_string(),
            None if hwnd == self.intruder.get() => "intruder".to_string(),
            None => format!("other:{}", win32::class_name(hwnd)),
        }
    }

    /// Logical pixels to physical ones: offsets.
    fn r(&self, v: f32) -> i32 {
        (v * self.scale.get()).round() as i32
    }

    /// A window's logical size to physical pixels, as Slint sizes its
    /// windows (winitwindowadapter.rs, round_up_logical): the smallest
    /// whole logical size whose rounded physical size is at least
    /// v x scale. At 125% the card's 337 px is 423, not 421; Slint grows
    /// a window back to this whenever its constraints change.
    fn px(&self, v: f32) -> i32 {
        let (v, s) = (f64::from(v), f64::from(self.scale.get()));
        let mut up = v.ceil().max((((v * s).ceil() - 0.5) / s).ceil());
        if (up * s).round() < v * s {
            up += 1.0;
        }
        (up * s).round() as i32
    }

    /// The window item's logical size: what the software renderer draws,
    /// times Slint's scale, into a buffer of Slint's physical size
    /// (i-slint-renderer-software lib.rs, the size assert). Read as the
    /// renderer reads it, through Slint's private API: an out property
    /// bound to the card's width said 337 while its item held more.
    fn item_size(&self, i: usize) -> (f32, f32) {
        use slint::private_unstable_api::re_exports::WindowInner;
        let item = WindowInner::from_pub(self.window(i)).window_item().unwrap();
        let item = item.as_pin_ref();
        (item.width().get(), item.height().get())
    }

    fn z_top_first(&self) -> [HWND; 5] {
        Z_TOP_FIRST.map(|i| self.h(i))
    }

    fn card_h(&self) -> i32 {
        let r = win32::window_rect(self.h(CARD));
        r.bottom - r.top
    }

    /// The panel's rect were it at (x, y).
    fn panel_at(&self, x: i32, y: i32) -> RECT {
        let p = win32::window_rect(self.h(PANEL));
        sized(x, y, p.right - p.left, p.bottom - p.top)
    }

    /// Where each window belongs for a panel at `p` (the panel's own is `p`).
    fn targets_for(&self, p: RECT, card_h: i32) -> [RECT; 5] {
        let out = self.r(EDGE_OUT);
        let card_w = self.px(CARD_W);
        [
            p,
            sized(
                p.left + self.r(BAR_X),
                p.top + self.r(BAR_Y),
                self.px(BAR_W),
                self.px(BAR_H),
            ),
            RECT {
                left: p.left - out,
                top: p.top - out,
                right: p.right + out,
                bottom: p.bottom + out,
            },
            sized(
                p.right - self.r(CHIP_IN) - self.px(CHIP_W),
                p.top + self.r(CHIP_Y),
                self.px(CHIP_W),
                self.px(CHIP_H),
            ),
            sized(
                p.left - self.r(CARD_GAP) - card_w,
                p.top + self.r(ROW1_Y),
                card_w,
                card_h,
            ),
        ]
    }

    fn targets(&self) -> [RECT; 5] {
        self.targets_for(win32::window_rect(self.h(PANEL)), self.card_h())
    }

    /// Where each window belongs with the panel at home, sized as Slint
    /// wants it at the current scale.
    fn wanted(&self) -> [RECT; 5] {
        let (x, y) = self.home.get();
        let p = sized(
            x,
            y,
            self.px(PANEL_W),
            self.px(self.panel.get_want_height()),
        );
        self.targets_for(p, self.px(self.card.get_want_height()))
    }

    /// The panel's home: bottom-right of the work area.
    fn home_in(&self, work: RECT) -> (i32, i32) {
        (
            work.right - MARGIN - self.px(PANEL_W),
            work.bottom - MARGIN - self.px(MAX_PANEL_H),
        )
    }

    /// The edges' two strips, window-relative, for their current size.
    fn edge_strips(&self) -> [RECT; 2] {
        let r = win32::window_rect(self.h(EDGES));
        let (w, height, deep) = (r.right - r.left, r.bottom - r.top, self.r(EDGE_DEEP));
        [
            RECT {
                left: 0,
                top: 0,
                right: w,
                bottom: deep,
            },
            RECT {
                left: 0,
                top: height - deep,
                right: w,
                bottom: height,
            },
        ]
    }

    /// The edges' region cut to the two strips again.
    fn cut_edges(&self) {
        win32::set_region(self.h(EDGES), Some(&self.edge_strips()));
    }

    /// The re-place handler, after a scale or work-area change: work area,
    /// the monitor's DPI (not the windows' own or Slint's, which may not
    /// have heard yet) and home read again. A window Slint has at the
    /// monitor's scale is sized through Slint, as a logical size: the
    /// wanted one (constants and Slint's preferred heights, never the
    /// current rect, so rounding never compounds) over the scale; winit
    /// makes it physical at that scale, and Slint takes the Resized at it.
    /// A window not yet at the new scale is only moved: the move brings
    /// its WM_DPICHANGED, winit resizes it for the new scale and Slint
    /// follows (win32.rs, guard_proc); the poll re-places once more when
    /// all five have it. Sized from here behind Slint's back instead, a
    /// window still at the old scale had Slint take its new size as
    /// logical, 1.5 times too big once the scale came: Slint drew past the
    /// window and the software renderer panicked (2026-10-20). A size
    /// already right is not set: it brings no Resized, and Slint, waiting
    /// for one, would hold back its own resizes. All five are moved, no
    /// sizes, in one DeferWindowPos batch; the edges' region recut; the
    /// z-order re-stacked. Returns how far the window that moved most
    /// moved, px.
    fn replace(&self) -> i32 {
        let before: Vec<RECT> = (0..5).map(|i| win32::window_rect(self.h(i))).collect();
        let (work, _) = win32::monitor_of(self.h(PANEL));
        let dpi = win32::monitor_dpi(self.h(PANEL));
        let s = dpi as f32 / 96.0;
        self.work.set(work);
        self.dpi.set(dpi);
        self.scale.set(s);
        self.home.set(self.home_in(work));
        let want = self.wanted();
        for (i, r) in want.iter().enumerate().take(5) {
            let (w, (width, height)) = (self.window(i), (r.right - r.left, r.bottom - r.top));
            if (w.scale_factor() - s).abs() < 0.001
                && (w.size().width as i32, w.size().height as i32) != (width, height)
            {
                w.set_size(slint::LogicalSize::new(width as f32 / s, height as f32 / s));
            }
        }
        let moves: Vec<(HWND, i32, i32)> = (0..5)
            .map(|i| (self.h(i), want[i].left, want[i].top))
            .collect();
        win32::move_together(&moves);
        self.cut_edges();
        // Slint repaints only what changed, and after winit's resize it
        // painted inside the old, shallower region: the rows the new one
        // adds hold nothing. A one-step change of blue repaints the strips.
        let gold = self.edges.get_gold();
        self.edges.set_gold(Color::from_rgb_u8(
            gold.red(),
            gold.green(),
            gold.blue() ^ 1,
        ));
        win32::stack_topmost(&self.z_top_first());
        (0..5)
            .map(|i| side_error(before[i], win32::window_rect(self.h(i))))
            .max()
            .unwrap()
    }

    /// One check of this round failed: logged and kept for the verdict.
    fn fail(&self, what: String) {
        selflog::line(&format!("check FAILED: {what}"));
        self.fails.borrow_mut().push(what);
    }

    /// How far the worst helper is from where the panel says it belongs, px.
    fn worst_error(&self) -> i32 {
        let want = self.targets();
        (1..5)
            .map(|i| side_error(win32::window_rect(self.h(i)), want[i]))
            .max()
            .unwrap()
    }

    /// Each helper to its place by the panel; the edges resized too when the
    /// panel's size changed, and their region cut to the two strips again.
    /// Not while a screen change is being handled: winit moves and sizes
    /// each window on its own then, at a scale only some may have yet.
    fn follow(&self) {
        if self.change.get().is_some() {
            return;
        }
        let want = self.targets();
        for i in [BAR, EDGES, CHIP, CARD] {
            let (h, t) = (self.h(i), want[i]);
            let r = win32::window_rect(h);
            if r == t {
                continue;
            }
            if i == EDGES
                && (r.right - r.left, r.bottom - r.top) != (t.right - t.left, t.bottom - t.top)
            {
                win32::set_rect(h, t);
                self.cut_edges();
            } else {
                win32::move_window(h, t.left, t.top);
            }
        }
    }

    /// All five to a panel at (x, y) in one DeferWindowPos batch.
    fn place_all(&self, x: i32, y: i32) {
        let want = self.targets_for(self.panel_at(x, y), self.card_h());
        let moves: Vec<(HWND, i32, i32)> = (0..5)
            .map(|i| (self.h(i), want[i].left, want[i].top))
            .collect();
        win32::move_together(&moves);
    }

    /// (x, y) for the panel moved just enough that all five stay inside the work area.
    fn clamp(&self, x: i32, y: i32) -> (i32, i32) {
        let u = union(&self.targets_for(self.panel_at(x, y), self.card_h()));
        let w = self.work.get();
        (
            x + (w.left - u.left).max(0) - (u.right - w.right).max(0),
            y + (w.top - u.top).max(0) - (u.bottom - w.bottom).max(0),
        )
    }

    fn inside(&self) -> bool {
        let rects: Vec<RECT> = (0..5).map(|i| win32::window_rect(self.h(i))).collect();
        within(union(&rects), self.work.get())
    }

    /// Walks the z-order from the top and hit-tests a point on each window
    /// that takes clicks (the card does not). Wanted: ours visible in
    /// Z_TOP_FIRST order with nothing between, all topmost, each point
    /// hitting its own window - or the intruder, while it is on top.
    /// Logs always, or with `quiet` only when something is wrong.
    fn z_check(&self, label: &str, intruder_top: bool, quiet: bool) -> bool {
        let intruder = self.intruder.get();
        let shown: Vec<usize> = Z_TOP_FIRST
            .into_iter()
            .filter(|&i| win32::is_visible(self.h(i)))
            .collect();
        let mut want: Vec<&str> = shown.iter().map(|&i| NAMES[i]).collect();
        if intruder_top {
            want.insert(0, "intruder");
        }
        let (mut seen, mut above, mut between) = (Vec::new(), Vec::new(), Vec::new());
        let mut left = shown.len();
        for h in win32::z_order() {
            if left == 0 {
                break;
            }
            if !win32::is_visible(h) {
                continue;
            }
            if let Some(i) = self.hwnd.get().iter().position(|&o| o == h) {
                seen.push(NAMES[i]);
                left -= 1;
            } else if h == intruder {
                seen.push("intruder");
            } else if left < shown.len() {
                between.push(win32::class_name(h));
            } else if win32::is_topmost(h) {
                above.push(win32::class_name(h));
            }
        }
        let topmost = shown.iter().all(|&i| win32::is_topmost(self.h(i)));

        let rect = |i| win32::window_rect(self.h(i));
        let (p, bar, edges, chip) = (rect(PANEL), rect(BAR), rect(EDGES), rect(CHIP));
        let covered = |name| if intruder_top { "intruder" } else { name };
        let mut points = vec![
            (
                "bar",
                bar.left + self.r(10.0),
                (bar.top + bar.bottom) / 2,
                covered("bar"),
            ),
            (
                "edges",
                (edges.left + edges.right) / 2,
                edges.top + self.r(2.0),
                covered("edges"),
            ),
            (
                "panel",
                p.left + self.r(150.0),
                p.top + self.r(72.0),
                "panel",
            ),
        ];
        if shown.contains(&CHIP) {
            points.push((
                "chip",
                chip.left + self.r(8.0),
                chip.top + self.r(13.0),
                "chip",
            ));
        }
        let (mut hits_ok, mut hits) = (true, String::new());
        for (name, x, y, wanted) in points {
            let got = self.who(win32::window_from_point(x, y));
            hits_ok &= got == wanted;
            hits += &format!(" {name}={got}{}", if got == wanted { "" } else { "!" });
        }

        let ok = seen == want && topmost && hits_ok && between.is_empty();
        let (checks, bad) = self.z.get();
        self.z.set((checks + 1, bad + u32::from(!ok)));
        if !ok || !quiet {
            selflog::line(&format!(
                "z {label}: {}; order {} (want {}); all topmost {topmost}; hits{hits}; foreign topmost above ours {above:?}; foreign between ours {between:?}",
                if ok { "ok" } else { "WRONG" },
                seen.join(">"),
                want.join(">"),
            ));
        }
        ok
    }
}

/// `scale_test`: --scale, else --glued; `poke`, `pretend`: --poke,
/// --pretend (with --scale).
pub fn start(scale_test: bool, poke: bool, pretend: bool) {
    let g = Rc::new(Glue {
        panel: GluePanel::new().unwrap(),
        bar: Strip::new().unwrap(),
        edges: Edges::new().unwrap(),
        chip: Chip::new().unwrap(),
        card: Card::new().unwrap(),
        hwnd: Cell::new([HWND::default(); 5]),
        made: Cell::new(0),
        scale: Cell::new(1.0),
        work: Cell::new(RECT::default()),
        home: Cell::new((0, 0)),
        intruder: Cell::new(HWND::default()),
        z: Cell::new((0, 0)),
        glue_worst: Cell::new(0),
        height_worst: Cell::new([0; 3]),
        press: Cell::new(None),
        drag: Cell::new((0, 0)),
        timers: RefCell::new(Vec::new()),
        scale_test,
        poke,
        pretend,
        dpi: Cell::new(0),
        change: Cell::new(None),
        busy: Cell::new(false),
        epoch: Cell::new(0),
        rounds: Cell::new(0),
        fails: RefCell::new(Vec::new()),
        flash_bad: Cell::new(0),
        focus_ours: Cell::new(0),
        first_heights: Cell::new((0.0, 0.0)),
    });
    g.bar.set_w(BAR_W);
    g.bar.set_h(BAR_H);
    g.bar.set_label("bar - drag me".into());
    let c = g.clone();
    g.bar.on_pointer(move |kind| on_bar(&c, &kind));
    let c = g.clone();
    g.bar.on_dragged(move || on_drag(&c));
    // the last palette colour, so FLASH's first show has a known stale colour
    set_content(&g, CHIP, PALETTE.len() - 1);
    set_content(&g, CARD, PALETTE.len() - 1);
    set_phase(
        &g,
        "START",
        Color::from_rgb_u8(0xa0, 0xa0, 0xa0),
        "five windows: off-screen, placed, shown",
    );
    for i in 0..5 {
        adopt(&g, i);
    }
}

/// Made off-screen by Slint when the loop starts; given the overlay's
/// styles while hidden. Once all five exist they are placed and shown.
fn adopt(g: &Rc<Glue>, i: usize) {
    g.window(i)
        .set_position(slint::PhysicalPosition::new(OFF, OFF));
    let g = g.clone();
    slint::spawn_local(async move {
        let winit_window = g.window(i).winit_window().await.expect("winit window");
        let hwnd = win32::hwnd_of(&winit_window);
        win32::make_overlay(hwnd);
        let mut all = g.hwnd.get();
        all[i] = hwnd;
        g.hwnd.set(all);
        selflog::line(&format!(
            "{} made hidden at {}, visible={}",
            NAMES[i],
            rect_text(win32::window_rect(hwnd)),
            win32::is_visible(hwnd)
        ));
        g.made.set(g.made.get() + 1);
        if g.made.get() == 5 {
            place_and_show(&g);
        }
    })
    .unwrap();
}

fn place_and_show(g: &Rc<Glue>) {
    let panel = g.h(PANEL);
    let (work, monitor) = win32::monitor_of(panel);
    g.work.set(work);
    g.scale.set(g.panel.window().scale_factor());
    selflog::line(&format!(
        "work area {} (GetMonitorInfo rcWork; SPI_GETWORKAREA {}), monitor {}",
        rect_text(work),
        rect_text(win32::work_area()),
        rect_text(monitor)
    ));
    let dpis: Vec<String> = (0..5)
        .map(|i| format!("{}={}", NAMES[i], win32::dpi(g.h(i))))
        .collect();
    selflog::line(&format!(
        "GetDpiForWindow {}; Slint scale factor {} (not changed)",
        dpis.join(" "),
        g.scale.get()
    ));
    g.dpi.set(win32::dpi(panel));

    let home = g.home_in(work);
    g.home.set(home);
    let c = g.clone();
    win32::on_moved(panel, move || c.follow());
    // click-through, as the real card is: winit's WS_EX_TRANSPARENT | WS_EX_LAYERED
    g.card
        .window()
        .with_winit_window(|w| w.set_cursor_hittest(false).unwrap());
    win32::layered_opaque(g.h(CARD));
    // Before its first show the card's preferred height left out the lines
    // its `for` would make: 61 px (one line) for six, until the show laid
    // it out. So the wanted rects are taken after each show (show_next).
    selflog::line(&format!(
        "Slint's preferred heights before any show: panel {}px, card {}px",
        g.panel.get_want_height(),
        g.card.get_want_height()
    ));
    // Still hidden: the panel moves, the helpers follow it.
    win32::move_window(panel, home.0, home.1);
    show_next(g.clone(), 0);
}

/// One window shown every 150 ms; its rect read back right after the show,
/// against home and Slint's own sizes.
fn show_next(g: Rc<Glue>, n: usize) {
    if n == SHOW_ORDER.len() {
        after(&g, 400, |g| {
            selflog::line(&format!(
                "all five shown: worst helper error {}px; inside the work area {}",
                g.worst_error(),
                g.inside()
            ));
            g.z_check("start", false, false);
            let c = g.clone();
            // Checked before the re-assert, so it shows whether the order
            // held on its own since the last one, not only that one works.
            g.timers
                .borrow_mut()
                .push(repeat(Duration::from_secs(5), move || {
                    c.z_check("5 s, before the re-assert", false, false);
                    win32::stack_topmost(&c.z_top_first());
                }));
            if g.scale_test {
                scale_phase(g);
            } else {
                card_alpha(g, glue_phase);
            }
        });
        return;
    }
    let i = SHOW_ORDER[n];
    let hwnd = g.h(i);
    g.window(i).show().unwrap();
    let r = win32::window_rect(hwnd);
    let foreground_ours = win32::is_ours(win32::foreground());
    let want = g.wanted();
    win32::stack_topmost(&g.z_top_first());
    selflog::line(&format!(
        "shown {}: at {} want {}, error {}px; styles_ok={}; foreground ours {foreground_ours}",
        NAMES[i],
        rect_text(r),
        rect_text(want[i]),
        side_error(r, want[i]),
        win32::styles_ok(win32::exstyle(hwnd))
    ));
    later(150, move || show_next(g, n + 1));
}

/// The card over a magenta window: beside its tail it must show magenta
/// (the per-pixel alpha kept though the window is layered), on its body
/// the body's fill. Then `then`. The magenta window goes even if the round
/// was dropped meanwhile.
fn card_alpha(g: &Rc<Glue>, then: fn(&Rc<Glue>)) {
    let r = win32::window_rect(g.h(CARD));
    let magenta = win32::magenta_behind(g.h(CARD), r);
    let (g, epoch) = (g.clone(), g.epoch.get());
    later(500, move || {
        if g.epoch.get() != epoch {
            win32::destroy(magenta);
            return;
        }
        let g = &g;
        let got = read_points(&[
            (r.left + g.r(334.0), r.top + g.r(3.0)),
            (r.left + g.r(5.0), r.top + g.r(45.0)),
        ]);
        let ok = win32::close(got[0], win32::MAGENTA) && win32::close(got[1], win32::FILL);
        selflog::line(&format!(
            "card alpha, layered, over magenta: {}; beside the tail {:06x} (want ff00ff), body {:06x} (want 241f1e)",
            if ok { "works" } else { "FAILS" },
            got[0],
            got[1]
        ));
        if !ok {
            g.fail("card alpha over magenta".into());
        }
        win32::destroy(magenta);
        then(g);
    });
}

fn glue_phase(g: &Rc<Glue>) {
    set_phase(
        g,
        "GLUE",
        Color::from_rgb_u8(0xc0, 0xa0, 0x40),
        "10 panel moves; the helpers must follow",
    );
    for m in 1..=MOVES {
        after(g, 500 + 1500 * u64::from(m - 1), move |g| glue_move(g, m));
    }
    after(g, 1500 * u64::from(MOVES) + 500, |g| {
        let traces = *MOVE_TRACES.lock().unwrap();
        for (mode, [moves, apart, frames, early, missing]) in
            ["follow", "batch"].into_iter().zip(traces)
        {
            selflog::line(&format!(
                "glue {mode}: {moves} moves traced; seen apart in {apart} ({frames} frames); moved before the first frame {early}; not all in place at the last frame {missing}"
            ));
        }
        let apart: u32 = traces.iter().map(|t| t[1]).sum();
        let text = format!(
            "glue: worst helper error {}px, moves seen apart {apart}",
            g.glue_worst.get()
        );
        selflog::line(&text);
        g.panel.set_verdict(text.into());
        z_phase(g);
    });
}

/// Odd moves go up-left, the panel alone; even ones come home, all five in
/// a batch. The trace starts 50 ms before the move.
fn glue_move(g: &Rc<Glue>, m: u32) {
    let (hx, hy) = g.home.get();
    let batch = m.is_multiple_of(2);
    let k = (m / 2) as f32;
    let (x, y) = if batch {
        (hx, hy)
    } else {
        (hx - g.r(150.0 + 30.0 * k), hy - g.r(100.0 + 20.0 * k))
    };
    let mode = if batch { "batch" } else { "follow" };
    g.panel
        .set_status(format!("move {m}/{MOVES}, {mode}").into());

    let t = g.targets_for(g.panel_at(x, y), g.card_h());
    let inside = within(union(&t), g.work.get());
    let at = |r: RECT, dx: f32, dy: f32| (r.left + g.r(dx), r.top + g.r(dy));
    let points = vec![
        at(t[PANEL], 276.0, 42.0),
        at(t[BAR], 10.0, BAR_H / 2.0),
        (
            (t[EDGES].left + t[EDGES].right) / 2,
            t[EDGES].top + g.r(2.0),
        ),
        at(t[CHIP], 8.0, 13.0),
        at(t[CARD], 30.0, 22.0),
    ];
    let colours = [MARK, BLUE, GOLD, PALETTE[5], PALETTE[5]];
    std::thread::spawn(move || glue_trace(m, batch, points, colours));

    after(g, 50, move |g| {
        if batch {
            g.place_all(x, y);
        } else {
            win32::move_window(g.h(PANEL), x, y);
        }
        let now = g.worst_error();
        after(g, 300, move |g| {
            let settled = g.worst_error();
            g.glue_worst.set(g.glue_worst.get().max(now).max(settled));
            selflog::line(&format!(
                "glue move {m} ({mode}) to {x},{y}: worst helper error {now}px at once, {settled}px 300 ms on; all inside the work area {inside}"
            ));
        });
    });
}

/// Ten DWM frames read around one move, each a letter per window that shows
/// at its new place (p b e c k: panel bar edges chip card) or a dot, and
/// the ms since the trace began. A frame neither like the first nor all
/// five had some moved and others not. The read itself takes time, so not
/// every composed frame is read: the ms say which were.
fn glue_trace(m: u32, batch: bool, points: Vec<(i32, i32)>, colours: [u32; 5]) {
    let start = Instant::now();
    let (frames, times): (Vec<u32>, Vec<u128>) = (0..10)
        .map(|_| {
            win32::dwm_flush();
            let got = read_points(&points);
            let mask = (0..5).fold(0, |mask, i| {
                mask | (u32::from(win32::close(got[i], colours[i])) << i)
            });
            (mask, start.elapsed().as_millis())
        })
        .unzip();
    let all = 0b11111;
    let apart = frames
        .iter()
        .filter(|&&f| f != frames[0] && f != all)
        .count() as u32;
    let early = frames[0] == all;
    let missing = *frames.last().unwrap() != all;
    {
        let mut traces = MOVE_TRACES.lock().unwrap();
        let t = &mut traces[usize::from(batch)];
        t[0] += 1;
        t[1] += u32::from(apart > 0);
        t[2] += apart;
        t[3] += u32::from(early);
        t[4] += u32::from(missing);
    }
    let text: Vec<String> = frames
        .iter()
        .zip(times)
        .map(|(f, ms)| {
            let seen: String = (0..5)
                .map(|i| {
                    if f & (1 << i) != 0 {
                        b"pbeck"[i] as char
                    } else {
                        '.'
                    }
                })
                .collect();
            format!("{seen}@{ms}")
        })
        .collect();
    selflog::line(&format!(
        "glue trace move {m}: frames {}; apart {apart}",
        text.join(" ")
    ));
}

fn z_phase(g: &Rc<Glue>) {
    set_phase(
        g,
        "Z-ORDER",
        Color::from_rgb_u8(0xe0, 0x70, 0xe0),
        "another topmost window comes over the top",
    );
    let p = win32::window_rect(g.h(PANEL));
    let out = g.r(EDGE_OUT);
    let cover = RECT {
        left: p.left - out,
        top: p.top - out,
        right: p.right + out,
        bottom: p.top + g.r(60.0),
    };
    g.intruder.set(win32::magenta_topmost(cover));
    g.z_check("intruder just shown", true, false);
    after(g, 1000, |g| {
        win32::stack_topmost(&g.z_top_first());
        g.z_check("ours re-asserted over the intruder", false, false);
        after(g, 500, |g| {
            win32::destroy(g.intruder.get());
            g.intruder.set(HWND::default());
            g.z_check("intruder gone", false, false);
            after(g, 500, |g| {
                flash_phase(g, SHOWS, |g| height_phase(g, hands_phase))
            });
        });
    });
}

/// `shows` shows of the chip and of the card, then `then`.
fn flash_phase(g: &Rc<Glue>, shows: usize, then: fn(&Rc<Glue>)) {
    *FLASH.lock().unwrap() = vec![Flash::default(); SLOTS.len()];
    set_phase(
        g,
        "FLASH",
        Color::from_rgb_u8(0xff, 0x60, 0x60),
        &format!("chip and card shown and hidden {shows} times each"),
    );
    for i in [CHIP, CARD] {
        g.window(i).hide().unwrap();
        set_content(g, i, 0);
    }
    after(g, 300, move |g| flash_step(g, 0, shows, then));
}

fn flash_summary(g: &Rc<Glue>, then: fn(&Rc<Glue>)) {
    // the traces of the last shows may still be running
    after(g, 300, move |g| {
        let mut total = 0;
        for (name, f) in SLOTS.into_iter().zip(FLASH.lock().unwrap().iter()) {
            selflog::line(&format!(
                "flash {name}: {} shows, {} ambiguous; traced {}: flashed {} (stale frames {}, black {}), not fresh before the hide {}, slowest to fresh {}ms; forced, the worst of {FORCED_FRAMES} frames before Slint paints: F{} S{} B{} U{} O{}; wrong 60 ms on {}; wrong height at show {}; foreground ours {}; worst: {}",
                f.shows,
                f.ambiguous,
                f.traced,
                f.flashes,
                f.stale_frames,
                f.black_frames,
                f.never_fresh,
                f.worst_to_fresh,
                f.forced[0],
                f.forced[1],
                f.forced[2],
                f.forced[3],
                f.forced[4],
                f.settled_wrong,
                f.wrong_height,
                f.foreground_ours,
                if f.worst.is_empty() { "-" } else { &f.worst }
            ));
            total += f.flashes + f.forced[1] + f.forced[2];
        }
        g.panel
            .set_verdict(format!("flash: {total} stale or black shows").into());
        g.flash_bad.set(total);
        then(g);
    });
}

/// The two points each judged on, logical pixels in the window.
fn flash_points(i: usize) -> [(f32, f32); 2] {
    if i == CHIP {
        [(8.0, 13.0), (22.0, 13.0)]
    } else {
        [(30.0, 22.0), (130.0, 22.0)]
    }
}

/// Show k of `shows`: (traced, cloaked until painted). The full pass
/// (SHOWS): traced in 0..50 and 100..150, forced in the others, cloaked
/// from 100 on. The short one after a scale change: traced in the first
/// half, forced in the second, all cloaked.
fn segment(k: usize, shows: usize) -> (bool, bool) {
    if shows == SHOWS {
        (k % 100 < 50, k >= 100)
    } else {
        (k < shows / 2, true)
    }
}

/// Step n: even the chip, odd the card, show k of each. What is behind is
/// read first; then the show, read either by a thread over the next DWM
/// frames while Slint paints (traced) or on this thread over the next
/// FORCED_FRAMES DWM frames, so Slint cannot paint first (forced; judged by
/// the worst frame). 60 ms on: read again, hide, next content, and 10 ms
/// later the next step.
fn flash_step(g: &Rc<Glue>, n: usize, shows: usize, then: fn(&Rc<Glue>)) {
    let (i, k) = (if n.is_multiple_of(2) { CHIP } else { CARD }, n / 2);
    let (natural, cloak) = segment(k, shows);
    let slot = usize::from(i == CARD) + 2 * usize::from(cloak);
    let r = win32::window_rect(g.h(i));
    let points: Vec<(i32, i32)> = flash_points(i)
        .iter()
        .map(|&(x, y)| (r.left + g.r(x), r.top + g.r(y)))
        .collect();
    let (fresh, stale) = (PALETTE[k % 6], PALETTE[(k + 5) % 6]);
    let under = read_points(&points);
    let ambiguous = under
        .iter()
        .any(|&u| [fresh, stale, 0].into_iter().any(|c| win32::close(u, c)));
    if natural && !ambiguous {
        let (points, under) = (points.clone(), under.clone());
        std::thread::spawn(move || flash_trace(slot, k, points, fresh, stale, under));
    }
    if cloak {
        win32::cloak_until_painted(g.h(i));
    }
    g.window(i).show().unwrap();
    let forced = (!natural).then(|| {
        let frames: Vec<char> = (0..FORCED_FRAMES)
            .map(|_| {
                win32::dwm_flush();
                frame_kind(&read_points(&points), fresh, stale, &under)
            })
            .collect();
        (worst(&frames), frames.into_iter().collect::<String>())
    });
    let height_ok = i != CARD || g.card_h() == g.px(g.card.get_want_height());
    win32::stack_topmost(&g.z_top_first());
    {
        let mut all = FLASH.lock().unwrap();
        let f = &mut all[slot];
        f.shows += 1;
        f.ambiguous += u32::from(ambiguous);
        f.wrong_height += u32::from(!height_ok);
        if let (Some((kind, _)), false) = (&forced, ambiguous) {
            f.forced[KINDS.iter().position(|c| c == kind).unwrap()] += 1;
        }
    }
    if !height_ok {
        selflog::line(&format!(
            "flash card {}: shown {}px high, Slint wants {}px",
            k + 1,
            g.card_h(),
            g.px(g.card.get_want_height())
        ));
    }
    if let Some((kind, frames)) = forced.filter(|_| k % 25 == 0) {
        selflog::line(&format!(
            "flash {} {} forced: {kind} (frames {frames})",
            SLOTS[slot],
            k + 1
        ));
    }
    let how = if natural {
        "traced"
    } else {
        "read before Slint paints"
    };
    let cloaked = if cloak { ", cloaked till painted" } else { "" };
    g.panel
        .set_status(format!("{} show {}/{shows}, {how}{cloaked}", NAMES[i], k + 1).into());

    after(g, 60, move |g| {
        let now = read_points(&points);
        let settled = now.iter().all(|&c| win32::close(c, fresh));
        let (height, want) = (g.card_h(), g.px(g.card.get_want_height()));
        let height_ok = i != CARD || height == want;
        let foreground_ours = win32::is_ours(win32::foreground());
        g.z_check(&format!("flash {} {}", NAMES[i], k + 1), false, true);
        {
            let mut all = FLASH.lock().unwrap();
            let f = &mut all[slot];
            f.settled_wrong += u32::from(!(settled && height_ok));
            f.foreground_ours += u32::from(foreground_ours);
        }
        if !settled || !height_ok {
            selflog::line(&format!(
                "flash {} {} wrong 60 ms on: pixels {now:06x?} want {fresh:06x}; card height {height}px, Slint wants {want}px",
                SLOTS[slot],
                k + 1
            ));
        }
        g.window(i).hide().unwrap();
        set_content(g, i, k + 1);
        // Chained, not on a fixed clock: the screen reads take tens of ms,
        // and steps that fall behind must not pile up over the hides.
        if n + 1 == 2 * shows {
            flash_summary(g, then);
        } else {
            after(g, 10, move |g| flash_step(g, n + 1, shows, then));
        }
    });
}

/// DWM frames after one show until the first fresh one or the hide (55 ms
/// on), each judged by frame_kind, with the ms since the show. A stale or
/// black frame before the first fresh one is a flash; see-through frames
/// before it are only a late first paint.
fn flash_trace(
    slot: usize,
    k: usize,
    points: Vec<(i32, i32)>,
    fresh: u32,
    stale: u32,
    under: Vec<u32>,
) {
    let start = Instant::now();
    let (mut kinds, mut frames, mut ms) = (String::new(), Vec::new(), 0);
    for _ in 0..TRACE_FRAMES {
        win32::dwm_flush();
        let kind = frame_kind(&read_points(&points), fresh, stale, &under);
        ms = start.elapsed().as_millis() as u32;
        kinds.push(kind);
        frames.push(format!("{kind}@{ms}"));
        if kind == 'F' || ms >= 55 {
            break;
        }
    }
    let frames = frames.join(" ");
    let fresh_at = kinds.ends_with('F').then_some(ms);
    let flash_frames = kinds.matches(['S', 'B']).count() as u32;
    let name = SLOTS[slot];
    {
        let mut all = FLASH.lock().unwrap();
        let f = &mut all[slot];
        f.traced += 1;
        f.stale_frames += kinds.matches('S').count() as u32;
        f.black_frames += kinds.matches('B').count() as u32;
        f.flashes += u32::from(flash_frames > 0);
        f.never_fresh += u32::from(fresh_at.is_none());
        let key = (flash_frames, fresh_at.unwrap_or(u32::MAX));
        if fresh_at.is_some() {
            f.worst_to_fresh = f.worst_to_fresh.max(key.1);
        }
        if key > f.worst_key {
            f.worst_key = key;
            f.worst = format!("{name} show {} frames {frames}", k + 1);
        }
    }
    if flash_frames > 0 || fresh_at.is_none() || k.is_multiple_of(25) {
        selflog::line(&format!("flash {name} {} traced: frames {frames}", k + 1));
    }
}

/// One frame at the points, judged by its worst point.
fn frame_kind(got: &[u32], fresh: u32, stale: u32, under: &[u32]) -> char {
    let each: Vec<char> = got
        .iter()
        .zip(under)
        .map(|(&c, &u)| {
            if win32::close(c, fresh) {
                'F'
            } else if win32::close(c, stale) {
                'S'
            } else if win32::close(c, 0) {
                'B'
            } else if win32::close(c, u) {
                'U'
            } else {
                'O'
            }
        })
        .collect();
    worst(&each)
}

/// F if all are fresh, else the worst kind found (stale, black,
/// see-through, other).
fn worst(kinds: &[char]) -> char {
    if kinds.iter().all(|&c| c == 'F') {
        'F'
    } else {
        *KINDS[1..].iter().find(|k| kinds.contains(k)).unwrap()
    }
}

/// The height changes, then `then`.
fn height_phase(g: &Rc<Glue>, then: fn(&Rc<Glue>)) {
    set_phase(
        g,
        "HEIGHT",
        Color::from_rgb_u8(0x70, 0xa8, 0xff),
        "card 1..8 lines, panel 1..4 rows; tops stay put",
    );
    for i in [CHIP, CARD] {
        g.window(i).show().unwrap();
    }
    win32::stack_topmost(&g.z_top_first());
    let mut changes: Vec<(usize, i32)> = (2..=8).chain((1..=7).rev()).map(|v| (CARD, v)).collect();
    changes.extend([3, 4, 3, 2, 1, 2].map(|v| (PANEL, v)));
    let count = changes.len();
    for (n, (i, v)) in changes.into_iter().enumerate() {
        after(g, 500 + 600 * n as u64, move |g| {
            height_change(g, n + 1, count, i, v)
        });
    }
    after(g, 500 + 600 * count as u64 + 200, move |g| {
        let [drift, wrong, glue] = g.height_worst.get();
        let text = format!(
            "height: worst top-left drift {drift}px, height error {wrong}px, helper error {glue}px"
        );
        selflog::line(&text);
        g.panel.set_verdict(text.into());
        then(g);
    });
}

/// One content change; 300 ms on, the window's rect against Slint's
/// preferred height and against where it was.
fn height_change(g: &Rc<Glue>, n: usize, count: usize, i: usize, v: i32) {
    let before = win32::window_rect(g.h(i));
    let what = if i == CARD { "lines" } else { "rows" };
    if i == CARD {
        g.card.set_lines(v);
    } else {
        g.panel.set_rows(v);
    }
    g.panel
        .set_status(format!("change {n}/{count}: {} to {v} {what}", NAMES[i]).into());
    after(g, 300, move |g| {
        let r = win32::window_rect(g.h(i));
        let want = g.px(if i == CARD {
            g.card.get_want_height()
        } else {
            g.panel.get_want_height()
        });
        let drift = (r.top - before.top).abs().max((r.left - before.left).abs());
        let wrong = (r.bottom - r.top - want).abs();
        let glue = g.worst_error();
        let [a, b, c] = g.height_worst.get();
        g.height_worst
            .set([a.max(drift), b.max(wrong), c.max(glue)]);
        selflog::line(&format!(
            "height {n}: {} {v} {what}: {}px -> {}px (Slint wants {want}px), top-left drift {drift}px, worst helper error {glue}px, all inside the work area {}",
            NAMES[i],
            before.bottom - before.top,
            r.bottom - r.top,
            g.inside()
        ));
    });
}

fn hands_phase(g: &Rc<Glue>) {
    set_phase(
        g,
        "HANDS ON",
        Color::from_rgb_u8(0x60, 0xd0, 0x80),
        "drag the blue bar; type in Notepad; watch chip and card",
    );
    g.panel
        .set_status("chip and card swap each second, new content each show".into());
    let (checks, bad) = g.z.get();
    selflog::line(&format!("z checks so far {checks}, wrong {bad}"));
    let tick = Cell::new(0usize);
    let c = g.clone();
    g.timers
        .borrow_mut()
        .push(repeat(Duration::from_secs(1), move || {
            let t = tick.get() + 1;
            tick.set(t);
            let (show, hide) = if t.is_multiple_of(2) {
                (CHIP, CARD)
            } else {
                (CARD, CHIP)
            };
            c.window(hide).hide().unwrap();
            set_content(&c, hide, t);
            c.window(show).show().unwrap();
            win32::stack_topmost(&c.z_top_first());
        }));
}

/// --scale: an ear on every screen change, the 100 ms poll that handles a
/// change, and the first round: the re-place handler with nothing changed.
fn scale_phase(g: &Rc<Glue>) {
    let c = g.clone();
    win32::on_screen_change(move |hwnd, dpi_changed, text| {
        selflog::line(&format!("{}: {text}", c.who(hwnd)));
        heard(&c, hwnd, dpi_changed);
    });
    for (i, name) in NAMES.iter().enumerate().take(5) {
        let c = g.clone();
        g.window(i).on_winit_window_event(move |w, event| {
            // seen before Slint takes it (winitwindowadapter.rs)
            if let winit::event::WindowEvent::ScaleFactorChanged { scale_factor, .. } = event {
                let size = w.size();
                selflog::line(&format!(
                    "{}: winit ScaleFactorChanged to {scale_factor}; Slint's scale factor still {}, size {}x{}",
                    name,
                    w.scale_factor(),
                    size.width,
                    size.height
                ));
                heard(&c, c.h(i), None);
            }
            EventResult::Propagate
        });
    }
    let c = g.clone();
    g.timers
        .borrow_mut()
        .push(repeat(Duration::from_millis(100), move || scale_poll(&c)));
    check_round(g);
}

/// A screen message: its change opened or kept open, and a window's
/// WM_DPICHANGED (`dpi_changed`: its DPI, what it came inside) timed.
/// Runs inside the window message, so it only notes.
fn heard(g: &Glue, hwnd: HWND, dpi_changed: Option<(u32, &'static str)>) {
    let mut c = g.change.get().unwrap_or_else(Change::new);
    c.last = Instant::now();
    if let (Some((dpi, inside)), Some(i)) =
        (dpi_changed, g.hwnd.get().iter().position(|&h| h == hwnd))
    {
        c.got[i] = Some((c.first.elapsed().as_secs_f32(), dpi, inside));
    }
    g.change.set(Some(c));
}

/// Every 100 ms: the foreground read; a change caught by its effect, should
/// no message have come; while a change is open, any check round dropped,
/// then once it has been quiet SETTLE the re-place for the monitor's DPI
/// and work area, once all five and Slint are at that DPI and quiet SETTLE
/// again the re-place once more, and quiet SETTLE after that (or GIVE_UP
/// from the first message) a check round.
fn scale_poll(g: &Rc<Glue>) {
    if win32::is_ours(win32::foreground()) {
        g.focus_ours.set(g.focus_ours.get() + 1);
        selflog::line("scale poll: the foreground window is ours");
    }
    let (work, _) = win32::monitor_of(g.h(PANEL));
    let dpi = win32::monitor_dpi(g.h(PANEL));
    if g.change.get().is_none() {
        if work == g.work.get() && dpi == g.dpi.get() {
            return;
        }
        selflog::line(&format!(
            "scale poll: a change no message told of: monitor {dpi} dpi, work area {}",
            rect_text(work)
        ));
        g.change.set(Some(Change::new()));
    }
    if g.busy.get() {
        drop_round(g);
    }
    let c = g.change.get().unwrap();
    let behind = behind(g, dpi);
    g.panel.set_status(
        format!(
            "change heard {:.1} s ago; not yet at {dpi} dpi: {}",
            c.first.elapsed().as_secs_f32(),
            names(&behind)
        )
        .into(),
    );
    if c.last.elapsed() < SETTLE {
        return;
    }
    // Re-placed when quiet, and once more when all five have the new DPI:
    // the first one's moves bring the WM_DPICHANGED still to come, the
    // last sizes every window at the scale Slint then has (Glue::replace).
    let all_there = behind.is_empty();
    if c.placed != Some((dpi, work, all_there)) {
        set_phase(
            g,
            "CHANGE",
            Color::from_rgb_u8(0xa0, 0xa0, 0xa0),
            &format!("re-placed for {dpi} dpi; waiting for all five"),
        );
        let moved = g.replace();
        // the WM_DPICHANGED the re-place brought were noted (heard)
        let mut c = g.change.get().unwrap();
        c.placed = Some((dpi, work, all_there));
        c.last = Instant::now();
        g.change.set(Some(c));
        selflog::line(&format!(
            "change: re-placed for {dpi} dpi, work area {}; the window that moved most moved {moved}px; not yet at {dpi} dpi before: {}; after, GetDpiForWindow {}",
            rect_text(work),
            names(&behind),
            (0..5)
                .map(|i| format!("{}={}", NAMES[i], win32::dpi(g.h(i))))
                .collect::<Vec<_>>()
                .join(" ")
        ));
        return;
    }
    let gave_up = c.first.elapsed() >= GIVE_UP;
    if behind.is_empty() || gave_up {
        log_change(&c, dpi, &behind);
        g.change.set(None);
        check_round(g);
    }
}

/// The windows not yet at `dpi`: by GetDpiForWindow, or by Slint's scale.
fn behind(g: &Glue, dpi: u32) -> Vec<usize> {
    (0..5)
        .filter(|&i| {
            win32::dpi(g.h(i)) != dpi
                || (g.window(i).scale_factor() - dpi as f32 / 96.0).abs() >= 0.001
        })
        .collect()
}

fn names(windows: &[usize]) -> String {
    if windows.is_empty() {
        "none".to_string()
    } else {
        windows
            .iter()
            .map(|&i| NAMES[i])
            .collect::<Vec<_>>()
            .join(" ")
    }
}

/// A change done: each window's WM_DPICHANGED (s after the first message,
/// its DPI, what it came inside), the spread from the first window's to
/// the last's, and whether the wait for all five gave up.
fn log_change(c: &Change, dpi: u32, behind: &[usize]) {
    let each: Vec<String> = (0..5)
        .map(|i| match c.got[i] {
            Some((s, to, inside)) => format!("{} +{s:.2}s to {to} dpi, inside {inside}", NAMES[i]),
            None => format!("{} none", NAMES[i]),
        })
        .collect();
    let times: Vec<f32> = c.got.iter().flatten().map(|got| got.0).collect();
    let spread = match (
        times.iter().cloned().reduce(f32::min),
        times.iter().cloned().reduce(f32::max),
    ) {
        (Some(first), Some(last)) => format!("{:.2} s over {} windows", last - first, times.len()),
        _ => "no WM_DPICHANGED".to_string(),
    };
    let end = if behind.is_empty() {
        format!("all five at {dpi} dpi with Slint's scale to match")
    } else {
        format!("GAVE UP: not at {dpi} dpi: {}", names(behind))
    };
    selflog::line(&format!(
        "change done {:.1} s after its first message; WM_DPICHANGED: {}; spread first to last window {spread}; {end}",
        c.first.elapsed().as_secs_f32(),
        each.join(", ")
    ));
}

/// A screen change came during a check round: the round's remaining steps
/// are dropped (after), so no screen read blocks the thread and nothing
/// moves the windows while the change is handled. The chip and the card
/// are shown again, as scale_verdict leaves them.
fn drop_round(g: &Rc<Glue>) {
    g.epoch.set(g.epoch.get() + 1);
    g.busy.set(false);
    selflog::line(&format!(
        "round {} dropped: a screen change came during its checks",
        g.rounds.get()
    ));
    set_phase(
        g,
        "CHANGE",
        Color::from_rgb_u8(0xa0, 0xa0, 0xa0),
        "screen change heard; checks dropped",
    );
    for i in [CHIP, CARD] {
        set_content(g, i, PALETTE.len() - 1);
        g.window(i).show().unwrap();
    }
    win32::stack_topmost(&g.z_top_first());
}

/// --poke: each window told by us of another DPI and straight back to the
/// monitor's, as WM_DPICHANGED with its own rect suggested: the panel and
/// the card now, the bar, the edges and the chip 1.5 s later, after the
/// change's re-place, as the late ones came in the hand run.
fn poke(g: &Rc<Glue>) {
    let dpi = win32::monitor_dpi(g.h(PANEL));
    let other = if dpi == 120 { 144 } else { 120 };
    selflog::line(&format!(
        "poke: WM_DPICHANGED to {other} dpi and back to {dpi}: panel and card now, bar, edges and chip in 1.5 s"
    ));
    let there_and_back = move |g: &Glue, windows: &[usize]| {
        for &i in windows {
            win32::poke_dpi(g.h(i), other);
            win32::poke_dpi(g.h(i), dpi);
        }
    };
    there_and_back(g, &[PANEL, CARD]);
    let g = g.clone();
    later(1500, move || there_and_back(&g, &[BAR, EDGES, CHIP]));
}

/// --pretend: Windows' scale pretended to go to 150% (to 100% if it is
/// really at 150%), or `back` to what it really is. The card is told at
/// once, the others when the change's re-place moves them, as in the hand
/// run (win32::pretend_dpi); the poll handles it as a real change.
fn pretend(g: &Rc<Glue>, back: bool) {
    let real = win32::real_monitor_dpi(g.h(PANEL));
    let dpi = if back {
        real
    } else if real == 144 {
        96
    } else {
        144
    };
    selflog::line(&format!(
        "pretend: Windows' scale now {dpi} dpi (really {real}); the card told at once, the rest when next moved or sized"
    ));
    win32::pretend_dpi(dpi, &[g.h(CARD)]);
}

/// One round: where Windows, winit and Slint left each window, the
/// re-place handler, the checks that need no waiting; then card alpha, one
/// HEIGHT round and a short FLASH pass, and the verdict.
fn check_round(g: &Rc<Glue>) {
    g.busy.set(true);
    g.fails.borrow_mut().clear();
    g.height_worst.set([0; 3]);
    // the last FLASH pass's tallies, so a round that skips FLASH (below) is not judged on them
    g.flash_bad.set(0);
    *FLASH.lock().unwrap() = vec![Flash::default(); SLOTS.len()];
    let round = g.rounds.get() + 1;
    g.rounds.set(round);
    let first = round == 1;
    let what = if first {
        "the re-place handler, nothing changed"
    } else {
        "the scale or the work area changed"
    };
    set_phase(g, "CHECKING", Color::from_rgb_u8(0xa0, 0xa0, 0xa0), what);
    if g.poke && round == 3 {
        // Round 2 is dropped by the first poke's late batch; this one lands
        // in round 3's FLASH pass, which it must drop too.
        after(g, 16_000, poke);
    }
    let dpi = win32::monitor_dpi(g.h(PANEL));
    for (i, name) in NAMES.iter().enumerate().take(5) {
        selflog::line(&format!(
            "round {round}, before re-placing: {} at {}, {} dpi, Slint scale factor {}",
            name,
            rect_text(win32::window_rect(g.h(i))),
            win32::dpi(g.h(i)),
            g.window(i).scale_factor()
        ));
    }
    let behind = behind(g, dpi);
    let pending = !behind.is_empty();
    if pending {
        g.fail(format!(
            "not at the monitor's {dpi} dpi with Slint's scale to match: {}",
            names(&behind)
        ));
    }
    // After a change the poll has re-placed already, so this one, like the
    // self-test's, must find all five in place.
    let moved = g.replace();
    selflog::line(&format!(
        "round {round}: re-placed at {dpi} dpi, work area {}, home {:?}; the window that moved most moved {moved}px",
        rect_text(g.work.get()),
        g.home.get()
    ));
    if moved != 0 {
        g.fail(if first {
            format!("nothing changed, yet a window moved {moved}px")
        } else {
            format!("the change's re-place had not left them in place: a window moved {moved}px")
        });
    }

    // each window against where it belongs at this scale, sizes included
    let want = g.wanted();
    for i in 0..5 {
        let r = win32::window_rect(g.h(i));
        let error = side_error(r, want[i]);
        selflog::line(&format!(
            "round {round}: {} at {} want {}, error {error}px",
            NAMES[i],
            rect_text(r),
            rect_text(want[i])
        ));
        if error != 0 {
            g.fail(format!("{} {error}px off", NAMES[i]));
        }
    }
    let helper = g.worst_error();
    if helper != 0 {
        g.fail(format!("helper error {helper}px"));
    }
    let heights = (g.panel.get_want_height(), g.card.get_want_height());
    if first {
        g.first_heights.set(heights);
    }
    let (panel0, card0) = g.first_heights.get();
    selflog::line(&format!(
        "round {round}: Slint's preferred heights, logical: panel {}px, card {}px (round 1: {panel0}px, {card0}px)",
        heights.0, heights.1
    ));

    if !g.inside() {
        g.fail("not inside the work area".into());
    }
    if !g.z_check(&format!("round {round}"), false, false) {
        g.fail("z-order".into());
    }

    // 300 ms on, once winit's and Slint's queued events have run: each
    // window still where it belongs (no late resize back), and all the
    // same: what Slint draws (its window item's logical size x its scale),
    // Slint's physical size (the softbuffer's), winit's and Windows', and
    // Slint's scale, winit's and the monitor's. Then frames painted for
    // 3 s (paint_check).
    // The edges, once Slint has repainted the strips (replace): the region
    // read back is the two strips at this scale's depth, and both strips
    // are drawn, the bottom one at its new rows (left of the panel, where
    // nothing else of ours is); the last row inside the region is logged.
    after(g, 300, move |g| {
        let want = g.wanted();
        for i in 0..5 {
            let (r, w) = (win32::window_rect(g.h(i)), g.window(i));
            let (slint, slint_scale) = (w.size(), w.scale_factor());
            let (winit_scale, winit_size) = w
                .with_winit_window(|ww| (ww.scale_factor(), ww.inner_size()))
                .unwrap();
            let (item_w, item_h) = g.item_size(i);
            let drawn = (
                (item_w * slint_scale).round() as i32,
                (item_h * slint_scale).round() as i32,
            );
            let error = side_error(r, want[i]);
            let size = (r.right - r.left, r.bottom - r.top);
            let agree = drawn == size
                && (slint.width as i32, slint.height as i32) == size
                && (winit_size.width as i32, winit_size.height as i32) == size
                && (f64::from(slint_scale) - winit_scale).abs() < 0.001
                && (winit_scale - f64::from(dpi) / 96.0).abs() < 0.001;
            selflog::line(&format!(
                "round {round}, 300 ms on: {} at {} want {}, error {error}px; Slint draws {item_w}x{item_h} x {slint_scale} = {}x{} into {}x{}, winit {}x{} at scale {winit_scale}: {}",
                NAMES[i],
                rect_text(r),
                rect_text(want[i]),
                drawn.0,
                drawn.1,
                slint.width,
                slint.height,
                winit_size.width,
                winit_size.height,
                if agree { "agree" } else { "DISAGREE" }
            ));
            if error != 0 {
                g.fail(format!("{} {error}px off 300 ms on", NAMES[i]));
            }
            if !agree {
                g.fail(format!(
                    "{}: Slint, winit and Windows disagree on its size or scale",
                    NAMES[i]
                ));
            }
        }
        paint_check(g, round, 0, [0; 5]);
        if pending {
            // The wait gave up (scale_poll): a window still at the old DPI
            // may yet get its WM_DPICHANGED, so nothing that holds this
            // thread on screen reads runs meanwhile.
            selflog::line(&format!(
                "round {round}: screen reads, card alpha, HEIGHT and FLASH skipped: not all five at {dpi} dpi"
            ));
            // after the paint check's last step (3 s), so its result is in the verdict
            after(g, 3100, scale_verdict);
            return;
        }
        let e = win32::window_rect(g.h(EDGES));
        let deep = g.r(EDGE_DEEP);
        let ring = win32::region_is(g.h(EDGES), &g.edge_strips());
        let px = read_points(&[
            (e.left + 1, e.top + 1),
            (e.left + 1, e.bottom - 2),
            (e.left + 1, e.top + deep - 1),
        ]);
        let drawn = win32::close(px[0], GOLD) && win32::close(px[1], GOLD);
        selflog::line(&format!(
            "round {round}: edges region exactly the two {deep}px strips: {ring}; both drawn gold: {drawn} ({:06x}, {:06x}); last row inside {:06x}",
            px[0], px[1], px[2]
        ));
        if !ring {
            g.fail("edges region".into());
        }
        if !drawn {
            g.fail("edges strips not drawn".into());
        }
        // a picture of all five, for the glyphs
        let rects: Vec<RECT> = (0..5).map(|i| win32::window_rect(g.h(i))).collect();
        win32::save_screen_bmp(
            union(&rects),
            &selflog::data_dir().join(format!("scale-round{round}-{dpi}dpi.bmp")),
        );
        card_alpha(g, |g| {
            height_phase(g, |g| flash_phase(g, SCALE_SHOWS, scale_verdict))
        });
    });
}

/// Slint still drawing all five: every 0.5 s for 3 s a redraw asked of
/// each, and each must have painted since the step before (step 0 only
/// asks). A window drawn past its buffer panics and ends the process
/// instead, PANIC in the log (selflog.rs).
fn paint_check(g: &Rc<Glue>, round: u32, step: u32, last: [u32; 5]) {
    let now: [u32; 5] = std::array::from_fn(|i| win32::paints(g.h(i)));
    if step > 0 {
        let stuck: Vec<usize> = (0..5).filter(|&i| now[i] == last[i]).collect();
        if !stuck.is_empty() {
            g.fail(format!(
                "no frame painted in 0.5 s ({}, at {:.1} s)",
                names(&stuck),
                f64::from(step) / 2.0
            ));
            return;
        }
    }
    if step == 6 {
        selflog::line(&format!(
            "round {round}: all five painted every 0.5 s for 3 s; paints so far {now:?}"
        ));
        return;
    }
    for i in 0..5 {
        g.window(i).request_redraw();
    }
    after(g, 500, move |g| paint_check(g, round, step + 1, now));
}

/// The round's verdict, in large letters and in the log. The chip and the
/// card are shown again with the content the next FLASH pass takes for
/// stale; then the poll waits for the next change.
fn scale_verdict(g: &Rc<Glue>) {
    let [drift, wrong, glue] = g.height_worst.get();
    if drift.max(wrong).max(glue) != 0 {
        g.fail(format!(
            "height: drift {drift}px, height error {wrong}px, helper error {glue}px"
        ));
    }
    if g.flash_bad.get() != 0 {
        g.fail(format!("flash: {} stale or black shows", g.flash_bad.get()));
    }
    let focus = FLASH
        .lock()
        .unwrap()
        .iter()
        .map(|f| f.foreground_ours)
        .sum::<u32>()
        + g.focus_ours.get();
    if focus != 0 {
        g.fail(format!("ours in the foreground {focus} times"));
    }
    for i in [CHIP, CARD] {
        set_content(g, i, PALETTE.len() - 1);
        g.window(i).show().unwrap();
    }
    win32::stack_topmost(&g.z_top_first());

    let (round, dpi) = (g.rounds.get(), g.dpi.get());
    let pct = dpi * 100 / 96;
    let fails = g.fails.borrow().join("; ");
    let text = if fails.is_empty() {
        format!("scale {pct}%: all checks passed")
    } else {
        format!("scale {pct}%: FAILED {fails}")
    };
    selflog::line(&format!("round {round} verdict ({dpi} dpi): {text}"));
    if round == 1 && fails.is_empty() {
        set_phase(
            g,
            &format!("SCALE {pct}%"),
            Color::from_rgb_u8(0x70, 0xa8, 0xff),
            "change Windows scale now",
        );
        g.panel
            .set_status(format!("now {dpi} dpi; self-test with nothing changed done").into());
        if g.poke {
            after(g, 2000, poke);
        }
    } else if round == 1 {
        // a failed self-test makes any later round meaningless
        set_phase(
            g,
            &format!("FAILED {pct}%"),
            Color::from_rgb_u8(0xff, 0x60, 0x60),
            "self-test failed: leave the scale as it is",
        );
        g.panel
            .set_status(format!("now {dpi} dpi; see spike.log").into());
    } else if fails.is_empty() {
        set_phase(
            g,
            &format!("PASSED {pct}%"),
            Color::from_rgb_u8(0x60, 0xd0, 0x80),
            "look, then change the scale again",
        );
        g.panel
            .set_status(format!("round {round}, now {dpi} dpi").into());
    } else {
        set_phase(
            g,
            &format!("FAILED {pct}%"),
            Color::from_rgb_u8(0xff, 0x60, 0x60),
            "see spike.log; change the scale again",
        );
        g.panel
            .set_status(format!("round {round}, now {dpi} dpi").into());
    }
    g.panel.set_verdict(text.into());
    g.focus_ours.set(0);
    g.busy.set(false);
    if g.pretend && round <= 2 {
        after(g, 2000, move |g| pretend(g, round == 2));
    }
}

/// The bar's press and release (mouse.rs Strip): a drag starts and ends.
fn on_bar(g: &Rc<Glue>, kind: &str) {
    let foreground_ours = win32::is_ours(win32::foreground());
    if kind == "down" {
        let (mx, my) = win32::cursor();
        let p = win32::window_rect(g.h(PANEL));
        g.press.set(Some((mx, my, p.left, p.top)));
        g.drag.set((0, 0));
        selflog::line(&format!(
            "bar down at {mx},{my}; foreground ours {foreground_ours}"
        ));
    } else if g.press.take().is_some() {
        let (steps, worst) = g.drag.get();
        let p = win32::window_rect(g.h(PANEL));
        selflog::line(&format!(
            "bar drag {kind}: {steps} steps, worst helper error {worst}px, panel at {},{}, all inside the work area {}; foreground ours {foreground_ours}",
            p.left,
            p.top,
            g.inside()
        ));
        g.panel
            .set_verdict(format!("drag: {steps} steps, worst helper error {worst}px").into());
    }
}

/// A move while pressed: all five to the pointer, in one batch, kept inside
/// the work area. The pointer is read in screen pixels, as the windows move under it.
fn on_drag(g: &Rc<Glue>) {
    let Some((mx, my, px, py)) = g.press.get() else {
        return;
    };
    let (cx, cy) = win32::cursor();
    let (x, y) = g.clamp(px + cx - mx, py + cy - my);
    g.place_all(x, y);
    let (steps, worst) = g.drag.get();
    g.drag.set((steps + 1, worst.max(g.worst_error())));
}

/// The chip's or card's content for show k: colour, label, and the card's
/// line count. Set while the window is hidden.
fn set_content(g: &Glue, i: usize, k: usize) {
    let c = PALETTE[k % PALETTE.len()];
    let colour = Color::from_rgb_u8(c as u8, (c >> 8) as u8, (c >> 16) as u8);
    if i == CHIP {
        g.chip.set_swatch(colour);
        g.chip.set_label(format!("{k}").into());
    } else {
        g.card.set_swatch(colour);
        g.card.set_label(format!("#{k}").into());
        g.card.set_lines(1 + (k % 8) as i32);
    }
}

fn set_phase(g: &Glue, phase: &str, color: Color, hint: &str) {
    selflog::line(&format!("phase {phase}"));
    g.panel.set_phase(phase.into());
    g.panel.set_phase_color(color);
    g.panel.set_hint(hint.into());
}

/// `f` in `ms`, unless a check round is dropped meanwhile (drop_round).
fn after(g: &Rc<Glue>, ms: u64, f: impl FnOnce(&Rc<Glue>) + 'static) {
    let (g, epoch) = (g.clone(), g.epoch.get());
    later(ms, move || {
        if g.epoch.get() == epoch {
            f(&g)
        }
    });
}

/// Screen pixels at the points, from one capture of their bounding box.
fn read_points(points: &[(i32, i32)]) -> Vec<u32> {
    let left = points.iter().map(|p| p.0).min().unwrap();
    let top = points.iter().map(|p| p.1).min().unwrap();
    let right = points.iter().map(|p| p.0).max().unwrap() + 1;
    let bottom = points.iter().map(|p| p.1).max().unwrap() + 1;
    let pixels = win32::capture(RECT {
        left,
        top,
        right,
        bottom,
    });
    points
        .iter()
        .map(|&(x, y)| pixels[((y - top) * (right - left) + x - left) as usize])
        .collect()
}

fn sized(x: i32, y: i32, w: i32, h: i32) -> RECT {
    RECT {
        left: x,
        top: y,
        right: x + w,
        bottom: y + h,
    }
}

fn union(rects: &[RECT]) -> RECT {
    rects.iter().fold(rects[0], |u, r| RECT {
        left: u.left.min(r.left),
        top: u.top.min(r.top),
        right: u.right.max(r.right),
        bottom: u.bottom.max(r.bottom),
    })
}

fn within(r: RECT, outer: RECT) -> bool {
    r.left >= outer.left && r.top >= outer.top && r.right <= outer.right && r.bottom <= outer.bottom
}

/// The largest distance between matching sides, px.
fn side_error(a: RECT, b: RECT) -> i32 {
    [
        a.left - b.left,
        a.top - b.top,
        a.right - b.right,
        a.bottom - b.bottom,
    ]
    .into_iter()
    .map(i32::abs)
    .max()
    .unwrap()
}

/// DEFERRED.md "Slint's private API in the spike": item_size reads the
/// window item through slint::private_unstable_api, which any Slint release
/// may change. The call itself is checked by this crate compiling; this
/// pins the release it was checked against, so a Slint update fails here
/// first and item_size is looked at again before the pin moves.
#[cfg(test)]
mod slint_pin {
    #[test]
    fn slint_stays_at_the_release_item_size_was_checked_on() {
        let dir = env!("CARGO_MANIFEST_DIR");
        let toml = std::fs::read_to_string(format!("{dir}/Cargo.toml")).unwrap();
        assert!(
            toml.contains(r#"slint = { version = "=1.18.1""#),
            "Cargo.toml no longer pins slint =1.18.1"
        );
        // CRLF in a Windows checkout (.gitattributes' text=auto), as LF
        let lock = std::fs::read_to_string(format!("{dir}/Cargo.lock"))
            .unwrap()
            .replace("\r\n", "\n");
        for name in ["slint", "i-slint-core"] {
            assert!(
                lock.contains(&format!("name = \"{name}\"\nversion = \"1.18.1\"\n")),
                "Cargo.lock has another {name} than 1.18.1"
            );
        }
    }
}
