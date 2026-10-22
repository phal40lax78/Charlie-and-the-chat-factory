// The open chip's open, as the WPF overlay's: the hidden Windows PowerShell
// that runs Show-ChatFresh for a row (Start-ChatShowFreshProcess), VS
// Code's processes let bring their window forward at the click
// (Grant-ChatOverlayFront), and once the child ends, the chat's VS Code
// window found and brought to the front (Get-ChatCodeWindowList,
// Get-ChatCodeProfileNames, Invoke-ChatOverlayRaise). The one place the
// panel takes the foreground, and only for the user's own click on open.
// The waits, the log lines and the said marker are app.rs's. Under
// CHATQ_NOFRONT (the tests) nothing here asks for the front: no leave
// given, no raise, the window in front read as none.

use std::path::Path;

use windows::Win32::Foundation::{CloseHandle, HANDLE, HWND, LPARAM, WAIT_OBJECT_0};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS,
};
use windows::Win32::System::Threading::{
    CREATE_NEW_CONSOLE, CreateProcessW, GetCurrentThreadId, GetExitCodeProcess,
    PROCESS_INFORMATION, STARTF_USESHOWWINDOW, STARTUPINFOW, WaitForSingleObject,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetForegroundWindow, GetWindowTextW, GetWindowThreadProcessId, IsHungAppWindow,
    IsIconic, IsWindowVisible, SW_HIDE, SW_RESTORE, ShowWindow,
};
use windows::core::{BOOL, PCWSTR, PWSTR};

/// The variables the child is handed as they are here, set (the WPF
/// overlay's list): which Claude, Codex and code it speaks for.
const PASSED: [&str; 5] = [
    "CLAUDE_CONFIG_DIR",
    "CODEX_HOME",
    "CHAT_CODE_USER",
    "CHATQ_CLAUDE",
    "CHATQ_CODE",
];

/// CHATQ_NOFRONT set: nothing of ours asks for the front.
pub fn nofront() -> bool {
    std::env::var_os("CHATQ_NOFRONT").is_some_and(|v| !v.is_empty())
}

/// PowerShell's single-quoted string of `s`: each quote doubled, the
/// curly ones too (CodeGeneration.EscapeSingleQuotedStringContent).
pub fn quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        if matches!(c, '\'' | '\u{2018}' | '\u{2019}' | '\u{201A}' | '\u{201B}') {
            out.push(c);
        }
        out.push(c);
    }
    out.push('\'');
    out
}

pub fn base64(bytes: &[u8]) -> String {
    const A: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let at = |i: usize| u32::from(c.get(i).copied().unwrap_or(0));
        let n = (at(0) << 16) | (at(1) << 8) | at(2);
        for i in 0..4 {
            out.push(if i <= c.len() {
                A[(n >> (18 - 6 * i)) as usize & 63] as char
            } else {
                '='
            });
        }
    }
    out
}

/// The set ones of PASSED, as they are now.
pub fn env_now() -> Vec<(&'static str, String)> {
    PASSED
        .iter()
        .filter_map(|&n| {
            std::env::var(n)
                .ok()
                .filter(|v| !v.is_empty())
                .map(|v| (n, v))
        })
        .collect()
}

/// The child's script (Start-ChatShowFreshProcess): chatq.ps1 dot-sourced
/// and Show-ChatFresh run for the session, its ExitCode the child's. Every
/// value single-quoted and the title in base64, so nothing a chat is
/// called is ever read as code.
pub fn command(
    script: &str,
    sid: &str,
    cwd: &str,
    title: &str,
    claude_home: &str,
    env: &[(&str, String)],
) -> String {
    let mut pre = String::from("$env:CHATQ_OVERLAY='1'; ");
    for (n, v) in env {
        pre += &format!("$env:{n}={}; ", quote(v));
    }
    format!(
        "{pre}. {}; $r = @(Show-ChatFresh -Via chip -SessionId {} -Cwd {} -TitleB64 {} -ConfigDir {})[-1]; exit [int]$r.ExitCode",
        quote(script),
        quote(sid),
        quote(cwd),
        quote(&base64(title.as_bytes())),
        quote(claude_home)
    )
}

/// PowerShell's -EncodedCommand of `cmd`: base64 of its UTF-16LE.
pub fn encoded(cmd: &str) -> String {
    let bytes: Vec<u8> = cmd.encode_utf16().flat_map(u16::to_le_bytes).collect();
    base64(&bytes)
}

