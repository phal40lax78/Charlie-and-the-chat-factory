// The panel's tray icon, its menu, its balloons and its two hotkeys (A10),
// as the WPF overlay's NotifyIcon had them (New-ChatOverlayTrayIcon,
// Set-ChatOverlayTrayColor, Update-ChatOverlayMenu,
// Register-ChatOverlayHotkey): all on one hidden window of this thread's
// own, in raw Win32 - Shell_NotifyIcon, TrackPopupMenu, RegisterHotKey.
// Not tray-icon and muda, as the spike's --tray has them: muda draws no
// bold item and no item tooltips, and a balloon's click comes back only to
// the icon's own window. A top-level window, hidden, not a message-only
// one: only top-level windows hear TaskbarCreated, the broadcast an
// Explorer restart sends, after which the icon is added again.
//
// What the window hears goes to a queue, drained by a message posted to
// it, so nothing of app.rs runs inside Shell_NotifyIcon's or the menu's
// own calls. App's state is borrowed per event, never across
// TrackPopupMenu: its modal loop stops Slint's timers, so a timer of the
// window's own ticks the panel meanwhile (Ev::Tick).

use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::io::Cursor;
use std::sync::{Once, OnceLock};

use serde_json::Value;
use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    HOT_KEY_MODIFIERS, MOD_NOREPEAT, RegisterHotKey, UnregisterHotKey,
};
use windows::Win32::UI::Shell::{
    NIF_ICON, NIF_INFO, NIF_MESSAGE, NIF_TIP, NIIF_ERROR, NIIF_INFO, NIIF_NONE, NIIF_WARNING,
    NIM_ADD, NIM_DELETE, NIM_MODIFY, NIN_BALLOONHIDE, NIN_BALLOONTIMEOUT, NIN_BALLOONUSERCLICK,
    NOTIFYICONDATAW, NOTIFYICONDATAW_0, Shell_NotifyIconW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    AppendMenuW, CreateIcon, CreatePopupMenu, CreateWindowExW, DefWindowProcW, DestroyIcon,
    DestroyMenu, DestroyWindow, GetSystemMetrics, HICON, KillTimer, MF_CHECKED, MF_GRAYED,
    MF_SEPARATOR, MF_STRING, PostMessageW, RegisterClassW, RegisterWindowMessageW, SM_CXSMICON,
    SetMenuDefaultItem, SetTimer, TPM_RETURNCMD, TPM_RIGHTBUTTON, TrackPopupMenu, WINDOW_EX_STYLE,
    WM_APP, WM_ENTERMENULOOP, WM_EXITMENULOOP, WM_HOTKEY, WM_LBUTTONUP, WM_MENUSELECT, WM_NULL,
    WM_RBUTTONUP, WM_TIMER, WNDCLASSW, WS_POPUP,
};
use windows::core::{PCWSTR, w};

use crate::{model, tooltip, win32};

/// What the icon's window heard, for app.rs (App::tray).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ev {
    Left,
    Right,
    BalloonClick,
    BalloonGone,
    Hotkey(i32),
    /// a second of the menu's modal loop, which Slint's timers sleep through
    Tick,
    /// Explorer started again: the icon is gone from its tray
    Readd,
}

/// One menu item; an empty name is a separator. The verb is what a pick
/// does, fixed as the menu opens.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Item {
    pub name: &'static str,
    pub text: String,
    pub tip: String,
    pub verb: String,
    pub checked: bool,
    pub grayed: bool,
    pub bold: bool,
}

/// The two hotkeys' ids: the panel's and the console's.
pub const MAIN: i32 = 1;
pub const CONSOLE: i32 = 2;

const WM_TRAY: u32 = WM_APP + 1;
const WM_DRAIN: u32 = WM_APP + 2;
const TICK_TIMER: usize = 1;
const TIP_TIMER: usize = 2;
/// How long the pointer rests on a menu item before its tip shows, as
/// a ToolStrip's own (its ToolTip's initial delay).
const TIP_MS: u32 = 500;
const CLASS: PCWSTR = w!("chatq-overlay-tray");

thread_local! {
    static QUEUE: RefCell<VecDeque<Ev>> = const { RefCell::new(VecDeque::new()) };
    static IN_MENU: Cell<bool> = const { Cell::new(false) };
    static MENU_TIPS: RefCell<Vec<String>> = const { RefCell::new(Vec::new()) };
    static TIP: RefCell<Option<tooltip::Tip>> = const { RefCell::new(None) };
    static TIP_WANT: RefCell<String> = const { RefCell::new(String::new()) };
    static TASKBAR: Cell<u32> = const { Cell::new(0) };
}

