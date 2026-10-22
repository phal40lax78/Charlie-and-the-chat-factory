//! Tier 0: the regex layer against `vectors/<task>.json` for the regex-tier tasks
//! (fail_kind, extract), plus catalogue/schema hygiene. The model-tier tasks
//! have no rule and no vector file: no regex stand-in (SPEC.md section 0).

use chatq_brain::api::{Tail, Turn};
use chatq_brain::catalogue::{self, FAIL_KINDS, TASKS};
use chatq_brain::{rules, schema};
use serde_json::Value;
use std::path::Path;

fn load(task: &str) -> Value {
    let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("vectors").join(format!("{task}.json"));
    serde_json::from_str(&std::fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display())))
        .unwrap_or_else(|e| panic!("{}: {e}", p.display()))
}

fn same(want: &Value, got: &Value) -> bool {
    match (want, got) {
        (Value::Number(a), Value::Number(b)) => a.as_f64() == b.as_f64(),
        _ => want == got,
    }
}

#[test]
fn every_regex_task_has_a_vector_file_with_hits_and_misses() {
    for t in TASKS.iter().filter(|t| !t.model_tier) {
        let v = load(t.name);
        assert_eq!(v["task"], t.name);
        let cases = v["cases"].as_array().unwrap();
        assert!(cases.len() >= 5, "{}: only {} cases", t.name, cases.len());
        let pos = cases.iter().filter(|c| c["positive"] == true).count();
        let neg = cases.iter().filter(|c| c["positive"] == false).count();
        assert!(pos >= 2 && neg >= 2, "{}: {pos} positive, {neg} negative", t.name);
    }
}

#[test]
fn vectors_match_the_regex_layer() {
    let mut run = 0;
    for t in TASKS.iter().filter(|t| !t.model_tier) {
        let v = load(t.name);
        let schema_v = t.schema_value();
        for c in v["cases"].as_array().unwrap() {
            let name = format!("{}: {}", t.name, c["name"].as_str().unwrap());
            let tail: Tail = serde_json::from_value(c["input"].clone()).unwrap_or_else(|e| panic!("{name}: {e}"));
            let got = rules::classify(t.name, &tail).unwrap();
            schema::validate(&schema_v, &got.labels).unwrap_or_else(|e| panic!("{name}: labels break the schema: {e}"));
            for (k, want) in c["expect"]["labels"].as_object().unwrap() {
                assert!(same(want, &got.labels[k]), "{name}: labels.{k} want {want} got {}", got.labels[k]);
            }
            if let Some(conf) = c["expect"].get("confidence") {
                assert_eq!(conf.as_f64().unwrap(), got.confidence, "{name}: confidence");
            }
            run += 1;
        }
    }
    assert!(run >= 40, "only {run} vector cases ran");
}

#[test]
fn model_tasks_have_no_rule_and_no_vector_file() {
    for t in TASKS.iter().filter(|t| t.model_tier) {
        let tail = Tail { chat: None, turns: vec![Turn { role: "user".into(), text: "fix it".into() }], tool_out: String::new() };
        assert!(rules::classify(t.name, &tail).is_none(), "{}: no regex stand-in", t.name);
        let p = Path::new(env!("CARGO_MANIFEST_DIR")).join("vectors").join(format!("{}.json", t.name));
        assert!(!p.exists(), "{}: a fallback vector file came back", t.name);
    }
}

#[test]
fn catalogue_ids_and_lookup() {
    assert_eq!(
        catalogue::known_ids(),
        ["fail_kind@1", "scope_drift@1", "contradiction@1", "unread_reply@1", "prompt_quality@1", "extract@1"]
    );
    assert!(catalogue::find("fail_kind", "fail_kind@1").is_ok());
    assert_eq!(catalogue::find("fail_kind", "fail_kind@2").err().unwrap().len(), 6);
    assert!(catalogue::find("fail_kind", "extract@1").is_err(), "task and schema_id must agree");
    assert!(catalogue::find("nope", "nope@1").is_err());
}

#[test]
fn fail_kind_enum_is_the_thirteen_plus_none() {
    let s = catalogue::find("fail_kind", "fail_kind@1").unwrap().schema_value();
    let mut e: Vec<&str> = s["properties"]["kind"]["enum"].as_array().unwrap().iter().map(|x| x.as_str().unwrap()).collect();
    let mut want: Vec<&str> = FAIL_KINDS.to_vec();
    assert_eq!(want.len(), 14);
    e.sort();
    want.sort();
    assert_eq!(e, want);
}

#[test]
fn schemas_are_closed_and_complete_and_prompts_are_short() {
    for t in TASKS.iter() {
        let s = t.schema_value();
        assert_eq!(s["additionalProperties"], false, "{}", t.name);
        let props: Vec<&String> = s["properties"].as_object().unwrap().keys().collect();
        let req: Vec<&str> = s["required"].as_array().unwrap().iter().map(|x| x.as_str().unwrap()).collect();
        assert_eq!(props.len(), req.len(), "{}: every field is required", t.name);
        let words = t.system.split_whitespace().count();
        assert!(words < 80, "{}: system prompt has {words} words", t.name);
        assert!(t.system.starts_with("You classify a coding-chat excerpt. Answer only the JSON."), "{}", t.name);
    }
}

#[test]
fn schema_rejects_off_contract_labels() {
    let s = catalogue::find("fail_kind", "fail_kind@1").unwrap().schema_value();
    let bad = serde_json::json!({"kind": "exploded", "n": null, "file": null, "tool": null, "attempt": null});
    assert!(schema::validate(&s, &bad).is_err());
    let missing = serde_json::json!({"kind": "tests"});
    assert!(schema::validate(&s, &missing).is_err());
}
