#!/usr/bin/env bash
# Claude Stop-owned watcher auto-arm (asyncRewake hook).
#
# Registered in tracked .claude/settings.json as a Stop command hook with
# "asyncRewake": true and an explicit multi-hour timeout. Claude Code fires it
# in the background on EVERY Stop of a Claude primary session, with no
# deduplication across firings. It owns routine tokenless watcher continuity
# for Claude primaries (main home and marked secondmate homes):
#
#   - Scope: only a genuine primary checkout (plain checkout or validly marked
#     secondmate home) with AGENTS.md, bin/, and the effective state dir - the
#     exact fm-turnend-guard.sh scope. Child crew/scout worktrees stay inert.
#   - Identity: only when THIS session holds state/.lock, as
#     bin/fm-session-lock-lib.sh decides it: the recorded pid is a harness
#     ancestor, or a live lock was recorded under this same trusted Claude
#     session id (which is what keeps a background session arming after its
#     transient helper chain is recycled).
#     When an existing numeric owner fails the shared harness-liveness predicate,
#     the hook delegates guarded recovery to bin/fm-lock.sh and then re-verifies
#     ownership. A live owner, missing lock, malformed lock, or unresolved
#     ancestry remains inert, so a competing session never arms or rewakes.
#   - AFK: while state/.afk exists the away daemon owns the watcher and triage;
#     this hook exits 0 and NEVER rewakes the primary (checked again at
#     translation time so a mid-cycle AFK transition is honored).
#   - Need: arms only while the home needs supervision, as
#     bin/fm-supervision-lib.sh defines it; an idle home exits 0.
#   - Single-flight: Claude does not dedupe async hooks, so exactly one
#     GENERATION owner arms per event epoch: the epoch ledger's monotonic
#     sequence is the claim generation, every firing defers (exit 0) to a live
#     open claim, and a stuck, dead, identity-mismatched, or finished claim is
#     superseded by taking the next generation instead of being unlocked or
#     revoked. No mutex is ever held across arming or output - the owner lock
#     survives only as the micro-mutex serializing individual ledger writes -
#     and a superseded owner goes completely silent: ownership is re-verified
#     before every arm invocation, episode-state mutation, ledger write, and
#     continuation (fm_autoarm_claim_open/fm_autoarm_claim_next in
#     bin/fm-wake-lib.sh own the contract, including the legacy shim for a
#     pre-generation lock).
#   - Foreground arm: the owner runs bin/fm-watch-arm.sh as a tracked child it
#     waits on inside this hook-owned process tree (never a fire-and-forget
#     shell &); Claude owns the process group, so its timeout/session teardown
#     kills arm and watcher together, and the hook TERMs the arm with itself.
#     HUP, TERM, and INT are translated through the ordinary durable failure
#     handoff instead of leaving the generation frozen at arming. Claude does
#     not deliver the exit 2 of a hook it terminated at the configured timeout
#     as a rewake (measured on Claude Code 2.1.278 and 2.1.281,
#     docs/verification/supervision.md), so a park that outlives that timeout
#     records the failure durably without waking an idle primary; nothing here
#     shortens a quiet park, because no-change heartbeats are absorbed without
#     closing the arm.
#   - Handling successor: Pi, omp, and OpenCode start the next arm before they
#     deliver an actionable wake, so the fleet stays covered while the model
#     handles it. After an actionable close, including an attached peer cycle
#     that ended, this hook starts one successor bin/fm-watch-arm.sh with the
#     closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID, the same handoff the
#     Pi extension passes for its closed arm child, so the arm starts a
#     handling-successor watcher and links the lifecycle ledger. A child of
#     this hook cannot outlive the exit-2 rewake, so the successor is launched
#     the one way a process survives a Claude hook: nohup, stdio detached, in
#     its own process group (the shape bin/fm-startup-network.sh uses;
#     docs/verification/supervision.md records the survival check). The hook
#     waits for the successor's one status line, adds one banner line when no
#     live watcher was confirmed, and never withholds the wake for it; the
#     next Stop's foreground arm attaches to that live cycle. The supervision
#     host owns its own successors, so its path is unchanged.
#   - Supervision host: a home that runs it (by default on this Claude
#     primary; docs/configuration.md "Supervision host" owns the gate and its
#     opt-out) runs bin/fm-supervision-host.sh in the arm's place, bound
#     to this generation.
#     To this hook it is an arm that also takes away-posture wakes itself and
#     ends its own park before the hook timeout with a "supervision-host:"
#     line, which is actionable here like a wake line; its rewake banner
#     carries every "supervision-host:" line the host printed, in order, while
#     its wake lines keep the arm's eight-line cap. A "supervision-host stood
#     down:" close exits 0 silently, and a host that died without a close is
#     retried instead of being judged by the healthy-watcher predicate
#     (docs/supervision-host.md). On a home that opted out nothing below
#     changes.
#   - Translation: while supervision is still needed and AFK remains inactive,
#     an actionable arm close (signal:/stale:/check:/heartbeat) prints one
#     rewake banner to stderr and exits 2, which wakes Claude even while idle
#     ("Stop hook feedback"). The irrevocable commit point is the EXIT STATUS:
#     the harness delivers the collected stderr only on exit 2, so an owned
#     terminal commit decides the exit. Markerless outcomes commit with the
#     ledger write; the failure notice additionally requires its marker write.
#     A refused generation exits 0 silently even after printing. A close that
#     reports no actionable reason is benign when a live identity-matched
#     watcher still has a fresh beacon.
#   - Failure handling: a typed failure is rechecked against the same live,
#     fresh watcher predicate and retried a bounded number of times in this
#     hook. Only an exhausted failure with no verified watcher emits one
#     last-resort notice per failure episode; later consecutive failures still
#     exit 2 to guarantee the next Stop-owned retry without repeating notice,
#     until the synchronous guard has consumed its attended fail-open.
#   - Wake policy: between an actionable close and its rewake, a batch of
#     declared-pause rechecks is acknowledged host-side and re-parked, a warm
#     wake is coalesced with closes inside a short window, and a cold
#     decision-free wake is held (docs/configuration.md "Claude wake policy"
#     owns the knobs; the block above park_until_close owns the rules). A
#     delivered wake keeps the banner and exit-2 contract below.
#
# The epoch ledger state/.claude-autoarm-epoch records the latest claim
# generation and outcome, and binds rewake outcomes to the session-lock pid and
# watcher recovery generation, so the synchronous Stop guard
# (bin/fm-turnend-guard.sh --claude) can allow a stop whose recovery this hook
# already owns, instead of forcing a duplicate continuation for the same event
# epoch. The failure marker
# state/.claude-autoarm-failure-notified deduplicates the last-resort notice,
# and state/.claude-autoarm-failure-alarmed bounds the attended fail-open and
# suppresses any later automatic continuation in that unresolved episode.
#
# In hook mode it never blocks the Stop decision itself or prints to stdout:
# exit 0 is silent, and exit 2 carries the rewake banner on stderr.
# On any uncertainty such as unresolvable ancestry, malformed lock state, or
# lock contention, it exits 0 and leaves continuity to the synchronous guard and
# the model.
#
# The Stop hook passes no arguments, so any argument means a manual run: -h or
# --help prints usage and an unknown argument is refused, both before anything
# is sourced, read, or armed. A park started from a model's tool call would be
# owned by that short-lived process and leave supervision down once it exits.
set -u

