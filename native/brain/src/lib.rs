//! chatq-brain: the detachable brain, a classifier behind one localhost
//! contract. The model tasks go to the backend `brain.json` names: Gemini
//! (the default), Claude Haiku, or a local llama-server. See `SPEC.md`.

pub mod anthropic;
pub mod api;
pub mod catalogue;
pub mod config;
pub mod engine;
pub mod fetch;
pub mod gemini;
pub mod llm;
pub mod proc;
pub mod rules;
pub mod schema;
pub mod server;
pub mod supervisor;
pub mod sysinfo;
pub mod usage;
#[doc(hidden)]
pub mod testutil;
