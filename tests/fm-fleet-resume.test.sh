#!/usr/bin/env bash
# tests/fm-fleet-resume.test.sh - bin/fm-fleet-resume.sh against a fake home.
#
# Hermetic: the same fake world as tests/fm-fleet-pause.test.sh
# (tests/fleet-pause-helpers.sh owns it). The case that pins the whole resume
# pauses its fleet with the real bin/fm-fleet-pause.sh, and proves that the
# paused state the other cases write directly is record for record what that
# command leaves, so every case resumes what a pause really produces.
# Pins:
#   1. Without a pause record it refuses and resumes nothing; --force goes on.
#   2. --dry-run prints what it would do and changes nothing.
#   3. A resume confirms the queue from its snapshot, removes the pause record
#      before any worker is steered, restarts exactly the timers the pause
#      stopped, sends each marked worker ONE steer naming the jobs the pause
#      cut and the restart-safety rule, closes each mark, and staggers sends.
#   4. A queue that still reports paused, or cannot be resumed or started,
#      fails loudly: the record stays and nobody is steered.
#   5. A queue with no daemon is started first, with the user-manager
#      environment derived when absent.
#   6. A task held for the captain is skipped and keeps its mark for a later
#      --force run.
#   7. After a host restart during the pause it refuses until the recovery has
#      run for the new boot, and even then never steers an agent the fleet did
#      not launch.
#   8. A steer bin/fm-send.sh refuses leaves that worker's mark for a retry.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fleet-pause-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fleet-pause-helpers.sh"

fp_init fm-fleet-resume
JOB_CARGO=aaaaaaaa-0000-4000-8000-000000000001
JOB_GATE=aaaaaaaa-0000-4000-8000-000000000002
JOB_OTHER=aaaaaaaa-0000-4000-8000-000000000003

# The fleet every case resumes: two ships and one listed timer.
make_fleet() {  # <name> -> echoes the case dir
  local dir
  dir=$(fp_case "$1")
  fp_healthy_task "$dir" t1 101
  fp_status "$dir" t1 'working: building'
  fp_healthy_task "$dir" t2 102
  fp_status "$dir" t2 'resolved: job 9 passed'
  printf 'roadmap.timer\n' > "$dir/home/config/fleet-pause-timers"
  printf '%s\n' "$dir"
}

# That fleet, paused by the real command: t1 was mid-turn with two live jobs
# (one in its test phase) and was interrupted; t2 was idle with none; a third
# job belonged to no task of this home; the timer was running and was stopped.
# Fake logs are cleared afterwards, so a case counts only what the resume did.
make_paused_real() {  # <name> -> echoes the case dir
  local dir
  dir=$(make_fleet "$1")
  fp_busy "$dir" t1 busy
  fp_queue "$dir" running \
    "$(fp_job "$JOB_CARGO" t1 cargo running)" \
    "$(fp_job "$JOB_GATE" t1 gate running test)" \
    "$(fp_job "$JOB_OTHER" elsewhere general queued)"
  : > "$dir/timers/roadmap.timer"
  fp_run "$dir" fm-fleet-pause.sh --reason games >/dev/null || return 1
  fp_busy "$dir" t1 idle
  rm -f "$dir"/log/*
  printf '%s\n' "$dir"
}

# The same paused fleet written directly, which is what most cases start from:
# a suite that ran the pause command for every case would spend most of its
# time re-testing the pause.
make_paused() {  # <name> -> echoes the case dir
  local dir
  dir=$(make_fleet "$1")
  fp_paused "$dir" t1 t2
  fp_cut_job "$dir" t1 "$JOB_CARGO" cargo
  fp_cut_job "$dir" t1 "$JOB_GATE" gate test
  fp_cut_job "$dir" elsewhere "$JOB_OTHER" general '' queued
  fp_interrupted "$dir" t1
  printf 'roadmap.timer\n' > "$dir/home/state/fleet-pause/timers-stopped"
  printf '%s\n' "$dir"
}

# Everything a pause records, with clock readings replaced, so the two ways of
# pausing the fleet can be compared.
pause_records() {  # <dir>
  (
    cd "$1/home/state" || exit 1
    ls fleet-pause
    sed 's/ 20[0-9][0-9]-[0-9T:-]*Z$/ <when>/' captain-pause.flag
    sed 's/^paused_at=.*/paused_at=<when>/' fleet-pause/pause
    awk -F '\t' -v OFS='\t' '/^#/ { print; next } { $8 = "<when>"; print }' fleet-pause/jobs.tsv
    cut -f 1 fleet-pause/interrupted
    cat fleet-pause/timers-stopped
    sed -e 's/\[at=[0-9]*\]/[at=<when>]/' -e 's/ - until .*$/ - until <when>/' t1.status t2.status
    jq -c '[.paused, .pause_reason]' "$1/queue/status.json"
    ls "$1/timers"
  )
}

