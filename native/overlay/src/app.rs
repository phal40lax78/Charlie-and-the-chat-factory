// The panel (M9a, native/SPEC.md 8): the WPF overlay's five windows in
// Slint - the panel, the edges its top and foot are dragged by, the bar of
// buttons with the settings box, the open chip and the hover card - drawn
// from the headless host's data/overlay.json, as `chatq-overlay.exe <data
// folder> --since <ms>`, which Start-ChatOverlayUi (src/overlay-host.ps1)
// starts. What is the host's - an open's end, a delete, an answer, a
// setting, the console - goes back as a verb in data/overlay-cmd (App::cmd);
// what the WPF panel did itself - lock, hide, fold, its place - it does and
// keeps in overlay-state.json as that panel did. A setting moved shows at
// once, held until the snapshot's config has it (Held). The tray icon, its
// menu, balloons and hotkeys are trayicon.rs's; the pointer's every move is
// pointer.rs's, the chip's open opening.rs's; ui.rs holds the snapshot.
//
// As Invoke-ChatOverlayTick and Invoke-ChatOverlayVerb do it
// (src/overlay-windows.ps1):
// - a tick a second, 30 ms past it: the snapshot read, the host's commands
//   since its first panel started (--since) acted on once, its saids put on the
//   panel and its balloons in the tray one at a time; the panel drawn for
//   its clocks; a full screen, the relock after 2 minutes, the open's end;
//   every fifth tick the windows topmost again, the screens looked at and
//   the theme 'system' read again;
// - overlay-ui.json every 2 s, or at once on a change: what it has seen,
//   whether something is under way, and where the panel is (rect) - the
//   console takes that place;
// - under CHATQ_PANEL_DRIVE=<file> a test's lines (drive) stand in for the
//   pointer, the tray, the hotkeys and a full screen, and overlay-ui.json
//   says what is drawn; nothing then reads or moves the real pointer's
//   buttons, or looks for a real full screen.
// Every window's region and size is set only when it changed; nothing here
// moves the pointer, sends input or takes the foreground - an open's raise
// is open.rs's, at the user's click.

mod opening;
mod pointer;

use std::cell::RefCell;
use std::collections::BTreeSet;
use std::io::{Read as _, Write as _};
use std::path::PathBuf;
use std::time::{Duration, Instant, SystemTime};

use serde_json::{Value, json};
use slint::winit_030::{EventResult, WinitWindowAccessor, winit};
use slint::{ComponentHandle, TimerMode};
use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::UI::WindowsAndMessaging::WS_EX_LAYERED;

use crate::controls::{self, Thumb};
use crate::look::Look;
use crate::model::{self, Rect, eq, get, n, s};
use crate::scene::{self, Measurer, Prim, Scene};
use crate::snapshot::Event;
use crate::{card, chip, clock, look, panel, selflog, tooltip, trayicon, ui, win32};

const PANEL: usize = 0;
const EDGES: usize = 1;
const BAR: usize = 2;
const CHIP: usize = 3;
const CARD: usize = 4;
const COUNT: usize = 5;
const NAMES: [&str; COUNT] = ["panel", "edges", "controls", "chip", "card"];
/// Where a window waits, made and hidden, until it is placed.
const OFF: i32 = -32000;
/// A setting sent to the host shows as sent until config.json has it, or
/// this long.
const HOLD_FOR: Duration = Duration::from_secs(10);
/// A slider at rest this long, no button held, is sent (Update-ChatOverlayHover).
const REST: Duration = Duration::from_millis(700);
/// Unlocked and left this long, it locks again (Invoke-ChatOverlayTick).
const RELOCK: Duration = Duration::from_secs(120);
/// A screen change heard: re-placed once quiet this long, looked at again
/// until every window has its new scale, or this long has gone.
const SETTLE: Duration = Duration::from_millis(500);
const GIVE_UP: Duration = Duration::from_secs(15);
/// The card's model asked for again this often while it shows.
const CARD_AGAIN: Duration = Duration::from_secs(2);

static NULL: Value = Value::Null;

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
}

/// `f` on the panel's state: now, or - when a callback comes from inside
/// one of the state's own calls into Slint or Windows, which hold it - as
/// soon as that call is done.
pub(crate) fn with_app(f: impl FnOnce(&mut App) + 'static) {
    let f = APP.with(|a| match a.try_borrow_mut() {
        Ok(mut g) => {
            if let Some(app) = g.as_mut() {
                f(app);
            }
            None
        }
        Err(_) => Some(f),
    });
    if let Some(f) = f {
        slint::Timer::single_shot(Duration::ZERO, move || with_app(f));
    }
}

/// The tray menu as it opens (trayicon::menu): None while the state is
/// busy, and the right click does nothing.
pub(crate) fn menu_items() -> Option<Vec<trayicon::Item>> {
    APP.with(|a| {
        let g = a.try_borrow().ok()?;
        Some(g.as_ref()?.menu())
    })
}

/// A setting moved here and not yet in config.json: since when it was
/// sent, None while a slider still moves or rests.
struct Held<T> {
    v: T,
    sent: Option<Instant>,
}

fn held<T>(v: T) -> Option<Held<T>> {
    Some(Held { v, sent: None })
}

/// Unlocked and left alone RELOCK by `now`: due to lock again - not while
/// the console has the panel's place, nor with the pointer on it
/// (Invoke-ChatOverlayTick).
fn relock_due(
    locked: bool,
    console: bool,
    pointer_in: bool,
    left_at: Option<Instant>,
    now: Instant,
) -> bool {
    !locked
        && !console
        && !pointer_in
        && left_at.is_some_and(|t| now.saturating_duration_since(t) >= RELOCK)
}

/// The said line on the panel (Set-ChatOverlayOpenSay): the host's, by its
/// event id, or the panel's own open under way ('' id).
struct SaidSlot {
    id: String,
    said: panel::Said,
    until: Instant,
}

/// The host's saids (Add-ChatOverlaySaid, ui::pick_said) on the panel's
/// slot: the newest not seen goes on, unless it is on already, and the rest
/// are seen as they come - none waits its turn.
fn take_saids(
    slot: &mut Option<SaidSlot>,
    seen: &mut BTreeSet<String>,
    events: &[Event],
    now: Instant,
) {
    let (newest, rest) = ui::pick_said(events, seen);
    let x = newest
        .filter(|e| slot.as_ref().is_none_or(|x| x.id != e.id))
        .map(|e| SaidSlot {
            id: e.id.clone(),
            said: panel::Said {
                kind: e.said.clone(),
                tone: e.tone.clone(),
                text: e.text.clone(),
                about: e.about.clone(),
            },
            until: now + ui::shown_for(e),
        });
    seen.extend(rest);
    if let Some(x) = x {
        put_said(slot, seen, x);
    }
}

/// A said in the slot in the place of the one there: the host's it takes
/// the place of is seen now, as one shown its time through is
/// (said_through) - until then it is not, so a panel a restart cut short
/// leaves it to the next, as a balloon is left (ui::Hold).
fn put_said(slot: &mut Option<SaidSlot>, seen: &mut BTreeSet<String>, x: SaidSlot) {
    if let Some(was) = slot.replace(x)
        && !was.id.is_empty()
        && slot.as_ref().is_some_and(|x| x.id != was.id)
    {
        seen.insert(was.id);
    }
}

/// The host's said shown its time through by `now`: gone, and seen.
fn said_through(slot: &mut Option<SaidSlot>, seen: &mut BTreeSet<String>, now: Instant) {
    if let Some(x) = slot.take_if(|x| now >= x.until)
        && !x.id.is_empty()
    {
        seen.insert(x.id);
    }
}

