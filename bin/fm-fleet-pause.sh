#!/usr/bin/env bash
# fm-fleet-pause.sh - pause this home's whole fleet in one command, with no model call.
# Usage: fm-fleet-pause.sh [--dry-run] [--reason <text>]
#
# Steps, in this order:
#   1. Write the pause record state/captain-pause.flag FIRST, so everything
#      that reads it sees the pause before anything else moves.
#   2. Save the queue's live jobs to state/fleet-pause/jobs.tsv, so the resume
#      can tell each worker which of its jobs the pause cut.
#   3. Pause the job queue with `jobqueue pause`, which closes admission and
#      cancels every active job (nothing is frozen), and confirm it from the
#      snapshot the queue publishes.
#   4. For each ship and scout this home records: interrupt it through
#      bin/fm-control.sh when its busy record says it is mid-turn, then append
#      one status line declaring a keyed wait (key `fleet-pause`) so the watcher
#      reads the worker as waiting. No message is sent to any worker: a message
#      costs each of them a full-context turn.
#   5. Stop the systemd user units listed in config/fleet-pause-timers (one per
#      line, `#` comments; absent means none) that are active, and record which
#      were stopped so the resume restarts exactly those.
#   6. Where the user service cgroup has a user-writable memory.reclaim, ask it
#      to give back its file cache, bounded in size and time; a failure is
#      ignored. sudo is never used, so the last line printed is the one command
#      that returns the rest of the file cache and needs root.
#
# A worker is left unmarked when it is idle, the pause cut no job of its, and
# its newest status event already says it is finished or owed an answer by a
# person (done, failed, needs-decision, blocked, captain-held): the watcher
# keeps such a pane quiet from that event, and a mark would replace it. Second
# mates are reported and not touched; each one's crew belongs to its own home.
#
# Idempotent: run again while paused, it keeps the record (refreshing its age,
# which is what its readers measure), does not call `jobqueue pause` on a queue
# that is already paused, never interrupts the same turn twice, and re-appends
# a worker's wait mark only when it no longer stands. A step that failed is
# retried by simply running the command again.
#
# --dry-run prints every command that would run and every line that would be
# written, and changes nothing.
#
# bin/fm-fleet-pause-lib.sh owns the records, the wait mark, and the queue
# snapshot trust rule. Undo with bin/fm-fleet-resume.sh.
#
# Exit: 0 paused; 1 a step that matters failed (named on stderr); 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

usage() {
  echo "usage: fm-fleet-pause.sh [--dry-run] [--reason <text>]" >&2
}

