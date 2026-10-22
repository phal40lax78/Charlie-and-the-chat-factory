# chatq-brain

The detachable brain: a classifier behind one localhost contract, answered by
one of three backends that `data/brain/brain.json` picks: **Gemini** through
the Gemini API (the default), **Claude Haiku** through the Anthropic API, or a
**local** llama.cpp `llama-server` the brain downloads on request and
supervises. Contract and design: [SPEC.md](SPEC.md). This
crate is standalone (its own `[workspace]` table in `Cargo.toml`), not a
member of `native/Cargo.toml` until SPEC section 8. Everything it needs at run
time lives in one folder, `data/brain/`; uninstall is the overlay stopping it
and deleting that folder.

No fallback: the four model tasks (`scope_drift`, `contradiction`,
`unread_reply`, `prompt_quality`) are answered by the backend or not at all.
When it does not answer, `/classify` is 503 `{contract, state, note}` with no
labels, and the overlay discards that event: no line, no tag. `fail_kind` and
`extract` answer from the regex layer ([rules::classify](src/rules.rs)); a
`fail_kind` escalation that fails keeps its regex answer.

## Run the mock (no key, no network)

```
cargo run --manifest-path native/brain/Cargo.toml -- --mock --data native/brain/target/mock-data
```

It binds `127.0.0.1` on a free port, writes `port` and a fresh 32-byte hex
`token` into `--data`, and answers the three routes. Regex tasks run the regex
layer; model tasks answer canned labels from
[vectors/mock-answers.json](vectors/mock-answers.json) (compiled in), tier
`model`, why `mock:<task>@1`. `/health` says `backend: "mock"`, `model: null`.
Ctrl-C removes `port` and `token`. Wire the overlay against it:

```
curl -H "Authorization: Bearer <token file>" http://127.0.0.1:<port file>/health
curl -H "Authorization: Bearer <token file>" http://127.0.0.1:<port file>/usage
curl -H "Authorization: Bearer <token file>" -H "Content-Type: application/json" \
     -d '{"task":"prompt_quality","schema_id":"prompt_quality@1","transcript_tail":{"turns":[{"role":"user","text":"fix it"}],"tool_out":""}}' \
     http://127.0.0.1:<port file>/classify
```

Flags: `--data <dir>` (default: the folder the exe sits in), `--mock`,
`--port <n>` (default 0 = any).

## Pick a backend: brain.json

Without `--mock` the brain reads `data/brain/brain.json` at startup
([config::backend](src/config.rs), [Engine.from_config](src/engine.rs)).
Every field is optional:

```
{"backend": "gemini",                  // or "anthropic" or "local"; missing = "gemini"
 "model": "<id>",                      // the model of the backend named above
 "gemini":    {"model": "gemini-3.1-flash-lite"},
 "anthropic": {"model": "claude-haiku-4-5-20251001"},
 "local":     {"model": "phi-4-mini-q4km",   // a catalogue id; /install writes it
               "gpu": false,                 // true = Vulkan build, -ngl 99
               "timeout_ms": 10000}}         // one local answer's wait
```

- **backend** is read once; change it and restart chatq-brain. Anything but
  the three names (`"openai"`, `"Gemini"`, `""`, a number) stops the start:
  exit 1, `brain.json: unknown backend ...` on stderr and in `brain.log`, no
  `port` or `token`. Never a silent fallback.
- **model**: a backend's own section wins, else the top-level `"model"` if
  that backend is the configured one, else its default. So a top-level model
  never leaks into another backend. Read on every call.
- **Keys**: gemini reads `data/brain/gemini-key`, else `GEMINI_API_KEY`;
  anthropic reads `data/brain/anthropic-key`, else `ANTHROPIC_API_KEY`. One
  line, trimmed; a blank file counts as missing. Each backend reads only its
  own. Local needs none.
- `/health` and `/usage` name the backend's model on all three.

**Gemini stays the default.** In the 2026-10-22 bakeoff on this PC (SPEC
section 9) the local models were slower (about 7 s an answer for a 4B on the
CPU, against the overlay's 2.5 s) and weaker (no model beat "always no" by
more than one case of 40) than Gemini. Local is for a PC with no network or
no key; Claude for a user who would rather not add Google.

