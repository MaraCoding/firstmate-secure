#!/usr/bin/env bash
# Behavior tests for the semantic busy-state contract (bin/fm-busy-lib.sh and
# its only writer bin/fm-busy-event.sh).
#
# Covers the captain-approved redesign invariants: busy/idle/unknown/dead with
# explicit source attribution; missing, malformed, stale (gen-mismatch), and
# untrusted (source-mismatch) semantic data classify unknown - never idle;
# adapter isolation (one adapter's writer or Grok's regex can never classify
# another adapter); endpoint death is the only process-level override and
# yields dead, never busy; converted adapters never classify from rendered
# footer text. It also pins the host-boot binding arm writes beside each gen and
# the restored-incarnation check that reads it, exact by boot id and
# conservative by clock for a gen armed before the binding existed.
# All hermetic over temp dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-busy-state)
EV="$ROOT/bin/fm-busy-event.sh"

new_state_dir() {  # <name>
  local d="$TMP_ROOT/$1/state"
  mkdir -p "$d"
  printf '%s' "$d"
}

# --- writer: arm and apply ---------------------------------------------------

test_arm_seeds_busy_spawn() {
  local state gen out
  state=$(new_state_dir arm-seed)
  gen=$("$EV" arm "$state" t1) || fail "arm failed"
  [ -f "$state/t1.busy-gen" ] || fail "arm did not write the gen sidecar"
  [ "$(cat "$state/t1.busy-gen")" = "$gen" ] || fail "sidecar gen does not match printed gen"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed should classify 'busy fm-spawn', got '$out'"
  pass "arm mints a gen sidecar and seeds busy fm-spawn at seq=1"
}

test_apply_advances_seq_and_source() {
  local state gen out seq
  state=$(new_state_dir apply-seq)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop \
    || fail "apply idle failed"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "idle claude-hook" ] || fail "expected 'idle claude-hook', got '$out'"
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit \
    || fail "apply busy failed"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy claude-hook" ] || fail "expected 'busy claude-hook', got '$out'"
  seq=$(fm_busy_record_read "$state" t1 | awk '{print $4}')
  [ "$seq" = 3 ] || fail "expected seq 3 after seed + two applies, got '$seq'"
  pass "apply advances seq under the armed gen and attributes the writing source"
}

test_apply_current_gen_reset() {
  local state out
  state=$(new_state_dir apply-current)
  "$EV" arm "$state" t1 >/dev/null
  "$EV" apply "$state" t1 idle --current-gen --source fm-interrupt --event interrupt \
    || fail "apply --current-gen failed"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "idle fm-interrupt" ] || fail "expected 'idle fm-interrupt', got '$out'"
  "$EV" apply "$state" t1 unknown --current-gen --source fm-recovery --event relaunch \
    || fail "apply unknown failed"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "unknown fm-recovery" ] || fail "expected 'unknown fm-recovery', got '$out'"
  pass "firstmate-owned interrupt and recovery events bind to the current gen"
}

test_apply_unarmed_refused() {
  local state
  state=$(new_state_dir apply-unarmed)
  if "$EV" apply "$state" t1 busy --gen g1.2.3 --source claude-hook --event x 2>/dev/null; then
    fail "apply against an unarmed task must be refused"
  fi
  [ ! -f "$state/t1.busy-state" ] || fail "refused apply must not write a record"
  pass "apply is refused for a task whose busy contract was never armed"
}

test_retire_serializes_and_rejects_stale_gen() {
  local state old_gen new_gen out retire_pid i=0
  state=$(new_state_dir retire)
  old_gen=$("$EV" arm "$state" t1)
  mkdir "$state/t1.busy-state.lock"
  "$EV" retire "$state" t1 --gen "$old_gen" >/dev/null 2>&1 &
  retire_pid=$!
  while [ "$i" -lt 20 ] && ! kill -0 "$retire_pid" 2>/dev/null; do
    i=$((i + 1))
  done
  [ -e "$state/t1.busy-state" ] || fail "retire bypassed the writer lock"
  rmdir "$state/t1.busy-state.lock"
  wait "$retire_pid" || fail "retire failed after acquiring the writer lock"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left the record behind"
  [ ! -e "$state/t1.busy-gen" ] || fail "retire left the gen sidecar behind"

  new_gen=$("$EV" arm "$state" t1)
  if "$EV" retire "$state" t1 --gen "$old_gen" 2>/dev/null; then
    fail "retire accepted a superseded incarnation"
  fi
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "stale retirement changed the new incarnation, got '$out'"
  [ "$(cat "$state/t1.busy-gen")" = "$new_gen" ] || fail "stale retirement changed the new gen"
  pass "retire waits for the writer lock and cannot remove a new incarnation"
}

# Regression for issue #2625: the writer lock's stale-lock branch resolved the
# lock's mtime with `stat -f %m ... || stat -c %Y ...`. On GNU coreutils `-f` is
# *filesystem* stat, so it consumes the format string as a path, complains on
# stderr, prints "  File: ..." on stdout, and still exits 0 - the GNU form in the
# fallback never ran. The following `$((now - mtime))` then evaluated the word
# `File`, which under `set -u` aborted the writer with "File: unbound variable".
# fm-teardown.sh died there after returning the worktree, leaving state/<id>.meta
# and friends behind to generate stale wakes forever, and every re-run died
# identically because the abandoned lock directory was never broken.
#
# The stat and uname stubs make this deterministic on any host: the writer must
# take the Linux path and still break a provably stale lock.
test_stale_lock_broken_under_gnu_stat() {
  local state gen fakebin real_uname out status
  state=$(new_state_dir gnu-stat-lock)
  gen=$("$EV" arm "$state" t1)
  fakebin=$(fm_fakebin "$TMP_ROOT/gnu-stat-lock")
  real_uname=$(command -v uname)

  # GNU coreutils semantics, self-contained so no real stat is consulted.
  cat > "$fakebin/stat" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = %Y ]; then
  printf '%s\n' 1000000000   # long-abandoned lock
  exit 0
