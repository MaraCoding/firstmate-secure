#!/usr/bin/env bash
# fm-review-tier.sh - decide from the diff alone which independent review a finished change needs.
# Usage: fm-review-tier.sh <repo-path> <base-ref> <head-ref> [--rules <file>] [--json]
#
# Read-only and network-free: it resolves the two refs and reads one
# `git diff --numstat` of what <head-ref> changed since it forked from
# <base-ref>, the comparison bin/fm-review-diff.sh shows. It never fetches,
# checks out, writes, or locks anything, in the repository or in this home, so
# the refs are only as current as the caller left them.
#
# Tiers, highest first; the verdict is the highest one any path or the size gives:
#   cross-family  a changed production path matches a cross-family rule
#   standard      a changed production path matches a standard rule, or the
#                 change has at least `threshold` changed production lines
#   none          anything else: documentation or tests only, and small
#                 changes no rule names
# The ship-landing skill owns what firstmate does with each tier; the
# `requires:` line repeats it only as a reminder at the point of decision.
#
# Rules file (blank lines and lines starting with # are ignored):
#   <path-glob> <tier> <reason...>  A path rule. The first rule that matches a
#                                   path decides it. Tier none says the path is
#                                   not a risk path, which carves an exception
#                                   out of a broader rule written after it; its
#                                   lines still count toward the size.
#   threshold=<lines>               The size trigger for standard; 300 when no
#                                   file sets one.
#   nonprod=<path-glob>...          Not production: tests, documentation,
#                                   generated files, lock files. Their lines
#                                   never count and no path rule sees them.
#   prod=<path-glob>...             Production even though a nonprod glob
#                                   matches, such as a policy README or a
#                                   schema kept under docs/.
#   Path globs follow .gitignore: a glob with no slash matches a file or
#   directory name at any depth, one with a slash is anchored at the repository
#   root (a leading `/` or `./` does only that), a `**/` also matches no
#   directory at all, a trailing slash matches only what lies beneath that
#   directory, and a match on a directory covers everything beneath it. Unlike
#   .gitignore, `*` also matches `/`, there is no `!` negation, and a glob
#   cannot hold whitespace (write `?` for a space).
#
# Which rules apply: --rules <file> reads that file alone. Otherwise this
#   home's config/review-tiers, when present, is read before the tracked
#   config-defaults/review-tiers: its path rules are tried first, its
#   threshold replaces the default one, and its nonprod and prod globs add to
#   the defaults'.
#
# What is counted: changed production lines are the added plus the deleted
#   lines `git diff --numstat` reports for production files. A rename counts
#   only the lines that changed, and both of its names are classified: moving
#   a file out of a risk path still matches that path's rule, and the file is
#   production when either name is. A deleted file counts its deleted lines
#   and is matched like any other path. A binary file has no line count: it is
#   matched against the rules and reported, never counted. A diff with no
#   changes is tier none on the basis no-changes.
#
# Output (stdout): a `review-tier:` block of `  key: value` lines, in this order:
#   tier, basis (path-rule | size | below-threshold | non-production |
#   no-changes), reason, requires, production_lines, files, risk_paths (then
#   one line per matched path with its rule and where that rule is written,
#   the first 20), an optional note naming non-production paths a risk rule
#   would have matched, diff, rules.
#   --json prints the same facts as one JSON object on one line: tier, basis,
#   reason, requires, production_lines, production_added, production_deleted,
#   threshold, files_changed, production_files, nonproduction_files,
#   binary_files, risk_paths (every matched path, as objects with path, tier,
#   glob, reason, source, note), nonproduction_rule_matches, base, head,
#   base_commit, head_commit, fork_commit, rules.
#
# Environment: FM_HOME, FM_CONFIG_OVERRIDE, and FM_ROOT_OVERRIDE resolve the
#   home and the tracked defaults exactly as the other bin/ scripts do.
#
# Exit status: 0 with a verdict; 1 when the repository, a ref, or a rules file
#   cannot be read or a rules line is malformed, so a broken input is never a
#   silent none; 2 on a usage error.
set -u
# Rule globs are patterns for `case`; they must never expand against the
# filesystem while a rules line or a pattern list is word-split.
set -f
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

