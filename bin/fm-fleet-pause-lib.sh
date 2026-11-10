#!/usr/bin/env bash
# fm-fleet-pause-lib.sh - shared records and readers behind the fleet-wide
# pause, resume, and host-recovery commands.
#
# Sourced by bin/fm-fleet-pause.sh, bin/fm-fleet-resume.sh, and
# bin/fm-host-recover.sh, never executed. The caller has resolved STATE and
# CONFIG the way every bin/ script does, confirmed STATE exists, and sourced
# bin/fm-backend.sh, bin/fm-busy-lib.sh, bin/fm-classify-lib.sh, and
# bin/fm-wake-lib.sh. Nothing here calls a model, uses sudo, or writes outside
# this home's state directory.
#
# THE PAUSE RECORD. state/captain-pause.flag says a fleet-wide pause is in
# force. A home's own alarm guard and queue watchdog already read it, and they
# read only whether it exists and how old it is. So three things are contract:
# the file name, the one-line shape, and "its mtime is when the pause was last
# confirmed". Everything these commands need beyond that lives beside it under
# state/fleet-pause/:
#   pause           key=value lines: v, paused_at (epoch), boot_id, reason
#   jobs.tsv        the queue jobs that were live when the pause began, one per
#                   line, and what became of each (fm_fleet_jobs_* below)
#   interrupted     <task><TAB><busy record> for each turn the pause interrupted
#   timers-stopped  the systemd user units the pause stopped, one per line
#   host-boot       key=value lines: boot_id, recovered_at - the boot the
#                   recovery command last finished for
#
# THE WAIT MARK. A paused worker is declared waiting with one ordinary status
# line, `paused [key=fleet-pause]: ... until <UTC>`, so the watcher's existing
# declared-wait handling applies and no new reader is needed. The key is what
# makes it durable: bin/fm-classify-lib.sh's keyed phase fold keeps it open
# until a `resolved [key=fleet-pause]` line closes it, whatever else the worker
# appends, and that open phase is the resume command's list of whom to steer.
# The `until` is what keeps the mark silent: a declared wait with a clearing
# time still ahead is absorbed without a wake, where one without it wakes the
# supervisor once per worker.
#
# THE QUEUE IS READ FROM ITS SNAPSHOT. The job queue's daemon atomically
# publishes status.json about once a second. It is trusted only when it is
# fresh and the daemon it names is the same live process in this boot (pid,
# start time, boot id), which is the rule the home's queue guard applies. A
# snapshot that fails it is never read as "not paused" or "nothing running".
#
# FLEET-LAUNCH EVIDENCE. A host restart can leave an agent in a task's endpoint
# that the fleet did not launch: a terminal backend that restores panes re-runs
# the bare harness, without the environment, flags, or working directory
# bin/fm-spawn.sh gave it. The endpoint classifier still reads that pane as a
# live agent. Three independent facts tell the two apart, none needing a backend
# write: some agent process carries the task's launch marker in its environment
# (FM_TASK_ID for a ship or scout, FM_TASK_INBOX for a second mate, which is not
# given FM_TASK_ID), that process's working directory is the recorded worktree,
# and the task's busy generation was minted in this boot. The marker scan cannot
# say which pane a process serves, only that the task has such a process; the
# pane-to-process link would need the backend's own process view, which no
# read-only helper exposes.

FM_FLEET_PAUSE_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$FM_FLEET_PAUSE_LIB_DIR/fm-agent-process-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_FLEET_PAUSE_LIB_DIR/fm-timeout-lib.sh"

FM_FLEET_PAUSE_KEY=fleet-pause
# How long one confirmation of a pause stays current. The pause record's readers
# stop honouring it at this age so a forgotten pause surfaces again, and each
# worker's wait mark names the same clearing time for the same reason.
FM_FLEET_PAUSE_HOLD_SECS=${FM_FLEET_PAUSE_HOLD_SECS:-43200}
case "$FM_FLEET_PAUSE_HOLD_SECS" in ''|*[!0-9]*|0) FM_FLEET_PAUSE_HOLD_SECS=43200 ;; esac
# The queue's own freshness rule is 15 s; this tolerates a loaded host.
FM_FLEET_QUEUE_FRESH_SECS=60
FM_FLEET_DRY_RUN=${FM_FLEET_DRY_RUN:-0}
FM_FLEET_FAILURES=0
FM_FLEET_LOCK=
FM_FLEET_US=$(printf '\037')