/// What the host's snapshot says of itself (its ui block).
#[derive(Default)]
struct Host {
    spin: bool,
    console: bool,
    closing: bool,
    script: String,
    claude_home: String,
    /// VS Code's tabs: (session id, window name) - an open by name's
    tabs: Vec<(String, String)>,
}

/// overlay-state.json's (Read-ChatOverlayState).
struct Place {
    x: Option<i32>,
    y: Option<i32>,
    locked: bool,
    hidden: bool,
    collapsed: bool,
}

/// The balloon up: what a click on it means, and its words for the drive.
#[derive(Default)]
struct Balloon {
    kind: String,
    title: String,
    text: String,
}

/// The hover card: the row it is up for, the model the host wrote for it,
/// when that was asked for.
#[derive(Default)]
struct CardUp {
    key: String,
    model: Option<Value>,
    read: Option<SystemTime>,
    asked: Option<Instant>,
}

pub(crate) struct App {
    data: PathBuf,
    since: i64,
    t0: Instant,
    scenes: Vec<Scene>,
    hwnds: [HWND; COUNT],
    made: usize,
    started: bool,
    m: Measurer,
    hold: ui::Hold,
    /// the last good snapshot, whole
    snap: Value,
    host: Host,
    /// the host's commands acted on, by id
    done: BTreeSet<i64>,
    st: Place,
    full_hidden: bool,
    full_kept: bool,
    placed: bool,
    shown: bool,
    visible: [bool; COUNT],
    pos: [(i32, i32); COUNT],
    sizes: [(i32, i32); COUNT],
    regions: [Option<Vec<RECT>>; COUNT],
    built: Option<panel::Built>,
    rect: Rect,
    said: Option<SaidSlot>,
    tray: Option<trayicon::Tray>,
    tip: Option<tooltip::Tip>,
    /// a tooltip waiting on its rest: its words, since when, and where
    tip_want: Option<(String, Instant)>,
    tip_up: Option<Instant>,
    balloon: Balloon,
    showing_id: String,
    hide_told: bool,
    /// the hotkeys as registered: config.hotkey's and consoleHotkey's
    keys: [String; 2],
    chip: chip::Chip,
    placed_chip: Option<chip::Placed>,
    card: CardUp,
    card_up: bool,
    edges_shown: bool,
    edge_hits: Vec<(&'static str, [f64; 4])>,
    /// the edge lit: n, s or ''
    hint: String,
    box_open: bool,
    below: bool,
    left: bool,
    ctl: Option<controls::Controls>,
    enter_at: Option<Instant>,
    over_at: Option<Instant>,
    box_over_at: Option<Instant>,
    thumbs: [Thumb; 2],
    spin_until: Option<Instant>,
    opacity: Option<Held<f64>>,
    max_rows: Option<Held<i64>>,
    recent: Option<Held<i64>>,
    theme: Option<Held<String>>,
    auto: Option<Held<String>>,
    pending_at: Option<Instant>,
    drag: Option<pointer::Drag>,
    tile: Option<pointer::Tile>,
    /// the drive's pointer, in the real one's place
    fake: Option<(i32, i32)>,
    /// the drive's full screen, in the real one's place: the query's
    /// answer (QUERY_USER_NOTIFICATION_STATE), None for a query that failed
    fake_full: Option<i32>,
    pointer_in: bool,
    left_at: Option<Instant>,
    opening: Option<opening::Opening>,
    raise: Option<opening::Raise>,
    ticks: u64,
    ui_sig: String,
    ui_at: Option<Instant>,
    screens_sig: String,
    work: RECT,
    dpi: u32,
    change: Option<(Instant, Instant)>,
    sys_dark: bool,
    drive: Option<PathBuf>,
    cloak: bool,
    tick_timer: slint::Timer,
    hover_timer: slint::Timer,
    frame_timer: slint::Timer,
}

/// The panel's run: its five windows made, then the loop until the host
/// goes (stdin closed) or the snapshot is stale.
pub fn run(data: PathBuf, since: Option<i64>) {
    selflog::line(&format!("ui: data {}", data.display()));
    // the host's quit: its end of the pipe closed, or the host gone
    std::thread::spawn(|| {
        let mut buf = [0u8; 64];
        let mut stdin = std::io::stdin();
        while matches!(stdin.read(&mut buf), Ok(n) if n > 0) {}
        let _ = slint::invoke_from_event_loop(|| {
            selflog::line("ui: stdin closed, quitting");
            let _ = slint::quit_event_loop();
        });
    });
    crate::han_fallbacks();
    let scenes: Vec<Scene> = (0..COUNT).map(|_| Scene::new().unwrap()).collect();
    for (i, sc) in scenes.iter().enumerate() {
        sc.on_hit(move |id, kind| {
            let (id, kind) = (id.to_string(), kind.to_string());
            with_app(move |a| a.hit(i, &id, &kind));
        });
        sc.window()
            .set_position(slint::PhysicalPosition::new(OFF, OFF));
    }
    let app = App::new(data, since.unwrap_or_else(ui::epoch_ms), scenes);
    let weak: Vec<slint::Weak<Scene>> = app.scenes.iter().map(|sc| sc.as_weak()).collect();
    APP.with(|a| *a.borrow_mut() = Some(app));
    for (i, w) in weak.into_iter().enumerate() {
        slint::spawn_local(async move {
            let Some(sc) = w.upgrade() else { return };
            let ww = sc.window().winit_window().await.expect("winit window");
            let h = win32::hwnd_of(&ww);
            win32::make_overlay(h);
            with_app(move |a| a.made(i, h));
        })
        .unwrap();
    }
    slint::run_event_loop_until_quit().unwrap();
    let app = APP.with(|a| a.borrow_mut().take());
    drop(app);
}

fn rect_of(r: RECT) -> Rect {
    Rect::new(r.left, r.top, r.right - r.left, r.bottom - r.top)
}

/// overlay-state.json as Read-ChatOverlayState reads it: locked unless it
/// says otherwise.
fn read_place(v: &Value) -> Place {
    let num = |k: &str| get(v, k).filter(|x| !x.is_null()).map(|_| n(v, k) as i32);
    let flag = |k: &str, d: bool| {
        get(v, k)
            .filter(|x| !x.is_null())
            .map_or(d, |x| clock::truthy(Some(x)))
    };
    Place {
        x: num("x"),
        y: num("y"),
        locked: flag("locked", true),
        hidden: flag("hidden", false),
        collapsed: flag("collapsed", false),
    }
}

fn read_json(path: &std::path::Path) -> Value {
    std::fs::read(path)
        .ok()
        .and_then(|b| {
            serde_json::from_slice::<Value>(b.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(&b)).ok()
        })
        .unwrap_or(Value::Null)
}

impl App {
    fn new(data: PathBuf, since: i64, scenes: Vec<Scene>) -> App {
        let m = Measurer::new(&scenes[PANEL]);
        let st = read_place(&read_json(&data.join("overlay-state.json")));
        let now = Instant::now();
        App {
            since,
            t0: now,
            m,
            scenes,
            hwnds: [HWND::default(); COUNT],
            made: 0,
            started: false,
            hold: ui::Hold::new(now),
            snap: Value::Null,
            host: Host::default(),
            done: BTreeSet::new(),
            st,
            full_hidden: false,
            full_kept: false,
            placed: false,
            shown: false,
            visible: [false; COUNT],
            pos: [(OFF, OFF); COUNT],
            sizes: [(0, 0); COUNT],
            regions: Default::default(),
            built: None,
            rect: Rect::default(),
            said: None,
            tray: None,
            tip: None,
            tip_want: None,
            tip_up: None,
            balloon: Balloon::default(),
            showing_id: String::new(),
            hide_told: false,
            keys: [String::new(), String::new()],
            chip: chip::Chip::default(),
            placed_chip: None,
            card: CardUp::default(),
            card_up: false,
            edges_shown: false,
            edge_hits: Vec::new(),
            hint: String::new(),
            box_open: false,
            below: false,
            left: false,
            ctl: None,
            enter_at: None,
            over_at: None,
            box_over_at: None,
            thumbs: [Thumb::Still; 2],
            spin_until: None,
            opacity: None,
            max_rows: None,
            recent: None,
            theme: None,
            auto: None,
            pending_at: None,
            drag: None,
            tile: None,
            fake: None,
            fake_full: Some(5),
            pointer_in: false,
            left_at: None,
            opening: None,
            raise: None,
            ticks: 0,
            ui_sig: String::new(),
            ui_at: None,
            screens_sig: String::new(),
            work: RECT::default(),
            dpi: 0,
            change: None,
            sys_dark: win32::system_dark(),
            drive: std::env::var_os("CHATQ_PANEL_DRIVE")
                .filter(|v| !v.is_empty())
                .map(PathBuf::from),
            cloak: std::env::var_os("CHATQ_CLOAK").is_some(),
            tick_timer: slint::Timer::default(),
            hover_timer: slint::Timer::default(),
            frame_timer: slint::Timer::default(),
            data,
        }
    }