/// The child: its process and thread handles, closed when dropped.
pub struct Child {
    process: HANDLE,
    thread: HANDLE,
    /// the tests' alone: an open is logged by its chat, never its process
    #[cfg_attr(not(test), allow(dead_code))]
    pub pid: u32,
}

impl Child {
    /// Its exit code once it has ended, -1 if that cannot be read.
    pub fn exited(&self) -> Option<i64> {
        if unsafe { WaitForSingleObject(self.process, 0) } != WAIT_OBJECT_0 {
            return None;
        }
        let mut code = 0u32;
        Some(
            match unsafe { GetExitCodeProcess(self.process, &mut code) } {
                Ok(()) => i64::from(code as i32),
                Err(_) => -1,
            },
        )
    }
}

impl Drop for Child {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.thread);
            let _ = CloseHandle(self.process);
        }
    }
}

/// `cmd` run by Windows PowerShell 5.1, hidden: Start-Process -WindowStyle
/// Hidden's. A console of its own, hidden, so the code -n it starts finds
/// one and makes none; nothing of ours inherited. None if it did not start
/// or the script is not there.
pub fn spawn(script: &str, cmd: &str) -> Option<Child> {
    if script.is_empty() || !Path::new(script).exists() {
        return None;
    }
    let root = std::env::var("SystemRoot")
        .ok()
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "C:\\Windows".into());
    let exe = format!(
        "{}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
        root.trim_end_matches('\\')
    );
    let wide = |s: &str| -> Vec<u16> { s.encode_utf16().chain(std::iter::once(0)).collect() };
    let app = wide(&exe);
    let mut line = wide(&format!(
        "\"{exe}\" -NoProfile -NonInteractive -EncodedCommand {}",
        encoded(cmd)
    ));
    let si = STARTUPINFOW {
        cb: size_of::<STARTUPINFOW>() as u32,
        dwFlags: STARTF_USESHOWWINDOW,
        wShowWindow: SW_HIDE.0 as u16,
        ..Default::default()
    };
    let mut pi = PROCESS_INFORMATION::default();
    unsafe {
        CreateProcessW(
            PCWSTR(app.as_ptr()),
            Some(PWSTR(line.as_mut_ptr())),
            None,
            None,
            false,
            CREATE_NEW_CONSOLE,
            None,
            PCWSTR::null(),
            &si,
            &mut pi,
        )
    }
    .ok()?;
    Some(Child {
        process: pi.hProcess,
        thread: pi.hThread,
        pid: pi.dwProcessId,
    })
}

/// VS Code's processes, Insiders' too (Get-ChatCodePids).
pub fn code_pids() -> Vec<u32> {
    let mut out = Vec::new();
    unsafe {
        let Ok(snap) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else {
            return out;
        };
        let mut e = PROCESSENTRY32W {
            dwSize: size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        let mut more = Process32FirstW(snap, &mut e).is_ok();
        while more {
            let len = e
                .szExeFile
                .iter()
                .position(|&c| c == 0)
                .unwrap_or(e.szExeFile.len());
            let name = String::from_utf16_lossy(&e.szExeFile[..len]);
            if name.eq_ignore_ascii_case("Code.exe")
                || name.eq_ignore_ascii_case("Code - Insiders.exe")
            {
                out.push(e.th32ProcessID);
            }
            more = Process32NextW(snap, &mut e).is_ok();
        }
        let _ = CloseHandle(snap);
    }
    out
}

/// At the click, while this process holds the user's last input: leave for
/// those processes alone to bring a window of theirs to the front, which
/// Windows takes back at the user's next input (Grant-ChatOverlayFront).
/// How many took it; none under CHATQ_NOFRONT.
pub fn grant(pids: &[u32]) -> usize {
    if nofront() {
        return 0;
    }
    pids.iter()
        .filter(|&&p| {
            p > 0
                && unsafe { windows::Win32::UI::WindowsAndMessaging::AllowSetForegroundWindow(p) }
                    .is_ok()
        }) // allow-input-hijack - the user's own click on open asks for it
        .count()
}

/// The window in front; 0 under CHATQ_NOFRONT.
pub fn foreground() -> isize {
    if nofront() {
        return 0;
    }
    unsafe { GetForegroundWindow() }.0 as isize
}

struct Found<'a> {
    pids: &'a [u32],
    windows: Vec<(isize, String)>,
}