# --- output -----------------------------------------------------------------
#
# Every step that did something, or deliberately did nothing, prints one line
# on stdout as it happens. A step that failed prints `error: ...` on stderr and
# is counted; the closing summary line on stdout carries the count, and the
# command exits non-zero when it is not zero.

fm_fleet_note() {
  printf '%s\n' "$*"
}

fm_fleet_fail() {
  FM_FLEET_FAILURES=$((FM_FLEET_FAILURES + 1))
  printf 'error: %s\n' "$*" >&2
}

# One shell-quoted line for a command, so a dry run prints something that can be
# pasted back into a shell.
fm_fleet_show() {  # <command> [args...]
  local out='' arg
  for arg in "$@"; do
    out="$out$(printf '%q' "$arg") "
  done
  printf '%s' "${out% }"
}

# In a dry run, print the command and return 0 so the caller skips it.
fm_fleet_dry() {  # <command> [args...]
  [ "$FM_FLEET_DRY_RUN" = 1 ] || return 1
  printf 'would run: %s\n' "$(fm_fleet_show "$@")"
}

# The same for a sibling bin/ script, shown with the explicit home it is given.
fm_fleet_dry_house() {  # <script> [args...]
  local script=$1
  [ "$FM_FLEET_DRY_RUN" = 1 ] || return 1
  shift
  printf 'would run: FM_HOME=%s %s\n' "$(printf '%q' "$FM_HOME")" "$(fm_fleet_show "bin/$script" "$@")"
}

# The last few lines of a captured command output on one line, for a failure
# message that must say what the command said.
fm_fleet_tail() {  # <text>
  printf '%s' "$1" | tail -n 3 | tr '\n\t' '  ' | cut -c1-400
}

# --- paths, clock, lock -----------------------------------------------------

fm_fleet_pause_flag() {
  printf '%s/captain-pause.flag' "$STATE"
}

fm_fleet_dir() {
  printf '%s/fleet-pause' "$STATE"
}

fm_fleet_proc_root() {
  printf '%s' "${FM_PROC_ROOT_OVERRIDE:-/proc}"
}

fm_fleet_utc_minute() {  # <epoch> -> YYYY-MM-DDTHH:MMZ
  date -u -d "@$1" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%MZ 2>/dev/null
}

# Create state/fleet-pause/ private to this user; a dry run creates nothing.
fm_fleet_dir_ensure() {
  local dir
  dir=$(fm_fleet_dir)
  [ "$FM_FLEET_DRY_RUN" = 1 ] && return 0
  [ -d "$dir" ] || (umask 077 && mkdir -p "$dir")
}

# Replace <file> with the lines on stdin, atomically.
fm_fleet_write() {  # <file>
  local file=$1 tmp="$1.tmp.$$"
  cat > "$tmp" && mv -f "$tmp" "$file" || { rm -f "$tmp"; return 1; }
}

# One pause, resume, or recovery at a time per home: two of them interleaved
# is how an aborted resume once still reached workers. A dry run takes no lock
# because it changes nothing.
fm_fleet_lock() {
  [ "$FM_FLEET_DRY_RUN" = 1 ] && return 0
  FM_FLEET_LOCK="$STATE/.fleet-pause.lock"
  if ! fm_lock_try_acquire "$FM_FLEET_LOCK"; then
    echo "error: another fleet pause, resume, or host recovery is running for this home (pid ${FM_LOCK_HELD_PID:-unknown}); wait for it to finish" >&2
    exit 1
  fi
  trap 'fm_lock_release "$FM_FLEET_LOCK"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# --- boot identity ----------------------------------------------------------

# The kernel's id for this boot; nonzero when the host does not expose one.
fm_fleet_boot_id() {
  local file id=''
  file="$(fm_fleet_proc_root)/sys/kernel/random/boot_id"
  if [ -r "$file" ]; then
    IFS= read -r id < "$file" 2>/dev/null || true
  elif [ -z "${FM_PROC_ROOT_OVERRIDE:-}" ]; then
    id=$(sysctl -n kern.bootsessionuuid 2>/dev/null) || id=
  fi
  case "$id" in ''|*[!A-Za-z0-9-]*) return 1 ;; esac
  printf '%s' "$id"
}

