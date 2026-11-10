#!/usr/bin/env bash
# tests/fleet-pause-helpers.sh - the fake world shared by the fleet pause,
# resume, and host-recovery suites.
#
# Source this after tests/lib.sh and call fp_init once:
#   # shellcheck source=tests/fleet-pause-helpers.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/fleet-pause-helpers.sh"
#   fp_init fm-fleet-pause
#
# The three commands under test compose things a test must never reach for
# real: the job queue, the terminal backend, systemd, the kernel's process and
# cgroup trees, and the lifecycle and steering scripts. fp_init builds, once
# per suite, the code the commands run:
#
#   $FP_SHARED/bin/      every real bin/ entry symlinked, with fm-control.sh,
#                        fm-send.sh, fm-captain-hold.sh and fm-crew-state.sh
#                        replaced by recording stubs, so the commands under
#                        test run unmodified and find their siblings the way
#                        they do in a home
#   $FP_SHARED/fakebin/  jobqueue, tmux, systemctl, sleep, herdr (which must
#                        never run)
#
# and fp_case builds one directory per case holding everything they act on:
#
#   home/     the temp firstmate home: state/, config/, data/
#   queue/    the fake queue's state directory; status.json is its snapshot
#   proc/     a substitute /proc: the boot id, btime, the queue daemon's stat,
#             and one directory per fake agent process
#   cgroup/   a substitute cgroup root with the user service memory files
#   panes/    one file per terminal window; its content is the foreground
#             command, which is what the tmux endpoint classifier reads
#   timers/   one file per active systemd user unit
#   wt/       one worktree directory per task
#   knob/     files a case creates to make a fake fail or behave differently
#   log/      what the stubs and fakes were asked to do
#
# fp_run is the only way a case runs a command: it pins every path above
# through the environment the commands already honour, so nothing in a case can
# fall through to the host's real queue, cgroup, or process tree. The stubs and
# fakes find their case through FP_DIR, which fp_run sets.

FP_DAEMON_PID=4242
FP_DAEMON_START=777
FP_ROOT=
FP_SHARED=
FP_UID=
FP_MARK_UNTIL=

fp_now() {
  date +%s
}

