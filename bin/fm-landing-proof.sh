#!/usr/bin/env bash
# fm-landing-proof.sh - record and check the validation proof for the exact
# commit a local-only ship task is about to land.
#
# Why this exists: a project can require that named validations (a full gate, a
# parity run) passed ON THE COMMIT THAT LANDS. That rule lived only in briefs
# and captain memory, and bin/fm-merge-local.sh checked none of it, so a branch
# could land on proof that belonged to an earlier commit, or on none at all.
# This script is the one owner of the proof record and of the check the merge
# consults. It reads logs and git; it never runs a validation and never merges.
#
# Opt-in and home-local: config/landing-proof names the projects and their
# rules. A home without that file, and a project the file does not name, are
# untouched: no record is written and the merge takes its old path.
#
# config/landing-proof - plain text, one rule per line; blank lines and `#`
# comments are skipped:
#   <project> mode <warn|require>
#   <project> proof <name> <extended regular expression>
# <project> is the basename of the project checkout recorded in the task's meta
# and may hold only letters, digits, `.`, `_` and `-`.
# <name> is a short label ([a-z][a-z0-9_-]*), for example gate or parity.
# In the expression the token @COMMIT@ stands for the full commit id being
# landed, so a rule is only ever met by a log line that names that commit.
# `warn` reports what is missing and lets the merge proceed; `require` refuses
# it. A project with proof rules and no mode line is `warn`.
# The whole file must parse. Anything this script cannot read as written (an
# unreadable file, a line of another shape, a mode with nothing to require, a
# file that is not plain text) refuses every gated merge in the home, because a
# rules file that cannot be read must never be mistaken for "nothing required".
#
# A proof is a regular, non-symlink log file holding one line its rule matches.
# Record: state/<task-id>.landing-proof (key=value lines)
#   schema=1
#   commit=<full commit id>
#   written_at=<epoch>
#   proof.<name>.log=<absolute path>
#   proof.<name>.sha256=<hex>
#   waived=<reason>            only on an explicit waiver, bound to commit=
# A recorded proof is trusted only while its log is byte-identical to what was
# recorded; a log that changed is examined again from scratch, never taken on
# the record's word.
# Landing history: state/landing-proofs.log, one line per gated landing; it
# outlives the per-task record, which task cleanup removes.
#
# Usage:
#   fm-landing-proof.sh gate <task-id> [--commit <id>]
#       What bin/fm-merge-local.sh runs. Accepts a still-valid record; otherwise
#       looks for each proof among the regular *.log files directly in
#       data/<task-id>/ and one directory below it, newest first, and writes the
#       record. Exit 0: proven, waived, a warn-mode shortfall (warned on stderr),
#       or a project with no rules. Exit 1: a require-mode shortfall or a rules
#       file that cannot be read as written.
#   fm-landing-proof.sh write <task-id> --proof <name>=<log> [--proof ...] [--commit <id>]
#       Record named logs explicitly. Each must satisfy its rule for the commit.
#   fm-landing-proof.sh waive <task-id> --reason <text> [--commit <id>]
#       Record an explicit waiver for exactly this commit.
#   fm-landing-proof.sh landed <task-id> --commit <id>
#       Append the landing-history line (the merge calls this after it lands).
#   fm-landing-proof.sh show <task-id>
# The commit defaults to the tip of the task's recorded ship branch.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

RULES="$CONFIG/landing-proof"
HISTORY="$STATE/landing-proofs.log"
NL=$'\n'
# Discovery bounds: how many candidate logs one gate inspects (newest first) and
# the largest log it will read. Both only stop a runaway proof folder from
# turning a merge into a long scan; a proof past either bound can still be
# recorded explicitly with `write`.
FM_LANDING_PROOF_MAX_LOGS=${FM_LANDING_PROOF_MAX_LOGS:-400}
FM_LANDING_PROOF_MAX_LOG_BYTES=${FM_LANDING_PROOF_MAX_LOG_BYTES:-268435456}
case "$FM_LANDING_PROOF_MAX_LOGS" in ''|*[!0-9]*|0) FM_LANDING_PROOF_MAX_LOGS=400 ;; esac
case "$FM_LANDING_PROOF_MAX_LOG_BYTES" in ''|*[!0-9]*|0) FM_LANDING_PROOF_MAX_LOG_BYTES=268435456 ;; esac

