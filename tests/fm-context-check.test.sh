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
#   5. A Pi session compacted since its last assistant turn is unknown rather
#      than over, until the next turn is measured; unknown carries the limit.
#   6. Each --allow-large-context use on a steer the gate covers appends one
#      line to state/context-bypass.log (measured context, limit, over) and
#      notes an over-limit target on stderr, without changing the send; the
#      measure is bounded, FM_SEND_CONTEXT_CHECK=0 records nothing, and the
#      log is size-capped.
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

pi_compaction_line() {  # <tokensBefore>
  printf '{"type":"compaction","id":"c1","parentId":"a1","timestamp":"2026-11-04T10:05:00.000Z","summary":"earlier work","firstKeptEntryId":"k1","tokensBefore":%s}\n' "$1"
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
  assert_contains "$res" "context: unknown · limit: 250000 · " "unknown should be stated, with the limit it was read against"
  res=$(run_check "$home" -- missing-task)
  expect_code 4 "${res%%$'\t'*}" "a missing task record should be unknown: $res"
  res=$(run_check "$home" --)
  expect_code 2 "${res%%$'\t'*}" "no argument is a usage error: $res"
  pass "fm-context-check: unknown context exits 4 and no target exits 2"
}

test_pi_compaction_since_last_turn_is_unknown() {
  local home root dir res
  home=$(make_home pi-compacted pi)
  root="$home/pi-root"
  dir=$(pi_session_dir "$root" "$home/wt")
  mkdir -p "$dir"
  { printf '{"type":"session"}\n'; pi_line 1 300000 0; pi_compaction_line 300001; } > "$dir/s.jsonl"
  res=$(run_check "$home" PI_CODING_AGENT_DIR="$root" -- t1)
  expect_code 4 "${res%%$'\t'*}" "a Pi session compacted since its last turn should be unknown, not over: $res"
  assert_contains "$res" "context: unknown · limit: 250000 · session compacted at 2026-11-04T10:05:00.000Z from 300001 tokens" \
    "the reason should name the compaction and the size it replaced"
  pi_line 2 40000 0 >> "$dir/s.jsonl"
  res=$(run_check "$home" PI_CODING_AGENT_DIR="$root" -- t1)
  expect_code 0 "${res%%$'\t'*}" "the first turn after a compaction should be measured again: $res"
  assert_contains "$res" "context: 40002 · limit: 250000 · over: no" "the turn after the compaction should win"
  pass "fm-context-check: a Pi session compacted since its last turn is unknown until the next turn"
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
  env -u FM_CREW_CONTEXT_LIMIT -u FM_SEND_CONTEXT_CHECK -u FM_SEND_CONTEXT_CHECK_BUDGET \
    PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$home" FM_HOME="$home" FM_SEND_SETTLE=0 \
    ${envs[@]+"${envs[@]}"} "$SEND" "$@" > "$home/send.out" 2> "$home/send.err" || rc=$?
  return "$rc"
}

# The bypass record's line count, 0 while the log does not exist.
bypass_lines() {  # <home>
  local n=0
  [ ! -f "$1/state/context-bypass.log" ] || n=$(wc -l < "$1/state/context-bypass.log" | tr -d '[:space:]')
  printf '%s' "$n"
}

# Assert the newest bypass record is "<UTC stamp> <expected fields>".
expect_last_bypass() {  # <home> <fields> <message>
  local last
  last=$(tail -n 1 "$1/state/context-bypass.log" 2>/dev/null || true)
  printf '%s\n' "$last" | grep -Eq "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z $2\$" \
    || fail "$3: expected '<UTC stamp> $2', got '$last'"
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
  assert_grep "recorded in state/context-bypass.log" "$home/send.err" "the refusal should say a bypass is recorded"
  [ ! -e "$home/state/t1.inbox/001.msg" ] || fail "a refused steer must not be recorded"
  [ "$(bypass_lines "$home")" = 0 ] || fail "a refused steer must not write the bypass record"
  rc=0
  send "$home" PI_CODING_AGENT_DIR="$root" -- t1 --allow-large-context "answer before handoff" || rc=$?
  expect_code 0 "$rc" "--allow-large-context should send the steer: $(cat "$home/send.err")"
  [ -f "$home/state/t1.inbox/001.msg" ] || fail "the allowed steer should be recorded"
  [ ! -s "$home/send.out" ] || fail "a bypassed send must keep its empty stdout: $(cat "$home/send.out")"
  [ "$(bypass_lines "$home")" = 1 ] \
    || fail "one bypass should append exactly one line: $(cat "$home/state/context-bypass.log" 2>&1)"
  expect_last_bypass "$home" "task=t1 context=300001 limit=250000 over=yes" "an over-limit bypass"
  assert_grep "t1 is at 300001 context tokens, past the crew context limit of 250000" "$home/send.err" \
    "an over-limit bypass should note the measured size and the limit"
  assert_grep "A relaunch with a fresh session resets the context" "$home/send.err" \
    "the note should say what resets the context"
  rc=0
  send "$home" PI_CODING_AGENT_DIR="$TMP_ROOT/no-pi" -- t1 "unknown context" || rc=$?
  expect_code 0 "$rc" "unknown context must never block a steer: $(cat "$home/send.err")"
  [ "$(bypass_lines "$home")" = 1 ] || fail "a steer sent without the flag must not write the bypass record"
  pass "fm-send: refuses a text steer past the crew context limit unless --allow-large-context, which is recorded"
}

