#!/bin/sh
COUNT=0
FAILS=0

assert_eq() {
  COUNT=$((COUNT + 1))
  if [ "$1" != "$2" ]; then
    FAILS=$((FAILS + 1))
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$3" "$1" "$2"
  fi
}

assert_contains() {
  COUNT=$((COUNT + 1))
  case $1 in
    *"$2"*) ;;
    *)
      FAILS=$((FAILS + 1))
      printf 'FAIL %s\n  missing: %s\n  in:      %s\n' "$3" "$2" "$1"
      ;;
  esac
}

assert_not_contains() {
  COUNT=$((COUNT + 1))
  case $1 in
    *"$2"*)
      FAILS=$((FAILS + 1))
      printf 'FAIL %s\n  unexpected: %s\n  in:         %s\n' "$3" "$2" "$1"
      ;;
  esac
}

assert_file_absent() {
  COUNT=$((COUNT + 1))
  if [ -e "$1" ]; then
    FAILS=$((FAILS + 1))
    printf 'FAIL %s\n  exists: %s\n' "$2" "$1"
  fi
}

finish() {
  printf '%s: %d assertions, %d failed\n' "$0" "$COUNT" "$FAILS"
  [ "$FAILS" -eq 0 ] || exit 1
  exit 0
}
