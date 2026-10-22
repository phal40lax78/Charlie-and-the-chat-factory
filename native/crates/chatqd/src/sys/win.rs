//! Windows: CreateProcessW, SetThreadExecutionState, the process probes.

use super::Kind;
use crate::http::{loopback, url_host};
use std::io;
use std::time::Duration;
use windows::Win32::Foundation::{
    CloseHandle, FILETIME, GlobalFree, HANDLE, HGLOBAL, WAIT_OBJECT_0,
};
use windows::Win32::Networking::WinHttp::{
    WINHTTP_CURRENT_USER_IE_PROXY_CONFIG, WinHttpGetIEProxyConfigForCurrentUser,
};
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

/// Takes a WinHTTP-allocated string: its text, and the string GlobalFree'd.
fn take_wstr(p: PWSTR) -> Option<String> {
    if p.is_null() {
        return None;
    }
    // SAFETY: p is a NUL-terminated string WinHTTP GlobalAlloc'd for its
    // caller, read once and freed once here.
    let s = unsafe { p.to_string() }.ok();
    // SAFETY: as above; p is not used after this.
    let _ = unsafe { GlobalFree(Some(HGLOBAL(p.0.cast()))) };
    s.filter(|s| !s.trim().is_empty())
}

/// The system proxy for `url` as .NET's default `WebRequest` proxy finds it:
/// the user's IE settings, then auto-detect (WPAD) or the PAC script they
/// name, then the manual proxy and its bypass list. Only a proxy's first
/// entry is used; DIRECT, a failure or nothing set is None. The answer is
/// `http://host:port`. `url` is the origin alone, `scheme://authority/`
/// ([crate::http::get]), so no path or topic reaches a PAC script.
pub fn system_proxy(url: &str) -> Option<String> {
    // .NET's WebProxy.IsBypassed: a loopback host never goes through a
    // proxy, found by WPAD, a PAC or by hand
    let host = url_host(url);
    if loopback(host) {
        return None;
    }
    let mut ie = WINHTTP_CURRENT_USER_IE_PROXY_CONFIG::default();
    // SAFETY: ie is a valid out pointer; its strings are taken below.
    let have = unsafe { WinHttpGetIEProxyConfigForCurrentUser(&mut ie) }.is_ok();
    let (auto_detect, pac, manual, bypass) = if have {
        (
            ie.fAutoDetect.as_bool(),
            take_wstr(ie.lpszAutoConfigUrl),
            take_wstr(ie.lpszProxy),
            take_wstr(ie.lpszProxyBypass),
        )
    } else {
        (true, None, None, None)
    };
    // nothing found there: the manual settings, as .NET falls back
    if (auto_detect || pac.is_some())
        && let Some(found) = auto_proxy(url, auto_detect, pac.as_deref())
    {
        return found;
    }
    let manual = manual?;
    if bypassed(host, bypass.as_deref().unwrap_or("")) {
        return None;
    }
    pick_proxy(&manual, url.starts_with("https:")).map(|p| with_scheme(&p))
}

/// WPAD or the named PAC script through WinHttpGetProxyForUrl: Some(None)
/// for DIRECT, Some(Some(proxy)) for its first proxy, None when it found
/// nothing.
fn auto_proxy(url: &str, detect: bool, pac: Option<&str>) -> Option<Option<String>> {
    use windows::Win32::Networking::WinHttp::*;
    // SAFETY: plain arguments; the session is closed below.
    let session = unsafe {
        WinHttpOpen(
            PCWSTR::null(),
            WINHTTP_ACCESS_TYPE_NO_PROXY,
            PCWSTR::null(),
            PCWSTR::null(),
            0,
        )
    };
    if session.is_null() {
        return None;
    }
    // The PAC download's resolve, connect, send and receive: 7 s at most
    // together, inside the poll's 8 s. The DHCP and DNS discovery of WPAD
    // itself is not bound by these.
    // SAFETY: session is the open handle from WinHttpOpen.
    let _ = unsafe { WinHttpSetTimeouts(session, 1000, 2000, 2000, 2000) };
    let url_w = HSTRING::from(url);
    let pac_w = pac.map(HSTRING::from);
    let mut opts = WINHTTP_AUTOPROXY_OPTIONS {
        fAutoLogonIfChallenged: true.into(),
        ..Default::default()
    };
    if detect {
        opts.dwFlags |= WINHTTP_AUTOPROXY_AUTO_DETECT;
        opts.dwAutoDetectFlags = WINHTTP_AUTO_DETECT_TYPE_DHCP | WINHTTP_AUTO_DETECT_TYPE_DNS_A;
    }
    if let Some(p) = &pac_w {
        opts.dwFlags |= WINHTTP_AUTOPROXY_CONFIG_URL;
        opts.lpszAutoConfigUrl = PCWSTR(p.as_ptr());
    }
    let mut info = WINHTTP_PROXY_INFO::default();
    // SAFETY: session is open; url_w, pac_w and opts outlive the call; info's
    // strings are taken below.
    let ok = unsafe { WinHttpGetProxyForUrl(session, &url_w, &mut opts, &mut info) }.is_ok();
    // SAFETY: session came from WinHttpOpen and is closed once.
    let _ = unsafe { WinHttpCloseHandle(session) };
    if !ok {
        return None;
    }
    let proxy = take_wstr(info.lpszProxy);
    let _ = take_wstr(info.lpszProxyBypass);
    if info.dwAccessType != WINHTTP_ACCESS_TYPE_NAMED_PROXY {
        return Some(None);
    }
    Some(
        proxy
            .and_then(|p| pick_proxy(&p, url.starts_with("https:")))
            .map(|p| with_scheme(&p)),
    )
}

/// The first usable entry of a WinHTTP proxy list (`;` or space apart):
/// `https=` for an https URL, else a bare `host:port`.
fn pick_proxy(list: &str, https: bool) -> Option<String> {
    let entries = || {
        list.split([';', ' ', '\t'])
            .map(str::trim)
            .filter(|e| !e.is_empty())
    };
    let want = if https { "https=" } else { "http=" };
    entries()
        .find_map(|e| e.strip_prefix(want).map(str::to_string))
        .or_else(|| entries().find(|e| !e.contains('=')).map(str::to_string))
        .filter(|p| !p.eq_ignore_ascii_case("DIRECT"))
}

fn with_scheme(p: &str) -> String {
    if p.contains("://") {
        p.to_string()
    } else {
        format!("http://{p}")
    }
}

/// The IE bypass list: `<local>` for a dotless host, else `*` wildcards,
/// case-blind.
fn bypassed(host: &str, list: &str) -> bool {
    list.split([';', ' ', '\t'])
        .map(str::trim)
        .filter(|e| !e.is_empty())
        .any(|e| {
            if e.eq_ignore_ascii_case("<local>") {
                !host.contains('.')
            } else {
                wildcard(&e.to_ascii_lowercase(), &host.to_ascii_lowercase())
            }
        })
}

fn wildcard(pat: &str, s: &str) -> bool {
    match pat.split_once('*') {
        None => pat == s,
        Some((head, rest)) => {
            s.starts_with(head) && {
                let s = &s[head.len()..];
                (0..=s.len()).any(|i| s.is_char_boundary(i) && wildcard(rest, &s[i..]))
            }
        }
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
