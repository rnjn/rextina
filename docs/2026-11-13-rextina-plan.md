# Rextina Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Claude Code agents running in Rex terminals report their state to Rex, notify the Mac when one blocks, finishes or fails on any host, and add one action that jumps to the agent needing attention.

**Architecture:** A dependency-free `sh` reporter, called from Claude Code hooks, writes OSC 7501 status reports to the agent's terminal; Rex's own UI shows them. On the Mac, one `rex do --all` Lua watcher per host turns status events into macOS notifications. A Lua action loaded from `init.lua` scans all hosts and selects the next waiting agent. All decision logic lives in one pure Lua module so it can be tested without a server.

**Tech Stack:** POSIX `sh`, `jq` (hook installer only), Lua 5.1 as run by `rex do`, `osascript` and `lsappinfo` (Mac only), `launchd`, `make`, `shellcheck`.

**Spec:** `docs/2026-11-13-rextina-design.md`

## Global Constraints

- Stock Rex only. Never modify, patch or wrap the Rex binary or app.
- Claude Code only. No Codex or other agent support.
- Lua must run under Rex's Lua 5.1: no `goto`, no integer division, no `io.popen`, no `os.execute`. Run commands with `rex.exec`.
- `rex.on` works only in `rex do` scripts, never in `init.lua`.
- `lua/rextina_status.lua` must not reference the `rex` global.
- Never overwrite the user's existing hooks or `init.lua` content; add and remove only Rextina's own entries.
- Hooks must never break or slow an agent: the reporter exits 0 in every case and does no network or server call.
- Reporter works on macOS and Linux. Notifications, the LaunchAgent and the jump action are Mac-only.
- OSC 7501 values: `app` is `claude-code`; `msg` is base64 of single-line UTF-8 with no control characters, at most 200 characters before encoding.
- No code comments. Short commit messages, no tool or model attribution. Never `git push`.
- After every change run `make lint` and `make test`; commit only when both pass.
- The `rex` binary is not assumed to be on `PATH` in non-interactive contexts. Every script takes it from `REXTINA_REX`, defaulting to `rex`.
- When testing against the live server, pass `--focus=false`, create only resources labelled `rextina-test`, and close them afterwards. Do not touch other sessions, tabs or panes.

## Review Focus

1. **A `settings.json` that already has hooks, empty arrays, `null`, is absent, or is invalid JSON.** Everything not owned by Rextina must survive unchanged; invalid JSON must cause a refusal with nothing written. Tests in Task 2.
2. **A status message containing quotes, backslashes, newlines, non-ASCII text, or 5,000 characters.** The report must stay a valid OSC 7501 sequence and the notification must not break AppleScript quoting. Tests in Task 1 and Task 3.
3. **The agent runs outside Rex, with no terminal, or with `REX_BLOCK` unset.** The hook must write nothing and exit 0. Tests in Task 1.
4. **A stored host is unreachable.** Watchers for the other hosts keep running, and the jump action still returns results from reachable hosts. Tests in Task 5 and Task 6.
5. **The watcher starts while an agent is mid-turn, or receives events for child records or removed records.** No crash and no notification for a `done` whose start it never saw. Tests in Task 3 and Task 4.

---

## File Map

| File | Responsibility |
|---|---|
| `Makefile` | `test`, `test-integration`, `lint`, `install`, `uninstall` |
| `bin/rextina-status` | Write one OSC 7501 report to the agent's terminal |
| `bin/rextina-hooks` | Add or remove Rextina's hook entries in Claude Code settings |
| `bin/rextina-watch` | Start and restart one watcher per host |
| `lua/rextina_status.lua` | Pure logic: transitions, ordering, cycling, text, quoting, view lookup |
| `lua/watch.lua` | `rex do` script: status events to notifications |
| `lua/rextina.lua` | `rextina_next` action and its host scan |
| `launchd/com.rextina.watch.plist.in` | LaunchAgent template |
| `test/lib.sh` | Shell assertions |
| `test/status_test.sh`, `test/hooks_test.sh`, `test/watch_test.sh` | Shell tests |
| `test/run.lua`, `test/status_spec.lua`, `test/next_spec.lua` | Lua tests, run with `rex do` |
| `test/integration.sh` | Live-server test of the reporter |
| `test/fixtures/` | Captured API output and sample settings files |
| `README.md` | Install, bind a key, limits |

