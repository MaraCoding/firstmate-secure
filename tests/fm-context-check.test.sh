#!/usr/bin/env bash
# tests/fm-context-check.test.sh - live crewmate context size and the steer gate.
#
# Pins:
#   1. A Pi task resolves its session under the account root's sessions dir by
#      worktree, and reports the last assistant turn's input + cacheRead +
#      cacheWrite; sessions written before the task's spawn are ignored.
#   2. A Claude task resolves its transcript under <config>/projects/<encoded
#      worktree> and sums input + cache read + cache creation, skipping
#      synthetic and sidechain rows.
#   3. The limit comes from --limit, FM_CREW_CONTEXT_LIMIT, config/crew-context-limit,
#      then 250000; over it exits 3, unknown exits 4, a bad knob exits 2.
#   4. fm-send refuses a text steer to a ship past the limit, sends it with
#      --allow-large-context, and never blocks a task whose context is unknown.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-context-check.sh"
SEND="$ROOT/bin/fm-send.sh"
TMP_ROOT=$(fm_test_tmproot fm-context-check)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
NOW=$(date +%s)

pi_line() {  # <input> <cacheRead> <cacheWrite>
  printf '{"type":"message","timestamp":"2026-11-04T10:00:00Z","message":{"role":"assistant","model":"gpt-6.1-sol","usage":{"input":%s,"output":10,"cacheRead":%s,"cacheWrite":%s,"totalTokens":0}}}\n' "$1" "$2" "$3"
}

claude_line() {  # <input> <read> <create> [model] [sidechain]
  printf '{"type":"assistant","isSidechain":%s,"timestamp":"2026-11-04T10:00:00Z","message":{"model":"%s","usage":{"input_tokens":%s,"cache_read_input_tokens":%s,"cache_creation_input_tokens":%s,"output_tokens":5}}}\n' \
    "${5:-false}" "${4:-claude-opus-5-5}" "$1" "$2" "$3"
}

make_home() {  # <name> <harness> [extra meta...] -> echoes home; worktree is <home>/wt
  local home="$TMP_ROOT/$1" harness=$2
  shift 2
  mkdir -p "$home/state" "$home/config" "$home/wt"
  fm_write_meta "$home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=$harness" \
    "worktree=$home/wt" "spawn_gen=s$NOW.1.1" "$@"
  printf '%s\n' "$home"
}

