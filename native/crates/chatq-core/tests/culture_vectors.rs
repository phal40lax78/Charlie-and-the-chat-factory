//! native/vectors/culture.json (SPEC 2.11). A culture's launch case holds the
//! `--culture` argument Get-ChatqWatcherLaunch builds in it, and chatqd learns
//! a culture from that argument alone, so each of the culture's other cases
//! is rendered from what [Culture::from_arg] reads there.

mod common;

use chatq_core::culture::Culture;
use chatq_core::time::Flavour;
use chrono::NaiveTime;
use common::{Case, Report};
use serde_json::{Value, json};
use std::collections::HashMap;

fn strs(v: &Value) -> Vec<&str> {
    v.as_array()
        .map(|a| a.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default()
}

/// What `c` renders for a clock, N0 or lanes case.
fn render(c: &Culture, case: &Case, fl: Flavour) -> Result<Value, String> {
    let i = &case.input;
    match i["what"].as_str() {
        Some("clock") => {
            // HH:mm:ss, maybe .fffffff
            let ts = strs(&i["times"])
                .into_iter()
                .map(|s| {
                    NaiveTime::parse_from_str(s, "%H:%M:%S%.f").map_err(|e| format!("'{s}': {e}"))
                })
                .collect::<Result<Vec<_>, _>>()?;
            Ok(json!({
                "hhmm": ts.iter().map(|t| c.hh_mm(t)).collect::<Vec<_>>(),
                "hhmmss": ts.iter().map(|t| c.hh_mm_ss(t)).collect::<Vec<_>>(),
            }))
        }
        Some("n0") => {
            let ns = i["counts"]
                .as_array()
                .and_then(|a| a.iter().map(Value::as_u64).collect::<Option<Vec<_>>>())
                .ok_or("counts are not counts")?;
            Ok(json!({"n0": ns.iter().map(|&n| c.n0(n)).collect::<Vec<_>>()}))
        }
        Some("lanes") => {
            let lanes: Vec<Value> = strs(&i["lanes"])
                .into_iter()
                .map(|l| {
                    json!({
                        "lane": l,
                        "name": c.lane_name(l, fl),
                        "provider": c.provider_name(l, fl),
                    })
                })
                .collect();
            Ok(json!({ "lanes": lanes }))
        }
        w => Err(format!("no part {w:?}")),
    }
}

#[test]
fn each_culture_renders_from_its_launch_argument() {
    let cases = common::load("culture");
    let mut report = Report::new("culture.json");
    for fl in [Flavour::Desktop, Flavour::Core] {
        let mut cultures: HashMap<&str, Culture> = HashMap::new();
        for case in cases.iter().filter(|c| c.input["what"] == "launch") {
            let arg = case.expect(fl)["arg"].as_str().unwrap_or_default();
            let Some(c) = Culture::from_arg(arg) else {
                report.fail(case, fl, format!("--culture {arg} does not decode"));
                continue;
            };
            let carries = json!({
                "name": &c.name,
                "timeSep": &c.time_sep,
                "groupSep": &c.group_sep,
                "groupSizes": &c.group_sizes,
            });
            report.check(case, fl, &json!({"arg": arg, "carries": carries}));
            cultures.insert(case.input["culture"].as_str().unwrap_or_default(), c);
        }
        for case in cases.iter().filter(|c| c.input["what"] != "launch") {
            let name = case.input["culture"].as_str().unwrap_or_default();
            let Some(c) = cultures.get(name) else {
                report.fail(case, fl, format!("no launch case for '{name}'"));
                continue;
            };
            match render(c, case, fl) {
                Ok(got) => report.check(case, fl, &got),
                Err(why) => report.fail(case, fl, why),
            }
        }
    }
    report.finish();
}
