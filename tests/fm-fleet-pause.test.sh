#!/usr/bin/env bash
# tests/fm-fleet-pause.test.sh - bin/fm-fleet-pause.sh against a fake home.
#
# Hermetic: a temp home, a fake jobqueue, tmux, and systemctl on PATH, a
# substitute /proc and cgroup root, and recording stubs for fm-control.sh and
# fm-send.sh (tests/fleet-pause-helpers.sh owns the world). Pins:
#   1. --dry-run prints what it would do and changes nothing.
#   2. The pause record is written before the queue is asked to pause; the
#      queue's live jobs are saved with what became of them; a mid-turn worker
#      is interrupted and an idle one is not; every worker is marked waiting
#      through the house status writer with a clearing time, and none is sent
#      a message; listed active timers are stopped and recorded; the user
#      service cgroup is asked for its file cache; the last line is the
#      Windows command.
#   3. Running it again is idempotent: no second queue pause, no second
#      interrupt of the same turn, no duplicate mark; a new turn or a lost
#      mark is repaired.
#   4. A worker whose newest status already says finished or owed an answer is
#      left unmarked unless the pause cut a job of its or interrupted it.
#   5. A queue that is already paused is not paused again; a queue with no
#      daemon is reported, not failed.
#   6. A queue that will not pause fails loudly, and the next run retries it.
#   7. A failed interrupt fails the run; an interrupt with nobody to interrupt
#      does not.
#   8. Second mates are reported and not touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fleet-pause-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fleet-pause-helpers.sh"

fp_init fm-fleet-pause
ROOT_CACHE_LINE="wsl -u root -d Ubuntu -- sh -c 'sync; echo 1 > /proc/sys/vm/drop_caches'"

# A fleet at work: one ship mid-turn with two live queue jobs, one idle ship
# waiting on something of its own, a third job belonging to no task of this
# home, one active listed timer and one inactive.
make_fleet() {  # <name> -> echoes the case dir
  local dir
  dir=$(fp_case "$1")
  fp_healthy_task "$dir" t-busy 101
  fp_busy "$dir" t-busy busy
  fp_status "$dir" t-busy 'working: building the thing'
  fp_healthy_task "$dir" t-idle 102
  fp_status "$dir" t-idle 'paused: review candidate until 2099-01-01T00:00Z'
  fp_queue "$dir" running \
    "$(fp_job aaaaaaaa-0000-4000-8000-000000000001 t-busy cargo running)" \
    "$(fp_job aaaaaaaa-0000-4000-8000-000000000002 t-busy gate running test)" \
    "$(fp_job aaaaaaaa-0000-4000-8000-000000000003 other-home general queued)"
  printf '# timers a pause stops\nroadmap.timer\n\nidle.timer\n' > "$dir/home/config/fleet-pause-timers"
  : > "$dir/timers/roadmap.timer"
  printf '%s\n' "$dir"
}

test_dry_run_changes_nothing() {
  local dir before after out rc=0
  dir=$(make_fleet dry)
  before=$(fp_sig "$dir")
  out=$(fp_run "$dir" fm-fleet-pause.sh --dry-run --reason games) || rc=$?
  expect_code 0 "$rc" "a dry run should succeed: $out"
  after=$(fp_sig "$dir")
  assert_equals "$before" "$after" "a dry run must not change the home, the queue, the cgroup, the panes, or the timers"
  assert_absent "$dir/log/jobqueue" "a dry run must not call the queue"
  assert_absent "$dir/log/control" "a dry run must not interrupt anyone"
  assert_equals 0 "$(fp_log_count "$dir/log/systemctl" stop)" "a dry run must not stop a timer"
  assert_contains "$out" "would write state/captain-pause.flag: fleet pause: games 20" "the dry run should print the pause record"
  assert_contains "$out" "would save 3 live job(s) to state/fleet-pause/jobs.tsv" "the dry run should count the live jobs"
  assert_contains "$out" "would run: $FP_SHARED/fakebin/jobqueue pause" "the dry run should print the queue pause"
  assert_contains "$out" "bin/fm-control.sh t-busy interrupt" "the dry run should print the interrupt of the mid-turn worker"
  assert_not_contains "$out" "fm-control.sh t-idle" "the dry run should not plan to interrupt an idle worker"
  assert_contains "$out" "would append to state/t-busy.status: paused [key=fleet-pause]: fleet pause (games)" "the dry run should print the wait mark"
  assert_contains "$out" "would run: systemctl --user stop roadmap.timer" "the dry run should print the timer stop"
  assert_contains "$out" "would write 209715200 to $(fp_reclaim_file "$dir")" "the dry run should print the reclaim request"
  assert_contains "$out" "$ROOT_CACHE_LINE" "the dry run should still print the Windows command"
  pass "fm-fleet-pause: --dry-run prints every step and changes nothing"
}

