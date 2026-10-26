#!/usr/bin/env bash
# Airgap kill switch contract (bin/fm-airgap-lib.sh).
#
# When config/airgap exists in a home, or FM_AIRGAP is set, every path that
# would reach a third party other than the forge and the model provider must
# refuse before any network call, whatever .env or the environment carry:
# the myfirstmate.io Relay, the api.typesafe.ai dispatch classifier, and the
# Bedrock-backed inbox and voice relay. Off must change nothing. Each case
# below drives the real script with a fake curl/aws on PATH that fails loudly
# if it is ever executed, so a regression shows as a network attempt, not as a
# missing message.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot)
HOME_DIR="$TMP/home"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/data"
printf 'FMX_PAIRING_TOKEN=secret-token\nTYPESAFE_API_KEY=secret-key\nOTHER=kept\n' > "$HOME_DIR/.env"

# A curl or aws that is ever reached under airgap is the failure we test for.
FAKEBIN="$TMP/fakebin"
mkdir -p "$FAKEBIN"
NET_LOG="$TMP/network-attempts.log"
for tool in curl aws; do
  cat > "$FAKEBIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$NET_LOG"
exit 7
SH
  chmod +x "$FAKEBIN/$tool"
done
export PATH="$FAKEBIN:$PATH"

airgap_on()  { : > "$HOME_DIR/config/airgap"; }
airgap_off() { rm -f "$HOME_DIR/config/airgap"; }
no_network() { [ ! -s "$NET_LOG" ] || fail "$1 reached the network under airgap:"$'\n'"$(cat "$NET_LOG")"; }

# --- fmx_env_get hides exactly the two opt-in secrets --------------------------

test_env_get_hides_secrets_only_when_on() {
  local out
  airgap_off
  out=$(bash -c '. "$1/bin/fm-env-lib.sh"; printf "%s|%s|%s" "$(fmx_env_get FMX_PAIRING_TOKEN "$2")" "$(fmx_env_get TYPESAFE_API_KEY "$2")" "$(fmx_env_get OTHER "$2")"' _ "$ROOT" "$HOME_DIR/.env")
  assert_equals "secret-token|secret-key|kept" "$out" "airgap off: fmx_env_get must read every key unchanged"

  airgap_on
  out=$(bash -c '. "$1/bin/fm-env-lib.sh"; printf "%s|%s|%s" "$(fmx_env_get FMX_PAIRING_TOKEN "$2")" "$(fmx_env_get TYPESAFE_API_KEY "$2")" "$(fmx_env_get OTHER "$2")"' _ "$ROOT" "$HOME_DIR/.env")
  assert_equals "||kept" "$out" "airgap on: the two opt-in secrets read as absent, other keys unchanged"

  airgap_off
  out=$(FM_AIRGAP=1 bash -c '. "$1/bin/fm-env-lib.sh"; printf "%s" "$(fmx_env_get FMX_PAIRING_TOKEN "$2")"' _ "$ROOT" "$HOME_DIR/.env")
  assert_equals "" "$out" "FM_AIRGAP=1 alone hides the relay token"
  pass "fmx_env_get hides exactly FMX_PAIRING_TOKEN and TYPESAFE_API_KEY while airgap is on"
}

# --- relay client: token cleared even when the environment supplies it ---------

