#!/usr/bin/env bash
# tests/fm-host-recover.test.sh - bin/fm-host-recover.sh against a fake home.
#
# Hermetic: the same fake world as tests/fm-fleet-pause.test.sh
# (tests/fleet-pause-helpers.sh owns it). The endpoint states come from the
# real tmux endpoint classifier reading a fake tmux, and the launch evidence
# from the real marker scan reading a substitute /proc. Pins:
#   1. On the boot it last finished for, it does nothing and prints nothing;
#      --force runs it anyway.
#   2. --dry-run prints what it would do, including each note, and changes
#      nothing.
#   3. Only a dead endpoint and an agent the fleet did not launch (no launch
#      marker, a working directory outside the worktree, or a busy generation
#      older than the boot) are relaunched; a healthy worker, a dead worker
#      whose work is finished, and an endpoint that cannot be classified are
#      not. The queue daemon is started, each note names the jobs the restart
#      cut, and the boot id is recorded last.
#   4. While the pause record exists the queue is paused again, each note tells
#      the worker to wait for the resume message, and a second mate is not
#      relaunched.
#   5. A failed relaunch fails the run and leaves the boot id unrecorded, so
#      running it again retries.
#   6. Second mates: a local one that is dead or not fleet-launched is
#      relaunched, a healthy one is not, and a remote one is only reported with
#      the command that relaunches it.
#   7. A queue the daemon itself restored as paused is left that way.
#   8. --skip leaves the named worker exactly as it is and says so; a --skip
#      that names nobody is reported.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fleet-pause-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fleet-pause-helpers.sh"

fp_init fm-host-recover
JOB_A=aaaaaaaa-0000-4000-8000-00000000000a
JOB_B=bbbbbbbb-0000-4000-8000-00000000000b
JOB_C=cccccccc-0000-4000-8000-00000000000c

# A host that restarted ten minutes ago into boot-B. Before it went down the
# queue was running three jobs. Since then two workers have no agent:
#   t-dead       its pane holds a bare shell
#   t-gone       its pane no longer exists
# A case about one relaunch needs no more than those two.
make_restarted_pair() {  # <name> -> echoes the case dir
  local dir now
  now=$(fp_now)
  dir=$(fp_case "$1")
  fp_queue "$dir" running \
    "$(fp_job "$JOB_A" t-dead cargo running)" \
    "$(fp_job "$JOB_B" t-restored gate running compile)" \
    "$(fp_job "$JOB_C" t-healthy cargo queued)"
  fp_boot "$dir" boot-B "$((now - 600))"
  fp_queue_gone "$dir"
  fp_add_task "$dir" t-dead
  fp_endpoint "$dir" t-dead dead
  fp_busy "$dir" t-dead busy "$((now - 90000))"
  fp_add_task "$dir" t-gone
  fp_endpoint "$dir" t-gone missing
  printf '%s\n' "$dir"
}

# The same restart with every reading the classifier can return:
#   t-healthy    someone already relaunched it: a fleet-launched agent runs
#   t-restored   the terminal backend restored it: an agent without a marker
#   t-elsewhere  an agent carrying its marker, but outside its worktree
#   t-oldgen     an agent carrying its marker, with a pre-boot busy generation
#   t-finished   a bare shell, and its newest status is done
#   t-unsure     something that is neither an agent nor a shell
make_restarted() {  # <name> -> echoes the case dir
  local dir now
  now=$(fp_now)
  dir=$(make_restarted_pair "$1")
  fp_healthy_task "$dir" t-healthy 401
  fp_add_task "$dir" t-restored
  fp_endpoint "$dir" t-restored alive
  fp_agent_proc "$dir" 402 t-restored "$dir/wt" none
  fp_busy "$dir" t-restored idle "$((now - 90000))"
  fp_add_task "$dir" t-elsewhere
  fp_endpoint "$dir" t-elsewhere alive
  fp_agent_proc "$dir" 403 t-elsewhere "$dir/wt"
  fp_busy "$dir" t-elsewhere idle
  fp_add_task "$dir" t-oldgen
  fp_endpoint "$dir" t-oldgen alive
  fp_agent_proc "$dir" 404 t-oldgen
  fp_busy "$dir" t-oldgen idle "$((now - 7200))"
  fp_add_task "$dir" t-finished
  fp_endpoint "$dir" t-finished dead
  fp_status "$dir" t-finished 'working: last step' 'done: branch ready at abc123'
  fp_add_task "$dir" t-unsure
  fp_endpoint "$dir" t-unsure ambiguous
  printf '%s\n' "$dir"
}

