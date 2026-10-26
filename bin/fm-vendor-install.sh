#!/usr/bin/env bash
# fm-vendor-install.sh - install firstmate's pinned toolchain from a local
# vendor directory, never from `curl | sh` or the public npm registry.
#
# Usage:
#   fm-vendor-install.sh [--vendor <dir>] [--prefix <dir>] [--bin-dir <dir>] [--airgap] [--check]
#
# The vendor directory (default $FM_VENDOR_DIR, then a firstmate-vendor clone
# beside this checkout, then ~/firstmate-vendor) holds:
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
#   - a per-user npm prefix (~/.npm-global, in ~/.npmrc) when the global one is
#     not writable
#   - one env file with PATH and the variables above, sourced by one line in
#     ~/.bashrc (and ~/.zshrc, ~/.profile when they exist); it then checks every
#     tool resolves, so firstmate never starts with them MISSING
#
# --prefix <dir> puts everything under <dir> instead of the home directory
# (e.g. /mnt/workspace/fm-tools): tools in <dir>/bin, npm packages in <dir>/npm
# (cache <dir>/npm-cache), no-mistakes and its data in <dir>/no-mistakes
# (NM_HOME), lavish state in <dir>/lavish-axi (LAVISH_AXI_STATE_DIR), and the env
# file at <dir>/env.sh, which also sets FM_VENDOR_PREFIX so later runs (including
# bin/fm-bootstrap.sh install under airgap) reuse <dir>. Only the one source line goes in the shell rc files, and
# the systemd drop-in in ~/.config, because that is where the shell and systemd
# read them.
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

# Default vendor directory: $FM_VENDOR_DIR, else a firstmate-vendor clone next
# to this checkout (any location, e.g. /mnt/workspace), else ~/firstmate-vendor.
if [ -n "${FM_VENDOR_DIR:-}" ]; then VENDOR=$FM_VENDOR_DIR
elif [ -d "$FM_ROOT/../firstmate-vendor" ]; then VENDOR=$(cd "$FM_ROOT/../firstmate-vendor" && pwd)
else VENDOR="$HOME/firstmate-vendor"; fi
BIN_DIR=
PREFIX="${FM_VENDOR_PREFIX:-}"  # set by the env file after a --prefix install, so re-runs keep it
AIRGAP=0
CHECK=0

usage() { awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }
die() { printf 'fm-vendor-install: %s\n' "$1" >&2; exit 1; }
say() { printf 'fm-vendor-install: %s\n' "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --vendor) [ $# -ge 2 ] || die "--vendor needs a directory"; VENDOR=$2; shift 2 ;;
    --bin-dir) [ $# -ge 2 ] || die "--bin-dir needs a directory"; BIN_DIR=$2; shift 2 ;;
    --prefix) [ $# -ge 2 ] || die "--prefix needs a directory"; PREFIX=$2; shift 2 ;;
    --airgap) AIRGAP=1; shift ;;
    --check) CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument $1" ;;
  esac
done
if [ -n "$PREFIX" ]; then
  mkdir -p "$PREFIX" || die "cannot create $PREFIX"
  PREFIX=$(cd "$PREFIX" && pwd)
  [ -n "$BIN_DIR" ] || BIN_DIR="$PREFIX/bin"
  NM_ROOT="$PREFIX/no-mistakes"
  ENV_FILE="$PREFIX/env.sh"
else
  [ -n "$BIN_DIR" ] || BIN_DIR="$HOME/.local/bin"
  NM_ROOT="$HOME/.no-mistakes"
  ENV_FILE="$HOME/.config/firstmate/vendor-env.sh"
fi
[ -d "$VENDOR" ] || die "vendor directory not found: $VENDOR (clone firstmate-vendor next to this checkout, or pass --vendor <dir>)"

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

# A system node (prefix /usr or /usr/local) makes `npm install -g` fail with
# EACCES for a normal user. Use a per-user prefix then, the way npm's own docs
# recommend, so the install never needs sudo.
if [ -n "$PREFIX" ]; then
  # Per-invocation only: ~/.npmrc is left alone, the env file carries the prefix.
  export npm_config_prefix="$PREFIX/npm" npm_config_cache="$PREFIX/npm-cache"
  mkdir -p "$npm_config_prefix" "$npm_config_cache" || die "cannot create $PREFIX/npm"
fi
NPM_PREFIX=$(npm prefix -g 2>/dev/null) || die "cannot read the npm global prefix"
if [ -z "$PREFIX" ] && [ ! -w "$NPM_PREFIX" ] || { [ -d "$NPM_PREFIX/lib/node_modules" ] && [ ! -w "$NPM_PREFIX/lib/node_modules" ]; }; then
  NPM_PREFIX="$HOME/.npm-global"
  mkdir -p "$NPM_PREFIX" || die "cannot create $NPM_PREFIX"
  npm config set prefix "$NPM_PREFIX" || die "cannot set the npm prefix to $NPM_PREFIX"
  say "npm global prefix was not writable; using $NPM_PREFIX (saved in ~/.npmrc)"
