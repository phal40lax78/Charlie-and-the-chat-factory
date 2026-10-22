//! What the model calls cost (SPEC.md section 5): one JSON line per call in
//! `data/brain/usage.jsonl`, totals for `/usage` and `/health` computed by
//! reading that file. Lines carry counts, never transcript text or labels.
//! Gemini and Claude calls are priced from the tables here; a local call
//! costs 0.

use crate::anthropic;
use crate::gemini::Usage;
use chrono::{DateTime, Datelike, Local, NaiveDate, SecondsFormat};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::Path;

/// USD per million tokens.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Price {
    pub input: f64,
    /// Output, thought tokens included.
    pub output: f64,
    /// The cached part of the input.
    pub cached_input: f64,
}

/// Paid-tier Standard prices, from https://ai.google.dev/gemini-api/docs/pricing
/// as read on 2026-10-22 (the free tier is $0 but trains on the data, SPEC.md
/// section 5). None of these models has a >200k-token price tier.
/// `gemini-3.8-flash` output is $3.75 "through December 31, 2026" per that page.
/// UPDATE HERE when a price changes or `brain.json` names a model that is not
/// listed. A model with no row gets `cost_usd: null`, never a guess.
pub const PRICES: &[(&str, Price)] = &[
    ("gemini-3.5-flash-lite", Price { input: 0.30, output: 2.50, cached_input: 0.03 }),
    ("gemini-3.1-flash-lite", Price { input: 0.25, output: 1.50, cached_input: 0.025 }),
    ("gemini-3.8-flash", Price { input: 0.75, output: 3.75, cached_input: 0.075 }),
    ("gemini-3.6-flash", Price { input: 0.75, output: 3.75, cached_input: 0.075 }),
    ("gemini-2.5-flash-lite", Price { input: 0.10, output: 0.40, cached_input: 0.01 }),
    ("gemini-2.5-flash", Price { input: 0.30, output: 2.50, cached_input: 0.03 }),
];

/// Claude prices in USD per million tokens.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ClaudePrice {
    pub input: f64,
    pub output: f64,
    /// 5-minute cache write.
    pub cache_write: f64,
    pub cache_read: f64,
}

/// Claude prices by model id prefix (a dated id like
/// `claude-haiku-4-5-20251001` matches `claude-haiku-4-5`). UPDATE HERE when
/// Anthropic changes a price or `brain.json` names a model that is not
/// listed. A model with no row gets `cost_usd: null`.
pub const CLAUDE_PRICES: &[(&str, ClaudePrice)] =
    &[("claude-haiku-4-5", ClaudePrice { input: 1.00, output: 5.00, cache_write: 1.25, cache_read: 0.10 })];

pub fn claude_price(model: &str) -> Option<ClaudePrice> {
    CLAUDE_PRICES
        .iter()
        .find(|(id, _)| model == *id || model.strip_prefix(id).is_some_and(|rest| rest.starts_with('-')))
        .map(|(_, p)| *p)
}

/// Fresh input, output, cache writes and cache reads, each at its price.
pub fn claude_cost(model: &str, u: &anthropic::Usage) -> Option<f64> {
    let p = claude_price(model)?;
    let micro = u.input_tokens as f64 * p.input
        + u.output_tokens as f64 * p.output
        + u.cache_creation_input_tokens as f64 * p.cache_write
        + u.cache_read_input_tokens as f64 * p.cache_read;
    Some(round9(micro / 1_000_000.0))
}

/// A row in either table.
fn priced(model: &str) -> bool {
    price(model).is_some() || claude_price(model).is_some()
}

/// The Gemini row for `model`: its exact id, or the id plus a numeric version
/// suffix (`gemini-2.5-flash-001`). `gemini-2.5-flash-lite` never falls
/// back to `gemini-2.5-flash`, nor `-preview-...` to its stable row.
pub fn price(model: &str) -> Option<Price> {
    PRICES
        .iter()
        .find(|(id, _)| {
            model == *id
                || model
                    .strip_prefix(id)
                    .and_then(|r| r.strip_prefix('-'))
                    .is_some_and(|v| !v.is_empty() && v.bytes().all(|b| b.is_ascii_digit()))
        })
        .map(|(_, p)| *p)
}

