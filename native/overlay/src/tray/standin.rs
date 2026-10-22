// --tray --standin: the step-4 hand checks done without a hand. What Explorer
// and the keyboard would deliver is posted to the spike's own windows, and
// what changed is read back. Seconds from the start:
//
//   14, 16    tray-icon's callback message with lParam WM_LBUTTONUP, as
//             Explorer posts a left click (no NOTIFYICON_VERSION_4: wParam
//             the uID, lParam the mouse message): the status window hides,
//             then shows
//   41        WM_COMMAND with the command id of "Auto-continue ..." read from
//             the menu itself (GetMenuItemInfo), as TrackPopupMenu posts a
//             click on an item; then "Unlock to move"; each read back from
//             the same menu. 51.5: the menu built at 50, as a reopen shows it
//   45, 47    WM_HOTKEY to global-hotkey's window with the registered id,
//             once, then 10 times 100 ms apart. Posted, so Windows' own
//             MOD_NOREPEAT never comes into it: only the handler path is shown
//   balloons  the screen's bottom right captured just before each balloon
//             and 1 s after it shows; 1.5 s after a click balloon shows, the
//             callback message with NIN_BALLOONUSERCLICK; in the close's
//             4 s, captures at 0.5, 2 and 3.5 s. Saved to data/ as BMPs
//
// Every post goes only to a window first checked to be this process's. The
// menu is never opened (tray-icon's right click calls SetForegroundWindow and
// TrackPopupMenu); nothing moves the pointer, sends input or takes the
// foreground.

use std::cell::RefCell;

use windows::Win32::Foundation::{HWND, LPARAM, RECT, WPARAM};
use windows::Win32::System::Threading::GetCurrentProcessId;
use windows::Win32::UI::Input::KeyboardAndMouse::{MOD_ALT, MOD_CONTROL, MOD_SHIFT, VK_F12};
use windows::Win32::UI::Shell::NIN_BALLOONUSERCLICK;
use windows::Win32::UI::WindowsAndMessaging::{
    FindWindowExW, GetMenuItemCount, GetMenuItemInfoW, GetWindowThreadProcessId, HMENU,
    MENUITEMINFOW, MFS_CHECKED, MIIM_ID, MIIM_STATE, MIIM_STRING, PostMessageW, WM_COMMAND,
    WM_HOTKEY, WM_LBUTTONUP,
};
use windows::core::{PCWSTR, PWSTR, w};

use super::{State, TRAY_CALLBACK, with};
use crate::{later, selflog, win32};

const AUTO: &str = "Auto-continue cut-off chats (spike)";
/// The work area's bottom right captured for a toast, in logical pixels.
const CAPTURE_W: f32 = 480.0;
const CAPTURE_H: f32 = 360.0;

thread_local! {
    /// The capture taken just before the last balloon: its number, region, pixels.
    static BEFORE: RefCell<Option<(u32, RECT, Vec<u32>)>> = const { RefCell::new(None) };
}

pub(super) fn start(seconds: u64) {
    if seconds < 60 {
        selflog::line("standin: needs --seconds 60 or more; nothing posted");
        return;
    }
    selflog::line(&format!(
        "standin: the spike is pid {}; every post goes only to a window of this pid",
        own_pid()
    ));
    later(14_000, || click_icon(1));
    later(16_000, || click_icon(2));
    later(41_000, menu_auto);
    later(51_500, reopened);
    if let Some(hwnd) = hotkey_window() {
        later(45_000, move || press(hwnd, "once".to_string()));
        later(46_000, || check_presses(1));
        for i in 0..10 {
            later(47_000 + i * 100, move || {
                press(hwnd, format!("burst {}/10", i + 1))
            });
        }
        later(49_000, || check_presses(11));
    }
}

fn own_pid() -> u32 {
    unsafe { GetCurrentProcessId() }
}

fn pid_of(hwnd: HWND) -> u32 {
    let mut pid = 0;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    pid
}

fn verdict(pass: bool) -> &'static str {
    if pass { "PASS" } else { "FAIL" }
}