usage() {
  sed -n '/^# Usage:/,/^# The commit defaults/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
  echo "error: $*" >&2
  exit 1
}

landing_sha256() {  # <file>
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

# Trim leading and trailing whitespace of $1 into TRIMMED, without a subshell.
TRIMMED=
landing_trim() {
  TRIMMED=${1#"${1%%[![:space:]]*}"}
  TRIMMED=${TRIMMED%"${TRIMMED##*[![:space:]]}"}
}

# The rules for one project, loaded into MODE and the parallel arrays
# PROOF_NAMES / PROOF_REGEX. A project the file does not name leaves both arrays
# empty. Returns 1, with the reason on stderr, for a file that cannot be read as
# written; the caller refuses. Every line is checked, whichever project it
# names, so a damaged file is caught by the first gate that runs.
# The file is read once into memory and split here, with no here-document and
# no redirected loop: either can fail without stopping the script (an
# unreadable file, a temp directory with no room), and a rule that was silently
# skipped is a merge that was silently allowed.
MODE=warn
PROOF_NAMES=()
PROOF_REGEX=()
landing_rules_load() {  # <project>
  local want=$1 text line project kind rest name regex seen lineno=0 rc mode_seen=0
  MODE=warn
  PROOF_NAMES=()
  PROOF_REGEX=()
  [ -e "$RULES" ] || [ -L "$RULES" ] || return 0
  [ -f "$RULES" ] && [ -r "$RULES" ] || {
    echo "error: config/landing-proof must be a readable regular file" >&2
    return 1
  }
  text=$(cat -- "$RULES" 2>/dev/null) || {
    echo "error: config/landing-proof could not be read" >&2
    return 1
  }
  # A UTF-8 byte-order mark glued to line 1 would make that rule read as some
  # other project's and drop it.
  case "$text" in
    $'\xef\xbb\xbf'*) text=${text#$'\xef\xbb\xbf'} ;;
  esac
  while [ -n "$text" ]; do
    line=${text%%"$NL"*}
    if [ "$line" = "$text" ]; then text=; else text=${text#*"$NL"}; fi
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    landing_trim "$line"
    line=$TRIMMED
    case "$line" in ''|'#'*) continue ;; esac
    project=${line%%[[:space:]]*}
    landing_trim "${line#"$project"}"
    rest=$TRIMMED
    kind=${rest%%[[:space:]]*}
    landing_trim "${rest#"$kind"}"
    rest=$TRIMMED
    case "$project" in
      *[!A-Za-z0-9._-]*)
        echo "error: config/landing-proof line $lineno: the project name holds characters outside letters, digits, '.', '_' and '-' (the file must be plain text)" >&2
        return 1
        ;;
    esac
    case "$kind" in
      mode)
        case "$rest" in
          warn|require) ;;
          *)
            echo "error: config/landing-proof line $lineno: mode must be warn or require" >&2
            return 1
            ;;
        esac
        [ "$project" = "$want" ] || continue
        [ "$mode_seen" -eq 0 ] || {
          echo "error: config/landing-proof line $lineno: mode is set twice for $want" >&2
          return 1
        }
        MODE=$rest
        mode_seen=1
        ;;
      proof)
        name=${rest%%[[:space:]]*}
        landing_trim "${rest#"$name"}"
        regex=$TRIMMED
        case "$name" in
          ''|[!a-z]*|*[!a-z0-9_-]*)
            echo "error: config/landing-proof line $lineno: proof name must match [a-z][a-z0-9_-]*" >&2
            return 1
            ;;
        esac
        [ -n "$regex" ] || {
          echo "error: config/landing-proof line $lineno: proof $name has no expression" >&2
          return 1
        }
        case "$regex" in
          *@COMMIT@*) ;;
          *)
            echo "error: config/landing-proof line $lineno: proof $name must contain @COMMIT@, or any old log would satisfy it" >&2
            return 1
            ;;
        esac
        # An expression grep cannot compile would silently never match.
        rc=0
        printf '' | LC_ALL=C grep -E -q -- "${regex//@COMMIT@/0}" 2>/dev/null || rc=$?
        [ "$rc" -le 1 ] || {
          echo "error: config/landing-proof line $lineno: proof $name is not a valid extended regular expression" >&2
          return 1
        }
        [ "$project" = "$want" ] || continue
        for seen in ${PROOF_NAMES[@]+"${PROOF_NAMES[@]}"}; do
          [ "$seen" != "$name" ] || {
            echo "error: config/landing-proof line $lineno: proof $name is defined twice for $want" >&2
            return 1
          }
        done
        PROOF_NAMES[${#PROOF_NAMES[@]}]=$name
        PROOF_REGEX[${#PROOF_REGEX[@]}]=$regex
        ;;
      *)
        echo "error: config/landing-proof line $lineno: expected 'mode' or 'proof' after the project name" >&2
        return 1
        ;;
    esac
  done
  if [ "$mode_seen" -eq 1 ] && [ "${#PROOF_NAMES[@]}" -eq 0 ]; then
    echo "error: config/landing-proof sets a mode for $want but no proof rule, so nothing would be required" >&2
    return 1
  fi
  return 0
}

# landing_log_proves <expression-for-this-commit> <file>: 0 iff the file is a
# regular, non-symlink file holding a line the expression matches. -a because a
# build log may carry stray bytes that would make grep call the file binary and
# hide a real pass line.
landing_log_proves() {
  [ -f "$2" ] && [ ! -L "$2" ] && [ -r "$2" ] || return 1
  LC_ALL=C grep -a -E -q -- "$1" "$2" 2>/dev/null
}

ID=
META=
PROJ=
PROJECT=
BRANCH=
RECORD=
COMMIT=
landing_task_load() {  # <task-id>
  fm_pr_task_id_valid "${1-}" || { echo "error: invalid task id" >&2; exit 2; }
  ID=$1
  META="$STATE/$ID.meta"
  RECORD="$STATE/$ID.landing-proof"
  [ -f "$META" ] || die "no meta for task $ID at $META"
  PROJ=$(grep '^project=' "$META" | cut -d= -f2- || true)
  [ -n "$PROJ" ] || die "task $ID records no project"
  PROJECT=$(basename "$PROJ")
  BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
  [ -n "$BRANCH" ] || BRANCH="fm/$ID"
}

# A full commit id: 40 hex digits, or 64 in a SHA-256 repository.
landing_commit_resolve() {  # [<id>]
  if [ -n "${1-}" ]; then
    case "$1" in
      *[!0-9a-f]*) die "--commit must be a full lowercase commit id" ;;
    esac
    case "${#1}" in
      40|64) ;;
      *) die "--commit must be a full lowercase commit id" ;;
    esac
    COMMIT=$1
    return 0
  fi
  COMMIT=$(git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH^{commit}" 2>/dev/null) \
    || die "cannot resolve branch $BRANCH in $PROJ"
}

