//! Every OS call chatqd makes, and so every `unsafe` block (SPEC 3.1).

#[cfg(unix)]
#[path = "mac.rs"]
mod os;
#[cfg(windows)]
#[path = "win.rs"]
mod os;

pub use os::{Awake, alive, is_chatqd, launch, peek_message};

/// The process's own environment, set before any thread exists (SPEC 4.1).
pub fn set_env(name: &str, value: Option<&str>) {
    // SAFETY: called only at start-up, from the main thread, before chatqd
    // starts any thread that could read the environment meanwhile.
    unsafe {
        match value {
            Some(v) => std::env::set_var(name, v),
            None => std::env::remove_var(name),
        }
    }
}

/// The Windows command line of a launch: the exe always quoted, as .NET
/// quotes it, then [ConvertTo-ChatqArgLine](src/queue.ps1)'s line.
pub fn command_line(exe: &str, args: &[String]) -> String {
    format!("\"{exe}\" {}", chatq_core::argline::arg_line(args))
}

/// How a launch starts: chatqd itself, or a PowerShell (console) watcher.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Native,
    Ps,
}
