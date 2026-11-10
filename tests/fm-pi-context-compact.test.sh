#!/usr/bin/env bash
# tests/fm-pi-context-compact.test.sh - the opt-in context bound in the per-task
# Pi extension (config/crew-context-compact-at; docs/configuration.md "Crew
# context limit").
#
# These tests run the REAL fm-spawn against a fake tmux pane and an isolated git
# worktree, then read and drive the extension it wrote in a plain Node host, with
# no live harness session. Pins:
#   1. With no knob the extension is its base text, byte for byte (the rendering
#      below is that text), and a malformed threshold only warns.
#   2. With the knob the threshold is baked in, nothing outside the bound's own
#      block changes, and the bound asks Pi to compact only once Pi has settled
#      idle past the threshold, at most once per interval.
#   3. FM_CREW_CONTEXT_COMPACT_AT overrides the file for one launch, the bound
#      covers a scout as it does a ship, and a secondmate's extension never
#      carries it.
#   4. Both forms load through Pi's own extension loader. That part skips,
#      visibly, on a host with no installed Pi.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-context-compact)
# The bound is set per case below; an operator's own one-launch override must
# not reach the cases that pin the extension without it.
unset FM_CREW_CONTEXT_COMPACT_AT

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" pi)
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  # A ship spawn carries an explicit delivery contract (AGENTS.md section 7);
  # these tests are about the extension, so they pass a fixed valid one.
  local home=$1 wt=$2 fakebin=$3
  shift 3
  GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

classify() {  # <harness> <id> <state-dir>
  fm_busy_classify tmux fake:w "$1" "$2" "$3"
}

# render_base_pi_ext <dest> <home> <id>: the per-task Pi extension exactly as
# fm-spawn writes it for a ship with no config/crew-context-compact-at, rendered
# for one spawned fixture. This is the pinned base text the opt-in bound must
# leave byte-identical; a deliberate change to the base extension updates this
# rendering in the same change. Fixture paths are plain, so each reads the same
# raw as it does JSON-encoded.
render_base_pi_ext() {
  local dest=$1 home=$2 id=$3 state gen
  state=$(cd "$home/state" && pwd -P) || fail "cannot resolve state dir $home/state"
  gen=$(cat "$home/state/$id.busy-gen") || fail "spawn left no busy generation for $id"
  cat > "$dest" <<EOF
// Firstmate semantic busy-state events + turn-end notification; written by
// fm-spawn under the contract owned by bin/fm-busy-lib.sh.
// Semantic state: "agent_start" -> busy when a low-level agent run begins;
// "agent_settled" -> idle only when ctx.isIdle() confirms Pi will not
// continue automatically - auto-retries, auto-compaction retries, tool
// loops, and queued continuations all keep the run un-settled, and a settle
// that raced another extension's fresh run keeps state busy via isIdle().
// "turn_end" fires at every inner turn boundary (one LLM response plus its
// tool calls) and stays a wake NOTIFICATION touch for the watcher, never
// current-state truth.
import { execFile } from "node:child_process";
import { appendFileSync } from "node:fs";
const notifyTurnEnd = true;
const excludeTools = "".split(",").filter(Boolean);
const excludeFile = "$home/config/crew-exclude-tools";
const statusFile = "$home/state/$id.status";
const busyEvent = (state: string, event: string) =>
  new Promise<void>((resolve) => {
    execFile("$ROOT/bin/fm-busy-event.sh", [
      "apply", "$state", "$id", state,
      "--gen", "$gen", "--source", "pi-ext", "--event", event,
    ], () => resolve());
  });
export default function (pi: any) {
  let checkedExclusions = false;
  pi.on("agent_start", async () => {
    await busyEvent("busy", "agent-start");
    // Verify only this worker's registry, never connect servers from Firstmate.
    // Check before actions so the warning cannot supersede this turn's terminal status.
    if (!checkedExclusions && excludeTools.length) {
      const loaded = new Set(pi.getAllTools().map((tool: any) => tool.name));
      const unmatched = excludeTools.filter((name) => !loaded.has(name));
      if (unmatched.length) {
        appendFileSync(statusFile, "note [at=" + Math.floor(Date.now() / 1000) + "]: warning: " + excludeFile
          + " unmatched exclusion entries (unverified: absent from the worker's loaded-tool registry; excluded tools or unavailable servers cannot be verified): "
          + unmatched.join(", ") + "\n");
      }
      checkedExclusions = true;
    }
  });
  pi.on("agent_settled", (_event: any, ctx: any) => {
    if (ctx && typeof ctx.isIdle === "function" && !ctx.isIdle()) return;
    return busyEvent("idle", "agent-settled");
  });
  pi.on("turn_end", () => { if (notifyTurnEnd) execFile("touch", ["$state/$id.turn-ended"]); });
  // A native harness can make progress inside one Pi turn. This separate
  // marker prevents false wedge alarms without fabricating a completed turn.
  let lastProgress = 0;
  pi.events?.on?.("codex-native:progress", () => {
    const now = Date.now();
    if (now - lastProgress < 1000) return;
    lastProgress = now;
    execFile("$ROOT/bin/fm-busy-event.sh", [
      "progress", "$state", "$id", "--gen", "$gen",
    ]);
  });
}
EOF
}

