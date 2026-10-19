//! native/vectors/idle.json: Get-ChatqIdleSeconds on macOS over
//! `ioreg -c IOHIDSystem` outputs ([idle::idle_seconds]), under both
//! flavours. An answer is the seconds' IEEE-754 bits as 16 hex digits, or
//! null.

mod common;

use chatq_core::idle;
use serde_json::{Value, json};

#[test]
fn idle_seconds_as_powershell_reads_them() {
    let mut report = common::Report::new("idle.json");
    for case in common::load("idle") {
        let out = case.input["out"].as_str().unwrap();
        for fl in case.flavours() {
            let got = match idle::idle_seconds(out, fl) {
                Some(s) => json!(format!("{:016x}", s.to_bits())),
                None => Value::Null,
            };
            report.check(&case, fl, &got);
        }
    }
    report.finish();
}
