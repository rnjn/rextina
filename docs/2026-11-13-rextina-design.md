# Rextina: agent attention for stock Rex

Date: 2026-11-13
Status: draft, awaiting approval

## Intent

The user uses herdr for three things: a sidebar of machines, sessions and tabs;
a simple indicator that an agent needs attention or has finished; and a server
that a client can attach to from another machine. He wants the same on Rex,
without modifying Rex.

The Rex Mac app already provides the sidebar, an Activity view grouped by
blocked / failed / done / working, stored hosts (`clu`, `fred`, `spode`), and
attaching to a remote server. What is missing is the data that feeds the
indicators, and anything that reaches across hosts. Rextina fills those gaps
and nothing else.

## Goals

1. Coding agents running in a Rex terminal report `working`, `blocked`, `done`
   and `idle`, so Rex's own sidebar, tab headers and Activity view show them.
2. A macOS notification appears when an agent on any stored host becomes
   blocked, finishes, or fails.
3. One action jumps to the agent that most needs attention.

## Non-goals

- A custom sidebar or any other UI. The native sidebar is the sidebar.
- A terminal-mode attach client. The Mac app attaching to a remote server is
  enough.
- A client on Linux. The Linux machine runs a Rex server only; agents on it
  still report status and the Mac is notified.
- Codex and other agents. Claude Code only for now, by the user's decision;
  Codex is a future iteration.
- Herdr's agent CLI (`agent start / prompt / wait`), worktree workspaces,
  session restore, screen-scraping detection.
- Agents running inside herdr or tmux inside a Rex pane. The inner multiplexer
  swallows the status sequence.

## Anti-goals

- Modifying, patching or wrapping the Rex binary or app.
- Notifications noisy enough that they get turned off.
- Overwriting the user's existing agent hooks or `init.lua`.

## Constraints

- Stock Rex only: `init.lua`, `rex do` Lua scripts, the `rex` CLI, and the
  OSC 7501 Program Status Protocol.
- Rex runs Lua 5.1. `rex.on` works only in `rex do` scripts, not in
  `init.lua`. `io.popen` and `os.execute` are disabled; use `rex.exec`.
- A `rex do` script hears events from one server. `rex.server(label)` gives
  calls to another host, not its events.
- Program status can only be set by writing OSC 7501 to the terminal's output.
  There is no API method for it.
- Must work on macOS and Linux for the reporting part; notifications and the
  jump action are Mac-only.

## What was verified (2026-11-13, Rex API revision 7)

- A child process whose stdout is redirected can write OSC 7501 to `/dev/tty`
  and Rex records it. `program_status` returned
  `state=blocked kind=permission app=claude-code msg="Needs approval"`.
- No block in the live session had any status record, and `rex skill status`
  shows no Rex hooks installed for Claude Code or Codex.
- The Mac app action `session.select` takes `session_id` and optional
  `window_id`. `client.host.switch` takes no arguments.

Not verified: whether Claude Code or Codex emit OSC 7501 themselves; whether
`session.select` can show a session on a host other than the one the app is
viewing; whether the sidebar lists all hosts at once. `clu` and `fred` were
unreachable during research.

## Approaches considered

1. **Fill the gaps in the native app.** Agent hooks emit OSC 7501; a Lua
   watcher notifies; a Lua action jumps. Smallest build, uses Rex's own UI,
   improves for free as Rex adds its planned inbox and push notifications.
   Cannot give an all-hosts tree if the native sidebar is one host at a time.
2. **Our own sidebar as a terminal program** over the `rex` CLI. True
   all-hosts view, but duplicates the native sidebar and is several times the
   work.
3. **A terminal attach client** against the block data stream. A new Rex
   client, not a plugin.

Chosen: 1, by the user. Option 2 stays available if the native sidebar proves
to be one host at a time and that turns out to matter. Option 3 is dropped;
he confirmed app-to-server attach is what he meant.

## Design

Three parts, built and verified in this order. Each is useful alone.

### Sketch

How the pieces connect. Boxes with a number are Rextina; the rest is stock
Rex or the agent.

