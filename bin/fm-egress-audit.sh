#!/usr/bin/env bash
# fm-egress-audit.sh - run a command and report every network destination it
# (and every child) connected to, judged against an allowlist.
#
# Usage:
#   fm-egress-audit.sh [--allowlist <file>] [--out <dir>] -- <command> [args...]
#   fm-egress-audit.sh --judge <trace-file> [--allowlist <file>]
#
# What it does: wraps <command> in strace (connect plus the send/recv/read/write
# calls that carry name lookups, with -yy so every call names the socket it
# used), then reduces the trace to the distinct remote endpoints it connected
# to and attributes each endpoint to the hostname THE PROCESS ITSELF asked for.
# Two lookup paths are understood:
#   - systemd-resolved's varlink socket (/run/systemd/resolve/io.systemd.Resolve),
#     which glibc's nss-resolve uses, so Node, Python, curl, gh and every shell
#     tool on such a host appear here as JSON ResolveHostname exchanges;
#   - classic DNS packets to a nameserver listed in /etc/resolv.conf on port 53,
#     which static Go binaries use (on any socket call, including read/write).
# A lookup answer is trusted only when the kernel-reported socket it arrived on
# is connected to that resolver (the -yy label, or the connect() this trace saw
# on the same socket, or an explicit source address of the nameserver on port
# 53) and, for DNS, it matches the id and name of a query sent on that socket.
# The destination owner controls reverse DNS and could point a PTR at any name,
# so a PTR is shown as a side note (ptr=...) and never clears a host. A UDP
# connect that is never followed by a send on that socket is an address-
# selection probe (glibc's and Go's RFC 6724 sorting), counted separately, as
# is any connect on port 0. Loopback, link-local and UNIX sockets are dropped:
# they never leave the machine. A connection to a resolv.conf nameserver on
# port 53 is reported as `allowed resolver`.
#
# Each attributed name is matched against the allowlist (default
# docs/egress-allowlist.txt, first column, `#` comments ignored; an entry
# matches itself and any subdomain; a literal IP entry matches that address).
# An endpoint with no trusted lookup, or whose looked-up name matches no entry,
# is UNEXPECTED. A program that resolves names some other way (DNS-over-HTTPS,
# a hardcoded address) therefore shows as "no lookup seen" and fails the audit
# until the operator reads the trace.
#
# UV_USE_IO_URING=0 is exported to the command unless already set: libuv's
# io_uring path livelocks under ptrace, so Node (Pi, the axi tools) would hang.
#
# Output: one report on stdout -
#   egress-audit:
#     command: ...
#     connects: <n>         (remote connect() calls, after the drops above)
#     probes_dropped: <m>   (address-selection probes, see above)
#     lookups: <k>          (trusted name lookups seen)
#     hosts:
#       <name> <port> allowed <class> (<ip>, looked up as <name>)
#       <ip> <port> unexpected (no lookup seen; ptr=<name>)
#     verdict: clean | unexpected
# Exit 0 when every endpoint is allowed, 1 when any is unexpected, 2 on usage or
# a missing strace. The raw trace, the endpoint table and the report are kept
# under --out (default $FM_HOME/state/egress-audit/<utc-stamp>/) so a run is
# evidence, not a claim.
#
# This is the runtime half of the egress contract; tests/fm-egress-allowlist.test.sh
# is the static half (every hostname in the code must be classified). Together
# they are what an operator shows a reviewer: the code cannot name an
# unclassified host, and this run did not reach one. docs/airgap.md explains.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

ALLOWLIST="$FM_ROOT/docs/egress-allowlist.txt"
OUT=
JUDGE=
usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}
die() { printf 'fm-egress-audit: %s\n' "$1" >&2; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --allowlist) [ $# -ge 2 ] || die "--allowlist needs a file"; ALLOWLIST=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || die "--out needs a directory"; OUT=$2; shift 2 ;;
    --judge) [ $# -ge 2 ] || die "--judge needs a trace file"; JUDGE=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown flag $1" ;;
    *) break ;;
  esac