    /// Monotonic ms since the start: the chip's and the ring's clock.
    fn ms(&self) -> i64 {
        self.t0.elapsed().as_millis() as i64
    }

    fn h(&self, i: usize) -> HWND {
        self.hwnds[i]
    }

    /// The panel's scale: screen pixels a unit.
    fn px(&self) -> f64 {
        f64::from(self.scenes[PANEL].window().scale_factor())
    }

    fn cfg(&self) -> &Value {
        get(&self.snap, "config").unwrap_or(&NULL)
    }

    fn opacity(&self) -> f64 {
        self.opacity.as_ref().map_or_else(
            || {
                let v = model::f(self.cfg(), "opacity");
                if v > 0.0 { v.clamp(0.3, 1.0) } else { 0.94 }
            },
            |h| h.v,
        )
    }

    fn max_rows(&self) -> i64 {
        if let Some(pointer::Drag::Size(z)) = &self.drag {
            return z.rows;
        }
        self.max_rows.as_ref().map_or_else(
            || {
                let v = n(self.cfg(), "maxRows");
                if v > 0 { v } else { 8 }
            },
            |h| h.v,
        )
    }

    fn recent_count(&self) -> i64 {
        if let Some(pointer::Drag::Size(z)) = &self.drag {
            return z.recent;
        }
        self.recent.as_ref().map_or_else(
            || {
                get(self.cfg(), "recent")
                    .filter(|v| !v.is_null())
                    .map_or(5, |_| n(self.cfg(), "recent"))
            },
            |h| h.v,
        )
    }

    fn theme_name(&self) -> String {
        self.theme.as_ref().map_or_else(
            || {
                let t = s(self.cfg(), "theme");
                if t.is_empty() { "dark".into() } else { t }
            },
            |h| h.v.clone(),
        )
    }

    fn look(&self) -> &'static Look {
        let t = self.theme_name();
        if eq(&t, "system") {
            look::look(if self.sys_dark { "dark" } else { "light" })
        } else {
            look::look(&t)
        }
    }

    fn auto_choice(&self) -> String {
        self.auto.as_ref().map_or_else(
            || {
                let a = s(self.cfg(), "autoContinue");
                if a.is_empty() { "ask".into() } else { a }
            },
            |h| h.v.clone(),
        )
    }

    fn delay(&self) -> f64 {
        let d = model::f(self.cfg(), "chipDelayMs");
        if d > 0.0 { d } else { 400.0 }
    }

    /// The hotkey's words while it is held, for the unlocked hint.
    fn hotkey_words(&self) -> String {
        if self.tray.as_ref().is_some_and(|t| t.held(trayicon::MAIN)) {
            self.keys[0].clone()
        } else {
            String::new()
        }
    }

    /// One window made by Slint, hidden: the overlay's styles on it; once
    /// all five are, the panel starts.
    fn made(&mut self, i: usize, h: HWND) {
        self.hwnds[i] = h;
        self.made += 1;
        if self.cloak {
            // drawn, never seen: the tests' windows (CHATQ_CLOAK)
            win32::set_cloak(h, true);
        }
        if self.made == COUNT {
            self.start();
        }
    }

    fn start(&mut self) {
        self.started = true;
        // the card never takes the pointer
        self.scenes[CARD]
            .window()
            .with_winit_window(|w| w.set_cursor_hittest(false).unwrap());
        win32::layered_opaque(self.h(CARD));
        self.apply_lock();
        win32::on_screen_change(|_, _, text| {
            selflog::line(&format!("ui screen: {text}"));
            with_app(|a| a.heard());
        });
        for (sc, name) in self.scenes.iter().zip(NAMES) {
            sc.window().on_winit_window_event(move |_, event| {
                if let winit::event::WindowEvent::ScaleFactorChanged { scale_factor, .. } = event {
                    selflog::line(&format!("ui screen: {name}: scale {scale_factor}"));
                    with_app(|a| a.heard());
                }
                EventResult::Propagate
            });
        }
        if std::env::var_os("CHATQ_NOTRAY").is_none() {
            self.tray = trayicon::Tray::new();
        }
        self.tip = tooltip::Tip::new(self.h(PANEL));
        let (work, _) = win32::monitor_of(self.h(PANEL));
        self.work = work;
        self.dpi = win32::monitor_dpi(self.h(PANEL));
        self.screens_sig = screens_sig();
        self.hover_timer
            .start(TimerMode::Repeated, Duration::from_millis(120), || {
                with_app(|a| a.hover())
            });
        selflog::line(&format!(
            "ui: started, work area {}, {} dpi{}",
            win32::rect_text(work),
            self.dpi,
            if self.drive.is_some() { ", driven" } else { "" }
        ));
        self.tick();
    }

    /// The panel's click-through as locked says (Set-ChatOverlayLocked):
    /// winit's hit test off, and the layered window it makes drawn.
    fn apply_lock(&self) {
        let on = self.st.locked;
        self.scenes[PANEL]
            .window()
            .with_winit_window(|w| w.set_cursor_hittest(!on).unwrap());
        if win32::exstyle(self.h(PANEL)) & WS_EX_LAYERED.0 != 0 {
            win32::layered_opaque(self.h(PANEL));
        }
    }

    // ---- the tick --------------------------------------------------------

    /// Invoke-ChatOverlayTick, once a second, 30 ms past it.
    fn tick(&mut self) {
        let now = Instant::now();
        let bytes = std::fs::read(self.data.join("overlay.json")).ok();
        if self.hold.take(bytes.as_deref(), now) {
            self.taken(now);
        }
        if self.hold.last.is_some()
            && self.hold.tick(now)
            && let Some((e, _)) = self
                .hold
                .showing
                .clone()
                .filter(|(e, _)| e.id != self.showing_id)
        {
            self.showing_id = e.id.clone();
            self.balloon_event(&e);
        }
        if self.hold.stale(now) {
            selflog::line("ui: no new snapshot for 20 s, quitting");
            let _ = slint::quit_event_loop();
            return;
        }
        said_through(&mut self.said, &mut self.hold.seen, now);
        self.ticks += 1;
        if self.hold.last.is_some() {
            self.full_screen();
            self.relock();
            self.open_tick();
            self.card_tick();
            if self.ticks.is_multiple_of(5) {
                self.fifth();
            }
            if self.drag.is_none() {
                self.redraw();
            }
            self.sync_shown();
        }
        self.write_ui(false);
        let off = 1000 - ui::epoch_ms().rem_euclid(1000) + 30;
        self.tick_timer.start(
            TimerMode::SingleShot,
            Duration::from_millis(off as u64),
            || with_app(|a| a.tick()),
        );
    }

