#!/usr/bin/env bash
# Launch-time version proof, remote guarded convergence, and tracked-bin drift.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP=$(fm_test_tmproot fm-secondmate-launch-freshness)
CODE="$TMP/code"
MATE="$TMP/mate"
mkdir -p "$CODE"
cp -R "$ROOT/bin" "$CODE/bin"
printf 'fixture\n' > "$CODE/AGENTS.md"
printf 'config/\ndata/\nstate/\n.fm-secondmate-home\n' > "$CODE/.gitignore"
git -C "$CODE" init -q -b main
fm_git_identity Fixture fixture.invalid
git -C "$CODE" add .
git -C "$CODE" commit -qm initial
OLD=$(git -C "$CODE" rev-parse HEAD)
git clone -q --no-local "$CODE" "$MATE"
printf 'mate\n' > "$MATE/.fm-secondmate-home"
mkdir -p "$MATE/state" "$MATE/data" "$MATE/config"
printf 'new\n' > "$CODE/bin/version-fixture"
git -C "$CODE" add bin/version-fixture
git -C "$CODE" commit -qm next
NEW=$(git -C "$CODE" rev-parse HEAD)
control() {
  FM_HOME="$MATE" FM_ROOT_OVERRIDE="$CODE" bash "$CODE/bin/fm-remote-secondmate-control.sh" "$@"
}
OUT=$(control prepare-launch mate "$NEW") || fail "remote prelaunch convergence failed: $OUT"
[ "$(git -C "$MATE" rev-parse HEAD)" = "$NEW" ] || fail "home did not converge before launch"
[ "$(cat "$MATE/bin/version-fixture")" = new ] || fail "home bin was stale"
pass "remote prelaunch guarded-syncs the home before allowing launch"
OUT=$(control prepare-launch mate "$OLD" 2>&1) && fail "mismatched code root was accepted"
assert_contains "$OUT" "$OLD" "refusal omitted requested primary commit"
assert_contains "$OUT" "$NEW" "refusal omitted actual remote commit"
pass "code-root mismatch refuses with both commits"
# Keep the parent's expected commit through to the actual lifecycle call,
# rather than accepting any two copies that happen to match one another.
OUT=$(control launch mate claude default - herdr '' "$OLD" 2>&1) && fail "launch forgot the parent's expected commit"
assert_contains "$OUT" "$NEW" "launch refusal omitted the current remote commit"
assert_contains "$OUT" "$OLD" "launch refusal omitted the parent commit"
OUT=$(control relaunch mate claude default default "$OLD" 2>&1) && fail "relaunch forgot the parent's expected commit"
assert_contains "$OUT" "$OLD" "relaunch refusal omitted the parent commit"
pass "host-local launch and relaunch recheck the exact parent commit at the boundary"
printf 'dirty\n' >> "$CODE/bin/version-fixture"
OUT=$(control prepare-launch mate "$NEW" 2>&1) && fail "modified code-root bin was accepted"
assert_contains "$OUT" 'tracked bin/ differs' "code-root drift was not diagnosed"
pass "modified code-root scripts refuse launch"
# Restore only this fixture's deliberate modification.
printf 'new\n' > "$CODE/bin/version-fixture"
printf 'dirty\n' >> "$MATE/bin/version-fixture"
git -C "$MATE" add bin/version-fixture
OUT=$(control prepare-launch mate "$NEW" 2>&1) && fail "staged home bin drift was accepted"
assert_contains "$OUT" 'dirty working tree' "staged home drift was not diagnosed"
pass "same HEAD with staged home bin drift refuses launch"
# The local spawn and pre-stop relaunch use this same public library proof.
# shellcheck source=bin/fm-ff-lib.sh
. "$ROOT/bin/fm-ff-lib.sh"
OUT=$(require_secondmate_launch_freshness "$MATE" "$NEW" 2>&1) && fail "local proof accepted drift"
assert_contains "$OUT" "$NEW" "local refusal omitted the launch commit"
pass "local launch/relaunch proof rejects drift too"