pi_session_dir() {  # <pi-root> <worktree>
  local enc=${2#/}
  printf '%s/sessions/--%s--' "$1" "${enc//\//-}"
}

run_check() {  # <home> [env...] -- <args...>; prints "rc<TAB>output"
  local home=$1 out rc=0
  shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  out=$(env -u FM_CREW_CONTEXT_LIMIT FM_HOME="$home" FM_ROOT_OVERRIDE="$home" ${envs[@]+"${envs[@]}"} "$CHECK" "$@" 2>&1) || rc=$?
  printf '%s\t%s' "$rc" "$out"
}

test_pi_task_reads_newest_session_since_spawn() {
  local home root dir res
  home=$(make_home pi pi)
  root="$home/pi-root"
  dir=$(pi_session_dir "$root" "$home/wt")
  mkdir -p "$dir"
  { printf '{"type":"session","cwd":"%s"}\n' "$home/wt"; pi_line 999 999999 0; } > "$dir/old.jsonl"
  touch -d "@$((NOW - 7200))" "$dir/old.jsonl"
  { printf '{"type":"session","cwd":"%s"}\n' "$home/wt"; pi_line 100 200000 50; pi_line 7 0 0 | sed 's/"assistant"/"user"/'; } > "$dir/new.jsonl"
  res=$(run_check "$home" PI_CODING_AGENT_DIR="$root" -- t1)
  expect_code 0 "${res%%$'\t'*}" "a Pi session under the limit should exit 0: $res"
  assert_contains "$res" "context: 200150 · limit: 250000 · over: no · harness: pi · model: gpt-6.1-sol" \
    "Pi context should sum input, cacheRead and cacheWrite of the last assistant turn"
  assert_contains "$res" "session: $dir/new.jsonl" "the session written since the spawn should win"
  pass "fm-context-check: Pi task resolves its session by worktree and spawn time"
}

test_pi_account_pin_root_wins() {
  local home acct dir res
  acct="$TMP_ROOT/pi-acct-root"
  home=$(make_home pi-acct pi "account=$acct")
  dir=$(pi_session_dir "$acct" "$home/wt")
  mkdir -p "$dir"
  { printf '{"type":"session"}\n'; pi_line 1 260000 0; } > "$dir/s.jsonl"
  res=$(run_check "$home" PI_CODING_AGENT_DIR="$TMP_ROOT/nowhere" -- t1)
  expect_code 3 "${res%%$'\t'*}" "a Pi session past the limit should exit 3: $res"
  assert_contains "$res" "context: 260001 · limit: 250000 · over: yes" "the pinned account root should be read"
  pass "fm-context-check: a pinned Pi account root is where the session is read"
}

test_claude_task_skips_synthetic_and_sidechain() {
  local home cfg dir res
  home=$(make_home claude claude)
  cfg="$home/claude-cfg"
  dir="$cfg/projects/$(printf '%s' "$home/wt" | sed 's/[^A-Za-z0-9]/-/g')"
  mkdir -p "$dir"
  { claude_line 3 120000 4000; claude_line 1 900000 0 claude-opus-5-5 true; claude_line 0 0 0 '<synthetic>'; } > "$dir/abc.jsonl"
  res=$(run_check "$home" CLAUDE_CONFIG_DIR="$cfg" -- t1)
  expect_code 0 "${res%%$'\t'*}" "a Claude transcript under the limit should exit 0: $res"
  assert_contains "$res" "context: 124003 · limit: 250000 · over: no · harness: claude · model: claude-opus-5-5" \
    "Claude context should come from the last main-chain, non-synthetic turn"
  pass "fm-context-check: Claude task sums input and cache tokens of the last real turn"
}

test_limit_knobs_and_session_path() {
  local home f res
  home=$(make_home knobs claude)
  f="$TMP_ROOT/direct.jsonl"
  claude_line 0 150000 0 > "$f"
  res=$(run_check "$home" -- "$f")
  expect_code 0 "${res%%$'\t'*}" "the default limit is 250000: $res"
  printf '100000\n' > "$home/config/crew-context-limit"
  res=$(run_check "$home" -- "$f")
  expect_code 3 "${res%%$'\t'*}" "config/crew-context-limit should lower the limit: $res"
  res=$(run_check "$home" FM_CREW_CONTEXT_LIMIT=200000 -- "$f")
  expect_code 0 "${res%%$'\t'*}" "FM_CREW_CONTEXT_LIMIT should override the config file: $res"
  res=$(run_check "$home" FM_CREW_CONTEXT_LIMIT=200000 -- --limit 140000 "$f")
  expect_code 3 "${res%%$'\t'*}" "--limit should override the environment: $res"
  printf 'lots\n' > "$home/config/crew-context-limit"
  res=$(run_check "$home" -- "$f")
  expect_code 2 "${res%%$'\t'*}" "a malformed config/crew-context-limit should be a usage error: $res"
  pass "fm-context-check: --limit, FM_CREW_CONTEXT_LIMIT, config/crew-context-limit, default 250000"
}

test_unknown_cases_exit_4() {
  local home res
  home=$(make_home unknown pi)
  res=$(run_check "$home" PI_CODING_AGENT_DIR="$TMP_ROOT/empty-pi" -- t1)
  expect_code 4 "${res%%$'\t'*}" "no session should be unknown: $res"
  assert_contains "$res" "context: unknown" "unknown should be stated"
  res=$(run_check "$home" -- missing-task)
  expect_code 4 "${res%%$'\t'*}" "a missing task record should be unknown: $res"
  res=$(run_check "$home" --)
  expect_code 2 "${res%%$'\t'*}" "no argument is a usage error: $res"
  pass "fm-context-check: unknown context exits 4 and no target exits 2"
}

make_tmux_stub() {  # <dir>
  mkdir -p "$1/fakebin"
  cat > "$1/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done; printf 'fakepane\n' ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) printf 'fm-t1\nwin\n' ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/fakebin/sleep"
  chmod +x "$1/fakebin/tmux" "$1/fakebin/sleep"
}

send() {  # <home> [env...] -- <args>
  local home=$1 rc=0
  shift
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env -u FM_CREW_CONTEXT_LIMIT PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_SETTLE=0 \
    ${envs[@]+"${envs[@]}"} "$SEND" "$@" > /dev/null 2> "$home/send.err" || rc=$?
  return "$rc"
}

test_fm_send_refuses_steer_past_limit() {
  local home root dir rc
  home=$(make_home send pi)
  make_tmux_stub "$home"
  root="$home/pi-root"
  dir=$(pi_session_dir "$root" "$home/wt")
  mkdir -p "$dir"
  { printf '{"type":"session"}\n'; pi_line 1 300000 0; } > "$dir/s.jsonl"
  rc=0
  send "$home" PI_CODING_AGENT_DIR="$root" -- t1 "change the layout again" || rc=$?
  expect_code 1 "$rc" "a steer past the limit should be refused: $(cat "$home/send.err")"
  assert_grep "past the crew context limit" "$home/send.err" "the refusal should name the context limit"
  assert_grep "respawn it with a handoff brief" "$home/send.err" "the refusal should say what to do instead"
  [ ! -e "$home/state/t1.inbox/001.msg" ] || fail "a refused steer must not be recorded"
  rc=0
  send "$home" PI_CODING_AGENT_DIR="$root" -- t1 --allow-large-context "answer before handoff" || rc=$?
  expect_code 0 "$rc" "--allow-large-context should send the steer: $(cat "$home/send.err")"
  [ -f "$home/state/t1.inbox/001.msg" ] || fail "the allowed steer should be recorded"
  rc=0
  send "$home" PI_CODING_AGENT_DIR="$TMP_ROOT/no-pi" -- t1 "unknown context" || rc=$?
  expect_code 0 "$rc" "unknown context must never block a steer: $(cat "$home/send.err")"
  pass "fm-send: refuses a text steer past the crew context limit unless --allow-large-context"
}

test_pi_task_reads_newest_session_since_spawn
test_pi_account_pin_root_wins
test_claude_task_skips_synthetic_and_sidechain
test_limit_knobs_and_session_path
test_unknown_cases_exit_4
test_fm_send_refuses_steer_past_limit