    /// A new snapshot: the held settings it agrees with let go, the host's
    /// ui block, its commands and saids, the hotkeys and the theme.
    fn taken(&mut self, now: Instant) {
        self.snap = self.hold.last.as_ref().map_or(Value::Null, |s| s.v.clone());
        let cfg = self.cfg().clone();
        let gone = |sent: Option<Instant>, agrees: bool| {
            sent.is_some_and(|t| agrees || now.duration_since(t) > HOLD_FOR)
        };
        if self
            .opacity
            .as_ref()
            .is_some_and(|h| gone(h.sent, (model::f(&cfg, "opacity") - h.v).abs() < 0.005))
        {
            self.opacity = None;
        }
        if self
            .max_rows
            .as_ref()
            .is_some_and(|h| gone(h.sent, n(&cfg, "maxRows") == h.v))
        {
            self.max_rows = None;
        }
        if self
            .recent
            .as_ref()
            .is_some_and(|h| gone(h.sent, n(&cfg, "recent") == h.v))
        {
            self.recent = None;
        }
        if self
            .theme
            .as_ref()
            .is_some_and(|h| gone(h.sent, eq(&s(&cfg, "theme"), &h.v)))
        {
            self.theme = None;
        }
        if self
            .auto
            .as_ref()
            .is_some_and(|h| gone(h.sent, eq(&s(&cfg, "autoContinue"), &h.v)))
        {
            self.auto = None;
        }
        let u = get(&self.snap, "ui").cloned().unwrap_or(Value::Null);
        let was = (self.host.console, self.host.closing);
        self.host = Host {
            spin: model::t(&u, "spin"),
            console: model::t(&u, "console"),
            closing: model::t(&u, "closing"),
            script: s(&u, "script"),
            claude_home: s(&u, "claudeHome"),
            tabs: model::list(&u, "tabs")
                .iter()
                .map(|t| (s(t, "sessionId"), s(t, "window")))
                .collect(),
        };
        if was != (self.host.console, self.host.closing) {
            selflog::line(&format!(
                "ui: console {}, closing {}",
                self.host.console, self.host.closing
            ));
        }
        // back from the console: unlocked, it locks itself 2 minutes from
        // now, not from before (Exit-ChatOverlayConsoleMode)
        if was.0 && !self.host.console && !self.st.locked {
            self.left_at = Some(now);
        }
        self.commands();
        self.saids(now);
        self.hotkeys();
        self.redraw();
    }

    /// The host's commands for its panel (a shell's, the macOS menu's),
    /// each once: only those since its first panel started (--since), and
    /// none it says it has done (overlay-ui.json's done), which it drops -
    /// so a panel started again acts on those the last left.
    fn commands(&mut self) {
        let list: Vec<(i64, i64, String)> = model::list(&self.snap, "commands")
            .iter()
            .map(|c| (n(c, "id"), n(c, "at"), s(c, "verb")))
            .collect();
        self.done.retain(|id| list.iter().any(|c| c.0 == *id));
        for (id, at, verb) in list {
            if at <= self.since || !self.done.insert(id) {
                continue;
            }
            self.act(&verb, true);
        }
    }

    /// The host's saids on the panel (take_saids).
    fn saids(&mut self, now: Instant) {
        let Some(snap) = self.hold.last.as_ref() else {
            return;
        };
        take_saids(&mut self.said, &mut self.hold.seen, &snap.events, now);
    }

    /// A said on the panel in the place of the one there (put_said).
    fn put_said(&mut self, x: SaidSlot) {
        put_said(&mut self.said, &mut self.hold.seen, x);
    }

    /// Register-ChatOverlayHotkey and the console's: each registered anew
    /// when its words change. None under CHATQ_NOTRAY.
    fn hotkeys(&mut self) {
        let words = [s(self.cfg(), "hotkey"), s(self.cfg(), "consoleHotkey")];
        for (k, (id, text)) in [trayicon::MAIN, trayicon::CONSOLE]
            .into_iter()
            .zip(words)
            .enumerate()
        {
            if self.keys[k] == text {
                continue;
            }
            self.keys[k] = text.clone();
            let Some(tray) = self.tray.as_mut() else {
                continue;
            };
            tray.unregister(id);
            match model::parse_hotkey(&text) {
                Err(e) => selflog::line(&format!("hotkey: {e}")),
                Ok(None) => {}
                Ok(Some(hk)) => {
                    if !tray.register(id, &hk) {
                        if id == trayicon::MAIN {
                            selflog::line(&format!("hotkey {text} is taken by another program"));
                            self.local_balloon(&format!("{text} is taken by another program - charlie -Hotkey picks another"), 8000, "Info");
                        } else {
                            selflog::line(&format!(
                                "console hotkey {text} is taken by another program"
                            ));
                        }
                    }
                }
            }
        }
    }

    /// Every fifth tick: topmost again, the screens and the work area looked
    /// at, the controls re-placed, and the theme 'system' read again.
    fn fifth(&mut self) {
        if self.shown {
            self.stack();
        }
        let sig = screens_sig();
        let (work, _) = win32::monitor_of(self.h(PANEL));
        if sig != self.screens_sig || work != self.work {
            self.screens_sig = sig;
            self.work = work;
            selflog::line("ui screen: the screens changed");
            self.place();
        }
        if eq(&self.theme_name(), "system") {
            let dark = win32::system_dark();
            if dark != self.sys_dark {
                self.sys_dark = dark;
                self.chip.hide();
                self.redraw();
            }
        }
    }

    /// Update-ChatOverlayFullScreen: out of a full screen's way, unless
    /// shown by hand during it. Driven, the drive's answer in the query's
    /// place, read as the real one is (win32::full_screen_of).
    fn full_screen(&mut self) {
        if self.st.hidden || self.host.console || self.host.closing {
            return;
        }
        let full = if self.drive.is_some() {
            win32::full_screen_of(
                self.fake_full
                    .map(windows::Win32::UI::Shell::QUERY_USER_NOTIFICATION_STATE)
                    .ok_or_else(|| windows::Win32::Foundation::E_FAIL.into()),
            )
        } else {
            win32::full_screen()
        };
        if full {
            if !(self.full_hidden || self.full_kept) {
                self.full_hidden = true;
                selflog::line("ui: a full screen - out of its way");
            }
        } else {
            self.full_kept = false;
            if self.full_hidden {
                self.full_hidden = false;
                selflog::line("ui: the full screen is gone");
            }
        }
    }

    /// Unlocked and left alone 2 minutes: locked again (relock_due).
    fn relock(&mut self) {
        if relock_due(
            self.st.locked,
            self.host.console,
            self.pointer_in,
            self.left_at,
            Instant::now(),
        ) {
            self.set_locked(true);
        }
    }

    // ---- verbs -----------------------------------------------------------

