# S62: the console in a process of its own

A prototype, and its measurements, on the 0.11.1 code. There the headless
host loads the WPF console into itself the first time it is asked for
(`Import-ChatOverlayConsoleParts`, gone since 0.11.6, and
[Open-ChatOverlayHeadlessConsole](../../src/overlay-windows.ps1)) and keeps
it for its life. 0.11.6 put the console in a process of its own
([Start-ChatConsoleProcess](../../src/overlay-host.ps1)), so these scripts
run only from a clone at 1a48212 (v0.11.1) with `tests/m9/` copied in;
`Assert-S62Root` refuses newer code, whose host would start the real
console's process, none of S62's seams in it. S62 asks two questions.
Can a separate process start fast enough to exit when the console closes? Does it come to the front when the
panel, the hotkey, the tray or `charlie -Console` asks for it?

## Files

| File | What it is |
| --- | --- |
| `s62-common.ps1` | Shared helpers: the sandbox's paths, config, fake homes, each process's own environment, collect.ps1's stubs, the JSON-lines log, and the few Windows calls (emitted in memory, no csc). |
| `s62-console.ps1` | The prototype console client. It loads every part, takes one `Invoke-ChatOverlayCycle -Peek` and opens the console. It takes `show`, `back` and `quit` on stdin. |
| `s62-host.ps1` | The sandbox headless host. `-Mode spawn` starts `s62-console.ps1` for the console. `-Mode inproc` runs today's console, timed. Started only through `Start-S62Host` (hidden, as an encoded command that dot-sources it). |
| `s62-auto.ps1` | The automatic run: no input, every window cloaked. |
| `s62-hand.ps1` | The one hand step, from your usual terminal. |

## How to run

From the clone's root, in Windows PowerShell:

    powershell -NoProfile -ExecutionPolicy Bypass -File tests\m9\s62-auto.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\m9\s62-hand.ps1 -Exe C:\t12\release\chatq-overlay.exe

Run both with `-File`, never dot-sourced (the hand run refuses that). The
hand run restores its process's variables at the end, so even `&` from a
shell leaves that shell as it was.

The auto run takes about 7 minutes and needs nothing from you. It reads
no input, so it can run with stdin closed. It writes `data/s62/auto.json`,
then prints a table and the cold-time verdict. If a step fails, it still
writes what it measured, plus an `error` field. The hand run takes about
5 minutes and asks you to act six times. It writes `data/s62/hand.json`,
then prints a table, the terminal's parent chain and the other verdicts.

During the hand run:

- Click only what a step asks for. A chat row or chip clicked by mistake
  opens nothing (`ChatCodeSeam`, and `CHATQ_CODE` points at a file that
  is not there).
- Leave the console's close button and Esc alone. The step's
  console-back hides the console. A console closed by hand leaves the
  host thinking it is still open.
- If y/n gets no answer after five tries, the step records `?`.
- The sandbox panel registers Ctrl+Alt+Shift+F10 system-wide while it
  runs. If something else already holds F10, registration fails and step
  2 shows no open. Your overlay's O and Q are never registered by it.

## What each measures

**s62-auto.ps1**

- **(a) Today's console in the host** (`s62-host.ps1 -Mode inproc`, with
  collect.ps1's stand-in panel):
  - the host's private MB after 60 s, with no console parts loaded
  - the parts' import, timed to the first frame
  - MB with the console open 10 s, and 30 s after console-back
  - the warm in-host verb-to-frame time
- **(b) The prototype standalone:**
  - six cold starts of `s62-console.ps1`, each timed from the spawn to
    its first frame and to its lists filled. Run 1 is shown apart; runs
    2-6 give a median and a max.
  - MB 10 s open
  - five warm re-shows
  - MB 30 s after the last back
  - one `-Measure warm` start's first show
- **(c) The prototype started by `s62-host.ps1 -Mode spawn`:**
  - the host's MB with no parts
  - the child's STARTUPINFO, and its IsWindowVisible and DWM cloaked
    state at its first frame. Cloaked windows still count as visible to
    IsWindowVisible.
  - the grant's outcome
  - verb-to-frame times, cold and warm
  - MB of both processes, with the console open and after back

**s62-hand.ps1** uses the real panel, the sandbox host `-Mode spawn -Grant pid`
and a visible console. It runs six steps:

1. the panel's console button
2. Ctrl+Alt+Shift+F10
3. the tray menu's Open console
4. the panel's button again, with the console warm
5. `charlie -Console`
6. AllowSetForegroundWindow(`data/overlay.pid`), then `charlie -Console`

