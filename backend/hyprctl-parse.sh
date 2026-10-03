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
# Matched case-insensitively on a lowercased copy, because the "not set"
# wordings differ between hyprctl versions.
#
# There are THREE failure banners plus one exit-status signal, and all four
# were verified against Hyprland 0.56.2:
#
#   * unknown subcommand    -> "unknown request"                              exit 0
#   * no instance signature -> "HYPRLAND_INSTANCE_SIGNATURE not set! (is
#                              hyprland running?)"                             exit 1
#   * STALE signature (the
#     signature names a
#     socket that no
#     longer exists)       -> "Couldn't connect to /run/user/1000/hypr/<sig>/
#                              .socket.sock. (4)"                              exit 4
#   * older builds         -> "... was not set! (Is Hyprland running?)",
#                              "error while ..."
#
# The stale-signature case is the dangerous one: it arrives on STDOUT, so a
# parser that only pattern-matches the older wordings reads a socket error as a
# monitor list and reports "your display is off". Callers must therefore ALSO
# test hyprctl's exit status; see hypr_query in backend/hyprland.sh.
hypr_hyprland_error() {
  printf '%s' "$1" | /usr/bin/grep -qiE \
    "unknown request|hyprland_instance_signature|is hyprland running|error while|couldn't connect to|socket\.sock|no such file or directory"
}