fi
if [ "${1:-}" = -f ]; then
  echo "stat: cannot read file system information for '$2': No such file or directory" >&2
  shift 2
  printf '  File: "%s"\n' "${1:-}"
  exit 0
fi
exit 1
SH
  chmod +x "$fakebin/stat"
  cat > "$fakebin/uname" <<SH
#!/usr/bin/env bash
if [ \$# -eq 0 ]; then printf 'Linux\n'; exit 0; fi
exec "$real_uname" "\$@"
SH
  chmod +x "$fakebin/uname"

  mkdir "$state/t1.busy-state.lock"
  out=$(PATH="$fakebin:$PATH" "$EV" retire "$state" t1 --gen "$gen" 2>&1) && status=0 || status=$?
  case "$out" in
    *'unbound variable'*) fail "the writer still dies on GNU stat output: $out" ;;
  esac
  [ "$status" = 0 ] || fail "retire did not break a provably stale writer lock: $out"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left the record behind"
  [ ! -e "$state/t1.busy-gen" ] || fail "retire left the gen sidecar behind"
  [ ! -e "$state/t1.busy-state.lock" ] || fail "retire left the stale lock behind"

  # Teardown must be able to run again over the same task without failing.
  PATH="$fakebin:$PATH" "$EV" retire "$state" t1 --current-gen \
    || fail "a repeated retire over already-cleaned state was not idempotent"
  pass "the writer breaks a stale lock instead of dying on GNU stat output"
}

test_retire_missing_sidecar_is_idempotent() {
  local state gen
  state=$(new_state_dir retire-missing)
  gen=$("$EV" arm "$state" t1)
  rm -f "$state/t1.busy-gen"

  "$EV" retire "$state" t1 --gen "$gen" || fail "exact-gen retire rejected a missing sidecar"
  [ ! -e "$state/t1.busy-state" ] || fail "retire left an orphan record behind"
  "$EV" retire "$state" t1 --gen "$gen" || fail "repeated exact-gen retire was not idempotent"
  "$EV" retire "$state" t1 --current-gen || fail "current-gen retire was not idempotent"

  printf 'malformed gen\n' > "$state/t1.busy-gen"
  printf 'orphan\n' > "$state/t1.busy-state"
  if "$EV" retire "$state" t1 --gen "$gen" 2>/dev/null; then
    fail "retire accepted a malformed existing sidecar"
  fi
  [ -e "$state/t1.busy-state" ] || fail "retire removed the record for a malformed existing sidecar"
  pass "retire treats only an absent sidecar as already retired"
}

# --- stale event rejection ----------------------------------------------------

test_stale_gen_event_rejected() {
  local state old_gen new_gen out
  state=$(new_state_dir stale-event)
  old_gen=$("$EV" arm "$state" t1)
  new_gen=$("$EV" arm "$state" t1)
  [ "$old_gen" != "$new_gen" ] || fail "re-arm must mint a fresh gen"
  if "$EV" apply "$state" t1 idle --gen "$old_gen" --source claude-hook --event stop 2>/dev/null; then
    fail "an event carrying a stale gen must be rejected"
  fi
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "stale event must not change the record, got '$out'"
  pass "a late event from a previous incarnation is rejected, record unchanged"
}

test_stale_gen_record_unknown() {
  local state gen out
  state=$(new_state_dir stale-record)
  gen=$("$EV" arm "$state" t1)
  # Simulate a record left behind by a superseded incarnation.
  printf 'g-superseded.1.1\n' > "$state/t1.busy-gen.new"
  mv "$state/t1.busy-gen.new" "$state/t1.busy-gen"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown gen-mismatch" ] || fail "stale record must classify 'unknown gen-mismatch', got '$out'"
  pass "a record from a stale incarnation classifies unknown, never idle"
}

# --- missing and malformed semantic data --------------------------------------

