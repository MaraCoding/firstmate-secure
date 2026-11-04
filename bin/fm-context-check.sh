#!/usr/bin/env bash
# fm-context-check.sh - report a crewmate session's live context size (last turn's input tokens).
# Usage: fm-context-check.sh [--limit <tokens>] <task-id|session.jsonl>
#   A task id resolves through this home's state/<id>.meta: harness=, worktree=,
#   spawn_gen=, and any account= pin. Pi sessions are read from
#   <pi-root>/sessions/--<worktree with / as ->--/*.jsonl, where <pi-root> is
#   the pinned account root, else $PI_CODING_AGENT_DIR, else ~/.pi/agent.
#   Claude transcripts are read from <claude-root>/projects/<worktree with every
#   non-alphanumeric byte as ->/*.jsonl, where <claude-root> is the pinned
#   account root, else $CLAUDE_CONFIG_DIR, else ~/.claude. Treehouse slots are
#   reused, so only sessions written since the task's spawn_gen time count, and
#   the most recently written one wins (a relaunch starts a new session).
#   A path argument reads that session file directly (Pi when its first record
#   is a `session` header, Claude otherwise).
# Context is the last real assistant turn's prompt size: Pi input + cacheRead +
# cacheWrite; Claude input_tokens + cache_read_input_tokens +
# cache_creation_input_tokens. Only the file's tail is scanned.
# Limit: --limit, else FM_CREW_CONTEXT_LIMIT, else config/crew-context-limit
# (one positive integer), else 250000. Past it, end the session and respawn with
# a handoff brief instead of steering (AGENTS.md section 7); fm-send.sh refuses
# a text steer to a ship or scout past it unless given --allow-large-context.
# Output, one line:
#   context: <tokens> · limit: <limit> · over: <yes|no> · harness: <h> · model: <m> · at: <ts> · session: <file>
# or `context: unknown · <reason>` when no session or usage can be found.
# Exit: 0 at or under the limit, 3 over it, 4 unknown, 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FM_CONTEXT_DEFAULT_LIMIT=250000

usage() {
  echo "usage: fm-context-check.sh [--limit <tokens>] <task-id|session.jsonl>" >&2
}

LIMIT=
TARGET=
while [ $# -gt 0 ]; do
  case "$1" in
  --limit)
    [ $# -ge 2 ] || { usage; exit 2; }
    LIMIT=$2
    shift 2
    ;;
  --limit=*) LIMIT=${1#--limit=}; shift ;;
  -h | --help)
    sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"
    exit 0
    ;;
  -*) usage; exit 2 ;;
  *)
    [ -z "$TARGET" ] || { usage; exit 2; }
    TARGET=$1
    shift
    ;;
  esac
done
[ -n "$TARGET" ] || { usage; exit 2; }
command -v jq >/dev/null 2>&1 || { echo "error: fm-context-check.sh needs jq" >&2; exit 2; }

fm_context_valid_limit() { case "$1" in '' | *[!0-9]* | 0*) return 1 ;; esac; return 0; }

if [ -z "$LIMIT" ]; then
  if [ -n "${FM_CREW_CONTEXT_LIMIT:-}" ]; then
    LIMIT=$FM_CREW_CONTEXT_LIMIT
  elif [ -f "$CONFIG/crew-context-limit" ]; then
    LIMIT=$(tr -d '[:space:]' <"$CONFIG/crew-context-limit")
    fm_context_valid_limit "$LIMIT" || {
      echo "error: config/crew-context-limit must hold one positive integer token count: $CONFIG/crew-context-limit" >&2
      exit 2
    }
  else
    LIMIT=$FM_CONTEXT_DEFAULT_LIMIT
  fi
fi
fm_context_valid_limit "$LIMIT" || { echo "error: context limit must be a positive integer: $LIMIT" >&2; exit 2; }

unknown() { printf 'context: unknown · %s\n' "$1"; exit 4; }

meta_get() {  # <meta> <key>: last value, empty when absent
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1
}

