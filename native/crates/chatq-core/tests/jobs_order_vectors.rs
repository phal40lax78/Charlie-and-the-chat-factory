//! native/vectors/jobs-order.json: the queue order of Get-ChatqJobs over a
//! queue folder ([jobs::get_jobs], [jobs::job_files]) and Get-ChatqLane
//! ([jobs::lane]), under both flavours.

mod common;

use chatq_core::jobs;
use chatq_core::json;
use chatq_core::time::Zone;
use chrono::FixedOffset;
use serde_json::{Value, json};
use std::fs;
use std::path::Path;

/// The case's queue folder, as the generator wrote it.
fn make_queue(q: &Path, input: &Value) {
    if input["noQueue"] == true {
        return;
    }
    fs::create_dir_all(q).unwrap();
    for d in input["dirs"].as_array().into_iter().flatten() {
        fs::create_dir_all(q.join(d.as_str().unwrap())).unwrap();
    }
    for f in input["files"].as_array().unwrap() {
        let mut bytes = Vec::new();
        if f["bom"] == true {
            bytes.extend_from_slice(b"\xEF\xBB\xBF");
        }
        bytes.extend_from_slice(f["text"].as_str().unwrap().as_bytes());
        fs::write(q.join(f["name"].as_str().unwrap()), bytes).unwrap();
    }
}

#[test]
fn queue_order_and_lanes_as_powershell_gives_them() {
    let root =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../target/test-data/jobs_order_vectors");
    let _ = fs::remove_dir_all(&root);
    let mut report = common::Report::new("jobs-order.json");
    for (n, case) in common::load("jobs-order").iter().enumerate() {
        let input = &case.input;
        if input["kind"] == "lane" {
            for fl in case.flavours() {
                report.check(case, fl, &json!(jobs::lane(&input["job"])));
            }
            continue;
        }
        let q = root.join(format!("c{n}")).join("queue");
        make_queue(&q, input);
        let mins = input["utcOffsetMinutes"].as_i64().unwrap() as i32;
        let zone = Zone::Fixed(FixedOffset::east_opt(mins * 60).unwrap());
        for fl in case.flavours() {
            let listed: Vec<Value> = jobs::job_files(&q)
                .iter()
                .map(|p| json!(p.file_name().unwrap().to_string_lossy()))
                .collect();
            let order: Vec<Value> = jobs::get_jobs(&q, fl, zone)
                .into_iter()
                .map(|j| {
                    if j.is_object() {
                        json::get(Some(&j), "tag").cloned().unwrap_or(Value::Null)
                    } else {
                        j
                    }
                })
                .collect();
            report.check(case, fl, &json!({"listed": listed, "order": order}));
        }
    }
    report.finish();
}