/// What the menu is built from: Update-ChatOverlayMenu's state, and the
/// ask (the snapshot's header.ask) while one is out.
pub struct MenuIn<'a> {
    pub ask: Option<&'a Value>,
    pub auto_on: bool,
    pub crash_on: bool,
    pub version: &'a str,
    pub hotkey_text: &'a str,
    pub hotkey_held: bool,
    pub locked: bool,
    /// hidden, hidden for a full screen, or closing by hand: Show
    pub hidden: bool,
    pub collapsed: bool,
}

fn item(name: &'static str, text: &str, tip: &str, verb: &str) -> Item {
    Item {
        name,
        text: text.into(),
        tip: tip.into(),
        verb: verb.into(),
        ..Default::default()
    }
}

fn separator() -> Item {
    Item::default()
}

/// The menu, item for item as New-ChatOverlayTrayIcon adds them and
/// Update-ChatOverlayMenu and Update-ChatOverlayAsk word them. The ask's
/// keys go in its verbs now: a pick answers for the chats the menu showed.
pub fn menu_spec(m: &MenuIn) -> Vec<Item> {
    let mut items = Vec::new();
    if let Some(ask) = m.ask.filter(|a| model::n(a, "count") > 0) {
        let n = model::n(ask, "count");
        let keys: Vec<String> = model::list(ask, "keys")
            .iter()
            .filter_map(|k| k.as_str().map(String::from))
            .collect();
        let keys = keys.join(",");
        let titles: Vec<String> = model::list(ask, "titles")
            .iter()
            .filter_map(|t| t.as_str().map(String::from))
            .collect();
        let s = if n != 1 { "s" } else { "" };
        items.push(item(
            "ask-go",
            &format!("Continue {n} cut-off chat{s}"),
            &titles.join("\n"),
            &format!("ask-go {keys}"),
        ));
        items.push(item(
            "ask-leave",
            "Leave them",
            model::ask_leave_tip(ask),
            &format!("ask-leave {keys}"),
        ));
        items.push(separator());
    }
    items.push(Item {
        bold: true,
        ..item(
            "console",
            "Open console",
            "In the panel's place, grown from its top-right corner - Esc brings the panel back",
            "console",
        )
    });
    items.push(item(
        "phone",
        "Phone alerts...",
        "Join alerts, and answering them from the phone - a window of its own",
        "phone",
    ));
    items.push(Item {
        checked: m.auto_on,
        ..item(
            "auto",
            "Auto-continue cut-off chats",
            "A minute after the limit resets, send \"continue\" to each chat it cut off - unchecked, the panel asks first",
            if m.auto_on { "auto-ask" } else { "auto-on" },
        )
    });
    items.push(Item {
        checked: m.crash_on,
        ..item(
            "crash",
            "Continue chats a VS Code crash cut off",
            "When VS Code runs out of memory or crashes, send each chat it cut off a prompt that says so - unchecked, the panel asks first",
            if m.crash_on { "crash-off" } else { "crash-on" },
        )
    });
    items.push(separator());
    items.push(Item {
        grayed: true,
        ..item(
            "version",
            &format!("Charlie-and-the-chat-factory {}", m.version),
            "",
            "",
        )
    });
    let t = m.hotkey_text;
    let hotkey = if m.hotkey_held {
        format!("hotkey  {t}")
    } else if !t.is_empty() && !model::eq(t, "none") {
        format!("hotkey  {t} (taken)")
    } else {
        "no hotkey".into()
    };
    items.push(Item {
        grayed: true,
        ..item("hotkey", &hotkey, "", "")
    });
    items.push(separator());
    items.push(item(
        "lock",
        if m.locked { "Unlock to move" } else { "Lock" },
        "",
        "toggle",
    ));
    items.push(item(
        "hide",
        if m.hidden { "Show" } else { "Hide" },
        "",
        if m.hidden { "show" } else { "hide" },
    ));
    items.push(item(
        "fold",
        if m.collapsed {
            "Expand"
        } else {
            "Collapse to one line"
        },
        "",
        if m.collapsed { "expand" } else { "collapse" },
    ));
    items.push(item("refresh", "Refresh usage", "", "refresh"));
    items.push(item("reset", "Move to top right", "", "reset"));
    items.push(separator());
    items.push(item("quit", "Quit", "", "close"));
    items
}

