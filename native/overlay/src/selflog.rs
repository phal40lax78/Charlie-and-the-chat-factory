// The process's own log: a sample every so often from a thread of its own,
// and at exit the loaded modules and the mapped files. The spike's modes
// write <exe dir>/data/spike.log, a sample every 10 s; the panel writes
// <data folder>/logs/overlay-panel.log, a sample a minute, so its host's
// data folder holds all it writes (main.rs). Past 1 MB a log is moved to
// <name>.1, over the one before, and begun again, as the tool's own logs
// are (Add-ChatqLogLine, src/queue.ps1): two of them at most.
// Private bytes is PROCESS_MEMORY_COUNTERS_EX.PrivateUsage, the figure .NET
// reports as PrivateMemorySize64 (the 271 MB of the WPF overlay).

use std::collections::BTreeMap;
use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering::SeqCst};
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use windows::Win32::Foundation::{CloseHandle, HMODULE};
use windows::Win32::System::Diagnostics::ToolHelp::{
    CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next,
};
use windows::Win32::System::Memory::{
    MEM_COMMIT, MEM_MAPPED, MEMORY_BASIC_INFORMATION, VirtualQuery,
};
use windows::Win32::System::ProcessStatus::{
    EnumProcessModules, GetMappedFileNameW, GetModuleBaseNameW, GetProcessMemoryInfo,
    PROCESS_MEMORY_COUNTERS, PROCESS_MEMORY_COUNTERS_EX,
};
use windows::Win32::System::Threading::{
    GR_GDIOBJECTS, GR_USEROBJECTS, GetCurrentProcess, GetCurrentProcessId, GetGuiResources,
};

use crate::win32;

const MB: f64 = 1024.0 * 1024.0;
/// Modules that would mean a GPU path got loaded after all.
const GPU_MODULES: [&str; 6] = [
    "opengl32.dll",
    "d3d9.dll",
    "d3d11.dll",
    "d3d12.dll",
    "dxgi.dll",
    "vulkan-1.dll",
];

/// Past this a log is moved aside (Add-ChatqLogLine's 1 MB).
const ROLL: u64 = 1024 * 1024;

#[derive(Debug)]
struct Log {
    /// None only while it is moved aside
    file: Option<File>,
    path: PathBuf,
    size: u64,
}

static LOG: OnceLock<Mutex<Log>> = OnceLock::new();
static START: OnceLock<Instant> = OnceLock::new();
static MAX_PRIVATE: AtomicUsize = AtomicUsize::new(0);

pub fn data_dir() -> PathBuf {
    std::env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .join("data")
}

fn open(path: &Path) -> File {
    File::options()
        .create(true)
        .append(true)
        .open(path)
        .unwrap()
}

/// Opens the log at `path`, starts the sampler, every `every`, arms a
/// watchdog that ends the process 20 s past its run time should the event
/// loop ever hang, and logs any panic.
pub fn start(path: PathBuf, args: &str, seconds: u64, every: Duration) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let file = open(&path);
    let size = file.metadata().map_or(0, |m| m.len());
    LOG.set(Mutex::new(Log {
        file: Some(file),
        path,
        size,
    }))
    .unwrap();
    START.set(Instant::now()).unwrap();
    line(&format!("start pid={} {args}", unsafe {
        GetCurrentProcessId()
    }));
    std::thread::spawn(move || {
        loop {
            std::thread::sleep(every);
            line(&sample());
        }
    });
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(seconds + 20));
        line("watchdog: the event loop did not end, exiting");
        std::process::exit(3);
    });
    // A panic goes into the log as well as to the console, which may be
    // closed by the time anyone looks (the renderer's size panic of
    // 2026-10-20 reached only the console). No backtrace: the release
    // build is stripped of symbols.
    let console = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        let thread = std::thread::current();
        line(&format!(
            "PANIC on thread {}: {}",
            thread.name().unwrap_or("?"),
            info.to_string().replace('\n', " ")
        ));
        console(info);
    }));
}

pub fn line(text: &str) {
    // before start there is no log: a unit test's run of the panel's parts
    let (Some(start), Some(log)) = (START.get(), LOG.get()) else {
        return;
    };
    let secs = start.elapsed().as_secs_f64();
    let text = format!("{secs:7.1}s {} {text}\n", win32::local_hms());
    append(&mut log.lock().unwrap(), &text, ROLL);
}