## Run it for real: gemini (Tier 1, needs the user's go-ahead and a key)

The Gemini backend ([Engine.gemini](src/engine.rs)) downloads nothing and
needs:

- **A key.** `data/brain/gemini-key`, one line, trimmed; else the
  `GEMINI_API_KEY` environment variable ([config::api_key](src/config.rs)).
  Read on every call, so a key saved by the overlay works at the next event.
  It is never logged, never put in a URL, never answered back; `/health` says
  only `key: "present" | "missing"`. No key: every model task is 503
  `no key`, `state: "unconfigured"`, and nothing is sent. Use a **paid
  (billing-enabled) key**; see Privacy below.
- **Optionally a model.** `data/brain/brain.json` `{"model": "<id>"}` or
  `{"gemini": {"model": "<id>"}}`; absent or blank means
  `gemini-3.1-flash-lite`
  ([config::DEFAULT_MODEL](src/config.rs)), with minimal thinking: as
  accurate as `gemini-3.5-flash-lite`, twice as fast and cheaper.

Each model task is one
`POST https://generativelanguage.googleapis.com/v1beta/models/<model>:generateContent`
([gemini::call](src/gemini.rs)) with the key in the `x-goog-api-key` header:
the task's `schemas/<task>@1.txt` as `systemInstruction`, the rendered tail
as the one user turn, and `generationConfig` temperature 0,
`maxOutputTokens` 300, `responseMimeType: "application/json"`, the task's
schema as `responseJsonSchema` (unsupported keywords stripped, untyped string
enums typed; [gemini::json_schema](src/gemini.rs)), and
`thinkingConfig: {thinkingLevel: "minimal"}` (`thinkingBudget: 0` for a
`gemini-2.*` model; [gemini::thinking_config](src/gemini.rs)). The JSON
answer is checked against the full original schema
([schema::validate](src/schema.rs)) before it counts. The API timeout is
2 300 ms ([gemini::TIMEOUT_MS](src/gemini.rs)), under the overlay's 2 500 ms.
No retries. This request shape was confirmed live on 2026-10-22 against
`gemini-3.5-flash-lite` and `gemini-3.1-flash-lite`: accepted as written,
schema-valid answers, 0 thought tokens at `minimal`. `thinkingBudget: 0`
for `gemini-2.*` is unverified (`gemini-2.5-flash-lite` is 404 for a new
key). **Latency:** `gemini-3.5-flash-lite` took median about 2.55 s and
answered only 6 of 40 calls within the 2 300 ms timeout;
`gemini-3.1-flash-lite` took median about 1.2 s, 79 of 80 within it, so it
is the default since 2026-10-23 (SPEC section 9, Gemini accuracy). With
the tuned prompts all 40 answered within it, max 1.3 s (SPEC section 9,
Tuned prompts).

**503 notes** ([gemini::Fail](src/gemini.rs)): `no key`; `bad key` (400
`API_KEY_INVALID`, 401, 403); `rate limited` (429); `overloaded` (503, 500);
`remote error` (any other HTTP error status, refused connection, DNS, TLS);
`timeout`; `malformed` (no JSON text in the first candidate, text that does
not parse, or JSON off the schema); `blocked` (a safety `finishReason` or a
`promptFeedback.blockReason`). `/health` `note` holds the last one until the
next answer.

**Usage.** Every call that got a response appends one line to
`data/brain/usage.jsonl` ([usage::append](src/usage.rs)): `ts` (local, with
offset), `task`, `model`, `status`, `ms`, `input_tokens`
(`promptTokenCount`), `output_tokens` (`candidatesTokenCount`),
`thought_tokens` (`thoughtsTokenCount`), `cached_tokens`
(`cachedContentTokenCount`) and `cost_usd`. No transcript text, labels or
key. `cost_usd` comes from [usage::PRICES](src/usage.rs), USD per million
tokens, paid tier, from the Gemini pricing page as read 2026-10-22:

| Model | Input | Output (thinking included) | Cached input |
|---|---|---|---|
| `gemini-3.5-flash-lite` | 0.30 | 2.50 | 0.03 |
| `gemini-3.1-flash-lite` (default) | 0.25 | 1.50 | 0.025 |
| `gemini-3.8-flash` | 0.75 | 3.75 | 0.075 |
| `gemini-3.6-flash` | 0.75 | 3.75 | 0.075 |
| `gemini-2.5-flash-lite` | 0.10 | 0.40 | 0.01 |
| `gemini-2.5-flash` | 0.30 | 2.50 | 0.03 |