usage() {
  cat <<'EOF'
Usage: fm-claude-stop-autoarm.sh

Claude Stop hook registered in .claude/settings.json; not for manual use.
It reads the Stop payload on stdin and, in a primary home that needs
supervision, arms the watcher or supervision host for this session.
Exit 0 is silent; exit 2 carries a rewake banner on stderr.
EOF
}

if [ "$#" -gt 0 ]; then
  case "$1" in
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
OWNER_LOCK="$STATE/.claude-autoarm.lock"
FAILURE_NOTICE="$STATE/.claude-autoarm-failure-notified"
FAILURE_ALARM="$STATE/.claude-autoarm-failure-alarmed"
AUTOARM_ATTEMPTS=${FM_CLAUDE_AUTOARM_ATTEMPTS:-2}
case "$AUTOARM_ATTEMPTS" in
  1|2|3) : ;;
  *) AUTOARM_ATTEMPTS=2 ;;
esac

# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-supervision-lib.sh
. "$SCRIPT_DIR/fm-supervision-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-hook-host-lib.sh
. "$SCRIPT_DIR/fm-hook-host-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"

# fm-watch.sh touches the liveness beacon once per cycle, immediately before
# its terminal wait, so a healthy watcher's beacon can legitimately age up to
# FM_POLL seconds between touches (docs/turnend-guard.md "Guard grace and the
# poll cadence"). fm_poll_derived_grace (bin/fm-wake-lib.sh) is the single
# owner of that max(300, poll+60) derivation.
GRACE=${FM_GUARD_GRACE:-$(fm_poll_derived_grace)}

# Consume the Stop payload once. The decisions below are state-based; the
# payload is read so a slow writer can never wedge on a full pipe, and its host
# is inspected before anything else runs.
PAYLOAD=$(cat 2>/dev/null || true)

# Cursor loads the tracked Claude settings too. Cursor has no asyncRewake, so if
# a future Cursor build starts firing the Claude-shaped Stop entry, this arm
# would run SYNCHRONOUSLY inside Cursor's stop step and hold that turn open for
# the declared multi-hour timeout - the exact wedge grok 1.0.0 produced
# (docs/turnend-guard.md "Harness integrations"). Cursor's own park adapter owns
# its turn boundary, so stand down on a Cursor-delivered payload.
fm_hook_payload_is_foreign_host "$PAYLOAD" && exit 0

# pi-code (Pi's Claude-hook compatibility extension) also loads the tracked
# Claude settings and has no asyncRewake, so it awaits every Stop hook and this
# arm would run SYNCHRONOUSLY inside Pi's turn end, holding that turn open for
# the declared multi-hour timeout - the same wedge as Cursor above (issue
# #3343). Pi's own native extensions own Pi supervision, so stand down on a
# pi-code-delivered payload. The signal is again the PAYLOAD, not the
# environment: pi-code stamps every hook payload's transcript_path with Pi's
# own session file under .pi/, which a Claude transcript path never contains.
# Fail direction matches the guard above: no payload, no jq, or no
# transcript_path means the hook RUNS.
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  printf '%s' "$PAYLOAD" | jq -e '(.transcript_path // "") | type == "string" and contains("/.pi/")' >/dev/null 2>&1 && exit 0
fi

# --- scope: genuine primary checkout only -----------------------------------
fm_primary_scope_matches "$FM_ROOT" "$STATE" || exit 0

# --- identity: only the lock-owning session's hooks may arm ------------------
# A prior session may have died after leaving its numeric harness pid in .lock.
# Use the shared liveness predicate to recognize only that stale-owner case.
# Defer the mutating claim until after the unchanged AFK and need gates, so an
# idle or away home remains byte-for-byte inert. Missing or malformed locks are
# uncertainty rather than stale-owner evidence and remain inert.
RECOVER_SESSION_LOCK=0
if ! fm_session_lock_owned_by_self "$STATE"; then
  LOCK_PID=$(cat "$STATE/.lock" 2>/dev/null || true)
  case "$LOCK_PID" in
    ''|*[!0-9]*) exit 0 ;;
  esac
  fm_harness_pid_alive "$LOCK_PID" && exit 0
  RECOVER_SESSION_LOCK=1
fi

# --- AFK: the away daemon owns the watcher and triage; never rewake ----------
[ -e "$STATE/.afk" ] && exit 0

# --- need: whatever bin/fm-supervision-lib.sh counts as supervision need ------
need_supervision() {
  fm_supervision_needed "$STATE" "$GRACE"
}
need_supervision || exit 0

