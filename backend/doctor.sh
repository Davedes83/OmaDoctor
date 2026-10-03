#!/bin/sh
# OmaDoctor scan dispatcher.
#
# Usage: doctor.sh [quick|full] [--checks-only]
#
#   quick  local-only sections (system, audio, storage). Cheap enough for a
#         periodic background scan. No network probing.
#   full   everything, including the network section. Run on demand, when the
#         panel opens, or when the user asks for a full diagnosis.
#
# Emits one merged JSON document:
#   {"mode":"quick","ts":<epoch>,"version":"0.1.0","checks":[ ... ]}
# with --checks-only, just the array.
#
# Every section is invoked behind its own timeout. A section that times out,
# crashes, exits non-zero or emits malformed output contributes an explicit
# problem check rather than vanishing -- a missing check must never be mistaken
# for a healthy one.
#
# common.sh is sourced for check(), jstr() and json_fragment_ok(). It is
# deliberately NOT sourced by the section scripts through this file: each
# section is a separate process that sources it itself.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

VERSION="0.5.0"

MODE=quick
CHECKS_ONLY=0
for arg in "$@"; do
  case "$arg" in
    quick | full) MODE=$arg ;;
    --checks-only) CHECKS_ONLY=1 ;;
  esac
done

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Per-section deadline in seconds. Network is the slowest and gets the most.
# These are worst-case budgets, not expected durations: a section that stalls
# must be killed and reported as a problem rather than hanging the scan.
deadline_for() {
  case "$1" in
    network) printf '25' ;;
    audio)   printf '12' ;;
    storage) printf '15' ;;
    services) printf '10' ;;
    hyprland) printf '10' ;;
    display) printf '10' ;;
    *)       printf '15' ;;
  esac
}

CHECKS=""
SECTIONS=""

# section_failure NAME VALUE DETAIL SUGGESTION -> a bare check object marking a
# section as unusable. Emitted INSTEAD of that section's own output, never
# alongside it: a partial section that died half-way through has not been shown
# to be complete, and reporting its surviving checks as a clean section is the
# failure this file exists to prevent.
section_failure() {
  check "$1.section" "$1" problem 3 "Section" "$2" "$3" "$4"
}

add_section() {
  _name=$1
  _script="$DIR/$_name.sh"
  _budget=$(deadline_for "$_name")
  _run_hint="Run it directly to see the error: sh $DIR/$_name.sh"

  # Sections learn the scan mode from the environment rather than from argv:
  # argv[1] is already spoken for by --checks-only, and a mode flag there would
  # be one more magic string that a caller can get wrong (see the note in
  # common.sh's emit_json). Only checkupdates consumes it today, but "cheap
  # local-only" vs "everything, including the network" is a distinction more
  # probes will want to make.
  OMADOCTOR_MODE=$MODE
  export OMADOCTOR_MODE

  if [ ! -r "$_script" ]; then
    arr=$(section_failure "$_name" "missing" "$_name.sh not found" \
      "Reinstall or update the plugin.")
  else
    # Each section writes JSON to stdout only; stderr is discarded so a noisy
    # probe cannot corrupt the document.
    arr=$(/usr/bin/timeout -k 2 "$_budget" /bin/sh "$_script" --checks-only 2>/dev/null)
    _rc=$?
    # The section may have emitted its own trailing newline; strip it so the
    # concatenation below never introduces a break inside the array.
    arr=$(printf '%s' "$arr" | /usr/bin/tr -d '\n')

    if [ -z "$(printf '%s' "$arr" | /usr/bin/tr -d ' \n')" ]; then
      # Distinguish "was killed at its deadline" from "produced nothing".
      # 124 is timeout(1)'s "timed out"; 137 is the SIGKILL that follows when
      # the -k grace period is also exceeded. Both are real answers about this
      # machine, not code defects, so they are reported as such.
      case "$_rc" in
        124 | 137)
          arr=$(section_failure "$_name" "timed out" \
            "$_name.sh exceeded its ${_budget}s deadline and was killed" \
            "This usually means a probe it depends on hung. $_run_hint")
          ;;
        *)
          arr=$(section_failure "$_name" "failed" \
            "$_name.sh produced no output (exit $_rc)" "$_run_hint")
          ;;
      esac
    elif [ "$_rc" -ne 0 ]; then
      # A section can emit well-formed checks and THEN die -- a wedged
      # compositor, a hung systemd call, an OOM. Its exit status is the only
      # evidence that the remaining checks never ran, so its output is
      # discarded rather than trusted. Exit 124/137 reach this branch too when
      # the section had already printed something.
      case "$_rc" in
        124 | 137)
          arr=$(section_failure "$_name" "timed out" \
            "$_name.sh was killed at its ${_budget}s deadline after partial output" \
            "Its remaining checks did not run, so they are not reported. $_run_hint")
          ;;
        *)
          arr=$(section_failure "$_name" "incomplete" \
            "$_name.sh exited $_rc after emitting output, so its remaining checks did not run" \
            "$_run_hint")
          ;;
      esac
    elif ! json_fragment_ok "$arr"; then
      # Truncated mid-write, a nested document, or malformed output. Splicing
      # it would make the ENTIRE merged document unparseable and cost every
      # other section its findings, so it is replaced.
      arr=$(section_failure "$_name" "corrupt" \
        "$_name.sh produced output that is not a valid list of checks" \
        "It was discarded so the rest of this scan survives. $_run_hint")
    fi
  fi

  if [ -z "$(printf '%s' "$CHECKS" | /usr/bin/tr -d ' ')" ]; then
    CHECKS=$arr
  else
    CHECKS="$CHECKS,$arr"
  fi
  SECTIONS="$SECTIONS $_name"
}

