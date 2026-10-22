// M9 spike, step 2: the overlay's mouse model (--mouse).
//
// A panel like the real overlay's, bottom right, with two strips - the bar's
// drag handle and tile 1 - that still take clicks while the panel is locked,
// when the rest lets clicks through to whatever is behind.
//
// 1. Self-test, about 30 s, hands off: each way to get strips is tried in
//    the plan's order - (a) alpha 0 pixels, (b) WM_NCHITTEST, (c)
//    SetWindowRgn, (d) a window per strip over a click-through panel - and
//    probed with WindowFromPoint, which hit-tests a point as a click would,
//    without any input. Then 20 quick lock toggles and the opacity steps,
//    each probed again, over a magenta window so the pixels can be read.
// 2. The panel hidden 5 s: the 120 ms pointer poll must go quiet.
// 3. Live, for the user's hand: locked and unlocked swap every 10 s, the
//    opacity steps every 3 s, and the panel says what each click did.
//
// The pointer and the left button are only ever read (win32.rs).

use std::cell::{Cell, RefCell};
use std::rc::Rc;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, Ordering::SeqCst};
use std::time::{Duration, Instant};

use slint::winit_030::WinitWindowAccessor;
use slint::{Color, ComponentHandle};
use windows::Win32::Foundation::{HWND, RECT};

use crate::{later, repeat, selflog, show_no_activate, win32};

