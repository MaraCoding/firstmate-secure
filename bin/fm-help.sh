#!/usr/bin/env bash
# fm-help.sh - one-line cheat sheet of the fm-* commands, generated from each script's header.
# Usage: fm-help.sh [--all] [<pattern>]
#   Prints one line per command: the name, its Usage: arguments when the header
#   has a Usage: line, and the header's first sentence, capped at
#   FM_HELP_WIDTH columns (default 118). The default view lists the commands an
#   operator runs and stays under 6k characters; hooks, daemons, remote legs,
#   installers, adapters, and other internals are hidden unless --all is
#   given. <pattern> is a case-insensitive substring filter on the line.
#   Read this instead of running per-command --help; open one script's header
#   only when the line is not enough.
# Exit: 0 on success (even when the filter matches nothing), 2 on usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL=0
PATTERN=
while [ $# -gt 0 ]; do
  case "$1" in
  --all) ALL=1 ;;
  -h | --help)
    sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  -*)
    echo "error: unknown option: $1" >&2
    exit 2
    ;;
  *)
    [ -z "$PATTERN" ] || {
      echo "error: at most one pattern" >&2
      exit 2
    }
    PATTERN=$1
    ;;
  esac
  shift
done

WIDTH=${FM_HELP_WIDTH:-118}
case "$WIDTH" in '' | *[!0-9]*) WIDTH=118 ;; esac

# Internal commands: invoked by hooks, daemons, other fm-* scripts, CI, or a
# skill's own procedure rather than typed by the operator. Shown with --all.
fm_help_internal() {  # <name without .sh>
  case "$1" in
  fm-*-pretool-check | fm-turnend-guard* | fm-claude-stop-autoarm | fm-busy-event | \
    fm-watch | fm-watch-checkpoint | fm-supervise-daemon | fm-supervision-host | \
    fm-supervision-instructions | fm-sessionstart-* | fm-startup-* | fm-remote-* | \
    fm-procevent-* | fm-install-* | fm-lint* | fm-test-* | fm-vendor-* | fm-git-* | \
    fm-kimi-turnend-hook | fm-agy-trust | fm-claude-trust | fm-devin-config | \
    fm-jev-mem-guard | fm-quota-axi-shim | fm-public-followup-* | fm-afk-* | \
    fm-branch-outcome | fm-branch-prompt | fm-branch-report | fm-host-mirror | \
    fm-inactive-reconcile | fm-home-summary-refresh | fm-doc-audience-check | \
    fm-egress-audit | fm-wake-grant | fm-herdr-ci-cleanup | fm-herdr-session-cleanup | \
    fm-herdr-groups | fm-guard | fm-harness | fm-decision-hold | fm-fleet-ledger | \
    fm-operational-input | fm-stow-cascade | fm-secondmate-report | fm-x-* | \
    fm-bearings-board | fm-bearings-snapshot | fm-mail-check | fm-lab-home | fm-live-lab | \
    fm-herdr-lab | fm-extension | fm-check-register | fm-check-unregister | \
    fm-pr-poll | fm-tool-update-check | fm-update | fm-ensure-agents-md | fm-lock | \
    fm-quota-choose | fm-backend | fm-backlog-receive | fm-on | fm-pipeline-spend)
    return 0
    ;;
  esac
  return 1
}

fm_help_line() {  # <script> <name>
  awk -v name="$2" -v width="$WIDTH" '
    function strip_name(t) {
      sub(/^ *(bin\/)?fm-[A-Za-z0-9_-]+\.sh */, "", t)
      return t
    }
    function plain(t) { return t != "" && t !~ /^[<\[(-]/ }
    NR == 1 && /^#!/ { next }
    /^[^#]/ { exit }
    /^# *shellcheck/ { next }
    {
      line = $0
      sub(/^# ?/, "", line)
      if (!usage_seen && line ~ /^ *[Uu]sage:/) {
        usage_seen = 1
        in_usage = 1
        t = line
        sub(/^ *[Uu]sage: */, "", t)
        if (t != "") forms[++nforms] = strip_name(t)
        next
      }
      if (in_usage) {
        t = line
        sub(/^ *(bin\/)?/, "", t)
        if (index(t, name ".sh") == 1 && (length(t) == length(name) + 3 || substr(t, length(name) + 4, 1) == " ")) {
          forms[++nforms] = strip_name(line)
          next
        }
        # Indented continuation or per-form description lines stay in the block.
        if (line ~ /^ +[^ ]/) next
        in_usage = 0
      }
      if (done) next
      if (line == "") { if (syn != "") done = 1; next }
      if (syn == "") {
        sub(/^fm-[A-Za-z0-9_-]+\.sh *[-:]+ */, "", line)
        syn = line
      } else {
        syn = syn " " line
      }
      if (syn ~ /[.:]$/ || length(syn) > width) done = 1
    }
    END {
      usage = ""
      for (i = 1; i <= nforms; i++) sub(/ *\\$/, "", forms[i])
      if (nforms == 1) usage = forms[1]
      else if (nforms > 1) {
        # Several forms: show the verbs. A verb is the first plain word, or
        # the second when every form shares the same leading placeholder.
        split(forms[1], a0, " ")
        lead = a0[1]
        same = 1
        for (i = 2; i <= nforms; i++) { split(forms[i], ai, " "); if (ai[1] != lead) same = 0 }
        verbs = ""
        for (i = 1; i <= nforms; i++) {
          split(forms[i], ai, " ")
          v = (same && !plain(ai[1])) ? ai[2] : ai[1]
          if (!plain(v) || (("|" verbs "|") ~ ("\\|" v "\\|"))) continue
          verbs = verbs (verbs == "" ? "" : "|") v
        }
        if (verbs == "") usage = forms[1]
        else usage = (same && !plain(lead) ? lead " " : "") verbs
      }
      sub(/^ +/, "", syn)
      sub(/\.$/, "", syn)
      out = name
      if (usage != "") out = out " " usage
      if (syn != "") out = out " - " syn
      if (length(out) > width) out = substr(out, 1, width - 3) "..."
      print out
    }
  ' "$1"
}

for script in "$SCRIPT_DIR"/fm-*.sh; do
  base=${script##*/}
  base=${base%.sh}
  case "$base" in *-lib) continue ;; esac
  [ "$base" != fm-help ] || continue
  if [ "$ALL" = 0 ] && fm_help_internal "$base"; then
    continue
  fi
  line=$(fm_help_line "$script" "$base")
  if [ -n "$PATTERN" ]; then
    case "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')" in
    *"$(printf '%s' "$PATTERN" | tr '[:upper:]' '[:lower:]')"*) ;;
    *) continue ;;
    esac
  fi
  printf '%s\n' "$line"
done
