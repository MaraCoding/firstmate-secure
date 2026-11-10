#!/usr/bin/env bash
# tests/fm-landing-proof.test.sh - the opt-in landing proof, driven through
# bin/fm-landing-proof.sh directly and through the real bin/fm-merge-local.sh
# against a fixture project. The script's header owns the contract.
#
# Pins:
#   1. A home without config/landing-proof, and a project the file does not
#      name, land exactly as before and record nothing.
#   2. `warn` reports a missing proof and still merges; `require` refuses and
#      leaves the default branch where it was.
#   3. A proof counts only for the exact commit being landed: a log naming an
#      earlier commit, a branch that moved after the proof, and a recorded log
#      that no longer holds its line are all shortfalls.
#   4. Proofs are found directly in data/<id>/ and one directory below it;
#      a symlinked log is never accepted.
#   5. A waiver is explicit, needs a reason, and is bound to one commit.
#   6. A rules file that cannot be read as written (malformed, unreadable, not
#      plain text) refuses instead of reading as "nothing required".
#   7. The commit that lands is the commit that was proven, even when the ship
#      branch moves between the check and the fast-forward.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROOF="$ROOT/bin/fm-landing-proof.sh"
MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-landing-proof)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK=t1

commit_file() {  # <repo> <name>
  printf '%s\n' "$2" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm "$2"
}

# Sets HOME_DIR PROJ BASE TIP for one isolated case: a project named `sample`
# whose ship branch fm/t1 is one commit ahead of main.
make_case() {  # <name>
  HOME_DIR="$TMP_ROOT/$1/home"
  PROJ="$TMP_ROOT/$1/sample"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/$TASK"
  fm_git_init_commit "$PROJ"
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$PROJ" checkout -q -b "fm/$TASK"
  commit_file "$PROJ" change
  TIP=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$PROJ" checkout -q main
  printf 'project=%s\nmode=local-only\nbranch=fm/%s\n' "$PROJ" "$TASK" > "$HOME_DIR/state/$TASK.meta"
}

rules() {  # <mode>
  cat > "$HOME_DIR/config/landing-proof" <<EOF
# landing proof rules for the fixture
sample mode $1
sample proof gate ^FULL CI GATE PASSED commit=@COMMIT@\$
sample proof parity ^PRIVATE ALL [0-9]+ SUITES PARITY PASSED commit=@COMMIT@\$
elsewhere proof gate ^ELSEWHERE @COMMIT@\$
EOF
}

gate_log() {  # <file> <commit>
  mkdir -p "$(dirname "$1")"
  printf 'compiling\nCOMPILE PIECE PASSED commit=%s\nFULL CI GATE PASSED commit=%s\n' "$2" "$2" > "$1"
}

parity_log() {  # <file> <commit>
  mkdir -p "$(dirname "$1")"
  printf 'PRIVATE SUITE RESULT a PASS\nPRIVATE ALL 29 SUITES PARITY PASSED commit=%s\n' "$2" > "$1"
}

in_home() {  # <command...>
  env -u FM_TRACE_CONTEXT FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$@"
}

# run <command...>: sets RC and OUT (stdout and stderr together).
run() {
  RC=0
  OUT=$(in_home "$@" 2>&1) || RC=$?
}

main_head() {
  git -C "$PROJ" rev-parse main
}

test_unconfigured_home_lands_as_before() {
  make_case unconfigured
  run "$MERGE_LOCAL" "$TASK"
  expect_code 0 "$RC" "a home without config/landing-proof should merge: $OUT"
  assert_contains "$OUT" "merged fm/$TASK into local main" "the merge line should be unchanged"
  assert_not_contains "$OUT" "landing proof" "an unconfigured home should say nothing about proof"
  [ "$(main_head)" = "$TIP" ] || fail "the default branch should be at the ship branch tip"
  assert_absent "$HOME_DIR/state/$TASK.landing-proof" "no record should be written without rules"
  assert_absent "$HOME_DIR/state/landing-proofs.log" "no history should be written without rules"
  pass "fm-landing-proof: a home without config/landing-proof lands exactly as before"
}

