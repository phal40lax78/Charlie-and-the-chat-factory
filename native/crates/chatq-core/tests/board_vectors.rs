//! native/vectors/board.json (tests/vectors/board.ps1): data/queue.md as
//! [chatq_core::board::text] makes it from a case's job files, prompt files
//! and state.json, written into a data/ of the case's own and read back as
//! chatqd reads them, in a zone of a fixed offset and the culture of the
//! case's `--culture` argument (all chatqd learns of a culture, SPEC 2.11).

mod common;

use chatq_core::board;
use chatq_core::culture::Culture;
use chatq_core::fsx::read_json;
use chatq_core::jobs::get_jobs;
use chatq_core::paths::{NEWLINE, Paths, join};
use chatq_core::time::{Flavour, Zone, parse_stamp_in};
use chrono::FixedOffset;
use serde_json::{Value, json};
use std::fs;
use std::path::Path;

fn zone_of(input: &Value) -> Zone {
    let m = input["utcOffsetMinutes"]
        .as_i64()
        .expect("a case has utcOffsetMinutes");
    Zone::Fixed(FixedOffset::east_opt(m as i32 * 60).expect("an offset"))
}

/// An input's list, empty when the case has none.
fn list<'a>(input: &'a Value, field: &str) -> &'a [Value] {
    input
        .get(field)
        .and_then(Value::as_array)
        .map_or(&[], Vec::as_slice)
}

/// The case's own data/, empty, as tests/vectors/common.ps1's Enter-NvData
/// names it.
fn data_of(name: &str) -> Paths {
    let safe: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || "._-".contains(c) {
                c
            } else {
                '_'
            }
        })
        .collect();
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../target/test-data/board_vectors")
        .join(safe);
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(root.join("data")).expect("a scratch data/");
    Paths::new(root.to_str().expect("a UTF-8 path"))
}

/// A job file from its recipe, as Get-NvBoardJobFile makes it: job n's
/// defaults, then the recipe's other fields over them in order, a null one
/// dropping the field.
fn job_file(recipe: &Value) -> Value {
    let n = recipe["n"].as_i64().expect("a job number");
    let mut job = json!({
        "id": format!("j{n}"), "seq": n, "title": format!("chat {n}"), "provider": "claude",
        "cwd": "code\\app", "rule": "typed", "kind": "prompt", "promptFile": format!("p{n}.md"),
        "mode": "default", "state": "queued", "createdAt": format!("2026-10-14T08:{n:02}:00.0000000Z")
    });
    let fields = job.as_object_mut().expect("an object");
    for (k, v) in recipe.as_object().expect("a recipe") {
        if k == "n" {
            continue;
        }
        if v.is_null() {
            fields.shift_remove(k);
        } else {
            fields.insert(k.clone(), v.clone());
        }
    }
    job
}

/// The board as the answer's lines. PowerShell split its file at its own
/// newline, so the text is compared with those lines joined at this
/// platform's: the same board, CRLF on Windows and LF elsewhere. When they
/// differ, the lines shown are the text split at that newline.
fn lines_of(text: &str, want: &Value) -> Value {
    let joined = want.as_array().map(|w| {
        w.iter()
            .map(|l| l.as_str().unwrap_or_default())
            .collect::<Vec<_>>()
            .join(NEWLINE)
    });
    if joined.as_deref() == Some(text) {
        return want.clone();
    }
    Value::from(text.split(NEWLINE).collect::<Vec<_>>())
}

fn answer(case: &common::Case, fl: Flavour) -> Value {
    let input = &case.input;
    let zone = zone_of(input);
    let p = data_of(&case.name);
    fs::create_dir_all(&p.queue).expect("data/queue");
    for recipe in list(input, "jobs") {
        let n = recipe["n"].as_i64().expect("a job number");
        let file = join(&p.queue, &format!("j{n}.json"));
        fs::write(file, job_file(recipe).to_string()).expect("a job file");
    }
    if let Some(prompts) = input.get("prompts").and_then(Value::as_object) {
        for (name, text) in prompts {
            let text = text.as_str().expect("a prompt's text");
            fs::write(join(&p.queue, name), text).expect("a prompt file");
        }
    }
    let mut runs = Vec::new();
    for fill in list(input, "fills") {
        let unit = fill["unit"].as_str().expect("a fill's unit");
        let times = fill["times"].as_u64().expect("a fill's count");
        let run = unit.repeat(times as usize);
        let file = join(&p.queue, fill["file"].as_str().expect("a fill's file"));
        fs::write(file, &run).expect("a fill");
        runs.push((run, format!("<<{unit}*{times}>>")));
    }
    if let Some(state) = input.get("state") {
        fs::write(p.state(), state.to_string()).expect("state.json");
    }
    let arg = case.expect(fl)["culture"]
        .as_str()
        .expect("the answer's --culture argument");
    let culture = Culture::from_arg(arg).expect("a culture chatqd reads");
    let now = input["now"].as_str().expect("a case's now");
    let now = parse_stamp_in(now, fl, zone).expect("a stamp");
    let jobs = get_jobs(Path::new(&p.queue), fl, zone);
    let blocks = board::blocks(read_json(&p.state(), fl).as_ref(), now, fl, zone);
    let lines = match board::text(&p.queue, &jobs, &blocks, now, fl, zone, &culture) {
        None => Value::Null,
        Some(mut text) => {
            for (run, mark) in &runs {
                text = text.replace(run.as_str(), mark);
            }
            lines_of(&text, &case.expect(fl)["lines"])
        }
    };
    json!({"culture": arg, "lines": lines})
}

#[test]
fn board_as_write_chatqboard_writes_it() {
    let mut r = common::Report::new("board");
    for case in common::load("board") {
        for fl in case.flavours() {
            r.check(&case, fl, &answer(&case, fl));
        }
    }
    r.finish();
}