mark_open() {  # <dir> <id>
  [ "$(fp_mark_state "$1" "$2")" = open ]
}

test_refuses_without_a_pause_record() {
  local dir out rc=0
  dir=$(fp_case norecord)
  fp_healthy_task "$dir" t1 101
  fp_queue "$dir" paused
  out=$(fp_run "$dir" fm-fleet-resume.sh) || rc=$?
  expect_code 1 "$rc" "a resume with no pause record must refuse: $out"
  assert_contains "$out" "error: there is no pause record at $dir/home/state/captain-pause.flag" "the refusal should say why"
  assert_absent "$dir/log/jobqueue" "a refused resume must not touch the queue"
  rc=0
  out=$(fp_run "$dir" fm-fleet-resume.sh --stagger-secs soon) || rc=$?
  expect_code 2 "$rc" "a non-numeric stagger is a usage error: $out"

  fp_mark "$dir" t1
  rc=0
  out=$(fp_run "$dir" fm-fleet-resume.sh) || rc=$?
  expect_code 1 "$rc" "a leftover mark does not make a pause: $out"
  assert_contains "$out" "still carry a wait mark from an earlier pause that was not fully resumed: t1" "the refusal should name the leftover marks"
  assert_contains "$out" "bin/fm-fleet-resume.sh --force" "the refusal should say how to finish"

  rc=0
  out=$(fp_run "$dir" fm-fleet-resume.sh --force --stagger-secs 0) || rc=$?
  expect_code 0 "$rc" "--force should resume without a record: $out"
  assert_contains "$out" "pause record: none; going on because of --force" "--force should say it is going on"
  assert_equals 1 "$(fp_log_count "$dir/log/jobqueue" resume)" "--force resumes the paused queue"
  assert_equals t1 "$(cat "$dir/log/send")" "--force steers the worker that still carried a mark"
  assert_contains "$(cat "$dir/log/sent-t1")" "Which of your queue jobs the pause cancelled was not recorded" \
    "with no saved job list the worker is told to check its own last job"
  pass "fm-fleet-resume: refuses without a pause record, names leftover marks, and --force goes on"
}

test_dry_run_changes_nothing() {
  local dir before after out rc=0
  dir=$(make_paused dry)
  before=$(fp_sig "$dir")
  out=$(fp_run "$dir" fm-fleet-resume.sh --dry-run) || rc=$?
  expect_code 0 "$rc" "a dry run should succeed: $out"
  after=$(fp_sig "$dir")
  assert_equals "$before" "$after" "a dry run must not change the home, the queue, the panes, or the timers"
  assert_absent "$dir/log/jobqueue" "a dry run must not call the queue"
  assert_absent "$dir/log/send" "a dry run must not steer anyone"
  assert_equals 0 "$(fp_log_count "$dir/log/systemctl" start)" "a dry run must not start a timer"
  assert_contains "$out" "would run: $FP_SHARED/fakebin/jobqueue resume" "the dry run should print the queue resume"
  assert_contains "$out" "would remove state/captain-pause.flag" "the dry run should print the record removal"
  assert_contains "$out" "would run: systemctl --user start roadmap.timer" "the dry run should print the timer start"
  assert_contains "$out" "bin/fm-send.sh t1 " "the dry run should print the steer"
  assert_contains "$out" "would append to state/t1.status: resolved [key=fleet-pause]: fleet resumed by firstmate" "the dry run should print the mark close"
  pass "fm-fleet-resume: --dry-run prints every step and changes nothing"
}

