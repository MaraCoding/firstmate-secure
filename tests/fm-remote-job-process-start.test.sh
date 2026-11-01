#!/usr/bin/env bash
# Process identity: immutable Linux start ticks, portable lstart fallback, and
# stat comm fields containing spaces and right parentheses.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$ROOT/bin/fm-remote-job-lib.sh"

if [ -r "/proc/$$/stat" ]; then
  expected=$(awk '{sub(/^.*\) /, ""); print $20}' "/proc/$$/stat")
  first=$(fm_remote_job_process_start "$$")
  second=$(fm_remote_job_process_start "$$")
  [ "$first" = "ticks:$expected" ] || fail "Linux identity did not select stat field 22: $first"
  [ "$first" = "$second" ] || fail "Linux identity changed between reads"
  pass "readable Linux proc stat yields stable field-22 ticks"
else
  printf 'note: no native /proc; exercising proc stat through the portable fixture below\n'
fi

# Redirect only the stat read, through shell command boundaries rather than
# rewriting production source. This runs on macOS too, including fallback.
FIXTURE_READABLE=1
FIXTURE_STAT=
function [() {
  if builtin [ "$#" -eq 3 ] && builtin [ "$1" = -r ] && builtin [ "$2" = "/proc/$$/stat" ]; then
    builtin [ "$FIXTURE_READABLE" = 1 ]
  else
    builtin [ "$@"
  fi
}
cat() {
  if [ "$#" -eq 1 ] && [ "$1" = "/proc/$$/stat" ]; then
    printf '%s\n' "$FIXTURE_STAT"
  else
    command cat "$@"
  fi
}
# After the last ') ', state is field 3, then nineteen fields up to starttime.
FIXTURE_STAT="$$ (worker ) with spaces and )) S"
for n in $(seq 4 21); do FIXTURE_STAT="$FIXTURE_STAT $n"; done
FIXTURE_STAT="$FIXTURE_STAT 7654321 23 24"
[ "$(fm_remote_job_process_start "$$")" = ticks:7654321 ] || fail "comm field broke starttime selection"
[ "$(fm_remote_job_process_start "$$")" = ticks:7654321 ] || fail "fixture ticks changed"
pass "portable stat fixture tolerates spaces and right parentheses in comm"

FIXTURE_READABLE=0
expected=$(LC_ALL=C /bin/ps -p "$$" -o lstart=)
actual=$(fm_remote_job_process_start "$$")
[ "$actual" = "$expected" ] || fail "unreadable/absent proc did not fall back to lstart: $actual (expected $expected)"
pass "unreadable or absent proc uses lstart on every platform"
FIXTURE_READABLE=1
FIXTURE_STAT='malformed proc record'
[ "$(fm_remote_job_process_start "$$")" = "$expected" ] || fail "invalid proc record did not fall back"
pass "invalid proc record uses lstart"
