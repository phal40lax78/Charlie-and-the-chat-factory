//! Wire types of the contract (SPEC.md section 2).

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Contract version, in every answer.
pub const CONTRACT: u32 = 1;

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct Turn {
    pub role: String,
    pub text: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub struct Tail {
    #[serde(default)]
    pub chat: Option<String>,
    #[serde(default)]
    pub turns: Vec<Turn>,
    #[serde(default)]
    pub tool_out: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ClassifyReq {
    pub task: String,
    pub schema_id: String,
    #[serde(default)]
    pub transcript_tail: Tail,
}

/// `POST /install` (local backend): a catalogue model id.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct InstallReq {
    pub model: String,
}

/// A 200 from `/classify`. `tier` is "model" (model-tier tasks always, and a
/// `fail_kind` escalation) or "regex" (the regex-tier tasks). A model-tier task
/// the backend does not answer gets no `Answer` at all: 503, see
/// [engine::Unavailable](crate::engine::Unavailable).
#[derive(Debug, Clone, Serialize)]
pub struct Answer {
    pub contract: u32,
    pub labels: Value,
    pub confidence: f64,
    pub tier: &'static str,
    pub why: String,
}
