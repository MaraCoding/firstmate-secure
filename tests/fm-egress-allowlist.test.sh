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

# fixture traces: the exact shapes strace emits for connect() and for the two
# lookup paths the judge trusts (systemd-resolved varlink JSON, DNS packets).
VARLINK='/run/systemd/resolve/io.systemd.Resolve'
tr_unix()    { printf '%s connect(%s, {sa_family=AF_UNIX, sun_path="%s"}, 110) = 0\n' "$1" "$2" "$3"; }
tr_connect() { printf '%s connect(%s, {sa_family=AF_INET, sin_port=htons(%s), sin_addr=inet_addr("%s")}, 16) = 0\n' "$1" "$2" "$3" "$4"; }
tr_connect6() { printf '%s connect(%s, {sa_family=AF_INET6, sin6_port=htons(%s), sin6_flowinfo=htonl(0), inet_pton(AF_INET6, "%s", &sin6_addr), sin6_scope_id=0}, 28) = 0\n' "$1" "$2" "$3" "$4"; }
# tr_varlink <tid> <fd> <name> <ip4>: the ResolveHostname request and its answer
tr_varlink() {
  local octets; octets=$(printf '%s' "$4" | tr . ,)
  printf '%s sendto(%s, "{\\"method\\":\\"io.systemd.Resolve.ResolveHostname\\",\\"parameters\\":{\\"name\\":\\"%s\\",\\"flags\\":0}}\\0", 90, MSG_DONTWAIT|MSG_NOSIGNAL, NULL, 0) = 90\n' "$1" "$2" "$3"
  printf '%s recvfrom(%s, "{\\"parameters\\":{\\"addresses\\":[{\\"ifindex\\":2,\\"family\\":2,\\"address\\":[%s]}],\\"name\\":\\"%s\\",\\"flags\\":1048577}}\\0", 135152, MSG_DONTWAIT, NULL, NULL) = 120\n' "$1" "$2" "$octets" "$3"
}
# tr_dns <tid> <fd> <name> <ip4>: a DNS A query to 127.0.0.53:53 and its answer, in strace's octal escaping
tr_dns() {
  python3 -I - "$@" <<'PY2'
import struct, sys
tid, fd, name, ip = sys.argv[1:5]
def esc(b):
    # strace's quoting: printable ASCII as-is, else minimal octal, widened to
    # three digits when the next byte is an ASCII digit (so \0224 is \022 '4').
    out = []
    for i, c in enumerate(b):
        nxt = b[i + 1] if i + 1 < len(b) else None
        if c == 0x22: out.append('\\"')
        elif c == 0x5c: out.append('\\\\')
        elif 0x20 <= c < 0x7f: out.append(chr(c))
        elif nxt is not None and 0x30 <= nxt <= 0x39: out.append('\\%03o' % c)
        else: out.append('\\%o' % c)
    return ''.join(out)
qn = b''.join(bytes([len(l)]) + l.encode() for l in name.split('.')) + b'\0'
q = struct.pack('>6H', 0x1234, 0x0100, 1, 0, 0, 0) + qn + struct.pack('>HH', 1, 1)
a = struct.pack('>6H', 0x1234, 0x8180, 1, 1, 0, 0) + qn + struct.pack('>HH', 1, 1) \
    + b'\xc0\x0c' + struct.pack('>HHIH', 1, 1, 60, 4) + bytes(int(o) for o in ip.split('.'))
ns = '{sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("127.0.0.53")}'
print(f'{tid} sendto({fd}, "{esc(q)}", {len(q)}, 0, {ns}, 16) = {len(q)}')
print(f'{tid} recvfrom({fd}, "{esc(a)}", 4096, 0, {ns}, [16]) = {len(a)}')
PY2
}

test_audit_judges_allowlisted_ip_clean() {
  # An allowlist that names the IP directly needs no lookup at all.
  printf 'github.com forge test\n203.0.113.9 forge fixture\n' > "$TMP/al.txt"
  {
    tr_unix 12345 5 /tmp/x.sock
    tr_connect 12345 6 53 127.0.0.53
    tr_connect 12346 7 443 203.0.113.9
  } > "$TMP/clean.trace"
  out=$("$AUDIT" --allowlist "$TMP/al.txt" --judge "$TMP/clean.trace" 2>&1); rc=$?
  expect_code 0 "$rc" "audit verdict clean for an allowlisted endpoint"
  assert_contains "$out" "connects: 1" "loopback and unix connects are dropped from the count"
  assert_contains "$out" "address listed" "the literal address entry is what cleared it"
  assert_contains "$out" "verdict: clean" "clean verdict printed"
  pass "fm-egress-audit judges an allowlisted address clean and ignores loopback/unix"
}

test_audit_attributes_by_the_process_own_lookup() {
  printf 'github.com forge test\n' > "$TMP/al3.txt"
  {
    tr_unix 777 20 "$VARLINK"
    tr_varlink 777 20 api.github.com 203.0.113.9
    tr_connect 777 20 0 203.0.113.9          # glibc address-selection probe
    tr_connect 777 21 443 203.0.113.9
  } > "$TMP/attr.trace"
  out=$("$AUDIT" --allowlist "$TMP/al3.txt" --judge "$TMP/attr.trace" 2>&1); rc=$?
  expect_code 0 "$rc" "a connection to an address the process looked up under an allowlisted name is clean"
  assert_contains "$out" "api.github.com 443 allowed forge" "the looked-up name, not the address, is judged"
  assert_contains "$out" "looked up as api.github.com" "the attribution is stated"
  assert_contains "$out" "connects: 1" "the port-0 probe is not a connection"
  assert_contains "$out" "probes_dropped: 1" "the probe is counted separately"
  pass "fm-egress-audit attributes an endpoint to the name the process itself resolved"
}

