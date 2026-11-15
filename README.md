# Rextina

Agent attention for stock [Rex](https://www.superlogical.com/rex/docs). Nothing in Rex is modified.

Rex already shows which programs are working, blocked or done in its sidebar, tab headers and Activity view (`cmd+.`), and Claude Code reports its own state to Rex when it runs directly in a Rex pane. That covers the indicator. Rextina adds:

- **A jump action.** `rextina_next` goes to the agent on this Mac that most needs you: blocked first, then failed, then done, oldest first. Repeated use cycles through them. A finished agent is offered once; after the shortcut has taken you to it, it is skipped until it finishes another turn.
- **Session restore.** Rex loses every session when its server restarts, which every Rex upgrade requires. Rextina saves your sessions once a minute and rebuilds them on request, with Claude Code conversations resumed.
- **Optional banners.** A macOS notification when an agent on this Mac or on any stored host becomes blocked, fails, or finishes a turn that ran for at least 30 seconds. Off unless you install the watcher.

## Requirements

- Rex. `make` finds `rex` on your `PATH` or in the Mac app's default location; otherwise pass `REXTINA_REX=/path/to/rex`
- macOS
- `jq`, for the optional banner watcher and the integration tests only (at `/usr/bin/jq` on current macOS)
- Claude Code 2.1.311 or later, run directly in a Rex pane

## Install

```sh
make install
```

This does two things:

1. Copies the Lua modules to `~/.config/rex` and adds `require("rextina")` to `init.lua`, unless it is already loaded there.
2. Installs the LaunchAgent `com.rextina.save`, which saves your sessions every 60 seconds.

`make uninstall` reverses both, leaves the rest of `init.lua` alone, and keeps the save files.

A machine that only runs a Rex server, such as a Linux box, needs nothing installed. Claude Code reports to the Rex server it runs in, and the Mac app shows it.

## Bind a key

No key is bound by default. Add one to `~/.config/rex/init.lua`:

```lua
rex.bind("cmd+shift+a", "rextina_next")
```

The action is also in the command palette as "Go to Next Agent Needing Attention", and runs from a shell with `rex do rextina_next`.

## Restore after a restart

Three actions, all in the command palette under "Rextina":

| Action | Name | What it does |
|---|---|---|
| Restore Sessions | `rextina_restore` | Rebuilds the sessions from the last save taken before the current server started |
| Save Sessions and Restart Server… | `rextina_save_restart` | Takes a fresh save, then runs Rex's own "Restart Server…", which asks for confirmation |
| List Session Saves | `rextina_saves` | Lists the saves and whether each is `running`, `open`, `closed` or `trivial` |

What comes back: sessions with their labels, tabs in order, splits with their ratios, tab and pane labels you chose, each pane's working directory, the active tab, and Claude Code conversations. A pane that was running Claude Code gets `claude --resume <id>` typed into a fresh shell.

What does not: running processes, scrollback, other programs such as editors and dev servers, floating panes, and zoom. Claude Code is resumed without any flags it was started with.

How it behaves:

- Nothing is restored unless you run the action.
- The session Rex creates after a restart is left alone; restored sessions appear beside it.
- Restore uses the newest save from an earlier server run and skips a save that is only one empty shell, so two restarts in a row do not lose the real layout.
- Running it twice does nothing the second time. To restore an older or already-restored save, name it: `rex do rextina_restore save=<instance id>`, with the id from `rex do rextina_saves`.
- If one session fails to rebuild, the others are still restored, and running the action again rebuilds only the one that failed.
- A saved directory that no longer exists opens in your home directory.

Saves live in `~/.local/state/rextina/saves`, one file per server run, newest five kept, readable only by you. They contain directory paths and Claude Code conversation ids, not terminal contents. The save log is `~/Library/Logs/rextina-save.log` and is normally empty.

To bind keys, add to `~/.config/rex/init.lua`:

```lua
rex.bind("cmd+shift+r", "rextina_restore")
```

`make uninstall-save` stops the every-minute save and keeps the files. Saving and restoring are per machine: install on each Mac whose sessions you want back. A Linux server is not covered yet, because the every-minute trigger is a macOS LaunchAgent.

The conversation id is read from `~/.claude/sessions/<pid>.json`, a file Claude Code maintains for its own use and does not document. If a Claude Code update changes it, panes come back as plain shells until Rextina is updated.

A real server restart has not been tested yet; the round trip is tested by saving, destroying and rebuilding a test session on a live server.

## Banners (optional)

```sh
make install-watch     # copy scripts to ~/.local/share/rextina and start the LaunchAgent com.rextina.watch
make uninstall-watch   # stop and remove it
```

The LaunchAgent runs one watcher for the local server and one per host from `rex hosts`. Clicking a banner does nothing; it only tells you which host, session and tab to look at.

| Setting | Default | How to change |
|---|---|---|
| Shortest turn that notifies when done | 30 seconds | `make install-watch REXTINA_MIN_WORKING=120` |
| Watcher log | `~/Library/Logs/rextina-watch.log` | `make install-watch WATCH_LOG=/path` |

After adding or removing a host, restart the watcher:

```sh
launchctl kickstart -k gui/$(id -u)/com.rextina.watch
```

## Reporting status from your own scripts

`bin/rextina-status` writes one OSC 7501 report to the terminal it runs in. Any script can use it to show up in Rex's sidebar, in `rextina_next`, and in the banners:

```sh
rextina-status --app deploy working - "Deploying"
rextina-status --app deploy blocked permission "Approve production deploy?"
rextina-status --app deploy done - "Deployed"
```

It does nothing outside a Rex terminal.

## Limits

- An agent inside herdr or tmux inside a Rex pane reports nothing, because the inner multiplexer swallows the status sequence.
- No banner is raised when Rex is the frontmost app and the agent's pane is the focused pane of its session's active tab.
- A `done` banner is raised only if the watcher saw the turn start.
- `rextina_next` remembers which finished agents it has shown you in memory only. A config reload or server restart clears that, and each finished agent is offered once more.
- `rextina_next` only sees agents on the Rex server that runs it, which on your Mac means local agents. Actions in `init.lua` get no host list from Rex, and the app does not switch hosts when asked to show a remote session. For an agent on another host, find it in the sidebar, which lists every host.
- Banner titles say "Claude" for every program that reports status.

## Development

```sh
make test              # shell tests and Lua tests (Lua runs under `rex do`)
make test-integration  # opens a background tab in a live Rex session and closes it
make lint              # shellcheck
```

Design and plan are in `docs/`.
