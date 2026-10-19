//! `chatqd vector <name> …`: the contract checks no static file can hold
//! (SPEC 6.1), which tests/vectors/live.ps1 runs against a real build. Each
//! prints its answer on stdout. Anything else is a person typing: USAGE.

use chatq_core::{secret, time};
use std::io::Write;
use std::process::ExitCode;

/// `dpapi <hex>`, as [Unprotect-ChatqSecret](src/alerts.ps1) opens
/// `{value: <hex>, protected: true}`; `local-stamps --ps <exe> <stamp>…`, as
/// [ConvertTo-ChatqDate](src/queue.ps1) reads each stamp and
/// `(Get-Date).ToString('o')` renders the instant on this PC.
pub fn run(args: &[String]) -> ExitCode {
    match args {
        [name, hex] if name == "dpapi" => dpapi(hex),
        [name, flag, ps, stamps @ ..] if name == "local-stamps" && flag == "--ps" => {
            local_stamps(ps, stamps)
        }
        _ => ExitCode::from(crate::USAGE),
    }
}

/// Exit 0 with the text as UTF-8 on stdout and nothing after it, '' being
/// no bytes; exit 1 and nothing where PowerShell gives $null.
fn dpapi(hex: &str) -> ExitCode {
    let sealed = serde_json::json!({ "value": hex, "protected": true });
    match secret::unprotect(Some(&sealed)) {
        Some(text) => emit(text.as_bytes()),
        None => ExitCode::FAILURE,
    }
}

/// One line per stamp, LF-ended: the instant ConvertTo-ChatqDate makes of it
/// as JSON hands it over, under the PowerShell `--ps` names (whose ConvertFrom-Json
/// decides a stamp with no zone), in this PC's zone; an empty line where it
/// gives $null. Exit 0.
fn local_stamps(ps: &str, stamps: &[String]) -> ExitCode {
    let flavour = time::Flavour::from_exe(ps);
    let mut out = String::new();
    for s in stamps {
        if let Some(t) = time::parse_stamp(s, flavour) {
            out.push_str(&time::stamp_local(t));
        }
        out.push('\n');
    }
    emit(out.as_bytes())
}

/// The answer, whole; exit 1 if stdout will not take it.
fn emit(bytes: &[u8]) -> ExitCode {
    let mut out = std::io::stdout().lock();
    match out.write_all(bytes).and_then(|()| out.flush()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(_) => ExitCode::FAILURE,
    }
}