    /// Invoke-ChatOverlayVerb: a verb from the host's commands
    /// (`from_host`), or one of the panel's own - its tray, menu, hotkey or
    /// buttons. The host's are carried out here; the rest go to it.
    fn act(&mut self, verb: &str, from_host: bool) {
        let (word, rest) = verb.split_once(' ').unwrap_or((verb, ""));
        if self.host.closing {
            // closing by hand: only a show, the hotkeys or the console take it
            // back, the host's to do
            if !from_host && matches!(word, "show" | "hotkey" | "console" | "console-key") {
                if matches!(word, "console" | "console-key") {
                    self.grant_host();
                }
                self.cmd(word);
            }
            return;
        }
        if self.host.console {
            match word {
                "hotkey" => return self.cmd("console-back"),
                "show" => {
                    self.set_hidden(false);
                    return;
                }
                "lock" | "unlock" | "toggle" | "hide" | "collapse" | "expand" | "reset" => {
                    self.cmd("console-back")
                }
                _ => {}
            }
        }
        match word {
            "lock" => self.set_locked(true),
            "unlock" => self.set_locked(false),
            "toggle" => self.set_locked(!self.st.locked),
            "show" => {
                if self.st.hidden || self.full_hidden {
                    self.set_hidden(false);
                }
            }
            "hide" => {
                if !self.st.hidden {
                    self.set_hidden(true);
                }
            }
            "reset" => {
                self.st.x = None;
                self.st.y = None;
                self.place();
            }
            "hotkey" => {
                if self.st.hidden || self.full_hidden {
                    self.set_hidden(false);
                } else {
                    self.set_locked(!self.st.locked);
                }
            }
            "collapse" | "expand" => {
                let c = word == "collapse";
                if c != self.st.collapsed {
                    self.set_collapsed(c);
                }
            }
            _ if from_host => {}
            "console" | "console-key" => {
                self.grant_host();
                self.cmd(word);
            }
            _ => self.cmd(if rest.is_empty() { word } else { verb }),
        }
    }

    /// The console's window is the host's to bring forward (its
    /// Open-ChatOverlayHeadlessConsole): this panel's leave to set the
    /// foreground handed to the host's process first.
    fn grant_host(&self) {
        if let Some(pid) = self.hold.last.as_ref().map(|s| s.pid).filter(|&p| p > 0) {
            crate::open::grant(&[pid as u32]);
        }
    }

    /// A line for the host (Send-ChatOverlayCommand): "<utc time> <verb>".
    fn cmd(&self, verb: &str) {
        let path = self.data.join("overlay-cmd");
        let line = format!(
            "{} {verb}\n",
            chrono::Utc::now().format("%Y-%m-%dT%H:%M:%S%.6fZ")
        );
        let done = std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(&path)
            .and_then(|mut f| f.write_all(line.as_bytes()));
        match done {
            Ok(()) => selflog::line(&format!(
                "ui: sent {}",
                verb.split(' ').next().unwrap_or("")
            )),
            Err(e) => selflog::line(&format!("overlay-cmd not written: {e}")),
        }
    }

    /// Set-ChatOverlayLocked.
    fn set_locked(&mut self, on: bool) {
        self.hide_chip();
        self.st.locked = on;
        self.apply_lock();
        self.pointer_in = false;
        self.left_at = if on { None } else { Some(Instant::now()) };
        self.save_place();
        self.redraw();
    }

    /// Set-ChatOverlayHidden.
    fn set_hidden(&mut self, on: bool) {
        if !on && self.full_hidden {
            self.full_kept = true;
        }
        self.full_hidden = false;
        self.st.hidden = on;
        self.save_place();
        self.sync_shown();
    }

    /// Set-ChatOverlayCollapsed.
    fn set_collapsed(&mut self, on: bool) {
        self.st.collapsed = on;
        self.hide_chip();
        self.save_place();
        self.redraw();
    }

    /// The menu (trayicon::menu_spec) from the state now.
    fn menu(&self) -> Vec<trayicon::Item> {
        let ask = get(get(&self.snap, "header").unwrap_or(&NULL), "ask").filter(|a| a.is_object());
        let version = self
            .hold
            .last
            .as_ref()
            .map_or(String::new(), |s| s.version.clone());
        trayicon::menu_spec(&trayicon::MenuIn {
            ask,
            auto_on: eq(&s(self.cfg(), "autoContinue"), "on"),
            crash_on: model::t(self.cfg(), "autoContinueCrash"),
            version: &version,
            hotkey_text: &self.keys[0],
            hotkey_held: self.tray.as_ref().is_some_and(|t| t.held(trayicon::MAIN)),
            locked: self.st.locked,
            hidden: self.st.hidden || self.full_hidden || self.host.closing,
            collapsed: self.st.collapsed,
        })
    }

    /// A pick in the tray's menu: its verb, fixed as it opened.
    pub(crate) fn menu_pick(&mut self, name: &'static str, verb: &str) {
        selflog::line(&format!("ui: menu {name}"));
        match name {
            "lock" | "hide" | "fold" | "reset" => self.act(verb, false),
            _ if verb.is_empty() => {}
            _ => self.act(verb, false),
        }
    }

    /// What the tray's window heard (trayicon::drain).
    pub(crate) fn tray(&mut self, ev: trayicon::Ev) {
        match ev {
            trayicon::Ev::Left => {
                let v = if self.st.hidden || self.full_hidden || self.host.closing {
                    "show"
                } else {
                    "hide"
                };
                self.act(v, false);
            }
            trayicon::Ev::Right => {}
            trayicon::Ev::BalloonClick => {
                let kind = std::mem::take(&mut self.balloon.kind);
                if kind == "ask" {
                    self.act("console", false);
                }
            }
            trayicon::Ev::BalloonGone => self.balloon.kind.clear(),
            trayicon::Ev::Hotkey(trayicon::MAIN) => self.act("hotkey", false),
            trayicon::Ev::Hotkey(_) => self.act("console-key", false),
            trayicon::Ev::Tick => self.tick(),
            trayicon::Ev::Readd => {
                if let Some(t) = self.tray.as_mut() {
                    t.readd();
                }
            }
        }
    }

    /// One of the host's balloons up (Show-ChatOverlayBalloon's event).
    fn balloon_event(&mut self, e: &Event) {
        let ms = if e.ms > 0 { e.ms as u32 } else { 6000 };
        self.show_balloon(&e.title, &e.text, &e.icon, ms, &e.click);
    }

    /// One of the panel's own: titled Charlie, as the host's are.
    fn local_balloon(&mut self, text: &str, ms: u32, icon: &str) {
        self.show_balloon("Charlie", text, icon, ms, "");
    }

    fn show_balloon(&mut self, title: &str, text: &str, icon: &str, ms: u32, kind: &str) {
        self.balloon = Balloon {
            kind: kind.into(),
            title: title.into(),
            text: text.into(),
        };
        let up = self
            .tray
            .as_mut()
            .is_some_and(|t| t.balloon(title, text, icon, ms));
        // Logged whether or not the tray showed it, so a run with the tray
        // up still says which balloons came (the loopback reads this line).
        selflog::line(&format!(
            "ui: balloon {}{}",
            if kind.is_empty() { "-" } else { kind },
            if up { " (tray)" } else { "" }
        ));
    }

    // ---- showing and placing ---------------------------------------------

    fn want_shown(&self) -> bool {
        self.started
            && self.hold.last.is_some()
            && !self.st.hidden
            && !self.full_hidden
            && !self.host.closing
            && !self.host.console
    }

    /// Set-ChatOverlayShown: the panel and its bar shown or hidden as its
    /// state says - placed first if it never was - the rest with them.
    fn sync_shown(&mut self) {
        let want = self.want_shown();
        if want == self.shown {
            return;
        }
        self.shown = want;
        if want {
            if !self.placed {
                self.place();
            }
            self.layout(self.pos[PANEL]);
            self.set_visible(PANEL, true);
            self.set_visible(BAR, true);
            self.stack();
            selflog::line("ui: shown");
        } else {
            self.hide_chip();
            self.edges_shown = false;
            self.box_open = false;
            self.end_drag();
            self.hide_tip();
            for i in 0..COUNT {
                self.set_visible(i, false);
            }
            selflog::line("ui: hidden");
        }
    }