test_relay_token_cleared_and_post_refused() {
  local out
  airgap_on
  out=$(FM_HOME="$HOME_DIR" FMX_PAIRING_TOKEN=env-token bash -c '
    . "$1/bin/fm-x-lib.sh"; fmx_load_config
    printf "token=[%s]" "$FMX_TOKEN"
    fmx_post_json poll /dev/null; printf " post=%s" "$?"' _ "$ROOT")
  assert_equals "token=[] post=4" "$out" "airgap on: FMX_TOKEN cleared despite env token and fmx_post_json refuses"
  no_network "fm-x-lib"

  : > "$NET_LOG"
  out=$(FM_HOME="$HOME_DIR" FMX_PAIRING_TOKEN=env-token "$ROOT/bin/fm-x-poll.sh" 2>&1); rc=$?
  expect_code 0 "$rc" "fm-x-poll under airgap is a silent no-op"
  assert_equals "" "$out" "fm-x-poll under airgap prints nothing"
  no_network "fm-x-poll"

  out=$(FM_HOME="$HOME_DIR" FMX_PAIRING_TOKEN=env-token bash -c '
    . "$1/bin/fm-public-followup-lib.sh"; fm_pf_relay_active "$2" && echo active || echo inactive' _ "$ROOT" "$HOME_DIR")
  assert_equals "inactive" "$out" "fm_pf_relay_active is false under airgap even with an env token"

  airgap_off
  out=$(FM_HOME="$HOME_DIR" bash -c '. "$1/bin/fm-x-lib.sh"; fmx_load_config; printf "%s" "$FMX_TOKEN"' _ "$ROOT")
  assert_equals "secret-token" "$out" "airgap off: fmx_load_config still reads the .env token"
  pass "relay token is cleared and every relay POST refuses while airgap is on"
}

# --- dispatch classifier ------------------------------------------------------

test_dispatch_resolve_off_before_any_key() {
  local out rc
  airgap_on
  : > "$NET_LOG"
  printf '{"rules":[{"when":"anything","harness":"pi"}]}\n' > "$HOME_DIR/config/crew-dispatch.json"
  printf '# brief\n## Captain'"'"'s intent\nnda text\n' > "$TMP/brief.md"
  out=$(FM_HOME="$HOME_DIR" TYPESAFE_API_KEY=env-key "$ROOT/bin/fm-dispatch-resolve.sh" "$TMP/brief.md" 2>&1 >"$TMP/stdout"); rc=$?
  expect_code 0 "$rc" "dispatch-resolve exits 0 under airgap"
  assert_contains "$out" "dispatch-resolve: off (airgap:" "dispatch-resolve names the airgap on stderr"
  assert_contains "$out" "nothing sent" "dispatch-resolve says nothing was sent"
  [ ! -s "$TMP/stdout" ] || fail "dispatch-resolve under airgap must print nothing on stdout"
  no_network "fm-dispatch-resolve"
  rm -f "$HOME_DIR/config/crew-dispatch.json"
  airgap_off
  pass "dispatch-resolve is off under airgap before the key is even considered"
}

# --- inbox: say/ask refuse, note keeps working ---------------------------------

test_inbox_model_calls_refuse_but_note_works() {
  local out rc
  airgap_on
  : > "$NET_LOG"
  out=$(FM_HOME="$HOME_DIR" FM_INBOX_REGION=eu-north-1 FM_INBOX_STT_MODEL=m FM_INBOX_PROFILE='' \
    "$ROOT/bin/fm-inbox.sh" say /dev/null 2>&1); rc=$?
  expect_code 1 "$rc" "fm-inbox say refuses under airgap"
  assert_contains "$out" "airgap" "fm-inbox say names the airgap"
  out=$(FM_HOME="$HOME_DIR" FM_INBOX_REGION=eu-north-1 FM_INBOX_ASK_MODEL=m FM_INBOX_PROFILE='' \
    "$ROOT/bin/fm-inbox.sh" ask "what is in flight" 2>&1); rc=$?
  expect_code 1 "$rc" "fm-inbox ask refuses under airgap"
  assert_contains "$out" "airgap" "fm-inbox ask names the airgap"
  no_network "fm-inbox say/ask"
  out=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-inbox.sh" note "still local" 2>&1); rc=$?
  expect_code 0 "$rc" "fm-inbox note keeps working under airgap"
  assert_contains "$out" "queued" "fm-inbox note queued the note"
  airgap_off
  pass "fm-inbox say and ask refuse under airgap while note still works"
}

# --- voice relay ----------------------------------------------------------------

test_voice_relay_refuses() {
  local out rc
  command -v python3 >/dev/null 2>&1 || { pass "voice relay check skipped: no python3"; return 0; }
  airgap_on
  out=$(FM_HOME="$HOME_DIR" python3 "$ROOT/bin/fm-voice-relay.py" --self-test /dev/null --region r --model m --profile "" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "fm-voice-relay must exit non-zero under airgap"
  assert_contains "$out" "airgap" "fm-voice-relay names the airgap"
  assert_contains "$out" "nothing sent" "fm-voice-relay says nothing was sent"
  airgap_off
  pass "fm-voice-relay refuses before resolving credentials while airgap is on"
}

# --- bootstrap prints the status line and removes relay artifacts ----------------

test_bootstrap_reports_airgap() {
  local out
  # Detect-only is the read-only diagnostic pass; the AIRGAP line is a
  # diagnostic, so it must appear there. The relay-artifact removal happens in
  # the mutating x_mode_setup pass, whose own suite (fm-x-mode) covers the
  # token-absent path that airgap forces.
  airgap_on
  out=$(cd "$ROOT" && FM_HOME="$HOME_DIR" FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh 2>&1) || true
  assert_contains "$out" "AIRGAP: on (config/airgap is present)" "bootstrap prints the AIRGAP status line in detect-only mode"
  airgap_off
  out=$(cd "$ROOT" && FM_HOME="$HOME_DIR" FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh 2>&1) || true
  assert_not_contains "$out" "AIRGAP:" "bootstrap prints no AIRGAP line when the switch is off"
  out=$(cd "$ROOT" && FM_AIRGAP=1 FM_HOME="$HOME_DIR" FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh 2>&1) || true
  assert_contains "$out" "AIRGAP: on (FM_AIRGAP is set)" "bootstrap names the environment trigger"
  no_network "fm-bootstrap detect-only"
  pass "bootstrap reports the airgap switch as a detection line"
}

test_bootstrap_install_uses_vendor_only() {
  local out rc empty="$TMP/empty-vendor" bare="$TMP/bare-path"
  mkdir -p "$empty/npm" "$empty/bin" "$bare"
  # A PATH where treehouse is surely absent, so detect-only prints its MISSING hint.
  for t in bash sh env git node jq tmux awk sed grep cat date mkdir rm mv cp ls tr head tail sort uname dirname basename find wc cut ps id mktemp printf python3 sha256sum readlink stat touch sleep; do
    p=$(command -v "$t" 2>/dev/null) && ln -sf "$p" "$bare/$t"
  done
  airgap_on
  out=$(cd "$ROOT" && PATH="$FAKEBIN:$bare" FM_HOME="$HOME_DIR" FM_BOOTSTRAP_NETWORK=skip FM_BOOTSTRAP_DETECT_ONLY=1 bin/fm-bootstrap.sh 2>&1) || true
  assert_contains "$out" "MISSING: treehouse (install: $ROOT/bin/fm-vendor-install.sh" "airgap MISSING hint names the vendor installer"
  assert_not_contains "$out" "install.sh | sh" "airgap MISSING hint never suggests curl | sh"
  out=$(cd "$ROOT" && FM_VENDOR_DIR="$empty" FM_HOME="$HOME_DIR" bin/fm-bootstrap.sh install treehouse tasks-axi 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "airgap install with an empty vendor directory must fail, not fall back to the network"
  assert_contains "$out" "from the vendor directory" "airgap install routes vendored tools to fm-vendor-install.sh"
  assert_contains "$out" "no npm tarballs under $empty/npm" "the vendor installer names what is missing"
  airgap_off
  no_network "fm-bootstrap install"
  pass "airgap: bootstrap installs vendored tools only from the vendor directory"
}

test_quota_axi_shim() {
  local shim="$TMP/shim/quota-axi" real="$TMP/shim/real-quota-axi" out rc
  mkdir -p "$TMP/shim"
  printf '#!/usr/bin/env bash\nprintf "real %%s\\n" "$*"\n' > "$real"; chmod +x "$real"
  # Render the template exactly as bin/fm-vendor-install.sh does.
  sed -e "s#@QUOTA_AXI_REAL@#$real#" -e "s#@FM_AIRGAP_FILE@#$HOME_DIR/config/airgap#" \
    "$ROOT/bin/fm-quota-axi-shim.sh" > "$shim"; chmod +x "$shim"
  assert_equals "real --provider claude,codex --json" "$(FM_AIRGAP='' "$shim" --json)" "shim pins a plain read to claude,codex"
  assert_equals "real quota --provider claude,codex --json" "$(FM_AIRGAP='' "$shim" quota --json)" "shim pins the quota subcommand too"
  assert_equals "real --provider claude --json" "$(FM_AIRGAP='' "$shim" --provider claude --json)" "an explicit --provider passes through"
  airgap_on
  out=$(FM_AIRGAP='' "$shim" update 2>&1); rc=$?
  assert_equals 75 "$rc" "shim refuses update under airgap"
  assert_contains "$out" "'update' refused" "shim says why update is refused"
  airgap_off
  assert_equals "real update" "$(FM_AIRGAP='' "$shim" update)" "update passes through with airgap off"
  assert_grep 'fm-quota-axi-shim.sh' "$ROOT/bin/fm-vendor-install.sh" "fm-vendor-install.sh installs the quota-axi shim"
  pass "quota-axi shim pins providers and refuses update under airgap"
}

# --- every guarded file still carries its guard ---------------------------------

test_guards_present() {
  local f
  for f in bin/fm-env-lib.sh bin/fm-x-lib.sh bin/fm-public-followup-lib.sh \
           bin/fm-dispatch-resolve.sh bin/fm-inbox.sh bin/fm-bootstrap.sh; do
    assert_grep "fm_airgap_active" "$ROOT/$f" "$f lost its airgap guard"
  done
  assert_grep "def airgap_active" "$ROOT/bin/fm-voice-relay.py" "fm-voice-relay.py lost its airgap guard"
  pass "every guarded egress file still calls the airgap check"
}

test_env_get_hides_secrets_only_when_on
test_relay_token_cleared_and_post_refused
test_dispatch_resolve_off_before_any_key
test_inbox_model_calls_refuse_but_note_works
test_voice_relay_refuses
test_bootstrap_reports_airgap
test_bootstrap_install_uses_vendor_only
test_quota_axi_shim
test_guards_present