test_unnamed_project_lands_as_before() {
  make_case unnamed
  printf 'elsewhere mode require\nelsewhere proof gate ^ELSEWHERE @COMMIT@$\n' > "$HOME_DIR/config/landing-proof"
  run "$MERGE_LOCAL" "$TASK"
  expect_code 0 "$RC" "a project the rules do not name should merge: $OUT"
  [ "$(main_head)" = "$TIP" ] || fail "the default branch should be at the ship branch tip"
  assert_absent "$HOME_DIR/state/$TASK.landing-proof" "no record for a project without rules"
  assert_absent "$HOME_DIR/state/landing-proofs.log" "no history for a project without rules"
  pass "fm-landing-proof: a project the rules do not name is untouched"
}

test_warn_mode_reports_and_merges() {
  make_case warn
  rules warn
  run "$MERGE_LOCAL" "$TASK"
  expect_code 0 "$RC" "warn mode should still merge: $OUT"
  assert_contains "$OUT" "warning: no landing proof for $TASK" "warn mode should report the shortfall"
  assert_contains "$OUT" "missing gate,parity" "the warning should name each missing proof"
  [ "$(main_head)" = "$TIP" ] || fail "warn mode should land the branch"
  assert_grep "task=$TASK project=sample commit=$TIP mode=warn missing=gate,parity" \
    "$HOME_DIR/state/landing-proofs.log" "the history should record what was missing"
  pass "fm-landing-proof: warn mode reports the missing proof and merges"
}

test_require_mode_refuses_without_proof() {
  make_case require-none
  rules require
  run "$MERGE_LOCAL" "$TASK"
  expect_code 1 "$RC" "require mode should refuse a merge with no proof: $OUT"
  assert_contains "$OUT" "no landing proof for $TASK" "the refusal should say what is missing"
  assert_contains "$OUT" "missing gate,parity" "the refusal should name each missing proof"
  assert_contains "$OUT" "local merge refused" "the merge script should say it refused"
  [ "$(main_head)" = "$BASE" ] || fail "a refused merge must leave the default branch alone"
  assert_absent "$HOME_DIR/state/landing-proofs.log" "a refused merge is not a landing"
  pass "fm-landing-proof: require mode refuses and leaves the default branch where it was"
}

test_require_mode_lands_the_proven_commit() {
  make_case require-proven
  rules require
  # One level down, the way a worker keeps each validated commit's logs.
  gate_log "$HOME_DIR/data/$TASK/validation-$TIP/final-gate.log" "$TIP"
  parity_log "$HOME_DIR/data/$TASK/validation-$TIP/final-parity.log" "$TIP"
  # An older run's logs at the top level name another commit and must not count.
  gate_log "$HOME_DIR/data/$TASK/final-gate.log" "$BASE"
  run "$MERGE_LOCAL" "$TASK"
  expect_code 0 "$RC" "proofs on the exact commit should let the merge through: $OUT"
  assert_contains "$OUT" "landing proof: gate, parity proven for $TASK" "the gate should say what it accepted"
  assert_contains "$OUT" "merged fm/$TASK into local main" "the merge line should be unchanged"
  [ "$(main_head)" = "$TIP" ] || fail "the proven commit should be what landed"
  assert_grep "commit=$TIP" "$HOME_DIR/state/$TASK.landing-proof" "the record should name the commit"
  assert_grep "proof.gate.log=$HOME_DIR/data/$TASK/validation-$TIP/final-gate.log" \
    "$HOME_DIR/state/$TASK.landing-proof" "the record should point at the log that proved the gate"
  grep -E -q '^proof\.parity\.sha256=[0-9a-f]{64}$' "$HOME_DIR/state/$TASK.landing-proof" \
    || fail "the record should carry the parity log's hash"
  assert_grep "task=$TASK project=sample commit=$TIP mode=require proven gate=" \
    "$HOME_DIR/state/landing-proofs.log" "the history should record a proven landing"
  pass "fm-landing-proof: require mode lands a commit whose proofs name it, found one directory down"
}