# --- stale session-lock recovery ---------------------------------------------
# Delegate the claim to fm-lock.sh so its live-owner refusal and write semantics
# remain the single acquisition owner, then re-verify current-session identity
# before touching any auto-arm state.
if [ "$RECOVER_SESSION_LOCK" -eq 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >/dev/null 2>&1 || exit 0
  fm_session_lock_owned_by_self "$STATE" || exit 0
fi

# --- single-flight generation claim --------------------------------------------
# Claude runs one background process per firing with no dedupe. Exactly one
# generation owner arms and translates per event epoch: every firing defers to
# a live open claim, and a stuck, dead, identity-mismatched, or finished claim
# is superseded by taking the next generation (fm_autoarm_claim_open and
# fm_autoarm_claim_next in bin/fm-wake-lib.sh own the contract). No mutex is
# held past this point. A micro-mutex contention with a bare hold is another
# participant's short ledger section and the next Stop firing simply retries,
# while a role-carrying hold is a legacy lock-holding claim from a
# pre-generation build (or the guard's own terminal-check), which the legacy
# shim defers to while genuinely deciding and reclaims once when proven
# abandoned.
fm_autoarm_claim_open "$STATE" "$GRACE" && exit 0
fm_autoarm_claim_next "$STATE" "$GRACE"
CLAIM_RC=$?
if [ "$CLAIM_RC" -ne 0 ]; then
  [ "$CLAIM_RC" -eq 2 ] && exit 0
  ROLE=$(fm_lock_role "$OWNER_LOCK" 2>/dev/null || true)
  [ -n "$ROLE" ] || exit 0
  fm_autoarm_release_abandoned "$STATE" "$GRACE" || exit 0
  fm_autoarm_claim_next "$STATE" "$GRACE" || exit 0
fi
MY_GEN=$FM_AUTOARM_MY_GEN
[ -n "$MY_GEN" ] || exit 0

# Commit <outcome> (optionally with the once-per-episode notice marker) for
# this generation. Success means this generation's translation WINS and the
# caller exits 2 unconditionally. Markerless outcomes commit with the owned
# ledger write; a notice wins only when its following marker write succeeds in
# the same hold. Failure means refused or unverifiable: the caller goes silent
# (cleanup, exit 0) - the harness discards the collected stderr on exit 0, so
# even an already-printed banner is never delivered by a losing generation.
autoarm_commit() {  # <outcome> [marker-file]
  local outcome=$1 marker=${2:-} session_pid recovery
  if [ "$outcome" = rewake ]; then
    fm_session_lock_owned_by_self "$STATE" || return 2
    session_pid=$(sed -n '1p' "$STATE/.lock" 2>/dev/null || true)
    fm_recovery_marker_snapshot "$STATE/.watcher-down" || return 2
    case "$FM_RECOVERY_MARKER_TOKEN" in
      pending:downtime:*|announced:downtime:*) recovery=${FM_RECOVERY_MARKER_TOKEN##*:} ;;
      *) return 2 ;;
    esac
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker" "$session_pid" "$recovery"
  elif [ -n "$marker" ]; then
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome" "$marker"
  else
    fm_autoarm_write_owned "$STATE" "$MY_GEN" "$outcome"
  fi
}

# Best-effort ownership-checked record for exit-0 paths, where supersession
# changes nothing about the action taken.
autoarm_record() {  # <outcome>
  fm_autoarm_write_owned "$STATE" "$MY_GEN" "$1" >/dev/null 2>&1 || true
}

# Claude terminates the complete async-hook process tree when the configured
# hook timeout expires. The arm is intentionally allowed to follow a healthy
# watcher until its next wake, so that wait cannot be shortened without adding
# artificial turns. Translate a host interruption through the ordinary durable
# failure protocol instead: the winning generation records a terminal outcome,
# creates the episode marker, and exits 2 so Claude delivers a recovery turn -
# except after Claude's own timeout kill, whose exit 2 is dropped (header).
# A superseded generation remains silent, and an episode whose attended
# fail-open was already consumed must not restart automatic continuation.
# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_autoarm_signal() {
  local signal=$1
  trap - HUP TERM INT
  if [ -n "${ARM_PID:-}" ]; then
    kill -TERM "$ARM_PID" 2>/dev/null || true
    wait "$ARM_PID" 2>/dev/null || true
  fi
  [ -z "${OUT:-}" ] || rm -f "$OUT" 2>/dev/null || true
  if [ -e "$FAILURE_ALARM" ]; then
    autoarm_record failed-suppressed
    exit 0
  fi
  if [ ! -e "$FAILURE_NOTICE" ]; then
    printf 'firstmate watcher auto-arm INTERRUPTED by %s - the Stop-owned automatic supervision mechanism did not reach a terminal watcher outcome.\n' "$signal" >&2
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n' >&2
    autoarm_commit failed "$FAILURE_NOTICE" && exit 2
    exit 0
  fi
  autoarm_commit failed-suppressed && exit 2
  exit 0
}

trap 'handle_autoarm_signal HUP' HUP
trap 'handle_autoarm_signal TERM' TERM
trap 'handle_autoarm_signal INT' INT

# X mode cadence: source the generated config so an X instance polls at its
# 30s cadence (fm-bootstrap.sh x_mode_setup contract).
# shellcheck source=/dev/null
[ -f "$CONFIG/x-mode.env" ] && . "$CONFIG/x-mode.env"

# --- foreground the real arm wrapper ------------------------------------------
# The arm is a tracked child this hook waits on, never a fire-and-forget shell
# & whose child would be reaped when the hook returned: this hook process tree
# is the harness-owned lifecycle. The arm forks the watcher as its own tracked
# child exactly as it does for the model-driven background-task path, and
# propagates the wake reason on close. Holding the arm's pid lets the signal
# handler TERM it with the hook and lets the handling successor below name it
# as the predecessor whose cycle just closed.
# Every non-actionable close is checked against the same identity-matched live
# watcher and fresh-beacon predicate used by the turn-end guard before it is
# retried or translated into an operator-visible failure.
ARM_PID=
CLOSED_ARM_PID=
run_arm() {  # <output file, or empty for none>
  if [ -n "$1" ]; then
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >"$1" 2>&1 &
  else
    FM_GUARD_GRACE="$GRACE" "$SCRIPT_DIR/fm-watch-arm.sh" >/dev/null 2>&1 &
  fi
  ARM_PID=$!
  wait "$ARM_PID" || true
  CLOSED_ARM_PID=$ARM_PID
  ARM_PID=
}

