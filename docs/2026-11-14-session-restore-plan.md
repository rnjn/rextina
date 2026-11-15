# Session Restore Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Save every Rex session's layout, directories and Claude Code conversation ids once a minute, and rebuild them on request after a server restart.

**Architecture:** A one-shot Lua script, run by launchd every 60 seconds, writes one JSON save file per server run. A Rex action reads the newest non-trivial save from an earlier run and recreates each session with `session.create`. All decisions (what to save, which save to pick, what to create) live in one pure Lua module with injected dependencies; file access and Rex calls are thin glue around it.

**Tech Stack:** Lua 5.1 as run by Rex (`rex do` and `init.lua`), `rex.json`, `rex.exec`, launchd, `make`, POSIX `sh` for the integration test, `jq` in tests only.

**Spec:** `docs/2026-11-14-session-restore-design.md`

## Global Constraints

- Stock Rex only. Never modify, patch or wrap the Rex binary or app.
- Lua must run under Rex's Lua 5.1: no `goto`, no `io.popen`, no `os.execute`. Run commands with `rex.exec`.
- Under `rex do`, a local captured by a closure stops tracking after a `pcall`-caught error. Shared mutable state lives in tables.
- `lua/rextina_restore.lua` must not reference the `rex` global.
- Never start a Rex server in order to save it: every save runs with `--autostart=false`.
- Never change Claude Code settings or install hooks.
- Nothing is restored unless the user runs the restore action.
- Text from a save file is never typed into a shell unless it matches `^[A-Za-z0-9-]+$`. Directories are passed as the `cwd` option, never as shell text.
- Save files are mode 600, written to a temporary file in the same directory and renamed.
- Save directory: `$REXTINA_STATE_DIR` if set, else `${XDG_STATE_HOME:-$HOME/.local/state}/rextina/saves`.
- Keep the newest 5 save files.
- The resume command is exactly `claude --resume <id>` followed by a newline.
- No code comments. Short commit messages, no tool or model attribution. Never `git push`.
- After every change run `make lint` and `make test`; commit only when both pass.
- When testing against the live server, create only sessions and tabs labelled with the prefix `rextina-test`, use `--focus=false`, and remove them afterwards. Never restart or stop a Rex server; the one real restart in Task 6 is done by the user.

## Review Focus

1. **A save file that is corrupt, from a newer version, or edited by hand** (invalid JSON, `version` not 1, a conversation id containing `; rm -rf ~`). It is skipped or the id is dropped; nothing from it reaches a shell. Tests in Task 4.
2. **A saved directory that no longer exists, or whose path has spaces, quotes or non-ASCII characters.** The pane still opens; a missing directory falls back to home. Tests in Task 4 and Task 5.
3. **Two restarts with no restore between them, restore pressed twice, restore with no saves at all.** The real layout is found past the trivial save; the second press and the no-save case each report "nothing to restore" and create nothing. Tests in Task 4.
4. **A pane whose foreground process is not really the saved conversation**: reused process id, Claude's file missing, `kind` not `interactive`, directory mismatch. The pane is saved as a plain shell. Tests in Task 2.
5. **A save that cannot complete**: no sessions, a session that vanishes between listing and reading, a save directory that cannot be written. No partial file, no overwrite of a good save from the same run, exit without an error dialog. Tests in Task 3.

---

## File Map

| File | Responsibility |
|---|---|
| `lua/rextina_restore.lua` | Pure logic: build a save, judge it, choose one, turn it into create calls, run a restore through injected functions |
| `lua/rextina_store.lua` | Read, write, list and prune save files |
| `lua/rextina_api.lua` | `attached` call helper, moved out of `rextina.lua` |
| `lua/rextina_save.lua` | Glue: wire real Rex calls into `build` and `write` |
| `lua/save.lua` | One-shot script: call `rextina_save` and stop |
| `lua/rextina.lua` | Registers `rextina_restore`, `rextina_saves`, `rextina_save_restart` |
| `launchd/com.rextina.save.plist.in` | 60-second LaunchAgent |
| `test/restore_spec.lua`, `test/store_spec.lua` | Unit tests |
| `test/restore_integration.sh` | Save, destroy and rebuild a test session on a live server |
| `test/fixtures/view-split.json`, `test/fixtures/create-result.json` | Recorded API output |