THRESHOLD_DEFAULT=300
RISK_LIST_CAP=20
NOTE_LIST_CAP=5

usage() {
  echo "usage: fm-review-tier.sh <repo-path> <base-ref> <head-ref> [--rules <file>] [--json]" >&2
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

REPO='' BASE='' HEAD_REF='' RULES_ARG='' JSON=0 POSITIONALS=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help)
      sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    --json) JSON=1 ;;
    --rules)
      if [ $# -lt 2 ] || [ -z "$2" ]; then
        echo "error: --rules needs a file" >&2
        usage
        exit 2
      fi
      RULES_ARG=$2
      shift
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage
      exit 2
      ;;
    *)
      POSITIONALS=$((POSITIONALS + 1))
      case "$POSITIONALS" in
        1) REPO=$1 ;;
        2) BASE=$1 ;;
        3) HEAD_REF=$1 ;;
      esac
      ;;
  esac
  shift
done
if [ "$POSITIONALS" -ne 3 ] || [ -z "$REPO" ] || [ -z "$BASE" ] || [ -z "$HEAD_REF" ]; then
  usage
  exit 2
fi

# --- rules ------------------------------------------------------------------

# fm_review_tier_patterns <glob>: set FM_RT_PATTERNS to the `case` patterns the
# glob stands for, space-separated; non-zero when the glob names nothing.
# A glob never holds whitespace, so the list splits back unambiguously.
fm_review_tier_patterns() {
  local glob=$1 dironly=0 todo g seen=' ' out='' prefix rest head
  local leading='**/' inner='/**/'
  FM_RT_PATTERNS=''
  case "$glob" in */) dironly=1 glob=${glob%/} ;; esac
  case "$glob" in ./*) glob=${glob#.} ;; esac
  case "$glob" in
    /*) glob=${glob#/} ;;
    */*) ;;
    ?*) glob="$leading$glob" ;;
  esac
  [ -n "$glob" ] || return 1
  todo=$glob
  while [ -n "$todo" ]; do
    g=${todo%% *}
    case "$todo" in *' '*) todo=${todo#* } ;; *) todo='' ;; esac
    case "$seen" in *" $g "*) continue ;; esac
    seen="$seen$g "
    [ "$dironly" = 1 ] || out="$out $g"
    out="$out $g/*"
    # Every `**/` may also stand for no directory at all, so queue the glob
    # again with each one dropped.
    case "$g" in
      "$leading"*)
        rest=${g#"$leading"}
        todo="${todo:+$todo }$rest"
        ;;
    esac
    prefix='' rest=$g
    while :; do
      case "$rest" in
        *"$inner"*)
          head=${rest%%"$inner"*}
          rest=${rest#*"$inner"}
          todo="${todo:+$todo }$prefix$head/$rest"
          prefix="$prefix$head$inner"
          ;;
        *) break ;;
      esac
    done
  done
  FM_RT_PATTERNS=${out# }
}

# fm_review_tier_match <patterns> <path>: 0 when any of the patterns matches.
fm_review_tier_match() {
  local pattern
  for pattern in $1; do
    # shellcheck disable=SC2254 # A rule glob must match as a pattern, not literally.
    case "$2" in $pattern) return 0 ;; esac
  done
  return 1
}

RULE_COUNT=0
RULE_GLOB=() RULE_TIER=() RULE_REASON=() RULE_SOURCE=() RULE_PATTERNS=()
THRESHOLD=''
NONPROD_PATTERNS='' PROD_PATTERNS=''
RULES_FILE_COUNT=0
RULES_FILES=()

