#!/usr/bin/env bash
# fm-host-recover.sh - bring this home's fleet back after a host restart, with no model call.
# Usage: fm-host-recover.sh [--dry-run] [--force]
#
# Run it once after the host restarts. It exits at once, printing nothing,
# when the boot id is the one it recorded last time; --force runs it anyway.
#
# Steps, in this order:
#   1. Queue: start the daemon when it is not running (it is deliberately not
#      started at boot). While the pause record state/captain-pause.flag
#      exists, make sure the queue is paused; otherwise leave admission as the
#      daemon restored it and say which that is.
#   2. Classify the endpoint of each ship and scout this home records:
#        dead          no agent is running in it
#        not-launched  an agent is running that the fleet did not launch: no
#                      agent process carries FM_TASK_ID for the task, or that
#                      process is not in the recorded worktree, or the task's
#                      busy generation is older than this boot. A terminal
#                      backend that restores panes after a restart leaves
#                      exactly this, and the pane still reads as a live agent.
#        healthy       a fleet-launched agent is running
#        unknown       the readings do not settle it; it is left alone
#   3. Relaunch each dead and each not-launched worker with the existing
#      bin/fm-control.sh <id> relaunch, giving it a generated note: that the
#      host restarted, which of its queue jobs were lost, and - while the pause
#      record exists - that the fleet is paused and it should wait for the
#      resume message. A dead worker whose newest status is `done` or `failed`
#      is not relaunched: nothing is running and its work is finished.
#   4. Second mates: report each one and its state. A local one that is dead
#      or not-launched (its marker is FM_TASK_INBOX) is relaunched with the
#      same verb, except while the fleet is paused, because a relaunched second
#      mate reads no note and would start supervising; the exact command is
#      printed instead. A remote one is only reported, with the command that
#      relaunches it. A second mate's own crew is recovered in its own home.
#   5. Print a summary table, then record the boot id - last, and only when no
#      step failed, so a run that failed part-way is retried by running it
#      again.
#
# The lost jobs come from the queue's published snapshot: the snapshot the
# previous boot's daemon left names every job that was live when the host went
# down, and once the daemon is running again its own list names the jobs it
# ended at the restart. That second list holds only its latest finished jobs,
# so a note built from it alone also tells the worker to check its last job.
#
# --dry-run prints every command that would run and every note that would be
# given, and changes nothing.
#
# bin/fm-fleet-pause-lib.sh owns the records, the queue snapshot trust rule,
# and the classification. This command never recovers a second mate's crew
# from here and never steers anyone: it relaunches, and a relaunched worker
# reads its instructions and the note.
#
# Exit: 0 recovered, or nothing to do; 1 a step that matters failed (named on
# stderr) and the boot id was not recorded; 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck disable=SC2034 # Read by the sourced libraries.
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  echo "usage: fm-host-recover.sh [--dry-run] [--force]" >&2
}

DRY_RUN=0
FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help)
      sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *) usage; exit 2 ;;
  esac
done

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# relaunch a crew (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-host-recover.sh cannot find this home's fleet (FM_HOME '$FM_HOME')" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || { echo "error: fm-host-recover.sh needs jq" >&2; exit 1; }
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
FLAG=$(fm_fleet_pause_flag)
DIR=$(fm_fleet_dir)
NOW=$(date +%s)

BOOT=$(fm_fleet_boot_id 2>/dev/null) || {
  echo "error: this host exposes no boot id, so fm-host-recover.sh cannot tell one boot from the next" >&2
  exit 1
}
RECORDED_BOOT=$(fm_meta_get "$DIR/host-boot" boot_id)
# The same boot as the last finished recovery: nothing to do, and nothing to say.
if [ "$RECORDED_BOOT" = "$BOOT" ] && [ "$FORCE" != 1 ]; then
  exit 0
fi

fm_fleet_lock
fm_fleet_dir_ensure || {
  echo "error: $DIR could not be created" >&2
  exit 1
}

PAUSED=0
[ ! -e "$FLAG" ] || PAUSED=1
BOOT_BOUND=$(fm_fleet_boot_epoch_bound 2>/dev/null) || BOOT_BOUND=
BOOT_UTC=
[ -z "$BOOT_BOUND" ] || BOOT_UTC=$(fm_fleet_utc_minute "$BOOT_BOUND")

HEAD="host recovery: home $FM_HOME, boot $BOOT (last recovered boot: ${RECORDED_BOOT:-none})"
[ "$DRY_RUN" != 1 ] || HEAD="$HEAD (dry run: nothing is changed)"
fm_fleet_note "$HEAD"
[ "$PAUSED" = 0 ] || fm_fleet_note "pause record: present ($(head -n 1 "$FLAG" 2>/dev/null)); the fleet stays paused"