/// PostMessage, only once the window is found to be this process's.
fn post(hwnd: HWND, msg: u32, wparam: usize, lparam: isize, what: &str) {
    let (pid, own) = (pid_of(hwnd), own_pid());
    if pid != own {
        selflog::line(&format!(
            "standin: NOT posted {what}: window {:?} is pid {pid}, not the spike's {own}",
            hwnd.0
        ));
        return;
    }
    let result = unsafe { PostMessageW(Some(hwnd), msg, WPARAM(wparam), LPARAM(lparam)) };
    selflog::line(&format!(
        "standin: posted {what} to {:?} ({}, pid {pid} = the spike's): {result:?}",
        hwnd.0,
        win32::class_name(hwnd)
    ));
}

/// A left click as Explorer reports it; read back 500 ms later.
fn click_icon(n: u32) {
    let (hwnd, uid, before) = with(|s| (s.tray_hwnd, s.uid.unwrap_or(0), s.shown));
    let foreground = win32::foreground();
    post(
        hwnd,
        TRAY_CALLBACK,
        uid as usize,
        WM_LBUTTONUP as isize,
        &format!("left click {n} (callback message, lParam WM_LBUTTONUP)"),
    );
    later(500, move || {
        let shown = with(|s| s.shown);
        let visible = win32::our_hwnd().is_some_and(win32::is_visible);
        let now = win32::foreground();
        let pass = shown != before && visible == shown && !win32::is_ours(now);
        selflog::line(&format!(
            "standin check left click {n}: {}; status window shown {before} -> {shown}, IsWindowVisible {visible}; foreground {:?} -> {:?} (ours: {})",
            verdict(pass),
            foreground.0,
            now.0,
            win32::is_ours(now)
        ));
    });
}

struct Item {
    id: u32,
    text: String,
    checked: bool,
}

/// The popup menu's items as Windows holds them: command id, text, check.
fn menu_items(hmenu: isize) -> Vec<Item> {
    let hmenu = HMENU(hmenu as *mut _);
    let count = unsafe { GetMenuItemCount(Some(hmenu)) }.max(0) as u32;
    (0..count)
        .filter_map(|i| {
            let mut text = [0u16; 128];
            let mut info = MENUITEMINFOW {
                cbSize: size_of::<MENUITEMINFOW>() as u32,
                fMask: MIIM_ID | MIIM_STRING | MIIM_STATE,
                dwTypeData: PWSTR(text.as_mut_ptr()),
                cch: text.len() as u32,
                ..Default::default()
            };
            unsafe { GetMenuItemInfoW(hmenu, i, true, &mut info) }.ok()?;
            let text = String::from_utf16_lossy(&text[..info.cch as usize]);
            Some(Item {
                id: info.wID,
                text,
                checked: info.fState.0 & MFS_CHECKED.0 != 0,
            })
        })
        .collect()
}

fn menu_text(items: &[Item]) -> String {
    let each: Vec<String> = items
        .iter()
        .map(|i| {
            format!(
                "{} \"{}\"{}",
                i.id,
                i.text,
                if i.checked { " checked" } else { "" }
            )
        })
        .collect();
    each.join("; ")
}

/// WM_COMMAND for the auto-continue item; read back from the same menu,
/// then the lock item's.
fn menu_auto() {
    let (hwnd, hmenu) = with(|s| (s.tray_hwnd, s.menu_handle));
    let items = menu_items(hmenu);
    selflog::line(&format!(
        "standin: menu {hmenu:#x} by GetMenuItemInfo: {}",
        menu_text(&items)
    ));
    let Some(auto) = items.iter().find(|i| i.text == AUTO) else {
        selflog::line("standin check auto-continue: FAIL; no such item in the menu");
        return;
    };
    let (id, was) = (auto.id, auto.checked);
    post(
        hwnd,
        WM_COMMAND,
        id as usize,
        0,
        &format!("WM_COMMAND id {id} (\"{AUTO}\")"),
    );
    later(500, move || {
        let (menu_now, auto_on) = with(|s| (s.menu_handle, s.auto_on));
        let checked = menu_items(hmenu)
            .into_iter()
            .find(|i| i.id == id)
            .map(|i| i.checked);
        let pass = menu_now == hmenu && checked == Some(!was) && auto_on == !was;
        selflog::line(&format!(
            "standin check auto-continue: {}; menu check {was} -> {checked:?} (GetMenuItemInfo), the spike's auto_on {auto_on}; same menu {}",
            verdict(pass),
            menu_now == hmenu
        ));
        menu_lock(hwnd, hmenu);
    });
}