fp_mtime() {  # <path>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# fp_init <prefix>: make the suite's temp root and its shared bin and fakebin.
fp_init() {
  local now
  FP_ROOT=$(fm_test_tmproot "$1") || fail "fp_init: no temp root"
  FP_SHARED="$FP_ROOT/shared"
  FP_UID=$(id -u)
  now=$(fp_now)
  FP_MARK_UNTIL=$(date -u -d "@$((now + 43200))" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$((now + 43200))" +%Y-%m-%dT%H:%MZ)
  mkdir -p "$FP_SHARED/bin" "$FP_SHARED/fakebin"
  # One ln for the whole directory: a fork per entry would dominate the suite.
  ln -s "$ROOT"/bin/* "$FP_SHARED/bin/"
  fp_write_stubs "$FP_SHARED"
  fp_write_fakebin "$FP_SHARED"
}

# fp_case <name>: build one case's world and echo its directory. The host
# booted an hour ago as boot-A, no queue snapshot exists, and no timer is
# active.
fp_case() {
  local dir="$FP_ROOT/$1" service
  service="$dir/cgroup/user.slice/user-$FP_UID.slice/user@$FP_UID.service"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/queue" \
    "$dir/proc/sys/kernel/random" "$dir/panes" "$dir/timers" "$dir/knob" "$dir/log" \
    "$dir/userhome" "$dir/wt" "$service"
  fp_boot "$dir" boot-A "$(($(fp_now) - 3600))"
  : > "$service/memory.reclaim"
  printf 'anon 1048576\nfile 209715200\n' > "$service/memory.stat"
  printf '%s\n' "$dir"
}

fp_reclaim_file() {  # <dir>
  printf '%s/cgroup/user.slice/user-%s.slice/user@%s.service/memory.reclaim' "$1" "$FP_UID" "$FP_UID"
}

# fp_boot <dir> <boot-id> [boot-epoch]: make the substitute host be this boot.
fp_boot() {
  local dir=$1 id=$2 epoch=${3:-}
  printf '%s\n' "$id" > "$dir/proc/sys/kernel/random/boot_id"
  [ -z "$epoch" ] || printf 'cpu  1 2 3\nbtime %s\n' "$epoch" > "$dir/proc/stat"
}

fp_write_stubs() {  # <shared-dir>
  local dir=$1
  rm -f "$dir/bin/fm-control.sh" "$dir/bin/fm-send.sh" "$dir/bin/fm-captain-hold.sh" "$dir/bin/fm-crew-state.sh"
  # The control plane: records the verb, keeps the note it was handed, and
  # models what a real relaunch leaves - the old agent gone, a new one in the
  # recorded worktree carrying the launch marker, and a fresh busy generation.
  cat > "$dir/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
set -u
D=$FP_DIR
id=${1:-}
verb=${2:-}
printf '%s %s\n' "$id" "$verb" >> "$D/log/control"
[ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is not set" >&2; exit 1; }
case "$verb" in
  interrupt)
    if [ -e "$D/knob/interrupt-noagent-$id" ]; then
      echo "error: no agent is running at task $id's recorded endpoint (state: dead); there is nothing to interrupt" >&2
      exit 1
    fi
    if [ -e "$D/knob/interrupt-fails-$id" ]; then
      echo "error: interrupt key Escape was not delivered to task $id on tmux" >&2
      exit 1
    fi
    echo "interrupt-delivered $id harness=pi backend=tmux verified=agent-alive cancel=unconfirmed"
    ;;
  relaunch)
    shift 2
    note=
    while [ $# -gt 0 ]; do
      case "$1" in
        --note-file) note=${2:-}; shift 2 ;;
        *) shift ;;
      esac
    done
    if [ -n "$note" ]; then cp "$note" "$D/log/note-$id"; fi
    if [ -e "$D/knob/relaunch-fails-$id" ]; then
      echo "error: the replacement agent for $id could not be launched on pi" >&2
      exit 1
    fi
    meta="$FM_HOME/state/$id.meta"
    worktree=
    kind=
    while IFS= read -r line; do
      case "$line" in
        worktree=*) worktree=${line#worktree=} ;;
        kind=*) kind=${line#kind=} ;;
      esac
    done < "$meta"
    inbox="$FM_HOME/state/$id.inbox"
    for old in "$D"/proc/[0-9]*; do
      [ -f "$old/environ" ] || continue
      if grep -qaz -e "^FM_TASK_ID=$id\$" -e "^FM_TASK_INBOX=$inbox\$" "$old/environ"; then
        rm -rf "$old"
      fi
    done
    pid=$((9000 + $(wc -l < "$D/log/control")))
    mkdir -p "$D/proc/$pid"
    printf 'pi\n' > "$D/proc/$pid/comm"
    printf 'pi\0' > "$D/proc/$pid/cmdline"
    ln -s "$worktree" "$D/proc/$pid/cwd"
    if [ "$kind" = secondmate ]; then
      printf 'FM_TASK_INBOX=%s\0' "$inbox" > "$D/proc/$pid/environ"
    else
      printf 'FM_TASK_ID=%s\0FM_TASK_INBOX=%s\0' "$id" "$inbox" > "$D/proc/$pid/environ"
    fi
    now=$(date +%s)
    printf 'g%s.1.1\n' "$now" > "$FM_HOME/state/$id.busy-gen"
    printf 'v1 gen=g%s.1.1 seq=1 state=busy source=fm-spawn event=launch-brief ts=%s\n' "$now" "$now" > "$FM_HOME/state/$id.busy-state"
    printf 'pi' > "$D/panes/fm-$id"
    echo "relaunched $id harness=pi"
    ;;
  *) exit 2 ;;
esac
SH
  # The data plane: records who was steered, with what, and whether the pause
  # record still existed at that moment.
  cat > "$dir/bin/fm-send.sh" <<'SH'
#!/usr/bin/env bash
set -u
D=$FP_DIR
id=${1:-}
shift
[ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is not set" >&2; exit 1; }
printf '%s\n' "$id" >> "$D/log/send"
if [ -e "$FM_HOME/state/captain-pause.flag" ]; then
  printf '%s record-present\n' "$id" >> "$D/log/send-order"
else
  printf '%s record-gone\n' "$id" >> "$D/log/send-order"
fi
if [ -e "$D/knob/send-fails-$id" ]; then
  echo "error: task $id's live context is past the crew context limit; end the session and respawn it" >&2
  exit 1
fi
printf '%s\n' "$*" > "$D/log/sent-$id"
SH
  # Asked once per marked worker, so it is plain sh: the lighter interpreter is
  # most of what such a stub costs. The same goes for the fake tmux and sleep.
  cat > "$dir/bin/fm-captain-hold.sh" <<'SH'
#!/bin/sh
D=$FP_DIR
[ "${1:-}" = open ] || exit 2
[ ! -e "$D/knob/hold-unreadable-${2:-}" ] || exit 2
[ -e "$D/knob/held-${2:-}" ] && exit 0
exit 1
SH
  cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
D=$FP_DIR
printf '%s\n' "${1:-}" >> "$D/log/crew-state"
printf 'state: unknown · source: remote-endpoint · alive on vps (an idle secondmate is healthy)\n'
SH
  chmod +x "$dir/bin/fm-control.sh" "$dir/bin/fm-send.sh" "$dir/bin/fm-captain-hold.sh" "$dir/bin/fm-crew-state.sh"
}

fp_write_fakebin() {  # <shared-dir>
  local dir=$1
  # The queue: one JSON snapshot, rewritten the way the daemon would for each
  # verb. `pause` also records whether the pause record existed when it ran.
  cat > "$dir/fakebin/jobqueue" <<'SH'
#!/usr/bin/env bash
set -u
D=$FP_DIR
snap="$D/queue/status.json"
printf '%s\n' "$*" >> "$D/log/jobqueue"
publish() {  # <jq filter>
  jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "($1) | .generated_at = \$now" "$snap" > "$snap.tmp" \
    && mv "$snap.tmp" "$snap"
}
case "${1:-}" in
  pause)
    if [ -e "$D/home/state/captain-pause.flag" ]; then
      echo "pause: record present" >> "$D/log/order"
    else
      echo "pause: record ABSENT" >> "$D/log/order"
    fi
    if [ -e "$D/knob/pause-fails" ]; then
      echo "jobqueue: [Errno 111] Connection refused" >&2
      exit 125
    fi
    publish '.paused = true | .pause_reason = "paused"
      | .jobs |= map(if (.state == "queued" or .state == "between_phases" or .state == "running" or .state == "stopping")
          then (.state = "done" | .result = "cancelled" | .reason = "paused" | .exit_code = 130) else . end)'
    ;;
  resume)
    if [ -e "$D/knob/resume-fails" ]; then
      echo "jobqueue: outside pressure: insufficient available memory to resume" >&2
      exit 2
    fi
    [ -e "$D/knob/resume-noop" ] || publish '.paused = false | .pause_reason = null'
    ;;
  daemon)
    [ "${2:-}" = --start ] || exit 2
    printf 'XDG_RUNTIME_DIR=%s DBUS_SESSION_BUS_ADDRESS=%s\n' "${XDG_RUNTIME_DIR:-unset}" "${DBUS_SESSION_BUS_ADDRESS:-unset}" >> "$D/log/daemon-env"
    if [ -e "$D/knob/start-fails" ]; then
      echo "Failed to start transient service unit: Unit jobqueue-daemon.service was already loaded" >&2
      exit 1
    fi
    paused=false
    reason=null
    if [ -e "$D/knob/starts-paused" ]; then
      paused=true
      reason='"daemon_restart"'
    fi
    [ -s "$snap" ] || printf '{"jobs":[]}\n' > "$snap"
    mkdir -p "$D/proc/$FP_DAEMON_PID"
    printf '%s (jobqueue) S 1 %s %s 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' \
      "$FP_DAEMON_PID" "$FP_DAEMON_PID" "$FP_DAEMON_PID" "$FP_DAEMON_START" > "$D/proc/$FP_DAEMON_PID/stat"
    jq --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg boot "$(cat "$D/proc/sys/kernel/random/boot_id")" \
      --argjson pid "$FP_DAEMON_PID" --arg start "$FP_DAEMON_START" --argjson paused "$paused" --argjson reason "$reason" \
      --argjson at "$(date +%s)" '
      {schema: "jobqueue.status", version: 1, schema_version: "1.1", generated_at: $now, stale: false,
       daemon: {pid: $pid, start_time: $start, boot_id: $boot}, paused: $paused, pause_reason: $reason,
       jobs: ((.jobs // []) | map(if (.state == "queued" or .state == "between_phases" or .state == "running" or .state == "stopping")
          then (.state = "done" | .result = "interrupted" | .reason = "daemon_restart" | .exit_code = 125 | .finished_at = $at) else . end))}' \
      "$snap" > "$snap.tmp" && mv "$snap.tmp" "$snap"
    ;;
  status) cat "$snap" ;;
  *) exit 2 ;;
esac
exit 0
SH
  # tmux: every file under panes/ is a window of the one session, and its
  # content is the pane's foreground command. The endpoint classifier asks it
  # several questions per task.
  cat > "$dir/fakebin/tmux" <<'SH'
#!/bin/sh
set -u
D=$FP_DIR
case "${1:-}" in
  list-windows)
    for pane in "$D"/panes/*; do
      [ -e "$pane" ] || continue
      printf '%s\n' "${pane##*/}"
    done
    exit 0
    ;;
  display-message)
    shift
    target=
    format=
    while [ $# -gt 0 ]; do
      case "$1" in
        -p) shift ;;
        -t) target=${2:-}; shift 2 ;;
        *) format=$1; shift ;;
      esac
    done
    case "$format" in
      *pane_current_command*)
        command=
        { IFS= read -r command < "$D/panes/${target#*:}"; } 2>/dev/null || true
        printf '%s\n' "$command"
        ;;
      *) printf '\n' ;;
    esac
    exit 0
    ;;
