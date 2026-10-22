//! `data/brain/` layout (SPEC.md section 4): paths, `brain.json` (backend,
//! per-backend model, the local options), the API keys, the local model
//! catalogue and swap, atomic port/token files, the diagnostics log.

use serde::Deserialize;
use serde_json::Value;
use std::collections::HashMap;
use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

/// The Gemini model asked when `brain.json` names none, thinking `minimal`.
/// Not gemini-3.5-flash-lite: measured 2026-10-22 it answered only 6 of 40
/// calls within [crate::gemini::TIMEOUT_MS]; this one answered 79 of 80, as
/// accurate and cheaper (SPEC.md section 9, Gemini accuracy).
pub const DEFAULT_MODEL: &str = "gemini-3.1-flash-lite";

/// Per-request timeout of the local backend when `brain.json` names none.
/// The bakeoff's 4B models took about 7 s per answer on a CPU.
pub const DEFAULT_LOCAL_TIMEOUT_MS: u64 = 10_000;

/// Which service answers the model tasks: `brain.json` `"backend"`, read
/// once at startup.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    Gemini,
    Anthropic,
    Local,
}

impl Backend {
    pub fn name(self) -> &'static str {
        match self {
            Backend::Gemini => "gemini",
            Backend::Anthropic => "anthropic",
            Backend::Local => "local",
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct Pinned {
    pub url: String,
    pub sha256: String,
    pub bytes: u64,
}

/// One catalogue model: a GGUF pinned to a commit, its size and hash.
#[derive(Debug, Clone, Deserialize)]
pub struct ModelSpec {
    pub id: String,
    pub file: String,
    pub url: String,
    pub sha256: String,
    pub bytes: u64,
    #[serde(default)]
    pub ram_mb: Option<u64>,
    /// Extra llama-server flags this model needs (`["-rea", "off"]` for the
    /// Qwen3 thinking models).
    #[serde(default)]
    pub args: Vec<String>,
}

/// `manifest.json`: the pinned llama-server builds and the GGUF catalogue.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct Manifest {
    #[serde(default)]
    pub default: Option<String>,
    /// Keyed by [server_target], plus `<target>-vulkan` for the GPU build.
    #[serde(default)]
    pub server: HashMap<String, Pinned>,
    #[serde(default)]
    pub models: Vec<ModelSpec>,
}

#[derive(Debug, Clone)]
pub struct Layout {
    pub dir: PathBuf,
}

impl Layout {
    pub fn new(dir: impl Into<PathBuf>) -> Self {
        Layout { dir: dir.into() }
    }
    pub fn port_file(&self) -> PathBuf {
        self.dir.join("port")
    }
    pub fn token_file(&self) -> PathBuf {
        self.dir.join("token")
    }
    pub fn brain_json(&self) -> PathBuf {
        self.dir.join("brain.json")
    }
    /// One line, the Gemini API key, written by the overlay's settings.
    pub fn key_file(&self) -> PathBuf {
        self.dir.join("gemini-key")
    }
    /// One line, the Anthropic API key.
    pub fn anthropic_key_file(&self) -> PathBuf {
        self.dir.join("anthropic-key")
    }
    pub fn usage_file(&self) -> PathBuf {
        self.dir.join("usage.jsonl")
    }
    pub fn log_file(&self) -> PathBuf {
        self.dir.join("brain.log")
    }
    /// Overrides the catalogue built into the exe when present.
    pub fn manifest_file(&self) -> PathBuf {
        self.dir.join("manifest.json")
    }
    /// The unpacked llama-server: `server/` (CPU) or `server-gpu/` (GPU).
    pub fn server_dir(&self, gpu: bool) -> PathBuf {
        self.dir.join(if gpu { "server-gpu" } else { "server" })
    }
    pub fn llama_exe(&self, gpu: bool) -> Option<PathBuf> {
        let p = self.server_dir(gpu).join(server_exe_name());
        p.is_file().then_some(p)
    }
}

pub fn server_exe_name() -> &'static str {
    if cfg!(windows) {
        "llama-server.exe"
    } else {
        "llama-server"
    }
}

