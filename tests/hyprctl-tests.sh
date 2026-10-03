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

# =====================================================================
# Display diagnostics
#
# The Display Doctor asks whether Hyprland's reported display state is
# internally CONSISTENT. These fixtures are hand-authored from the field shapes
# confirmed against live `hyprctl monitors all` output on this machine; the
# single-monitor fixture is a trimmed real capture. The multi-monitor cases are
# synthetic because this machine has one display -- so they are checked against
# the field NAMES hyprland actually emits, not against a captured two-monitor
# session.

# Two outputs: DP-1 active but scaled 1.50 and rotated, mirroring a second
# output that is itself DISABLED. That is a genuine layout conflict and the
# single most common multi-monitor complaint.
MONITORS_LAYOUT_FIXTURE='Monitor DP-1 (ID 0):
        1920x1080@59.99800 at 0x0
        scale: 1.50
        transform: 1
        focused: yes
        disabled: false
        mirrorOf: DP-2
        availableModes: 1920x1080@60.00Hz 1280x1024@60.00Hz
Monitor DP-2 (ID 1):
        1920x1080@60.00 at 3840x0
        scale: 1
        transform: 0
        focused: no
        disabled: true
        mirrorOf: none
        availableModes: 1920x1080@60.00Hz'

# Active and healthy, with an INTEGER scale so the fractional check is not
# triggered by accident.
MONITORS_CLEAN_TWO_FIXTURE='Monitor eDP-1 (ID 0):
        1920x1080@59.99800 at 0x0
        scale: 1
        transform: 0
        focused: yes
        disabled: false
        mirrorOf: none
        availableModes: 1920x1080@60.00Hz
Monitor DP-1 (ID 1):
        2560x1440@143.85 at 1920x0
        scale: 2
        transform: 0
        focused: no
        disabled: false
        mirrorOf: none
        availableModes: 2560x1440@144.00Hz 1920x1080@60.00Hz'

# The current mode is one the output does not list: the mode/mode mismatch that
# makes a display revert after a reconnect or a resume.
MONITORS_BADMODE_FIXTURE='Monitor DP-1 (ID 0):
        3840x2160@120.00000 at 0x0
        scale: 1
        transform: 0
        focused: yes
        disabled: false
        mirrorOf: none
        availableModes: 3840x2160@60.00Hz 1920x1080@60.00Hz'

# ------------------------------------------- active vs total monitor counts
#
# "How many displays work" and "how many outputs does this hardware have" are
# different questions. Conflating them makes a disabled output look like a
# missing display, or hides a genuinely absent one behind a disabled one.

check_eq "active monitors exclude disabled outputs" "DP-1" \
  "$(hypr_active_monitor_names "$MONITORS_LAYOUT_FIXTURE" | tr '\n' ' ' | /usr/bin/sed 's/ $//')"
check_eq "active monitor count counts only enabled outputs" "1" \
  "$(hypr_active_monitor_count "$MONITORS_LAYOUT_FIXTURE")"
check_eq "total monitor count includes disabled outputs" "2" \
  "$(hypr_monitor_count "$MONITORS_LAYOUT_FIXTURE")"
check_eq "all-enabled layouts report every monitor as active" "eDP-1 DP-1" \
  "$(hypr_active_monitor_names "$MONITORS_CLEAN_TWO_FIXTURE" | tr '\n' ' ' | /usr/bin/sed 's/ $//')"
check_eq "all-enabled layouts count every monitor as active" "2" \
  "$(hypr_active_monitor_count "$MONITORS_CLEAN_TWO_FIXTURE")"

# Zero active monitors is a real, serious answer and must be returned as "0"
# rather than as nothing. Nothing means "hyprctl did not answer", which is a
# completely different thing and must never be reported as "no displays".
check_eq "zero active monitors is reported as 0, not as unknown" "0" \
  "$(hypr_active_monitor_count 'Monitor DP-1 (ID 0):
        1920x1080@60.00 at 0x0
        scale: 1
        transform: 0
        focused: no
        disabled: true
        availableModes: 1920x1080@60.00Hz')"
check_eq "an error banner yields no active monitor count at all" "" \
  "$(hypr_active_monitor_count 'unknown request')"
check_eq "an error banner is not read as zero active monitors" "" \
  "$(hypr_active_monitor_count 'HYPRLAND_INSTANCE_SIGNATURE not set! (is hyprland running?)')"

# ------------------------------------------------------ mode is supported
#
# The refresh tolerance is the whole point of this check. The two sides are in
# different formats -- "1920x1080@59.99800" versus "1920x1080@60.00Hz" -- so a
# literal comparison reports a mismatch on EVERY monitor, EVERY time. That
# false alarm would be worse than having no check at all, because users would
# learn to ignore it.

check_eq "a rounding difference is not a mode mismatch" "yes" \
  "$(hypr_mode_is_supported "$MONITORS_CLEAN_TWO_FIXTURE" eDP-1 && echo yes || echo no)"
check_eq "a 143.85 vs 144.00 difference is not a mismatch" "yes" \
  "$(hypr_mode_is_supported "$MONITORS_CLEAN_TWO_FIXTURE" DP-1 && echo yes || echo no)"
check_eq "a mode the output does not list IS a mismatch" "no" \
  "$(hypr_mode_is_supported "$MONITORS_BADMODE_FIXTURE" DP-1 && echo yes || echo no)"
check_eq "an unavailable monitor reports no verdict either way" "no" \
  "$(hypr_mode_is_supported "$MONITORS_BADMODE_FIXTURE" NO-SUCH-MONITOR && echo yes || echo no)"
check_eq "a monitor with no availableModes list reports no verdict" "no" \
  "$(hypr_mode_is_supported 'Monitor DP-1 (ID 0):
        1920x1080@60.00 at 0x0
        scale: 1' DP-1 && echo yes || echo no)"

# A fractional scale must never be mistaken for an unsupported mode: 1.50 is
# common and legitimate.
check_eq "a fractional scale does not affect the mode verdict" "yes" \
  "$(hypr_mode_is_supported "$MONITORS_LAYOUT_FIXTURE" DP-1 && echo yes || echo no)"

# ---------------------------------------------------------------- mirrors

check_eq "a mirrored monitor is reported with its target" "DP-1	DP-2" \
  "$(hypr_mirrored_monitor "$MONITORS_LAYOUT_FIXTURE")"
check_eq "mirrorOf none is an independent output, not a mirror" "" \
  "$(hypr_mirrored_monitor "$MONITORS_CLEAN_TWO_FIXTURE")"
check_eq "an error banner yields no mirror reading" "" \
  "$(hypr_mirrored_monitor 'unknown request')"

# ------------------------------------------------- fractional scale / transform

check_eq "a fractional scale is reported with its monitor" "DP-1	1.50" \
  "$(hypr_fractional_scale "$MONITORS_LAYOUT_FIXTURE")"
# Integer scales (1, 2, 3) are the normal case and must not be flagged.
check_eq "integer scales are not reported as fractional" "" \
  "$(hypr_fractional_scale "$MONITORS_CLEAN_TWO_FIXTURE")"
check_eq "a non-zero transform is reported with its monitor" "DP-1	1" \
  "$(hypr_transformed_monitor "$MONITORS_LAYOUT_FIXTURE")"
check_eq "transform zero is normal and is not reported" "" \
  "$(hypr_transformed_monitor "$MONITORS_CLEAN_TWO_FIXTURE")"
check_eq "an error banner yields no transform reading" "" \
  "$(hypr_transformed_monitor 'unknown request')"

finish