/// A UTF-16 copy of `s`, NUL-ended.
fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// `text` into a fixed NUL-ended field, cut to fit.
fn fill(field: &mut [u16], text: &str) {
    let units: Vec<u16> = text.encode_utf16().take(field.len() - 1).collect();
    field[..units.len()].copy_from_slice(&units);
    field[units.len()] = 0;
}

fn push(hwnd: HWND, ev: Ev) {
    QUEUE.with(|q| q.borrow_mut().push_back(ev));
    let _ = unsafe { PostMessageW(Some(hwnd), WM_DRAIN, WPARAM(0), LPARAM(0)) };
}

fn hide_tip() {
    TIP.with(|t| {
        if let Some(t) = t.borrow_mut().as_mut() {
            t.hide();
        }
    });
}

/// The queue, event by event, each to App::tray with its state borrowed
/// for that event alone. While the menu is open, only its ticks: the rest
/// wait for it to close.
fn drain(hwnd: HWND) {
    loop {
        let ev = QUEUE.with(|q| {
            let mut q = q.borrow_mut();
            if IN_MENU.get() {
                let i = q.iter().position(|e| *e == Ev::Tick)?;
                q.remove(i)
            } else {
                q.pop_front()
            }
        });
        let Some(ev) = ev else { break };
        match ev {
            Ev::Right => menu(hwnd),
            // a tick from before the menu closed: Slint's own timer has it
            Ev::Tick if !IN_MENU.get() => {}
            ev => crate::app::with_app(move |a| a.tray(ev)),
        }
    }
}

/// The menu at the pointer, built as it opens (the WPF menu's Opening),
/// and the pick's verb run once it closes.
fn menu(hwnd: HWND) {
    let Some(items) = crate::app::menu_items() else {
        return;
    };
    let Ok(m) = (unsafe { CreatePopupMenu() }) else {
        return;
    };
    for (k, it) in items.iter().enumerate() {
        if it.name.is_empty() {
            let _ = unsafe { AppendMenuW(m, MF_SEPARATOR, 0, PCWSTR::null()) };
            continue;
        }
        let mut flags = MF_STRING;
        if it.checked {
            flags |= MF_CHECKED;
        }
        if it.grayed {
            flags |= MF_GRAYED;
        }
        let text = wide(&it.text);
        let _ = unsafe { AppendMenuW(m, flags, k + 1, PCWSTR(text.as_ptr())) };
        if it.bold {
            let _ = unsafe { SetMenuDefaultItem(m, (k + 1) as u32, 0) };
        }
    }
    MENU_TIPS.with(|t| *t.borrow_mut() = items.iter().map(|i| i.tip.clone()).collect());
    let (x, y) = win32::cursor_now().unwrap_or((0, 0));
    IN_MENU.set(true);
    if std::env::var_os("CHATQ_NOFRONT").is_none() {
        // Windows' rule for a notification icon's menu: its window in front, or the menu never closes on a click elsewhere
        let _ = unsafe { windows::Win32::UI::WindowsAndMessaging::SetForegroundWindow(hwnd) }; // allow-input-hijack - the tray menu's own hidden window, as Windows asks before TrackPopupMenu
    }
    let id =
        unsafe { TrackPopupMenu(m, TPM_RETURNCMD | TPM_RIGHTBUTTON, x, y, None, hwnd, None) }.0;
    // and a message after it, so a second right click opens it again
    let _ = unsafe { PostMessageW(Some(hwnd), WM_NULL, WPARAM(0), LPARAM(0)) };
    IN_MENU.set(false);
    let _ = unsafe { DestroyMenu(m) };
    hide_tip();
    if let Some(it) = usize::try_from(id)
        .ok()
        .filter(|&i| i > 0)
        .and_then(|i| items.get(i - 1))
    {
        let (name, verb) = (it.name, it.verb.clone());
        crate::app::with_app(move |a| a.menu_pick(name, &verb));
    }
}