test_resume_steers_each_marked_worker_once() {
  local dir out rc=0 sent id line until open
  dir=$(make_paused_real resume) || fail "setup: the pause failed"
  assert_equals "$(pause_records "$dir")" "$(pause_records "$(make_paused written)")" \
    "the paused state the other cases write directly must be what bin/fm-fleet-pause.sh leaves"
  out=$(fp_run "$dir" fm-fleet-resume.sh) || rc=$?
  expect_code 0 "$rc" "the resume should succeed: $out"

  jq -e '.paused == false' "$dir/queue/status.json" >/dev/null || fail "the queue should be admitting"
  assert_equals 1 "$(fp_log_count "$dir/log/jobqueue" resume)" "the queue is resumed once"
  assert_absent "$dir/home/state/captain-pause.flag" "the pause record should be gone"
  assert_absent "$dir/home/state/fleet-pause/pause" "the pause's detail record goes with it"
  assert_equals "t1 record-gone
t2 record-gone" "$(cat "$dir/log/send-order")" "each marked worker is steered once, after the pause record was removed"

  sent=$(cat "$dir/log/sent-t1")
  assert_contains "$sent" "Fleet resume: the fleet-wide pause is over and the job queue is admitting again." "the steer should open with the news"
  assert_contains "$sent" "The pause interrupted the turn you were in." "an interrupted worker should be told"
  assert_contains "$sent" "- aaaaaaaa (jobqueue show $JOB_CARGO): class cargo, ran bash, was running" "the steer should list the cut cargo job"
  assert_contains "$sent" "- aaaaaaaa (jobqueue show $JOB_GATE): class gate, phase test, ran bash, was running - cut during a test phase: ask before re-running it" \
    "the steer should flag the job cut during a test phase"
  assert_contains "$sent" "Resubmit them and carry on from where you stopped." "the steer should say to resubmit and carry on"
  assert_contains "$sent" "Ask firstmate before re-running a gate test phase or a measurement run: those are not restart-safe." \
    "the steer should carry the restart-safety rule"
  assert_not_contains "$sent" "$JOB_OTHER" "a worker must not be told about another task's job"
  sent=$(cat "$dir/log/sent-t2")
  assert_contains "$sent" "The pause cancelled no queue job of yours. Carry on from where you stopped." "a worker with no cut job should be told so"
  assert_not_contains "$sent" "interrupted the turn" "a worker that was idle was not interrupted"

  for id in t1 t2; do
    assert_contains "$(tail -n 1 "$dir/home/state/$id.status")" "resolved [key=fleet-pause] [at=" "$id's mark should be closed"
    { IFS= read -r line; IFS= read -r until; IFS= read -r open; } <<EOF
$(fp_mark_reading "$dir" "$id")
EOF
    assert_equals closed "$open" "$id's mark should no longer be open"
    assert_equals "" "$line" "the watcher should read no standing wait for $id"
  done
  assert_present "$dir/timers/roadmap.timer" "the timer the pause stopped should be running again"
  assert_absent "$dir/home/state/fleet-pause/timers-stopped" "the stopped-timer record should be cleared"
  assert_equals 5 "$(cat "$dir/log/sleep")" "two sends are one default stagger apart"
  assert_absent "$dir/home/state/fleet-pause/jobs.tsv" "a finished resume clears the pause's job list"
  assert_contains "$out" "summary: 2 marked task(s): 2 steered, 0 held for the captain, 0 not steered; 0 step(s) failed" "the summary should count the steers"
  assert_absent "$dir/home/state/.fleet-pause.lock" "the lock should be released"

  rc=0
  out=$(fp_run "$dir" fm-fleet-resume.sh) || rc=$?
  expect_code 1 "$rc" "a second resume has no pause record to act on: $out"
  assert_equals 2 "$(wc -l < "$dir/log/send" | tr -d ' ')" "a second resume steers nobody again"
  pass "fm-fleet-resume: queue confirmed, record removed first, timers restarted, one steer per worker with its cut jobs, marks closed"
}

