// The Win32 side of the spike: the overlay's window styles, the style guard,
// the panel's click-through, the magenta backdrop for the alpha check,
// placing, stacking and following for the glued windows, the screen
// changes they hear (scale, display, work area), and screen,
// pointer and button reads. Nothing here moves the pointer, sends input or
// takes the foreground.

use std::cell::{Cell, RefCell};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicU32, Ordering::SeqCst};
use std::sync::{Mutex, Once};
use std::time::Instant;

use slint::winit_030::winit;
use windows::Win32::Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{
    DWMWA_CLOAK, DWMWA_EXTENDED_FRAME_BOUNDS, DwmFlush, DwmGetWindowAttribute,
    DwmIsCompositionEnabled, DwmSetWindowAttribute,
};
use windows::Win32::Graphics::Gdi::{
    BI_RGB, BITMAPINFO, BITMAPINFOHEADER, BitBlt, CAPTUREBLT, CombineRgn, CreateCompatibleBitmap,
    CreateCompatibleDC, CreateRectRgn, CreateSolidBrush, DIB_RGB_COLORS, DeleteDC, DeleteObject,
    EqualRgn, GetDC, GetDIBits, GetMonitorInfoW, GetPixel, GetWindowRgn, HBRUSH,
    MONITOR_DEFAULTTONEAREST, MONITORINFO, MonitorFromWindow, RGN_ERROR, RGN_OR, ROP_CODE,
    ReleaseDC, SRCCOPY, SelectObject, SetWindowRgn,
};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::SystemInformation::GetLocalTime;
use windows::Win32::System::Threading::GetCurrentProcessId;
use windows::Win32::UI::HiDpi::{
    GetDpiForMonitor, GetDpiForSystem, GetDpiForWindow, MDT_EFFECTIVE_DPI,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
use windows::Win32::UI::Shell::{DefSubclassProc, SetWindowSubclass};
use windows::Win32::UI::WindowsAndMessaging::{
    BeginDeferWindowPos, CreateWindowExW, DefWindowProcW, DeferWindowPos, DestroyWindow,
    EndDeferWindowPos, GW_HWNDNEXT, GWL_EXSTYLE, GWL_STYLE, GetClassNameW, GetCursorPos,
    GetForegroundWindow, GetTopWindow, GetWindow, GetWindowLongPtrW, GetWindowRect,
    GetWindowThreadProcessId, HTTRANSPARENT, HWND_TOPMOST, IsWindowVisible, LWA_ALPHA,
    RegisterClassW, SPI_GETWORKAREA, SPI_SETWORKAREA, STYLESTRUCT, SWP_FRAMECHANGED,
    SWP_HIDEWINDOW, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, SWP_SHOWWINDOW,
    SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS, SendMessageW, SetLayeredWindowAttributes,
    SetWindowLongPtrW, SetWindowPos, SystemParametersInfoW, WINDOWPOS, WM_DISPLAYCHANGE,
    WM_DPICHANGED, WM_NCHITTEST, WM_PAINT, WM_SETICON, WM_SETTEXT, WM_SETTINGCHANGE,
    WM_STYLECHANGING, WM_WINDOWPOSCHANGED, WNDCLASSW, WS_EX_APPWINDOW, WS_EX_LAYERED,
    WS_EX_NOACTIVATE, WS_EX_NOREDIRECTIONBITMAP, WS_EX_TOOLWINDOW, WS_EX_TOPMOST,
    WS_EX_TRANSPARENT, WS_POPUP, WS_VISIBLE, WindowFromPoint,
};
use windows::core::{BOOL, w};

/// Never activated by a click, never in the taskbar or Alt+Tab.
const OURS: u32 = WS_EX_NOACTIVATE.0 | WS_EX_TOOLWINDOW.0;

/// The first window made an overlay: the probe, or the mouse mode's panel.
static OUR_HWND: AtomicIsize = AtomicIsize::new(0);
static STYLE_FIXES: AtomicU32 = AtomicU32::new(0);
/// The mouse mode's panel, and how it lets clicks through while locked:
/// WS_EX_TRANSPARENT (kept by the guard through winit's rewrites), or
/// HTTRANSPARENT from WM_NCHITTEST outside the given window-relative rects.
static PANEL: AtomicIsize = AtomicIsize::new(0);
static PASS_ALL: AtomicBool = AtomicBool::new(false);
static PASS_OUTSIDE: Mutex<Option<Vec<RECT>>> = Mutex::new(None);
/// --pretend: the DPI Windows' scale is pretended to be at, 0 for none
/// (pretend_dpi).
static PRETEND: AtomicU32 = AtomicU32::new(0);

type Follow = Box<dyn Fn()>;
type OnScreen = Box<dyn Fn(HWND, Option<(u32, &'static str)>, String)>;

thread_local! {
    /// The glued mode's panel, and what to run each time it has moved or
    /// changed size: the helpers follow it (glue.rs), as they follow the
    /// real panel's LocationChanged and SizeChanged (New-ChatOverlayWindow).
    static FOLLOW: RefCell<Option<(isize, Follow)>> = const { RefCell::new(None) };
    /// Windows cloaked until their next paint (cloak_until_painted).
    static CLOAKED: RefCell<Vec<isize>> = const { RefCell::new(Vec::new()) };
    /// The scale mode's ear for screen changes (on_screen_change).
    static SCREEN: RefCell<Option<OnScreen>> = const { RefCell::new(None) };
    /// Which of our calls that move, size or stack windows is running (doing),
    /// so a WM_DPICHANGED can say what it came inside.
    static DOING: Cell<&'static str> = const { Cell::new("") };
    /// Each window's last WM_WINDOWPOSCHANGED: when, and its SWP_ flags.
    static LAST_POS: RefCell<Vec<(isize, Instant, u32)>> = const { RefCell::new(Vec::new()) };
    /// WM_PAINTs each window has handled, Slint's drawing included (paints).
    static PAINTS: RefCell<Vec<(isize, u32)>> = const { RefCell::new(Vec::new()) };
    /// --pretend: the DPI each window was last sent (tell).
    static TOLD: RefCell<Vec<(isize, u32)>> = const { RefCell::new(Vec::new()) };
}

pub fn hwnd_of(window: &winit::window::Window) -> HWND {
    use winit::raw_window_handle::{HasWindowHandle, RawWindowHandle};
    match window.window_handle().expect("window handle").as_raw() {
        RawWindowHandle::Win32(h) => HWND(h.hwnd.get() as *mut _),
        _ => unreachable!("winit on Windows hands out Win32 handles"),
    }
}

pub fn our_hwnd() -> Option<HWND> {
    let bits = OUR_HWND.load(SeqCst);
    (bits != 0).then_some(HWND(bits as *mut _))
}

/// winit rewrites GWL_EXSTYLE wholesale from its own flags on every flag
/// change, show and hide included (WindowFlags::apply_diff), and its flags
/// have no NOACTIVATE or TOOLWINDOW but do have APPWINDOW. So the guard
/// procedure puts ours back in WM_STYLECHANGING, before the change lands.
/// A comctl32 subclass, so each of several windows keeps its own chain.
/// Called while the window is still hidden.
pub fn make_overlay(hwnd: HWND) {
    unsafe {
        assert!(SetWindowSubclass(hwnd, Some(guard_proc), 1, 0).as_bool());
        let ex = exstyle(hwnd);
        SetWindowLongPtrW(
            hwnd,
            GWL_EXSTYLE,
            ((ex | OURS) & !WS_EX_APPWINDOW.0) as isize,
        );
        SetWindowPos(
            hwnd,
            None,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
        )
        .unwrap();
    }
    let _ = OUR_HWND.compare_exchange(0, hwnd.0 as isize, SeqCst, SeqCst);
}

unsafe extern "system" fn guard_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _id: usize,
    _data: usize,
) -> LRESULT {
    let panel = hwnd.0 as isize == PANEL.load(SeqCst);
    if msg == WM_STYLECHANGING && wparam.0 as i32 == GWL_EXSTYLE.0 {
        let change = unsafe { &mut *(lparam.0 as *mut STYLESTRUCT) };
        let pass = if panel && PASS_ALL.load(SeqCst) {
            WS_EX_TRANSPARENT.0
        } else {
            0
        };
        let wanted = (change.styleNew | OURS | pass) & !WS_EX_APPWINDOW.0;
        if wanted != change.styleNew {
            change.styleNew = wanted;
            STYLE_FIXES.fetch_add(1, SeqCst);
        }
    }
    if msg == WM_SETTEXT || msg == WM_SETICON {
        // Slint sets the title (winit's set_title) on every show and
        // property change, and DefWindowProc paints a classic caption -
        // "chatq-overlay" and a close button - for these two straight into
        // a window with WS_CAPTION whose frame DWM does not draw: one with
        // a region, the bar's. winit keeps WS_CAPTION on an undecorated
        // window and takes the frame off in WM_NCCALCSIZE, so the caption
        // lands on the window's content, and Slint's next frame repaints
        // only what changed: it stayed until a resize repainted the whole
        // bar (M9a's Tier 1). Handled as not visible for the moment, it
        // is painted nowhere (Chromium's ScopedRedrawLock does the same).
        let style = unsafe { GetWindowLongPtrW(hwnd, GWL_STYLE) };
        let shown = style & WS_VISIBLE.0 as isize != 0;
        if shown {
            unsafe { SetWindowLongPtrW(hwnd, GWL_STYLE, style & !(WS_VISIBLE.0 as isize)) };
        }
        let result = unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) };
        if shown {
            unsafe { SetWindowLongPtrW(hwnd, GWL_STYLE, style) };
        }
        return result;
    }
    if msg == WM_NCHITTEST
        && panel
        && let Some(keep) = &*PASS_OUTSIDE.lock().unwrap()
    {
        // lparam holds the point in screen pixels, each half signed
        let (x, y) = (lparam.0 as i16 as i32, (lparam.0 >> 16) as i16 as i32);
        let r = window_rect(hwnd);
        if !keep.iter().any(|k| contains(k, x - r.left, y - r.top)) {
            return LRESULT(HTTRANSPARENT as isize);
        }
    }
    if msg == WM_WINDOWPOSCHANGED {
        let flags = unsafe { (*(lparam.0 as *const WINDOWPOS)).flags.0 };
        LAST_POS.with(|l| {
            let mut l = l.borrow_mut();
            l.retain(|e| e.0 != hwnd.0 as isize);
            l.push((hwnd.0 as isize, Instant::now(), flags));
        });
        // winit first, so the window has its new place before the helpers go to theirs
        let result = unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) };
        if flags & (SWP_NOMOVE.0 | SWP_NOSIZE.0) != SWP_NOMOVE.0 | SWP_NOSIZE.0 {
            tell(hwnd);
        }
        FOLLOW.with(|f| {
            if let Some((panel, follow)) = &*f.borrow()
                && *panel == hwnd.0 as isize
            {
                follow();
            }
        });
        return result;
    }
    if msg == WM_DPICHANGED {
        // Heard before winit, so the helpers stop following the panel
        // before winit moves it; winit then sizes the window to its old
        // logical size at the new scale, from its current size, at the
        // suggested rect's top-left (winit event_loop.rs, WM_DPICHANGED).
        // Slint gets the new scale (ScaleFactorChanged) and then that size
        // (Resized), so its own size stays the window's. No frame is drawn
        // between the two: winit queues both when this comes inside a
        // Slint callback and hands them over back to back, and a WM_PAINT
        // never runs inside this message (runner.rs, send_event and
        // dispatch_buffered_events). Left alone: a
        // hold that kept winit's resize to a size set before Slint knew the
        // scale had Slint draw past the window, and panic (glue.rs, replace).
        // Logged with what it came inside and the window's last move, as
        // the evidence for when Windows sends it.
        let suggested = unsafe { *(lparam.0 as *const RECT) };
        let dpi = (wparam.0 & 0xffff) as u32;
        let key = hwnd.0 as isize;
        let inside = match DOING.get() {
            "" => "no call of ours",
            doing => doing,
        };
        screen_change(hwnd, Some((dpi, inside)), || {
            let last = LAST_POS.with(|l| {
                l.borrow()
                    .iter()
                    .find(|e| e.0 == key)
                    .map(|e| (e.1.elapsed().as_millis(), e.2))
            });
            let last = last.map_or("none".to_string(), |(ms, flags)| {
                format!("{ms} ms before, {}", swp_text(flags))
            });
            format!(
                "WM_DPICHANGED to {dpi} dpi: suggested {}, was {}; inside {inside}; its last WM_WINDOWPOSCHANGED {last}; monitor {} dpi, GetDpiForWindow {}",
                rect_text(suggested),
                rect_text(window_rect(hwnd)),
                monitor_dpi(hwnd),
                self::dpi(hwnd)
            )
        });
        let result = unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) };
        screen_change(hwnd, None, || {
            format!(
                "WM_DPICHANGED handled by winit: now {}",
                rect_text(window_rect(hwnd))
            )
        });
        return result;
    }
    if msg == WM_DISPLAYCHANGE {
        let (w, h) = (lparam.0 & 0xffff, (lparam.0 >> 16) & 0xffff);
        screen_change(hwnd, None, || {
            format!(
                "WM_DISPLAYCHANGE: {w}x{h}, {} bits per pixel; monitor {} dpi",
                wparam.0,
                monitor_dpi(hwnd)
            )
        });
    }
    if msg == WM_SETTINGCHANGE && wparam.0 as u32 == SPI_SETWORKAREA.0 {
        screen_change(hwnd, None, || {
            format!(
                "WM_SETTINGCHANGE SPI_SETWORKAREA: work area now {}",
                rect_text(work_area())
            )
        });
    }
    if msg == WM_PAINT {
        // winit sends RedrawRequested from inside WM_PAINT and Slint draws
        // there, so once it returns the window holds its new content
        // (unless winit was buffering events; then it paints a WM_PAINT later)
        let result = unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) };
        PAINTS.with(|p| {
            let mut p = p.borrow_mut();
            match p.iter_mut().find(|e| e.0 == hwnd.0 as isize) {
                Some(e) => e.1 += 1,
                None => p.push((hwnd.0 as isize, 1)),
            }
        });
        let waiting = CLOAKED.with(|c| {
            let mut c = c.borrow_mut();
            let before = c.len();
            c.retain(|&h| h != hwnd.0 as isize);
            c.len() != before
        });
        if waiting {
            set_cloak(hwnd, false);
        }
        return result;
    }
    unsafe { DefSubclassProc(hwnd, msg, wparam, lparam) }
}