/// Rounded to 1e-9 USD so sums print cleanly.
fn round9(x: f64) -> f64 {
    (x * 1e9).round() / 1e9
}

/// Input at the input price (its cached part at the cached price), output
/// plus thought tokens at the output price.
pub fn cost(model: &str, u: &Usage) -> Option<f64> {
    let p = price(model)?;
    let fresh = u.input_tokens.saturating_sub(u.cached_tokens);
    let micro = fresh as f64 * p.input
        + u.cached_tokens as f64 * p.cached_input
        + (u.output_tokens + u.thought_tokens) as f64 * p.output;
    Some(round9(micro / 1_000_000.0))
}

/// One line of `usage.jsonl`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Line {
    /// Local time with its UTC offset, RFC 3339.
    pub ts: String,
    pub task: String,
    pub model: String,
    /// The HTTP status of the response.
    pub status: u16,
    pub ms: u64,
    /// `promptTokenCount`, cached part included.
    pub input_tokens: u64,
    /// `candidatesTokenCount`.
    pub output_tokens: u64,
    /// `thoughtsTokenCount`.
    pub thought_tokens: u64,
    /// `cachedContentTokenCount`.
    pub cached_tokens: u64,
    /// Claude only: `cache_creation_input_tokens`. Absent on other lines.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_creation_input_tokens: Option<u64>,
    /// Claude only: `cache_read_input_tokens`. Absent on other lines.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read_input_tokens: Option<u64>,
    /// `null` for a model with no price row; 0 for a local call.
    pub cost_usd: Option<f64>,
}

impl Line {
    pub fn new(at: DateTime<Local>, task: &str, model: &str, status: u16, ms: u64, u: &Usage) -> Line {
        Line {
            ts: at.to_rfc3339_opts(SecondsFormat::Millis, false),
            task: task.into(),
            model: model.into(),
            status,
            ms,
            input_tokens: u.input_tokens,
            output_tokens: u.output_tokens,
            thought_tokens: u.thought_tokens,
            cached_tokens: u.cached_tokens,
            cache_creation_input_tokens: None,
            cache_read_input_tokens: None,
            cost_usd: cost(model, u),
        }
    }

    /// A Claude call. `input_tokens` is the fresh input; the cached parts
    /// are their own fields.
    pub fn anthropic(at: DateTime<Local>, task: &str, model: &str, status: u16, ms: u64, u: &anthropic::Usage) -> Line {
        Line {
            ts: at.to_rfc3339_opts(SecondsFormat::Millis, false),
            task: task.into(),
            model: model.into(),
            status,
            ms,
            input_tokens: u.input_tokens,
            output_tokens: u.output_tokens,
            thought_tokens: 0,
            cached_tokens: 0,
            cache_creation_input_tokens: Some(u.cache_creation_input_tokens),
            cache_read_input_tokens: Some(u.cache_read_input_tokens),
            cost_usd: claude_cost(model, u),
        }
    }

    /// A local llama-server call: its token counts, cost 0.
    pub fn local(at: DateTime<Local>, task: &str, model: &str, status: u16, ms: u64, input: u64, output: u64) -> Line {
        Line {
            ts: at.to_rfc3339_opts(SecondsFormat::Millis, false),
            task: task.into(),
            model: model.into(),
            status,
            ms,
            input_tokens: input,
            output_tokens: output,
            thought_tokens: 0,
            cached_tokens: 0,
            cache_creation_input_tokens: None,
            cache_read_input_tokens: None,
            cost_usd: Some(0.0),
        }
    }

    fn date(&self) -> Option<NaiveDate> {
        DateTime::parse_from_rfc3339(&self.ts).ok().map(|t| t.with_timezone(&Local).date_naive())
    }
}

pub fn append(path: &Path, line: &Line) -> std::io::Result<()> {
    let mut s = serde_json::to_string(line).map_err(std::io::Error::other)?;
    s.push('\n');
    fs::OpenOptions::new().create(true).append(true).open(path)?.write_all(s.as_bytes())
}

#[derive(Debug, Default)]
struct Bucket {
    calls: u64,
    errors: u64,
    input_tokens: u64,
    output_tokens: u64,
    thought_tokens: u64,
    cost_usd: f64,
    by_task: BTreeMap<String, (u64, f64)>,
}