# The latest wall-clock second this boot can have started at, or nonzero when
# unknown. /proc/stat's btime is the obvious reading and is not enough alone:
# on WSL2 it moves LATER every time the clock is stepped after the host slept
# (measured here: 20 minutes late nine hours into a boot), and a generation
# minted between the real boot and that drifted figure would read as older
# than the boot. Every candidate below can only be at or after the real boot -
# btime, and the modification time of things the boot itself creates on
# memory-backed filesystems - so the earliest of them is the tightest bound and
# an error in any one of them can only make a generation look newer, never
# older, which is the direction that relaunches nothing.
fm_fleet_boot_epoch_bound() {
  local root best='' value anchor
  root=$(fm_fleet_proc_root)
  value=$(awk '$1 == "btime" { print $2; exit }' "$root/stat" 2>/dev/null) || value=
  case "$value" in ''|*[!0-9]*) ;; *) best=$value ;; esac
  if [ -z "${FM_PROC_ROOT_OVERRIDE:-}" ]; then
    for anchor in "$root/1" /run/systemd/system /dev/shm; do
      [ -e "$anchor" ] || continue
      value=$(fm_path_mtime "$anchor") || continue
      case "$value" in ''|*[!0-9]*) continue ;; esac
      if [ -z "$best" ] || [ "$value" -lt "$best" ]; then best=$value; fi
    done
    if [ -z "$best" ]; then
      value=$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*sec = \([0-9][0-9]*\).*/\1/p')
      case "$value" in ''|*[!0-9]*) ;; *) best=$value ;; esac
    fi
  fi
  [ -n "$best" ] || return 1
  printf '%s' "$best"
}

# --- the job queue ----------------------------------------------------------

fm_fleet_jobqueue_bin() {
  local bin
  if bin=$(command -v jobqueue 2>/dev/null) && [ -n "$bin" ]; then
    printf '%s' "$bin"
    return 0
  fi
  if [ -x "$HOME/.local/bin/jobqueue" ]; then
    printf '%s' "$HOME/.local/bin/jobqueue"
    return 0
  fi
  return 1
}

# Where the queue keeps its state; mirrors the queue CLI's own default.
fm_fleet_queue_state_dir() {
  printf '%s' "${JOBQUEUE_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/jobqueue}"
}

fm_fleet_queue_snapshot() {
  printf '%s/status.json' "$(fm_fleet_queue_state_dir)"
}

# Classify the queue from its published snapshot (the header's trust rule).
# Sets FM_FLEET_QUEUE to:
#   running  the daemon is live and admitting
#   paused   the daemon is live and paused (FM_FLEET_QUEUE_PAUSE_REASON says why)
#   stale    the daemon named by the snapshot is live, but the snapshot is old
#            or not a shape this reader knows, so its contents prove nothing
#   down     no snapshot, or the daemon it names is not running in this boot
# and FM_FLEET_QUEUE_WHY to a short reason for the two untrusted states.
fm_fleet_queue_probe() {
  local snap fields schema version generated pid start boot paused reason
  local now made age stat_line
  local -a stat_fields
  FM_FLEET_QUEUE=down
  FM_FLEET_QUEUE_WHY=
  FM_FLEET_QUEUE_PAUSE_REASON=
  snap=$(fm_fleet_queue_snapshot)
  if [ ! -r "$snap" ]; then
    FM_FLEET_QUEUE_WHY="no queue snapshot at $snap"
    return 0
  fi
  fields=$(jq -r '[ .schema, (.schema_version // .version), .generated_at,
      .daemon.pid, .daemon.start_time, .daemon.boot_id,
      (if .paused == true then "true" elif .paused == false then "false" else null end),
      .pause_reason ]
    | map(if . == null or . == "" then "-" else tostring end) | join("\u001f")' "$snap" 2>/dev/null) || fields=
  if [ -z "$fields" ]; then
    FM_FLEET_QUEUE_WHY="queue snapshot $snap is not readable JSON"
    return 0
  fi
  IFS=$FM_FLEET_US read -r schema version generated pid start boot paused reason <<EOF
$fields
EOF
  case "$pid" in ''|*[!0-9]*)
    FM_FLEET_QUEUE_WHY="queue snapshot names no daemon"
    return 0
    ;;
  esac
  if [ "$boot" != "$(fm_fleet_boot_id 2>/dev/null || true)" ]; then
    FM_FLEET_QUEUE_WHY="queue daemon has not run in this boot"
    return 0
  fi
  stat_line=
  { IFS= read -r stat_line < "$(fm_fleet_proc_root)/$pid/stat"; } 2>/dev/null || true
  # After the final comm delimiter, array index 19 is proc stat field 22, the
  # process start time, which is what the daemon records about itself.
  read -r -a stat_fields <<< "${stat_line##*)}"
  if [ "${#stat_fields[@]}" -lt 20 ] || [ "${stat_fields[19]}" != "$start" ]; then
    FM_FLEET_QUEUE_WHY="queue daemon (pid $pid) is not running"
    return 0
  fi
  FM_FLEET_QUEUE=stale
  if [ "$schema" != jobqueue.status ] || [ "${version%%.*}" != 1 ]; then
    FM_FLEET_QUEUE_WHY="queue snapshot schema $schema $version is not one this command reads"
    return 0
  fi
  made=$(fm_utc_iso_to_epoch "$generated" 2>/dev/null) || made=
  fm_epoch_seconds_to now
  case "$made" in ''|*[!0-9]*)
    FM_FLEET_QUEUE_WHY="queue snapshot carries no readable time"
    return 0
    ;;
  esac
  age=$((now - made))
  if [ "$age" -gt "$FM_FLEET_QUEUE_FRESH_SECS" ] || [ "$age" -lt "-$FM_FLEET_QUEUE_FRESH_SECS" ]; then
    FM_FLEET_QUEUE_WHY="queue snapshot is ${age}s old although its daemon is running"
    return 0
  fi
  case "$paused" in
    true)
      FM_FLEET_QUEUE=paused
      [ "$reason" = - ] || FM_FLEET_QUEUE_PAUSE_REASON=$reason
      ;;
    false) FM_FLEET_QUEUE=running ;;
    *) FM_FLEET_QUEUE_WHY="queue snapshot does not say whether it is paused" ;;
  esac
  return 0
}

