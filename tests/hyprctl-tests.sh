#!/bin/sh
# OmaDoctor hyprctl parser tests.
#
# Scope: backend/hyprctl-parse.sh, driven by fixtures. No live system calls, so
# these run identically on any machine and pin the exact cases that could
# otherwise turn a hyprctl failure into a fabricated reading.
#
# The bug these guard: hyprctl reports THREE different failures -- an unknown
# subcommand, a missing compositor instance, and "no results" -- as ordinary
# stdout with EXIT STATUS 0. So a parser without a positive structural token
# reads "unknown request" or "HYPRLAND_INSTANCE_SIGNATURE not set!" as data.
# That is the audio bug in mirror image: wpctl's usage banner was once reported
# as a healthy device name, status "ok", value "Usage:".
#
# Every fixture below is either hand-authored or a trimmed capture. The error
# banners are hand-authored from hyprctl's documented behaviour, because
# provoking a real compositor error means breaking the user's live session.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
. "$BACKEND_DIR/hyprctl-parse.sh"

# A trimmed capture of real `hyprctl monitors` output from a laptop panel.
MONITORS_FIXTURE='Monitor eDP-1 (ID 0):
        1920x1080@59.99800 at 0x0
        description: BOE 0x0838
        make: BOE
        model: 0x0838
        active workspace: 2 (2)
        scale: 1
        transform: 0
        focused: yes
        dpmsStatus: 1
        disabled: false
        currentFormat: XRGB8888'

# Two attached monitors, neither focused -- so the focused one is the SECOND
# block. A parser that never resets its "focused" flag across blocks would
# wrongly report the first.
MONITORS_TWO_FIXTURE='Monitor eDP-1 (ID 0):
        1920x1080@60.00 at 0x0
        scale: 1
        focused: no
        disabled: false
Monitor DP-1 (ID 1):
        2560x1440@143.85 at 1920x0
        scale: 1.60
        focused: yes
        disabled: false'

# A disabled output that is NOT the last block -- the case a reap-in-END parser
# silently drops.
MONITORS_DISABLED_FIXTURE='Monitor DP-1 (ID 0):
        2560x1440@59.95 at 0x0
        focused: yes
        disabled: true
Monitor eDP-1 (ID 1):
        1920x1080@59.99 at 2560x0
        focused: no
        disabled: false'

# ------------------------------------------------------- error-banner guards
#
# These three are the whole reason this file exists. Each must yield NOTHING,
# never a plausible-looking reading.

check_eq "an unknown subcommand is not monitor data" "" \
  "$(hypr_monitor_names 'unknown request')"
check_eq "an unknown subcommand yields no monitor count" "" \
  "$(hypr_monitor_count 'unknown request')"

check_eq "a missing instance signature is not monitor data" "" \
  "$(hypr_monitor_names 'HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland running?)')"
check_eq "a missing instance signature yields no monitor count" "" \
  "$(hypr_monitor_count 'HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland running?)')"

# Older hyprctl word the same failure differently; both must be caught.
check_eq "the older instance-signature wording is also an error" "" \
  "$(hypr_monitor_count 'HYPRLAND_INSTANCE_SIGNATURE was not set! (Is Hyprland running?) (3)')"

check_eq "an unknown subcommand yields no config errors" "" \
  "$(hypr_config_errors 'unknown request')"
check_eq "an unknown subcommand yields no config error count" "" \
  "$(hypr_config_error_count 'unknown request')"
check_eq "a missing instance yields no config errors" "" \
  "$(hypr_config_errors 'HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland running?)')"

# An error banner must never be read as a version either.
check_eq "an unknown subcommand yields no version" "" \
  "$(hypr_version 'unknown request')"

# ------------------------------------------------------------ monitor parsing

check_eq "monitor names are extracted in order" "eDP-1" \
  "$(hypr_monitor_names "$MONITORS_FIXTURE")"
check_eq "monitor count is the number of monitor headers" "1" \
  "$(hypr_monitor_count "$MONITORS_FIXTURE")"
check_eq "two monitors are both counted" "2" \
  "$(hypr_monitor_count "$MONITORS_TWO_FIXTURE")"
check_eq "the focused monitor is found even when it is not first" "DP-1" \
  "$(hypr_active_monitor "$MONITORS_TWO_FIXTURE")"

check_eq "a monitor field is read for the named monitor" "1.60" \
  "$(hypr_monitor_field "$MONITORS_TWO_FIXTURE" DP-1 scale)"
check_eq "a monitor field is not borrowed from another monitor" "1" \
  "$(hypr_monitor_field "$MONITORS_TWO_FIXTURE" eDP-1 scale)"
# An absent field yields nothing, so "not reported" is never read as a value.
check_eq "an absent monitor field yields nothing" "" \
  "$(hypr_monitor_field "$MONITORS_FIXTURE" eDP-1 nonexistentfield)"
check_eq "an absent monitor yields nothing" "" \
  "$(hypr_monitor_field "$MONITORS_FIXTURE" NO-SUCH-MONITOR scale)"

check_eq "the mode line is read for the named monitor" "1920x1080@59.99800" \
  "$(hypr_monitor_mode "$MONITORS_FIXTURE" eDP-1)"
check_eq "the mode line is not borrowed from another monitor" "2560x1440@143.85" \
  "$(hypr_monitor_mode "$MONITORS_TWO_FIXTURE" DP-1)"

# A disabled output that is not the last block must still be reported.
check_eq "a disabled monitor is found when it is not the last block" "DP-1" \
  "$(hypr_monitor_disabled "$MONITORS_DISABLED_FIXTURE")"
check_eq "no disabled monitor is reported when all are attached" "" \
  "$(hypr_monitor_disabled "$MONITORS_TWO_FIXTURE")"

# ---------------------------------------------------------- config errors

# A clean config produces EMPTY output, and that legitimately means zero errors.
check_eq "empty configerrors output is zero errors" "0" \
  "$(hypr_config_error_count '')"

CONFIG_ERRORS_FIXTURE=' /home/u/.config/hypr/hyprland.conf:42: Unknown keyword: bogus
 /home/u/.config/hypr/monitors.lua:7: Invalid rule'
check_eq "config errors are counted" "2" \
  "$(hypr_config_error_count "$CONFIG_ERRORS_FIXTURE")"
check_eq "config errors are passed through with the file and line" \
  "/home/u/.config/hypr/hyprland.conf:42: Unknown keyword: bogus" \
  "$(hypr_config_errors "$CONFIG_ERRORS_FIXTURE" | head -n 1)"

# ------------------------------------------------------------ version

VERSION_FIXTURE='Hyprland 0.56.2 built from branch v0.56.2 at commit efb5099
Date: Wed Aug 5 14:13:21 2026
Tag: v0.56.2, commits: 7661'
check_eq "the version is read from the expected shape" "0.56.2" \
  "$(hypr_version "$VERSION_FIXTURE")"
# A reworded banner must not yield a number rather than nothing.
check_eq "an unrecognised version banner yields nothing" "" \
  "$(hypr_version 'some future hyprctl banner without the usual shape')"

# --------------------------------------------------------- workspaces

WORKSPACES_FIXTURE='workspace ID 2 (2) on monitor eDP-1:
        monitorID: 0
        windows: 1
workspace ID 1 (1) on monitor eDP-1:
        monitorID: 0
        windows: 0'
check_eq "workspaces are counted" "2" \
  "$(hypr_workspace_count "$WORKSPACES_FIXTURE")"
check_eq "an unknown subcommand yields no workspace count" "" \
  "$(hypr_workspace_count 'unknown request')"

finish