# --- 1. the queue ---------------------------------------------------------------

# The jobs the restart cut, in the jobs.tsv row shape, and how much of the
# truth they are: `complete` when read from the snapshot the previous boot
# left, `partial` when only the restarted daemon's list of recent endings was
# available, `none` when the queue's records could not be read at all.
LOST_ROWS=
LOST_SOURCE=none

recover_queue() {
  local bin snapshot_boot extra
  if ! bin=$(fm_fleet_jobqueue_bin); then
    fm_fleet_note "queue: jobqueue is not installed here; skipped"
    return 0
  fi
  snapshot_boot=$(fm_fleet_queue_snapshot_boot)
  if [ -n "$snapshot_boot" ] && [ "$snapshot_boot" != "$BOOT" ]; then
    LOST_ROWS=$(fm_fleet_queue_live_rows) || LOST_ROWS=
    LOST_SOURCE=complete
  fi
  fm_fleet_queue_probe
  if [ "$FM_FLEET_QUEUE" = down ]; then
    fm_fleet_note "queue: ${FM_FLEET_QUEUE_WHY:-daemon not running}; starting it"
    fm_fleet_queue_start || return 1
    if [ "$DRY_RUN" = 1 ]; then
      [ "$PAUSED" = 0 ] || fm_fleet_note "would then pause the queue if it comes up admitting ($(fm_fleet_show "$bin" pause))"
      return 0
    fi
    fm_fleet_queue_probe
  fi
  case "$FM_FLEET_QUEUE" in
    running|paused)
      extra=$(fm_fleet_queue_restart_rows "${BOOT_BOUND:-0}") || extra=
      if [ -n "$extra" ]; then
        LOST_ROWS=$(printf '%s\n%s\n' "$LOST_ROWS" "$extra" | awk -F '\t' 'NF >= 8 && !seen[$2]++')
      fi
      [ "$LOST_SOURCE" != none ] || LOST_SOURCE=partial
      ;;
  esac
  if [ "$PAUSED" = 1 ]; then
    case "$FM_FLEET_QUEUE" in
      paused) fm_fleet_note "queue: running and paused, as the pause record requires" ;;
      *)
        fm_fleet_queue_pause || return 1
        [ "$DRY_RUN" = 1 ] || fm_fleet_note "queue: paused (jobqueue pause), as the pause record requires"
        ;;
    esac
    return 0
  fi
  case "$FM_FLEET_QUEUE" in
    running) fm_fleet_note "queue: running and admitting" ;;
    paused) fm_fleet_note "queue: running, with admission paused by the daemon itself${FM_FLEET_QUEUE_PAUSE_REASON:+ (reason $FM_FLEET_QUEUE_PAUSE_REASON)}; left as it restored it. Run 'jobqueue resume' when the fleet should take jobs again" ;;
    *)
      fm_fleet_fail "queue: ${FM_FLEET_QUEUE_WHY:-its state could not be read}"
      return 1
      ;;
  esac
}
recover_queue || true

# --- 2 to 4. the endpoints --------------------------------------------------------

ROWS=
N_HEALTHY=0
N_RELAUNCHED=0
N_LEFT=0
N_UNSURE=0
UNSURE_IDS=

add_row() {  # <id> <kind> <endpoint> <action> <result>
  ROWS="$ROWS$1$FM_FLEET_US$2$FM_FLEET_US$3$FM_FLEET_US$4$FM_FLEET_US$5
"
}

# What a relaunched worker is told. It replaces a conversation that is gone,
# so it carries everything the worker cannot learn from its instructions.
note_text() {  # <id> <why>
  local id=$1 why=$2 rows
  printf 'Host recovery (bin/fm-host-recover.sh, %s): this worker was relaunched because %s.\n' \
    "$(fm_fleet_utc_minute "$NOW")" "$why"
  [ -z "$BOOT_UTC" ] || printf 'The host last started at about %s.\n' "$BOOT_UTC"
  rows=$(printf '%s\n' "$LOST_ROWS" | awk -F '\t' -v task="$id" '$1 == task')
  case "$LOST_SOURCE" in
    complete)
      if [ -n "$rows" ]; then
        printf 'These queue jobs of yours were live when the host went down and are lost:\n'
        printf '%s\n' "$rows" | fm_fleet_jobs_describe
      else
        printf 'No queue job of yours was live when the host went down.\n'
      fi
      ;;
    partial)
      if [ -n "$rows" ]; then
        printf 'The job queue ended these jobs of yours at the restart:\n'
        printf '%s\n' "$rows" | fm_fleet_jobs_describe
        printf 'It lists only its latest finished jobs, so also check your own last job with `jobqueue show <id>`.\n'
      else
        printf 'The job queue lists no job of yours as ended by the restart, but it lists only its latest finished jobs: check your own last job with `jobqueue show <id>` before relying on its result.\n'
      fi
      ;;
    *)
      printf 'Which of your queue jobs the restart cut could not be read: check your last job with `jobqueue show <id>` before relying on its result.\n'
      ;;
  esac
  if [ "$PAUSED" = 1 ]; then
    printf 'The fleet is paused: do not start work and do not submit queue jobs. Stay idle and wait for the resume message.\n'
  else
    printf 'Resubmit what you still need and carry on from where the previous worker stopped. Ask firstmate before re-running a gate test phase or a measurement run: those are not restart-safe.\n'
  fi
}

