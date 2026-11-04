#!/usr/bin/env bash
# tests/fm-report-outline.test.sh - outline-first report reading.
# Pins: the heading list skips fenced headings and counts section lines; named
# sections print exactly or by text, capped per line and per section; a
# missing report or heading exits 1.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUTLINE="$ROOT/bin/fm-report-outline.sh"
TMP_ROOT=$(fm_test_tmproot fm-report-outline)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/data/t1"
REPORT="$HOME_DIR/data/t1/report.md"
{
  printf '# Report\n\nintro\n\n## Verdict\n\nShip it.\n\n## Findings\n\n'
  printf '```\n## not a heading\n```\n'
  printf '%0500d\n' 0
  for i in $(seq 1 30); do printf 'finding %s\n' "$i"; done
  printf '\n## Commands run\n\nmake test\n'
} > "$REPORT"

run() { FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" "$@"; }

test_outline_lists_headings() {
  local out
  out=$(run "$OUTLINE" t1) || fail "outline should succeed"
  assert_contains "$out" "5: ## Verdict (3 lines)" "the outline should give the line and section length"
  assert_contains "$out" "## Commands run" "the outline should list every heading"
  assert_not_contains "$out" "not a heading" "fenced headings are not headings"
  assert_contains "$out" "total: " "the outline should give the total size"
  pass "fm-report-outline: lists headings with line counts, skipping fenced blocks"
}

test_sections_are_capped() {
  local out
  out=$(FM_REPORT_SECTION_LINES=10 run "$OUTLINE" "$REPORT" verdict '## Findings') || fail "sections should print"
  assert_contains "$out" "Ship it." "a section named by text should print"
  assert_contains "$out" "[... " "a long section should be cut at FM_REPORT_SECTION_LINES"
  assert_contains "$out" "long lines cut at 400 chars" "a long line should be cut at the line cap"
  assert_not_contains "$out" "make test" "unnamed sections must not print"
  pass "fm-report-outline: prints only the named sections, capped"
}

test_missing_exits_1() {
  local rc=0
  run "$OUTLINE" t1 Nope >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a missing heading should exit 1"
  rc=0
  run "$OUTLINE" t2 >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a missing report should exit 1"
  pass "fm-report-outline: missing report or heading exits 1"
}

test_outline_lists_headings
test_sections_are_capped
test_missing_exits_1
