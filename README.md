# Rextina

Agent attention for stock [Rex](https://www.superlogical.com/rex/docs). Nothing in Rex is modified.

Rex already shows which programs are working, blocked or done in its sidebar, tab headers and Activity view (`cmd+.`), and Claude Code reports its own state to Rex. Rextina adds the two things that are missing:

- **Notifications.** A macOS notification when an agent on this Mac or on any stored host becomes blocked, fails, or finishes a turn that ran for at least 30 seconds.
- **A jump action.** `rextina_next` goes to the agent that most needs you: blocked first, then failed, then done, oldest first. Repeated use cycles through them.

## Requirements

- Rex, with the `rex` command on your `PATH`
- macOS for notifications and the action
- `jq` (at `/usr/bin/jq` on current macOS)
- Claude Code 2.1.311 or later, run directly in a Rex pane

## Install

```sh
make install
```

This does three things:

1. Copies the scripts to `~/.local/share/rextina`.
2. Installs and starts the LaunchAgent `com.rextina.watch`, which runs one watcher for the local server and one per host from `rex hosts`.
3. Copies `rextina.lua` and `rextina_status.lua` to `~/.config/rex` and adds `require("rextina")` to `init.lua`.

`make uninstall` reverses all three and leaves the rest of `init.lua` alone.

A machine that only runs a Rex server, such as a Linux box, needs nothing installed. Claude Code reports to the Rex server it runs in, and the Mac's watcher hears it over the host connection.

## Bind a key

No key is bound by default. Add one to `~/.config/rex/init.lua`:

```lua
rex.bind("cmd+shift+a", "rextina_next")
```

The action is also in the command palette as "Go to Next Agent Needing Attention", and runs from a shell with `rex do rextina_next`.

## Settings

| Setting | Default | How to change |
|---|---|---|
| Shortest turn that notifies when done | 30 seconds | `make install REXTINA_MIN_WORKING=120` |
| Watcher log | `~/Library/Logs/rextina-watch.log` | `make install WATCH_LOG=/path` |

After adding or removing a host, restart the watcher:

```sh
launchctl kickstart -k gui/$(id -u)/com.rextina.watch
```

## Reporting status from your own scripts

`bin/rextina-status` writes one OSC 7501 report to the terminal it runs in. Any script can use it to show up in Rex and in Rextina's notifications:

```sh
rextina-status --app deploy working - "Deploying"
rextina-status --app deploy blocked permission "Approve production deploy?"
rextina-status --app deploy done - "Deployed"
```

It does nothing outside a Rex terminal.

## Limits

- An agent inside herdr or tmux inside a Rex pane reports nothing, because the inner multiplexer swallows the status sequence.
- No notification is raised when Rex is the frontmost app and the agent's pane is the focused pane of its session's active tab.
- A `done` is announced only if the watcher saw the turn start. Turns in progress when the watcher starts are not announced.
- Clicking a notification does not jump to the agent. Use `rextina_next`.
- Notification titles say "Claude" for every program that reports status.

## Not yet verified

No remote host was reachable while this was built, so these are untested:

- Notifications for agents on a remote host.
- Whether `rextina_next` can make the app show a session on a host other than the one it is viewing.
- How long `rextina_next` takes when a host resolves but does not answer. With hosts that fail to resolve it took under 50 ms.
- Whether the Rex sidebar lists sessions from all hosts at once.

## Development

```sh
make test              # shell tests and Lua tests (Lua runs under `rex do`)
make test-integration  # opens a background tab in a live Rex session and closes it
make lint              # shellcheck
```

Design and plan are in `docs/`.