esac
exit 0
SH
  cat > "$dir/fakebin/systemctl" <<'SH'
#!/usr/bin/env bash
set -u
D=$FP_DIR
printf '%s\n' "$*" >> "$D/log/systemctl"
printf 'XDG_RUNTIME_DIR=%s DBUS_SESSION_BUS_ADDRESS=%s\n' "${XDG_RUNTIME_DIR:-unset}" "${DBUS_SESSION_BUS_ADDRESS:-unset}" >> "$D/log/systemctl-env"
[ "${1:-}" != --user ] || shift
case "${1:-}" in
  is-active)
    if [ -e "$D/timers/${2:-}" ]; then echo active; exit 0; fi
    echo inactive
    exit 3
    ;;
  stop)
    [ ! -e "$D/knob/timer-stop-fails" ] || { echo "Failed to stop ${2:-}" >&2; exit 1; }
    rm -f "$D/timers/${2:-}"
    ;;
  start)
    [ ! -e "$D/knob/timer-start-fails" ] || { echo "Failed to start ${2:-}" >&2; exit 1; }
    : > "$D/timers/${2:-}"
    ;;
esac
exit 0
SH
  cat > "$dir/fakebin/sleep" <<'SH'
#!/bin/sh
printf '%s\n' "${1:-}" >> "$FP_DIR/log/sleep"
exit 0
SH
  # Every fixture task is on the tmux backend, so herdr must never be asked.
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FP_DIR/log/herdr"
exit 1
SH
  chmod +x "$dir/fakebin/jobqueue" "$dir/fakebin/tmux" "$dir/fakebin/systemctl" "$dir/fakebin/sleep" "$dir/fakebin/herdr"
}