unsafe extern "system" fn proc(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match msg {
        // no NOTIFYICON_VERSION_4 asked for: lParam is the mouse message,
        // or a balloon's NIN_*
        WM_TRAY => match (lparam.0 as u32) & 0xFFFF {
            WM_LBUTTONUP => push(hwnd, Ev::Left),
            WM_RBUTTONUP => push(hwnd, Ev::Right),
            NIN_BALLOONUSERCLICK => push(hwnd, Ev::BalloonClick),
            NIN_BALLOONTIMEOUT | NIN_BALLOONHIDE => push(hwnd, Ev::BalloonGone),
            _ => {}
        },
        WM_HOTKEY => push(hwnd, Ev::Hotkey(wparam.0 as i32)),
        WM_DRAIN => drain(hwnd),
        WM_ENTERMENULOOP => {
            unsafe { SetTimer(Some(hwnd), TICK_TIMER, 1000, None) };
        }
        WM_EXITMENULOOP => {
            let _ = unsafe { KillTimer(Some(hwnd), TICK_TIMER) };
            let _ = unsafe { KillTimer(Some(hwnd), TIP_TIMER) };
            hide_tip();
        }
        WM_TIMER if wparam.0 == TICK_TIMER => push(hwnd, Ev::Tick),
        WM_TIMER if wparam.0 == TIP_TIMER => {
            let _ = unsafe { KillTimer(Some(hwnd), TIP_TIMER) };
            let text = TIP_WANT.with(|w| w.borrow().clone());
            if let Some((x, y)) = win32::cursor_now() {
                TIP.with(|t| {
                    if let Some(t) = t.borrow_mut().as_mut() {
                        t.show(&text, x, y + 20);
                    }
                });
            }
        }
        WM_MENUSELECT => {
            let (id, flags) = (wparam.0 & 0xFFFF, (wparam.0 >> 16) & 0xFFFF);
            hide_tip();
            let _ = unsafe { KillTimer(Some(hwnd), TIP_TIMER) };
            let closed = flags == 0xFFFF && lparam.0 == 0;
            if !closed && id > 0 {
                let tip = MENU_TIPS.with(|t| t.borrow().get(id - 1).cloned().unwrap_or_default());
                if !tip.is_empty() {
                    TIP_WANT.with(|w| *w.borrow_mut() = tip);
                    unsafe { SetTimer(Some(hwnd), TIP_TIMER, TIP_MS, None) };
                }
            }
        }
        m if m != 0 && m == TASKBAR.get() => push(hwnd, Ev::Readd),
        _ => return unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) },
    }
    LRESULT(0)
}

/// The icon in the tray, and the hotkeys held on its window.
pub struct Tray {
    hwnd: HWND,
    icon: HICON,
    key: String,
    tip: String,
    added: bool,
    told: bool,
    keys: [bool; 2],
}

impl Tray {
    /// Its window; the icon comes with the first set. None if Windows
    /// gives no window.
    pub fn new() -> Option<Tray> {
        static REGISTER: Once = Once::new();
        let instance = unsafe { GetModuleHandleW(None) }.ok()?;
        REGISTER.call_once(|| {
            let class = WNDCLASSW {
                lpfnWndProc: Some(proc),
                hInstance: instance.into(),
                lpszClassName: CLASS,
                ..Default::default()
            };
            unsafe { RegisterClassW(&class) };
        });
        let hwnd = unsafe {
            CreateWindowExW(
                WINDOW_EX_STYLE(0),
                CLASS,
                w!("Charlie tray"),
                WS_POPUP,
                0,
                0,
                0,
                0,
                None,
                None,
                Some(instance.into()),
                None,
            )
        }
        .ok()?;
        TASKBAR.set(unsafe { RegisterWindowMessageW(w!("TaskbarCreated")) });
        TIP.with(|t| *t.borrow_mut() = tooltip::Tip::new(hwnd));
        Some(Tray {
            hwnd,
            icon: HICON::default(),
            key: String::new(),
            tip: "Charlie".into(),
            added: false,
            told: false,
            keys: [false; 2],
        })
    }

    fn nid(&self) -> NOTIFYICONDATAW {
        NOTIFYICONDATAW {
            cbSize: size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: self.hwnd,
            uID: 1,
            ..Default::default()
        }
    }

    fn add(&mut self) {
        let mut nid = self.nid();
        nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
        nid.uCallbackMessage = WM_TRAY;
        nid.hIcon = self.icon;
        fill(&mut nid.szTip, &self.tip);
        self.added = unsafe { Shell_NotifyIconW(NIM_ADD, &nid) }.as_bool();
        if !self.added && !self.told {
            crate::selflog::line("tray: the icon was not added - tried again each second");
        }
        self.told = !self.added;
    }