# fm_review_tier_load <file> <label>: append one rules file. Files are loaded
# in precedence order, so path rules keep that order and the first threshold
# read stands.
fm_review_tier_load() {
  local file=$1 label=$2 n=0 line key value word glob tier reason threshold=''
  [ -f "$file" ] && [ -r "$file" ] || die "rules file is not a readable regular file: $file"
  RULES_FILES[RULES_FILE_COUNT]=$file
  RULES_FILE_COUNT=$((RULES_FILE_COUNT + 1))
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    # Trim both ends; the trailing trim also drops a CR from a CRLF file.
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in
      threshold=*)
        value=${line#threshold=}
        case "$value" in
          '' | *[!0-9]* | 0*) die "$label:$n: threshold must be a positive whole number of lines" ;;
        esac
        [ "${#value}" -le 9 ] || die "$label:$n: threshold is too large"
        [ -z "$threshold" ] || die "$label:$n: threshold is set twice"
        threshold=$value
        ;;
      nonprod=* | prod=*)
        key=${line%%=*}
        value=${line#*=}
        for word in $value; do
          case "$word" in '!'*) die "$label:$n: negated glob '$word' is not supported" ;; esac
          fm_review_tier_patterns "$word" || die "$label:$n: glob '$word' names nothing"
          if [ "$key" = nonprod ]; then
            NONPROD_PATTERNS="$NONPROD_PATTERNS $FM_RT_PATTERNS"
          else
            PROD_PATTERNS="$PROD_PATTERNS $FM_RT_PATTERNS"
          fi
        done
        ;;
      *)
        # Split on the first two runs of whitespace; the reason keeps its own.
        glob=${line%%[[:space:]]*}
        reason=${line#"$glob"}
        reason=${reason#"${reason%%[![:space:]]*}"}
        tier=${reason%%[[:space:]]*}
        reason=${reason#"$tier"}
        reason=${reason#"${reason%%[![:space:]]*}"}
        case "$tier" in
          cross-family | standard | none) ;;
          '') die "$label:$n: expected '<path-glob> <tier> <reason>', threshold=, nonprod=, or prod=" ;;
          *) die "$label:$n: unknown tier '$tier' (cross-family, standard, or none)" ;;
        esac
        [ -n "$reason" ] || die "$label:$n: a path rule needs a reason after its tier"
        case "$glob" in '!'*) die "$label:$n: negated glob '$glob' is not supported" ;; esac
        fm_review_tier_patterns "$glob" || die "$label:$n: glob '$glob' names nothing"
        RULE_GLOB[RULE_COUNT]=$glob
        RULE_TIER[RULE_COUNT]=$tier
        RULE_REASON[RULE_COUNT]=$reason
        RULE_SOURCE[RULE_COUNT]="$label:$n"
        RULE_PATTERNS[RULE_COUNT]=$FM_RT_PATTERNS
        RULE_COUNT=$((RULE_COUNT + 1))
        ;;
    esac
  done <"$file"
  [ -n "$THRESHOLD" ] || THRESHOLD=$threshold
}

if [ -n "$RULES_ARG" ]; then
  fm_review_tier_load "$RULES_ARG" "$RULES_ARG"
else
  if [ -e "$CONFIG/review-tiers" ] || [ -L "$CONFIG/review-tiers" ]; then
    fm_review_tier_load "$CONFIG/review-tiers" config/review-tiers
  fi
  fm_review_tier_load "$FM_ROOT/config-defaults/review-tiers" config-defaults/review-tiers
fi
[ -n "$THRESHOLD" ] || THRESHOLD=$THRESHOLD_DEFAULT

# --- the diff ---------------------------------------------------------------

# Reads never take git's optional locks, so a busy worktree is left alone.
export GIT_OPTIONAL_LOCKS=0

fm_review_tier_git() {
  git -C "$REPO" --no-pager "$@"
}

command -v git >/dev/null 2>&1 || die "git not found"
fm_review_tier_git rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $REPO"
BASE_SHA=$(fm_review_tier_git rev-parse --verify --quiet "$BASE^{commit}") \
  || die "unknown base ref '$BASE' in $REPO"
HEAD_SHA=$(fm_review_tier_git rev-parse --verify --quiet "$HEAD_REF^{commit}") \
  || die "unknown head ref '$HEAD_REF' in $REPO"
FORK_SHA=$(fm_review_tier_git merge-base "$BASE_SHA" "$HEAD_SHA" 2>/dev/null) \
  || die "'$BASE' and '$HEAD_REF' share no history in $REPO"

FILES=0 PROD_FILES=0 NONPROD_FILES=0 BINARY_FILES=0 ADDED=0 DELETED=0
RISK_COUNT=0
RISK_PATH=() RISK_RULE=() RISK_NOTE=()
CROSS_FIRST=-1 STANDARD_FIRST=-1
SHADOW_COUNT=0
SHADOW_PATH=()

