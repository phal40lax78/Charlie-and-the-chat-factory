# VS-code-chat-manager

Find, delete, archive and queue prompts for your local AI chats — Claude Code,
Codex and GitHub Copilot Chat — from PowerShell.

[![marketplace](https://vsmarketplacebadges.dev/version-short/redaechan.vs-code-chat-manager.svg)](https://marketplace.visualstudio.com/items?itemName=redaechan.vs-code-chat-manager)
[![release](https://img.shields.io/github/v/release/phal40lax78/VS-code-chat-manager)](https://github.com/phal40lax78/VS-code-chat-manager/releases)
[![test](https://github.com/phal40lax78/VS-code-chat-manager/actions/workflows/test.yml/badge.svg)](https://github.com/phal40lax78/VS-code-chat-manager/actions/workflows/test.yml)
[![licence](https://img.shields.io/github/license/phal40lax78/VS-code-chat-manager)](LICENSE)
[![PowerShell 5.1 | 7](https://img.shields.io/badge/PowerShell-5.1%20%7C%207-5391FE?logo=powershell&logoColor=white)](#requirements)
[![sponsor: coming soon](https://img.shields.io/badge/sponsor-coming%20soon-lightgrey?logo=githubsponsors)](FUTURE_WORK.md#sponsorship)

![chatq queueing a prompt for a chat picked by its title, to be sent a minute after the five-hour limit resets](docs/demo-queue.svg)

![chatqlist: two queued prompts, a long one folded to its first line, the usage and when the limit resets](docs/demo-list.svg)

- **Find any chat by part of its title** and Tab-complete it: `chatfind`, `chatrm`, `chatq`.
- **Delete one chat** and everything it leaves on disk, or **archive** it and bring it back later.
- **Queue prompts while the usage limit is hit.** At the reset each chat is resumed in turn, sent its prompt, and run to the end.
- **Picks up what the limit cut off:** once it is over, the panel asks and continues those chats on a click - or, chosen, [continues each by itself](#auto-continue) a minute after the reset.
- **Waits out `API Error: 529 Overloaded`** by watching status.claude.com, and resumes as soon as Claude Code is back.
- **Tells you how it went:** a desktop toast, your phone through Join or ntfy, or a command of your own.
- **Shows every running chat at a glance:** `chatoverlay` keeps a small panel on top — each open chat's project, title, newest prompt and whether it waits on you, with usage live at the top. On Windows it starts by itself, and a click on a chat opens it as a tab in VS Code.
- **Does all of it in the panel's place:** `chatconsole` turns the panel into a console — pick a chat, write to it, drop files on it, send now or queue it; continue the chats the limit cut off; start new ones; run the queue.

One script and the `src/` folder it loads, no modules, nothing to build. It was two tools — chatrm and chatq — and is now one, with one index and one install.

## Install

**From VS Code:** install **VS Code Chat Manager** from the
[Marketplace](https://marketplace.visualstudio.com/items?itemName=redaechan.vs-code-chat-manager) -
search the Extensions view, or:

```powershell
code --install-extension redaechan.vs-code-chat-manager
```

On its first start it puts the scripts in `~/Tools/VS-code-chat-manager`,
asks once before adding the line that loads them to your PowerShell profile,
and from then on VS Code's own extension updates keep the scripts up to date
too. [What it does, step by step](extension/README.md). Then open a new
terminal and type `chat`.

**Terminal only**, without the extension:

```powershell
iex (irm https://raw.githubusercontent.com/phal40lax78/VS-code-chat-manager/main/install.ps1)
```

Then type `chat`. The commands are live in the shell you ran that in, and the
line the installer writes into `$PROFILE` brings them back in every new one. It
downloads the repo as one zip and copies `VS-code-chat-manager.ps1` and `src/`
to `~/Tools/VS-code-chat-manager`; set `$env:CHAT_MANAGER_DIR` first to put it
somewhere else. The first install builds the search index, about 30 seconds.

Already have the files? Load the script and install. It loads its parts from
`src/` beside it, so copy the two together; without them it says which are
missing and loads nothing.

```powershell
. "$HOME\Tools\VS-code-chat-manager\VS-code-chat-manager.ps1"
chatinstall
```

The leading dot matters: `. file.ps1` loads the commands into this shell, while
`& file.ps1` runs them into a scope that is thrown away. The script notices and
prints the line you meant.

**Coming from chatrm or chatq?** `chatinstall` replaces their profile lines with
this one — both define the same commands. The commands keep their names.

**Updating:** with the extension, VS Code does it. VS Code fetches a new
version by itself, and a window starts running it once you click **Restart
Extensions** or reload. Either ends the Claude chats of that window, so the
version still running says the new one is there and which chats a reload
would stop, and can wait until they are idle
([When chatq itself updates](#chats-open-in-vs-code-and-the-extension)).
The first window to do so puts the new scripts in place. An extension installed from a `.vsix` file is pinned and never
updates by itself: right-click it in the Extensions view and turn on **Auto
Update**. Without the extension, run the one-liner again. It says `updated 0.2.0 -> 0.3.0` or `unchanged`; an
`unchanged` right after a push is GitHub serving the old copy for a few
minutes. Either way a background watcher that is running switches to the new
copy after its current job, and a running overlay restarts on it at once. The
extension never writes into a folder that is a git checkout; it says when the
scripts there are another version than itself.

## Contents

- [Commands](#commands)
- [Find and delete](#find-and-delete)
- [Archive and restore](#archive-and-restore)
- [Queue prompts for when the limit resets](#queue-prompts-for-when-the-limit-resets)
- [Alerts](#alerts)
- [The overlay](#the-overlay)
- [The console](#the-console)
- [Chats open in VS Code, and the extension](#chats-open-in-vs-code-and-the-extension)
- [Codex](#codex)
- [Where it looks, and what it writes](#where-it-looks-and-what-it-writes)
- [How it compares](#how-it-compares)
- [Things to know](#things-to-know)
- [Uninstall](#uninstall) · [Requirements](#requirements) · [Sponsorship](#sponsorship)

## Commands

| | |
|---|---|
| `chatfind "text"` | find chats by title or message; emits objects |
| `chatrm <id>` / `chatrm "title"` | delete a chat, permanently |
| `chatrm ... -Archive` / `chatrestore [<title>]` | put a chat away / list the archive, bring one back |
| `chatclean` | delete ghost chats left behind by the VS Code list; list again chats Claude Code hid |
| `chatq <title\|id> [-Prompt s]` | queue a prompt for that chat; without `-Prompt` an editor tab opens |
| `chatq <title> -Continue` | queue *"Continue from where you left off."* for a chat the limit cut off |
| `chatq -AutoContinue ask\|on\|off` | once the limit is over, ask to continue what it cut off (the default); [continue each by itself](#auto-continue); or only mark them |
| `chatq <title> -AutoContinue always\|never\|default` | one chat's own [auto-continue](#auto-continue) |
| `chatq <title> -Attach a.png, b.pdf` / `-Paste` | send files, a screenshot or the clipboard with the prompt |
| `chatq <n>` | open queued prompt *n* in the editor — edits count until it is sent |
| `chatqlist [-Board] [-All]` | what is queued, when it sends, what ran, the usage |
| `chatqrm <n> [-Force]` | drop a job; `-Force` cancels a running one |
| `chatqrun [<n>] [-Now] [-First] [-Stop]` | requeue *n*, move it up, stop waiting and try now, stop the watcher |
| `chatqlog <n> [-Raw]` | what a run did |
| `chatnotify [-Setup] [-Pair] [-Test]` | desktop, phone and command alerts, and replies from the phone; `-Setup` has all of it in a window (Windows) |
| `chatoverlay [-Stop] [-Collapse] [-Refresh] [-Console] [-Theme dark\|light\|system] [-Print]` | every open chat, the queue and live usage in a panel that stays on top; `-Console` opens the console |
| `chatconsole` | all of the above in the panel, grown into a console: write, send now, queue, continue, new chats; Esc for the panel again (Windows) |
| `chatproviders` / `chatindex` | which tools were found / rebuild the index |
| `chatinstall` / `chatuninstall [-All]` | add to, or drop from, your profile |
| `chat` | cheat sheet |

`chatrm` flags: `-Force` `-AllProjects` `-WaitForIdle` `-DropJobs` `-Archive`
`-Provider claude|copilot|codex`. `chatfind` adds `-Deep` and `-All`.
`chatq` flags: `-WhatIf` (show the pick only), `-Mode auto|acceptEdits|…`,
`-Model <name>`, `-First`, `-At 13:00` / `-In 2h`, `-AllProjects`,
`-Provider claude|codex`, `-Attach <files>`, `-Paste`, and
`-AutoContinue on|ask|off|always|never|default`, which goes alone.

```powershell
chatfind commit | Select-Object Provider, Title, Id, Age
```

## Find and delete

Claude Code, Copilot Chat and Codex keep every chat on disk, and none offers a
per-chat delete: `claude project purge` works a whole project at a time, and
archiving in VS Code only hides a chat. `chatrm` deletes one chat, whichever
tool wrote it.

Type any part of a title — no quotes, no id, no exact spelling — then press Tab:

![The prompt reading "chatrm upload", with the Tab key drawn under it, beside the chat panel's session list, which holds a chat named "Flaky upload test"](docs/demo-1-type.svg)

Tab fills in the whole argument, quoted for you, with the chat's age and which
match it is: `(1d)` since it was last touched, `#1/1` the only chat that matched.
Then Enter:

![The same prompt, now reading "chatrm 'Flaky upload test' (1d) #1/1", with the Enter key drawn under it](docs/demo-2-tab.svg)

![The chat reported deleted, followed by a note that the session list is cached and needs a window reload, while the panel still lists the chat](docs/demo-3-deleted.svg)

The panel still lists it until the window reloads — VS Code caches the session
list (**Ctrl+Shift+P → Developer: Reload Window**, or the
[extension](#chats-open-in-vs-code-and-the-extension) offers a button). After
that it is gone there too:

![The panel's session list after a window reload, no longer listing the deleted chat](docs/demo-4-reloaded.svg)

### Tab

Tab fills in the **whole argument**, not the word under the cursor — for
`chatrm`, `chatfind` and `chatq` alike:

```
chatrm gitign<Tab>     chatrm 'Gitignore file' (21d) #1/2
(down)                 chatrm 'Gitignore rules' (5d) #2/2
```

Tab/down for the next match, Shift+Tab/up for the previous, Enter runs it,
Ctrl+Space opens the full list. Hex matches ids. Subagent chats are left out
unless `-All`, and `chatq` is never offered a Copilot chat. Opt out with
`$ChatNoKeyBindings = $true` before the dot-source.

### Deleting is permanent

Titles match on **substring**, so part of a title is a search, not a choice —
`chatrm Haiku` matches *Haiku ChatGPT Opus Astra*. So a fragment never deletes
on its own:

- **Part of a title:** Enter fills the match in, the way Tab would, and has to be
  pressed again on the full title. Where no key handler reaches — a script,
  `-NoProfile`, no VT — it asks `delete permanently? y / Enter = yes`.
- **A whole title** deletes. Typing all of it is the decision.
- **An id** deletes. An id is exact.
- **`-Force`** skips all of the above.

There is no recycle bin. `chatrm` removes the transcript and everything it
leaves behind — for Claude the sidecar folder (subagents, tool results),
`file-history`, `session-env`, `tasks`, `debug`, the security, telemetry and todo
files, a background job's folder, and its plan file when no other chat in the
project shares it; for Copilot `chatEditingSessions`. The inventory follows
[claude-chats-delete](https://github.com/ataleckij/claude-chats-delete)'s. The
leftovers go only once the transcript is really gone: on Windows a chat a live
window still holds open fails as `LOCKED`, and keeps all of it.

A chat with a prompt queued for it by `chatq` is kept, and the job named;
`-DropJobs` drops the jobs first.

### Scope

Titles match chats of the directory you are standing in — Claude by its project
slug, Copilot and Codex by the folder name — so a sibling repo never answers for
this one. `-AllProjects` widens it. Ids skip scoping: one id is one chat.

### Ghosts

A chat still listed in the panel is one the window is tracking, and the window
writes it back as an empty stub when it reloads. A `FileSystemWatcher` takes that
stub back the moment it lands, and `data/rewritten.txt` remembers the delete for
shells that were not open at the time. `chatclean` sweeps whatever slips past.

### Reloading safely

A reload restarts every extension in the window, so one taken mid-answer loses
that answer — and every workflow and background agent that chat started dies
with it. Every delete ends by saying whether now is a safe moment —
`all project chat is idle - safe to reload now` — and `-WaitForIdle` blocks until
it is. The window's Reload offer says the same (see
[the extension](#chats-open-in-vs-code-and-the-extension)).
Showing a queued run's chat fresh is no reload: the chat opens in an editor
tab of its own, and nothing else in the window restarts. It still acts
without asking only on the same judgement.

What counts as a chat still working, in this project:
- **Claude says so.** `claude agents --json` lists every chat open in a window as
  `busy` or `waiting` (a permission prompt).
- **Work sent to the background.** The turn that starts a workflow or a
  background agent ends at once, so the chat can read as finished while the
  work goes on. Its transcript is searched for a start with no
  `<task-notification>` after it. Only starts since the chat's process began
  count, because anything older died with an earlier process. A background
  shell does not count: it may be a server that never stops.
- **The transcript itself**, for Codex and for chats Claude does not list.
  Anything written in the last minute counts. So does an unanswered `tool_use`,
  because a chat parked on a permission prompt writes nothing.

The extension asks the same of one window's chats, wherever their folders,
right before it reloads the window, for a queued run or for a new version
of itself ([When chatq itself
updates](#chats-open-in-vs-code-and-the-extension)).

## Archive and restore

```powershell
chatrm 'Old experiment' -Archive     # out of the way, not gone
chatrestore                          # what is archived
chatrestore 'Old experiment'         # back where it was
```

- **Claude:** the transcript and its leftovers move into
  `data/archive/claude/<id>/`, with a manifest of where each came from.
  `chatrestore` moves them back — replacing the empty stub the window may have
  written there meanwhile, never a real chat — and the panel shows it after a
  window reload. A chat still open in a window is not archived: it would go on
  writing to the old path.
- **Codex:** through Codex's own `codex archive` / `codex unarchive`, since Codex
  keeps thread state in its own databases. `chatrestore` lists what chatrm
  archived, and threads in Codex's `archived_sessions` folder when it has one.
- **Copilot:** VS Code archives those itself, from its chat list.

`chatuninstall -All` refuses while the archive holds anything — it is the only
copy — unless `-Force`.

## Queue prompts for when the limit resets

The VS Code panel queues a message you send while Claude is working. What it
won't do is hold one you send while the subscription limit is used up: that is
refused with *"You've hit your session limit"* and dropped. So you wait, and at
the reset you go round every chat typing again. `chatq` is the queue for that
moment:

```
PS> chatq 'Parser rewrite and plugin unification' -Prompt 'Also update the changelog'
  -> 'Parser rewrite and plugin unification' (2h)  claude · exact title
     auto (as the chat last ran) · D:\src\parser
  queued #1  sends 13:01 (five_hour limit resets 13:00)
```

### Long prompts, files and screenshots

- **Long text, quotes, anything:** leave `-Prompt` off. An editor tab opens on
  the prompt file; paste anything into it — quotes, newlines, `$`, Hangul — then
  save and close it. `chatq <n>` reopens it, and edits count until it sends.
- **Files:** `-Attach a.png, spec.pdf, notes.txt`, with commas — after a space
  the next name would be read as part of the title — or `-Attach .\shots\*.png`.
  They are copied into the job (`data/queue/<id>/`) at once, so the originals
  can move or change; one missing or locked queues nothing.
- **The clipboard:** `-Paste` takes what is on it now — a screenshot, files
  copied in Explorer, or text, which becomes the prompt or goes under the one
  given. Windows only.
- **In the editor tab,** Ctrl+V pastes a screenshot into the prompt. VS Code
  saves it beside the prompt file, in `data/queue/`, and chatq moves it into the
  job. A link to any other file is left as it is: it names that file where it
  is, for the chat to open — or change — there, not a copy of it.
- **Forgot one?** `chatq <n> -Attach shot.png` (or `-Paste`) adds to job *n*
  while it waits.

| | images (png, jpg, gif, webp) | other files |
|---|---|---|
| Claude | named under the prompt; Claude Code opens each with its Read tool and sees the picture | named under the prompt; it reads text, code and PDF |
| Codex | attached with `-i`, as if pasted into the chat | named under the prompt |

What goes under the prompt reads `Attached files - read each one:`, then the
paths. A "continue" sends none — they went with the prompt. `chatqlist` counts
them (`+2 files`); delete one from the job's folder to drop it, and `chatqrm`
removes them with the job. Over 10 files or 20 MB draws a warning: each one
costs context, and usage.

### How it picks the chat

It picks when you queue, not when it sends — you are at the keyboard now and gone
later, so the pick is printed while a wrong one can still be undone
(`chatqrm <n>`).

1. **An id** (hex, at least 6 characters) is that chat.
2. **A title** is matched in this project first — *exact*, then *contains*, then
   *every word in any order* — and in every project only when this one has none.
3. **Nothing matches:** the candidates are this project's chats. It never guesses
   across projects, and standing in no project at all it refuses unless
   `-AllProjects`.
4. **Several candidates:** the newest wins, unless others were active within 5
   hours of it — one limit window — and then the most relevant one does: the
   cosine of character pairs between what you typed (and the prompt) and each
   chat's title and prompts. Pure PowerShell, no model call, Hangul and English
   alike. The runner-up and both scores are printed.

A Copilot chat is found but refused: no CLI can resume one.

### When it sends

- **The reset time** comes from the record Claude writes into the transcript it
  cut off, or from Codex's rate-limit snapshot.
- **A probe goes first:** a throwaway `ok` that saves no session, asked with the
  model the run will use. Sending the real prompt while still limited would
  plant it, and an error after it, in your chat.
- **One job at a time, in queue order** — oldest first, `-First` jumps the line.
  A Claude job never waits behind a Codex limit, nor one account behind another.
- **In the permission mode the chat last used**, `-Mode` overriding it for one
  job, and on the chat's own model, `-Model` overriding that. Anything that would
  ask a question is denied, since nobody is there to answer.
- **Needs input:** a denied tool, or plan mode stopping at a plan, parks the job
  and the queue moves on. `chatqrun <n> -Mode acceptEdits` sends it a "continue"
  in a mode that allows it. Or answer it in the chat itself: once anything is
  typed there after the job stopped - in VS Code, a terminal, or by a later
  job - the overlay skips the job, `answered in the chat`, as a reply from
  the phone skips one, and nothing says it needs you any more. The overlay
  has to be running for that; until then, `chatqrm <n>`.
- **A limit hit again mid-run** puts the job back; if its prompt had reached the
  chat, the retry is a "continue", never the prompt twice.
- **`API Error: 529 Overloaded`** (any 5xx) is Anthropic's side. The job goes back
  and chatq watches <https://status.claude.com> every minute, resuming the moment
  Claude Code is `operational` again; one the page never shows is retried after
  1, 2, 5 and 10 minutes, then every 15. One alert, and a reminder at 6 hours.
- **A dropped connection** is retried after 1, 2 and 5 minutes, then fails.
- **A refused login** — an expired login, or a subscription that ran out, which
  the API turns down the same way — holds that account's jobs, with one alert
  that quotes what Claude or Codex said: `Claude login refused: OAuth token has
  expired. (401)`. They go once the login works again; chatq looks every 15
  minutes.
- **A job that keeps breaking before any reply** gives up after `maxRetries` (5)
  tries in a row. A long task that gets through several limit windows moves on
  each time and is never stopped by this.

Chats you left cut off — by the limit or a 529 — show in `chatqlist`, and
`chatq <title> -Continue` queues one - or, once the limit is over, the
overlay [asks](#when-the-limit-is-over), or with
[auto-continue](#auto-continue) on it is done by itself. A continue chatq
queued itself is dropped if the chat moved on meanwhile, and so is a
`-Continue`; one you ask for again with `chatqrun <n>` is always sent.

### When the limit is over

The overlay asks, once, whether to continue the chats the limit cut off.
Five minutes after the reset - room for Claude Code to continue a chat open
in a VS Code panel itself, and for a fresh usage figure - it counts them,
and one prompt offers all of them:

- **a toast** on Windows, `chatq - limit over at 13:00`, naming the first
  three. A click on it opens [the console](#the-console) with the chats
  listed; it never answers by itself, since a toast is often clicked just
  to be rid of it;
- **a banner** at the foot of the panel's header,
  `limit over at 13:00 · 3 chats it cut off can continue`. Rest the
  pointer on it for its chip: **continue 3** or **leave them**;
- **the tray's menu**, at its top: **Continue 3 cut-off chats** and
  **Leave them**;
- **the console's Cut off header**, with **Leave them** beside
  **Continue all**;
- **the phone**, when you are away: one `limited` alert, answered at the
  PC ([Alerts](#alerts));
- **macOS**: a notification, and the two items at the top of the `CQ`
  menu.

**Continue** queues *"Continue from where you left off."* for each chat,
the job `chatq <title> -Continue` makes, and starts the watcher. **Leave
them** leaves them as they are: their rows stay orange, and **Continue
all** in the console, or `chatq <title> -Continue`, still continues one.
Either way that cut-off is not asked about again; the same chat cut off by
a later limit is a new one.

Left out, and why:
- **a 529** - it has no reset to wait for;
- **a chat a terminal's `claude` holds** - Claude Code waits for the reset
  there itself, and a run beside it would make two writers. The banner's
  tooltip names it;
- **a chat with a job queued or running** - it goes anyway;
- **a reset over 12 hours ago**, and **a limit record with no reset time**
  (from older Claude Code) - left to you; the orange row stays;
- **everything, while a 5 h or weekly window is still at its limit** - the
  chats could not go yet. The ask waits for that reset.

**Turning it off:** the settings box's **Cut off** → **Leave**, or
`chatq -AutoContinue off` (`ask` turns it back on). Either writes
`"autoContinue": "off"` at the top of `data/config.json`. Off, a cut-off
chat is only marked orange, as before 0.9.0. **Continue** there, or
`chatq -AutoContinue on`, is [auto-continue](#auto-continue): nothing is
asked, each is continued by itself. Nothing asks while no overlay runs,
and `chatoverlay -Print` shows the ask but never acts on it.

**What gets written:** one file per cut-off in `data/auto/` - named after
the chat's id and its limit record - holding the answer (`continue` or
`leave`), when, where it was given (`overlay`, `console`, `mac`), and the
job numbers; and an empty `.shown` beside it once the prompt was
announced, so a restarted overlay does not announce it again. Files over
8 days old are deleted. `overlay.log` gets a line for each ask and each
answer (`ask: continued 3 - #12 #13 #14`).

### Auto-continue

With the switch **on** - chosen; the default asks, above - chatq queues
*"Continue from where you left off."* by itself for a Claude chat the
usage limit cuts off, and it goes a minute after the limit resets. Only
what the limit cuts off from the moment it is turned on: older cut-offs are
shown, never queued. Each chat can also be set to always or never, whatever
the switch says.

```powershell
chatq -AutoContinue on                       # every chat the limit cuts off, by itself
chatq -AutoContinue ask                      # the default: ask once the limit is over
chatq -AutoContinue off                      # none - they are only marked
chatq 'Parser rewrite' -AutoContinue never   # this chat: never by itself
chatq 'Parser rewrite' -AutoContinue always  # this chat: even with the switch on ask or off
chatq 'Parser rewrite' -AutoContinue default # this chat: follow the switch
chatq 12 -AutoContinue never                 # the chat of job 12
```

The same switch is the overlay's settings box (**Cut off**: Continue, Ask
or Leave), its tray menu (**Auto-continue cut-off chats**, checked while it
is on; unchecked goes back to Ask), the Mac menu's item and **Chat Manager:
Auto-continue cut-off chats...** in VS Code: all of them set `autoContinue`
in `data/config.json`. A chat's own setting is in `data/auto-continue.json`,
which the console's **Auto-continue after a limit** chips set too. The
phone can do neither: turning it on would widen what runs unattended, and
turning it off from a phone that may not be yours would be a quiet way to
stop work.

| chat | auto-continued? |
|---|---|
| not open anywhere - its tab, window or terminal closed | **yes** |
| open in a VS Code panel, idle | **yes**, 5 minutes after the reset: the panel may continue it itself, and then chatq's finds it moved on and is skipped |
| open in a terminal's `claude`, or held by any other process (a background session, a `claude -p`) | **no** while that holds it - Claude Code's own wait is there. Once that exits, the next look queues it |
| a side chat, a chat under another `CLAUDE_CONFIG_DIR`, a Codex or Copilot chat | no |
| cut off by a 529 | no - the limit only |

**What it checks,** in order: the switch (or the chat's always or never);
that it was the limit; that nothing but a VS Code panel holds it; that
nothing is queued for it already; that the cut-off is new enough - after
the switch was turned on, under 12 hours old, and its reset under 24 hours
after it, so a weekly limit days out is left to you, as Claude Code leaves
it; that its reset has not passed by more than 30 minutes, which means you
came back to it; that this cut-off was never queued, or answered at the
reset ask, before; and that fewer than 2 auto-continues in a row for this
chat failed. Each cut-off is queued once: a marker in `data/auto/` - the
same file the ask's answer is - made with an exclusive create before the
job, so the overlay and the watcher never both queue one, and a continue
you removed never comes back for that reset - the next time the limit cuts
that chat off, it is continued again.

**Who looks:** the overlay, once a minute (Windows and macOS), and the
watcher every 5 minutes while it runs. With neither running nothing is
auto-continued, and `chatqlist` says so. It is only about chats chatq did not
start: a prompt you queued that the limit cuts off mid-run still comes back
as a continue, whatever the switch says.

**It runs** as `-Continue` does: in the chat's own mode and model, at the
back of the queue, a minute after the reset (5 for a chat open in VS Code).
A chat working again by then waits, and one you, or Claude Code's own wait,
continued meanwhile is skipped. One deleted or archived since is skipped
quietly, and `chatrm` drops a chat's auto-continue without `-DropJobs`,
where a job you queued still keeps the chat. Closing a chat's tab or window
does not cancel it - that is when it is most wanted.

**Taking one back:** **don't continue** on the overlay row's chip, **Don't
continue** in the console, **Don't continue** on the phone, or `chatqrm <n>`.
Continue - the chip's, the console's, `chatq <title> -Continue` - queues
one again.

**What could surprise you:**
- **Turning it on** covers only what the limit cuts off from then on. The
  Windows overlay says what it does once in a balloon, and again for the
  first continue it queues.
- **The PC stays awake** until the reset, as it does for any job due within
  6 hours; a closed laptop lid still sleeps. One that slept past the reset
  runs the continue as it wakes; a cut-off only seen more than 30 minutes
  after its reset waits for you.
- **Typing in the chat as it runs:** a chat open in VS Code is held 5
  minutes past the reset, and its row says so all the time. Anything you
  send first makes it skip. After the run, **Show it** in the window, as
  after any queued prompt.
- **Plan mode, or bypassPermissions:** it continues in the mode the chat was
  in. `reply.maxMode` does not apply - no reply is involved.
- **Two that fail in a row** - each giving up after `maxRetries` tries that
  got no reply - and it stops for that chat, with a `failed` alert that says
  so, until a turn ends without the limit or you set the chat to always.

### Status

- **`chatqlist`** is one line per job, fitted to the terminal; a long prompt
  shows its first line and a size note. Above them, what everything waits on and
  how much of each window is used — `usage  Claude 5h 83% · week 41% (as of
  12:10)` — read from Claude's and Codex's own caches, with their age, or for
  Claude the overlay's live figure where that is newer. Those
  caches only refresh when the tool itself runs, so a reading over an hour old
  is marked `stale`, and the window that is blocked reads `limited`
  (`5h limited`) rather than a percentage from before the limit.
- **`chatq <n>`** opens the whole prompt; edit it until it is sent.
- **`data/logs/jobs.log`** keeps a line per job event — queued, every state it
  moves through, and removals — so a job that left the queue can still be
  accounted for.
- **`chatqlist -Board`** opens `data/queue.md`: **Ctrl+Shift+V** there for VS
  Code's preview, which follows every change the watcher writes.

### The watcher

One per machine, a hidden PowerShell that exits when the queue is empty and is
started again by the next shell after a reboot. While a job is due within 6
hours it keeps the machine from sleeping (the display still turns off, and a
closed lid still sleeps a laptop). `chatqrun -Foreground` runs it in the console
to watch.

## Alerts

chatq tells you how a queued prompt went - and, while you are away, how
the chats you run yourself are doing - with a desktop toast, a push to your
phone through Join or ntfy, or a command of your own. With a phone paired,
you can answer an alert from the phone.

**The setup window.** `chatnotify -Setup` opens all of it in one window -
also **Phone alerts...** in the overlay's tray menu, and **Chat Manager:
Phone alerts...** in VS Code's command palette:
- **Join:** paste the API key from <https://joinjoaomgcd.appspot.com> (the
  **Join API** button) - the key alone, or the whole push URL that page
  shows, whose key and device are taken out of it. **Find devices** (or
  Enter in the key box) asks Join which devices the key has, with Join's
  groups after them - all phones, all Android, every device. Pick one, then
  **Send test**.
- **Replies:** **Reply from the phone**, **Pair phone**, a line saying
  which phone is paired and how long the watcher listens, and the answers
  to a pairing, each with **Confirm** ([Pairing](#pairing)).
- **What reaches the phone:** a box per event; **Quiet while I use this PC
  for** *n* minutes; **Chats I run myself, when I'm away**
  ([below](#chats-you-run-yourself)); **Desktop toast**.
- **Other channels**, folded away: an ntfy topic, server and token, and
  your own command.
- **Read aloud** under Send test, **Quiet hours** with what still comes
  through, **Usage at** *n* % and **When a limit resets** - the four
  features below.

**Save** (Ctrl+S) writes `data/config.json` through the same code as the
switches below, so the two never disagree. **Send test** saves first, and
sends in the background, so the window stays live however slow the network
is; closing it with something unsaved asks first, in the window. One window
at a time. It is WPF, so Windows only; elsewhere `chatnotify -Setup` prints
the switches that do the same.

```powershell
chatnotify -Setup                                   # all of it in a window (Windows)
chatnotify -ApiKey <Join key> -Device group.phone   # Join
chatnotify -Ntfy <long random topic>                # ntfy.sh, free
chatnotify -Command '<PowerShell>'                  # anything else
chatnotify -Test
chatnotify                                          # what is set up, and the phone's state
```

`chatqnotify`, the name from when alerts were only about chatq's queue,
still works and does the same.

| channel | |
|---|---|
| desktop toast | on by default (`-Toast off`); nothing leaves the PC |
| Join | keys at <https://joinjoaomgcd.appspot.com>, the **Join API** button; DPAPI-protected on Windows. The alerts about one chat are one notification on the phone, and carry chatq's icon |
| ntfy | published as JSON, so Hangul survives; the topic works as a password — pick a long random one, or your own server with `-NtfyServer` / `-NtfyToken` |
| your command | runs with `$env:CHATQ_EVENT`, `CHATQ_TITLE`, `CHATQ_TEXT`, `CHATQ_PRIORITY`, `CHATQ_JOB`, `CHATQ_PRESENT`; the text never goes on a command line; 30 s at most |

| `chatnotify` switch | |
|---|---|
| `-Setup` | the setup window (Windows); elsewhere it prints these switches |
| `-ApiKey <key>` `-Device <id>` | Join. `-Device` takes a device id, a group (`group.phone`, `group.android`, `group.all`) or a device's name. A push URL pasted bare never reaches chatq - PowerShell stops at its first `&` - so paste the key, or the URL in quotes |
| `-Devices [-ApiKey <key>]` | the devices on the Join key saved, or on the one given, and Join's groups |
| `-Ntfy <topic>` `-NtfyServer <url>` `-NtfyToken <token>` | ntfy |
| `-Command '<PowerShell>'` | your own command on every alert; `''` removes it |
| `-Toast on\|off` | the desktop toast |
| `-QuietMinutes <n>` | how long since your last keyboard or mouse input the phone stays quiet; 5 by default, 0 never quiet |
| `-Events done, failed, 'needs input'` | only these reach the phone - of `started`, `needs input`, `done`, `failed`, `limited`, `overloaded`, `waiting`; `all` for every one. The toast, the command and `alerts.log` still get every event, and tests, replies and the pairing push always go |
| `-LiveAlerts on\|off` | alerts about [the chats you run yourself](#chats-you-run-yourself); on by default |
| `-Reply on\|off` | [answer alerts from the phone](#reply-from-the-phone); `on` with no phone paired starts a pairing |
| `-Pair` | pair a phone, afresh ([Pairing](#pairing)); `-Reply renew` is the old name for it |
| `-Confirm 123456` | confirm the code the phone shows |
| `-ReplyPage <https URL>` | serve the reply page from a copy of your own; `''` for the default again |
| `-UsageAt 75, 90` `-UsageAlerts on\|off` `-UsageReset on\|off` | [usage heads-ups](#usage-heads-ups): the thresholds, and the alerts around a reset |
| `-QuietHours 00:00-07:00\|off` `-Urgent failed, 'needs input'` | [quiet hours](#quiet-hours), and what still comes through; `-Urgent none` for nothing |
| `-Say 'needs input', failed` `-SayLanguage auto\|en\|ko\|<code>` | [read aloud](#read-aloud) on the phone, through Join; `-Say none` for nothing |
| `-Permit on\|off` `-PermitWait <min>` `-PermitTools <names>` | [approve a queued run's tool call from the phone](#approve-a-tool-call-from-the-phone); off by default, 10 minutes to answer (1-25), `default` for the usual tools |
| `-FullText on\|off` | [Claude's whole answer](#the-whole-answer) on the page of a `done`, `needs input` or `failed` alert; on by default |
| `-Compose on\|off` | [the board](#the-board-any-chat-from-the-phone): the phone may queue to any chat, act on the queue and start new chats; on by default |
| `-Listen alerts\|always` | when the PC reads the phone: while an alert is out (the default), or all the time while a phone is paired |
| `-NewMode <mode>` | the mode a chat started from the phone runs in, then brought down to `reply.maxMode`; `default` unless set |
| `-Test` | a test alert, through everything set up, even while you are at the PC |
| `-Off` | Join, ntfy and the command off; alerts still go to `alerts.log` and the toast |

A few settings are only in `data/config.json`:

| key | default | |
|---|---|---|
| `join.perChat` | `true` | alerts about one chat share one notification on the phone, so `done` replaces `started`; `false` stacks them |
| `join.icon` | chatq's icon | the icon URL Join shows; `""` for none |
| `reply.hours` | `12` | how long an alert can be answered, and the watcher listens after it |
| `reply.maxMode` | `acceptEdits` | the highest permission mode a job a reply queues or requeues runs in |
| `usage.soonMinutes` | `10` | how long before a reset the soon alert goes; `0` for none |
| `permit.on` | `false` | a queued run's permission prompt asks the phone (`-Permit`) |
| `permit.waitMinutes` | `10` | 1-25; then the call is denied (`-PermitWait`) |
| `permit.tools` | `Bash`, `PowerShell`, `Edit`, `Write`, `MultiEdit`, `NotebookEdit`, `WebFetch` | what the phone may approve; `mcp__server__*` for an MCP server's tools (`-PermitTools`) |
| `permit.maxPerRun` | `10` | how many calls one run may ask about |
| `reply.fullMax` | `30000` | the characters of a whole answer sent at most (2000 to 200000); over it the start is left out |
| `reply.downPerDay` | `150` | whole answers sent a day at most; boards, lists and acks stop 50 after that (at most 200) |

**The phone stays quiet while you are at the PC** — keyboard or mouse used in
the last 5 minutes (`-QuietMinutes`, 0 turns it off) — since the toast already
says it there. `chatnotify -Test` always goes through.

| event | priority | says |
|---|---|---|
| `chatq · started` | 0 | chat, mode, first line of the prompt |
| `chatq · needs input` | 2 | chat, what was denied, the end of the reply; for a chat you run yourself, what it waits for and its folder |
| `chatq · done` | 1 | chat, how long, the end of the reply (`asks:` when it ends on a question) |
| `chatq · failed` | 2 | chat, why — including a refused login, in the CLI's own words, or giving up |
| `chatq · limited` | 0 | the limit came back mid-run; when it continues. Or a chat you run yourself the limit cut off, and when [auto-continue](#auto-continue) continues it - in place of its `done` |
| `chatq · overloaded` | 0 | a 529; what status.claude.com says; a reminder after 6 h |
| `chatq · waiting` | 0 | a queued prompt's chat has been busy for 2 h; chatq waits until it is idle |
| `chatq · test` | 1 | `chatnotify -Test` or the window's **Send test** |
| `chatq · reply` | 1 | the PC's answer to a reply from the phone, or to a pairing |
| `chatq · pair` | 2 | the pairing push |
| `chatq · usage` | 0/1 | a window at a threshold, a reset coming with prompts queued, or one that came |
| `chatq · summary` | 1 | what quiet hours held |
| `chatq · permission` | 2 | chat, which kind of call, and by when - the call itself sealed in the link ([approve it](#approve-a-tool-call-from-the-phone)); always sent, even at the PC |

Every title starts `chatq ·`, so a Tasker profile can filter on it. Alerts also
go to `data/logs/alerts.log`. What they carry — the chat title, the end of the
reply — passes through the push service's servers
([what else](#what-passes-through-whose-servers)).

`chatnotify` alone prints what is set up: Join and its device, ntfy, the
command, the toast and the quiet minutes, the events the phone gets, whether
the chats you run yourself alert and what stops them (quiet minutes 0, no
overlay running, or an overlay running an older copy), and whether replies
are on - the phone paired and since when, how long the watcher listens, the
last reply, and the answers to a pairing still waiting for their code.

### Reply from the phone

Turn it on with `chatnotify -Reply on`, or **Reply from the phone** in the
setup window, and [pair the phone](#pairing). From then on every phone alert
carries a link: tap the notification, and a page opens on the phone with the chat's
title, the job's number and the event. Type the chat's next prompt and press
**Send**, or press one of the buttons the alert offers:

| alert | buttons |
|---|---|
| `done`, `limited`, `overloaded`, `waiting` | **Send** · Status |
| `limited`, a continue queued - auto-continue's, or a run of chatq's the limit cut | **Send** (goes after the continue) · Don't continue · Status |
| `needs input` | **Send** · Allow edits & continue (Claude) · Continue · Skip · Status |
| `failed` | **Send** · Retry · Skip · Status |
| `started` | **Send** (queued after this run) · Stop · Status |
| `test` | **Send a test reply** |
| about no chat - the PC's answer to Status, a test reply or a pairing | **Status** · Send a test reply |
| a chat you run yourself | **Send** · Status |
| `usage`, a reset coming | **Send now** · Status |
| `usage`, any other; `summary` | **Status** |

- **Send** queues the text as the chat's next prompt, as `chatq` would. A
  `needs input` job answered this way is skipped, "answered from the phone
  with #13". Links in the text are written so that none resolves: nothing in
  `data/queue` comes along with it.
- **Continue** and **Retry** queue the job again - as "continue" when its
  prompt already reached the chat, else with its prompt.
- **Allow edits & continue** queues a `needs input` Claude job again in
  `acceptEdits`, when its mode was below that.
- **Skip** skips a job queued, failed or waiting on input; **Stop** stops
  a running one. Both take a second tap, at least half a second after the
  first, so a double tap does neither. **Don't continue** is a skip too:
  the continue auto-continue queued goes, and that cut-off is not queued
  again.
- **Status** answers with the status line, each open job and the usage.
- **Send a test reply** answers with `reply reached <PC> after 3 s`: the
  whole way back, checked. `chatnotify -Test`, then a tap on the test
  alert, is the way to try it.

The page seals what you send on the phone - AES-256 and an HMAC-SHA256,
under a key made from the phone's own key and that alert's id - and posts it
to an ntfy.sh topic chatq made for this. The watcher polls that topic,
outbound only - nothing listens on the PC - does what the reply says, and
answers with a `chatq · reply` push, itself an alert with a link, so the
answer can be answered in turn.

**Never above `acceptEdits`.** A job a reply queues or requeues runs in its
old job's own mode, or else the chat's own, brought down to
`reply.maxMode` - `acceptEdits` unless `data/config.json` says otherwise;
the ladder is `plan`, `default`, `manual`, `acceptEdits`, `auto`,
`dontAsk`, `bypassPermissions`. Nothing in a reply picks a mode, and the
push says so when one was brought down:
`runs in acceptEdits, the phone's limit`. A Codex job never keeps a sandbox
wider than `workspace-write`.

**How long.** An alert can be answered for `reply.hours` (12), and 20 times.
Once one has gone out, the watcher listens that long: a running one from its
next pass, and when none runs one is started just to listen - and started
again by the next shell after a reboot. It polls every 15 s, and every 30 s
while a job runs, so a **Stop** reaches the run it is about. It never keeps
the PC awake to listen: a reply sent while the PC sleeps waits on ntfy.sh,
which keeps a message 12 hours, and is read when it wakes. `chatqrun -Stop`
stops the listening too, until the next alert that can be answered.

**Refusals.** A reply to an alert that expired, a reply the phone's clock
says was sent more than `reply.hours` and 10 minutes ago, and the 21st reply
to one alert do nothing; the phone is told so, at most once per alert every
10 minutes, with no link. The same message posted again runs once. The
text is 8,000 characters at most (the page stops at about 2,900 bytes).
`chatnotify -Reply off` keeps the phone paired but makes every alert out
there dead, and stops the listening; `-Reply on` picks up again with no new
pairing, and nothing sent while it was off is ever run.
`data/logs/replies.log` says what became of each reply, for one that seemed
to go nowhere.

**The page** is `docs/reply.html`, one static file served by GitHub Pages at
<https://phal40lax78.github.io/VS-code-chat-manager/reply.html>: the
repository's **Settings → Pages** has it deploy from the `main` branch,
`/docs` folder. A fork that serves its own copy the same way points
`chatnotify -ReplyPage` at it.

#### The whole answer

A `done`, `needs input` or `failed` alert about a chat also brings the
chat's whole last turn: the page shows it above the box you answer in,
`Claude's answer - 14:02`, rather than the alert's 200 characters. Claude's
text, with code blocks, inline code, headings and bold drawn and tables
kept in columns; each tool it used as one line, `-> Bash git status`, and
three or more in a row folded into `-> 5 tools`, a tap away; a limit or a
529 as a note. Links stay text. **Show all** opens it to full height,
**Copy** copies it, and while the keyboard is up it folds to one line so
**Send** stays in sight. For a job chatq ran it is that run, from its own
log - Codex's too; for a chat you run yourself, the transcript from your
last prompt on.

Over `reply.fullMax` (30,000 characters) the start is left out, since the
conclusion is at the end, and the page says how much. The PC sends it just
before the push, so it is usually there as the page opens; the page looks
for 30 s, and then offers **Ask the PC for it**, which has it sent again
while the watcher listens - also once ntfy.sh has dropped it (12 hours, or
3 for a long one). The page keeps none of it: a reload fetches it again.
Nothing is sent for other events, past the day's `reply.downPerDay` (150),
or with `-FullText off` - **Show Claude's whole answer on the phone** in
the setup window.

#### The board: any chat, from the phone

Open the reply page with no alert - a bookmark of
<https://phal40lax78.github.io/VS-code-chat-manager/reply.html>, or **Add
to Home screen** - on the paired phone, and it is the overlay, phone-sized:
- usage, a line and a bar per window, the reset when limited and `as of`
  when the figure is an hour old;
- **Waiting on you**, **Working**, **Cut off**, **Queue**, **Open, idle**
  and **Recent**, in the overlay's order and colours: each chat's folder,
  where it runs (VS Code or a terminal), its newest prompt, its age, the
  blue dot of a turn not seen yet, and the jobs riding on it; a job's
  number and when it sends, as `chatqlist` has it;
- a search over the titles and folders, every word in any order, Hangul
  as typed;
- **Older chats** under them, a tap away: the PC's 30 newest Claude and
  Codex chats that the board does not show, each with the mode a message
  to it would run in - `acceptEdits (phone's limit)` when brought down;
- at the foot, **+ New chat**, whether the PC listens all the time or
  until when, and **Status**.

Tap a chat for its view: its folder and where it runs, the mode a message
runs in at most, what a message would wait on (`working now - a message
goes when this turn ends`), its newest prompt, a box and **Send** - the
text queued as that chat's next prompt, as `chatq` would - and what fits
its state: **Send now** (as `chatqrun <n> -Now`), **Skip**, **Stop**,
**Continue**, **Allow edits & continue**, **Retry**, **Continue at reset**
for a chat cut off with nothing queued - an answer for that cut-off, as the
overlay's Continue is, so a continue you then skip stays skipped -
**Don't continue** for a continue queued for it, and **Read the last
answer**. Skip and Stop take a second
tap. A job that needs input is left alone by a message: only Continue or
Allow answers it. **+ New chat** lists the folders chatq already knows -
the board's chats', the console's, the queue's - never a path typed on the
phone; pick one, name it or not, and it starts in `reply.newMode`
(`default`: anything that would ask is denied), brought down to
`reply.maxMode`. Each answer comes back on the page, and anything that
changed the queue also as the usual `chatq · reply` push - a new chat's
naming neither its title nor its folder, which the phone sent sealed.
**Other chats** at the foot of an alert's page opens the board; **Board**
goes back to it.

The board comes from `data/overlay.json` while the overlay keeps it fresh,
else from a look at the open chats, the queue and the tools' own usage
caches, and the page says `The overlay is not running - some rows may be
missing`. It asks on open, on **Refresh**, and every 30 s while it is on
the screen, for 10 minutes, then says `Paused - tap Refresh`; never in the
background. The PC builds one board per 10 s at most - per 40 s from that
look, with no overlay running, as the look is the slower - and a second ask
within that gets the same one again, unless the phone changed the queue
since.

**The PC has to be listening.** It reads the phone while an alert is out,
as for a reply - usually the case while you are away and chats finish. For
any time, `chatnotify -Listen always`, or **Listen all the time** in the
setup window: while a phone is paired, one hidden PowerShell stays running
(about 60-120 MB) and asks ntfy.sh every 20 s - every 6 s for two minutes
after the phone asked for something. It never keeps the PC awake: a
sleeping PC answers when it wakes, if the board's ask is under 10 minutes
old and a change under 30. `chatqrun -Stop` ends it until the next shell
or overlay start. A PC that does not answer within 45 s gets the card `No
answer from the PC`, which says so.

**Its safeguards are the replies'.** Every message both ways is sealed and
checked; the phone never names a session, a job or a folder, only a
handle the board gave it, bound to one chat, job or folder for
`reply.hours` - a stale one is refused, `that list is out of date - refresh
it`, and the page asks for the board again. In an hour the PC takes 120
boards, 30 lists and statuses, and 20 changes, 5 of them new chats, from
the phone; a refusal is told once a minute at most. Everything it queues or
requeues runs within `reply.maxMode`, and `data/logs/replies.log` names
each act and handle, never a text, title or folder. `-Compose off` turns
the board off - status aside - and takes the chat list out of what the
shared site could ask for (below); so does **Let the phone queue to any
chat, or start one** in the setup window.

**ntfy.sh's free limits.** Answers go to a second topic, the down topic,
worked out from the phone's key each time and in no push, link or file.
One message each, raw-deflated before it is sealed, so most fit ntfy's
4 KB, which ntfy.sh keeps 12 hours; a longer one goes as one attachment,
kept 3 hours, 2 MB at most. ntfy.sh gives an address without an account
250 messages a day, shared with alerts sent through ntfy, so whole answers
stop at `reply.downPerDay` (150) and boards and acks 50 after that; the
board says `Few refreshes left today` when fewer than 20 remain. The
page needs `DecompressionStream` - Chrome 103, Safari 16.4, Firefox 113 or
later - and says so where it is missing; the rest of the page still works.
A phone paired on 0.8.0 needs no new pairing.

### Approve a tool call from the phone

A queued Claude run that meets a permission prompt - a `git push`, an edit
outside what its mode allows - used to be told no, and the job parked as
`needs input` until you were back. With `chatnotify -Permit on`, or
**Approve tool calls from the phone** under Replies in the setup window,
the run asks the phone instead and waits:

1. A `chatq · permission` push: `<chat> · #12 asks to run a command - tap
   to see it and answer by 10:17`. It names the chat and the kind of call,
   never the command.
2. The page shows the call itself - the command (its first 8 lines),
   the file and what an edit replaces, or the URL - with Claude's own
   description, the folder and the minutes left. What looks like a secret
   (`TOKEN=...`, `--password ...`, a URL's password, `ghp_...`, a long
   random run) shows as `***` - but only a plain value: one holding `$( )`,
   a backtick, `|`, `;`, `&`, `<` or `>` is code, and is shown as it is.
   When anything was hidden, or the call was cut to fit, the page says *Not
   all of this call is shown* - if you cannot tell what it does, Deny.
3. **Allow once** (a second tap, as Stop takes) runs that one call as shown,
   and the run goes on within about 10 seconds. **Deny** - with a note for
   Claude if you like - tells Claude no; it goes on without it, and the job
   ends `done`, its alert saying `you denied Bash(git push)`.
4. Nobody answers within `permit.waitMinutes` (10): the call is denied, and
   the rest of that run is denied without asking. The job ends as before,
   `needs input`, `denied Bash(git push) - no answer from the phone`.
   `chatqlist` and the board say `running · asks the phone: Bash, until
   10:17` meanwhile.

**Off by default, on purpose.** Before this, the phone could only ask
Claude for something; with permits on, a paired phone can make a command
run on this PC. So:
- An Allow approves exactly the call on the page and nothing else: no
  "always allow", no changed input, no other mode, and no later call of the
  run. `reply.maxMode` is not in play - no job's mode is raised.
- The phone is never asked about `AskUserQuestion`, a plan, a tool not in
  `permit.tools`, an edit of chatq's own `data/` or of a Claude settings or
  MCP file, or a command that names chatq's `data/` folder (best effort: a
  command can reach a folder without naming it). A path counts by every
  name it has - Git Bash's `/c/...`, the 8.3 short name, `\\?\`, an NTFS
  stream, `~` - and one that cannot be read counts as `data/`. Those are
  denied at once. A request whose file changed after the run asked is
  declined, never shown.
- At most 10 asks a run, 3 waiting at once, 20 an hour, and nothing more in
  a run once one went unanswered. The first answer to an alert wins; any
  later one is told `already answered`.
- The page's site is shared by every `phal40lax78.github.io` page
  ([below](#what-passes-through-whose-servers)); serve the page from a
  site of your own (`chatnotify -ReplyPage`) before turning this on.

**When it asks.** Only for a queued Claude run - Codex's `exec` cannot ask
mid-run - in a mode that prompts at all: `default`, `manual`,
`acceptEdits` or `auto`. `dontAsk` and `bypassPermissions` never prompt,
and a `plan` run still ends `plan ready - approve it in VS Code`. Replies
must be on, a phone paired, and Join or ntfy over https there to carry the
link. The phone is asked even while you are at the PC: a queued run has no
window to ask in, and the toast says so. Anything else, and the run denies
as it always did.

**How.** The run starts `claude -p` with `--permission-prompt-tool` and a
small MCP server of chatq's own, the bridge: this script, in a hidden
Windows PowerShell, which claude starts itself. The bridge does no network:
it writes each request into `data/permit/<job>/`, and the watcher - the one
process that sends pushes and polls the reply topic - sends the push and
hands the phone's sealed answer back. The bridge believes an allow only
when it opens that answer itself with the phone's key and it names that very
request, so nothing that can write into `data/` can allow anything - only
deny. A bridge that fails to start ends the run at its first prompt; the job
is queued once more without it (as `continue` when the prompt reached the
chat), and `chatnotify` says `the last run could not start the bridge`.
`data/logs/permit.log` is the bridge's side of every request, and
`data/logs/replies.log` the watcher's.

Not covered: chats you run straight in VS Code or a terminal (they would
need a hook in your Claude settings), answering at the PC, and approving a
plan or answering a question.

### Pairing

A reply needs the phone paired once. `chatnotify -Pair` - or **Pair
phone** in the setup window, or `-Reply on` with no phone paired - sends
one push, `tap to let this phone answer chatq alerts - within 15 min`:

1. **On the phone,** tap it. The page says **Pair this phone with chatq on**
   and your PC's name; tap **Pair**. The phone makes a key of its own, sends it to
   the PC sealed to a public key the push carried, and shows a six-digit
   code, `123 456`.
2. **On the PC,** confirm the same code. `chatnotify -Pair`, in a console
   that can ask, waits for the answer and asks,
   `Android - Chrome 128 answered - code 123 456` and
   `same code on the phone? (y/n)`; Ctrl+C stops waiting and leaves the
   pairing open. Later, `chatnotify -Confirm 123456`; in the window, the
   **Confirm** beside the answer with that code. A push saying
   `paired - Android - Chrome 128` follows.

**Why the code.** The pairing push goes where alerts go, and more than your
phone may read it: Join's servers log it, and an ntfy topic is read by
anyone who has its name. Whoever reads it could answer it first, with a key
of their own. So an answer pairs nothing by itself: it waits, up to five of
them, each with the code of the key it carries, and the phone that is paired
is the one whose code you confirm. An answer whose code your phone does not
show is someone else's. `-Confirm` refuses a code two answers share - pair
again then.

**Pairing again replaces the phone.** Each `-Pair` makes a new reply topic
and drops the old phone's key at once, so the phone paired before - or
whoever held its key - stops working, and so does every link already out
there. A phone that is already paired says so before it pairs again: only
continue if you just pressed Pair phone on your PC, and it shows where
replies would go. The pairing needs a way to the phone that carries a link -
Join, or ntfy on an https server - and is refused, with nothing changed,
without one.

### Chats you run yourself

Only prompts queued with `chatq` went through the watcher, so they were all
that alerted: a chat you run straight in VS Code, or a terminal's `claude`,
never reached the phone. Now it does, from [the overlay](#the-overlay),
which reads every open chat's state on each pass anyway:
- `needs input` (priority 2) once a chat has waited on you for 20 seconds -
  a prompt answered at once never alerts - saying what it waits for, where
  that is known, and its folder;
- `done` (priority 1) when a chat finishes a turn, with the end of its reply;
  one the limit cut off says so, and - with [auto-continue](#auto-continue)
  on - what it does about it (`· never auto`); when it queued a continue,
  the alert is `limited` (priority 0) about that job instead: `stopped by
  the usage limit · auto-continues 13:01`, with **Don't continue** on the
  page. An `-Events` list without `limited` drops that one.

**Only while you are away:** no keyboard or mouse for `quietMinutes`. While
you are at the PC nothing is sent at all, not even the toast - the overlay
shows it. Once you are away they go whichever window is in front, the
chat's own VS Code window included. A `done` that finished while you were
still at the PC is not news by then, and is dropped; one that finished after
you left goes as soon as you count as away. With `quietMinutes` 0 you never
count as away, so none go.

**Never** about a chat chatq itself is running a prompt in (that one alerts
through the watcher), a side chat, or twice for one chat and event within 3
minutes. An overlay that has just started sends nothing about chats already
waiting. `-Events` filters these as it filters the rest, and each carries a
reply link: **Send** queues the text for that chat, and it goes in once the
chat is idle - while the chat still waits on a prompt at the PC, the push
says it goes once that is answered there.

**The overlay has to be running** - on Windows it starts by itself - and
only the Windows overlay sends them; there are none on macOS or Linux. The
overlay loads its code once, as it starts: one started before an update
runs the old code, which may have none of this, and `chatnotify` says
`the overlay runs an older copy`. `chatoverlay -Stop`, then `chatoverlay`.
The alert is written to `data/outbox/` and a hidden process sends it, so the
panel waits on no network; `data/logs/outbox.log` says what became of each,
and one not sent within 30 minutes is dropped.
`chatnotify -LiveAlerts off`, or **Chats I run myself, when I'm away** in
the window, keeps the phone to what chatq runs.

### Usage heads-ups

Three alerts under one event, `chatq · usage`:

| kind | when | says |
|---|---|---|
| threshold | a 5-hour or weekly window, Claude's or Codex's, reaches `-UsageAt` (90%) | `Claude 5h at 91% · resets 13:00 · 3 queued` |
| soon | a limit resets in 10 minutes with prompts queued in it | `Claude resets 13:00 · 3 queued · they go then` - with **Send now** |
| reset | a limit reset with two or more prompts queued | `Claude limit reset · 3 queued · sending #12 now` |

- **Threshold** comes from [the overlay](#the-overlay), which already asks
  for the usage every few minutes - so Windows, with the overlay running;
  `chatnotify` says when it is not. Up to three thresholds (`-UsageAt 75,
  90`); at 95% with both new, one alert says 95%. A figure that is stale,
  over 30 minutes old, or of a window already limited never alerts.
- **Soon** and **reset** come from the watcher, on every OS. Soon goes only
  for a wait that was 30 minutes or more: the 15 minutes the watcher
  guesses when a check gives no reset time is not a reset. **Send now** on
  its page is `chatqrun -Now` from the phone: the watcher forgets its waits
  and checks the limit first, so nothing is typed into a chat while the
  limit still holds, and a chat busy at the PC is still left alone. It
  queues nothing and picks no mode.
- Each alert goes once - recorded in `data/usage-alerts.json` before it is
  sent. Like every alert, at the PC it is the toast; away, the phone.
- A `phoneEvents` list gets them only once `usage` is in it (`-Events`, or
  the window's **usage** box). `-UsageAlerts off` stops the thresholds,
  `-UsageReset off` the other two.

### Quiet hours

```powershell
chatnotify -QuietHours 00:00-07:00                  # this PC's clock
chatnotify -Urgent failed, 'needs input'            # what still comes through; none for nothing
chatnotify -QuietHours off                          # what was held goes now
```

In the window the phone's alerts are **held**, not dropped. `failed` still
comes through - a refused login or an unreachable service holds every
queued prompt all night - and whatever `-Urgent` names. When the window
ends, one `chatq · summary` push lists what was held,
`held 00:00-07:00: 2 done, 1 needs input`, then a line each; the next
alert, the watcher or the overlay sends it, whichever comes first, and one
that does not go is tried again. The toast and `alerts.log` go on as ever,
and your command runs with `$env:CHATQ_QUIET` = `1`, so a Pushover or
Telegram command can hold itself. Tests, replies and the pairing push
always go, and so does a
[permission request](#approve-a-tool-call-from-the-phone): a run waits on
it, and a held one could only run out. The summary answers no particular job - **Status** lists them,
and `chatqrun <n>` works at the PC.

### Read aloud

`chatnotify -Say 'needs input', failed` has Join speak a short line on the
phone for those events - `Parser rewrite needs input`, not the alert's
text; in Korean, `<title> 입력을 기다립니다`, for a chat with a Hangul title
(`-SayLanguage auto`, the default; `en`, `ko` or another language code force
one). It is off until you name events, because Join speaks through the
phone's speaker as well as headphones. Never in quiet hours, and never for
a reply, the pairing push or the summary; ntfy has no speech. `-Say test`
and `-Test` try it.

### Reply from Tasker

An alert's link takes one more thing, `&text=` with the words URL-encoded.
The page puts them in the box, says **Filled in from outside the page -
check it, then Send.**, and waits. **Send is still a tap in the browser, on
purpose:** a link that sent by itself could be opened by anything - another
app, a web page, a restored tab - and would send with your phone's key.
Only alerts that take a prompt use it: not a test, a usage alert or the
summary. The text is in the page's address until the page takes it out, at
once, and in whatever Tasker keeps; a browser may keep the address in its
history, so treat it like anything typed into the browser.

A Tasker profile turns that into a reply typed outside the browser.
**First check what was not confirmed:** that Join's own *Push Received*
event fires for chatq's pushes and names the link `%joinurl`.

1. **Check Join's event.** Profile → Event → Plugin → Join → *Push
   Received*; task: Flash `%jointitle | %joinurl`. Then `chatnotify -Test`
   with the phone away from the PC: the flash shows
   `chatq · test | https://…/reply.html#v=2&a=…`. If the variable list (the
   tag icon in the task) names the URL differently, use that name below. If
   the event never fires for chatq's pushes, stop here.
2. **Filter.** In that event, set Title to `chatq ·*`. In the entry task:
   Variable Set `%ChatqLink` to `%joinurl`, `%ChatqTitle` to `%jointitle`.

**Route B, Tasker alone:** then, in the same task,
- Input Dialog, title `%ChatqTitle` → `%input`;
- Variable Convert `%input` → *URL Encode*, into `%ChatqText`;
- Browse URL `%ChatqLink&text=%ChatqText`.

**Route A, a reply field in the notification (AutoNotification):**
3. AutoNotification → Notify: Title `%ChatqTitle`, Text `%jointext`, a
   *Reply* action with the command `chatqreply`, Id `chatq`. Join's own
   notification stays too; AutoNotification Cancel (app Join, title
   `chatq ·*`) drops it if you want one.
4. Profile → Event → Plugin → AutoNotification, Command filter
   `chatqreply`. Check with a Flash which variable holds what was typed
   (`%anreply` is the likely name).
5. Entry task: Variable Convert it → *URL Encode*, into `%ChatqText`, then
   Browse URL `%ChatqLink&text=%ChatqText`.

The link already ends inside its `#` part, so `&text=` joins it, and
nothing after `#` reaches any server. The page opens with the text in the
box: check it, tap **Send**. The phone's key stays in the page; Tasker
never sees it.

### What passes through whose servers

| | what it sees |
|---|---|
| Join | the alert's text, as before, and its link: the page's address, an alert id, the event, the job's number, the first 20 characters of the chat's title, which tool and the job's state. No key: without the phone's own, none of it answers an alert. Join's push is a GET, so its server logs have all of that. The pairing push carries more - the reply topic, a public key made for that pairing, and the PC's name - and still nothing that answers an alert |
| Join, read aloud | for the events you chose (`-Say`), a spoken line as well: the chat's title and what happened - shorter than the alert's text, which Join sees anyway |
| ntfy.sh | the reply topic, and what the phone posts to it: sealed, so ntfy.sh sees when a reply came and how long it is, never what it says. With ntfy as your alert channel too, its alert topic carries the alert text and the link, as Join does |
| a permission request | Join, and an ntfy alert topic, get the chat's title, the kind of call (`asks to run a command`) and a card sealed for the phone: the command, Claude's description of it and the digest it must be answered with, AES-256 under an HMAC with keys from the phone's key and the alert's id - the other direction's own keys. Neither can read or change it. The answer goes back sealed through the reply topic, as every reply does |
| ntfy.sh, the down topic | what the PC sends the phone - [whole answers](#the-whole-answer), [boards](#the-board-any-chat-from-the-phone), acks: when each went and how long it is once compressed, never a title, folder, prompt or answer. A long answer's sealed file for 3 hours. Neither topic's name is in any push, and nothing but timing ties the two together. Join sees two more fields in each alert's link, `f=1` and `o=<time>` |
| GitHub Pages | only that the page was loaded. It is one static file that loads nothing else and posts only to the reply topic; the part of the link after `#`, which says which alert, never leaves the phone. The phone keeps its key in the browser, in IndexedDB, as a key that will not export - in `localStorage` only where there is no IndexedDB, and the page says so |

**The page's site is shared.** A browser keeps the key per site, and every
`<user>.github.io` project page is one site: a script on another of that
account's pages, opened in the same browser, could use the key - not copy
it, but post replies with it. `chatnotify -ReplyPage <https URL>` serves
the page from a copy on a site of its own, a custom domain or a
`<name>.github.io` of its own. A phone paired on the old site has no key on
the new one, so pair it again there.

Since 0.9.0 the same goes for reading: such a script could use the key to
ask for the board or an answer, and read what comes back, as the page
does. `-ReplyPage` is still the fix; `-Compose off` takes the board out of
it, and `-FullText off` the whole answers.

## The overlay

```powershell
chatoverlay                 # start it (or show it again)
chatoverlay -Stop
chatoverlay -AutoStart off  # not with every shell and VS Code window (on Windows it is)
chatoverlay -Print          # the same, once, in this console
```

![The overlay: a usage line for Claude - five-hour window at 100% in red, weekly at 46% - and one for Copilot's chat and code quotas, each ending with the time of its figure; then four chats with their newest prompt beneath - one amber and waiting on input, one green and working, each carrying a queued prompt, one idle, and a purple queued prompt for a chat that is not open](docs/demo-overlay.png)

A small panel in the top-right corner that stays above other windows:

- **Usage at the top, live.** A line each for Claude, Codex and Copilot, as the
  collapsed panel has it: `Claude  5h 41% · week 74% · Fable week 2%   22:22`.
  Claude's five-hour and weekly windows, and one model's weekly window once it
  is used; Codex's weekly (and five-hour, on a paid plan); Copilot's monthly
  chat and code quotas, or premium requests on a paid plan. A percent turns
  amber or red as Claude's own usage view would colour it, and each line ends
  with when its figure is from. The window you wait on says when it
  resets - `5h 100% resets 13:00` - the latest reset of those at their
  limit, in red, else the 5 h window's; the time goes once it passes, and
  a narrow panel wraps the line rather than hiding a window. The settings
  box switches to **bars** - a bar and a reset countdown per window, the
  same few words under each name - and back.
- **Every open Claude chat:** project, title and newest prompt, with a dot for
  what it is doing. Amber is waiting on you (a permission prompt, say) and goes
  to the top; green is working; grey is idle. A chat open in two windows is one
  row. A slash command counts as the newest thing sent. Claude Code writes
  `/compact` down only once it ends, so while it runs the row says a command
  is running rather than showing the prompt before it. After the dot, a
  small mark says where the chat runs: a window outline for a VS Code
  panel, `>_` for a terminal's `claude`.
- **A blue dot for a turn you have not seen,** on Windows only. A chat
  that went from working or waiting to idle while you were elsewhere gets
  a small blue dot just before its state, and the collapsed line and the
  tray dot's tooltip count them (`2 new`). A chat whose window was in
  front as it finished gets none: any window of its VS Code counts, or for
  a terminal's `claude` any tab of the terminal that draws it. A console
  Windows handed off to Windows Terminal (its default-terminal setting)
  cannot be matched, so that chat gets the dot even with its tab in front.
  The chip clears the dot once its open sent the window its request -
  `ended 0`, `25`, `40` or `41` in `overlay.log`; a chat turned away (one
  at work, `10`, a terminal's, or one a queued prompt is running in), an
  open that failed before the request, or one with no answer in 60
  seconds leaves it. A new turn, or its session ending, clears it too. The
  overlay keeps it in memory only, so a restart clears every dot, and
  reading the chat in VS Code clears none.
- **Chats the limit cut off,** in orange, just under those waiting on you:
  `cut off - resets 13:00`, or `529 - waits for Claude`. One no window has
  open gets a row of its own: from the transcripts of the last week while
  its reset is ahead or under 12 hours ago, or while the cut-off is under
  12 hours old. A continue you queued for it takes the row's place. The
  console's Continue, or `chatq <title> -Continue`, queues one. With
  [auto-continue](#auto-continue) on, the row says what it does with the
  chat, in few words - `#12 auto 13:01` (a continue queued, and when it
  goes: that continue stays on the orange row), `resets 13:00 · never`,
  `· terminal`, `· skipped` (its continue taken back, or left at the
  ask), `· failed`, `· stopped`, `· by hand` (too old, or a reset days
  out) - the same in full in the words' tooltip, the chip's, the console
  and `chatoverlay -Print`. Every title starts at one column: a row with no
  where mark keeps its place empty.
- **The ask, once the limit is over:** a banner at the foot of the header,
  `limit over at 13:00 · 3 chats it cut off can continue`, with a dot in
  the cut-off orange. Rest on it for its chip - **continue 3** or **leave
  them** - which comes and arms as the open chip does; its tooltip lists
  the chats, and those left to a terminal. Which chats, and what an
  answer writes: [When the limit is over](#when-the-limit-is-over).
- **The queue.** A queued prompt rides on its chat's row (`#3 sends 13:01`), or
  has a purple row of its own when that chat is not open; blue while it runs.
  Prompts queued with no watcher running are called out. One parked on input
  turns its row amber - until you go on in that chat yourself, which answers
  it ([Needs input](#when-it-sends)).
- **Recent,** under all of those, faint: the newest Claude chats not open,
  one line each - project, title, how long ago - five by default. Each
  opens as a tab from its chip, as an open row does. A side transcript, an
  empty one, and a chat whose folder is gone are never listed - a folder
  is looked for again every 3 minutes, and one on a network share or a
  mapped drive is never looked for, so it is listed - and lines the screen
  cannot hold are left off. The list is built again at most once
  a minute, and at once when a chat closes. `chatoverlay -Print` lists them
  too, under the rows, and puts `>_` before a terminal's chat.

**It starts by itself** on Windows: with every new shell, as the watcher
comes back after a reboot, and when a VS Code window starts - the extension
starts it as the window opens, or on a first install the moment it has
copied the scripts, without waiting on its setup's profile question. One
already running is left alone.
`chatoverlay -AutoStart off` keeps it to when you start it, and so does
**Chat Manager: Overlay: start by itself...** in VS Code's command palette
(On or Off; Off also closes a running overlay), with no terminal needed.
Both set `overlay.autoStart` in `data/config.json`. On macOS it starts that
way only after `chatoverlay -AutoStart on`.

**It stays out of the way.** As a panel it never takes focus, and clicks go
through it; only while it is the console (below) does it take the keyboard.
Rest the pointer on it for a moment and a row of buttons appears on its top
edge, outside the panel, flush with its top-right corner - or under the
panel when it sits too near the top of the screen for them. They keep that
side only while they are up, so a panel dragged down from the top has them
on its top edge again the next time they come. Resting on that
spot itself does it too, so you can point straight at the buttons. A pointer
just passing over on its way to the window underneath brings up nothing. Left to
right, with × at the corner as on any window:
- **the grip** (six dots): hold it and drag to move the panel;
- **resize** (a two-way diagonal arrow): hold it and drag - left to widen,
  right to narrow, down for a row more for each row's height, up for one
  fewer. Down never leaves fewer rows than were set, even with fewer chats
  open. The panel's right edge stays where it is, under the buttons.
  Collapsed, only the width changes. The size is kept in `config.json` as
  you let go, and the panel's place in `overlay-state.json`;
- **collapse** (a chevron): folds the panel to one line - how many chats wait,
  work or sit idle, and Claude's usage - and back;
- **refresh** (a circular arrow): asks Claude and Copilot for usage now. It
  turns while it asks, and the end of Claude's line reads `asking...`, then
  `checked 22:22:01` - or why it did not ask. Codex has nothing to ask: its
  figure is what Codex wrote on its last run (`last run Mar 13`), so it moves
  only when Codex runs;
- **console** (a speech bubble): turns the panel into
  [the console](#the-console), in its place; Esc brings the panel back;
- **settings** (two sliders): a box of seven rows - opacity on a slider;
  **Width** (260-800) and **Rows** (1-30) side by side on sliders; the
  theme as Dark, Light or System (System follows Windows' own light or dark
  mode); usage as Lines or Bars; **Style**, full or compact rows;
  **Recent**, off, 5 or 10; and **Cut off**, Continue, Ask or Leave -
  whether the chats the limit cut off are [continued by
  themselves](#auto-continue), [asked about](#when-the-limit-is-over) once
  it is over, or only marked (`autoContinue`). A slider applies as it moves - the width with
  the right edge held, and the panel kept on its screen, growing to the
  right by the screen's left edge - and `config.json` gets it a moment
  after it rests. Opened, the sliders show the size the panel has now,
  whatever changed it;
- **hide to tray** (an arrow onto a line): click the tray dot to show it again;
- **×**: closes the overlay. `chatoverlay` starts it again, and so does
  the next shell or VS Code window unless `-AutoStart off`.

The panel itself never takes a click - until it turns into the console; the
buttons are a small window of their own, and they go when the pointer leaves.

**Open a chat from its row.** Move onto a Claude row, or a Recent line, and
rest the pointer there for a moment - 400 ms, or what
`chatoverlay -ChipDelay` set - and a small **open** appears at the row's
right end - a window of its own like the buttons, taking no focus, in
neither Alt+Tab nor the taskbar. A pointer sweeping across brings up
nothing, it shows once per visit to a row, and a pointer it came up under
has to move off it before a click counts, so a pointer parked there never
opens anything by accident. Clicked, it:
- asks the window that has the chat to open it in an editor tab of its
  own, or to bring forward the tab that already shows it
  ([the extension](#chats-open-in-vs-code-and-the-extension) does it). It
  ends no process. A new tab loads the chat from disk; a tab there already
  comes forward as it is, on the process it has. So a queued run that
  ended while that process lived is not in it yet: click the run's
  **Show it**, or close the tab and open the chat again;
- leaves a chat in the side bar where it is when it is working: nothing
  reaches the side bar's chat, and a tab would start a second process on
  it mid-answer. The window says so; click open again once it finishes. A
  working chat is opened only when exactly one Claude tab here carries its
  label and no other chat of its folder would, since a tab carries no
  session id: one of no title, one whose label another tab shares, and
  one whose title another chat of the folder has - or whose first 24
  characters it has, open or not - are left the same way until one of the
  two is renamed. On a Mac, where the window holding a chat cannot be
  told, so is any working chat with no tab of its own here. A chat idle in
  the side bar does get a tab, a second view with a second process, and
  the window says so and asks you to close the side bar's copy;
- unlocks the editor group holding the chat's tab, when it is the active
  group and holds Claude tabs alone. Claude Code locks the group it makes
  for its tabs (`claudeCode.lockEditorGroups`, on by default), and the next
  file you open would go to another group. A group holding other editors is
  left as it is, and so is every group when `claudeCode.lockEditorGroups`
  is set to `true` in any settings scope - that lock is your choice. Claude
  Code's own **Open in New Tab** still locks the group it starts;
  `"claudeCode.lockEditorGroups": false` in VS Code's settings stops that;
- brings that window forward with `code -n <folder>`: VS Code raises its own
  window on that folder, or opens one, which shows the chat as it starts.
  `-n` keeps it from reusing an unrelated window. `code` is the one beside
  the VS Code that is running, else the one on PATH, else where VS Code's
  installers put it; `CHATQ_CODE` overrides all three. Nothing moves the
  pointer, types or activates a window.

**On a cut-off row** with [auto-continue](#auto-continue) on, the chip has
a second one beside open: **don't continue** while a continue it queued
waits - it removes that continue, and this cut-off is not queued again -
else **continue**, which queues one you asked for. They sit left of the
row's words, which their tooltip also says in full. A click counts only
when it goes down and up on the same chip - the banner's two answers too -
and neither takes a chat's unread dot away. The tray says what was done.

The tray says when it could not: a queued prompt running in that chat (open
it once it finishes), a chat open in a terminal, working or not (never
opened in VS Code as well, or there would be two writers), a window that
also has other folders open (shown there, but not brought forward -
`code -n` would open a second one; which windows are on exactly one
folder is read from their titles, a profile's name after the folder's
allowed for), a chat not started yet, or no `code` command. What you pick
in the settings box is kept in `config.json`, like a setting made with
`chatoverlay`; a collapsed panel stays collapsed across restarts.

**Ctrl+Alt+Shift+O** or the tray dot's menu unlocks the whole panel to drag:
it gets a blue edge, and it locks itself again two minutes after the pointer
leaves. The tray dot takes the colour of the most urgent chat, and its
tooltip counts the chats - those the overlay asks about as `2 can
continue`, apart from the rest `cut off` - and gives Claude's 5 h
percent, with its reset when that is the window you wait on
(`5h 43%, resets 13:00`).
Left-click it to
hide or show the panel; right-click it for Open console, Phone alerts...,
**Auto-continue cut-off chats** (checked while [it](#auto-continue) is on;
unchecked goes back to Ask), Lock, Hide, Collapse,
Refresh usage, Move to top right and Quit - and, at the top while the
overlay asks about the chats the limit cut off, **Continue 3 cut-off
chats** and **Leave them**. Collapsed, the one line says how many cut-off
chats auto-continue will continue: `3 cut off (1 auto)`.
`chatoverlay -Unlock`, `-Lock`, `-Reset`,
`-Collapse`, `-Expand` and `-Refresh` do the same from a shell.

**How live "live" is.** Claude Code caches its usage in `~/.claude.json`, but
only when a window opens its usage view. So that copy can be hours old: on the
machine this was written on it said 55% while the account stood at 79%. The
overlay asks Claude's usage endpoint itself, the same one `/usage` asks:
- every five minutes while any chat is working;
- every fifteen while all are idle, since nothing moves the figure then;
- straight after a window resets;
- when you press refresh, or run `chatoverlay -Refresh`.

The endpoint is meant for a `/usage` opened now and then. Asked once a minute,
it refused after about an hour, and then said to wait 48 minutes. When it
says how long to wait, the overlay waits that long and says so (`13:25, retry
14:13` at the end of Claude's line), refresh or not, since asking early only
earns another refusal. The last live figure and that wait survive a
restart. Meanwhile it shows the newest figure it has: its own last answer, or
Claude Code's cached one, with its age.

It uses the login Claude Code saved. The token is read for that one request and
is never stored, logged or refreshed: a refresh would sign Claude Code out. If
the login has expired, the overlay shows the cached figure with its age until
Claude Code next runs and renews it. `chatoverlay -LiveUsage off` keeps it to
the cache. Codex's figure comes from its newest session file, which it rewrites
every turn.

Copilot's comes from GitHub, through the GitHub CLI: `gh api
copilot_internal/user`, the answer VS Code's own Copilot status shows, every
fifteen minutes and on refresh. `gh` keeps its own login, so the overlay never
sees a token. With no `gh`, or one not logged in (`gh auth login`), there is
simply no Copilot line; `chatoverlay -CopilotUsage off` stops asking. That
endpoint is GitHub's own, not a documented one, so it may change under it.

**What it costs.** One hidden `powershell.exe`, about 160 MB and under 0.1% CPU.
It reads a file again only once that file has changed, and a transcript only from
where it last stopped. The first look at a 20 MB chat reads the last 256 KB.

Settings live in `data/config.json` under `overlay`. `chatoverlay -Theme`,
`-Opacity`, `-Width`, `-Rows`, `-Compact`, `-ChipDelay`, `-Recent`,
`-UsageView`, `-Hotkey`, `-ConsoleHotkey`, `-AutoStart`, `-LiveUsage` and
`-CopilotUsage` set theirs and apply them at once; after editing the file
by hand, `chatoverlay -Stop` and start it again. `-Width`, `-Rows`,
`-ChipDelay` and `-Recent` refuse a value out of range and save nothing
from that line, as `-Opacity` does; one out of range in the file is held
to the range.

One setting the overlay reads sits at the top of `data/config.json`, not
under `overlay`, like `liveIdle`: `autoContinue`, `"ask"` (the default),
`"on"` or `"off"` - whether, once the limit is over, the overlay asks to
continue the chats it cut off ([When the limit is over](#when-the-limit-is-over)),
chatq continues each by itself ([Auto-continue](#auto-continue)), or they
are only marked. The settings box's **Cut off** row or
`chatq -AutoContinue ask|on|off` sets it and tells a running overlay.
`false` reads as `"off"`; anything else, `true` included, as `"ask"`: only
the word `"on"` turns the automatic mode on.

```powershell
chatoverlay -Width 460 -Rows 12   # wider, and up to 12 chats before "+N more"
chatoverlay -Compact on           # one line a chat, no prompt under it
chatoverlay -ChipDelay 250        # the open chip after a 250 ms rest
chatoverlay -Recent 10            # ten chats not open under the rest; 0 for none
```

| key | default | |
|---|---|---|
| `width` | 380 | pixels at 100% scaling, 260–800; the resize handle, the settings box, or `chatoverlay -Width 460`. The right edge stays put |
| `maxRows` | 8 | 1–30; the rest become `+3 more · 2 idle`, and so do the rows that would run past the screen's bottom from wherever the panel sits. The resize handle, the settings box, or `chatoverlay -Rows 12` |
| `opacity` | 0.94 | 0.3–1; the settings box's slider, or `chatoverlay -Opacity 85` |
| `theme` | `dark` | `light`, or `system` to follow the OS; `chatoverlay -Theme system` |
| `prompts` | `true` | `false` hides the prompt lines - compact rows, one line a chat, and good for screen sharing; the settings box's Style, or `chatoverlay -Compact on` |
| `chipDelayMs` | 400 | 100–3000; how long the pointer rests on a row before its open chip comes; `chatoverlay -ChipDelay 250` |
| `recent` | 5 | 0–20; how many chats not open the Recent list shows, 0 for none; the settings box (off, 5, 10), or `chatoverlay -Recent 10` |
| `hotkey` | `Ctrl+Alt+Shift+O` | `chatoverlay -Hotkey Ctrl+Win+F9`; `none` for no key |
| `consoleHotkey` | `Ctrl+Alt+Shift+Q` | opens the console, or brings it forward when another window covers it; again while it is in front, the panel; `chatoverlay -ConsoleHotkey none` for no key |
| `cutOff` | `true` | `false`: no cut-off rows; the scan for them still runs while `autoContinue` asks, or auto-continue is on for anything, and stops with all off |
| `autoStart` | `true` on Windows, `false` on macOS | with every new shell and VS Code window; `chatoverlay -AutoStart off`, or **Chat Manager: Overlay: start by itself...** in VS Code's command palette |
| `usageView` | `lines` | `bars` for a bar and reset countdown per window; the settings box, or `chatoverlay -UsageView bars` |
| `liveUsage` | `true`, `false` on macOS | `chatoverlay -LiveUsage off` |
| `copilotUsage` | `true` | `chatoverlay -CopilotUsage off`: no Copilot line, and `gh` never run for it |
| `usageSeconds` | 300 | how often usage is asked while a chat works (three times that while idle, and for Copilot); 60 at least |

- **Only Claude chats get live rows.** Codex and Copilot write nothing that says a
  chat is open or working, so theirs show only as queued prompts.
- **A game in exclusive full screen** draws over it, as it does over anything.
- **macOS** (untested): a floating panel and a `CQ` menu bar item, with no
  hotkey, no buttons beside the panel and no collapsed view; the menu has
  Unlock, Hide, Move, **Auto-continue cut-off chats** and Quit - and, at
  its top while the overlay asks
  about the chats the limit cut off, **Continue N cut-off chats** and
  **Leave them**, with a notification once per ask; a cut-off row says what
  auto-continue does with it - and `-Theme`, `-Opacity`, `-Rows`,
  `-Compact` and `-Refresh` apply there too; `-Width` from its next start.
  A terminal's chat has `>_` before its title; there is no Recent list,
  no open chip and no unread dot. Live usage
  reads the login from the keychain there, and the first read by another
  program asks for your password, so it stays off until
  `chatoverlay -LiveUsage on`.
- **Linux:** `chatoverlay -Print`.

## The console

`chatconsole` - or the speech bubble on the overlay's buttons, **Open console**
in the tray menu, or **Ctrl+Alt+Shift+Q** - turns the overlay's panel into
chatq's console, in the panel's own place: it grows from the panel's top-right
corner, its right edge and top where the panel's were, to the size it was last
left - 980 x 680 the first time - and stays on the panel's screen. It is the
overlay's own window, so `chatconsole` starts the overlay if that is not
running. While it is the console it is an ordinary window: it takes the
keyboard, has a taskbar button and a place in Alt+Tab, and is not kept on top,
so other windows can cover it and files can be dragged in from Explorer. Its
header moves it - press anywhere on it but its controls and drag - and the
grip at its bottom-right corner resizes it. The header has the panel's
**Opacity** and **Theme** too: they are the same settings as the panel's box,
so the console opens at the panel's opacity and look, and a change made in
either is the other's. The overlay's buttons and the open chip stay away
meanwhile.

**Back to the panel:** **Esc**, **← Panel** at the header's right, the console
hotkey again while the console is in front, or Alt+F4. The panel comes back
exactly where it was, as wide, with its rows and its fold - to the tray, if it
was hidden there - and what you were writing is kept for next time. On a
console another window covers, the console hotkey brings it forward instead.
The tray's item and `chatconsole` only ever bring it forward, never back to
the panel: a command from a shell can arrive a couple of seconds late. Hide,
collapse, lock, unlock, Move to top right and Quit go back to the panel first,
then do what they say; the panel's own hotkey (Ctrl+Alt+Shift+O) only goes
back. While the folder picker is open over the console, or its header is being
dragged, those wait until it is closed or let go.

**On the left, the chats**, with a search over titles and projects, each drawn
as the panel draws its rows - the state's dot, where it runs, project and
title, what it is doing, the unread dot - on one line, the one picked with an
accent bar at its left:
- **Cut off** - the chats the limit or a 529 stopped, each with **Continue**,
  and **Continue all** for every one of them. While the overlay asks about
  them, the header says so - `Cut off (4) · limit over at 13:00 - 3 can
  continue` - and **Leave them** sits beside **Continue all**. Continue
  there answers the ask for the chats that got a job, so the banner and
  the tray's items go. With [auto-continue](#auto-continue) on, the header
  counts those it will continue (`Cut off (3) · 1 auto-continues`), and
  each of those has **Don't continue** instead - one click, since Continue
  undoes it; the same in the queue, where such a job reads
  `auto-continues 13:01` and its detail says when the limit cut the chat
  off;
- **Open in VS Code** - what the overlay's rows show, with what each is doing;
- **Recent** - the 30 newest Claude and Codex chats from the index, faint as
  in the panel's Recent;
- **+ New chat** - a Claude chat that does not exist yet, in a folder you pick
  (Browse, a recent one, or drop the folder on the box), under a name you give
  it or the prompt's first line.

**On the right, the prompt.** The line above it says which chat it goes to,
in which mode that chat last ran, and in which folder; under it, for a
Claude chat, **Auto-continue after a limit** - **Default (ask)** (or on, or
off, as the switch is), **Always** or **Never** - that chat's own
[auto-continue](#auto-continue) setting, Never also removing a continue
it queued. Type, or paste
anything; **drop files** on the box, or **paste a screenshot** or files copied
in Explorer with **Ctrl+V** - each becomes a chip you can × out, copied into
`data/console/draft/` straight away, so the original can move. Then:
- **When** - **Now** puts it at the front and sends it within seconds; **In
  turn** behind what is queued; **At** 13:00 or **In** 2h.
- **Mode** and **Model** - as the chat last ran, or one of chatq's modes and
  opus, sonnet, haiku for this one prompt. The line under them says what the
  mode means with nobody there to answer.
- A line saying what **Send** will do - within seconds; after the limit resets
  at 13:00; once that chat is idle, if it is working in VS Code (looked at
  every 30 s); that the VS Code window shows the reply once it is shown
  fresh.
- **Send now** or **Queue**, or **Ctrl+Enter**.

Send makes the same job `chatq` makes, and the watcher runs it the same way:
in the background with `claude -p --resume`, into the chat's own history. A
chat open in VS Code shows the reply once that window shows it fresh - the
extension does it, or offers it. A **new chat** runs `claude -p --session-id <id> --name <name>` in
its folder: the id is chosen when it is queued, so a retry after a limit
continues that same chat and never starts a second one. VS Code's chat
list never shows a chat `claude -p` started (**Chats Claude Code hides**,
in the next section), so a window on that folder is only told it started:
the console's **Write to this chat**, or `claude --resume <id>` in a
terminal, reaches it, and the overlay's open chip offers the terminal.
Until its first run has made it, the console says so rather than sending
to it.

**Below, the queue** - the jobs still to go and those that ended in the last
day, each saying where it stands (`sends 13:01`, `running since 12:04`,
`needs you - Edit denied`, `done 12:10`). Pick one for its outcome, the reply,
its last states, and what can be done to it now:
- waiting - **Try now** (stop waiting for a reset), **First**, **Remove**
  (twice, to be sure), and its prompt, editable until it sends;
- running - **Cancel**;
- ended - **Requeue** (as "continue" if its prompt already reached the chat),
  **Remove**, **Log** for everything the run did;
- and **Write to this chat**, to pick its chat for the next prompt.

The console's size, recent folders, and the draft - the chat, the text, the
files, the choices - are kept in `data/console-state.json`, so a restart loses
nothing; where it opens comes from the panel. Windows only for now; on macOS `chatq`, `chatqlist`
and `chatqrm` do the same from a shell.

## Chats open in VS Code, and the extension

The panel shows one chat, but each VS Code window keeps a `claude` process alive
for every chat opened in it, and clicking one switches back to that process
rather than re-reading the transcript. The side bar also keeps each chat's
messages in its own page, and picking a chat again from its history shows
that copy - even once the process is gone. So a chat still alive in a window
won't show what chatq ran until the window shows it anew — the run *is* in the
transcript.

- **The chat is busy** (you are typing in it, or Claude's own auto-continue is
  running it): chatq waits, checking every 5 minutes.
- **The chat is idle:** it runs, and asks that window to show the chat fresh
  — or shows it by itself (below). Its old idle process is ended as the
  run finishes when you are away, and otherwise by **Show it**, which the
  window runs by itself for a chat it has open, so the next message starts
  from the transcript on disk. With
  `"liveIdle": "stop"` in `data/config.json` it is ended before the run
  instead.

Nothing outside VS Code can show a chat in a window: the window reload and
the Claude Code extension's own command for opening a chat by its id run
from inside an extension only. **VS Code Chat Manager**, the Marketplace
extension that also installs the scripts ([Install](#install)), is that
extension; `extension/` is its source. It also starts
[the overlay](#the-overlay) as a window opens. Without it the terminal
commands work as ever, and only this part is missing.

It replaces the one that used to be copied into `~/.vscode/extensions/` by
hand, `phal40lax78.chat-manager-reload`. While that one is still installed
the new one leaves every request to it - both would act, and a window would
reload twice - and offers to uninstall it; a window reload finishes the move.

**After a queued run into a chat the window still holds**, the window is
asked to **show that chat fresh**. The request names the chat, so it goes to
the window whose Claude process held it, wherever that window's folder is;
failing that, to the window on the job's folder. The chat opens in an
editor tab of its own, loaded from disk; terminals, editors, other chats and
other extensions keep running. If the chat already has a tab, that tab only
comes forward with the old view, so it is closed and opened again - only
when it is certainly that chat's tab: the one that came forward, labelled
with the chat's title, or with the title as Claude shortens it on a tab
(the first 24 characters and `…` once it is over 25). A chat with no title
is never certain, since every such tab reads "Claude Code", and neither is
a label another Claude tab shares, or another chat of the folder would
carry, open or not - two chats whose titles begin alike - since closing the
wrong tab would cut off the other chat. If it is not
certain, you are told to close the tab yourself. Where the window had the
chat outside its tabs - in the side bar - it says that copy is stale now
and can be closed. The tab's group is unlocked as the chip's is.

**It shows the chat by itself** while the run's word on it is at most 20
seconds old, in two cases:
- **The chat is open here on an idle process** — its tab, or the side bar:
  the window does **Show it** (below) as if you had clicked it, at the PC or
  not, and whatever other chats do, since it touches that chat alone. Left
  stale, the tab would fork the chat: a message typed into it goes on from
  the tab's own memory, and the run's turn stays on a branch that tab never
  shows.
- **You are away** — nobody has used the PC for `quietMinutes` (5, the same
  clock that decides whether the phone gets an alert) — and the window is on
  exactly that folder. A chat nothing holds by then opens in a tab, whatever
  other chats do; where only a reload shows it, it reloads only while no
  other chat in the folder is working or was written in that time.

So you come back to a window that already shows the run. It asks instead:
- at the PC, for a chat no process here holds — you may be typing in that
  very window; an idle clock that cannot be read, or `quietMinutes` 0,
  counts as at the PC;
- in a window with more than one folder, or opened on a parent folder — only
  the chat's own folder was judged;
- before a reload, after a chat in the folder was written in the last
  `quietMinutes` — someone may be driving it from the phone, which the idle
  clock never sees.

Asking, it offers **Show it**. The click checks the chats again, right then,
and ends the chat's old idle process; a line in the status bar says so while
it runs. Then the chat opens in a tab of its own. Where the old process could
not be ended, only a reload shows the run, and it offers **Reload**. If the
chat itself was still working as the run ended, or the check finds it or
another chat in the folder working, it warns instead, with **Reload
anyway** for once that finishes. The warning says which: the chat itself
still working, or another chat in the workspace that a reload now would
cut off. If another queued prompt is going into the chat by the time you
click, it leaves it alone and says so; that run's own Show it comes when it
ends.

**Never ended:** only a VS Code window's `claude` is ever ended - its entry in
`~/.claude/sessions/` says `claude-vscode` and its parent process is
`Code.exe` - and never one busy, waiting, or with a workflow or background
agent in flight. Whose that work is comes from the transcript, where every
record names its writer: a workflow the window's own chat started holds it,
even one started while a queued run went on; one a finished queued run
(`claude -p`) left behind died with that run and holds nothing. A chat a
terminal's `claude` holds is not shown in VS Code at all, since that would
make two writers; the alert and the window say to type in the terminal. Nor
is one a queued prompt or any `claude -p` is going into right now. Ending a
process ends the background shells it runs too - a dev server a chat started
goes with it.

**Never beside a run:** after a request to show a chat, the next queued run
into it waits 30 seconds while the window shows it. And a window that opened
the chat while a run went into it - loaded part way through - gets the same
Show it after the run as one that held it from before.

`chatManager.showFresh: false`, or no Claude Code extension, brings back
0.5.0's window reload. `chatManager.autoReloadAfterRun: false` makes it
always ask. A window opened after the run already shows it, and neither asks
nor acts. The overlay's [open chip](#the-overlay) asks through a file of its
own, `data/open-request`, and never falls back to a reload, whatever
`showFresh` says: it gets a tab, or the tab already showing the chat, and
nothing for a chat working outside the tabs; with no Claude Code extension
the window says it cannot open the chat there. A command the extension
runs for any of these - an open, a tab closed, a reload - is given 15
seconds; one that never answers is logged under **Chat Manager: Show log**
and taken as failed, and the next show still runs.

**Chats Claude Code hides.** Claude Code leaves a chat out of its session
lists - the side bar's history, and `claude --resume`'s - when it takes it
for one an SDK started: when the first `entrypoint` in its transcript's
first 64 KB, or with none there the last one in its last 64 KB, is
`sdk-cli`, `sdk-ts` or `sdk-py`. Nor will it open such a chat in a tab:
asked to, it starts a blank chat. chatq's runs are `claude -p`, which
stamps `sdk-cli`, so a chat whose first prompt was a pasted screenshot -
64 KB with no entrypoint in it - fell out of the list after one queued
prompt or phone reply. It is mended as the run ends, and again as the
chip, **Open chat...** or **Show it** opens it: one line goes at its end,
`{"type":"chatq-listed","entrypoint":"claude-vscode","sessionId":...}`, a
type Claude Code's loaders pass over, as Claude Code's own rename adds a
line there. The file keeps its write time. Not while a process is busy or
waiting in the chat, as its entry in `~/.claude/sessions/` says; nor where
the line cannot be written. Either way the window says so rather than open
a blank tab. A chat hidden before 0.8.1, or by a watcher that died
mid-run, and neither run into nor opened since: `chatclean` lists it
again, and every other such Claude chat with it. A chat whose first
records say an SDK started it - every one **+ New chat** made, or your
own `claude -p` - can never be listed; instead of a blank tab, the window
offers it in a terminal, `claude --resume <id>`, once it checks nothing
else runs the chat by then.

**Chat Manager: Open chat...** in the command palette does what the chip
does, without the overlay. It lists this window's Claude chats - the
transcripts in its folders' project folders under `~/.claude/projects/`
(or `CLAUDE_CONFIG_DIR`), newest first, 200 at most - each by its title as
Claude would give it: a rename, else Claude's own title, else the first
prompt typed. Beside each, how long ago it was written and what runs it,
from `~/.claude/sessions/`: **open** in VS Code, **working**, **in a
terminal**, or **a queued prompt running**; in a window of several
folders, the folder too. Side transcripts and empty ones are left out. The
list comes up at once; titles not read within a quarter of a second show
the chat's id and are filled in as they come, and titles are kept until a
file changes. A `$(` in a title shows as typed, never as an icon. Picked,
what runs the chat is read again, then:
- **in a terminal**: not opened - type there, or close it first;
- **a queued prompt running** - chatq's `claude -p`, or any print-mode
  run: not opened, since a second copy would start mid-run; open it once
  that run finishes;
- **working**: only its one tab here is brought forward. With none - it
  works in another window or the side bar - it is not opened, since a
  second copy would start mid-answer; open it once it finishes;
- **open** and idle, with its one tab here: that tab comes forward. With
  none, it is open elsewhere, and a second copy here would answer on its
  own, so it asks first - **Open here too** or **Cancel**;
- **closed**: a new tab, loaded from disk.

Its one tab here is one Claude tab of its label, as for the chip, and only
while no other chat of its folder would carry that label - the same title,
or the same first 24 characters, open or not. Otherwise that tab may be the
other chat's, so the chat counts as having no tab here: working, it is
refused; idle, it asks. Renaming one of the two tells them apart. The
chats looked at are the newest 200 of each of the window's folders and of
the chat's own, and a look not done in 1.5 seconds counts as shared. What
runs the chat is read once more after **Open here too**, which may sit
unanswered for minutes, and again right before the open, which may wait
behind another show: a chat that began to work, or that a terminal or a
queued prompt took, meanwhile is refused as it would have been at once.
The tab's group is unlocked as the chip's is, and the log says what was
picked and how it ended.

The Claude Code extension also opens a chat from a
`vscode://anthropic.claude-code/open?session=<id>` link, but VS Code asks
before letting an outside program open one - a dialog on every run - so chatq
goes through this extension instead.

**After a delete or an archive in its folder,** *that* window — matched by
its workspace folder — offers a **Reload** button, as before. If a chat in the project was still working when the delete ran
([what counts](#reloading-safely)), it warns instead: *A chat in this workspace
is still working, and reloading now would cut it off*, with **Reload anyway**.
`chatManager.folder` points it elsewhere if the script does not live in
`~/Tools/VS-code-chat-manager`; `chatManager.autoReload` skips the question
after a delete — never while a chat is working, and never after a queued run
or a new chat, which have rules of their own. The old extension's
`chatManagerReload.*` settings are still read where the new ones are unset,
its `signalFile` standing in for the folder.

A new chat a queued run started is only said: the window on its folder names
it, and offers no reload - Claude Code's list leaves out a chat `claude -p`
started, so a reload would cut off what works there and show nothing
(**Chats Claude Code hides**, above).

**Every reload looks at the window's chats first.** The script's word on a
request is of one folder, given as the request went out; a reload ends
every chat of the window, whatever its folder, and one may have begun
since. So right before a reload the window takes by itself - after a delete
with `autoReload`, or after a queued run - and before a plain **Reload**
you click, the window asks the script which of its own chats work (below).
One working, and it says which and asks, with **Reload anyway**. A look
that fails stops a reload the window would take by itself, and lets one you
clicked go ahead. **Reload anyway**, the answer to a warning, is taken as
it is within a minute; clicked later - the warning is no dialog, and can
wait for hours - the window's chats are looked at again, and a chat the
warning did not name that is working by then is asked about first.

**When chatq itself updates.** A new version of the extension runs in a
window only after that window reloads - and a reload ends every `claude`
process the Claude extension started there: a turn in flight, a permission
prompt waiting, a workflow or a background agent, in every Claude tab of
the window, and a Claude session driving other agents loses them all. So the version still running
watches for the new one - VS Code's own event, and its list of installed
extensions (`~/.vscode/extensions/extensions.json`) changing, which also
tells the same version installed again - and says so once per install:

- **Nothing working here:** *VS Code Chat Manager 0.9.0 is installed -
  reload the window to load it*, with **Reload the window** and
  **Later**. The chats are looked at again as you click, since the notice
  may have waited for hours; one working by then gets the question below.
- **Chats working here:** *... Loading it reloads this window, which stops
  the 2 chats working here: "Refactor the parser" and "Nightly build"
  (background work running)*, with **Reload when they're idle**, **Reload
  now** and **Later**.

**Reload when they're idle** puts *Chat Manager: reloads when 2 chats are
idle* in the status bar - a click there cancels it - and looks again every
25 seconds. Once every chat of the window has been idle for a minute
straight, and no queued prompt is going into one of them - a chatq job
running counts even into a chat no process of the window holds any more -
it reads the Claude registry once more, and then reloads the window
(**Developer: Reload Window**), which loads the new version; terminals
survive it. Not **Developer: Restart Extension Host**: that starts the
extensions again from the ones VS Code already had, and a version
installed from the command line never loads through it. A reload that
fails is said, with **Try again**. The wait is kept in memory only: a
window closed meanwhile does nothing. **Later** does nothing, and the same
install is not said again; the next reload loads it. VS Code's own
**Restart Extensions** button, in the Extensions view, asks nothing - it
is VS Code's, not chatq's. If the tool folder's scripts are older than
0.9.0 (a git checkout, say), the chats cannot be looked at: the log and
the status bar say so.

A chat is this window's when its `claude` process runs under this window's
extension host, the process a reload ends - its parents, read from one
Windows process list, lead there - and working when it is busy, waiting on
a prompt, has a workflow or background agent it started still out, has a
queued prompt or any `claude -p` going into it, or had its transcript
written in the last minute: the judgement chatq makes of a folder before
it calls a reload safe ([Reloading safely](#reloading-safely)), made of
one window. A background shell still does not count - it is as often a
server that never ends. Off Windows the parents cannot be read, and every
VS Code chat counts as this window's, other windows' too, so a reload
there waits on them as well.

## Codex

- A thread is found by its name in `~/.codex/session_index.jsonl`, the name the
  panel shows.
- It is resumed with `codex exec resume <id>` in its own folder and sandbox mode.
- `codex exec` never asks for approval, so a Codex job ends done or failed, never
  needs-input.

## Where it looks, and what it writes

| | |
|---|---|
| Claude Code | `~/.claude/projects/<slug>/<uuid>.jsonl` (`CLAUDE_CONFIG_DIR` honoured) |
| Copilot Chat | `<Code user>/workspaceStorage/<hash>/chatSessions/<uuid>.json` |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl` (`CODEX_HOME` honoured) |
| the CLIs | `claude` / `codex` on PATH, else the copy bundled in the VS Code extension; `CHATQ_CLAUDE` / `CHATQ_CODEX` override |
| running chats (overlay) | `~/.claude/sessions/<pid>.json`, the list Claude Code keeps of what runs; the `<pid>.<hash>.key` beside each is never opened |
| usage (overlay) | Claude's usage endpoint, with the login in `~/.claude/.credentials.json` (the keychain on macOS); the `cachedUsageUtilization` block of `~/.claude.json` as the fallback. Copilot's through `gh api copilot_internal/user` - `gh` with its own login (`CHATQ_GH` names another `gh`) |

`<Code user>` is `%APPDATA%/Code/User` on Windows, `~/Library/Application
Support/Code/User` on macOS, `~/.config/Code/User` on Linux.

Everything it writes is in `data/` beside the script — the index, tombstones,
the archive, the queue and its logs, the board, `config.json`,
auto-continue's `auto-continue.json` and the markers in `auto/` that it
and the reset ask share, the
overlay's `overlay.json` and `overlay-state.json`, and the console's
`console-state.json` and the files waiting to go in `console/draft/`, and
the extension's `reload-request` and `open-request`, and the installer's
`download/` while it unpacks. No
registry keys,
no AppData, no scheduled task; the one line in `$PROFILE` is the only thing
outside the folder.

## How it compares

As of September 2026 — corrections welcome.

| | queues during a limit | picks by title | several chats in turn | phone alerts | waits out a 529 | find & delete | Windows |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| **this** | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Claude Code's own auto-continue | the open terminal session, reset within 24 h; a VS Code panel not seen doing it (2.1.283) | – | – | – | – | – | ✓ |
| [claude-code-queue](https://github.com/JCSnap/claude-code-queue) | ✓ | by id | ✓ | – | – | – | ? |
| [claude-auto-resume](https://github.com/terryso/claude-auto-resume) | the last task | – | – | – | – | – | via bash |
| `codex queue` (official) | – | exact name | – | – | – | – | ✓ |
| [claude-chats-delete](https://github.com/ataleckij/claude-chats-delete) | – | – | – | – | – | ✓ | – |
| [ClaudeSessionManager](https://github.com/RudraP272812/ClaudeSessionManager) | – | – | – | – | – | ✓ | ✓ |

## Things to know

- **API keys:** `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `OPENAI_API_KEY` and
  `CODEX_API_KEY` are kept out of the runs, so they use your subscription.
- **Accounts:** a job queued from a shell with `CLAUDE_CONFIG_DIR` or
  `CODEX_HOME` set runs, and is limited, in that account.
- **A limit on one model** (an Opus-only weekly limit) holds up no other model.
- **Plan mode:** a chat last in plan mode only produces a plan; `-Mode auto` lets
  it act.
- **Hooks:** your hooks, guards and `settings.json` allowlist apply to the runs,
  exactly as in the panel.
- **StrictMode** in your profile is fine; the commands turn it off for
  themselves only.
- **Files held open:** transcripts are read `FileShare.ReadWrite | Delete`, since
  Codex holds every rollout open for the life of its window.

## Uninstall

```powershell
chatuninstall        # drop the profile line, stop the watcher and the overlay, keep the folder
chatuninstall -All   # and delete the folder - not while the archive holds a chat
```

Uninstalling the VS Code extension leaves the terminal commands and the tool
folder as they are; these two remove them.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7. macOS and Linux need PowerShell 7, and
  are untested so far.
- The overlay's panel runs in Windows PowerShell, which every Windows has, even
  when started from PowerShell 7: WPF needs it.
- Claude Code 2.1.259 or later for the queue (`--permission-prompts none`).

## Sponsorship

Not set up yet — the badge above is a placeholder. The options being weighed
are in [FUTURE_WORK.md](FUTURE_WORK.md#sponsorship).

## Licence

MIT
