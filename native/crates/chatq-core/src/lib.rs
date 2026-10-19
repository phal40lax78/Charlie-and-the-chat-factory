//! The contracts chatqd shares with the PowerShell side (SPEC section 2):
//! every file in data/ is read and written here as the PS owner reads and
//! writes it, so both engines can run against the same folder.
//!
//! M1 holds every contract of SPEC 3.1, each pinned by a file in
//! native/vectors/ that both engines are tested against (SPEC 6.1). chatqd
//! itself still uses only what M0 needs.

#![deny(unsafe_code)]

pub mod argline;
pub mod board;
pub mod config;
pub mod culture;
pub mod fsx;
pub mod gates;
pub mod idle;
pub mod jobs;
pub mod json;
pub mod jsonl;
pub mod launch;
pub mod log;
pub mod paths;
pub mod replystate;
pub mod runenv;
pub mod secret;
pub mod state;
pub mod stream;
pub mod time;
pub mod timers;
pub mod utf8;
pub mod wire;
