#!/usr/bin/env bash
# tests/fm-review-tier.test.sh - the review tier decided from a diff
# (bin/fm-review-tier.sh).
# Pins: the shipped defaults give none for documentation and for a small
# change, standard at the size threshold, and cross-family for a one-line
# change to a risk path; a rename, a deletion, a binary file, and an empty diff
# each get the documented answer; a home's config/review-tiers is tried before
# the defaults while the defaults stay in force; a non-production path never
# triggers unless a prod= line names it; and a path that is no repository, an
# unknown ref, or an unreadable or malformed rules file is an error, never a
# silent none.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TIER="$ROOT/bin/fm-review-tier.sh"
TMP_ROOT=$(fm_test_tmproot fm-review-tier)
REPO="$TMP_ROOT/repo"
BARE_HOME="$TMP_ROOT/home"
fm_git_identity

commit_all() {  # <message>
  git -C "$REPO" add -A || fail "fixture add failed: $1"
  git -C "$REPO" commit -qm "$1" || fail "fixture commit failed: $1"
}

start_branch() {  # <name>: a fresh branch from the base commit
  git -C "$REPO" checkout -q -b "$1" main || fail "could not create fixture branch $1"
}

numbered_lines() {  # <count> <word>
  awk -v n="$1" -v w="$2" 'BEGIN { for (i = 1; i <= n; i++) print w, i }'
}

# Every case reads the tracked defaults; a case that needs home rules passes
# its own home, so no case can see another's config/review-tiers.
tier_in() {  # <home> <fm-review-tier args...>
  local home=$1
  shift
  env -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$home" "$TIER" "$REPO" "$@"
}

tier() {  # <fm-review-tier args...>
  tier_in "$BARE_HOME" "$@"
}

field() {  # <output> <key>
  printf '%s\n' "$1" | sed -n "s/^  $2: //p"
}

build_fixture() {
  fm_git_init_commit "$REPO"
  mkdir -p "$REPO/src" "$REPO/docs" "$REPO/tests" "$REPO/scripts" "$REPO/.github/workflows" "$BARE_HOME"
  printf 'print("app")\n' > "$REPO/src/app.py"
  numbered_lines 400 old > "$REPO/src/legacy.py"
  printf 'on: push\n' > "$REPO/.github/workflows/ci.yml"
  printf '#!/bin/sh\necho deploy\n' > "$REPO/scripts/deploy.sh"
  printf 'def test_app(): pass\n' > "$REPO/tests/test_app.py"
  printf 'def helper(): pass\n' > "$REPO/tests/deploy_helper.py"
  printf 'guide\n' > "$REPO/docs/guide.md"
  commit_all base

  start_branch docs
  printf 'more\n' >> "$REPO/README.md"
  printf 'more\n' >> "$REPO/docs/guide.md"
  commit_all docs

  start_branch small
  numbered_lines 10 small >> "$REPO/src/app.py"
  commit_all small

  start_branch size299
  numbered_lines 299 new > "$REPO/src/feature.py"
  commit_all size299

  start_branch size300
  numbered_lines 300 new > "$REPO/src/feature.py"
  commit_all size300

  start_branch risk
  printf 'on: pull_request\n' >> "$REPO/.github/workflows/ci.yml"
  commit_all risk

  start_branch rename
  git -C "$REPO" mv src/legacy.py src/renamed.py || fail "fixture rename failed"
  commit_all rename

  start_branch rename-risk
  git -C "$REPO" mv scripts/deploy.sh scripts/ship.sh || fail "fixture risk rename failed"
  commit_all rename-risk

  start_branch deleted
  git -C "$REPO" rm -q src/legacy.py || fail "fixture delete failed"
  commit_all deleted

  start_branch binary
  printf '\000\001\002\003' > "$REPO/src/blob.bin"
  commit_all binary

  start_branch test-helper
  printf 'def more(): pass\n' >> "$REPO/tests/deploy_helper.py"
  commit_all test-helper

  start_branch many-risk
  mkdir -p "$REPO/migrations"
  local i=1
  while [ "$i" -le 25 ]; do
    printf 'select %s;\n' "$i" > "$REPO/migrations/step-$i.sql"
    i=$((i + 1))
  done
  commit_all many-risk

  git -C "$REPO" checkout -q main || fail "could not return the fixture to main"
}

