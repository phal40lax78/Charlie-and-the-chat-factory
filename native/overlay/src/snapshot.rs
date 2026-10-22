// The M9 contract: data/overlay.json as the PowerShell host writes it
// (native/SPEC.md "M9: the overlay's snapshot"), and what the panel takes
// from it. The host's cycle writes it with ConvertTo-Json -Depth 6, which
// writes a value nested deeper as its .NET name ("@{...}",
// "System.Collections.Hashtable") instead of failing: parse names every such
// place (deep), so a new nesting in the host shows up as a logged path, not
// as a row that quietly lost its parts. native/vectors/overlay-snapshot.json
// pins both PowerShells' text; the tests below read it.

use serde_json::Value;

/// What the host has for the panel to say: a balloon's words today
/// (Add-ChatOverlayEvent), kept in the snapshot until the panel has seen it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Event {
    pub id: String,
    pub at: i64,
    pub kind: String,
    pub title: String,
    pub text: String,
    pub ms: i64,
    /// what a click on it means (the balloon's Kind): ask, memory, leak, ''
    pub click: String,
    pub keys: Vec<String>,
    /// a balloon's icon: None, Info, Warning, Error
    pub icon: String,
    /// a said event's kind (Add-ChatOverlaySaid): done, busy, late, delete...
    pub said: String,
    /// a said event's colour: a palette name (dim, warn, error...)
    pub tone: String,
    /// the row key a said event is about ('' for none)
    pub about: String,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Row {
    pub key: String,
    pub kind: String,
    pub status: String,
    pub title: String,
    pub project: String,
    pub prompt: String,
    pub state_text: String,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Snapshot {
    pub schema: i64,
    pub version: String,
    pub pid: i64,
    /// epoch ms the host wrote it: at least every 10 s while it runs
    pub at: i64,
    pub usage_text: String,
    pub rows: Vec<Row>,
    /// Recent's titles, then recentMore's
    pub recent: Vec<String>,
    pub events: Vec<Event>,
    /// ui.spin: a usage ask out; None where the host writes no ui (the WPF
    /// and macOS hosts)
    pub spin: Option<bool>,
    /// every place a value went past Depth 6, as a path ("rows[0].auto")
    pub deep: Vec<String>,
    /// the whole file, for what the panel draws from it (scene.rs, app.rs)
    pub v: Value,
}

/// The one schema this reader knows.
pub const SCHEMA: i64 = 1;

fn s(v: &Value, k: &str) -> String {
    match v.get(k) {
        Some(Value::String(t)) => t.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

fn i(v: &Value, k: &str) -> i64 {
    v.get(k)
        .and_then(|x| x.as_i64().or_else(|| x.as_f64().map(|f| f as i64)))
        .unwrap_or(0)
}

fn arr<'a>(v: &'a Value, k: &str) -> &'a [Value] {
    v.get(k)
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[])
}

/// A string ConvertTo-Json wrote in a too-deep value's place.
fn is_deep(t: &str) -> bool {
    t.starts_with("@{")
        || t == "System.Collections.Hashtable"
        || t == "System.Collections.Specialized.OrderedDictionary"
}

fn walk(v: &Value, path: &str, out: &mut Vec<String>) {
    match v {
        Value::String(t) if is_deep(t) => out.push(path.to_string()),
        Value::Object(m) => {
            for (k, x) in m {
                let p = if path.is_empty() {
                    k.clone()
                } else {
                    format!("{path}.{k}")
                };
                walk(x, &p, out);
            }
        }
        Value::Array(a) => {
            for (n, x) in a.iter().enumerate() {
                walk(x, &format!("{path}[{n}]"), out);
            }
        }
        _ => {}
    }
}

/// Every path whose value went past Depth 6, in ordinal order.
pub fn deep_paths(v: &Value) -> Vec<String> {
    let mut out = Vec::new();
    walk(v, "", &mut out);
    out.sort();
    out
}

