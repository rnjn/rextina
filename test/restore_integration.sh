#!/bin/sh
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/test/lib.sh"

rex=${REXTINA_REX:-rex}
r() {
  "$rex" --autostart=false "$@"
}

if ! r ls > /dev/null 2>&1; then
  echo "SKIP no rex session"
  exit 0
fi

tmp=$(mktemp -d)
tmp=$(cd "$tmp" && pwd -P)
state="$tmp/saves"
mkdir -p "$tmp/a" "$tmp/b" "$tmp/c"

test_sessions() {
  r ls --json | jq -r '.. | objects | select(.session_id? and (.label? // "" | startswith("rextina-test"))) | .session_id'
}

trap 'test_sessions | xargs -n 1 "$rex" --autostart=false kill > /dev/null 2>&1; rm -rf "$tmp"' EXIT

shape() {
  r api call -s "$1" session.view |
    jq -c '[.windows[] | {label: (if (.label | test("^Window ")) then null else .label end), layout: (.layers[0].layout | walk(if type == "object" then del(.rect, .split_id, .block_id) else . end))}]'
}

cwds() {
  for b in $(r api call -s "$1" session.view | jq -r '.windows[].layers[0].blocks[].block_id'); do
    r block call -s "$1" -b "$b" process | jq -r '.foreground.cwd'
  done | tr '\n' ' '
}

ses=$(r new rextina-test-rt -c "$tmp/a" --json | jq -r '.session_id')
first=$(r window new -s "$ses" rextina-test-tab -c "$tmp/a" --focus=false --json | jq -r '.block_ids[0]')
r split -s "$ses" -b "$first" --split=right -c "$tmp/c" --focus=false --json > /dev/null
r split -s "$ses" -b "$first" --split=below -c "$tmp/b" --focus=false --json > /dev/null
r focus -s "$ses" 2 > /dev/null
sleep 2
before_shape=$(shape "$ses")
before_cwds=$(cwds "$ses")
assert_eq "$tmp/a $tmp/a $tmp/b $tmp/c " "$before_cwds" rt_setup_cwds

r "do" "$root/lua/save.lua" "dir=$state"
saved=$(ls "$state"/*.json)
jq '.instance_id = "previous" | .sessions |= map(select(.label == "rextina-test-rt"))' "$saved" > "$state/previous.json"
rm -f "$saved"
assert_eq "1" "$(jq '.sessions | length' "$state/previous.json")" rt_save_has_test_session

r kill "$ses" > /dev/null
assert_eq "" "$(test_sessions)" rt_session_destroyed

cat > "$tmp/restore.lua" << LUA
package.path = "$root/lua/?.lua;" .. package.path
return require("rextina").restore_action(rex, { dir = rex.args.dir, save = rex.args.save })
LUA

report=$(r "do" "$tmp/restore.lua" "dir=$state" save=previous --json)
assert_eq "true" "$(printf '%s' "$report" | jq -r '.complete')" rt_report_complete
assert_eq "2" "$(printf '%s' "$report" | jq -r '.sessions[0].tabs')" rt_report_tabs
assert_eq "4" "$(printf '%s' "$report" | jq -r '.sessions[0].panes')" rt_report_panes

restored=$(test_sessions)
assert_eq "1" "$(printf '%s\n' "$restored" | grep -c .)" rt_one_session_restored
sleep 3
assert_eq "$before_shape" "$(shape "$restored")" rt_layout_matches
assert_eq "$before_cwds" "$(cwds "$restored")" rt_cwds_match
view=$(r api call -s "$restored" session.view)
assert_eq "rextina-test-rt" "$(printf '%s' "$view" | jq -r '.label')" rt_session_label
assert_eq "rextina-test-tab" "$(printf '%s' "$view" | jq -r '.active_window_id as $a | .windows[] | select(.window_id == $a) | .label')" rt_active_tab
assert_eq "true" "$(jq -r '.closed_at != null' "$state/previous.json")" rt_save_closed

again=$(r "do" "$tmp/restore.lua" "dir=$state" --json)
assert_eq "closed" "$(printf '%s' "$again" | jq -r '.reason')" rt_second_press_reason
assert_eq "1" "$(test_sessions | grep -c .)" rt_second_press_creates_nothing

finish