# Relaunch one direct report through the control plane. Sets RELAUNCH_RESULT.
relaunch() {  # <id> <why>
  local id=$1 why=$2 text notefile out rc=0
  text=$(note_text "$id" "$why")
  if [ "$DRY_RUN" = 1 ]; then
    printf 'would run: FM_HOME=%s %s --note-file <a file holding the note below>\n' \
      "$(printf '%q' "$FM_HOME")" "$(fm_fleet_show bin/fm-control.sh "$id" relaunch)"
    printf '%s\n' "$text" | sed 's/^/  | /'
    RELAUNCH_RESULT="would relaunch ($why)"
    N_RELAUNCHED=$((N_RELAUNCHED + 1))
    return 0
  fi
  notefile=$(mktemp "$DIR/.recover-note.XXXXXX") || {
    fm_fleet_fail "task $id: NOT relaunched: the note file could not be created under $DIR"
    RELAUNCH_RESULT="FAILED: no note file"
    return 1
  }
  printf '%s\n' "$text" > "$notefile"
  fm_fleet_note "task $id: relaunching ($why) ..."
  out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --note-file "$notefile" 2>&1 </dev/null) || rc=$?
  rm -f "$notefile"
  if [ "$rc" -ne 0 ]; then
    fm_fleet_fail "task $id: NOT relaunched (fm-control exit $rc): $(fm_fleet_tail "$out")"
    RELAUNCH_RESULT="FAILED: relaunch refused or failed ($why)"
    return 1
  fi
  N_RELAUNCHED=$((N_RELAUNCHED + 1))
  RELAUNCH_RESULT="relaunched ($why)"
  fm_fleet_note "task $id: relaunched"
}

recover_task() {  # <id> <kind>
  local id=$1 kind=$2 verb
  fm_fleet_classify "$id"
  case "$FM_FLEET_CLASS" in
    healthy)
      N_HEALTHY=$((N_HEALTHY + 1))
      add_row "$id" "$kind" "$FM_FLEET_ENDPOINT" none "healthy${FM_FLEET_UNSURE:+ (not checked: $FM_FLEET_UNSURE)}"
      return 0
      ;;
    dead|not-launched) ;;
    *)
      # Nothing may be relaunched on a guess: a second agent on a live
      # worktree is worse than a worker left as it is. It is reported, and it
      # does not fail the run, because no step failed.
      N_UNSURE=$((N_UNSURE + 1))
      UNSURE_IDS="$UNSURE_IDS $id"
      add_row "$id" "$kind" "$FM_FLEET_ENDPOINT" none "NOT DETERMINED: $FM_FLEET_WHY"
      return 0
      ;;
  esac
  if [ "$FM_FLEET_CLASS" = dead ]; then
    verb=$(status_line_verb "$(last_status_line "$STATE/$id.status")")
    case "$verb" in
      "done"|failed)
        N_LEFT=$((N_LEFT + 1))
        add_row "$id" "$kind" "$FM_FLEET_ENDPOINT" none "not relaunched: its newest status is $verb, so its work is finished"
        return 0
        ;;
    esac
  fi
  relaunch "$id" "$FM_FLEET_WHY" || true
  add_row "$id" "$kind" "$FM_FLEET_ENDPOINT" relaunch "$RELAUNCH_RESULT"
}

