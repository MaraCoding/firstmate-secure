#!/usr/bin/env bash
# quota-axi shim for the NDA-safe firstmate track.
#
# Why: stock quota-axi probes EVERY provider it can find a credential for. On
# this box that includes GitHub Copilot, which it checks by sending the `gh`
# OAuth token from ~/.config/gh/hosts.yml to api.github.com/copilot_internal/user
# even though no Copilot plan exists. firstmate only routes between the Claude
# and Codex subscriptions, so this shim pins every read to those providers
# unless the caller names its own --provider list, and refuses the built-in
# `update` subcommand (an npm registry fetch) while the firstmate airgap is on.
#
# Install: bin/fm-vendor-install.sh writes this file to <bin-dir>/quota-axi,
#          which precedes the npm global bin on PATH, with the two paths below
#          filled in. It is a template here; do not run it from bin/.
# Override: QUOTA_AXI_PROVIDERS=claude,codex,copilot quota-axi ...
#           or pass --provider explicitly.
# Audit:    ~/firstmate/bin/fm-egress-audit.sh -- quota-axi --json
#           must show only anthropic.com and chatgpt.com.
#           tests/fm-airgap.test.sh owns the contract.

set -eu

REAL="@QUOTA_AXI_REAL@"
[ -x "$REAL" ] || { echo "quota-axi shim: real binary missing at $REAL" >&2; exit 127; }

providers="${QUOTA_AXI_PROVIDERS:-claude,codex}"
airgap="${FM_AIRGAP:-}"
[ -n "$airgap" ] || { [ -f "@FM_AIRGAP_FILE@" ] && airgap=1; } || true

explicit=0
first="${1:-}"
for arg in "$@"; do
  case "$arg" in
    --provider|--provider=*) explicit=1 ;;
  esac
done

case "$first" in
  update)
    if [ -n "$airgap" ]; then
      echo "quota-axi shim: 'update' refused (firstmate airgap is on; it fetches registry.npmjs.org)" >&2
      exit 75
    fi
    exec "$REAL" "$@"
    ;;
  --help|-h|--version|-v)
    exec "$REAL" "$@"
    ;;
esac

if [ "$explicit" -eq 1 ]; then
  exec "$REAL" "$@"
fi

# quota (default), auth and models all accept --provider.
case "$first" in
  quota|auth|models)
    sub="$1"; shift
    exec "$REAL" "$sub" --provider "$providers" "$@"
    ;;
  *)
    exec "$REAL" --provider "$providers" "$@"
    ;;
esac