test_queue_that_stays_paused_fails_loudly() {
  local dir out rc=0
  dir=$(make_paused stuck)
  : > "$dir/knob/resume-noop"
  out=$(fp_run "$dir" fm-fleet-resume.sh) || rc=$?
  expect_code 1 "$rc" "a queue that still reports paused must fail the resume: $out"
  assert_contains "$out" "error: queue: NOT resumed. It still reads paused (reason paused) after jobqueue resume (exit 0)" \
    "the failure should say what the snapshot still reports"
  assert_contains "$out" "the pause record is kept and no worker was steered" "the failure should say nothing else moved"
  assert_present "$dir/home/state/captain-pause.flag" "the pause record must stay"
  assert_absent "$dir/log/send" "nobody is steered while the queue is paused"
  assert_absent "$dir/timers/roadmap.timer" "the timers stay stopped"
  mark_open "$dir" t1 || fail "the marks must stay open"

  rm -f "$dir/knob/resume-noop"
  : > "$dir/knob/resume-fails"
  rc=0
  out=$(fp_run "$dir" fm-fleet-resume.sh) || rc=$?
  expect_code 1 "$rc" "a queue that refuses to resume must fail the resume: $out"
  assert_contains "$out" "insufficient available memory to resume" "the failure should carry what the queue said"
  assert_present "$dir/home/state/captain-pause.flag" "the pause record must stay"

  rm -f "$dir/knob/resume-fails"
  rc=0
  out=$(fp_run "$dir" fm-fleet-resume.sh --stagger-secs 2) || rc=$?
  expect_code 0 "$rc" "once the queue resumes the same command finishes the job: $out"
  assert_equals 2 "$(wc -l < "$dir/log/send" | tr -d ' ')" "both workers are steered on the run that succeeds"
  assert_equals 2 "$(tail -n 1 "$dir/log/sleep")" "--stagger-secs sets the gap between sends"
  pass "fm-fleet-resume: a queue that will not resume fails loudly, keeps the record, and steers nobody"
}

test_starts_the_queue_daemon_when_it_is_down() {
  local dir out rc=0 uid
  uid=$(id -u)
  dir=$(make_paused daemon)
  fp_queue_gone "$dir"
  : > "$dir/knob/starts-paused"
  out=$(fp_run "$dir" fm-fleet-resume.sh --stagger-secs=0) || rc=$?
  expect_code 0 "$rc" "a resume should start a queue daemon that is down: $out"
  assert_equals 2 "$(wc -l < "$dir/log/send" | tr -d ' ')" "both workers are steered once the daemon is up"
  assert_absent "$dir/log/sleep" "--stagger-secs=0 sends without a gap, and a queue that answers at once is not waited on"
  assert_equals "daemon --start
resume" "$(cat "$dir/log/jobqueue")" "the daemon is started, then the queue is resumed"
  assert_equals "XDG_RUNTIME_DIR=/run/user/$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus" "$(cat "$dir/log/daemon-env")" \
    "the daemon start should get the derived user-manager environment"
  assert_contains "$out" "queue: queue daemon (pid $FP_DAEMON_PID) is not running; starting it" "the report should say the daemon was down"
  assert_contains "$out" "queue: resumed (jobqueue resume) and confirmed admitting" "the report should confirm admission"

  dir=$(make_paused daemonup)
  fp_queue_gone "$dir"
  rc=0
  out=$(fp_run "$dir" fm-fleet-resume.sh --stagger-secs 0) || rc=$?
  expect_code 0 "$rc" "a daemon that comes up admitting needs no resume: $out"
  assert_equals "daemon --start" "$(cat "$dir/log/jobqueue")" "a queue that restarts admitting is not resumed again"

  dir=$(make_paused daemonfail)
  fp_queue_gone "$dir"
  : > "$dir/knob/start-fails"
  rc=0
  out=$(fp_run "$dir" fm-fleet-resume.sh) || rc=$?
  expect_code 1 "$rc" "a daemon that will not start must fail the resume: $out"
  assert_contains "$out" "error: queue: the daemon did not start (jobqueue daemon --start exit 1)" "the failure should name the start"
  assert_contains "$out" "systemctl --user reset-failed jobqueue-daemon.service" "the failure should say how to clear a leftover unit"
  assert_present "$dir/home/state/captain-pause.flag" "the pause record must stay"
  assert_absent "$dir/log/send" "nobody is steered without a queue"
  pass "fm-fleet-resume: a queue daemon that is down is started first, and a failed start stops the resume"
}

