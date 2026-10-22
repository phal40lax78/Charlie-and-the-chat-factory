// The panel's tooltips: one of the system's own (tooltips_class32), a
// tracking one shown where and when app.rs says - the WPF ToolTips of the
// bar's buttons, the settings box's cut-off chips and the markers, and the
// tray menu's item tips (trayicon.rs). Tracking, so nothing of ours is
// subclassed and no window of ours is asked for its tools.

use std::mem::offset_of;

use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::UI::Controls::{
    ICC_WIN95_CLASSES, INITCOMMONCONTROLSEX, InitCommonControlsEx, TOOLTIPS_CLASSW, TTF_ABSOLUTE,
    TTF_TRACK, TTM_ADDTOOLW, TTM_SETMAXTIPWIDTH, TTM_TRACKACTIVATE, TTM_TRACKPOSITION,
    TTM_UPDATETIPTEXTW, TTS_ALWAYSTIP, TTS_NOPREFIX, TTTOOLINFOW,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CW_USEDEFAULT, CreateWindowExW, DestroyWindow, SendMessageW, WINDOW_STYLE, WS_EX_TOPMOST,
    WS_POPUP,
};
use windows::core::{PCWSTR, PWSTR};

/// WPF's ToolTip wraps at its own width; this one at 400 pixels.
const WIDTH: isize = 400;

pub struct Tip {
    hwnd: HWND,
    info: TTTOOLINFOW,
    text: Vec<u16>,
    shown: Option<(String, i32, i32)>,
}

impl Tip {
    /// One tooltip owned by `owner`; None if the system gives none.
    pub fn new(owner: HWND) -> Option<Tip> {
        unsafe {
            let icc = INITCOMMONCONTROLSEX {
                dwSize: size_of::<INITCOMMONCONTROLSEX>() as u32,
                dwICC: ICC_WIN95_CLASSES,
            };
            let _ = InitCommonControlsEx(&icc);
            let hwnd = CreateWindowExW(
                WS_EX_TOPMOST,
                TOOLTIPS_CLASSW,
                PCWSTR::null(),
                WINDOW_STYLE(WS_POPUP.0 | TTS_NOPREFIX | TTS_ALWAYSTIP),
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                CW_USEDEFAULT,
                Some(owner),
                None,
                None,
                None,
            )
            .ok()?;
            let mut tip = Tip {
                hwnd,
                // the size before lpReserved: what comctl32 5 and 6 both take
                info: TTTOOLINFOW {
                    cbSize: offset_of!(TTTOOLINFOW, lpReserved) as u32,
                    uFlags: TTF_TRACK | TTF_ABSOLUTE,
                    hwnd: owner,
                    uId: 1,
                    ..Default::default()
                },
                text: vec![0],
                shown: None,
            };
            tip.info.lpszText = PWSTR(tip.text.as_mut_ptr());
            SendMessageW(
                hwnd,
                TTM_ADDTOOLW,
                None,
                Some(LPARAM(&tip.info as *const _ as isize)),
            );
            SendMessageW(hwnd, TTM_SETMAXTIPWIDTH, None, Some(LPARAM(WIDTH)));
            Some(tip)
        }
    }

    /// `text` with its top left at (x, y), screen pixels.
    pub fn show(&mut self, text: &str, x: i32, y: i32) {
        if self
            .shown
            .as_ref()
            .is_some_and(|(t, sx, sy)| t == text && *sx == x && *sy == y)
        {
            return;
        }
        let was = self.shown.is_some();
        self.text = text.encode_utf16().chain(std::iter::once(0)).collect();
        self.info.lpszText = PWSTR(self.text.as_mut_ptr());
        let info = LPARAM(&self.info as *const _ as isize);
        unsafe {
            SendMessageW(self.hwnd, TTM_UPDATETIPTEXTW, None, Some(info));
            // MAKELPARAM(x, y): each a 16-bit half, a screen left of the
            // main one's negative x kept in its two's complement
            let at = ((y as u16 as isize) << 16) | x as u16 as isize;
            SendMessageW(self.hwnd, TTM_TRACKPOSITION, None, Some(LPARAM(at)));
            if !was {
                SendMessageW(self.hwnd, TTM_TRACKACTIVATE, Some(WPARAM(1)), Some(info));
            }
        }
        self.shown = Some((text.to_string(), x, y));
    }

    pub fn hide(&mut self) {
        if self.shown.take().is_some() {
            let info = LPARAM(&self.info as *const _ as isize);
            unsafe { SendMessageW(self.hwnd, TTM_TRACKACTIVATE, Some(WPARAM(0)), Some(info)) };
        }
    }

    /// What it shows now, if anything.
    pub fn text(&self) -> Option<&str> {
        self.shown.as_ref().map(|(t, _, _)| t.as_str())
    }
}

impl Drop for Tip {
    fn drop(&mut self) {
        let _ = unsafe { DestroyWindow(self.hwnd) };
    }
}
