#!/usr/bin/env bash
# Static egress contract: every hostname named in firstmate's executable and
# harness surfaces must be classified in docs/egress-allowlist.txt.
#
# This is the merge gate for the NDA-safe fork. Upstream can add a new endpoint
# in any of 500 scripts; this test fails until a human reads it and writes one
# allowlist line saying what class it is. It also proves bin/fm-egress-audit.sh
# judges a trace the way the allowlist says, with fixture traces that need no
# network. docs/airgap.md owns the operator view.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALLOWLIST="$ROOT/docs/egress-allowlist.txt"
AUDIT="$ROOT/bin/fm-egress-audit.sh"
SCAN_DIRS="bin .pi .claude .codex .cursor .agents skills"
TMP=$(fm_test_tmproot)

allowlist_hosts() {
  awk '!/^[[:space:]]*(#|$)/ { print tolower($1) }' "$ALLOWLIST" | LC_ALL=C sort -u
}

host_allowed() {  # <host>
  local host=$1 entry
  while read -r entry; do
    [ "$host" = "$entry" ] && return 0
    [ "${host%."$entry"}" != "$host" ] && return 0
  done < <(allowlist_hosts)
  return 1
}

test_allowlist_is_well_formed() {
  [ -r "$ALLOWLIST" ] || fail "missing $ALLOWLIST"
  local bad
  bad=$(awk '!/^[[:space:]]*(#|$)/ && (NF < 3 || $2 !~ /^(forge|provider|guarded|install-hint|browser-asset|doc)$/) { print NR": "$0 }' "$ALLOWLIST")
  [ -z "$bad" ] || fail "allowlist lines need <host> <class> <why> with a known class:"$'\n'"$bad"
  pass "docs/egress-allowlist.txt has a host, a known class and a reason on every line"
}

test_every_code_host_is_classified() {
  local hosts host unclassified=
  # shellcheck disable=SC2086 # SCAN_DIRS is a deliberate word list.
  hosts=$(cd "$ROOT" && grep -rhoE 'https?://[A-Za-z0-9.-]+\.[A-Za-z]{2,}' $SCAN_DIRS 2>/dev/null \
    | sed -E 's#^https?://##' | tr '[:upper:]' '[:lower:]' | LC_ALL=C sort -u)
  [ -n "$hosts" ] || fail "scan found no hostnames at all; the scan itself is broken"
  while read -r host; do
    [ -n "$host" ] || continue
    host_allowed "$host" || unclassified="$unclassified"$'\n'"  $host"
  done <<< "$hosts"
  [ -z "$unclassified" ] || fail "hostnames in code with no docs/egress-allowlist.txt entry (classify or remove):$unclassified"
  pass "every hostname in $SCAN_DIRS is classified in docs/egress-allowlist.txt"
}

test_guarded_hosts_are_the_known_three() {
  local guarded
  guarded=$(awk '!/^[[:space:]]*(#|$)/ && $2 == "guarded" { print $1 }' "$ALLOWLIST" | LC_ALL=C sort | tr '\n' ' ')
  assert_equals "amazonaws.com api.typesafe.ai myfirstmate.io " "$guarded" \
    "the guarded set changed; add the matching refusal to bin/fm-airgap-lib.sh callers and tests/fm-airgap.test.sh first"
  pass "the guarded third parties are exactly Relay, typesafe and Bedrock"
}

# fixture traces: the exact shapes strace -e trace=connect emits.
write_trace() {  # <file> <ip> <port> [<ip6>]
  {
    printf '12345 connect(5, {sa_family=AF_UNIX, sun_path="/tmp/x.sock"}, 110) = 0\n'
    printf '12345 connect(6, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("127.0.0.53")}, 16) = 0\n'
    printf '12346 connect(7, {sa_family=AF_INET, sin_port=htons(%s), sin_addr=inet_addr("%s")}, 16) = 0\n' "$3" "$2"
    [ -z "${4:-}" ] || printf '12346 connect(8, {sa_family=AF_INET6, sin6_port=htons(443), sin6_flowinfo=htonl(0), inet_pton(AF_INET6, "%s", &sin6_addr), sin6_scope_id=0}, 28) = 0\n' "$4"
  } > "$1"
}

test_audit_judges_allowlisted_ip_clean() {
  # An allowlist that names the IP directly avoids depending on reverse DNS.
  printf 'github.com forge test\n203.0.113.9 forge fixture\n' > "$TMP/al.txt"
  write_trace "$TMP/clean.trace" 203.0.113.9 443
  out=$("$AUDIT" --allowlist "$TMP/al.txt" --judge "$TMP/clean.trace" 2>&1); rc=$?
  expect_code 0 "$rc" "audit verdict clean for an allowlisted endpoint"
  assert_contains "$out" "connects: 1" "loopback and unix connects are dropped from the count"
  assert_contains "$out" "verdict: clean" "clean verdict printed"
  pass "fm-egress-audit judges an allowlisted endpoint clean and ignores loopback/unix"
}

test_audit_flags_unknown_endpoint() {
  printf 'github.com forge test\n' > "$TMP/al2.txt"
  write_trace "$TMP/bad.trace" 203.0.113.77 443 "2001:db8::77"
  out=$("$AUDIT" --allowlist "$TMP/al2.txt" --judge "$TMP/bad.trace" 2>&1); rc=$?
  expect_code 1 "$rc" "audit exits 1 when an endpoint is outside the allowlist"
  assert_contains "$out" "unexpected" "unexpected endpoint named"
  assert_contains "$out" "2001:db8::77" "IPv6 endpoints are parsed"
  pass "fm-egress-audit flags endpoints outside the allowlist, IPv4 and IPv6"
}

test_audit_runs_a_command_and_keeps_evidence() {
  command -v strace >/dev/null 2>&1 || { pass "live audit skipped: no strace"; return 0; }
  out=$(FM_HOME="$TMP" "$AUDIT" --out "$TMP/run" -- true 2>&1); rc=$?
  expect_code 0 "$rc" "auditing a command that never connects is clean"
  assert_present "$TMP/run/connect.trace" "raw trace kept"
  assert_present "$TMP/run/report.txt" "report kept"
  assert_contains "$out" "command_exit: 0" "wrapped command exit recorded"
  pass "fm-egress-audit wraps a command and keeps the trace as evidence"
}

test_allowlist_is_well_formed
test_every_code_host_is_classified
test_guarded_hosts_are_the_known_three
test_audit_judges_allowlisted_ip_clean
test_audit_flags_unknown_endpoint
test_audit_runs_a_command_and_keeps_evidence
