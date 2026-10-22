# Skin packs: the mascot as data

The product ships a neutral mascot. A pack in `data/skins/<id>/` replaces the
face, the lines and the voice; the overlay (native/overlay, Rust + Slint)
picks it up on start or on Skin > Refresh. Skippy is one pack, kept out of
the public repo (private git or a zip). Same shape as the Brain: a folder in
`data/`, installed by unzip, uninstalled by delete.

Source of the shape: the prototype `design/skippy/proto/index.html` (the
engines: `moodNow`, `moodFor`, `failLine`, `roastText`, pacing) and
`design/skippy/proto/lines.js` (the bank). The engines are product code; the
bank, the faces and the writer rules are the pack.

## 1. Folder layout

```
data/skins/<id>/
  skin.json          manifest (below)
  moods/<mood>.png   sprite atlas, one per mood the pack has
  moods/<mood>.json  frames, fps, frame size, cols, play mode
  stills/tray.png    optional tray/strip still (or `tray` in skin.json, below)
  moods/<mood>.webm  optional, the HTML prototype only; the overlay ignores it
  lines.json         the bank: the prototype's window.SKIPPY_LINES as JSON
  moodmap.json       base mood per section + the phrase overrides moodFor applies
  voice.md           writer rules (bible, grammar, roast, fail, deflect); not read by code
  LICENSE            the pack's own terms; NOTICE for third-party credits
```

Mood ids are a closed set the engine knows: `idle ready pleased sad smug
angry scared`. A pack may ship any subset; `idle` and `ready` are required.

### skin.json

```json
{
  "format": 1,
  "id": "skippy",
  "name": "Skippy",
  "version": "4.14.0",
  "author": "Hae-chan Hong",
  "voice": "SKIPPY",
  "tags": ["cyberpunk", "roast", "en"],
  "mascot": { "w": 160, "h": 128, "scale": 2, "anchor": [80, 124] },
  "colours": { "accent": "#5EF6FF", "box": "#0E0E17", "ink": "#E2DCCF", "gold": "#F0B537" },
  "tray": { "mood": "ready", "frame": 0, "crop": [63, 35, 199, 199] },
  "moods": ["idle", "ready", "pleased", "sad", "smug", "angry", "scared"],
  "fallback": { "smug": "ready", "angry": "ready", "scared": "ready", "pleased": "ready", "sad": "idle" },
  "modes": ["killer", "pacifist"],
  "maxChars": 95
}
```

- `format`: the pack format version; the engine refuses a pack whose major
  it does not know.
- `voice`: the name the box header shows (`SKIPPY:` before a line, the
  hover card's name, the tray tooltip's lead).
- `mascot.w`/`h`: display size in logical px; `scale`: atlas pixels per
  display px (2 = frames are 320x256 for a 160x128 mascot); `anchor`: the
  point in display px that sits on the panel's mascot slot (feet, usually).
- `tray`: the still for the tray icon and the strip, which cannot animate:
  `frame` of the `mood` atlas (default `ready`), cut to `crop` = `[x, y, w, h]`
  in frame pixels. A pack with no `tray` may ship `stills/tray.png` instead
  (square, alpha); with neither, the engine cuts frame 0 of `ready`. The
  default skin and the Skippy builder both write `tray`.
- `fallback`: the face worn when a mood's atlas is missing or broken, as the
  prototype's `faceOf` (every missing face wears `ready`). Must resolve to a
  shipped mood in one hop; `ready` itself never falls back.
- `modes`: the registers the bank has. `killer` is the default register; a
  pack with one mode lists `["killer"]` and the Pacifist takeover is off.
- `maxChars`: the filled-line cap (`trim2` cuts after the second sentence);
  events use `maxChars - 5`. It lives once, here in `skin.json`; the engine
  ignores the `habit.pace.maxChars` copy in `lines.json` (the prototype's own
  bank, kept for the prototype).

### moods/<mood>.json

```json
{ "frames": 24, "fps": 15, "w": 320, "h": 256, "cols": 6, "play": "loop" }
```