Save file shape, version 1:

```
{ version = 1, instance_id, saved_at, host, closed_at?,
  sessions = { { label, restored_at?, tabs = { { label?, active, layout } } } } }
layout leaf:  { pane = { label?, cwd?, program?, claude? } }
layout split: { split = { direction, ratio, before = <layout>, after = <layout> } }
```

---

### Task 1: API facts and fixtures

**Files:**
- Create: `test/fixtures/view-split.json`, `test/fixtures/create-result.json`
- Modify: `docs/2026-11-14-session-restore-design.md` ("What was verified")

**Interfaces:**
- Produces: the two fixtures, and five recorded answers that later tasks rely on.

- [ ] **Step 1: Build a test session.** `rex new rextina-test-facts -c DIR1 --json`, add a second tab, and in it split right, then split the left pane below, each pane in a different temporary directory. Use `--focus=false` throughout.

- [ ] **Step 2: Record `session.view`** for it into `test/fixtures/view-split.json`, replacing ids with short neutral ones (`session:s1`, `window:w1`, `block:b1`…) and directories with `/work/a`, `/work/b`, `/work/c`.

- [ ] **Step 3: Recreate it with one `session.create` call** written by hand from the view (label `rextina-test-facts-2`, two `initial_windows`, block options `cwd`). Save the response, ids neutralised, as `test/fixtures/create-result.json`. Compare the new session's `session.view` with the original: same directions, ratios within 0.01, same pane count and order, and each pane's `process` reports the expected `cwd`.

- [ ] **Step 4: Answer and write down in the design doc:**
  1. Does the `session.create` result give each new window's `window_id`, in order?
  2. What happens when `label` equals an existing session's label?
  3. What happens when a block's `cwd` does not exist: an error for the whole call, or a pane somewhere else?
  4. Does a script run with `rex do` and no `-s` need `session.attach` before `session.view` and `block.method` on the local server?
  5. In a `rextina-test` tab, start `claude --model haiku`, read its id from `~/.claude/sessions/<pid>.json`, quit it, then create a tab with `initial_input` set to `claude --resume <id>` plus a newline. Does it resume with no extra prompt? What does an unknown id do?

- [ ] **Step 5: Kill both test sessions and confirm** `rex ls` shows neither.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "record session api facts for restore"
```

If answer 2 is "error", Task 4's `restore` retries a failed create once without the label. If answer 3 is "error for the whole call", Task 4's `dir_exists` check is mandatory as written; if it is a silent fallback, keep the check anyway so the behaviour does not depend on Rex's.

---

### Task 2: Building a save

**Files:**
- Create: `lua/rextina_restore.lua`, `test/restore_spec.lua`
- Modify: `test/run.lua` (spec list)

**Interfaces:**
- Consumes: `test/fixtures/view-split.json`; the `test`, `eq`, `fixture` globals from `test/run.lua`.
- Produces: module `rextina_restore`, table `M`:
  - `M.claude_id(process, record) -> string|nil`. `process` is a terminal `process` result; `record` is the decoded `~/.claude/sessions/<pid>.json` or `nil`. Returns `record.sessionId` only when `process.foreground.name == "claude"`, `record.kind == "interactive"`, `record.cwd == process.foreground.cwd`, and the id matches `^[A-Za-z0-9-]+$`.
  - `M.build(deps) -> save|nil`. `deps`:
    - `status() -> { instance_id }`
    - `sessions() -> { { session_id, label }, ... }`
    - `view(session_id) -> view|nil`
    - `process(session_id, block_id) -> process|nil`
    - `claude(pid) -> record|nil`
    - `now() -> string`, `host -> string`
    Returns `nil` when `status()` fails. A session whose `view` is `nil` is left out. For each window, only the layer with `kind == "tiled"` is read. A window label matching `^Window %x+$` and a block label equal to `shell` are stored as `nil`. `pane.program` is the foreground process name. A block whose `creator_name` is not `com.superlogical.terminal` becomes a pane with no `cwd`, `program` or `claude`. `active` is true for the session's `active_window_id`.
  - `M.is_trivial(save) -> boolean`: exactly one session with one tab whose layout is a single pane without `claude`. A save with no sessions is also trivial.
  - `M.counts(session) -> { tabs, panes, resumed }`.

- [ ] **Step 1: Write the failing tests in `test/restore_spec.lua`** and add `"restore_spec"` to the list in `test/run.lua`

```lua
test("claude_id accepts a matching interactive record", ...)
  -- process {foreground={name="claude",pid=7,cwd="/work/a"}}, record {sessionId="ab12-cd",kind="interactive",cwd="/work/a"} -> "ab12-cd"