/// `brain.json` as JSON, `Null` when missing or unreadable.
fn brain(l: &Layout) -> Value {
    fs::read_to_string(l.brain_json()).ok().and_then(|s| serde_json::from_str(&s).ok()).unwrap_or(Value::Null)
}

fn nonblank(v: &Value) -> Option<String> {
    v.as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

/// `brain.json` `"backend"`: missing (or no file) is gemini, an unknown
/// value is an error that names the three.
pub fn backend(l: &Layout) -> Result<Backend, String> {
    let b = brain(l);
    match b.get("backend") {
        None | Some(Value::Null) => Ok(Backend::Gemini),
        Some(v) => match v.as_str().map(str::trim) {
            Some("gemini") => Ok(Backend::Gemini),
            Some("anthropic") => Ok(Backend::Anthropic),
            Some("local") => Ok(Backend::Local),
            _ => Err(format!("brain.json: unknown backend {v}; use \"gemini\", \"anthropic\" or \"local\"")),
        },
    }
}

/// The model for `backend`: `brain.json` `{<backend>: {model}}`, else the
/// top-level `"model"` when `backend` is the configured one (gemini when
/// none is), else `None`. Read on every call, so a change needs no restart.
fn section_model(l: &Layout, backend: Backend) -> Option<String> {
    let b = brain(l);
    if let Some(m) = nonblank(&b[backend.name()]["model"]) {
        return Some(m);
    }
    let configured = b.get("backend").and_then(Value::as_str).map(str::trim).unwrap_or("gemini");
    (configured == backend.name()).then(|| nonblank(&b["model"])).flatten()
}

/// The Gemini model, else [DEFAULT_MODEL].
pub fn model(l: &Layout) -> String {
    section_model(l, Backend::Gemini).unwrap_or_else(|| DEFAULT_MODEL.to_string())
}

/// The Claude model, else [crate::anthropic::DEFAULT_MODEL].
pub fn anthropic_model(l: &Layout) -> String {
    section_model(l, Backend::Anthropic).unwrap_or_else(|| crate::anthropic::DEFAULT_MODEL.to_string())
}

/// `brain.json` `"local"` options.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LocalOpts {
    /// Use the Vulkan build and offload layers to the GPU (`-ngl`).
    pub gpu: bool,
    /// One `/classify` call's wait for llama-server.
    pub timeout_ms: u64,
}

pub fn local_opts(l: &Layout) -> LocalOpts {
    let b = brain(l);
    let s = &b["local"];
    LocalOpts {
        gpu: s["gpu"].as_bool().unwrap_or(false),
        timeout_ms: s["timeout_ms"].as_u64().filter(|&t| t > 0).unwrap_or(DEFAULT_LOCAL_TIMEOUT_MS),
    }
}

/// One line, trimmed, else the env var named `env` when given. Read on
/// every call. Never logged, never echoed.
fn read_key(file: &Path, env: Option<&str>) -> Option<String> {
    let from_file = fs::read_to_string(file).ok().map(|s| s.trim().to_string());
    from_file
        .filter(|k| !k.is_empty())
        .or_else(|| env.and_then(|n| std::env::var(n).ok()).map(|s| s.trim().to_string()))
        .filter(|k| !k.is_empty())
}

/// The Gemini key: `gemini-key`, else the env var named `env`.
pub fn api_key(l: &Layout, env: Option<&str>) -> Option<String> {
    read_key(&l.key_file(), env)
}

/// The Anthropic key: `anthropic-key`, else the env var named `env`.
pub fn anthropic_key(l: &Layout, env: Option<&str>) -> Option<String> {
    read_key(&l.anthropic_key_file(), env)
}

/// Manifest key of this build's server archive, e.g. `windows-x86_64`.
pub fn server_target() -> String {
    format!("{}-{}", std::env::consts::OS, std::env::consts::ARCH)
}

/// The catalogue built into the exe (`manifest.json` beside `Cargo.toml`).
pub const BUILTIN_MANIFEST: &str = include_str!("../manifest.json");

