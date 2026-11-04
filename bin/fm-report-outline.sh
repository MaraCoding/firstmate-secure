#!/usr/bin/env bash
# fm-report-outline.sh - read a crewmate report by outline: headings first, then only the sections needed.
# Usage: fm-report-outline.sh <task-id|file> [<heading>...]
#   With no heading, prints the report's heading list (outside fenced blocks),
#   one per line as `<line>: <heading> (<n> lines)`, plus the total size.
#   With headings, prints each named section's body. A heading may be given
#   exactly (`## Findings`) or by its text alone (`Findings`, case-insensitive,
#   first match at any level). Each printed line is cut to FM_REPORT_LINE_CAP
#   characters (default 400) and each section to FM_REPORT_SECTION_LINES lines
#   (default 120), with a note when anything was cut.
#   <task-id> reads data/<task-id>/report.md in this home.
#   bin/fm-brief-heading-lib.sh owns the section parse.
# Exit: 0 on success, 1 when the report or a named heading is missing, 2 on usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-brief-heading-lib.sh
. "$SCRIPT_DIR/fm-brief-heading-lib.sh"

case "${1:-}" in
'' ) echo "usage: fm-report-outline.sh <task-id|file> [<heading>...]" >&2; exit 2 ;;
-h | --help) sed -n '2,/^[^#]/{/^#/s/^# \{0,1\}//p}' "${BASH_SOURCE[0]}"; exit 0 ;;
esac
TARGET=$1
shift
if [ -f "$TARGET" ]; then
  REPORT=$TARGET
else
  REPORT="$DATA/${TARGET#fm-}/report.md"
fi
[ -f "$REPORT" ] || { echo "error: no report at $REPORT" >&2; exit 1; }

LINE_CAP=${FM_REPORT_LINE_CAP:-400}
SECTION_LINES=${FM_REPORT_SECTION_LINES:-120}
case "$LINE_CAP" in '' | *[!0-9]*) LINE_CAP=400 ;; esac
case "$SECTION_LINES" in '' | *[!0-9]*) SECTION_LINES=120 ;; esac

# Heading lines outside fenced blocks: "<line>\t<heading>".
fm_report_headings() {
  awk '
    {
      scan = $0; sub(/^ {0,3}/, "", scan)
      m = substr(scan, 1, 1); n = 0
      if (m == "`" || m == "~") while (substr(scan, n + 1, 1) == m) n++
      if (n >= 3) {
        if (!fenced) { fenced = 1; fm = m; fl = n }
        else if (m == fm && n >= fl) fenced = 0
        next
      }
      if (!fenced && scan ~ /^#{1,6}( |$)/) print NR "\t" $0
    }
  ' "$REPORT"
}

HEADINGS=$(fm_report_headings)
TOTAL=$(wc -l < "$REPORT" | tr -d ' ')

if [ $# -eq 0 ]; then
  printf '%s\n' "$HEADINGS" | awk -F '\t' -v total="$TOTAL" '
    NF == 2 { ln[++n] = $1; h[n] = $2 }
    END {
      for (i = 1; i <= n; i++) {
        end = (i < n ? ln[i + 1] - 1 : total)
        printf "%s: %s (%d lines)\n", ln[i], h[i], end - ln[i]
      }
    }'
  printf 'total: %s lines, %s chars: %s\n' "$TOTAL" "$(wc -c < "$REPORT" | tr -d ' ')" "$REPORT"
  exit 0
fi

rc=0
for want in "$@"; do
  heading=
  case "$want" in
  '#'*) printf '%s\n' "$HEADINGS" | cut -f2- | grep -Fxq -- "$want" && heading=$want ;;
  *)
    heading=$(printf '%s\n' "$HEADINGS" | cut -f2- | awk -v w="$want" '
      { t = $0; sub(/^#+ */, "", t); sub(/ +#* *$/, "", t)
        if (tolower(t) == tolower(w)) { print; exit } }')
    ;;
  esac
  if [ -z "$heading" ]; then
    echo "error: no heading '$want' in $REPORT (run with no heading for the list)" >&2
    rc=1
    continue
  fi
  printf '%s\n' "$heading"
  fm_brief_heading_body "$REPORT" "$heading" | awk -v cap="$LINE_CAP" -v max="$SECTION_LINES" '
    NR <= max { if (length($0) > cap) { print substr($0, 1, cap) " [...]"; cut++ } else print }
    END {
      if (NR > max) printf "[... %d more lines in this section]\n", NR - max
      if (cut) printf "[%d long lines cut at %d chars]\n", cut, cap
    }'
done
exit "$rc"