# --- handling successor --------------------------------------------------------
# Start the next arm before the rewake delivers the wake, as the Pi, omp, and
# OpenCode adapters do from their child-close handlers, so a watcher covers the
# handling turn instead of the home waiting uncovered for the next Stop. The
# successor receives the closed arm's pid as FM_WATCH_PREDECESSOR_ARM_PID; it
# must outlive this hook's exit, so it is detached three ways: nohup, stdio
# away from the hook's pipes, and its own process group. Its one status line
# is awaited within the arm's own confirmation budget plus slack. Sets
# SUCCESSOR_FAILURE to the banner line for an unconfirmed successor.
SUCCESSOR_FAILURE=
start_handling_successor() {  # <closed-arm-pid>
  local out pid deadline budget line monitor_was_on=0
  budget=${FM_ARM_CONFIRM_TIMEOUT:-30}
  case "$budget" in ''|*[!0-9]*) budget=30 ;; esac
  if ! out=$(mktemp "$STATE/.claude-autoarm-successor.XXXXXX"); then
    SUCCESSOR_FAILURE='The handling successor did not confirm a live watcher (its output file could not be created); this handling turn runs uncovered until the next turn end re-arms.'
    return 1
  fi
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  FM_WATCH_PREDECESSOR_ARM_PID=$1 FM_GUARD_GRACE="$GRACE" \
    nohup "$SCRIPT_DIR/fm-watch-arm.sh" >"$out" 2>&1 </dev/null &
  pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  deadline=$(( $(date +%s) + budget + 2 ))
  while :; do
    if grep -Eq '^watcher: (started|attached) pid=[0-9]+' "$out" 2>/dev/null; then
      rm -f "$out" 2>/dev/null || true
      return 0
    fi
    grep -q '^watcher: FAILED' "$out" 2>/dev/null && break
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.2
  done
  line=$(grep '^watcher: FAILED' "$out" 2>/dev/null | head -n 1 || true)
  rm -f "$out" 2>/dev/null || true
  [ -z "$line" ] || line=" ($line)"
  SUCCESSOR_FAILURE="The handling successor pid=$pid did not confirm a live watcher$line; this handling turn runs uncovered until the next turn end re-arms."
  return 1
}

# --- wake policy: host-side auto-ack, coalescing, cold-wake hold -------------
# Every wake this hook delivers is a full model turn on the primary, and a
# wake that lands after the prompt cache expired re-writes the whole context.
# Three bounded policies sit between an actionable close and the rewake
# (docs/configuration.md "Claude wake policy" owns the knobs and defaults):
#   - auto-ack: a batch whose every pending event is a declared-pause recheck
#     (the watcher's long-cadence "confirm the wait still holds" stale) needs
#     no decision, so this hook acknowledges it through bin/fm-wake-drain.sh's
#     own --ack-through path, records it in state/.claude-autoarm-autoacked.log
#     plus a pending digest the next delivered banner names in one line, and
#     parks again inside this same generation instead of waking the model.
#   - coalesce: any other close waits up to the coalesce window for further
#     closes, so events seconds apart become one wake.
#   - cold-wake hold: when the primary has been idle past the prompt-cache TTL
#     and nothing pending is a decision (no captain-relevant signal, blocker,
#     failure, check, heartbeat, or outcome to relay), the wake is held until a
#     further decision-bearing batch arrives, the session shows activity (a
#     captain prompt writes the transcript), or the hold limit passes.
# A park-budget clock below Claude's hook timeout bounds every re-park, and a
# host cycle boundary is never acknowledged or held: it is the only way the
# Stop chain re-arms once the hook nears that timeout.
HOOK_STARTED=$(date +%s)

# <env-name> <config-key> <default>: the env value, else the last valid
# "<key>=<digits>" line of config/claude-wake-policy, else the default.
wake_policy_knob() {
  local name=$1 key=$2 def=$3 val
  val=${!name:-}
  if [ -z "$val" ] && [ -f "$CONFIG/claude-wake-policy" ]; then
    val=$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*\$/\1/p" \
      "$CONFIG/claude-wake-policy" 2>/dev/null | tail -n 1)
  fi
  case "$val" in ''|*[!0-9]*) val=$def ;; esac
  printf '%s\n' "$val"
}
POLICY_AUTOACK=$(wake_policy_knob FM_CLAUDE_AUTOARM_AUTOACK autoack 1)
POLICY_COALESCE=$(wake_policy_knob FM_CLAUDE_AUTOARM_COALESCE_SECS coalesce-secs 60)
POLICY_CACHE_TTL=$(wake_policy_knob FM_CLAUDE_AUTOARM_CACHE_TTL_SECS cache-ttl-secs 3300)
POLICY_HOLD_MAX=$(wake_policy_knob FM_CLAUDE_AUTOARM_COLD_HOLD_MAX_SECS cold-hold-max-secs 10800)
POLICY_PARK_BUDGET=$(wake_policy_knob FM_CLAUDE_AUTOARM_PARK_BUDGET_SECS park-budget-secs 27000)
[ "$POLICY_PARK_BUDGET" -gt 0 ] && [ "$POLICY_PARK_BUDGET" -lt 28800 ] || POLICY_PARK_BUDGET=27000
BUDGET_DEADLINE=$((HOOK_STARTED + POLICY_PARK_BUDGET))
# A re-park needs at least this much budget left to be worth starting.
POLICY_MIN_REPARK=300
REPARKED=0
AUTOACK_PENDING="$STATE/.claude-autoarm-autoacked"
AUTOACK_LOG="$STATE/.claude-autoarm-autoacked.log"
POLICY_NOTE=

TRANSCRIPT=
if [ -n "$PAYLOAD" ] && command -v jq >/dev/null 2>&1; then
  TRANSCRIPT=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty | strings' 2>/dev/null || true)
fi
[ -z "$TRANSCRIPT" ] || [ -f "$TRANSCRIPT" ] || TRANSCRIPT=

# Last sign of model or captain activity: the Stop that started this hook,
# or a later transcript write.
last_activity() {
  local t=$HOOK_STARTED m
  if [ -n "$TRANSCRIPT" ]; then
    m=$(fm_path_mtime "$TRANSCRIPT" 2>/dev/null || true)
    case "$m" in ''|*[!0-9]*) ;; *) [ "$m" -le "$t" ] || t=$m ;; esac
  fi
  printf '%s\n' "$t"
}

WAKE_LINE_RE='^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)'
PAUSE_RECHECK_RE='^stale: .* \(paused [0-9]+s, awaiting external - (declared pause, rechecked on a long cadence not a wedge|the declared time is beyond the recheck cadence); confirm the wait still holds\)$'
DECISION_WORDS_RE='captain|escalation|wedged|demand-deep-inspection|blocked|block|needs-decision|decision|waiting on human|unread firstmate instruction|dead|no agent|fail|error|question|unwritable|stuck|done|landed|merged|ready|review'