test_documentation_only_is_none() {
  local out
  out=$(tier main docs) || fail "a documentation-only diff should get a verdict"
  assert_equals none "$(field "$out" tier)" "documentation only should need no review"
  assert_equals non-production "$(field "$out" basis)" "documentation only should say why"
  assert_contains "$out" "production_lines: 0 " "documentation lines must not count"
  assert_contains "$out" "files: 2 changed, 0 production, 2 non-production" "both files should be non-production"
  pass "fm-review-tier: a documentation-only change is tier none"
}

test_small_change_is_none() {
  local out
  out=$(tier main small) || fail "a small diff should get a verdict"
  assert_equals none "$(field "$out" tier)" "a small low-risk change should need no review"
  assert_equals below-threshold "$(field "$out" basis)" "a small change should name the threshold"
  assert_contains "$out" "production_lines: 10 (+10 -0, threshold 300)" "the changed production lines should be reported"
  assert_contains "$out" "risk_paths: 0" "no rule names src/app.py"
  pass "fm-review-tier: a small change no rule names is tier none"
}

test_size_threshold_gives_standard() {
  local out
  out=$(tier main size299) || fail "a 299-line diff should get a verdict"
  assert_equals none "$(field "$out" tier)" "one line under the threshold should stay none"
  out=$(tier main size300) || fail "a 300-line diff should get a verdict"
  assert_equals standard "$(field "$out" tier)" "the threshold itself should be standard"
  assert_equals size "$(field "$out" basis)" "a size verdict should say so"
  assert_contains "$(field "$out" reason)" "300 changed production lines" "the reason should carry the count"
  pass "fm-review-tier: a change at the size threshold is tier standard"
}

test_one_line_on_a_risk_path_is_cross_family() {
  local out
  out=$(tier main risk) || fail "a risk-path diff should get a verdict"
  assert_equals cross-family "$(field "$out" tier)" "one line of CI workflow should be cross-family"
  assert_equals path-rule "$(field "$out" basis)" "a path verdict should say so"
  assert_contains "$(field "$out" reason)" ".github/workflows/ci.yml matches '.github/workflows/'" \
    "the reason should name the path and the rule"
  assert_contains "$(field "$out" reason)" "[config-defaults/review-tiers:" "the reason should say where the rule is written"
  assert_contains "$out" "production_lines: 1 " "the one changed line should be counted"
  assert_contains "$out" "risk_paths: 1" "the matched path should be counted"
  assert_contains "$out" "    cross-family .github/workflows/ci.yml matches" "the matched path should be listed"
  assert_contains "$(field "$out" requires)" "other model family" "the verdict should say what it requires"
  pass "fm-review-tier: a one-line change to a risk path is tier cross-family"
}

test_rename_counts_changed_lines_and_checks_both_names() {
  local out
  out=$(tier main rename) || fail "a rename should get a verdict"
  assert_equals none "$(field "$out" tier)" "moving 400 unchanged lines is not a 400-line change"
  assert_contains "$out" "production_lines: 0 " "a pure rename changes no line"
  assert_contains "$out" "files: 1 changed, 1 production" "a rename is one changed file"

  out=$(tier main rename-risk) || fail "a rename off a risk path should get a verdict"
  assert_equals cross-family "$(field "$out" tier)" "moving a file off a risk path still touches that path"
  assert_contains "$out" "scripts/deploy.sh matches 'deploy*'" "the old name should match the rule"
  assert_contains "$out" "renamed to scripts/ship.sh" "the listing should say where the file went"
  pass "fm-review-tier: a rename counts only changed lines and classifies both names"
}

test_deleted_and_binary_files() {
  local out
  out=$(tier main deleted) || fail "a deletion should get a verdict"
  assert_equals standard "$(field "$out" tier)" "deleting 400 production lines is a 400-line change"
  assert_contains "$out" "production_lines: 400 (+0 -400, threshold 300)" "deleted lines should count"

  out=$(tier main binary) || fail "a binary file should get a verdict"
  assert_equals none "$(field "$out" tier)" "a binary file has no lines to count"
  assert_contains "$out" "files: 1 changed, 1 production, 0 non-production, 1 binary" "the binary file should be reported"
  pass "fm-review-tier: a deletion counts its lines and a binary file is reported, not counted"
}