test_skips_a_task_held_for_the_captain() {
  local dir out rc=0
  dir=$(make_paused held)
  : > "$dir/knob/held-t1"
  out=$(fp_run "$dir" fm-fleet-resume.sh) || rc=$?
  expect_code 0 "$rc" "a held task is not a failure: $out"
  assert_equals t2 "$(cat "$dir/log/send")" "only the task that is not held is steered"
  assert_contains "$out" "task t1: held for the captain; not steered, its wait mark stays" "the report should say the held task was skipped"
  assert_contains "$out" "next: 1 task(s) keep their wait mark; once they can be steered run: bin/fm-fleet-resume.sh --force" \
    "the report should say how to finish later"
  mark_open "$dir" t1 || fail "a held task must keep its wait mark"
  ! mark_open "$dir" t2 || fail "the steered task's mark should be closed"
  assert_absent "$dir/log/sleep" "a skipped task costs no stagger"
  assert_present "$dir/home/state/fleet-pause/jobs.tsv" "the job list is kept while a marked task remains"

  rm -f "$dir/knob/held-t1"
  rc=0
  out=$(fp_run "$dir" fm-fleet-resume.sh --force) || rc=$?
  expect_code 0 "$rc" "the later --force run should steer the released task: $out"
  assert_contains "$(cat "$dir/log/sent-t1")" "(jobqueue show $JOB_GATE)" "the released task is still told which jobs the pause cut"
  ! mark_open "$dir" t1 || fail "the released task's mark should now be closed"
  assert_absent "$dir/home/state/fleet-pause/jobs.tsv" "the job list goes once nobody is left to tell"
  pass "fm-fleet-resume: a task held for the captain is skipped and steered by a later --force run"
}

