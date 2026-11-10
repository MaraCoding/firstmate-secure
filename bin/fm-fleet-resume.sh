#!/usr/bin/env bash
# fm-fleet-resume.sh - end this home's fleet pause in one command, with no model call.
# Usage: fm-fleet-resume.sh [--dry-run] [--stagger-secs <n>] [--force]
#
# Steps, in this order:
#   1. Refuse when there is no pause record (state/captain-pause.flag), so a
#      stray run cannot resume a queue that something else paused. --force goes
#      on anyway; it is how a resume that was cut short is finished.
#   2. Refuse when the host restarted during the pause - the boot id differs
#      from the one the pause recorded - until bin/fm-host-recover.sh has run
#      for this boot: a restart can leave agents in the panes that the fleet
#      did not launch. --force goes on anyway, and step 6 still protects.
#   3. Queue: start the daemon when it is not running (it is deliberately not
#      started at boot), run `jobqueue resume` when it is paused, and confirm
#      from the snapshot the queue publishes that it is running and admitting.
#      On anything else stop with an error: the pause record stays and no
#      worker is steered.
#   4. Remove the pause record at once, because the alarm guard keys on it.
#   5. Restart exactly the systemd user units the pause recorded as stopped.
#   6. For each ship and scout that still carries the pause's wait mark
#      (key `fleet-pause`): skip it while it is held for the captain; skip it,
#      as a failure, unless a fleet-launched agent is running for it; otherwise
#      send ONE steer through bin/fm-send.sh that lists the queue jobs of its
#      that the pause cut and tells it to resubmit them and carry on, but to
#      ask before re-running a gate test phase or a measurement run, which are
#      not restart-safe. Then close the mark. Sends are --stagger-secs apart
#      (default 5) so the whole crew does not start in the same second.
#
# The steer goes first and the mark is closed only once it is recorded, so a
# worker whose steer failed keeps its mark and is picked up by the next run.
# A steer that bin/fm-send.sh refuses - for one, a worker past the crew context
# limit - is such a failure; its error says how to proceed.
#
# --dry-run prints every command that would run and every line that would be
# written, and changes nothing.
#
# bin/fm-fleet-pause-lib.sh owns the records, the wait mark, the queue
# snapshot trust rule, and what "fleet-launched" means.
#
# Exit: 0 resumed; 1 refused, or a step that matters failed (named on stderr);
# 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck disable=SC2034 # Read by the sourced libraries.
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  echo "usage: fm-fleet-resume.sh [--dry-run] [--stagger-secs <n>] [--force]" >&2
}

DRY_RUN=0
FORCE=0
STAGGER=5
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --stagger-secs)
      [ $# -ge 2 ] || { usage; exit 2; }
      STAGGER=$2
      shift 2
      ;;
    --stagger-secs=*) STAGGER=${1#--stagger-secs=}; shift ;;
    -h|--help)
      sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) usage; exit 2 ;;
  esac
done
case "$STAGGER" in
  ''|*[!0-9]*)
    echo "error: --stagger-secs must be a whole number of seconds: $STAGGER" >&2
    exit 2
    ;;
esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# resume a fleet (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-fleet-resume.sh cannot find this home's fleet (FM_HOME '$FM_HOME')" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || { echo "error: fm-fleet-resume.sh needs jq" >&2; exit 1; }
export FM_HOME

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-busy-lib.sh
. "$SCRIPT_DIR/fm-busy-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-fleet-pause-lib.sh
. "$SCRIPT_DIR/fm-fleet-pause-lib.sh"

FM_FLEET_DRY_RUN=$DRY_RUN
fm_fleet_lock

FLAG=$(fm_fleet_pause_flag)
DIR=$(fm_fleet_dir)
LEDGER="$DIR/interrupted"
TIMERS_STOPPED="$DIR/timers-stopped"

# The ships and scouts that still carry the pause's wait mark, space-separated.
marked_tasks() {
  local kind id out=''
  while IFS=$(printf '\t') read -r kind id; do
    [ -n "$id" ] && [ "$kind" != secondmate ] || continue
    ! fm_fleet_wait_open "$STATE/$id.status" || out="$out $id"
  done <<EOF
$(fm_fleet_tasks)
EOF
  printf '%s' "${out# }"
}

# --- 1. a pause record, or --force --------------------------------------------