unsafe extern "system" fn each(h: HWND, l: LPARAM) -> BOOL {
    let found = unsafe { &mut *(l.0 as *mut Found) };
    let mut pid = 0;
    unsafe { GetWindowThreadProcessId(h, Some(&mut pid)) };
    if found.pids.contains(&pid) && unsafe { IsWindowVisible(h) }.as_bool() {
        let mut text = [0u16; 512];
        let len = unsafe { GetWindowTextW(h, &mut text) };
        if len > 0 {
            found.windows.push((
                h.0 as isize,
                String::from_utf16_lossy(&text[..len as usize]),
            ));
        }
    }
    BOOL::from(true)
}

/// The visible top-level windows of `pids`, with their titles
/// (Get-ChatCodeWindowList): read, nothing more. The titles go no further
/// than model::select_window, never into a log.
pub fn windows(pids: &[u32]) -> Vec<(isize, String)> {
    if pids.is_empty() {
        return Vec::new();
    }
    let mut found = Found {
        pids,
        windows: Vec::new(),
    };
    let _ = unsafe { EnumWindows(Some(each), LPARAM(&mut found as *mut Found as isize)) };
    found.windows
}

/// The names of VS Code's profiles, which its window titles carry after
/// the folder's (Get-ChatCodeProfileNames): from its own storage.json,
/// read, nothing more. None when there are none or it cannot be read.
pub fn profiles() -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    let Some(appdata) = std::env::var_os("APPDATA").filter(|v| !v.is_empty()) else {
        return names;
    };
    for app in ["Code", "Code - Insiders"] {
        let file = Path::new(&appdata)
            .join(app)
            .join("User")
            .join("globalStorage")
            .join("storage.json");
        let Ok(bytes) = std::fs::read(&file) else {
            continue;
        };
        let Ok(v) = serde_json::from_slice::<serde_json::Value>(&bytes) else {
            continue;
        };
        for p in v
            .get("userDataProfiles")
            .and_then(|p| p.as_array())
            .into_iter()
            .flatten()
        {
            let n = crate::model::s(p, "name");
            if !n.is_empty() && !names.contains(&n) {
                names.push(n);
            }
        }
    }
    names
}

/// How a raise went (Invoke-ChatOverlayRaise): in front at the end,
/// restored from minimized, the window in front's input joined, and why
/// not in front.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct Raised {
    pub front: bool,
    pub restored: bool,
    pub joined: bool,
    pub why: Option<&'static str>,
}

/// The VS Code window `h` brought to the front, as the user's click on open
/// asked: restored first if minimized, then asked for the front. If Windows
/// says no, one fallback, and only while the window in front is still the
/// one the click left there (`was_front`) and answers: this thread joins
/// its input for the call. A window the user put in front since is theirs,
/// and a hung one would hang this thread too. Never topmost, no input made.
pub fn raise(h: isize, was_front: isize) -> Raised {
    raise_if(!nofront(), h, was_front)
}

fn raise_if(allowed: bool, h: isize, was_front: isize) -> Raised {
    let mut r = Raised::default();
    if !allowed {
        r.why = Some("refused - CHATQ_NOFRONT is set");
        return r;
    }
    let hwnd = HWND(h as *mut _);
    let front = || unsafe { GetForegroundWindow() }.0 as isize;
    unsafe {
        if IsIconic(hwnd).as_bool() {
            r.restored = true;
            let _ = ShowWindow(hwnd, SW_RESTORE);
        }
        if front() != h {
            let _ = windows::Win32::UI::WindowsAndMessaging::SetForegroundWindow(hwnd); // allow-input-hijack - the user's own click on open asks for it
            let fg = front();
            if fg != 0 && fg != h {
                let other = HWND(fg as *mut _);
                if fg != was_front {
                    r.why = Some("another window came to the front since the click");
                } else if IsHungAppWindow(other).as_bool() {
                    r.why = Some("the window in front is not answering");
                } else {
                    r.joined = true;
                    joined(hwnd, other);
                }
            }
        }
    }
    r.front = front() == h;
    if !r.front && r.why.is_none() {
        r.why = Some("Windows kept the window in front");
    }
    r
}