# assert_base_pi_ext <ext-path> <home> <id> <expected-scratch> <message>
assert_base_pi_ext() {
  render_base_pi_ext "$4" "$2" "$3"
  cmp -s "$4" "$1" || fail "$5:"$'\n'"$(diff "$4" "$1")"
}

# pi_package_dir: the installed Pi package, or nothing. FM_PI_PACKAGE_DIR and
# the global npm root are the suite's usual lookups; the package that owns the
# pi on PATH covers an install outside that root.
pi_package_dir() {
  local dir pi_bin
  for dir in "${FM_PI_PACKAGE_DIR:-}" "$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"; do
    if [ -n "$dir" ] && [ -f "$dir/package.json" ]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  pi_bin=$(command -v pi 2>/dev/null) || return 1
  dir=$(PI_BIN="$pi_bin" node -e '
    const fs = require("node:fs"), path = require("node:path");
    let dir = path.dirname(fs.realpathSync(process.env.PI_BIN));
    for (; dir !== path.dirname(dir); dir = path.dirname(dir)) {
      try {
        const manifest = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
        if (manifest.name === "@earendil-works/pi-coding-agent") {
          console.log(dir);
          break;
        }
      } catch {}
    }' 2>/dev/null) || return 1
  [ -n "$dir" ] || return 1
  printf '%s\n' "$dir"
}

# load_through_pi_loader <pi-package-dir> <ext-path>: load an extension file the
# way Pi does - the jiti that ships in Pi's own dependencies, created against
# dist/core/extensions/loader.js with the module cache off as Pi sets it - and
# print the handler names its factory registers, in order. The on-disk cache is
# off too, so every run transpiles the file and leaves nothing behind. Exit 3
# when that loader cannot be found.
load_through_pi_loader() {
  PI_PACKAGE_DIR="$1" EXT_PATH="$2" node --input-type=module 2>&1 <<'EOF'
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { pathToFileURL } from "node:url";
const loader = join(process.env.PI_PACKAGE_DIR, "dist/core/extensions/loader.js");
let createJiti;
try {
  const jitiPackage = createRequire(loader).resolve("jiti/package.json");
  const entry = JSON.parse(readFileSync(jitiPackage, "utf8")).exports["./static"].import;
  ({ createJiti } = await import(pathToFileURL(join(dirname(jitiPackage), entry)).href));
} catch (error) {
  console.log(String((error && error.message) || error).split("\n")[0]);
  process.exit(3);
}
const jiti = createJiti(pathToFileURL(loader).href, { moduleCache: false, fsCache: false });
const factory = await jiti.import(process.env.EXT_PATH, { default: true });
if (typeof factory !== "function") throw new Error("the default export is not a factory function");
const names = [];
factory({ on: (name) => { names.push(name); }, events: { on() {} }, getAllTools: () => [] });
console.log(names.join(","));
EOF
}


# drive_pi_agent_start <ext-path>: fire the busy-state agent_start handler.
drive_pi_agent_start() {
  EXT_PATH="$1" node --input-type=module 2>&1 <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({ on: (name, fn) => { (handlers[name] ||= []).push(fn); }, events: { on() {} }, getAllTools: () => [] });
for (const fn of handlers.agent_start) await fn({}, { isIdle: () => false });
EOF
}

# drive_pi_context_bound <ext-path> <threshold>: load the generated extension in
# a plain Node host that keeps every handler registered for an event, as Pi
# does, and walk the bound through its cases against a scripted ctx and clock.
drive_pi_context_bound() {
  EXT_PATH="$1" THRESHOLD="$2" node --input-type=module 2>&1 <<'EOF'
import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT_PATH).href);
const handlers = {};
mod.default({
  on: (name, fn) => { (handlers[name] ||= []).push(fn); },
  events: { on() {} },
  getAllTools: () => [],
});
assert.equal(handlers.agent_settled.length, 2, "the bound adds its own agent_settled handler after the busy-state one");
const threshold = Number(process.env.THRESHOLD);
let compactions = 0;
let now = 1_800_000_000_000;
Date.now = () => now;
const settle = async (ctx) => { for (const fn of handlers.agent_settled) await fn({}, ctx); };
const ctx = (tokens, idle = true) => ({
  isIdle: () => idle,
  getContextUsage: () => (tokens === undefined ? undefined : { tokens, contextWindow: 500000, percent: null }),
  compact: () => { compactions += 1; },
});
await settle(ctx(threshold));
assert.equal(compactions, 0, "a session at the threshold is not past it");
await settle(ctx(null));
assert.equal(compactions, 0, "an unknown size, as right after a compaction, must not compact");
await settle(ctx(undefined));
assert.equal(compactions, 0, "no usage at all must not compact");
await settle(ctx(threshold + 1, false));
assert.equal(compactions, 0, "a run still in flight must never be compacted");
await settle(ctx(threshold + 1));
assert.equal(compactions, 1, "past the threshold and settled idle compacts once");
await settle(ctx(threshold + 50000));
assert.equal(compactions, 1, "a second request inside the interval is suppressed");
now += 599_999;
await settle(ctx(threshold + 50000));
assert.equal(compactions, 1, "the interval has not passed yet");
now += 1;
await settle(ctx(threshold + 50000));
assert.equal(compactions, 2, "after the interval a session still past the threshold may compact again");
// A ctx without the compaction API (an older Pi) and one whose usage read
// throws must both leave the lifecycle handlers working.
now += 3_600_000;
await settle({ isIdle: () => true });
await settle({
  isIdle: () => true,
  compact: () => { compactions += 1; },
  getContextUsage: () => { throw new Error("usage unavailable"); },
});
assert.equal(compactions, 2, "a failing usage read must not compact");
EOF
}

