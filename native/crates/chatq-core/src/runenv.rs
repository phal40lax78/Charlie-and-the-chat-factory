//! The environment a run's CLI gets: the parent's, with the plan's delta,
//! [$script:ChatqRunEnv](src/queue.ps1) where absent and
//! [$script:ChatqEnvDrop](src/queue.ps1) removed, in the order .NET writes
//! the block (SPEC 2.5, 2.6). Used from M5. Vector: native/vectors/env.json.

use crate::time::Flavour;
use std::cmp::Ordering;

/// [$script:ChatqEnvDrop](src/queue.ps1), in its order: what no run's CLI
/// gets, the variables of the Claude Code session chatq may run inside and
/// the API keys, with which a run would bill the API.
pub const ENV_DROP: [&str; 20] = [
    "CLAUDECODE",
    "CLAUDE_PID",
    "CLAUDE_EFFORT",
    "CLAUDE_AGENT_SDK_VERSION",
    "CLAUDE_CODE_ENTRYPOINT",
    "CLAUDE_CODE_EXECPATH",
    "CLAUDE_CODE_SESSION_ID",
    "CLAUDE_CODE_SESSION_ATTENDED",
    "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_SSE_PORT",
    "CLAUDE_CODE_MESSAGING_SOCKET",
    "CLAUDE_CODE_MESSAGING_TOKEN",
    "CLAUDE_CODE_ENABLE_SDK_FILE_CHECKPOINTING",
    "CLAUDE_CODE_ENABLE_TASKS",
    "CLAUDE_CODE_SDK_READS_SESSION_STATE",
    "MCP_CONNECTION_NONBLOCKING",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "OPENAI_API_KEY",
    "CODEX_API_KEY",
];

/// [$script:ChatqRunEnv](src/queue.ps1), in its order: what a Claude run
/// sets where the parent has no variable of that name.
pub const RUN_ENV: [(&str, &str); 4] = [
    ("CLAUDE_CODE_DISABLE_BACKGROUND_TASKS", "1"),
    ("BASH_MAX_TIMEOUT_MS", "3600000"),
    ("BASH_DEFAULT_TIMEOUT_MS", "1800000"),
    ("CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS", "3600000"),
];

/// The CLI a run starts: its job's `provider`, which
/// [Invoke-ChatqRun](src/queue.ps1) branches on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cli {
    /// `claude`, and any provider that is not `codex`
    Claude,
    /// `codex`
    Codex,
}

/// The `-SetEnv` [Invoke-ChatqRun](src/queue.ps1) hands a run's CLI, name
/// and value, None for PowerShell's `$null`. Codex gets `CODEX_HOME` alone.
/// Claude gets `CLAUDE_CONFIG_DIR`, `MCP_TOOL_TIMEOUT` when the run has the
/// phone's bridge (`bridge_ms`, the permit's TimeoutMs), and each of
/// [RUN_ENV] the parent has no variable for. PowerShell asks Windows
/// (`GetEnvironmentVariable`), which matches these ASCII names case-blind.
/// `home` goes as the job holds it; None and an empty one both remove the
/// variable ([child_env]).
pub fn run_delta(
    cli: Cli,
    home: Option<&str>,
    bridge_ms: Option<u64>,
    parent: &[(String, String)],
) -> Vec<(String, Option<String>)> {
    let home = home.map(str::to_string);
    if cli == Cli::Codex {
        return vec![("CODEX_HOME".into(), home)];
    }
    let mut d = vec![("CLAUDE_CONFIG_DIR".to_string(), home)];
    if let Some(ms) = bridge_ms {
        d.push(("MCP_TOOL_TIMEOUT".into(), Some(ms.to_string())));
    }
    for (k, v) in RUN_ENV {
        if !parent.iter().any(|(n, _)| n.eq_ignore_ascii_case(k)) {
            d.push((k.into(), Some(v.into())));
        }
    }
    d
}

/// The environment [New-ChatqProcessStartInfo](src/queue.ps1) starts a CLI
/// with: `parent` without [ENV_DROP], then `delta` over it in its order. A
/// value sets the variable, under the parent's name for it where the parent
/// has one; None or an empty value removes it. Names are one variable when
/// [same_name] says so for `fl`.
/// Deferred: DEFERRED.md "A run's environment off Windows"
pub fn child_env(
    parent: &[(String, String)],
    delta: &[(String, Option<String>)],
    fl: Flavour,
) -> Vec<(String, String)> {
    let mut env: Vec<(String, String)> = parent
        .iter()
        .filter(|(n, _)| !ENV_DROP.iter().any(|d| same_name(n, d, fl)))
        .cloned()
        .collect();
    for (k, v) in delta {
        let at = env.iter().position(|(n, _)| same_name(n, k, fl));
        match (v.as_deref().filter(|v| !v.is_empty()), at) {
            (Some(v), Some(i)) => env[i].1 = v.to_string(),
            (Some(v), None) => env.push((k.clone(), v.to_string())),
            (None, Some(i)) => {
                env.remove(i);
            }
            (None, None) => {}
        }
    }
    env
}