recover_mate() {  # <id>
  local id=$1 host state
  host=$(fm_meta_get "$STATE/$id.meta" remote_host)
  if [ -n "$host" ]; then
    # Its endpoint lives on another host; bin/fm-crew-state.sh is the reader
    # that asks that host, and a host that does not answer must not hold this
    # recovery up.
    state=$(fm_run_timed 45 "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null </dev/null | head -n 1) || state=
    add_row "$id" secondmate "remote:$host" none "${state:-state not read}; to relaunch it run: FM_HOME=$FM_HOME bin/fm-remote-secondmate-relaunch.sh $id default default default"
    return 0
  fi
  fm_fleet_classify "$id"
  case "$FM_FLEET_CLASS" in
    healthy)
      N_HEALTHY=$((N_HEALTHY + 1))
      add_row "$id" secondmate "$FM_FLEET_ENDPOINT" none "healthy${FM_FLEET_UNSURE:+ (not checked: $FM_FLEET_UNSURE)}"
      ;;
    dead|not-launched)
      if [ "$PAUSED" = 1 ]; then
        N_LEFT=$((N_LEFT + 1))
        add_row "$id" secondmate "$FM_FLEET_ENDPOINT" none "$FM_FLEET_WHY; not relaunched while the fleet is paused. After the resume run: FM_HOME=$FM_HOME bin/fm-control.sh $id relaunch"
        return 0
      fi
      if relaunch "$id" "$FM_FLEET_WHY"; then
        add_row "$id" secondmate "$FM_FLEET_ENDPOINT" relaunch "$RELAUNCH_RESULT"
      else
        add_row "$id" secondmate "$FM_FLEET_ENDPOINT" relaunch "$RELAUNCH_RESULT; if its endpoint is gone run: FM_HOME=$FM_HOME bin/fm-spawn.sh $id --secondmate"
      fi
      ;;
    *)
      N_UNSURE=$((N_UNSURE + 1))
      UNSURE_IDS="$UNSURE_IDS $id"
      add_row "$id" secondmate "$FM_FLEET_ENDPOINT" none "NOT DETERMINED: $FM_FLEET_WHY"
      ;;
  esac
}

# One read of every process's launch marker serves all the classifications.
fm_fleet_proc_scan
[ "$FM_FLEET_PROC_SCAN" = ok ] || fm_fleet_note "note: this host has no /proc, so no agent's environment or working directory can be read; classification rests on the endpoint state and the busy generation alone"
while IFS=$(printf '\t') read -r kind id <&3; do
  [ -n "$id" ] || continue
  if [ "$kind" = secondmate ]; then
    recover_mate "$id"
  else
    recover_task "$id" "$kind"
  fi
done 3<<EOF
$(fm_fleet_tasks)
EOF

# --- 5. the table, then the boot id --------------------------------------------

if [ -n "$ROWS" ]; then
  printf '%-30s %-10s %-10s %-9s %s\n' TASK KIND ENDPOINT ACTION RESULT
  while IFS=$FM_FLEET_US read -r id kind endpoint action result; do
    [ -n "$id" ] || continue
    printf '%-30s %-10s %-10s %-9s %s\n' "$id" "$kind" "$endpoint" "$action" "$result"
  done <<EOF
$ROWS
EOF
else
  fm_fleet_note "tasks: this home records no direct report"
fi

if [ "$DRY_RUN" = 1 ]; then
  fm_fleet_note "would record boot $BOOT in state/fleet-pause/host-boot"
elif [ "$FM_FLEET_FAILURES" -eq 0 ]; then
  printf 'boot_id=%s\nrecovered_at=%s\n' "$BOOT" "$NOW" | fm_fleet_write "$DIR/host-boot" \
    || fm_fleet_fail "the boot id could not be recorded in $DIR/host-boot; the next run will repeat this recovery"
else
  fm_fleet_note "boot id NOT recorded because a step failed: fix it and run bin/fm-host-recover.sh again"
fi

SUMMARY="summary: $N_HEALTHY healthy, $N_RELAUNCHED relaunched, $N_LEFT left alone, $N_UNSURE not determined; $FM_FLEET_FAILURES step(s) failed"
[ "$DRY_RUN" != 1 ] || SUMMARY="$SUMMARY (dry run: these are what a real run would do)"
fm_fleet_note "$SUMMARY"
if [ "$N_UNSURE" -gt 0 ]; then
  fm_fleet_note "not determined:$UNSURE_IDS - nothing was relaunched for them. Check each with bin/fm-crew-state.sh <task>; bin/fm-host-recover.sh --force classifies them again"
fi
if [ "$PAUSED" = 1 ]; then
  fm_fleet_note "next: the fleet is still paused. Run bin/fm-fleet-pause.sh again to restore the wait marks and stopped timers a restart undoes; bin/fm-fleet-resume.sh ends the pause"
fi

[ "$FM_FLEET_FAILURES" -eq 0 ] || exit 1
exit 0