# One wake line's class: ack (a declared-pause recheck, safe to acknowledge
# unseen), neutral (carries no event of its own), boundary (the host park
# boundary), routine (an event with no decision), or decision.
wake_line_class() {
  local l=$1
  case "$l" in
    'check: rearm-resurface') echo neutral; return ;;
    'supervision-host: cycle boundary'*) echo boundary; return ;;
  esac
  if [[ "$l" =~ $PAUSE_RECHECK_RE ]]; then echo ack; return; fi
  case "$l" in
    supervision-host:*)
      if printf '%s' "$l" | grep -Eqi 'captain|relay|verif|outcome|restored|fail|error|lookup'; then
        echo decision
      elif [[ "$l" == *'this wake is yours'* ]]; then
        echo neutral
      else
        echo decision
      fi
      ;;
    stale:*)
      if [[ "$l" == *'rechecked on a long cadence not a wedge'* ]] \
        && ! printf '%s' "$l" | grep -Eqi "$DECISION_WORDS_RE"; then
        echo routine
      else
        echo decision
      fi
      ;;
    signal:*)
      if printf '%s' "$l" | grep -Eq '^signal: [^ ]+ (working|progress|note|info|started|update)(:| |$)' \
        && ! printf '%s' "$l" | grep -Eqi "$DECISION_WORDS_RE"; then
        echo routine
      else
        echo decision
      fi
      ;;
    *) echo decision ;;
  esac
}

# Classify the wake lines of <file> plus every durable queue row.
# BATCH_CLASS is boundary, decision, ack (every event auto-ackable), routine,
# or neutral (no event at all). QUEUE_CUTOFF is the highest queued sequence and
# QUEUE_PAYLOADS the queued payloads, oldest first.
BATCH_CLASS=
QUEUE_CUTOFF=0
QUEUE_PAYLOADS=
classify_batch() {  # <file>
  local line c seq kind payload events=0 routine=0 decision=0 boundary=0
  QUEUE_CUTOFF=0
  QUEUE_PAYLOADS=
  if [ -n "$1" ] && [ -f "$1" ]; then
    while IFS= read -r line; do
      [[ "$line" =~ $WAKE_LINE_RE ]] || continue
      c=$(wake_line_class "$line")
      case "$c" in
        ack) events=$((events + 1)) ;;
        routine) routine=1; events=$((events + 1)) ;;
        boundary) boundary=1 ;;
        neutral) ;;
        *) decision=1 ;;
      esac
    done < "$1"
  fi
  # A live branch grant reserves rows main may not acknowledge: leave them to
  # the model rather than reasoning about the partition here.
  if [ -e "$STATE/.branch-eligible-rows" ] || [ -L "$STATE/.branch-eligible-rows" ]; then
    decision=1
  fi
  if [ -s "$FM_WAKE_QUEUE" ]; then
    while IFS=$'\t' read -r _ seq kind _ payload; do
      case "$seq" in ''|*[!0-9]*) decision=1; continue ;; esac
      [ -n "$payload" ] || { decision=1; continue; }
      [ "$seq" -le "$QUEUE_CUTOFF" ] || QUEUE_CUTOFF=$seq
      QUEUE_PAYLOADS="$QUEUE_PAYLOADS$payload"$'\n'
      case "$kind" in signal|stale|check|heartbeat) ;; *) decision=1; continue ;; esac
      c=$(wake_line_class "$payload")
      case "$c" in
        ack) events=$((events + 1)) ;;
        routine) routine=1; events=$((events + 1)) ;;
        neutral) ;;
        *) decision=1 ;;
      esac
    done < "$FM_WAKE_QUEUE"
  fi
  if [ "$boundary" -eq 1 ]; then BATCH_CLASS=boundary
  elif [ "$decision" -eq 1 ]; then BATCH_CLASS=decision
  elif [ "$events" -eq 0 ]; then BATCH_CLASS=neutral
  elif [ "$routine" -eq 0 ]; then BATCH_CLASS=ack
  else BATCH_CLASS=routine
  fi
}

# Acknowledge the current batch host-side when every pending event is
# auto-ackable. 0 when the queue was consumed through its cutoff and the
# digest recorded; 1 leaves everything for the ordinary wake.
autoack_batch() {  # <file>
  local gen out now payloads line
  [ "$POLICY_AUTOACK" -ne 0 ] || return 1
  [ $((BUDGET_DEADLINE - $(date +%s))) -ge "$POLICY_MIN_REPARK" ] || return 1
  [ ! -e "$STATE/.afk-contract" ] || return 1
  classify_batch "$1"
  [ "$BATCH_CLASS" = ack ] || return 1
  fm_recovery_marker_snapshot "$STATE/.watcher-down" || return 1
  case "$FM_RECOVERY_MARKER_TOKEN" in
    pending:*|announced:*) gen=${FM_RECOVERY_MARKER_TOKEN##*:} ;;
    *) return 1 ;;
  esac
  case "$gen" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  fm_autoarm_still_owner "$STATE" "$MY_GEN" || return 1
  payloads=$QUEUE_PAYLOADS
  [ -n "$payloads" ] || payloads=$(grep -E "$WAKE_LINE_RE" "$1" 2>/dev/null | grep -v '^supervision-host:')
  out=$(FM_SUPERVISION_ACTOR=main "$SCRIPT_DIR/fm-wake-drain.sh" --ack-through "$QUEUE_CUTOFF" \
    --recovery-generation "$gen" 2>&1) || return 1
  case "$out" in *'nothing was acknowledged'*) return 1 ;; esac
  if [ -s "$FM_WAKE_QUEUE" ] && awk -F '\t' -v c="$QUEUE_CUTOFF" \
    'NF >= 5 && $2 ~ /^[0-9]+$/ && $2 + 0 <= c + 0 { found = 1 } END { exit found ? 0 : 1 }' "$FM_WAKE_QUEUE"; then
    return 1
  fi
  now=$(date +%s)
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\t%s\n' "$now" "$line" >> "$AUTOACK_PENDING" 2>/dev/null || true
    printf '%s\t%s\n' "$now" "$line" >> "$AUTOACK_LOG" 2>/dev/null || true
  done <<ROWS