    /// The icon in `dot` (ARGB) ringed in `ring` (RGB), and its tooltip:
    /// each sent only when it changed; an icon not yet in the tray is
    /// added (again, after a failed add).
    pub fn set(&mut self, dot: u32, ring: u32, tip: &str) {
        let key = format!("{dot:08x}|{ring:06x}");
        let mut old = None;
        let icon_new = key != self.key;
        if icon_new && let Some(icon) = icon(dot, ring) {
            if !self.icon.0.is_null() {
                old = Some(self.icon);
            }
            self.icon = icon;
            self.key = key;
        }
        let tip_new = tip != self.tip;
        if tip_new {
            self.tip = tip.into();
        }
        if !self.added {
            self.add();
        } else if icon_new || tip_new {
            let mut nid = self.nid();
            if icon_new {
                nid.uFlags |= NIF_ICON;
                nid.hIcon = self.icon;
            }
            if tip_new {
                nid.uFlags |= NIF_TIP;
                fill(&mut nid.szTip, &self.tip);
            }
            let _ = unsafe { Shell_NotifyIconW(NIM_MODIFY, &nid) };
        }
        if let Some(old) = old {
            let _ = unsafe { DestroyIcon(old) };
        }
    }

    /// The icon added again, as it was: Explorer started over.
    pub fn readd(&mut self) {
        self.added = false;
        self.add();
    }

    /// A balloon from the icon, as NotifyIcon.ShowBalloonTip sends one:
    /// `icon` None, Info, Warning or Error. False with no icon to show it.
    pub fn balloon(&mut self, title: &str, text: &str, icon: &str, ms: u32) -> bool {
        if !self.added {
            return false;
        }
        let mut nid = self.nid();
        nid.uFlags = NIF_INFO;
        fill(&mut nid.szInfo, text);
        fill(&mut nid.szInfoTitle, title);
        nid.Anonymous = NOTIFYICONDATAW_0 { uTimeout: ms };
        nid.dwInfoFlags = match icon.to_ascii_lowercase().as_str() {
            "info" => NIIF_INFO,
            "warning" => NIIF_WARNING,
            "error" => NIIF_ERROR,
            _ => NIIF_NONE,
        };
        unsafe { Shell_NotifyIconW(NIM_MODIFY, &nid) }.as_bool()
    }

    /// `k` under `id` (MAIN or CONSOLE), held with MOD_NOREPEAT: false when
    /// another program holds those keys.
    pub fn register(&mut self, id: i32, k: &model::Hotkey) -> bool {
        self.unregister(id);
        let ok = unsafe {
            RegisterHotKey(
                Some(self.hwnd),
                id,
                HOT_KEY_MODIFIERS(k.mods | MOD_NOREPEAT.0),
                k.vk,
            )
        }
        .is_ok();
        self.keys[(id - 1) as usize] = ok;
        ok
    }

    pub fn unregister(&mut self, id: i32) {
        let i = (id - 1) as usize;
        if self.keys[i] {
            let _ = unsafe { UnregisterHotKey(Some(self.hwnd), id) };
            self.keys[i] = false;
        }
    }

    pub fn held(&self, id: i32) -> bool {
        self.keys[(id - 1) as usize]
    }
}

impl Drop for Tray {
    fn drop(&mut self) {
        TIP.with(|t| t.borrow_mut().take());
        if self.added {
            let nid = self.nid();
            let _ = unsafe { Shell_NotifyIconW(NIM_DELETE, &nid) };
        }
        if !self.icon.0.is_null() {
            let _ = unsafe { DestroyIcon(self.icon) };
        }
        for id in [MAIN, CONSOLE] {
            self.unregister(id);
        }
        let _ = unsafe { DestroyWindow(self.hwnd) };
    }
}

/// Charlie as the panel's art: src/icon.ps1's PNG (docs/make-icon.py's),
/// straight RGBA, rows top first.
pub struct Art {
    pub w: usize,
    pub h: usize,
    pub rgba: Vec<u8>,
}

/// The art, decoded once; None if icon.ps1 holds none that reads.
pub fn art() -> Option<&'static Art> {
    static ART: OnceLock<Option<Art>> = OnceLock::new();
    ART.get_or_init(|| decode_art(include_str!("../../../src/icon.ps1")))
        .as_ref()
}