test_empty_diff_has_its_own_basis() {
  local out
  out=$(tier main main) || fail "an empty diff should get a verdict"
  assert_equals none "$(field "$out" tier)" "nothing changed, so nothing needs review"
  assert_equals no-changes "$(field "$out" basis)" "an empty diff must not read as a small change"
  assert_contains "$(field "$out" reason)" "same commit" "the reason should say the refs are one commit"

  out=$(tier docs main) || fail "a head behind its base should get a verdict"
  assert_equals no-changes "$(field "$out" basis)" "a head its base already holds adds nothing"
  assert_contains "$(field "$out" reason)" "already contained in docs" "the reason should say the head is already in the base"
  pass "fm-review-tier: a diff with no changes is tier none on the basis no-changes"
}

test_home_rules_come_before_the_defaults() {
  local home="$TMP_ROOT/home-rules" out
  mkdir -p "$home/config"
  cat > "$home/config/review-tiers" <<'RULES'
# this home's rules
threshold=5
src/app.py          none          carved out of the rule below
src/                cross-family  this home treats all of src as risky
.github/workflows/  none          this home reviews its workflows elsewhere
RULES

  out=$(tier_in "$home" main size300) || fail "home rules should give a verdict"
  assert_equals cross-family "$(field "$out" tier)" "a home rule should apply"
  assert_contains "$(field "$out" reason)" "[config/review-tiers:4]" "the reason should point at the home rule"

  out=$(tier_in "$home" main small) || fail "home rules should give a verdict"
  assert_equals standard "$(field "$out" tier)" "the home threshold should replace the default one"
  assert_equals size "$(field "$out" basis)" "the earlier none rule should keep src/app.py off the risk paths"
  assert_contains "$out" "threshold 5)" "the home threshold should be reported"

  out=$(tier_in "$home" main risk) || fail "home rules should give a verdict"
  assert_equals none "$(field "$out" tier)" "a home rule should win over the default rule for the same path"

  out=$(tier_in "$home" main rename-risk) || fail "home rules should give a verdict"
  assert_equals cross-family "$(field "$out" tier)" "the defaults should stay in force beneath the home rules"
  assert_contains "$(field "$out" reason)" "[config-defaults/review-tiers:" "the reason should point at the default rule"
  assert_contains "$(field "$out" rules)" "$home/config/review-tiers, " "the home file should be listed first"
  pass "fm-review-tier: a home's rules are tried first and the defaults stay in force"
}

test_non_production_paths_never_trigger_unless_named() {
  local home="$TMP_ROOT/home-prod" out
  out=$(tier main test-helper) || fail "a test-only diff should get a verdict"
  assert_equals none "$(field "$out" tier)" "a test file is not the machinery it tests"
  assert_equals non-production "$(field "$out" basis)" "a test-only change should say why"
  assert_contains "$(field "$out" note)" "tests/deploy_helper.py" "a left-out path that matches a risk rule should be named"

  mkdir -p "$home/config"
  printf 'prod=tests/deploy_helper.py\n' > "$home/config/review-tiers"
  out=$(tier_in "$home" main test-helper) || fail "a prod= line should give a verdict"
  assert_equals cross-family "$(field "$out" tier)" "a prod= path should be matched like production"
  assert_contains "$out" "production_lines: 1 " "a prod= path should be counted"
  pass "fm-review-tier: a non-production path never triggers unless prod= names it"
}

test_rules_flag_reads_one_file_alone() {
  local rules="$TMP_ROOT/only-rules" out
  # Written with CRLF line endings, as an editor on Windows would leave it.
  printf 'src/  standard  only rule in this file\r\n' > "$rules"
  out=$(tier main small --rules "$rules") || fail "--rules should give a verdict"
  assert_equals standard "$(field "$out" tier)" "the file's rule should apply"
  assert_contains "$(field "$out" reason)" "(only rule in this file)" "a carriage return must not ride into the reason"
  assert_equals "$rules" "$(field "$out" rules)" "only the named file should be read"
  out=$(tier main risk --rules "$rules") || fail "--rules should give a verdict"
  assert_equals none "$(field "$out" tier)" "the defaults must not apply under --rules"
  out=$(tier main docs --rules "$rules") || fail "--rules should give a verdict"
  assert_equals below-threshold "$(field "$out" basis)" "with no nonprod line every file is production"
  pass "fm-review-tier: --rules reads that file alone"
}

