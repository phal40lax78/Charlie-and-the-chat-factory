//! native/vectors/env.json: [ENV_DROP] and [RUN_ENV] as they stand, a run's
//! [run_delta] and the block [child_env] and [block] make of it over a
//! parent, and that block for a parent and a delta given outright.

mod common;

use chatq_core::runenv::{Cli, ENV_DROP, RUN_ENV, block, child_env, run_delta};
use common::{Report, load};
use serde_json::{Map, Value, json};

fn parent(v: &Value) -> Vec<(String, String)> {
    v.as_object()
        .expect("a parent of names")
        .iter()
        .map(|(k, v)| (k.clone(), v.as_str().expect("a value").to_string()))
        .collect()
}

fn delta_value(d: &[(String, Option<String>)]) -> Value {
    Value::Object(d.iter().map(|(k, v)| (k.clone(), json!(v))).collect())
}

#[test]
fn every_environment_as_powershell_builds_it() {
    let mut r = Report::new("env.json");
    for c in load("env") {
        let i = &c.input;
        for fl in c.flavours() {
            match i["kind"].as_str() {
                Some("drop") => r.check(&c, fl, &json!(ENV_DROP)),
                Some("runEnv") => {
                    let m: Map<String, Value> = RUN_ENV
                        .iter()
                        .map(|(k, v)| (k.to_string(), json!(v)))
                        .collect();
                    r.check_ordered(&c, fl, &Value::Object(m));
                }
                Some("run") => {
                    let cli = match i["cli"].as_str() {
                        Some("claude") => Cli::Claude,
                        Some("codex") => Cli::Codex,
                        other => panic!("'{}': cli {other:?}", c.name),
                    };
                    let p = parent(&i["parent"]);
                    let d = run_delta(cli, i["home"].as_str(), i["bridge"].as_u64(), &p);
                    let env = child_env(&p, &d, fl);
                    let got = json!({"delta": delta_value(&d), "block": block(&env, fl)});
                    r.check(&c, fl, &got);
                }
                Some("block") => {
                    let d: Vec<(String, Option<String>)> = i["setEnv"]
                        .as_object()
                        .expect("a setEnv")
                        .iter()
                        .map(|(k, v)| (k.clone(), v.as_str().map(str::to_string)))
                        .collect();
                    let env = child_env(&parent(&i["parent"]), &d, fl);
                    r.check(&c, fl, &json!({"block": block(&env, fl)}));
                }
                k => panic!("'{}': kind {k:?}", c.name),
            }
        }
    }
    r.finish();
}