test_missing_record_unknown_not_idle() {
  local state out h
  state=$(new_state_dir missing)
  for h in claude opencode pi pi-signed; do
    out=$(fm_busy_classify tmux w1 "$h" t1 "$state")
    [ "$out" = "unknown missing" ] || fail "$h with no record must be 'unknown missing', got '$out'"
  done
  out=$(fm_busy_classify tmux w1 codex t1 "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "codex with no verified source must be 'unknown codex-unverified', got '$out'"
  pass "a converted adapter with no record classifies unknown, never idle"
}

test_malformed_record_unknown() {
  local state gen out
  state=$(new_state_dir malformed)
  gen=$("$EV" arm "$state" t1)
  for bad in \
    'garbage' \
    "v0 gen=$gen seq=1 state=busy source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=NaN state=busy source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=1 state=frobbing source=claude-hook event=x ts=1" \
    "v1 gen=$gen seq=1 state=busy source=bad source event=x ts=1" \
    "v1 gen=$gen seq=1 state=busy source=claude-hook event=x ts=1 rogue=1"; do
    printf '%s\n' "$bad" > "$state/t1.busy-state"
    out=$(fm_busy_classify tmux w1 claude t1 "$state")
    [ "$out" = "unknown malformed" ] || fail "malformed record '$bad' must be 'unknown malformed', got '$out'"
  done
  printf 'v1 gen=%s seq=1 state=busy source=claude-hook event=x ts=1\nsecond line\n' "$gen" > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "multi-line record must be 'unknown malformed', got '$out'"
  pass "malformed records classify unknown malformed, never busy or idle"
}

test_record_without_sidecar_unknown() {
  local state out
  state=$(new_state_dir orphan-record)
  printf 'v1 gen=g1.1.1 seq=1 state=busy source=claude-hook event=x ts=1\n' > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "record without an armed gen must be unknown, got '$out'"
  pass "a record with no armed gen sidecar classifies unknown"
}

# --- adapter isolation ---------------------------------------------------------

test_source_mismatch_cross_adapter() {
  local state gen out
  state=$(new_state_dir cross-adapter)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source pi-ext --event agent-start
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown source-mismatch" ] || fail "pi-ext record on a claude task must be untrusted, got '$out'"
  out=$(fm_busy_classify tmux w1 pi t1 "$state")
  [ "$out" = "busy pi-ext" ] || fail "pi-ext record on a pi task must classify, got '$out'"
  out=$(fm_busy_classify tmux w1 grok t1 "$state")
  [ "$out" = "unknown source-mismatch" ] || fail "grok trusts no semantic source, got '$out'"
  pass "a record is trusted only by the adapter whose source wrote it"
}

test_converted_adapters_ignore_footer_text() {
  local state out h
  state=$(new_state_dir no-footer)
  local tail='• Working (6s • esc to interrupt)
   ■■■■⬝⬝⬝⬝  esc interrupt
Working...
Ctrl+c:cancel'
  for h in claude opencode pi pi-signed; do
    out=$(fm_busy_classify tmux w1 "$h" t1 "$state" "$tail")
    [ "$out" = "unknown missing" ] || fail "$h must never classify from footer text, got '$out'"
  done
  out=$(fm_busy_classify tmux w1 codex t1 "$state" "$tail")
  [ "$out" = "unknown codex-unverified" ] || fail "codex must never classify from footer text, got '$out'"
  pass "converted adapters never classify busy from rendered footer text"
}

# --- launch-prompt backstop (a launch pinned at fm-spawn, parked on a
# recognized interactive prompt, must classify unknown rather than busy) ------

test_launch_prompt_claude_trust_dialog() {
  local state out
  state=$(new_state_dir launch-prompt-claude)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 claude t1 "$state" 'Accessing workspace: /tmp/wt-a
Quick safety check: Is this a project you created or one you trust?
Claude Code'"'"'ll be able to read, edit, and execute files here.
> No, exit
  Yes, I trust this folder
Enter to confirm . Esc to cancel')
  [ "$out" = "unknown launch-prompt" ] \
    || fail "a launch pinned at fm-spawn parked on Claude's trust dialog must classify unknown launch-prompt, got '$out'"
  out=$(fm_busy_classify tmux w1 claude t1 "$state" 'Allow external CLAUDE.md file imports?
This project'"'"'s CLAUDE.md imports files outside the current working directory.
> No, disable external imports
  Yes, allow external imports')
  [ "$out" = "unknown launch-prompt" ] \
    || fail "a launch pinned at fm-spawn parked on Claude's external-imports dialog must classify unknown launch-prompt, got '$out'"
  pass "a Claude launch parked on its trust or external-imports dialog classifies unknown launch-prompt"
}

test_launch_prompt_pi_trust_dialog() {
  local state out h
  for h in pi pi-signed omp; do
    state=$(new_state_dir "launch-prompt-$h")
    "$EV" arm "$state" t1 >/dev/null
    out=$(fm_busy_classify tmux w1 "$h" t1 "$state" ' Trust project folder?
 /tmp/fm-pi-trust-check/wt

 This allows pi to load .pi settings and resources, install missing project packages, and execute project extensions.

 > Trust
   Trust parent folder (/tmp/fm-pi-trust-check)
   Trust (this session only)
   Do not trust
   Do not trust (this session only)

 up/down navigate  enter select  escape/ctrl+c cancel')
    [ "$out" = "unknown launch-prompt" ] \
      || fail "a $h launch pinned at fm-spawn parked on the project-trust dialog must classify unknown launch-prompt, got '$out'"
  done
  pass "a Pi-family launch (pi, pi-signed, omp) parked on the project-trust dialog classifies unknown launch-prompt"
}

test_launch_prompt_pi_requires_both_markers() {
  local state out
  state=$(new_state_dir launch-prompt-pi-partial)
  "$EV" arm "$state" t1 >/dev/null
  # "trust" alone, with neither the dialog heading nor its decline option, must
  # not be read as the dialog - it is an ordinary word a worker's own output
  # could easily contain.
  out=$(fm_busy_classify tmux w1 pi t1 "$state" 'I trust this approach and will proceed.')
  [ "$out" = "busy fm-spawn" ] \
    || fail "ordinary prose containing 'trust' must not classify as a parked launch, got '$out'"
  pass "the Pi signature requires both the dialog heading and its decline option, not the bare word trust"
}

test_launch_prompt_gemini_dialogs() {
  local state out
  state=$(new_state_dir launch-prompt-gemini-trust)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 gemini t1 "$state" 'Do you trust the files in this folder?
● 1. Trust folder (worktree)
  2. Trust parent folder (project)
  3. Don'"'"'t trust')
  [ "$out" = "unknown launch-prompt" ] \
    || fail "a Gemini launch parked on the workspace-trust dialog must classify unknown launch-prompt, got '$out'"

  state=$(new_state_dir launch-prompt-gemini-auth)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 gemini t1 "$state" 'How would you like to authenticate for this project?
● 2. Use Gemini API Key')
  [ "$out" = "unknown launch-prompt" ] \
    || fail "a Gemini launch parked on the auth-method picker must classify unknown launch-prompt, got '$out'"

  state=$(new_state_dir launch-prompt-gemini-apikey)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 gemini t1 "$state" 'Enter Gemini API Key
> ')
  [ "$out" = "unknown launch-prompt" ] \
    || fail "a Gemini launch parked on the API-key entry dialog must classify unknown launch-prompt, got '$out'"
  pass "a Gemini launch parked on its trust, auth-picker, or API-key dialog classifies unknown launch-prompt"
}

test_launch_prompt_never_shortens_a_working_launch() {
  local state out
  state=$(new_state_dir launch-prompt-working)
  "$EV" arm "$state" t1 >/dev/null
  # A genuinely working launch (Claude's ordinary busy footer, rendered before
  # its own hook has posted a single event yet) must keep the normal busy
  # bound rather than being shortened by this backstop.
  out=$(fm_busy_classify tmux w1 claude t1 "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "busy fm-spawn" ] \
    || fail "a genuinely busy launch must not be reclassified, got '$out'"
  pass "the launch-prompt backstop never reclassifies a genuinely working launch"
}

test_launch_prompt_scoped_to_armed_harnesses() {
  local state out
  # opencode ships no trust dialog (fm-busy-lib.sh header), so it has no
  # signature at all: even Claude's own dialog text must not reclassify it.
  state=$(new_state_dir launch-prompt-opencode)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 opencode t1 "$state" \
    'Quick safety check: Is this a project you created or one you trust?')
  [ "$out" = "busy fm-spawn" ] \
    || fail "opencode has no launch-prompt signature and must stay busy fm-spawn, got '$out'"
  pass "the launch-prompt backstop is scoped to harnesses with a verified signature"
}

test_launch_prompt_never_reclassifies_an_advanced_record() {
  local state gen out
  state=$(new_state_dir launch-prompt-advanced)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source claude-hook --event user-prompt-submit
  out=$(fm_busy_classify tmux w1 claude t1 "$state" \
    'Quick safety check: Is this a project you created or one you trust?')
  [ "$out" = "busy claude-hook" ] \
    || fail "a record that has advanced past fm-spawn must never be reclassified by pane text, got '$out'"
  pass "the launch-prompt backstop only ever touches the untouched fm-spawn seed"
}

test_launch_prompt_requires_a_captured_tail() {
  local state out
  state=$(new_state_dir launch-prompt-no-tail)
  "$EV" arm "$state" t1 >/dev/null
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] \
    || fail "with no captured tail the record's own state must stand, got '$out'"
  pass "the launch-prompt backstop never runs without a captured tail"
}

test_grok_regex_isolated() {
  local state out
  state=$(new_state_dir grok-arm)
  out=$(fm_busy_classify tmux w1 grok t1 "$state" 'thinking hard
Ctrl+c:cancel')
  [ "$out" = "busy grok-regex" ] || fail "grok busy tail must classify 'busy grok-regex', got '$out'"
  out=$(fm_busy_classify tmux w1 grok t1 "$state" 'done.
> ')
  [ "$out" = "idle grok-regex" ] || fail "grok idle tail must classify 'idle grok-regex', got '$out'"
  # Another adapter's footer never makes grok busy either.
  out=$(fm_busy_classify tmux w1 grok t1 "$state" '• Working (6s • esc to interrupt)')
  [ "$out" = "idle grok-regex" ] || fail "a claude footer must not classify grok busy, got '$out'"
  pass "the grok fallback is regex-scoped to grok and classifies only grok tasks"
}

# --- kimi verification gate -----------------------------------------------------

test_codex_unverified_gate() {
  local state gen out
  state=$(new_state_dir codex-gate)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source codex-hook --event user-prompt-submit
  out=$(fm_busy_classify tmux w1 codex t1 "$state")
  [ "$out" = "unknown codex-unverified" ] || fail "unverified codex must classify unknown, got '$out'"
  [ -z "$(fm_busy_sources_for_harness codex)" ] \
    || fail "codex must trust no semantic source until one is verified"
  pass "codex classifies unknown until a semantic source passes its verification gate"
}

test_kimi_unverified_gate() {
  local state gen out
  state=$(new_state_dir kimi-gate)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source kimi-hook --event user-prompt-submit
  out=$(fm_busy_classify tmux w1 kimi t1 "$state")
  [ "$out" = "unknown kimi-unverified" ] || fail "unverified kimi must classify unknown, got '$out'"
  out=$(fm_busy_classify tmux w1 kimi t1 "$state" '🌒 · thinking')
  [ "$out" = "unknown kimi-unverified" ] || fail "kimi must not classify from footer text, got '$out'"
  pass "standalone kimi classifies unknown until the live verification gate opens"
}

test_cursor_ignores_rendered_and_native_signals() {
  local state out
  state=$(new_state_dir cursor-gate)
  # Cursor's verdict comes from its own transcript, never from rendered text.
  # With no binding to fold, the honest answer is unknown - and a rendered
  # busy-looking footer must not change that.
  out=$(fm_busy_classify tmux w1 cursor t1 "$state" 'Working')
  [ "$out" = "unknown cursor-transcript" ] \
    || fail "cursor must not classify from its rendered footer, got '$out'"
  out=$(fm_busy_classify tmux w1 cursor t1 "$state" 'ctrl+c to stop')
  [ "$out" = "unknown cursor-transcript" ] \
    || fail "cursor must not classify from the ctrl+c busy token either, got '$out'"
  # Herdr's narrower native streaming state is not cursor's turn lifecycle.
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_busy_state() { printf '%s' busy; }
  out=$(fm_busy_classify herdr s:p cursor t1 "$state")
  [ "$out" = "unknown cursor-transcript" ] \
    || fail "cursor must not borrow herdr's native busy verdict, got '$out'"
  unset -f fm_backend_busy_state
  # The fold is a PULL source: nothing is armed, so no stored record is trusted.
  [ -z "$(fm_busy_sources_for_harness cursor)" ] \
    || fail "cursor must trust no stored record source; its fold has no writer"
  pass "cursor classifies only from its transcript fold, never rendered text or native state"
}

# --- endpoint death and native fallbacks ----------------------------------------

test_dead_endpoint_overrides() {
  local state gen out
  state=$(new_state_dir dead)
  gen=$("$EV" arm "$state" t1)
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_live
  fm_backend_target_exists() { return 1; }
  out=$(fm_busy_classify_live tmux w1 claude t1 "$state")
  [ "$out" = "dead endpoint-gone" ] || fail "gone endpoint must classify dead, got '$out'"
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify_live
  fm_backend_target_exists() { return 0; }
  out=$(fm_busy_classify_live tmux w1 claude t1 "$state")
  [ "$out" = "busy fm-spawn" ] || fail "live endpoint must fall through to the record, got '$out'"
  out=$(fm_busy_classify_live tmux '' claude t1 "$state")
  [ "$out" = "unknown no-target" ] || fail "empty target must classify unknown, got '$out'"
  unset -f fm_backend_target_exists
  pass "endpoint death is the only process-level override and yields dead, never busy"
}

test_herdr_native_busy_only() {
  local state out
  state=$(new_state_dir herdr-native)
  # shellcheck disable=SC2329 # invoked indirectly through fm_busy_classify
  fm_backend_busy_state() { printf '%s' "$FAKE_NATIVE"; }
  FAKE_NATIVE=busy
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "busy herdr-native" ] || fail "native busy with no record must classify busy, got '$out'"
  FAKE_NATIVE=idle
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "unknown missing" ] || fail "native idle must NOT classify idle, got '$out'"
  # A valid record outranks the native verdict.
  local gen
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop
  FAKE_NATIVE=busy
  out=$(fm_busy_classify herdr s:p claude t1 "$state")
  [ "$out" = "idle claude-hook" ] || fail "the adapter record must outrank herdr's native verdict, got '$out'"
  unset -f fm_backend_busy_state
  pass "herdr's native verdict is trusted for busy only, and records outrank it"
}

# The record parser runs inside sourcing callers (the watcher, the daemon, the
# crew-state reader), so it must not disturb their shell: no clobbered
# positional parameters and no changed glob setting.
test_record_read_leaves_caller_shell_intact() {
  local state out
  state=$(new_state_dir parser-isolation)
  "$EV" arm "$state" t1 >/dev/null
  out=$(bash -c '
    set -f
    . "$1/bin/fm-busy-lib.sh"
    set -- keepme second
    fm_busy_record_read "$2" t1 >/dev/null
    printf "%s|%s|%s" "$1" "$#" "$-"
  ' _ "$ROOT" "$state")
  case "$out" in
    keepme\|2\|*f*) : ;;
    *) fail "record parsing disturbed the caller's shell: $out" ;;
  esac
  # A glob-shaped field must survive parsing literally rather than expanding.
  printf 'v1 gen=%s seq=1 state=busy source=* event=x ts=1\n' "$(cat "$state/t1.busy-gen")" \
    > "$state/t1.busy-state"
  out=$(fm_busy_classify tmux w1 claude t1 "$state")
  [ "$out" = "unknown malformed" ] || fail "a glob-shaped source must be rejected, not expanded, got '$out'"
  pass "record parsing never clobbers the caller's positional parameters, glob setting, or fields"
}

test_boolean_view_never_promotes_unknown() {
  local state gen
  state=$(new_state_dir boolean)
  gen=$("$EV" arm "$state" t1)
  fm_busy_is_busy tmux w1 claude t1 "$state" || fail "busy record must read busy"
  "$EV" apply "$state" t1 idle --gen "$gen" --source claude-hook --event stop
  if fm_busy_is_busy tmux w1 claude t1 "$state"; then
    fail "idle record must not read busy"
  fi
  printf 'garbage\n' > "$state/t1.busy-state"
  if fm_busy_is_busy tmux w1 claude t1 "$state"; then
    fail "malformed record must not read busy"
  fi
  pass "the boolean view reports busy only on an exact busy verdict"
}

test_progress_is_generation_bound_and_not_semantic_state() {
  local state gen replacement before
  state=$(new_state_dir native-progress)
  gen=$("$EV" arm "$state" t1)
  before=$(cat "$state/t1.busy-state")
  "$EV" progress "$state" t1 --gen "$gen" || fail "current progress was refused"
  [ -f "$state/t1.progress" ] || fail "progress marker missing"
  [ ! -e "$state/t1.turn-ended" ] || fail "progress emitted a completed turn"
  [ "$(cat "$state/t1.busy-state")" = "$before" ] || fail "progress changed semantic state"
  replacement=$("$EV" arm "$state" t1)
  [ ! -e "$state/t1.progress" ] || fail "arm retained the previous incarnation's progress"
  if "$EV" progress "$state" t1 --gen "$gen" 2>/dev/null; then fail "stale progress was accepted"; fi
  [ ! -e "$state/t1.progress" ] || fail "stale progress wrote a marker"
  "$EV" progress "$state" t1 --gen "$replacement" || fail "replacement progress was refused"
  "$EV" retire "$state" t1 --gen "$replacement" || fail "retire failed"
  [ ! -e "$state/t1.progress" ] || fail "retire retained progress"
  pass "native progress is generation-bound, separately recorded, and cleared on arm and retire"
}

test_turn_ended_notification_is_generation_bound() {
  local state gen
  state=$(new_state_dir turn-ended)
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source commandcode-mod --event run-end \
    || fail "current idle event was refused"
  [ ! -e "$state/t1.turn-ended" ] || fail "an idle event without --turn-ended notified"
  "$EV" apply "$state" t1 idle --gen "$gen" --source commandcode-mod --event run-end --turn-ended \
    || fail "current turn-ended event was refused"
  [ -f "$state/t1.turn-ended" ] || fail "turn-ended notification missing"
  rm "$state/t1.turn-ended"
  "$EV" arm "$state" t1 >/dev/null
  if "$EV" apply "$state" t1 idle --gen "$gen" --source commandcode-mod --event run-end --turn-ended 2>/dev/null; then
    fail "stale turn-ended event was accepted"
  fi
  [ ! -e "$state/t1.turn-ended" ] || fail "stale turn-ended event woke the replacement"
  if "$EV" progress "$state" t1 --gen "$gen" --turn-ended 2>/dev/null; then fail "--turn-ended accepted outside apply"; fi
  pass "the turn-ended notification rides the apply generation check"
}

# --- incarnation and host boot -------------------------------------------------
#
# A gen says which incarnation a record belongs to, not that its agent is still
# the process sitting in the endpoint. After a host restart every agent the
# fleet launched is gone, while a terminal backend that restores its layout can
# put a new agent into the endpoint. arm therefore binds each gen to the host
# boot it was minted in, and fm_busy_incarnation_restored reads that binding.
# Fake /proc and /run roots make every case deterministic on any platform.

BOOT_T0=1794293642   # the fixture boot's first second, for the legacy cases

boot_world() {  # <name> [boot-id] -> sets BW_STATE BW_PROC BW_RUN
  BW_STATE=$(new_state_dir "$1")
  BW_PROC="$TMP_ROOT/$1/proc"
  BW_RUN="$TMP_ROOT/$1/run"
  mkdir -p "$BW_PROC/sys/kernel/random" "$BW_RUN"
  [ -z "${2:-}" ] || printf '%s\n' "$2" > "$BW_PROC/sys/kernel/random/boot_id"
}

# boot_world_clocks <btime> [run-entry-mtime...]: the two boot-time witnesses
# the legacy fallback reads - /proc/stat's btime, and one /run entry per stamp.
boot_world_clocks() {
  local btime=$1 n=0 stamp
  shift
  printf 'cpu  1 2 3 4\nintr 9 8 7\nctxt 5\nbtime %s\nprocesses 6\n' "$btime" > "$BW_PROC/stat"
  rm -rf "$BW_RUN"
  mkdir -p "$BW_RUN"
  for stamp in "$@"; do
    n=$((n + 1))
    : > "$BW_RUN/entry$n"
    fm_touch_epoch "$stamp" "$BW_RUN/entry$n"
  done
}

boot_meta() {  # [meta-line...] -> the task record for t1
  fm_write_meta "$BW_STATE/t1.meta" "window=s:w" "kind=ship" "harness=claude" "$@"
}

# The reader, in a subshell so the real fm-backend.sh (it supplies fm_meta_get)
# never joins the backend stubs the cases above define. Prints
# "<yes|no>:<evidence>"; an argument first rewrites the running boot's id.
boot_restored() {  # [host-boot-id]
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-backend.sh"
    [ -z "${1:-}" ] || printf '%s\n' "$1" > "$BW_PROC/sys/kernel/random/boot_id"
    export FM_PROC_ROOT_OVERRIDE="$BW_PROC" FM_RUN_ROOT_OVERRIDE="$BW_RUN"
    if evidence=$(fm_busy_incarnation_restored "$BW_STATE/t1.meta" t1 "$BW_STATE"); then
      printf 'yes:%s' "$evidence"
    else
      printf 'no:%s' "$evidence"
    fi
  )
}