```
 any machine that runs agents (Mac or Linux server)
 ┌──────────────────────────────────────────────────────────┐
 │  Rex terminal block                                      │
 │  ┌────────────────────────────────────────────────────┐  │
 │  │ claude                                             │  │
 │  │   └─ hook fires ──▶ [1] rextina-status blocked ... │  │
 │  │                          │ writes OSC 7501         │  │
 │  │                          ▼                         │  │
 │  │                     the block's tty                │  │
 │  └──────────────────────────┬─────────────────────────┘  │
 │                             ▼                            │
 │  Rex server: stores the status record, emits             │
 │              terminal.program_status_changed             │
 └───────────────┬──────────────────────────┬───────────────┘
                 │ native                   │ events, over the
                 │                          │ host connection
                 ▼                          ▼
 the Mac
 ┌──────────────────────────────────────────────────────────┐
 │  Rex app                      [2] rextina-watch          │
 │  sidebar, tab headers,            ├─ watch.lua  (local)  │
 │  Activity view show the           ├─ watch.lua  (clu)    │
 │  state with no help from us       └─ watch.lua  (fred)   │
 │        ▲                                │                │
 │        │ session.select                 ▼                │
 │  [3] rextina_next action          macOS notification     │
 │      scans local + every host,                           │
 │      picks blocked > error > done                        │
 └──────────────────────────────────────────────────────────┘
```

What the user sees. The sidebar is Rex's own; the exact glyphs are Rex's and
shown here only as placeholders.

```
 Rex sidebar (Activity, by priority)       macOS notification
 ┌───────────────────────────────┐        ┌────────────────────────────────┐
 │ Blocked                       │        │ Claude needs approval          │
 │  ! platform-ops › deploy      │        │ fred › platform-ops › deploy   │
 │ Done                          │        │ Allow: terraform apply         │
 │  ✓ admin-cli › tests          │        └────────────────────────────────┘
 │ Working                       │        ┌────────────────────────────────┐
 │  ◌ marketing › docs           │        │ Claude finished                │
 │ Idle                          │        │ spode › admin-cli › tests      │
 │    store-testbed › shell      │        │ Worked for 4m 12s              │
 └───────────────────────────────┘        └────────────────────────────────┘

 rextina_next, pressed repeatedly:
   platform-ops › deploy (blocked)  ─▶  admin-cli › tests (done)  ─▶  wraps
```

One agent turn, in order:

```
 you send a prompt      UserPromptSubmit ─▶ working    tab shows a spinner
 agent wants approval   Notification     ─▶ blocked    notification + indicator
 you approve, tool runs PostToolUse      ─▶ working
 agent finishes         Stop             ─▶ done       notification if ≥ 30s
 you send a prompt      UserPromptSubmit ─▶ working    done indicator is replaced
 you quit the agent     SessionEnd       ─▶ clear
```

### 1. Status reporter

Revised 2026-11-13 during the build: Claude Code 2.1.311 reports OSC 7501
itself, with no hooks (`working`, `blocked kind=permission` with a message
naming the tool and path, `idle` on interrupt, `done` at the end of a turn).
The hook mapping and installer below were therefore not built. The reporter
script exists and is used by the integration test and by any script that
wants to report status.

`bin/rextina-status STATE [KIND] [MESSAGE]`, a POSIX `sh` script with no
dependencies. It writes one OSC 7501 report with `app=<agent>` to the agent's
terminal: `/dev/tty` first, and if that cannot be opened, the tty of the
parent process. It exits 0 silently when there is no terminal or `REX_BLOCK`
is unset, so hooks never break an agent outside Rex.

Claude Code hook mapping:

| Hook | Report |
|---|---|
| `SessionStart` | `idle` |
| `UserPromptSubmit`, `PostToolUse` | `working` |
| `Notification` (permission prompt) | `blocked kind=permission` |
| `PreToolUse` for a tool that asks the user a question | `blocked kind=question` |
| `Stop` | `done` |
| `SessionEnd` | `clear` |

Claude Code's idle notification, which fires about a minute after a turn
ends, is ignored. The turn already reported `done`, and turning that into
`blocked` would notify twice and outrank real requests.

No Claude Code hook reports `error` in the first version. The watcher and the
action still handle `error`, because any program can report it through
OSC 7501, such as a build script.

This version supports Claude Code only. The reporter takes the agent name as
an argument, so a later iteration can add Codex through `~/.codex/hooks.json`
without changing it.

`PostToolUse`, not `PreToolUse`, returns the state to `working`: Claude Code
runs `PreToolUse` before it asks for permission, so only `PostToolUse` marks
the approval as given.

`bin/rextina-hooks install|uninstall` installs the hooks into
`~/.claude/settings.json` with `jq`. It adds Rextina's entries, leaves every
other setting untouched, is safe to run twice, and backs the file up first.
It must be run on each machine where agents run, including the Linux server.