test_proof_for_an_earlier_commit_does_not_count() {
  make_case stale
  rules require
  gate_log "$HOME_DIR/data/$TASK/final-gate.log" "$BASE"
  parity_log "$HOME_DIR/data/$TASK/final-parity.log" "$BASE"
  run "$PROOF" gate "$TASK"
  expect_code 1 "$RC" "logs naming an earlier commit prove nothing: $OUT"
  assert_contains "$OUT" "missing gate,parity" "both proofs should be reported missing"
  parity_log "$HOME_DIR/data/$TASK/final-parity.log" "$TIP"
  run "$PROOF" gate "$TASK"
  expect_code 1 "$RC" "one proof of two is still a shortfall: $OUT"
  assert_contains "$OUT" "missing gate" "only the gate should now be missing"
  assert_not_contains "$OUT" "gate,parity" "the parity proof should have been accepted"
  pass "fm-landing-proof: a proof counts only for the exact commit, and every rule must be met"
}

test_branch_that_moved_needs_new_proof() {
  make_case moved
  rules require
  gate_log "$HOME_DIR/data/$TASK/final-gate.log" "$TIP"
  parity_log "$HOME_DIR/data/$TASK/final-parity.log" "$TIP"
  run "$PROOF" gate "$TASK"
  expect_code 0 "$RC" "the tip is proven: $OUT"
  git -C "$PROJ" checkout -q "fm/$TASK"
  commit_file "$PROJ" later
  git -C "$PROJ" checkout -q main
  run "$MERGE_LOCAL" "$TASK"
  expect_code 1 "$RC" "a commit added after the proof must not land on it: $OUT"
  [ "$(main_head)" = "$BASE" ] || fail "the default branch must not move"
  pass "fm-landing-proof: a branch that moved after its proof needs new proof"
}

test_recorded_log_must_still_hold_its_line() {
  make_case rewritten
  rules require
  gate_log "$HOME_DIR/data/$TASK/final-gate.log" "$TIP"
  parity_log "$HOME_DIR/data/$TASK/final-parity.log" "$TIP"
  run "$PROOF" gate "$TASK"
  expect_code 0 "$RC" "the tip is proven: $OUT"
  printf 'GATE FAILED: a later run overwrote this log\n' > "$HOME_DIR/data/$TASK/final-gate.log"
  run "$PROOF" gate "$TASK"
  expect_code 1 "$RC" "a recorded log that lost its line is no longer proof: $OUT"
  assert_contains "$OUT" "missing gate" "the gate should be reported missing again"
  pass "fm-landing-proof: a recorded log that no longer holds its line stops counting"
}

test_symlinked_log_is_never_proof() {
  make_case symlink
  rules require
  gate_log "$TMP_ROOT/symlink/outside-gate.log" "$TIP"
  ln -s "$TMP_ROOT/symlink/outside-gate.log" "$HOME_DIR/data/$TASK/final-gate.log"
  parity_log "$HOME_DIR/data/$TASK/final-parity.log" "$TIP"
  run "$PROOF" gate "$TASK"
  expect_code 1 "$RC" "a symlinked log must not be accepted: $OUT"
  assert_contains "$OUT" "missing gate" "the symlinked gate log should not count"
  pass "fm-landing-proof: a symlinked log is never accepted as proof"
}

