//! native/vectors/<name>.json as every `*_vectors.rs` runner reads it
//! (`mod common;`). tests/vectors.ps1 writes these files from the PowerShell
//! functions they pin, under both PowerShells, and checks them in the suite
//! (SPEC 6.1); nobody edits one by hand.
//!
//! A file is `{about, cases}`. A case is `{name, by?, input, expect}` when
//! Windows PowerShell 5.1 and pwsh 7 give the same answer, else
//! `{name, by?, input, expectByEdition: {Desktop, Core}}`. `by` names the one
//! PowerShell that can make that input (bytes its own ConvertTo-Json wrote);
//! both still answer it, so every case is checked under both flavours.

#![allow(dead_code)]

use chatq_core::time::Flavour;
use serde_json::Value;
use std::fmt::Display;
use std::fs;
use std::path::PathBuf;

/// native/vectors/
pub fn dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../vectors")
}

/// `$PSVersionTable.PSEdition` for a flavour: the key in `expectByEdition`.
pub fn edition(fl: Flavour) -> &'static str {
    match fl {
        Flavour::Desktop => "Desktop",
        Flavour::Core => "Core",
    }
}

pub struct Case {
    pub name: String,
    /// The PowerShell that made the input, when only one can.
    pub by: Option<String>,
    pub input: Value,
    raw: Value,
}

impl Case {
    /// Every case is answered by both PowerShells.
    pub fn flavours(&self) -> [Flavour; 2] {
        [Flavour::Desktop, Flavour::Core]
    }

    /// The answer of `fl`'s PowerShell. A file one PowerShell has not
    /// written yet fails here, naming the fix.
    pub fn expect(&self, fl: Flavour) -> &Value {
        if let Some(e) = self.raw.get("expect") {
            return e;
        }
        let ed = edition(fl);
        match self.raw.get("expectByEdition").and_then(|m| m.get(ed)) {
            Some(e) => e,
            None => panic!(
                "case '{}' has no {ed} answer: run tests/vectors.ps1 -Write under {}",
                self.name,
                if ed == "Desktop" {
                    "Windows PowerShell 5.1"
                } else {
                    "pwsh 7"
                }
            ),
        }
    }

    /// Whether the two PowerShells answered alike.
    pub fn same_for_both(&self) -> bool {
        self.raw.get("expect").is_some()
    }
}

/// Every case of native/vectors/<name>.json, in the file's order.
pub fn load(name: &str) -> Vec<Case> {
    let p = dir().join(format!("{name}.json"));
    let text = fs::read_to_string(&p).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
    let v: Value = serde_json::from_str(&text).unwrap_or_else(|e| panic!("{}: {e}", p.display()));
    let cases = v["cases"]
        .as_array()
        .unwrap_or_else(|| panic!("{}: no cases", p.display()));
    assert!(!cases.is_empty(), "{}: no cases", p.display());
    cases
        .iter()
        .map(|c| Case {
            name: c["name"].as_str().expect("a case has a name").to_string(),
            by: c.get("by").and_then(Value::as_str).map(str::to_string),
            input: c["input"].clone(),
            raw: c.clone(),
        })
        .collect()
}

/// Bytes as tests/vectors/common.ps1's ConvertTo-NvHex writes them.
pub fn hex(s: &str) -> Vec<u8> {
    assert!(s.len().is_multiple_of(2), "odd hex: {s}");
    (0..s.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap_or_else(|e| panic!("hex {s}: {e}")))
        .collect()
}

/// A .NET string as ConvertTo-NvUnits writes it: its UTF-16 code units,
/// lone surrogates and all.
pub fn units(v: &Value) -> Vec<u16> {
    v.as_array()
        .unwrap_or_else(|| panic!("code units, not {v}"))
        .iter()
        .map(|u| {
            u.as_u64()
                .and_then(|n| u16::try_from(n).ok())
                .unwrap_or_else(|| panic!("a code unit, not {u}"))
        })
        .collect()
}

/// Equal as JSON values: numbers by value (5 and 5.0 alike), objects by
/// their keys whatever the order. [same_ordered] holds the order too.
pub fn same(a: &Value, b: &Value) -> bool {
    eq(a, b, false)
}

/// [same], with every object's keys in the same order: for a file whose
/// field order is part of its contract (SPEC 2.4's state.json).
pub fn same_ordered(a: &Value, b: &Value) -> bool {
    eq(a, b, true)
}

fn eq(a: &Value, b: &Value, ordered: bool) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => match (x.as_i64(), y.as_i64()) {
            (Some(i), Some(j)) => i == j,
            _ => match (x.as_u64(), y.as_u64()) {
                (Some(i), Some(j)) => i == j,
                _ => x.as_f64() == y.as_f64(),
            },
        },
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(p, q)| eq(p, q, ordered))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len()
                && if ordered {
                    x.iter()
                        .zip(y)
                        .all(|((k, p), (l, q))| k == l && eq(p, q, ordered))
                } else {
                    x.iter()
                        .all(|(k, p)| y.get(k).is_some_and(|q| eq(p, q, ordered)))
                }
        }
        _ => a == b,
    }
}

/// Every mismatch of one runner, so a run shows them all at once.
pub struct Report {
    file: String,
    bad: Vec<String>,
    checked: usize,
}

impl Report {
    pub fn new(file: &str) -> Report {
        Report {
            file: file.to_string(),
            bad: Vec::new(),
            checked: 0,
        }
    }

    /// `got` against the case's answer for `fl`, by [same].
    pub fn check(&mut self, case: &Case, fl: Flavour, got: &Value) {
        self.compare(case, fl, got, false);
    }

    /// `got` against the case's answer for `fl`, by [same_ordered].
    pub fn check_ordered(&mut self, case: &Case, fl: Flavour, got: &Value) {
        self.compare(case, fl, got, true);
    }

    fn compare(&mut self, case: &Case, fl: Flavour, got: &Value, ordered: bool) {
        self.checked += 1;
        let want = case.expect(fl);
        if !eq(want, got, ordered) {
            self.bad.push(format!(
                "'{}' ({}):\n    want {}\n    got  {}",
                case.name,
                edition(fl),
                want,
                got
            ));
        }
    }

    /// A mismatch the runner found its own way.
    pub fn fail(&mut self, case: &Case, fl: Flavour, why: impl Display) {
        self.checked += 1;
        self.bad
            .push(format!("'{}' ({}): {why}", case.name, edition(fl)));
    }

    /// A check that passed without [Report::check].
    pub fn pass(&mut self) {
        self.checked += 1;
    }

    /// Panics with every mismatch, or when nothing was checked.
    pub fn finish(self) {
        assert!(self.checked > 0, "{}: nothing was checked", self.file);
        assert!(
            self.bad.is_empty(),
            "{}: {} of {} checks differ from PowerShell's answers\n{}",
            self.file,
            self.bad.len(),
            self.checked,
            self.bad.join("\n")
        );
    }
}