# fp_run <dir> <script> [args...]: run one command under test against the
# world. Prints its combined output and returns its exit status.
fp_run() {
  local dir=$1 script=$2
  shift 2
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    -u XDG_STATE_HOME -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS -u FM_FLEET_PAUSE_HOLD_SECS \
    PATH="$FP_SHARED/fakebin:$PATH" FP_DIR="$dir" FP_DAEMON_PID="$FP_DAEMON_PID" FP_DAEMON_START="$FP_DAEMON_START" \
    FM_HOME="$dir/home" HOME="$dir/userhome" JOBQUEUE_STATE="$dir/queue" \
    FM_PROC_ROOT_OVERRIDE="$dir/proc" FM_FLEET_PAUSE_CGROUP_ROOT="$dir/cgroup" \
    WSL_DISTRO_NAME="${FP_WSL_DISTRO-Ubuntu}" \
    "$FP_SHARED/bin/$script" "$@" 2>&1
}

# fp_add_task <dir> <id> [kind] [harness]: record a direct report on the tmux
# backend with its own worktree directory and instructions. No endpoint, agent
# process, busy record, or status exists until a case adds them.
fp_add_task() {
  local dir=$1 id=$2 kind=${3:-ship} harness=${4:-pi}
  mkdir -p "$dir/wt/$id" "$dir/home/data/$id"
  printf '# brief for %s\n' "$id" > "$dir/home/data/$id/brief.md"
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=fmses:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$dir/wt/$id" \
    "project=$dir/wt" \
    "harness=$harness" \
    "kind=$kind" \
    "mode=local-only"
  if [ "$kind" = secondmate ]; then
    printf 'home=%s\n' "$dir/wt/$id" >> "$dir/home/state/$id.meta"
  fi
}

