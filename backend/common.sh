#!/bin/sh
# Shared helpers for OmaDoctor diagnostic scripts.
# POSIX-only. Every script sources bootstrap.sh first (directly or via
# run-capped.sh), then sources this file for the JSON emitters and check
# helpers below.
#
# Design notes
# ------------
# * Scripts emit ONE JSON document on stdout. stderr is discarded by
#   run-capped.sh, so a diagnostic must never depend on writing there.
# * JSON is built by printf, not echo, so values containing spaces, quotes or
#   backslashes cannot corrupt the document. `jstr` is the only way a shell
#   value enters the JSON.
# * No command is ever invoked through `eval` or a dynamically built shell
#   string. Callers pass fixed argument vectors.
# * A failing probe must not abort the script: `have` gates optional tools and
#   every probe is written to degrade to an "unknown"/skipped state.

: "${OMADOCTOR_STATE_DIR:=$HOME/.local/state/omadoctor}"

# ---------------------------------------------------------------- JSON output

# jstr VALUE -> print a quoted, escaped JSON string.
jstr() {
  _s=$1
  # Escape backslash and double quote first, then the control characters that
  # would otherwise produce invalid JSON.
  _s=$(printf '%s' "$_s" | /usr/bin/sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' \
        -e 's/	/\\t/g' \
        -e 's/\r/\\r/g' | /usr/bin/tr '\n' ' ')
  printf '"%s"' "$_s"
}

# jnum VALUE -> print a JSON number, or null when the value is not numeric.
jnum() {
  case "$1" in
    '' | *[!0-9.-]*) printf 'null' ;;
    *) printf '%s' "$1" ;;
  esac
}

# Emit the opening of a check array element.
# check_open ID CATEGORY TITLE
check_open() {
  printf '{"id":%s,"category":%s,"title":%s,"status":%s,"severity":%s,"value":%s,"detail":%s,"suggestion":%s}' \
    "$(jstr "$1")" "$(jstr "$2")" "$(jstr "$3")" \
    "$(jstr "$STATUS")" "$(jstr "$SEVERITY")" \
    "$(jstr "$VALUE")" "$(jstr "$DETAIL")" "$(jstr "$SUGGESTION")"
}

# check ID CATEGORY STATUS SEVERITY TITLE VALUE DETAIL SUGGESTION
#
# STATUS is one of: ok | info | attention | problem
# SEVERITY is the internal weight: 0 (ok/info) | 1 (attention) | 3 (problem)
check() {
  check_open "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

# ------------------------------------------------------------------- probing

# have CMD -> succeed when CMD is resolvable on the trusted PATH.
have() {
  command -v "$1" >/dev/null 2>&1
}

# trim VALUE -> strip leading/trailing whitespace.
trim() {
  printf '%s' "$1" | /usr/bin/sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

# first_line VALUE -> first newline-delimited line of VALUE.
first_line() {
  printf '%s' "$1" | /usr/bin/head -n 1
}

# read_file PATH -> contents of PATH, or the empty string when unreadable.
read_file() {
  [ -r "$1" ] || return 1
  /usr/bin/cat "$1" 2>/dev/null
}

# keyof JSON KEY -> extract a top-level string field without requiring jq.
# Used only where jq would add a dependency for a trivial lookup.
# Fall back to jq when available since it is more correct.
field() {
  if have jq; then
    /usr/bin/jq -r --arg k "$2" '.[$k] // ""' <<EOF 2>/dev/null
$1
EOF
    return 0
  fi
  printf '%s' "$1" | /usr/bin/sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" | /usr/bin/head -n 1
}

# fs_usage_percent MOUNT -> used percentage of MOUNT, or empty when unknown.
fs_usage_percent() {
  _line=$(/usr/bin/df -P "$1" 2>/dev/null | /usr/bin/sed -n '2p')
  [ -n "$_line" ] || return 1
  # df -P columns: Filesystem 1024-blocks Used Available Capacity Mounted-on
  set -- $_line
  _cap=${5-}
  case "$_cap" in
    '' | *[!0-9%]*) return 1 ;;
  esac
  printf '%s' "${_cap%\%}"
}

# severity_for_pct PCT -> map a used-percentage to (SEVERITY STATUS).
# Thresholds: <80 ok | 80-90 attention | >90 warning | >95 critical(problem)
# Sets the globals SEVERITY and STATUS.
severity_for_pct() {
  case "$1" in
    '' | *[!0-9]*) SEVERITY=0; STATUS=ok; SUGGESTION="" ;;
    *)
      if [ "$1" -ge 95 ]; then
        SEVERITY=3; STATUS=problem
        SUGGESTION="Free space urgently; the filesystem may fail writes soon."
      elif [ "$1" -ge 90 ]; then
        SEVERITY=3; STATUS=problem
        SUGGESTION="Free space soon; above 90% some tools start failing."
      elif [ "$1" -ge 80 ]; then
        SEVERITY=1; STATUS=attention
        SUGGESTION="Worth a cleanup; above 80% is the usual warning threshold."
      else
        SEVERITY=0; STATUS=ok; SUGGESTION=""
      fi
      ;;
  esac
}