test("claude_id rejects another program, a missing record, a different cwd, a non-interactive kind", ...)
test("claude_id rejects an id with shell characters", ...)      -- sessionId "x; rm -rf ~" -> nil
test("build records sessions, tabs and nested splits from the fixture", ...)
  -- second tab layout == { split = { direction=..., ratio=..., before = { split = {...} }, after = { pane = {...} } } } exactly as the fixture
test("build stores each pane's cwd, program and conversation id", ...)
test("build drops generated labels and keeps chosen ones", ...)  -- "Window 7c0f2fb7" -> nil, "deploy" kept, "shell" -> nil
test("build marks the active tab", ...)
test("build leaves out a session whose view fails", ...)
test("build returns nil when the server status fails", ...)
test("build saves a non-terminal block as a bare pane", ...)
test("build ignores floating layers", ...)
test("is_trivial", ...)   -- fresh single shell: true; no sessions: true; single claude pane: false; two tabs: false; one tab with a split: false
test("counts", ...)       -- 2 tabs, 4 panes, 1 resumed for the fixture-based save
```

- [ ] **Step 2: Run `make test`.** Expected: FAIL, `module 'rextina_restore' not found`.

- [ ] **Step 3: Implement the four functions** in `lua/rextina_restore.lua`.

- [ ] **Step 4: Run `make test` and `make lint`.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "build a session save"
```

---

### Task 3: Storing saves and the save script

**Files:**
- Create: `lua/rextina_store.lua`, `lua/rextina_api.lua`, `lua/rextina_save.lua`, `lua/save.lua`, `test/store_spec.lua`
- Modify: `lua/rextina.lua` (use `rextina_api`), `test/run.lua`

**Interfaces:**
- Consumes: `rextina_restore.build`, `rextina_restore.is_trivial`.
- Produces: module `rextina_store`, built with `Store.new(lib, dir)` where `lib` provides `exec` and `json` (pass `rex`) and `dir` is the save directory:
  - `store:write(save) -> path|nil, err`. Creates the directory, writes `<instance_id>.json.tmp`, sets mode 600, renames to `<instance_id>.json`. Refuses an `instance_id` that does not match `^[A-Za-z0-9-]+$`.
  - `store:read_all() -> list`. Every `*.json` in the directory that decodes, has `version == 1` and whose `instance_id` matches its file name. Anything else is skipped.
  - `store:read(instance_id) -> save|nil`.
  - `store:prune(keep)`. Deletes all but the `keep` saves with the newest `saved_at`.
  - `Store.default_dir(getenv) -> string` following the Global Constraints.
