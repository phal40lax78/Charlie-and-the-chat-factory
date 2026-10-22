//! The regex layer (SPEC.md section 3). Pure functions, no I/O. Only the
//! regex-tier tasks (`fail_kind`, `extract`) have rules here; it is their
//! primary path. The model-tier tasks have none: no regex stand-in, by the
//! user's decision (SPEC.md section 0). The labels returned are always complete
//! (every schema field present, `null` where it cannot tell).
//!
//! One cue is tightened from the spec text, pinned by a vector near-miss:
//! `tests` ignores `0 failed` (a green summary line) and wants `assertion
//! failed|error` rather than the bare word.

use crate::api::Tail;
use regex::Regex;
use serde_json::{json, Value};
use std::sync::LazyLock;

pub struct Verdict {
    pub labels: Value,
    pub confidence: f64,
    /// The rule's name, for the hover card.
    pub why: String,
}

fn re(p: &str) -> Regex {
    Regex::new(p).unwrap_or_else(|e| panic!("bad pattern {p}: {e}"))
}

struct Cue {
    kind: &'static str,
    re: Regex,
    /// Matches needed in the tail (3 for `loop`, else 1).
    min: usize,
}

const SCOPE_CUE: &str = r"(?i)\bI also\b|while I was at it|additionally,? I (?:refactored|renamed|moved|cleaned)";

/// Table order is the spec's, with `crash` before `tests` and `merge` before `build`.
static CUES: LazyLock<Vec<Cue>> = LazyLock::new(|| {
    let c = |kind, p: &str, min| Cue { kind, re: re(p), min };
    vec![
        c("crash", r"(?m)^Traceback|panicked at|Unhandled exception|^[ \t]+at .+\(.+:\d+\)", 1),
        c("tests", r"(?i)\b[1-9]\d* failed\b|(?-i:\bFAILED\b)|AssertionError|\bassertion (?:failed|error)\b", 1),
        c("merge", r"(?m)^<{7} |^>{7} |CONFLICT \(content\)", 1),
        c("build", r"error TS\d+|error CS\d+|error\[E0|(?i:compilation failed)", 1),
        c(
            "gaveup",
            r"(?i)\bI (?:cannot|can't|could not|couldn't|was unable)\b|\b(?:do|run|apply) (?:it|this|that) manually",
            1,
        ),
        c("loop", r"(?i)let me try again|different approach", 3),
        c("revert", r"(?i)\breverted\b|undone my change|rolled back|git (?:checkout --|revert)", 1),
        c("timeout", r"(?i)timed out|TimeoutError", 1),
        c("lint", r"(?i)\b\d+ problems?\b|\b\d+ errors?, \d+ warnings?", 1),
        c("scope", SCOPE_CUE, 1),
        c("permission", r"(?i)permission denied|the user declined|I would need permission", 1),
        c(
            "clarify",
            r"(?i)which .{0,40} do you mean|could you clarify|did you mean|I see \d+ .{0,40} which one",
            1,
        ),
        c("missing", r"(?i)no such file|ENOENT|cannot find module|ModuleNotFoundError|not found in the repo", 1),
    ]
});

static PATH: LazyLock<Regex> = LazyLock::new(|| {
    re(r"(?:[A-Za-z]:)?[\w.\-]*(?:[/\\][\w.\-]+)*[/\\][\w\-]+\.\w{1,5}\b|\b[\w\-]+\.(?:rs|ts|tsx|js|jsx|py|cs|json|toml|md|c|h|cpp|go|java|ps1|sh|yml|yaml)\b")
});
static TOOL: LazyLock<Regex> =
    LazyLock::new(|| re(r"\b(cargo|npm|pnpm|yarn|pytest|tsc|dotnet|git|eslint|make|python|node|go)\b"));
static INT: LazyLock<Regex> = LazyLock::new(|| re(r"\d+"));
static ERROR_LINE: LazyLock<Regex> = LazyLock::new(|| re(r"(?i)\berror\b|panicked at|Traceback|exception"));

/// Cut to at most `n` bytes on a char boundary.
pub fn cut(s: &str, n: usize) -> &str {
    if s.len() <= n {
        return s;
    }
    let mut i = n;
    while !s.is_char_boundary(i) {
        i -= 1;
    }
    &s[..i]
}

fn line_at(text: &str, pos: usize) -> &str {
    let start = text[..pos].rfind('\n').map_or(0, |i| i + 1);
    let end = text[pos..].find('\n').map_or(text.len(), |i| pos + i);
    &text[start..end]
}