test_extension_without_the_bound_is_its_base_text() {
  local rec id=ctx-pi-base out ext
  rec=$(make_spawn_case base pi "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn should succeed: $out"
  ext="$HOME_DIR/state/$id.pi-ext.ts"
  assert_present "$ext" "pi spawn did not write the per-task extension"
  assert_base_pi_ext "$ext" "$HOME_DIR" "$id" "$CASE_DIR/expected.ts" \
    "with no config/crew-context-compact-at the Pi extension must stay byte-identical to its base text"
  cp "$ext" "$TMP_ROOT/base.pi-ext.ts"
  pass "pi extension without config/crew-context-compact-at is byte-identical to its base text"
}

test_malformed_threshold_warns_and_launches_the_base_text() {
  local rec id=ctx-pi-malformed out
  rec=$(make_spawn_case malformed pi "$id")
  read_case_record "$rec"
  printf '230k\n' > "$HOME_DIR/config/crew-context-compact-at"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "a malformed config/crew-context-compact-at must not refuse the launch: $out"
  assert_contains "$out" "warning: config/crew-context-compact-at must hold one positive integer token count" \
    "a malformed threshold should be reported on the spawn"
  assert_base_pi_ext "$HOME_DIR/state/$id.pi-ext.ts" "$HOME_DIR" "$id" "$CASE_DIR/expected.ts" \
    "a malformed config/crew-context-compact-at must leave the base Pi extension"
  pass "a malformed context-bound threshold warns and launches the worker on the base extension"
}

test_bound_is_baked_in_and_compacts_only_when_settled_idle() {
  local rec id=ctx-pi-bound out state ext block_at
  rec=$(make_spawn_case bound pi "$id")
  read_case_record "$rec"
  printf '230000\n' > "$HOME_DIR/config/crew-context-compact-at"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "pi spawn with a context bound should succeed: $out"
  assert_not_contains "$out" "warning: config/crew-context-compact-at" "a valid threshold must not warn"
  state="$HOME_DIR/state"
  ext="$state/$id.pi-ext.ts"
  assert_grep "  const compactAtTokens = 230000;" "$ext" "the threshold was not baked into the extension"

  # Everything outside the bound's own block is the base text, byte for byte.
  block_at=$(grep -n '^  // Opt-in context bound' "$ext" | cut -d: -f1)
  [ -n "$block_at" ] || fail "the bound's block is not marked in the extension"
  { head -n "$((block_at - 1))" "$ext"; printf '}\n'; } > "$CASE_DIR/without-block.ts"
  assert_base_pi_ext "$CASE_DIR/without-block.ts" "$HOME_DIR" "$id" "$CASE_DIR/expected.ts" \
    "the context bound changed the extension outside its own block"
  cp "$ext" "$TMP_ROOT/bound.pi-ext.ts"

  out=$(drive_pi_context_bound "$ext" 230000) || fail "context bound drive failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "idle pi-ext" ] || fail "the bound must leave the settle's idle record intact, got '$out'"
  out=$(drive_pi_agent_start "$ext") || fail "agent_start drive with a context bound failed: $out"
  out=$(classify pi "$id" "$state")
  [ "$out" = "busy pi-ext" ] || fail "agent_start must still classify busy with a context bound, got '$out'"
  pass "pi extension compacts past config/crew-context-compact-at only when settled idle, once per interval"
}

test_one_launch_override_reaches_a_scout() {
  local rec id=ctx-pi-scout out
  rec=$(make_spawn_case scout pi "$id")
  read_case_record "$rec"
  printf '230000\n' > "$HOME_DIR/config/crew-context-compact-at"
  out=$(FM_CREW_CONTEXT_COMPACT_AT=180000 GROK_HOME="$HOME_DIR/grok-home" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" --scout)
  expect_code 0 $? "pi scout spawn with a one-launch context bound should succeed: $out"
  assert_grep "  const compactAtTokens = 180000;" "$HOME_DIR/state/$id.pi-ext.ts" \
    "FM_CREW_CONTEXT_COMPACT_AT did not override config/crew-context-compact-at on a scout"
  pass "FM_CREW_CONTEXT_COMPACT_AT overrides the file for one launch, and the bound covers scouts"
}

test_secondmate_extension_never_carries_the_bound() {
  local rec id=ctx-pi-mate sm out ext
  rec=$(make_spawn_case mate codex "$id")
  read_case_record "$rec"
  printf '230000\n' > "$HOME_DIR/config/crew-context-compact-at"
  printf 'pi fixture-model\n' > "$HOME_DIR/config/secondmate-harness"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' > "$sm/.gitignore"
  git -C "$sm" init -q -b main
  sm=$(cd "$sm" && pwd -P)
  out=$(GROK_HOME="$HOME_DIR/grok-home" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$sm" --secondmate)
  expect_code 0 $? "pi secondmate spawn should succeed: $out"
  ext="$HOME_DIR/state/$id.pi-ext.ts"
  assert_present "$ext" "pi secondmate spawn did not write the busy extension"
  assert_no_grep "compactAtTokens" "$ext" "config/crew-context-compact-at reached a secondmate's extension"
  pass "a secondmate's Pi extension never carries the crew context bound"
}

# The two extensions the cases above generated must load through Pi's own
# loader and register exactly the expected handlers. A plain Node import proves
# less, because Pi never loads an extension that way. Runs last so that a host
# with no installed Pi, or a Pi without that loader, reports one mid-run skip
# line instead of reading as a whole-suite gate skip.
test_both_forms_load_through_pi_own_loader() {
  local pkg form expected out rc version
  for form in base bound; do
    [ -f "$TMP_ROOT/$form.pi-ext.ts" ] || fail "the $form extension was not kept by its generating case"
  done
  if ! pkg=$(pi_package_dir); then
    echo "skip: installed @earendil-works/pi-coding-agent package not found; the generated extensions were not loaded through Pi's own loader"
    return 0
  fi
  version=$(jq -r '.version // "unknown"' "$pkg/package.json" 2>/dev/null || printf 'unknown')
  for form in base bound; do
    expected="agent_start,agent_settled,turn_end"
    [ "$form" = base ] || expected="$expected,agent_settled"
    rc=0
    out=$(load_through_pi_loader "$pkg" "$TMP_ROOT/$form.pi-ext.ts") || rc=$?
    if [ "$rc" -eq 3 ]; then
      echo "skip: Pi $version at $pkg has no jiti extension loader to load the generated extensions through: $out"
      return 0
    fi
    expect_code 0 "$rc" "the $form Pi extension did not load through Pi $version's own extension loader: $out"
    assert_equals "$expected" "$out" "the $form Pi extension registered unexpected handlers through Pi $version's own loader"
  done
  pass "both forms of the pi extension load through Pi $version's own extension loader"
}

test_extension_without_the_bound_is_its_base_text
test_malformed_threshold_warns_and_launches_the_base_text
test_bound_is_baked_in_and_compacts_only_when_settled_idle
test_one_launch_override_reaches_a_scout
test_secondmate_extension_never_carries_the_bound
test_both_forms_load_through_pi_own_loader

echo "all fm-pi-context-compact tests passed"
