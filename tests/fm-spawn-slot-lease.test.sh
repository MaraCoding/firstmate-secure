#!/usr/bin/env bash
# Regression tests for a Treehouse pool slot whose interactive lease lapsed
# while its task was still live.
#
# The pane-driven `treehouse get` holds a slot only through a process lease, so
# a long-paused worker whose pane no longer runs anything in the slot reads as
# free, and the next spawn on the project was handed that slot (seen live:
# teve-evo-content-inventory landed on teve-seamless-world's slot 1 after a 26 h
# pause and reset it to a detached HEAD). These tests drive the real spawn path
# against a stateful pool stand-in and prove that spawn durably leases every
# slot a live task record names before allocating, and that a slot Treehouse
# hands out anyway is refused without disturbing the live task's claim.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-slot-lease)

# A project with an origin and two managed Treehouse slots laid out as
# <pool>/<slot>/project beside the pool's state file.
make_pool_case() {  # <name> <id>...
  local name=$1 case_dir home project origin slots fakebin initial id
  shift
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  slots="$case_dir/slots"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/projects" "$home/state" "$home/config" "$slots/1" "$slots/2"
  printf 'codex\n' > "$home/config/crew-harness"
  for id in "$@"; do fm_test_spawn_brief "$home" "$id"; done
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" fetch --quiet origin
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$slots/1/project" "$initial"
  git -C "$project" worktree add --quiet --detach "$slots/2/project" "$initial"
  printf '{"worktrees":[{"name":"1","path":"%s"},{"name":"2","path":"%s"}]}\n' \
    "$slots/1/project" "$slots/2/project" > "$slots/treehouse-state.json"

  install_lease_world "$fakebin" "$case_dir/tmux-world" "$slots" "$case_dir/treehouse.log"
  CASE_DIR=$case_dir HOME_DIR=$home PROJECT_DIR=$project SLOTS=$slots FAKEBIN_DIR=$fakebin
}

# A stateful terminal and Treehouse stand-in. Each window is a file recording
# its stable id and the path its shell sits in. A `treehouse get` typed into a
# window moves it into the lowest slot that no live window sits in and that
# carries no durable lease - the two things real Treehouse honours. The fake
# `treehouse lease <path> --lease-holder <id>` records a durable lease beside
# the slot, refuses an already-leased slot the way Treehouse does, and with
# FM_FAKE_TREEHOUSE_NO_LEASE=1 behaves like a Treehouse without the subcommand.
install_lease_world() {  # <fakebin> <world-dir> <slot-root> <log>
  local fakebin=$1 world=$2 slots=$3 log=$4
  mkdir -p "$world"
  cat > "$fakebin/tmux" <<SH
#!/usr/bin/env bash
set -u
world='$world'
slots='$slots'
SH
  cat >> "$fakebin/tmux" <<'SH'
window_name() {  # <target>
  local t=${1#=}
  t=${t#*:}
  t=${t#=}
  case "$t" in
    @*) grep -lxF -- "$t" "$world"/*.id 2>/dev/null | head -n 1 | sed 's|.*/||; s|\.id$||' ;;
    *) printf '%s' "$t" ;;
  esac
}
target= name= cwd= text=
cmd=${1:-}
[ "$#" -eq 0 ] || shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    -t) target=$2; shift 2 ;;
    -n) name=$2; shift 2 ;;
    -c) cwd=$2; shift 2 ;;
    -F) shift 2 ;;
    -*) shift ;;
    *) text="$text${text:+ }$1"; shift ;;
  esac
