//! Windows: CreateProcessW, SetThreadExecutionState, the process probes.

use super::Kind;
use std::io;
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::System::Power::{ES_CONTINUOUS, ES_SYSTEM_REQUIRED, SetThreadExecutionState};
use windows::Win32::System::Threading::{
    CREATE_NEW_CONSOLE, CREATE_SUSPENDED, CreateProcessW, GetExitCodeProcess, OpenProcess,
    PROCESS_INFORMATION, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    QueryFullProcessImageNameW, ResumeThread, STARTF_USESHOWWINDOW, STARTUPINFOW, TerminateProcess,
};
use windows::Win32::UI::WindowsAndMessaging::{MSG, PM_NOREMOVE, PeekMessageW, SW_HIDE};
use windows::core::{HSTRING, PCWSTR, PWSTR};

const STILL_ACTIVE: u32 = 259;
const ERROR_ACCESS_DENIED: i32 = 5;

/// A GUI-subsystem process started with feedback shows the "app starting"
/// cursor for 5 s unless it looks at its message queue once (SPEC 4.1).
pub fn peek_message() {
    let mut msg = MSG::default();
    // SAFETY: msg is a valid out pointer; no window is named.
    let _ = unsafe { PeekMessageW(&mut msg, None, 0, 0, PM_NOREMOVE) };
}

/// `SetThreadExecutionState`: `ES_CONTINUOUS|ES_SYSTEM_REQUIRED`, or
/// `ES_CONTINUOUS` alone to let go. The flag belongs to the calling thread,
/// so only the main thread calls this.
#[derive(Default)]
pub struct Awake;

impl Awake {
    pub fn set(&mut self, on: bool) {
        let flags = if on {
            ES_CONTINUOUS | ES_SYSTEM_REQUIRED
        } else {
            ES_CONTINUOUS
        };
        // SAFETY: plain flags, no pointers.
        unsafe { SetThreadExecutionState(flags) };
    }
}

fn open(pid: u32) -> Result<HANDLE, i32> {
    // SAFETY: the handle returned is closed by every caller.
    unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) }
        .map_err(|e| e.code().0 & 0xFFFF)
}

fn running(h: HANDLE) -> bool {
    let mut code = 0u32;
    // SAFETY: h is a live process handle with query rights.
    unsafe { GetExitCodeProcess(h, &mut code) }.is_ok_and(|()| code == STILL_ACTIVE)
}

/// Is there a live process at `pid`? One we may not open is there.
pub fn alive(pid: u32) -> bool {
    match open(pid) {
        Ok(h) => {
            let r = running(h);
            close(h);
            r
        }
        Err(code) => code == ERROR_ACCESS_DENIED,
    }
}

/// Is the live process at `pid` a chatqd? By its image's file name, so a
/// reused pid is not taken for one.
pub fn is_chatqd(pid: u32) -> bool {
    let Ok(h) = open(pid) else {
        return false;
    };
    let mut buf = [0u16; 1024];
    let mut len = buf.len() as u32;
    // SAFETY: buf holds len u16s; len is updated to the length written.
    let named = unsafe {
        QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len)
    }
    .is_ok();
    let r = named && running(h) && {
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        let name = path.rsplit(['\\', '/']).next().unwrap_or("");
        name.eq_ignore_ascii_case("chatqd.exe")
    };
    close(h);
    r
}

fn close(h: HANDLE) {
    // SAFETY: h came from OpenProcess or CreateProcessW and is closed once.
    let _ = unsafe { CloseHandle(h) };
}

/// Starts `cmdline` in `cwd`, suspended, and calls `before_run` with its pid
/// before it runs a single instruction: a native launch writes pending.json
/// there, so the child's ack (deleting it) can never come first. A PS watcher
/// gets its own hidden console, as `Start-Process -WindowStyle Hidden` gives
/// it; chatqd needs none.
pub fn launch(
    kind: Kind,
    exe: &str,
    args: &[String],
    cwd: &str,
    _log_dir: &str,
    before_run: &mut dyn FnMut(u32),
) -> io::Result<u32> {
    let mut line: Vec<u16> = super::command_line(exe, args)
        .encode_utf16()
        .chain([0])
        .collect();
    let cwd = HSTRING::from(cwd);
    let mut si = STARTUPINFOW {
        cb: size_of::<STARTUPINFOW>() as u32,
        ..Default::default()
    };
    let mut flags = CREATE_SUSPENDED;
    if kind == Kind::Ps {
        flags |= CREATE_NEW_CONSOLE;
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE.0 as u16;
    }
    let mut pi = PROCESS_INFORMATION::default();
    // SAFETY: line is a mutable NUL-terminated buffer that outlives the call,
    // as are cwd and si; pi is a valid out pointer. No handle is inherited.
    unsafe {
        CreateProcessW(
            PCWSTR::null(),
            Some(PWSTR(line.as_mut_ptr())),
            None,
            None,
            false,
            flags,
            None,
            &cwd,
            &si,
            &mut pi,
        )
    }
    .map_err(|e| io::Error::from_raw_os_error(e.code().0 & 0xFFFF))?;
    before_run(pi.dwProcessId);
    // SAFETY: the thread handle is the suspended main thread just created.
    let resumed = unsafe { ResumeThread(pi.hThread) } != u32::MAX;
    // A child that cannot be resumed would sit suspended for good, with no
    // handle left to it: end it, so the caller sees a launch that failed.
    let err = (!resumed).then(|| {
        let e = io::Error::last_os_error();
        // SAFETY: the process handle is the one CreateProcessW just gave.
        let _ = unsafe { TerminateProcess(pi.hProcess, 1) };
        e
    });
    close(pi.hThread);
    close(pi.hProcess);
    match err {
        Some(e) => Err(e),
        None => Ok(pi.dwProcessId),
    }
}