impl Bucket {
    fn add(&mut self, l: &Line) {
        let c = l.cost_usd.unwrap_or(0.0);
        self.calls += 1;
        if l.status != 200 {
            self.errors += 1;
        }
        self.input_tokens += l.input_tokens;
        self.output_tokens += l.output_tokens;
        self.thought_tokens += l.thought_tokens;
        self.cost_usd += c;
        let t = self.by_task.entry(l.task.clone()).or_default();
        t.0 += 1;
        t.1 += c;
    }

    fn to_json(&self) -> Value {
        let by_task: serde_json::Map<String, Value> = self
            .by_task
            .iter()
            .map(|(k, (n, c))| (k.clone(), json!({"calls": n, "cost_usd": round9(*c)})))
            .collect();
        json!({
            "calls": self.calls, "errors": self.errors,
            "input_tokens": self.input_tokens, "output_tokens": self.output_tokens,
            "thought_tokens": self.thought_tokens,
            "cost_usd": round9(self.cost_usd), "by_task": by_task,
        })
    }
}

/// Every readable line; a line that does not parse is skipped.
fn lines(path: &Path) -> Vec<Line> {
    let Ok(f) = fs::File::open(path) else { return Vec::new() };
    BufReader::new(f).lines().map_while(Result::ok).filter_map(|s| serde_json::from_str(&s).ok()).collect()
}

/// `{today, month, all, note}`, by the local date of each line against
/// `now`. `note` names the models with no price row (the configured
/// `model`, or any in the file), whose calls count 0 in the cost totals.
pub fn summary(path: &Path, now: DateTime<Local>, model: &str) -> Value {
    summary_with(path, now, (!priced(model)).then_some(model))
}

/// [summary] with the configured model's price check done by the caller:
/// `unpriced_model` names it when it has no row (`None` for a local model,
/// which costs 0).
pub fn summary_with(path: &Path, now: DateTime<Local>, unpriced_model: Option<&str>) -> Value {
    let today = now.date_naive();
    let (mut d, mut m, mut a) = (Bucket::default(), Bucket::default(), Bucket::default());
    let mut unpriced = BTreeSet::new();
    if let Some(model) = unpriced_model {
        unpriced.insert(model.to_string());
    }
    for l in lines(path) {
        if l.cost_usd.is_none() {
            unpriced.insert(l.model.clone());
        }
        a.add(&l);
        if let Some(date) = l.date() {
            if date.year() == today.year() && date.month() == today.month() {
                m.add(&l);
                if date == today {
                    d.add(&l);
                }
            }
        }
    }
    let note = (!unpriced.is_empty()).then(|| {
        let names: Vec<String> = unpriced.into_iter().collect();
        format!("no price for {}: cost_usd is null for its calls and counts 0 here", names.join(", "))
    });
    json!({"today": d.to_json(), "month": m.to_json(), "all": a.to_json(), "note": note})
}