/// How many WM_PAINTs the window has handled, each one Slint drawing it
/// (winit's RedrawRequested): a count still rising, and no PANIC in the
/// log (a panic there ends the process), says Slint still draws it.
pub fn paints(hwnd: HWND) -> u32 {
    PAINTS.with(|p| {
        p.borrow()
            .iter()
            .find(|e| e.0 == hwnd.0 as isize)
            .map_or(0, |e| e.1)
    })
}

/// Keeps DWM from showing the window until its next paint: cloaked now,
/// uncloaked by the guard after the next WM_PAINT. Called just before a
/// show, it is meant to keep a re-shown window's last picture off screen.
pub fn cloak_until_painted(hwnd: HWND) {
    set_cloak(hwnd, true);
    CLOAKED.with(|c| c.borrow_mut().push(hwnd.0 as isize));
}

/// Cloaked: DWM composes the window off the screen - drawn, never seen
/// (CHATQ_CLOAK, app.rs).
pub fn set_cloak(hwnd: HWND, on: bool) {
    let value = BOOL::from(on);
    unsafe {
        DwmSetWindowAttribute(
            hwnd,
            DWMWA_CLOAK,
            &value as *const BOOL as *const _,
            size_of::<BOOL>() as u32,
        )
        .unwrap()
    };
}