    fn set_visible(&mut self, i: usize, on: bool) {
        if self.visible[i] == on {
            return;
        }
        self.visible[i] = on;
        let w = self.scenes[i].window();
        if on {
            if !self.cloak && (i == CHIP || i == CARD) {
                win32::cloak_until_painted(self.h(i));
            }
            let _ = w.show();
        } else {
            let _ = w.hide();
        }
    }

    /// The windows shown, topmost in their order: the card over the chip
    /// over the bar over the edges over the panel.
    fn stack(&self) {
        let top: Vec<HWND> = [CARD, CHIP, BAR, EDGES, PANEL]
            .into_iter()
            .filter(|&i| self.visible[i])
            .map(|i| self.h(i))
            .collect();
        if !top.is_empty() {
            win32::stack_topmost(&top);
        }
    }

    /// Set-ChatOverlayPlacement: where it was left, while a corner of it
    /// is on some screen; else the main screen's top right.
    fn place(&mut self) {
        let wide = if self.sizes[PANEL].0 > 0 {
            self.sizes[PANEL].0
        } else {
            380
        };
        let tall = self.sizes[PANEL].1.max(24);
        let screens = win32::screens();
        let at = self.st.x.zip(self.st.y);
        let (x, y, moved) = model::placement(at, wide, tall, &screens);
        if let (true, Some((ox, oy))) = (moved, at) {
            selflog::line(&format!("ui: moved back onto a screen from {ox},{oy}"));
        }
        self.placed = true;
        if self.st.x != Some(x) || self.st.y != Some(y) {
            self.st.x = Some(x);
            self.st.y = Some(y);
            self.save_place();
        }
        self.layout((x, y));
    }

    /// overlay-state.json, read and written back with the panel's own keys
    /// set, any other kept (Save-ChatOverlayState).
    fn save_place(&self) {
        let path = self.data.join("overlay-state.json");
        let mut v = read_json(&path);
        if !v.is_object() {
            v = json!({});
        }
        let o = v.as_object_mut().unwrap();
        if let (Some(x), Some(y)) = (self.st.x, self.st.y) {
            o.insert("x".into(), json!(x));
            o.insert("y".into(), json!(y));
        }
        o.insert("locked".into(), json!(self.st.locked));
        o.insert("hidden".into(), json!(self.st.hidden));
        o.insert("collapsed".into(), json!(self.st.collapsed));
        ui::save(&path, &v.to_string());
    }

    /// The panel's height cap in units (Update-ChatOverlayMaxHeight): to
    /// the work area's foot, or during a top edge's drag up from its held
    /// foot to the area's top.
    fn cap(&self) -> f64 {
        let px = self.px();
        let row = self.built.as_ref().map_or(0.0, |b| b.row_h);
        let floor = if row > 0.0 { row } else { 42.0 } + panel::CHROME;
        let area = rect_of(self.work);
        if let Some(pointer::Drag::Size(z)) = &self.drag
            && z.top
        {
            let max = model::height_cap(self.rect.y, area, px, floor, Some(z.bottom));
            return z.cap.max(max.min(z.want.unwrap_or(z.cap)));
        }
        model::height_cap(self.pos[PANEL].1, area, px, floor, None)
    }

    /// The panel drawn anew from the snapshot and the state, sized to it,
    /// and the rest placed by it.
    fn redraw(&mut self) {
        if !self.started || self.hold.last.is_none() {
            return;
        }
        let said = self.said.as_ref().map(|x| &x.said);
        let hotkey = self.hotkey_words();
        let inp = panel::Input {
            snap: &self.snap,
            look: self.look(),
            locked: self.st.locked,
            collapsed: self.st.collapsed,
            max_rows: self.max_rows(),
            recent: self.recent_count(),
            cap: Some(self.cap()),
            said,
            hotkey: &hotkey,
            now_ms: ui::epoch_ms(),
            opacity: self.opacity(),
            wall: &clock::local_wall,
        };
        let mut b = panel::build(&inp, &self.m);
        let prims = std::mem::take(&mut b.prims);
        self.size_units(PANEL, b.width, b.height);
        scene::show(&self.scenes[PANEL], prims);
        self.built = Some(b);
        // the tray's dot in the state's colour, its tooltip the usage
        // (Set-ChatOverlayTrayColor): sent only when either changed
        let look = self.look();
        let dot = look.argb(model::tray_name(&self.snap));
        let tip = clock::tooltip(&self.snap, ui::epoch_ms(), &clock::local_wall);
        if let Some(t) = self.tray.as_mut() {
            t.set(dot, look.tray_ring, &tip);
        }
        if self.placed {
            self.layout(self.pos[PANEL]);
        }
    }

    /// A window's size in units at its own scale, set only when it changed.
    fn size_units(&mut self, i: usize, w: f64, h: f64) {
        let sc = f64::from(self.scenes[i].window().scale_factor());
        self.size_px(i, (w * sc).ceil() as i32, (h * sc).ceil() as i32);
    }

    fn size_px(&mut self, i: usize, w: i32, h: i32) {
        let (w, h) = (w.max(1), h.max(1));
        if self.sizes[i] != (w, h) {
            self.sizes[i] = (w, h);
            self.scenes[i]
                .window()
                .set_size(slint::PhysicalSize::new(w as u32, h as u32));
        }
    }

    /// A window's region from its parts in units, set only when it changed.
    fn region(&mut self, i: usize, parts: &[[f64; 4]]) {
        let sc = f64::from(self.scenes[i].window().scale_factor());
        let r = |v: f64| (v * sc).round() as i32;
        let rects: Vec<RECT> = parts
            .iter()
            .map(|p| RECT {
                left: r(p[0]),
                top: r(p[1]),
                right: r(p[0] + p[2]),
                bottom: r(p[1] + p[3]),
            })
            .collect();
        if self.regions[i].as_ref() != Some(&rects) {
            win32::set_region(self.h(i), Some(&rects));
            self.regions[i] = Some(rects);
        }
    }