/// The `name=value` entries of the block .NET hands CreateProcess for `env`
/// when it starts [New-ChatqProcessStartInfo](src/queue.ps1)'s process, in
/// its order: by name, [cmp_names] for `fl`.
/// Deferred: DEFERRED.md "A run's environment off Windows"
pub fn block(env: &[(String, String)], fl: Flavour) -> Vec<String> {
    let mut e: Vec<&(String, String)> = env.iter().collect();
    e.sort_by(|a, b| cmp_names(&a.0, &b.0, fl));
    e.iter().map(|(n, v)| format!("{n}={v}")).collect()
}

/// Two variable names in the order of `StringComparer.OrdinalIgnoreCase`,
/// which sorts the block and keys the variables of the `ProcessStartInfo`
/// [New-ChatqProcessStartInfo](src/queue.ps1) fills: each
/// character upper-cased alone, then compared as numbers, a name before any
/// longer one it begins. Windows PowerShell 5.1 (.NET Framework) goes by
/// UTF-16 code unit, so a character beyond the BMP sorts by its surrogates,
/// before U+E000; pwsh 7 (.NET 10) by code point, after U+FFFF. The two
/// upper-case a few characters differently as well.
pub fn cmp_names(a: &str, b: &str, fl: Flavour) -> Ordering {
    fold(a, fl).cmp(&fold(b, fl))
}

/// Whether `fl`'s .NET takes `a` and `b` for the same variable, as
/// [New-ChatqProcessStartInfo](src/queue.ps1) drops and sets them.
pub fn same_name(a: &str, b: &str, fl: Flavour) -> bool {
    cmp_names(a, b, fl) == Ordering::Equal
}

fn fold(s: &str, fl: Flavour) -> Vec<u32> {
    match fl {
        Flavour::Desktop => s.encode_utf16().map(|u| upper(u32::from(u), fl)).collect(),
        Flavour::Core => s.chars().map(|c| upper(c as u32, fl)).collect(),
    }
}

/// One character upper-cased as `fl`'s .NET does it: Unicode's simple
/// mapping, as Rust's tables give it, but for what .NET leaves alone - a
/// character [KEEP_DESKTOP] or [KEEP_CORE] names, one beyond ASCII that would
/// become ASCII, and on the Desktop one that would leave the BMP.
fn upper(c: u32, fl: Flavour) -> u32 {
    let keep = match fl {
        Flavour::Desktop => KEEP_DESKTOP,
        Flavour::Core => KEEP_CORE,
    };
    if keep
        .as_chunks::<2>()
        .0
        .iter()
        .any(|&[s, e]| s <= c && c <= e)
    {
        return c;
    }
    // a lone surrogate, which only the Desktop's code units hold
    let Some(ch) = char::from_u32(c) else {
        return c;
    };
    let u = match c {
        // with iota subscript: the simple mapping is the title-case letter,
        // where Rust's full one is two letters
        0x1F80..=0x1F87 | 0x1F90..=0x1F97 | 0x1FA0..=0x1FA7 => c + 8,
        0x1FB3 | 0x1FC3 | 0x1FF3 => c + 9,
        _ => {
            let mut it = ch.to_uppercase();
            match (it.next(), it.next()) {
                (Some(u), None) => u as u32,
                _ => c,
            }
        }
    };
    if (c >= 0x80 && u < 0x80) || (fl == Flavour::Desktop && u > 0xFFFF) {
        return c;
    }
    u
}