# fp_endpoint <dir> <id> <alive|dead|ambiguous|missing>
fp_endpoint() {
  case "$3" in
    alive) printf 'pi' > "$1/panes/fm-$2" ;;
    dead) printf 'bash' > "$1/panes/fm-$2" ;;
    ambiguous) printf 'vim' > "$1/panes/fm-$2" ;;
    missing) rm -f "$1/panes/fm-$2" ;;
  esac
}

# fp_agent_proc <dir> <pid> <id> [cwd] [marker]: a running agent process for
# <id>. marker `id` (the default) gives it FM_TASK_ID and FM_TASK_INBOX the way
# a ship or scout launch does; `inbox` gives it FM_TASK_INBOX alone, the way a
# second mate launch does; `none` gives it neither, which is what a pane
# restored by the terminal backend runs. The environment also holds a value
# that must never surface in any output.
fp_agent_proc() {
  local dir=$1 pid=$2 id=$3 cwd=${4:-} marker=${5:-id}
  [ -n "$cwd" ] || cwd="$dir/wt/$id"
  mkdir -p "$dir/proc/$pid"
  printf 'pi\n' > "$dir/proc/$pid/comm"
  printf 'pi\0' > "$dir/proc/$pid/cmdline"
  ln -sfn "$cwd" "$dir/proc/$pid/cwd"
  case "$marker" in
    id) printf 'HOME=/h\0FM_TASK_ID=%s\0FM_TASK_INBOX=%s\0SECRET_TOKEN=do-not-print\0' "$id" "$dir/home/state/$id.inbox" > "$dir/proc/$pid/environ" ;;
    inbox) printf 'HOME=/h\0FM_TASK_INBOX=%s\0SECRET_TOKEN=do-not-print\0' "$dir/home/state/$id.inbox" > "$dir/proc/$pid/environ" ;;
    none) printf 'HOME=/h\0SECRET_TOKEN=do-not-print\0' > "$dir/proc/$pid/environ" ;;
  esac
}

# fp_busy <dir> <id> <busy|idle> [gen-epoch] [seq]: arm the task's busy record
# the way bin/fm-busy-event.sh writes it.
fp_busy() {
  local dir=$1 id=$2 state=$3 epoch=${4:-} seq=${5:-2} gen now
  now=$(fp_now)
  [ -n "$epoch" ] || epoch=$((now - 60))
  gen="g$epoch.123.456"
  printf '%s\n' "$gen" > "$dir/home/state/$id.busy-gen"
  printf 'v1 gen=%s seq=%s state=%s source=pi-ext event=test ts=%s\n' "$gen" "$seq" "$state" "$now" \
    > "$dir/home/state/$id.busy-state"
}

