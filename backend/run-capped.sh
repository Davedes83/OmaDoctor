#!/bin/sh
# OmaDoctor stdout guard.
#
# Every diagnostic helper launched from the QML layer is run through this
# wrapper. It enforces:
#
#   * A hard byte cap on stdout (default 1 MB). When MAX bytes pass, head closes
#     the read end of the pipe, the producer gets SIGPIPE and terminates, and
#     the consumer receives truncated (unparseable) JSON so the UI falls back
#     to its last known good state rather than rendering garbage.
#   * The producer itself runs under the sanitized bootstrap environment
#     (trusted PATH, pinned locale, no loader injection).
#
# Usage:  run-capped.sh <interpreter> <script> [args...]
#
# Callers wrap this one level further in a GNU coreutils timeout:
#   timeout -k 2 N /bin/sh run-capped.sh /bin/sh <script> [args...]
# That places the producer in its own process group and guarantees group-level
# SIGTERM -> SIGKILL reaping, so no diagnostic can outlive its deadline.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/bootstrap.sh"

MAX="${OMADOCTOR_MAX_OUT_BYTES:-1048576}"
case "$MAX" in '' | *[!0-9]*) MAX=1048576 ;; esac
[ "$MAX" -gt 0 ] 2>/dev/null || MAX=1048576

"$@" 2>/dev/null | /usr/bin/head -c "$MAX"