# legacy_gen <mint-epoch>: a task armed before the boot binding existed - a gen
# with that mint second, no binding, and a record that names it.
legacy_gen() {
  rm -f "$BW_STATE"/t1.busy-*
  printf 'g%s.4242.7\n' "$1" > "$BW_STATE/t1.busy-gen"
  boot_meta "busy_gen=g$1.4242.7"
}

test_arm_binds_the_gen_to_the_host_boot() {
  local gen replacement
  boot_world boot-arm boot-a
  gen=$(FM_PROC_ROOT_OVERRIDE="$BW_PROC" "$EV" arm "$BW_STATE" t1) || fail "arm failed"
  [ "$(cat "$BW_STATE/t1.busy-boot" 2>/dev/null)" = "v1 gen=$gen boot=boot-a" ] \
    || fail "arm did not bind the gen to the host boot, got '$(cat "$BW_STATE/t1.busy-boot" 2>/dev/null)'"
  printf 'boot-b\n' > "$BW_PROC/sys/kernel/random/boot_id"
  replacement=$(FM_PROC_ROOT_OVERRIDE="$BW_PROC" "$EV" arm "$BW_STATE" t1) || fail "re-arm failed"
  [ "$(cat "$BW_STATE/t1.busy-boot")" = "v1 gen=$replacement boot=boot-b" ] \
    || fail "re-arm kept the previous incarnation's boot binding"
  "$EV" retire "$BW_STATE" t1 --gen "$replacement" || fail "retire failed"
  [ ! -e "$BW_STATE/t1.busy-boot" ] || fail "retire left the boot binding behind"
  pass "arm binds each gen to the kernel boot id, re-arm replaces the binding, and retire removes it"
}