DRY_RUN=0
REASON=
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --reason)
      [ $# -ge 2 ] || { usage; exit 2; }
      REASON=$2
      shift 2
      ;;
    --reason=*) REASON=${1#--reason=}; shift ;;
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
# pause a fleet (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

[ -d "$STATE" ] || {
  echo "error: state dir '$STATE' is missing; fm-fleet-pause.sh cannot find this home's fleet (FM_HOME '$FM_HOME')" >&2
  exit 1
}
command -v jq >/dev/null 2>&1 || { echo "error: fm-fleet-pause.sh needs jq" >&2; exit 1; }
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
NOW=$(date +%s)
BOOT=$(fm_fleet_boot_id 2>/dev/null) || BOOT=unknown

# One printable line, so free text can sit in a one-line record or status line.
one_line() {  # <text>
  printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\037\177' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c1-160
}

if [ "$DRY_RUN" = 1 ]; then
  fm_fleet_note "fleet pause: home $FM_HOME (dry run: nothing is changed)"
else
  fm_fleet_note "fleet pause: home $FM_HOME"
fi

# --- 1. the pause record, before anything else moves -------------------------

REASON=$(one_line "$REASON")
FLAG_MTIME=$NOW
if [ -e "$FLAG" ]; then
  FRESH=0
  FLAG_MTIME=$(fm_path_mtime "$FLAG" 2>/dev/null) || FLAG_MTIME=$NOW
  RECORDED_REASON=$(fm_meta_get "$DIR/pause" reason)
  [ -z "$RECORDED_REASON" ] || REASON=$RECORDED_REASON
  [ -n "$REASON" ] || REASON='captain order'
  if [ "$DRY_RUN" = 1 ]; then
    fm_fleet_note "pause record: already present ($(head -n 1 "$FLAG" 2>/dev/null)); would refresh its age"
  else
    # Its readers measure the pause from this file's age, so running the
    # command again is what confirms a long pause still holds.
    touch "$FLAG" || {
      echo "error: the pause record $FLAG could not be refreshed" >&2
      exit 1
    }
    fm_fleet_note "pause record: already present ($(head -n 1 "$FLAG" 2>/dev/null)); age refreshed"
  fi
else
  FRESH=1
  [ -n "$REASON" ] || REASON='captain order'
  RECORD_LINE="fleet pause: $REASON $(fm_fleet_utc_minute "$NOW")"
  if [ "$DRY_RUN" = 1 ]; then
    fm_fleet_note "would write state/captain-pause.flag: $RECORD_LINE"
  else
    printf '%s\n' "$RECORD_LINE" | fm_fleet_write "$FLAG" || {
      echo "error: the pause record $FLAG could not be written; nothing else was done" >&2
      exit 1
    }
    fm_fleet_note "pause record: written state/captain-pause.flag: $RECORD_LINE"
  fi
fi

fm_fleet_dir_ensure || {
  echo "error: $DIR could not be created" >&2
  exit 1
}
# The job list and the interrupt ledger belong to one pause. They carry over
# only when this run continues a pause this command began, which is what the
# detail file beside the record says; a new pause, or a record made by hand,
# starts both afresh. The stopped timers of an earlier pause are always kept:
# they are still stopped.
SAME_PAUSE=0
[ "$FRESH" = 1 ] || [ ! -f "$DIR/pause" ] || SAME_PAUSE=1
JOBS_SAVED=0
[ "$SAME_PAUSE" = 0 ] || [ ! -f "$(fm_fleet_jobs_file)" ] || JOBS_SAVED=1
if [ "$SAME_PAUSE" = 0 ]; then
  if [ "$DRY_RUN" = 1 ]; then
    # A dry run removes nothing, so it must not read what a real run would.
    LEDGER="$DIR/.no-ledger-in-a-dry-run"
  else
    rm -f "$(fm_fleet_jobs_file)" "$LEDGER"
    printf 'v=1\npaused_at=%s\nboot_id=%s\nreason=%s\n' "$FLAG_MTIME" "$BOOT" "$REASON" \
      | fm_fleet_write "$DIR/pause" \
      || fm_fleet_fail "pause record: its detail file $DIR/pause could not be written; a host restart during this pause will not be recognised by the resume"
  fi
fi

# --- 2 and 3. the queue: save what is live, then pause it ---------------------

# The rows the pause is about to cut, kept in memory as well so a dry run can
# reason about them without having written the file.
CUT_ROWS=
if [ "$JOBS_SAVED" = 1 ]; then
  CUT_ROWS=$(grep -v '^#' "$(fm_fleet_jobs_file)" || true)
fi
QUEUE_NOTE=
fm_fleet_queue_probe
case "$FM_FLEET_QUEUE" in
  paused)
    QUEUE_NOTE="queue already paused"
    fm_fleet_note "queue: already paused${FM_FLEET_QUEUE_PAUSE_REASON:+ (reason $FM_FLEET_QUEUE_PAUSE_REASON)}; not pausing it again"
    if [ "$JOBS_SAVED" = 0 ]; then
      fm_fleet_note "queue: it was paused before this command ran, so the jobs that pause cut are not recorded; the resume will tell workers to check their own last job"
      [ "$DRY_RUN" = 1 ] || : | fm_fleet_jobs_merge incomplete \
        || fm_fleet_fail "queue: $(fm_fleet_jobs_file) could not be written"
    fi
    ;;
  running|stale)
    [ "$FM_FLEET_QUEUE" = running ] || fm_fleet_note "queue: ${FM_FLEET_QUEUE_WHY}; pausing it anyway"
    LIVE_ROWS=$(fm_fleet_queue_live_rows) || LIVE_ROWS=
    LIVE_COUNT=$(printf '%s\n' "$LIVE_ROWS" | grep -c . || true)
    if [ "$DRY_RUN" = 1 ]; then
      fm_fleet_note "would save $LIVE_COUNT live job(s) to state/fleet-pause/jobs.tsv"
      CUT_ROWS=$(printf '%s\n%s\n' "$CUT_ROWS" "$LIVE_ROWS" | grep . || true)
    else
      printf '%s\n' "$LIVE_ROWS" | grep . | fm_fleet_jobs_merge \
        || fm_fleet_fail "queue: the live job list could not be saved to $(fm_fleet_jobs_file); the resume cannot name the jobs this pause cuts"
    fi
    if fm_fleet_queue_pause; then
      if [ "$DRY_RUN" != 1 ]; then
        fm_fleet_jobs_annotate || true
        CUT_ROWS=$(grep -v '^#' "$(fm_fleet_jobs_file)" 2>/dev/null || true)
        fm_fleet_note "queue: paused (jobqueue pause); $LIVE_COUNT job(s) were live and are listed in state/fleet-pause/jobs.tsv"
      fi
      QUEUE_NOTE="queue paused, $LIVE_COUNT live job(s) cut"
    else
      QUEUE_NOTE="QUEUE NOT PAUSED"
    fi
    ;;
  *)
    QUEUE_NOTE="queue daemon not running"
    fm_fleet_note "queue: ${FM_FLEET_QUEUE_WHY:-daemon not running}; nothing runs or is admitted under it, and the queue itself holds no pause. bin/fm-host-recover.sh pauses it when it starts the daemon while this pause record stands"
    ;;