test_refuses_after_a_host_restart() {
  local dir before after out rc=0 now
  now=$(fp_now)
  dir=$(make_paused restart)
  # The host restarted: a new boot, no queue daemon, t1's pane restored with an
  # agent the fleet did not launch, t2's pane a bare shell.
  fp_boot "$dir" boot-B "$((now - 600))"
  fp_queue_gone "$dir"
  rm -rf "$dir/proc/101" "$dir/proc/102"
  fp_agent_proc "$dir" 201 t1 "$dir/wt" none
  fp_endpoint "$dir" t2 dead
  before=$(fp_sig "$dir")
  out=$(fp_run "$dir" fm-fleet-resume.sh) || rc=$?
  expect_code 1 "$rc" "a resume across a host restart must refuse: $out"
  assert_contains "$out" "error: the host restarted during the pause (boot boot-A then, boot-B now)" "the refusal should name both boots"
  assert_contains "$out" "Run bin/fm-host-recover.sh first, then run bin/fm-fleet-resume.sh again" "the refusal should say what to run"
  after=$(fp_sig "$dir")
  assert_equals "$before" "$after" "a refused resume must change nothing"
  assert_absent "$dir/log/jobqueue" "a refused resume must not touch the queue"
  assert_absent "$dir/log/send" "a refused resume must not steer anyone"

  # The recovery ran for the new boot: the queue is up and paused, t2 was
  # relaunched, and t1's relaunch failed, so its pane still holds the restored
  # agent.
  printf 'boot_id=boot-B\nrecovered_at=%s\n' "$now" > "$dir/home/state/fleet-pause/host-boot"
  fp_queue "$dir" paused
  fp_endpoint "$dir" t2 alive
  fp_agent_proc "$dir" 302 t2
  fp_busy "$dir" t2 idle
  rc=0
  out=$(fp_run "$dir" fm-fleet-resume.sh) || rc=$?
  expect_code 1 "$rc" "a worker the fleet did not launch must fail the resume: $out"
  assert_contains "$out" "host: restarted during the pause; bin/fm-host-recover.sh has already run for this boot" \
    "the report should say the restart was handled"
  assert_contains "$out" "error: task t1: NOT steered: the fleet did not launch the agent in its endpoint (no agent process carries FM_TASK_ID for it)" \
    "the refusal should say why t1 was not steered"
  assert_equals t2 "$(cat "$dir/log/send")" "only the fleet-launched worker is steered"
  mark_open "$dir" t1 || fail "the unsteered worker must keep its wait mark"
  assert_absent "$dir/home/state/captain-pause.flag" "the queue resumed, so the pause record is gone"

  dir=$(make_paused restartforce)
  fp_boot "$dir" boot-B "$((now - 600))"
  rm -rf "$dir/proc/101"
  fp_agent_proc "$dir" 201 t1 "$dir/wt" none
  fp_queue "$dir" paused
  rc=0
  out=$(fp_run "$dir" fm-fleet-resume.sh --force --stagger-secs 0) || rc=$?
  expect_code 1 "$rc" "--force goes on but still does not steer a restored agent: $out"
  assert_contains "$out" "going on because of --force (a worker the fleet did not launch is not steered)" "--force should say what still protects"
  assert_equals t2 "$(cat "$dir/log/send")" "--force steers only the fleet-launched worker"
  pass "fm-fleet-resume: refuses across a host restart, and never steers an agent the fleet did not launch"
}

test_a_refused_steer_keeps_the_mark() {
  local dir out rc=0
  dir=$(make_paused refused)
  : > "$dir/knob/send-fails-t1"
  out=$(fp_run "$dir" fm-fleet-resume.sh --stagger-secs 0) || rc=$?
  expect_code 1 "$rc" "a refused steer must fail the resume: $out"
  assert_contains "$out" "error: task t1: NOT steered: bin/fm-send.sh refused or failed (exit 1): error: task t1's live context is past the crew context limit" \
    "the failure should carry what fm-send said"
  assert_contains "$out" "FM_SEND_CONTEXT_CHECK=0" "the failure should name the way past a context-size refusal"
  mark_open "$dir" t1 || fail "a worker whose steer was refused must keep its wait mark"
  ! mark_open "$dir" t2 || fail "the other worker is steered and closed"
  assert_present "$dir/home/state/fleet-pause/jobs.tsv" "the job list is kept for the retry"

  rm -f "$dir/knob/send-fails-t1"
  rc=0
  out=$(fp_run "$dir" fm-fleet-resume.sh --force) || rc=$?
  expect_code 0 "$rc" "the retry should steer the remaining worker: $out"
  assert_contains "$(cat "$dir/log/sent-t1")" "(jobqueue show $JOB_CARGO)" "the retried steer still lists the cut jobs"
  ! mark_open "$dir" t1 || fail "the retried worker's mark should be closed"
  pass "fm-fleet-resume: a steer fm-send refuses fails the run and leaves the mark for a retry"
}

test_refuses_without_a_pause_record
test_dry_run_changes_nothing
test_resume_steers_each_marked_worker_once
test_queue_that_stays_paused_fails_loudly
test_starts_the_queue_daemon_when_it_is_down
test_skips_a_task_held_for_the_captain
test_refuses_after_a_host_restart
test_a_refused_steer_keeps_the_mark
