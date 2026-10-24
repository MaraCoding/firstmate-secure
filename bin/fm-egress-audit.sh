#!/usr/bin/env bash
# fm-egress-audit.sh - run a command and report every network destination it
# (and every child) connected to, judged against an allowlist.
#
# Usage:
#   fm-egress-audit.sh [--allowlist <file>] [--out <dir>] -- <command> [args...]
#   fm-egress-audit.sh --judge <trace-file> [--allowlist <file>]
#
# What it does: wraps <command> in `strace -f -e trace=connect`, then reduces
# the trace to the set of distinct remote endpoints (IPv4/IPv6 address, port,
# and the hostname it reverse-resolves to when one exists). Loopback and UNIX
# sockets are dropped: they never leave the machine. Each remaining host is
# matched against the allowlist (default docs/egress-allowlist.txt, first
# column, `#` comments ignored; an entry matches itself and any subdomain).
# A host that matches no entry, or that resolves to nothing, is UNEXPECTED.
#
# Output: one report on stdout -
#   egress-audit:
#     command: ...
#     connects: <n>        (remote connect() calls, after loopback/unix drop)
#     hosts:
#       <host-or-ip> <port> allowed <class>   | unexpected
#     verdict: clean | unexpected
# Exit 0 when every host is allowed, 1 when any is unexpected, 2 on usage or a
# missing strace. The raw trace and the report are kept under --out (default
# $FM_HOME/state/egress-audit/<utc-stamp>/) so a run is evidence, not a claim.
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

# allowed_class <host>: print the allowlist class for <host> (exact or parent
# domain match) and succeed, or fail when no entry covers it.
allowed_class() {
  local host=$1 entry class
  host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
  host=${host%.}
  while read -r entry class _; do
    case "$entry" in ''|\#*) continue ;; esac
    entry=$(printf '%s' "$entry" | tr '[:upper:]' '[:lower:]')
    if [ "$host" = "$entry" ] || [ "${host%."$entry"}" != "$host" ]; then
      printf '%s' "${class:-allowed}"
      return 0
    fi
  done < "$ALLOWLIST"
  return 1
}

# resolve_name <ip>: reverse-resolve, print the name or nothing.
resolve_name() {
  local ip=$1 name=
  if command -v getent >/dev/null 2>&1; then
    name=$(getent hosts "$ip" 2>/dev/null | awk '{print $2; exit}')
  fi
  if [ -z "$name" ] && command -v python3 >/dev/null 2>&1; then
    name=$(python3 -I -c 'import socket,sys
try: print(socket.gethostbyaddr(sys.argv[1])[0])
except Exception: pass' "$ip" 2>/dev/null)
  fi
  printf '%s' "${name%.}"
}

# judge <trace> : reduce + classify; prints the report; returns 0 clean / 1 not.
judge() {
  local trace=$1 label=$2 n=0 bad=0 ip port name host class
  printf 'egress-audit:\n  command: %s\n' "$label"
  # Keep only remote AF_INET/AF_INET6 connect() lines; drop loopback.
  # strace renders: connect(3, {sa_family=AF_INET, sin_port=htons(443), sin_addr=inet_addr("1.2.3.4")}, 16) = 0
  #                 connect(3, {sa_family=AF_INET6, sin6_port=htons(443), ..., inet_pton(AF_INET6, "2606:...", &sin6_addr), ...}, 28) = 0
  while IFS=$'\t' read -r ip port; do
    [ -n "$ip" ] || continue
    case "$ip" in 127.*|::1|0.0.0.0|::|fe80:*) continue ;; esac
    n=$((n + 1))
    printf '%s\t%s\n' "$ip" "$port"
  done < <(awk '
    /connect\(/ && /AF_INET/ {
      ip=""; port=""
      if (match($0, /inet_addr\("[^"]+"\)/)) { ip=substr($0, RSTART+11, RLENGTH-13) }
      else if (match($0, /inet_pton\(AF_INET6, "[^"]+"/)) { ip=substr($0, RSTART+21, RLENGTH-22) }
      if (match($0, /htons\([0-9]+\)/)) { port=substr($0, RSTART+6, RLENGTH-7) }
      if (ip != "") printf "%s\t%s\n", ip, port
    }' "$trace" | LC_ALL=C sort -u) > "$trace.endpoints"
  printf '  connects: %s\n  hosts:\n' "$n"
  while IFS=$'\t' read -r ip port; do
    name=$(resolve_name "$ip")
    host=${name:-$ip}
    if [ -n "$name" ] && class=$(allowed_class "$name"); then
      printf '    %s %s allowed %s\n' "$host" "$port" "$class"
    elif class=$(allowed_class "$ip"); then
      printf '    %s %s allowed %s\n' "$host" "$port" "$class"
    else
      printf '    %s %s unexpected\n' "$host" "$port"
      bad=$((bad + 1))
    fi
  done < "$trace.endpoints"
  if [ "$bad" -eq 0 ]; then
    printf '  verdict: clean\n'
    return 0
  fi
  printf '  verdict: unexpected (%s host(s) outside %s)\n' "$bad" "$ALLOWLIST"
  return 1
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

strace -f -qq -e trace=connect -s 256 -o "$TRACE" -- "$@" > "$OUT/stdout" 2> "$OUT/stderr"
cmd_rc=$?
printf '%s\n' "$cmd_rc" > "$OUT/exit"

judge "$TRACE" "$label" | tee "$OUT/report.txt"
rc=${PIPESTATUS[0]}
printf '  command_exit: %s\n  evidence: %s\n' "$cmd_rc" "$OUT" | tee -a "$OUT/report.txt"
exit "$rc"