/// This local month's spend, for `/health`.
pub fn month_cost(path: &Path, now: DateTime<Local>, model: &str) -> f64 {
    summary(path, now, model)["month"]["cost_usd"].as_f64().unwrap_or(0.0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testutil::tmpdir;
    use chrono::{Duration, TimeZone};

    fn u(i: u64, o: u64, th: u64, ca: u64) -> Usage {
        Usage { input_tokens: i, output_tokens: o, thought_tokens: th, cached_tokens: ca }
    }

    const M: &str = "gemini-3.5-flash-lite";

    #[test]
    fn every_researched_model_has_a_row_and_ids_match_exactly() {
        for id in [
            "gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-3.8-flash", "gemini-3.6-flash",
            "gemini-2.5-flash-lite", "gemini-2.5-flash",
        ] {
            assert!(price(id).is_some(), "{id}");
        }
        assert_eq!(price("gemini-2.5-flash-lite").unwrap().input, 0.10, "not the gemini-2.5-flash row");
        assert_eq!(price("gemini-2.5-flash-001"), price("gemini-2.5-flash"));
        assert!(price("gemini-2.5-flash-image").is_none(), "a suffix that is not a version is another model");
        assert!(price("gemini-3.5-flash-lite-preview-09-2026").is_none());
        assert!(price("gemini-3.5-flash-lite-").is_none());
        assert!(price("claude-haiku-4-5").is_none());
    }

    #[test]
    fn cost_per_million_with_thoughts_and_cache() {
        // 1000 in of which 200 cached, 100 out, 50 thought:
        // (800*0.30 + 200*0.03 + 150*2.50) / 1e6 = 0.000621
        assert_eq!(cost(M, &u(1000, 100, 50, 200)), Some(0.000621));
        assert_eq!(cost(M, &u(1_000_000, 0, 0, 0)), Some(0.3));
        assert_eq!(cost(M, &u(0, 1_000_000, 0, 0)), Some(2.5));
        assert_eq!(cost(M, &u(0, 0, 1_000_000, 0)), Some(2.5), "thoughts bill as output");
        assert_eq!(cost(M, &u(1_000_000, 0, 0, 1_000_000)), Some(0.03));
        assert_eq!(cost("gemini-2.5-flash-lite", &u(1_000_000, 1_000_000, 0, 0)), Some(0.5));
        assert_eq!(cost("gemini-unknown", &u(1, 1, 0, 0)), None);
    }

    #[test]
    fn summary_buckets_by_local_date() {
        let d = tmpdir("usage-summary");
        let p = d.join("usage.jsonl");
        let now = Local.with_ymd_and_hms(2026, 10, 22, 12, 0, 0).unwrap();
        // 1000 in, 200 out, 100 thought: 0.0003 + 0.00075 = 0.00105
        append(&p, &Line::new(now, "scope_drift", M, 200, 900, &u(1000, 200, 100, 0))).unwrap();
        append(&p, &Line::new(now, "contradiction", M, 429, 80, &u(0, 0, 0, 0))).unwrap();
        append(&p, &Line::new(now - Duration::days(10), "scope_drift", M, 200, 900, &u(2000, 0, 0, 0))).unwrap();
        append(&p, &Line::new(now - Duration::days(60), "unread_reply", M, 200, 900, &u(0, 1000, 0, 0))).unwrap();
        std::fs::OpenOptions::new().append(true).open(&p).unwrap().write_all(b"garbage\n").unwrap();
        let s = summary(&p, now, M);
        assert_eq!(s["note"], Value::Null);
        assert_eq!(s["today"]["calls"], 2);
        assert_eq!(s["today"]["errors"], 1);
        assert_eq!(s["today"]["thought_tokens"], 100);
        assert_eq!(s["today"]["cost_usd"], 0.00105);
        assert_eq!(s["month"]["calls"], 3);
        assert_eq!(s["month"]["cost_usd"], 0.00165);
        assert_eq!(s["month"]["by_task"]["scope_drift"], json!({"calls": 2, "cost_usd": 0.00165}));
        assert_eq!(s["all"]["calls"], 4);
        assert_eq!(s["all"]["input_tokens"], 3000);
        assert_eq!(s["all"]["output_tokens"], 1200);
        assert_eq!(s["all"]["thought_tokens"], 100);
        assert_eq!(s["all"]["cost_usd"], 0.00415);
        assert_eq!(s["all"]["by_task"]["unread_reply"], json!({"calls": 1, "cost_usd": 0.0025}));
        assert_eq!(month_cost(&p, now, M), 0.00165);
    }

    #[test]
    fn an_unpriced_model_is_named_in_the_note_and_counts_zero() {
        let d = tmpdir("usage-unpriced");
        let p = d.join("usage.jsonl");
        let now = Local::now();
        append(&p, &Line::new(now, "scope_drift", "gemini-9-mystery", 200, 900, &u(1000, 100, 0, 0))).unwrap();
        assert_eq!(lines(&p)[0].cost_usd, None);
        let s = summary(&p, now, M);
        assert_eq!(s["all"]["cost_usd"], 0.0);
        assert_eq!(s["all"]["calls"], 1);
        assert!(s["note"].as_str().unwrap().contains("gemini-9-mystery"));
        let none = summary(&d.join("absent.jsonl"), now, "gemini-9-other");
        assert!(none["note"].as_str().unwrap().contains("gemini-9-other"), "the configured model too");
    }

    fn cu(i: u64, o: u64, cw: u64, cr: u64) -> anthropic::Usage {
        anthropic::Usage { input_tokens: i, output_tokens: o, cache_creation_input_tokens: cw, cache_read_input_tokens: cr }
    }

    #[test]
    fn haiku_price_and_dated_ids() {
        assert_eq!(claude_price("claude-haiku-4-5-20251001"), claude_price("claude-haiku-4-5"));
        assert_eq!(
            claude_price("claude-haiku-4-5"),
            Some(ClaudePrice { input: 1.00, output: 5.00, cache_write: 1.25, cache_read: 0.10 })
        );
        assert!(claude_price("claude-haiku-4-50").is_none(), "a prefix must end at a dash");
        assert!(claude_price("claude-unknown").is_none());
        assert!(claude_price("gemini-2.5-flash").is_none());
    }

    #[test]
    fn claude_cost_per_million_with_cache_writes_and_reads() {
        // (1000*1.00 + 100*5.00 + 200*1.25 + 300*0.10) / 1e6 = 0.00178
        assert_eq!(claude_cost("claude-haiku-4-5-20251001", &cu(1000, 100, 200, 300)), Some(0.00178));
        assert_eq!(claude_cost("claude-haiku-4-5", &cu(1_000_000, 0, 0, 0)), Some(1.0));
        assert_eq!(claude_cost("claude-haiku-4-5", &cu(0, 1_000_000, 0, 0)), Some(5.0));
        assert_eq!(claude_cost("claude-haiku-4-5", &cu(0, 0, 1_000_000, 0)), Some(1.25));
        assert_eq!(claude_cost("claude-haiku-4-5", &cu(0, 0, 0, 1_000_000)), Some(0.1));
        assert_eq!(claude_cost("claude-unknown", &cu(1, 1, 0, 0)), None);
    }

    #[test]
    fn claude_and_local_lines_carry_their_own_fields_and_sum_with_the_rest() {
        let d = tmpdir("usage-mixed");
        let p = d.join("usage.jsonl");
        let now = Local.with_ymd_and_hms(2026, 10, 22, 12, 0, 0).unwrap();
        let c = Line::anthropic(now, "scope_drift", "claude-haiku-4-5-20251001", 200, 700, &cu(1000, 100, 200, 300));
        let l = Line::local(now, "scope_drift", "phi-4-mini-q4km", 200, 7000, 400, 30);
        append(&p, &c).unwrap();
        append(&p, &l).unwrap();
        let text = std::fs::read_to_string(&p).unwrap();
        let rows: Vec<Value> = text.lines().map(|s| serde_json::from_str(s).unwrap()).collect();
        assert_eq!(
            (&rows[0]["cache_creation_input_tokens"], &rows[0]["cache_read_input_tokens"]),
            (&json!(200), &json!(300))
        );
        assert_eq!(rows[0]["cost_usd"], 0.00178);
        assert!(rows[1].get("cache_read_input_tokens").is_none(), "only Claude lines carry cache fields");
        assert_eq!(
            (&rows[1]["input_tokens"], &rows[1]["output_tokens"], &rows[1]["cost_usd"]),
            (&json!(400), &json!(30), &json!(0.0))
        );
        let s = summary(&p, now, "claude-haiku-4-5-20251001");
        assert_eq!(s["note"], Value::Null, "Claude has a row");
        assert_eq!((&s["today"]["calls"], &s["today"]["cost_usd"]), (&json!(2), &json!(0.00178)));
        assert_eq!(s["today"]["by_task"]["scope_drift"], json!({"calls": 2, "cost_usd": 0.00178}));
        assert_eq!(summary_with(&p, now, None)["note"], Value::Null, "a local model costs 0 and is not unpriced");
    }

    #[test]
    fn no_file_is_all_zero() {
        let d = tmpdir("usage-none");
        let s = summary(&d.join("usage.jsonl"), Local::now(), M);
        for k in ["today", "month", "all"] {
            assert_eq!(
                s[k],
                json!({"calls": 0, "errors": 0, "input_tokens": 0, "output_tokens": 0, "thought_tokens": 0,
                       "cost_usd": 0.0, "by_task": {}})
            );
        }
    }
}