slint::slint! {
    export component Panel inherits Window {
        in property <string> phase;
        in property <color> phase-color: #a0a0a0;
        in property <string> hint;
        in property <string> status;
        in property <string> last;
        in property <string> verdict;
        in property <float> body-opacity: 1;
        // (what was pressed, "down" / "up" / "cancel"), left button only
        callback pointer(string, string);
        // a move while pressed
        callback dragged(string);
        no-frame: true;
        always-on-top: true;
        background: transparent;
        width: 300px;
        height: 210px;

        function report(what: string, e: PointerEvent) {
            if e.kind == PointerEventKind.cancel {
                root.pointer(what, "cancel");
            } else if e.button == PointerEventButton.left && e.kind != PointerEventKind.move {
                root.pointer(what, e.kind == PointerEventKind.down ? "down" : "up");
            }
        }

        // What the opacity setting fades. The labels further down stay at
        // full strength, so the phase is readable at 30% too.
        Rectangle {
            opacity: root.body-opacity;
            border-radius: 14px;
            background: #1e1f24;
            Rectangle {
                x: 0;
                y: 0;
                width: parent.width;
                height: 26px;
                border-top-left-radius: 14px;
                border-top-right-radius: 14px;
                background: #2c2f38;
            }
            // Tile 1 and the bar's handle are drawn by their strip windows.
            Rectangle {
                x: 110px;
                y: 140px;
                width: 80px;
                height: 56px;
                border-radius: 6px;
                background: #3a3d47;
                Text { text: "tile 2"; color: #d0d0d0; font-size: 12px; }
            }
            Rectangle {
                x: 208px;
                y: 140px;
                width: 80px;
                height: 56px;
                border-radius: 6px;
                background: #3a3d47;
                Text { text: "tile 3"; color: #d0d0d0; font-size: 12px; }
            }
        }
        // Later siblings are on top for the mouse: the body first.
        TouchArea {
            pointer-event(e) => { root.report("body", e); }
        }
        TouchArea {
            x: 0;
            y: 0;
            width: parent.width;
            height: 26px;
            pointer-event(e) => { root.report("bar", e); }
            moved => { root.dragged("bar"); }
        }
        TouchArea {
            x: 110px;
            y: 140px;
            width: 80px;
            height: 56px;
            pointer-event(e) => { root.report("tile2", e); }
            moved => { root.dragged("tile2"); }
        }
        TouchArea {
            x: 208px;
            y: 140px;
            width: 80px;
            height: 56px;
            pointer-event(e) => { root.report("tile3", e); }
            moved => { root.dragged("tile3"); }
        }
        Text { x: 12px; y: 26px; text: root.phase; color: root.phase-color; font-size: 26px; font-weight: 700; }
        Text { x: 12px; y: 62px; width: 276px; text: root.hint; color: #e8e8e8; font-size: 12px; }
        Text { x: 12px; y: 78px; width: 276px; text: root.status; color: #b8b8b8; font-size: 12px; }
        Text { x: 12px; y: 94px; width: 276px; text: root.last; color: #9fd0ff; font-size: 12px; }
        Text { x: 12px; y: 110px; width: 276px; text: root.verdict; color: #f0d090; font-size: 12px; }
    }

    // One strip: a small window of its own over the panel, never
    // click-through. The real overlay's bar of buttons is one of these.
    export component Strip inherits Window {
        in property <string> label;
        in property <float> paint-opacity: 1;
        in property <length> w;
        in property <length> h;
        callback pointer(string);
        callback dragged();
        no-frame: true;
        always-on-top: true;
        background: transparent;
        width: root.w;
        height: root.h;

        Rectangle {
            opacity: root.paint-opacity;
            border-radius: 6px;
            background: #3d6fa8;
            Text { text: root.label; color: #ffffff; font-size: 11px; }
        }
        TouchArea {
            pointer-event(e) => {
                if e.kind == PointerEventKind.cancel {
                    root.pointer("cancel");
                } else if e.button == PointerEventButton.left && e.kind != PointerEventKind.move {
                    root.pointer(e.kind == PointerEventKind.down ? "down" : "up");
                }
            }
            moved => { root.dragged(); }
        }
    }
}

/// The panel's size, logical pixels.
const W: f32 = 300.0;
const H: f32 = 210.0;
const MARGIN: i32 = 24;

/// A strip: its name for presses, its name in probe logs, its label, and
/// where it sits on the panel in logical pixels.
struct Spot {
    what: &'static str,
    hit: &'static str,
    label: &'static str,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
}

const STRIPS: [Spot; 2] = [
    Spot {
        what: "handle",
        hit: "strip:handle",
        label: "drag",
        x: 110.0,
        y: 3.0,
        w: 80.0,
        h: 20.0,
    },
    Spot {
        what: "tile1",
        hit: "strip:tile1",
        label: "tile 1 (strip)",
        x: 12.0,
        y: 140.0,
        w: 80.0,
        h: 56.0,
    },
];

/// What a probe point should hit.
#[derive(Clone, Copy)]
enum Want {
    /// ours while unlocked, what is behind while locked
    Lockable,
    /// ours either way
    Strip,
    /// logged only: alpha 0, whose answer is the finding
    Report,
}

/// Probe points, logical pixels on the panel.
const POINTS: [(&str, f32, f32, Want); 6] = [
    ("body", 150.0, 132.0, Want::Lockable),
    ("bar", 40.0, 13.0, Want::Lockable),
    ("tile2", 150.0, 168.0, Want::Lockable),
    ("corner", 1.0, 1.0, Want::Report),
    ("handle", 150.0, 13.0, Want::Strip),
    ("tile1", 52.0, 168.0, Want::Strip),
];

const LEVELS: [f32; 4] = [1.0, 0.7, 0.5, 0.3];

/// The real overlay's tile slop (Test-ChatOverlayTileDragStarts): a press
/// that moves more than this either way drags; less is a click.
const SLOP: i32 = 4;

/// How the live part locks the panel, the first way the self-test found
/// working: strip windows over a panel winit makes WS_EX_TRANSPARENT |
/// WS_EX_LAYERED. WS_EX_TRANSPARENT alone still took every click, as on
/// any window that is not layered.
const LIVE: Lock = Lock::WinitHittest;

#[derive(Clone, Copy)]
enum Lock {
    /// WS_EX_TRANSPARENT on the whole panel, kept by the style guard
    ExTransparent,
    /// winit's own set_cursor_hittest(false): WS_EX_TRANSPARENT | WS_EX_LAYERED
    WinitHittest,
    /// (b) HTTRANSPARENT from WM_NCHITTEST outside the strips
    NcHitTest,
    /// (c) a window region of the strips alone
    Region,
}

/// Our windows by HWND, for the probe logs; read from the probe threads too.
static NAMES: Mutex<Vec<(isize, &'static str)>> = Mutex::new(Vec::new());
/// Probes that had an expected answer, and how many got it, per thread.
static UI_OK: AtomicU32 = AtomicU32::new(0);
static UI_ALL: AtomicU32 = AtomicU32::new(0);
static OTHER_OK: AtomicU32 = AtomicU32::new(0);
static OTHER_ALL: AtomicU32 = AtomicU32::new(0);
static POLL_TICKS: AtomicU32 = AtomicU32::new(0);

/// A left press Slint delivered, while it lasts: where the pointer and the
/// panel were, and whether it has become a drag.
struct Press {
    what: String,
    mx: i32,
    my: i32,
    x: i32,
    y: i32,
    dragging: bool,
}

struct Ctx {
    panel: Panel,
    strips: Vec<Strip>,
    hwnd: Cell<HWND>,
    strip_hwnds: RefCell<Vec<HWND>>,
    locked: Cell<bool>,
    opacity: Cell<f32>,
    press: RefCell<Option<Press>>,
    /// when Slint last delivered a left press, to tell a click taken from one gone through
    last_down: Cell<Option<Instant>>,
    poll: slint::Timer,
    /// the poll's last reading: pointer on the panel, button held
    poll_was: Cell<(bool, bool)>,
    timers: RefCell<Vec<slint::Timer>>,
}

impl Ctx {
    /// Logical pixels on the panel to physical ones.
    fn phys(&self, x: f32, y: f32) -> (i32, i32) {
        let s = self.panel.window().scale_factor();
        ((x * s).round() as i32, (y * s).round() as i32)
    }

    /// The strips, window-relative physical pixels.
    fn strip_rects(&self) -> Vec<RECT> {
        STRIPS
            .iter()
            .map(|spot| {
                let (left, top) = self.phys(spot.x, spot.y);
                let (w, h) = self.phys(spot.w, spot.h);
                RECT {
                    left,
                    top,
                    right: left + w,
                    bottom: top + h,
                }
            })
            .collect()
    }
}

pub fn start(work: RECT) {
    let strips = STRIPS
        .iter()
        .map(|spot| {
            let s = Strip::new().unwrap();
            s.set_w(spot.w);
            s.set_h(spot.h);
            s.set_label(spot.label.into());
            s
        })
        .collect();
    let ctx = Rc::new(Ctx {
        panel: Panel::new().unwrap(),
        strips,
        hwnd: Cell::new(HWND::default()),
        strip_hwnds: RefCell::new(Vec::new()),
        locked: Cell::new(false),
        opacity: Cell::new(1.0),
        press: RefCell::new(None),
        last_down: Cell::new(None),
        poll: slint::Timer::default(),
        poll_was: Cell::new((false, false)),
        timers: RefCell::new(Vec::new()),
    });
    let c = ctx.clone();
    ctx.panel
        .on_pointer(move |what, kind| on_pointer(&c, &what, &kind));
    let c = ctx.clone();
    ctx.panel.on_dragged(move |what| on_dragged(&c, &what));
    for (strip, spot) in ctx.strips.iter().zip(&STRIPS) {
        let c = ctx.clone();
        strip.on_pointer(move |kind| on_pointer(&c, spot.what, &kind));
        let c = ctx.clone();
        strip.on_dragged(move || on_dragged(&c, spot.what));
    }
    set_phase(
        &ctx,
        "SELF-TEST",
        Color::from_rgb_u8(0xa0, 0xa0, 0xa0),
        "hands off for about 30 s",
    );

    let scale = win32::system_scale();
    let (x, y) = (
        work.right - (W * scale) as i32 - MARGIN,
        work.bottom - (H * scale) as i32 - MARGIN,
    );
    let c = ctx.clone();
    show_no_activate(&ctx.panel, x, y, move |hwnd| {
        c.hwnd.set(hwnd);
        NAMES.lock().unwrap().push((hwnd.0 as isize, "panel"));
        show_strips(c, 0);
    });
}

/// The strips one after another, each over its place on the panel and so
/// above it, then the poll, the topmost re-assert and the self-test.
fn show_strips(ctx: Rc<Ctx>, i: usize) {
    if i == STRIPS.len() {
        let c = ctx.clone();
        ctx.poll.start(
            slint::TimerMode::Repeated,
            Duration::from_millis(120),
            move || poll_tick(&c),
        );
        let c = ctx.clone();
        ctx.timers
            .borrow_mut()
            .push(repeat(Duration::from_secs(5), move || {
                win32::reassert_topmost(c.hwnd.get());
                c.strip_hwnds
                    .borrow()
                    .iter()
                    .for_each(|&h| win32::reassert_topmost(h));
            }));
        later(1000, move || self_test(ctx));
        return;
    }
    let r = win32::window_rect(ctx.hwnd.get());
    let (dx, dy) = ctx.phys(STRIPS[i].x, STRIPS[i].y);
    let c = ctx.clone();
    show_no_activate(&ctx.strips[i], r.left + dx, r.top + dy, move |hwnd| {
        NAMES.lock().unwrap().push((hwnd.0 as isize, STRIPS[i].hit));
        c.strip_hwnds.borrow_mut().push(hwnd);
        show_strips(c, i + 1);
    });
}

fn set_phase(ctx: &Ctx, phase: &str, color: Color, hint: &str) {
    ctx.panel.set_phase(phase.into());
    ctx.panel.set_phase_color(color);
    ctx.panel.set_hint(hint.into());
}

fn set_lock(ctx: &Ctx, how: Lock, on: bool) {
    let hwnd = ctx.hwnd.get();
    match how {
        Lock::ExTransparent => win32::set_click_through(hwnd, on),
        Lock::WinitHittest => {
            ctx.panel
                .window()
                .with_winit_window(|w| w.set_cursor_hittest(!on).unwrap());
        }
        Lock::NcHitTest => win32::set_pass_outside(hwnd, on.then(|| ctx.strip_rects())),
        Lock::Region => win32::set_region(hwnd, on.then(|| ctx.strip_rects()).as_deref()),
    }
    ctx.locked.set(on);
}

fn set_opacity(ctx: &Ctx, o: f32) {
    ctx.opacity.set(o);
    ctx.panel.set_body_opacity(o);
    ctx.strips.iter().for_each(|s| s.set_paint_opacity(o));
}

fn set_strips_shown(ctx: &Ctx, on: bool) {
    for s in &ctx.strips {
        if on {
            s.show().unwrap()
        } else {
            s.hide().unwrap()
        }
    }
}

/// Moves the panel and its strips with it, without activating either.
fn place(ctx: &Ctx, x: i32, y: i32) {
    win32::move_window(ctx.hwnd.get(), x, y);
    for (&h, spot) in ctx.strip_hwnds.borrow().iter().zip(&STRIPS) {
        let (dx, dy) = ctx.phys(spot.x, spot.y);
        win32::move_window(h, x + dx, y + dy);
    }
}

fn who(hwnd: HWND) -> String {
    let names = NAMES.lock().unwrap();
    match names.iter().find(|(h, _)| *h == hwnd.0 as isize) {
        Some((_, name)) => name.to_string(),
        None => format!("other:{}", win32::class_name(hwnd)),
    }
}

/// (name, screen x, y, whether ours should take it - None: just log it)
type Point = (&'static str, i32, i32, Option<bool>);

/// WindowFromPoint at each point: "name=hit" each, "!" where the answer
/// is not the one wanted, and how many of those with a wanted answer had it.
fn hits(points: &[Point]) -> (String, u32, u32) {
    let (mut text, mut ok, mut all) = (String::new(), 0, 0);
    for &(name, x, y, want) in points {
        let hit = who(win32::window_from_point(x, y));
        let taken = hit == "panel" || hit.starts_with("strip:");
        let mark = match want {
            None => "",
            Some(w) => {
                all += 1;
                ok += (w == taken) as u32;
                if w == taken { "" } else { "!" }
            }
        };
        text += &format!("{name}={hit}{mark} ");
    }
    (text, ok, all)
}

/// Probes every point from this (the UI) thread and from another one.
/// WM_NCHITTEST is sent only to windows of the thread that asks, so the
/// two differ exactly where HTTRANSPARENT decides; the other thread's
/// answer is what another app's window gets. `tally` counts the result
/// towards the run's totals; the trials of ways that are expected to fail
/// are only logged.
fn probe(ctx: &Ctx, label: &str, tally: bool) {
    ctx.panel.set_status(label.into());
    let r = win32::window_rect(ctx.hwnd.get());
    let locked = ctx.locked.get();
    let points: Vec<Point> = POINTS
        .iter()
        .map(|&(name, x, y, want)| {
            let (px, py) = ctx.phys(x, y);
            let want = match want {
                Want::Lockable => Some(!locked),
                Want::Strip => Some(true),
                Want::Report => None,
            };
            (name, r.left + px, r.top + py, want)
        })
        .collect();
    let head = format!(
        "probe {label}: locked={locked} opacity={:.0}%",
        ctx.opacity.get() * 100.0
    );
    let (text, ok, all) = hits(&points);
    selflog::line(&format!("{head} ui-thread {ok}/{all}: {text}"));
    if tally {
        UI_OK.fetch_add(ok, SeqCst);
        UI_ALL.fetch_add(all, SeqCst);
    }
    // Not joined: should WindowFromPoint ever wait on this thread, a join would hang it.
    std::thread::spawn(move || {
        let (text, ok, all) = hits(&points);
        selflog::line(&format!("{head} other-thread {ok}/{all}: {text}"));
        if tally {
            OTHER_OK.fetch_add(ok, SeqCst);
            OTHER_ALL.fetch_add(all, SeqCst);
        }
    });
}

fn tally_line() -> String {
    format!(
        "probe tally: ui-thread {}/{} as wanted, other-thread {}/{}",
        UI_OK.load(SeqCst),
        UI_ALL.load(SeqCst),
        OTHER_OK.load(SeqCst),
        OTHER_ALL.load(SeqCst)
    )
}

/// Per channel, a over b at opacity o: what DWM shows for the panel's fill
/// faded over the magenta window.
fn blend(a: u32, b: u32, o: f32) -> u32 {
    (0..3).fold(0, |acc, i| {
        let (ca, cb) = (
            ((a >> (8 * i)) & 0xff) as f32,
            ((b >> (8 * i)) & 0xff) as f32,
        );
        acc | (((ca * o + cb * (1.0 - o)).round() as u32) << (8 * i))
    })
}

/// Screen pixels over the magenta window: the corner (alpha 0) must show
/// magenta, the body its fill faded by the opacity setting.
fn pixels(ctx: &Ctx, label: &str) {
    let r = win32::window_rect(ctx.hwnd.get());
    let body = blend(win32::FILL, win32::MAGENTA, ctx.opacity.get());
    let mut text = String::new();
    let mut all = true;
    for (name, x, y, want) in [
        ("corner", 1.0, 1.0, win32::MAGENTA),
        ("body", 150.0, 132.0, body),
    ] {
        let (px, py) = ctx.phys(x, y);
        let got = win32::screen_pixel(r.left + px, r.top + py);
        let ok = win32::close(got, want);
        all &= ok;
        text += &format!(
            "{name}={got:06x}{} (want {want:06x}) ",
            if ok { "" } else { "!" }
        );
    }
    selflog::line(&format!(
        "pixels {label}: {} {text}(00bbggrr)",
        if all { "as wanted" } else { "WRONG" }
    ));
}

fn exstyle_line(ctx: &Ctx, label: &str) {
    let ex = win32::exstyle(ctx.hwnd.get());
    selflog::line(&format!(
        "{label}: panel exstyle={ex:#010x} styles_ok={}",
        win32::styles_ok(ex)
    ));
}

type StepFn = Box<dyn FnOnce(&Rc<Ctx>)>;
type Step = (u64, StepFn);

/// Runs each step its delay (ms) after the one before.
fn run_steps(ctx: Rc<Ctx>, mut steps: std::collections::VecDeque<Step>) {
    if let Some((ms, f)) = steps.pop_front() {
        later(ms, move || {
            f(&ctx);
            run_steps(ctx, steps);
        });
    }
}

fn self_test(ctx: Rc<Ctx>) {
    let magenta = win32::magenta_behind(ctx.hwnd.get(), win32::window_rect(ctx.hwnd.get()));
    NAMES.lock().unwrap().push((magenta.0 as isize, "magenta"));
    let mut steps: Vec<Step> = Vec::new();
    let mut step = |ms: u64, f: StepFn| steps.push((ms, f));

    // Unlocked: all of the panel takes clicks. The corner is alpha 0, so
    // whether a click there goes through is (a).
    step(
        600,
        Box::new(|c| {
            probe(c, "unlocked; corner = (a) alpha 0", true);
            pixels(c, "unlocked");
            // a picture of the panel and its strips, to look at afterwards
            win32::save_screen_bmp(
                win32::window_rect(c.hwnd.get()),
                &selflog::data_dir().join("mouse-panel.bmp"),
            );
        }),
    );
    // (b) and (c) need no strip windows: the strips would be the panel's own.
    step(
        400,
        Box::new(|c| {
            set_strips_shown(c, false);
            set_lock(c, Lock::NcHitTest, true);
        }),
    );
    step(
        600,
        Box::new(|c| {
            probe(c, "(b) WM_NCHITTEST HTTRANSPARENT", false);
            pixels(c, "(b)");
            set_lock(c, Lock::NcHitTest, false);
            set_lock(c, Lock::Region, true);
        }),
    );
    step(
        600,
        Box::new(|c| {
            probe(c, "(c) SetWindowRgn", false);
            pixels(c, "(c), the body must be gone");
            set_lock(c, Lock::Region, false);
            set_strips_shown(c, true);
            // Slint repaints only what changed, so what the region cut off stays
            // stale on screen; a change to the faded rectangle, which covers the
            // whole window, repaints all of it.
            set_opacity(c, 0.99);
        }),
    );
    step(100, Box::new(|c| set_opacity(c, 1.0)));
    // (d): the strips' own windows over a panel that lets everything through.
    step(800, Box::new(|c| set_lock(c, Lock::ExTransparent, true)));
    step(
        600,
        Box::new(|c| {
            probe(c, "(d) strip windows, WS_EX_TRANSPARENT panel", false);
            pixels(c, "(d) WS_EX_TRANSPARENT");
            exstyle_line(c, "(d) WS_EX_TRANSPARENT");
            set_lock(c, Lock::ExTransparent, false);
            set_lock(c, Lock::WinitHittest, true);
        }),
    );
    step(
        600,
        Box::new(|c| {
            probe(
                c,
                "(d) strip windows, winit set_cursor_hittest(false)",
                false,
            );
            pixels(c, "(d) winit hittest");
            exstyle_line(c, "(d) winit hittest");
            set_lock(c, Lock::WinitHittest, false);
        }),
    );
    step(
        800,
        Box::new(|c| {
            pixels(c, "winit hittest back on");
            probe(c, "unlocked again", true);
        }),
    );
    // 20 live toggles the way the live part locks.
    for i in 1..=20 {
        step(250, Box::new(move |c| set_lock(c, LIVE, i % 2 == 1)));
        step(
            250,
            Box::new(move |c| probe(c, &format!("toggle {i}"), true)),
        );
    }
    // The opacity steps, locked: strips keep their clicks, the corner stays see-through.
    step(100, Box::new(|c| set_lock(c, LIVE, true)));
    for (i, o) in LEVELS.into_iter().enumerate() {
        step(
            if i == 0 { 400 } else { 2500 },
            Box::new(move |c| set_opacity(c, o)),
        );
        step(
            500,
            Box::new(move |c| {
                probe(c, &format!("opacity {:.0}%", o * 100.0), true);
                pixels(c, &format!("opacity {:.0}%", o * 100.0));
            }),
        );
    }
    step(
        2500,
        Box::new(move |c| {
            set_opacity(c, 1.0);
            set_lock(c, LIVE, false);
            win32::destroy(magenta);
            selflog::line(&format!(
                "self-test done; {}; winit style rewrites undone {}",
                tally_line(),
                win32::style_fixes()
            ));
        }),
    );
    step(500, Box::new(hide_test));
    run_steps(ctx, steps.into());
}

/// Hides the panel and its strips 5 s, the poll stopped meanwhile, then
/// shows them again and starts the live part.
fn hide_test(ctx: &Rc<Ctx>) {
    selflog::line("hide 5 s: the poll stops");
    ctx.poll.stop();
    let before = POLL_TICKS.load(SeqCst);
    set_strips_shown(ctx, false);
    ctx.panel.hide().unwrap();
    let c = ctx.clone();
    later(5000, move || {
        let quiet = POLL_TICKS.load(SeqCst) - before;
        let fg = win32::foreground();
        c.panel.show().unwrap();
        set_strips_shown(&c, true);
        c.poll.restart();
        selflog::line(&format!(
            "shown again: poll ticks while hidden {quiet}; foreground ours {}",
            win32::is_ours(fg) || win32::is_ours(win32::foreground())
        ));
        exstyle_line(&c, "after the hide");
        live(c);
    });
}

/// Locked and unlocked swap every 10 s, the opacity steps every 3 s, each
/// change probed; the label counts down to the next swap.
fn live(ctx: Rc<Ctx>) {
    let tick = Cell::new(0u64);
    let level = Cell::new(0usize);
    let switches = Cell::new(0u32);
    show_live(&ctx, 10);
    let c = ctx.clone();
    ctx.timers
        .borrow_mut()
        .push(repeat(Duration::from_secs(1), move || {
            let t = tick.get() + 1;
            tick.set(t);
            if t.is_multiple_of(10) {
                set_lock(&c, LIVE, !c.locked.get());
                switches.set(switches.get() + 1);
                selflog::line(&format!(
                    "live switch {}: {}",
                    switches.get(),
                    if c.locked.get() { "LOCKED" } else { "UNLOCKED" }
                ));
                probe(&c, &format!("live switch {}", switches.get()), true);
                selflog::line(&tally_line());
            } else if t.is_multiple_of(3) {
                level.set((level.get() + 1) % LEVELS.len());
                set_opacity(&c, LEVELS[level.get()]);
                probe(
                    &c,
                    &format!("live opacity {:.0}%", LEVELS[level.get()] * 100.0),
                    true,
                );
            }
            show_live(&c, 10 - t % 10);
        }));
}

fn show_live(ctx: &Ctx, left: u64) {
    if ctx.locked.get() {
        set_phase(
            ctx,
            "LOCKED",
            Color::from_rgb_u8(0xf0, 0xb0, 0x40),
            "clicks go through - the blue strips still click",
        );
    } else {
        set_phase(
            ctx,
            "UNLOCKED",
            Color::from_rgb_u8(0x60, 0xd0, 0x80),
            "the whole panel takes clicks",
        );
    }
    ctx.panel.set_status(
        format!(
            "opacity {:.0}%  -  switch in {left} s",
            ctx.opacity.get() * 100.0
        )
        .into(),
    );
}

/// The 120 ms poll, as the real overlay's Update-ChatOverlayHover reads it:
/// where the pointer is and whether the left button is held, logged when
/// either changes. A press over the panel is judged 300 ms later.
fn poll_tick(ctx: &Rc<Ctx>) {
    POLL_TICKS.fetch_add(1, SeqCst);
    let panel = ctx.hwnd.get();
    if !win32::is_visible(panel) {
        selflog::line("poll ran while the panel was hidden");
    }
    let (x, y) = win32::cursor();
    let inside = win32::contains(&win32::window_rect(panel), x, y);
    let (down, since) = win32::left_button();
    let (was_in, was_down) = ctx.poll_was.get();
    if inside != was_in {
        selflog::line(&format!(
            "poll: pointer {} the panel at {x},{y}",
            if inside { "onto" } else { "off" }
        ));
    }
    if down != was_down {
        selflog::line(&format!(
            "poll: button {} at {x},{y}, on the panel {inside}",
            if down { "down" } else { "up" }
        ));
    }
    let quick = since && !down && !was_down;
    if quick {
        selflog::line(&format!(
            "poll: a click shorter than one poll, at {x},{y}, on the panel {inside}"
        ));
    }
    if inside && ((down && !was_down) || quick) {
        judge_click(ctx, x, y);
    }
    ctx.poll_was.set((inside, down));
}

/// Whether a press the poll saw over the panel reached Slint, against what
/// the lock says it should do, on the panel's last line.
fn judge_click(ctx: &Rc<Ctx>, x: i32, y: i32) {
    let at = Instant::now();
    let r = win32::window_rect(ctx.hwnd.get());
    let on_strip = ctx
        .strip_rects()
        .iter()
        .any(|k| win32::contains(k, x - r.left, y - r.top));
    let should_take = !ctx.locked.get() || on_strip;
    let c = ctx.clone();
    later(300, move || {
        let taken = c
            .last_down
            .get()
            .is_some_and(|t| t + Duration::from_millis(500) > at);
        let what = if taken {
            "click taken".to_string()
        } else {
            format!(
                "click went through (front: {})",
                win32::class_name(win32::foreground())
            )
        };
        let verdict = if taken == should_take {
            format!("{what} - right")
        } else {
            format!(
                "{what} - WRONG, should {}",
                if should_take {
                    "be taken"
                } else {
                    "go through"
                }
            )
        };
        selflog::line(&format!(
            "click at {x},{y}, locked {}, on a strip {on_strip}: {verdict}",
            c.locked.get()
        ));
        c.panel.set_verdict(verdict.into());
    });
}

fn on_pointer(ctx: &Rc<Ctx>, what: &str, kind: &str) {
    let fg_ours = win32::is_ours(win32::foreground());
    ctx.panel.set_last(format!("Slint: {what} {kind}").into());
    match kind {
        "down" => {
            ctx.last_down.set(Some(Instant::now()));
            let (mx, my) = win32::cursor();
            let r = win32::window_rect(ctx.hwnd.get());
            *ctx.press.borrow_mut() = Some(Press {
                what: what.to_string(),
                mx,
                my,
                x: r.left,
                y: r.top,
                dragging: false,
            });
            selflog::line(&format!(
                "slint: {what} down at {mx},{my}; foreground ours {fg_ours}"
            ));
        }
        "up" => {
            let Some(p) = ctx.press.borrow_mut().take() else {
                return;
            };
            let text = match (p.what.starts_with("tile"), p.dragging) {
                (true, true) => "tile drag end",
                (true, false) => "tile click",
                (false, true) => "bar drag end",
                (false, false) => "click, no drag",
            };
            let r = win32::window_rect(ctx.hwnd.get());
            selflog::line(&format!(
                "slint: {} up: {text}; panel at {},{}; foreground ours {fg_ours}",
                p.what, r.left, r.top
            ));
            ctx.panel.set_last(format!("{text} ({})", p.what).into());
        }
        _ => {
            ctx.press.borrow_mut().take();
            selflog::line(&format!("slint: {what} cancel"));
        }
    }
}

/// A move while pressed. The bar and its handle drag at once; a tile only
/// once past the slop. The pointer is read in screen pixels, as the real
/// overlay's Move-ChatOverlayGripDrag does, since the window moves under it.
fn on_dragged(ctx: &Rc<Ctx>, what: &str) {
    let mut press = ctx.press.borrow_mut();
    let Some(p) = press.as_mut() else { return };
    let bar = p.what == "bar" || p.what == "handle";
    if !bar && !p.what.starts_with("tile") {
        return;
    }
    let (mx, my) = win32::cursor();
    let (dx, dy) = (mx - p.mx, my - p.my);
    if !p.dragging {
        if !bar && dx.abs() <= SLOP && dy.abs() <= SLOP {
            return;
        }
        p.dragging = true;
        let text = if bar { "bar drag" } else { "tile drag" };
        selflog::line(&format!("{text} start ({what}, moved {dx},{dy})"));
        ctx.panel.set_last(text.into());
    }
    let (x, y) = (p.x + dx, p.y + dy);
    drop(press);
    place(ctx, x, y);
}