test_arm_without_a_boot_id_writes_no_binding() {
  local gen
  boot_world boot-none boot-a
  FM_PROC_ROOT_OVERRIDE="$BW_PROC" "$EV" arm "$BW_STATE" t1 >/dev/null || fail "arm failed"
  [ -f "$BW_STATE/t1.busy-boot" ] || fail "fixture: the first arm should have bound a boot"
  rm -f "$BW_PROC/sys/kernel/random/boot_id"
  gen=$(FM_PROC_ROOT_OVERRIDE="$BW_PROC" "$EV" arm "$BW_STATE" t1) \
    || fail "arm must not depend on a kernel boot id"
  [ ! -e "$BW_STATE/t1.busy-boot" ] \
    || fail "an arm with no boot id left the previous incarnation's binding in place"
  [ "$(cat "$BW_STATE/t1.busy-gen")" = "$gen" ] || fail "arm did not mint the gen"
  [ "$(fm_busy_classify tmux w1 claude t1 "$BW_STATE")" = "busy fm-spawn" ] \
    || fail "arm without a boot id did not seed the record"
  "$EV" retire "$BW_STATE" t1 --gen "$gen" || fail "retire without a binding failed"
  pass "a platform with no kernel boot id arms exactly as before and leaves no stale boot binding"
}