# fm_review_tier_name <path> <note>: classify one name of a changed file. Sets
# FM_RT_PRODUCTION=1 when the name is production, and records either a risk
# path or a non-production path that a risk rule would have matched.
fm_review_tier_name() {
  local path=$1 note=$2 i=0 rule=-1
  while [ "$i" -lt "$RULE_COUNT" ]; do
    if fm_review_tier_match "${RULE_PATTERNS[i]}" "$path"; then
      rule=$i
      break
    fi
    i=$((i + 1))
  done
  if fm_review_tier_match "$NONPROD_PATTERNS" "$path" && ! fm_review_tier_match "$PROD_PATTERNS" "$path"; then
    if [ "$rule" -ge 0 ] && [ "${RULE_TIER[rule]}" != none ]; then
      SHADOW_PATH[SHADOW_COUNT]=$path
      SHADOW_COUNT=$((SHADOW_COUNT + 1))
    fi
    return 0
  fi
  FM_RT_PRODUCTION=1
  [ "$rule" -ge 0 ] || return 0
  case "${RULE_TIER[rule]}" in
    none) return 0 ;;
    cross-family) [ "$CROSS_FIRST" -ge 0 ] || CROSS_FIRST=$RISK_COUNT ;;
    standard) [ "$STANDARD_FIRST" -ge 0 ] || STANDARD_FIRST=$RISK_COUNT ;;
  esac
  RISK_PATH[RISK_COUNT]=$path
  RISK_RULE[RISK_COUNT]=$rule
  RISK_NOTE[RISK_COUNT]=$note
  RISK_COUNT=$((RISK_COUNT + 1))
}

# numstat -z ends every record with NUL and never quotes a path. A trailing
# status record stands in for the exit status a process substitution drops, so
# a diff that died part-way is an error instead of a short, quiet answer.
# The -c settings and flags on the diff pin its output against the diff
# configuration of the repository being read: rename detection on, paths
# relative to the root, and no external program run on its behalf.
DIFF_STATUS=''
while IFS= read -r -d '' record; do
  case "$record" in
    status=*)
      DIFF_STATUS=${record#status=}
      continue
      ;;
  esac
  added=${record%%$'\t'*}
  rest=${record#*$'\t'}
  deleted=${rest%%$'\t'*}
  path=${rest#*$'\t'}
  old=''
  if [ -z "$path" ]; then
    # A rename: its old and new names follow as two records of their own.
    IFS= read -r -d '' old || break
    IFS= read -r -d '' path || break
  fi
  FILES=$((FILES + 1))
  FM_RT_PRODUCTION=0
  if [ -n "$old" ]; then
    fm_review_tier_name "$old" "renamed to $path"
    fm_review_tier_name "$path" "renamed from $old"
  else
    fm_review_tier_name "$path" ''
  fi
  if [ "$FM_RT_PRODUCTION" = 1 ]; then
    PROD_FILES=$((PROD_FILES + 1))
    case "$added$deleted" in
      *[!0-9]*) BINARY_FILES=$((BINARY_FILES + 1)) ;;
      *)
        ADDED=$((ADDED + added))
        DELETED=$((DELETED + deleted))
        ;;
    esac
  else
    NONPROD_FILES=$((NONPROD_FILES + 1))
  fi
done < <(
  fm_review_tier_git -c diff.renames=true -c diff.relative=false diff --numstat -z -M \
    --no-ext-diff --no-textconv "$FORK_SHA" "$HEAD_SHA" --
  printf 'status=%s\0' "$?"
)
[ "$DIFF_STATUS" = 0 ] || die "git diff failed in $REPO (status ${DIFF_STATUS:-unknown})"

# --- verdict ----------------------------------------------------------------

PROD_LINES=$((ADDED + DELETED))
DECIDER=-1
if [ "$CROSS_FIRST" -ge 0 ]; then
  TIER=cross-family BASIS=path-rule DECIDER=$CROSS_FIRST
elif [ "$STANDARD_FIRST" -ge 0 ]; then
  TIER=standard BASIS=path-rule DECIDER=$STANDARD_FIRST
elif [ "$PROD_LINES" -ge "$THRESHOLD" ]; then
  TIER=standard BASIS=size
elif [ "$FILES" -eq 0 ]; then
  TIER=none BASIS=no-changes
elif [ "$PROD_FILES" -eq 0 ]; then
  TIER=none BASIS=non-production
else
  TIER=none BASIS=below-threshold
fi

case "$BASIS" in
  path-rule)
    rule=${RISK_RULE[DECIDER]}
    REASON="${RISK_PATH[DECIDER]} matches '${RULE_GLOB[rule]}' (${RULE_REASON[rule]}) [${RULE_SOURCE[rule]}]"
    [ -z "${RISK_NOTE[DECIDER]}" ] || REASON="$REASON, ${RISK_NOTE[DECIDER]}"
    ;;
  size) REASON="$PROD_LINES changed production lines, at or above the threshold of $THRESHOLD" ;;
  no-changes)
    if [ "$BASE_SHA" = "$HEAD_SHA" ]; then
      REASON="$BASE and $HEAD_REF are the same commit"
    elif [ "$FORK_SHA" = "$HEAD_SHA" ]; then
      REASON="$HEAD_REF is already contained in $BASE"
    else
      REASON="the commits $HEAD_REF adds to $BASE change no file"
    fi
    ;;
  non-production) REASON="only non-production files changed" ;;
  below-threshold) REASON="$PROD_LINES changed production lines, under the threshold of $THRESHOLD, and no path rule matched" ;;
