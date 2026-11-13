#!/bin/sh
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/test/lib.sh"

bin="$root/bin/rextina-watch"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export REXTINA_REX="$root/test/fixtures/fake-rex"
export REXTINA_WATCH_LUA=/opt/watch.lua
export REXTINA_BACKOFF_MIN=1
export REXTINA_BACKOFF_MAX=2

do_lines() {
  grep ' do --all ' "$1" || true
}

export FAKE_REX_LOG="$tmp/once.log"
REXTINA_MIN_WORKING=45 "$bin" --once
assert_eq "0" "$?" t_once_exit
lines=$(do_lines "$FAKE_REX_LOG")
assert_eq "2" "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" t_once_starts_local_and_remote_count
assert_contains "$lines" "-S beta do --all /opt/watch.lua host=beta" t_unreachable_host_still_watched
assert_not_contains "$lines" "-S alpha" t_skips_host_that_is_local
assert_eq "1" "$(printf '%s\n' "$lines" | grep -vc -e '-S ')" t_once_starts_local
assert_contains "$lines" "min_working=45" t_passes_min_working

export FAKE_REX_LOG="$tmp/loop.log"
"$bin" &
pid=$!
sleep 4
kill -TERM "$pid"
wait "$pid"
assert_eq "0" "$?" t_restart_term_exit
lines=$(do_lines "$FAKE_REX_LOG")
local_runs=$(printf '%s\n' "$lines" | grep -vc -e '-S ')
beta_runs=$(printf '%s\n' "$lines" | grep -c -e '-S beta')
assert_eq "yes" "$([ "$local_runs" -ge 2 ] && echo yes || echo "no:$local_runs")" t_restarts_after_exit_local
assert_eq "yes" "$([ "$beta_runs" -ge 2 ] && echo yes || echo "no:$beta_runs")" t_restarts_after_exit_remote

export FAKE_REX_LOG="$tmp/term.log"
FAKE_REX_DO_SLEEP=7777 "$bin" &
pid=$!
sleep 2
assert_eq "2" "$(pgrep -f 'sleep 7777' | wc -l | tr -d ' ')" t_term_children_running
kill -TERM "$pid"
wait "$pid"
assert_eq "0" "$?" t_term_exit
sleep 1
assert_eq "0" "$(pgrep -f 'sleep 7777' | wc -l | tr -d ' ')" t_term_stops_children

export FAKE_REX_LOG="$tmp/flip.log"
export FAKE_REX_BETA_LOCAL="$tmp/beta-is-local"
"$bin" &
pid=$!
sleep 2
touch "$FAKE_REX_BETA_LOCAL"
sleep 3
before=$(do_lines "$FAKE_REX_LOG" | grep -c -e '-S beta')
sleep 4
after=$(do_lines "$FAKE_REX_LOG" | grep -c -e '-S beta')
kill -TERM "$pid"
wait "$pid"
assert_eq "$before" "$after" t_host_that_turns_out_local_is_dropped
unset FAKE_REX_BETA_LOCAL

finish