test_waiver_is_explicit_and_bound_to_one_commit() {
  make_case waiver
  rules require
  run "$PROOF" waive "$TASK"
  expect_code 2 "$RC" "a waiver without a reason is a usage error: $OUT"
  run "$PROOF" waive "$TASK" --reason "docs only, captain approved"
  expect_code 0 "$RC" "a waiver with a reason should be recorded: $OUT"
  run "$PROOF" gate "$TASK"
  expect_code 0 "$RC" "a waived commit should pass the gate: $OUT"
  assert_contains "$OUT" "waived for $TASK" "the gate should say the proof was waived"
  assert_contains "$OUT" "docs only, captain approved" "the gate should repeat the reason"
  git -C "$PROJ" checkout -q "fm/$TASK"
  commit_file "$PROJ" later
  git -C "$PROJ" checkout -q main
  run "$PROOF" gate "$TASK"
  expect_code 1 "$RC" "a waiver must not carry over to a later commit: $OUT"
  pass "fm-landing-proof: a waiver needs a reason and covers exactly one commit"
}

test_write_records_named_logs() {
  make_case write
  rules require
  gate_log "$TMP_ROOT/write/elsewhere/gate.log" "$TIP"
  parity_log "$TMP_ROOT/write/elsewhere/parity.log" "$TIP"
  gate_log "$TMP_ROOT/write/elsewhere/old-gate.log" "$BASE"
  run "$PROOF" write "$TASK" --proof "gate=$TMP_ROOT/write/elsewhere/old-gate.log"
  expect_code 1 "$RC" "a log that does not name the commit must be rejected: $OUT"
  run "$PROOF" write "$TASK" --proof "lint=$TMP_ROOT/write/elsewhere/gate.log"
  expect_code 1 "$RC" "a proof the rules do not define must be rejected: $OUT"
  run "$PROOF" write "$TASK" --proof "gate=$TMP_ROOT/write/elsewhere/gate.log"
  expect_code 0 "$RC" "a matching gate log should be recorded: $OUT"
  assert_contains "$OUT" "still missing: parity" "write should say what is still owed"
  run "$PROOF" write "$TASK" --proof "parity=$TMP_ROOT/write/elsewhere/parity.log"
  expect_code 0 "$RC" "a matching parity log should be recorded: $OUT"
  assert_contains "$OUT" "gate, parity proven" "the earlier gate proof should be kept"
  run "$PROOF" show "$TASK"
  assert_contains "$OUT" "proof.gate.log=$TMP_ROOT/write/elsewhere/gate.log" "show should print the record"
  run "$MERGE_LOCAL" "$TASK"
  expect_code 0 "$RC" "explicitly recorded proofs should let the merge through: $OUT"
  [ "$(main_head)" = "$TIP" ] || fail "the proven commit should be what landed"
  pass "fm-landing-proof: write records named logs one at a time and rejects ones that prove nothing"
}

test_malformed_rules_refuse() {
  local body
  make_case malformed
  for body in \
    'sample mode strict' \
    'sample proof gate ^FULL CI GATE PASSED$' \
    'sample proof gate ^(unclosed @COMMIT@$' \
    'sample proof Gate ^X @COMMIT@$' \
    'sample check gate ^X @COMMIT@$'; do
    printf '%s\n' "$body" > "$HOME_DIR/config/landing-proof"
    run "$MERGE_LOCAL" "$TASK"
    expect_code 1 "$RC" "malformed rules must refuse, not read as nothing required ($body): $OUT"
    assert_contains "$OUT" "config/landing-proof line 1" "the error should name the line ($body)"
    [ "$(main_head)" = "$BASE" ] || fail "malformed rules must not let a merge through ($body)"
  done
  pass "fm-landing-proof: a malformed rules file refuses the merge and names the line"
}

test_usage_errors() {
  make_case usage
  run "$PROOF"
  expect_code 2 "$RC" "no verb is a usage error: $OUT"
  run "$PROOF" gate
  expect_code 2 "$RC" "no task id is a usage error: $OUT"
  run "$PROOF" gate '../escape'
  expect_code 2 "$RC" "an unsafe task id is a usage error: $OUT"
  run "$PROOF" gate "$TASK" --commit abc123
  expect_code 0 "$RC" "without rules the gate has nothing to check: $OUT"
  rules warn
  run "$PROOF" gate "$TASK" --commit abc123
  expect_code 1 "$RC" "a short commit id must be rejected: $OUT"
  run "$PROOF" show "$TASK"
  assert_contains "$OUT" "no landing proof recorded for $TASK" "show should say when nothing is recorded"
  pass "fm-landing-proof: usage errors exit 2 and a short commit id is rejected"
}