esac

# How many jobs the pause cut for one task (a job that finished on its own
# before the pause reached it does not count).
cut_count() {  # <task>
  printf '%s\n' "$CUT_ROWS" | awk -F '\t' -v task="$1" '$1 == task && $9 !~ /^succeeded\// { n++ } END { print n + 0 }'
}

# --- 4. the workers ----------------------------------------------------------

N_TASKS=0
N_INTERRUPTED=0
N_MARKED=0
N_STANDING=0
N_LEFT=0
MATE_LINES=

# The busy record as written, which names one turn: a generation and a
# sequence number. An interrupt is recorded against it, so a second run sees
# the same turn and leaves it alone even on a harness that keeps reading busy
# after an interrupt (Claude writes no close for one).
busy_record() {  # <id>
  local line=''
  { IFS= read -r line < "$STATE/$1.busy-state"; } 2>/dev/null || true
  printf '%s' "${line:-no-record}"
}

interrupted_before() {  # <id> [busy-record]: this turn when given, else any turn of this pause
  [ -f "$LEDGER" ] || return 1
  if [ $# -ge 2 ]; then
    awk -F '\t' -v id="$1" -v rec="$2" '$1 == id && $2 == rec { found = 1 } END { exit(found ? 0 : 1) }' "$LEDGER"
  else
    awk -F '\t' -v id="$1" '$1 == id { found = 1 } END { exit(found ? 0 : 1) }' "$LEDGER"
  fi
}

pause_task() {  # <id>
  local id=$1 meta="$STATE/$1.meta" statusf="$STATE/$1.status"
  local verdict state record out rc=0 turn mark settled cut interrupted=0
  N_TASKS=$((N_TASKS + 1))
  verdict=$(fm_busy_classify_meta "$meta" "$id" "$STATE" 2>/dev/null) || verdict='unknown unreadable'
  state=${verdict%% *}
  turn="$state (${verdict#* })"
  if [ "$state" = busy ]; then
    record=$(busy_record "$id")
    if interrupted_before "$id" "$record"; then
      turn="mid-turn, already interrupted by this pause; not interrupted twice"
    elif fm_fleet_dry_house fm-control.sh "$id" interrupt; then
      N_INTERRUPTED=$((N_INTERRUPTED + 1))
      interrupted=1
      turn="mid-turn ($verdict)"
    else
      out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" interrupt 2>&1 </dev/null) || rc=$?
      if [ "$rc" -eq 0 ]; then
        printf '%s\t%s\n' "$id" "$record" >> "$LEDGER" \
          || fm_fleet_fail "task $id: its interrupt could not be recorded in $LEDGER; running this again may interrupt the same turn twice"
        N_INTERRUPTED=$((N_INTERRUPTED + 1))
        interrupted=1
        turn="mid-turn ($verdict): interrupted"
      else
        case "$out" in
          *"there is nothing to interrupt"*)
            turn="its busy record says mid-turn, but no agent is running in its endpoint"
            ;;
          *)
            fm_fleet_fail "task $id: mid-turn and NOT interrupted (fm-control exit $rc): $(fm_fleet_tail "$out")"
            turn="mid-turn ($verdict): interrupt FAILED"
            ;;
        esac
      fi
    fi
  fi
  if [ "$interrupted" = 0 ] && interrupted_before "$id"; then
    interrupted=1
  fi
  cut=$(cut_count "$id")
  if [ "$interrupted" = 0 ] && [ "$cut" -eq 0 ] && settled=$(fm_fleet_status_settled "$statusf"); then
    N_LEFT=$((N_LEFT + 1))
    mark="left as is (newest status is $settled)"
  elif fm_fleet_wait_standing "$statusf"; then
    N_STANDING=$((N_STANDING + 1))
    mark="already marked waiting"
  elif fm_fleet_status_append "$id" "$(fm_fleet_wait_line "$REASON")"; then
    N_MARKED=$((N_MARKED + 1))
    mark="marked waiting"
  else
    fm_fleet_fail "task $id: the wait mark could not be appended to $statusf; the watcher will read this worker as idle, not waiting"
    mark="NOT marked"
  fi
  [ "$cut" -eq 0 ] || mark="$mark; $cut queue job(s) cut"
  fm_fleet_note "task $id: $turn; $mark"
}