/// The characters Rust 1.99 (Unicode 17) upper-cases that Windows PowerShell
/// 5.1.22621.6133's `OrdinalIgnoreCase` leaves alone, as start and end pairs:
/// every BMP character compared on Windows 11 22631, where .NET Framework
/// upper-cases with Windows' own table.
/// Deferred: DEFERRED.md "Unicode tables scanned on one PC"
const KEEP_DESKTOP: &[u32] = &[
    0xb5, 0xb5, 0x19b, 0x19b, 0x1c5, 0x1c5, 0x1c8, 0x1c8, 0x1cb, 0x1cb, 0x1f2, 0x1f2, 0x23f, 0x240,
    0x252, 0x252, 0x25c, 0x25c, 0x261, 0x261, 0x264, 0x266, 0x26a, 0x26a, 0x26c, 0x26c, 0x282,
    0x282, 0x287, 0x287, 0x29d, 0x29e, 0x345, 0x345, 0x3c2, 0x3c2, 0x3d0, 0x3d1, 0x3d5, 0x3d6,
    0x3f0, 0x3f1, 0x3f3, 0x3f3, 0x3f5, 0x3f5, 0x525, 0x525, 0x527, 0x527, 0x529, 0x529, 0x52b,
    0x52b, 0x52d, 0x52d, 0x52f, 0x52f, 0x10d0, 0x10fa, 0x10fd, 0x10ff, 0x13f8, 0x13fd, 0x1c80,
    0x1c88, 0x1c8a, 0x1c8a, 0x1d8e, 0x1d8e, 0x1e9b, 0x1e9b, 0x1fbe, 0x1fbe, 0x2c5f, 0x2c5f, 0x2cec,
    0x2cec, 0x2cee, 0x2cee, 0x2cf3, 0x2cf3, 0x2d27, 0x2d27, 0x2d2d, 0x2d2d, 0xa661, 0xa661, 0xa699,
    0xa699, 0xa69b, 0xa69b, 0xa791, 0xa791, 0xa793, 0xa794, 0xa797, 0xa797, 0xa799, 0xa799, 0xa79b,
    0xa79b, 0xa79d, 0xa79d, 0xa79f, 0xa79f, 0xa7a1, 0xa7a1, 0xa7a3, 0xa7a3, 0xa7a5, 0xa7a5, 0xa7a7,
    0xa7a7, 0xa7a9, 0xa7a9, 0xa7b5, 0xa7b5, 0xa7b7, 0xa7b7, 0xa7b9, 0xa7b9, 0xa7bb, 0xa7bb, 0xa7bd,
    0xa7bd, 0xa7bf, 0xa7bf, 0xa7c1, 0xa7c1, 0xa7c3, 0xa7c3, 0xa7c8, 0xa7c8, 0xa7ca, 0xa7ca, 0xa7cd,
    0xa7cd, 0xa7cf, 0xa7cf, 0xa7d1, 0xa7d1, 0xa7d3, 0xa7d3, 0xa7d5, 0xa7d5, 0xa7d7, 0xa7d7, 0xa7d9,
    0xa7d9, 0xa7db, 0xa7db, 0xa7f6, 0xa7f6, 0xab53, 0xab53, 0xab70, 0xabbf,
];

/// The same for pwsh 7.6.6 on .NET 10.0.12, every code point compared:
/// .NET's own casing table, the same on every system.
const KEEP_CORE: &[u32] = &[
    0x19b, 0x19b, 0x264, 0x264, 0x1c8a, 0x1c8a, 0x2c5f, 0x2c5f, 0xa7c1, 0xa7c1, 0xa7cd, 0xa7cd,
    0xa7cf, 0xa7cf, 0xa7d1, 0xa7d1, 0xa7d3, 0xa7d3, 0xa7d5, 0xa7d5, 0xa7d7, 0xa7d7, 0xa7d9, 0xa7d9,
    0xa7db, 0xa7db, 0x16ebb, 0x16ed3,
];

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs
            .iter()
            .map(|(n, v)| (n.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn claude_and_codex_deltas() {
        let parent = env(&[("bash_max_timeout_ms", "60")]);
        let d = run_delta(Cli::Claude, Some(r"C:\h"), Some(780000), &parent);
        let names: Vec<&str> = d.iter().map(|(n, _)| n.as_str()).collect();
        assert_eq!(
            names,
            [
                "CLAUDE_CONFIG_DIR",
                "MCP_TOOL_TIMEOUT",
                "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS",
                "BASH_DEFAULT_TIMEOUT_MS",
                "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"
            ]
        );
        assert_eq!(d[1].1.as_deref(), Some("780000"));
        assert_eq!(
            run_delta(Cli::Codex, None, Some(1), &parent),
            [("CODEX_HOME".to_string(), None)]
        );
    }

    #[test]
    fn delta_over_the_parent() {
        let parent = env(&[("Path", "p"), ("ClaudeCode", "1"), ("Gone", "g")]);
        let delta = [
            ("PATH".to_string(), Some("q".to_string())),
            ("gone".to_string(), Some(String::new())),
            ("New".to_string(), Some("n".to_string())),
        ];
        let e = child_env(&parent, &delta, Flavour::Core);
        assert_eq!(e, env(&[("Path", "q"), ("New", "n")]));
        assert_eq!(block(&e, Flavour::Core), ["New=n", "Path=q"]);
    }

    #[test]
    fn name_order_by_edition() {
        let astral = "\u{10000}X";
        let last = "\u{FFFD}X";
        assert_eq!(cmp_names(astral, last, Flavour::Desktop), Ordering::Less);
        assert_eq!(cmp_names(astral, last, Flavour::Core), Ordering::Greater);
        assert!(same_name("\u{1C5}x", "\u{1C4}X", Flavour::Core));
        assert!(!same_name("\u{1C5}x", "\u{1C4}X", Flavour::Desktop));
        assert!(!same_name("\u{131}", "I", Flavour::Core));
        assert!(same_name("\u{1F80}", "\u{1F88}", Flavour::Desktop));
        assert_eq!(cmp_names("a_c", "A[", Flavour::Desktop), Ordering::Greater);
        assert_eq!(cmp_names("AB", "AB1", Flavour::Core), Ordering::Less);
    }
}