HAD_RECORD=1
if [ ! -e "$FLAG" ]; then
  HAD_RECORD=0
  if [ "$FORCE" != 1 ]; then
    LEFT=$(marked_tasks)
    if [ -n "$LEFT" ]; then
      echo "error: there is no pause record at $FLAG, so this home's fleet is not paused. These tasks still carry a wait mark from an earlier pause that was not fully resumed: $LEFT. Finish resuming them with: bin/fm-fleet-resume.sh --force" >&2
    else
      echo "error: there is no pause record at $FLAG, so this home's fleet is not paused; nothing was changed (--force resumes anyway)" >&2
    fi
    exit 1
  fi
fi

if [ "$DRY_RUN" = 1 ]; then
  fm_fleet_note "fleet resume: home $FM_HOME (dry run: nothing is changed)"
else
  fm_fleet_note "fleet resume: home $FM_HOME"
fi
[ "$HAD_RECORD" = 1 ] || fm_fleet_note "pause record: none; going on because of --force"

# --- 2. a host restart during the pause ---------------------------------------

BOOT=$(fm_fleet_boot_id 2>/dev/null) || BOOT=
PAUSE_BOOT=$(fm_meta_get "$DIR/pause" boot_id)
if [ -z "$BOOT" ] || [ -z "$PAUSE_BOOT" ] || [ "$PAUSE_BOOT" = unknown ]; then
  [ "$HAD_RECORD" = 0 ] || fm_fleet_note "host: the boot at pause time is not recorded, so a restart during the pause cannot be ruled out here; each worker is checked before it is steered"
elif [ "$PAUSE_BOOT" != "$BOOT" ]; then
  if [ "$(fm_meta_get "$DIR/host-boot" boot_id)" = "$BOOT" ]; then
    fm_fleet_note "host: restarted during the pause; bin/fm-host-recover.sh has already run for this boot"
  elif [ "$FORCE" = 1 ]; then
    fm_fleet_note "host: restarted during the pause and bin/fm-host-recover.sh has not run for this boot; going on because of --force (a worker the fleet did not launch is not steered)"
  else
    echo "error: the host restarted during the pause (boot $PAUSE_BOOT then, $BOOT now), so the agents in the panes may not be the ones the fleet launched. Run bin/fm-host-recover.sh first, then run bin/fm-fleet-resume.sh again. Nothing was changed." >&2
    exit 1
  fi
fi

# --- 3. the queue -------------------------------------------------------------

# Returns 0 only when the queue is confirmed running and admitting (or this
# home has no job queue at all).
resume_queue() {
  local bin out rc=0
  if ! bin=$(fm_fleet_jobqueue_bin); then
    fm_fleet_note "queue: jobqueue is not installed here; nothing to resume"
    return 0
  fi
  fm_fleet_queue_probe
  if [ "$FM_FLEET_QUEUE" = down ]; then
    fm_fleet_note "queue: ${FM_FLEET_QUEUE_WHY:-daemon not running}; starting it"
    fm_fleet_queue_start || return 1
    if [ "$DRY_RUN" = 1 ]; then
      fm_fleet_dry "$bin" resume
      return 0
    fi
    fm_fleet_queue_probe
  fi
  if [ "$FM_FLEET_QUEUE" = running ]; then
    fm_fleet_note "queue: running and admitting"
    return 0
  fi
  [ "$FM_FLEET_QUEUE" != stale ] || fm_fleet_note "queue: ${FM_FLEET_QUEUE_WHY}; resuming it anyway"
  if fm_fleet_dry "$bin" resume; then
    return 0
  fi
  out=$(fm_run_timed 120 "$bin" resume 2>&1 </dev/null) || rc=$?
  if ! fm_fleet_queue_wait 20 running; then
    fm_fleet_fail "queue: NOT resumed. It still reads $FM_FLEET_QUEUE${FM_FLEET_QUEUE_PAUSE_REASON:+ (reason $FM_FLEET_QUEUE_PAUSE_REASON)}${FM_FLEET_QUEUE_WHY:+ ($FM_FLEET_QUEUE_WHY)} after jobqueue resume (exit $rc): $(fm_fleet_tail "$out")"
    return 1
  fi
  fm_fleet_note "queue: resumed (jobqueue resume) and confirmed admitting"
}

if ! resume_queue; then
  echo "error: the queue is not confirmed running, so the pause record is kept and no worker was steered. Fix the queue and run bin/fm-fleet-resume.sh again." >&2
  exit 1
fi

# --- 4. the pause record goes the moment the queue is confirmed ---------------