    /// The panel's satellites placed by the panel's corner at `at`, and
    /// every window moved to its place in one go (win32::move_together).
    fn layout(&mut self, at: (i32, i32)) {
        if !self.started {
            return;
        }
        let px = self.px();
        let (pw, ph) = self.sizes[PANEL];
        self.rect = Rect::new(at.0, at.1, pw, ph);
        let mut to = self.pos;
        to[PANEL] = at;
        let look = self.look();
        let shown = self.shown;
        // the edges, round the panel
        if shown && self.edges_shown {
            let r = model::edges_rect(self.rect, (controls::EDGE_OUT * px).round() as i32);
            let e = controls::edges(
                look,
                f64::from(r.w) / px,
                f64::from(r.h) / px,
                self.st.collapsed,
                &self.hint,
            );
            self.size_px(EDGES, r.w, r.h);
            self.region(EDGES, &e.region);
            scene::show(&self.scenes[EDGES], e.prims);
            self.edge_hits = e.hits;
            to[EDGES] = (r.x, r.y);
        }
        // the bar and the box, in the panel's top strip
        if shown && let Some((c, at)) = self.controls_target() {
            self.size_units(BAR, c.w, c.h);
            self.region(BAR, &c.region);
            scene::show(&self.scenes[BAR], c.prims.clone());
            self.ctl = Some(c);
            to[BAR] = (at.x, at.y);
        }
        // the chip over its row
        let mut placed = None;
        if shown && self.chip.visible && !self.chip.key().is_empty() {
            let work = rect_of(self.work);
            placed = self.chip.place(
                &self.m,
                self.rect,
                work,
                px,
                look,
                self.opacity(),
                self.ms(),
            );
        }
        if let Some(p) = &placed {
            self.size_units(CHIP, p.w, p.h);
            self.region(CHIP, &p.region);
            scene::show(&self.scenes[CHIP], p.prims.clone());
            to[CHIP] = (p.x, p.y);
        }
        let chip_on = placed.is_some();
        self.placed_chip = placed;
        // the card beside the panel
        let card = if shown { self.card_target() } else { None };
        let card_on = card.is_some();
        if let Some((prims, w, h, x, y)) = card {
            self.size_px(CARD, w, h);
            scene::show(&self.scenes[CARD], prims);
            to[CARD] = (x, y);
        }
        let moves: Vec<(HWND, i32, i32)> = (0..COUNT)
            .filter(|&i| to[i] != self.pos[i] && (i == PANEL || shown))
            .map(|i| (self.h(i), to[i].0, to[i].1))
            .collect();
        if !moves.is_empty() {
            win32::move_together(&moves);
        }
        self.pos = to;
        if shown {
            self.set_visible(EDGES, self.edges_shown);
            let was = (self.visible[CHIP], self.visible[CARD]);
            self.set_visible(CHIP, chip_on);
            self.set_visible(CARD, card_on);
            self.card_up = card_on;
            if was != (chip_on, card_on) {
                self.stack();
            }
        }
    }

    /// Get-ChatOverlayControlsTarget: the controls window's content, and
    /// where it goes - the box on the side it was while it fits there.
    fn controls_target(&mut self) -> Option<(controls::Controls, model::CtlAt)> {
        let px = self.px();
        let theme = self.theme_name();
        let auto = self.auto_choice();
        let spin = if self.spinning() {
            (self.ms() % 900) as f64 / 900.0 * 360.0
        } else {
            0.0
        };
        let build = |a: &App, below: bool, left: bool| {
            controls::build(
                &controls::In {
                    look: a.look(),
                    opacity: a.opacity(),
                    panel_w: f64::from(a.rect.w) / px,
                    collapsed: a.st.collapsed,
                    spin,
                    open: a.box_open,
                    below,
                    left,
                    values: controls::Values {
                        opacity: a.opacity(),
                        rows: a.max_rows(),
                        theme: &theme,
                        recent: a.recent_count(),
                        auto: &auto,
                    },
                    thumbs: a.thumbs,
                },
                &a.m,
            )
        };
        let c = build(self, self.below, self.left);
        let r = |v: f64| (v * px).round() as i32;
        let size = ((c.w * px).ceil() as i32, (c.h * px).ceil() as i32);
        let bx = if self.box_open { r(c.box_h) } else { 0 };
        let at = model::controls_placement(
            self.rect,
            size,
            rect_of(self.work),
            r(controls::BOX_GAP),
            self.box_open && self.below,
            r(controls::BAR_H),
            bx,
            r(controls::BAR_INSET),
            r(controls::BAR_INDENT),
        );
        if (at.below, at.left) == (self.below, self.left) {
            return Some((c, at));
        }
        self.below = at.below;
        self.left = at.left;
        Some((build(self, at.below, at.left), at))
    }

    /// The card for the chip's row (Set-ChatOverlayCardPlacement): its face
    /// and window - size and corner, in screen pixels. None while the box
    /// is open, or for a row whose card has nothing yet.
    fn card_target(&self) -> Option<(Vec<Prim>, i32, i32, i32, i32)> {
        if self.box_open || self.chip.key().is_empty() || self.drag.is_some() {
            return None;
        }
        let e = self.chip.entry.as_ref()?;
        let said = self.said.as_ref().map(|x| &x.said);
        let modelv = self
            .card
            .model
            .as_ref()
            .filter(|_| eq(&self.card.key, &e.key));
        let c = card::build(
            &card::In {
                row: &e.row,
                model: modelv,
                said,
                look: self.look(),
                opacity: self.opacity(),
                now_ms: ui::epoch_ms(),
                wall: &clock::local_wall,
            },
            &self.m,
        )?;
        let px = f64::from(self.scenes[CARD].window().scale_factor());
        let w = if c.below {
            model::CARD_WIDTH
        } else {
            card::WIDTH
        };
        let size = ((w * px).ceil() as i32, (c.height * px).ceil() as i32);
        let push = self.placed_chip.as_ref().map_or(0, |p| p.out);
        let at = model::card_placement(
            self.rect,
            e.rect,
            size,
            rect_of(self.work),
            (f64::from(model::CARD_GAP) * px).round() as i32,
            push,
            c.below,
        );
        let tip = if c.below {
            f64::from(at.tip_x) / px
        } else {
            (f64::from(e.rect.y) + f64::from(e.rect.h) / 2.0 - f64::from(at.y)) / px
        };
        let (prims, _) = card::face(&c, self.look(), self.opacity(), at.left, at.above, tip);
        Some((prims, size.0, size.1, at.x, at.y))
    }

    /// The chip gone, the card with it (Hide-ChatOverlayChip).
    fn hide_chip(&mut self) {
        self.chip.hide();
        self.placed_chip = None;
        self.tile = None;
        if self.started {
            self.set_visible(CHIP, false);
            self.set_visible(CARD, false);
        }
        self.card_up = false;
    }

    /// The card's model asked of the host for the chip's row, and asked
    /// again every 2 s while it shows; data/card.json read when it changed.
    fn card_tick(&mut self) {
        let key = self.chip.key().to_string();
        let row_ok = self
            .chip
            .entry
            .as_ref()
            .is_some_and(|e| model::card_row(&e.row));
        if key.is_empty() || !row_ok || self.box_open {
            self.card.key.clear();
            return;
        }
        if !eq(&self.card.key, &key) || self.card.asked.is_none_or(|t| t.elapsed() >= CARD_AGAIN) {
            if !eq(&self.card.key, &key) {
                self.card = CardUp {
                    key: key.clone(),
                    ..CardUp::default()
                };
            }
            self.card.asked = Some(Instant::now());
            self.cmd(&format!("card {key}"));
        }
        let path = self.data.join("card.json");
        let at = std::fs::metadata(&path).and_then(|m| m.modified()).ok();
        if at.is_some() && at != self.card.read {
            self.card.read = at;
            if let Some(m) = std::fs::read_to_string(&path)
                .ok()
                .and_then(|t| card::model_of(&t, &key))
            {
                self.card.model = Some(m);
                self.layout(self.pos[PANEL]);
            }
        }
    }

    fn spinning(&self) -> bool {
        self.host.spin || self.spin_until.is_some_and(|t| Instant::now() < t)
    }

    // ---- screens ----------------------------------------------------------

    /// A screen change heard inside a window message: noted only.
    fn heard(&mut self) {
        let now = Instant::now();
        self.change = Some(self.change.map_or((now, now), |(first, _)| (first, now)));
    }