# The record is read once into memory, so one decision never mixes two versions
# of it, and re-read only after this script itself rewrites it.
RECORD_TEXT=
landing_record_load() {
  RECORD_TEXT=
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  RECORD_TEXT=$(cat -- "$RECORD" 2>/dev/null) || RECORD_TEXT=
}

record_get() {  # <key>
  local key=$1 text=$RECORD_TEXT line
  while [ -n "$text" ]; do
    line=${text%%"$NL"*}
    if [ "$line" = "$text" ]; then text=; else text=${text#*"$NL"}; fi
    case "$line" in
      "$key="*)
        printf '%s' "${line#"$key="}"
        return 0
        ;;
    esac
  done
  return 0
}

# landing_record_proves <index>: 0 iff the record proves that configured proof
# for COMMIT: same commit, the log still byte-identical to what was recorded,
# and its line still there.
landing_record_proves() {
  local name=${PROOF_NAMES[$1]} regex=${PROOF_REGEX[$1]//@COMMIT@/$COMMIT} log sum
  [ "$(record_get commit)" = "$COMMIT" ] || return 1
  log=$(record_get "proof.$name.log")
  sum=$(record_get "proof.$name.sha256")
  [ -n "$log" ] && [ -n "$sum" ] || return 1
  landing_log_proves "$regex" "$log" || return 1
  [ "$(landing_sha256 "$log" 2>/dev/null)" = "$sum" ]
}

# Names of the configured proofs the record does NOT prove for COMMIT, comma
# separated.
landing_record_missing() {
  local i=0 out=''
  while [ "$i" -lt "${#PROOF_NAMES[@]}" ]; do
    landing_record_proves "$i" || out="$out${out:+,}${PROOF_NAMES[$i]}"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

landing_record_waiver() {  # prints the waiver reason when the record waives COMMIT
  [ "$(record_get commit)" = "$COMMIT" ] || return 0
  record_get waived
}

# Write the record for COMMIT from the parallel arrays W_NAMES / W_LOGS (and a
# waiver when WAIVED is set). The whole text is built first and the file is
# replaced in one rename, so a reader never sees half a record and a failed
# write leaves the old one in place.
W_NAMES=()
W_LOGS=()
WAIVED=
landing_record_write() {
  local tmp="$RECORD.tmp.$$" i=0 body sum
  body="schema=1${NL}commit=$COMMIT${NL}written_at=$(date +%s)${NL}"
  while [ "$i" -lt "${#W_NAMES[@]}" ]; do
    sum=$(landing_sha256 "${W_LOGS[$i]}" 2>/dev/null) || sum=
    [ -n "$sum" ] || die "could not hash ${W_LOGS[$i]}"
    body="${body}proof.${W_NAMES[$i]}.log=${W_LOGS[$i]}${NL}proof.${W_NAMES[$i]}.sha256=$sum${NL}"
    i=$((i + 1))
  done
  [ -z "$WAIVED" ] || body="${body}waived=$WAIVED${NL}"
  if ! printf '%s' "$body" 2>/dev/null > "$tmp" || ! mv -f "$tmp" "$RECORD" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null || true
    die "could not write $RECORD"
  fi
  RECORD_TEXT=${body%"$NL"}
}

# "<mtime> <path>" for each NUL-separated path on stdin.
landing_mtime_lines() {
  if [ "$(uname)" = Darwin ]; then
    xargs -0 /usr/bin/stat -f '%m %N' 2>/dev/null
  else
    xargs -0 stat -c '%Y %n' 2>/dev/null
  fi
}

# Look under the task's proof folder for each configured proof the record does
# not already prove, and rewrite the record with everything proven so far, so a
# shortfall names exactly what is still owed. Two levels and no deeper: a worker
# keeps a rerun's logs in one sub-folder per validated commit, and the folders
# below that hold build output that must never be walked. find, not a shell
# glob handed to ls: a folder with thousands of logs overflows an argument list,
# and find neither follows a symlinked sub-folder nor reports a directory that
# happens to be named *.log.
landing_discover() {
  local dir listing='' i=0 name regex found
  W_NAMES=()
  W_LOGS=()
  dir=$(cd "$DATA/$ID" 2>/dev/null && pwd) || dir=
  if [ -n "$dir" ]; then
    listing=$(find "$dir" -maxdepth 2 -type f -name '*.log' \
      -size "-${FM_LANDING_PROOF_MAX_LOG_BYTES}c" -print0 2>/dev/null \
      | landing_mtime_lines | LC_ALL=C sort -rn | head -n "$FM_LANDING_PROOF_MAX_LOGS" | cut -d' ' -f2-) || listing=
  fi
  while [ "$i" -lt "${#PROOF_NAMES[@]}" ]; do
    name=${PROOF_NAMES[$i]}
    regex=${PROOF_REGEX[$i]//@COMMIT@/$COMMIT}
    found=
    if landing_record_proves "$i"; then
      found=$(record_get "proof.$name.log")
    elif [ -n "$listing" ]; then
      # One grep over the whole candidate list, in list order, so the newest
      # log that proves the commit is the one recorded.
      found=$(printf '%s\n' "$listing" | tr '\n' '\0' \
        | LC_ALL=C xargs -0 grep -a -E -l -- "$regex" 2>/dev/null | head -n 1) || found=
      if [ -n "$found" ] && ! landing_log_proves "$regex" "$found"; then
        found=
      fi
    fi
    if [ -n "$found" ]; then
      W_NAMES[${#W_NAMES[@]}]=$name
      W_LOGS[${#W_LOGS[@]}]=$found
    fi
    i=$((i + 1))
  done
  [ "${#W_NAMES[@]}" -gt 0 ] || return 1
  WAIVED=$(landing_record_waiver)
  landing_record_write
}

landing_names_joined() {
  local i=0 out=''
  while [ "$i" -lt "${#PROOF_NAMES[@]}" ]; do
    out="$out${out:+, }${PROOF_NAMES[$i]}"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

# --- verbs ------------------------------------------------------------------

VERB=${1-}
[ -n "$VERB" ] || { usage >&2; exit 2; }
shift
case "$VERB" in
  -h|--help|help) usage; exit 0 ;;
  gate|write|waive|landed|show) ;;
  *) usage >&2; exit 2 ;;
esac
[ $# -ge 1 ] || { usage >&2; exit 2; }
landing_task_load "$1"
shift

COMMIT_ARG=
REASON=
ARG_NAMES=()
ARG_LOGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --commit)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      COMMIT_ARG=$2
      shift 2
      ;;
    --commit=*) COMMIT_ARG=${1#--commit=}; shift ;;
    --reason)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      REASON=$2
      shift 2
      ;;
    --reason=*) REASON=${1#--reason=}; shift ;;
    --proof)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      case "$2" in
        *"$NL"*) echo "error: a proof path cannot contain a line break" >&2; exit 2 ;;
        *=*) ;;
        *) usage >&2; exit 2 ;;
      esac
      ARG_NAMES[${#ARG_NAMES[@]}]=${2%%=*}
      ARG_LOGS[${#ARG_LOGS[@]}]=${2#*=}
      shift 2
      ;;
    *) usage >&2; exit 2 ;;
  esac
done

landing_record_load

case "$VERB" in
  show)
    if [ -n "$RECORD_TEXT" ]; then
      printf '%s\n' "$RECORD_TEXT"
    else
      echo "no landing proof recorded for $ID"
    fi
    exit 0
    ;;
esac

landing_rules_load "$PROJECT" || die "landing proof rules could not be read as written; fix config/landing-proof"

case "$VERB" in
  gate)
    # No rules for this project: nothing is required and nothing is recorded.
    [ "${#PROOF_NAMES[@]}" -gt 0 ] || exit 0
    landing_commit_resolve "$COMMIT_ARG"
    short=$(printf '%s' "$COMMIT" | cut -c1-12)
    waiver=$(landing_record_waiver)
    if [ -n "$waiver" ]; then
      echo "landing proof: waived for $ID at $short: $waiver" >&2
      exit 0
    fi
    missing=$(landing_record_missing)
    if [ -n "$missing" ]; then
      landing_discover || true
      missing=$(landing_record_missing)
    fi
    if [ -z "$missing" ]; then
      echo "landing proof: $(landing_names_joined) proven for $ID at $short" >&2
      exit 0
    fi
    if [ "$MODE" = require ]; then
      echo "error: no landing proof for $ID at $short: missing $missing." >&2
      echo "Each proof is a log under $DATA/$ID/ holding the line config/landing-proof names for this exact commit." >&2
      echo "Run the missing validation on this commit, or record why it does not apply: bin/fm-landing-proof.sh waive $ID --reason \"<why>\"" >&2
      exit 1
    fi
    echo "warning: no landing proof for $ID at $short: missing $missing (config/landing-proof mode is warn, so the merge proceeds)" >&2
    exit 0
    ;;

  write)
    [ "${#PROOF_NAMES[@]}" -gt 0 ] || die "project $PROJECT has no rules in config/landing-proof; nothing to record"
    [ "${#ARG_NAMES[@]}" -gt 0 ] || { usage >&2; exit 2; }
    j=0
    while [ "$j" -lt "${#ARG_NAMES[@]}" ]; do
      known=0
      for name in "${PROOF_NAMES[@]}"; do
        [ "$name" != "${ARG_NAMES[$j]}" ] || known=1
      done
      [ "$known" -eq 1 ] || die "proof ${ARG_NAMES[$j]} is not defined for $PROJECT in config/landing-proof"
      j=$((j + 1))
    done
    landing_commit_resolve "$COMMIT_ARG"
    # Start from what the record already proves for this commit, so a gate log
    # recorded now and a parity log recorded later end up in one record.
    W_NAMES=()
    W_LOGS=()
    i=0
    while [ "$i" -lt "${#PROOF_NAMES[@]}" ]; do
      name=${PROOF_NAMES[$i]}
      regex=${PROOF_REGEX[$i]//@COMMIT@/$COMMIT}
      log=
      j=0
      while [ "$j" -lt "${#ARG_NAMES[@]}" ]; do
        if [ "${ARG_NAMES[$j]}" = "$name" ]; then
          log=${ARG_LOGS[$j]}
          [ -f "$log" ] && [ ! -L "$log" ] || die "proof $name: $log is not a regular file"
          log="$(cd "$(dirname "$log")" && pwd)/$(basename "$log")"
          landing_log_proves "$regex" "$log" \
            || die "proof $name: $log holds no line matching the rule for commit $COMMIT"
        fi
        j=$((j + 1))
      done
      if [ -z "$log" ] && landing_record_proves "$i"; then
        log=$(record_get "proof.$name.log")
      fi
      if [ -n "$log" ]; then
        W_NAMES[${#W_NAMES[@]}]=$name
        W_LOGS[${#W_LOGS[@]}]=$log
      fi
      i=$((i + 1))
    done
    # A waiver already recorded for this commit stays in force.
    WAIVED=$(landing_record_waiver)
    landing_record_write
    missing=$(landing_record_missing)
    if [ -n "$missing" ]; then
      echo "recorded for $ID at $COMMIT; still missing: $missing"
    else
      echo "recorded for $ID at $COMMIT: $(landing_names_joined) proven"
    fi
    ;;

  waive)
    [ "${#PROOF_NAMES[@]}" -gt 0 ] || die "project $PROJECT has no rules in config/landing-proof; there is nothing to waive"
    REASON=$(printf '%s' "$REASON" | tr '\n\r\t' '   ' | tr -d '\000-\010\013-\037' | cut -c1-240)
    case "$REASON" in
      *[![:space:]]*) ;;
      *) echo "error: a waiver needs --reason <text>" >&2; exit 2 ;;
    esac
    landing_commit_resolve "$COMMIT_ARG"
    # Keep whatever is already proven for this commit beside the waiver.
    W_NAMES=()
    W_LOGS=()
    i=0
    while [ "$i" -lt "${#PROOF_NAMES[@]}" ]; do
      if landing_record_proves "$i"; then
        W_NAMES[${#W_NAMES[@]}]=${PROOF_NAMES[$i]}
        W_LOGS[${#W_LOGS[@]}]=$(record_get "proof.${PROOF_NAMES[$i]}.log")
      fi
      i=$((i + 1))
    done
    WAIVED=$REASON
    landing_record_write
    echo "waived landing proof for $ID at $COMMIT: $REASON"
    ;;

  landed)
    [ "${#PROOF_NAMES[@]}" -gt 0 ] || exit 0
    [ -n "$COMMIT_ARG" ] || { usage >&2; exit 2; }
    landing_commit_resolve "$COMMIT_ARG"
    # One line per landed commit: re-running the merge on a task that already
    # landed must not record the landing twice.
    if [ -f "$HISTORY" ] && grep -F -q -- " task=$ID project=$PROJECT commit=$COMMIT " "$HISTORY" 2>/dev/null; then
      exit 0
    fi
    waiver=$(landing_record_waiver)
    if [ -n "$waiver" ]; then
      result="waived reason=$waiver"
    else
      missing=$(landing_record_missing)
      if [ -z "$missing" ]; then
        result=proven
        i=0
        while [ "$i" -lt "${#PROOF_NAMES[@]}" ]; do
          name=${PROOF_NAMES[$i]}
          result="$result $name=$(record_get "proof.$name.sha256" | cut -c1-16)"
          i=$((i + 1))
        done
      else
        result="missing=$missing"
      fi
    fi
    printf '%s task=%s project=%s commit=%s mode=%s %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ID" "$PROJECT" "$COMMIT" "$MODE" "$result" >> "$HISTORY"
    ;;
esac
