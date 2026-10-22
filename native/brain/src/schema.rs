//! A small JSON Schema checker: just the keywords the catalogue uses
//! (type incl. arrays of types, enum, properties, required,
//! additionalProperties:false, items, minimum, maximum).

use serde_json::Value;

pub fn validate(schema: &Value, v: &Value) -> Result<(), String> {
    check(schema, v, "$")
}

fn type_ok(t: &str, v: &Value) -> bool {
    match t {
        "object" => v.is_object(),
        "array" => v.is_array(),
        "string" => v.is_string(),
        "boolean" => v.is_boolean(),
        "null" => v.is_null(),
        "integer" => v.is_i64() || v.is_u64(),
        "number" => v.is_number(),
        _ => false,
    }
}

fn check(schema: &Value, v: &Value, at: &str) -> Result<(), String> {
    if let Some(t) = schema.get("type") {
        let ok = match t {
            Value::String(s) => type_ok(s, v),
            Value::Array(a) => a.iter().filter_map(Value::as_str).any(|s| type_ok(s, v)),
            _ => true,
        };
        if !ok {
            return Err(format!("{at}: wrong type"));
        }
    }
    if let Some(Value::Array(e)) = schema.get("enum") {
        if !e.contains(v) {
            return Err(format!("{at}: not in enum"));
        }
    }
    if let Some(n) = v.as_f64() {
        if let Some(min) = schema.get("minimum").and_then(Value::as_f64) {
            if n < min {
                return Err(format!("{at}: below minimum"));
            }
        }
        if let Some(max) = schema.get("maximum").and_then(Value::as_f64) {
            if n > max {
                return Err(format!("{at}: above maximum"));
            }
        }
    }
    if let Value::Object(obj) = v {
        if let Some(Value::Array(req)) = schema.get("required") {
            for k in req.iter().filter_map(Value::as_str) {
                if !obj.contains_key(k) {
                    return Err(format!("{at}: missing {k}"));
                }
            }
        }
        let props = schema.get("properties").and_then(Value::as_object);
        for (k, val) in obj {
            match props.and_then(|p| p.get(k)) {
                Some(sub) => check(sub, val, &format!("{at}.{k}"))?,
                None if schema.get("additionalProperties") == Some(&Value::Bool(false)) => {
                    return Err(format!("{at}: unexpected {k}"));
                }
                None => {}
            }
        }
    }
    if let (Value::Array(items), Some(sub)) = (v, schema.get("items")) {
        for (i, it) in items.iter().enumerate() {
            check(sub, it, &format!("{at}[{i}]"))?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn accepts_and_rejects() {
        let s = json!({"type":"object","additionalProperties":false,"required":["a","b"],
            "properties":{"a":{"type":["integer","null"]},"b":{"enum":["x","y"]},
            "c":{"type":"array","items":{"type":"string"}}}});
        assert!(validate(&s, &json!({"a":null,"b":"x"})).is_ok());
        assert!(validate(&s, &json!({"a":3,"b":"y","c":["q"]})).is_ok());
        assert!(validate(&s, &json!({"a":3})).is_err(), "missing b");
        assert!(validate(&s, &json!({"a":"3","b":"x"})).is_err(), "wrong type");
        assert!(validate(&s, &json!({"a":3,"b":"z"})).is_err(), "enum");
        assert!(validate(&s, &json!({"a":3,"b":"x","d":1})).is_err(), "extra key");
        assert!(validate(&s, &json!({"a":3.5,"b":"x"})).is_err(), "float is not integer");
        assert!(validate(&s, &json!({"a":1,"b":"x","c":[1]})).is_err(), "items");
    }

    #[test]
    fn bounds() {
        let s = json!({"type":"integer","minimum":0,"maximum":3});
        assert!(validate(&s, &json!(3)).is_ok());
        assert!(validate(&s, &json!(4)).is_err());
        assert!(validate(&s, &json!(-1)).is_err());
    }
}