test_audit_trusts_only_the_resolver_socket() {
  # The same answer arriving on a socket that is NOT the resolver's is a forgery
  # and must not clear the host; the endpoint stays unexpected.
  printf 'github.com forge test\n' > "$TMP/al4.txt"
  {
    tr_unix 778 9 /tmp/evil.sock
    tr_varlink 778 9 api.github.com 203.0.113.9
    tr_connect 778 10 443 203.0.113.9
  } > "$TMP/spoof.trace"
  out=$("$AUDIT" --allowlist "$TMP/al4.txt" --judge "$TMP/spoof.trace" 2>&1); rc=$?
  expect_code 1 "$rc" "an answer on a non-resolver socket does not clear the endpoint"
  assert_contains "$out" "lookups: 0" "the forged answer is not counted as a lookup"
  assert_contains "$out" "no lookup seen" "the report says why"
  pass "fm-egress-audit ignores lookup answers that did not come from the resolver"
}

test_audit_reads_classic_dns_too() {
  printf 'github.com forge test\n' > "$TMP/al5.txt"
  {
    tr_connect 779 3 53 127.0.0.53
    tr_dns 779 3 api.github.com 203.0.113.9
    tr_connect 779 4 443 203.0.113.9
  } > "$TMP/dns.trace"
  out=$("$AUDIT" --allowlist "$TMP/al5.txt" --judge "$TMP/dns.trace" 2>&1); rc=$?
  expect_code 0 "$rc" "a DNS answer from the resolv.conf nameserver attributes the endpoint"
  assert_contains "$out" "lookups: 1" "the DNS exchange is counted"
  assert_contains "$out" "api.github.com 443 allowed forge" "the DNS name is judged"
  pass "fm-egress-audit understands classic DNS packets as well as systemd-resolved"
}

test_audit_follows_labeled_sockets_across_threads() {
  # With strace -yy every call names its socket, so a Go-style resolver that
  # writes the query on one thread and reads the answer on another is still
  # attributed, and a UDP connect with nothing sent is a probe, not a connection.
  printf 'github.com forge test\n' > "$TMP/al6.txt"
  {
    printf '900 connect(3<UDP:[111]>, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("127.0.0.53")}, 16) = 0\n'
    tr_dns 900 3 api.github.com 203.0.113.9 | sed \
      -e 's/^900 sendto(3, \(".*"\), \([0-9]*\), 0, {[^}]*}, 16)/900 write(3<UDP:[127.0.0.1:40000->127.0.0.53:53]>, \1, \2)/' \
      -e 's/^900 recvfrom(3, \(".*"\), 4096, 0, {[^}]*}, \[16\])/901 read(3<UDP:[127.0.0.1:40000->127.0.0.53:53]>, \1, 512)/'
    printf '901 connect(5<UDP:[222]>, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("203.0.113.9")}, 16) = 0\n'
    printf '901 connect(6<TCP:[333]>, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("203.0.113.9")}, 16) = -1 EINPROGRESS (Operation now in progress)\n'
  } > "$TMP/labeled.trace"
  out=$("$AUDIT" --allowlist "$TMP/al6.txt" --judge "$TMP/labeled.trace" 2>&1); rc=$?
  expect_code 0 "$rc" "a labeled cross-thread DNS exchange attributes the endpoint"
  assert_contains "$out" "lookups: 1" "the answer read on another thread is matched to the query"
  assert_contains "$out" "api.github.com 443 allowed forge" "the TCP endpoint is judged by the looked-up name"
  assert_contains "$out" "connects: 1" "the UDP connect with nothing sent is not a connection"
  assert_contains "$out" "probes_dropped: 1" "it is counted as a probe"
  pass "fm-egress-audit follows -yy socket labels across threads and drops silent UDP probes"
}

test_audit_flags_unknown_endpoint() {
  printf 'github.com forge test\n' > "$TMP/al2.txt"
  {
    tr_unix 12345 5 /tmp/x.sock
    tr_connect 12346 7 443 203.0.113.77
    tr_connect6 12346 8 443 2001:db8::77
    tr_unix 12347 11 "$VARLINK"
    tr_varlink 12347 11 a.example.test 203.0.113.78
    tr_connect 12347 12 443 203.0.113.78
  } > "$TMP/bad.trace"
  out=$("$AUDIT" --allowlist "$TMP/al2.txt" --judge "$TMP/bad.trace" 2>&1); rc=$?
  expect_code 1 "$rc" "audit exits 1 when an endpoint is outside the allowlist"
  assert_contains "$out" "203.0.113.77 443 unexpected (no lookup seen" "an endpoint with no lookup is unexpected"
  assert_contains "$out" "2001:db8::77" "IPv6 endpoints are parsed"
  assert_contains "$out" "a.example.test 443 unexpected" "a looked-up name outside the allowlist is unexpected"
  assert_contains "$out" "3 host(s) outside" "every unexpected endpoint is counted"
  pass "fm-egress-audit flags endpoints outside the allowlist, with or without a lookup"
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
test_audit_attributes_by_the_process_own_lookup
test_audit_trusts_only_the_resolver_socket
test_audit_reads_classic_dns_too
test_audit_follows_labeled_sockets_across_threads
test_audit_flags_unknown_endpoint
test_audit_runs_a_command_and_keeps_evidence