add_section sysinfo
add_section services
add_section hyprland
add_section display
add_section audio
add_section storage
[ "$MODE" = "full" ] && add_section network

# Wrap the merged comma-separated objects in exactly one array.
if [ -z "$(printf '%s' "$CHECKS" | /usr/bin/tr -d ' ')" ]; then
  CHECKS_ARRAY="[]"
else
  CHECKS_ARRAY="[$CHECKS]"
fi

if [ "$CHECKS_ONLY" = "1" ]; then
  printf '%s\n' "$CHECKS_ARRAY"
  exit 0
fi

# Last line of defence. Every section fragment was validated on its own above,
# but this catches anything that went wrong in the merge itself -- and the
# snapshot below must never cache a document the QML layer cannot parse, or the
# next scan would read back a poisoned baseline.
if ! json_fragment_ok "$CHECKS"; then
  printf '{"id":"doctor.merged","category":"system","title":"Scan","status":"problem","severity":3,"value":"corrupt","detail":"the merged check list is malformed and was discarded","suggestion":"Run sh %s/doctor.sh full to see the raw output."}\n' \
    "$DIR"
  exit 1
fi

TS=$(/usr/bin/date +%s 2>/dev/null || printf '0')

DOC="{\"mode\":$(printf '%s' "$MODE" | /usr/bin/sed 's/^/"/; s/$/"/'),\"version\":\"$VERSION\",\"ts\":$TS,\"sections\":\"$(printf '%s' "$SECTIONS" | /usr/bin/sed 's/^ *//; s/ /,/g')\",\"checks\":$CHECKS_ARRAY}"

printf '%s\n' "$DOC"

# Persist the snapshot atomically so a reader never sees a half-written file.
# The state dir is created by bootstrap.sh under a restrictive umask.
SNAP="$OMADOCTOR_STATE_DIR/last-scan.json"
TMP="$OMADOCTOR_STATE_DIR/.last-scan.$$"
if printf '%s\n' "$DOC" > "$TMP" 2>/dev/null; then
  /usr/bin/mv -f "$TMP" "$SNAP" 2>/dev/null || /usr/bin/rm -f "$TMP" 2>/dev/null
fi

# A timestamp file lets the QML layer detect staleness without re-parsing JSON.
printf '%s\n' "$TS" > "$OMADOCTOR_STATE_DIR/last-scan.ts.tmp.$$" 2>/dev/null \
  && /usr/bin/mv -f "$OMADOCTOR_STATE_DIR/last-scan.ts.tmp.$$" \
                "$OMADOCTOR_STATE_DIR/last-scan.ts" 2>/dev/null
# --------------------------------------------------------------- history
#
# Bounded status history, for "what changed since ...". Two deliberate limits:
#
#   * ONLY on full scans. A quick scan runs every 30s on a timer; writing one
#     history file per poll would be thousands of files a day of churn for a
#     feature nobody is looking at. A full scan is user-initiated and
#     infrequent, so it is the natural checkpoint.
#   * a COMPACT status map, not the whole document. A full snapshot is ~7KB of
#     which the diff needs only id and status; this is ~1KB. diffScans takes
#     titles and values from the CURRENT scan, so nothing is lost.
#
# The point of the history is to survive a shell restart: without it the first
# scan after `omarchy restart shell` has no baseline and reports nothing, which
# is precisely when a user most wants to know what moved.
if [ "$MODE" = "full" ]; then
  HIST_DIR="$OMADOCTOR_STATE_DIR/history"
  if mkdir -p "$HIST_DIR" 2>/dev/null; then
    _hist=$(printf '%s' "$CHECKS_ARRAY" | jq -c \
      'map({key: .id, value: .status}) | from_entries' 2>/dev/null)
    if [ -n "$_hist" ]; then
      _htmp="$HIST_DIR/.$TS.$$"
      if printf '{"ts":%s,"status":%s}\n' "$TS" "$_hist" > "$_htmp" 2>/dev/null; then
        /usr/bin/mv -f "$_htmp" "$HIST_DIR/$TS.json" 2>/dev/null \
          || /usr/bin/rm -f "$_htmp" 2>/dev/null
        # Keep the newest 20. The FILENAME is the epoch, so sort by name rather
        # than by mtime: `ls -1t` orders by modification time, which is wrong
        # here. Two scans in the same second share an mtime and tie-break
        # arbitrarily, and a restored or copied history has mtimes unrelated to
        # when a scan ran. Sorting zero-padded epoch filenames
        # lexicographically IS chronological.
        #
        # The grep skips the .tmp.$$ file an in-flight write leaves behind, and
        # anything that is not <digits>.json.
        for _old in $(/usr/bin/ls -1 "$HIST_DIR" 2>/dev/null \
                        | /usr/bin/grep '^[0-9][0-9]*\.json$' \
                        | /usr/bin/sort \
                        | /usr/bin/head -n -20); do
          /usr/bin/rm -f "$HIST_DIR/$_old" 2>/dev/null
        done
      fi
    fi
  fi
fi
exit 0