esac

case "$TIER" in
  cross-family) REQUIRES="a reviewer from the other model family than the builder, reporting before the change lands, deploys, or goes live" ;;
  standard) REQUIRES="a same-family reviewer using the severity rubric" ;;
  none) REQUIRES="no independent review" ;;
esac

# --- output -----------------------------------------------------------------

# fm_review_tier_swap <text> <char> <replacement>: set FM_RT_SWAPPED to the
# text with every <char> replaced. It cuts and joins instead of using
# ${text//char/replacement}, whose handling of a backslash or a quote in the
# replacement differs between bash 3.2, 4.3, and 5.2.
fm_review_tier_swap() {
  local rest=$1 out='' head
  while :; do
    case "$rest" in
      *"$2"*)
        head=${rest%%"$2"*}
        rest=${rest#*"$2"}
        out=$out$head$3
        ;;
      *) break ;;
    esac
  done
  FM_RT_SWAPPED=$out$rest
}

# fm_review_tier_json <text>: print it as one JSON string. Control characters
# other than newline, carriage return, and tab are dropped.
fm_review_tier_json() {
  local backslash='\'
  fm_review_tier_swap "$1" "$backslash" "$backslash$backslash"
  fm_review_tier_swap "$FM_RT_SWAPPED" '"' "$backslash\""
  fm_review_tier_swap "$FM_RT_SWAPPED" $'\n' "${backslash}n"
  fm_review_tier_swap "$FM_RT_SWAPPED" $'\r' "${backslash}r"
  fm_review_tier_swap "$FM_RT_SWAPPED" $'\t' "${backslash}t"
  printf '"%s"' "${FM_RT_SWAPPED//[[:cntrl:]]/}"
}

# fm_review_tier_plain <text>: print it on one line for the text block.
fm_review_tier_plain() {
  printf '%s' "${1//[[:cntrl:]]/?}"
}