fi
NPM_BIN="$NPM_PREFIX/bin"

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
export NM_HOME="$NM_ROOT"
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
{
  printf 'NO_MISTAKES_TELEMETRY=off\nNO_MISTAKES_NO_UPDATE_CHECK=1\n'
  [ -z "$PREFIX" ] || printf 'NM_HOME=%s\n' "$NM_ROOT"
} > "$HOME/.config/environment.d/no-mistakes.conf"
export NO_MISTAKES_TELEMETRY=off NO_MISTAKES_NO_UPDATE_CHECK=1
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
  systemctl --user import-environment NO_MISTAKES_TELEMETRY NO_MISTAKES_NO_UPDATE_CHECK NM_HOME 2>/dev/null || true
  # upstream's installer ends with `daemon restart`; do the same so the unit exists,
  # then give it a drop-in so the variables survive reboots.
  "$NM_ROOT/bin/no-mistakes" daemon restart >/dev/null 2>&1 || say "warning: no-mistakes daemon restart failed; run it after login"
  # One unit per NM_HOME; the drop-in only sets the two off switches, so it is
  # safe on every unit, including one for another root.
  units=$(systemctl --user list-units --all --no-legend 'no-mistakes-daemon-*.service' 2>/dev/null | awk '{print $1}')
  for unit in $units; do
    mkdir -p "$HOME/.config/systemd/user/$unit.d"
    printf '[Service]\nEnvironment=NO_MISTAKES_TELEMETRY=off\nEnvironment=NO_MISTAKES_NO_UPDATE_CHECK=1\n' \
      > "$HOME/.config/systemd/user/$unit.d/no-phone-home.conf"
  done
  if [ -n "$units" ]; then
    systemctl --user daemon-reload 2>/dev/null || true
    for unit in $units; do systemctl --user restart "$unit" 2>/dev/null || true; done
    say "daemon unit(s) restarted with the no-phone-home drop-in: $(printf '%s' "$units" | tr '\n' ' ')"
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

# ---- env file: every tool above lands in $BIN_DIR or $NPM_BIN; firstmate
# reports them MISSING unless both are on PATH in the shell that starts it.
mkdir -p "$(dirname "$ENV_FILE")" || die "cannot create $(dirname "$ENV_FILE")"
{
  echo "# written by firstmate bin/fm-vendor-install.sh; re-run it to refresh"
  printf 'export PATH="%s:%s:%s"\n' "$BIN_DIR" "$NPM_BIN" "\$PATH"  # $PATH stays literal: expanded when sourced
  echo "export NO_MISTAKES_TELEMETRY=off NO_MISTAKES_NO_UPDATE_CHECK=1"
  if [ -n "$PREFIX" ]; then
    printf 'export FM_VENDOR_PREFIX="%s"\n' "$PREFIX"
    printf 'export NM_HOME="%s"\n' "$NM_ROOT"
    printf 'export LAVISH_AXI_STATE_DIR="%s"\n' "$PREFIX/lavish-axi"
    printf 'export npm_config_prefix="%s" npm_config_cache="%s"\n' "$PREFIX/npm" "$PREFIX/npm-cache"
  fi
} > "$ENV_FILE" || die "cannot write $ENV_FILE"
src_mark='# firstmate vendor install: env'
src_line="[ -f \"$ENV_FILE\" ] && . \"$ENV_FILE\"  $src_mark"
for rc in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
  case "$rc" in */.bashrc) ;; *) [ -e "$rc" ] || continue ;; esac
  # Replace any earlier line (this one, or the older inline PATH line) with the current one.
  grep -vF -e "$src_mark" -e '# firstmate vendor install: PATH' "$rc" > "$rc.fm-tmp" 2>/dev/null || true
  printf '%s\n' "$src_line" >> "$rc.fm-tmp" || die "cannot write $rc.fm-tmp"
  cat "$rc.fm-tmp" > "$rc" || die "cannot update $rc"
  rm -f "$rc.fm-tmp"
done
say "env: $ENV_FILE (sourced from ~/.bashrc)"
missing=()
for t in treehouse no-mistakes gh-axi chrome-devtools-axi tasks-axi quota-axi lavish-axi; do
  PATH="$BIN_DIR:$NPM_BIN:$PATH" command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
[ ${#missing[@]} -eq 0 ] || die "installed, but not found on $BIN_DIR or $NPM_BIN: ${missing[*]}"

case ":$PATH:" in
  *":$BIN_DIR:"*":$NPM_BIN:"*|*":$NPM_BIN:"*":$BIN_DIR:"*) say "done. Run bin/fm-bootstrap.sh in this home." ;;
  *) say "done. Open a new terminal (or run: . $ENV_FILE) before starting firstmate, so it finds these tools." ;;
esac
