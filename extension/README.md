# VS Code Chat Manager

Find, delete, archive and queue prompts for your local AI chats - Claude Code,
Codex and GitHub Copilot Chat - from PowerShell, and see every running chat at
a glance. This extension installs those PowerShell commands, keeps them up to
date, and does the part only VS Code can: showing a chat up to date after a
queued prompt ran into it.

![The overlay: every open chat with its project, title and newest prompt, and usage live at the top](https://raw.githubusercontent.com/phal40lax78/VS-code-chat-manager/main/docs/demo-overlay.png)

- **Find any chat by part of its title** and Tab-complete it: `chatfind`, `chatrm`, `chatq`.
- **Delete one chat** and everything it leaves on disk, or **archive** it and bring it back later.
- **Queue prompts while the usage limit is hit.** At the reset each chat is resumed in turn, sent its prompt, and run to the end - with VS Code closed, too.
- **Tells you how it went:** a desktop toast, your phone through Join or ntfy, or a command of your own.
- **Shows every running chat at a glance:** `chatoverlay` keeps a small panel above every app, started with VS Code on Windows. Click a chat there to open it as a tab.
- **Open chat...** in the command palette lists this window's Claude chats, newest first, with what runs each - open, working, a terminal, or a queued prompt - and opens the one you pick in a tab. A chat working elsewhere, in a terminal, or taking a queued prompt is never opened a second time. A chat Claude Code's own list hides after a `claude -p` run is listed again first, or offered in a terminal where it cannot be - never opened as a blank chat.
- **After a queued run**, once the chat's old idle process is ended, the window shows it up to date in a tab of its own, with no window reload. Where that process is still running, it offers a reload instead.
- **Phone alerts...** in the command palette opens the window that sets up alerts on your phone through Join - and answering them from the phone, with the phone paired once - with no terminal needed (Windows).

![chatrm after Tab: the whole title filled in, quoted, with its age and match count, beside the chat panel](https://raw.githubusercontent.com/phal40lax78/VS-code-chat-manager/main/docs/demo-2-tab.png)

![chatq queueing a prompt for a chat picked by its title, to be sent when the usage limit resets](https://raw.githubusercontent.com/phal40lax78/VS-code-chat-manager/main/docs/demo-queue.png)

![chatqlist showing two queued prompts, the usage and when the limit resets](https://raw.githubusercontent.com/phal40lax78/VS-code-chat-manager/main/docs/demo-list.png)

## What it does on first start

1. It puts the PowerShell scripts in `~/Tools/VS-code-chat-manager`
   (`chatManager.folder` moves it). Everything the tool writes goes in `data/`
   there - nothing in AppData.
2. It asks once before adding one line to your PowerShell profile, which loads
   the commands in every new terminal. The profile is backed up first.
   **Never** is remembered; **Chat Manager: Install terminal commands** asks
   again whenever you like.
3. If PowerShell's execution policy would stop that line from running, it
   offers to allow local scripts for your user (`RemoteSigned`), and changes
   nothing unless you click.
4. On Windows it starts the overlay as soon as step 1 is done, without
   waiting on step 2's question, and does so with every window after that
   unless it is running already. **Chat Manager: Overlay: start by
   itself...** in the command palette turns that On or Off - Off also
   closes a running overlay - with no terminal needed.
   `chatoverlay -AutoStart off` in a terminal sets the same switch,
   `overlay.autoStart` in `data/config.json`, and leaves a running one
   up.

Updates come through VS Code. A window starts running a new version once
you click **Restart Extensions** or reload. The first to do so replaces
the scripts in the tool folder and moves a running watcher and overlay
onto the new copy. Terminals already open keep the old commands until
they are reopened. A folder that is a git checkout is never written to.
If you installed the extension from a `.vsix` file, it is pinned and never
updates by itself: right-click it in the Extensions view and turn on
**Auto Update**.

Then open a new terminal and type `chat` for the list of commands.

## Requirements

- Windows, with Windows PowerShell 5.1 (every Windows has it) or PowerShell 7.
  macOS and Linux need PowerShell 7 and are untested.
- Claude Code 2.1.259 or later for the queue; the Claude Code extension for
  showing a chat fresh.

## Settings

| setting | |
|---|---|
| `chatManager.folder` | where the scripts and `data/` live; empty means `~/Tools/VS-code-chat-manager` |
| `chatManager.showFresh` | after a queued run, show the chat in a fresh tab of its own instead of reloading the window (on) |
| `chatManager.autoReloadAfterRun` | do that without asking when you are away and nothing else works (on) |
| `chatManager.autoReload` | reload without asking after a delete (off) |

Settings under `chatManagerReload.*`, from the extension this one replaces,
are still read where the new ones are unset.

## Uninstalling

Uninstalling the extension leaves the PowerShell commands working. To remove
them as well, run `chatuninstall` in a terminal (`-All` also deletes the tool
folder and its `data/`).

## More

The full guide - every command, the overlay, the console, alerts, and how a
queued prompt is sent - is in the
[README on GitHub](https://github.com/phal40lax78/VS-code-chat-manager#readme).