while IFS=$(printf '\t') read -r kind id <&3; do
  [ -n "$id" ] || continue
  if [ "$kind" = secondmate ]; then
    host=$(fm_meta_get "$STATE/$id.meta" remote_host)
    if [ -n "$host" ]; then
      MATE_LINES="${MATE_LINES}second mate $id: on host $host; not paused by this command
"
    else
      MATE_LINES="${MATE_LINES}second mate $id: home $(fm_meta_get "$STATE/$id.meta" home); not paused by this command (its crew belongs to that home: run bin/fm-fleet-pause.sh there)
"
    fi
    continue
  fi
  pause_task "$id"
done 3<<EOF
$(fm_fleet_tasks)
EOF
[ "$N_TASKS" -gt 0 ] || fm_fleet_note "tasks: this home records no ship or scout"
[ -z "$MATE_LINES" ] || printf '%s' "$MATE_LINES"

# --- 5. timers ----------------------------------------------------------------

N_TIMERS=0
pause_timers() {
  local list="$CONFIG/fleet-pause-timers" unit state out rc
  if [ ! -f "$list" ]; then
    fm_fleet_note "timers: none listed (config/fleet-pause-timers is absent)"
    return 0
  fi
  if ! command -v systemctl >/dev/null 2>&1; then
    fm_fleet_fail "timers: config/fleet-pause-timers lists units, but systemctl is not available here; none were stopped"
    return 0
  fi
  fm_fleet_systemd_env
  while IFS= read -r unit <&3 || [ -n "$unit" ]; do
    unit=${unit%%#*}
    unit=$(printf '%s' "$unit" | tr -d '[:space:]')
    [ -n "$unit" ] || continue
    case "$unit" in
      *[!A-Za-z0-9:_.@-]*)
        fm_fleet_fail "timers: '$unit' in config/fleet-pause-timers is not a systemd unit name; skipped"
        continue
        ;;
    esac
    state=$(fm_run_timed 15 systemctl --user is-active "$unit" 2>/dev/null </dev/null) || true
    case "$state" in
      active|activating|reloading)
        if fm_fleet_dry systemctl --user stop "$unit"; then
          N_TIMERS=$((N_TIMERS + 1))
          continue
        fi
        rc=0
        out=$(fm_run_timed 30 systemctl --user stop "$unit" 2>&1 </dev/null) || rc=$?
        if [ "$rc" -ne 0 ]; then
          fm_fleet_fail "timers: $unit was not stopped (systemctl exit $rc): $(fm_fleet_tail "$out")"
          continue
        fi
        grep -Fqx -- "$unit" "$TIMERS_STOPPED" 2>/dev/null || printf '%s\n' "$unit" >> "$TIMERS_STOPPED" \
          || fm_fleet_fail "timers: $unit was stopped but could not be recorded in $TIMERS_STOPPED; the resume will not restart it"
        N_TIMERS=$((N_TIMERS + 1))
        fm_fleet_note "timers: stopped $unit"
        ;;
      *)
        if grep -Fqx -- "$unit" "$TIMERS_STOPPED" 2>/dev/null; then
          fm_fleet_note "timers: $unit already stopped by this pause"
        else
          fm_fleet_note "timers: $unit is ${state:-not active}; left alone"
        fi
        ;;
    esac
  done 3< "$list"
}
pause_timers