test_pause_records_first_and_quiesces_the_fleet() {
  local dir out rc=0 flag id line until open now
  dir=$(make_fleet pause)
  out=$(fp_run "$dir" fm-fleet-pause.sh --reason 'games	and
supper') || rc=$?
  expect_code 0 "$rc" "the pause should succeed: $out"

  flag="$dir/home/state/captain-pause.flag"
  assert_present "$flag" "the pause record should exist"
  assert_equals 1 "$(wc -l < "$flag" | tr -d ' ')" "the pause record must stay one line"
  case "$(cat "$flag")" in
    "fleet pause: games and supper 20"[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]Z) ;;
    *) fail "unexpected pause record: $(cat "$flag")" ;;
  esac
  assert_grep "pause: record present" "$dir/log/order" "the record must exist before the queue is asked to pause"
  assert_no_grep "ABSENT" "$dir/log/order" "the queue was paused before the record was written"
  assert_grep "boot_id=boot-A" "$dir/home/state/fleet-pause/pause" "the pause should record the boot it began in"

  jq -e '.paused == true' "$dir/queue/status.json" >/dev/null || fail "the queue should be paused"
  assert_equals 3 "$(grep -vc '^#' "$dir/home/state/fleet-pause/jobs.tsv")" "all three live jobs should be saved"
  assert_equals 3 "$(grep -c 'cancelled/paused$' "$dir/home/state/fleet-pause/jobs.tsv")" "each saved job should carry what became of it"
  assert_grep "$(printf 't-busy\taaaaaaaa-0000-4000-8000-000000000002\tgate\tbash\trunning\ttest')" \
    "$dir/home/state/fleet-pause/jobs.tsv" "a saved job should keep its task, id, class, command, state and phase"

  assert_equals "t-busy interrupt" "$(cat "$dir/log/control")" "only the mid-turn worker is interrupted, once"
  assert_absent "$dir/log/send" "a pause must not message any worker"
  for id in t-busy t-idle; do
    assert_equals 1 "$(fp_mark_count "$dir" "$id")" "$id should carry exactly one wait mark"
    { IFS= read -r line; IFS= read -r until; IFS= read -r open; } <<EOF
$(fp_mark_reading "$dir" "$id")
EOF
    assert_contains "$line" "paused [key=fleet-pause] [at=" "the watcher should read $id's standing wait as the pause mark"
    [ -n "$until" ] || fail "$id's mark carries no clearing time the watcher can read: $line"
    now=$(fp_now)
    [ "$until" -gt "$((now + 39600))" ] || fail "$id's mark should clear about twelve hours out, got $((until - now))s"
    assert_equals open "$open" "$id's mark should be open for the resume to find"
  done
  assert_present "$dir/home/state/.t-busy.home-appends" "the mark must go through the house self-announced status writer"

  assert_absent "$dir/timers/roadmap.timer" "the active listed timer should be stopped"
  assert_equals roadmap.timer "$(cat "$dir/home/state/fleet-pause/timers-stopped")" "only the timer that was stopped is recorded"
  assert_contains "$out" "timers: idle.timer is inactive; left alone" "an inactive listed timer is left alone"
  assert_grep "XDG_RUNTIME_DIR=/run/user/$(id -u) DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$(id -u)/bus" \
    "$dir/log/systemctl-env" "systemctl should get the derived user-manager environment"
  assert_equals 209715200 "$(cat "$(fp_reclaim_file "$dir")")" "the user service cgroup should be asked for its file cache"

  assert_contains "$out" "summary: 2 task(s): 1 interrupted, 2 marked waiting, 0 already marked, 0 left as is; queue paused, 3 live job(s) cut; 1 timer(s) stopped; 0 step(s) failed" \
    "the summary should count what happened"
  assert_equals "$ROOT_CACHE_LINE" "$(printf '%s\n' "$out" | tail -n 1)" "the last line must be the Windows command"
  assert_not_contains "$out" "do-not-print" "nothing from a process environment may be printed"
  assert_absent "$dir/home/state/.fleet-pause.lock" "the lock should be released"
  pass "fm-fleet-pause: record first, queue paused with its jobs saved, workers interrupted and marked, timers and cache handled"
}

