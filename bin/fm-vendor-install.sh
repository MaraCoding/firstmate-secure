#!/usr/bin/env bash
# fm-vendor-install.sh - install firstmate's pinned toolchain from a local
# vendor directory, never from `curl | sh` or the public npm registry.
#
# Usage:
#   fm-vendor-install.sh [--vendor <dir>] [--bin-dir <dir>] [--airgap] [--check]
#
# The vendor directory (default $FM_VENDOR_DIR, then ~/firstmate-vendor) holds:
#   npm/*.tgz + npm/SHA256SUMS       tasks-axi quota-axi gh-axi chrome-devtools-axi
#                                    axi-sdk-js (npm pack output) and lavish-local,
#                                    the offline replica that provides the
#                                    `lavish-axi` bin (docs/airgap.md "Toolchain");
#                                    never the stock lavish-axi tarball, which
#                                    would claim the same bin name and phone home
#   bin/treehouse-*.tar.gz           treehouse release tarball
#   bin/no-mistakes-nda-safe-*       no-mistakes rebuilt without telemetry
#                                    (README-no-mistakes.md beside it owns the recipe)
#   bin/SHA256SUMS                   hashes for everything under bin/
# Every file is verified against its SHA256SUMS line before it is used; a
# missing or mismatched hash stops the install with the file named.
#
# What it installs, idempotently:
#   - the npm packages globally from the .tgz files (npm install -g <file>)
#   - treehouse into --bin-dir (default ~/.local/bin)
#   - no-mistakes into ~/.no-mistakes/bin with the ~/.local/bin symlink the
#     upstream installer creates, then restarts its daemon the way upstream does
#   - a systemd user drop-in and ~/.config/environment.d entry setting
#     NO_MISTAKES_TELEMETRY=off and NO_MISTAKES_NO_UPDATE_CHECK=1 (belt and
#     braces: the rebuilt binary cannot phone home even without them)
#   - with --airgap, config/airgap in this home (docs/airgap.md)
# --check only verifies hashes and reports what would change; it installs nothing.
#
# It never fetches anything. If a file is missing it says which one and how it
# was produced (npm pack <name>@<version>; the release tarball URL; the rebuild
# README) so the vendor directory can be refilled on a machine that may fetch.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

VENDOR="${FM_VENDOR_DIR:-$HOME/firstmate-vendor}"
BIN_DIR="$HOME/.local/bin"
AIRGAP=0
CHECK=0

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
die() { printf 'fm-vendor-install: %s\n' "$1" >&2; exit 1; }
say() { printf 'fm-vendor-install: %s\n' "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --vendor) [ $# -ge 2 ] || die "--vendor needs a directory"; VENDOR=$2; shift 2 ;;
    --bin-dir) [ $# -ge 2 ] || die "--bin-dir needs a directory"; BIN_DIR=$2; shift 2 ;;
    --airgap) AIRGAP=1; shift ;;
    --check) CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
[ -d "$VENDOR" ] || die "vendor directory not found: $VENDOR"

# verify <dir> <file>: the file's sha256 must match its line in <dir>/SHA256SUMS.
verify() {
  local dir=$1 file=$2 want have
  [ -r "$dir/$file" ] || die "missing $dir/$file"
  [ -r "$dir/SHA256SUMS" ] || die "missing $dir/SHA256SUMS"
  want=$(awk -v f="$file" '$2 == f || $2 == "*"f { print $1; exit }' "$dir/SHA256SUMS")
  [ -n "$want" ] || die "no SHA256SUMS line for $file in $dir"
  have=$(sha256sum "$dir/$file" | awk '{print $1}')
  [ "$have" = "$want" ] || die "sha256 mismatch for $dir/$file (have $have, want $want)"
}

# ---- gather and verify everything first, so a bad file stops before any change
NPM_PKGS=()
for f in "$VENDOR"/npm/*.tgz; do
  [ -e "$f" ] || die "no npm tarballs under $VENDOR/npm (produce them with: npm pack <name>@<version>)"
  verify "$VENDOR/npm" "$(basename "$f")"
  NPM_PKGS+=("$f")
done
TREEHOUSE_TGZ=$(find "$VENDOR/bin" -maxdepth 1 -name 'treehouse-*.tar.gz' 2>/dev/null | head -n1)
[ -n "$TREEHOUSE_TGZ" ] || die "no treehouse tarball under $VENDOR/bin (https://github.com/kunchenguid/treehouse/releases)"
verify "$VENDOR/bin" "$(basename "$TREEHOUSE_TGZ")"
NM_BIN=$(find "$VENDOR/bin" -maxdepth 1 -name 'no-mistakes-nda-safe-*' 2>/dev/null | head -n1)
[ -n "$NM_BIN" ] || die "no no-mistakes-nda-safe-* binary under $VENDOR/bin (see README-no-mistakes.md for the rebuild)"
verify "$VENDOR/bin" "$(basename "$NM_BIN")"
say "verified ${#NPM_PKGS[@]} npm tarballs, $(basename "$TREEHOUSE_TGZ"), $(basename "$NM_BIN")"

if [ "$CHECK" -eq 1 ]; then
  say "--check: hashes verified; nothing installed"
  exit 0
fi

command -v npm >/dev/null 2>&1 || die "npm not found; install node first (system package)"
command -v tar >/dev/null 2>&1 || die "tar not found"
mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"

# ---- npm packages from local tarballs (the SDK first so the others resolve it)
ordered=()
for f in "${NPM_PKGS[@]}"; do case "$f" in */axi-sdk-js-*) ordered=("$f" "${ordered[@]}") ;; *) ordered+=("$f") ;; esac; done
for f in "${ordered[@]}"; do
  say "npm install -g $(basename "$f")"
  npm install -g --no-fund --no-audit "$f" >/dev/null || die "npm install failed for $f"