/// ChatOverlayFront.ToFrontJoined: for one call, this thread's input joined
/// to the thread of the window in front, so Windows lets the front go.
fn joined(h: HWND, other: HWND) {
    unsafe {
        let mine = GetCurrentThreadId();
        let theirs = GetWindowThreadProcessId(other, None);
        let attached = theirs != 0
            && theirs != mine
            && windows::Win32::System::Threading::AttachThreadInput(mine, theirs, true).as_bool(); // allow-input-hijack - the user's own click on open asks for it
        let _ = windows::Win32::UI::WindowsAndMessaging::BringWindowToTop(h); // allow-input-hijack - the user's own click on open asks for it
        let _ = windows::Win32::UI::WindowsAndMessaging::SetForegroundWindow(h); // allow-input-hijack - the user's own click on open asks for it
        if attached {
            let _ = windows::Win32::System::Threading::AttachThreadInput(mine, theirs, false); // allow-input-hijack - the user's own click on open asks for it
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_quote_doubles_every_single_quote_the_curly_ones_too() {
        assert_eq!(quote(""), "''");
        assert_eq!(quote("plain"), "'plain'");
        assert_eq!(quote("it's"), "'it''s'");
        assert_eq!(
            quote("\u{2018}a\u{2019} \u{201A}b\u{201B}"),
            "'\u{2018}\u{2018}a\u{2019}\u{2019} \u{201A}\u{201A}b\u{201B}\u{201B}'"
        );
        assert_eq!(quote("$(x) \"y\" `z"), "'$(x) \"y\" `z'");
    }

    #[test]
    fn base64_as_convert_writes_it() {
        for (text, want) in [
            ("", ""),
            ("f", "Zg=="),
            ("fo", "Zm8="),
            ("foo", "Zm9v"),
            ("foobar", "Zm9vYmFy"),
        ] {
            assert_eq!(base64(text.as_bytes()), want);
        }
        // UTF-8 for the title, UTF-16LE for -EncodedCommand
        assert_eq!(base64("한".as_bytes()), "7ZWc");
        assert_eq!(encoded("ab"), "YQBiAA==");
    }

    #[test]
    fn the_childs_script_is_the_wpf_overlays_word_for_word() {
        let env = [
            (
                "CLAUDE_CONFIG_DIR",
                "C:\\Users\\me\\.claude-two".to_string(),
            ),
            ("CHATQ_CODE", "C:\\it's\\code.cmd".to_string()),
        ];
        let got = command(
            "C:\\chatq\\chatq.ps1",
            "0123456789abcdef",
            "D:\\work\\it's",
            "fix ‘it’",
            "C:\\Users\\me\\.claude",
            &env,
        );
        assert_eq!(
            got,
            "$env:CHATQ_OVERLAY='1'; $env:CLAUDE_CONFIG_DIR='C:\\Users\\me\\.claude-two'; $env:CHATQ_CODE='C:\\it''s\\code.cmd'; . 'C:\\chatq\\chatq.ps1'; $r = @(Show-ChatFresh -Via chip -SessionId '0123456789abcdef' -Cwd 'D:\\work\\it''s' -TitleB64 'Zml4IOKAmGl04oCZ' -ConfigDir 'C:\\Users\\me\\.claude')[-1]; exit [int]$r.ExitCode"
        );
        let bare = command("s.ps1", "", "", "", "", &[]);
        assert_eq!(
            bare,
            "$env:CHATQ_OVERLAY='1'; . 's.ps1'; $r = @(Show-ChatFresh -Via chip -SessionId '' -Cwd '' -TitleB64 '' -ConfigDir '')[-1]; exit [int]$r.ExitCode"
        );
    }

    #[test]
    fn a_raise_refused_calls_nothing() {
        // a handle no window has: any call made would fail, none is made
        let r = raise_if(false, 0x7fff_0000, 0);
        assert_eq!(
            r,
            Raised {
                front: false,
                restored: false,
                joined: false,
                why: Some("refused - CHATQ_NOFRONT is set")
            }
        );
    }

    #[test]
    fn the_child_runs_hidden_and_its_exit_code_comes_back() {
        // its own script stands in for chatq.ps1, which must be there
        let script = std::env::current_exe().unwrap();
        let child = spawn(&script.to_string_lossy(), "exit 7").expect("started");
        assert!(child.pid > 0);
        let start = std::time::Instant::now();
        let code = loop {
            if let Some(code) = child.exited() {
                break code;
            }
            assert!(start.elapsed().as_secs() < 60, "no end in 60 s");
            std::thread::sleep(std::time::Duration::from_millis(50));
        };
        assert_eq!(code, 7);
        assert!(spawn("", "exit 0").is_none());
        assert!(spawn("C:\\no\\such\\chatq.ps1", "exit 0").is_none());
    }
}