test_rerun_is_idempotent_and_repairs() {
  local dir out rc=0 flag record old
  dir=$(make_fleet rerun)
  fp_run "$dir" fm-fleet-pause.sh --reason games >/dev/null || fail "the first pause failed"
  flag="$dir/home/state/captain-pause.flag"
  record=$(cat "$flag")
  old=$(($(fp_now) - 7200))
  fm_touch_epoch "$old" "$flag"

  out=$(fp_run "$dir" fm-fleet-pause.sh --reason 'something else') || rc=$?
  expect_code 0 "$rc" "a second pause should succeed: $out"
  assert_equals "$record" "$(cat "$flag")" "a second run must keep the original record line"
  [ "$(fp_mtime "$flag")" -gt "$((old + 3600))" ] || fail "a second run should refresh the record's age"
  assert_equals 1 "$(fp_log_count "$dir/log/jobqueue" pause)" "a paused queue must not be paused again"
  assert_equals 1 "$(wc -l < "$dir/log/control" | tr -d ' ')" "the same turn must not be interrupted twice"
  assert_equals 1 "$(fp_mark_count "$dir" t-busy)" "a standing mark must not be appended again"
  assert_equals 1 "$(fp_mark_count "$dir" t-idle)" "a standing mark must not be appended again"
  assert_equals 3 "$(grep -vc '^#' "$dir/home/state/fleet-pause/jobs.tsv")" "the saved jobs must survive a second run"
  assert_contains "$out" "queue: already paused (reason paused); not pausing it again" "the second run should say the queue is already paused"
  assert_contains "$out" "task t-busy: mid-turn, already interrupted by this pause; not interrupted twice; already marked waiting; 2 queue job(s) cut" \
    "the second run should say why it left the mid-turn worker alone"
  assert_contains "$out" "timers: roadmap.timer already stopped by this pause" "the second run should recognise its own stopped timer"

  # A new turn started after the interrupt, and a worker wrote over its mark.
  fp_busy "$dir" t-busy busy "" 9
  fp_status "$dir" t-idle 'working: carried on anyway'
  rc=0
  out=$(fp_run "$dir" fm-fleet-pause.sh) || rc=$?
  expect_code 0 "$rc" "a repairing pause should succeed: $out"
  assert_equals 2 "$(wc -l < "$dir/log/control" | tr -d ' ')" "a turn that began after the interrupt should be interrupted"
  assert_equals 2 "$(fp_mark_count "$dir" t-idle)" "a mark the worker wrote over should be appended again"
  assert_equals 1 "$(fp_mark_count "$dir" t-busy)" "an untouched mark stays single"
  assert_contains "$(tail -n 1 "$dir/home/state/t-idle.status")" "fleet pause (games)" "a repaired mark keeps the pause's recorded reason"
  pass "fm-fleet-pause: a second run pauses and interrupts nothing twice, and repairs a new turn and a lost mark"
}

test_settled_workers_are_left_as_they_are() {
  local dir out rc=0
  dir=$(fp_case settled)
  fp_healthy_task "$dir" t-done 201
  fp_status "$dir" t-done 'done: branch ready at abc123'
  fp_healthy_task "$dir" t-ask 202
  fp_status "$dir" t-ask 'needs-decision [key=shape]: REST or RPC?'
  fp_healthy_task "$dir" t-held 203
  fp_status "$dir" t-held 'captain-held [key=shape]: held as task q1'
  fp_healthy_task "$dir" t-donejob 204
  fp_status "$dir" t-donejob 'done: branch ready at def456'
  fp_healthy_task "$dir" t-resolved 205
  fp_status "$dir" t-resolved 'paused: job 7' 'resolved: job 7 passed'
  fp_healthy_task "$dir" t-new 206
  fp_queue "$dir" running "$(fp_job bbbbbbbb-0000-4000-8000-000000000001 t-donejob cargo running)"

  out=$(fp_run "$dir" fm-fleet-pause.sh) || rc=$?
  expect_code 0 "$rc" "the pause should succeed: $out"
  for id in t-done t-ask t-held; do
    assert_equals 0 "$(fp_mark_count "$dir" "$id")" "$id is settled and idle, so it must not be marked"
  done
  assert_contains "$out" "task t-done: idle (pi-ext); left as is (newest status is done)" "a finished worker should be reported as left alone"
  assert_contains "$out" "task t-ask: idle (pi-ext); left as is (newest status is needs-decision)" "a worker owed a decision should be left alone"
  assert_contains "$out" "task t-held: idle (pi-ext); left as is (newest status is captain-held)" "a captain-held worker should be left alone"
  assert_equals 1 "$(fp_mark_count "$dir" t-donejob)" "a finished worker whose job the pause cut must be marked, so the resume tells it"
  assert_equals 1 "$(fp_mark_count "$dir" t-resolved)" "a worker whose newest event is resolved would alarm, so it is marked"
  assert_equals 1 "$(fp_mark_count "$dir" t-new)" "a worker with no status yet is marked"
  assert_contains "$out" "summary: 6 task(s): 0 interrupted, 3 marked waiting, 0 already marked, 3 left as is" "the summary should count the unmarked workers"
  assert_grep "fleet pause (captain order)" "$dir/home/state/t-new.status" "an unnamed pause should mark with the default reason"
  pass "fm-fleet-pause: a finished or answer-owed idle worker keeps its own newest status"
}

