#!/bin/sh
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/test/lib.sh"

bin="$root/bin/rextina-save"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export REXTINA_REX="$root/test/fixtures/fake-rex"
export FAKE_REX_LOG="$tmp/rex.log"

out=$(FAKE_REX_DO_OK=1 "$bin" 2>&1)
assert_eq "0" "$?" t_ok_exit
assert_eq "" "$out" t_ok_silent
assert_contains "$(cat "$FAKE_REX_LOG")" "--autostart=false do $root/bin/../lua/save.lua" t_runs_save_without_autostart

out=$(FAKE_REX_DO_ERR="Error: no Rex server is running at /x, and autostart is disabled" "$bin" 2>&1)
assert_eq "0" "$?" t_no_server_exit
assert_eq "" "$out" t_no_server_silent

out=$(FAKE_REX_DO_ERR="Error: something else broke" "$bin" 2>&1)
assert_eq "0" "$?" t_other_error_exit
assert_contains "$out" "something else broke" t_other_error_logged

out=$(FAKE_REX_DO_OK=1 FAKE_REX_DO_OUT="warn: rextina save failed: disk full" "$bin" 2>&1)
assert_contains "$out" "disk full" t_warning_logged

finish