if [ "$HAD_RECORD" = 1 ]; then
  if [ "$DRY_RUN" = 1 ]; then
    fm_fleet_note "would remove state/captain-pause.flag"
  elif rm -f "$FLAG" "$DIR/pause"; then
    fm_fleet_note "pause record: removed"
  else
    fm_fleet_fail "pause record: $FLAG could not be removed; the alarm guard still reads this home as paused"
  fi
fi

# --- 5. timers ----------------------------------------------------------------

resume_timers() {
  local unit out rc keep=''
  if [ ! -s "$TIMERS_STOPPED" ]; then
    fm_fleet_note "timers: the pause stopped none"
    return 0
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    fm_fleet_fail "timers: $TIMERS_STOPPED lists stopped units, but systemctl is not available here; none were started"
    return 0
  fi
  fm_fleet_systemd_env
  while IFS= read -r unit <&3 || [ -n "$unit" ]; do
    [ -n "$unit" ] || continue
    case "$unit" in
      *[!A-Za-z0-9:_.@-]*) continue ;;
    esac
    if fm_fleet_dry systemctl --user start "$unit"; then
      continue
    fi
    rc=0
    out=$(fm_run_timed 30 systemctl --user start "$unit" 2>&1 </dev/null) || rc=$?
    if [ "$rc" -ne 0 ]; then
      fm_fleet_fail "timers: $unit was not started (systemctl exit $rc): $(fm_fleet_tail "$out")"
      keep="$keep$unit
"
      continue
    fi
    fm_fleet_note "timers: started $unit"
  done 3< "$TIMERS_STOPPED"
  [ "$DRY_RUN" != 1 ] || return 0
  if [ -n "$keep" ]; then
    printf '%s' "$keep" | fm_fleet_write "$TIMERS_STOPPED" || true
  else
    rm -f "$TIMERS_STOPPED"
  fi
}
resume_timers

# --- 6. the workers -----------------------------------------------------------

N_MARKED=0
N_STEERED=0
N_HELD=0
N_SKIPPED=0
SENT_ANY=0
HOLD_UNREADABLE=0

# What the worker is told. One message, because every message costs it a turn.
steer_text() {  # <id>
  local id=$1 rows
  rows=$(fm_fleet_jobs_for "$id")
  printf 'Fleet resume: the fleet-wide pause is over and the job queue is admitting again.\n'
  if [ -f "$LEDGER" ] && awk -F '\t' -v id="$id" '$1 == id { found = 1 } END { exit(found ? 0 : 1) }' "$LEDGER"; then
    printf 'The pause interrupted the turn you were in.\n'
  fi
  if [ -n "$rows" ]; then
    printf 'The pause cancelled these queue jobs of yours (they ended with exit 130, reason "paused"):\n'
    printf '%s\n' "$rows" | fm_fleet_jobs_describe
    printf 'Resubmit them and carry on from where you stopped.\n'
  elif [ -f "$(fm_fleet_jobs_file)" ] && ! fm_fleet_jobs_incomplete; then
    printf 'The pause cancelled no queue job of yours. Carry on from where you stopped.\n'
  else
    printf 'Which of your queue jobs the pause cancelled was not recorded. Check your last job with `jobqueue show <id>`; resubmit it if it ended with reason "paused", then carry on from where you stopped.\n'
  fi
  printf 'Ask firstmate before re-running a gate test phase or a measurement run: those are not restart-safe.\n'
  printf 'Anything else you were waiting on before the pause still holds.\n'
}