- Produces: module `rextina_api` with `attached(api, session_id, method, args) -> result, err, did_attach`, behaviour unchanged from `rextina.lua`.
- Produces: module `rextina_save` with `run(lib, opts) -> save|nil, path|nil, reason`. `lib` is `rex`. `opts.dir` overrides the directory. It builds real `deps` for `M.build` (`server.status`, `session.list`, `session.view` and the terminal `process` method through `attached`, Claude's file read with `io.open` from `$HOME/.claude/sessions/<pid>.json`, `hostname -s` through `exec`), then:
  - returns `nil, nil, "no server"` when `build` returns `nil`;
  - when the new save has no sessions and a save for this `instance_id` already exists, writes nothing and returns `nil, nil, "empty"`;
  - otherwise writes, prunes to 5, and returns the save and its path.
- Produces: `lua/save.lua`, which adds its own directory to `package.path`, calls `require("rextina_save").run(rex, { dir = rex.args.dir })`, and calls `rex.stop(0)` in every case.

- [ ] **Step 1: Write the failing tests in `test/store_spec.lua`,** each in a fresh temporary directory made with `rex.exec({ "mktemp", "-d" })` and removed afterwards

```lua
test("write then read_all round trips a save", ...)
test("write creates the directory and sets mode 600", ...)        -- `stat -f %Lp` on macOS, `stat -c %a` elsewhere
test("write leaves no .tmp file behind", ...)
test("write refuses an instance id with a slash", ...)
test("read_all skips invalid JSON, a wrong version, and a mismatched file name", ...)
test("read_all returns {} for a missing directory", ...)
test("prune keeps the five newest by saved_at", ...)              -- write 7, expect the 5 latest ids
test("default_dir honours REXTINA_STATE_DIR, then XDG_STATE_HOME, then HOME", ...)
test("write returns nil and an error when the directory cannot be created", ...)  -- dir under /dev/null
```

Add to `test/restore_spec.lua`, with a fake `lib`:

```lua
test("save run writes nothing when there is no server", ...)
test("save run does not overwrite a save from this run with an empty one", ...)
test("save run writes and prunes", ...)
```

- [ ] **Step 2: Run `make test`.** Expected: FAIL, modules not found.

- [ ] **Step 3: Implement the three modules and `save.lua`;** change `lua/rextina.lua` to `require("rextina_api")`.

- [ ] **Step 4: Run `make test` and `make lint`.** Expected: all pass, including the existing `next_spec` tests.

- [ ] **Step 5: Verify live.** `rex --autostart=false do lua/save.lua dir=$TMP`. Expected: one file named after the server's `instance_id`, mode 600, listing the real sessions; panes running Claude Code have a `claude` id that matches `~/.claude/sessions/<pid>.json`. Then run it with `REXTINA_REX` pointed at a path with no server (`rex --autostart=false -S unix:///nonexistent do …`). Expected: nothing written.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "store session saves"
```

---

### Task 4: Choosing a save and rebuilding it

**Files:**
- Modify: `lua/rextina_restore.lua`, `test/restore_spec.lua`

**Interfaces:**
- Consumes: the save shape; `create-result.json`; Task 1's answers.
- Produces, on `M`:
  - `M.choose(saves, current_instance_id, wanted_id) -> save|nil, reason`.
    - With `wanted_id`: that save, closed or not; `nil, "unknown"` if absent; `nil, "running"` if it is the current run's.
    - Without: drop the current run's save and trivial saves; take the newest by `saved_at`; if there is none return `nil, "none"`; if it has `closed_at` return `nil, "closed"`.
  - `M.window_spec(tab, deps) -> { window_label?, layout }` in the API's form. A pane becomes `{ block = { flavor = "com.superlogical.terminal.shell", label?, options? } }`. `options.cwd` is set only when the pane has a `cwd` and `deps.dir_exists(cwd)` is true. `options.initial_input` is `"claude --resume " .. id .. "\n"` only when `pane.claude` matches `^[A-Za-z0-9-]+$`. A split keeps `direction` and `ratio`.
  - `M.restore(save, deps, all) -> report`. `deps`: `create(args) -> result|nil, err`, `focus_window(session_id, window_id)`, `dir_exists(path) -> boolean`, `now() -> string`, `persist(save)`.
    - Rebuilds each session without `restored_at`, or every session when `all` is true.
    - Calls `create({ label, initial_windows })`; per Task 1 answer 2, on failure retries once without `label`.
    - On success sets `session.restored_at = deps.now()`, calls `deps.persist(save)`, and focuses the saved active tab using the window ids from the create result.
    - A failed session is recorded and the loop continues.
    - When every session has `restored_at`, sets `save.closed_at` and persists.
    - `report = { saved_at, host, complete, sessions = { { label, tabs, panes, resumed, error? } } }`, listing only the sessions attempted in this call.

- [ ] **Step 1: Write the failing tests**

```lua
test("choose skips the running server's save", ...)
test("choose skips a trivial save and finds the real one behind it", ...)   -- two restarts in a row
test("choose returns closed, not an older save, after a completed restore", ...)
test("choose returns none when there are no saves", ...)
test("choose by id returns a closed save", ...)
test("choose by id refuses the running server's save and an unknown id", ...)
test("window_spec turns a nested split into the api layout", ...)
test("window_spec passes an existing cwd and omits a missing one", ...)
test("window_spec keeps a cwd with spaces, quotes and non-ASCII as an option", ...)
  -- cwd [[/work/my "odd" dir é]] appears only in options.cwd, never in initial_input
test("window_spec types the resume command for a claude pane", ...)          -- initial_input == "claude --resume ab12-cd\n"
test("window_spec drops a conversation id with shell characters", ...)       -- claude = "x; rm -rf ~" -> no initial_input
test("restore creates every session and closes the save", ...)
test("restore focuses the saved active tab", ...)                           -- focus_window called with the 2nd window id from the fixture
test("restore continues after one session fails and leaves the save open", ...)
test("a second restore rebuilds only the session that failed", ...)         -- create called once, for that label
test("restore retries without the label when the labelled create fails", ...)
test("restore persists after each session", ...)                            -- persist call count == sessions + 1 on full success
test("restore with all=true rebuilds sessions already marked", ...)
test("report counts tabs, panes and resumed conversations", ...)
```

- [ ] **Step 2: Run `make test`.** Expected: FAIL on the new tests.

- [ ] **Step 3: Implement `choose`, `window_spec` and `restore`.**

- [ ] **Step 4: Run `make test` and `make lint`.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "choose and rebuild a session save"
```

---

### Task 5: Actions and the round trip

**Files:**
- Modify: `lua/rextina.lua`, `test/next_spec.lua` or a new `test/actions_spec.lua`, `test/run.lua`
- Create: `test/restore_integration.sh`
- Modify: `Makefile` (`test-integration` runs both integration scripts)

**Interfaces:**
- Consumes: `rextina_store`, `rextina_save`, `rextina_restore`.
- Produces, in `lua/rextina.lua`:
  - `M.restore_action(lib, args) -> result`. Reads all saves, calls `choose` with the running `instance_id` and `args.save`, and when a save is chosen calls `M.restore` with real `deps` (`session.create`, `session.focus_window`, `dir_exists` through `exec({ "test", "-d", path })`, `persist` through the store). With `args.save` it passes `all = true`. Returns the report, or `{ restored = false, reason = "none" | "closed" | "unknown" | "running" }`.
  - `M.saves_action(lib) -> { { instance_id, saved_at, host, sessions, state } }` with `state` one of `running`, `trivial`, `open`, `closed`, newest first.
  - Actions, all with `category = "Rextina"`:
    - `rextina_restore`, title "Restore Sessions", `args = { save = "string?" }`
    - `rextina_saves`, title "List Session Saves"
    - `rextina_save_restart`, title "Save Sessions and Restart Server…": runs `rextina_save.run(rex)`, then `rex.client.queue("client.server.restart")`. If the save fails it does not queue the restart and returns the reason.

- [ ] **Step 1: Write the failing unit tests** with a fake `lib` (fake `call`, `exec`, `json = rex.json`, a store on a temp dir)

```lua
test("restore_action reports none when there is nothing to restore", ...)   -- no create call made
test("restore_action restores the chosen save and marks it closed on disk", ...)
test("restore_action by id restores a closed save in full", ...)
test("restore_action falls back to home for a directory that is gone", ...)
test("saves_action labels running, trivial, open and closed saves, newest first", ...)
test("save_restart does not restart when the save fails", ...)
```

- [ ] **Step 2: Run `make test`.** Expected: FAIL on the new tests.

- [ ] **Step 3: Implement the two functions and register the three actions.**

- [ ] **Step 4: Run `make test` and `make lint`.** Expected: all pass.

- [ ] **Step 5: Write `test/restore_integration.sh`.** It skips with `SKIP no rex session` when no server is running. Otherwise, with `REXTINA_STATE_DIR` set to a temp directory and a `trap` that kills every session whose label starts with `rextina-test`:
  1. Create session `rextina-test-rt` with the Task 1 layout: tab 1 one pane in `$A`; tab 2 split right then left pane split below, in `$A`, `$B`, `$C`; tab 2 labelled `rextina-test-tab`.
  2. Run `rex --autostart=false do lua/save.lua dir=$REXTINA_STATE_DIR`.
  3. With `jq`, reduce the save to only the `rextina-test-rt` session and set `instance_id` to `previous`, written as `previous.json`; delete the original file. This keeps the user's real sessions out of the restore.
  4. Kill `rextina-test-rt`.
  5. Run a three-line loader script that requires `rextina` and returns `restore_action(rex, { save = "previous" })`.
  6. Assert: the report is `complete`; a session labelled `rextina-test-rt` exists; it has 2 tabs; tab 2 is labelled `rextina-test-tab`, is active, and its layout has the same directions and pane count as before with ratios within 0.01; after 3 seconds the three panes' `process` `cwd` values are `$A`, `$B`, `$C` in order.
  7. Run the loader again without `save=`. Assert `reason` is `none` and no second `rextina-test-rt` exists.

- [ ] **Step 6: Run `make test-integration`.** Expected: both integration scripts pass, and `rex ls` shows no `rextina-test` session.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "add restore actions"
```

---

### Task 6: Scheduled save, install, README, and a real restart

**Files:**
- Create: `launchd/com.rextina.save.plist.in`
- Modify: `Makefile`, `README.md`

**Interfaces:**
- Consumes: `lua/save.lua` and the modules it requires.
- Produces:
  - `make install` = `install-action` + `install-save`.
  - `install-action` copies `rextina.lua`, `rextina_status.lua`, `rextina_api.lua`, `rextina_restore.lua`, `rextina_store.lua`, `rextina_save.lua` to the Rex config directory.
  - `install-save` (Darwin only) copies `lua/save.lua` and the four modules it needs to `$(SHARE_DIR)/lua`, renders the plist and loads `com.rextina.save`. The plist runs `REX_PATH --autostart=false do $(SHARE_DIR)/lua/save.lua` with `StartInterval` 60 and `RunAtLoad` true, and sends output to `~/Library/Logs/rextina-save.log`.
  - `uninstall-save` unloads and removes the plist and the copied save files; it leaves the save directory alone. `uninstall` calls it.
  - `uninstall-watch` removes only the watcher's own files from `$(SHARE_DIR)`, no longer the whole directory.

- [ ] **Step 1: Write the plist template and the Makefile targets.** `plutil -lint` the rendered plist.

- [ ] **Step 2: Run `make install`.** Expected: `launchctl print gui/$(id -u)/com.rextina.save` shows the job loaded; within 70 seconds a file named after the running `instance_id` appears in the save directory and its `saved_at` advances on the next run; `rex actions` lists `rextina_restore`, `rextina_saves` and `rextina_save_restart`; the log file is empty.

- [ ] **Step 3: Check the launchd path (spec risk 3).** Confirm from the log and the file's modification time that the save ran under launchd with no `PATH` help, including reading `~/.claude/sessions`. If macOS blocked the read, the log will say so; report it to the user, since it needs a privacy permission only they can grant.

- [ ] **Step 4: Update `README.md`:** a "Restore after a restart" section covering what is saved and what is not, the three actions, binding a key, where saves live, `make uninstall-save`, and the limits from the spec's Non-goals. State that Claude Code is resumed with no launch flags, and that the conversation id comes from an undocumented Claude Code file.

- [ ] **Step 5: Run `make lint`, `make test`, `make test-integration`.** Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "save sessions every minute"
```

- [ ] **Step 7: Real restart (spec risk 4). Do not do this yourself.** Tell the user everything else is done and ask them to pick a moment, since it ends every session on this Mac including the one the agent runs in. They run "Save Sessions and Restart Server…", then "Restore Sessions". What to check afterwards, by them or by a new agent session: sessions, tabs and splits are back; Claude panes resumed their conversations; `rextina_saves` shows the old run `closed` and the new run `running`; a second "Restore Sessions" does nothing. Record the outcome in the README, or as untested if it has not happened.