Cost = uncached input at the input price + cached input at the cached price
+ (output + thought) at the output price. A model with no row (exact id, or
the id plus a numeric version suffix) logs `cost_usd: null` and `/usage`
`note` names it; never a guessed price. `GET /usage` sums the file into
`today`, `month` and `all` by local date ([usage::summary](src/usage.rs)),
each `{calls, errors, input_tokens, output_tokens, thought_tokens, cost_usd,
by_task}`, plus `note`; `/health` carries `month_cost_usd`. The file is never
rotated. On a free-tier key the real bill is $0; `cost_usd` shows the paid
price.

**Cost** (measured 2026-10-22 on the 40 labelled tails). Mean 410 input
tokens a call (system line plus tail; the schema is not counted), 44 output,
0 thought: **$0.17 per 1 000 calls** at the default `gemini-3.1-flash-lite`
(the same with the tuned prompts of 2026-10-23), **$0.23 per 1 000** at
`gemini-3.5-flash-lite` (SPEC section 5).

**Privacy.** The transcript tail the overlay sends (at most 6 turns, 3 000
bytes) goes to Google, a second company beside Anthropic (which Claude Code
already sends the whole chat to). Nothing else leaves the PC. What Google
does with it depends on the key: on the **free tier** Google uses prompts
and responses to improve its products, and human reviewers may read them; on
the **paid tier** (billing enabled) it does not, and keeps them only for a
limited period for abuse detection and legal compliance (Gemini API terms,
"How Google Uses Your Data", read 2026-10-22). Use a paid key.

Tier 1 (SPEC section 6): one call first to confirm the request shape, then
the 40 labelled tails in `data/brain-eval/tails.json` through `/classify`,
scored as the local bakeoff was, `/usage` checked against the run. Done
2026-10-22: $0.009 for the 40 at `gemini-3.5-flash-lite`; results in SPEC
section 9, Gemini accuracy. The `scope_drift` and `contradiction` system
lines were rewritten and rerun on 2026-10-23 (SPEC section 9, Tuned
prompts): ship `unread_reply`, `prompt_quality` (verdict only) and
`scope_drift` (provisionally); `contradiction` still does not ship.

**Test-only:** `CHATQ_BRAIN_API_BASE` replaces
`https://generativelanguage.googleapis.com`
([gemini::BASE_ENV](src/gemini.rs)) so the contract tests can use a local
mock. Never set it on a real install: the key goes wherever it points.

## Run it for real: anthropic (not yet run live)

`{"backend": "anthropic"}` ([Engine.anthropic](src/engine.rs)). Downloads
nothing. Key in `data/brain/anthropic-key` or `ANTHROPIC_API_KEY`; model
`claude-haiku-4-5-20251001` ([anthropic::DEFAULT_MODEL](src/anthropic.rs))
unless `brain.json` names another.

Each model task is one `POST https://api.anthropic.com/v1/messages`
([anthropic::call](src/anthropic.rs)) with headers `x-api-key` (the only
place the key goes) and `anthropic-version: 2023-06-01`; body `model`,
`max_tokens` 300, temperature 0, the task line as `system`, the rendered tail
as the one user message, and one tool named after the task whose
`input_schema` is the labels schema, forced by
`tool_choice: {type: "tool", name: <task>}`. The tool input is checked
against the full schema. Timeout 2 300 ms, no retries.

**503 notes** ([anthropic::Fail](src/anthropic.rs)), the same words as
Gemini's: `no key`; `bad key` (401, 403); `rate limited` (429); `overloaded`
(500, 503, 529); `remote error` (other status, refused connection, DNS, TLS);
`timeout`; `malformed` (no `tool_use` block, unreadable, off-schema);
`blocked` (`stop_reason: "refusal"`).

