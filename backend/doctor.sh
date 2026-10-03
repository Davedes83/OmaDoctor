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
# Every section is invoked behind its own timeout. A section that times out or
# crashes contributes an explicit problem check rather than vanishing --
# a missing check must never be mistaken for a healthy one.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/bootstrap.sh"

VERSION="0.3.0"

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

add_section() {
  _name=$1
  _script="$DIR/$_name.sh"
  _budget=$(deadline_for "$_name")

  if [ ! -r "$_script" ]; then
    arr=$(printf '{"id":"%s.section","category":"%s","title":"Section","status":"problem","severity":3,"value":"missing","detail":"%s.sh not found","suggestion":"Reinstall or update the plugin."}' \
          "$_name" "$_name" "$_name")
  else
    # Each section writes JSON to stdout only; stderr is discarded so a noisy
    # probe cannot corrupt the document.
    arr=$(/usr/bin/timeout -k 2 "$_budget" /bin/sh "$_script" --checks-only 2>/dev/null)
    # The section may have emitted its own trailing newline; strip it so the
    # concatenation below never introduces a break inside the array.
    arr=$(printf '%s' "$arr" | /usr/bin/tr -d '\n')
    if [ -z "$(printf '%s' "$arr" | /usr/bin/tr -d ' \n')" ]; then
      arr=$(printf '{"id":"%s.section","category":"%s","title":"Section","status":"problem","severity":3,"value":"failed","detail":"%s.sh produced no output or exceeded %ss","suggestion":"Run it directly to see the error: sh %s/%s.sh"}' \
            "$_name" "$_name" "$_name" "$_budget" "$DIR" "$_name")
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

exit 0