fp_status() {  # <dir> <id> <line>...
  local dir=$1 id=$2 line
  shift 2
  for line in "$@"; do
    printf '%s\n' "$line" >> "$dir/home/state/$id.status"
  done
}

# fp_healthy_task <dir> <id> <pid>: a ship with a live, fleet-launched, idle
# agent - what every worker looks like in an undisturbed fleet.
fp_healthy_task() {
  fp_add_task "$1" "$2"
  fp_endpoint "$1" "$2" alive
  fp_agent_proc "$1" "$3" "$2"
  fp_busy "$1" "$2" idle
}

# fp_queue <dir> <running|paused> [job-json...]: publish a fresh snapshot from
# a daemon that is alive in the current boot. Each job is a JSON object; fp_job
# builds one.
fp_queue() {
  local dir=$1 mode=$2 jobs='' job paused=false reason=null boot
  shift 2
  for job in "$@"; do
    jobs="$jobs${jobs:+,}$job"
  done
  if [ "$mode" = paused ]; then
    paused=true
    reason='"paused"'
  fi
  IFS= read -r boot < "$dir/proc/sys/kernel/random/boot_id"
  mkdir -p "$dir/proc/$FP_DAEMON_PID"
  printf '%s (jobqueue) S 1 %s %s 0 -1 4194304 0 0 0 0 0 0 0 0 20 0 1 0 %s 0 0\n' \
    "$FP_DAEMON_PID" "$FP_DAEMON_PID" "$FP_DAEMON_PID" "$FP_DAEMON_START" > "$dir/proc/$FP_DAEMON_PID/stat"
  printf '{"schema":"jobqueue.status","version":1,"schema_version":"1.1","generated_at":"%s","stale":false,"daemon":{"pid":%s,"start_time":"%s","boot_id":"%s"},"paused":%s,"pause_reason":%s,"jobs":[%s]}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$FP_DAEMON_PID" "$FP_DAEMON_START" "$boot" "$paused" "$reason" "$jobs" \
    > "$dir/queue/status.json"
}

# fp_job <id> <task> <class> <state> [phase] [exe]: one live job as JSON. Ids,
# task names, and classes in the suites are plain words, so no escaping is
# needed.
fp_job() {
  local task=null phase=null
  [ -z "$2" ] || task="\"$2\""
  [ -z "${5:-}" ] || phase="\"$5\""
  printf '{"id":"%s","task":%s,"class":"%s","state":"%s","phase":%s,"exe":"%s","project":null,"submitted_at":%s,"result":null,"reason":null,"exit_code":null}' \
    "$1" "$task" "$3" "$4" "$phase" "${6:-bash}" "$(fp_now)"
}

# fp_queue_gone <dir>: the daemon of the snapshot is no longer running (its
# process entry is removed), as after a crash or a host restart.
fp_queue_gone() {
  rm -rf "$1/proc/$FP_DAEMON_PID"
}

# fp_paused <dir> <id>...: put the home in the state a pause leaves, without
# running one: the pause record and its detail file bound to the current boot,
# a complete (empty) job list, a paused queue, and the wait mark on each named
# task. fp_cut_job and fp_interrupted add what the pause cut and interrupted.
fp_paused() {
  local dir=$1 id boot
  shift
  IFS= read -r boot < "$dir/proc/sys/kernel/random/boot_id"
  mkdir -p "$dir/home/state/fleet-pause"
  printf 'fleet pause: games 2026-11-10T05:47Z\n' > "$dir/home/state/captain-pause.flag"
  printf 'v=1\npaused_at=%s\nboot_id=%s\nreason=games\n' "$(fp_now)" "$boot" > "$dir/home/state/fleet-pause/pause"
  printf '# fleet-pause queue snapshot v1: jobs that were live when the pause began\n# columns: task id class exe state phase project submitted_at outcome\n' \
    > "$dir/home/state/fleet-pause/jobs.tsv"
  fp_queue "$dir" paused
  for id in "$@"; do
    fp_mark "$dir" "$id"
  done
}

