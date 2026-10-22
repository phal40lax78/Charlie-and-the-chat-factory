//! Pinned downloads (SPEC.md section 1, Download): `.part` file, Range resume,
//! sha256 streamed as bytes arrive, mismatch deletes the partial. The network
//! sits behind `Source` so tests feed bytes from memory.

use sha2::{Digest, Sha256};
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;

#[derive(Debug, PartialEq, Eq)]
pub enum FetchError {
    /// Network or source failure; the `.part` stays for a resume.
    Net(String),
    Io(String),
    /// Stream ended early or ran past the pinned size.
    Size { got: u64, want: u64 },
    /// Pinned hash did not match; the `.part` is deleted.
    Mismatch,
}

impl fmt::Display for FetchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FetchError::Net(s) => write!(f, "network: {s}"),
            FetchError::Io(s) => write!(f, "io: {s}"),
            FetchError::Size { got, want } => write!(f, "size {got} != pinned {want}"),
            FetchError::Mismatch => write!(f, "sha256 mismatch"),
        }
    }
}

fn io(e: std::io::Error) -> FetchError {
    FetchError::Io(e.to_string())
}

pub struct Pin<'a> {
    pub url: &'a str,
    pub sha256: &'a str,
    pub bytes: u64,
}

pub trait Source: Send + Sync {
    /// Open `url` from byte `from`. Returns the reader and the offset it really
    /// starts at (0 when the server ignored the Range header).
    fn open(&self, url: &str, from: u64) -> Result<(Box<dyn Read + Send>, u64), FetchError>;
}

pub struct HttpSource {
    agent: ureq::Agent,
}

impl HttpSource {
    pub fn new() -> Result<Self, FetchError> {
        let tls = native_tls::TlsConnector::new().map_err(|e| FetchError::Net(e.to_string()))?;
        let agent = ureq::AgentBuilder::new().tls_connector(Arc::new(tls)).build();
        Ok(HttpSource { agent })
    }
}

impl Source for HttpSource {
    fn open(&self, url: &str, from: u64) -> Result<(Box<dyn Read + Send>, u64), FetchError> {
        let mut req = self.agent.get(url);
        if from > 0 {
            req = req.set("Range", &format!("bytes={from}-"));
        }
        let resp = req.call().map_err(|e| FetchError::Net(e.to_string()))?;
        let start = if resp.status() == 206 { from } else { 0 };
        Ok((Box::new(resp.into_reader()), start))
    }
}