fn menu_lock(hwnd: HWND, hmenu: isize) {
    let Some(lock) = menu_items(hmenu)
        .into_iter()
        .find(|i| i.text.starts_with("Unlock to move"))
    else {
        selflog::line("standin check lock: FAIL; no \"Unlock to move\" item in the menu");
        return;
    };
    let id = lock.id;
    post(
        hwnd,
        WM_COMMAND,
        id as usize,
        0,
        &format!("WM_COMMAND id {id} (\"{}\")", lock.text),
    );
    later(500, move || {
        let (menu_now, locked) = with(|s| (s.menu_handle, s.locked));
        let text = menu_items(hmenu)
            .into_iter()
            .find(|i| i.id == id)
            .map(|i| i.text);
        let pass =
            menu_now == hmenu && !locked && text.as_deref().is_some_and(|t| t.starts_with("Lock "));
        selflog::line(&format!(
            "standin check lock: {}; item text now {text:?} (GetMenuItemInfo), the spike's locked {locked}; same menu {}",
            verdict(pass),
            menu_now == hmenu
        ));
    });
}

/// The menu a reopen would show, built since the commands: the check and
/// the "Lock" text carried over.
fn reopened() {
    let (hmenu, build) = with(|s| (s.menu_handle, s.rebuilds));
    let items = menu_items(hmenu);
    let auto = items.iter().find(|i| i.text == AUTO).map(|i| i.checked);
    let lock = items.iter().any(|i| i.text.starts_with("Lock "));
    selflog::line(&format!(
        "standin check reopened menu (build {build}, {hmenu:#x}): {}; auto-continue checked {auto:?}, a \"Lock\" item {lock}; items {}",
        verdict(auto == Some(true) && lock),
        menu_text(&items)
    ));
}

/// global-hotkey's window of this process. Any other process's window of
/// that class is logged and left alone.
fn hotkey_window() -> Option<HWND> {
    let own = own_pid();
    let mut after = None;
    while let Ok(hwnd) =
        unsafe { FindWindowExW(None, after, w!("global_hotkey_app"), PCWSTR::null()) }
    {
        let pid = pid_of(hwnd);
        selflog::line(&format!(
            "standin: global_hotkey_app window {:?} is pid {pid}{}",
            hwnd.0,
            if pid == own {
                ", the spike's"
            } else {
                ", not ours: never a target"
            }
        ));
        if pid == own {
            return Some(hwnd);
        }
        after = Some(hwnd);
    }
    selflog::line("standin: no global_hotkey_app window of this pid; no hotkey posted");
    None
}

/// WM_HOTKEY as Windows builds it: wParam the id, lParam the modifiers in
/// the low word and the key in the high one (global-hotkey's release thread
/// reads that key's real state, which is up).
fn press(hwnd: HWND, what: String) {
    let Some(id) = with(|s| s.hotkey.as_ref().map(|(_, key)| key.id())) else {
        selflog::line("standin: the hotkey is not registered; none posted");
        return;
    };
    let lparam = ((VK_F12.0 as isize) << 16) | (MOD_CONTROL | MOD_ALT | MOD_SHIFT).0 as isize;
    post(
        hwnd,
        WM_HOTKEY,
        id as usize,
        lparam,
        &format!("WM_HOTKEY id {id} ({what})"),
    );
}

fn check_presses(want: u32) {
    let (presses, phase) = with(|s| (s.presses, s.status.get_phase()));
    selflog::line(&format!(
        "standin check hotkey: {}; presses {presses} (want {want}), status phase \"{phase}\"",
        verdict(presses == want)
    ));
}

/// The bottom right of the work area, where Windows puts its toasts.
fn region() -> RECT {
    let work = win32::work_area();
    let scale = win32::system_scale();
    RECT {
        left: work.right - (CAPTURE_W * scale) as i32,
        top: work.bottom - (CAPTURE_H * scale) as i32,
        right: work.right,
        bottom: work.bottom,
    }
}