/// `data/brain/manifest.json` when it parses, else [BUILTIN_MANIFEST].
pub fn load_manifest(l: &Layout) -> Manifest {
    fs::read_to_string(l.manifest_file())
        .ok()
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_else(|| serde_json::from_str(BUILTIN_MANIFEST).expect("built-in manifest.json parses"))
}

/// The local model: `brain.json` `{local: {model}}` (or the top-level
/// `"model"` when the backend is local), else the manifest default, else its
/// first model. An id the catalogue lacks falls to the default.
pub fn pick_model(l: &Layout, m: &Manifest) -> Option<ModelSpec> {
    let wanted = section_model(l, Backend::Local);
    let find = |id: &str| m.models.iter().find(|s| s.id == id);
    wanted
        .as_deref()
        .and_then(find)
        .or_else(|| m.default.as_deref().and_then(find))
        .or_else(|| m.models.first())
        .cloned()
}

/// Make `id` the local model in `brain.json`, keeping every other field.
pub fn set_local_model(l: &Layout, id: &str) -> std::io::Result<()> {
    let mut b = brain(l);
    if !b.is_object() {
        b = serde_json::json!({});
    }
    if !b["local"].is_object() {
        b["local"] = serde_json::json!({});
    }
    b["local"]["model"] = Value::String(id.to_string());
    let text = serde_json::to_string_pretty(&b).map_err(std::io::Error::other)?;
    write_atomic(&l.brain_json(), text.as_bytes())
}

/// One model on disk at a time: delete every `.gguf` and `.gguf.part` except
/// `keep` (and its own `.part`). Returns the names removed.
pub fn swap_models(dir: &Path, keep: &str) -> Vec<String> {
    let keep_part = format!("{keep}.part");
    let mut gone = Vec::new();
    if let Ok(rd) = fs::read_dir(dir) {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_string();
            let is_model = name.ends_with(".gguf") || name.ends_with(".gguf.part");
            if is_model && name != keep && name != keep_part && fs::remove_file(e.path()).is_ok() {
                gone.push(name);
            }
        }
    }
    gone.sort();
    gone
}

/// Write whole through a rename. Unix: mode 0600 (tokens).
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    {
        let mut opts = fs::OpenOptions::new();
        opts.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
        }
        let mut f = opts.open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    fs::rename(&tmp, path)
}

pub fn new_token() -> Result<String, String> {
    let mut b = [0u8; 32];
    getrandom::getrandom(&mut b).map_err(|e| e.to_string())?;
    Ok(b.iter().map(|x| format!("{x:02x}")).collect())
}

