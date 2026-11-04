#!/usr/bin/env bash
# tests/fm-help.test.sh - the generated fm-* cheat sheet.
# Pins: the default view stays under 6000 characters, carries one line per
# operator command (including fm-context-check and fm-report-outline), hides
# internals that --all shows, and filters by pattern.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HELP="$ROOT/bin/fm-help.sh"

test_default_view_is_small_and_complete() {
  local out n
  out=$("$HELP") || fail "fm-help should succeed"
  n=$(printf '%s\n' "$out" | wc -c | tr -d ' ')
  [ "$n" -lt 6000 ] || fail "the default cheat sheet should stay under 6000 chars, got $n"
  for cmd in fm-spawn fm-send fm-control fm-crew-state fm-teardown fm-context-check fm-report-outline fm-dispatch-resolve fm-tasks-axi; do
    printf '%s\n' "$out" | grep -q "^${cmd}[ ]" || fail "the cheat sheet should list $cmd"
  done
  assert_contains "$out" "fm-control <task-id> interrupt|exit|relaunch" "multi-form usage should collapse to verbs"
  printf '%s\n' "$out" | awk 'length($0) > 118 { exit 1 }' || fail "every line should fit FM_HELP_WIDTH"
  assert_not_contains "$out" "fm-subagent-pretool-check" "hooks should be hidden by default"
  pass "fm-help: default view is under 6000 chars and lists the operator commands"
}

test_all_and_filter() {
  local all out
  all=$("$HELP" --all) || fail "fm-help --all should succeed"
  assert_contains "$all" "fm-subagent-pretool-check" "--all should include internals"
  out=$("$HELP" PEEK) || fail "a filter should succeed"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "the filter should be a case-insensitive substring: $out"
  pass "fm-help: --all shows internals and a pattern filters"
}

test_default_view_is_small_and_complete
test_all_and_filter