fn decode_art(src: &str) -> Option<Art> {
    let body = &src[src.find("$script:ChatIconPng = @'")?..];
    let body = &body[body.find('\n')? + 1..];
    let bytes = base64(&body[..body.find("'@")?])?;
    let mut d = png::Decoder::new(Cursor::new(bytes.as_slice()));
    d.set_transformations(png::Transformations::EXPAND);
    let mut r = d.read_info().ok()?;
    let mut buf = vec![0; r.output_buffer_size()?];
    let info = r.next_frame(&mut buf).ok()?;
    buf.truncate(info.buffer_size());
    if info.bit_depth != png::BitDepth::Eight {
        return None;
    }
    let rgba = match info.color_type {
        png::ColorType::Rgba => buf,
        png::ColorType::Rgb => buf
            .as_chunks::<3>()
            .0
            .iter()
            .flat_map(|c| [c[0], c[1], c[2], 255])
            .collect(),
        _ => return None,
    };
    Some(Art {
        w: info.width as usize,
        h: info.height as usize,
        rgba,
    })
}

/// Base64's text to its bytes; whitespace skipped, None at anything else.
fn base64(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for b in text.bytes() {
        let v = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            b' ' | b'\t' | b'\r' | b'\n' => continue,
            _ => return None,
        };
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Some(out)
}

/// The art at `n` square: each pixel the average of what it covers of
/// the art, premultiplied, 0 to 1. WPF's DrawImage was HighQualityBicubic
/// - near, not the same.
fn scaled(a: &Art, n: usize) -> Vec<[f64; 4]> {
    let (sx, sy) = (a.w as f64 / n as f64, a.h as f64 / n as f64);
    let mut out = vec![[0.0; 4]; n * n];
    for ty in 0..n {
        let (y0, y1) = (ty as f64 * sy, (ty + 1) as f64 * sy);
        for tx in 0..n {
            let (x0, x1) = (tx as f64 * sx, (tx + 1) as f64 * sx);
            let mut acc = [0.0f64; 4];
            for y in (y0.floor() as usize)..(y1.ceil() as usize).min(a.h) {
                let wy = (y1.min(y as f64 + 1.0) - y0.max(y as f64)).max(0.0);
                for x in (x0.floor() as usize)..(x1.ceil() as usize).min(a.w) {
                    let wx = (x1.min(x as f64 + 1.0) - x0.max(x as f64)).max(0.0);
                    let p = &a.rgba[(y * a.w + x) * 4..][..4];
                    let al = f64::from(p[3]) / 255.0;
                    let wt = wx * wy;
                    for c in 0..3 {
                        acc[c] += f64::from(p[c]) / 255.0 * al * wt;
                    }
                    acc[3] += al * wt;
                }
            }
            out[ty * n + tx] = acc.map(|v| v / (sx * sy));
        }
    }
    out
}

/// An ellipse filling the box (x, y, w, h) in `argb`, over what is there
/// (source over, premultiplied), its edge anti-aliased by 4 x 4 samples
/// a pixel - FillEllipse with AntiAlias and HighQuality pixel offsets,
/// pixel i covering i to i + 1.
fn ellipse(px: &mut [[f64; 4]], n: usize, (x, y, w, h): (f64, f64, f64, f64), argb: u32) {
    let (rx, ry) = (w / 2.0, h / 2.0);
    if rx <= 0.0 || ry <= 0.0 {
        return;
    }
    let (cx, cy) = (x + rx, y + ry);
    let a = f64::from(argb >> 24) / 255.0;
    let rgb = [(argb >> 16) & 255, (argb >> 8) & 255, argb & 255].map(|c| f64::from(c) / 255.0);
    for j in 0..n {
        for i in 0..n {
            let mut hit = 0u32;
            for l in 0..4 {
                for k in 0..4 {
                    let dx = (i as f64 + (f64::from(k) + 0.5) / 4.0 - cx) / rx;
                    let dy = (j as f64 + (f64::from(l) + 0.5) / 4.0 - cy) / ry;
                    if dx * dx + dy * dy <= 1.0 {
                        hit += 1;
                    }
                }
            }
            if hit == 0 {
                continue;
            }
            let al = a * f64::from(hit) / 16.0;
            let p = &mut px[j * n + i];
            for c in 0..3 {
                p[c] = rgb[c] * al + p[c] * (1.0 - al);
            }
            p[3] = al + p[3] * (1.0 - al);
        }
    }
}

