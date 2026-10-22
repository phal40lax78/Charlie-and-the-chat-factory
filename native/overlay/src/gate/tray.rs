// The gate's tray (step 4's pieces, all at once with the windows): the dot
// redrawn from the snapshot's state every 2 s, a tooltip from the
// snapshot's counts cut to 127 UTF-16 units (Format-ChatOverlayTooltip),
// a menu rebuilt every 30 s with the Recent titles in a submenu, the
// spare-chord hotkey (Ctrl+Alt+Shift+F12, never the live overlay's), one
// start balloon and the close balloon with its 4 s delayed exit.
//
// Every crate event is handed to Slint's loop with invoke_from_event_loop,
// as in tray.rs; muda's ids are the spike's own strings, matched each time,
// never cached handles. The icon, menu and subclass are made on Slint's UI
// thread.

use std::cell::RefCell;
use std::time::Instant;

use global_hotkey::{GlobalHotKeyEvent, GlobalHotKeyManager, HotKeyState, hotkey::HotKey};
use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};
use tray_icon::{MouseButton, MouseButtonState, TrayIcon, TrayIconBuilder, TrayIconEvent};
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::UI::Shell::{
    DefSubclassProc, NIF_INFO, NIIF_INFO, NIIF_NOSOUND, NIM_MODIFY, NIN_BALLOONSHOW,
    NIN_BALLOONUSERCLICK, NOTIFYICONDATAW, SetWindowSubclass, Shell_NotifyIconW,
};
use windows::Win32::UI::WindowsAndMessaging::{IsWindow, WM_ENTERMENULOOP, WM_EXITMENULOOP};

use crate::selflog;
use crate::tray::{CHORD, TRAY_CALLBACK, dot_icon, fill, icon_rect, register_hotkey};

/// A run's balloons: the start one and the close one.
const MAX_BALLOONS: u32 = 2;

pub struct Tray {
    icon: Option<TrayIcon>,
    hwnd: HWND,
    uid: Option<u32>,
    hotkey: Option<(GlobalHotKeyManager, HotKey)>,
    hotkey_text: String,
    pub redraws: u32,
    pub icon_errors: u32,
    pub rebuilds: u32,
    /// (rebuild, gdi, user) after each rebuild
    rebuild_counts: Vec<(u32, u32, u32)>,
    pub tips: u32,
    tip: String,
    pub balloons: u32,
    pub balloon_clicks: u32,
    pub presses: u32,
    pub menu_open: bool,
    pub menu_opens: u32,
    opened_at: Option<Instant>,
    /// the menu's state the gate keeps (Lock, the two checks)
    pub auto_on: bool,
    pub crash_on: bool,
}

type Act = Box<dyn Fn(&str)>;

thread_local! {
    static TRAY: RefCell<Option<Tray>> = const { RefCell::new(None) };
    /// What a menu choice does in the gate: "lock", "quit".
    static ACT: RefCell<Option<Act>> = const { RefCell::new(None) };
}

pub fn with<R>(f: impl FnOnce(&mut Tray) -> R) -> Option<R> {
    TRAY.with(|t| t.borrow_mut().as_mut().map(f))
}

enum Heard {
    Tray(TrayIconEvent),
    Menu(MenuEvent),
    Hotkey(GlobalHotKeyEvent),
    Balloon(u32),
    MenuLoop(bool),
}

fn hand_over(heard: Heard) {
    let _ = slint::invoke_from_event_loop(move || on_heard(heard));
}

/// The icon, its menu and tooltip, the hotkey and the balloon subclass.
pub fn setup(tip: &str, rgb: u32, locked: bool, recent: &[String], act: impl Fn(&str) + 'static) {
    ACT.with(|a| *a.borrow_mut() = Some(Box::new(act)));
    TrayIconEvent::set_event_handler(Some(|e: TrayIconEvent| {
        if !matches!(e, TrayIconEvent::Move { .. }) {
            hand_over(Heard::Tray(e));
        }
    }));
    MenuEvent::set_event_handler(Some(|e| hand_over(Heard::Menu(e))));
    GlobalHotKeyEvent::set_event_handler(Some(|e| hand_over(Heard::Hotkey(e))));
    let (hotkey, hotkey_text) = register_hotkey();
    let mut t = Tray {
        icon: None,
        hwnd: HWND::default(),
        uid: None,
        hotkey,
        hotkey_text,
        redraws: 0,
        icon_errors: 0,
        rebuilds: 0,
        rebuild_counts: Vec::new(),
        tips: 0,
        tip: String::new(),
        balloons: 0,
        balloon_clicks: 0,
        presses: 0,
        menu_open: false,
        menu_opens: 0,
        opened_at: None,
        auto_on: false,
        crash_on: true,
    };
    let tip = cut_tip(tip);
    let menu = build_menu(&t, locked, recent);
    let icon = TrayIconBuilder::new()
        .with_icon(dot_icon(rgb))
        .with_tooltip(&tip)
        .with_menu(Box::new(menu))
        .with_menu_on_left_click(false)
        .build()
        .expect("tray icon");
    t.tip = tip;
    t.tips = 1;
    t.rebuilds = 1;
    t.hwnd = HWND(icon.window_handle() as *mut _);
    t.uid = Some(icon.window_uid());
    unsafe { assert!(SetWindowSubclass(t.hwnd, Some(gate_tray_proc), 5, 0).as_bool()) };
    t.icon = Some(icon);
    let (_, gdi, user) = selflog::counts();
    t.rebuild_counts.push((1, gdi, user));
    selflog::line(&format!(
        "gate tray: icon on tray-icon's window {:?}, uID {:?}; hotkey {}",
        t.hwnd.0, t.uid, t.hotkey_text
    ));
    TRAY.with(|s| *s.borrow_mut() = Some(t));
}