if [ "$JSON" = 1 ]; then
  printf '{"tier":"%s","basis":"%s","reason":' "$TIER" "$BASIS"
  fm_review_tier_json "$REASON"
  printf ',"requires":'
  fm_review_tier_json "$REQUIRES"
  printf ',"production_lines":%s,"production_added":%s,"production_deleted":%s,"threshold":%s' \
    "$PROD_LINES" "$ADDED" "$DELETED" "$THRESHOLD"
  printf ',"files_changed":%s,"production_files":%s,"nonproduction_files":%s,"binary_files":%s' \
    "$FILES" "$PROD_FILES" "$NONPROD_FILES" "$BINARY_FILES"
  printf ',"risk_paths":['
  i=0
  while [ "$i" -lt "$RISK_COUNT" ]; do
    rule=${RISK_RULE[i]}
    [ "$i" -eq 0 ] || printf ','
    printf '{"path":'
    fm_review_tier_json "${RISK_PATH[i]}"
    printf ',"tier":"%s","glob":' "${RULE_TIER[rule]}"
    fm_review_tier_json "${RULE_GLOB[rule]}"
    printf ',"reason":'
    fm_review_tier_json "${RULE_REASON[rule]}"
    printf ',"source":'
    fm_review_tier_json "${RULE_SOURCE[rule]}"
    printf ',"note":'
    fm_review_tier_json "${RISK_NOTE[i]}"
    printf '}'
    i=$((i + 1))
  done
  printf '],"nonproduction_rule_matches":['
  i=0
  while [ "$i" -lt "$SHADOW_COUNT" ]; do
    [ "$i" -eq 0 ] || printf ','
    fm_review_tier_json "${SHADOW_PATH[i]}"
    i=$((i + 1))
  done
  printf '],"base":'
  fm_review_tier_json "$BASE"
  printf ',"head":'
  fm_review_tier_json "$HEAD_REF"
  printf ',"base_commit":"%s","head_commit":"%s","fork_commit":"%s","rules":[' "$BASE_SHA" "$HEAD_SHA" "$FORK_SHA"
  i=0
  while [ "$i" -lt "$RULES_FILE_COUNT" ]; do
    [ "$i" -eq 0 ] || printf ','
    fm_review_tier_json "${RULES_FILES[i]}"
    i=$((i + 1))
  done
  printf ']}\n'
  exit 0
fi

printf 'review-tier:\n'
printf '  tier: %s\n' "$TIER"
printf '  basis: %s\n' "$BASIS"
printf '  reason: %s\n' "$(fm_review_tier_plain "$REASON")"
printf '  requires: %s\n' "$REQUIRES"
printf '  production_lines: %s (+%s -%s, threshold %s)\n' "$PROD_LINES" "$ADDED" "$DELETED" "$THRESHOLD"
printf '  files: %s changed, %s production, %s non-production, %s binary (no line count)\n' \
  "$FILES" "$PROD_FILES" "$NONPROD_FILES" "$BINARY_FILES"
printf '  risk_paths: %s\n' "$RISK_COUNT"
i=0
while [ "$i" -lt "$RISK_COUNT" ] && [ "$i" -lt "$RISK_LIST_CAP" ]; do
  rule=${RISK_RULE[i]}
  line="${RISK_PATH[i]} matches '${RULE_GLOB[rule]}' (${RULE_REASON[rule]}) [${RULE_SOURCE[rule]}]"
  [ -z "${RISK_NOTE[i]}" ] || line="$line, ${RISK_NOTE[i]}"
  printf '    %s %s\n' "${RULE_TIER[rule]}" "$(fm_review_tier_plain "$line")"
  i=$((i + 1))
done
[ "$RISK_COUNT" -le "$RISK_LIST_CAP" ] \
  || printf '    ... and %s more (--json lists every one)\n' "$((RISK_COUNT - RISK_LIST_CAP))"
if [ "$SHADOW_COUNT" -gt 0 ]; then
  line=''
  i=0
  while [ "$i" -lt "$SHADOW_COUNT" ] && [ "$i" -lt "$NOTE_LIST_CAP" ]; do
    line="${line:+$line, }${SHADOW_PATH[i]}"
    i=$((i + 1))
  done
  [ "$SHADOW_COUNT" -le "$NOTE_LIST_CAP" ] || line="$line, and $((SHADOW_COUNT - NOTE_LIST_CAP)) more"
  printf '  note: %s non-production path(s) match a risk rule and were left out (a prod= line would count them): %s\n' \
    "$SHADOW_COUNT" "$(fm_review_tier_plain "$line")"
fi
printf '  diff: %s..%s (%s forked from %s)\n' "$FORK_SHA" "$HEAD_SHA" "$(fm_review_tier_plain "$HEAD_REF")" "$(fm_review_tier_plain "$BASE")"
line=''
i=0
while [ "$i" -lt "$RULES_FILE_COUNT" ]; do
  line="${line:+$line, }${RULES_FILES[i]}"
  i=$((i + 1))
done
printf '  rules: %s\n' "$line"
