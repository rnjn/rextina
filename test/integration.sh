#!/bin/sh
root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/test/lib.sh"

rex=${REXTINA_REX:-rex}
ses=$("$rex" --autostart=false ls --json 2>/dev/null | jq -r '[.. | .session_id? // empty][0] // empty')
if [ -z "$ses" ]; then
  echo "SKIP no rex session"
  exit 0
fi

window=
trap '[ -n "$window" ] && "$rex" --autostart=false window close -s "$ses" "$window" > /dev/null 2>&1' EXIT

out=$("$rex" --autostart=false run -s "$ses" --label rextina-test --focus=false --json -- \
  sh -c "REX_BLOCK=test '$root/bin/rextina-status' blocked permission 'Needs approval' >/dev/null 2>&1; sleep 15")
window=$(printf '%s' "$out" | jq -r '.window_id')
block=$(printf '%s' "$out" | jq -r '.block_ids[0]')
sleep 2

status=$("$rex" --autostart=false block call -s "$ses" -b "$block" program_status)
assert_contains "$status" '"state":"blocked"' integration_state
assert_contains "$status" '"kind":"permission"' integration_kind
assert_contains "$status" '"app":"claude-code"' integration_app
assert_contains "$status" '"msg":"Needs approval"' integration_msg

finish
