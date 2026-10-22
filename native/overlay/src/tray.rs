// M9 spike, step 4: tray icon, menu, balloons and the hotkey (--tray).
//
//   --tray            a tray icon (tray-icon) whose dot is drawn in code and
//                     redrawn 1,800 times, every 40 ms, while GDI and USER
//                     handle counts are logged; a 127-unit tooltip, and a
//                     128-unit one from 20 s to 30 s; a menu (muda) with
//                     check items, a text that changes every 3 s and a
//                     rebuild every 10 s; a balloon to click; the spike's
//                     own hotkey; at the end a close balloon and a 4 s
//                     delayed exit, the icon removed last
//   --tray --second   only the same hotkey, which must come back "taken"
//   --tray --standin  as --tray, with the hand checks stood in for by
//                     messages to the spike's own windows (tray/standin.rs)
//
// The hotkey is Ctrl+Alt+Shift+F12. The live overlay holds Ctrl+Alt+Shift+O
// and Ctrl+Alt+Shift+Q (overlay-data.ps1, the hotkey and consoleHotkey
// defaults; data/config.json sets neither); neither is ever touched here.
//
// Every tray, menu, balloon and hotkey event is heard where the crate's
// window procedure (or thread) runs and is handed to Slint's loop with
// invoke_from_event_loop, a message posted to winit's loop: no poll and no
// loop of our own. The log has the thread it was heard on and the one it
// was handled on beside the UI thread. A small status window, bottom right,
// shows the phase and the last event; a left click on the icon hides and
// shows it, as on the real overlay's.

use std::cell::RefCell;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering::SeqCst};
use std::time::{Duration, Instant};