resume_task() {  # <id>
  local id=$1 statusf="$STATE/$1.status" text out rc=0 jobs
  fm_fleet_wait_open "$statusf" || return 0
  N_MARKED=$((N_MARKED + 1))
  # A task held for the captain stays parked: telling it to carry on would
  # countermand the hold. Its mark stays too, so a later run steers it once
  # the hold is released. Only a positive answer counts as held, which is the
  # rule the watcher applies to the same predicate.
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" >/dev/null 2>&1 </dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    N_HELD=$((N_HELD + 1))
    fm_fleet_note "task $id: held for the captain; not steered, its wait mark stays"
    return 0
  fi
  [ "$rc" -ne 2 ] || HOLD_UNREADABLE=1
  fm_fleet_classify "$id"
  if [ "$FM_FLEET_CLASS" != healthy ]; then
    N_SKIPPED=$((N_SKIPPED + 1))
    case "$FM_FLEET_CLASS" in
      dead) fm_fleet_fail "task $id: NOT steered: $FM_FLEET_WHY. Relaunch it with bin/fm-host-recover.sh --force (or bin/fm-control.sh $id relaunch --note ...), then run bin/fm-fleet-resume.sh --force" ;;
      not-launched) fm_fleet_fail "task $id: NOT steered: the fleet did not launch the agent in its endpoint ($FM_FLEET_WHY). Run bin/fm-host-recover.sh --force, then bin/fm-fleet-resume.sh --force" ;;
      *) fm_fleet_fail "task $id: NOT steered: $FM_FLEET_WHY. Check it with bin/fm-crew-state.sh $id, then run bin/fm-fleet-resume.sh --force" ;;
    esac
    return 0
  fi
  text=$(steer_text "$id")
  jobs=$(fm_fleet_jobs_for "$id" | grep -c . || true)
  if [ "$SENT_ANY" = 1 ] && [ "$STAGGER" -gt 0 ] && [ "$DRY_RUN" != 1 ]; then
    sleep "$STAGGER"
  fi
  SENT_ANY=1
  if fm_fleet_dry_house fm-send.sh "$id" "$text"; then
    fm_fleet_status_append "$id" "resolved [key=$FM_FLEET_PAUSE_KEY]: fleet resumed by firstmate"
    N_STEERED=$((N_STEERED + 1))
    return 0
  fi
  rc=0
  out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-send.sh" "$id" "$text" 2>&1 </dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    N_SKIPPED=$((N_SKIPPED + 1))
    fm_fleet_fail "task $id: NOT steered: bin/fm-send.sh refused or failed (exit $rc): $(fm_fleet_tail "$out"). Its wait mark stays. Steer it by hand, or run bin/fm-fleet-resume.sh --force again (FM_SEND_CONTEXT_CHECK=0 in the environment skips fm-send's context-size refusal)"
    return 0
  fi
  N_STEERED=$((N_STEERED + 1))
  if fm_fleet_status_append "$id" "resolved [key=$FM_FLEET_PAUSE_KEY]: fleet resumed by firstmate"; then
    fm_fleet_note "task $id: steered ($jobs cut job(s) listed)${FM_FLEET_UNSURE:+; note: $FM_FLEET_UNSURE}"
  else
    fm_fleet_fail "task $id: steered, but its wait mark could not be closed in $statusf; close it by appending 'resolved [key=$FM_FLEET_PAUSE_KEY]: fleet resumed' or the next resume will steer it again"
  fi
}

# One read of every process's launch marker serves all the per-worker checks.
fm_fleet_proc_scan
MATE_LINES=
while IFS=$(printf '\t') read -r kind id <&3; do
  [ -n "$id" ] || continue
  if [ "$kind" = secondmate ]; then
    [ -n "$(fm_meta_get "$STATE/$id.meta" remote_host)" ] \
      || MATE_LINES="${MATE_LINES}second mate $id: not touched by this command (if its own home was paused, run bin/fm-fleet-resume.sh there)
"
    continue
  fi
  resume_task "$id"
done 3<<EOF
$(fm_fleet_tasks)
EOF
[ "$N_MARKED" -gt 0 ] || fm_fleet_note "tasks: none carries a fleet-pause wait mark"
[ -z "$MATE_LINES" ] || printf '%s' "$MATE_LINES"
[ "$HOLD_UNREADABLE" = 0 ] || fm_fleet_note "note: bin/fm-captain-hold.sh could not say whether some task is held for the captain; those were treated as not held"

# --- summary ------------------------------------------------------------------

LEFT=$((N_MARKED - N_STEERED))
if [ "$DRY_RUN" != 1 ] && [ "$LEFT" -eq 0 ] && [ "$FM_FLEET_FAILURES" -eq 0 ]; then
  # Nothing is left to steer, so the job list and the interrupt ledger of this
  # pause have told every worker what they hold.
  rm -f "$(fm_fleet_jobs_file)" "$LEDGER"
fi
SUMMARY="summary: $N_MARKED marked task(s): $N_STEERED steered, $N_HELD held for the captain, $N_SKIPPED not steered; $FM_FLEET_FAILURES step(s) failed"
[ "$DRY_RUN" != 1 ] || SUMMARY="$SUMMARY (dry run: these are what a real run would do)"
fm_fleet_note "$SUMMARY"
if [ "$LEFT" -gt 0 ] && [ "$DRY_RUN" != 1 ]; then
  fm_fleet_note "next: $LEFT task(s) keep their wait mark; once they can be steered run: bin/fm-fleet-resume.sh --force"
fi

[ "$FM_FLEET_FAILURES" -eq 0 ] || exit 1
exit 0
