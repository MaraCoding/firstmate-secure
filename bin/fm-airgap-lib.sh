# shellcheck shell=bash
# fm-airgap-lib.sh - the airgap kill switch (NDA-safe fork): contract and shim.
# Usage: . bin/fm-airgap-lib.sh   (or . bin/fm-env-lib.sh, which defines it)
#
# firstmate's only third-party egress beyond the forge (gh) and the model
# provider is opt-in by credential: the myfirstmate.io Relay (FMX_PAIRING_TOKEN),
# the api.typesafe.ai dispatch classifier (TYPESAFE_API_KEY), and AWS Bedrock
# for the spoken interface and inbox side-questions (config/voice-*, inbox-*).
# This switch makes "off" unconditional: when it is active every one of those
# paths refuses BEFORE any network call, regardless of what .env, the
# environment, or config/ otherwise say. Guarded call sites:
#   bin/fm-env-lib.sh            fmx_env_get returns nothing for the two secrets
#   bin/fm-x-lib.sh              fmx_load_config clears FMX_TOKEN; fmx_post_json refuses
#   bin/fm-public-followup-lib.sh fm_pf_relay_active is false
#   bin/fm-bootstrap.sh          prints one AIRGAP: detection line; x_mode_setup
#                                sees no token and removes Relay artifacts
#   bin/fm-dispatch-resolve.sh   prints "dispatch-resolve: off (airgap ...)" and exits 0
#   bin/fm-inbox.sh              say/ask die (own inline copy); note/status/... unaffected
#   bin/fm-voice-relay.py        refuses in resolve_settings (own inline copy)
#
# Activation, either of:
#   FM_AIRGAP=1 (also true|yes|on) in the environment
#   <home>/config/airgap exists (any content, in the home's gitignored config/)
# Off is the default and changes nothing. Nothing in .env can turn it back on:
# the switch exists so a stray token cannot re-enable egress on an NDA machine.
#
# The shell implementation (fm_airgap_active, fm_airgap_reason) lives in
# bin/fm-env-lib.sh, the single owner of the opt-in secret read, so every
# copied-out script that can read a secret carries the switch with no second
# file to forget. This file sources it for callers that want the name.
# tests/fm-airgap.test.sh owns the contract; docs/airgap.md the operator view.
# shellcheck source=bin/fm-env-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-env-lib.sh"