test_incarnation_restored_when_the_boot_id_changed() {
  local gen far
  boot_world boot-changed boot-a
  gen=$(FM_PROC_ROOT_OVERRIDE="$BW_PROC" "$EV" arm "$BW_STATE" t1)
  boot_meta "busy_gen=$gen"
  [ "$(boot_restored boot-a)" = "no:" ] \
    || fail "an incarnation armed in the running boot must not read restored, got '$(boot_restored boot-a)'"
  [ "$(boot_restored boot-b)" = "yes:boot-id" ] \
    || fail "an incarnation armed in an earlier boot must read restored by boot id, got '$(boot_restored boot-b)'"
  [ "$(FM_BUSY_BOOT_CHECK=off boot_restored boot-b)" = "no:" ] \
    || fail "FM_BUSY_BOOT_CHECK=off must switch the check off"
  # The binding is exact, so no clock can overrule it: with both boot clocks far
  # in the future the legacy comparison would call this fresh gen ancient.
  far=$(( $(date +%s) + 100000000 ))
  boot_world_clocks "$far" "$far"
  [ "$(boot_restored boot-a)" = "no:" ] \
    || fail "a gen bound to the running boot must not fall back to comparing clocks"
  pass "the boot binding alone decides: the running boot is not restored, another boot is, whatever the clocks say"
}