test_queue_already_paused_or_without_a_daemon() {
  local dir out rc=0
  dir=$(fp_case prepaused)
  fp_healthy_task "$dir" t1 301
  fp_queue "$dir" paused
  out=$(fp_run "$dir" fm-fleet-pause.sh) || rc=$?
  expect_code 0 "$rc" "pausing over a paused queue should succeed: $out"
  assert_absent "$dir/log/jobqueue" "a queue that is already paused must not be paused again"
  assert_grep "# incomplete" "$dir/home/state/fleet-pause/jobs.tsv" "jobs cut before the command ran must be recorded as unknown"
  assert_contains "$out" "the jobs that pause cut are not recorded" "the operator should be told the job list is incomplete"

  dir=$(fp_case nodaemon)
  fp_healthy_task "$dir" t1 302
  fp_queue "$dir" running "$(fp_job cccccccc-0000-4000-8000-000000000001 t1 cargo running)"
  fp_queue_gone "$dir"
  rc=0
  out=$(fp_run "$dir" fm-fleet-pause.sh) || rc=$?
  expect_code 0 "$rc" "pausing with no queue daemon should succeed: $out"
  assert_absent "$dir/log/jobqueue" "a queue with no daemon cannot be asked to pause"
  assert_present "$dir/home/state/captain-pause.flag" "the pause record is still written"
  assert_equals 1 "$(fp_mark_count "$dir" t1)" "the worker is still marked"
  assert_contains "$out" "queue: queue daemon (pid $FP_DAEMON_PID) is not running" "the operator should be told the daemon is down"
  assert_absent "$dir/home/state/fleet-pause/jobs.tsv" "a dead daemon's stale job list must not be saved as jobs the pause cut"

  dir=$(fp_case otherboot)
  fp_healthy_task "$dir" t1 303
  fp_queue "$dir" running
  fp_boot "$dir" boot-B
  rc=0
  out=$(fp_run "$dir" fm-fleet-pause.sh) || rc=$?
  expect_code 0 "$rc" "pausing after a restart should succeed: $out"
  assert_contains "$out" "queue: queue daemon has not run in this boot" "a snapshot from another boot must not be trusted"
  assert_grep "boot_id=boot-B" "$dir/home/state/fleet-pause/pause" "the pause records the boot it began in"
  pass "fm-fleet-pause: a paused queue is not paused twice, and a queue with no daemon is reported, not failed"
}

test_queue_that_will_not_pause_fails_loudly_and_is_retried() {
  local dir out rc=0
  dir=$(make_fleet stubborn)
  : > "$dir/knob/pause-fails"
  out=$(fp_run "$dir" fm-fleet-pause.sh) || rc=$?
  expect_code 1 "$rc" "a queue that did not pause must fail the run: $out"
  assert_contains "$out" "error: queue: NOT paused (jobqueue pause exit 125" "the failure should name the queue and the exit"
  assert_contains "$out" "QUEUE NOT PAUSED" "the summary should say the queue is not paused"
  assert_present "$dir/home/state/captain-pause.flag" "the pause record stands even when the queue step failed"
  assert_equals 1 "$(fp_mark_count "$dir" t-idle)" "the workers are still marked"
  assert_equals 3 "$(grep -c 'unknown$' "$dir/home/state/fleet-pause/jobs.tsv")" "the live jobs are saved before the pause is attempted"

  rm -f "$dir/knob/pause-fails"
  rc=0
  out=$(fp_run "$dir" fm-fleet-pause.sh) || rc=$?
  expect_code 0 "$rc" "the retry should succeed: $out"
  assert_equals 2 "$(fp_log_count "$dir/log/jobqueue" pause)" "the retry should ask the queue again"
  assert_equals 3 "$(grep -c 'cancelled/paused$' "$dir/home/state/fleet-pause/jobs.tsv")" "the retry should settle what became of the saved jobs"
  assert_equals 1 "$(wc -l < "$dir/log/control" | tr -d ' ')" "the retry must not interrupt the same turn again"
  assert_equals 1 "$(fp_mark_count "$dir" t-busy)" "the retry must not mark twice"
  pass "fm-fleet-pause: a queue that will not pause fails the run, and running it again finishes the pause"
}

