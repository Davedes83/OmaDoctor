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

# check ID CATEGORY STATUS SEVERITY TITLE VALUE DETAIL SUGGESTION
#
# Emits one check object. Field order in the JSON is deliberately
# id, category, title, status, severity, value, detail, suggestion -- which is
# NOT the argument order (status/severity precede title for readability at the
# call site). Keep this mapping and the call sites in sync.
#
# STATUS   is one of: ok | info | attention | problem
# SEVERITY is the internal weight: 0 (ok/info) | 1 (attention) | 3 (problem)
check() {
  printf '{"id":%s,"category":%s,"title":%s,"status":%s,"severity":%s,"value":%s,"detail":%s,"suggestion":%s}' \
    "$(jstr "$1")" "$(jstr "$2")" "$(jstr "$5")" \
    "$(jstr "$3")" "$(jnum "$4")" \
    "$(jstr "$6")" "$(jstr "$7")" "$(jstr "$8")"
}

# jlines [STRING...] -> a JSON array of the non-empty arguments, [] if none.
# Empty arguments are dropped so a caller can pass an unset variable safely.
jlines() {
  _jl=""
  for _jl_s in "$@"; do
    [ -z "$_jl_s" ] && continue
    if [ -z "$_jl" ]; then
      _jl=$(jstr "$_jl_s")
    else
      _jl="$_jl,$(jstr "$_jl_s")"
    fi
  done
  if [ -z "$_jl" ]; then printf '[]'; else printf '[%s]' "$_jl"; fi
}

# jrepair TIER LABEL DETAIL -> a repair object, or "null" when LABEL is empty.
# TIER is safe|caution|manual; an unrecognised tier degrades to "manual" so an
# unknown value is never presented as the reassuring one. DATA ONLY: nothing in
# OmaDoctor ever executes a repair.
jrepair() {
  if [ -z "$2" ]; then printf 'null'; return 0; fi
  _jr_tier=$(printf '%s' "$1" | /usr/bin/tr 'A-Z' 'a-z')
  case "$_jr_tier" in safe | caution | manual) ;; *) _jr_tier=manual ;; esac
  printf '{"tier":"%s","label":%s,"detail":%s}' \
    "$_jr_tier" "$(jstr "$2")" "$(jstr "$3")"
}

# checkd ID CATEGORY STATUS SEVERITY TITLE VALUE DETAIL SUGGESTION [DETAIL...]
#
# As check(), plus an OPTIONAL "details" array for structured evidence -- the
# multi-line "here is what I measured" block a single detail string cannot
# carry (per-monitor state, one config-error line each, ...). Trailing empty
# arguments are dropped. The field is additive: an absent key and an empty
# array mean the same thing to Model.js, which normalises both to [].
checkd() {
  _cd_id=$1; _cd_cat=$2; _cd_st=$3; _cd_sv=$4
  _cd_ti=$5; _cd_va=$6; _cd_de=$7; _cd_sg=$8
  shift 8
  printf '{"id":%s,"category":%s,"title":%s,"status":%s,"severity":%s,"value":%s,"detail":%s,"suggestion":%s,"details":%s}' \
    "$(jstr "$_cd_id")" "$(jstr "$_cd_cat")" "$(jstr "$_cd_ti")" \
    "$(jstr "$_cd_st")" "$(jnum "$_cd_sv")" \
    "$(jstr "$_cd_va")" "$(jstr "$_cd_de")" "$(jstr "$_cd_sg")" \
    "$(jlines "$@")"
}

# checkr ID CATEGORY STATUS SEVERITY TITLE VALUE DETAIL SUGGESTION TIER LABEL [REPAIR_DETAIL] [DETAIL...]
#
# As checkd(), plus an optional "repair" descriptor. TIER is safe|caution|manual
# and LABEL is the short human description of what a fix WOULD be. DESCRIPTIVE
# ONLY -- OmaDoctor is read-only and never runs it.
checkr() {
  _cr_id=$1; _cr_cat=$2; _cr_st=$3; _cr_sv=$4
  _cr_ti=$5; _cr_va=$6; _cr_de=$7; _cr_sg=$8
  _cr_tier=$9; shift 9
  # Explicitly consume the two optional repair fields by COUNT, never by an
  # over-count shift: `shift 2` with fewer args left has shell-dependent
  # behaviour, and a masked `|| :` would hide it. If only a label was given,
  # the second positional is empty and the label is not duplicated into
  # repair.detail or leaked into details[].
  _cr_rlabel=${1:-}
  if [ "$#" -ge 2 ]; then
    _cr_rdetail=$2
    shift 2
  else
    _cr_rdetail=""
    shift 2>/dev/null || :
  fi
  printf '{"id":%s,"category":%s,"title":%s,"status":%s,"severity":%s,"value":%s,"detail":%s,"suggestion":%s,"details":%s,"repair":%s}' \
    "$(jstr "$_cr_id")" "$(jstr "$_cr_cat")" "$(jstr "$_cr_ti")" \
    "$(jstr "$_cr_st")" "$(jnum "$_cr_sv")" \
    "$(jstr "$_cr_va")" "$(jstr "$_cr_de")" "$(jstr "$_cr_sg")" \
    "$(jlines "$@")" \
    "$(jrepair "$_cr_tier" "$_cr_rlabel" "$_cr_rdetail")"
}

# Accumulate one check object into $CHECKS. This only appends a comma-separated
# object; the enclosing [ ... ] is added once at print time by emit_json.
# Do NOT try to bracket the first element here -- that makes every later append
# re-close the array and produces [c1],c2],c3] garbage.
emit() {
  _c=$(check "$@")
  if [ -z "$CHECKS" ]; then
    CHECKS=$_c
  else
    CHECKS="$CHECKS,$_c"
  fi
}

# emitd/emitr are the emit() counterparts of checkd/checkr. All three share the
# accumulate-bare-then-wrap-once rule above.
emitd() {
  _c=$(checkd "$@")
  if [ -z "$CHECKS" ]; then
    CHECKS=$_c
  else
    CHECKS="$CHECKS,$_c"
  fi
}

emitr() {
  _c=$(checkr "$@")
  if [ -z "$CHECKS" ]; then
    CHECKS=$_c
  else
    CHECKS="$CHECKS,$_c"
  fi
}

# Print the accumulated checks as JSON. $1 is the section name; $2 may be
# "--checks-only" to emit the BARE comma-separated objects (no enclosing
# brackets) so doctor.sh can concatenate several sections and wrap the result
# in exactly one [ ... ].
emit_json() {
  if [ -z "$CHECKS" ]; then CHECKS=""; fi
  case "${2:-}" in
    --checks-only) printf '%s\n' "$CHECKS" ;;
    *) printf '{"section":%s,"checks":[%s]}\n' "$(jstr "$1")" "$CHECKS" ;;
  esac
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