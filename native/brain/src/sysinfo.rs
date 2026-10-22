//! Free physical memory and free disk, behind a trait so the guard is testable.
//! Windows: GlobalMemoryStatusEx / GetDiskFreeSpaceExW. Linux: /proc/meminfo.
//! Elsewhere (macOS host_statistics64 is not wired yet) readings are `None`
//! and the guard lets the load through.

use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Mem {
    pub free: u64,
    pub total: u64,
}

pub trait MemSource: Send + Sync {
    fn read(&self) -> Option<Mem>;
    fn disk_free(&self, dir: &Path) -> Option<u64>;
}

pub struct OsMem;

impl MemSource for OsMem {
    fn read(&self) -> Option<Mem> {
        os_mem()
    }
    fn disk_free(&self, dir: &Path) -> Option<u64> {
        os_disk_free(dir)
    }
}

#[cfg(windows)]
fn os_mem() -> Option<Mem> {
    use windows::Win32::System::SystemInformation::{GlobalMemoryStatusEx, MEMORYSTATUSEX};
    let mut s = MEMORYSTATUSEX { dwLength: std::mem::size_of::<MEMORYSTATUSEX>() as u32, ..Default::default() };
    // SAFETY: `s` is a valid MEMORYSTATUSEX with dwLength set, as the API requires.
    unsafe { GlobalMemoryStatusEx(&mut s).ok()? };
    Some(Mem { free: s.ullAvailPhys, total: s.ullTotalPhys })
}

#[cfg(windows)]
fn os_disk_free(dir: &Path) -> Option<u64> {
    use std::os::windows::ffi::OsStrExt;
    use windows::core::PCWSTR;
    use windows::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    let wide: Vec<u16> = dir.as_os_str().encode_wide().chain(std::iter::once(0)).collect();
    let mut avail: u64 = 0;
    // SAFETY: `wide` is NUL-terminated and outlives the call; `avail` is a valid out pointer.
    unsafe { GetDiskFreeSpaceExW(PCWSTR(wide.as_ptr()), Some(&mut avail), None, None).ok()? };
    Some(avail)
}

#[cfg(target_os = "linux")]
fn os_mem() -> Option<Mem> {
    let s = std::fs::read_to_string("/proc/meminfo").ok()?;
    let kb = |key: &str| -> Option<u64> {
        let line = s.lines().find(|l| l.starts_with(key))?;
        line.split_whitespace().nth(1)?.parse::<u64>().ok().map(|k| k * 1024)
    };
    Some(Mem { free: kb("MemAvailable:")?, total: kb("MemTotal:")? })
}

#[cfg(not(any(windows, target_os = "linux")))]
fn os_mem() -> Option<Mem> {
    None
}

#[cfg(not(windows))]
fn os_disk_free(_dir: &Path) -> Option<u64> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn os_reading_is_sane_where_supported() {
        if let Some(m) = OsMem.read() {
            assert!(m.total > 0 && m.free <= m.total);
        }
    }
}
