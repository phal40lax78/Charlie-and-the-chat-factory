//! The two patterns [chatq_core::stream] compiles in, held to the ones
//! src/queue.ps1 assigns (SPEC 6.3): `$script:ChatqLimitRx` and
//! `$script:ChatqOverloadRx`, each a single-quoted string on its own line.

use chatq_core::stream::{LIMIT_RX, OVERLOAD_RX};
use std::fs;
use std::path::Path;

/// The single-quoted string assigned to `$script:<name>` in queue.ps1.
fn assigned(queue: &str, name: &str) -> String {
    let head = format!("$script:{name} = '");
    let lines: Vec<&str> = queue
        .lines()
        .filter(|l| l.trim_start().starts_with(&head))
        .collect();
    assert_eq!(lines.len(), 1, "src/queue.ps1 assigns $script:{name} once");
    let rest = &lines[0].trim_start()[head.len()..];
    // a single-quoted string ends at a lone quote; '' is one quote
    let mut out = String::new();
    let mut chars = rest.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\'' {
            if chars.peek() == Some(&'\'') {
                chars.next();
                out.push('\'');
                continue;
            }
            return out;
        }
        out.push(c);
    }
    panic!("$script:{name} in src/queue.ps1 is not one quoted string");
}

#[test]
fn the_patterns_are_queue_ps1s() {
    let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../src/queue.ps1");
    let queue = fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
    assert_eq!(LIMIT_RX, assigned(&queue, "ChatqLimitRx"));
    assert_eq!(OVERLOAD_RX, assigned(&queue, "ChatqOverloadRx"));
}