    /// The change re-placed once it has been quiet a while, and again
    /// while a window is still behind the new scale (the gate's
    /// screen_poll).
    fn screen_poll(&mut self) {
        let Some((first, last)) = self.change else {
            return;
        };
        if last.elapsed() < SETTLE {
            return;
        }
        let (work, _) = win32::monitor_of(self.h(PANEL));
        self.work = work;
        self.dpi = win32::monitor_dpi(self.h(PANEL));
        self.screens_sig = screens_sig();
        // Windows moves a window itself for a new scale: read back
        for i in 0..COUNT {
            if self.visible[i] {
                let r = win32::window_rect(self.h(i));
                self.pos[i] = (r.left, r.top);
            }
        }
        self.sizes = [(0, 0); COUNT];
        self.regions = Default::default();
        self.redraw();
        self.place();
        let behind = (0..COUNT).any(|i| {
            win32::dpi(self.h(i)) != self.dpi
                || (f64::from(self.scenes[i].window().scale_factor()) - f64::from(self.dpi) / 96.0)
                    .abs()
                    >= 0.001
        });
        if !behind || first.elapsed() >= GIVE_UP {
            selflog::line(&format!(
                "ui screen: change done, {} dpi, work area {}",
                self.dpi,
                win32::rect_text(work)
            ));
            self.change = None;
        } else {
            self.change = Some((first, Instant::now()));
        }
    }

    // ---- overlay-ui.json --------------------------------------------------

    fn under_way(&self) -> bool {
        self.pointer_in
            || self.box_open
            || self.full_hidden
            || self.drag.is_some()
            || self.tile.is_some()
            || self.pending()
            || self.opening.is_some()
    }

    fn pending(&self) -> bool {
        self.opacity.as_ref().is_some_and(|h| h.sent.is_none())
            || self.max_rows.as_ref().is_some_and(|h| h.sent.is_none())
    }

    /// overlay-ui.json: every 2 s, or at once when what it says changed.
    fn write_ui(&mut self, quick: bool) {
        let r = self.rect;
        let mut v = ui::ui_json(
            self.under_way(),
            &self.hold.seen,
            &self.done,
            [r.x, r.y, r.w, r.h],
        );
        if self.drive.is_some() {
            v["drawn"] = self.drawn();
        }
        let sig = v.to_string();
        let due = self
            .ui_at
            .is_none_or(|t| t.elapsed() >= Duration::from_secs(2));
        if sig == self.ui_sig && !due || quick && sig == self.ui_sig {
            return;
        }
        self.ui_sig = sig;
        self.ui_at = Some(Instant::now());
        v["at"] = json!(ui::epoch_ms());
        ui::save(&self.data.join("overlay-ui.json"), &v.to_string());
    }

    /// What is drawn, for a driven run's checks.
    fn drawn(&self) -> Value {
        let b = self.built.as_ref();
        json!({
            "shown": self.shown,
            "visible": self.visible,
            "locked": self.st.locked,
            "collapsed": self.st.collapsed,
            "hidden": self.st.hidden,
            "fullHidden": self.full_hidden,
            "rows": b.map_or(0, |b| b.rows),
            "recent": b.map_or(0, |b| b.recent),
            "items": b.map_or(Vec::new(), |b| b.items.iter().map(|i| i.key.clone()).collect::<Vec<_>>()),
            "chip": self.chip.key(),
            "acts": self.chip.acts.iter().map(|a| a.id).collect::<Vec<_>>(),
            "hint": self.chip.hint.0,
            "card": if self.card_up { self.chip.key() } else { "" },
            "box": self.box_open,
            "edges": self.edges_shown,
            "edge": self.hint,
            "balloon": { "title": self.balloon.title, "text": self.balloon.text, "kind": self.balloon.kind },
            "said": self.said.as_ref().map_or(String::new(), |x| x.said.text.clone()),
            "theme": self.theme_name(),
            "look": self.look().name,
            "opacity": self.opacity(),
            "maxRows": self.max_rows(),
            "recentCount": self.recent_count(),
            "auto": self.auto_choice(),
            "opening": self.opening.is_some(),
            "tip": self.tip.as_ref().and_then(|t| t.text()).unwrap_or(""),
            "pos": self.pos,
        })
    }
}

/// The screens' work areas and which is the main one, as one string.
fn screens_sig() -> String {
    win32::screens()
        .iter()
        .map(|(r, p)| {
            format!(
                "{},{},{},{}{}",
                r.x,
                r.y,
                r.w,
                r.h,
                if *p { "*" } else { "" }
            )
        })
        .collect::<Vec<_>>()
        .join(";")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Unlocked and left, by the test's own clock: locked again at 2
    /// minutes, not a moment before - and never while locked, with the
    /// pointer on it, while the console has its place, or never left.
    #[test]
    fn it_locks_again_two_minutes_after_it_is_left() {
        let t = Instant::now();
        let due = relock_due;
        assert!(!due(
            false,
            false,
            false,
            Some(t),
            t + RELOCK - Duration::from_millis(1)
        ));
        assert!(due(false, false, false, Some(t), t + RELOCK));
        assert!(due(false, false, false, Some(t), t + RELOCK * 30));
        assert!(!due(true, false, false, Some(t), t + RELOCK), "locked");
        assert!(
            !due(false, false, true, Some(t), t + RELOCK),
            "the pointer on it"
        );
        assert!(
            !due(false, true, false, Some(t), t + RELOCK),
            "the console's"
        );
        assert!(!due(false, false, false, None, t + RELOCK), "never left");
        let later = t + Duration::from_secs(90);
        assert!(
            !due(false, false, false, Some(later), t + RELOCK),
            "left again since"
        );
        assert!(
            !due(false, false, false, Some(later), t),
            "a clock behind the leave"
        );
    }

    /// A said the panel had up when it was started again is not seen, so
    /// the host keeps it and the next panel shows it again for its whole
    /// time; the one it took the place of, and one shown its time through,
    /// are seen.
    #[test]
    fn a_said_outlives_a_restart_of_the_panel() {
        let said = |id: &str, at: i64| Event {
            id: id.into(),
            at,
            kind: "said".into(),
            text: id.into(),
            ms: 5000,
            ..Event::default()
        };
        let on = |slot: &Option<SaidSlot>| slot.as_ref().map(|x| x.id.clone());
        let t = Instant::now();
        let (mut slot, mut seen) = (None, BTreeSet::new());
        take_saids(&mut slot, &mut seen, &[said("9-1", 1), said("9-2", 2)], t);
        assert_eq!(on(&slot).as_deref(), Some("9-2"));
        assert_eq!(
            seen,
            BTreeSet::from(["9-1".to_string()]),
            "9-2 not seen yet"
        );
        // the panel started again 2 s on: the host dropped what it saw
        let t2 = t + Duration::from_secs(2);
        let (mut slot, mut seen) = (None, BTreeSet::new());
        take_saids(&mut slot, &mut seen, &[said("9-2", 2)], t2);
        assert_eq!(on(&slot).as_deref(), Some("9-2"), "shown again");
        assert!(
            slot.as_ref()
                .is_some_and(|x| x.until == t2 + Duration::from_secs(5))
        );
        assert!(seen.is_empty());
        take_saids(
            &mut slot,
            &mut seen,
            &[said("9-2", 2)],
            t2 + Duration::from_secs(1),
        );
        assert!(seen.is_empty(), "the same said, on already");
        // a newer one takes its place: 9-2 seen now
        take_saids(&mut slot, &mut seen, &[said("9-2", 2), said("9-3", 3)], t2);
        assert_eq!(on(&slot).as_deref(), Some("9-3"));
        assert_eq!(seen, BTreeSet::from(["9-2".to_string()]));
        said_through(&mut slot, &mut seen, t2 + Duration::from_millis(4999));
        assert_eq!(on(&slot).as_deref(), Some("9-3"), "still up");
        said_through(&mut slot, &mut seen, t2 + Duration::from_secs(5));
        assert!(slot.is_none());
        assert_eq!(seen, BTreeSet::from(["9-2", "9-3"].map(String::from)));
    }
}
