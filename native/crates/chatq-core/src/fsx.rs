//! The file primitives of [src/queue.ps1](src/queue.ps1) (SPEC 2.1), and the
//! watcher lock (SPEC 4.3). Every handle here is std's default, never
//! inheritable, so no child chatqd starts can hold watcher.lock.

use crate::json::Tolerant;
use crate::time::Flavour;
use serde_json::Value;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::path::Path;
use std::thread::sleep;
use std::time::Duration;

/// [Save-ChatqText](src/queue.ps1): UTF-8 without a BOM, written aside and
/// swapped in, so a reader never sees half a file. Up to 5 tries, 100·n ms
/// apart, as a reader holding the file open is waited out there.
pub fn save_text(path: &Path, text: &str) -> io::Result<()> {
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = Path::new(&tmp);
    let mut tries = 1;
    loop {
        let r = fs::write(tmp, text.as_bytes()).and_then(|()| {
            if path.exists() {
                replace(tmp, path)
            } else {
                fs::rename(tmp, path)
            }
        });
        match r {
            Ok(()) => return Ok(()),
            Err(e) if tries == 5 => return Err(e),
            Err(_) => {
                sleep(Duration::from_millis(100 * tries));
                tries += 1;
            }
        }
    }
}

/// [Update-ChatqText](src/queue.ps1): [save_text] over a file that must
/// still be there, by the replace alone, so a file deleted meanwhile stays
/// deleted: false then, and the copy aside dropped. A failure with the file
/// still there is tried again as in [save_text].
pub fn update_text(path: &Path, text: &str) -> io::Result<bool> {
    let mut tmp = path.as_os_str().to_owned();
    tmp.push(".tmp");
    let tmp = Path::new(&tmp);
    let mut tries = 1;
    loop {
        match fs::write(tmp, text.as_bytes()).and_then(|()| replace(tmp, path)) {
            Ok(()) => return Ok(true),
            Err(_) if !path.exists() => {
                let _ = fs::remove_file(tmp);
                return Ok(false);
            }
            Err(e) if tries == 5 => return Err(e),
            Err(_) => {
                sleep(Duration::from_millis(100 * tries));
                tries += 1;
            }
        }
    }
}

/// `File.Replace(tmp, path, null)`.
#[cfg(windows)]
fn replace(tmp: &Path, path: &Path) -> io::Result<()> {
    win::replace(tmp, path)
}

/// .NET's Unix File.Replace: the target must be there, then a rename.
#[cfg(not(windows))]
fn replace(tmp: &Path, path: &Path) -> io::Result<()> {
    fs::metadata(path)?;
    fs::rename(tmp, path)
}

/// std has no ReplaceFileW, so this calls it directly: a plain rename would
/// not keep the target's identity as .NET's File.Replace does. secret.rs's
/// CryptUnprotectData is the crate's other Win32 call.
#[cfg(windows)]
#[allow(unsafe_code)]
mod win {
    use std::io;
    use std::path::Path;
    use windows::Win32::Storage::FileSystem::{REPLACE_FILE_FLAGS, ReplaceFileW};
    use windows::core::{HSTRING, PCWSTR};

    pub fn replace(tmp: &Path, path: &Path) -> io::Result<()> {
        let target = HSTRING::from(path.as_os_str());
        let source = HSTRING::from(tmp.as_os_str());
        // No flags, as .NET passes for ignoreMetadataErrors = false: a merge
        // error fails the try, and save_text retries as Save-ChatqText does.
        // SAFETY: both strings are NUL-terminated and outlive the call; the
        // backup name, exclude and reserved pointers are null as allowed.
        unsafe {
            ReplaceFileW(
                &target,
                &source,
                PCWSTR::null(),
                REPLACE_FILE_FLAGS(0),
                None,
                None,
            )
        }
        .map_err(|e| io::Error::from_raw_os_error(e.code().0 & 0xFFFF))
    }
}

/// [Read-ChatqJson](src/queue.ps1) as the PowerShell `fl` runs it
/// ([json::parse_tolerant_in](crate::json::parse_tolerant_in)): None for a
/// missing file at once; a file that does not read or parse is tried 3
/// times, 100 ms apart, then None. The top level is not unrolled.
pub fn read_json(path: &Path, fl: Flavour) -> Option<Value> {
    read_json_raw(path, fl).and_then(|(_, t)| t.value)
}