done
[ -r "$ALLOWLIST" ] || die "allowlist not readable: $ALLOWLIST"
command -v python3 >/dev/null 2>&1 || die "python3 not installed"

# judge <trace> <label>: reduce + attribute + classify; prints the report and
# writes <trace>.endpoints; returns 0 clean / 1 not.
judge() {
  python3 -I - "$1" "$ALLOWLIST" "$2" "${FM_EGRESS_RESOLV_CONF:-/etc/resolv.conf}" <<'PY'
import codecs
import ipaddress
import json
import re
import socket
import struct
import sys

trace_path, allowlist_path, label, resolv_conf = sys.argv[1:5]
VARLINK = "/run/systemd/resolve/io.systemd.Resolve"

# ---------------------------------------------------------------- allowlist
entries = []
with open(allowlist_path, encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        parts = raw.split()
        if not parts or parts[0].startswith("#"):
            continue
        entries.append((parts[0].lower().rstrip("."), parts[1] if len(parts) > 1 else "allowed"))


def allowed_class(host):
    host = host.lower().rstrip(".")
    for entry, cls in entries:
        if host == entry or host.endswith("." + entry):
            return cls
    return None


# ---------------------------------------------------------------- resolvers
nameservers = set()
try:
    with open(resolv_conf, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            parts = raw.split()
            if len(parts) >= 2 and parts[0] == "nameserver":
                try:
                    nameservers.add(ipaddress.ip_address(parts[1].split("%")[0]).compressed)
                except ValueError:
                    pass
except OSError:
    pass


def norm_ip(text):
    try:
        return ipaddress.ip_address(text).compressed
    except ValueError:
        return None


def is_local(ip):
    a = ipaddress.ip_address(ip)
    return a.is_loopback or a.is_unspecified or a.is_link_local


def is_ns(ip, port):
    return port == 53 and ip in nameservers


# ---------------------------------------------------------------- trace parsing
LINE = re.compile(r"^(?:\[pid\s+)?(\d+)\]?\s+(.*)$")
RESUMED = re.compile(r"^<\.\.\. (\w+) resumed>\s?(.*)$")
CSTRING = re.compile(r'"((?:[^"\\]|\\.)*)"(\.\.\.)?')
SOCKADDR_IN = re.compile(r'sin_port=htons\((\d+)\), sin_addr=inet_addr\("([^"]+)"\)')
SOCKADDR_IN6 = re.compile(r'sin6_port=htons\((\d+)\),.*?inet_pton\(AF_INET6, "([^"]+)"')
SUN_PATH = re.compile(r'sun_path="((?:[^"\\]|\\.)*)"')
FD_LABEL = re.compile(r"^(\d+)(?:<((?:->|[^<>])*)>)?")  # labels contain "->"; try it first
# -yy socket labels: TCP:[1.2.3.4:5->6.7.8.9:443], UDPv6:[[::1]:5->[2001:db8::1]:53],
# TCP:[12345] (not yet connected), UNIX-STREAM:[12345->12346], UNIX-STREAM:[12345]
ADDRPORT = re.compile(r"^\[?([0-9a-fA-F.:]+)\]?:(\d+)$")


def events(path):
    pending = {}
    with open(path, encoding="latin-1") as fh:
        for raw in fh:
            raw = raw.rstrip("\n")
            m = LINE.match(raw)
            if not m:
                continue
            tid, rest = m.group(1), m.group(2)
            if rest.endswith("<unfinished ...>"):
                pending[tid] = rest[: -len("<unfinished ...>")]
                continue
            rm = RESUMED.match(rest)
            if rm:
                rest = pending.pop(tid, "") + rm.group(2)
            yield tid, rest


def parse_call(rest):
    """-> (syscall, fd, label) or (None, None, None)."""
    name, sep, tail = rest.partition("(")
    if not sep or not name.isidentifier():
        return None, None, None
    m = FD_LABEL.match(tail.strip())
    if not m:
        return name, None, None
    return name, int(m.group(1)), m.group(2)


def label_parts(lab):
    """-> (proto, local, peer) from a -yy socket label; peer/local are (ip, port) or inode strings."""
    if not lab or ":[" not in lab or not lab.endswith("]"):
        return None, None, None
    proto, body = lab.split(":[", 1)
    body = body[:-1]
    local, _arrow, peer = body.partition("->")

    def side(text):
        if not text:
            return None
        m = ADDRPORT.match(text)
        if m:
            ip = norm_ip(m.group(1))
            return (ip, int(m.group(2))) if ip else text
        return text  # inode

    return proto, side(local), side(peer)


def strings_in(rest):
    out = []
    for m in CSTRING.finditer(rest):
        if m.group(2):  # truncated by -s; unusable
            continue
        try:
            out.append(codecs.escape_decode(m.group(1).encode("latin-1"))[0])
        except (ValueError, UnicodeError):
            continue
    return out


def sockaddrs_in(rest):
    found = []
    for m in SOCKADDR_IN.finditer(rest):
        ip = norm_ip(m.group(2))
        if ip:
            found.append((ip, int(m.group(1))))
    for m in SOCKADDR_IN6.finditer(rest):
        ip = norm_ip(m.group(2))
        if ip:
            found.append((ip, int(m.group(1))))
    return found


def dns_name(buf, off):
    labels, jumped, end, hops = [], False, None, 0
    while True:
        if off >= len(buf):
            raise ValueError("truncated name")
        length = buf[off]
        if length == 0:
            off += 1
            break
        if length & 0xC0 == 0xC0:
            if off + 1 >= len(buf):
                raise ValueError("bad pointer")
            ptr = ((length & 0x3F) << 8) | buf[off + 1]
            if not jumped:
                end = off + 2
            off, jumped, hops = ptr, True, hops + 1
            if hops > 20:
                raise ValueError("pointer loop")
            continue
        labels.append(buf[off + 1 : off + 1 + length].decode("ascii", "replace"))
        off += 1 + length
    return ".".join(labels).lower(), (end if jumped else off)


def dns_parse_one(buf):
    if len(buf) < 12:
        return None
    ident, flags, qd, an, _ns, _ar = struct.unpack(">6H", buf[:12])
    qr = flags >> 15
    off, qnames, answers = 12, [], []
    try:
        for _ in range(qd):
            name, off = dns_name(buf, off)
            off += 4
            qnames.append(name)
        if qr:
            for _ in range(an):
                _name, off = dns_name(buf, off)
                typ, _cls, _ttl, rdlen = struct.unpack(">HHIH", buf[off : off + 10])
                off += 10
                rdata = buf[off : off + rdlen]
                off += rdlen
                if typ == 1 and rdlen == 4:
                    answers.append(ipaddress.IPv4Address(rdata).compressed)
                elif typ == 28 and rdlen == 16:
                    answers.append(ipaddress.IPv6Address(rdata).compressed)
    except (ValueError, struct.error):
        return None
    if qd != 1 or not qnames:
        return None
    return ident, qr, qnames[0], answers


def dns_parse(buf):
    parsed = dns_parse_one(buf)
    if parsed is None and len(buf) > 2 and struct.unpack(">H", buf[:2])[0] == len(buf) - 2:
        parsed = dns_parse_one(buf[2:])  # DNS over TCP carries a length prefix
    return parsed


def varlink_messages(buf):
    for chunk in buf.split(b"\0"):
        chunk = chunk.strip()
        if not chunk.startswith(b"{"):
            continue
        try:
            yield json.loads(chunk.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            continue


# socket identity: the -yy label's local side (inode or ip:port) when present,
# else the (tid, fd) pair this trace saw the connect() on.
varlink_socks = set()      # identities connected to the varlink path
dns_socks = set()          # identities connected to a nameserver:53
varlink_query = {}         # identity -> last name asked
dns_query = {}             # (identity, id) -> name asked
lookups = {}               # ip -> set(names the process asked for)
endpoints = set()          # (ip, port)
udp_pending = {}           # identity -> (ip, port): UDP connects awaiting a send
probes = 0
lookup_count = 0

SENDS = {"sendto", "sendmsg", "sendmmsg", "write"}
RECVS = {"recvfrom", "recvmsg", "recvmmsg", "read"}


def identities(tid, fd, lab):
    """-> (proto, peer address or None, identities). A UNIX label's peer is an
    inode string, never an address, so only a tuple counts as a peer address."""
    proto, local, peer = label_parts(lab)
    ids = [("fd", tid, fd)]
    if local is not None:
        ids.insert(0, ("sock", local))
    return proto, (peer if isinstance(peer, tuple) else None), ids


for tid, rest in events(trace_path):
    name, fd, lab = parse_call(rest)
    if name is None or fd is None:
        continue
    proto, peer, ids = identities(tid, fd, lab)
    if name == "connect":
        for i in ids:
            udp_pending.pop(i, None)
        if "AF_UNIX" in rest:
            m = SUN_PATH.search(rest)
            if m and m.group(1) == VARLINK and rest.rstrip().endswith("= 0"):
                varlink_socks.update(ids)
            else:
                varlink_socks.difference_update(ids)
            dns_socks.difference_update(ids)
            continue
        addrs = sockaddrs_in(rest)
        varlink_socks.difference_update(ids)
        if not addrs:
            dns_socks.difference_update(ids)  # AF_UNSPEC disconnect or unknown family
            continue
        ip, port = addrs[0]
        if is_ns(ip, port):
            dns_socks.update(ids)
            if not is_local(ip):
                endpoints.add((ip, port))
            continue
        dns_socks.difference_update(ids)
        if is_local(ip):
            continue
        if port == 0:
            probes += 1
            continue
        if proto and proto.startswith("UDP"):
            udp_pending[ids[0]] = (ip, port)
            continue
        endpoints.add((ip, port))
        continue
    if name in SENDS:
        if ids[0] in udp_pending:
            endpoints.add(udp_pending.pop(ids[0]))
        explicit = sockaddrs_in(rest)
        for ip, port in explicit:
            if not is_ns(ip, port) and not is_local(ip) and port != 0:
                endpoints.add((ip, port))  # unconnected UDP send to a remote
        if any(i in varlink_socks for i in ids):
            for buf in strings_in(rest):
                for msg in varlink_messages(buf):
                    params = msg.get("parameters") if isinstance(msg, dict) else None
                    if msg.get("method") == "io.systemd.Resolve.ResolveHostname" and isinstance(params, dict):
                        qname = params.get("name")
                        if isinstance(qname, str):
                            for i in ids:
                                varlink_query[i] = qname.lower().rstrip(".")
            continue
        dns_dest = any(is_ns(ip, port) for ip, port in explicit)
        if (peer and is_ns(*peer)) or dns_dest or any(i in dns_socks for i in ids):
            for buf in strings_in(rest):
                parsed = dns_parse(buf)
                if parsed and parsed[1] == 0:
                    for i in ids:
                        dns_query[(i, parsed[0])] = parsed[2]
        continue
    if name in RECVS:
        if any(i in varlink_socks for i in ids):
            for buf in strings_in(rest):
                for msg in varlink_messages(buf):
                    params = msg.get("parameters") if isinstance(msg, dict) else None
                    if not isinstance(params, dict) or "addresses" not in params:
                        continue
                    names = set()
                    for i in ids:
                        asked = varlink_query.get(i)
                        if asked:
                            names.add(asked)
                    canon = params.get("name")
                    if isinstance(canon, str):
                        names.add(canon.lower().rstrip("."))
                    if not names:
                        continue
                    got = 0
                    for rec in params.get("addresses", []):
                        raw = rec.get("address") if isinstance(rec, dict) else None
                        if not isinstance(raw, list):
                            continue
                        try:
                            ip = ipaddress.ip_address(bytes(raw)).compressed
                        except (ValueError, TypeError):
                            continue
                        lookups.setdefault(ip, set()).update(names)
                        got += 1
                    if got:
                        lookup_count += 1
            continue
        src_ok = any(is_ns(ip, port) for ip, port in sockaddrs_in(rest))
        if not ((peer and is_ns(*peer)) or src_ok or any(i in dns_socks for i in ids)):
            continue
        for buf in strings_in(rest):
            parsed = dns_parse(buf)
            if not parsed or parsed[1] != 1:
                continue
            ident, _qr, qname, answers = parsed
            asked = None
            for i in ids:
                asked = dns_query.get((i, ident))
                if asked is not None:
                    break
            if asked is None or asked != qname:
                continue
            if answers:
                lookup_count += 1
            for ip in answers:
                lookups.setdefault(ip, set()).add(qname)

probes += len(udp_pending)

# ---------------------------------------------------------------- report


def ptr(ip):
    try:
        return socket.gethostbyaddr(ip)[0].rstrip(".")
    except (OSError, UnicodeError):
        return ""


rows = []
bad = 0
for ip, port in sorted(endpoints, key=lambda e: (e[0], e[1])):
    names = sorted(lookups.get(ip, ()))
    verdict = None
    for n in names:
        cls = allowed_class(n)
        if cls:
            verdict = f"{n} {port} allowed {cls} ({ip}, looked up as {n})"
            break
    if verdict is None:
        cls = allowed_class(ip)
        if cls:
            verdict = f"{ip} {port} allowed {cls} (address listed)"
        elif is_ns(ip, port):
            verdict = f"{ip} {port} allowed resolver (nameserver in {resolv_conf})"
    if verdict is None:
        bad += 1
        if names:
            verdict = f"{names[0]} {port} unexpected ({ip}, looked up as {', '.join(names)}; not in allowlist)"
        else:
            p = ptr(ip)
            verdict = f"{ip} {port} unexpected (no lookup seen" + (f"; ptr={p}" if p else "") + ")"
    rows.append((ip, port, names, verdict))

with open(trace_path + ".endpoints", "w", encoding="utf-8") as fh:
    for ip, port, names, verdict in rows:
        fh.write(f"{ip}\t{port}\t{','.join(names)}\t{verdict.split(' ', 2)[2]}\n")

print("egress-audit:")
print(f"  command: {label}")
print(f"  connects: {len(endpoints)}")
print(f"  probes_dropped: {probes}")
print(f"  lookups: {lookup_count}")
print("  hosts:")
for _ip, _port, _names, verdict in rows:
    print(f"    {verdict}")
if bad == 0:
    print("  verdict: clean")
    sys.exit(0)
print(f"  verdict: unexpected ({bad} host(s) outside {allowlist_path})")
sys.exit(1)
PY
}

if [ -n "$JUDGE" ]; then
  [ -r "$JUDGE" ] || die "trace not readable: $JUDGE"
  judge "$JUDGE" "(judged from $JUDGE)"
  exit $?
fi

[ $# -gt 0 ] || { usage >&2; exit 2; }
command -v strace >/dev/null 2>&1 || die "strace not installed"

[ -n "$OUT" ] || OUT="$STATE/egress-audit/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT" || die "cannot create $OUT"
TRACE="$OUT/connect.trace"
label=$(printf '%q ' "$@")
label=${label% }

# libuv's io_uring path livelocks under ptrace (Node spins on an eventfd), so
# keep it off for the traced command tree unless the caller chose otherwise.
export UV_USE_IO_URING="${UV_USE_IO_URING:-0}"

# connect() gives the endpoints; the send/recv/read/write family carries the
# lookups (varlink JSON or DNS packets); -yy labels every call with its socket;
# --seccomp-bpf keeps untraced syscalls from stopping; -s 2048 keeps a whole
# lookup answer in the trace while bounding what file reads contribute.
strace -f --seccomp-bpf -qq -yy -e signal=none \
  -e trace=socket,connect,sendto,sendmsg,sendmmsg,recvfrom,recvmsg,recvmmsg,read,write \
  -s 2048 -o "$TRACE" -- "$@" > "$OUT/stdout" 2> "$OUT/stderr"
cmd_rc=$?
printf '%s\n' "$cmd_rc" > "$OUT/exit"

judge "$TRACE" "$label" | tee "$OUT/report.txt"
rc=${PIPESTATUS[0]}
printf '  command_exit: %s\n  evidence: %s\n' "$cmd_rc" "$OUT" | tee -a "$OUT/report.txt"
exit "$rc"
