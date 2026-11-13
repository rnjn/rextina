# Rextina

Agent attention for stock [Rex](https://www.superlogical.com/rex/docs). Nothing in Rex is modified.

Rex already shows which programs are working, blocked or done in its sidebar, tab headers and Activity view (`cmd+.`), and Claude Code reports its own state to Rex when it runs directly in a Rex pane. That covers the indicator. Rextina adds:

- **A jump action.** `rextina_next` goes to the agent on this Mac that most needs you: blocked first, then failed, then done, oldest first. Repeated use cycles through them.
- **Optional banners.** A macOS notification when an agent on this Mac or on any stored host becomes blocked, fails, or finishes a turn that ran for at least 30 seconds. Off unless you install the watcher.

## Requirements

- Rex. `make` finds `rex` on your `PATH` or in the Mac app's default location; otherwise pass `REXTINA_REX=/path/to/rex`
- macOS
- `jq`, for the optional watcher only (at `/usr/bin/jq` on current macOS)
- Claude Code 2.1.311 or later, run directly in a Rex pane

## Install

```sh
make install
```

This copies `rextina.lua` and `rextina_status.lua` to `~/.config/rex` and adds `require("rextina")` to `init.lua`. `make uninstall` reverses it and leaves the rest of `init.lua` alone.

A machine that only runs a Rex server, such as a Linux box, needs nothing installed. Claude Code reports to the Rex server it runs in, and the Mac app shows it.

## Bind a key

No key is bound by default. Add one to `~/.config/rex/init.lua`:

```lua
rex.bind("cmd+shift+a", "rextina_next")
```

The action is also in the command palette as "Go to Next Agent Needing Attention", and runs from a shell with `rex do rextina_next`.

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
- `rextina_next` only sees agents on the Rex server that runs it, which on your Mac means local agents. Actions in `init.lua` get no host list from Rex, and the app does not switch hosts when asked to show a remote session. For an agent on another host, find it in the sidebar, which lists every host.
- Banner titles say "Claude" for every program that reports status.

## Development

```sh
make test              # shell tests and Lua tests (Lua runs under `rex do`)
make test-integration  # opens a background tab in a live Rex session and closes it
make lint              # shellcheck
```

Design and plan are in `docs/`.