test_landed_commit_is_the_proven_commit() {
  local fakebin later real_shasum real_sha256sum
  make_case pin
  rules require
  gate_log "$HOME_DIR/data/$TASK/final-gate.log" "$TIP"
  parity_log "$HOME_DIR/data/$TASK/final-parity.log" "$TIP"
  git -C "$PROJ" checkout -q -b later "fm/$TASK"
  commit_file "$PROJ" later
  later=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$PROJ" checkout -q main
  # The gate hashes each accepted log. A hashing tool that first moves the ship
  # branch to the later, never-validated commit puts that move squarely between
  # the proof check and the fast-forward.
  fakebin="$TMP_ROOT/pin/fakebin"
  mkdir -p "$fakebin"
  real_shasum=$(command -v shasum || true)
  real_sha256sum=$(command -v sha256sum || true)
  cat > "$fakebin/shasum" <<SH
#!/usr/bin/env bash
[ -e "$fakebin/moved" ] || { : > "$fakebin/moved"; git -C "$PROJ" update-ref "refs/heads/fm/$TASK" "$later"; }
[ -z "$real_shasum" ] || exec "$real_shasum" "\$@"
shift 2
exec "$real_sha256sum" "\$@"
SH
  cat > "$fakebin/sha256sum" <<SH
#!/usr/bin/env bash
[ -e "$fakebin/moved" ] || { : > "$fakebin/moved"; git -C "$PROJ" update-ref "refs/heads/fm/$TASK" "$later"; }
exec "$real_sha256sum" "\$@"
SH
  chmod +x "$fakebin/shasum" "$fakebin/sha256sum"
  run env PATH="$fakebin:$PATH" "$MERGE_LOCAL" "$TASK"
  expect_code 0 "$RC" "the proven commit should still land: $OUT"
  assert_present "$fakebin/moved" "the fixture never moved the branch, so the case proves nothing"
  [ "$(git -C "$PROJ" rev-parse "fm/$TASK")" = "$later" ] || fail "the fixture did not move the ship branch"
  [ "$(main_head)" = "$TIP" ] || fail "a commit that arrived after the proof check must not land"
  assert_contains "$OUT" "moved after its landing proof was checked" "the merge should say the branch moved"
  assert_grep "task=$TASK project=sample commit=$TIP mode=require proven" \
    "$HOME_DIR/state/landing-proofs.log" "the history should name the commit that landed"
  pass "fm-landing-proof: the commit that lands is the commit that was proven, even if the branch moves meanwhile"
}

test_recorded_log_must_stay_byte_identical() {
  make_case hash
  rules require
  gate_log "$TMP_ROOT/hash/elsewhere/gate.log" "$TIP"
  parity_log "$TMP_ROOT/hash/elsewhere/parity.log" "$TIP"
  run "$PROOF" write "$TASK" --proof "gate=$TMP_ROOT/hash/elsewhere/gate.log" \
    --proof "parity=$TMP_ROOT/hash/elsewhere/parity.log"
  expect_code 0 "$RC" "both logs should be recorded: $OUT"
  run "$PROOF" gate "$TASK"
  expect_code 0 "$RC" "the recorded proofs should pass the gate: $OUT"
  # Same pass line, different bytes: the record no longer describes this file,
  # and the file is outside the folder the gate may search on its own.
  printf 'a later run appended this\n' >> "$TMP_ROOT/hash/elsewhere/gate.log"
  run "$PROOF" gate "$TASK"
  expect_code 1 "$RC" "a recorded log that changed must not be taken on the record's word: $OUT"
  assert_contains "$OUT" "missing gate." "only the changed log should stop counting"
  pass "fm-landing-proof: a recorded proof is trusted only while its log is byte-identical"
}

