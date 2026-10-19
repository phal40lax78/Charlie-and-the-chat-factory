//! chatqd, the native watcher (SPEC). `chatqd version --root <R>` answers the
//! launcher's preflight; `chatqd watch …` is the watcher; `chatqd vector …`
//! answers the live contract checks (SPEC 6.1).

// no console is ever created or flashed (SPEC 4.1)
#![windows_subsystem = "windows"]
#![deny(unsafe_op_in_unsafe_fn)]

mod seams;
mod sys;
mod vector;
mod watch;

use chatq_core::launch::{TARGET, read_loader_version};
use chatq_core::paths::Paths;
use std::process::ExitCode;

/// The compiled version, which build.rs holds equal to the loader's.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Bad arguments: nothing a launcher builds, so only a person typing.
const USAGE: u8 = 64;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("version") => version(&args[1..]),
        Some("watch") => match watch::Args::parse(&args[1..]) {
            Some(a) => watch::run(a),
            None => ExitCode::from(USAGE),
        },
        Some("vector") => vector::run(&args[1..]),
        _ => ExitCode::from(USAGE),
    }
}

/// SPEC 4.2 preflight: the compiled version, never the one read, so the
/// launcher's comparison catches a mismatch; 2 when the scripts under
/// `--root` say otherwise, 3 when they cannot be read.
fn version(args: &[String]) -> ExitCode {
    let [flag, root] = args else {
        return ExitCode::from(USAGE);
    };
    if flag != "--root" {
        return ExitCode::from(USAGE);
    }
    let head = format!("chatqd {VERSION} {TARGET}");
    match read_loader_version(&Paths::new(root).loader()) {
        Some(v) if v == VERSION => {
            println!("{head}");
            ExitCode::SUCCESS
        }
        Some(v) => {
            println!("{head}: the scripts are {v}");
            ExitCode::from(2)
        }
        None => {
            println!("{head}: the scripts cannot be read");
            ExitCode::from(3)
        }
    }
}