/// The tray icon's pixels, `n` square, straight BGRA rows top first, as
/// Set-ChatOverlayTrayColor draws them: the art, and at its bottom right a
/// dot half the icon wide in `dot` (ARGB), ringed a sixteenth of it (a
/// pixel at least) in `ring` (RGB) - or, with no art, the dot alone, 22/32
/// wide, unringed. [Math]::Round's halves go to even, as here.
pub fn picture(n: usize, dot: u32, ring: u32, art: Option<&Art>) -> Vec<u8> {
    let mut px = match art {
        Some(a) => scaled(a, n),
        None => vec![[0.0; 4]; n * n],
    };
    let nf = n as f64;
    if art.is_some() {
        let d = (nf * 0.5).round_ties_even();
        let r = (nf / 16.0).round_ties_even().max(1.0);
        ellipse(&mut px, n, (nf - d, nf - d, d, d), 0xFF00_0000 | ring);
        ellipse(
            &mut px,
            n,
            (nf - d + r, nf - d + r, d - 2.0 * r, d - 2.0 * r),
            dot,
        );
    } else {
        let (at, size) = (nf * 5.0 / 32.0, nf * 22.0 / 32.0);
        ellipse(&mut px, n, (at, at, size, size), dot);
    }
    let byte = |v: f64| (v * 255.0).round().clamp(0.0, 255.0) as u8;
    let mut out = Vec::with_capacity(n * n * 4);
    for p in px {
        let a = p[3];
        let un = |c: f64| if a > 0.0 { byte(c / a) } else { 0 };
        out.extend([un(p[2]), un(p[1]), un(p[0]), byte(a)]);
    }
    out
}