fn append(log: &mut Log, text: &str, roll_at: u64) {
    if let Some(f) = log.file.as_mut() {
        f.write_all(text.as_bytes()).unwrap();
    }
    log.size += text.len() as u64;
    if log.size > roll_at {
        roll(log);
    }
}

/// The log moved to <name>.1, over the one before, and begun again. One
/// that cannot be moved - open elsewhere - is written on, and tried again
/// at the next line.
fn roll(log: &mut Log) {
    let mut old = log.path.clone().into_os_string();
    old.push(".1");
    // closed first, so nothing of it is left to write as it moves
    log.file = None;
    let _ = std::fs::remove_file(&old);
    let moved = std::fs::rename(&log.path, &old).is_ok();
    log.file = Some(open(&log.path));
    if moved {
        log.size = 0;
    }
}

/// Private MB, GDI objects and USER objects now: the tray mode's handle
/// series (tray.rs).
pub fn counts() -> (f64, u32, u32) {
    let process = unsafe { GetCurrentProcess() };
    let mut mem = PROCESS_MEMORY_COUNTERS_EX {
        cb: size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32,
        ..Default::default()
    };
    unsafe {
        GetProcessMemoryInfo(
            process,
            &mut mem as *mut _ as *mut PROCESS_MEMORY_COUNTERS,
            mem.cb,
        )
        .unwrap()
    };
    let gui = |kind| unsafe { GetGuiResources(process, kind) };
    (
        mem.PrivateUsage as f64 / MB,
        gui(GR_GDIOBJECTS),
        gui(GR_USEROBJECTS),
    )
}

fn sample() -> String {
    let process = unsafe { GetCurrentProcess() };
    let mut mem = PROCESS_MEMORY_COUNTERS_EX {
        cb: size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32,
        ..Default::default()
    };
    unsafe {
        GetProcessMemoryInfo(
            process,
            &mut mem as *mut _ as *mut PROCESS_MEMORY_COUNTERS,
            mem.cb,
        )
        .unwrap()
    };
    MAX_PRIVATE.fetch_max(mem.PrivateUsage, SeqCst);
    let exstyle = win32::our_hwnd().map_or("none".to_string(), |h| {
        format!("{:#010x}", win32::exstyle(h))
    });
    format!(
        "sample private={:.1}MB sections={:.1}MB ws={:.1}MB gdi={} user={} threads={} foreground_ours={} exstyle={exstyle} style_fixes={}",
        mem.PrivateUsage as f64 / MB,
        sections() as f64 / MB,
        mem.WorkingSetSize as f64 / MB,
        unsafe { GetGuiResources(process, GR_GDIOBJECTS) },
        unsafe { GetGuiResources(process, GR_USEROBJECTS) },
        thread_count(),
        win32::is_ours(win32::foreground()),
        win32::style_fixes()
    )
}

/// Committed memory in mapped sections that no file backs, as softbuffer's
/// DIB sections (one per window) are: outside private bytes, so logged
/// beside them.
fn sections() -> usize {
    let process = unsafe { GetCurrentProcess() };
    let (mut total, mut address) = (0usize, 0usize);
    loop {
        let mut info = MEMORY_BASIC_INFORMATION::default();
        if unsafe {
            VirtualQuery(
                Some(address as *const _),
                &mut info,
                size_of::<MEMORY_BASIC_INFORMATION>(),
            )
        } == 0
        {
            break;
        }
        if info.Type == MEM_MAPPED && info.State == MEM_COMMIT {
            let mut buf = [0u16; 8];
            if unsafe { GetMappedFileNameW(process, info.BaseAddress, &mut buf) } == 0 {
                total += info.RegionSize;
            }
        }
        address = info.BaseAddress as usize + info.RegionSize;
    }
    total
}