After each step it records:

- your y/n answer: did the console come to the front with the cursor in
  its text box?
- the host's `allow` and `lastError`, and which process was in front
- the console's own reading at +0, +500 and +1500 ms: in front, active,
  prompt focused
- the time from the overlay-cmd line to the first frame

Every step except step 4 starts the console cold. After a step, its back
also ends the console process (`data/s62/host-cold`), so the next step
starts a new one.

## Decision rules (printed at the end of both runs)

- Cold median (runs 2-6) <= 2.0 s and max <= 3 s => exit on close
  (KeepMinutes 0). Otherwise warm 15.
- allow=false on steps 1-3 => Rust ASFW_ANY for console verbs.
- allow=true but not in front when cold, while warm is in front => warm.
- Step 6 in front and step 5 not => `charlie -Console` grants
  `overlay.pid`.

## Isolation

- **Your live copy is never used.** Every root is the clone.
  `Assert-S62Root` refuses:
  - the live copy, or a folder under it
  - a root that leads back to it some other way: a junction, symlink,
    8.3 short name or `subst` drive (`Get-S62RealPath`)
  - a network path, or any root whose real path cannot be read
  - code past 0.11.1: no `Import-ChatOverlayConsoleParts` in its
    `src/overlay-host.ps1`

  A sibling such as `<live>-clone` is not refused. The tool is
  dot-sourced from the clone, so its data root is `<clone>/data`
  (`$script:ChatqData`), and the scripts check this after loading.
- **A real data folder is never used.** `Set-S62Sandbox` stops the run
  if `data/` has anything besides `s62/` and no safety `config.json`.
  That case may be a real data folder copied in.
- **Runtime files stay in the clone's `data/`.** Everything an s62 run
  writes goes under `<clone>/data`, and its own files under
  `<clone>/data/s62`. Nothing goes to TEMP or APPDATA. The Windows calls
  are emitted in memory, and the tool's own compiles put their working
  files in `data/tmp` (`Invoke-ChatCompile`).
- **The sandbox config is protected and safe.**
  - `config.json` is collect.ps1's safety config, with
    `overlay.panel=native`, `hotkey=none`,
    `consoleHotkey=Ctrl+Alt+Shift+F10` and `autoStart=false`, and no
    usage fetch.
  - A config.json that is neither an s62 nor a collect.ps1 safety config
    is never overwritten.
  - `overlay-state.json` places the panel at 300,300.
  - Your overlay's Ctrl+Alt+Shift+O and Q stay its own.
- **Environment variables are set only in each run's processes.** The
  fake homes and CLIs are `CLAUDE_CONFIG_DIR=data/s62/fake-claude` (one
  transcript, no credentials), `CODEX_HOME=data/s62/fake-codex`,
  `CHATQ_CLAUDE`/`CHATQ_CODEX=tests/fake-claude.cmd`, and a `CHATQ_GH`
  and a `CHATQ_CODE` that do not exist. Each s62 process sets these for itself
  (`Set-S62Env`), and the consoles that auto starts get theirs through
  ProcessStartInfo. Nothing is set for the machine or the user.
- **No real side effects.** collect.ps1's stubs and seams are in place
  (`Set-S62Seams`): no watcher, outbox, phone setup, relaunch, toast,
  ntfy or usage fetch. An open starts no VS Code and makes no front call.
  `Get-ChatqHomeDir` with no override returns the fake homes, never
  `~/.claude` or `~/.codex`. Each call is logged to
  `data/s62/seam-calls.log`.
- **The auto run never shows or activates a window.** It uses
  `CHATQ_CLOAK`, `CHATQ_NOFRONT` and `CHATQ_NOTRAY`, and the console
  never activates (`ChatConsoleFrontSeam` is a no-op). Only the hand
  run's console (`-Visible`) calls `Window.Activate`. Nothing drives the
  mouse or keyboard, and the only front call made is
  AllowSetForegroundWindow, which grants rights and takes nothing.
- **Only what a run started is stopped.** Every process a run starts is
  tracked by pid and start time, and those are the only ones it stops or
  ends. A sandbox overlay already running in the clone stops the run
  before anything starts.
- **The prototype console never writes the host's files.** It takes no
  overlay-cmd lines (`-Peek`). It never saves `overlay.json`, because
  `SavedAt` is set to its maximum, or `overlay-events.json`, because
  `Save-ChatOverlayEvents` is a no-op. It starts no index sync
  (`ChatConsoleNoSync`).