---

### Task 1: Repository, test harness and status reporter

**Files:**
- Create: `.gitignore`, `Makefile`, `test/lib.sh`, `bin/rextina-status`, `test/status_test.sh`, `test/integration.sh`

**Interfaces:**
- Produces: `bin/rextina-status [--app NAME] STATE [KIND] [MESSAGE]`
  - `STATE`: `idle`, `working`, `blocked`, `done`, `error`, `clear`. Anything else: write nothing, exit 0.
  - `KIND`: `permission`, `question`, `auth`, or `-` for none. Emitted only with `blocked`.
  - `--app` defaults to `claude-code`.
  - Output target, first that applies: file named by `REXTINA_TTY`; `/dev/tty`; `/dev/<tty of $PPID from ps -o tty=>`.
  - Writes nothing and exits 0 when `REX_BLOCK` is unset or no target can be opened.
  - Exact bytes for `REX_BLOCK=b rextina-status blocked permission "Needs approval"`:
    `ESC ] 7501 ; state=blocked:kind=permission:app=claude-code:msg=TmVlZHMgYXBwcm92YWw= ESC \` with no spaces.
  - `clear` emits `state=clear` only.
- Produces: `test/lib.sh` with `assert_eq EXPECTED ACTUAL NAME`, `assert_contains HAYSTACK NEEDLE NAME`, `assert_file_absent PATH NAME`, and `finish` which prints a count and exits 1 if any assertion failed.
- Produces: `make test` runs every `test/*_test.sh` then `$(REXTINA_REX) do test/run.lua root=$(CURDIR)` when `test/run.lua` exists; `make lint` runs `shellcheck bin/* test/*.sh`; `make test-integration` runs `test/integration.sh`.

- [ ] **Step 1: Initialise the repository**

```bash
git init -b main
printf '%s\n' '.DS_Store' '*.bak' > .gitignore
git add .gitignore docs && git commit -m "add design and plan"
```

- [ ] **Step 2: Write `test/lib.sh` and the `Makefile` targets** described under Interfaces. `REXTINA_REX ?= rex`.

- [ ] **Step 3: Write the failing tests in `test/status_test.sh`**

Each test runs the reporter with `REXTINA_TTY` pointing at a temp file and compares the file's bytes (`od -An -c` or `printf` comparison).

```sh
t_blocked_permission   # REX_BLOCK=b, args: blocked permission "Needs approval"
                       # file == '\033]7501;state=blocked:kind=permission:app=claude-code:msg=TmVlZHMgYXBwcm92YWw=\033\\'
t_working_no_message   # args: working  -> '\033]7501;state=working:app=claude-code\033\\'
t_kind_ignored_unless_blocked  # args: done permission "x" -> no "kind=" in output
t_kind_dash            # args: blocked - "Q" -> no "kind=" in output, msg present
t_clear                # args: clear -> '\033]7501;state=clear\033\\'
t_app_option           # args: --app codex idle -> contains "app=codex"
t_unknown_state        # args: bogus -> file empty, exit 0
t_no_rex_block         # REX_BLOCK unset, args: working -> file empty, exit 0
t_unwritable_target    # REXTINA_TTY=/nonexistent/dir/x -> exit 0, no stderr
t_message_sanitised    # message 'a"b\c' + newline + 'd' + tab + 'é'
                       # decoded msg == 'a"b\c d é' (control chars become one space each)
t_message_truncated    # 5000-char message -> decoded msg length == 200
t_invalid_app          # --app 'bad app!' -> no "app=" in output
```

- [ ] **Step 4: Run `make test`.** Expected: FAIL, `bin/rextina-status: not found`.

- [ ] **Step 5: Implement `bin/rextina-status`** as `#!/bin/sh`, `chmod +x`. Base64 with `base64 | tr -d '\n'`. Truncate by characters, not bytes, so a multi-byte character is never split (`LC_ALL` aware `cut -c` or `awk substr`; pick one and keep `t_message_sanitised` passing on both macOS and Linux). Build the whole sequence in one `printf` so it is written in a single call.

- [ ] **Step 6: Run `make test` and `make lint`.** Expected: all pass, shellcheck clean.

- [ ] **Step 7: Write `test/integration.sh`**

It picks the first session from `$REXTINA_REX --autostart=false ls --json`; if there is none it prints `SKIP no rex session` and exits 0. Otherwise:

```sh
out=$($REXTINA_REX run -s "$ses" --label rextina-test --focus=false --json -- \
  sh -c "REX_BLOCK=test '$root/bin/rextina-status' blocked permission 'Needs approval' >/dev/null 2>&1; sleep 15")
```

Then, after 2 seconds, `block call -s "$ses" -b "$block" program_status` must contain `"state":"blocked"`, `"kind":"permission"`, `"app":"claude-code"` and `"msg":"Needs approval"`. A `trap` closes the window (`window close -s "$ses" "$window"`) on every exit path.

- [ ] **Step 8: Run `make test-integration`.** Expected: PASS, and no `rextina-test` tab left in the session.

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "add status reporter"
```

---

### Task 2: Claude Code hook installer

**Files:**
- Create: `bin/rextina-hooks`, `test/hooks_test.sh`, `test/fixtures/settings-existing.json`, `test/fixtures/settings-invalid.json`

**Interfaces:**
- Consumes: `bin/rextina-status` from Task 1.
- Produces: `bin/rextina-hooks install|uninstall|print [--settings PATH] [--status-bin PATH]`
  - `--settings` defaults to `$HOME/.claude/settings.json`; `--status-bin` defaults to the absolute path of `rextina-status` beside the script.
  - `print` writes the hook entries as JSON to stdout and changes nothing.
  - An entry is Rextina's if its command contains `rextina-status`. `install` removes Rextina's entries, then adds the current set, so it is idempotent. `uninstall` removes them and deletes any event key and the `hooks` key left empty.
  - Before writing, copies the file to `PATH.rextina.bak`. Writes through a temp file in the same directory and `mv`.
  - Missing file: `install` creates it containing only the hooks; `uninstall` does nothing, exit 0.
  - Invalid JSON, or `jq` missing: message on stderr, exit 1, nothing written, no backup made.

Hook entries, in Claude Code's settings shape (`hooks.<Event>[] = {matcher?, hooks:[{type:"command", command}]}`), with `BIN` the status-bin path, shell-quoted:

| Event | Matcher | Command |
|---|---|---|
| `SessionStart` | none | `BIN idle` |
| `UserPromptSubmit` | none | `BIN working` |
| `PreToolUse` | `AskUserQuestion` | `BIN blocked question 'Has a question'` |
| `PostToolUse` | none | `BIN working` |
| `Notification` | `permission_prompt` | `BIN blocked permission 'Needs approval'` |
| `Notification` | `elicitation_dialog` | `BIN blocked question 'Has a question'` |
| `Stop` | none | `BIN done 'Finished'` |
| `SessionEnd` | none | `BIN clear` |

There is deliberately no entry for the `idle_prompt` notification.

- [ ] **Step 1: Check whether Claude Code already reports status (spec risk 2).** This needs a person at the Mac: ask the user to open a new Rex tab, run `claude` directly in it (not inside herdr or tmux), send one prompt, and run `rex block call -s SESSION -b BLOCK program_status` for that pane from another pane. If `records` is non-empty with `app` naming Claude, stop and report to the user: the hook mapping may be unnecessary. If it is empty, continue.

- [ ] **Step 2: Confirm the hook names and matchers** in the table against the hooks reference for the installed Claude Code version (`claude --version`; https://code.claude.com/docs/en/hooks). If an event or matcher name differs, use the documented one and note the change in the commit message.

- [ ] **Step 3: Write the fixtures.** `settings-existing.json` must contain: a top-level key with an empty array, a key with `null`, a non-Rextina `Stop` hook, and a non-Rextina `PreToolUse` hook with matcher `Bash`. `settings-invalid.json` is `{"hooks": `.

- [ ] **Step 4: Write the failing tests in `test/hooks_test.sh`**, each on a temp copy:

```sh
t_install_into_missing_file   # file created; jq '.hooks|keys|length' == 7
t_install_preserves_others    # jq 'del(.hooks)' equal before and after;
                              # foreign Stop and PreToolUse(Bash) hooks still present;
                              # empty array still [] and null still null in the raw output
t_install_idempotent          # install twice -> file identical to after first install
t_install_updates_bin_path    # install with --status-bin /a, then /b -> no "/a" left
t_uninstall_restores          # install then uninstall -> jq -S equal to the original fixture
t_uninstall_missing_file      # exit 0, file still absent
t_backup_written              # PATH.rextina.bak equals the pre-install content
t_invalid_json_refused        # exit 1, file bytes unchanged, no .rextina.bak
t_print_changes_nothing       # print -> valid JSON on stdout, file untouched
t_path_with_space             # --status-bin "/tmp/a b/rextina-status" -> the Stop command,
                              # run through sh -c with REXTINA_TTY set, writes state=done
```

- [ ] **Step 5: Run `make test`.** Expected: FAIL, `bin/rextina-hooks: not found`.

- [ ] **Step 6: Implement `bin/rextina-hooks`** with `jq`. Build the entries with `jq -n --arg bin ...` so the path is never interpolated into the filter text.

- [ ] **Step 7: Run `make test` and `make lint`.** Expected: all pass.

- [ ] **Step 8: Verify with a real agent (spec risk 1).** Run `bin/rextina-hooks install`. Ask the user to start `claude` directly in a new Rex tab and send a prompt that needs a permission approval. From another pane, read `program_status` for that block at each stage. Expected: `working` after the prompt, `blocked` with `kind=permission` at the approval, `working` after approving, `done` at the end, and no records after quitting. Also confirm the Rex tab header shows an indicator. If `blocked` never appears, the hook has no controlling terminal: confirm the `$PPID` fallback is reached (run the hook command by hand with `REXTINA_TTY` unset under `setsid`/`script`) and fix the reporter, adding a test for the case found.

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "add claude code hook installer"
```

---

### Task 3: Pure status logic

**Files:**
- Create: `lua/rextina_status.lua`, `test/run.lua`, `test/status_spec.lua`, `test/fixtures/view.json`

**Interfaces:**
- Produces: module `rextina_status`, returned as a table `M`:
  - `M.transition(entry, record, now, min_working) -> entry, event`
    - `entry`: `nil` or `{ state = string, working_since = number|nil }`. `record`: `nil` (removed) or a table with `state`. `now`: seconds. `min_working`: seconds.
    - `event`: `nil`, `"blocked"`, `"error"` or `"done"`.
    - Rules: same state as `entry.state` gives no event. `working` sets `working_since = now` unless the previous state was `working` or `blocked`, in which case it is kept. `blocked` and `error` always give their event. `done` gives `"done"` only when `working_since` is set and `now - working_since >= min_working`. `done`, `error`, `idle` and a `nil` record clear `working_since` in the returned entry. A `nil` record returns `nil, nil`.
  - `M.worked(entry, now) -> number|nil`: seconds since `working_since`.
  - `M.duration(seconds) -> string`: `45` gives `"45s"`, `252` gives `"4m 12s"`, `3725` gives `"1h 2m"`.
  - `M.text(info) -> title, subtitle, body`
    - `info`: `{ event, kind, msg, host, session, window, worked }`.
    - Titles: `blocked`+`permission` `"Claude needs approval"`; `blocked`+`question` `"Claude has a question"`; `blocked`+`auth` `"Claude needs sign-in"`; other `blocked` `"Claude is blocked"`; `done` `"Claude finished"`; `error` `"Claude failed"`.
    - Subtitle: `host › session › window`, omitting empty parts.
    - Body: for `done`, `"Worked for " .. M.duration(worked)`; otherwise `msg` or `""`.
  - `M.applescript(title, subtitle, body) -> string`: `display notification "BODY" with title "TITLE" subtitle "SUBTITLE"`, with `\` and `"` escaped and control characters replaced by a space.
  - `M.locate(view, block_id) -> { session_label, window_id, window_label, focused } | nil`: `view` is a decoded `session.view` result; `focused` is true when the block is the focused block of the session's active window.
  - `M.order(items) -> list`: keeps items whose `state` is `blocked`, `error` or `done`; sorts by that priority, then `updated_at` ascending, then `block_id`. Item: `{ host, session_id, window_id, block_id, state, updated_at }`; `host` is `nil` for the local server.
  - `M.next(ordered, current_block_id) -> item|nil`: the entry after the one whose `block_id` equals `current_block_id`, wrapping; the first entry when there is no match; `nil` for an empty list.
  - `M.root(records) -> record|nil`: the record with no `id` (absent or empty string).
- Produces: `test/run.lua`, run as `rex do test/run.lua root=ABS_PATH`. It prepends `root/lua/?.lua` and `root/test/?.lua` to `package.path`, provides globals `test(name, fn)` and `eq(expected, actual)` (deep comparison), requires every `*_spec` module listed in a table at the top of the file, prints one line per failure and a summary, and calls `rex.stop(1)` on any failure, `rex.stop(0)` otherwise.

- [ ] **Step 1: Capture the fixture.** Run `rex --autostart=false api call -s SESSION session.view > test/fixtures/view.json` against the live session, then read `rex api describe session.view` so `M.locate` matches the real field names. Replace working-directory paths and labels in the fixture with neutral values.

- [ ] **Step 2: Write `test/run.lua` and the failing tests in `test/status_spec.lua`**

```lua
test("blocked always notifies", function()
  local e, ev = S.transition(nil, { state = "blocked" }, 100, 30)
  eq("blocked", ev); eq("blocked", e.state)
end)
test("same state twice is silent", ...)            -- second blocked -> ev == nil
test("short turn done is silent", ...)             -- working@100, done@110, min 30 -> nil
test("long turn done notifies", ...)               -- working@100, done@140 -> "done"
test("approval does not reset the turn clock", ...) -- working@100, blocked@110, working@120, done@135 -> "done"
test("done without seeing the start is silent", ...) -- nil entry, done@500 -> nil
test("error notifies without a start", ...)        -- nil entry, error -> "error"
test("removed record clears the entry", ...)       -- transition(e, nil, ...) -> nil, nil
test("new turn after done restarts the clock", ...) -- done@140, working@200 -> working_since == 200
test("duration", ...)                              -- 45, 252, 3725 as above
test("text for each event", ...)                   -- the six titles; subtitle "fred › infra › deploy";
                                                   -- subtitle "infra" when host and window are nil
test("applescript escapes quotes and backslashes", ...)
  -- body [[say "hi" \ there]] -> contains [[say \"hi\" \\ there]]; a newline becomes a space
test("locate finds labels and focus in the fixture", ...)
test("locate returns nil for an unknown block", ...)
test("order filters and sorts", ...)               -- working and idle dropped; blocked before error before done; older first
test("next cycles and wraps", ...)                 -- [a,b,c]: nil->a, a->b, c->a, "zzz"->a; {} -> nil
test("root ignores child records", ...)            -- {{id="build",...},{state="done"}} -> the second
```

- [ ] **Step 3: Run `make test`.** Expected: FAIL, `module 'rextina_status' not found`.

- [ ] **Step 4: Implement `lua/rextina_status.lua`** to the signatures above.

- [ ] **Step 5: Run `make test` and `make lint`.** Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add -A && git commit -m "add status logic"
```

---

### Task 4: Watcher script and notifications

**Files:**
- Create: `lua/watch.lua`
- Modify: `test/run.lua` (spec list), `test/status_spec.lua` or a new `test/watch_spec.lua`

**Interfaces:**
- Consumes: `rextina_status` from Task 3.
- Produces: `lua/watch.lua`, run as `rex [-S HOST] do --all lua/watch.lua host=LABEL [min_working=30] [dry=true]`.
  - `host` is display text only; empty or absent for the local server.
  - Adds its own directory to `package.path` using `debug.getinfo(1, "S").source`, so `require("rextina_status")` works wherever it is installed.
  - Exposes, for tests, a function `handle(deps, state, ctx, ev)` returned from a small factory at the top of the file or placed in `rextina_status` as `M.handle`; choose the latter if `watch.lua` cannot be required without running. `deps` is `{ now = fn, view = fn(session_id), frontmost = fn(), notify = fn(title, subtitle, body) }`; `state` is a table keyed by `block_id` holding transition entries.
  - `handle` behaviour: ignore events whose `ev.id` is non-empty (child records). Run `transition`. On an event, call `deps.view`, then `M.locate`; skip when `locate(...).focused` and `deps.frontmost()` are both true; otherwise call `deps.notify(M.text{...})`. A failing `deps.view` (returns `nil`) still notifies, with session and window omitted.
  - Real `deps`: `view` is `rex.session.view{ session_id = id }`; `frontmost` runs `lsappinfo info -only name` on the result of `lsappinfo front` through `rex.exec` and is true when the name starts with `Rex`; `notify` runs `rex.exec({ "osascript", "-e", M.applescript(...) })`. With `dry=true`, `notify` calls `rex.log` instead.
  - Registers `rex.on("terminal.program_status_changed", ...)` passing `ev.record`, and `rex.on("terminal.program_status_removed", ...)` passing a `nil` record for the root when `ev.ids` contains the root or `ev.reason` clears the whole terminal. Read `rex api describe` output and one live `rex events -s SESSION --json` sample to confirm how the root id is represented in both events before coding this.
  - No more than one notification per block per 5 seconds.

- [ ] **Step 1: Capture one real event.** Run `rex --autostart=false events -s SESSION --json` in the background, run `make test-integration`, stop the stream, and save the `program_status_changed` and `program_status_removed` lines to `test/fixtures/events.jsonl`. Use them to settle the root-id representation.

- [ ] **Step 2: Write the failing tests** using fake `deps` that record calls:

```lua
test("blocked event notifies with labels from the view", ...)
  -- notify called once with "Claude needs approval", subtitle "fred › <session> › <window>", body "Needs approval"
test("child record is ignored", ...)                 -- ev.id = "build/test" -> notify not called
test("focused block with Rex frontmost is silent", ...)
test("focused block with another app frontmost notifies", ...)
test("view failure still notifies", ...)             -- deps.view returns nil -> subtitle is the host only
test("repeat within 5 seconds is dropped", ...)      -- blocked, working, blocked at now+2 -> one notify
test("done after a long turn reports the duration", ...) -- body "Worked for 1m 0s"
test("removed root record then done is silent", ...)
```

- [ ] **Step 3: Run `make test`.** Expected: FAIL on the new tests.

- [ ] **Step 4: Implement `handle` and `lua/watch.lua`.**

- [ ] **Step 5: Run `make test` and `make lint`.** Expected: all pass.

- [ ] **Step 6: Verify live.** Start `rex do --all lua/watch.lua dry=true min_working=0` in one pane, run `make test-integration` in another. Expected: one log line with the `blocked` title. Then run once without `dry=true` and confirm a macOS notification appears; if macOS asks to allow notifications for the script host, tell the user.

- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "add watcher"
```

---

### Task 5: Watcher supervisor, LaunchAgent and install

**Files:**
- Create: `bin/rextina-watch`, `test/watch_test.sh`, `test/fixtures/fake-rex`, `launchd/com.rextina.watch.plist.in`
- Modify: `Makefile`

**Interfaces:**
- Consumes: `lua/watch.lua` from Task 4, `bin/rextina-hooks` from Task 2.
- Produces: `bin/rextina-watch [--once]`
  - Reads hosts from `$REXTINA_REX hosts --json` (confirm the JSON shape with the live command first).
  - Always starts a watcher for the local server (no `-S`, `host=` empty). Skips a stored host that is the local server, compared by the server identity field in `server.status` (confirm the field name with `rex api call server.status`). A host whose status cannot be fetched is not skipped.
  - Each watcher runs in its own loop: `$REXTINA_REX [-S LABEL] do --all WATCH_LUA host=LABEL min_working=$REXTINA_MIN_WORKING`. On exit it sleeps then restarts. Backoff starts at 5 seconds, doubles to a cap of 300, and resets to 5 after a run of at least 60 seconds. `REXTINA_BACKOFF_MIN` and `REXTINA_BACKOFF_MAX` override the two bounds for tests.
  - `WATCH_LUA` is `watch.lua` beside the script's `../lua/`, overridable with `REXTINA_WATCH_LUA`.
  - On `TERM` or `INT` it stops every child and exits 0. `--once` starts each watcher a single time with no restart, then waits.
  - The host list is read once at start; adding a host needs a restart of the agent.
- Produces: `make install`
  - Copies `bin/*` and `lua/watch.lua`, `lua/rextina_status.lua` to `~/.local/share/rextina/` keeping the `bin/` and `lua/` layout.
  - Copies `lua/rextina.lua` and `lua/rextina_status.lua` to `${XDG_CONFIG_HOME:-~/.config}/rex/`.
  - Appends `require("rextina")` to `init.lua` there if no line contains it, creating the file if absent; then runs `rex config check`.
  - Runs `~/.local/share/rextina/bin/rextina-hooks install`.
  - On Darwin only: renders the plist with the absolute path from `command -v rex` as `REXTINA_REX` and `~/Library/Logs/rextina-watch.log` for stdout and stderr, writes `~/Library/LaunchAgents/com.rextina.watch.plist`, and (re)loads it with `launchctl bootout` then `launchctl bootstrap gui/$(id -u)`.
- Produces: `make uninstall` reversing each of those, leaving `init.lua` otherwise intact.

`make install` depends on `lua/rextina.lua`, which Task 6 creates. In this task, write the target in full and verify it after Task 6; verify the supervisor and plist now with `make install-watch`, a sub-target that does only the `~/.local/share/rextina` copy and the LaunchAgent.

- [ ] **Step 1: Write `test/fixtures/fake-rex`**, a shell script that appends its arguments as one line to `$FAKE_REX_LOG`, prints canned JSON for `hosts --json` (two hosts, `alpha` and `beta`) and for `api call server.status` (identity `local` with no `-S`, `local` for `-S alpha`, exit 1 for `-S beta`), and for `do` exits immediately with status 1.

- [ ] **Step 2: Write the failing tests in `test/watch_test.sh`** with `REXTINA_REX` set to the fake and `REXTINA_BACKOFF_MIN=1 REXTINA_BACKOFF_MAX=2`:

```sh
t_once_starts_local_and_remote   # --once: log has one "do --all" with no -S and one with "-S beta"
t_skips_host_that_is_local       # no "do" line with "-S alpha"
t_unreachable_host_still_watched # beta's status call fails, yet "-S beta do" is present
t_restarts_after_exit            # without --once, after 4 seconds the log has >= 2 "do" lines per target
t_term_stops_children            # send TERM; within 2 seconds no child processes remain, exit 0
t_passes_min_working             # REXTINA_MIN_WORKING=45 -> "min_working=45" in the do line
```

- [ ] **Step 3: Run `make test`.** Expected: FAIL, `bin/rextina-watch: not found`.

- [ ] **Step 4: Implement `bin/rextina-watch`.**

- [ ] **Step 5: Write the plist template and the `Makefile` targets.**

- [ ] **Step 6: Run `make test` and `make lint`,** then `plutil -lint` on a rendered plist. Expected: all pass.

- [ ] **Step 7: Verify live.** Run `make install-watch`. Expected: `launchctl print gui/$(id -u)/com.rextina.watch` shows it running; `~/Library/Logs/rextina-watch.log` shows one watcher per target, with unreachable hosts retrying and the local one staying up. Run `make test-integration`. The test tab reports `blocked` and is unfocused, so a notification is expected. Confirm exactly one appears, not one per watcher.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "add watcher supervisor and install"
```

---

### Task 6: Jump action

**Files:**
- Create: `lua/rextina.lua`, `test/next_spec.lua`
- Modify: `test/run.lua` (spec list)

**Interfaces:**
- Consumes: `rextina_status` (`order`, `next`, `root`, `locate`).
- Produces: module `rextina`, loaded by `require("rextina")`:
  - `M.collect(api, host) -> items`: `api` is a table with `call(method, args)` returning a result or `nil, err`. It calls `session.list`, then per session `session.view` and, per terminal block, the terminal's `program_status` through `block.method` (confirm the argument shape with `rex api describe block.method`). It returns one item per block with a root record, shaped as in Task 3's `order`. Any failing call skips that session or block; a failing `session.list` returns `{}`.
  - `M.find_next(apis, current_block_id) -> item|nil`: `apis` is a list of `{ host = label|nil, api = table }`; concatenates `collect` over all, then `order` and `next`.
  - `M.go(item, apis, queue)`: calls `session.focus_block` on the item's server and then `queue("session.select", { session_id = item.session_id, window_id = item.window_id })`.
  - Registers the action when `rex.action` exists:
    `name = "rextina_next"`, `title = "Go to Next Agent Needing Attention"`, `category = "Rextina"`, `keywords = "agent claude blocked done attention jump next"`. `run(ctx)` builds `apis` from `rex` itself (host `nil`) and each label in `rex.servers()` via `rex.server(label)`, calls `find_next` with `ctx.block_id`, and `go` with `rex.client.queue`. It returns `{ host, session_id, window_id, block_id, state }` for the target, or `{ none = true }`.
  - Binds no key.

- [ ] **Step 1: Write the failing tests in `test/next_spec.lua`** with fake `api` tables built from the Task 3 fixture:

```lua
test("collect returns one item per block with a root record", ...)
test("collect skips a block whose status call fails", ...)
test("collect returns {} when session.list fails", ...)       -- the unreachable-host case
test("find_next merges hosts and prefers blocked over done", ...)
  -- local has a done block, host "fred" has a blocked block -> item.host == "fred"
test("find_next still answers when one host is unreachable", ...)
test("find_next cycles from the current block", ...)
test("find_next returns nil when nobody is waiting", ...)
test("go focuses on the item's server and queues session.select", ...)
  -- fake apis record calls: focus_block on fred's api only; queue called with the item's session_id and window_id
```

- [ ] **Step 2: Run `make test`.** Expected: FAIL, `module 'rextina' not found`.

- [ ] **Step 3: Implement `lua/rextina.lua`.**

- [ ] **Step 4: Run `make test` and `make lint`.** Expected: all pass.

- [ ] **Step 5: Verify the action locally.** Start the integration test's blocked tab by hand (the `rex run` line from `test/integration.sh` with `sleep 60`), then run `rex do lua/rextina.lua --action rextina_next --json`. Expected: the result names that block with `state` `blocked`, and the Rex app switches to the `rextina-test` tab. Run it again with no waiting agent. Expected: `{"none":true}`. Close the test tab.

- [ ] **Step 6: Run `make install`,** then `rex config check` and `rex actions`. Expected: no warnings from the config, and `rextina_next` listed. Confirm `~/.claude/settings.json` hooks now point at `~/.local/share/rextina/bin/rextina-status`.

- [ ] **Step 7: Measure the action with an unreachable host.** With `clu` and `fred` unreachable, time `rex do rextina_next`. If it takes more than 3 seconds, give remote scans a shorter limit or skip hosts that fail a first `server.status` call, add a test for the chosen rule, and re-measure.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "add jump action"
```

---

### Task 7: Cross-host check and README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: everything above, installed.

- [ ] **Step 1: Cross-host verification (spec risk 4).** This needs `clu` or `fred` reachable; ask the user to bring one up and run `make install` there (on Linux this installs the reporter and hooks only). With an agent blocked on the remote host and the Mac app viewing the local host, confirm: the Mac gets one notification naming the remote host; `rex do rextina_next` returns the remote block; and whether the app actually shows it. If the app does not switch hosts, change `M.go` so that for an item whose host differs from the local server it skips `session.select` and the action result carries `needs_host_switch = true` with the host label, add a test for that, and record the limit in the README. If no remote host can be reached, leave the code as is and record the behaviour as unverified in the README.

- [ ] **Step 2: Check the native sidebar across hosts.** With a remote host reachable, note whether the Rex sidebar lists sessions from all hosts at once or one host at a time, and record the answer in the README. This decides whether the spec's option 2 is worth revisiting.

- [ ] **Step 3: Write `README.md`** covering: what Rextina adds to Rex and what it leaves to Rex; requirements (`jq`, Rex, Claude Code); `make install` and `make uninstall` on the Mac and on a server-only Linux machine; binding a key, with this example:

```lua
rex.bind("cmd+shift+a", "rextina_next")
```

`REXTINA_MIN_WORKING`; where the watcher log is; and these limits: agents inside herdr or tmux in a Rex pane report nothing; interrupting Claude Code with Esc leaves `working` showing until the next prompt or exit, because no hook fires; clicking a notification does not jump; adding a host needs `launchctl kickstart -k gui/$(id -u)/com.rextina.watch`; the results of steps 1 and 2.

- [ ] **Step 4: Run `make lint` and `make test`.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "add readme"
```