`play` is `loop` or `pingpong`. The atlas is `cols` frames wide, rows as
needed, row-major, no padding. `w`/`h` are FRAME pixels (one frame, not the
sheet; the sheet is `cols * w` by `rows * h`); `w / scale` must equal
`mascot.w`. One atlas is decoded at a time (the mood on show), so the
budget is per atlas: at most 4096x4096 px, 8 MB on disk, and 8,388,608
bytes decoded (sheet width x height x 4), at most 120 frames.

Frame cap: at 320x256 a 5x5 sheet is 8,192,000 bytes, so a loop holds at
most 25 frames (24 to 25 is the target). A longer source is cut, never
squeezed: a clip that loops uses the window of 24-25 frames whose last
frame is closest to its first; a clip that does not loop uses its forward
half with `pingpong`; if that is still over 25 frames, drop to 12 fps. The
frame size stays 320x256.

### lines.json

The prototype's `window.SKIPPY_LINES = {...}` with the assignment removed:
the same top-level keys, the same shapes. The engine reads these and
nothing else; unknown keys are kept for the prototype and the writer.

| Key | Shape (as lines.js) | Engine use |
|---|---|---|
| `events[]` | `n id name trig mood hold pri cd freq s{} extra[] killer[] pacifist[]` (`n` the event's number in the table, `trig` its trigger in words, `s` sample slot values for the writer's preview; the engine keys on `id`); `fail` adds `kinds[] again[] quoted[] streak[] recovery[]` | the event lines, keyed by `id`; `extra[].lb` the coalesced/re-nag pools; `fail.kinds[].key` the fail kinds with `cue readout t4 mood` |
| `talk[]` | `mode topic when text` | random small talk; `when` is `any`, `night` or `day` |
| `talkMood` | `{topic: mood}` | the face of a small-talk topic |
| `hum` | `tune[] announce{} repeat[] cut{}` | the wait song |
| `pacifist` | `name moods{} enter{} refuse{} protest[] modeNoted` | the takeover register |
| `status` | `mood opening opened denied deleted answer lock{} relocation brain{} usage{} queue{} reload{} console crash{}` | the status lines the overlay says for its own results |
| `conversations` | `monologue silence setup habit askmode flip resume confirm`, each `nodes{}` of `say mood src opts[] beat then fx tone` and optionally `lock note silent`; `flip` is keyed by mode (`killer`, `pacifist`), each side a talk of its own | the talks; `habit.habits[]`, `habit.roast{moods killer pacifist tiers combos card streak blame deflect}` the roast engine's banks; `roast.moods` holds `t1 t2 t3 t4 pacifist combos card streak callbacks tally blame deflect` |

Node extras: `lock: true` holds the node's mood against the phrase
overrides (see moodmap); `note` is the writer's comment, never read;
`silent` maps a silence step to the line said at it.