test_interrupt_failures() {
  local dir out rc=0
  dir=$(fp_case intfail)
  fp_healthy_task "$dir" t-busy 101
  fp_busy "$dir" t-busy busy
  : > "$dir/knob/interrupt-fails-t-busy"
  out=$(fp_run "$dir" fm-fleet-pause.sh) || rc=$?
  expect_code 1 "$rc" "a mid-turn worker that was not interrupted must fail the run: $out"
  assert_contains "$out" "error: task t-busy: mid-turn and NOT interrupted (fm-control exit 1): error: interrupt key Escape was not delivered" \
    "the failure should carry what the control plane said"
  assert_equals 1 "$(fp_mark_count "$dir" t-busy)" "the worker is still marked"
  assert_absent "$dir/home/state/fleet-pause/interrupted" "a failed interrupt must not be recorded as done"

  # The retry finds the same turn still unrecorded and tries again; this time
  # the control plane says the agent is gone.
  rm -f "$dir/knob/interrupt-fails-t-busy"
  : > "$dir/knob/interrupt-noagent-t-busy"
  rc=0
  out=$(fp_run "$dir" fm-fleet-pause.sh) || rc=$?
  expect_code 0 "$rc" "a stale busy record with no agent behind it is not a failure: $out"
  assert_equals 2 "$(fp_log_count "$dir/log/control" "t-busy interrupt")" "a turn whose interrupt failed is tried again"
  assert_contains "$out" "task t-busy: its busy record says mid-turn, but no agent is running in its endpoint; already marked waiting" \
    "the report should say nobody was there to interrupt"
  assert_absent "$dir/home/state/fleet-pause/interrupted" "an interrupt that reached nobody is not recorded either"
  pass "fm-fleet-pause: a failed interrupt fails the run; an interrupt with nobody to interrupt does not"
}

test_second_mates_and_usage() {
  local dir out rc=0
  dir=$(fp_case mates)
  fp_add_task "$dir" mate-local secondmate claude
  fp_busy "$dir" mate-local busy
  fp_add_task "$dir" mate-far secondmate claude
  printf 'remote_host=vps\n' >> "$dir/home/state/mate-far.meta"
  out=$(fp_run "$dir" fm-fleet-pause.sh) || rc=$?
  expect_code 0 "$rc" "a home with only second mates should pause: $out"
  assert_absent "$dir/log/control" "a second mate is never interrupted by a fleet pause"
  assert_absent "$dir/home/state/mate-local.status" "a second mate is never marked by a fleet pause"
  assert_contains "$out" "second mate mate-local: home $dir/wt/mate-local; not paused by this command" "a local second mate should be reported"
  assert_contains "$out" "second mate mate-far: on host vps; not paused by this command" "a remote second mate should be reported"
  assert_contains "$out" "tasks: this home records no ship or scout" "the report should say there was no crew"
  assert_contains "$out" "timers: none listed (config/fleet-pause-timers is absent)" "an absent timer list means none"

  rc=0
  out=$(fp_run "$dir" fm-fleet-pause.sh --bogus) || rc=$?
  expect_code 2 "$rc" "an unknown option is a usage error"
  rc=0
  out=$(fp_run "$dir" fm-fleet-pause.sh --reason) || rc=$?
  expect_code 2 "$rc" "--reason without a value is a usage error"
  out=$(fp_run "$dir" fm-fleet-pause.sh --help) || fail "--help should succeed"
  assert_contains "$out" "Usage: fm-fleet-pause.sh [--dry-run] [--reason <text>]" "--help should print the header"

  if [ -e /proc/sys/vm/drop_caches ]; then
    out=$(FP_WSL_DISTRO='' fp_run "$dir" fm-fleet-pause.sh --dry-run) || fail "a pause outside WSL should succeed"
    assert_equals "sh -c 'sync; echo 1 > /proc/sys/vm/drop_caches'" "$(printf '%s\n' "$out" | tail -n 1)" \
      "outside WSL the last line is the root command for this host"
  fi
  pass "fm-fleet-pause: second mates are reported and not touched; usage errors exit 2"
}

test_dry_run_changes_nothing
test_pause_records_first_and_quiesces_the_fleet
test_rerun_is_idempotent_and_repairs
test_settled_workers_are_left_as_they_are
test_queue_already_paused_or_without_a_daemon
test_queue_that_will_not_pause_fails_loudly_and_is_retried
test_interrupt_failures
test_second_mates_and_usage