RELAUNCHED_FIVE="t-dead relaunch
t-elsewhere relaunch
t-gone relaunch
t-oldgen relaunch
t-restored relaunch"

# One line of the summary table, laid out as the command lays it out.
row() {  # <task> <kind> <endpoint> <action> <result>
  printf '%-30s %-10s %-10s %-9s %s' "$@"
}

test_same_boot_is_quiet() {
  local dir out rc=0
  dir=$(fp_case sameboot)
  fp_add_task "$dir" t-dead
  fp_endpoint "$dir" t-dead dead
  mkdir -p "$dir/home/state/fleet-pause"
  printf 'boot_id=boot-A\nrecovered_at=1\n' > "$dir/home/state/fleet-pause/host-boot"
  out=$(fp_run "$dir" fm-host-recover.sh) || rc=$?
  expect_code 0 "$rc" "the boot already recovered should exit 0: $out"
  assert_equals "" "$out" "the boot already recovered should print nothing"
  [ -z "$(ls -A "$dir/log")" ] || fail "the boot already recovered should touch nothing: $(ls "$dir/log")"

  out=$(fp_run "$dir" fm-host-recover.sh --force) || fail "--force on the same boot should run: $out"
  assert_equals "t-dead relaunch" "$(cat "$dir/log/control")" "--force recovers on the same boot"
  assert_contains "$out" "host recovery: home $dir/home, boot boot-A (last recovered boot: boot-A)" "--force should say which boot it is"
  pass "fm-host-recover: quiet on the boot it last finished for, and --force runs anyway"
}

test_dry_run_changes_nothing() {
  local dir before after out rc=0
  dir=$(make_restarted dry)
  before=$(fp_sig "$dir")
  out=$(fp_run "$dir" fm-host-recover.sh --dry-run) || rc=$?
  expect_code 0 "$rc" "a dry run should succeed: $out"
  after=$(fp_sig "$dir")
  assert_equals "$before" "$after" "a dry run must not change the home, the queue, the panes, or the timers"
  assert_absent "$dir/log/jobqueue" "a dry run must not call the queue"
  assert_absent "$dir/log/control" "a dry run must not relaunch anyone"
  assert_absent "$dir/home/state/fleet-pause" "a dry run must not record the boot"
  assert_contains "$out" "would run: $FP_SHARED/fakebin/jobqueue daemon --start" "the dry run should print the daemon start"
  assert_contains "$out" "bin/fm-control.sh t-dead relaunch --note-file <a file holding the note below>" "the dry run should print the relaunch"
  assert_contains "$out" "  | Host recovery (bin/fm-host-recover.sh, 20" "the dry run should print the note"
  assert_contains "$out" "  | - aaaaaaaa (jobqueue show $JOB_A): class cargo, ran bash, was running" "the dry run's note should name the lost job"
  assert_not_contains "$out" "fm-control.sh t-healthy" "the dry run should not plan to relaunch a healthy worker"
  assert_contains "$out" "would record boot boot-B in state/fleet-pause/host-boot" "the dry run should print the boot record"
  pass "fm-host-recover: --dry-run prints every relaunch and note and changes nothing"
}