fp_mark() {  # <dir> <id>: append the pause's wait mark to a task's status log
  fp_status "$1" "$2" "paused [key=fleet-pause] [at=$(fp_now)]: fleet pause (games): stay idle and wait for the resume message - until $FP_MARK_UNTIL"
}

fp_cut_job() {  # <dir> <task> <job-id> <class> [phase] [state]: a job the pause cancelled
  printf '%s\t%s\t%s\tbash\t%s\t%s\t-\t1794326401\tcancelled/paused\n' "$2" "$3" "$4" "${6:-running}" "${5:--}" \
    >> "$1/home/state/fleet-pause/jobs.tsv"
}

fp_interrupted() {  # <dir> <id>: the pause interrupted this task's turn
  printf '%s\tv1 gen=g1.1.1 seq=2 state=busy source=pi-ext event=test ts=1\n' "$2" >> "$1/home/state/fleet-pause/interrupted"
}

# fp_mark_state <dir> <id>: `open` while the task's newest fleet-pause line is
# the mark, `closed` once a resolved line for the key follows it, `none` when it
# was never marked. A cheap reading of the same fold fm_fleet_wait_open asks;
# fp_reader runs the real one where a case needs the house reader's word.
fp_mark_state() {
  local line last=''
  while IFS= read -r line; do
    case "$line" in *'[key=fleet-pause]'*) last=$line ;; esac
  done 2>/dev/null < "$1/home/state/$2.status"
  case "$last" in
    paused*) printf 'open' ;;
    resolved*) printf 'closed' ;;
    *) printf 'none' ;;
  esac
}

fp_mark_count() {  # <dir> <id>: how many wait marks the status log holds
  grep -c '^paused \[key=fleet-pause\]' "$1/home/state/$2.status" 2>/dev/null || true
}

# fp_sig <dir>: a signature of everything a command could change: the home, the
# queue, the cgroup files, the panes, and the timers, with file contents and
# times. A dry run must leave it identical.
fp_sig() {
  (
    cd "$1" || exit 1
    find home queue cgroup panes timers -type d 2>/dev/null | LC_ALL=C sort
    find home queue cgroup panes timers ! -type d 2>/dev/null | LC_ALL=C sort > .sig-files
    [ -s .sig-files ] || exit 0
    xargs cksum < .sig-files
    xargs stat -c '%n %Y' < .sig-files 2>/dev/null || xargs stat -f '%N %m' < .sig-files
  )
}

# The house readers a case uses to ask what the watcher and the resume would
# see, run in a clean shell so they never touch the suite's own state.
FP_READER_LIBS='. "$1/bin/fm-backend.sh"; . "$1/bin/fm-busy-lib.sh"; . "$1/bin/fm-classify-lib.sh"; . "$1/bin/fm-wake-lib.sh"
  STATE=$FM_STATE_OVERRIDE; . "$1/bin/fm-fleet-pause-lib.sh"'

fp_reader() {  # <dir> <function> [args...]
  local dir=$1
  shift
  FM_STATE_OVERRIDE="$dir/home/state" FM_HOME="$dir/home" bash -c "$FP_READER_LIBS"'
    shift; "$@"' _ "$ROOT" "$@"
}

# fp_mark_reading <dir> <id>: what those readers make of one task's status log,
# as three lines from one shell: the watcher's standing declared wait (empty
# when it reads none), the epoch that wait clears at (empty when it names
# none), and `open` or `closed` for whether a resume would still find the
# pause's mark.
fp_mark_reading() {
  FM_STATE_OVERRIDE="$1/home/state" FM_HOME="$1/home" bash -c "$FP_READER_LIBS"'
    line=$(status_declared_wait_line "$2")
    until=$(status_paused_until "$line") || until=
    printf "%s\n%s\n" "$line" "$until"
    if fm_fleet_wait_open "$2"; then echo open; else echo closed; fi' _ "$ROOT" "$1/home/state/$2.status"
}

fp_log_count() {  # <file> <fixed-string>: how many log lines contain the string
  [ -f "$1" ] || { printf '0\n'; return 0; }
  grep -cF -- "$2" "$1" || true
}
