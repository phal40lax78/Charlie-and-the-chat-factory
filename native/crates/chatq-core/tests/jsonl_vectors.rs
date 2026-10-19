//! native/vectors/jsonl.json: a run's stdout as Invoke-ChatqProcess reads it
//! (jsonl::LineReader, fed in chunks of every size the case allows), logs it
//! (jsonl::log_line) and hands each line on to be parsed (jsonl::too_long).

mod common;

use chatq_core::json;
use chatq_core::jsonl::{self, LineReader};
use chatq_core::paths::NEWLINE;
use chatq_core::time::Flavour;
use common::{Report, hex, load};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

fn to_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn sha256(bytes: &[u8]) -> String {
    to_hex(&Sha256::digest(bytes))
}

/// The case's stdout: hex, or pre + head + fill x count + tail + post.
fn stdout(input: &Value) -> Vec<u8> {
    let s = |v: &Value, k: &str| -> String {
        v[k].as_str()
            .unwrap_or_else(|| panic!("no {k} in {v}"))
            .to_string()
    };
    if input.get("hex").is_some() {
        return hex(&s(input, "hex"));
    }
    let l = &input["line"];
    let count = l["count"].as_u64().expect("a count") as usize;
    let mut b = hex(&s(input, "pre"));
    b.extend_from_slice((s(l, "head") + &s(l, "fill").repeat(count) + &s(l, "tail")).as_bytes());
    b.extend(hex(&s(input, "post")));
    b
}

fn read(bytes: &[u8], fl: Flavour, chunk: usize) -> Vec<String> {
    let mut r = LineReader::new(fl);
    let mut lines = Vec::new();
    for c in bytes.chunks(chunk) {
        r.feed(c, &mut lines);
    }
    r.finish(&mut lines);
    lines
}

/// Whether Update-ChatqClaudeState sets Init for the line, for the lines
/// these cases hold: one past the limit is never read; another passes its
/// filter, ConvertFrom-Json reads it, and its type is system, its subtype
/// init.
fn sets_init(line: &str, fl: Flavour) -> bool {
    let filter = line.starts_with("{\"type\":\"assistant\"")
        || line.contains("\"type\":\"result\"")
        || line.contains("\"type\":\"rate_limit_event\"")
        || line.starts_with("{\"type\":\"system\"");
    !jsonl::too_long(line)
        && filter
        && json::parse_tolerant_in(line.as_bytes(), fl)
            .value
            .is_some_and(|o| {
                json::eq_str(json::get(Some(&o), "type"), "system")
                    && json::eq_str(json::get(Some(&o), "subtype"), "init")
            })
}

/// The answer as the PowerShell side shows it: a line past 256 code units,
/// and a log past 512 bytes, by length and SHA-256; the log as on Windows.
fn answer(lines: &[String], fl: Flavour) -> Value {
    let shown: Vec<Value> = lines
        .iter()
        .map(|l| match l.encode_utf16().count() {
            n if n <= 256 => json!(l),
            n => json!({ "units": n, "sha256": sha256(l.as_bytes()) }),
        })
        .collect();
    let mut log: String = lines.iter().map(|l| jsonl::log_line(l)).collect();
    if NEWLINE != "\r\n" {
        // a line holds no CR or LF: every LF is a line's end
        log = log.replace('\n', "\r\n");
    }
    let log = log.into_bytes();
    let log = if log.len() <= 512 {
        json!(to_hex(&log))
    } else {
        json!({ "length": log.len(), "sha256": sha256(&log) })
    };
    let parsed: Vec<bool> = lines.iter().map(|l| sets_init(l, fl)).collect();
    json!({ "lines": shown, "log": log, "parsed": parsed })
}

#[test]
fn jsonl_vectors() {
    let mut r = Report::new("jsonl.json");
    for case in load("jsonl") {
        let bytes = stdout(&case.input);
        // a pipe hands stdout over in reads of any size
        let chunks: &[usize] = if bytes.len() <= 65_536 {
            &[1, 2, 3, 4096]
        } else {
            &[4096, 65_537]
        };
        for fl in case.flavours() {
            let lines = read(&bytes, fl, bytes.len().max(1));
            for &n in chunks {
                if read(&bytes, fl, n) != lines {
                    r.fail(
                        &case,
                        fl,
                        format!("fed {n} bytes at a time, the lines differ"),
                    );
                }
            }
            r.check_ordered(&case, fl, &answer(&lines, fl));
        }
    }
    r.finish();
}