test_relaunches_only_dead_or_not_fleet_launched() {
  local dir out rc=0 note
  dir=$(make_restarted recover)
  out=$(fp_run "$dir" fm-host-recover.sh) || rc=$?
  expect_code 0 "$rc" "the recovery should succeed: $out"

  assert_equals "$RELAUNCHED_FIVE" "$(cat "$dir/log/control")" \
    "exactly the dead and the not-fleet-launched workers are relaunched"
  assert_equals "daemon --start" "$(cat "$dir/log/jobqueue")" "the queue daemon is started, and admission is left as it came up"
  assert_contains "$out" "queue: running and admitting" "the report should say how the queue came up"
  assert_absent "$dir/log/send" "a recovery never steers anyone"

  assert_contains "$out" "$(row TASK KIND ENDPOINT ACTION RESULT)" "the summary table should have its header"
  assert_contains "$out" "$(row t-healthy ship alive none healthy)" "a healthy worker is left alone"
  assert_contains "$out" "$(row t-dead ship dead relaunch 'relaunched (no agent is running in its endpoint (dead))')" \
    "a dead endpoint is relaunched"
  assert_contains "$out" "$(row t-gone ship missing relaunch 'relaunched (no agent is running in its endpoint (missing))')" \
    "a missing endpoint is relaunched"
  assert_contains "$out" "$(row t-restored ship alive relaunch 'relaunched (no agent process carries FM_TASK_ID for it)')" \
    "an agent without the launch marker is relaunched"
  assert_contains "$out" "$(row t-elsewhere ship alive relaunch "relaunched (its agent runs in $dir/wt, not the recorded worktree)")" \
    "an agent outside its worktree is relaunched"
  assert_contains "$out" "$(row t-oldgen ship alive relaunch 'relaunched (its busy generation is older than this boot)')" \
    "an agent with a pre-boot busy generation is relaunched"
  assert_contains "$out" "$(row t-finished ship dead none 'not relaunched: its newest status is done, so its work is finished')" \
    "a dead worker whose work is finished is not relaunched"
  assert_contains "$out" "$(row t-unsure ship ambiguous none 'NOT DETERMINED: its endpoint reads ambiguous')" \
    "an endpoint that cannot be classified is reported, not relaunched"
  assert_contains "$out" "summary: 1 healthy, 5 relaunched, 1 left alone, 1 not determined; 0 step(s) failed" "the summary should count each outcome"
  assert_contains "$out" "not determined: t-unsure - nothing was relaunched for them" "the undetermined worker should be named"

  note=$(cat "$dir/log/note-t-dead")
  assert_contains "$note" "this worker was relaunched because no agent is running in its endpoint (dead)." "the note should say why"
  assert_contains "$note" "The host last started at about 20" "the note should say when the host started"
  assert_contains "$note" "These queue jobs of yours were live when the host went down and are lost:" "the note should introduce the lost jobs"
  assert_contains "$note" "- aaaaaaaa (jobqueue show $JOB_A): class cargo, ran bash, was running" "the note should name the lost job"
  assert_not_contains "$note" "$JOB_B" "a note must not name another task's job"
  assert_contains "$note" "Resubmit what you still need and carry on" "outside a pause the worker is told to carry on"
  assert_contains "$note" "Ask firstmate before re-running a gate test phase or a measurement run" "the note should carry the restart-safety rule"
  assert_contains "$(cat "$dir/log/note-t-restored")" "- bbbbbbbb (jobqueue show $JOB_B): class gate, phase compile, ran bash, was running" \
    "a restored worker's note should name its lost job"
  assert_contains "$(cat "$dir/log/note-t-gone")" "No queue job of yours was live when the host went down." \
    "a worker with no lost job should be told so"
  assert_equals host-boot "$(ls -A "$dir/home/state/fleet-pause")" "only the boot record is left behind; the note files are removed"

  assert_equals "boot_id=boot-B" "$(sed -n 1p "$dir/home/state/fleet-pause/host-boot")" "the boot id is recorded once the recovery finished"
  assert_absent "$dir/home/state/.fleet-pause.lock" "the lock should be released"

  out=$(fp_run "$dir" fm-host-recover.sh) || fail "a second run on the same boot should succeed"
  assert_equals "" "$out" "a second run on the same boot prints nothing"
  out=$(fp_run "$dir" fm-host-recover.sh --force) || fail "--force on a recovered fleet should succeed: $out"
  assert_equals "$RELAUNCHED_FIVE" "$(cat "$dir/log/control")" "a recovered fleet has nothing left to relaunch"
  assert_contains "$out" "summary: 6 healthy, 0 relaunched, 1 left alone, 1 not determined" "a recovered fleet reads healthy"
  pass "fm-host-recover: relaunches exactly the dead and the not-fleet-launched, with a note naming each one's lost jobs"
}