fn last_with_role<'a>(tail: &'a Tail, role: &str) -> Option<&'a str> {
    tail.turns.iter().rev().find(|t| t.role == role).map(|t| t.text.as_str())
}

fn paths(text: &str) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for m in PATH.find_iter(text) {
        let p = m.as_str().to_string();
        if !out.contains(&p) {
            out.push(p);
        }
    }
    out
}

fn verdict(labels: Value, confidence: f64, why: &str) -> Verdict {
    Verdict { labels, confidence, why: why.to_string() }
}

/// `None` when `task` has no rule: not a catalogue name, or a model-tier task.
pub fn classify(task: &str, tail: &Tail) -> Option<Verdict> {
    Some(match task {
        "fail_kind" => fail_kind(tail),
        "extract" => extract(tail),
        _ => return None,
    })
}

fn fail_kind(tail: &Tail) -> Verdict {
    let mut corpus = tail.tool_out.clone();
    for t in tail.turns.iter().filter(|t| t.role == "assistant") {
        corpus.push('\n');
        corpus.push_str(&t.text);
    }
    for cue in CUES.iter() {
        let mut it = cue.re.find_iter(&corpus);
        let Some(m) = it.next() else { continue };
        let count = 1 + it.count();
        if count < cue.min {
            continue;
        }
        let mut end = (m.end() + 40).min(corpus.len());
        while !corpus.is_char_boundary(end) {
            end -= 1;
        }
        let n = INT.find(&corpus[m.start()..end]).and_then(|d| d.as_str().parse::<u64>().ok());
        let line = line_at(&corpus, m.start());
        let file = PATH.find(line).map(|p| p.as_str().to_string());
        let tool = TOOL.find(line).map(|t| t.as_str().to_string());
        let attempt = (cue.kind == "loop").then_some(count);
        let labels = json!({"kind": cue.kind, "n": n, "file": file, "tool": tool, "attempt": attempt});
        return verdict(labels, 1.0, &format!("fail_kind:{}", cue.kind));
    }
    verdict(
        json!({"kind": "none", "n": null, "file": null, "tool": null, "attempt": null}),
        0.5,
        "fail_kind:none",
    )
}

fn first_line_with<'a>(text: &'a str, word: &Regex) -> Option<&'a str> {
    text.lines().find(|l| word.is_match(l))
}

fn extract(tail: &Tail) -> Verdict {
    let user = last_with_role(tail, "user").unwrap_or("");
    let asst = last_with_role(tail, "assistant").unwrap_or("");
    let task = cut(user.lines().next().unwrap_or("").trim(), 80);
    let file = paths(&tail.tool_out).into_iter().next().or_else(|| paths(asst).into_iter().next());
    let error = first_line_with(&tail.tool_out, &ERROR_LINE)
        .or_else(|| first_line_with(asst, &ERROR_LINE))
        .map(|l| cut(l.trim(), 120).to_string());
    verdict(json!({"task": task, "file": file, "error": error}), 1.0, "extract:first-line")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::Turn;

    fn tail(turns: &[(&str, &str)], tool_out: &str) -> Tail {
        Tail {
            chat: None,
            turns: turns.iter().map(|(r, t)| Turn { role: r.to_string(), text: t.to_string() }).collect(),
            tool_out: tool_out.to_string(),
        }
    }

    #[test]
    fn cut_respects_char_boundary() {
        assert_eq!(cut("héllo", 2), "h");
        assert_eq!(cut("abc", 10), "abc");
    }

    #[test]
    fn unknown_task_is_none() {
        assert!(classify("nope", &Tail::default()).is_none());
    }

    #[test]
    fn regex_tasks_return_schema_valid_labels_and_model_tasks_have_no_rule() {
        for t in crate::catalogue::TASKS.iter() {
            let v = classify(t.name, &Tail::default());
            if t.model_tier {
                assert!(v.is_none(), "{}: a model-tier task has no regex stand-in", t.name);
                continue;
            }
            crate::schema::validate(&t.schema_value(), &v.unwrap().labels)
                .unwrap_or_else(|e| panic!("{}: {e}", t.name));
        }
    }

    #[test]
    fn loop_needs_three() {
        let two = tail(&[("assistant", "let me try again. Let me try again.")], "");
        assert_eq!(fail_kind(&two).labels["kind"], "none");
        let three = tail(&[("assistant", "Let me try again. let me try again. different approach.")], "");
        let v = fail_kind(&three);
        assert_eq!(v.labels["kind"], "loop");
        assert_eq!(v.labels["attempt"], 3);
    }
}
