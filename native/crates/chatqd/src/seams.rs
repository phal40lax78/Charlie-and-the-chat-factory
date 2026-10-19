//! CHATQ_NATIVE_SEAMS (SPEC 6.5): a JSON file of test seams. chatqd itself
//! honours `spawn`, `capture` and `panic`; the steps get the file too, and
//! any other name is theirs or a later milestone's.

use chatq_core::fsx::{read_json, save_text};
use chatq_core::json;
use chatq_core::time::Flavour;
use serde_json::Value;
use std::path::PathBuf;

#[derive(Default)]
pub struct Seams {
    /// where launches are recorded instead of started, when `spawn` is on
    pub capture: Option<PathBuf>,
    /// the first pass panics, so the panic strike and handoff are tested
    pub panic: bool,
}

impl Seams {
    pub fn load() -> Seams {
        let Some(path) = std::env::var_os("CHATQ_NATIVE_SEAMS").filter(|p| !p.is_empty()) else {
            return Seams::default();
        };
        // a test's own file, read before any flavour is known
        let Some(v) = read_json(&PathBuf::from(path), Flavour::Core) else {
            return Seams::default();
        };
        let v = Some(&v);
        let capture = json::get(v, "capture")
            .and_then(Value::as_str)
            .filter(|_| json::truthy(json::get(v, "spawn")))
            .map(PathBuf::from);
        let panic = json::truthy(json::get(v, "panic"));
        Seams { capture, panic }
    }

    /// One line per honoured seam, for chatqd.log.
    pub fn honoured(&self) -> Vec<String> {
        let mut out = Vec::new();
        if let Some(c) = &self.capture {
            out.push(format!("seam spawn: launches recorded in {}", c.display()));
        }
        if self.panic {
            out.push("seam panic: the first pass panics".into());
        }
        out
    }

    /// Records a launch as `<capture>/spawn-<n>.json` when the seam is on,
    /// and says whether it did, so the caller starts nothing.
    pub fn capture(&self, record: &Value) -> bool {
        let Some(dir) = &self.capture else {
            return false;
        };
        let n = (1..)
            .find(|n| !dir.join(format!("spawn-{n}.json")).exists())
            .unwrap_or(1);
        let text = serde_json::to_string_pretty(record).unwrap_or_default();
        let _ = save_text(&dir.join(format!("spawn-{n}.json")), &text);
        true
    }
}