**Usage and cost.** Lines add `cache_creation_input_tokens` and
`cache_read_input_tokens`. Prices per million tokens
([usage::CLAUDE_PRICES](src/usage.rs)): `claude-haiku-4-5` (dated ids match)
1.00 input, 5.00 output, 1.25 cache write, 0.10 cache read; any other model
logs `cost_usd: null`. At the 40 tails' mean (410 in, 44 out) that is about
$0.63 per 1 000 calls, unmeasured. The tail goes to Anthropic, which already
has the whole chat from Claude Code. The same test-only
`CHATQ_BRAIN_API_BASE` ([anthropic::BASE_ENV](src/anthropic.rs)) points it
at a mock; environment only, never `brain.json`.

## Run it for real: local (not yet run live in 0.4.0)

`{"backend": "local"}` ([supervisor::Local](src/supervisor.rs)). Nothing
loads or downloads at startup; `/health` says `state: "absent"` until a
model is installed.

- **Catalogue**: [manifest.json](manifest.json), built into the exe; a
  `data/brain/manifest.json` that parses replaces it. Seven Q4_K_M GGUFs,
  each pinned to a Hugging Face commit with its sha256 and size:
  `phi-4-mini-q4km` (default), `qwen3.5-4b-q4km`, `qwen3-4b-2507-q4km`,
  `gemma-3-4b-q4km`, `qwen3-1.7b-q4km`, `llama-3.2-1b-q4km`,
  `llama-3.2-3b-q4km`; llama.cpp server builds for `windows-x86_64`,
  `windows-x86_64-vulkan`, `macos-aarch64`, `linux-x86_64`.
- **Install**: `POST /install {"model": "<id>"}` answers 202 and fetches in
  the background: llama-server (when that build is missing) then the GGUF,
  to `<file>.part` with `Range` resume and a streamed sha256, three strikes,
  then `note: "download failed: <reason>"`. `/health` shows
  `downloading` and `download_pct`. The server archive (zip or tar.gz) is
  unpacked with every entry kept inside `server/`, `llama-server(.exe)`
  found in nested folders and lifted out. 400 for an unknown id, 503 `disk`
  under 3 GB free. `/install` writes `local.model`, and a different model
  deletes the old GGUF: one model on disk.
- **GPU is opt-in**: `"local": {"gpu": true}` installs the Vulkan build to
  `server-gpu/` and launches with `-ngl 99`. The CPU build in `server/` is
  the default.
- **Supervision**: lazy load on the first model task, 10 min idle unload,
  `POST /unload` to unload now. Before a load a RAM guard wants free memory
  ≥ GGUF × 1.15 + 300 MB + 1 GiB, else 503 `deferred` (`announce` once per
  10 min, then `quiet`). Launch flags `-c 4096 -np 1 --cache-ram 0 -t
  <half the cores> --no-webui --jinja`, plus the model's own (`-rea off` for
  the Qwen hybrids). `brain.log` gets load, unload, defer and every 503.
- **Timeouts**: one answer waits `local.timeout_ms` (10 000 by default). A
  slow answer is 503 `timeout` and the model stays loaded; only a process
  that died is a `crash` (one strike; three is `backoff` for 10 min).
- **Usage**: one line per answered call with llama-server's token counts and
  `cost_usd: 0`.
- **Known limit**: the overlay gives up on `/classify` after 2.5 s and was
  not changed, so most local answers on a CPU arrive too late and are
  discarded (SPEC section 10).

## Package a release

```
python -I -X utf8 native/brain/tools/package.py
```

It runs `cargo build --release`, then zips `chatq-brain.exe` and this README
into `native/brain/target/package/chatq-brain-<version>-windows-x86_64.zip`
(version from `Cargo.toml`). Beside it, `release-pin.json` holds `target`,
`version`, `file`, `url`, `sha256`, `bytes`. `url` stays `null` until the zip
is published; the script never invents one and never publishes.

The overlay pins this zip in its own manifest: after publishing, copy `url`,
`sha256` and `bytes` from `release-pin.json` into that manifest so the
"Install brain" menu has something to download.

Only `windows-x86_64` is built here. Other targets (macOS, Linux) need their
own build machine; the script does not cross-build.

## Tests (Tier 0)

```
cargo test --manifest-path native/brain/Cargo.toml
```

Nothing leaves `127.0.0.1`; no real API is called, nothing is downloaded,
and no real llama-server runs: `fake-llama-server` (a test-only `[[bin]]`
from `tests/support/fake_llama_server.rs`) stands in for it.

