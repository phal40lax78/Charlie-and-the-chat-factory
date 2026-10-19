//! native/vectors/log.json: the lines the logs get - [log::add_log_line_in],
//! [log::write_reply_log], [log::add_alert_line] - and the roll past 1 MB,
//! each case run in a logs/ of its own under both flavours.

mod common;

use chatq_core::log;
use chatq_core::time::{Instant, Zone};
use chrono::{DateTime, FixedOffset, Utc};
use serde_json::{Value, json};
use std::fs;
use std::path::Path;

fn instant(s: &Value) -> Instant {
    let s = s.as_str().unwrap_or_else(|| panic!("a stamp, not {s}"));
    DateTime::parse_from_rfc3339(s)
        .unwrap_or_else(|e| panic!("{s}: {e}"))
        .with_timezone(&Utc)
}

/// A `[string]` parameter's value: null is "".
fn text(v: &Value) -> &str {
    v.as_str().unwrap_or("")
}

/// The files in `dir`, in ordinal order; none when it is not there.
fn names(dir: &Path) -> Vec<String> {
    let mut names: Vec<String> = fs::read_dir(dir)
        .into_iter()
        .flatten()
        .map(|e| e.unwrap())
        .filter(|e| e.file_type().unwrap().is_file())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort_by(|a, b| a.encode_utf16().cmp(b.encode_utf16()));
    names
}

fn read(p: &Path) -> String {
    String::from_utf8_lossy(&fs::read(p).unwrap()).into_owned()
}

/// The generator's recipe: `n` bytes, a line feed where i % 100 is 99.
fn recipe(n: u64) -> Vec<u8> {
    (0..n)
        .map(|i| if i % 100 == 99 { b'\n' } else { b'x' })
        .collect()
}

/// A log case: its steps, then every file with its text.
fn steps(dir: &Path, input: &Value, zone: Zone) -> Value {
    for s in input["steps"].as_array().unwrap() {
        let at = instant(&s["at"]);
        match s["act"].as_str().unwrap() {
            "line" => {
                log::add_log_line_in(dir, s["log"].as_str().unwrap(), text(&s["text"]), at, zone)
                    .unwrap()
            }
            "reply" => log::write_reply_log(dir, text(&s["text"]), at, zone),
            "alert" => {
                log::add_alert_line(dir, text(&s["event"]), text(&s["text"]), at, zone).unwrap()
            }
            act => panic!("a step that does '{act}'"),
        }
    }
    let files: Vec<Value> = names(dir)
        .into_iter()
        .map(|n| {
            let t = read(&dir.join(&n));
            json!({"name": n, "text": t})
        })
        .collect();
    json!({ "files": files })
}

/// A roll case: the files laid down, one line, then each file's size and
/// the last line of the one written to.
fn roll(dir: &Path, input: &Value, zone: Zone) -> Value {
    let laid = input["files"].as_array().unwrap();
    if !laid.is_empty() {
        fs::create_dir_all(dir).unwrap();
    }
    for f in laid {
        let bytes = recipe(f["bytes"].as_u64().unwrap());
        fs::write(dir.join(f["name"].as_str().unwrap()), bytes).unwrap();
    }
    let name = input["log"].as_str().unwrap();
    log::add_log_line_in(
        dir,
        name,
        text(&input["text"]),
        instant(&input["now"]),
        zone,
    )
    .unwrap();
    let files: Vec<Value> = names(dir)
        .into_iter()
        .map(|n| {
            let size = fs::metadata(dir.join(&n)).unwrap().len();
            json!({"name": n, "size": size})
        })
        .collect();
    let t = read(&dir.join(name));
    let cut = t.strip_suffix('\n').unwrap_or(&t);
    let start = cut.rfind('\n').map_or(0, |i| i + 1);
    json!({"files": files, "tail": &t[start..]})
}

#[test]
fn log_lines_as_powershell_writes_them() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/test-data/log_vectors");
    let _ = fs::remove_dir_all(&root);
    let mut report = common::Report::new("log.json");
    for (n, case) in common::load("log").iter().enumerate() {
        let input = &case.input;
        let mins = input["utcOffsetMinutes"].as_i64().unwrap() as i32;
        let zone = Zone::Fixed(FixedOffset::east_opt(mins * 60).unwrap());
        for fl in case.flavours() {
            let dir = root
                .join(format!("c{n}-{}", common::edition(fl)))
                .join("logs");
            let got = if input["kind"] == "roll" {
                roll(&dir, input, zone)
            } else {
                steps(&dir, input, zone)
            };
            report.check_ordered(case, fl, &got);
        }
    }
    report.finish();
}
