//! native/vectors/stream-state.json, each case's lines fed to
//! [St::update_claude] or [St::update_codex] as tests/vectors/stream-state.ps1
//! fed them to Update-ChatqClaudeState or Update-ChatqCodexState, and
//! [St::to_json] (SPEC 3.8's St) held to the answer, keys in order.

mod common;

use chatq_core::stream::St;
use chatq_core::time::Flavour;
use common::{Report, load};
use serde_json::{Map, Value};

/// A line as a case holds it: a string, or a recipe
/// `{parts: [[text, count], ...], length}`.
fn line_of(v: &Value) -> String {
    if let Some(s) = v.as_str() {
        return s.to_string();
    }
    let parts = v["parts"]
        .as_array()
        .unwrap_or_else(|| panic!("a line, not {v}"));
    let s: String = parts
        .iter()
        .map(|p| {
            let text = p[0].as_str().unwrap_or_else(|| panic!("a part, not {p}"));
            let count = p[1].as_u64().unwrap_or_else(|| panic!("a part, not {p}"));
            text.repeat(usize::try_from(count).expect("a count"))
        })
        .collect();
    let length = v["length"].as_u64().expect("a recipe's length");
    assert_eq!(s.encode_utf16().count() as u64, length, "a recipe's length");
    s
}

/// A stream: one line, or a list of them.
fn stream_of(v: &Value) -> Vec<String> {
    match v {
        Value::Array(a) => a.iter().map(line_of).collect(),
        x => vec![line_of(x)],
    }
}

/// St's JSON, or only `fields` of it in that order.
fn project(st: &St, fields: Option<&[Value]>) -> Value {
    let all = st.to_json();
    let Some(fields) = fields else {
        return all;
    };
    let mut m = Map::new();
    for f in fields {
        let f = f.as_str().expect("a field name");
        let v = all
            .get(f)
            .unwrap_or_else(|| panic!("St has no field '{f}'"));
        m.insert(f.to_string(), v.clone());
    }
    Value::Object(m)
}

/// One stream from a new St: St after it, or with `each` after each line.
fn run(
    provider: &str,
    lines: &[String],
    fl: Flavour,
    fields: Option<&[Value]>,
    each: bool,
) -> Value {
    let mut st = St::new();
    let mut snaps = Vec::new();
    for line in lines {
        if provider == "codex" {
            st.update_codex(line, fl);
        } else {
            st.update_claude(line, fl);
        }
        if each {
            snaps.push(project(&st, fields));
        }
    }
    if each {
        Value::Array(snaps)
    } else {
        project(&st, fields)
    }
}

#[test]
fn every_stream_leaves_st_as_powershell_did() {
    let mut report = Report::new("stream-state.json");
    for case in load("stream-state") {
        let input = &case.input;
        let provider = input["provider"].as_str().expect("a provider");
        let fields = input
            .get("fields")
            .and_then(Value::as_array)
            .map(Vec::as_slice);
        let each = input.get("each").and_then(Value::as_bool).unwrap_or(false);
        let fresh = input.get("fresh").and_then(Value::as_bool).unwrap_or(false);
        for fl in case.flavours() {
            let got = if fresh {
                let items = match &input["lines"] {
                    Value::Array(a) => a.clone(),
                    x => vec![x.clone()],
                };
                let runs = items
                    .iter()
                    .map(|s| run(provider, &stream_of(s), fl, fields, false))
                    .collect();
                Value::Array(runs)
            } else {
                run(provider, &stream_of(&input["lines"]), fl, fields, each)
            };
            report.check_ordered(&case, fl, &got);
        }
    }
    report.finish();
}