test_incarnation_check_is_silent_without_a_bound_record() {
  local gen
  boot_world boot-silent boot-a
  gen=$(FM_PROC_ROOT_OVERRIDE="$BW_PROC" "$EV" arm "$BW_STATE" t1)

  boot_meta
  [ "$(boot_restored boot-b)" = "no:" ] \
    || fail "a record that names no busy gen must not be judged by a gen file it does not claim"
  boot_meta "busy_gen=g1.2.3"
  [ "$(boot_restored boot-b)" = "no:" ] \
    || fail "a record naming another gen must not be judged by the armed one"
  boot_meta "busy_gen=$gen" "remote_host=buildbox"
  [ "$(boot_restored boot-b)" = "no:" ] \
    || fail "a remote task's boot is another host's and must be skipped"
  boot_meta "busy_gen=$gen"
  rm -f "$BW_PROC/sys/kernel/random/boot_id"
  [ "$(boot_restored)" = "no:" ] \
    || fail "a bound incarnation with no readable host boot id must be 'cannot tell'"
  rm -f "$BW_STATE/t1.meta"
  [ "$(boot_restored boot-b)" = "no:" ] || fail "a missing record must be 'cannot tell'"
  boot_meta "busy_gen=$gen"
  [ "$(boot_restored boot-b)" = "yes:boot-id" ] || fail "fixture: the bound record should read restored again"
  "$EV" retire "$BW_STATE" t1 --gen "$gen" || fail "retire failed"
  [ "$(boot_restored boot-b)" = "no:" ] || fail "a retired incarnation has nothing to judge"
  pass "the incarnation check answers 'cannot tell' for an unbound, foreign, remote, unreadable, or retired incarnation"
}

# The fallback for an incarnation armed before the boot binding existed: the
# gen's own mint second against this boot. /proc/stat's btime is derived from
# two clocks and drifts late (20 minutes after 9 hours on a WSL2 host), so on its
# own it would call a task armed early in THIS boot restored; the oldest mtime
# in /run is stored at boot and does not move. The gen must predate both.
test_legacy_incarnation_needs_both_boot_clocks() {
  local drift=1229
  boot_world boot-legacy boot-b
  # This boot began at BOOT_T0; btime has since drifted `drift` seconds late.
  boot_world_clocks $((BOOT_T0 + drift)) "$BOOT_T0" $((BOOT_T0 + 3)) $((BOOT_T0 + 4000))

  legacy_gen $((BOOT_T0 - 3600))
  [ "$(boot_restored)" = "yes:gen-epoch" ] \
    || fail "a gen minted an hour before this boot must read restored, got '$(boot_restored)'"
  legacy_gen $((BOOT_T0 + 600))
  [ "$(boot_restored)" = "no:" ] \
    || fail "a gen minted ten minutes INTO this boot read restored because btime had drifted past it"
  legacy_gen $((BOOT_T0 + 30000))
  [ "$(boot_restored)" = "no:" ] || fail "a gen minted hours into this boot must not read restored"
  legacy_gen $((BOOT_T0 - 60))
  [ "$(boot_restored)" = "no:" ] || fail "a gen inside the margin before boot must not read restored"
  legacy_gen $((BOOT_T0 - 121))
  [ "$(boot_restored)" = "yes:gen-epoch" ] || fail "a gen just past the margin must read restored"
  pass "the legacy fallback flags a gen older than this boot and never one minted in it, even under btime drift"
}

test_legacy_incarnation_is_silent_without_a_trustworthy_boot_time() {
  local gen
  boot_world boot-legacy-silent boot-b
  boot_world_clocks $((BOOT_T0 + 1229)) "$BOOT_T0"
  legacy_gen $((BOOT_T0 - 3600))
  [ "$(boot_restored)" = "yes:gen-epoch" ] || fail "fixture: this gen should read restored"

  # /run entries rewritten long after boot are not a boot stamp.
  boot_world_clocks $((BOOT_T0 + 1229)) $((BOOT_T0 + 1229 + 301)) $((BOOT_T0 + 9000))
  [ "$(boot_restored)" = "no:" ] || fail "a /run stamp later than btime plus its slack must not be believed"
  # A /run that was not emptied at boot can only make the check quieter.
  boot_world_clocks $((BOOT_T0 + 1229)) $((BOOT_T0 - 90000))
  [ "$(boot_restored)" = "no:" ] || fail "a /run older than the gen must not flag it"
  boot_world_clocks $((BOOT_T0 + 1229))
  [ "$(boot_restored)" = "no:" ] || fail "an empty /run gives no boot stamp"
  rm -rf "$BW_RUN"
  [ "$(boot_restored)" = "no:" ] || fail "a missing /run gives no boot stamp"
  boot_world_clocks $((BOOT_T0 + 1229)) "$BOOT_T0"
  printf 'cpu  1 2 3 4\n' > "$BW_PROC/stat"
  [ "$(boot_restored)" = "no:" ] || fail "a /proc/stat with no btime must be 'cannot tell'"
  rm -f "$BW_PROC/stat"
  [ "$(boot_restored)" = "no:" ] || fail "a platform with no /proc/stat must be 'cannot tell'"

  # A gen that carries no wall-clock second (hand-written fixtures do) is never judged.
  boot_world_clocks $((BOOT_T0 + 1229)) "$BOOT_T0"
  for gen in g1.1.1 g-superseded.1.1 g0794293642.1.1 "g$((BOOT_T0 - 3600))"; do
    rm -f "$BW_STATE"/t1.busy-*
    printf '%s\n' "$gen" > "$BW_STATE/t1.busy-gen"
    boot_meta "busy_gen=$gen"
    [ "$(boot_restored)" = "no:" ] || fail "gen '$gen' has no plausible mint second and must not be judged"
  done
  pass "the legacy fallback stays silent when either boot clock is missing or late, or the gen has no mint second"
}