test_no_mode_line_means_warn() {
  make_case nomode
  printf 'sample proof gate ^FULL CI GATE PASSED commit=@COMMIT@$\n' > "$HOME_DIR/config/landing-proof"
  run "$MERGE_LOCAL" "$TASK"
  expect_code 0 "$RC" "proof rules with no mode line should warn and merge: $OUT"
  assert_contains "$OUT" "warning: no landing proof for $TASK" "the shortfall should be reported"
  assert_grep "commit=$TIP mode=warn missing=gate" "$HOME_DIR/state/landing-proofs.log" \
    "the history should record warn mode"
  pass "fm-landing-proof: proof rules with no mode line are warn"
}

test_discovery_depth_and_order() {
  make_case depth
  rules require
  parity_log "$HOME_DIR/data/$TASK/final-parity.log" "$TIP"
  gate_log "$HOME_DIR/data/$TASK/a/b/final-gate.log" "$TIP"
  mkdir -p "$TMP_ROOT/depth/outside"
  gate_log "$TMP_ROOT/depth/outside/final-gate.log" "$TIP"
  ln -s "$TMP_ROOT/depth/outside" "$HOME_DIR/data/$TASK/linked"
  run "$PROOF" gate "$TASK"
  expect_code 1 "$RC" "a log three levels down or behind a symlinked folder must not be found: $OUT"
  assert_contains "$OUT" "missing gate." "only the gate should be missing"
  gate_log "$HOME_DIR/data/$TASK/older/final-gate.log" "$TIP"
  gate_log "$HOME_DIR/data/$TASK/newer/final-gate.log" "$TIP"
  fm_touch_epoch 1790000000 "$HOME_DIR/data/$TASK/older/final-gate.log"
  fm_touch_epoch 1790003600 "$HOME_DIR/data/$TASK/newer/final-gate.log"
  run "$PROOF" gate "$TASK"
  expect_code 0 "$RC" "a log one directory down should be found: $OUT"
  assert_grep "proof.gate.log=$HOME_DIR/data/$TASK/newer/final-gate.log" \
    "$HOME_DIR/state/$TASK.landing-proof" "the newest proving log should be the one recorded"
  pass "fm-landing-proof: discovery stops one directory down, skips symlinked folders and prefers the newest log"
}

test_rules_file_must_be_readable() {
  make_case unreadable
  rules require
  if [ "$(id -u)" -eq 0 ]; then
    pass "fm-landing-proof: unreadable rules refuse the merge (skipped: root reads any file)"
    return 0
  fi
  chmod 000 "$HOME_DIR/config/landing-proof"
  run "$MERGE_LOCAL" "$TASK"
  chmod 600 "$HOME_DIR/config/landing-proof"
  expect_code 1 "$RC" "rules that cannot be read must refuse, not read as nothing required: $OUT"
  assert_contains "$OUT" "config/landing-proof must be a readable regular file" "the refusal should say why"
  [ "$(main_head)" = "$BASE" ] || fail "unreadable rules must not let a merge through"
  pass "fm-landing-proof: unreadable rules refuse the merge"
}