done

# ---- treehouse
tmp=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$tmp"' EXIT
tar -xzf "$TREEHOUSE_TGZ" -C "$tmp" || die "cannot extract $TREEHOUSE_TGZ"
[ -f "$tmp/treehouse" ] || die "tarball did not contain a treehouse binary"
install -m 0755 "$tmp/treehouse" "$BIN_DIR/treehouse" || die "cannot install treehouse"
say "treehouse -> $BIN_DIR/treehouse ($("$BIN_DIR/treehouse" --version 2>/dev/null | head -n1))"

# ---- no-mistakes (same layout as upstream's docs/install.sh)
NM_ROOT="$HOME/.no-mistakes"
mkdir -p "$NM_ROOT/bin" || die "cannot create $NM_ROOT/bin"
if [ -x "$NM_ROOT/bin/no-mistakes" ] && [ ! -e "$NM_ROOT/bin/no-mistakes.pre-vendor" ]; then
  cp -p "$NM_ROOT/bin/no-mistakes" "$NM_ROOT/bin/no-mistakes.pre-vendor"
fi
install -m 0755 "$NM_BIN" "$NM_ROOT/bin/no-mistakes.new" || die "cannot stage no-mistakes"
mv -f "$NM_ROOT/bin/no-mistakes.new" "$NM_ROOT/bin/no-mistakes" || die "cannot install no-mistakes"
ln -sfn "$NM_ROOT/bin/no-mistakes" "$BIN_DIR/no-mistakes"
say "no-mistakes -> $NM_ROOT/bin/no-mistakes ($("$NM_ROOT/bin/no-mistakes" --version 2>/dev/null | head -n1))"

# environment: shell and systemd user session
mkdir -p "$HOME/.config/environment.d"
printf 'NO_MISTAKES_TELEMETRY=off\nNO_MISTAKES_NO_UPDATE_CHECK=1\n' > "$HOME/.config/environment.d/no-mistakes.conf"
if ! grep -q 'NO_MISTAKES_TELEMETRY' "$HOME/.bashrc" 2>/dev/null; then
  printf '\n# firstmate vendor install: keep no-mistakes from phoning home\nexport NO_MISTAKES_TELEMETRY=off\nexport NO_MISTAKES_NO_UPDATE_CHECK=1\n' >> "$HOME/.bashrc"
fi
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user import-environment NO_MISTAKES_TELEMETRY NO_MISTAKES_NO_UPDATE_CHECK 2>/dev/null || true
  # upstream's installer ends with `daemon restart`; do the same so the unit exists,
  # then give it a drop-in so the variables survive reboots.
  "$NM_ROOT/bin/no-mistakes" daemon restart >/dev/null 2>&1 || say "warning: no-mistakes daemon restart failed; run it after login"
  unit=$(systemctl --user list-units --all --no-legend 'no-mistakes-daemon-*.service' 2>/dev/null | awk '{print $1; exit}')
  if [ -n "$unit" ]; then
    mkdir -p "$HOME/.config/systemd/user/$unit.d"
    printf '[Service]\nEnvironment=NO_MISTAKES_TELEMETRY=off\nEnvironment=NO_MISTAKES_NO_UPDATE_CHECK=1\n' \
      > "$HOME/.config/systemd/user/$unit.d/no-phone-home.conf"
    systemctl --user daemon-reload 2>/dev/null || true
    systemctl --user restart "$unit" 2>/dev/null || true
    say "daemon $unit restarted with the no-phone-home drop-in"
  fi
else
  "$NM_ROOT/bin/no-mistakes" daemon restart >/dev/null 2>&1 || say "warning: no-mistakes daemon restart failed; run it after login"
fi

# ---- airgap switch
if [ "$AIRGAP" -eq 1 ]; then
  mkdir -p "$CONFIG" || die "cannot create $CONFIG"
  : > "$CONFIG/airgap" || die "cannot write $CONFIG/airgap"
  say "airgap on: $CONFIG/airgap (docs/airgap.md)"
fi

say "done. Put $BIN_DIR and your npm global bin on PATH, then run bin/fm-bootstrap.sh in this home."
