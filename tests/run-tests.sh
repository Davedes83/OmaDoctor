#!/bin/sh
# OmaDoctor test runner.
#
# Usage:
#   tests/run-tests.sh [interpreter [flags]]
#
# Examples:
#   tests/run-tests.sh                 # default: sh
#   tests/run-tests.sh bash --posix    # bash in POSIX compatibility mode
#
# Runs the shell suites and, when node is available, the Model.js unit tests.
# Exits nonzero if any suite failed.

set -u

DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
. "$DIR/lib.sh"

OMC_TEST_SH="${1:-sh}"
export OMC_TEST_SH

_interp0=${OMC_TEST_SH%% *}
if command -v "$_interp0" >/dev/null 2>&1; then
  :
else
  echo "interpreter not found: $OMC_TEST_SH" >&2
  exit 2
fi

# OMC_TEST_SH may carry an option word, e.g. "bash --posix". Split it once here
# so each suite is invoked as "$interp" "$opt" "$suite".
case "$OMC_TEST_SH" in
  *\ *)
    SUITE_INTERP=${OMC_TEST_SH%% *}
    SUITE_OPT=${OMC_TEST_SH#* }
    ;;
  *)
    SUITE_INTERP=$OMC_TEST_SH
    SUITE_OPT=""
    ;;
esac

RC=0

echo "# --- shell suites (interpreter: $OMC_TEST_SH) ---"
for suite in "$DIR"/*-tests.sh; do
  [ -f "$suite" ] || continue
  # The runner is itself named *-tests.sh, so it MUST be excluded or the loop
  # invokes this script recursively until the machine falls over.
  case "${suite##*/}" in
    run-tests.sh) continue ;;
  esac
  echo "# ${suite##*/}"
  # stdin from /dev/null: a suite that accidentally reads stdin must not block
  # waiting on the terminal.
  if [ -n "$SUITE_OPT" ]; then
    "$SUITE_INTERP" "$SUITE_OPT" "$suite" </dev/null || RC=1
  else
    "$SUITE_INTERP" "$suite" </dev/null || RC=1
  fi
  echo
done

echo "# --- Model.js unit tests (node) ---"
if command -v node >/dev/null 2>&1; then
  if /usr/bin/timeout -k 2 60 node "$DIR/model-tests.js" </dev/null; then
    :
  else
    RC=1
  fi
else
  echo "# skipped: node not found"
fi

if [ "$RC" -eq 0 ]; then
  echo "# ALL SUITES PASSED"
else
  echo "# SUITE FAILURES PRESENT"
fi
exit "$RC"