test_rules_file_encodings() {
  make_case encodings
  # A byte-order mark must not turn line 1 into another project's rule.
  printf '\357\273\277sample mode require\nsample proof gate ^FULL CI GATE PASSED commit=@COMMIT@$\n' \
    > "$HOME_DIR/config/landing-proof"
  run "$MERGE_LOCAL" "$TASK"
  expect_code 1 "$RC" "a byte-order mark must not drop the require line: $OUT"
  assert_contains "$OUT" "missing gate." "the proof rule should still apply"
  # UTF-16 is not plain text; nothing in it may be read as a rule or skipped.
  python3 -c 'import sys; sys.stdout.buffer.write(("﻿" + sys.argv[1]).encode("utf-16-le"))' \
    'sample mode require
sample proof gate ^FULL CI GATE PASSED commit=@COMMIT@$
' > "$HOME_DIR/config/landing-proof" || fail "could not write the UTF-16 fixture"
  run "$MERGE_LOCAL" "$TASK"
  expect_code 1 "$RC" "a UTF-16 rules file must refuse: $OUT"
  assert_contains "$OUT" "config/landing-proof line 1" "the refusal should name the first line"
  # Windows line endings and a last line without a newline are still plain text.
  printf 'sample mode require\r\nsample proof gate ^FULL CI GATE PASSED commit=@COMMIT@$\r\nsample proof parity ^PRIVATE ALL [0-9]+ SUITES PARITY PASSED commit=@COMMIT@$' \
    > "$HOME_DIR/config/landing-proof"
  gate_log "$HOME_DIR/data/$TASK/final-gate.log" "$TIP"
  parity_log "$HOME_DIR/data/$TASK/final-parity.log" "$TIP"
  run "$MERGE_LOCAL" "$TASK"
  expect_code 0 "$RC" "CRLF rules without a final newline should parse: $OUT"
  [ "$(main_head)" = "$TIP" ] || fail "the proven commit should land"
  [ "$(main_head)" != "$BASE" ] || fail "the default branch did not move"
  pass "fm-landing-proof: a byte-order mark and CRLF are read, and a file that is not plain text refuses"
}

test_more_malformed_rules_refuse() {
  local case_name body want
  make_case malformed-more
  while IFS='|' read -r case_name want body; do
    [ -n "$case_name" ] || continue
    printf '%b' "$body" > "$HOME_DIR/config/landing-proof"
    run "$MERGE_LOCAL" "$TASK"
    expect_code 1 "$RC" "$case_name must refuse: $OUT"
    assert_contains "$OUT" "$want" "$case_name should explain itself"
    [ "$(main_head)" = "$BASE" ] || fail "$case_name must not let a merge through"
  done <<'CASES'
duplicate proof|line 3: proof gate is defined twice|sample mode warn\nsample proof gate ^A @COMMIT@$\nsample proof gate ^B @COMMIT@$\n
missing expression|line 1: proof gate has no expression|sample proof gate\n
duplicate mode|line 2: mode is set twice|sample mode warn\nsample mode require\nsample proof gate ^A @COMMIT@$\n
mode with nothing to require|sets a mode for sample but no proof rule|sample mode require\n
bad line for another project|line 1: mode must be warn or require|elsewhere mode strict\nsample proof gate ^A @COMMIT@$\n
project token only|line 1: expected 'mode' or 'proof'|sample\n
CASES
  rm -f "$HOME_DIR/config/landing-proof"
  mkdir "$HOME_DIR/config/landing-proof"
  run "$MERGE_LOCAL" "$TASK"
  expect_code 1 "$RC" "a rules path that is not a regular file must refuse: $OUT"
  [ "$(main_head)" = "$BASE" ] || fail "a non-regular rules path must not let a merge through"
  pass "fm-landing-proof: every malformed shape of the rules file refuses, whichever project the bad line names"
}

test_sha256_repository() {
  local dir="$TMP_ROOT/sha256"
  HOME_DIR="$dir/home"
  PROJ="$dir/sample"
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data/$TASK" "$PROJ"
  if ! git -C "$PROJ" init -q -b main --object-format=sha256 2>/dev/null; then
    pass "fm-landing-proof: a SHA-256 repository can land (skipped: this git cannot create one)"
    return 0
  fi
  commit_file "$PROJ" README.md
  git -C "$PROJ" checkout -q -b "fm/$TASK"
  commit_file "$PROJ" change
  TIP=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$PROJ" checkout -q main
  printf 'project=%s\nmode=local-only\nbranch=fm/%s\n' "$PROJ" "$TASK" > "$HOME_DIR/state/$TASK.meta"
  [ "${#TIP}" -eq 64 ] || fail "the fixture is not a SHA-256 repository"
  rules require
  gate_log "$HOME_DIR/data/$TASK/final-gate.log" "$TIP"
  parity_log "$HOME_DIR/data/$TASK/final-parity.log" "$TIP"
  run "$MERGE_LOCAL" "$TASK"
  expect_code 0 "$RC" "a 64-digit commit id should be accepted: $OUT"
  [ "$(main_head)" = "$TIP" ] || fail "the proven commit should land"
  pass "fm-landing-proof: a SHA-256 repository can land"
}

