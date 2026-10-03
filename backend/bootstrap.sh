#!/bin/sh
# OmaDoctor secure-execution bootstrap.
#
# Sourced immediately after a script's shebang. It normalizes the environment
# so that no diagnostic helper can be influenced by anything inherited from the
# long-lived Quickshell shell process:
#
#   * PATH is replaced with a fixed, root-owned allowlist. A shadow executable
#     dropped anywhere else on the user's PATH (~/bin, a repo dir, ...) can
#     never be resolved here.
#   * Locale is pinned to C so ip/ping/df/lsblk output parsing is deterministic.
#   * Dynamic-loader and interpreter module injection variables are dropped.
#   * The plugin state directory is guaranteed to exist.
#
# OmaDoctor is read-only with respect to system configuration: nothing here
# grants write access to /etc or ~/.config/hypr. The state dir holds only
# diagnostic cache and scan history.
umask 077

export PATH=/usr/bin:/bin
export LC_ALL=C

unset LD_PRELOAD LD_AUDIT LD_LIBRARY_PATH LD_LIBRARY_PATH_64 \
  PYTHONHOME PYTHONSTARTUP PYTHONPATH PERL5LIB PERLLIB 2>/dev/null || true

: "${OMADOCTOR_STATE_DIR:=$HOME/.local/state/omadoctor}"
export OMADOCTOR_STATE_DIR
mkdir -p "$OMADOCTOR_STATE_DIR" 2>/dev/null || true

# Hard ceiling for any helper's stdout, applied by run-capped.sh. Diagnostic
# payloads are small (a fixed number of checks with bounded detail lines), so
# this only exists to bound worst-case retention in the long-lived shell if a
# producer ever runs away.
: "${OMADOCTOR_MAX_OUT_BYTES:=1048576}"
export OMADOCTOR_MAX_OUT_BYTES