/// The real overlay's cut: past 127 UTF-16 units, 126 and an ellipsis,
/// never splitting a surrogate pair.
pub fn cut_tip(text: &str) -> String {
    if text.encode_utf16().count() <= 127 {
        return text.to_string();
    }
    let mut out = String::new();
    let mut units = 0;
    for c in text.chars() {
        if units + c.len_utf16() > 126 {
            break;
        }
        units += c.len_utf16();
        out.push(c);
    }
    out.push('…');
    out
}

fn build_menu(t: &Tray, locked: bool, recent: &[String]) -> Menu {
    let menu = Menu::new();
    let head = MenuItem::with_id(
        "g-head",
        format!("M9 spike gate - menu build {}", t.rebuilds + 1),
        false,
        None,
    );
    let auto = CheckMenuItem::with_id(
        "g-auto",
        "Auto-continue cut-off chats (spike)",
        true,
        t.auto_on,
        None,
    );
    let crash = CheckMenuItem::with_id(
        "g-crash",
        "Continue chats a crash cut off (spike)",
        true,
        t.crash_on,
        None,
    );
    let sub = Submenu::with_id("g-recent", format!("Recent ({})", recent.len()), true);
    for (n, title) in recent.iter().enumerate() {
        let short: String = title.chars().take(60).collect();
        sub.append(&MenuItem::with_id(
            format!("g-recent-{n}"),
            short,
            true,
            None,
        ))
        .unwrap();
    }
    let hotkey = MenuItem::with_id(
        "g-hotkey",
        format!("hotkey  {}", t.hotkey_text),
        false,
        None,
    );
    let lock = MenuItem::with_id(
        "g-lock",
        format!(
            "{}   {}",
            if locked { "Unlock to move" } else { "Lock" },
            crate::win32::local_hms()
        ),
        true,
        None,
    );
    let quit = MenuItem::with_id("g-quit", "Quit (close balloon, then 4 s)", true, None);
    let sep = || PredefinedMenuItem::separator();
    for item in [
        &head as &dyn tray_icon::menu::IsMenuItem,
        &sep(),
        &auto,
        &crash,
        &sub,
        &sep(),
        &hotkey,
        &lock,
        &quit,
    ] {
        menu.append(item).unwrap();
    }
    menu
}

/// A whole new menu, unless it is open.
pub fn rebuild(locked: bool, recent: &[String]) {
    with(|t| {
        if t.icon.is_none() {
            return;
        }
        if t.menu_open {
            selflog::line("gate tray: menu rebuild skipped, the menu is open");
            return;
        }
        let menu = build_menu(t, locked, recent);
        t.icon.as_ref().unwrap().set_menu(Some(Box::new(menu)));
        t.rebuilds += 1;
        let (_, gdi, user) = selflog::counts();
        t.rebuild_counts.push((t.rebuilds, gdi, user));
    });
}

/// The dot in `rgb`, a new icon each time.
pub fn redraw(rgb: u32) {
    with(|t| {
        let Some(icon) = &t.icon else { return };
        if let Err(e) = icon.set_icon(Some(dot_icon(rgb))) {
            t.icon_errors += 1;
            selflog::line(&format!("gate tray: set_icon failed: {e}"));
        }
        t.redraws += 1;
    });
}

pub fn set_tip(text: &str) {
    let tip = cut_tip(text);
    with(|t| {
        if tip == t.tip {
            return;
        }
        let Some(icon) = &t.icon else { return };
        let result = icon.set_tooltip(Some(&tip));
        t.tips += 1;
        selflog::line(&format!(
            "gate tray: tooltip {} UTF-16 units ({} chars); {result:?}",
            tip.encode_utf16().count(),
            tip.chars().count()
        ));
        t.tip = tip;
    });
}