$payloads
ROWS
  if [ "$(awk 'END { print NR }' "$AUTOACK_LOG" 2>/dev/null || echo 0)" -gt 1000 ]; then
    tail -n 500 "$AUTOACK_LOG" > "$AUTOACK_LOG.tmp.$$" 2>/dev/null \
      && mv -f "$AUTOACK_LOG.tmp.$$" "$AUTOACK_LOG" 2>/dev/null || rm -f "$AUTOACK_LOG.tmp.$$" 2>/dev/null || true
  fi
  return 0
}

# The one-line digest of events auto-acked since the last delivered wake.
autoack_digest_line() {
  local n latest
  [ -s "$AUTOACK_PENDING" ] || return 0
  n=$(awk 'END { print NR }' "$AUTOACK_PENDING" 2>/dev/null || echo 0)
  latest=$(tail -n 1 "$AUTOACK_PENDING" 2>/dev/null | cut -f2- | cut -c1-200)
  printf 'Auto-acknowledged by this Stop hook since your last wake, no action needed: %s declared-pause recheck(s), latest "%s"; record in state/.claude-autoarm-autoacked.log.\n' "$n" "$latest"
}

# Run one more cycle until it closes, <deadline> passes, or the session shows
# activity; append its wake lines to OUT. <budget-bound> 1 means the deadline
# is the park budget, so a host boundary there is real and kept. Sets
# COLLECT_END (closed, deadline, activity, ended) and COLLECT_CLASS (the class
# of the lines it added).
COLLECT_END=
COLLECT_CLASS=
collect_cycle() {  # <deadline> <budget-bound>
  local deadline=$1 budget_bound=$2 out now since rc=0 park lines
  COLLECT_END=
  COLLECT_CLASS=
  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then COLLECT_END=deadline; return 0; fi
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  out=$(mktemp "$STATE/.claude-autoarm-collect.XXXXXX") || { COLLECT_END=ended; return 0; }
  since=$(last_activity)
  if [ "$HOST_MODE" -eq 1 ]; then
    park=$((deadline - now))
    [ "$park" -ge 1 ] || park=1
    # The pending batch is still unacknowledged, so the host's first cycle
    # runs as a handling successor (a predecessor pid, here this hook's own,
    # which names no ledger row) and does not re-surface that batch.
    FM_WATCH_PREDECESSOR_ARM_PID=$$ FM_SUPERVISION_HOST_PARK_SECONDS=$park \
      FM_SUPERVISION_HOST_AUTOARM_GEN=$MY_GEN FM_SUPERVISION_HOST_OWNER_PID=$$ \
      FM_SUPERVISION_HOST_PRIMARY=claude FM_GUARD_GRACE="$GRACE" \
      "$SCRIPT_DIR/fm-supervision-host.sh" park >"$out" 2>&1 &
  else
    FM_WATCH_PREDECESSOR_ARM_PID=${CLOSED_ARM_PID:-$$} FM_GUARD_GRACE="$GRACE" \
      "$SCRIPT_DIR/fm-watch-arm.sh" >"$out" 2>&1 &
  fi
  ARM_PID=$!
  while kill -0 "$ARM_PID" 2>/dev/null; do
    sleep 1
    kill -0 "$ARM_PID" 2>/dev/null || break
    now=$(date +%s)
    if [ "$(last_activity)" -gt "$since" ]; then
      COLLECT_END=activity
    elif [ "$HOST_MODE" -eq 0 ] && [ "$now" -ge "$deadline" ]; then
      COLLECT_END=deadline
    elif [ "$now" -ge $((deadline + 120)) ]; then
      # A host that outlived its own park boundary.
      COLLECT_END=deadline
    else
      continue
    fi
    kill -TERM "$ARM_PID" 2>/dev/null || true
    break
  done
  wait "$ARM_PID" 2>/dev/null || rc=$?
  [ "$HOST_MODE" -eq 1 ] || CLOSED_ARM_PID=$ARM_PID
  ARM_PID=
  if [ -e "$STATE/.afk" ]; then
    autoarm_record afk
    rm -f "$out" "$OUT" 2>/dev/null || true
    exit 0
  fi
  if [ "$HOST_MODE" -eq 1 ] && grep -q '^supervision-host stood down:' "$out" 2>/dev/null; then
    autoarm_record clean
    rm -f "$out" "$OUT" 2>/dev/null || true
    exit 0
  fi
  lines=$(grep -E "$WAKE_LINE_RE" "$out" 2>/dev/null || true)
  if [ "$budget_bound" -ne 1 ]; then
    lines=$(printf '%s\n' "$lines" | grep -v '^supervision-host: cycle boundary' || true)
  fi
  rm -f "$out" 2>/dev/null || true
  if [ -n "$lines" ]; then
    printf '%s\n' "$lines" >> "$OUT"
    printf '%s\n' "$lines" > "$OUT.collect"
    classify_lines_only "$OUT.collect"
    rm -f "$OUT.collect" 2>/dev/null || true
    [ -n "$COLLECT_END" ] || COLLECT_END=closed
  elif [ -z "$COLLECT_END" ]; then
    if [ "$(date +%s)" -ge "$deadline" ]; then COLLECT_END=deadline; else COLLECT_END=ended; fi
  fi
  : "$rc"
  return 0
}

# COLLECT_CLASS for the lines one collect cycle added (queue rows excluded).
classify_lines_only() {  # <file>
  local line c cls=neutral
  while IFS= read -r line; do
    c=$(wake_line_class "$line")
    case "$c" in
      boundary) cls=boundary; break ;;
      decision) cls=decision ;;
      routine) [ "$cls" = decision ] || cls=routine ;;
      ack) [ "$cls" != neutral ] || cls=ack ;;
    esac
  done < "$1"
  COLLECT_CLASS=$cls
}