/// Append a line to `brain.log`; at 1 MB rotate once to `brain.log.1`.
pub fn diag(l: &Layout, msg: &str) {
    let path = l.log_file();
    if fs::metadata(&path).map_or(false, |m| m.len() >= 1_000_000) {
        let _ = fs::rename(&path, path.with_extension("log.1"));
    }
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(&path) {
        let secs = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        let _ = writeln!(f, "{secs} {msg}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::tmpdir;

    #[test]
    fn model_from_brain_json_else_the_default() {
        let d = tmpdir("model");
        let l = Layout::new(&d);
        assert_eq!(model(&l), DEFAULT_MODEL);
        fs::write(l.brain_json(), r#"{"model":"gemini-x"}"#).unwrap();
        assert_eq!(model(&l), "gemini-x");
        fs::write(l.brain_json(), r#"{"model":""}"#).unwrap();
        assert_eq!(model(&l), DEFAULT_MODEL);
        fs::write(l.brain_json(), "not json").unwrap();
        assert_eq!(model(&l), DEFAULT_MODEL);
    }

    #[test]
    fn backend_defaults_to_gemini_and_an_unknown_one_is_an_error() {
        let d = tmpdir("backend");
        let l = Layout::new(&d);
        assert_eq!(backend(&l), Ok(Backend::Gemini), "no brain.json");
        for (text, want) in [
            (r#"{"model":"gemini-x"}"#, Backend::Gemini),
            (r#"{"backend":"gemini"}"#, Backend::Gemini),
            (r#"{"backend":"anthropic"}"#, Backend::Anthropic),
            (r#"{"backend":" local "}"#, Backend::Local),
            (r#"{"backend":null}"#, Backend::Gemini),
        ] {
            fs::write(l.brain_json(), text).unwrap();
            assert_eq!(backend(&l), Ok(want), "{text}");
        }
        for text in [r#"{"backend":"openai"}"#, r#"{"backend":3}"#, r#"{"backend":""}"#] {
            fs::write(l.brain_json(), text).unwrap();
            let e = backend(&l).unwrap_err();
            assert!(e.contains("unknown backend") && e.contains("\"local\""), "{text}: {e}");
        }
    }

    #[test]
    fn the_section_model_wins_and_the_top_level_one_belongs_to_the_chosen_backend() {
        let d = tmpdir("section-model");
        let l = Layout::new(&d);
        assert_eq!(anthropic_model(&l), "claude-haiku-4-5-20251001");
        fs::write(l.brain_json(), r#"{"model":"gemini-x"}"#).unwrap();
        assert_eq!((model(&l), anthropic_model(&l)), ("gemini-x".into(), "claude-haiku-4-5-20251001".into()));
        fs::write(l.brain_json(), r#"{"backend":"anthropic","model":"claude-y"}"#).unwrap();
        assert_eq!((model(&l), anthropic_model(&l)), (DEFAULT_MODEL.into(), "claude-y".into()));
        let both = r#"{"backend":"gemini","model":"top","gemini":{"model":"g"},"anthropic":{"model":"a"}}"#;
        fs::write(l.brain_json(), both).unwrap();
        assert_eq!((model(&l), anthropic_model(&l)), ("g".into(), "a".into()));
    }

    #[test]
    fn local_options_default_to_cpu_and_ten_seconds() {
        let d = tmpdir("local-opts");
        let l = Layout::new(&d);
        assert_eq!(local_opts(&l), LocalOpts { gpu: false, timeout_ms: DEFAULT_LOCAL_TIMEOUT_MS });
        fs::write(l.brain_json(), r#"{"backend":"local","local":{"gpu":true,"timeout_ms":4000}}"#).unwrap();
        assert_eq!(local_opts(&l), LocalOpts { gpu: true, timeout_ms: 4000 });
        fs::write(l.brain_json(), r#"{"local":{"gpu":"yes","timeout_ms":0}}"#).unwrap();
        assert_eq!(local_opts(&l), LocalOpts { gpu: false, timeout_ms: DEFAULT_LOCAL_TIMEOUT_MS });
    }

    #[test]
    fn key_from_the_file_trimmed_and_never_from_an_unset_env() {
        let d = tmpdir("key");
        let l = Layout::new(&d);
        assert_eq!(api_key(&l, None), None);
        assert!(l.key_file().ends_with("gemini-key"));
        fs::write(l.key_file(), "  AIza-test-1\r\n").unwrap();
        assert_eq!(api_key(&l, None).as_deref(), Some("AIza-test-1"));
        fs::write(l.key_file(), "\n").unwrap();
        assert_eq!(api_key(&l, None), None, "a blank file is no key");
        assert_eq!(api_key(&l, Some("CHATQ_BRAIN_TEST_ENV_THAT_IS_NEVER_SET")), None);
    }

    #[test]
    fn each_backend_reads_its_own_key_file() {
        let d = tmpdir("key-anthropic");
        let l = Layout::new(&d);
        fs::write(l.key_file(), "AIza-g").unwrap();
        assert_eq!(anthropic_key(&l, None), None, "not the Gemini key");
        fs::write(l.anthropic_key_file(), " sk-ant-test \n").unwrap();
        assert_eq!(anthropic_key(&l, None).as_deref(), Some("sk-ant-test"));
        assert_eq!(api_key(&l, None).as_deref(), Some("AIza-g"));
    }

    fn spec(id: &str) -> ModelSpec {
        ModelSpec {
            id: id.into(),
            file: format!("{id}.gguf"),
            url: "u".into(),
            sha256: "0".into(),
            bytes: 1,
            ram_mb: None,
            args: vec![],
        }
    }

    #[test]
    fn pick_prefers_brain_json_then_default_then_first() {
        let d = tmpdir("pick");
        let l = Layout::new(&d);
        let m = Manifest { default: Some("1b".into()), models: vec![spec("3b"), spec("1b")], ..Default::default() };
        assert_eq!(pick_model(&l, &m).unwrap().id, "1b");
        fs::write(l.brain_json(), r#"{"local":{"model":"3b"}}"#).unwrap();
        assert_eq!(pick_model(&l, &m).unwrap().id, "3b");
        fs::write(l.brain_json(), r#"{"backend":"local","model":"3b"}"#).unwrap();
        assert_eq!(pick_model(&l, &m).unwrap().id, "3b", "the top-level model of the local backend");
        fs::write(l.brain_json(), r#"{"model":"3b"}"#).unwrap();
        assert_eq!(pick_model(&l, &m).unwrap().id, "1b", "a top-level model of gemini is not a local id");
        fs::write(l.brain_json(), r#"{"local":{"model":"zzz"}}"#).unwrap();
        assert_eq!(pick_model(&l, &m).unwrap().id, "1b", "an unknown id falls to the default");
        let no_default = Manifest { models: vec![spec("3b"), spec("1b")], ..Default::default() };
        assert_eq!(pick_model(&l, &no_default).unwrap().id, "3b");
        assert!(pick_model(&l, &Manifest::default()).is_none());
    }

    #[test]
    fn set_local_model_keeps_the_other_fields() {
        let d = tmpdir("set-local");
        let l = Layout::new(&d);
        set_local_model(&l, "a").unwrap();
        let v: Value = serde_json::from_str(&fs::read_to_string(l.brain_json()).unwrap()).unwrap();
        assert_eq!(v, serde_json::json!({"local": {"model": "a"}}));
        fs::write(l.brain_json(), r#"{"backend":"local","local":{"gpu":true,"model":"a"},"gemini":{"model":"g"}}"#).unwrap();
        set_local_model(&l, "b").unwrap();
        let v: Value = serde_json::from_str(&fs::read_to_string(l.brain_json()).unwrap()).unwrap();
        assert_eq!(
            v,
            serde_json::json!({"backend": "local", "local": {"gpu": true, "model": "b"}, "gemini": {"model": "g"}})
        );
    }

    #[test]
    fn swap_deletes_old_model_and_its_part() {
        let d = tmpdir("swap");
        for f in ["old.gguf", "older.gguf.part", "new.gguf.part", "keep.txt"] {
            fs::write(d.join(f), b"x").unwrap();
        }
        let gone = swap_models(&d, "new.gguf");
        assert_eq!(gone, vec!["old.gguf", "older.gguf.part"]);
        assert!(d.join("new.gguf.part").exists() && d.join("keep.txt").exists());
    }

    #[test]
    fn llama_exe_lives_in_server_or_server_gpu() {
        let d = tmpdir("exe");
        let l = Layout::new(&d);
        assert!(l.llama_exe(false).is_none() && l.llama_exe(true).is_none());
        fs::create_dir_all(d.join("server-gpu")).unwrap();
        fs::write(d.join("server-gpu").join(server_exe_name()), b"").unwrap();
        assert!(l.llama_exe(false).is_none(), "the CPU build is its own folder");
        assert_eq!(l.llama_exe(true).unwrap(), d.join("server-gpu").join(server_exe_name()));
    }

    #[test]
    fn atomic_files_and_token() {
        let d = tmpdir("atomic");
        let p = d.join("port");
        write_atomic(&p, b"123").unwrap();
        write_atomic(&p, b"4567").unwrap();
        assert_eq!(fs::read_to_string(&p).unwrap(), "4567");
        assert!(!d.join("port.tmp").exists());
        let t = new_token().unwrap();
        assert_eq!(t.len(), 64);
        assert_ne!(t, new_token().unwrap());
    }

    #[test]
    fn log_rotates_once() {
        let d = tmpdir("log");
        let l = Layout::new(&d);
        fs::write(l.log_file(), vec![b'x'; 1_000_001]).unwrap();
        diag(&l, "hello");
        assert!(d.join("brain.log.1").exists());
        assert!(fs::read_to_string(l.log_file()).unwrap().contains("hello"));
    }
}