/// The file's bytes as the panel reads them. A schema other than 1 is
/// refused: the panel would draw what it does not understand.
pub fn parse(bytes: &[u8]) -> Result<Snapshot, String> {
    let bytes = bytes.strip_prefix(b"\xEF\xBB\xBF").unwrap_or(bytes);
    let v: Value = serde_json::from_slice(bytes).map_err(|e| format!("{e}"))?;
    if !v.is_object() {
        return Err("not an object".into());
    }
    let schema = i(&v, "schema");
    if schema != SCHEMA {
        return Err(format!("schema {schema}, not {SCHEMA}"));
    }
    let header = v.get("header").cloned().unwrap_or(Value::Null);
    let rows = arr(&v, "rows")
        .iter()
        .map(|r| Row {
            key: s(r, "key"),
            kind: s(r, "kind"),
            status: s(r, "status"),
            title: s(r, "title"),
            project: s(r, "project"),
            prompt: s(r, "prompt"),
            state_text: s(r, "stateText"),
        })
        .collect();
    let recent = arr(&v, "recent")
        .iter()
        .chain(arr(&v, "recentMore"))
        .filter(|r| !r.is_null())
        .map(|r| s(r, "title"))
        .collect();
    let events = arr(&v, "events")
        .iter()
        .filter(|e| !e.is_null())
        .map(|e| Event {
            id: s(e, "id"),
            at: i(e, "at"),
            kind: s(e, "kind"),
            title: s(e, "title"),
            text: s(e, "text"),
            ms: i(e, "ms"),
            click: s(e, "click"),
            keys: arr(e, "keys")
                .iter()
                .filter_map(|k| k.as_str().map(str::to_string))
                .collect(),
            icon: s(e, "icon"),
            said: s(e, "said"),
            tone: s(e, "tone"),
            about: s(e, "about"),
        })
        .collect();
    let spin = v
        .get("ui")
        .map(|u| u.get("spin").and_then(Value::as_bool).unwrap_or(false));
    Ok(Snapshot {
        schema,
        version: s(&v, "version"),
        pid: i(&v, "pid"),
        at: i(&v, "at"),
        usage_text: s(&header, "usageText"),
        rows,
        recent,
        events,
        spin,
        deep: deep_paths(&v),
        v,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vectors() -> Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../vectors/overlay-snapshot.json"
        );
        let text = std::fs::read_to_string(path).expect("native/vectors/overlay-snapshot.json");
        serde_json::from_str(&text).unwrap()
    }

    fn strings(v: &Value) -> Vec<String> {
        v.as_array()
            .unwrap()
            .iter()
            .map(|x| x.as_str().unwrap().to_string())
            .collect()
    }

    /// Each PowerShell's text read as the vector's answer says, for every
    /// case: the answer is per edition only where the two differ.
    #[test]
    fn every_golden_reads_as_its_answer() {
        let file = vectors();
        let cases = file["cases"].as_array().unwrap();
        assert!(cases.len() >= 10, "both editions' cases: {}", cases.len());
        for c in cases {
            let name = c["name"].as_str().unwrap();
            let by = c["by"].as_str().unwrap();
            let want = c.get("expect").unwrap_or_else(|| &c["expectByEdition"][by]);
            assert!(!want.is_null(), "{name}: no answer for {by}");
            let got = parse(c["input"]["text"].as_str().unwrap().as_bytes())
                .unwrap_or_else(|e| panic!("{name}: {e}"));
            assert_eq!(got.schema, want["schema"].as_i64().unwrap(), "{name}");
            assert_eq!(got.version, want["version"].as_str().unwrap(), "{name}");
            let keys: Vec<String> = got.rows.iter().map(|r| r.key.clone()).collect();
            assert_eq!(keys, strings(&want["rowKeys"]), "{name}: row keys");
            let titles: Vec<String> = got.rows.iter().map(|r| r.title.clone()).collect();
            assert_eq!(titles, strings(&want["rowTitles"]), "{name}: row titles");
            assert_eq!(got.recent, strings(&want["recent"]), "{name}: recent");
            assert_eq!(
                got.usage_text,
                want["usageText"].as_str().unwrap(),
                "{name}"
            );
            let events: Vec<String> = got
                .events
                .iter()
                .map(|e| format!("{} {}", e.id, e.kind))
                .collect();
            assert_eq!(events, strings(&want["events"]), "{name}: events");
            assert_eq!(got.spin, want["spin"].as_bool(), "{name}: spin");
            assert_eq!(got.deep, strings(&want["deep"]), "{name}: past Depth 6");
        }
    }

    /// The case built one level too deep is named by both PowerShells, and
    /// the rest are whole.
    #[test]
    fn the_deep_case_alone_goes_past_depth_6() {
        let file = vectors();
        for c in file["cases"].as_array().unwrap() {
            let name = c["name"].as_str().unwrap();
            let got = parse(c["input"]["text"].as_str().unwrap().as_bytes()).unwrap();
            assert_eq!(
                !got.deep.is_empty(),
                name.ends_with("a row too deep"),
                "{name}: {:?}",
                got.deep
            );
        }
    }

    #[test]
    fn refuses_another_schema_and_reads_a_bom() {
        assert!(parse(br#"{"schema":2}"#).unwrap_err().contains("schema 2"));
        assert!(parse(b"[1]").is_err());
        let got = parse(b"\xEF\xBB\xBF{\"schema\":1,\"rows\":[{\"key\":\"s:1\"}]}").unwrap();
        assert_eq!(got.rows[0].key, "s:1");
        assert_eq!(got.spin, None);
    }
}