Revised 2026-11-13: the installer was first designed in Lua to need only
Rex. `rex.json.decode` drops `null` and turns empty arrays into objects, and
the user's `settings.json` contains such a value, so a Lua round trip would
corrupt it. `jq` is at `/usr/bin/jq` on this Mac and is a one-package install
on Linux.

### 2. Watcher and notifications

`watch.lua`, run as `rex -S HOST do --all watch.lua host=HOST`, one process
per stored host, all on the Mac. It handles
`terminal.program_status_changed` and raises a macOS notification with
`rex.exec` and `osascript` when a root record changes to `blocked`, `done` or
`error`. The text names the host, session label, tab label and the record's
message.

A `done` notifies only when the record was `working` for at least 30 seconds
before it, so a quick conversational reply stays silent. `blocked` and
`error` always notify. The threshold is a script argument.

A notification is skipped when the user is plainly looking at the block: the
Rex app is the frontmost Mac application (asked through `osascript`) and the
block is the focused block of its session's active window. This can
occasionally skip a notification for a focused block in a session that is not
on screen; Rex's own indicators still show it.

`bin/rextina-watch` starts one watcher for the Mac's local server and one per
stored host from `rex hosts`, skipping a stored host that is the local server
(`spode` here; compared by server identity from `server.status`). It restarts
a watcher that exits, with backoff, so an unreachable host does not stop the
others. A LaunchAgent runs it at login.

### 3. Jump action

`rextina.lua`, loaded from the user's `init.lua` with
`require("rextina")`. It defines the action `rextina_next`, "Go to next agent
needing attention". The action reads status from every block on the local
server and each host in `rex.servers()`, picks one by priority
(`blocked`, then `error`, then `done`, oldest first), focuses the block, and
queues `session.select` on the client. Repeated use cycles: when the focused
block is already in that ordered list, the action goes to the entry after it
and wraps at the end. This needs no state between invocations. No key is bound by default; the README
shows how to bind one.

### Layout

```
bin/rextina-status      reporter (sh)
bin/rextina-hooks       hook installer (sh + jq)
bin/rextina-watch       watcher supervisor (sh)
lua/rextina.lua         action, loaded from init.lua
lua/rextina_status.lua  pure logic: priority, record selection, message text
lua/watch.lua           event script
test/                   tests
Makefile                test, lint, install
```

The Lua files are flat because Rex documents `require` only for files beside
`init.lua`. `make install` copies them to `~/.config/rex/`.

## Calls made by Claude, not decided by the user

- `Stop` reports `done`, not `idle`. Rex decides when a seen `done` stops
  showing.
- `done` notifies only after at least 30 seconds of `working`.
- Claude Code's idle notification is ignored; only permission prompts and
  question tools report `blocked`.
- No notification when Rex is frontmost and the block is the focused block of
  its session's active window. Repeats of the same state for the same block
  are not re-notified.
- `rextina_next` cycles through the waiting agents instead of always landing
  on the top one.
- The local server is always watched, alongside the stored hosts.
- `osascript` for notifications, to avoid a dependency. Clicking the
  notification does not jump; the action does.
- The action scans live rather than reading state kept by the watcher, so it
  works when the watcher is not running.
- No default key binding.
- Tests: pure Lua modules are tested by a script run with `rex do`, so no
  extra Lua toolchain is needed. The reporter is tested by a shell script
  against a pseudo-terminal. One integration test opens a background Rex tab,
  reports a status, and reads it back with `program_status`.

## Risks to settle first, in the plan's first steps

1. Claude Code hooks may run without a controlling terminal. The parent-tty
   fallback covers this; confirm with a real Claude Code session directly in
   a Rex pane.
2. If Claude Code already emits OSC 7501, part 1 shrinks to nothing. Check before writing its hook mapping.
3. Settled: the Rex docs state that scripts run locally where the `rex` CLI
   is, so `rex.exec` in a `rex -S HOST do` script runs on the Mac.
4. `session.select` may not cross hosts. If it does not, the action jumps
   within the host the app is viewing and names the host for the rest.

## Left to the builder

- Exact hook matchers and payload parsing for each agent version.
- Notification wording and backoff timings.
- Lint tooling (`shellcheck`, `luacheck`) depending on what is installed.
- Repository setup: `git init`, trunk-based, short commit messages.