# Newest *.jsonl directly in <dir> modified at or after <epoch>.
newest_session() {  # <dir> <epoch>
  local dir=$1 since=$2 f m best='' best_m=0
  [ -d "$dir" ] || return 0
  for f in "$dir"/*.jsonl; do
    [ -f "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || continue
    [ "$m" -ge "$since" ] || continue
    if [ "$m" -gt "$best_m" ]; then best=$f; best_m=$m; fi
  done
  printf '%s' "$best"
}

HARNESS=
SESSION=
if [ -f "$TARGET" ]; then
  SESSION=$TARGET
  if head -n 1 "$SESSION" | jq -e 'select(.type == "session")' >/dev/null 2>&1; then
    HARNESS=pi
  else
    HARNESS=claude
  fi
else
  case "$TARGET" in fm-*) [ -f "$STATE/$TARGET.meta" ] || TARGET=${TARGET#fm-} ;; esac
  META="$STATE/$TARGET.meta"
  [ -f "$META" ] || unknown "no task record $META"
  HARNESS=$(meta_get "$META" harness)
  WT=$(meta_get "$META" worktree)
  ACCOUNT=$(meta_get "$META" account)
  SPAWN_GEN=$(meta_get "$META" spawn_gen)
  SINCE=${SPAWN_GEN#s}
  SINCE=${SINCE%%.*}
  case "$SINCE" in '' | *[!0-9]*) SINCE=0 ;; esac
  # A session can be created a moment before the record's stamp is minted.
  [ "$SINCE" -le 120 ] || SINCE=$((SINCE - 120))
  [ -n "$WT" ] || unknown "task $TARGET records no worktree="
  case "$HARNESS" in
  pi | pi-signed)
    HARNESS=pi
    case "$ACCOUNT" in
    /*) ROOT=$ACCOUNT ;;
    *) ROOT=${FM_CONTEXT_PI_ROOT:-${PI_CODING_AGENT_DIR:-$HOME/.pi/agent}} ;;
    esac
    for cwd in "$WT" "$(cd "$WT" 2>/dev/null && pwd -P)"; do
      [ -n "$cwd" ] || continue
      enc=${cwd#/}
      SESSION=$(newest_session "$ROOT/sessions/--${enc//\//-}--" "$SINCE")
      [ -z "$SESSION" ] || break
    done
    ;;
  claude)
    case "$ACCOUNT" in
    /*) ROOT=$ACCOUNT ;;
    *) ROOT=${FM_CONTEXT_CLAUDE_ROOT:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}} ;;
    esac
    for cwd in "$WT" "$(cd "$WT" 2>/dev/null && pwd -P)"; do
      [ -n "$cwd" ] || continue
      SESSION=$(newest_session "$ROOT/projects/$(printf '%s' "$cwd" | sed 's/[^A-Za-z0-9]/-/g')" "$SINCE")
      [ -z "$SESSION" ] || break
    done
    ;;
  *) unknown "harness ${HARNESS:-unrecorded} has no session reader (pi and claude only)" ;;
  esac
  [ -n "$SESSION" ] || unknown "no $HARNESS session for $WT written since the task's spawn"
fi

# Scan the tail newest-first for the last assistant row with real usage.
if [ "$HARNESS" = pi ]; then
  FILTER='select(.type == "message" and .message.role == "assistant" and (.message.usage | type) == "object")
    | .message as $m | (($m.usage.input // 0) + ($m.usage.cacheRead // 0) + ($m.usage.cacheWrite // 0)) as $c
    | select($c > 0) | "\($c)\t\($m.model // "?")\t\(.timestamp // "?")"'
else
  FILTER='select(.type == "assistant" and (.isSidechain | not) and (.message.usage | type) == "object" and .message.model != "<synthetic>")
    | .message as $m | (($m.usage.input_tokens // 0) + ($m.usage.cache_read_input_tokens // 0) + ($m.usage.cache_creation_input_tokens // 0)) as $c
    | select($c > 0) | "\($c)\t\($m.model // "?")\t\(.timestamp // "?")"'
fi
ROW=$(tac "$SESSION" 2>/dev/null | grep -m 40 '"usage"' | jq -R -r "fromjson? | $FILTER" 2>/dev/null | head -n 1)
[ -n "$ROW" ] || unknown "no assistant turn with usage in $SESSION"
CTX=${ROW%%$'\t'*}
REST=${ROW#*$'\t'}
MODEL=${REST%%$'\t'*}
AT=${REST#*$'\t'}
OVER=no
[ "$CTX" -le "$LIMIT" ] || OVER=yes
printf 'context: %s · limit: %s · over: %s · harness: %s · model: %s · at: %s · session: %s\n' \
  "$CTX" "$LIMIT" "$OVER" "$HARNESS" "$MODEL" "$AT" "$SESSION"
[ "$OVER" = no ] || exit 3
exit 0
