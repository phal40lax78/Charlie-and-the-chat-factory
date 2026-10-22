//! The task catalogue (SPEC.md section 3): names, tiers, schemas, system prompts.

use serde_json::Value;

pub struct Task {
    pub name: &'static str,
    pub version: u32,
    /// `true`: a model feature, answered by the model or not at all (503).
    /// `false`: a regex feature, answered by the regex layer (fail_kind may escalate, see engine).
    pub model_tier: bool,
    pub schema: &'static str,
    pub system: &'static str,
}

impl Task {
    pub fn schema_id(&self) -> String {
        format!("{}@{}", self.name, self.version)
    }
    pub fn schema_value(&self) -> Value {
        serde_json::from_str(self.schema).expect("catalogue schema parses")
    }
}

macro_rules! task {
    ($name:literal, $tier:expr) => {
        Task {
            name: $name,
            version: 1,
            model_tier: $tier,
            schema: include_str!(concat!("../schemas/", $name, "@1.json")),
            system: include_str!(concat!("../schemas/", $name, "@1.txt")),
        }
    };
}

pub static TASKS: [Task; 6] = [
    task!("fail_kind", false),
    task!("scope_drift", true),
    task!("contradiction", true),
    task!("unread_reply", true),
    task!("prompt_quality", true),
    task!("extract", false),
];

pub fn known_ids() -> Vec<String> {
    TASKS.iter().map(Task::schema_id).collect()
}

/// `Err(known)` when the task or its schema version is not in this catalogue (409).
pub fn find(task: &str, schema_id: &str) -> Result<&'static Task, Vec<String>> {
    match TASKS.iter().find(|t| t.name == task) {
        Some(t) if t.schema_id() == schema_id => Ok(t),
        _ => Err(known_ids()),
    }
}

/// Fail kinds, in the order of SPEC.md section 3 plus `none`.
pub const FAIL_KINDS: [&str; 14] = [
    "none", "tests", "build", "gaveup", "loop", "revert", "timeout", "merge", "lint", "crash", "scope",
    "permission", "clarify", "missing",
];