/// Runs `follow` each time `panel` has moved or changed size (or changed
/// place in the z-order), however that came about.
pub fn on_moved(panel: HWND, follow: impl Fn() + 'static) {
    FOLLOW.with(|f| *f.borrow_mut() = Some((panel.0 as isize, Box::new(follow))));
}

/// Runs `heard` with the window and a line about it on each WM_DPICHANGED
/// (before winit handles it and after), WM_DISPLAYCHANGE and work-area
/// WM_SETTINGCHANGE any of our subclassed windows gets; before winit
/// handles a WM_DPICHANGED, also with its DPI and the call of ours it came
/// inside. It runs inside the window message: it should only note the change.
pub fn on_screen_change(heard: impl Fn(HWND, Option<(u32, &'static str)>, String) + 'static) {
    SCREEN.with(|s| *s.borrow_mut() = Some(Box::new(heard)));
}

fn screen_change(hwnd: HWND, dpi: Option<(u32, &'static str)>, text: impl FnOnce() -> String) {
    SCREEN.with(|s| {
        if let Some(heard) = &*s.borrow() {
            heard(hwnd, dpi, text());
        }
    });
}

/// Runs `f` labelled as `what`, for the log of a WM_DPICHANGED it brings.
fn doing<R>(what: &'static str, f: impl FnOnce() -> R) -> R {
    let outer = DOING.replace(what);
    let result = f();
    DOING.set(outer);
    result
}

/// What a WM_WINDOWPOSCHANGED did by its flags (moved, sized, shown,
/// hidden), and the flags themselves.
fn swp_text(flags: u32) -> String {
    let did: Vec<&str> = [
        (SWP_NOMOVE.0, "moved", false),
        (SWP_NOSIZE.0, "sized", false),
        (SWP_SHOWWINDOW.0, "shown", true),
        (SWP_HIDEWINDOW.0, "hidden", true),
    ]
    .into_iter()
    .filter(|&(bit, _, set)| (flags & bit != 0) == set)
    .map(|(_, name, _)| name)
    .collect();
    format!(
        "{} (flags {flags:#06x})",
        if did.is_empty() {
            "none of moved, sized, shown, hidden".to_string()
        } else {
            did.join(" ")
        }
    )
}

/// winit's click-through (set_cursor_hittest(false)) makes the window
/// layered but never calls SetLayeredWindowAttributes, and a layered window
/// is not drawn until something does: the card, made click-through before
/// its first show, never appeared. Full opacity; the alpha check in glue.rs
/// says whether the per-pixel alpha survives.
pub fn layered_opaque(hwnd: HWND) {
    unsafe { SetLayeredWindowAttributes(hwnd, COLORREF(0), 255, LWA_ALPHA).unwrap() };
}

pub fn contains(r: &RECT, x: i32, y: i32) -> bool {
    x >= r.left && x < r.right && y >= r.top && y < r.bottom
}

/// Locked or not, by WS_EX_TRANSPARENT on the whole panel. The guard adds it
/// back whenever winit rewrites the extended styles while locked.
pub fn set_click_through(panel: HWND, on: bool) {
    PANEL.store(panel.0 as isize, SeqCst);
    PASS_ALL.store(on, SeqCst);
    let ex = exstyle(panel);
    let ex = if on {
        ex | WS_EX_TRANSPARENT.0
    } else {
        ex & !WS_EX_TRANSPARENT.0
    };
    unsafe { SetWindowLongPtrW(panel, GWL_EXSTYLE, ex as isize) };
}

/// Locked or not, by WM_NCHITTEST: HTTRANSPARENT everywhere but `keep`
/// (window-relative physical rects). None answers as usual again.
pub fn set_pass_outside(panel: HWND, keep: Option<Vec<RECT>>) {
    PANEL.store(panel.0 as isize, SeqCst);
    *PASS_OUTSIDE.lock().unwrap() = keep;
}

/// The window's region: only `keep` (window-relative) is the window, for
/// clicks and for drawing alike. None gives the whole window back.
pub fn set_region(hwnd: HWND, keep: Option<&[RECT]>) {
    unsafe {
        let region = keep.map(|rects| {
            let all = CreateRectRgn(0, 0, 0, 0);
            for r in rects {
                let one = CreateRectRgn(r.left, r.top, r.right, r.bottom);
                CombineRgn(Some(all), Some(all), Some(one), RGN_OR);
                let _ = DeleteObject(one.into());
            }
            all
        });
        // the system owns the region from here on
        SetWindowRgn(hwnd, region, true);
    }
}

/// Whether the window's region is exactly the union of `rects`
/// (window-relative): read back from the system, not from what was set.
pub fn region_is(hwnd: HWND, rects: &[RECT]) -> bool {
    unsafe {
        let got = CreateRectRgn(0, 0, 0, 0);
        let kind = GetWindowRgn(hwnd, got);
        let want = CreateRectRgn(0, 0, 0, 0);
        for r in rects {
            let one = CreateRectRgn(r.left, r.top, r.right, r.bottom);
            CombineRgn(Some(want), Some(want), Some(one), RGN_OR);
            let _ = DeleteObject(one.into());
        }
        let same = kind != RGN_ERROR && EqualRgn(got, want).as_bool();
        for r in [got, want] {
            let _ = DeleteObject(r.into());
        }
        same
    }
}

/// The window a click at (x, y) would go to, found without any input.
pub fn window_from_point(x: i32, y: i32) -> HWND {
    unsafe { WindowFromPoint(POINT { x, y }) }
}

pub fn class_name(hwnd: HWND) -> String {
    let mut buf = [0u16; 128];
    let len = unsafe { GetClassNameW(hwnd, &mut buf) } as usize;
    String::from_utf16_lossy(&buf[..len])
}

/// Where the pointer is, in screen pixels. Read only.
pub fn cursor() -> (i32, i32) {
    cursor_now().expect("GetCursorPos")
}

/// The same, or None while the input desktop is another one: the PC locked,
/// a secure screen saver, a UAC prompt or Ctrl+Alt+Del (access denied).
pub fn cursor_now() -> Option<(i32, i32)> {
    let mut p = POINT::default();
    unsafe { GetCursorPos(&mut p) }.ok().map(|_| (p.x, p.y))
}

/// The left button: held now, and pressed since the last read (the low
/// bit, which Windows says not to rely on; it only helps catch a click
/// shorter than the 120 ms poll).
pub fn left_button() -> (bool, bool) {
    let state = unsafe { GetAsyncKeyState(VK_LBUTTON.0 as i32) } as u16;
    (state & 0x8000 != 0, state & 1 != 0)
}

/// Any mouse button held now (Control.MouseButtons not None). Read only.
pub fn any_button() -> bool {
    use windows::Win32::UI::Input::KeyboardAndMouse::{VK_MBUTTON, VK_RBUTTON};
    [VK_LBUTTON, VK_RBUTTON, VK_MBUTTON]
        .iter()
        .any(|k| unsafe { GetAsyncKeyState(i32::from(k.0)) } as u16 & 0x8000 != 0)
}

unsafe extern "system" fn each_screen(
    m: windows::Win32::Graphics::Gdi::HMONITOR,
    _: windows::Win32::Graphics::Gdi::HDC,
    _: *mut RECT,
    l: LPARAM,
) -> BOOL {
    let out = unsafe { &mut *(l.0 as *mut Vec<(crate::model::Rect, bool)>) };
    let mut info = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    if unsafe { GetMonitorInfoW(m, &mut info) }.as_bool() {
        let r = info.rcWork;
        let primary =
            info.dwFlags & windows::Win32::UI::WindowsAndMessaging::MONITORINFOF_PRIMARY != 0;
        out.push((
            crate::model::Rect::new(r.left, r.top, r.right - r.left, r.bottom - r.top),
            primary,
        ));
    }
    BOOL::from(true)
}

/// Every screen's work area, and whether it is the main one: what
/// Set-ChatOverlayPlacement reads from Screen.AllScreens.
pub fn screens() -> Vec<(crate::model::Rect, bool)> {
    let mut out: Vec<(crate::model::Rect, bool)> = Vec::new();
    let _ = unsafe {
        windows::Win32::Graphics::Gdi::EnumDisplayMonitors(
            None,
            None,
            Some(each_screen),
            LPARAM(&mut out as *mut Vec<(crate::model::Rect, bool)> as isize),
        )
    };
    out
}

/// A full-screen program in front - a game, a presentation, a video
/// (SHQueryUserNotificationState, Update-ChatOverlayFullScreen).
pub fn full_screen() -> bool {
    full_screen_of(unsafe { windows::Win32::UI::Shell::SHQueryUserNotificationState() })
}

/// The query's answer read: busy, a D3D full screen or presentation mode
/// is a full screen (model::full_screen_state), and a query that failed is
/// none. The drive's full screen comes through here too (App::full_screen).
pub fn full_screen_of(
    answer: windows::core::Result<windows::Win32::UI::Shell::QUERY_USER_NOTIFICATION_STATE>,
) -> bool {
    answer.is_ok_and(|s| crate::model::full_screen_state(s.0))
}

/// Windows' app mode dark: AppsUseLightTheme 0 (Test-ChatOverlaySystemDark);
/// missing is light. Read only.
pub fn system_dark() -> bool {
    use windows::Win32::System::Registry::{HKEY_CURRENT_USER, RRF_RT_REG_DWORD, RegGetValueW};
    let (mut v, mut size) = (1u32, size_of::<u32>() as u32);
    let r = unsafe {
        RegGetValueW(
            HKEY_CURRENT_USER,
            w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
            w!("AppsUseLightTheme"),
            RRF_RT_REG_DWORD,
            None,
            Some(&mut v as *mut u32 as *mut _),
            Some(&mut size),
        )
    };
    r == windows::Win32::Foundation::ERROR_SUCCESS && v == 0
}

/// Moves our own window; never activates it, never changes the z-order.
pub fn move_window(hwnd: HWND, x: i32, y: i32) {
    doing("our SetWindowPos move", || unsafe {
        SetWindowPos(
            hwnd,
            None,
            x,
            y,
            0,
            0,
            SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
        )
        .unwrap()
    });
}

/// The primary monitor's scale, for placing a window before it exists.
pub fn system_scale() -> f32 {
    unsafe { GetDpiForSystem() as f32 / 96.0 }
}

pub fn screen_pixel(x: i32, y: i32) -> u32 {
    unsafe {
        let dc = GetDC(None);
        let got = GetPixel(dc, x, y).0;
        ReleaseDC(None, dc);
        got
    }
}

/// How many times the guard had to undo a winit style rewrite.
pub fn style_fixes() -> u32 {
    STYLE_FIXES.load(SeqCst)
}

pub fn exstyle(hwnd: HWND) -> u32 {
    unsafe { GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32 }
}

pub fn is_visible(hwnd: HWND) -> bool {
    unsafe { IsWindowVisible(hwnd).as_bool() }
}

/// NOACTIVATE, TOOLWINDOW and TOPMOST set, APPWINDOW clear.
pub fn styles_ok(ex: u32) -> bool {
    let want = OURS | WS_EX_TOPMOST.0;
    ex & want == want && ex & WS_EX_APPWINDOW.0 == 0
}

pub fn foreground() -> HWND {
    unsafe { GetForegroundWindow() }
}

pub fn is_ours(hwnd: HWND) -> bool {
    let mut pid = 0;
    unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
    !hwnd.is_invalid() && pid == unsafe { GetCurrentProcessId() }
}

pub fn reassert_topmost(hwnd: HWND) {
    unsafe {
        SetWindowPos(
            hwnd,
            Some(HWND_TOPMOST),
            0,
            0,
            0,
            0,
            SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE,
        )
        .unwrap()
    };
}

pub fn work_area() -> RECT {
    let mut r = RECT::default();
    unsafe {
        SystemParametersInfoW(
            SPI_GETWORKAREA,
            0,
            Some(&mut r as *mut RECT as *mut _),
            SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
        )
        .unwrap()
    };
    r
}

pub fn window_rect(hwnd: HWND) -> RECT {
    let mut r = RECT::default();
    unsafe { GetWindowRect(hwnd, &mut r).unwrap() };
    r
}

/// The work area and the whole of the monitor the window is on (or
/// nearest to), from GetMonitorInfo: what the real overlay reads through
/// Screen.FromRectangle(..).WorkingArea (Get-ChatOverlayWorkArea).
pub fn monitor_of(hwnd: HWND) -> (RECT, RECT) {
    let mut info = MONITORINFO {
        cbSize: size_of::<MONITORINFO>() as u32,
        ..Default::default()
    };
    unsafe {
        assert!(
            GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mut info).as_bool()
        )
    };
    (info.rcWork, info.rcMonitor)
}

/// The window's own DPI: after a scale change, the old one until Windows
/// sends the window its WM_DPICHANGED. Under --pretend, the DPI it was
/// last sent, if any.
pub fn dpi(hwnd: HWND) -> u32 {
    told(hwnd).unwrap_or_else(|| unsafe { GetDpiForWindow(hwnd) })
}

/// The DPI of the monitor the window is on (or nearest to), as Windows'
/// scale setting has it now, whatever the window has been told; under
/// --pretend, the pretended one.
pub fn monitor_dpi(hwnd: HWND) -> u32 {
    match PRETEND.load(SeqCst) {
        0 => real_monitor_dpi(hwnd),
        dpi => dpi,
    }
}

/// The monitor's DPI as Windows' scale setting really has it.
pub fn real_monitor_dpi(hwnd: HWND) -> u32 {
    let (mut x, mut y) = (0, 0);
    unsafe {
        GetDpiForMonitor(
            MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
            MDT_EFFECTIVE_DPI,
            &mut x,
            &mut y,
        )
        .unwrap()
    };
    x
}

/// The test of a scale change with nothing really changed (--pretend):
/// from now monitor_dpi says `dpi`. The windows in `now` are sent
/// WM_DPICHANGED to it at once, each other of ours the next time it is
/// moved or sized, as the real change of 2026-10-20 reached them (one by
/// a z-order call, the rest inside our re-place batch); dpi() then says
/// what it was sent. Only winit and Slint hear of a new scale: Windows'
/// own, the monitor's real DPI and GetDpiForWindow stay as they are.
/// Sent by SendMessage to our own windows only.
pub fn pretend_dpi(dpi: u32, now: &[HWND]) {
    PRETEND.store(dpi, SeqCst);
    for &hwnd in now {
        tell(hwnd);
    }
}

/// --pretend: the window sent WM_DPICHANGED to the pretended DPI, unless
/// it was already.
fn tell(hwnd: HWND) {
    let dpi = PRETEND.load(SeqCst);
    if dpi == 0 || told(hwnd) == Some(dpi) {
        return;
    }
    let key = hwnd.0 as isize;
    // noted first: winit's resize from the message moves the window again
    TOLD.with(|t| {
        let mut t = t.borrow_mut();
        t.retain(|e| e.0 != key);
        t.push((key, dpi));
    });
    send_dpi(hwnd, dpi);
}

fn told(hwnd: HWND) -> Option<u32> {
    TOLD.with(|t| {
        t.borrow()
            .iter()
            .find(|e| e.0 == hwnd.0 as isize)
            .map(|e| e.1)
    })
}

/// Where and how big; never activates, never changes the z-order.
pub fn set_rect(hwnd: HWND, r: RECT) {
    doing("our SetWindowPos", || unsafe {
        SetWindowPos(
            hwnd,
            None,
            r.left,
            r.top,
            r.right - r.left,
            r.bottom - r.top,
            SWP_NOZORDER | SWP_NOACTIVATE,
        )
        .unwrap()
    });
}

/// Several windows moved in one DeferWindowPos batch, so they land
/// together; none activated, the z-order kept.
pub fn move_together(moves: &[(HWND, i32, i32)]) {
    doing("our DeferWindowPos move batch", || unsafe {
        let mut batch = BeginDeferWindowPos(moves.len() as i32).unwrap();
        for &(hwnd, x, y) in moves {
            batch = DeferWindowPos(
                batch,
                hwnd,
                None,
                x,
                y,
                0,
                0,
                SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
            )
            .unwrap();
        }
        EndDeferWindowPos(batch).unwrap();
    });
}

/// The poke test (--poke): a WM_DPICHANGED sent by us to one of our own
/// windows, its suggested rect the window's own rect, as the real ones
/// carried. Only winit and Slint hear of a new scale; Windows' scale, the
/// monitor's DPI and GetDpiForWindow stay as they are.
pub fn poke_dpi(hwnd: HWND, dpi: u32) {
    doing("our test poke", || send_dpi(hwnd, dpi));
}

/// WM_DPICHANGED to `dpi`, the window's own rect suggested.
fn send_dpi(hwnd: HWND, dpi: u32) {
    let r = window_rect(hwnd);
    let wparam = WPARAM((dpi | dpi << 16) as usize);
    unsafe {
        SendMessageW(
            hwnd,
            WM_DPICHANGED,
            Some(wparam),
            Some(LPARAM(&r as *const RECT as isize)),
        )
    };
}

/// The windows topmost and in this order, top first: the first to the top
/// of the topmost band, each next one inserted right after the one before.
/// Never activates, never moves or sizes.
pub fn stack_topmost(top_first: &[HWND]) {
    doing("our z-order re-stack, no move or size", || {
        let mut after = HWND_TOPMOST;
        for &hwnd in top_first {
            unsafe {
                SetWindowPos(
                    hwnd,
                    Some(after),
                    0,
                    0,
                    0,
                    0,
                    SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOSIZE,
                )
                .unwrap()
            };
            after = hwnd;
        }
    });
}

/// Every top-level window on the desktop, the top of the z-order first.
pub fn z_order() -> Vec<HWND> {
    let mut all = Vec::new();
    let mut next = unsafe { GetTopWindow(None) }.ok();
    while let Some(hwnd) = next {
        all.push(hwnd);
        next = unsafe { GetWindow(hwnd, GW_HWNDNEXT) }.ok();
    }
    all
}

pub fn is_topmost(hwnd: HWND) -> bool {
    exstyle(hwnd) & WS_EX_TOPMOST.0 != 0
}

/// Returns once DWM has composed its next frame.
pub fn dwm_flush() {
    let _ = unsafe { DwmFlush() };
}

/// The screen inside `r` as DWM last composed it, row by row from the
/// top, each pixel a COLORREF (0x00BBGGRR) as GetPixel gives it.
/// CAPTUREBLT so layered windows (the card) are included. Not isolated:
/// it went in while the card read as what was behind it, which turned out
/// to be the card never drawn (layered_opaque), not the capture.
pub fn capture(r: RECT) -> Vec<u32> {
    let (w, h) = (r.right - r.left, r.bottom - r.top);
    let mut info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            biHeight: -h, // top-down
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut pixels = vec![0u32; (w * h) as usize];
    unsafe {
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let bitmap = CreateCompatibleBitmap(screen, w, h);
        let old = SelectObject(mem, bitmap.into());
        BitBlt(
            mem,
            0,
            0,
            w,
            h,
            Some(screen),
            r.left,
            r.top,
            ROP_CODE(SRCCOPY.0 | CAPTUREBLT.0),
        )
        .unwrap();
        SelectObject(mem, old);
        GetDIBits(
            mem,
            bitmap,
            0,
            h as u32,
            Some(pixels.as_mut_ptr() as *mut _),
            &mut info,
            DIB_RGB_COLORS,
        );
        let _ = DeleteObject(bitmap.into());
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
    }
    // read as 0x00RRGGBB (B, G, R, 0 in memory): red and blue swap places
    pixels
        .iter()
        .map(|p| ((p & 0xff) << 16) | (p & 0xff00) | ((p >> 16) & 0xff))
        .collect()
}

/// What says whether winit's with_transparent reached the window: the
/// styles a per-pixel path would need, DWM composition, and whether DWM
/// sees a frame bigger than the window (a border or a shadow).
pub fn dwm_evidence(hwnd: HWND) -> String {
    let ex = exstyle(hwnd);
    let mut frame = RECT::default();
    let frame_ok = unsafe {
        DwmGetWindowAttribute(
            hwnd,
            DWMWA_EXTENDED_FRAME_BOUNDS,
            &mut frame as *mut RECT as *mut _,
            size_of::<RECT>() as u32,
        )
    };
    let rect = window_rect(hwnd);
    format!(
        "dwm: composition={:?} layered={} noredirectionbitmap={} window={:?} dwm_frame={:?} ({frame_ok:?})",
        unsafe { DwmIsCompositionEnabled() }.map(|b| b.as_bool()),
        ex & WS_EX_LAYERED.0 != 0,
        ex & WS_EX_NOREDIRECTIONBITMAP.0 != 0,
        (rect.left, rect.top, rect.right, rect.bottom),
        (frame.left, frame.top, frame.right, frame.bottom),
    )
}

pub const MAGENTA: u32 = 0x00FF_00FF; // COLORREF is 0x00BBGGRR
pub const FILL: u32 = 0x0024_1F1E; // #1e1f24, the probe's body and the panel's

unsafe extern "system" fn plain_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    unsafe { DefWindowProcW(hwnd, msg, wparam, lparam) }
}

/// A plain solid magenta window, never activated, placed right under `above`
/// in the z-order and over the same rectangle.
pub fn magenta_behind(above: HWND, r: RECT) -> HWND {
    magenta(above, r)
}

/// The same magenta window at the top of the topmost band: another topmost
/// window, for the z-order check (glue.rs).
pub fn magenta_topmost(r: RECT) -> HWND {
    magenta(HWND_TOPMOST, r)
}

fn magenta(after: HWND, r: RECT) -> HWND {
    static REGISTER: Once = Once::new();
    let instance = unsafe { GetModuleHandleW(None).unwrap() };
    REGISTER.call_once(|| {
        let class = WNDCLASSW {
            lpfnWndProc: Some(plain_proc),
            hInstance: instance.into(),
            hbrBackground: HBRUSH(unsafe { CreateSolidBrush(COLORREF(MAGENTA)) }.0),
            lpszClassName: w!("OverlaySpikeMagenta"),
            ..Default::default()
        };
        assert!(unsafe { RegisterClassW(&class) } != 0);
    });
    unsafe {
        let hwnd = CreateWindowExW(
            WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            w!("OverlaySpikeMagenta"),
            w!(""),
            WS_POPUP,
            r.left,
            r.top,
            r.right - r.left,
            r.bottom - r.top,
            None,
            None,
            Some(instance.into()),
            None,
        )
        .unwrap();
        SetWindowPos(
            hwnd,
            Some(after),
            r.left,
            r.top,
            r.right - r.left,
            r.bottom - r.top,
            SWP_NOACTIVATE | SWP_SHOWWINDOW,
        )
        .unwrap();
        hwnd
    }
}

pub fn destroy(hwnd: HWND) {
    unsafe { DestroyWindow(hwnd).unwrap() };
}

/// Reads the screen where the probe must be see-through (magenta expected,
/// the window behind it) and where it is filled (the fill expected). The
/// offsets are the .slint's logical pixels, scaled by the window's DPI to
/// the physical pixels GetWindowRect and GetPixel use.
pub fn sample_alpha(hwnd: HWND, r: RECT) -> String {
    let dpi = unsafe { GetDpiForWindow(hwnd) } as i32;
    let points = [
        ("corner", 5, 5, MAGENTA),
        ("left-edge", 0, 100, MAGENTA),
        ("beside-tail", 100, 205, MAGENTA),
        ("fill", 12, 40, FILL),
    ];
    let mut report = String::new();
    let mut all = true;
    let dc = unsafe { GetDC(None) };
    for (name, x, y, want) in points {
        let got = unsafe { GetPixel(dc, r.left + x * dpi / 96, r.top + y * dpi / 96) }.0;
        let hit = close(got, want);
        all &= hit;
        report += &format!(
            "{name}({x},{y})={got:06x}{} ",
            if hit { "=expected" } else { "!" }
        );
    }
    unsafe { ReleaseDC(None, dc) };
    format!(
        "per_pixel_alpha={} dpi={dpi} {report}(magenta=ff00ff fill=241f1e, as 00bbggrr)",
        if all { "works" } else { "FAILS" }
    )
}

pub fn close(a: u32, b: u32) -> bool {
    (0..3).all(|i| ((a >> (8 * i)) & 0xff).abs_diff((b >> (8 * i)) & 0xff) <= 6)
}

/// Saves the screen inside `r` as a 32-bit BMP, so the probe can be looked
/// at afterwards (glyphs, corners) without anyone watching the run.
pub fn save_screen_bmp(r: RECT, path: &Path) {
    let (w, h) = (r.right - r.left, r.bottom - r.top);
    let mut info = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            biHeight: h, // bottom-up, as a BMP file stores it
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let mut pixels = vec![0u8; (w * h * 4) as usize];
    unsafe {
        let screen = GetDC(None);
        let mem = CreateCompatibleDC(Some(screen));
        let bitmap = CreateCompatibleBitmap(screen, w, h);
        let old = SelectObject(mem, bitmap.into());
        BitBlt(mem, 0, 0, w, h, Some(screen), r.left, r.top, SRCCOPY).unwrap();
        SelectObject(mem, old);
        GetDIBits(
            mem,
            bitmap,
            0,
            h as u32,
            Some(pixels.as_mut_ptr() as *mut _),
            &mut info,
            DIB_RGB_COLORS,
        );
        let _ = DeleteObject(bitmap.into());
        let _ = DeleteDC(mem);
        ReleaseDC(None, screen);
    }
    write_bmp(path, w, h, &pixels);
}

/// Pixels from `capture` (rows from the top, COLORREFs) of the screen
/// inside `r`, saved as a 32-bit BMP.
pub fn save_capture_bmp(r: RECT, pixels: &[u32], path: &Path) {
    let w = r.right - r.left;
    // rows from the bottom, as a BMP stores them, each pixel's bytes B, G, R, 0
    let bytes: Vec<u8> = pixels
        .chunks(w as usize)
        .rev()
        .flatten()
        .flat_map(|&p| [(p >> 16) as u8, (p >> 8) as u8, p as u8, 0])
        .collect();
    write_bmp(path, w, r.bottom - r.top, &bytes);
}

/// A 32-bit BMP of `w` x `h` from its pixel bytes, rows from the bottom.
fn write_bmp(path: &Path, w: i32, h: i32, pixels: &[u8]) {
    let header_len = 14 + size_of::<BITMAPINFOHEADER>() as u32;
    let mut file = Vec::with_capacity(header_len as usize + pixels.len());
    file.extend_from_slice(b"BM");
    file.extend_from_slice(&(header_len + pixels.len() as u32).to_le_bytes());
    file.extend_from_slice(&0u32.to_le_bytes());
    file.extend_from_slice(&header_len.to_le_bytes());
    for v in [size_of::<BITMAPINFOHEADER>() as i32, w, h] {
        file.extend_from_slice(&v.to_le_bytes());
    }
    file.extend_from_slice(&1u16.to_le_bytes());
    file.extend_from_slice(&32u16.to_le_bytes());
    file.extend_from_slice(&[0u8; 24]); // BI_RGB, then sizes and palette counts all zero
    file.extend_from_slice(pixels);
    std::fs::write(path, file).unwrap();
}

pub fn rect_text(r: RECT) -> String {
    format!(
        "{},{} {}x{}",
        r.left,
        r.top,
        r.right - r.left,
        r.bottom - r.top
    )
}

pub fn local_hms() -> String {
    let t = unsafe { GetLocalTime() };
    format!("{:02}:{:02}:{:02}", t.wHour, t.wMinute, t.wSecond)
}

#[cfg(test)]
mod tests {
    use windows::Win32::Foundation::E_FAIL;
    use windows::Win32::UI::Shell::{
        QUNS_ACCEPTS_NOTIFICATIONS, QUNS_APP, QUNS_BUSY, QUNS_NOT_PRESENT, QUNS_PRESENTATION_MODE,
        QUNS_QUIET_TIME, QUNS_RUNNING_D3D_FULL_SCREEN,
    };

    /// B12's query, each answer Windows gives as the windows crate names
    /// it: busy, a D3D full screen and presentation mode are a full screen;
    /// no one there, accepting notifications, quiet time, a Store app, and
    /// a failed query are not.
    #[test]
    fn each_answer_of_the_full_screen_query() {
        for (state, full) in [
            (QUNS_NOT_PRESENT, false),
            (QUNS_BUSY, true),
            (QUNS_RUNNING_D3D_FULL_SCREEN, true),
            (QUNS_PRESENTATION_MODE, true),
            (QUNS_ACCEPTS_NOTIFICATIONS, false),
            (QUNS_QUIET_TIME, false),
            (QUNS_APP, false),
        ] {
            assert_eq!(super::full_screen_of(Ok(state)), full, "state {}", state.0);
        }
        assert!(!super::full_screen_of(Err(E_FAIL.into())), "a failed query");
    }

    /// The real query answers on this desktop - whichever way, as nothing
    /// here makes a full screen - and never panics.
    #[test]
    fn the_real_query_answers() {
        let _ = super::full_screen();
    }
}
