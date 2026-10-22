# chatq-brain: the detachable brain (SPEC)

Draft 2026-10-22, reworked the same day for a hosted backend, first Claude Haiku, then (0.3.0) **Gemini**, the user's choice. 0.4.0 (2026-10-23) makes the backend selectable in `brain.json`: **`gemini`** (the default, unchanged), **`anthropic`** (Claude Haiku through the Anthropic API) or **`local`** (a llama.cpp `llama-server` the brain downloads on request and supervises). Standalone Cargo workspace in `native/brain/`, not a member of `native/Cargo.toml` until the merge (§8). The overlay (`native/overlay/`) reads chat transcripts; a regex layer already names events (a failed task, a stack trace). The judgement cases (a contradiction between two prompts, scope drift, an unanswered question) need a language model. Local models were slower and less accurate than Gemini on this PC (§9), so the default is **Gemini through the Gemini API**; Claude and a local model are one `brain.json` line away. All three sit behind one localhost contract, never a dependency: the overlay runs with no brain or with this one and switches live. The brain is a **classifier only**: temperature 0, JSON output constrained by the task's labels schema, a kind and its slots. It never writes a line the mascot says; the words come from the overlay's stock bank or the installed skin pack (`data/skins/<pack>/lines.js`), which the brain never reads.

## 0. Decisions already taken

- **Modes.** Overlay menu Brain = Off / Regex only / Gemini; default Regex only. Off = no transcript classification at all. The tag in the panel reads `BRAIN: OFF | REGEX | GEMINI`, dimmed while unreachable or without a key.
- **Three backends, Gemini the default** ([config::backend](src/config.rs), read once at startup). `brain.json` `"backend"`: `"gemini"`, `"anthropic"` or `"local"`; missing (or no `brain.json`) is `gemini`. Any other value (`"openai"`, `"Gemini"`, `""`, a number) is not a fallback: chatq-brain logs `not started: brain.json: unknown backend …` to `brain.log`, prints the same to stderr, exits 1 and never writes `port` or `token`. Each backend has its own model (§1). Changing the backend takes a restart of chatq-brain; changing a model does not.
- **Gemini, the default backend, not a local model** (decided 2026-10-22 after §9; Gemini replaced Claude Haiku the same day at the user's choice; 0.4.0 brings Claude and the local path back as opt-in backends). Default model `gemini-3.1-flash-lite` ([config::DEFAULT_MODEL](src/config.rs)), minimal thinking, structured output: as accurate as `gemini-3.5-flash-lite` (Google's recommended model for new projects, the default until 2026-10-23), twice as fast and cheaper, and it answered 79 of 80 calls within the brain's 2 300 ms timeout where 3.5-flash-lite managed 6 of 40 (§9, Gemini accuracy). Overridable in `data/brain/brain.json` `{"model": "..."}` or `{"gemini": {"model": "..."}}`. The gemini and anthropic backends run no llama-server, hold no GGUF, download nothing and have no RAM guard.
- **Separate process.** Everything the brain needs lives in `data/brain/` next to the exe (never `%APPDATA%`/`%TEMP%`); uninstall is deleting the folder. The overlay talks to `chatq-brain(.exe)` only, never to an API or a llama-server itself.
- **Installed from the menu.** The overlay menu's "Install brain" fetches the chatq-brain release zip (pinned in the overlay's own manifest) into `data/brain/`. The gemini and anthropic backends download nothing more. The local backend downloads its pinned llama-server and GGUF only on `POST /install` (§2, The local backend), never from `/classify`.
- **The key is the user's.** Gemini: a Gemini API key (Google AI Studio), entered in the overlay's settings, written to `data/brain/gemini-key`; `GEMINI_API_KEY` is the fallback. A **paid (billing-enabled) key is recommended**: on the free tier Google uses the prompts to improve its products (§5). Anthropic: `data/brain/anthropic-key`, else `ANTHROPIC_API_KEY`. Each backend reads only its own key. No key, no model answers. The local backend needs no key.
- **Every call is counted.** One line per API call in `data/brain/usage.jsonl` with tokens and cost; `GET /usage` sums it (§5).
- **Features declare a tier; no fallback.** A feature is `regex` or `model`. A regex feature (`fail_kind`, `extract`) answers from the regex layer: that is its primary path, not a fallback. A model feature (`scope_drift`, `contradiction`, `unread_reply`, `prompt_quality`) has **no regex stand-in**: when the backend does not answer for any reason (no key, bad key, rate limit, overload, network, timeout, off-schema answer, safety block or refusal; on local also not installed, downloading, deferred by the RAM guard, loading, load failed, backoff, crash), `/classify` returns 503 with no labels and the overlay **discards that feature's event entirely: no line, no tag**. So Regex only mode, a missing brain, a missing key and an unreachable API all mean the four model features are silent.

## 1. Process model

```
overlay ──spawn──▶ chatq-brain  ──HTTPS──▶ generativelanguage.googleapis.com/v1beta/models/<model>:generateContent
   │ HTTP 127.0.0.1:<port>, Bearer <token>      x-goog-api-key from data/brain/gemini-key
   └──── data/brain/port, data/brain/token (written by chatq-brain at bind)

backend "anthropic":  chatq-brain ──HTTPS──▶ api.anthropic.com/v1/messages   (x-api-key from data/brain/anthropic-key)
backend "local":      chatq-brain ──spawn──▶ data/brain/server[-gpu]/llama-server  ──HTTP 127.0.0.1:<free port>──▶ /v1/chat/completions
```

**Spawn.** With mode = Gemini and `data/brain/chatq-brain(.exe)` present, the overlay spawns it with `--data <abs data/brain>`, and kills it when the mode leaves Gemini. On Windows the child sits in the overlay's job object with `KILL_ON_JOB_CLOSE`, so it never outlives the overlay; on macOS it polls its parent pid every 5 s and exits when it is gone. Missing exe → the menu item reads `Gemini (not installed)`, the menu offers Install brain, and the mode falls to Regex only.

**Uninstall** is the overlay's alone: kill chatq-brain (it removes `port`/`token`), then delete `data/brain/`. That deletes the key file and the usage file too.

**Bind.** `127.0.0.1:0`; the chosen port goes to `data/brain/port` (decimal, no newline) and a fresh 32-byte random token, hex, to `data/brain/token` (mode 0600 on Unix), both written whole through a rename; both deleted at a clean exit. Every request carries `Authorization: Bearer <token>`; a wrong or missing token is 401 with an empty body. The overlay re-reads both files after any connection refused, so a restart needs no overlay restart.

**Key and model are read per call** ([config::api_key](src/config.rs), [config::anthropic_key](src/config.rs), [config::model](src/config.rs), [config::anthropic_model](src/config.rs), [config::pick_model](src/config.rs)). Key: gemini reads `gemini-key` (one line, trimmed), else `GEMINI_API_KEY`; anthropic reads `anthropic-key`, else `ANTHROPIC_API_KEY`; a blank file counts as missing. Model: `brain.json` `{<backend>: {model}}`, else the top-level `"model"` when `<backend>` is the configured one, else that backend's default (`gemini-3.1-flash-lite`, `claude-haiku-4-5-20251001`, or the catalogue's `default`, `phi-4-mini-q4km`). So a top-level `"model"` never leaks into another backend's section. A key saved in the overlay's settings takes effect on the next event, with no restart. The key is never logged, never written anywhere else, never in a URL, never in any response; `/health` says only `key: "present" | "missing"`.