# --- 6. memory ----------------------------------------------------------------

# Only the user service cgroup's memory.reclaim is writable without root. It
# covers the queue's jobs and user services, not the agents, so it returns part
# of the cache; the root command printed last returns the rest. The request is
# bounded by the cache that cgroup actually holds and by a deadline, and what
# the kernel could not give back is not an error.
pause_memory() {
  local uid root dir file bytes rc=0
  uid=$(id -u 2>/dev/null) || return 0
  root=${FM_FLEET_PAUSE_CGROUP_ROOT:-/sys/fs/cgroup}
  dir="$root/user.slice/user-$uid.slice/user@$uid.service"
  file="$dir/memory.reclaim"
  if [ ! -f "$file" ] || [ ! -w "$file" ]; then
    fm_fleet_note "memory: no user-writable memory.reclaim for the user service cgroup; nothing reclaimed here"
    return 0
  fi
  bytes=$(awk '$1 == "file" { print $2; exit }' "$dir/memory.stat" 2>/dev/null) || bytes=
  case "$bytes" in
    ''|*[!0-9]*|0)
      fm_fleet_note "memory: the user service cgroup reports no file cache to give back"
      return 0
      ;;
  esac
  if [ "$DRY_RUN" = 1 ]; then
    fm_fleet_note "would write $bytes to $file (ask for up to $((bytes / 1048576)) MiB of file cache back, bounded to 30 s)"
    return 0
  fi
  # shellcheck disable=SC2016 # The positional parameters expand in the child shell.
  fm_run_timed 30 sh -c 'printf "%s\n" "$1" > "$2"' sh "$bytes" "$file" >/dev/null 2>&1 </dev/null || rc=$?
  if [ "$rc" -eq 0 ]; then
    fm_fleet_note "memory: the user service cgroup gave back up to $((bytes / 1048576)) MiB of file cache"
  else
    fm_fleet_note "memory: asked the user service cgroup for $((bytes / 1048576)) MiB of file cache; the kernel returned less (exit $rc, ignored)"
  fi
}
pause_memory

# --- summary ------------------------------------------------------------------

SUMMARY="summary: $N_TASKS task(s): $N_INTERRUPTED interrupted, $N_MARKED marked waiting, $N_STANDING already marked, $N_LEFT left as is; $QUEUE_NOTE; $N_TIMERS timer(s) stopped; $FM_FLEET_FAILURES step(s) failed"
[ "$DRY_RUN" != 1 ] || SUMMARY="$SUMMARY (dry run: these are what a real run would do)"
[ "$FM_FLEET_FAILURES" -eq 0 ] || SUMMARY="$SUMMARY (see the error lines; run this again to retry them)"
fm_fleet_note "$SUMMARY"
fm_fleet_note "undo with: bin/fm-fleet-resume.sh"

# The agents' file cache is charged where only root can reclaim it. Under WSL
# the root command is run from Windows, so that is the form printed, last and on
# its own line so it can be copied or taken with `tail -n 1`.
if [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft "$(fm_fleet_proc_root)/version" 2>/dev/null; then
  fm_fleet_note "file cache: only root can hand the rest back to Windows; run this in Windows:"
  fm_fleet_note "wsl -u root -d ${WSL_DISTRO_NAME:-Ubuntu} -- sh -c 'sync; echo 1 > /proc/sys/vm/drop_caches'"
elif [ -e /proc/sys/vm/drop_caches ]; then
  fm_fleet_note "file cache: only root can drop the rest; as root run:"
  fm_fleet_note "sh -c 'sync; echo 1 > /proc/sys/vm/drop_caches'"
fi

[ "$FM_FLEET_FAILURES" -eq 0 ] || exit 1
exit 0
