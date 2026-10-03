#!/bin/sh
# OmaDoctor hyprctl output parsers.
#
# Pure functions over hyprctl output text. No bootstrap, no PATH assumptions, no
# external commands beyond /usr/bin/awk and /usr/bin/grep -- so the awkward
# cases can be pinned in tests/hyprctl-tests.sh with fixtures instead of only
# being observable on a live machine.
#
# WHY THIS FILE EXISTS
# --------------------
# `hyprctl` answers three different failure modes with ordinary-looking stdout
# and EXIT STATUS 0:
#
#   * an unknown subcommand        -> "unknown request"
#   * no compositor instance       -> "HYPRLAND_INSTANCE_SIGNATURE not set!"
#                                     (also "... was not set! (Is Hyprland
#                                     running?)" from older builds)
#   * a valid command, no results  -> empty output
#
# Every one of those is text a careless parser will happily read as data. The
# audio section already shipped this bug once in mirror image: it called a
# `wpctl` subcommand that does not exist, scraped the usage banner, and reported
# the literal string "Usage:" as a healthy device name. Every function below
# therefore REQUIRES a positive structural token before it will return a
# reading. Absent the token, the answer is "nothing", which the caller reports
# as unknown/skipped -- never as healthy.
#
# Sourced by backend/hyprland.sh and backend/display.sh. NOT a section:
# doctor.sh never runs it.

# --------------------------------------------------------------- guards

# hypr_hyprland_error TEXT -> true when TEXT is one of hyprctl's failure
# banners rather than data.
#
# These are matched case-insensitively and on a lowercased copy, because the
# two "not set" wordings differ between hyprctl versions. The exit status is
# useless here (0 in both cases), so this check is the only way to tell.
hypr_hyprland_error() {
  printf '%s' "$1" | /usr/bin/grep -qiE 'unknown request|hyprland_instance_signature|is hyprland running|error while'
}

# hypr_clean_multiline TEXT -> TEXT with non-printable-ASCII bytes removed.
#
# The bootstrap pins LC_ALL=C, where any UTF-8 multi-byte character is just
# bytes >= 0x80. Dropping them keeps the parsers independent of both the locale
# and any literal box-drawing character.
hypr_clean_multiline() {
  printf '%s\n' "$1" | /usr/bin/tr -d '\000-\037\177-\377'
}

# ------------------------------------------------------------- monitors

# hypr_monitor_names MONITORS_TEXT -> one monitor name per line, in order.
#
# Only blocks introduced by a literal "Monitor <NAME> (ID <n>):" header count.
# `hyprctl monitors all` also includes disabled outputs, which is what the
# Display Doctor needs to spot a saved rule for a monitor that is not attached.
hypr_monitor_names() {
  printf '%s\n' "$1" | /usr/bin/awk '
    match($0, /^Monitor [^ ]+ \(ID [0-9]+\):$/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^Monitor /, "", s)
      sub(/ \(ID [0-9]+\):$/, "", s)
      if (s != "") print s
    }
  '
}

# hypr_monitor_count MONITORS_TEXT -> number of monitors, or nothing.
#
# Returns nothing (not 0) when the text is an error banner or carries no
# monitor header, so the caller can distinguish "no monitors" from "hyprctl
# did not answer".
hypr_monitor_count() {
  hypr_hyprland_error "$1" && return 1
  _n=$(hypr_monitor_names "$1" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  case "$_n" in '' | *[!0-9]* | 0) return 1 ;; esac
  printf '%s' "$_n"
}

# hypr_active_monitor MONITORS_TEXT -> the name of the focused monitor.
hypr_active_monitor() {
  printf '%s\n' "$1" | /usr/bin/awk '
    /^Monitor [^ ]+ \(ID [0-9]+\):$/ {
      name = $0
      sub(/^Monitor /, "", name)
      sub(/ \(ID [0-9]+\):$/, "", name)
      inside = (name != "")
      next
    }
    # "focused: yes" only exists inside a monitor block. Matching on a whole
    # line keeps a `lastwindowtitle` that happens to contain the word "focused"
    # from being read as a focus flag.
    inside && $0 ~ /^[[:space:]]*focused:[[:space:]]*yes[[:space:]]*$/ {
      print name
      exit
    }
  '
}

# hypr_monitor_disabled MONITORS_TEXT -> the names of every disabled monitor.
#
# This is how a saved monitor rule for hardware that is not currently attached
# is detected without ever touching the user's configuration.
#
# awk has no "end of block" hook, so each block is reaped when the NEXT header
# arrives and the last one in END. Reaping only in END -- the obvious shortcut
# -- silently reports nothing whenever the disabled monitor is not the final
# block, which is the common case.
hypr_monitor_disabled() {
  printf '%s\n' "$1" | /usr/bin/awk '
    function reap() {
      if (name != "" && disabled) print name
    }
    /^Monitor [^ ]+ \(ID [0-9]+\):$/ {
      reap()
      name = $0
      sub(/^Monitor /, "", name)
      sub(/ \(ID [0-9]+\):$/, "", name)
      disabled = 0
      next
    }
    name != "" && $0 ~ /^[[:space:]]*disabled:[[:space:]]*true[[:space:]]*$/ { disabled = 1 }
    END { reap() }
  '
}