pub(crate) fn thread_count() -> usize {
    let pid = unsafe { GetCurrentProcessId() };
    let mut count = 0;
    unsafe {
        // 0 on a failed snapshot: the gate's sampler thread calls this for
        // an hour, and must not die of a transient failure
        let Ok(snapshot) = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) else {
            return 0;
        };
        let mut entry = THREADENTRY32 {
            dwSize: size_of::<THREADENTRY32>() as u32,
            ..Default::default()
        };
        let mut more = Thread32First(snapshot, &mut entry).is_ok();
        while more {
            count += (entry.th32OwnerProcessID == pid) as usize;
            more = Thread32Next(snapshot, &mut entry).is_ok();
        }
        let _ = CloseHandle(snapshot);
    }
    count
}

/// The last sample, the peak, the module list with any GPU module flagged,
/// and the font files mapped into the process: which fonts were resolved,
/// and that they are mapped (file-backed, outside private bytes), not read in.
/// On this PC MarkAny's injected IMGSF50Filter_x64.dll loads opengl32 and
/// glu32 into every GUI process, so opengl32 alone does not mean Slint did.
pub fn finish() {
    line(&sample());
    line(&format!(
        "max private={:.1}MB (of the samples)",
        MAX_PRIVATE.load(SeqCst) as f64 / MB
    ));

    let process = unsafe { GetCurrentProcess() };
    let mut modules = [HMODULE::default(); 1024];
    let mut needed = 0;
    unsafe {
        EnumProcessModules(
            process,
            modules.as_mut_ptr(),
            size_of_val(&modules) as u32,
            &mut needed,
        )
        .unwrap()
    };
    let count = (needed as usize / size_of::<HMODULE>()).min(modules.len());
    let mut names: Vec<String> = modules[..count]
        .iter()
        .map(|&m| {
            let mut buf = [0u16; 260];
            let len = unsafe { GetModuleBaseNameW(process, Some(m), &mut buf) } as usize;
            String::from_utf16_lossy(&buf[..len]).to_lowercase()
        })
        .collect();
    names.sort();
    let gpu: Vec<&str> = GPU_MODULES
        .into_iter()
        .filter(|g| names.iter().any(|n| n == g))
        .collect();
    let markany = names.iter().any(|n| n == "imgsf50filter_x64.dll");
    line(&format!(
        "modules: {count}; gpu modules loaded: {gpu:?}; markany filter loaded: {markany}"
    ));
    line(&format!("module list: {}", names.join(" ")));

    let mut fonts: BTreeMap<String, usize> = BTreeMap::new();
    let mut address = 0usize;
    loop {
        let mut info = MEMORY_BASIC_INFORMATION::default();
        if unsafe {
            VirtualQuery(
                Some(address as *const _),
                &mut info,
                size_of::<MEMORY_BASIC_INFORMATION>(),
            )
        } == 0
        {
            break;
        }
        if info.Type == MEM_MAPPED && info.State == MEM_COMMIT {
            let mut buf = [0u16; 512];
            let len = unsafe { GetMappedFileNameW(process, info.BaseAddress, &mut buf) } as usize;
            let name = String::from_utf16_lossy(&buf[..len]).to_lowercase();
            if [".ttf", ".ttc", ".otf"].iter().any(|e| name.ends_with(e))
                || name.contains("fontcache")
            {
                *fonts
                    .entry(name.rsplit('\\').next().unwrap().to_string())
                    .or_default() += info.RegionSize;
            }
        }
        address = info.BaseAddress as usize + info.RegionSize;
    }
    let fonts: Vec<String> = fonts
        .iter()
        .map(|(n, b)| format!("{n}={:.1}MB", *b as f64 / MB))
        .collect();
    line(&format!("mapped font files: {}", fonts.join(" ")));
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Past its size a log goes to <name>.1, over the one before, and a
    /// new one begins: two files at most, the newest lines in the first.
    #[test]
    fn a_log_rolls_to_one_old_copy() {
        let dir = std::env::current_exe()
            .unwrap()
            .parent()
            .unwrap()
            .join("data")
            .join("selflog-test");
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("x.log");
        let mut log = Log {
            file: Some(open(&path)),
            path: path.clone(),
            size: 0,
        };
        for n in 0..5 {
            append(&mut log, &format!("line {n}\n"), 12);
        }
        let read = |p: &Path| std::fs::read_to_string(p).unwrap();
        drop(log);
        assert_eq!(read(&path), "line 4\n");
        assert_eq!(read(&dir.join("x.log.1")), "line 2\nline 3\n");
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 2);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