test_paused_fleet_stays_paused() {
  local dir out rc=0 note
  dir=$(make_restarted_pair paused)
  printf 'fleet pause: games 2026-11-10T05:47Z\n' > "$dir/home/state/captain-pause.flag"
  fp_add_task "$dir" mate-local secondmate claude
  fp_endpoint "$dir" mate-local dead
  out=$(fp_run "$dir" fm-host-recover.sh) || rc=$?
  expect_code 0 "$rc" "the recovery of a paused fleet should succeed: $out"
  assert_equals "daemon --start
pause" "$(cat "$dir/log/jobqueue")" "the queue is started and then paused again"
  jq -e '.paused == true' "$dir/queue/status.json" >/dev/null || fail "the queue should be paused"
  assert_contains "$out" "pause record: present (fleet pause: games 2026-11-10T05:47Z); the fleet stays paused" "the report should say the fleet is paused"
  assert_contains "$out" "queue: paused (jobqueue pause), as the pause record requires" "the report should say the queue was paused again"
  note=$(cat "$dir/log/note-t-dead")
  assert_contains "$note" "The fleet is paused: do not start work and do not submit queue jobs. Stay idle and wait for the resume message." \
    "a worker relaunched into a pause is told to wait"
  assert_not_contains "$note" "Resubmit what you still need" "a worker relaunched into a pause is not told to carry on"
  assert_equals 0 "$(fp_log_count "$dir/log/control" mate-local)" "a second mate is not relaunched while the fleet is paused"
  assert_contains "$out" "not relaunched while the fleet is paused. After the resume run: FM_HOME=$dir/home bin/fm-control.sh mate-local relaunch" \
    "the command that relaunches the second mate later should be printed"
  assert_contains "$out" "next: the fleet is still paused. Run bin/fm-fleet-pause.sh again" "the report should say what to run next"
  assert_present "$dir/home/state/captain-pause.flag" "a recovery never ends a pause"
  assert_equals "boot_id=boot-B" "$(sed -n 1p "$dir/home/state/fleet-pause/host-boot")" "the boot id is recorded"
  pass "fm-host-recover: under a pause record the queue is paused again and relaunched workers are told to wait"
}

test_failed_relaunch_is_retried() {
  local dir out rc=0
  dir=$(make_restarted_pair retry)
  : > "$dir/knob/relaunch-fails-t-dead"
  out=$(fp_run "$dir" fm-host-recover.sh) || rc=$?
  expect_code 1 "$rc" "a failed relaunch must fail the recovery: $out"
  assert_contains "$out" "error: task t-dead: NOT relaunched (fm-control exit 1): error: the replacement agent for t-dead could not be launched on pi" \
    "the failure should carry what the control plane said"
  assert_contains "$out" "$(row t-dead ship dead relaunch 'FAILED: relaunch refused or failed')" "the table should show the failure"
  assert_contains "$out" "boot id NOT recorded because a step failed" "the report should say the boot was not recorded"
  assert_absent "$dir/home/state/fleet-pause/host-boot" "a failed recovery must not record the boot"
  assert_equals "t-dead relaunch
t-gone relaunch" "$(cat "$dir/log/control")" "the other worker is still relaunched"

  rm -f "$dir/knob/relaunch-fails-t-dead"
  rc=0
  out=$(fp_run "$dir" fm-host-recover.sh) || rc=$?
  expect_code 0 "$rc" "running it again should finish the recovery: $out"
  assert_equals "t-dead relaunch
t-gone relaunch
t-dead relaunch" "$(cat "$dir/log/control")" "the failed relaunch is retried, and the worker already relaunched is left alone"
  assert_equals "boot_id=boot-B" "$(sed -n 1p "$dir/home/state/fleet-pause/host-boot")" "the boot id is recorded once nothing failed"
  pass "fm-host-recover: a failed relaunch fails the run, leaves the boot unrecorded, and is retried by the next run"
}