Slots are `{name}` and are the engine's: `{project} {chat} {minutes} {hours}
{percent} {provider} {window} {reset_time} {time} {count} {waiting}
{n_working} {order} {since} {mode} {seconds} {send_time} {lead} {opener}
{roast} {readout} {habit} {grade} {comment} {times} {pct} {rest} {n}
{attempt} {tool} {file} {prompt}`, the Brain status lines' `{where} {ms}`,
plus the habit readouts' `{words} {cuts}
{secs} {day} {lines} {chars} {first}`. A slot the engine cannot fill leaves
the line out of the draw (it never prints a brace). A pack adds no slots.

### moodmap.json

```json
{
  "sections": {
    "events": "ready", "talk": "ready", "hum": "pleased", "status": "ready",
    "pacifist.enter": "sad", "pacifist.refuse": "ready", "pacifist.protest": "ready",
    "roast.t1": "smug", "roast.t2": "smug", "roast.t3": "ready", "roast.t4": "angry",
    "roast.pacifist": "smug", "roast.tally": "smug",
    "roast.combos": "smug", "roast.card": "smug", "roast.streak": "smug",
    "roast.callbacks": "smug", "roast.blame": "smug", "roast.deflect": "smug",
    "conversations": "ready"
  },
  "locked": ["roast.t3", "roast.deflect", "pacifist.refuse", "pacifist.protest"],
  "phrases": [
    { "mood": "angry",   "regex": ["(?i)Increasing volume|\\bNo+!|Bad user!|(?:What|The fuck) is wrong with you\\?|Shut up|wrong tune"] },
    { "mood": "scared",  "match": ["Please jump to confirm", "Possible cause: Theft", "Please return me to my real owner"] },
    { "mood": "sad",     "match": ["I'm sorry. This never happens", "Memory: Damaged"], "regex": ["\\bRetracted\\b"] },
    { "mood": "ready",   "match": ["Permission denied"] },
    { "mood": "pleased", "match": ["Happy slaughtering", "Test successfully completed", "best user I know"] },
    { "mood": "smug",    "match": ["Just like you.", "Your therapist must be rich"] }
  ]
}
```

Resolution, as `moodFor(text, base, lock)`: a `mood` written on the bank,
tier, kind, node or line in `lines.json` is the base and wins over
`sections`; `sections` fills in where the bank says nothing; then the
`phrases` are tried in order and the first hit wins, except under a lock,
where only `angry` breaks the deadpan. `match` entries are case-sensitive
substrings; `regex` entries are Rust `regex` syntax, tested after `match`,
and a phrase may be one regex that carries its own flags, as the angry
pattern's `(?i)` above (case-insensitive, one alternation).

Lock rules: `roast.deflect` is always locked; `roast.t3` is locked when its
mood is `ready` (the roast opens on a deadpan, as `convOpen` does); the
pacifist refusals are locked; a conversation node is locked when it carries
`lock: true` (the 50-count FAQ nodes do). A locked line wears its base mood
unless an `angry` phrase hits. `locked` in `moodmap.json` lists the
sections; node locks live on the node.

## 2. Engine versus pack

| Engine (product code, native/overlay) | Pack (data) |
|---|---|
| state mood: `moodNow` (held line > card > limit > ask > waiting > stopped > pleased > tally > working > idle) | which face each mood shows |
| triggers and detectors: events, fail cues, the 50 habits, the brain's classify | the lines said at each |
| pacing: cooldowns, dice, day caps, P1-P4 ranks, coalescing, quiet hours, mute, the chatter level | `hold` per event (reading time only) |
| slot filling, `trim2`, the `maxChars` cut, the shuffle bag per mode and pool | the templates and the cap |
| the roast ladder, combos, callbacks, card grades, streak, blame split, deflect timing, tally | the roast lines, the tier/section moods |
| conversations: beat, silence steps, opts keys, `fx` verbs | the nodes, their text and moods |
| the atlas animator, the mood switch, the fallback hop | atlases, frame data, fallback map |
| the box, header, colours' use | `voice`, `colours` |

A pack may omit any section of `lines.json`, any mood atlas, or `talk`
altogether; the engine stays silent for a missing section (no line, no
log) and the event still updates the dials and badges. A missing `killer`
pool in a bank with a `pacifist` pool is silent in Killer, not borrowed.
`status` lines missing fall back to the default skin's, since they answer
what the user just did and must not vanish.

## 3. Discovery and selection

- At start and on Skin > Refresh the overlay reads
  `data/skins/*/skin.json`; `data` is the folder `chatq-overlay.exe <data folder>`
  is given (the same one the Brain uses as `data/brain/`).
- Right-click menu (tray and panel): `Skin > Default, Skippy, ..., Refresh`.
  The list is `name` per valid manifest, sorted, `Default` first. A tick on
  the one on show.
- The choice is `skin: "<id>"` in `data/overlay-state.json`, next to lock,
  fold and place (the panel's own file). Unset means `default`.
- A pick switches live: new bank, new atlases, the current line finishes in
  the old voice, the face reloads on the next tick.
- Missing or broken: the saved id not found, a manifest that fails
  validation, or an atlas that fails to decode. The overlay falls back to the
  built-in default and logs one line, `skin <id>: <reason>; using default`,
  once per start or Refresh, in the self log (selflog.rs). The menu still
  lists the broken pack, greyed, with the reason as its tooltip.
- Validation: `format` major is 1; `id` matches the folder name and
  `[a-z0-9-]+`; `moods` includes `idle` and `ready`; each listed mood has
  both `moods/<mood>.png` and `.json`; `fallback` targets are listed moods;
  `w / scale == mascot.w`, `h / scale == mascot.h` (`w`/`h` are
  frame pixels); atlas within the budget above, decoded size included;
  `tray`, where present, names a listed mood and a crop inside the frame; `lines.json` parses and, where present, each event has an
  `id`; `moodmap.json` names only known moods. `lines.json` missing is
  valid (face only, default lines). A validation failure names the file
  and the rule.

## 4. The built-in default skin

`skins/default/` in the public repo, same layout as a pack, `id: default`,
`voice: "OVERLAY"`, a neutral mascot (a round badge with two dots and a mouth
line, seven moods, the full closed set, so no fallback fires), and plain lines: readouts with no character ("Chat finished.",
"{chat} is waiting.", "Usage: {percent}%."). No talk, no hum, no pacifist,
no conversations, no roast: those sections are absent and the engine is
silent for them. It is compiled in with `include_bytes!` so the exe runs
with an empty `data/`, and `skins/default/` on disk is the reference pack
a writer copies to start a new one.

## 5. Distribution

- The pack is its own git repo (private) or a zip of the folder.
- Install: unzip or clone into `data/skins/`, so that
  `data/skins/skippy/skin.json` exists; then Skin > Refresh, or restart.
- Uninstall: delete `data/skins/skippy/`. If it was the one on show the
  overlay logs the fallback line and shows the default.
- Update: replace the folder; `version` in the manifest is for the menu
  tooltip and the self log, nothing else keys on it.
- The public repo never holds the Skippy pack. `design/skippy/` keeps the
  prototype and the voice study; the pack is exported from it by a script
  in the pack's repo (`lines.js` to `lines.json`, webm to atlas).
- `data/skins/` sits beside `data/brain/`; one `data/` folder, every
  optional part a subfolder, each removed by deleting it.

## 6. For the overlay session: what to build

Four pieces, each pure where it can be and tested with vectors in
`native/vectors/` as the panel's other parts are.

1. **Loader** (`skin.rs`): scan, validate, parse the three JSON files,
   build a `Skin { manifest, bank, moodmap, atlases }`; `Skin::default()`
   from the compiled-in bytes. Returns `Result<Skin, SkinError>` with the
   file and rule in the error.
2. **Atlas animator**: decode the current mood's PNG only; drop the previous
   on switch. A Slint `Image` with `source-clip-x/y/width/height` stepped by
   a timer at `fps`; `loop` wraps, `pingpong` reverses. Frame index is kept
   across a redraw, reset on a mood switch.
3. **Mood switch**: `moodNow` as the prototype orders it, then `moodFor`
   with the pack's moodmap, then the fallback hop for a missing face. The
   true mood stays the true one (hover card, header); the face is what
   plays.
4. **Line picker**: given an event id and mode, the pool (bank, `extra` by
   label, fail kind, roast tier), the shuffle bag per pool, slot fill, the
   `maxChars` cut, and the mood of the line. Missing section: `None`.

Acceptance:

- A folder with only `skin.json` and `moods/idle|ready` loads; every mood
  requested shows `ready` or `idle`; no line is ever said; the self log is
  clean.
- Remove one atlas of a loaded pack and Refresh: the fallback face plays,
  one log line, the mood on the hover card is still the true one.
- Corrupt `lines.json`: default lines, default voice name, pack faces, one
  log line naming `lines.json` and the parse error.
- Delete the pack folder of the skin on show while it runs: next tick shows
  default, one log line, `overlay-state.json` keeps `skin: "skippy"` so a
  reinstall comes back without a pick.
- Vectors: `skin-manifest.json` (valid and each rule broken),
  `skin-moodfor.json` (text, base, lock, expected), `skin-pick.json`
  (event, mode, bag state, slots, expected text and mood), run under
  `tests/vectors/skin-*.ps1` as the overlay vectors are.
- Memory: with Skippy on show, the overlay's working set grows by one
  decoded atlas (at most 8,388,608 bytes, 25 frames of 320x256) and not by seven.
- The public repo builds and runs with no `data/skins/` folder at all.