/// A NIF_INFO balloon on tray-icon's own icon (tray.rs, way 1).
pub fn balloon(title: &str, text: &str) {
    with(|t| {
        let Some(uid) = t.uid else {
            selflog::line("gate tray: no uID found, no balloon");
            return;
        };
        if t.balloons >= MAX_BALLOONS {
            selflog::line("gate tray: balloon not shown, the run's two are used");
            return;
        }
        t.balloons += 1;
        let mut nid = NOTIFYICONDATAW {
            cbSize: size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: t.hwnd,
            uID: uid,
            uFlags: NIF_INFO,
            dwInfoFlags: NIIF_INFO | NIIF_NOSOUND,
            ..Default::default()
        };
        fill(&mut nid.szInfoTitle, title);
        fill(&mut nid.szInfo, text);
        let ok = unsafe { Shell_NotifyIconW(NIM_MODIFY, &nid) }.as_bool();
        selflog::line(&format!(
            "gate tray: balloon {} \"{title}\" sent: {ok}",
            t.balloons
        ));
    });
}

/// The icon removed (NIM_DELETE in tray-icon's Drop), Explorer asked
/// before and after whether it still holds it.
pub fn remove_icon() {
    with(|t| {
        let Some(icon) = t.icon.take() else { return };
        let uid = t.uid.unwrap_or(0);
        selflog::line(&format!(
            "gate close: 4 s up; Explorer has the icon: {:?}",
            icon_rect(t.hwnd, uid)
        ));
        drop(icon);
        selflog::line(&format!(
            "gate close: icon dropped; Explorer has the icon: {:?} (None = no ghost); tray-icon's window still exists: {}",
            icon_rect(t.hwnd, uid),
            unsafe { IsWindow(Some(t.hwnd)) }.as_bool()
        ));
    });
}

/// After the loop: the hotkey unregistered, the counts logged.
pub fn finish() {
    let Some(t) = TRAY.with(|s| s.borrow_mut().take()) else {
        return;
    };
    if let Some((manager, key)) = &t.hotkey {
        selflog::line(&format!(
            "gate tray: hotkey unregistered: {:?}",
            manager.unregister(*key)
        ));
    }
    let builds: Vec<String> = t
        .rebuild_counts
        .iter()
        .map(|(n, g, u)| format!("{n}:g{g}/u{u}"))
        .collect();
    // every 10th build, so the line stays short over an hour
    let some: Vec<&String> = builds
        .iter()
        .enumerate()
        .filter(|(i, _)| i % 10 == 0 || *i + 1 == builds.len())
        .map(|(_, b)| b)
        .collect();
    selflog::line(&format!(
        "gate summary tray: redraws {} ({} errors); tooltips set {}; menu builds {} [{}]; menu opened {}; balloons {} (clicked {}); hotkey presses {} ({CHORD})",
        t.redraws,
        t.icon_errors,
        t.tips,
        t.rebuilds,
        some.iter()
            .map(|s| s.as_str())
            .collect::<Vec<_>>()
            .join(" "),
        t.menu_opens,
        t.balloons,
        t.balloon_clicks,
        t.presses
    ));
}

unsafe extern "system" fn gate_tray_proc(
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
        hand_over(Heard::MenuLoop(msg == WM_ENTERMENULOOP));
    }
    unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) }
}

fn act(what: &str) {
    ACT.with(|a| {
        if let Some(f) = &*a.borrow() {
            f(what)
        }
    });
}

fn on_heard(heard: Heard) {
    let text = match heard {
        Heard::Tray(TrayIconEvent::Click {
            button: MouseButton::Left,
            button_state: MouseButtonState::Up,
            ..
        }) => "tray left click".to_string(),
        Heard::Tray(e) => format!("tray {e:?}").chars().take(80).collect(),
        Heard::Menu(e) => {
            let id = e.id.0.clone();
            let mut what = format!("menu {id}");
            match id.as_str() {
                "g-lock" => act("lock"),
                "g-quit" => act("quit"),
                "g-auto" => {
                    with(|t| t.auto_on = !t.auto_on);
                }
                "g-crash" => {
                    with(|t| t.crash_on = !t.crash_on);
                }
                other if other.starts_with("g-recent-") => {
                    what = format!("menu recent item {}", &other[9..])
                }
                _ => {}
            }
            what
        }
        Heard::Hotkey(e) => match e.state() {
            HotKeyState::Pressed => {
                let n = with(|t| {
                    t.presses += 1;
                    t.presses
                });
                format!("hotkey {CHORD} pressed (press {})", n.unwrap_or(0))
            }
            HotKeyState::Released => format!("hotkey {CHORD} released"),
        },
        Heard::Balloon(code) => {
            if code == NIN_BALLOONUSERCLICK {
                with(|t| t.balloon_clicks += 1);
                super::sample::touched("balloon click");
            }
            format!("balloon NIN code {code:#x}")
        }
        Heard::MenuLoop(open) => with(|t| {
            t.menu_open = open;
            if open {
                t.menu_opens += 1;
                super::sample::touched("menu open");
                t.opened_at = Some(Instant::now());
                "menu opened".to_string()
            } else {
                format!(
                    "menu closed after {} ms",
                    t.opened_at.take().map_or(0, |at| at.elapsed().as_millis())
                )
            }
        })
        .unwrap_or_default(),
    };
    selflog::line(&format!("gate event: {text}"));
}