pub fn part_path(dest: &Path) -> PathBuf {
    let mut name = dest.file_name().map(|n| n.to_os_string()).unwrap_or_default();
    name.push(".part");
    dest.with_file_name(name)
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn sha256_bytes(b: &[u8]) -> String {
    hex(&Sha256::digest(b))
}

pub fn sha256_file(p: &Path) -> std::io::Result<String> {
    let mut h = Sha256::new();
    feed(&mut File::open(p)?, &mut h)?;
    Ok(hex(&h.finalize()))
}

fn feed(r: &mut dyn Read, h: &mut Sha256) -> std::io::Result<u64> {
    let mut buf = vec![0u8; 64 * 1024];
    let mut n = 0u64;
    loop {
        let k = r.read(&mut buf)?;
        if k == 0 {
            return Ok(n);
        }
        h.update(&buf[..k]);
        n += k as u64;
    }
}

/// Fetch `pin` to `dest` (a no-op when `dest` exists). `progress(done, total)`
/// is called as bytes land.
pub fn get_pinned(
    src: &dyn Source,
    pin: &Pin,
    dest: &Path,
    progress: &mut dyn FnMut(u64, u64),
) -> Result<(), FetchError> {
    if dest.exists() {
        return Ok(());
    }
    let part = part_path(dest);
    let mut have = fs::metadata(&part).map_or(0, |m| m.len());
    if have > pin.bytes {
        let _ = fs::remove_file(&part);
        have = 0;
    }
    let mut hasher = Sha256::new();
    if have > 0 {
        feed(&mut File::open(&part).map_err(io)?, &mut hasher).map_err(io)?;
    }
    if have < pin.bytes {
        let (mut r, start) = src.open(pin.url, have)?;
        let mut f = if start == have {
            OpenOptions::new().append(true).create(true).open(&part).map_err(io)?
        } else {
            // The server restarted from 0: drop what we had.
            hasher = Sha256::new();
            have = 0;
            File::create(&part).map_err(io)?
        };
        let mut buf = vec![0u8; 64 * 1024];
        loop {
            let k = r.read(&mut buf).map_err(|e| FetchError::Net(e.to_string()))?;
            if k == 0 {
                break;
            }
            if have + k as u64 > pin.bytes {
                let _ = fs::remove_file(&part);
                return Err(FetchError::Size { got: have + k as u64, want: pin.bytes });
            }
            f.write_all(&buf[..k]).map_err(io)?;
            hasher.update(&buf[..k]);
            have += k as u64;
            progress(have, pin.bytes);
        }
        f.flush().map_err(io)?;
    }
    if have != pin.bytes {
        return Err(FetchError::Size { got: have, want: pin.bytes });
    }
    if !hex(&hasher.finalize()).eq_ignore_ascii_case(pin.sha256) {
        let _ = fs::remove_file(&part);
        return Err(FetchError::Mismatch);
    }
    fs::rename(&part, dest).map_err(io)
}

/// Unpack `zip_path` into `out`. An entry that would land outside `out`
/// (`..`, a root, a drive) refuses the whole archive, as in [unpack_targz].
pub fn unpack_zip(zip_path: &Path, out: &Path) -> Result<(), String> {
    let mut ar = zip::ZipArchive::new(File::open(zip_path).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    fs::create_dir_all(out).map_err(|e| e.to_string())?;
    for i in 0..ar.len() {
        let mut f = ar.by_index(i).map_err(|e| e.to_string())?;
        let rel = match f.enclosed_name() {
            Some(p) => safe_rel(&p)?,
            None => return Err(format!("unsafe path in archive: {}", f.name())),
        };
        if rel.as_os_str().is_empty() {
            continue;
        }
        let target = out.join(rel);
        if f.is_dir() {
            fs::create_dir_all(&target).map_err(|e| e.to_string())?;
        } else {
            if let Some(p) = target.parent() {
                fs::create_dir_all(p).map_err(|e| e.to_string())?;
            }
            let mut o = File::create(&target).map_err(|e| e.to_string())?;
            std::io::copy(&mut f, &mut o).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

fn es(e: impl fmt::Display) -> String {
    e.to_string()
}

/// An archive entry path as a plain relative path: `Normal` parts only
/// (`.` is dropped). A `..`, a root or a drive prefix refuses the archive.
fn safe_rel(p: &Path) -> Result<PathBuf, String> {
    use std::path::Component;
    let mut rel = PathBuf::new();
    for c in p.components() {
        match c {
            Component::Normal(n) => rel.push(n),
            Component::CurDir => {}
            _ => return Err(format!("unsafe path in archive: {}", p.display())),
        }
    }
    Ok(rel)
}

/// Unpack the `.tar.gz` at `tar_path` into `out`. Same rule as the zip path:
/// nothing may land outside `out`, and an entry that tries to is an error.
/// Symlinks are kept only when relative with no `..` (so they point at or
/// below their own folder, and no chain of them can climb out); hard links
/// are copies of a file already unpacked; other entry kinds are skipped.
pub fn unpack_targz(tar_path: &Path, out: &Path) -> Result<(), String> {
    let gz = flate2::read::GzDecoder::new(File::open(tar_path).map_err(es)?);
    let mut ar = tar::Archive::new(gz);
    fs::create_dir_all(out).map_err(es)?;
    for entry in ar.entries().map_err(es)? {
        let mut e = entry.map_err(es)?;
        let rel = safe_rel(&e.path().map_err(es)?)?;
        if rel.as_os_str().is_empty() {
            continue;
        }
        let target = out.join(&rel);
        let kind = e.header().entry_type();
        if kind.is_dir() {
            fs::create_dir_all(&target).map_err(es)?;
        } else if kind.is_file() {
            if let Some(p) = target.parent() {
                fs::create_dir_all(p).map_err(es)?;
            }
            let mut o = File::create(&target).map_err(es)?;
            std::io::copy(&mut e, &mut o).map_err(es)?;
            drop(o);
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if let Ok(mode) = e.header().mode() {
                    let _ = fs::set_permissions(&target, fs::Permissions::from_mode(mode & 0o777));
                }
            }
        } else if kind.is_symlink() {
            let link = e.link_name().map_err(es)?.ok_or("symlink without a target")?.into_owned();
            let inside = link.components().all(|c| matches!(c, std::path::Component::Normal(_) | std::path::Component::CurDir));
            if !inside || link.as_os_str().is_empty() {
                return Err(format!("unsafe symlink in archive: {} -> {}", rel.display(), link.display()));
            }
            if let Some(p) = target.parent() {
                fs::create_dir_all(p).map_err(es)?;
            }
            #[cfg(unix)]
            {
                let _ = fs::remove_file(&target);
                std::os::unix::fs::symlink(&link, &target).map_err(es)?;
            }
        } else if kind.is_hard_link() {
            let from = safe_rel(&e.link_name().map_err(es)?.ok_or("hard link without a target")?)?;
            if let Some(p) = target.parent() {
                fs::create_dir_all(p).map_err(es)?;
            }
            fs::copy(out.join(from), &target).map_err(es)?;
        }
    }
    Ok(())
}

fn server_exe() -> &'static str {
    if cfg!(windows) {
        "llama-server.exe"
    } else {
        "llama-server"
    }
}

/// The shallowest `llama-server(.exe)` file under `dir` (searched four levels
/// deep, symlinks not followed).
fn find_server_exe(dir: &Path) -> Option<PathBuf> {
    let mut level = vec![dir.to_path_buf()];
    for _ in 0..4 {
        let mut next = Vec::new();
        for d in &level {
            let mut subs = Vec::new();
            for e in fs::read_dir(d).ok()?.flatten() {
                let Ok(t) = e.file_type() else { continue };
                if t.is_file() && e.file_name() == server_exe() {
                    return Some(e.path());
                }
                if t.is_dir() {
                    subs.push(e.path());
                }
            }
            subs.sort();
            next.extend(subs);
        }
        level = next;
    }
    None
}

/// Unpack a pinned llama-server archive into `out`, the format chosen by the
/// URL suffix (`.zip`, `.tar.gz`, `.tgz`), then leave `llama-server(.exe)` and
/// the files beside it directly in `out`: a release that nests them under a
/// folder is flattened. No such file in the archive is an error.
pub fn unpack_server(archive: &Path, url: &str, out: &Path) -> Result<(), String> {
    let path = url.split(['?', '#']).next().unwrap_or(url).to_ascii_lowercase();
    if path.ends_with(".zip") {
        unpack_zip(archive, out)?;
    } else if path.ends_with(".tar.gz") || path.ends_with(".tgz") {
        unpack_targz(archive, out)?;
    } else {
        return Err(format!("server archive is neither .zip nor .tar.gz: {url}"));
    }
    let exe = find_server_exe(out).ok_or_else(|| format!("{} is not in the server archive", server_exe()))?;
    let home = exe.parent().expect("exe has a parent").to_path_buf();
    if home != out {
        // Lift the exe's folder out of its wrapper; the wrapper goes. A scratch
        // name keeps a moved file from colliding with the folder it came from.
        let top = out.join(home.strip_prefix(out).expect("under out").components().next().expect("one part"));
        let lift = out.join(".lifted");
        let _ = fs::remove_dir_all(&lift);
        fs::rename(&home, &lift).map_err(es)?;
        if top.exists() {
            fs::remove_dir_all(&top).map_err(es)?;
        }
        for e in fs::read_dir(&lift).map_err(es)?.flatten() {
            let to = out.join(e.file_name());
            let _ = fs::remove_file(&to);
            fs::rename(e.path(), &to).map_err(es)?;
        }
        fs::remove_dir_all(&lift).map_err(es)?;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(out.join(server_exe()), fs::Permissions::from_mode(0o755)).map_err(es)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::{tmpdir, BytesSource};

    fn data() -> Vec<u8> {
        (0..200_000u32).map(|i| (i % 251) as u8).collect()
    }

    #[test]
    fn sha256_known_vector() {
        assert_eq!(sha256_bytes(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }

    #[test]
    fn fresh_download_verifies_and_renames() {
        let d = tmpdir("dl-fresh");
        let bytes = data();
        let src = BytesSource::new(bytes.clone(), true);
        let sha = sha256_bytes(&bytes);
        let pin = Pin { url: "mem://x", sha256: &sha, bytes: bytes.len() as u64 };
        let dest = d.join("m.gguf");
        let mut last = (0, 0);
        get_pinned(&src, &pin, &dest, &mut |a, b| last = (a, b)).unwrap();
        assert_eq!(fs::read(&dest).unwrap(), bytes);
        assert!(!part_path(&dest).exists());
        assert_eq!(last, (bytes.len() as u64, bytes.len() as u64));
        assert_eq!(sha256_file(&dest).unwrap(), sha);
    }

    #[test]
    fn resumes_a_part_with_range() {
        let d = tmpdir("dl-resume");
        let bytes = data();
        let sha = sha256_bytes(&bytes);
        let dest = d.join("m.gguf");
        fs::write(part_path(&dest), &bytes[..70_000]).unwrap();
        let src = BytesSource::new(bytes.clone(), true);
        let pin = Pin { url: "mem://x", sha256: &sha, bytes: bytes.len() as u64 };
        get_pinned(&src, &pin, &dest, &mut |_, _| {}).unwrap();
        assert_eq!(src.opened_from(), vec![70_000], "asked only for the missing tail");
        assert_eq!(fs::read(&dest).unwrap(), bytes);
    }

    #[test]
    fn server_ignoring_range_restarts_from_zero() {
        let d = tmpdir("dl-norange");
        let bytes = data();
        let sha = sha256_bytes(&bytes);
        let dest = d.join("m.gguf");
        fs::write(part_path(&dest), &bytes[..70_000]).unwrap();
        let src = BytesSource::new(bytes.clone(), false);
        let pin = Pin { url: "mem://x", sha256: &sha, bytes: bytes.len() as u64 };
        get_pinned(&src, &pin, &dest, &mut |_, _| {}).unwrap();
        assert_eq!(fs::read(&dest).unwrap(), bytes);
    }

    #[test]
    fn hash_mismatch_deletes_the_part() {
        let d = tmpdir("dl-bad");
        let bytes = data();
        let src = BytesSource::new(bytes.clone(), true);
        let pin = Pin { url: "mem://x", sha256: &"0".repeat(64), bytes: bytes.len() as u64 };
        let dest = d.join("m.gguf");
        assert_eq!(get_pinned(&src, &pin, &dest, &mut |_, _| {}), Err(FetchError::Mismatch));
        assert!(!dest.exists() && !part_path(&dest).exists());
    }

    #[test]
    fn short_stream_keeps_the_part_for_resume() {
        let d = tmpdir("dl-short");
        let bytes = data();
        let src = BytesSource::new(bytes[..50_000].to_vec(), true);
        let sha = sha256_bytes(&bytes);
        let pin = Pin { url: "mem://x", sha256: &sha, bytes: bytes.len() as u64 };
        let dest = d.join("m.gguf");
        let e = get_pinned(&src, &pin, &dest, &mut |_, _| {}).unwrap_err();
        assert_eq!(e, FetchError::Size { got: 50_000, want: bytes.len() as u64 });
        assert_eq!(fs::metadata(part_path(&dest)).unwrap().len(), 50_000);
    }

    fn write_zip(p: &Path, entries: &[(&str, &[u8])]) {
        use std::io::Write as _;
        let mut w = zip::ZipWriter::new(File::create(p).unwrap());
        let o = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
        for (name, body) in entries {
            w.start_file(*name, o).unwrap();
            w.write_all(body).unwrap();
        }
        w.finish().unwrap();
    }

    #[test]
    fn unpack_zip_keeps_folders_and_refuses_zip_slip() {
        let d = tmpdir("zip");
        let zp = d.join("s.zip");
        write_zip(&zp, &[("llama-server.exe", b"MZ"), ("sub/a.dll", b"dll")]);
        let out = d.join("server");
        unpack_zip(&zp, &out).unwrap();
        assert_eq!(fs::read(out.join("llama-server.exe")).unwrap(), b"MZ");
        assert_eq!(fs::read(out.join("sub").join("a.dll")).unwrap(), b"dll");
        let mut bads = vec!["../evil.txt", "a/../../evil.txt", "a/../evil.txt", "/abs-evil.txt"];
        if cfg!(windows) {
            bads.push("C:/evil.txt");
        }
        for (i, bad) in bads.iter().enumerate() {
            let d = tmpdir(&format!("zip-slip{i}"));
            let zp = d.join("s.zip");
            write_zip(&zp, &[("llama-server.exe", b"MZ"), (bad, b"bad")]);
            let e = unpack_zip(&zp, &d.join("server")).unwrap_err();
            assert!(e.contains("unsafe path"), "{bad}: {e}");
            assert!(!d.join("evil.txt").exists() && !Path::new("/abs-evil.txt").exists(), "{bad}");
            assert!(unpack_server(&zp, "https://x/s.zip", &d.join("server2")).is_err(), "{bad}");
        }
    }

    /// A `.tar.gz` at `p`. Names go into the header raw, so `..` and absolute
    /// paths can be written (the builder's own `set_path` would refuse them).
    fn write_targz(p: &Path, entries: &[(&str, tar::EntryType, &[u8], &str)]) {
        let gz = flate2::write::GzEncoder::new(File::create(p).unwrap(), flate2::Compression::fast());
        let mut b = tar::Builder::new(gz);
        for (name, kind, body, link) in entries {
            let mut h = tar::Header::new_gnu();
            h.as_old_mut().name[..name.len()].copy_from_slice(name.as_bytes());
            h.set_entry_type(*kind);
            h.set_mode(0o644);
            h.set_size(body.len() as u64);
            if !link.is_empty() {
                h.set_link_name(link).unwrap();
            }
            h.set_cksum();
            b.append(&h, *body).unwrap();
        }
        b.into_inner().unwrap().finish().unwrap();
    }

    #[test]
    fn targz_unpacks_and_the_server_is_found_flattened() {
        use tar::EntryType::{Directory, Regular};
        let d = tmpdir("targz");
        let tgz = d.join("s.tar.gz");
        let exe = format!("llama-b1/bin/{}", server_exe());
        let mut entries: Vec<(&str, tar::EntryType, &[u8], &str)> = vec![
            ("llama-b1/", Directory, &b""[..], ""),
            ("llama-b1/bin/", Directory, &b""[..], ""),
            (exe.as_str(), Regular, b"ELF", ""),
            ("llama-b1/bin/libggml.so.1", Regular, b"lib", ""),
            ("llama-b1/LICENSE", Regular, b"mit", ""),
        ];
        entries.push(("llama-b1/bin/libggml.so", tar::EntryType::Symlink, b"", "libggml.so.1"));
        write_targz(&tgz, &entries);
        let out = d.join("server");
        unpack_server(&tgz, "https://x/llama-b1-bin-ubuntu-x64.tar.gz", &out).unwrap();
        assert_eq!(fs::read(out.join(server_exe())).unwrap(), b"ELF");
        assert_eq!(fs::read(out.join("libggml.so.1")).unwrap(), b"lib");
        assert!(!out.join("llama-b1").exists(), "the wrapper folder is gone");
        assert!(!out.join(".lifted").exists());
        #[cfg(unix)]
        {
            assert_eq!(fs::read_link(out.join("libggml.so")).unwrap(), Path::new("libggml.so.1"));
            assert_eq!(fs::read(out.join("libggml.so")).unwrap(), b"lib");
        }
    }

    #[test]
    fn targz_refuses_entries_that_escape() {
        use tar::EntryType::{Regular, Symlink};
        let cases: [(&str, tar::EntryType, &str); 4] = [
            ("../evil.txt", Regular, ""),
            ("a/../../evil.txt", Regular, ""),
            ("/abs-evil.txt", Regular, ""),
            ("link", Symlink, "../outside"),
        ];
        for (i, (name, kind, link)) in cases.iter().enumerate() {
            let d = tmpdir(&format!("targz-slip{i}"));
            let tgz = d.join("s.tar.gz");
            write_targz(&tgz, &[(server_exe(), Regular, b"ok", ""), (name, *kind, b"bad", link)]);
            let out = d.join("server");
            let e = unpack_targz(&tgz, &out).unwrap_err();
            assert!(e.contains("unsafe"), "{name}: {e}");
            assert!(!d.join("evil.txt").exists() && !out.join("evil.txt").exists(), "{name}");
            assert!(unpack_server(&tgz, "https://x/s.tar.gz", &out).is_err(), "{name}");
        }
        let d = tmpdir("targz-slip-abs-link");
        let tgz = d.join("s.tar.gz");
        write_targz(&tgz, &[("link", Symlink, b"", "/etc/passwd")]);
        assert!(unpack_targz(&tgz, &d.join("server")).unwrap_err().contains("unsafe symlink"));
    }

    #[test]
    fn a_nested_zip_is_flattened_and_the_server_found() {
        use std::io::Write as _;
        let d = tmpdir("zip-nested");
        let zp = d.join("s.zip");
        {
            let mut w = zip::ZipWriter::new(File::create(&zp).unwrap());
            let o = zip::write::SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
            w.start_file(format!("build/bin/{}", server_exe()), o).unwrap();
            w.write_all(b"MZ").unwrap();
            w.start_file("build/bin/ggml.dll", o).unwrap();
            w.write_all(b"dll").unwrap();
            w.start_file("build/README.txt", o).unwrap();
            w.write_all(b"doc").unwrap();
            w.finish().unwrap();
        }
        let out = d.join("server");
        unpack_server(&zp, "https://x/llama-bin-win-cpu-x64.zip", &out).unwrap();
        assert_eq!(fs::read(out.join(server_exe())).unwrap(), b"MZ");
        assert_eq!(fs::read(out.join("ggml.dll")).unwrap(), b"dll");
        assert!(!out.join("build").exists());
    }

    #[test]
    fn an_archive_without_the_server_fails_with_a_note() {
        use std::io::Write as _;
        let d = tmpdir("zip-noserver");
        let zp = d.join("s.zip");
        {
            let mut w = zip::ZipWriter::new(File::create(&zp).unwrap());
            w.start_file("readme.txt", zip::write::SimpleFileOptions::default()).unwrap();
            w.write_all(b"x").unwrap();
            w.finish().unwrap();
        }
        let e = unpack_server(&zp, "https://x/s.zip", &d.join("server")).unwrap_err();
        assert!(e.contains("is not in the server archive") && e.contains("llama-server"), "{e}");
        let e = unpack_server(&zp, "https://x/s.rar", &d.join("server2")).unwrap_err();
        assert!(e.contains("neither .zip nor .tar.gz"), "{e}");
    }
}