# Hold a cold, decision-free wake or coalesce a warm one before it is
# delivered. Leaves OUT carrying every collected wake line and POLICY_NOTE the
# banner line explaining a hold.
hold_or_coalesce() {
  local now idle deadline bound held_since why streak
  [ -n "$OUT" ] || return 0
  classify_batch "$OUT"
  [ "$BATCH_CLASS" != boundary ] || return 0
  now=$(date +%s)
  idle=$((now - $(last_activity)))
  if [ "$BATCH_CLASS" != decision ] && [ "$POLICY_CACHE_TTL" -gt 0 ] && [ "$POLICY_HOLD_MAX" -gt 0 ] \
    && [ "$idle" -ge "$POLICY_CACHE_TTL" ] && [ ! -e "$STATE/.afk-contract" ]; then
    deadline=$((now + POLICY_HOLD_MAX))
    bound=0
    if [ "$deadline" -ge "$BUDGET_DEADLINE" ]; then deadline=$BUDGET_DEADLINE; bound=1; fi
    held_since=$now
    why='the hold limit'
    streak=0
    while :; do
      collect_cycle "$deadline" "$bound"
      case "$COLLECT_END" in
        activity) why='activity in the session'; break ;;
        closed)
          case "$COLLECT_CLASS" in
            neutral|ack)
              # Nothing new that needs the model: keep holding, but a cycle
              # that keeps closing with no event must not spin.
              if [ "$COLLECT_CLASS" = neutral ]; then streak=$((streak + 1)); else streak=0; fi
              if [ "$streak" -ge 3 ]; then why='repeated empty supervision cycles'; break; fi
              sleep 1
              continue
              ;;
            *) why='a second event batch'; break ;;
          esac
          ;;
        deadline) [ "$bound" -eq 0 ] || why='the park budget'; break ;;
        *) why='an ended supervision cycle'; break ;;
      esac
    done
    POLICY_NOTE="This wake was held $(( $(date +%s) - held_since ))s: you had been idle ${idle}s, past the ${POLICY_CACHE_TTL}s prompt-cache window, and nothing pending needed a decision; it was released by $why."
    return 0
  fi
  [ "$POLICY_COALESCE" -gt 0 ] || return 0
  deadline=$((now + POLICY_COALESCE))
  bound=0
  if [ "$deadline" -ge "$BUDGET_DEADLINE" ]; then deadline=$BUDGET_DEADLINE; bound=1; fi
  streak=0
  while :; do
    collect_cycle "$deadline" "$bound"
    case "$COLLECT_END" in
      closed)
        [ "$COLLECT_CLASS" != boundary ] || break
        [ "$(date +%s)" -lt "$deadline" ] || break
        if [ "$COLLECT_CLASS" = neutral ]; then streak=$((streak + 1)); else streak=0; fi
        [ "$streak" -lt 3 ] || break
        sleep 1
        ;;
      *) break ;;
    esac
  done
  return 0
}

OUT=
ACTIONABLE=0
HEALTHY=0
HOST_MODE=0
HOST_RC=0
ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:))'
# The home gate's owner decides (docs/configuration.md "Supervision host").
if fm_supervision_host_enabled "$CONFIG" claude; then
  HOST_MODE=1
  ACTIONABLE_RE='^(signal:|stale:|check:|heartbeat($|:)|supervision-host:)'