done
case "$cmd" in
  display-message)
    case "$text" in
      *pane_current_path*) cat "$world/$(window_name "$target").path" 2>/dev/null ;;
      *) printf 'firstmate\n' ;;
    esac
    ;;
  list-windows)
    for f in "$world"/*.id; do [ -e "$f" ] || continue; f=${f##*/}; printf '%s\n' "${f%.id}"; done
    ;;
  new-window)
    n=$(( $(cat "$world/.next" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$n" > "$world/.next"
    printf '@%s\n' "$n" > "$world/$name.id"
    printf '%s\n' "$cwd" > "$world/$name.path"
    printf '@%s\n' "$n"
    ;;
  kill-window)
    w=$(window_name "$target")
    rm -f "$world/$w.id" "$world/$w.path"
    ;;
  send-keys)
    if [ "$text" = "treehouse get Enter" ]; then
      w=$(window_name "$target")
      for slot in "$slots"/*/project; do
        grep -qxF -- "$slot" "$world"/*.path 2>/dev/null && continue
        [ -e "$(dirname "$slot")/.leased" ] && continue
        printf '%s\n' "$slot" > "$world/$w.path"
        break
      done
    fi
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$log'
slots='$slots'
SH
  cat >> "$fakebin/treehouse" <<'SH'
[ "${1:-}" = lease ] || exit 0
if [ "${FM_FAKE_TREEHOUSE_NO_LEASE:-0}" = 1 ]; then
  echo 'Error: unknown command "lease" for "treehouse"' >&2
  exit 1
fi
name=$2 holder=
[ "${3:-}" = --lease-holder ] && holder=${4:-}
path="$slots/$name/project"
[ -d "$path" ] || { echo "Error: no worktree named \"$name\" in pool" >&2; exit 1; }
marker="$slots/$name/.leased"
if [ -e "$marker" ]; then
  echo "Error: worktree $path is already leased (holder: \"$(cat "$marker")\")" >&2
  exit 1
fi
printf '%s\n' "$holder" > "$marker"
printf '%s\n' "$path"
SH
  chmod +x "$fakebin/treehouse"
}

run_spawn() {  # <id> [args...]
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$PROJECT_DIR" "$FAKEBIN_DIR" "$id" "$PROJECT_DIR" "$@"
}

# The first task takes slot 1, then its pane stops running anything there: the
# interactive process lease lapses while the task record, claim and branch stay.
spawn_live_task_then_lapse() {  # <id>
  local id=$1 out status
  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "the first task should launch"$'\n'"$out"
  assert_grep "worktree=$SLOTS/1/project" "$HOME_DIR/state/$id.meta" \
    "the first task did not land on slot 1"
  grep -Fxq -- "task=$id" "$SLOTS/1/.fm-slot-owner" || fail "slot 1 is not claimed by $id"
  rm -f "$SLOTS/1/.leased"
  rm -f "$CASE_DIR/tmux-world/fm-$id.id" "$CASE_DIR/tmux-world/fm-$id.path"
}

test_lapsed_slot_is_leased_before_the_next_allocation() {
  local first='lease-live-a' second='lease-next-b' out status
  rm -rf "/tmp/fm-$first" "/tmp/fm-$second"
  make_pool_case lapsed-leased "$first" "$second"
  spawn_live_task_then_lapse "$first"

  out=$(run_spawn "$second" --scout)
  status=$?
  expect_code 0 "$status" "the second task should launch on a free slot"$'\n'"$out"
  assert_grep "worktree=$SLOTS/2/project" "$HOME_DIR/state/$second.meta" \
    "the second task was handed the live task's lapsed slot"
  grep -Fxq -- "lease 1 --lease-holder $first" "$CASE_DIR/treehouse.log" \
    || fail "spawn did not durably lease the live task's slot: $(cat "$CASE_DIR/treehouse.log")"
  grep -Fxq -- "$first" "$SLOTS/1/.leased" || fail "slot 1's durable lease does not name $first"
  grep -Fxq -- "task=$first" "$SLOTS/1/.fm-slot-owner" \
    || fail "slot 1's claim no longer names the live task: $(cat "$SLOTS/1/.fm-slot-owner")"
  grep -Fxq -- "task=$second" "$SLOTS/2/.fm-slot-owner" || fail "slot 2 is not claimed by $second"
  assert_not_contains "$out" "could not durably lease" "a successful lease still warned"
  rm -rf "/tmp/fm-$first" "/tmp/fm-$second" "/tmp/fm-$first+"* "/tmp/fm-$second+"*
  pass "a live task's lapsed slot is durably leased before the next spawn allocates"
}

test_already_leased_slot_is_not_a_warning() {
  local first='lease-held-a' second='lease-held-b' out status
  rm -rf "/tmp/fm-$first" "/tmp/fm-$second"
  make_pool_case already-leased "$first" "$second"
  spawn_live_task_then_lapse "$first"
  printf '%s\n' "$first" > "$SLOTS/1/.leased"

  out=$(run_spawn "$second" --scout)
  status=$?
  expect_code 0 "$status" "the second task should launch beside an already-leased slot"$'\n'"$out"
  assert_grep "worktree=$SLOTS/2/project" "$HOME_DIR/state/$second.meta" \
    "the second task was not placed on the free slot"
  assert_not_contains "$out" "could not durably lease" "an already-leased slot was reported as a failure"
  rm -rf "/tmp/fm-$first" "/tmp/fm-$second" "/tmp/fm-$first+"* "/tmp/fm-$second+"*
  pass "a slot Treehouse already holds under a durable lease counts as leased"
}

test_double_issued_slot_is_refused_without_touching_the_live_claim() {
  local first='lease-old-a' second='lease-old-b' out status
  rm -rf "/tmp/fm-$first" "/tmp/fm-$second"
  make_pool_case double-issued "$first" "$second"
  spawn_live_task_then_lapse "$first"

  out=$(FM_FAKE_TREEHOUSE_NO_LEASE=1 run_spawn "$second" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched a second worker into a live task's slot"$'\n'"$out"
  assert_contains "$out" "could not durably lease pool slot $SLOTS/1/project for live task $first" \
    "a failed lease was not reported"
  assert_contains "$out" "live task $first still holds it" \
    "the refusal did not name the live holder"$'\n'"$out"
  [ ! -e "$HOME_DIR/state/$second.meta" ] || fail "spawn published a record for a double-issued slot"
  grep -Fxq -- "task=$first" "$SLOTS/1/.fm-slot-owner" \
    || fail "the refused spawn replaced the live task's claim: $(cat "$SLOTS/1/.fm-slot-owner")"
  assert_grep "worktree=$SLOTS/1/project" "$HOME_DIR/state/$first.meta" \
    "the live task's record was disturbed"
  rm -rf "/tmp/fm-$first" "/tmp/fm-$second" "/tmp/fm-$first+"* "/tmp/fm-$second+"*
  pass "a slot Treehouse double-issues to a new task is refused and the live claim survives"
}

test_lapsed_slot_is_leased_before_the_next_allocation
test_already_leased_slot_is_not_a_warning
test_double_issued_slot_is_refused_without_touching_the_live_claim

echo "# all fm-spawn-slot-lease tests passed"
