#!/bin/sh
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/test/lib.sh"

bin="$root/bin/rextina-init"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
line='require("rextina")'

f="$tmp/missing/init.lua"
mkdir -p "$tmp/missing"
"$bin" add "$f"
assert_eq "$line" "$(cat "$f")" t_add_creates_file

f="$tmp/plain.lua"
printf 'rex.bind("a", "b")\n' > "$f"
cp "$f" "$tmp/plain.orig"
"$bin" add "$f"
"$bin" add "$f"
assert_eq "1" "$(grep -cxF "$line" "$f")" t_add_twice_adds_one_line
"$bin" remove "$f"
assert_eq "$(od -c "$tmp/plain.orig")" "$(od -c "$f")" t_remove_restores_original

f="$tmp/nonewline.lua"
printf 'rex.bind("a", "b")' > "$f"
"$bin" add "$f"
assert_eq 'rex.bind("a", "b")' "$(sed -n 1p "$f")" t_add_keeps_last_line_intact
assert_eq "$line" "$(sed -n 2p "$f")" t_add_after_missing_newline

f="$tmp/comment.lua"
printf -- '-- require("rextina")' > "$f"
"$bin" add "$f"
assert_eq "1" "$(grep -cxF "$line" "$f")" t_commented_require_does_not_count
"$bin" remove "$f"
assert_eq '-- require("rextina")' "$(cat "$f")" t_remove_keeps_comment

printf 'x = 1\n' > "$tmp/real.lua"
ln -s "$tmp/real.lua" "$tmp/link.lua"
"$bin" add "$tmp/link.lua"
"$bin" remove "$tmp/link.lua"
assert_eq "yes" "$([ -L "$tmp/link.lua" ] && echo yes || echo no)" t_symlink_survives
assert_eq "x = 1" "$(cat "$tmp/real.lua")" t_symlink_target_restored

"$bin" remove "$tmp/never-existed.lua"
assert_eq "0" "$?" t_remove_missing_file
assert_file_absent "$tmp/never-existed.lua" t_remove_does_not_create

f="$tmp/mode.lua"
printf 'x = 1\n' > "$f"
chmod 600 "$f"
"$bin" add "$f"
"$bin" remove "$f"
assert_eq "$f" "$(find "$f" -perm 600)" t_mode_preserved

finish