/// [read_json], keeping the bytes read and whether the read was `repaired`
/// or `lossy` (SPEC 2.2), for a caller that may write the file back. The
/// value is always Some.
pub fn read_json_raw(path: &Path, fl: Flavour) -> Option<(Vec<u8>, Tolerant)> {
    for _ in 0..3 {
        match fs::read(path) {
            Err(e) if e.kind() == io::ErrorKind::NotFound => return None,
            Ok(b) => {
                let t = crate::json::parse_tolerant_in(&b, fl);
                if t.value.is_some() {
                    return Some((b, t));
                }
            }
            Err(_) => {}
        }
        sleep(Duration::from_millis(100));
    }
    None
}

/// `Set-Content -Encoding ASCII -Value <text>`: the text and the platform's
/// newline. Not atomic, as Set-Content is not.
pub fn write_ascii_line(path: &Path, text: &str) -> io::Result<()> {
    let ascii: String = text
        .chars()
        .map(|c| if c.is_ascii() { c } else { '?' })
        .collect();
    fs::write(path, format!("{ascii}{}", crate::paths::NEWLINE))
}

/// One try at the watcher lock, as the PS loop opens it:
/// `[IO.File]::Open(path, OpenOrCreate, ReadWrite, None)`. Held for as long
/// as the returned file lives.
pub fn try_lock(path: &Path) -> io::Result<File> {
    let f = open_none(path, true)?;
    #[cfg(unix)]
    unix_lock(&f)?;
    Ok(f)
}

/// [Test-ChatqLockHeld](src/alerts.ps1): a missing file is not held; one
/// that opens with no sharing is not held; any failure to open means held.
pub fn lock_held(path: &Path) -> bool {
    if !path.exists() {
        return false;
    }
    match open_none(path, false) {
        Ok(f) => {
            #[cfg(unix)]
            return unix_lock(&f).is_err();
            #[cfg(not(unix))]
            {
                drop(f);
                false
            }
        }
        Err(_) => true,
    }
}

#[cfg(windows)]
fn open_none(path: &Path, create: bool) -> io::Result<File> {
    use std::os::windows::fs::OpenOptionsExt;
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(create)
        .share_mode(0)
        .open(path)
}

#[cfg(not(windows))]
fn open_none(path: &Path, create: bool) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(create)
        .open(path)
}

/// .NET's FileShare.None on Unix is `flock(LOCK_EX|LOCK_NB)`; std's
/// try_lock is that call.
#[cfg(unix)]
fn unix_lock(f: &File) -> io::Result<()> {
    f.try_lock().map_err(|e| match e {
        fs::TryLockError::WouldBlock => io::Error::from(io::ErrorKind::WouldBlock),
        fs::TryLockError::Error(e) => e,
    })
}

/// Appends once, the file opened for append and closed again, so another
/// appender between two lines never interleaves within one.
pub fn append(path: &Path, text: &str) -> io::Result<()> {
    let mut f = OpenOptions::new().create(true).append(true).open(path)?;
    f.write_all(text.as_bytes())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn dir(name: &str) -> std::path::PathBuf {
        let d = Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../target/test-data/core-fsx")
            .join(name);
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn save_replaces_and_leaves_no_tmp() {
        let d = dir("save");
        let p = d.join("a.json");
        save_text(&p, "one").unwrap();
        save_text(&p, "two ·").unwrap();
        assert_eq!(fs::read(&p).unwrap(), "two ·".as_bytes());
        assert!(!d.join("a.json.tmp").exists());
    }

    #[test]
    fn update_never_brings_a_file_back() {
        let d = dir("update");
        let p = d.join("a.json");
        assert!(!update_text(&p, "one").unwrap());
        assert!(!p.exists());
        assert!(!d.join("a.json.tmp").exists());
        fs::write(&p, "one").unwrap();
        assert!(update_text(&p, "two").unwrap());
        assert_eq!(fs::read(&p).unwrap(), b"two");
        assert!(!d.join("a.json.tmp").exists());
    }

    #[test]
    fn lock_excludes_and_probes() {
        let d = dir("lock");
        let p = d.join("watcher.lock");
        assert!(!lock_held(&p));
        let held = try_lock(&p).unwrap();
        assert!(lock_held(&p));
        assert!(try_lock(&p).is_err());
        drop(held);
        assert!(!lock_held(&p));
    }

    #[test]
    fn json_read_with_a_bom() {
        let d = dir("read");
        let p = d.join("x.json");
        fs::write(&p, b"\xEF\xBB\xBF{\"id\":\"a\"}").unwrap();
        assert_eq!(read_json(&p, Flavour::Core).unwrap()["id"], "a");
        assert!(read_json(&d.join("missing.json"), Flavour::Core).is_none());
    }
}