test_waiver_survives_a_later_write_and_is_recorded() {
  make_case waiver-write
  rules require
  gate_log "$TMP_ROOT/waiver-write/gate.log" "$TIP"
  run "$PROOF" waive "$TASK" --reason "gate script change, reviewed"
  expect_code 0 "$RC" "the waiver should be recorded: $OUT"
  run "$PROOF" write "$TASK" --proof "gate=$TMP_ROOT/waiver-write/gate.log"
  expect_code 0 "$RC" "a proof recorded after a waiver should be accepted: $OUT"
  run "$MERGE_LOCAL" "$TASK"
  expect_code 0 "$RC" "the waiver should still be in force after a later write: $OUT"
  assert_contains "$OUT" "waived for $TASK" "the gate should say the proof was waived"
  assert_grep "commit=$TIP mode=require waived reason=gate script change, reviewed" \
    "$HOME_DIR/state/landing-proofs.log" "the history should record the waiver and its reason"
  run "$MERGE_LOCAL" "$TASK"
  expect_code 0 "$RC" "re-running the merge on a landed task should still succeed: $OUT"
  [ "$(grep -c "task=$TASK " "$HOME_DIR/state/landing-proofs.log")" -eq 1 ] \
    || fail "a landing must be recorded once, however often the merge is re-run"
  make_case waiver-norules
  printf 'elsewhere proof gate ^ELSEWHERE @COMMIT@$\n' > "$HOME_DIR/config/landing-proof"
  run "$PROOF" waive "$TASK" --reason "nothing to waive here"
  expect_code 1 "$RC" "a waiver for a project with no rules should be refused: $OUT"
  assert_absent "$HOME_DIR/state/$TASK.landing-proof" "no record should be written for a project with no rules"
  pass "fm-landing-proof: a waiver survives a later write, is recorded once, and needs rules to waive"
}

test_teardown_removes_the_record() {
  # The record is per-task state; bin/fm-teardown.sh's cleanup list must name
  # it or every landed task leaves one file behind. Driving a full teardown
  # needs a spawned fixture, so this pins the list entry itself.
  grep -F -q '"$STATE/$ID.landing-proof"' "$ROOT/bin/fm-teardown.sh" \
    || fail "bin/fm-teardown.sh no longer removes state/<id>.landing-proof at cleanup"
  pass "fm-landing-proof: task cleanup removes the per-task record"
}

test_unconfigured_home_lands_as_before
test_unnamed_project_lands_as_before
test_warn_mode_reports_and_merges
test_require_mode_refuses_without_proof
test_require_mode_lands_the_proven_commit
test_proof_for_an_earlier_commit_does_not_count
test_branch_that_moved_needs_new_proof
test_recorded_log_must_still_hold_its_line
test_symlinked_log_is_never_proof
test_waiver_is_explicit_and_bound_to_one_commit
test_write_records_named_logs
test_malformed_rules_refuse
test_usage_errors
test_landed_commit_is_the_proven_commit
test_recorded_log_must_stay_byte_identical
test_no_mode_line_means_warn
test_discovery_depth_and_order
test_rules_file_must_be_readable
test_rules_file_encodings
test_more_malformed_rules_refuse
test_sha256_repository
test_waiver_survives_a_later_write_and_is_recorded
test_teardown_removes_the_record