| File | What it pins |
|---|---|
| `vectors/fail_kind.json`, `vectors/extract.json` via `tests/rules_vectors.rs` | the regex layer for the two regex tasks (hits and near-misses, cue ordering), labels against the schemas, catalogue hygiene, and that the model tasks have no rule and no vector file |
| `tests/backends.rs` | `brain.json` picks the backend and each backend its own model (`/health`, `/usage`); unknown backends are errors, and the built exe exits 1 on one without writing `port`/`token`; `/install` and `/unload` only on local; a local engine starts `absent` and fetches nothing |
| `tests/anthropic.rs` | the Claude backend against [testutil::MockAnthropic](src/testutil.rs): headers and body (forced tool, `max_tokens` 300, temperature 0, `anthropic-version`), `brain.json` model, success with cache-token usage line and cost, no key (only a `gemini-key`, a blank file), env fallback, every status note, timeout, malformed, refusal = blocked, refused connection, no transcript or key in files or responses, `fail_kind` escalation, `/usage` totals, unpriced model, `/health` |
| `tests/local.rs` | the local backend with fakes ([testutil::FakeLlm](src/testutil.rs), faked clock and memory, [testutil::FileServer](src/testutil.rs) on 127.0.0.1) and with the real process code ([proc::ProcLlama](src/proc.rs) launching `fake-llama-server`): the shipped catalogue and its override, `/health`, lazy load, idle unload, launch flags and GPU opt-in, `/unload`, RAM guard, load backoff, crash vs timeout, usage at cost 0; `/install` start/join/done, nested zip and tar.gz, bad archive, zip-slip and tar-slip, Vulkan pin, sha256 mismatch, `.part` resume, unknown id, low disk, model swap |
| `tests/contract.rs` | the contract over a real socket. Mock: 401, 409, 400/404/405 (`/install` and `/unload` are 404 off local), the three shapes, `mock-answers.json` coverage. Gemini backend against [testutil::MockGemini](src/testutil.rs): URL, `x-goog-api-key` as the only carrier of the key (never the URL), body with schema and thinking setting, `brain.json` override, success with a usage line and its cost (thought and cached tokens), no key (no request, no line, old `anthropic-key` ignored), env-var fallback, 400 `API_KEY_INVALID`/401/403/429/503/500/400/404, timeout, no text / bad text / `MAX_TOKENS` / off-schema, safety stop and prompt block, refused connection, no transcript or key in `usage.jsonl` or `brain.log`, `fail_kind` escalation, `/usage` totals with thought tokens across faked dates, unknown model with null cost and a `/usage` note, `/health` backend `gemini` and key present or missing |
| unit tests in `src/` | backend, key and model reading per backend, `local` options, manifest loading and model swap, port/token files, log rotation, tail rendering, request bodies (Gemini, Claude, llama-server), schema conversion, thinking setting, note mapping, answer picking (thought parts skipped, blocks, tool blocks), price matching and cost for both tables, usage buckets by local date, the unpriced note, the RAM guard, the lifecycle state machine, launch flags, pinned fetch with resume and hash check, archive unpacking and path safety |

Test scratch lives in `native/brain/target/test-tmp/`, never the system temp dir.

## Where this build departs from or fills in SPEC.md

- Layout: one crate at `native/brain/` (lib `chatq_brain` plus bin
  `chatq-brain`), not `crates/chatq-brain` plus `brain-rules` and
  `brain-mock`. The mock is `--mock`. Split at the merge if the overlay wants
  `brain-rules` alone.
- `tests` cue ignores `0 failed` and wants `assertion failed|error`; see the
  header of [rules](src/rules.rs). `n` for `build` is the first integer near the
  cue, so `error CS1002` gives 1002.
- Model answers carry `confidence: 0.8` and `why: "model:<task>@<n>"`; the
  schemas have no `why` field.
- Job-object kill-on-close is the overlay's (a child inherits it). The brain
  polls its parent pid on Unix only.
- TLS is ureq with `native-tls` (SChannel on Windows); the real endpoint
  was first called from this crate on 2026-10-22. On a PC whose firewall
  blocks outbound by default, the exe needs its own allow rule: a copy at
  another path fails with os error 10013 (`remote error`).