test_fm_send_bypass_record_cases() {
  local home root dir rc log i before
  home=$(make_home bypass pi)
  make_tmux_stub "$home"
  root="$home/pi-root"
  dir=$(pi_session_dir "$root" "$home/wt")
  mkdir -p "$dir"
  log="$home/state/context-bypass.log"
  { printf '{"type":"session"}\n'; pi_line 1 100000 0; } > "$dir/s.jsonl"
  # 4000 earlier records, about 280 KB: past the 262144-byte cap.
  i=0
  while [ "$i" -lt 4000 ]; do
    printf '2026-11-01T00:00:00Z task=old-%04d context=100000 limit=250000 over=no\n' "$i"
    i=$((i + 1))
  done > "$log"

  # Under the limit: the bypass was not needed, which is exactly what the record
  # is for. This send also crosses the size cap.
  rc=0
  send "$home" PI_CODING_AGENT_DIR="$root" -- t1 --allow-large-context "habit" || rc=$?
  expect_code 0 "$rc" "the flag on a task under the limit must send: $(cat "$home/send.err")"
  expect_last_bypass "$home" "task=t1 context=100001 limit=250000 over=no" "a bypass the task did not need"
  assert_no_grep "context tokens" "$home/send.err" "a task under the limit gets no over-limit note"
  [ "$(bypass_lines "$home")" = 2000 ] \
    || fail "past the size cap the record should be trimmed to its newest 2000 lines, got $(bypass_lines "$home")"
  [ "$(head -n 1 "$log")" = "2026-11-01T00:00:00Z task=old-2001 context=100000 limit=250000 over=no" ] \
    || fail "the trim should keep the newest earlier records: $(head -n 1 "$log")"
  [ -z "$(find "$home/state" -maxdepth 1 -name 'context-bypass.log.tmp.*')" ] || fail "the trim left its temp file behind"

  # Over the limit at its last turn, then compacted: the stale turn must not be
  # recorded as an over-limit bypass.
  { pi_line 2 300000 0; pi_compaction_line 300002; } >> "$dir/s.jsonl"
  rc=0
  send "$home" PI_CODING_AGENT_DIR="$root" -- t1 --allow-large-context "after the compaction" || rc=$?
  expect_code 0 "$rc" "the flag on a compacted session must send: $(cat "$home/send.err")"
  expect_last_bypass "$home" "task=t1 context=unknown limit=250000 over=unknown" "a bypass on a just-compacted session"
  assert_no_grep "context tokens" "$home/send.err" "an unknown context gets no over-limit note"
  [ "$(bypass_lines "$home")" = 2001 ] || fail "a record under the cap should only be appended to"

  before=$(cat "$log")
  rc=0
  send "$home" PI_CODING_AGENT_DIR="$root" FM_SEND_CONTEXT_CHECK=0 -- t1 --allow-large-context "check off" || rc=$?
  expect_code 0 "$rc" "FM_SEND_CONTEXT_CHECK=0 must send: $(cat "$home/send.err")"
  rc=0
  send "$home" PI_CODING_AGENT_DIR="$root" -- sess:fm-t1 --allow-large-context "explicit endpoint" || rc=$?
  expect_code 0 "$rc" "an explicit backend target must not be affected by the flag: $(cat "$home/send.err")"
  [ "$(cat "$log")" = "$before" ] \
    || fail "FM_SEND_CONTEXT_CHECK=0 and an explicit endpoint must record nothing: $(tail -n 3 "$log")"
  pass "fm-send: the bypass record says whether the bypass was needed, is size-capped, and covers only gated steers"
}

test_fm_send_bypass_measure_is_bounded() {
  local home root dir rc started elapsed
  home=$(make_home bypass-slow pi)
  make_tmux_stub "$home"
  root="$home/pi-root"
  dir=$(pi_session_dir "$root" "$home/wt")
  mkdir -p "$dir"
  { printf '{"type":"session"}\n'; pi_line 1 300000 0; } > "$dir/s.jsonl"
  # A measure that never returns: tac is the session file's only reader, and
  # nothing on the send path itself runs it. The real sleep, because the
  # stubbed one on PATH returns immediately.
  printf '#!/usr/bin/env bash\n/bin/sleep 60\n' > "$home/fakebin/tac"
  chmod +x "$home/fakebin/tac"
  started=$(date +%s)
  rc=0
  send "$home" PI_CODING_AGENT_DIR="$root" FM_SEND_CONTEXT_CHECK_BUDGET=1 -- t1 --allow-large-context "must still land" || rc=$?
  elapsed=$(($(date +%s) - started))
  expect_code 0 "$rc" "a hung measure must not fail the send: $(cat "$home/send.err")"
  [ "$elapsed" -lt 30 ] || fail "a hung measure held the send for ${elapsed}s past its 1-second bound"
  [ -f "$home/state/t1.inbox/001.msg" ] || fail "the steer should be recorded despite the hung measure"
  expect_last_bypass "$home" "task=t1 context=unknown limit=unknown over=unknown" "a bypass whose measure hit the bound"
  pass "fm-send: a hung bypass measure is cut at its bound, recorded unknown, and the steer still lands"
}

test_pi_task_reads_newest_session_since_spawn
test_pi_account_pin_root_wins
test_claude_task_skips_synthetic_and_sidechain
test_limit_knobs_and_session_path
test_unknown_cases_exit_4
test_pi_compaction_since_last_turn_is_unknown
test_fm_send_refuses_steer_past_limit
test_fm_send_bypass_record_cases
test_fm_send_bypass_measure_is_bounded
