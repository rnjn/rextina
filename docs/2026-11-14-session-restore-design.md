# Session restore for stock Rex

Date: 2026-11-14
Status: draft, awaiting approval

## Intent

A Rex server restart ends every session on that machine, and upgrading Rex
requires one. Rex has no way to get the sessions back. The user wants to
restore sessions, tabs, splits and working directories after a restart, and
to resume the Claude Code conversations that were running in them.

This is the first Rextina feature that Rex does not already provide. If Rex
ships native restore, this feature is deleted.

## Goals

1. After a server restart, one action rebuilds the previous sessions: tabs in
   order, splits with their ratios, labels, and each pane's working
   directory.
2. Panes that were running Claude Code come back with the same conversation
   resumed.
3. Saving needs no attention: it happens every minute.
4. A planned restart can be made with a fresh save taken first.

## Non-goals

- Keeping processes alive across a restart. Shells come back fresh.
- Scrollback or screen contents.
- Restarting other programs (editors, dev servers, `tail`).
- Floating panes and zoom state.
- Other coding agents.
- Linux and other non-Mac servers. The Lua is portable; the every-minute
  trigger in this version is a macOS LaunchAgent.
- Restoring automatically. Nothing is rebuilt unless the user asks.

## Anti-goals

- Bringing back tabs the user did not ask for.
- A fresh, near-empty server overwriting the save from the server before it.
- Starting a Rex server just to save it.
- Changing Claude Code settings or installing hooks.
- Modifying Rex.

## Constraints

- Stock Rex only: `init.lua` actions, `rex do` Lua scripts, the `rex` CLI.
- Rex runs Lua 5.1 without `io.popen` or `os.execute`; timers do not exist in
  `init.lua`. Under `rex do`, shared mutable state must live in tables.
- Layout and Claude Code's files live on the machine that runs the server, so
  saving and restoring are per machine.
- Claude Code is not modified. The conversation id is read from
  `~/.claude/sessions/<pid>.json`, an undocumented file.

## What was verified (2026-11-14, Rex 0.1.0-preview.18, Claude Code 2.1.311)

- `session.view` reports each tab's layout as a tree: a node is either a
  block or a split with `direction`, `ratio`, `before` and `after`.
- `session.new_window` and `session.create` accept the same tree, with each
  block given a flavor, a label and options (`cwd`, `command`,
  `initial_input`).
- The terminal's `process` method reports the foreground process `pid`,
  `name` and `cwd` for a pane.
- `~/.claude/sessions/<pid>.json` holds `sessionId`, `cwd`, `kind` and
  `procStart` for a running Claude Code process.
- `server.status` reports an `instance_id` that changes on every server
  start.
- After a restart the Mac app creates one fresh session.

Verified while building (2026-11-15):

- A session with a nested split, recreated by one `session.create` call from
  its own `session.view`, has the same directions, ratios and pane order, and
  every pane starts in its saved directory.
- The `session.create` result lists each new window's `window_id` in order,
  and the last window becomes the active one.
- Two sessions may share a label; `session.create` accepts a duplicate.
- A pane whose `cwd` does not exist still opens, in the home directory, with
  no error.
- A `rex do` script can read only the session named by `REX_SESSION`
  without attaching. Every other session, and every session when the script
  runs under launchd, refuses reads until `session.attach` is called. The
  save attaches when refused and detaches afterwards.
- `claude --resume <id>` typed into a new shell as `initial_input` resumes
  the conversation with no extra prompt, under the same id. An unknown id
  prints "No conversation found with session ID" and leaves the shell.

Not verified: a real server restart.

## Approaches considered

Trigger for restore:

1. **User-triggered action.** Chosen by the user. Nothing returns uninvited.
2. Automatic on server start. Rejected: it has to guess intent and would
   resume every agent at once.

How saves happen:

1. **A one-shot save every minute.** Chosen by the user. launchd runs a short
   script that saves and exits. No long-running process, so a restart or
   crash cannot break it. A restore can be up to a minute stale.
2. A live watcher that saves on every change. Always current, but needs a
   supervisor and reconnect handling, which is where the earlier banner
   watcher's defects were.
3. Save only on demand. Smallest, but a crash restores whatever was last
   saved by hand.

## Design

### Sketch

```
 every 60 s (launchd)                         when the user asks
 ┌───────────────────────────┐               ┌─────────────────────────────┐
 │ rex do save.lua           │               │ action: Restore Sessions    │
 │  (never starts a server)  │               │  (command palette / key)    │
 │                           │               │                             │
 │ for each session:         │               │ pick newest save from an    │
 │   layout tree             │               │ EARLIER server run          │
 │   labels                  │               │                             │
 │   per pane: cwd,          │               │ for each saved session:     │
 │     foreground process    │               │   session.create with the   │
 │   if process is claude:   │               │   same tabs and splits      │
 │     ~/.claude/sessions/   │               │   shell in saved cwd        │
 │       <pid>.json ─▶ id    │               │   claude panes get          │
 └────────────┬──────────────┘               │   "claude --resume <id>"    │
              │ write                        │                             │
              ▼                              │ mark the save as restored   │
 ~/.local/state/rextina/saves/               └──────────────▲──────────────┘
   <server instance id>.json  ──────────────────────────────┘ read
   (one file per server run, newest 5 kept)
```

What a restore looks like:

```
 before restart                      after restart + Restore Sessions
 ┌───────────────────────────┐      ┌───────────────────────────────────┐
 │ electric-orchard          │      │ polished-strait   (fresh, kept)   │
 │  1 api      claude  ~/api │      │  1 shell                          │
 │  2 web      nvim    ~/web │      │ electric-orchard  (restored)      │
 │  3 ops    ┌──────┬──────┐ │      │  1 api    claude --resume 9f3…    │
 │           │claude│ tail │ │      │  2 web    shell in ~/web          │
 │           │~/ops │~/ops │ │      │  3 ops  ┌──────────┬───────────┐  │
 │           └──────┴──────┘ │      │         │ claude   │ shell     │  │
 └───────────────────────────┘      │         │ --resume │ in ~/ops  │  │
                                    │         └──────────┴───────────┘  │
                                    └───────────────────────────────────┘
```

### 1. Save

`lua/save.lua`, run as `rex --autostart=false do save.lua`. With no server
running it fails to connect and exits without writing anything.

It writes one JSON file per server run:
`${XDG_STATE_HOME:-~/.local/state}/rextina/saves/<instance_id>.json`, mode
600, written to a temporary file and renamed. Contents:

- `instance_id`, `saved_at`, `host` (the machine's name, for display)
- per session: label and the ordered tabs
- per tab: label, whether it was the active tab, and the layout tree
- per pane: label, working directory, foreground process name, and for a
  Claude Code pane the conversation id

A pane is a Claude Code pane when its foreground process is named `claude`
and `~/.claude/sessions/<pid>.json` exists with a matching `cwd` and
`kind` of `interactive`. The `cwd` check guards against a reused process id.

Only tiled terminal panes are saved. A non-terminal pane is saved as a plain
shell in the home directory. Floating layers are skipped.

After writing, the script deletes all but the newest five save files.

A save that finds no sessions does not overwrite an existing file for the
same server run.

### 2. Restore

Action `rextina_restore`, "Restore Sessions", in the command palette. For
each session in the chosen save it calls `session.create` with every tab's
layout.

Which save is chosen:

- Saves from the running server are never eligible.
- A trivial save is skipped: one session, one tab, one pane, no Claude Code
  conversation. That is what the app creates after a restart, so two
  restarts in a row do not bury the real layout behind an empty one.
- Of what remains, the newest is used.
- Once a restore completes, that save and every older one are closed: a
  second press finds nothing and says so. It never falls through to an older
  save.
- `rextina_restore save=<instance_id>` restores a named save, closed or not.
  `rextina_saves` lists the saves with their time, session count and state.

- Each pane starts an interactive shell in its saved directory. If the
  directory no longer exists, the pane starts in the home directory.
- A Claude Code pane has `claude --resume <id>` typed into that shell, so
  quitting Claude leaves a shell, as it would have before.
- Sessions keep their saved labels. The fresh session the app created is
  left alone.
- A tab or pane label that Rex generated (`Window 89abcdef`, `shell`) is not
  set, so the tab keeps showing its live title.
- The saved active tab of each session is made active again.

Each session is marked in the save file as soon as it is rebuilt. If one
session fails, the others are still restored and the result names the
failure; pressing again rebuilds only the sessions not yet marked, so a
conversation that is already running is never resumed a second time. When
every session is marked, the save is closed.

Claude Code is resumed with `claude --resume <id>` and nothing else. Flags
the original process was started with are not replayed. Rex reports only the
program name, and replaying a permission-skipping flag across many panes at
once is not something to do silently. On this machine every running Claude
Code process was started with no flags or with `--resume` alone.

The action returns what it did: the save's time, and per session the number
of tabs, panes and resumed conversations.

### 3. Save and restart

Action `rextina_save_restart`, "Save Sessions and Restart Server…". It runs
the save from inside the server, then queues the app's own "Restart Server…"
action, which asks for confirmation as it does today.

### 4. Install

`make install` on a Mac also copies `save.lua` and installs the LaunchAgent
`com.rextina.save` with a 60-second interval. `make uninstall` removes it and
leaves the save files. `make install-watch` and the banner watcher are
unchanged.

### Layout

```
lua/rextina_restore.lua   pure logic: build a save from API results, pick a
                          save, turn a save into create calls
lua/save.lua              one-shot save script
lua/rextina.lua           registers the two new actions
launchd/com.rextina.save.plist.in
test/restore_spec.lua     unit tests with recorded API fixtures
test/restore_integration.sh   round trip against a live server
```

## Calls made by Claude, not decided by the user

- "Save Sessions and Restart Server…" is included. The user agreed to the
  every-minute save; this action was proposed alongside it and not
  separately confirmed.
- Resumed conversations start immediately on restore, in every pane at once.
- One save file per server run, newest five kept, chosen by `instance_id`.
- Trivial saves are skipped, and a completed restore closes that save and
  all older ones. An older save can still be restored by naming it.
- A retry after a partial failure rebuilds only what failed.
- Launch flags are not replayed when resuming Claude Code.
- The conversation id comes from Claude Code's process file, with no hook.
  If the file is missing or does not match, the pane is restored as a shell;
  there is no `claude --continue` fallback, because it can pick the wrong
  conversation when two agents share a directory.
- The fresh session the app creates after a restart is not reused or closed.
- Auto-generated labels are not written back.
- No key is bound. The README shows how.

## Risks to settle first, in the plan's first steps

1. Round trip. Save a test session with a nested split, destroy it, rebuild
   it from the save, and compare the two layouts.
2. `claude --resume <id>` as initial input: confirm it resumes without an
   extra prompt, and what happens when the id is unknown.
3. Whether `rex do` under launchd can reach the server with only
   `REXTINA_REX` set, as the banner watcher did.
4. A save taken in the minute after a restart must not be the one restore
   picks. Covered by the `instance_id` rule; confirm with a real restart at
   the end, at a time the user chooses.

## Left to the builder

- The JSON field names of the save file.
- How the active tab is reapplied (`session.focus_window` or tab order).
- Notification of the result inside the app, if Rex offers one.
- Log location and wording.
