# shellcheck shell=bash
# Shared .env-style file accessor.
# Usage: . bin/fm-env-lib.sh
#
# This file is the single owner of the one-key .env read: the Relay pairing
# token (bin/fm-x-lib.sh and its callers) and the optional typesafe.ai
# dispatch key (bin/fm-dispatch-resolve.sh) both resolve their value through
# fmx_env_get, so those opt-in secrets in $FM_HOME/.env are parsed by one rule.
# (bin/fm-mail.sh loads its whole .env block itself under the same env-wins
# contract.) The value is printed to the caller's command substitution only;
# nothing is logged.

# fmx_env_get <key> <file>
# Read the value of KEY from a .env-style file: last assignment wins; tolerates a
# leading "export ", surrounding whitespace, and one layer of matching single or
# double quotes. Prints nothing (and succeeds) when the file or key is absent, so
# callers can treat empty output as "unset".
#
# Airgap kill switch (contract: bin/fm-airgap-lib.sh header; docs/airgap.md).
# Defined here, in the one file every secret-reading script already sources
# or copies, so no isolated copy can read a secret without the switch.
#
# fm_airgap_active [home]: 0 when the switch is on for <home>, 1 otherwise.
# On when FM_AIRGAP is 1|true|yes|on, or <home>/config/airgap exists. <home>
# defaults to $FM_HOME, then the repository root above bin/; the config
# directory honors FM_CONFIG_OVERRIDE like every other config reader.
fm_airgap_active() {
  local home=${1:-${FM_HOME:-}} cfg
  case "$(printf '%s' "${FM_AIRGAP:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) return 0 ;;
  esac
  if [ -z "$home" ]; then
    home="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 1
  fi
  cfg="${FM_CONFIG_OVERRIDE:-$home/config}"
  [ -e "$cfg/airgap" ]
}

# fm_airgap_reason: the active trigger, for refusal messages.
fm_airgap_reason() {
  case "$(printf '%s' "${FM_AIRGAP:-}" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on) printf 'FM_AIRGAP is set'; return 0 ;;
  esac
  printf 'config/airgap is present'
}

# When the switch is on, the two opt-in secrets read as absent whatever the
# file says, so every caller takes its existing "off" path with no second gate
# to drift.
fmx_env_get() {
  local key=$1 file=$2 line val
  case "$key" in
    FMX_PAIRING_TOKEN|TYPESAFE_API_KEY)
      if fm_airgap_active "$(dirname "$file")"; then return 0; fi ;;
  esac
  [ -f "$file" ] || return 0
  line=$(grep -E "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file" 2>/dev/null | tail -n1) || return 0
  [ -n "$line" ] || return 0
  val=${line#*=}
  val=${val#"${val%%[![:space:]]*}"}   # strip leading whitespace
  val=${val%"${val##*[![:space:]]}"}   # strip trailing whitespace (incl. CR)
  case "$val" in
    \"*\") val=${val#\"}; val=${val%\"} ;;
    \'*\') val=${val#\'}; val=${val%\'} ;;
  esac
  printf '%s' "$val"
}