test_legacy_fallback_is_only_for_an_unbound_gen() {
  boot_world boot-legacy-bound boot-b
  boot_world_clocks $((BOOT_T0 + 1229)) "$BOOT_T0"
  legacy_gen $((BOOT_T0 - 3600))
  # A binding left by another incarnation, or one that cannot be parsed, is not this gen's.
  printf 'v1 gen=gOTHER.1.1 boot=boot-b\n' > "$BW_STATE/t1.busy-boot"
  [ "$(boot_restored)" = "yes:gen-epoch" ] || fail "another gen's binding must not vouch for this one"
  printf 'garbage\n' > "$BW_STATE/t1.busy-boot"
  [ "$(boot_restored)" = "yes:gen-epoch" ] || fail "a malformed binding must not vouch for the gen"
  printf 'v1 gen=g%s.4242.7 boot=boot-b\nsecond line\n' "$((BOOT_T0 - 3600))" > "$BW_STATE/t1.busy-boot"
  [ "$(boot_restored)" = "yes:gen-epoch" ] || fail "a multi-line binding must not vouch for the gen"
  # Its own binding to the running boot settles it, whatever its epoch says.
  printf 'v1 gen=g%s.4242.7 boot=boot-b\n' "$((BOOT_T0 - 3600))" > "$BW_STATE/t1.busy-boot"
  [ "$(boot_restored)" = "no:" ] || fail "a gen bound to the running boot must not be judged by its epoch"
  pass "a gen's own boot binding outranks the legacy clock comparison, and no other binding stands in for it"
}

# The check runs inside sourcing callers (the crew-state reader, the
# session-start digest), so it must be safe under set -eu and leave their shell
# as it found it.
test_incarnation_check_leaves_the_caller_shell_intact() {
  local out
  boot_world boot-shell boot-b
  boot_world_clocks $((BOOT_T0 + 1229)) "$BOOT_T0"
  legacy_gen $((BOOT_T0 - 3600))
  out=$(FM_PROC_ROOT_OVERRIDE="$BW_PROC" FM_RUN_ROOT_OVERRIDE="$BW_RUN" bash -euc '
    . "$1/bin/fm-backend.sh"
    . "$1/bin/fm-busy-lib.sh"
    state=$2
    set -f
    set -- keepme second
    verdict=$(fm_busy_incarnation_restored "$state/t1.meta" t1 "$state") || verdict=none
    absent=$(fm_busy_incarnation_restored "$state/nope.meta" nope "$state") || absent=none
    printf "%s|%s|%s|%s|%s" "$verdict" "$absent" "$1" "$#" "$-"
  ' _ "$ROOT" "$BW_STATE" 2>&1)
  case "$out" in
    gen-epoch\|none\|keepme\|2\|*f*) : ;;
    *) fail "the incarnation check disturbed a set -eu caller: $out" ;;
  esac
  pass "the incarnation check is safe under set -eu and never clobbers the caller's parameters or glob setting"
}

test_progress_is_generation_bound_and_not_semantic_state
test_turn_ended_notification_is_generation_bound
test_arm_binds_the_gen_to_the_host_boot
test_arm_without_a_boot_id_writes_no_binding
test_incarnation_restored_when_the_boot_id_changed
test_incarnation_check_is_silent_without_a_bound_record
test_legacy_incarnation_needs_both_boot_clocks
test_legacy_incarnation_is_silent_without_a_trustworthy_boot_time
test_legacy_fallback_is_only_for_an_unbound_gen
test_incarnation_check_leaves_the_caller_shell_intact

test_arm_seeds_busy_spawn
test_apply_advances_seq_and_source
test_apply_current_gen_reset
test_apply_unarmed_refused
test_retire_serializes_and_rejects_stale_gen
test_retire_missing_sidecar_is_idempotent
test_stale_lock_broken_under_gnu_stat
test_stale_gen_event_rejected
test_stale_gen_record_unknown
test_missing_record_unknown_not_idle
test_malformed_record_unknown
test_record_without_sidecar_unknown
test_source_mismatch_cross_adapter
test_converted_adapters_ignore_footer_text
test_launch_prompt_claude_trust_dialog
test_launch_prompt_pi_trust_dialog
test_launch_prompt_pi_requires_both_markers
test_launch_prompt_gemini_dialogs
test_launch_prompt_never_shortens_a_working_launch
test_launch_prompt_scoped_to_armed_harnesses
test_launch_prompt_never_reclassifies_an_advanced_record
test_launch_prompt_requires_a_captured_tail
test_grok_regex_isolated
test_codex_unverified_gate
test_kimi_unverified_gate
test_cursor_ignores_rendered_and_native_signals
test_dead_endpoint_overrides
test_herdr_native_busy_only
test_record_read_leaves_caller_shell_intact
test_boolean_view_never_promotes_unknown

echo "all fm-busy-state tests passed"
