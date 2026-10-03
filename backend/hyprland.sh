#!/bin/sh
# OmaDoctor Hyprland Doctor.
#
# Reports whether the compositor is running and whether its configuration
# loaded cleanly. This is REPEATING state, not repairing it: `hyprctl reload` is
# a repair and is never run here. Every probe is a read-only hyprctl query.
#
# All parsing lives in hyprctl-parse.sh, which is covered by fixtures in
# tests/hyprctl-tests.sh. This file is only orchestration. That split matters
# here more than for audio, because hyprctl answers an unknown subcommand, a
# missing compositor instance and a clean result with THREE DIFFERENT texts and
# the SAME exit status of 0 -- so a parser with no positive structural token
# would read an error banner as a healthy reading.
#
# If HYPRLAND_INSTANCE_SIGNATURE is absent, hyprctl cannot reach the compositor.
# That is not a fault to report: the plugin may legitimately be running outside
# a Hyprland session (a TTY, a nested session, a test harness). Every check
# therefore degrades to "unknown", never to a problem.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/hyprctl-parse.sh"

CHECKS=""

# Capture the RAW first argument. doctor.sh invokes this as
# `hyprland.sh --checks-only`; emit_json switches on that literal to emit BARE
# comma-separated objects. Parsing it away and storing a mode instead makes the
# section emit a whole {section,checks} document, which the dispatcher splices
# into the array as an element -- checks with no `id`, breaking every consumer.
MODE=${1:-}

if ! have hyprctl; then
  emit "hyprland.available" hyprland info 0 "Hyprland" "not installed" \
    "hyprctl is not available on this system" ""
  emit_json hyprland "$MODE"
  exit 0
fi

# hyprctl QUERY -> its stdout, or nothing when it could not answer.
#
# A missing HYPRLAND_INSTANCE_SIGNATURE is indistinguishable from hyprctl's own
# error text once captured, so it is detected HERE, before the output is handed
# to the parsers, and every check below then reports "unknown". An absent
# signature must never surface as "Hyprland is not running": the compositor may
# be perfectly healthy in a session this process simply cannot see.
hypr_query() {
  if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
    return 1
  fi
  _hq_out=$(/usr/bin/hyprctl "$1" 2>/dev/null)
  if hypr_hyprland_error "$_hq_out"; then
    return 1
  fi
  printf '%s' "$_hq_out"
}

# ------------------------------------------------------------ compositor

if ! _hl_version_raw=$(hypr_query version); then
  emitd "hyprland.running" hyprland info 0 "Compositor" "unknown" \
    "hyprctl could not reach a Hyprland instance" \
    "This is expected outside a Hyprland session" \
    "no compositor instance visible to this process"
  emitd "hyprland.monitors" hyprland info 0 "Monitors" "unknown" \
    "hyprctl could not reach a Hyprland instance" \
    "This is expected outside a Hyprland session" \
    "no compositor instance visible to this process"
  emitd "hyprland.config_errors" hyprland info 0 "Configuration" "unknown" \
    "hyprctl could not reach a Hyprland instance" \
    "This is expected outside a Hyprland session" \
    "no compositor instance visible to this process"
  emit_json hyprland "$MODE"
  exit 0
fi

_hl_version=$(hypr_version "$_hl_version_raw")
if [ -n "$_hl_version" ]; then
  emitd "hyprland.running" hyprland ok 0 "Compositor" "Hyprland $_hl_version" \
    "compositor is running and answering" \
    "" \
    "version: $_hl_version"
else
  # hyprctl answered something, but not the shape we require. That is a real
  # anomaly worth surfacing -- but as info, not a failure, because the most
  # likely cause is a hyprctl whose banner changed, not a broken session.
  emitd "hyprland.running" hyprland info 0 "Compositor" "running" \
    "hyprctl answered but its version banner was not recognised" \
    "If this persists, please report it -- the parser may need updating" \
    "unrecognised banner shape"
fi

# ---------------------------------------------------------------- monitors

if _hl_monitors=$(hypr_query monitors); then
  if _hl_count=$(hypr_monitor_count "$_hl_monitors"); then
    _hl_names=$(hypr_monitor_names "$_hl_monitors" | /usr/bin/tr '\n' ' ')
    _hl_focused=$(hypr_active_monitor "$_hl_monitors")
    _hl_ev="monitors: $_hl_names"
    [ -n "$_hl_focused" ] && _hl_ev="$_hl_ev|focused: $_hl_focused"
    emitd "hyprland.monitors" hyprland ok 0 "Monitors" "$_hl_count" \
      "$_hl_count monitor(s) detected" \
      "Compare against your Hyprland monitor rules if a display misbehaves" \
      "$_hl_ev"
  else
    emit "hyprland.monitors" hyprland attention 1 "Monitors" "none detected" \
      "hyprctl reported no monitors" \
      "If a display is attached, check its Hyprland monitor rule"
  fi
else
  emit "hyprland.monitors" hyprland info 0 "Monitors" "unknown" \
    "could not read the monitor list" \
    "Run: hyprctl monitors"
fi

# --------------------------------------------------------- config errors

# The plan's headline Hyprland feature: this is information users otherwise
# have to dig out of a terminal. Every error line is carried in details[] so
# the report shows the compositor's own wording, file and line.
if _hl_cfg=$(hypr_query configerrors); then
  if _hl_ecount=$(hypr_config_error_count "$_hl_cfg"); then
    if [ "$_hl_ecount" -gt 0 ]; then
      # Bounded: a broken config can produce hundreds of lines and the report
      # must stay pasteable. The first ten are the ones a user acts on. They are
      # passed as trailing arguments so they land in details[], each as its own
      # evidence line, via emitr -> checkr -> jlines.
      #
      # `set --` would word-split each error line into separate words, so the
      # per-line boundary is lost. Instead the capped lines are read into
      # positional parameters one LINE at a time using IFS=newline.
      IFS='
'
      # shellcheck disable=SC2086
      set -- $(hypr_config_errors "$_hl_cfg" | /usr/bin/head -n 10)
      unset IFS
      emitr "hyprland.config_errors" hyprland problem 3 "Configuration" \
        "$_hl_ecount error(s)" \
        "Hyprland reported $_hl_ecount configuration error(s)" \
        "Open the file and line named in each error below" \
        manual "Fix the Hyprland configuration" \
        "OmaDoctor never edits your configuration" \
        "$@"
    else
      emit "hyprland.config_errors" hyprland ok 0 "Configuration" "clean" \
        "no configuration errors reported" ""
    fi
  else
    emit "hyprland.config_errors" hyprland info 0 "Configuration" "unknown" \
      "hyprctl did not report a readable configuration state" ""
  fi
else
  emit "hyprland.config_errors" hyprland info 0 "Configuration" "unknown" \
    "could not read configuration errors" \
    "Run: hyprctl configerrors"
fi

emit_json hyprland "$MODE"