fn save(n: u32, label: &str, region: RECT, pixels: &[u32]) {
    win32::save_capture_bmp(
        region,
        pixels,
        &selflog::data_dir().join(format!("standin-balloon{n}-{label}.bmp")),
    );
}

/// Balloon `n` is about to be sent: the picture to compare against.
pub(super) fn before_balloon(n: u32) {
    let region = region();
    let pixels = win32::capture(region);
    save(n, "0-before", region, &pixels);
    BEFORE.with(|b| *b.borrow_mut() = Some((n, region, pixels)));
}

/// A balloon showed (NIN_BALLOONSHOW): a capture, then its click. Not for
/// the close balloon (watch_close), and once a click has been counted none.
pub(super) fn balloon_shown(s: &State) {
    if s.closing || s.balloon_clicks > 0 {
        return;
    }
    let (hwnd, uid) = (s.tray_hwnd, s.uid.unwrap_or(0));
    later(1000, || compare("1-shown-1s"));
    later(1500, move || {
        let before = with(|s| s.balloon_clicks);
        post(
            hwnd,
            TRAY_CALLBACK,
            uid as usize,
            NIN_BALLOONUSERCLICK as isize,
            "balloon click (callback message, lParam NIN_BALLOONUSERCLICK)",
        );
        later(500, move || {
            let clicks = with(|s| s.balloon_clicks);
            selflog::line(&format!(
                "standin check balloon click: {}; clicks counted {before} -> {clicks}",
                verdict(clicks == before + 1)
            ));
        });
    });
}

/// The close balloon was sent: captures through its 4 s.
pub(super) fn watch_close() {
    for (ms, label) in [
        (500, "1-close-0.5s"),
        (2000, "2-close-2s"),
        (3500, "3-close-3.5s"),
    ] {
        later(ms, move || compare(label));
    }
}

/// The region now against the capture before the balloon. The status
/// window's own changes (its text) are counted apart: a toast shows as a
/// block of change outside it.
fn compare(label: &'static str) {
    let Some((n, region, before)) = BEFORE.with(|b| b.borrow().clone()) else {
        return;
    };
    let after = win32::capture(region);
    save(n, label, region, &after);
    let status = win32::our_hwnd()
        .filter(|&h| win32::is_visible(h))
        .map(win32::window_rect);
    let width = region.right - region.left;
    let (mut changed, mut outside) = (0u32, 0u32);
    let mut sum = [0u64; 3];
    let mut bounds: Option<RECT> = None;
    for (i, (a, b)) in before.iter().zip(&after).enumerate() {
        if win32::close(*a, *b) {
            continue;
        }
        changed += 1;
        let (x, y) = (
            region.left + i as i32 % width,
            region.top + i as i32 / width,
        );
        if status.is_some_and(|r| win32::contains(&r, x, y)) {
            continue;
        }
        outside += 1;
        // a COLORREF, 0x00BBGGRR: red in the low byte
        for (k, total) in sum.iter_mut().enumerate() {
            *total += ((b >> (8 * k)) & 0xff) as u64;
        }
        let r = bounds.get_or_insert(RECT {
            left: x,
            top: y,
            right: x + 1,
            bottom: y + 1,
        });
        (r.left, r.top, r.right, r.bottom) = (
            r.left.min(x),
            r.top.min(y),
            r.right.max(x + 1),
            r.bottom.max(y + 1),
        );
    }
    // a toast is about 360x100 logical or more; 150x40 of change is called toast-sized
    let scale = win32::system_scale();
    let toast = bounds.is_some_and(|r| {
        (r.right - r.left) as f32 >= 150.0 * scale && (r.bottom - r.top) as f32 >= 40.0 * scale
    });
    let mean = sum.map(|t| t / outside.max(1) as u64);
    selflog::line(&format!(
        "standin capture balloon {n} {label}: region {}; {changed} pixels changed, {outside} outside the status window ({}); changed block outside it {}, mean colour #{:02x}{:02x}{:02x}; {}",
        win32::rect_text(region),
        status.map_or("hidden".to_string(), win32::rect_text),
        bounds.map_or("none".to_string(), win32::rect_text),
        mean[0],
        mean[1],
        mean[2],
        if toast {
            "a toast-sized change"
        } else {
            "no toast-sized change"
        }
    ));
}