test_second_mates() {
  local dir out rc=0 state_real
  dir=$(fp_case mates)
  fp_boot "$dir" boot-B "$(($(fp_now) - 600))"
  fp_queue "$dir" running
  state_real=$(cd "$dir/home/state" && pwd -P)
  fp_add_task "$dir" mate-dead secondmate claude
  fp_endpoint "$dir" mate-dead dead
  fp_add_task "$dir" mate-ok secondmate claude
  fp_endpoint "$dir" mate-ok alive
  fp_agent_proc "$dir" 501 mate-ok "" inbox
  fp_busy "$dir" mate-ok idle
  fp_add_task "$dir" mate-restored secondmate claude
  fp_endpoint "$dir" mate-restored alive
  fp_agent_proc "$dir" 502 mate-restored "" none
  fp_add_task "$dir" mate-far secondmate claude
  printf 'remote_host=vps\n' >> "$dir/home/state/mate-far.meta"

  out=$(fp_run "$dir" fm-host-recover.sh) || rc=$?
  expect_code 0 "$rc" "the recovery should succeed: $out"
  assert_equals "mate-dead relaunch
mate-restored relaunch" "$(cat "$dir/log/control")" "a local second mate that is dead or not fleet-launched is relaunched"
  assert_contains "$out" "$(row mate-ok secondmate alive none healthy)" "a healthy second mate is left alone"
  assert_contains "$out" "$(row mate-restored secondmate alive relaunch 'relaunched (no agent process carries FM_TASK_INBOX for it)')" \
    "a second mate is matched on its inbox marker"
  assert_equals mate-far "$(cat "$dir/log/crew-state")" "a remote second mate's state is read through the house reader"
  assert_contains "$out" "$(row mate-far secondmate remote:vps none 'state: unknown')" "a remote second mate is reported with its state"
  assert_contains "$out" "to relaunch it run: FM_HOME=$dir/home bin/fm-remote-secondmate-relaunch.sh mate-far default default default" \
    "the command that relaunches a remote second mate should be printed"
  assert_absent "$dir/log/jobqueue" "a queue that is running is left alone"

  dir=$(fp_case matefail)
  fp_boot "$dir" boot-B "$(($(fp_now) - 600))"
  fp_add_task "$dir" mate-dead secondmate claude
  fp_endpoint "$dir" mate-dead missing
  : > "$dir/knob/relaunch-fails-mate-dead"
  rc=0
  out=$(fp_run "$dir" fm-host-recover.sh) || rc=$?
  expect_code 1 "$rc" "a second mate that could not be relaunched must fail the run: $out"
  assert_contains "$out" "if its endpoint is gone run: FM_HOME=$dir/home bin/fm-spawn.sh mate-dead --secondmate" \
    "the second mate's own recovery command should be printed"
  pass "fm-host-recover: local second mates are relaunched when needed, a remote one is reported with its command"
}