fi
# Park until a close: the bounded attempt loop below, run once per park. After
# a host-side auto-ack the same generation parks again (wake policy above).
park_until_close() {
  local host_park
  attempt=0
  ACTIONABLE=0
  HEALTHY=0
  while [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ]; do
    # A superseded owner must not start or attach another watcher or mutate any
    # watcher/wake state: re-verify generation ownership before every arm
    # invocation, first attempt and retries alike.
    if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi
    attempt=$((attempt + 1))
    OUT=$(mktemp "$STATE/.claude-autoarm-output.XXXXXX") || OUT=
    if [ "$HOST_MODE" -eq 1 ]; then
      HOST_RC=0
      # A re-park inside this generation keeps the host's own boundary inside
      # the hook's park budget; the first park is unchanged.
      host_park=$((BUDGET_DEADLINE - $(date +%s)))
      if [ "$REPARKED" -eq 1 ] && [ "$host_park" -lt "${FM_SUPERVISION_HOST_PARK_SECONDS:-27000}" ] 2>/dev/null; then
        [ "$host_park" -ge 1 ] || host_park=1
        FM_SUPERVISION_HOST_PARK_SECONDS=$host_park FM_SUPERVISION_HOST_AUTOARM_GEN=$MY_GEN FM_SUPERVISION_HOST_OWNER_PID=$$ \
          FM_SUPERVISION_HOST_PRIMARY=claude FM_GUARD_GRACE="$GRACE" \
          "$SCRIPT_DIR/fm-supervision-host.sh" park >"${OUT:-/dev/null}" 2>&1 || HOST_RC=$?
      else
        FM_SUPERVISION_HOST_AUTOARM_GEN=$MY_GEN FM_SUPERVISION_HOST_OWNER_PID=$$ \
          FM_SUPERVISION_HOST_PRIMARY=claude FM_GUARD_GRACE="$GRACE" \
          "$SCRIPT_DIR/fm-supervision-host.sh" park >"${OUT:-/dev/null}" 2>&1 || HOST_RC=$?
      fi
    else
      run_arm "$OUT"
    fi

    # AFK may have appeared mid-cycle: the daemon owns triage now, so suppress
    # every subsequent classification and handoff.
    if [ -e "$STATE/.afk" ]; then
      autoarm_record afk
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 0
    fi

    ACTIONABLE=0
    if [ -n "$OUT" ]; then
      grep -Eq "$ACTIONABLE_RE" "$OUT" 2>/dev/null && ACTIONABLE=1
    fi
    [ "$ACTIONABLE" -eq 1 ] && break
    if [ "$HOST_MODE" -eq 1 ]; then
      # The host stood down because this session or generation no longer owns
      # supervision: whoever does owns continuity now.
      if [ -n "$OUT" ] && grep -q '^supervision-host stood down:' "$OUT" 2>/dev/null; then
        autoarm_record clean
        rm -f "$OUT" 2>/dev/null || true
        exit 0
      fi
      # A host that died without a close may have left its cycle running with
      # no owner to deliver the close; retrying lets the next host stop what it
      # left and own a fresh cycle, which the healthy-watcher predicate cannot.
      if [ "$HOST_RC" -gt 128 ] || [ -z "$OUT" ] || [ ! -s "$OUT" ]; then
        [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
        [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
        OUT=
        continue
      fi
      # A failed hand-back cannot be dismissed just because its successor
      # watcher is healthy: the close is still undelivered.
      [ "$HOST_RC" -eq 0 ] || break
    fi

    # A non-actionable close is benign when another verified watcher already owns
    # this home and is still beating within the shared grace window.
    if fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
      HEALTHY=1
      break
    fi
    [ "$attempt" -lt "$AUTOARM_ATTEMPTS" ] || break
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    OUT=
  done
}

while :; do
  park_until_close
  [ "$ACTIONABLE" -eq 1 ] || break
  [ ! -e "$FAILURE_ALARM" ] || break
  need_supervision || break
  autoack_batch "$OUT" || break
  # Acknowledged host-side: nothing to deliver, so park again for the next
  # event in this same generation.
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  OUT=
  REPARKED=1
done

# The need may have vanished mid-cycle (fleet torn down, X opted out): nothing
# left to supervise, so close quietly instead of waking the model.
if ! need_supervision; then
  autoarm_record clean
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$HEALTHY" -eq 1 ]; then
  fm_autoarm_reset_owned "$STATE" "$MY_GEN"
  RESET_RC=$?
  if [ "$RESET_RC" -eq 0 ]; then
    autoarm_record clean
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  if [ "$RESET_RC" -eq 2 ]; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  if autoarm_commit failed-suppressed; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    [ -e "$FAILURE_ALARM" ] && exit 0
    exit 2
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# After the synchronous guard has consumed the episode's attended fail-open,
# do not create another exit-2 continuation that could defeat it.
if [ -e "$FAILURE_ALARM" ]; then
  autoarm_record failed-suppressed
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

if [ "$ACTIONABLE" -eq 1 ]; then
  # Coalesce a warm wake with what follows it, or hold a cold decision-free
  # one (wake policy above); the need may vanish meanwhile.
  hold_or_coalesce
  if ! need_supervision; then
    autoarm_record clean
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  # Cheap early-out before composing the banner; the real commit decision is
  # the owned terminal write below.
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  # The host owns its own successors and stops its cycle before handing back.
  if [ "$HOST_MODE" -eq 0 ]; then
    start_handling_successor "$CLOSED_ARM_PID" || true
  fi
  {
    printf 'firstmate watcher wake - one supervision event needs a handling turn now.\n'
    if [ "$HOST_MODE" -eq 1 ]; then
      [ -n "$OUT" ] && awk '/^supervision-host:/ { print; next } /^(signal:|stale:|check:|heartbeat)/ && shown++ < 8' "$OUT" 2>/dev/null
    else
      [ -n "$OUT" ] && grep -E '^(signal:|stale:|check:|heartbeat)' "$OUT" 2>/dev/null | head -8
    fi
    if [ "$HOST_MODE" -eq 1 ] && [ -e "$STATE/.afk-contract" ] \
      && [ "$(FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" != quiet ]; then
      printf 'This wake comes from automatic supervision under the away-posture record, not from the captain: it is not a return, so handle it under the away posture.\n'
    fi
    [ -z "$SUCCESSOR_FAILURE" ] || printf '%s\n' "$SUCCESSOR_FAILURE"
    [ -z "$POLICY_NOTE" ] || printf '%s\n' "$POLICY_NOTE"
    autoack_digest_line
    printf 'Run bin/fm-wake-drain.sh first, handle the wake, then run its exact WAKE_ACK_REQUIRED --ack-through command. Until that post-handling acknowledgement, interruption leaves the wake durable for idempotent re-handling. This Stop hook owns watcher continuity: when the handling turn ends, the next needed cycle arms automatically - do NOT run bin/fm-watch-arm.sh after an ordinary wake.\n'
  } >&2
  if autoarm_commit rewake; then
    # The digest above is delivered with this wake; the log keeps the record.
    rm -f "$AUTOACK_PENDING" 2>/dev/null || true
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  if [ "$HOST_MODE" -eq 1 ] && fm_autoarm_still_owner "$STATE" "$MY_GEN" \
    && fm_recovery_marker_snapshot "$STATE/.watcher-down" \
    && [[ "$FM_RECOVERY_MARKER_TOKEN" == pending:handling:* || "$FM_RECOVERY_MARKER_TOKEN" == announced:handling:* ]] \
    && ! fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "$GRACE" "$FM_HOME"; then
    LOST_HANDBACK_COMMITTED=0
    if [ ! -e "$FAILURE_NOTICE" ]; then
      printf 'firstmate watcher auto-arm FAILED - the supervision host returned an actionable wake, but its rewake could not be committed.\n' >&2
      autoarm_commit failed "$FAILURE_NOTICE" && LOST_HANDBACK_COMMITTED=1
    else
      autoarm_commit failed-suppressed && LOST_HANDBACK_COMMITTED=1
    fi
    if [ "$LOST_HANDBACK_COMMITTED" -eq 1 ]; then
      [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
      exit 2
    fi
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi

# Notify only once for this continuous failure episode; every later invocation
# still exits 2 so Claude must continue into another Stop-owned retry without
# creating a repeated operator notice or manual-arm loop. The notice marker
# commits in the same owned critical section as the winning failed write, so a
# losing generation can neither consume nor deliver it.
if [ ! -e "$FAILURE_NOTICE" ]; then
  if ! fm_autoarm_still_owner "$STATE" "$MY_GEN"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 0
  fi
  {
    printf 'firstmate watcher auto-arm FAILED - the Stop-owned automatic supervision mechanism is broken after %s bounded attempts, and no live watcher with a fresh beacon was verified.\n' "$attempt"
    [ -n "$OUT" ] && grep -E '^(watcher:|signal:|stale:|check:|heartbeat|supervision-host)' "$OUT" 2>/dev/null | head -8
    [ "$HOST_MODE" -eq 0 ] || printf 'The supervision host (docs/supervision-host.md) ran these cycles; its last one exited %s without a wake.\n' "$HOST_RC"
    printf 'Do not launch a manual background arm from this notice; investigate the automatic Stop hook and watcher startup before ending blind.\n'
  } >&2
  if autoarm_commit failed "$FAILURE_NOTICE"; then
    [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
    exit 2
  fi
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 0
fi
if autoarm_commit failed-suppressed; then
  [ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
  exit 2
fi
[ -z "$OUT" ] || rm -f "$OUT" 2>/dev/null || true
exit 0
