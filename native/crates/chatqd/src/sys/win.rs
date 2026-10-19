//! Windows: CreateProcessW, SetThreadExecutionState, the process probes.

use super::Kind;
use std::io;
use std::time::Duration;
use windows::Win32::Foundation::{CloseHandle, FILETIME, HANDLE, WAIT_OBJECT_0};
use windows::Win32::System::Power::{ES_CONTINUOUS, ES_SYSTEM_REQUIRED, SetThreadExecutionState};
use windows::Win32::System::Threading::{
    CREATE_NEW_CONSOLE, CREATE_SUSPENDED, CreateProcessW, GetCurrentProcess, GetExitCodeProcess,
    GetProcessTimes, OpenProcess, PROCESS_CREATION_FLAGS, PROCESS_INFORMATION, PROCESS_NAME_WIN32,
    PROCESS_QUERY_LIMITED_INFORMATION, QueryFullProcessImageNameW, ResumeThread,
    STARTF_USESHOWWINDOW, STARTUPINFOW, TerminateProcess, WaitForSingleObject,
};
use windows::Win32::UI::WindowsAndMessaging::{MSG, PM_NOREMOVE, PeekMessageW, SW_HIDE};
use windows::core::{HSTRING, PCWSTR, PWSTR};

const STILL_ACTIVE: u32 = 259;
const ERROR_ACCESS_DENIED: i32 = 5;
/// .NET ticks at 1601-01-01, the FILETIME epoch.
const FILETIME_TICKS: i64 = 504_911_232_000_000_000;

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

/// `CreateProcessW` of `exe args` in `cwd`. `console` gives the child its
/// own hidden console, as `Start-Process -WindowStyle Hidden` gives a PS
/// watcher. The caller closes both handles in the answer.
fn create(
    exe: &str,
    args: &[String],
    cwd: &str,
    mut flags: PROCESS_CREATION_FLAGS,
    console: bool,
) -> io::Result<PROCESS_INFORMATION> {
    let mut line: Vec<u16> = super::command_line(exe, args)
        .encode_utf16()
        .chain([0])
        .collect();
    let cwd = HSTRING::from(cwd);
    let mut si = STARTUPINFOW {
        cb: size_of::<STARTUPINFOW>() as u32,
        ..Default::default()
    };
    if console {
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
    Ok(pi)
}

/// Starts `cmdline` in `cwd`, suspended, and calls `before_run` with its pid
/// before it runs a single instruction: a native launch writes pending.json
/// there, so the child's ack (deleting it) can never come first. A PS watcher
/// gets its own hidden console; chatqd needs none.
pub fn launch(
    kind: Kind,
    exe: &str,
    args: &[String],
    cwd: &str,
    _log_dir: &str,
    before_run: &mut dyn FnMut(u32),
) -> io::Result<u32> {
    let pi = create(exe, args, cwd, CREATE_SUSPENDED, kind == Kind::Ps)?;
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

/// A helper step's process (SPEC 3.6), its handle kept for the exit code.
/// Not in a job object, so it outlives chatqd as a PS watcher's run does.
pub struct Waited(HANDLE);

/// Starts a helper step: `exe args` in `cwd` with its own hidden console,
/// the PS watcher's own window (SPEC 3.6 "Window"). Not [launch], whose
/// suspend-and-ack belongs to watcher launches.
pub fn spawn_waited(exe: &str, args: &[String], cwd: &str) -> io::Result<Waited> {
    let pi = create(exe, args, cwd, PROCESS_CREATION_FLAGS(0), true)?;
    close(pi.hThread);
    Ok(Waited(pi.hProcess))
}

impl Waited {
    /// Waits up to `timeout` for the step to end: its exit code as .NET's
    /// `ExitCode` reads it, or None while it still runs.
    pub fn wait(&mut self, timeout: Duration) -> Option<i32> {
        let ms = u32::try_from(timeout.as_millis()).unwrap_or(u32::MAX);
        // SAFETY: self.0 is the live process handle CreateProcessW gave.
        if unsafe { WaitForSingleObject(self.0, ms) } != WAIT_OBJECT_0 {
            return None;
        }
        let mut code = 0u32;
        // SAFETY: as above; code is a valid out pointer.
        unsafe { GetExitCodeProcess(self.0, &mut code) }.ok()?;
        Some(code as i32)
    }
}

impl Drop for Waited {
    fn drop(&mut self) {
        close(self.0);
    }
}

/// chatqd's own start time as .NET UTC ticks: the creation FILETIME from
/// `GetProcessTimes`, the source of .NET's `Process.StartTime` (SPEC 3.6).
pub fn own_start_ticks() -> io::Result<i64> {
    let mut times = [FILETIME::default(); 4];
    let [created, exited, kernel, user] = &mut times;
    // SAFETY: the pseudo handle needs no closing; all four are valid out
    // pointers.
    unsafe { GetProcessTimes(GetCurrentProcess(), created, exited, kernel, user) }
        .map_err(|e| io::Error::from_raw_os_error(e.code().0 & 0xFFFF))?;
    let ft = (u64::from(times[0].dwHighDateTime) << 32) | u64::from(times[0].dwLowDateTime);
    Ok(FILETIME_TICKS + ft as i64)
}