test_queue_restored_paused_is_left_alone() {
  local dir out rc=0 now
  now=$(fp_now)
  dir=$(fp_case restored)
  fp_boot "$dir" boot-B "$((now - 600))"
  fp_queue "$dir" paused
  jq --argjson at "$now" --arg id "$JOB_A" '.pause_reason = "daemon_restart"
    | .jobs = [{id: $id, task: "t-dead", class: "cargo", state: "done", result: "interrupted", reason: "daemon_restart",
                exe: "bash", phase: null, project: null, submitted_at: ($at - 900), finished_at: ($at - 300), exit_code: 125}]' \
    "$dir/queue/status.json" > "$dir/queue/status.json.new" && mv "$dir/queue/status.json.new" "$dir/queue/status.json"
  fp_add_task "$dir" t-dead
  fp_endpoint "$dir" t-dead dead
  fp_add_task "$dir" t-gone
  fp_endpoint "$dir" t-gone missing
  out=$(fp_run "$dir" fm-host-recover.sh) || rc=$?
  expect_code 0 "$rc" "the recovery should succeed: $out"
  assert_absent "$dir/log/jobqueue" "a running daemon is not started, paused, or resumed"
  assert_contains "$out" "queue: running, with admission paused by the daemon itself (reason daemon_restart); left as it restored it. Run 'jobqueue resume'" \
    "the report should say the daemon paused itself and how to resume"
  assert_contains "$(cat "$dir/log/note-t-dead")" "The job queue ended these jobs of yours at the restart:" \
    "with only the restarted daemon's list, the note says where the jobs came from"
  assert_contains "$(cat "$dir/log/note-t-dead")" "- aaaaaaaa (jobqueue show $JOB_A): class cargo, ran bash, was interrupted/daemon_restart" \
    "the note should name the job the daemon ended"
  assert_contains "$(cat "$dir/log/note-t-dead")" "It lists only its latest finished jobs, so also check your own last job" \
    "the note should say the list may be short"
  assert_contains "$(cat "$dir/log/note-t-gone")" "lists no job of yours as ended by the restart, but it lists only its latest finished jobs" \
    "a worker with nothing listed is still told to check"
  pass "fm-host-recover: a queue the daemon restored as paused is left that way, and notes say how far its list can be trusted"
}

test_usage_and_no_boot_id() {
  local dir out rc=0
  dir=$(fp_case usage)
  out=$(fp_run "$dir" fm-host-recover.sh --bogus) || rc=$?
  expect_code 2 "$rc" "an unknown option is a usage error"
  out=$(fp_run "$dir" fm-host-recover.sh --help) || fail "--help should succeed"
  assert_contains "$out" "Usage: fm-host-recover.sh [--dry-run] [--force]" "--help should print the header"
  rm -f "$dir/proc/sys/kernel/random/boot_id"
  rc=0
  out=$(fp_run "$dir" fm-host-recover.sh) || rc=$?
  expect_code 1 "$rc" "a host with no boot id cannot be recovered by boot: $out"
  assert_contains "$out" "error: this host exposes no boot id" "the refusal should say why"
  pass "fm-host-recover: usage errors exit 2, and a host with no boot id is refused"
}

test_skip_leaves_a_worker_alone() {
  local dir out rc=0
  dir=$(make_restarted_pair skip)
  out=$(fp_run "$dir" fm-host-recover.sh --skip t-dead --skip=t-typo) || rc=$?
  expect_code 0 "$rc" "a recovery that skips one worker should succeed: $out"
  assert_equals "t-gone relaunch" "$(cat "$dir/log/control")" "the skipped worker must not be relaunched, and the other still is"
  assert_absent "$dir/log/note-t-dead" "no note is written for a skipped worker"
  assert_contains "$out" "$(row t-dead ship - none 'skipped (--skip)')" "the table should say the worker was skipped"
  assert_contains "$out" "summary: 0 healthy, 1 relaunched, 1 left alone, 0 not determined; 0 step(s) failed" "a skipped worker counts as left alone"
  assert_contains "$out" "note: --skip t-typo names no direct report of this home" "a --skip that names nobody should be reported"
  assert_equals "boot_id=boot-B" "$(sed -n 1p "$dir/home/state/fleet-pause/host-boot")" "a skip is not a failure, so the boot is recorded"
  rc=0
  out=$(fp_run "$dir" fm-host-recover.sh --skip) || rc=$?
  expect_code 2 "$rc" "--skip without a task id is a usage error"
  pass "fm-host-recover: --skip leaves the named worker alone, and a --skip that names nobody is reported"
}

test_same_boot_is_quiet
test_dry_run_changes_nothing
test_relaunches_only_dead_or_not_fleet_launched
test_skip_leaves_a_worker_alone
test_paused_fleet_stays_paused
test_failed_relaunch_is_retried
test_second_mates
test_queue_restored_paused_is_left_alone
test_usage_and_no_boot_id