test_glob_semantics() {
  local rules="$TMP_ROOT/probe-rules" glob branch want out
  while read -r glob branch want; do
    [ -n "$glob" ] || continue
    printf '%s cross-family probe\n' "$glob" > "$rules"
    out=$(tier main "$branch" --rules "$rules") || fail "probe '$glob' should give a verdict"
    assert_equals "$want" "$(field "$out" tier)" "glob '$glob' against the $branch change"
  done <<'PROBES'
app.py          small  cross-family
/app.py         small  none
./app.py        small  none
src/app.py      small  cross-family
/src/app.py     small  cross-family
./src/app.py    small  cross-family
src             small  cross-family
src/            small  cross-family
sr              small  none
*.py            small  cross-family
src/**/app.py   small  cross-family
**/src/**       small  cross-family
workflows/      risk   cross-family
/workflows/     risk   none
ci.yml          risk   cross-family
.github/        risk   cross-family
github/         risk   none
PROBES
  pass "fm-review-tier: path globs follow the documented .gitignore-style rules"
}

test_long_risk_list_is_capped_in_text_only() {
  local out
  out=$(tier main many-risk) || fail "a many-file diff should get a verdict"
  assert_equals cross-family "$(field "$out" tier)" "migrations should be cross-family"
  assert_contains "$out" "risk_paths: 25" "every matched path should be counted"
  assert_contains "$out" "... and 5 more" "the text listing should stop at twenty paths"
  out=$(tier main many-risk --json) || fail "--json should give a verdict"
  [ "$(printf '%s\n' "$out" | grep -o '"path":' | wc -l | tr -d ' ')" = 25 ] \
    || fail "--json should list every matched path"
  pass "fm-review-tier: the text listing is capped while --json lists every risk path"
}

test_json_output() {
  local rules="$TMP_ROOT/json-rules" out
  # The reason carries a quote, a backslash, and a tab: each needs its escape.
  printf 'deploy*  cross-family  say "why" with a back\\slash and\ta tab\n' > "$rules"
  out=$(tier main rename-risk --json --rules "$rules") || fail "--json should give a verdict"
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] || fail "--json should print one line: $out"
  assert_contains "$out" '"tier":"cross-family"' "the JSON should carry the tier"
  assert_contains "$out" '"basis":"path-rule"' "the JSON should carry the basis"
  assert_contains "$out" '"production_lines":0' "the JSON should carry the line count"
  assert_contains "$out" '"reason":"say \"why\" with a back\\slash and\ta tab"' \
    "quotes, backslashes, and tabs should be escaped"
  assert_contains "$out" '"note":"renamed to scripts/ship.sh"' "the JSON should carry the rename"
  if command -v jq >/dev/null 2>&1; then
    assert_equals "scripts/deploy.sh" "$(printf '%s\n' "$out" | jq -r '.risk_paths[0].path')" \
      "the JSON should parse and name the matched path"
    assert_equals "$(printf 'say "why" with a back\\slash and\ta tab')" \
      "$(printf '%s\n' "$out" | jq -r '.risk_paths[0].reason')" \
      "the escaped reason should read back unchanged"
  fi
  pass "fm-review-tier: --json prints the verdict as one valid JSON object"
}

test_broken_input_is_an_error_never_none() {
  local out rc label rules="$TMP_ROOT/bad-rules" err="$TMP_ROOT/stderr"

  out=$(tier main no-such-ref 2>"$err") && rc=0 || rc=$?
  expect_code 1 "$rc" "an unknown head ref"
  assert_equals "" "$out" "an unknown ref must print no verdict"
  assert_contains "$(cat "$err")" "unknown head ref 'no-such-ref'" "the error should name the ref"

  out=$(tier no-such-ref main 2>"$err") && rc=0 || rc=$?
  expect_code 1 "$rc" "an unknown base ref"
  assert_contains "$(cat "$err")" "unknown base ref 'no-such-ref'" "the error should name the ref"

  # The ceiling keeps git from finding a repository above the temp root.
  mkdir -p "$TMP_ROOT/plain-dir"
  out=$(env -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$BARE_HOME" GIT_CEILING_DIRECTORIES="$TMP_ROOT" \
    "$TIER" "$TMP_ROOT/plain-dir" main docs 2>"$err") && rc=0 || rc=$?
  expect_code 1 "$rc" "a path that is no repository"
  assert_equals "" "$out" "a non-repository must print no verdict"
  assert_contains "$(cat "$err")" "not a git repository" "the error should say what is wrong"

  out=$(tier main docs --rules "$TMP_ROOT/no-such-rules" 2>"$err") && rc=0 || rc=$?
  expect_code 1 "$rc" "a missing rules file"
  assert_equals "" "$out" "a missing rules file must print no verdict"
  assert_contains "$(cat "$err")" "rules file is not a readable regular file" "the error should name the rules file"

  mkdir -p "$TMP_ROOT/no-defaults-root"
  out=$(env -u FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE="$TMP_ROOT/no-defaults-root" FM_HOME="$BARE_HOME" \
    "$TIER" "$REPO" main docs 2>"$err") && rc=0 || rc=$?
  expect_code 1 "$rc" "missing tracked defaults"
  assert_contains "$(cat "$err")" "config-defaults/review-tiers" "the error should name the missing defaults"

  while IFS='|' read -r label line; do
    [ -n "$label" ] || continue
    printf '# comment\n\n%s\n' "$line" > "$rules"
    out=$(tier main docs --rules "$rules" 2>"$err") && rc=0 || rc=$?
    expect_code 1 "$rc" "$label"
    assert_equals "" "$out" "$label must print no verdict"
    assert_contains "$(cat "$err")" "$rules:3: " "$label should be reported with its file and line"
  done <<'ROWS'
an unknown tier|src/ urgent because
a rule with no tier|src/
a rule with no reason|src/ standard
a threshold that is no number|threshold=many
a zero threshold|threshold=0
a negated glob|!src/ none not supported
a glob that names nothing|/ none nothing
ROWS

  out=$(tier main 2>"$err") && rc=0 || rc=$?
  expect_code 2 "$rc" "a missing head ref"
  assert_contains "$(cat "$err")" "usage: fm-review-tier.sh" "a usage error should print the usage"
  out=$(tier main docs --frobnicate 2>"$err") && rc=0 || rc=$?
  expect_code 2 "$rc" "an unknown option"
  out=$(tier main docs --rules 2>"$err") && rc=0 || rc=$?
  expect_code 2 "$rc" "--rules with no file"
  pass "fm-review-tier: broken input is an error with no verdict, and a usage error exits 2"
}

test_repository_is_left_untouched() {
  local before after
  before=$(git -C "$REPO" for-each-ref; git -C "$REPO" status --porcelain; git -C "$REPO" symbolic-ref HEAD)
  tier main many-risk >/dev/null || fail "a verdict should be given"
  tier main size300 --json >/dev/null || fail "a verdict should be given"
  after=$(git -C "$REPO" for-each-ref; git -C "$REPO" status --porcelain; git -C "$REPO" symbolic-ref HEAD)
  assert_equals "$before" "$after" "refs, checkout, and working tree must be unchanged"
  [ ! -e "$BARE_HOME/config" ] || fail "the home must gain no config directory"
  pass "fm-review-tier: the repository and the home are left untouched"
}

build_fixture
test_documentation_only_is_none
test_small_change_is_none
test_size_threshold_gives_standard
test_one_line_on_a_risk_path_is_cross_family
test_rename_counts_changed_lines_and_checks_both_names
test_deleted_and_binary_files
test_empty_diff_has_its_own_basis
test_home_rules_come_before_the_defaults
test_non_production_paths_never_trigger_unless_named
test_rules_flag_reads_one_file_alone
test_glob_semantics
test_long_risk_list_is_capped_in_text_only
test_json_output
test_broken_input_is_an_error_never_none
test_repository_is_left_untouched