/// The icon at the small-icon size Windows shows now (16 to 64), its mask
/// set where the picture is clear.
fn icon(dot: u32, ring: u32) -> Option<HICON> {
    let n = unsafe { GetSystemMetrics(SM_CXSMICON) }.clamp(16, 64) as usize;
    let bgra = picture(n, dot, ring, art());
    // each mask row a whole number of 16-bit words
    let row = n.div_ceil(16) * 2;
    let mut mask = vec![0u8; row * n];
    for y in 0..n {
        for x in 0..n {
            if bgra[(y * n + x) * 4 + 3] == 0 {
                mask[y * row + x / 8] |= 0x80 >> (x % 8);
            }
        }
    }
    unsafe {
        CreateIcon(
            None,
            n as i32,
            n as i32,
            1,
            32,
            mask.as_ptr(),
            bgra.as_ptr(),
        )
    }
    .ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn at(px: &[u8], n: usize, x: usize, y: usize) -> [u8; 4] {
        px[(y * n + x) * 4..][..4].try_into().unwrap()
    }

    #[test]
    fn the_art_is_charlie_48_square() {
        let a = art().expect("icon.ps1's art");
        assert_eq!((a.w, a.h, a.rgba.len()), (48, 48, 48 * 48 * 4));
        assert!(
            a.rgba.chunks(4).any(|p| p[3] == 255),
            "some of her is solid"
        );
    }

    #[test]
    fn the_dot_sits_bottom_right_in_its_ring() {
        // n 32: the dot's box 16 wide at (16, 16), the ring 2; the dot
        // inside it from 18 to 30
        let (dot, ring) = (0xFFF5_B942, 0x6E_0F24);
        let px = picture(32, dot, ring, art());
        assert_eq!(
            at(&px, 32, 24, 24),
            [0x42, 0xB9, 0xF5, 255],
            "the dot's middle"
        );
        assert_eq!(
            at(&px, 32, 17, 24),
            [0x24, 0x0F, 0x6E, 255],
            "the ring left of it"
        );
        assert_eq!(
            at(&px, 32, 24, 17),
            [0x24, 0x0F, 0x6E, 255],
            "the ring above it"
        );
        let a = art().unwrap();
        let top = picture(32, dot, ring, Some(a));
        assert_eq!(
            at(&top, 32, 0, 0)[3],
            (scaled(a, 32)[0][3] * 255.0).round() as u8,
            "her corner as the art has it"
        );
    }

    #[test]
    fn with_no_art_the_dot_alone_and_clear_round_it() {
        let px = picture(16, 0xFF4C_C38A, 0x6E_0F24, None);
        assert_eq!(at(&px, 16, 8, 8), [0x8A, 0xC3, 0x4C, 255]);
        for (x, y) in [(0, 0), (15, 0), (0, 15), (15, 15)] {
            assert_eq!(at(&px, 16, x, y)[3], 0, "corner {x},{y}");
        }
        // no ring colour anywhere
        assert!(
            px.chunks(4)
                .all(|p| p[3] == 0 || (p[0], p[1], p[2]) == (0x8A, 0xC3, 0x4C))
        );
    }

    #[test]
    fn base64_reads_padding_and_whitespace() {
        assert_eq!(base64("TWFu").unwrap(), b"Man");
        assert_eq!(base64("TW E=\r\n").unwrap(), b"Ma");
        assert_eq!(base64("TQ==").unwrap(), b"M");
        assert!(base64("T*").is_none());
    }

    fn menu_in<'a>(ask: Option<&'a Value>) -> MenuIn<'a> {
        MenuIn {
            ask,
            auto_on: false,
            crash_on: true,
            version: "0.10.22",
            hotkey_text: "Ctrl+Alt+Shift+O",
            hotkey_held: true,
            locked: true,
            hidden: false,
            collapsed: false,
        }
    }

    fn names(items: &[Item]) -> Vec<&'static str> {
        items.iter().map(|i| i.name).collect()
    }

    #[test]
    fn the_menu_has_the_wpf_items_in_their_order() {
        let items = menu_spec(&menu_in(None));
        assert_eq!(
            names(&items),
            [
                "console", "phone", "auto", "crash", "", "version", "hotkey", "", "lock", "hide",
                "fold", "refresh", "reset", "", "quit"
            ]
        );
        let by = |n: &str| items.iter().find(|i| i.name == n).unwrap().clone();
        assert!(by("console").bold);
        assert_eq!(
            (by("auto").checked, by("auto").verb.as_str()),
            (false, "auto-on")
        );
        assert_eq!(
            (by("crash").checked, by("crash").verb.as_str()),
            (true, "crash-off")
        );
        assert_eq!(
            (by("version").text.as_str(), by("version").grayed),
            ("Charlie-and-the-chat-factory 0.10.22", true)
        );
        assert_eq!(by("hotkey").text, "hotkey  Ctrl+Alt+Shift+O");
        assert_eq!(
            (by("lock").text.as_str(), by("lock").verb.as_str()),
            ("Unlock to move", "toggle")
        );
        assert_eq!(
            (by("hide").text.as_str(), by("hide").verb.as_str()),
            ("Hide", "hide")
        );
        assert_eq!(
            (by("fold").text.as_str(), by("fold").verb.as_str()),
            ("Collapse to one line", "collapse")
        );
        assert_eq!(by("quit").verb, "close");
    }

    #[test]
    fn the_menu_words_follow_the_state() {
        let mut m = menu_in(None);
        (m.locked, m.hidden, m.collapsed, m.auto_on, m.hotkey_held) =
            (false, true, true, true, false);
        let items = menu_spec(&m);
        let by = |n: &str| items.iter().find(|i| i.name == n).unwrap().clone();
        assert_eq!(by("lock").text, "Lock");
        assert_eq!(
            (by("hide").text.as_str(), by("hide").verb.as_str()),
            ("Show", "show")
        );
        assert_eq!(
            (by("fold").text.as_str(), by("fold").verb.as_str()),
            ("Expand", "expand")
        );
        assert_eq!(
            (by("auto").checked, by("auto").verb.as_str()),
            (true, "auto-ask")
        );
        assert_eq!(by("hotkey").text, "hotkey  Ctrl+Alt+Shift+O (taken)");
        m.hotkey_text = "none";
        assert_eq!(
            menu_spec(&m)
                .iter()
                .find(|i| i.name == "hotkey")
                .unwrap()
                .text,
            "no hotkey"
        );
    }

    #[test]
    fn an_ask_heads_the_menu_with_its_keys_in_the_verbs() {
        let ask = json!({"count": 2, "restart": 0, "keys": ["a1", "b2"], "titles": ["one", "two"]});
        let items = menu_spec(&menu_in(Some(&ask)));
        assert_eq!(names(&items)[..4], ["ask-go", "ask-leave", "", "console"]);
        assert_eq!(items[0].text, "Continue 2 cut-off chats");
        assert_eq!(items[0].tip, "one\ntwo");
        assert_eq!(items[0].verb, "ask-go a1,b2");
        assert_eq!(items[1].verb, "ask-leave a1,b2");
        assert_eq!(items[1].tip, model::ask_leave_tip(&ask));
        let one = json!({"count": 1, "keys": ["a1"], "titles": ["one"]});
        assert_eq!(
            menu_spec(&menu_in(Some(&one)))[0].text,
            "Continue 1 cut-off chat"
        );
        let none = json!({"count": 0});
        assert_eq!(menu_spec(&menu_in(Some(&none)))[0].name, "console");
    }
}