# hypr_monitor_field MONITORS_TEXT MONITOR FIELD -> a single field value for a
# named monitor, e.g. hypr_monitor_field TEXT eDP-1 scale  ->  1
#
# Prints nothing when the monitor or the field is absent, so a caller cannot
# mistake "not reported" for a reading. Matching is on an exact name so a
# monitor called "DP-1" never answers a query about "eDP-1".
hypr_monitor_field() {
  printf '%s\n' "$1" | /usr/bin/awk -v want="$2" -v field="$3" '
    /^Monitor [^ ]+ \(ID [0-9]+\):$/ {
      name = $0
      sub(/^Monitor /, "", name)
      sub(/ \(ID [0-9]+\):$/, "", name)
      inside = (name == want)
      next
    }
    inside && $1 == field":" {
      v = $0
      sub(/^[^:]*:[[:space:]]*/, "", v)
      sub(/[[:space:]]*$/, "", v)
      print v
      exit
    }
  '
}

# hypr_monitor_mode MONITORS_TEXT MONITOR -> "<width>x<height>@<refresh>", or
# nothing. That mode line is the one field that is positional rather than
# "key: value", so it needs its own reader.
#
# The line is INDENTED in real output ("        1920x1080@59.99800 at 0x0"),
# so the pattern allows leading whitespace. It is still anchored to require the
# full "<w>x<h>@<refresh> at <x>x<y>" shape; without the " at " suffix a stray
# number elsewhere in the block could satisfy it.
hypr_monitor_mode() {
  printf '%s\n' "$1" | /usr/bin/awk -v want="$2" '
    /^Monitor [^ ]+ \(ID [0-9]+\):$/ {
      name = $0
      sub(/^Monitor /, "", name)
      sub(/ \(ID [0-9]+\):$/, "", name)
      inside = (name == want)
      next
    }
    inside && match($0, /^[[:space:]]*[0-9]+x[0-9]+@[0-9.]+[[:space:]]+at[[:space:]]/) {
      v = substr($0, RSTART, RLENGTH)
      sub(/^[[:space:]]*/, "", v)
      sub(/[[:space:]]*at[[:space:]]*$/, "", v)
      print v
      exit
    }
  '
}

# ---------------------------------------------------------- config errors

# hypr_config_errors CONFIGERRORS_TEXT -> one error per line, or nothing.
#
# A clean config produces EMPTY output, so "no lines" legitimately means no
# errors. An error banner is rejected first, because "unknown request" is not a
# configuration error and must never be reported as one.
#
# hyprctl prints config errors as
#     /home/u/.config/hypr/hyprland.conf:42: Unknown keyword: foo
# so each non-empty line is one error. Leading "  " and "err " noise is
# stripped; the line is otherwise passed through unchanged so the user sees the
# compositor's own wording rather than a paraphrase.
hypr_config_errors() {
  hypr_hyprland_error "$1" && return 1
  printf '%s\n' "$1" | /usr/bin/awk '
    { gsub(/^[ \t]+/, ""); if ($0 != "") print }
  '
}

# hypr_config_error_count CONFIGERRORS_TEXT -> number of errors, or nothing
# when hyprctl did not answer at all. Note the asymmetry with a clean config:
# a CLEAN config returns 0, but an error banner returns nothing, because "no
# errors" and "could not ask" must never be the same answer.
hypr_config_error_count() {
  hypr_hyprland_error "$1" && return 1
  _n=$(hypr_config_errors "$1" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  case "$_n" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$_n"
}

# ---------------------------------------------------------------- version

# hypr_version VERSION_TEXT -> e.g. "0.56.2", or nothing.
#
# The first line is "Hyprland 0.56.2 built from branch ...". A version is only
# returned when that exact shape is present, so an error banner or an
# unexpected reformat yields nothing rather than a plausible-looking number.
hypr_version() {
  printf '%s\n' "$1" | /usr/bin/awk '
    match($0, /^Hyprland [0-9]+\.[0-9]+(\.[0-9]+)?/) {
      v = substr($0, RSTART, RLENGTH)
      sub(/^Hyprland /, "", v)
      print v
      exit
    }
  '
}

# ------------------------------------------------------------- workspaces

# hypr_workspace_count WORKSPACES_TEXT -> number of workspaces, or nothing.
hypr_workspace_count() {
  hypr_hyprland_error "$1" && return 1
  _n=$(printf '%s\n' "$1" | /usr/bin/awk '
    /^workspace ID [0-9]+ \([0-9]+\) on monitor / { c++ }
    END { print c + 0 }
  ')
  case "$_n" in '' | *[!0-9]* | 0) return 1 ;; esac
  printf '%s' "$_n"
}