use global_hotkey::hotkey::{Code, HotKey, Modifiers};
use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState};
use slint::ComponentHandle;
use tray_icon::menu::{CheckMenuItem, ContextMenu, Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Shell::{
    DefSubclassProc, NIF_INFO, NIIF_INFO, NIIF_NOSOUND, NIM_MODIFY, NIN_BALLOONHIDE,
    NIN_BALLOONSHOW, NIN_BALLOONTIMEOUT, NIN_BALLOONUSERCLICK, NOTIFYICONDATAW,
    NOTIFYICONIDENTIFIER, SetWindowSubclass, Shell_NotifyIconGetRect, Shell_NotifyIconW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetSystemMetrics, IsWindow, SM_CXSMICON, WM_ENTERMENULOOP, WM_EXITMENULOOP,
};

use crate::{later, repeat, selflog, show_no_activate, win32};

mod standin;

slint::slint! {
    export component Status inherits Window {
        in property <string> phase;
        in property <string> last;
        in property <string> counts;
        no-frame: true;
        always-on-top: true;
        background: transparent;
        width: 320px;
        height: 120px;
        Rectangle { border-radius: 12px; background: #1e1f24; }
        Text { x: 12px; y: 8px; text: root.phase; color: #f5b942; font-size: 24px; font-weight: 700; }
        Text { x: 12px; y: 44px; width: 296px; text: root.last; color: #9fd0ff; font-size: 12px; wrap: word-wrap; }
        Text { x: 12px; y: 92px; width: 296px; text: root.counts; color: #c0c0c0; font-size: 11px; }
    }
}

const W: f32 = 320.0;
const H: f32 = 120.0;
const MARGIN: i32 = 24;
pub(crate) const CHORD: &str = "Ctrl+Alt+Shift+F12";
/// The dot's redraws to watch handle counts over, a sample every 300.
const REDRAWS: u32 = 1800;
const REDRAW_MS: u64 = 40;
/// After the 1,800: a redraw every this many ticks, 3 s.
const SLOW_TICKS: u32 = 75;
/// Balloons show as Windows notifications on the user's screen: a run asks
/// for no more than these.
const MAX_BALLOONS: u32 = 5;
/// tray-icon's callback message on its own window (WM_USER_TRAYICON in
/// tray-icon's platform_impl/windows/mod.rs). It sets no NOTIFYICON_VERSION_4,
/// so the event is lParam itself: the mouse message, or NIN_BALLOON*.
pub(crate) const TRAY_CALLBACK: u32 = 6002;
/// The real overlay's state colours (ChatOverlayPalettes.dark) and its
/// dark look's trayRing.
pub(crate) const COLORS: [(&str, u32); 5] = [
    ("idle", 0x80868F),
    ("busy", 0x4CC38A),
    ("running", 0x4EA1FF),
    ("waiting", 0xF5B942),
    ("cutoff", 0xFF8A4C),
];
const RING: u32 = 0x6E0F24;

/// The UI thread, Slint's: each event's log line names it beside its own.
static UI_THREAD: AtomicU32 = AtomicU32::new(0);
/// The tray menu is open (WM_ENTERMENULOOP on tray-icon's window, which
/// owns the menu while TrackPopupMenu runs): no rebuild meanwhile.
static MENU_OPEN: AtomicBool = AtomicBool::new(false);

/// What a crate (or the balloon subclass) heard, on its way to Slint's loop.
enum Heard {
    Tray(TrayIconEvent),
    Menu(MenuEvent),
    Hotkey(GlobalHotKeyEvent),
    Balloon(u32),
    MenuLoop(bool),
}

/// The items whose text or check is changed later.
struct Items {
    lock: MenuItem,
    auto: CheckMenuItem,
    crash: CheckMenuItem,
}

struct State {
    status: Status,
    shown: bool,
    /// None in --second, and once the icon is removed at the end.
    tray: Option<TrayIcon>,
    /// tray-icon's own window and the icon's uID on it, for NIF_INFO.
    tray_hwnd: HWND,
    uid: Option<u32>,
    items: Option<Items>,
    /// The current menu's HMENU, the one TrackPopupMenu would show.
    menu_handle: isize,
    /// --standin: the hand checks stood in for (tray/standin.rs).
    standin: bool,
    auto_on: bool,
    crash_on: bool,
    locked: bool,
    rebuilds: u32,
    /// (rebuild, gdi, user) just after each rebuild
    rebuild_counts: Vec<(u32, u32, u32)>,
    ticks: u32,
    redraws: u32,
    /// (redraws, private MB, gdi, user) at the start, every 300 and the end
    redraw_counts: Vec<(u32, f64, u32, u32)>,
    icon_errors: u32,
    /// The tooltip's length now, on the status window's bottom line: the
    /// blue line is taken by the hover's own events while a hand checks it.
    tip_units: usize,
    last_tick: Instant,
    late_ticks: u32,
    balloons: u32,
    balloon_clicks: u32,
    presses: u32,
    hotkey: Option<(GlobalHotKeyManager, HotKey)>,
    hotkey_text: String,
    closing: bool,
}

thread_local! {
    static STATE: RefCell<Option<State>> = const { RefCell::new(None) };
}

fn with<R>(f: impl FnOnce(&mut State) -> R) -> R {
    STATE.with(|s| f(s.borrow_mut().as_mut().expect("tray state")))
}

fn thread() -> u32 {
    unsafe { GetCurrentThreadId() }
}

/// Runs the tray mode to its end: the event loop included.
pub fn run(second: bool, standin: bool, seconds: u64) {
    UI_THREAD.store(thread(), SeqCst);
    selflog::line(&format!("tray: UI thread {}", thread()));
    // Handlers run where the crate heard the event: tray-icon's and muda's in
    // the window procedure of tray-icon's window, global-hotkey's in its own
    // window's (the press) or a thread it spawns per press (the release).
    TrayIconEvent::set_event_handler(Some(|e: TrayIconEvent| {
        // Move comes with every mouse move over the icon: not worth a line
        if !matches!(e, TrayIconEvent::Move { .. }) {
            hand_over(Heard::Tray(e));
        }
    }));
    MenuEvent::set_event_handler(Some(|e| hand_over(Heard::Menu(e))));
    GlobalHotKeyEvent::set_event_handler(Some(|e| hand_over(Heard::Hotkey(e))));

    let status = Status::new().unwrap();
    let (hotkey, hotkey_text) = register_hotkey();
    let mut state = State {
        status: status.clone_strong(),
        shown: true,
        tray: None,
        tray_hwnd: HWND::default(),
        uid: None,
        items: None,
        menu_handle: 0,
        standin,
        auto_on: false,
        crash_on: true,
        locked: true,
        rebuilds: 0,
        rebuild_counts: Vec::new(),
        ticks: 0,
        redraws: 0,
        redraw_counts: Vec::new(),
        icon_errors: 0,
        tip_units: 127,
        last_tick: Instant::now(),
        late_ticks: 0,
        balloons: 0,
        balloon_clicks: 0,
        presses: 0,
        hotkey,
        hotkey_text,
        closing: false,
    };
    let taken = state.hotkey.is_none();
    if second {
        status.set_phase(if taken {
            "SECOND: TAKEN".into()
        } else {
            "SECOND: NOT TAKEN?".into()
        });
        status.set_last(format!("{CHORD}: {}", state.hotkey_text).into());
    } else {
        add_tray(&mut state);
        status.set_phase("TRAY".into());
        status.set_last("hands off: redraws and handle counts first".into());
    }
    STATE.with(|s| *s.borrow_mut() = Some(state));

    // Bottom right; the second instance just above, so both can be seen.
    let work = win32::work_area();
    let scale = win32::system_scale();
    let up = if second {
        ((H + 16.0) * scale) as i32
    } else {
        0
    };
    let (x, y) = (
        work.right - (W * scale) as i32 - MARGIN,
        work.bottom - (H * scale) as i32 - MARGIN - up,
    );
    show_no_activate(&status, x, y, |hwnd| {
        selflog::line(&format!(
            "status window shown: {}",
            win32::rect_text(win32::window_rect(hwnd))
        ))
    });

    let mut timers = Vec::new();
    if !second {
        timers.push(repeat(Duration::from_millis(REDRAW_MS), redraw_tick));
        timers.push(repeat(Duration::from_secs(3), || {
            with(|s| {
                if let Some(items) = &s.items {
                    items.lock.set_text(lock_text(s.locked));
                }
            })
        }));
        timers.push(repeat(Duration::from_secs(10), || with(rebuild)));
        later(8000, || with(|s| click_balloon(s, "first")));
        if seconds >= 120 {
            later(seconds * 500, || {
                with(|s| {
                    if s.balloon_clicks == 0 {
                        click_balloon(s, "again, none clicked yet")
                    }
                })
            });
        }
        later(20_000, || with(|s| set_tooltip(s, 128)));
        later(30_000, || with(|s| set_tooltip(s, 127)));
        if standin {
            standin::start(seconds);
        }
    }
    slint::Timer::single_shot(Duration::from_secs(seconds), move || {
        if second {
            let _ = slint::quit_event_loop();
        } else {
            with(|s| begin_close(s, "the run's --seconds are up"));
        }
    });
    slint::run_event_loop_until_quit().unwrap();
    drop(timers);
    with(|s| {
        if let Some((manager, key)) = s.hotkey.take() {
            selflog::line(&format!(
                "hotkey: unregistered: {:?}",
                manager.unregister(key)
            ));
        }
        if !second {
            summary(s);
        }
    });
}

/// The spike's chord, registered on global-hotkey's own hidden window,
/// which this thread owns. The crate always adds MOD_NOREPEAT
/// (platform_impl/windows/mod.rs, register). Never the live overlay's.
pub(crate) fn register_hotkey() -> (Option<(GlobalHotKeyManager, HotKey)>, String) {
    let key = HotKey::new(
        Some(Modifiers::CONTROL | Modifiers::ALT | Modifiers::SHIFT),
        Code::F12,
    );
    let manager = GlobalHotKeyManager::new().expect("global-hotkey's window");
    match manager.register(key) {
        Ok(()) => {
            selflog::line(&format!(
                "hotkey: {CHORD} registered (id {}), MOD_NOREPEAT added by the crate",
                key.id()
            ));
            (Some((manager, key)), CHORD.to_string())
        }
        Err(e) => {
            selflog::line(&format!(
                "hotkey: {CHORD} not registered: Display \"{e}\"; Debug {e:?}; the run carries on"
            ));
            (None, format!("{CHORD} (taken)"))
        }
    }
}

/// The icon, its tooltip and menu; then its uID on tray-icon's window
/// (TrayIcon::window_uid, the vendored patch) and the subclass that hears
/// its balloons.
fn add_tray(s: &mut State) {
    let (menu, items) = build_menu(s);
    let tip = tooltip(127);
    s.menu_handle = menu.hpopupmenu();
    let tray = TrayIconBuilder::new()
        .with_icon(dot_icon(COLORS[0].1))
        .with_tooltip(&tip)
        .with_menu(Box::new(menu))
        // as the real overlay: left click hides and shows, right click the menu
        .with_menu_on_left_click(false)
        .build()
        .expect("tray icon");
    log_tooltip(&tip, "at creation", Ok(()));
    s.tray_hwnd = HWND(tray.window_handle() as *mut _);
    s.uid = Some(tray.window_uid());
    s.items = Some(items);
    s.rebuilds = 1;
    s.tray = Some(tray);
    unsafe { assert!(SetWindowSubclass(s.tray_hwnd, Some(balloon_proc), 4, 0).as_bool()) };
    let (_, gdi, user) = selflog::counts();
    s.rebuild_counts.push((1, gdi, user));
    selflog::line(&format!(
        "tray: icon added on tray-icon's window {:?} (class {}), uID {:?}; balloons go through that window and uID (way 1)",
        s.tray_hwnd.0,
        win32::class_name(s.tray_hwnd),
        s.uid
    ));
}

/// Explorer's rect for the icon, None once it holds no such icon: the
/// close's ghost check. Read only.
pub(crate) fn icon_rect(hwnd: HWND, uid: u32) -> Option<String> {
    let id = NOTIFYICONIDENTIFIER {
        cbSize: size_of::<NOTIFYICONIDENTIFIER>() as u32,
        hWnd: hwnd,
        uID: uid,
        ..Default::default()
    };
    unsafe { Shell_NotifyIconGetRect(&id) }
        .ok()
        .map(win32::rect_text)
}

/// The menu as the real overlay's has it, in small: two check items, an
/// item whose text changes (the lock's, with the time, every 3 s), a
/// disabled head that counts the builds, the hotkey line, and Quit, which
/// closes as the real one does: a close balloon, then 4 s.
fn build_menu(s: &State) -> (Menu, Items) {
    let menu = Menu::new();
    let items = Items {
        lock: MenuItem::with_id("lock", lock_text(s.locked), true, None),
        auto: CheckMenuItem::with_id(
            "auto",
            "Auto-continue cut-off chats (spike)",
            true,
            s.auto_on,
            None,
        ),
        crash: CheckMenuItem::with_id(
            "crash",
            "Continue chats a crash cut off (spike)",
            true,
            s.crash_on,
            None,
        ),
    };
    let head = MenuItem::with_id(
        "head",
        format!("M9 spike - menu build {}", s.rebuilds + 1),
        false,
        None,
    );
    let hotkey = MenuItem::with_id("hotkey", format!("hotkey  {}", s.hotkey_text), false, None);
    let quit = MenuItem::with_id("quit", "Quit (close balloon, then 4 s)", true, None);
    let separator = || PredefinedMenuItem::separator();
    for item in [
        &items.auto as &dyn tray_icon::menu::IsMenuItem,
        &items.crash,
        &separator(),
        &head,
        &hotkey,
        &separator(),
        &items.lock,
        &quit,
    ] {
        menu.append(item).unwrap();
    }
    (menu, items)
}

fn lock_text(locked: bool) -> String {
    format!(
        "{}   {}",
        if locked { "Unlock to move" } else { "Lock" },
        win32::local_hms()
    )
}

/// Every 10 s a whole new menu, as the real overlay's ask items come and
/// go; the old one is destroyed by muda when tray-icon drops it. Not while
/// the menu is open, as the real overlay holds its ask items then.
fn rebuild(s: &mut State) {
    if s.tray.is_none() || s.closing {
        return;
    }
    if MENU_OPEN.load(SeqCst) {
        selflog::line("menu: rebuild skipped, the menu is open");
        return;
    }
    let (_, gdi0, user0) = selflog::counts();
    let (menu, items) = build_menu(s);
    s.menu_handle = menu.hpopupmenu();
    s.tray.as_ref().unwrap().set_menu(Some(Box::new(menu)));
    s.items = Some(items);
    s.rebuilds += 1;
    let (_, gdi, user) = selflog::counts();
    s.rebuild_counts.push((s.rebuilds, gdi, user));
    selflog::line(&format!(
        "menu: build {}: gdi {gdi0} -> {gdi}, user {user0} -> {user}",
        s.rebuilds
    ));
}

/// One redraw of the dot: a new icon from new pixels each time, the
/// colour stepping through the states every 10 redraws. After the 1,800,
/// one every 3 s, so a hand check still sees it change.
fn redraw_tick() {
    with(|s| {
        let now = Instant::now();
        let gap = now.duration_since(s.last_tick).as_millis();
        s.last_tick = now;
        // A Slint timer held up, by the menu's own loop or anything else.
        if gap > 250 {
            s.late_ticks += 1;
            selflog::line(&format!(
                "redraw timer: {gap} ms since the last tick; menu open {}",
                MENU_OPEN.load(SeqCst)
            ));
        }
        s.ticks += 1;
        if s.tray.is_none() || (s.redraws >= REDRAWS && s.ticks % SLOW_TICKS != 0) {
            return;
        }
        if s.redraws == 0 {
            sample_redraws(s);
        }
        let (name, rgb) = COLORS[(s.redraws as usize / 10) % COLORS.len()];
        if let Err(e) = s.tray.as_ref().unwrap().set_icon(Some(dot_icon(rgb))) {
            s.icon_errors += 1;
            selflog::line(&format!("tray: set_icon failed: {e}"));
        }
        s.redraws += 1;
        if s.redraws % 300 == 0 && s.redraws <= REDRAWS {
            sample_redraws(s);
        }
        s.status.set_counts(
            format!(
                "redraw {} ({name}); builds {}; tooltip {} units",
                s.redraws, s.rebuilds, s.tip_units
            )
            .into(),
        );
    });
}

fn sample_redraws(s: &mut State) {
    let (private, gdi, user) = selflog::counts();
    s.redraw_counts.push((s.redraws, private, gdi, user));
    selflog::line(&format!(
        "redraws {}: private={private:.1}MB gdi={gdi} user={user}",
        s.redraws
    ));
}

/// The dot, as Set-ChatOverlayTrayColor draws it without Charlie's art:
/// 22/32 of the icon wide, at the small-icon size of this screen's scale,
/// ringed in trayRing a sixteenth wide, edges anti-aliased.
pub(crate) fn dot_icon(rgb: u32) -> Icon {
    let n = unsafe { GetSystemMetrics(SM_CXSMICON) }.clamp(16, 64) as u32;
    let (c, outer) = (n as f32 / 2.0, n as f32 * 11.0 / 32.0);
    let inner = outer - (n as f32 / 16.0).max(1.0);
    let mut rgba = Vec::with_capacity((n * n * 4) as usize);
    for y in 0..n {
        for x in 0..n {
            let d = ((x as f32 + 0.5 - c).powi(2) + (y as f32 + 0.5 - c).powi(2)).sqrt();
            let cover = (outer - d + 0.5).clamp(0.0, 1.0);
            let colour = if inner - d + 0.5 > 0.5 { rgb } else { RING };
            rgba.extend_from_slice(&[
                (colour >> 16) as u8,
                (colour >> 8) as u8,
                colour as u8,
                (cover * 255.0) as u8,
            ]);
        }
    }
    Icon::from_rgba(rgba, n, n).expect("dot icon")
}

/// `units` UTF-16 units: szTip holds 128 with its NUL, so 127 is the most
/// Windows keeps - the real overlay's cut (Format-ChatOverlayTooltip
/// counts .NET's Length, UTF-16 units too). Hangul (a unit a syllable,
/// three UTF-8 bytes) and one character outside the BMP (two units) make
/// characters, units and bytes all differ.
fn tooltip(units: usize) -> String {
    let mut t = String::from("M9 spike tray - 한글 툴팁 시험 𝄞 ");
    let mut i = 0u8;
    while t.encode_utf16().count() < units {
        t.push(char::from(b'0' + i % 10));
        i += 1;
    }
    t
}

fn set_tooltip(s: &mut State, units: usize) {
    let Some(tray) = &s.tray else { return };
    let tip = tooltip(units);
    let result = tray.set_tooltip(Some(&tip));
    log_tooltip(&tip, "set", result);
    s.tip_units = units;
    s.status
        .set_last(format!("tooltip now {units} UTF-16 units").into());
}

/// What was sent: Shell_NotifyIcon has no way to read a tooltip back.
/// tray-icon copies min(units + NUL, 128) units into szTip
/// (set_tooltip, register_tray_icon), so 128 units or more go with no NUL.
fn log_tooltip(tip: &str, when: &str, result: tray_icon::Result<()>) {
    let units = tip.encode_utf16().count();
    let copied = (units + 1).min(128);
    selflog::line(&format!(
        "tooltip {when}: {} chars, {units} UTF-16 units, {} UTF-8 bytes; szTip gets {copied} units, NUL {}; result {result:?}; text \"{tip}\"",
        tip.chars().count(),
        tip.len(),
        if units < 128 { "included" } else { "cut off" }
    ));
}

/// A NIF_INFO balloon on the icon tray-icon made: its own window and uID
/// (way 1), as tray-icon has no balloon call of its own in 0.26. The
/// click comes back as tray-icon's callback message, heard by balloon_proc.
fn balloon(s: &mut State, title: &str, text: &str) -> bool {
    let Some(uid) = s.uid else {
        selflog::line("balloon: no uID found, none shown");
        return false;
    };
    if s.balloons >= MAX_BALLOONS {
        selflog::line(&format!(
            "balloon: not shown, {MAX_BALLOONS} already this run"
        ));
        return false;
    }
    s.balloons += 1;
    if s.standin {
        standin::before_balloon(s.balloons);
    }
    let mut nid = NOTIFYICONDATAW {
        cbSize: size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: s.tray_hwnd,
        uID: uid,
        uFlags: NIF_INFO,
        dwInfoFlags: NIIF_INFO | NIIF_NOSOUND,
        ..Default::default()
    };
    fill(&mut nid.szInfoTitle, title);
    fill(&mut nid.szInfo, text);
    let accepted = unsafe { Shell_NotifyIconW(NIM_MODIFY, &nid) }.as_bool();
    selflog::line(&format!(
        "balloon {}: \"{title}\" sent, Shell_NotifyIcon(NIM_MODIFY, NIF_INFO) = {accepted}",
        s.balloons
    ));
    accepted
}

fn click_balloon(s: &mut State, why: &str) {
    if s.closing {
        return;
    }
    selflog::line(&format!("balloon to click: {why}"));
    balloon(
        s,
        "M9 spike test",
        "From the M9 spike test (overlay-spike), not Charlie. Click here: the spike logs the click.",
    );
    s.status.set_last("balloon shown: click it".into());
}

/// `text` into a fixed NUL-ended field, cut to fit.
pub(crate) fn fill(field: &mut [u16], text: &str) {
    let units: Vec<u16> = text.encode_utf16().take(field.len() - 1).collect();
    field[..units.len()].copy_from_slice(&units);
    field[units.len()] = 0;
}

/// Subclass of tray-icon's window: its callback message with a balloon's
/// NIN_* (tray-icon passes those on unhandled), and the menu's loop
/// starting and ending. Each is handed over like the crates' events.
unsafe extern "system" fn balloon_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _id: usize,
    _data: usize,
) -> LRESULT {
    if msg == TRAY_CALLBACK {
        let code = (lparam.0 & 0xffff) as u32;
        if (NIN_BALLOONSHOW..=NIN_BALLOONUSERCLICK).contains(&code) {
            hand_over(Heard::Balloon(code));
        }
    }
    if msg == WM_ENTERMENULOOP || msg == WM_EXITMENULOOP {
        MENU_OPEN.store(msg == WM_ENTERMENULOOP, SeqCst);
        hand_over(Heard::MenuLoop(msg == WM_ENTERMENULOOP));
    }
    unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) }
}

/// From wherever it was heard to Slint's loop: invoke_from_event_loop
/// posts it to winit's loop, which wakes for it (no poll).
fn hand_over(heard: Heard) {
    let on = thread();
    // fails only once the loop has quit: the event is dropped then
    let _ = slint::invoke_from_event_loop(move || on_heard(on, heard));
}

fn on_heard(heard_on: u32, heard: Heard) {
    let threads = format!(
        "heard on thread {heard_on}, handled on {} (UI {})",
        thread(),
        UI_THREAD.load(SeqCst)
    );
    let text = match heard {
        Heard::Tray(e) => tray_event(e),
        Heard::Menu(e) => menu_event(e),
        Heard::Hotkey(e) => hotkey_event(e),
        Heard::Balloon(code) => balloon_event(code),
        Heard::MenuLoop(open) => format!("menu {}", if open { "opened" } else { "closed" }),
    };
    selflog::line(&format!("event: {text}; {threads}"));
    with(|s| s.status.set_last(text.into()));
}

fn tray_event(e: TrayIconEvent) -> String {
    match e {
        TrayIconEvent::Click {
            button: MouseButton::Left,
            button_state: MouseButtonState::Up,
            ..
        } => with(|s| {
            s.shown = !s.shown;
            if s.shown {
                s.status.show().unwrap()
            } else {
                s.status.hide().unwrap()
            }
            format!(
                "tray left click: status window {}",
                if s.shown { "shown" } else { "hidden" }
            )
        }),
        TrayIconEvent::Click {
            button,
            button_state,
            ..
        } => format!("tray click {button:?} {button_state:?}"),
        TrayIconEvent::DoubleClick { button, .. } => format!("tray double click {button:?}"),
        TrayIconEvent::Enter { .. } => "tray: pointer over the icon".to_string(),
        TrayIconEvent::Leave { .. } => "tray: pointer left the icon".to_string(),
        other => format!("tray {other:?}"),
    }
}

fn menu_event(e: MenuEvent) -> String {
    with(|s| {
        let Some(items) = &s.items else {
            return format!("menu {:?} with no menu", e.id);
        };
        match e.id.0.as_str() {
            // muda has already flipped the check when this comes
            "auto" => {
                s.auto_on = items.auto.is_checked();
                format!("menu: auto-continue now checked={}", s.auto_on)
            }
            "crash" => {
                s.crash_on = items.crash.is_checked();
                format!("menu: crash continue now checked={}", s.crash_on)
            }
            "lock" => {
                s.locked = !s.locked;
                items.lock.set_text(lock_text(s.locked));
                format!("menu: {}", if s.locked { "locked" } else { "unlocked" })
            }
            "quit" => {
                begin_close(s, "Quit in the tray menu");
                "menu: Quit".to_string()
            }
            other => format!("menu: {other}"),
        }
    })
}

/// MOD_NOREPEAT: a held chord gives one press; global-hotkey sends the
/// release from a thread it spawns per press, polling the key every 50 ms.
fn hotkey_event(e: GlobalHotKeyEvent) -> String {
    with(|s| match e.state() {
        HotKeyState::Pressed => {
            s.presses += 1;
            s.status.set_phase(format!("HOTKEY #{}", s.presses).into());
            format!("hotkey {CHORD} pressed (press {})", s.presses)
        }
        HotKeyState::Released => format!("hotkey {CHORD} released (after press {})", s.presses),
    })
}

fn balloon_event(code: u32) -> String {
    let name = match code {
        NIN_BALLOONSHOW => {
            with(|s| {
                if s.standin {
                    standin::balloon_shown(s)
                }
            });
            "NIN_BALLOONSHOW (shown)"
        }
        NIN_BALLOONHIDE => "NIN_BALLOONHIDE (gone, icon removed)",
        NIN_BALLOONTIMEOUT => "NIN_BALLOONTIMEOUT (timed out or closed)",
        _ => {
            with(|s| s.balloon_clicks += 1);
            "NIN_BALLOONUSERCLICK (clicked)"
        }
    };
    format!("balloon: {name}")
}

/// The real overlay's close by hand (Close-ChatOverlayByHand): the close
/// balloon first, the process and its icon kept 4 s so it is read, then
/// the icon removed and the loop ended.
fn begin_close(s: &mut State, why: &str) {
    if s.closing {
        return;
    }
    s.closing = true;
    selflog::line(&format!("close: begun ({why}); 1. close balloon"));
    s.status.set_phase("CLOSING".into());
    s.status
        .set_last("close balloon shown; icon removed in 4 s".into());
    balloon(
        s,
        "M9 spike closing",
        "From the M9 spike test: closing in 4 s. Its tray icon goes then.",
    );
    if s.standin {
        standin::watch_close();
    }
    later(4000, || with(end_close));
}

fn end_close(s: &mut State) {
    let Some(tray) = s.tray.take() else { return };
    let uid = s.uid.unwrap_or(0);
    selflog::line(&format!(
        "close: 2. 4 s up; Explorer has the icon: {:?}",
        icon_rect(s.tray_hwnd, uid)
    ));
    // tray-icon's Drop: NIM_DELETE, then DestroyWindow of its window
    drop(tray);
    s.items = None;
    selflog::line(&format!(
        "close: 3. icon dropped (NIM_DELETE); Explorer has the icon: {:?}; tray-icon's window still exists: {}",
        icon_rect(s.tray_hwnd, uid),
        unsafe { IsWindow(Some(s.tray_hwnd)) }.as_bool()
    ));
    selflog::line("close: 4. event loop ends");
    let _ = slint::quit_event_loop();
}

/// The verdicts: handle counts over the redraws (from the 300th, past
/// first-use allocations) and over the menu builds.
fn summary(s: &State) {
    let series: Vec<String> = s
        .redraw_counts
        .iter()
        .map(|(n, p, g, u)| format!("{n}:{p:.1}MB/g{g}/u{u}"))
        .collect();
    let at = |n: u32| {
        s.redraw_counts
            .iter()
            .find(|e| e.0 == n)
            .map(|e| (e.2, e.3))
    };
    let flat = match (at(300), at(REDRAWS)) {
        (Some((g0, u0)), Some((g1, u1))) => format!(
            "gdi {g0} -> {g1}, user {u0} -> {u1}: {}",
            if g1 <= g0 + 2 && u1 <= u0 + 2 {
                "FLAT"
            } else {
                "GROWS"
            }
        ),
        _ => format!("only {} redraws, no verdict", s.redraws),
    };
    selflog::line(&format!(
        "summary redraws: {} done, {} set_icon errors; series {}; from 300 to {REDRAWS}: {flat}",
        s.redraws,
        s.icon_errors,
        series.join(" ")
    ));
    let builds: Vec<String> = s
        .rebuild_counts
        .iter()
        .map(|(n, g, u)| format!("{n}:g{g}/u{u}"))
        .collect();
    let menu_flat = match (s.rebuild_counts.get(1), s.rebuild_counts.last()) {
        (Some(&(_, g0, u0)), Some(&(n, g1, u1))) if n > 2 => {
            format!(
                "build 2 to {n}: gdi {g0} -> {g1}, user {u0} -> {u1}: {}",
                if g1 <= g0 + 2 && u1 <= u0 + 2 {
                    "FLAT"
                } else {
                    "GROWS"
                }
            )
        }
        _ => "too few builds for a verdict".to_string(),
    };
    selflog::line(&format!("summary menu: {}; {menu_flat}", builds.join(" ")));
    selflog::line(&format!(
        "summary events: balloons sent {}, clicked {}; hotkey presses {}; redraw timer late {} times",
        s.balloons, s.balloon_clicks, s.presses, s.late_ticks
    ));
}
