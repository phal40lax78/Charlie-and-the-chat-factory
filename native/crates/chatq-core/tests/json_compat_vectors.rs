//! native/vectors/json-compat.json: files as Read-ChatqJson reads them under
//! each PowerShell - json::parse_tolerant_in, ps_dates_in and ps_return - and,
//! for a file chatqd's writer wrote, that json::to_pretty writes that text.

mod common;

use chatq_core::json;
use chatq_core::time::Flavour;
use chrono::FixedOffset;
use common::{Report, hex, load};
use serde_json::{Value, json};

/// The zone the answers were made in: Korea Standard Time, +09:00 all year.
fn kst() -> FixedOffset {
    FixedOffset::east_opt(9 * 3600).expect("+09:00")
}

/// The file: bytes as hex, or text - plain, or as chatqd writes it - as UTF-8.
fn file(input: &Value) -> Vec<u8> {
    if let Some(h) = input.get("bytes").and_then(Value::as_str) {
        return hex(h);
    }
    ["text", "pretty"]
        .iter()
        .find_map(|k| input.get(*k).and_then(Value::as_str))
        .unwrap_or_else(|| panic!("no file in {input}"))
        .as_bytes()
        .to_vec()
}

/// The value with each string PowerShell made a `[datetime]` of as the
/// answers hold one: {date: its 'o'}.
fn with_dates(mut v: Value, dates: &[(String, String)]) -> Value {
    for (at, o) in dates {
        if let Some(s) = v.pointer_mut(at) {
            *s = json!({ "date": o });
        }
    }
    v
}

#[test]
fn json_compat_vectors() {
    let mut r = Report::new("json-compat.json");
    for case in load("json-compat") {
        let bytes = file(&case.input);
        if let Some(text) = case.input.get("pretty").and_then(Value::as_str) {
            match serde_json::from_str::<Value>(text) {
                Ok(v) if json::to_pretty(&v) == text => r.pass(),
                Ok(v) => r.fail(
                    &case,
                    Flavour::Core,
                    format!("chatqd's writer writes {:?}", json::to_pretty(&v)),
                ),
                Err(e) => r.fail(
                    &case,
                    Flavour::Core,
                    format!("serde_json cannot read it: {e}"),
                ),
            }
        }
        for fl in case.flavours() {
            let t = json::parse_tolerant_in(&bytes, fl);
            let dates = json::ps_dates_in(&bytes, fl, kst());
            let value = json::ps_return(t.value.map(|v| with_dates(v, &dates)), fl);
            r.check_ordered(
                &case,
                fl,
                &json!({ "value": value, "repaired": t.repaired }),
            );
        }
    }
    r.finish();
}