# Poll the snapshot until the queue is in one of the wanted states.
fm_fleet_queue_wait() {  # <seconds> <state>...
  local left=$1 want
  shift
  while :; do
    fm_fleet_queue_probe
    for want in "$@"; do
      [ "$FM_FLEET_QUEUE" != "$want" ] || return 0
    done
    [ "$left" -gt 0 ] || return 1
    left=$((left - 1))
    sleep 1
  done
}

# `systemd-run --user` and `systemctl --user` reach the user manager through
# these two variables, and a shell started outside a login session (an agent's
# tool shell, cron, an ssh command) often has neither.
fm_fleet_systemd_env() {
  local uid
  uid=$(id -u 2>/dev/null) || return 0
  [ -n "${XDG_RUNTIME_DIR:-}" ] || export XDG_RUNTIME_DIR="/run/user/$uid"
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
}

# Start the queue daemon and wait until it publishes. The queue is deliberately
# not started at boot (the captain declined that), so starting it is a step of
# resume and of host recovery.
fm_fleet_queue_start() {
  local bin out rc=0
  bin=$(fm_fleet_jobqueue_bin) || {
    fm_fleet_fail "queue: jobqueue is not installed (not on PATH and not at ~/.local/bin/jobqueue)"
    return 1
  }
  fm_fleet_systemd_env
  if fm_fleet_dry "$bin" daemon --start; then
    return 0
  fi
  out=$(fm_run_timed 60 "$bin" daemon --start 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    fm_fleet_fail "queue: the daemon did not start (jobqueue daemon --start exit $rc): $(fm_fleet_tail "$out"). If systemd reports that jobqueue-daemon.service already exists, clear it with 'systemctl --user reset-failed jobqueue-daemon.service' and run this again"
    return 1
  fi
  if ! fm_fleet_queue_wait 30 running paused; then
    fm_fleet_fail "queue: the daemon was started but published no fresh snapshot within 30 s (${FM_FLEET_QUEUE_WHY:-state $FM_FLEET_QUEUE})"
    return 1
  fi
  fm_fleet_note "queue: daemon started (jobqueue daemon --start)"
}

# Pause the queue and confirm it from the snapshot. `jobqueue pause` closes
# admission first and then cancels every active job; it exits 125 while some
# are still being killed, which is a pause that holds, so only the snapshot
# decides success here.
fm_fleet_queue_pause() {
  local bin out rc=0
  bin=$(fm_fleet_jobqueue_bin) || {
    fm_fleet_fail "queue: jobqueue is not installed (not on PATH and not at ~/.local/bin/jobqueue)"
    return 1
  }
  if fm_fleet_dry "$bin" pause; then
    return 0
  fi
  out=$(fm_run_timed 120 "$bin" pause 2>&1) || rc=$?
  if ! fm_fleet_queue_wait 15 paused; then
    fm_fleet_fail "queue: NOT paused (jobqueue pause exit $rc: $(fm_fleet_tail "$out"); ${FM_FLEET_QUEUE_WHY:-snapshot says $FM_FLEET_QUEUE})"
    return 1
  fi
  if [ "$rc" -ne 0 ]; then
    fm_fleet_note "queue: paused; jobqueue pause exit $rc: $(fm_fleet_tail "$out")"
  fi
  return 0
}

# The queue's live jobs as TAB-separated rows:
#   task id class exe state phase project submitted_at
# An absent value is `-`, never empty, because a shell read on TAB collapses
# empty fields.
fm_fleet_queue_live_rows() {
  jq -r '.jobs[]?
    | select(.state == "queued" or .state == "between_phases" or .state == "running" or .state == "stopping")
    | [ .task, .id, .class, .exe, .state, .phase, .project, .submitted_at ]
    | map(if . == null or . == "" then "-" else tostring end) | @tsv' "$(fm_fleet_queue_snapshot)" 2>/dev/null
}

# The jobs the daemon ended because the host or the daemon itself went away,
# in the same row shape with the result in the state column.
fm_fleet_queue_restart_rows() {  # [finished-at-or-after-epoch]
  jq -r --arg since "${1:-0}" '.jobs[]?
    | select(.state == "done" and (.reason == "daemon_restart" or .reason == "client_lost"))
    | select((.finished_at // 0) >= ($since | tonumber))
    | [ .task, .id, .class, .exe, ((.result // "ended") + "/" + .reason), .phase, .project, .submitted_at ]
    | map(if . == null or . == "" then "-" else tostring end) | @tsv' "$(fm_fleet_queue_snapshot)" 2>/dev/null
}

# The boot id of the daemon that wrote the snapshot, whatever its freshness.
fm_fleet_queue_snapshot_boot() {
  jq -r '.daemon.boot_id // empty' "$(fm_fleet_queue_snapshot)" 2>/dev/null
}

fm_fleet_jobs_file() {
  printf '%s/jobs.tsv' "$(fm_fleet_dir)"
}

# Record the live rows on stdin as the jobs this pause cuts. Rows an earlier
# attempt at the same pause already saved are kept: once the queue is paused
# nothing is live any more, so a later snapshot could only lose them.
# With `incomplete`, the list is marked as not covering every cut job: the
# queue was already paused when the pause began, so what that earlier pause
# cancelled was never seen here. The mark survives later merges.
fm_fleet_jobs_merge() {  # [incomplete]
  local file tmp incomplete=${1:-} rc=0
  file=$(fm_fleet_jobs_file)
  tmp="$file.merge.$$"
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  [ -z "$incomplete" ] && ! fm_fleet_jobs_incomplete || incomplete=incomplete
  {
    printf '# fleet-pause queue snapshot v1: jobs that were live when the pause began\n'
    printf '# columns: task id class exe state phase project submitted_at outcome\n'
    [ -z "$incomplete" ] || printf '# incomplete: the queue was already paused when this pause began\n'
    {
      if [ -f "$file" ]; then grep -v '^#' "$file"; fi
      cat "$tmp"
    } | awk -F '\t' -v OFS='\t' 'NF >= 8 && !seen[$2]++ { if (NF < 9 || $9 == "") $9 = "unknown"; print }'
  } | fm_fleet_write "$file" || rc=1
  rm -f "$tmp"
  return "$rc"
}

# 0 when the saved list is marked as not covering every job the pause cut.
fm_fleet_jobs_incomplete() {
  grep -q '^# incomplete' "$(fm_fleet_jobs_file)" 2>/dev/null
}

# Write what became of each saved job into its outcome column, from the
# snapshot the daemon published after the pause: `cancelled/paused` for a job
# the pause cut, `succeeded/-` for one that finished on its own first,
# `still-<state>` for one not yet ended, and `unknown` when the daemon no
# longer lists it (it keeps only its most recent finished jobs).
fm_fleet_jobs_annotate() {
  local file map
  file=$(fm_fleet_jobs_file)
  [ -f "$file" ] || return 0
  map="$file.map.$$"
  jq -r '.jobs[]? | [ .id, .state, .result, .reason ]
    | map(if . == null or . == "" then "-" else tostring end) | @tsv' "$(fm_fleet_queue_snapshot)" > "$map" 2>/dev/null || {
    rm -f "$map"
    return 1
  }
  awk -F '\t' -v OFS='\t' '
    FILENAME == ARGV[1] { state[$1] = $2; result[$1] = $3; reason[$1] = $4; next }
    /^#/ { print; next }
    {
      if ($2 in state) {
        if (state[$2] == "done") $9 = result[$2] "/" reason[$2]
        else $9 = "still-" state[$2]
      }
      print
    }' "$map" "$file" | fm_fleet_write "$file"
  rm -f "$map"
}

# The saved rows of one task, leaving out a job that finished on its own.
fm_fleet_jobs_for() {  # <task>
  local file
  file=$(fm_fleet_jobs_file)
  [ -f "$file" ] || return 0
  awk -F '\t' -v task="$1" '!/^#/ && $1 == task && $9 !~ /^succeeded\// { print }' "$file"
}

# One line per job for a worker: short id, class, phase, what ran, how it ended.
fm_fleet_jobs_describe() {  # stdin: rows in the jobs.tsv shape
  local task id class exe state phase project submitted outcome line
  while IFS=$(printf '\t') read -r task id class exe state phase project submitted outcome; do
    [ -n "$id" ] || continue
    line="- ${id%%-*} (jobqueue show $id): class $class"
    [ "$phase" = - ] || line="$line, phase $phase"
    [ "$exe" = - ] || line="$line, ran $exe"
    line="$line, was $state"
    case "${outcome:-unknown}" in
      cancelled/paused|unknown|'') ;;
      *) line="$line, ended $outcome" ;;
    esac
    [ "$phase" != test ] || line="$line - cut during a test phase: ask before re-running it"
    printf '%s\n' "$line"
  done
}

# --- this home's direct reports ---------------------------------------------

# One "<kind><TAB><id>" line per recorded direct report, in name order. Only
# this home's own records are read; a second mate's crew lives in its own home.
fm_fleet_tasks() {
  local meta id kind
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}
    id=${id%.meta}
    case "$id" in ''|.*|*[!A-Za-z0-9._-]*) continue ;; esac
    kind=$(fm_meta_get "$meta" kind)
    printf '%s\t%s\n' "${kind:-ship}" "$id"
  done
}

# --- the wait mark ----------------------------------------------------------

fm_fleet_wait_line() {  # <reason> -> the status line that declares the wait
  local until
  until=$(fm_fleet_utc_minute "$(($(date +%s) + FM_FLEET_PAUSE_HOLD_SECS))")
  printf 'paused [key=%s]: fleet pause (%s): stay idle and wait for the resume message - until %s' \
    "$FM_FLEET_PAUSE_KEY" "$1" "$until"
}

# 0 when the watcher currently reads the task as waiting on this pause: the
# mark is its standing declared wait and its clearing time is still ahead.
fm_fleet_wait_standing() {  # <status-file>
  local line until
  line=$(status_declared_wait_line "$1")
  status_is_paused "$line" || return 1
  [ "$(_fm_decision_key "$line" 2>/dev/null || true)" = "$FM_FLEET_PAUSE_KEY" ] || return 1
  until=$(status_paused_until "$line") || return 1
  [ "$(date +%s)" -lt "$until" ]
}

# 0 while the pause's mark is still open in the task's status log, whatever
# the worker has appended since. This is what "the pause marked this task and
# nobody has resumed it" means.
fm_fleet_wait_open() {  # <status-file>
  local key verb note
  while IFS=$(printf '\t') read -r key verb note; do
    if [ "$key" = "$FM_FLEET_PAUSE_KEY" ] && [ "$verb" = "${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}" ]; then
      return 0
    fi
  done <<EOF
$(status_open_activities "$1")
EOF
  return 1
}

# Print the newest status verb and return 0 when that event already tells the
# watcher the task is finished or owed an answer by a person: done, failed,
# needs-decision, blocked, a verified captain-held transfer. The watcher reads
# exactly that newest event to keep such a pane quiet, so a wait mark appended
# after it would replace a settled reading with a weaker one and a resume would
# have to spend a worker turn to restore it.
fm_fleet_status_settled() {  # <status-file>
  local last
  last=$(last_status_line "$1")
  [ -n "$last" ] || return 1
  if status_is_captain_held "$last" || status_is_captain_relevant "$last"; then
    status_line_verb "$last"
    return 0
  fi
  return 1
}

# Append one line to a task's status log through the guarded self-announced
# writer, so the watcher does not wake the supervisor about this home's own
# bookkeeping. Returns nonzero only when nothing was appended.
fm_fleet_status_append() {  # <task> <line>
  local rc=0
  if [ "$FM_FLEET_DRY_RUN" = 1 ]; then
    printf 'would append to state/%s.status: %s\n' "$1" "$2"
    return 0
  fi
  fm_wake_status_append_self_announced "$STATE" "$STATE/$1.status" "$2" || rc=$?
  [ "$rc" -ne 2 ]
}

# --- fleet-launch evidence --------------------------------------------------

FM_FLEET_PROC_SCAN=unavailable
FM_FLEET_PROC_TABLE=

# Read every process's launch marker once. Sets FM_FLEET_PROC_SCAN to `ok` or
# `unavailable` (no Linux /proc), and FM_FLEET_PROC_TABLE to one row per AGENT
# process that carries a marker: pid, FM_TASK_ID, FM_TASK_INBOX, working
# directory, each `-` when absent. A marker is inherited by everything an agent
# starts, so only a process the shared harness classifier calls an agent counts.
# An environment can hold credentials: it is read into memory to pick out the
# two marker values and nothing else of it is ever printed or stored.
fm_fleet_proc_scan() {
  local root file dir pid comm argv0 args count entry id inbox cwd pid_arg
  FM_FLEET_PROC_SCAN=unavailable
  FM_FLEET_PROC_TABLE=
  root=$(fm_fleet_proc_root)
  [ -r "$root/sys/kernel/random/boot_id" ] || return 0
  FM_FLEET_PROC_SCAN=ok
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    dir=${file%/environ}
    pid=${dir##*/}
    comm=
    argv0=
    args=
    count=0
    # A process can end between the listing and these reads; that is a row to
    # skip, not an error to print. The harness classifier reads the command
    # line only as far as an interpreter, its flags, and the script it runs,
    # so the leading arguments are enough; the read also stops at the first
    # empty one, because a harness that rewrites its process title in place
    # (Pi) leaves thousands of them behind the name.
    { IFS= read -r comm < "$dir/comm"; } 2>/dev/null || true
    while [ "$count" -lt 16 ] && IFS= read -r -d '' entry; do
      [ -n "$entry" ] || break
      [ "$count" -gt 0 ] || argv0=$entry
      args="$args${args:+ }$entry"
      count=$((count + 1))
    done 2>/dev/null < "$dir/cmdline" || true
    # The harness classifier's Gemini rule reads the live process by pid; under
    # a substituted process root that pid names nothing real.
    pid_arg=$pid
    [ -z "${FM_PROC_ROOT_OVERRIDE:-}" ] || pid_arg=
    [ "$(fm_agent_process_classify "$comm" "$argv0" "$args" "$pid_arg")" = agent ] || continue
    args=
    id=
    inbox=
    while IFS= read -r -d '' entry; do
      case "$entry" in
        FM_TASK_ID=*) [ -n "$id" ] || id=${entry#FM_TASK_ID=} ;;
        FM_TASK_INBOX=*) [ -n "$inbox" ] || inbox=${entry#FM_TASK_INBOX=} ;;
      esac
    done 2>/dev/null < "$file" || true
    entry=
    cwd=$(readlink "$dir/cwd" 2>/dev/null) || cwd=
    FM_FLEET_PROC_TABLE="$FM_FLEET_PROC_TABLE$pid$FM_FLEET_US${id:--}$FM_FLEET_US${inbox:--}$FM_FLEET_US${cwd:--}
"
  done <<EOF
$(LC_ALL=C grep -lsaz -E '^FM_TASK_(ID|INBOX)=' "$root"/[0-9]*/environ 2>/dev/null || true)
EOF
  return 0
}

# What the scan says about one task. Prints one of:
#   ok            an agent process carries the task's marker and sits in (or
#                 below) the recorded worktree
#   cwd:<path>    such a process exists, but in another directory
#   absent        no agent process carries the task's marker
#   unknown       the scan was unavailable, or the task records no worktree to
#                 compare a working directory with
# A ship or scout is matched on FM_TASK_ID, and on FM_TASK_INBOX too when the
# process has one, since that path names this home and two homes can reuse an
# id. A second mate is matched on FM_TASK_INBOX alone.
fm_fleet_proc_evidence() {  # <id> <kind> <worktree>
  local id=$1 kind=$2 wt=$3 state_real inbox wt_real pid tid tinbox cwd other=''
  if [ "$FM_FLEET_PROC_SCAN" != ok ] || [ -z "$wt" ]; then
    printf 'unknown'
    return 0
  fi
  state_real=$(cd "$STATE" 2>/dev/null && pwd -P) || state_real=$STATE
  inbox="$state_real/$id.inbox"
  wt_real=$(cd "$wt" 2>/dev/null && pwd -P) || wt_real=$wt
  while IFS=$FM_FLEET_US read -r pid tid tinbox cwd; do
    [ -n "$pid" ] || continue
    if [ "$kind" = secondmate ]; then
      [ "$tinbox" = "$inbox" ] || continue
    else
      [ "$tid" = "$id" ] || continue
      [ "$tinbox" = - ] || [ "$tinbox" = "$inbox" ] || continue
    fi
    case "$cwd/" in
      "$wt_real/"*)
        printf 'ok'
        return 0
        ;;
    esac
    other=$cwd
  done <<EOF
$FM_FLEET_PROC_TABLE
EOF
  if [ -n "$other" ]; then
    printf 'cwd:%s' "$other"
  else
    printf 'absent'
  fi
}

# Whether the task's busy generation was minted in this boot. Prints `ok`,
# `stale` (older than the boot), `none` (this harness arms no generation), or
# `unknown` (the boot time cannot be bounded). A generation token is
# g<epoch>.<pid>.<random> (bin/fm-busy-event.sh).
fm_fleet_gen_evidence() {  # <id>
  local gen minted boot
  gen=$(fm_busy_current_gen "$STATE" "$1" 2>/dev/null) || {
    printf 'none'
    return 0
  }
  minted=${gen#g}
  minted=${minted%%.*}
  case "$minted" in ''|*[!0-9]*)
    printf 'unknown'
    return 0
    ;;
  esac
  boot=$(fm_fleet_boot_epoch_bound) || {
    printf 'unknown'
    return 0
  }
  if [ "$minted" -lt "$boot" ]; then
    printf 'stale'
  else
    printf 'ok'
  fi
}

# Classify one local direct report's endpoint. Sets:
#   FM_FLEET_ENDPOINT  the recovery-grade endpoint state (fm_backend_agent_state)
#   FM_FLEET_CLASS     healthy       a fleet-launched agent is running
#                      dead          no agent is running in the endpoint
#                      not-launched  an agent is running that the fleet did not
#                                    launch (the header's three facts)
#                      unknown       the readings do not settle it; nothing may
#                                    be relaunched or steered on a guess
#   FM_FLEET_WHY       one phrase saying which reading decided it
#   FM_FLEET_UNSURE    what could not be determined, or empty
fm_fleet_classify() {  # <id>
  local id=$1 meta="$STATE/$1.meta" kind wt backend target proc gen marker
  FM_FLEET_ENDPOINT=unreadable
  FM_FLEET_CLASS=unknown
  FM_FLEET_WHY=
  FM_FLEET_UNSURE=
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  wt=$(fm_meta_get "$meta" worktree)
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  marker=FM_TASK_ID
  [ "$kind" != secondmate ] || marker=FM_TASK_INBOX
  if [ -z "$target" ]; then
    FM_FLEET_ENDPOINT=none
    FM_FLEET_WHY="no endpoint is recorded for it"
    return 0
  fi
  # Load the adapter here, in the calling shell, so the read below does not
  # source it again inside its command substitution for every task.
  fm_backend_source "$backend" >/dev/null 2>&1 || true
  FM_FLEET_ENDPOINT=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) || FM_FLEET_ENDPOINT=unreadable
  [ -n "$FM_FLEET_ENDPOINT" ] || FM_FLEET_ENDPOINT=unreadable
  proc=$(fm_fleet_proc_evidence "$id" "$kind" "$wt")
  gen=$(fm_fleet_gen_evidence "$id")
  [ "$proc" != unknown ] || FM_FLEET_UNSURE="its agent's environment and working directory could not be read"
  case "$FM_FLEET_ENDPOINT" in
    dead|missing)
      if [ "$proc" = ok ]; then
        FM_FLEET_WHY="the endpoint reads $FM_FLEET_ENDPOINT, yet an agent process carrying $marker for it is running in its worktree"
      else
        FM_FLEET_CLASS=dead
        FM_FLEET_WHY="no agent is running in its endpoint ($FM_FLEET_ENDPOINT)"
      fi
      ;;
    alive)
      case "$proc" in
        absent)
          FM_FLEET_CLASS=not-launched
          FM_FLEET_WHY="no agent process carries $marker for it"
          ;;
        cwd:*)
          FM_FLEET_CLASS=not-launched
          FM_FLEET_WHY="its agent runs in ${proc#cwd:}, not the recorded worktree"
          ;;
        *)
          if [ "$gen" = stale ]; then
            FM_FLEET_CLASS=not-launched
            FM_FLEET_WHY="its busy generation is older than this boot"
          else
            FM_FLEET_CLASS=healthy
            FM_FLEET_WHY="agent running"
          fi
          ;;
      esac
      ;;
    *)
      if [ "$proc" = ok ] && [ "$gen" != stale ]; then
        FM_FLEET_CLASS=healthy
        FM_FLEET_WHY="agent process running in its worktree (the endpoint itself reads $FM_FLEET_ENDPOINT)"
      else
        FM_FLEET_WHY="its endpoint reads $FM_FLEET_ENDPOINT, which neither proves an agent nor its absence"
      fi
      ;;
  esac
  return 0
}
