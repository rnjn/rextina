#!/bin/sh
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/test/lib.sh"

bin="$root/bin/rextina-status"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
out="$tmp/tty"

run() {
  : > "$out"
  REX_BLOCK=b REXTINA_TTY="$out" "$bin" "$@"
}

hex() {
  od -An -tx1 "$1" | tr -d ' \n'
}

expect_bytes() {
  printf '%b' "$1" > "$tmp/expected"
  assert_eq "$(hex "$tmp/expected")" "$(hex "$out")" "$2"
}

decoded_msg() {
  sed -n 's/.*msg=\([A-Za-z0-9+\/=]*\).*/\1/p' "$out" | base64 -d
}

run blocked permission "Needs approval"
expect_bytes '\033]7501;state=blocked:kind=permission:app=claude-code:msg=TmVlZHMgYXBwcm92YWw=\033\0134' t_blocked_permission

run working
expect_bytes '\033]7501;state=working:app=claude-code\033\0134' t_working_no_message

run "done" permission "x"
assert_not_contains "$(cat "$out")" "kind=" t_kind_ignored_unless_blocked
assert_contains "$(cat "$out")" "state=done" t_kind_ignored_unless_blocked_state

run blocked - "Q"
assert_not_contains "$(cat "$out")" "kind=" t_kind_dash
assert_eq "Q" "$(decoded_msg)" t_kind_dash_msg

run clear
expect_bytes '\033]7501;state=clear\033\0134' t_clear

run --app codex idle
assert_contains "$(cat "$out")" "app=codex" t_app_option

run bogus
assert_eq "0" "$?" t_unknown_state_exit
assert_eq "" "$(hex "$out")" t_unknown_state

: > "$out"
env -u REX_BLOCK REXTINA_TTY="$out" "$bin" working
assert_eq "0" "$?" t_no_rex_block_exit
assert_eq "" "$(hex "$out")" t_no_rex_block

err=$(REX_BLOCK=b REXTINA_TTY=/nonexistent/dir/x "$bin" working 2>&1)
assert_eq "0" "$?" t_unwritable_target_exit
assert_eq "" "$err" t_unwritable_target_stderr

run blocked question "$(printf 'a"b\\c\nd\t\303\251')"
assert_eq "$(printf 'a"b\\c d \303\251')" "$(decoded_msg)" t_message_sanitised

long=$(awk 'BEGIN { for (i = 0; i < 5000; i++) printf "x" }')
run working - "$long"
assert_eq "200" "$(decoded_msg | wc -c | tr -d ' ')" t_message_truncated

edge=$(awk 'BEGIN { for (i = 0; i < 199; i++) printf "a" }')
run working - "$(printf '%s\303\251tail' "$edge")"
assert_eq "$edge" "$(decoded_msg)" t_message_truncated_multibyte

run --app 'bad app!' idle
assert_not_contains "$(cat "$out")" "app=" t_invalid_app
assert_contains "$(cat "$out")" "state=idle" t_invalid_app_state

if command -v script > /dev/null 2>&1; then
  if [ "$(uname)" = Darwin ]; then
    script -q "$tmp/pty" env -u REXTINA_TTY REX_BLOCK=b "$bin" working < /dev/null > /dev/null 2>&1
  else
    script -qc "env -u REXTINA_TTY REX_BLOCK=b '$bin' working" "$tmp/pty" < /dev/null > /dev/null 2>&1
  fi
  assert_contains "$(tr -d '\033' < "$tmp/pty")" "]7501;state=working:app=claude-code" t_writes_to_controlling_terminal
fi

finish