# hypr_clean_multiline TEXT -> TEXT with ASCII control bytes removed.
#
# Control bytes are stripped because they cannot survive a JSON string literal
# and must never reach a value. Bytes >= 0x80 are DELIBERATELY KEPT: under
# LC_ALL=C a UTF-8 multi-byte character is simply several bytes >= 0x80, so
# deleting them would silently turn "Beyerdynamic DT 770 Pro (80 Ω)" into
# "... (80 )" and mangle every non-English device name. jstr() escapes the
# control bytes and passes valid UTF-8 through untouched -- JSON permits raw
# multi-byte UTF-8 in a string.
#
# NEWLINE (0x0A) and TAB (0x0B is vertical tab; 0x09 is tab) are PRESERVED.
# The first version of this helper used \000-\037, which included the newline,
# so it silently flattened the whole document onto one line -- every
# line-oriented parser downstream then saw no monitor blocks at all and
# reported "no displays". That is why it sat unused. It is now range-excluded.
hypr_clean_multiline() {
  printf '%s\n' "$1" | /usr/bin/tr -d '\000-\010\013-\015\016-\037\177'
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

# =====================================================================
# Display diagnostics
#
# Everything above answers "what does Hyprland report". What follows answers
# the questions the Display Doctor actually asks -- is this state internally
# CONSISTENT? -- so the logic lives here rather than in display.sh, where it
# could only ever be verified by looking at one real machine.
#
# A note on scope: Omarchy configures monitors in ~/.config/hypr/monitors.lua,
# which is LUA, not the classic `monitor=` syntax. Parsing it would mean
# guessing at a general Lua parser to reach a conclusion about the user's
# hardware. So none of these functions read a config file. They compare
# Hyprland's own reported state against itself, which is sufficient for the
# failures users actually hit -- a display that reverts after wake, a mode
# Hyprland cannot honour, a stale rule for hardware that is no longer attached.
# Reading the config would be a REPAIR-shaped operation, and this plugin does
# not repair.

# hypr_active_monitor_names MONITORS_TEXT -> names of monitors that are enabled.
#
# Distinct from hypr_monitor_names, which counts every block `monitors all`
# returns including disabled ones. "How many displays are actually working" and
# "how many outputs does this hardware have" are different questions and must
# not be answered by the same function.
hypr_active_monitor_names() {
  printf '%s\n' "$1" | /usr/bin/awk '
    function reap() { if (name != "" && !disabled) print name }
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

# hypr_active_monitor_count MONITORS_TEXT -> count of ENABLED monitors.
#
# Returns nothing (not 0) when hyprctl did not answer, so "no displays" is never
# confused with "could not ask". 0 is a real and serious answer, so it is
# returned as "0" deliberately.
hypr_active_monitor_count() {
  hypr_hyprland_error "$1" && return 1
  _n=$(hypr_active_monitor_names "$1" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
  case "$_n" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$_n"
}

# hypr_mode_is_supported MONITORS_TEXT MONITOR -> true when the monitor's
# CURRENT mode appears in its own availableModes list.
#
# This is the mode/mode mismatch the design brief called out: Hyprland applying
# a mode the output says it does not support is what causes a display to revert
# after a reconnect or a resume.
#
# The two sides are normalised before comparison, because they are NOT in the
# same format: the current mode is "1920x1080@59.99800" while the available list
# carries "1920x1080@60.00Hz". Comparing them literally would report a mismatch
# on every monitor, every time -- a false alarm worse than no check at all. So
# both sides are reduced to "<width>x<height>" and the refresh rate is compared
# with a tolerance.
#
# Refresh rates disagree by rounding: a panel advertising 59.94Hz reports its
# current mode as 59.99800 and its available list as 59.94Hz. They are the same
# rate. A tolerance of 1.0Hz covers that without hiding a genuine mismatch
# between, say, 60Hz and 120Hz.
hypr_mode_is_supported() {
  _hm_current=$(hypr_monitor_mode "$1" "$2")
  [ -n "$_hm_current" ] || return 1
  _hm_avail=$(printf '%s\n' "$1" | /usr/bin/awk -v want="$2" '
    /^Monitor [^ ]+ \(ID [0-9]+\):$/ {
      name = $0
      sub(/^Monitor /, "", name)
      sub(/ \(ID [0-9]+\):$/, "", name)
      inside = (name == want)
      next
    }
    inside && $1 == "availableModes:" {
      v = $0
      sub(/^[^:]*:[[:space:]]*/, "", v)
      print v
      exit
    }
  ')
  [ -n "$_hm_avail" ] || return 1

  # Reduce the current mode to resolution + numeric refresh.
  _hm_cres=$(printf '%s' "$_hm_current" | /usr/bin/sed -n 's/^\([0-9]*x[0-9]*\)@.*/\1/p')
  _hm_cref=$(printf '%s' "$_hm_current" | /usr/bin/sed -n 's/^.*@//p')
  [ -n "$_hm_cres" ] && [ -n "$_hm_cref" ] || return 1

  for _hm_m in $_hm_avail; do
    case "$_hm_m" in
      *Hz) ;;
      *) continue ;;
    esac
    _hm_ares=$(printf '%s' "$_hm_m" | /usr/bin/sed -n 's/^\([0-9]*x[0-9]*\)@.*/\1/p')
    _hm_aref=$(printf '%s' "$_hm_m" | /usr/bin/sed -n 's/^.*@\([0-9.]*\)Hz.*/\1/p')
    [ "$_hm_ares" = "$_hm_cres" ] || continue
    [ -n "$_hm_aref" ] || continue
    # awk for the comparison: shell arithmetic cannot do floating point.
    if printf '%s %s %s\n' "$_hm_cref" "$_hm_aref" | \
       /usr/bin/awk '{ d = $1 - $2; if (d < 0) d = -d; exit !(d <= 1.0) }'; then
      return 0
    fi
  done
  return 1
}

# hypr_mirrored_monitor MONITORS_TEXT -> the name of a monitor that mirrors
# another, or nothing.
#
# mirrorOf is "none" for an independent output and the other output's name for
# a mirror. Two outputs claiming to mirror the SAME third output, or an output
# mirroring one that is disabled, is a classic multi-monitor layout conflict.
hypr_mirrored_monitor() {
  printf '%s\n' "$1" | /usr/bin/awk '
    /^Monitor [^ ]+ \(ID [0-9]+\):$/ {
      name = $0
      sub(/^Monitor /, "", name)
      sub(/ \(ID [0-9]+\):$/, "", name)
      inside = 1
      next
    }
    inside && $1 == "mirrorOf:" {
      v = $0
      sub(/^[^:]*:[[:space:]]*/, "", v)
      sub(/[[:space:]]*$/, "", v)
      # "none" is the independent case, not a mirror.
      if (v != "" && v != "none") { print name "\t" v; exit }
    }
  '
}

# hypr_fractional_scale MONITORS_TEXT -> "MONITOR<SCALE>" for every monitor
# whose scale is not a whole number, or nothing.
#
# A fractional scale is a legitimate choice and NOT a fault -- it is reported as
# info. It is surfaced because it is the most common cause of "the UI looks
# blurry" and the user cannot see the cause otherwise. Scale 1.5 is the whole
# number-times-one-half case and is extremely common; anything with more decimal
# places is worth a second look.
hypr_fractional_scale() {
  printf '%s\n' "$1" | /usr/bin/awk '
    /^Monitor [^ ]+ \(ID [0-9]+\):$/ {
      name = $0
      sub(/^Monitor /, "", name)
      sub(/ \(ID [0-9]+\):$/, "", name)
      inside = 1
      next
    }
    inside && $1 == "scale:" {
      v = $0
      sub(/^[^:]*:[[:space:]]*/, "", v)
      sub(/[[:space:]]*$/, "", v)
      # An integer scale (1, 2, 3) has no fractional part at all.
      if (v ~ /^[0-9]+$/) next
      if (v == "") next
      print name "\t" v
    }
  '
}

# hypr_transformed_monitor MONITORS_TEXT -> "MONITOR<TRANSFORM>" for every
# monitor with a non-zero transform, or nothing.
#
# transform 0 is normal. 1/3 are 90/270 degrees (portrait) and 2/4/5/6 are
# mirrored variants. A mirrored transform is unusual enough to be worth naming,
# because it is easy to leave behind after re-plugging a cable and it looks like
# a driver bug.
hypr_transformed_monitor() {
  printf '%s\n' "$1" | /usr/bin/awk '
    /^Monitor [^ ]+ \(ID [0-9]+\):$/ {
      name = $0
      sub(/^Monitor /, "", name)
      sub(/ \(ID [0-9]+\):$/, "", name)
      inside = 1
      next
    }
    inside && $1 == "transform:" {
      v = $0
      sub(/^[^:]*:[[:space:]]*/, "", v)
      sub(/[[:space:]]*$/, "", v)
      if (v != "" && v != "0") print name "\t" v
    }
  '
}