**brain.json** (all fields optional; the overlay's picker and `/install` write it):

```
{"backend": "gemini" | "anthropic" | "local",           // missing = "gemini"; read at startup
 "model":   "<id>",                                      // the configured backend's model
 "gemini":    {"model": "<gemini id>"},
 "anthropic": {"model": "<claude id>"},
 "local":     {"model": "<catalogue id>",                // /install writes this
               "gpu": false,                             // true = Vulkan build + -ngl 99
               "timeout_ms": 10000}}                     // one local answer's wait
```

A section model wins over the top-level `"model"`. `local.gpu` is read on every load and install; anything but `true` is `false`. `local.timeout_ms` is read on every call; missing, 0 or not a number is 10 000 ([config::DEFAULT_LOCAL_TIMEOUT_MS](src/config.rs)). `/install` rewrites only `local.model` and keeps every other field.

## 2. The contract

The overlay holds one client ([brain::Client](crates/brain-rules/src/client.rs), at the merge): `base_url` + token, from the port and token files. Three routes on every backend, five on local, JSON both ways, `Content-Type: application/json`, contract version in every answer. The client timeout is 2 500 ms for `/classify` (past it a model task's event is discarded, exactly as on a 503; a `fail_kind` escalation keeps its regex verdict), 1 000 ms for the rest. The brain's own API timeout is 2 300 ms on both API backends ([gemini::TIMEOUT_MS](src/gemini.rs), [anthropic::TIMEOUT_MS](src/anthropic.rs)), so a slow API answer comes back as 503 `timeout` before the overlay gives up. The local backend's is `local.timeout_ms` (10 000 by default), longer than the overlay's: see §10.

| Route | Body | Answer |
|---|---|---|
| `GET /health` | – | gemini, anthropic, mock: `{contract: 1, backend: "gemini"\|"anthropic"\|"mock", model: "<id>"\|null, state: "ready"\|"unconfigured", key: "present"\|"missing", month_cost_usd, note: str\|null}`; `note` is the last call's 503 note, cleared by the next answer. local: `{contract: 1, backend: "local", model: "<catalogue id>"\|null, state: "absent"\|"downloading"\|"cold"\|"loading"\|"hot"\|"deferred", resources_pct: 0..100\|null, idle_s, download_pct: 0..100\|null, note: str\|null}`; `download_pct` only while `downloading`, `note` only after a failed `/install` (`download failed: <reason>`) |
| `POST /classify` | `{task, transcript_tail, schema_id}` | 200 `{contract, labels, confidence, tier: "model"\|"regex", why}`; 503 `{contract, state, note}` when a model task gets no answer |
| `GET /usage` | – | `{contract, model, note, today, month, all}`, each bucket `{calls, errors, input_tokens, output_tokens, thought_tokens, cost_usd, by_task: {<task>: {calls, cost_usd}}}`; `note` is null, or names a model with no price row (§5); on local `note` is always null and `cost_usd` 0 |
| `POST /install` (local only) | `{model: "<catalogue id>"}` | 202 `{contract, state: "downloading", model}` (started, or joined a running fetch, whose id it names); 200 `{contract, state, model}` when server and model are already on disk; 400 `{error: "unknown model", known: [ids]}`, or 400 `{error: "<why>"}` for a body that is not `{model: "<id>"}`; 503 `{contract, state, note: "disk"\|"busy"}` |
| `POST /unload` (local only) | `{}` | `{contract, state}`; kills llama-server now if `hot` (then `cold`), keeps the file; a no-op in any other state |

Any other path is 404, a known path with the wrong method 405. `/install` and `/unload` exist on the local backend only; on gemini, anthropic and the mock they are 404 like any unknown path, whatever the method. Both need the token like every route.

- `task` names a catalogue entry (§3). `schema_id` is `"<task>@<n>"`, the schema version the overlay compiled against ([catalogue::SCHEMA_IDS](crates/brain-rules/src/catalogue.rs) at the merge); a brain that does not know it answers 409 `{known: [...]}` and the overlay drops that task (a model task) or keeps its own regex answer (a regex task).
- `transcript_tail`: `{chat, turns: [{role: "user"|"assistant", text}], tool_out}`, newest last, cut by the overlay to 3 000 bytes of text (older turns dropped first, then `tool_out` from its head), at most 6 turns. Nothing else leaves the overlay: no paths outside the text, no usage, no keys.
- `tier` is `model` for every model-task answer and for a `fail_kind` escalation the backend answered, `regex` for the regex tasks. A model task never answers `regex`.
- `labels` is the task's schema object, always complete: the backend's JSON answer must validate against the full schema ([schema::validate](src/schema.rs)), and the regex rules of `fail_kind` and `extract` fill every field, with `null` where they cannot. `confidence` 0..1 (regex hits report 1.0 on an exact cue, lower per §3; model answers 0.8). `why` is one line for the hover card: `model:<task>@<n>`, or the regex rule's name.
- **503 notes, gemini** ([gemini::Fail](src/gemini.rs) `note`): `no key` (no key file and no env var; nothing is sent), `bad key` (400 whose error names `API_KEY_INVALID`, 401 or 403), `rate limited` (429), `overloaded` (503 `UNAVAILABLE`, or 500), `remote error` (any other 4xx/5xx, connection refused, DNS, TLS), `timeout` (no full answer within 2 300 ms), `malformed` (a 200 with no JSON text in the first candidate, text that does not parse, e.g. cut by `MAX_TOKENS`, an unreadable body, or JSON that fails the schema), `blocked` (a safety `finishReason`: `SAFETY`, `RECITATION`, `BLOCKLIST`, `PROHIBITED_CONTENT`, `SPII`, `IMAGE_SAFETY`; or any `promptFeedback.blockReason`). `state` is `unconfigured` with `no key`, `ready` otherwise.
- **503 notes, anthropic** ([anthropic::Fail](src/anthropic.rs) `note`), the same words: `no key` (no `anthropic-key` and no `ANTHROPIC_API_KEY`; a `gemini-key` is never read; nothing is sent), `bad key` (401, 403), `rate limited` (429), `overloaded` (500 `api_error`, 503, 529 `overloaded_error`), `remote error` (any other status, connection refused, DNS, TLS), `timeout` (2 300 ms), `malformed` (a 200 with no `tool_use` block for the task, an unreadable body, or tool input that fails the schema), `blocked` (`stop_reason: "refusal"`). `state` as for gemini.
- **503 notes, local** ([supervisor::Local.ask](src/supervisor.rs)): `no model` (empty catalogue), `not installed` (no GGUF or no llama-server for the `gpu` setting), `downloading`, `loading` (a load is running past the 2 s wait), `load failed`, `backoff` (three failed loads; 10 min), `announce` / `quiet` (the RAM guard deferred; `announce` at most once per 10 min, for the overlay's `Resources available: 12%. Thinking: Deferred.` line), `timeout` (no answer within `local.timeout_ms`; the model stays loaded), `malformed` (not JSON, or off-schema; counted in `brain.log`), `remote error` (llama-server answered an error status but is still running), `crash` (llama-server died mid-answer; one load strike, reload on the next request). `state` is the lifecycle state at that moment.
- The overlay treats every 503 the same way: discard the event, no line, no tag; the note is for the hover, the brain-status line and the log.

**The model call** ([Engine.ask_model](src/engine.rs), [gemini::request_body](src/gemini.rs), [gemini::call](src/gemini.rs)): `POST {base}/v1beta/models/{model}:generateContent` with headers `x-goog-api-key: <key>` and `content-type: application/json` (the key never goes in the URL as `?key=`), and body

```
{systemInstruction: {parts: [{text: <schemas/<task>@1.txt>}]},
 contents: [{role: "user", parts: [{text: "[user] …\n[assistant] …\n[tool] …\n"}]}],
 generationConfig: {temperature: 0, maxOutputTokens: 300,
                    responseMimeType: "application/json",
                    responseJsonSchema: <schemas/<task>@1.json, see below>,
                    thinkingConfig: {thinkingLevel: "minimal"}}}
```

- **The schema** goes in `responseJsonSchema`, which takes JSON Schema (type arrays such as `["string", "null"]`, `additionalProperties`) where the older `responseSchema` takes an OpenAPI subset. [gemini::json_schema](src/gemini.rs) keeps only the keywords the structured-output page lists (`type`, `properties`, `required`, `additionalProperties`, `enum`, `format`, `minimum`, `maximum`, `items`, `prefixItems`, `minItems`, `maxItems`, `title`, `description`) and adds `"type": "string"` to an untyped all-string `enum` (`fail_kind.kind`, `prompt_quality.issues.items`). The catalogue schemas lose nothing else. The docs say `additionalProperties` is accepted but not enforced by constrained decoding, so the answer is checked against the **full original schema** locally before it counts.
- **Thinking** ([gemini::thinking_config](src/gemini.rs)): `thinkingLevel: "minimal"` for the 3.x models, `thinkingBudget: 0` (off) for a `gemini-2.*` model named in `brain.json`. Thought tokens count toward `maxOutputTokens` and are billed as output; a label object is about 60 tokens, so 300 leaves room. **Confirmed live 2026-10-22** (§9, Gemini accuracy): the body above, camelCase as written (`systemInstruction`, `generationConfig.responseJsonSchema`, `thinkingConfig.thinkingLevel: "minimal"`), was accepted unchanged by `gemini-3.5-flash-lite` and `gemini-3.1-flash-lite`: 200s, schema-valid JSON on all 120 calls, `thoughtsTokenCount` absent (0) on every one, so `minimal` thinks not at all here. `usageMetadata` carried `promptTokenCount` and `candidatesTokenCount`; the `responseJsonSchema` is not counted as prompt (a 3-turn made-up tail was 109 input tokens). `thinkingBudget: 0` for `gemini-2.*` is still unverified: `gemini-2.5-flash-lite` answers this key 404 "no longer available to new users".
- The labels are the first candidate's text parts (parts marked `thought: true` skipped), joined and parsed as JSON. No retries: a failed call is one 503, and the next event is a fresh call. No `cachedContent` and no safety-setting override: the defaults stand, and a block is the `blocked` note. `base` is `https://generativelanguage.googleapis.com`; **test-only**, `CHATQ_BRAIN_API_BASE` replaces it ([gemini::BASE_ENV](src/gemini.rs)), so the contract tests can point at a local mock. A real install never sets it: the key goes wherever it points.

**The Claude call** ([Engine.ask_anthropic](src/engine.rs), [anthropic::request_body](src/anthropic.rs), [anthropic::call](src/anthropic.rs)): `POST {base}/v1/messages` with headers `x-api-key: <key>`, `anthropic-version: 2023-06-01` and `content-type: application/json`, and body

```
{model: "<claude id>", max_tokens: 300, temperature: 0,
 system: <schemas/<task>@1.txt>,
 messages: [{role: "user", content: "[user] …\n[assistant] …\n[tool] …\n"}],
 tools: [{name: "<task>", description: "Record the <task> labels for the coding-chat excerpt.",
          input_schema: <schemas/<task>@1.json, unconverted>}],
 tool_choice: {type: "tool", name: "<task>"}}
```

- **Forced tool use** stands in for structured output: the labels are the `input` of the `tool_use` block named after the task, checked against the full schema locally like Gemini's. No thinking, no retries, no `cache_control` (the stable prefix is a few hundred tokens); the usage line still counts cache tokens if a response reports them.
- Default model `claude-haiku-4-5-20251001` ([anthropic::DEFAULT_MODEL](src/anthropic.rs)). `base` is `https://api.anthropic.com`; the same **test-only** `CHATQ_BRAIN_API_BASE` replaces it ([anthropic::BASE_ENV](src/anthropic.rs)), read from the environment only, never from `brain.json`.
- Not measured live: no Tier 1 run has sent a call to the Anthropic API from this crate, so latency against the 2 300 ms timeout and accuracy on the 40 tails are unknown.

### The local backend

Opt-in with `"backend": "local"`. The brain supervises a llama.cpp `llama-server` it downloaded itself; nothing else is installed and nothing is registered.

**Catalogue** ([manifest.json](manifest.json), built into the exe by `include_str!`; a `data/brain/manifest.json` that parses replaces it, one that does not is ignored). `{default: "<id>", server: {<target>: {url, sha256, bytes}}, models: [{id, file, url, sha256, bytes, ram_mb, args}]}`, `<target>` = [config::server_target](src/config.rs) (`windows-x86_64`, `macos-aarch64`, `linux-x86_64`), plus `windows-x86_64-vulkan` for the GPU build; unknown keys (`license`, `tag`, `about`) are ignored. Every GGUF URL is a Hugging Face `resolve/<40-hex commit>/` link and every hash a lowercase sha256, all from the 2026-10-22 bakeoff runs. Servers: llama.cpp `b11808` for the CPU (`win-cpu-x64`), macOS and Linux builds, `b11814` for `windows-x86_64-vulkan`, the build the bakeoff's GPU pass ran on.

| id | file | bytes | note |
|---|---|---|---|
| `phi-4-mini-q4km` (default) | Phi-4-mini-instruct-Q4_K_M.gguf | 2 491 874 272 | best key total of the bakeoff (§9) |
| `qwen3.5-4b-q4km` | Qwen3.5-4B-Q4_K_M.gguf | 2 740 937 888 | `-rea off` |
| `qwen3-4b-2507-q4km` | Qwen3-4B-Instruct-2507-Q4_K_M.gguf | 2 497 281 120 | |
| `gemma-3-4b-q4km` | gemma-3-4b-it-Q4_K_M.gguf | 2 489 894 016 | |
| `qwen3-1.7b-q4km` | Qwen3-1.7B-Q4_K_M.gguf | 1 107 409 472 | `-rea off` |
| `llama-3.2-1b-q4km` | Llama-3.2-1B-Instruct-Q4_K_M.gguf | 807 694 464 | |
| `llama-3.2-3b-q4km` | Llama-3.2-3B-Instruct-Q4_K_M.gguf | 2 019 377 696 | |

The model is `brain.json` `local.model` (or the top-level `"model"`), else the catalogue `default`, else its first entry; an id the catalogue lacks falls back to the default ([config::pick_model](src/config.rs)).

**Install** ([Local.install](src/supervisor.rs), [fetch::get_pinned](src/fetch.rs), [fetch::unpack_server](src/fetch.rs)). Only `POST /install {model}` downloads. It makes `<id>` the choice (writes `brain.json` `local.model`, keeping the other fields), then fetches in a background thread and answers 202 at once; a second `/install` while one runs joins it. The llama-server archive comes first when the build for the `gpu` setting is not on disk (`<target>-vulkan` into `server-gpu/` with `"gpu": true`, else `<target>` into `server/`; macOS has no Vulkan pin and its plain build already uses Metal), then the GGUF. Bytes go to `<file>.part` with `Range` resume and the sha256 streamed as they arrive; a mismatch at the end deletes the `.part`. Up to three attempts per `/install` (a short read resumes, a mismatch starts over); after the third the state goes back to `absent` and `/health` carries `note: "download failed: <reason>"` until the next `/install`. Archives: `.zip` (Windows) or `.tar.gz` (macOS, Linux), by URL suffix, unpacked into a staging folder that replaces `server/` (or `server-gpu/`) only when every entry stayed inside it (no `..`, no root, no drive prefix; a tar symlink only when relative with no `..`) and `llama-server(.exe)` was found up to four folders deep, its folder lifted to the top; otherwise the attempt fails and counts as a strike. The archive is deleted either way. Under 3 GB free disk `/install` refuses with 503 `disk`; while a load still holds the old model, 503 `busy`. `/health` shows `downloading` with `download_pct` over both files, then `cold`.

**Model swap.** A `brain.json` whose local model differs from the loaded one (checked on every `/classify` and at startup) stops llama-server and deletes every other `*.gguf` and `*.gguf.part` in `data/brain/` ([config::swap_models](src/config.rs)); the new one is fetched only by the next `/install`, and until then model tasks get 503 `not installed`. Never two models on disk.

**Lifecycle** ([Lifecycle.on_request](src/supervisor.rs)): `absent` (no file), `downloading`, `cold` (file, no process), `loading`, `hot`, `deferred` (the guard said no; retried after 60 s). A `/classify` for a model task in `cold` runs the RAM guard, then spawns llama-server on `127.0.0.1:<free port>` and polls its `GET /health` until 200 (up to 30 s, [proc::START_WAIT](src/proc.rs)); the request waits on the load up to 2 s, then gets 503 `loading`. Three failed loads in a row: `backoff` for 10 min. **Lazy:** nothing loads at startup. **Idle unload:** 10 min after the last `/classify` the process is killed and the state is `cold`. Once a second [Engine.tick](src/engine.rs) checks the idle clock and whether llama-server is still running; one that exited between requests is a load strike, and the next request reloads.

**RAM guard** ([supervisor::ram_guard](src/supervisor.rs)). Before a load, free physical memory (`GlobalMemoryStatusEx` `ullAvailPhys` on Windows, `MemAvailable` on Linux) must be ≥ `gguf bytes × 1.15 + 300 MB + 1 GiB` (the 1 GiB a fixed reserve left free after the load): about 4.0 GiB for a 2.5 GB 4B model, 2.2 GiB for the 1B. Otherwise 503 `deferred` with `announce` or `quiet`, no spawn, and `brain.log` `defer free=<n> need=<n>` on each `announce`. With no reading (macOS is not wired) the load goes ahead.

**Launch** ([supervisor::launch_args](src/supervisor.rs), [proc::ProcLlama](src/proc.rs)): `--host 127.0.0.1 --port <free> -m <gguf> -c 4096 -np 1 --cache-ram 0 -t <half the cores> --no-webui --jinja`, then `-ngl 99` with `"gpu": true`, then the model's own `args`. `-c 4096` and one slot keep the KV cache small; `--cache-ram 0` turns off the host prompt cache, which grew private bytes by gigabytes across the bakeoff's 40 calls (§9). **GPU is opt-in**: the bakeoff's best latency was Phi-4-mini on the Iris Xe Vulkan build, but an iGPU driver is a new way to fail, so the default is the CPU build.

**The local call** ([llm::ask](src/llm.rs)): `POST http://127.0.0.1:<port>/v1/chat/completions` `{messages: [{role: "system", content: <task line>}, {role: "user", content: <rendered tail>}], temperature: 0, max_tokens: 300, cache_prompt: false, response_format: {type: "json_schema", json_schema: {schema: <labels schema>}}}`, the whole request bounded by `local.timeout_ms`. **A slow answer is not a crash:** a timeout is 503 `timeout` with llama-server still loaded. An error with the process still running is `remote error`; only a process found dead within 200 ms of the failure is a `crash`.

**Log lines** (`brain.log`, never transcript text): `load start [(gpu)]`, `load ready <ms> ms`, `load failed: <why>`, `unload (idle)`, `unload (explicit)`, `llama-server exited; unloading`, `llama-server died: <why>`, `defer free=… need=…`, `model swap to <id>, removed [...]`, `install <id> strike <n>: <why>`, `install <id> done`, `local <task> <ms> ms`, `local <task> timeout after <ms> ms`, `malformed model answer for <task> (total <n>)`, and `503 <task> <state> <note>` for every 503.

## 3. Task catalogue

Each entry: tier, schema (JSON Schema draft 7, `additionalProperties: false`), the model definition line, and for the regex tier only, the rule ([rules::classify](src/rules.rs), every pattern valid in Rust's `regex`: no lookaround, no backreference). Model-tier tasks have no rule. Schemas are kept as files under `native/brain/schemas/<task>@<n>.json`; the table shows the shape. The same schema, converted as §2 says, is the `responseJsonSchema`.

| task | tier | labels schema | regex rule (confidence) |
|---|---|---|---|
| `fail_kind@1` | regex (the model only when regex finds `none` and `tool_out` holds `error`; if that escalation cannot run, the regex answer stands) | `{kind: enum[none, tests, build, gaveup, loop, revert, timeout, merge, lint, crash, scope, permission, clarify, missing], n: int\|null, file: str\|null, tool: str\|null, attempt: int\|null}` | the 13 cues below, first match in table order (1.0); `n` is the first integer within 40 bytes of the cue, `file` the first path token on the cue's line |
| `scope_drift@1` | model | `{drifted: bool, asked: int, done: int, extra: [str]}` | none: 503 when the model does not answer |
| `contradiction@1` | model | `{contradicts: bool, earlier: str\|null, later: str\|null}` | none: 503 when the model does not answer |
| `unread_reply@1` | model | `{asked: bool, answered: bool, question: str\|null}` | none: 503 when the model does not answer |
| `prompt_quality@1` | model | `{score: int 0..3, issues: [enum[vague, no_file, no_goal, no_check, too_long]]}` | none: 503 when the model does not answer |
| `extract@1` | regex | `{task: str, file: str\|null, error: str\|null}` | task = first line of the newest user turn cut at 80; file = first path token in `tool_out`, else in the assistant text; error = first line matching `(?i)\berror\b\|panicked at\|Traceback\|exception` cut at 120 (1.0) |

**The 13 fail kinds** (`fail_kind`): `tests` `(?i)\b\d+ failed\b\|\bFAILED\b\|AssertionError\|\bassertion\b`; `build` `error TS\d+\|error CS\d+\|error\[E0\|(?i)compilation failed`; `gaveup` `(?i)\bI (cannot\|can't\|could not\|couldn't\|was unable)\b\|(?i)\b(do\|run\|apply) (it\|this\|that) manually`; `loop` the same `(?i)let me try again\|different approach` 3+ times in the tail; `revert` `(?i)\breverted\b\|undone my change\|rolled back\|git (checkout --\|revert)`; `timeout` `(?i)timed out\|TimeoutError`; `merge` `^<{7} \|^>{7} \|CONFLICT \(content\)`; `lint` `(?i)\b\d+ problems?\b\|\b\d+ errors?, \d+ warnings?`; `crash` `^Traceback\|panicked at\|Unhandled exception\|^\s+at .+\(.+:\d+\)`; `scope` `(?i)\bI also\b\|while I was at it\|additionally,? I (refactored\|renamed\|moved\|cleaned)`; `permission` `(?i)permission denied\|the user declined\|I would need permission`; `clarify` `(?i)which .{0,40} do you mean\|could you clarify\|did you mean\|I see \d+ .{0,40} which one`; `missing` `(?i)no such file\|ENOENT\|cannot find module\|ModuleNotFoundError\|not found in the repo`. Order matters: `crash` is checked before `tests` so a traceback inside a test run reads as crash, `merge` before `build`. The cue table is the one the skin pack's `fail` event already keys on, so a pack needs no change.

The model definition lines (system prompts) live beside the schemas as `schemas/<task>@<n>.txt`, under 80 words each, every one of the form "You classify a coding-chat excerpt. Answer only the JSON. `kind` is … Say `none` when unsure." They were written for the small local models. After the Tier 1 run (§6) the `scope_drift` and `contradiction` lines were rewritten for Gemini on 2026-10-23 (§9, Tuned prompts): each now names the look-alikes that are not the real thing. The schemas and their ids did not change; the other four lines are as written.

## 4. data/brain/ layout

```
D/brain/chatq-brain(.exe)   unpacked by the overlay's "Install brain" from the release zip
D/brain/README.md           from the same zip
D/brain/gemini-key          one line, the Gemini API key; written by the overlay's settings (0600 on Unix)
D/brain/anthropic-key       one line, the Anthropic API key; read by the anthropic backend only
D/brain/brain.json          {backend, model, gemini, anthropic, local} (§1), optional; absent = gemini, gemini-3.1-flash-lite
D/brain/manifest.json       optional; replaces the built-in local catalogue when it parses
D/brain/server/             local, CPU: llama-server(.exe) + its dlls, unpacked by /install
D/brain/server-gpu/         local, "gpu": true: the Vulkan build, unpacked by /install
D/brain/<model>.gguf        local: the one catalogue GGUF (<model>.gguf.part while fetching)
D/brain/usage.jsonl         one line per model call (§5); never rotated
D/brain/port, D/brain/token the live brain's address; gone after a clean exit
D/brain/brain.log (+ .1)    diagnostics, 1 MB then rotated once; no transcript text, no key
D/brain.json                the overlay's side: {mode}
```

`D` is `data/` beside the overlay's exe, as every other runtime file (`native/SPEC.md` §4.5). The skin pack sits beside it, `D/skins/<pack>/`, and the two never read each other; the overlay joins them (the brain's `kind` picks the pack's line). **Uninstall-by-delete:** the overlay stops chatq-brain and deletes `D/brain/`; the next start shows `Gemini (not installed)`; delete `D/brain.json` too and the mode is Regex only again. Nothing is registered, no service, no PATH entry, no key outside `D` (unless the user set `GEMINI_API_KEY` or `ANTHROPIC_API_KEY` themselves). Each API backend reads only its own key file: gemini never reads `anthropic-key`, anthropic never reads `gemini-key`. The local backend's server folders and GGUF go with the rest of `D/brain/`.

## 5. Usage, cost and privacy

**Usage file** ([usage::append](src/usage.rs)). After every API call that got a response (any status, a `malformed` or `blocked` 200 included, since it may be billed), one JSON line:

```
{"ts": "2026-10-22T14:03:05.123+09:00", "task": "scope_drift", "model": "gemini-3.1-flash-lite",
 "status": 200, "ms": 812, "input_tokens": 742, "output_tokens": 58,
 "thought_tokens": 12, "cached_tokens": 0, "cost_usd": 0.0002905}
```

`ts` is local time with its offset. Token counts come from the response's `usageMetadata`: `input_tokens` = `promptTokenCount` (the cached part included), `output_tokens` = `candidatesTokenCount`, `thought_tokens` = `thoughtsTokenCount`, `cached_tokens` = `cachedContentTokenCount`; 0 when a field is absent. Error responses carry none, so their line costs 0. No line for `no key` (nothing sent), `timeout` or a network failure (no response). **Never** any transcript text, labels or key: the line is counts only.

- **anthropic** lines ([usage::Line.anthropic](src/usage.rs)) carry two more keys, `cache_creation_input_tokens` and `cache_read_input_tokens`, from the response's `usage`; `input_tokens` and `output_tokens` are Anthropic's own (the fresh input, without the cache parts), `thought_tokens` and `cached_tokens` are 0.
- **local** lines ([usage::Line.local](src/usage.rs)) have the Gemini key set, `input_tokens` / `output_tokens` from llama-server's `prompt_tokens` / `completion_tokens`, and `cost_usd: 0.0`. One line per call that got an HTTP answer from llama-server, none for a 503 before the call (not installed, deferred, loading …) or a timeout.

**Price table** ([usage::PRICES](src/usage.rs)), USD per million tokens, paid-tier Standard, from <https://ai.google.dev/gemini-api/docs/pricing> as read 2026-10-22. A row matches its exact id, or the id plus a numeric version suffix (`gemini-2.5-flash-001`); `gemini-2.5-flash-lite` never falls back to the `gemini-2.5-flash` row, and a `-preview-…` id is unpriced.

| Model | Input | Output (thinking included) | Cached input |
|---|---|---|---|
| `gemini-3.5-flash-lite` | 0.30 | 2.50 | 0.03 |
| `gemini-3.1-flash-lite` (default) | 0.25 | 1.50 | 0.025 |
| `gemini-3.8-flash` | 0.75 | 3.75 (through 2026-12-31 per the page) | 0.075 |
| `gemini-3.6-flash` | 0.75 | 3.75 | 0.075 |
| `gemini-2.5-flash-lite` | 0.10 | 0.40 | 0.01 |
| `gemini-2.5-flash` | 0.30 | 2.50 | 0.03 |

`cost_usd = ((input − cached) × in + cached × cached_in + (output + thought) × out) / 1e6`, rounded to 1e-9. A model with no row gets `cost_usd: null` (counted as 0 in the totals, and `/usage` `note` names it), never a guessed price. None of these models has a >200k-token price tier. Update the table in the code, next to its comment, when a price changes or `brain.json` names another model. `cost_usd` is what the paid tier bills; on the free tier the actual bill is $0, and the brain cannot tell which tier a key is on.

**Claude price table** ([usage::CLAUDE_PRICES](src/usage.rs)), USD per million tokens: the Haiku 4.5 list prices given with the 0.4.0 task, not re-read from Anthropic's pricing page; check it before relying on them. A row matches its id or the id plus a `-` suffix (the dated `claude-haiku-4-5-20251001` matches `claude-haiku-4-5`); any other id is unpriced, `cost_usd: null`, as for Gemini.

| Model | Input | Output | Cache write (5 min) | Cache read |
|---|---|---|---|---|
| `claude-haiku-4-5` (default `claude-haiku-4-5-20251001`) | 1.00 | 5.00 | 1.25 | 0.10 |

`cost_usd = (input × in + output × out + cache_creation × write + cache_read × read) / 1e6`, rounded to 1e-9. At the 40 tails' measured mean (410 in, 44 out, if Claude tokenizes alike, which is not measured) that is about $0.00063 a call, **$0.63 per 1 000**, nearly four times `gemini-3.1-flash-lite`.

**Local** calls cost 0 in `usage.jsonl` and `/usage` (the PC's power is not counted); a local model is never unpriced, so `/usage` `note` stays null.

**Totals** ([usage::summary](src/usage.rs)): `/usage` reads the whole file on each call and buckets lines by the local date of `ts`: `today`, this calendar `month`, and `all`. `errors` counts lines whose `status` is not 200. `input_tokens` is the plain prompt count (cached part included), `thought_tokens` sums the thought tokens apart from `output_tokens`. `note` is `"no price for <ids>: cost_usd is null for its calls and counts 0 here"` when the configured model or any model in the file has no row, else null. `/health` carries `month_cost_usd` from the same reading. No rotation: at about 250 bytes a line, 100 000 calls is 25 MB.

**What it costs** (measured 2026-10-22 on the 40 labelled tails, §9 Gemini accuracy). The schema is not counted as prompt, and `minimal` thinking produced 0 thought tokens. Input was 16 400 tokens for the 40 (mean **410** a call; per-task medians 228 `prompt_quality`, 421 `contradiction`, 449 `unread_reply`, 600 `scope_drift`; range 135 to 826), output 1 739 to 1 744 (mean **44**; median 18 to 26 for `prompt_quality`, 50 to 57 for the others). At `gemini-3.5-flash-lite` that is 410 × $0.30/M + 44 × $2.50/M ≈ **$0.00023 a call, $0.23 per 1 000 calls** ($0.0092675 for the 40); at `gemini-3.1-flash-lite` **$0.00017 a call, $0.17 per 1 000** ($0.006716 for the 40). Per task at 3.5-flash-lite: about $0.11 per 1 000 `prompt_quality` calls, $0.32 per 1 000 `scope_drift`. With the tuned prompts at the default `gemini-3.1-flash-lite` (2026-10-23): 17 160 input and 1 597 output tokens for the 40, $0.0066855, still **$0.17 per 1 000**. The pre-run estimate was $0.40 per 1 000 (500 in, 60 out, 40 thought). On the free tier: $0, under its rate limits, but see privacy. No context caching: the stable prefix is a few hundred tokens.

**Privacy.** In Gemini mode the transcript tail (at most 6 turns, 3 000 bytes, as §2 cuts it) goes to **Google** over HTTPS for every model-task event and every `fail_kind` escalation. That is a second company: Claude Code already sends the whole chat to Anthropic, and this mode adds Google for the tail. Nothing else leaves the PC: no paths outside the tail text, no usage data, no file contents. The key leaves only as the `x-goog-api-key` header to that same API. Regex only and Off send nothing. `usage.jsonl` and `brain.log` stay on the PC and hold no transcript text. What Google does with the tail depends on the key's tier (pricing page row "Used to improve our products", and the terms at <https://ai.google.dev/gemini-api/terms>, "How Google Uses Your Data", read 2026-10-22 through a summarizer, so paraphrased; check the page before relying on it):

- **Free tier (unpaid services): yes.** Google uses submitted prompts and responses to provide, improve and develop its products, and human reviewers may read and annotate inputs and outputs (Google says it disconnects them from the account first).
- **Paid tier (billing enabled on the Cloud project): no.** Google does not use prompts or responses to improve its products; data is processed under the Data Processing Addendum. Prompts and responses are still logged for a limited period, only to detect Prohibited Use Policy violations and for legal compliance; the exact retention period was not found.

**Recommendation: use a paid, billing-enabled key.** At a measured $0.17 to $0.23 per 1 000 calls the bill is small, and coding transcripts (code, paths, names, the user's own words) should not go to a free tier that trains on them and lets reviewers read them. The overlay's key field says so (§8).

**anthropic:** the same tail goes to **Anthropic** over HTTPS, the company that already receives the whole chat from Claude Code, so no new party. The key leaves only as the `x-api-key` header. Anthropic's commercial API terms govern use and retention; not re-checked for this draft. **local:** nothing leaves the PC at all; the only network traffic is `/install`'s fetch of the pinned files from GitHub and Hugging Face.

## 6. Test plan

**Tier 0** (always runnable, `cargo test --manifest-path native/brain/Cargo.toml`; nothing leaves 127.0.0.1, the real API is never called):
- Regex vectors in `native/brain/vectors/<task>.json` (`{about, cases:[{name, input, expect}]}`) for the two regex tasks only: every one of the 13 cues with a hit and a near-miss; the ordering cases; `extract`'s fields. The model tasks have no rule and no vector file, and a test keeps it so.
- Schema files parse and each `fail_kind` enum value is one of the 13 plus `none`; a vector's `expect.labels` validates against its schema; every catalogue schema converts to `responseJsonSchema` losing nothing but gaining the enum types.
- `--mock`: answers the contract with no network, `backend: "mock"`; regex tasks run the regex layer, model tasks answer canned `labels` per task from `vectors/mock-answers.json`, which validate against their schemas; the overlay's own tests run against it. Contract tests: 401 without the token, 409 on an unknown `schema_id`, the three routes' shapes, 404 for `/install` and `/unload` off the local backend.
- Backend selection (`tests/backends.rs`): no `brain.json`, `{}`, and each of the three backends with and without a model, top-level or in its section, picks the right engine, and `/health` and `/usage` name its model; a gemini config ignores an `anthropic` section; `"openai"`, `"Gemini"`, `""` and `5` are errors naming the three valid values; the built exe given an unknown backend exits 1 with the reason on stderr and in `brain.log`, and writes no `port` or `token`; `/install` and `/unload` are 404 on gemini and anthropic, 405 for GET and token-checked on local; a local engine from config starts `absent` and a model task gets 503 `not installed` with nothing fetched.
- The Anthropic backend against a local mock Messages API (`tests/anthropic.rs`, [testutil::MockAnthropic](src/testutil.rs)): the request (path `/v1/messages`, `x-api-key` the only place the key appears, `anthropic-version: 2023-06-01`, model, `max_tokens` 300, temperature 0, the system line, the rendered tail, one tool with the unconverted schema and `tool_choice` forcing it); a `brain.json` model; success with validated labels and one usage line with the cache keys and the right cost; no key (also with only a `gemini-key`, or a blank `anthropic-key`) gives 503 `no key` and no request; the env fallback and the file winning; 401, 403, 429, 500, 503, 529, 400, 404 give their notes; slow gives `timeout`; no tool block, off-schema input and garbage give `malformed`; a refusal gives `blocked`; a refused connection gives `remote error`; no transcript text, labels or key in `usage.jsonl`, `brain.log` or any response; `fail_kind` escalation; `/usage` totals; an unpriced model; `/health` shape.
- The local backend (`tests/local.rs`), two rigs. **Fakes:** [testutil::FakeLlm](src/testutil.rs), a faked clock and memory reading, and [testutil::FileServer](src/testutil.rs) serving the pinned files over HTTP on 127.0.0.1 (with `Range` → 206, a cut-short body, and a hold to observe `downloading`). Covered: the shipped `manifest.json` (default, lowercase-hex sha256, Hugging Face URLs pinned to a 40-hex commit, `-rea off` only for the two Qwen hybrids, a Vulkan pin) and a `data/brain/manifest.json` override, ignored when it does not parse; `/health` shape; lazy load and idle unload; launch flags (`-c 4096`, `--cache-ram 0`) and `-ngl 99` only with `"gpu": true`; `/unload`; a dead process caught by the tick; regex tasks with no model; `fail_kind` escalation; malformed; RAM-guard defer with `announce` then `quiet`; three load strikes then `backoff`; crash; a slow answer is `timeout` and the model stays loaded; usage lines at cost 0. Install: 202 then `downloading` then `cold`; a nested zip and a nested tar.gz unpacked flat; a bad archive striking out; zip-slip and tar-slip refused; the GPU pin into `server-gpu/`; a hash mismatch striking three times with the note; `.part` resume from byte 4 with a `Range` request; 400 on an unknown id; 503 `disk`; a swap deleting the old GGUF and keeping the other `brain.json` fields. **Real process:** [proc::ProcLlama](src/proc.rs) launching `fake-llama-server` (a `[[bin]]` built from `tests/support/fake_llama_server.rs`, which speaks `/health` and `/v1/chat/completions` and records its flags): lazy load with the real flags and usage 123/9; the GPU build with `-ngl 99`; a 3 s answer against a 300 ms timeout is `timeout`, not `crash`, and the next call is served by the same process; a process that exits mid-answer is `crash` and the next request reloads; one killed between calls is noticed by the tick; idle unload; the RAM guard deferring before any spawn.
- The Gemini backend against a local mock Gemini API ([testutil::MockGemini](src/testutil.rs)): the request (URL path with the model, `x-goog-api-key` the only place the key appears and never the URL, `systemInstruction`, the rendered tail, `generationConfig` with temperature, `maxOutputTokens`, `responseMimeType`, the converted schema and the thinking setting) and a `brain.json` model override that changes URL and thinking; success gives validated labels and one usage line with the right cost, thought and cached tokens included; no key gives 503 `no key`, no request and no usage line, and an old `anthropic-key` is not read; the env-var fallback and the file winning over it; 400 `API_KEY_INVALID`, 401, 403, 429, 503, 500, a plain 400 and 404 give their notes and a zero-cost line; a slow answer gives `timeout` at the configured timeout and no line; no text, unparseable text, a `MAX_TOKENS` cut and off-schema JSON give `malformed` and a billed line; a `SAFETY` or `PROHIBITED_CONTENT` stop and a `promptFeedback.blockReason` give `blocked`; a refused connection gives `remote error`; usage lines and the log hold no transcript text, labels or key; `/usage` totals for today, month and all, `thought_tokens` and `by_task`, across several calls plus lines on faked earlier dates; an unknown model logs `cost_usd: null` and `/usage` `note` names it; `/health` shows `backend: "gemini"`, `key` present or missing, never the key, and the last note.

**Tier 1** (this PC, user's go-ahead, once a key is in `data/brain/gemini-key`, ideally a paid one): first one call to confirm the request shape (`responseJsonSchema` and `thinkingConfig.thinkingLevel` accepted, not a 400), the bad-key error shape, and the `usageMetadata` fields. Then run the 40 labelled tails in `data/brain-eval/tails.json` through `/classify` on the real brain, the shipped path with the overlay's 2 500 ms client timeout, scored as in §9 (key field, verdict, precision and recall per task, latency median and max, answers under 2.5 s, 503 notes), against the "always no" rule and the local results. Then check `/usage` against the run (40 calls, by task) and against the AI Studio / Cloud billing view. Expected cost about $0.02 for the 40 (§5's $0.0004 a call), $0.04 with a second pass to check that temperature 0 repeats. The result decides which of the four model features ship, whether `minimal` thinking is enough, and whether the system lines need rewriting for Gemini. Run on 2026-10-22: results in §9, Gemini accuracy (measured $0.009 for the 40 at the then-default `gemini-3.5-flash-lite`; rerun 2026-10-23 with tuned prompts, §9 Tuned prompts). Still open from this list: the bad-key error shape (the run did not overwrite the user's key) and the check against the AI Studio / Cloud billing view.

## 7. Failure modes

| Failure | Behaviour |
|---|---|
| chatq-brain exe missing or fails to start | mode falls to Regex only, tag `REGEX`, one line `Brain: Unreachable. Running on reflexes.` per overlay session; model features silent |
| Port file stale (brain died) | connection refused → overlay re-reads port+token once, then respawns with backoff 5 s, 15 s, 60 s, hourly; model events meanwhile are discarded |
| No key | 503 `no key`, `/health` `state: "unconfigured"`, `key: "missing"`; the overlay shows `Brain: No key. Running on reflexes.` once and points at settings |
| Key rejected (400 `API_KEY_INVALID`, 401, 403) | 503 `bad key` on every model event until the key changes; the overlay says so once per session |
| Rate limit (429) or overload (503, 500) | 503 `rate limited` / `overloaded`; that event is dropped, the next one tries again; no retry, no queue |
| Network down, DNS, TLS, other HTTP error | 503 `remote error` |
| API slower than 2 300 ms | 503 `timeout`; no usage line (no response) |
| Off-schema answer, no JSON text, cut by `MAX_TOKENS` | 503 `malformed`, billed and counted in `usage.jsonl` |
| Safety stop or blocked prompt | 503 `blocked`, counted in `usage.jsonl`; that event is dropped |
| Model not in the price table | answers normally; `cost_usd: null`, `/usage` `note` names it |
| Wrong token / 401 from the brain | overlay re-reads the token file once; still 401 → treated as unreachable |
| Mode change | kill chatq-brain; a request in flight is discarded |
| Unknown `brain.json` `backend` | chatq-brain does not start: exit 1, reason on stderr and in `brain.log`, no `port`/`token`; the overlay sees it as unreachable |
| anthropic: no key, bad key, 429, 500/503/529, refusal | the same notes as gemini (§2); a refusal is `blocked` |
| local: model not installed | 503 `not installed`; nothing downloads until `/install` |
| local: free RAM under the guard | 503 `deferred` with `announce` (once per 10 min) or `quiet`; retried after 60 s; no spawn |
| local: answer slower than `local.timeout_ms` | 503 `timeout`; llama-server stays loaded; not a strike |
| local: llama-server dies mid-answer or between calls | 503 `crash` (mid-answer) or nothing (the tick finds it); one load strike; the next request reloads |
| local: three failed loads | 503 `backoff` for 10 min |
| local: download fails or hash mismatch | three strikes per `/install`, then `absent` with `note: "download failed: …"` in `/health` |
| local: under 3 GB free disk | `/install` answers 503 `disk`, nothing fetched |
| local: unsafe archive (zip-slip, tar-slip, symlink out) or no llama-server inside | the attempt fails and counts as a strike; nothing lands outside `server/` |

## 8. Merge

`native/Cargo.toml` gains the brain as a member, the overlay depends on its catalogue and client, and `CHANGELOG.md`, `TESTING.md` (the Tier 0/1 sections above) and the version move in the one commit. Until then this folder builds on its own and touches nothing of the main workspace.

**What the overlay must change for this backend:**

1. The mode `Local model` (or `Claude`) becomes `Gemini`: menu Brain → Off / Regex only / Gemini / Reconnect, `Gemini (not installed)` when the exe is missing, tag `BRAIN: OFF | REGEX | GEMINI`.
2. A settings field for the Gemini API key that writes `data/brain/gemini-key` whole (0600 on Unix) and never echoes it back (show only present/missing from `/health`). Beside it, one line: a paid (billing-enabled) key is recommended, because on the free tier Google uses the prompts to improve its products and reviewers may read them.
3. Read `/health` `key`, `state` and `note` for the status line instead of `resources_pct` / `download_pct` / `idle_s`.
4. Drop every `/install`, `/unload`, download-progress and RAM-deferral path (the "Install brain" menu item now only fetches the brain zip).
5. Show cost from `/usage` (`today.cost_usd` and `month.cost_usd`) in the menu or hover, and its `note` when not null (an unpriced model).
6. Keep the 2 500 ms `/classify` timeout and discard on any 503 as before; the new `blocked` note is handled like every other note.

**For the other two backends (0.4.0), not built in the overlay yet:**

7. Read `/health` `backend` and label the mode by it (`GEMINI`, `CLAUDE`, `LOCAL`), or add the two as modes that write `brain.json` `backend` and restart chatq-brain.
8. anthropic: a second key field writing `data/brain/anthropic-key` the same way.
9. local: a model picker over the catalogue that calls `POST /install {model}` and shows `download_pct` and the `download failed` note from `/health`; the `Resources available: N%. Thinking: Deferred.` line on `announce`; `/unload` on a mode change; and the `/classify` timeout raised for local (§10), or most local answers are discarded.

## 9. Why the local model is not the default

**Bakeoff note.** The `local` backend exists (0.4.0) for a PC with no network, no key or no wish to send the tail anywhere. It is slower and less accurate than Gemini on every measure below, so **gemini stays the default**, and local stays opt-in with Phi-4-mini, the best of the local candidates, as its default.

Measured on this PC (i7-1360P, 16 GB, Iris Xe) on 2026-10-22 with the llama.cpp backend this crate used to supervise; the raw results (`results-1b.json`, `results-3b.json`, `bake-*.json`) and the scripts that scored them stay in `data/brain-eval/`. Eval set: 40 tails from the user's own Claude Code chats, 10 per model task (5 positive, 5 negative), hand-labelled and scrubbed, in `data/brain-eval/` and never in the repo.

- **Too slow.** Real tails are 44 to 695 prompt tokens. Llama 3.2 1B on CPU: raw medians 3.5 to 15.9 s per task; 3 of 40 shipped answers came in under the 2.5 s timeout and none of them was a correct positive. In the bakeoff of six models, 9 of 480 calls answered within 2.5 s, and none of the 9 was right. The fastest real option, Phi-4-mini on the Vulkan iGPU, put 37 of 40 under 10 s.
- **Not accurate.** No model beat a rule that always says no by more than one case of 40 on the key field (best 19 against 18; best verdict 24 of 40 against 20). Each was a fixed bias, not a judge: the 1B and 3B never said `contradicts` on 5 real contradictions, Qwen3-1.7B called all 10 tails a contradiction, Gemma 3 4B called every prompt weak.
- **Too heavy.** The 3B as shipped answered nothing: the free-RAM guard deferred all 40 calls at about 3 GiB available. The 4B models peaked at 3.6 to 7.8 GiB working set and left the PC with 0.2 to 0.6 GiB free.

Models tried: Llama 3.2 1B and 3B, Qwen3-4B-Instruct-2507, Qwen3.5-4B, Phi-4-mini 3.8B, Gemma 3 4B, Qwen3-1.7B (all Q4_K_M). 0.3.0 removed the local path; 0.4.0 restores it as the opt-in `local` backend (§2, The local backend): llama-server spawn and supervision, model and server downloads, `/install`, `/unload`, the model manifest (now all seven candidates), the RAM guard, idle unload, archive unpacking. What changed from the first local version, from the findings above: `-c 4096` (was 2048) and `--cache-ram 0` (the host prompt cache grew private bytes across calls), `--jinja` and `-rea off` for the Qwen hybrids as the bakeoff ran them, the Vulkan build behind `"gpu": true`, a per-call timeout of its own (`local.timeout_ms`, 10 s) where a slow answer is a `timeout` and not a crash. None of this has run against a real llama-server or a real download in 0.4.0: Tier 0 only.

### Gemini accuracy (2026-10-22)

The same 40 tails, sent through `/classify` on the real brain (exe built from this crate, the request of §2 unchanged), client timeout 10 s so the true latency shows; the brain's own API timeout was raised to 15 s for the run only, so answers past 2.3 s were kept and counted instead of turning into 503 `timeout`. 0.5 s between calls. Scoring as for the local models: key field `drifted`, `contradicts`, `answered` (positive = false), `score` (positive = score ≤ 1). Script `data/brain-eval/eval_gemini.py`, per-case rows `results-gemini.json` (3.5-flash-lite), `results-gemini-3.1.json` and `results-gemini-3.1-r2.json` (3.1-flash-lite, two passes), `results-gemini-2.5.json` (the 404s), all in `data/`, never the repo.

**Models.** `gemini-3.5-flash-lite` (then the default) and `gemini-3.1-flash-lite` answered; `gemini-2.5-flash-lite` answered every call 404 `NOT_FOUND` "no longer available to new users", so it is not an option for a new key. No 429 and no quota message in 163 calls at up to about 35 a minute. Temperature 0 repeated: the second 3.1-flash-lite pass gave the same verdict on all 40 and the same token counts.

| Task (10 each) | Model | Key correct | TP FP TN FN | Precision | Recall | Median ms | Max ms | Over 2.5 s |
|---|---|---|---|---|---|---|---|---|
| `scope_drift` | 3.5-flash-lite | 7 | 4 2 3 1 | 0.67 | 0.80 | 2 703 | 3 263 | 10 |
| | 3.1-flash-lite | 7 | 5 3 2 0 | 0.63 | 1.00 | 1 308 | 2 150 | 0 |
| `contradiction` | 3.5-flash-lite | 6 | 5 4 1 0 | 0.56 | 1.00 | 2 542 | 3 176 | 7 |
| | 3.1-flash-lite | 5 | 5 5 0 0 | 0.50 | 1.00 | 1 209 | 1 438 | 0 |
| `unread_reply` | 3.5-flash-lite | 8 | 3 0 5 2 | 1.00 | 0.60 | 2 509 | 2 823 | 5 |
| | 3.1-flash-lite | 9 | 5 1 4 0 | 0.83 | 1.00 | 1 199 | 1 544 | 0 |
| `prompt_quality` (verdict 9 of 10 on both) | 3.5-flash-lite | 3 (MAE 0.7) | 4 0 5 1 | 1.00 | 0.80 | 2 493 | 2 799 | 5 |
| | 3.1-flash-lite | 4 (MAE 0.6) | 4 0 5 1 | 1.00 | 0.80 | 1 243 | 1 785 | 0 |

No 503 on either model: all 80 answers were schema-valid 200s.

| Rule or model | `scope_drift` | `contradiction` | `unread_reply` | `prompt_quality` | Key total | Verdict total |
|---|---|---|---|---|---|---|
| Always no | 5 | 5 | 5 | 3 (verdict 5) | 18 | 20 |
| Llama 3.2 1B (llama-server direct) | 3 | 4 | 4 | 3 (verdict 6) | 14 | 17 |
| Phi-4 mini, best local (CPU raw) | 3 | 8 | 6 | 2 (verdict 4) | 19 | 21 |
| `gemini-3.5-flash-lite` | 7 | 6 | 8 | 3 (verdict 9) | 24 | 30 |
| `gemini-3.1-flash-lite` (both passes) | 7 | 5 | 9 | 4 (verdict 9) | 25 | 30 |

**Tokens and cost** (from `usage.jsonl`, matching `/usage`): 16 400 input tokens for the 40 on both models (mean 410), 1 739 (3.5) and 1 744 (3.1) output, **0 thought tokens**. $0.0092675 for the 40 at 3.5-flash-lite = **$0.23 per 1 000 calls**; $0.006716 at 3.1-flash-lite = **$0.17 per 1 000 calls** (paid-tier prices of §5).

**Latency against the 2 500 ms overlay timeout.** `gemini-3.5-flash-lite` is too slow for the shipped path: median 2 570 ms (client) / 2 550 ms (API), max 3 263 ms; 27 of 40 over 2.5 s, and only 6 of 40 within the brain's own 2 300 ms API timeout, so as configured about 85 % of events would be 503 `timeout` and dropped. The floor is the service, not the tail: the 17-token `prompt_quality` answers took as long as the rest, and the two made-up 109-token probes took 2.6 and 2.9 s. `gemini-3.1-flash-lite`: median 1 239 / 1 263 ms over the two passes, 79 of 80 within 2 300 ms, one outlier at 6 086 ms.

**Ship verdict per task** (at `gemini-3.1-flash-lite`, the default since 2026-10-23; at 3.5-flash-lite nothing ships, it is too slow; superseded for `scope_drift` and `contradiction` by Tuned prompts below):

- `unread_reply`: **ship.** 9 of 10, recall 1.0, one false "unanswered".
- `prompt_quality`: **ship the verdict** (weak prompt yes/no, 9 of 10, no false alarm), not the exact `score` (4 of 10, MAE 0.6).
- `scope_drift`: **hold.** 7 of 10 with full recall, but 3 of 5 clean tails flagged as drift; a line on most clean turns is noise. Rewrite the system line for Gemini and rerun.
- `contradiction`: **do not ship.** It says `contradicts: true` on 10 of 10 (3.1) and 9 of 10 (3.5), no better than always-no on the key field. The system line needs rewriting before it is worth a call.

Gemini beats always-no by 6 to 7 cases on the key field and 10 on the verdict, and the best local results (19 key, Phi-4 mini; 24 verdict, Qwen3.5-4B) by 5 to 6 on each, at a latency the overlay can live with only on 3.1-flash-lite.

### Tuned prompts (2026-10-23)

The `scope_drift` and `contradiction` system lines rewritten from first principles: each now says the label is true *only* for the real thing and names the look-alikes that are not. `contradiction`: the newest user message must ask for the opposite of, or something instead of, what an earlier user message asked; refining or clarifying, answering the assistant, repeating an instruction or complaining it was ignored, and anything the assistant said are not contradictions; both quotes verbatim user text. `scope_drift`: a change the assistant made that was neither requested nor needed for a request; needed supporting edits, asked-for follow-ups and extras only mentioned or offered are not drift. Both default to false when unsure. Schemas and `schema_id`s unchanged. Two rounds, live, default model `gemini-3.1-flash-lite`, brain timeout as shipped (2 300 ms), client timeout 10 s, all 40 tails and all four tasks; rows in `data/brain-eval/results-gemini-tuned.json` (round 2, shipped) and `results-gemini-tuned-r1.json`. Round 1 phrased drift as "work" and made reporting count; round 2 says "change". Round 2 is the shipped text: better on `scope_drift`, equal on `contradiction`.

**Optimistic numbers.** The prompts were checked on the same 40 tails they are judged by, with no held-out set, so these scores overstate what a fresh chat will see. No wording was copied from the tails.

| Task (10 each) | Prompt | Key correct | TP FP TN FN | Precision | Recall | Median ms | Max ms |
|---|---|---|---|---|---|---|---|
| `scope_drift` | before (2026-10-22) | 7 | 5 3 2 0 | 0.63 | 1.00 | 1 308 | 2 150 |
| | round 1 | 6 | 3 2 3 2 | 0.60 | 0.60 | 1 215 | 1 914 |
| | **round 2** | **8** | 4 1 4 1 | 0.80 | 0.80 | 1 066 | 1 279 |
| `contradiction` | before | 5 | 5 5 0 0 | 0.50 | 1.00 | 1 209 | 1 438 |
| | round 1 | 6 | 5 4 1 0 | 0.56 | 1.00 | 1 040 | 1 468 |
| | **round 2** | **6** | 5 4 1 0 | 0.56 | 1.00 | 1 061 | 1 320 |
| `unread_reply` (unchanged) | round 2 | 9 | 5 1 4 0 | 0.83 | 1.00 | 1 076 | 1 234 |
| `prompt_quality` (unchanged; verdict 9, MAE 0.6) | round 2 | 4 | 4 0 5 1 | 1.00 | 0.80 | 1 011 | 1 228 |

Key total 25 before, 25 round 1, **27** round 2; verdict total 30, 30, **32**. No 503 in either round: all 80 answers were schema-valid 200s inside the 2 300 ms timeout (client max 1 914 ms). The two unchanged tasks gave the same verdicts as before, so no regression. Cost from `/usage`: $0.006685 round 1, $0.0066855 round 2 (17 160 in, 1 597 out, 0 thought), $0.0133705 for both, $0.17 per 1 000 as before.

**Ship verdict per task** (at `gemini-3.1-flash-lite`, round 2 prompts):

- `unread_reply`: **ship.** Unchanged, 9 of 10.
- `prompt_quality`: **ship the verdict only.** Unchanged, 9 of 10 on weak-or-fine; the exact score stays unreliable.
- `scope_drift`: **ship, provisionally.** 8 of 10, 1 of 5 clean tails flagged (was 3), recall 0.80 (was 1.00). Recheck on fresh labelled tails before trusting it further, given the optimism above.
- `contradiction`: **do not ship.** 6 of 10, still `true` on 4 of 5 clean tails despite the rule list: two refinements, one complaint that an instruction was ignored, one with an assistant question quoted as `earlier`. Untested hypothesis: the verdict is emitted before the evidence. `serde_json` (no `preserve_order`) sends the schema's keys sorted, and Gemini answers in that order, so `contradicts` comes before `earlier` and `later`. A `contradiction@2` whose quote fields sort first, or a stronger model, is the next thing to try.

## 10. Open questions

1. `loop` and `scope` are the wordy cues; whether `fail_kind`'s escalation is worth a call (and its cost) is a Tier 1 number.
2. A monthly spend cap: `/usage` makes it cheap to add (refuse with a new 503 note past a limit in `brain.json`), not built until the user asks.
3. The remote design (a brain on another PC serving this contract) has not been set up; nothing here depends on it.
4. Model choice is a Tier 1 number too: `gemini-3.1-flash-lite` is cheaper ($0.25 / $1.50) and `gemini-2.5-flash-lite` cheapest with thinking off ($0.10 / $0.40, but limited to past active users); both are one `brain.json` line away and already priced. Measured (§9, Gemini accuracy): `gemini-2.5-flash-lite` is 404 for a new key; `gemini-3.5-flash-lite` answers only 6 of 40 within the 2 300 ms API timeout, while `gemini-3.1-flash-lite` answers 79 of 80 within it, at equal accuracy and lower cost. Decided 2026-10-23: [config::DEFAULT_MODEL](src/config.rs) is now `gemini-3.1-flash-lite`.
5. **Known limit, local vs the overlay timeout.** The overlay's `/classify` timeout is 2 500 ms; a 4B local model answered in about 7 s on this PC's CPU (§9), and `local.timeout_ms` defaults to 10 000. As the overlay ships, most local answers arrive after it has given up and are discarded. The overlay was not changed in 0.4.0; raising its timeout for local is §8 item 9.
6. The Claude backend is untested live: latency against 2 300 ms, accuracy on the 40 tails and the real cost are Tier 1 numbers.
