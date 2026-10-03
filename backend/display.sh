#!/bin/sh
# OmaDoctor Display Doctor.
#
# Answers one question: is Hyprland's current display configuration internally
# CONSISTENT? It is deliberately not a monitor manager -- it never writes a
# monitor rule, never reloads Hyprland, and never touches monitors.lua.
#
# WHY IT DOES NOT READ THE CONFIG
# Omarchy configures displays in ~/.config/hypr/monitors.lua, which is LUA, not
# the classic `monitor=` syntax. Reading it correctly would mean implementing a
# general Lua parser to reach a conclusion about the user's hardware -- fragile,
# and it would put a config-parsing failure on the path of a health verdict.
# So this section compares Hyprland's OWN reported state against itself, which
# is enough for the failures users actually hit: a display that reverts after
# wake, a mode Hyprland cannot honour, a stale rule for hardware that is no
# longer attached.
#
# All comparison logic lives in hyprctl-parse.sh and is pinned by fixtures in
# tests/hyprctl-tests.sh, so every rule below is verifiable without a
# multi-monitor desk.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/hyprctl-parse.sh"

CHECKS=""

# Raw first argument: doctor.sh passes --checks-only and emit_json switches on
# that literal. See the note in services.sh.
MODE=${1:-}

if ! have hyprctl; then
  emit "display.available" display info 0 "Display inspection" "unavailable" \
    "hyprctl is not available on this system" ""
  emit_json display "$MODE"
  exit 0
fi

# Without a compositor instance every check degrades to unknown. The plugin may
# legitimately run outside a Hyprland session, and reporting "no display" there
# would be a fabricated fault on a perfectly healthy machine.
if [ -z "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]; then
  emitd "display.outputs" display info 0 "Outputs" "unknown" \
    "no Hyprland instance is reachable from this process" \
    "Expected outside a Hyprland session" \
    "no compositor instance visible"
  emit_json display "$MODE"
  exit 0
fi

_d_monitors=$(/usr/bin/hyprctl monitors all 2>/dev/null)
if hypr_hyprland_error "$_d_monitors"; then
  emitd "display.outputs" display info 0 "Outputs" "unknown" \
    "hyprctl did not answer the monitor query" \
    "Try: hyprctl monitors all" \
    "hyprctl returned an error banner"
  emit_json display "$MODE"
  exit 0
fi

# ------------------------------------------------------------ attached outputs

# "monitors all" is required, not "monitors": a DISABLED output is the
# signature of a saved rule for hardware that is not attached right now, which
# is precisely the complaint that a display "reverts" after being unplugged or
# after waking. The plain "monitors" omits those blocks entirely.
_d_active=$(hypr_active_monitor_count "$_d_monitors")
_d_total=$(hypr_monitor_count "$_d_monitors")

if [ -z "$_d_active" ]; then
  # hyprctl answered but carried no monitor block at all. Could be a very new
  # hyprctl whose format changed. Unknown, not a fault.
  emitd "display.outputs" display info 0 "Outputs" "unknown" \
    "the monitor list could not be parsed" \
    "If this persists, the parser needs updating for this hyprctl version" \
    "no monitor block found in hyprctl output"
  emit_json display "$MODE"
  exit 0
fi

if [ "$_d_active" -eq 0 ]; then
  # A real and serious answer: the compositor is running with nothing attached
  # or nothing enabled. This is the "my display went dark" case.
  emitr "display.outputs" display problem 3 "Outputs" "none active" \
    "Hyprland reports $_d_total output(s) but none are enabled" \
    "Check the cable, and whether a monitor rule disables this output" \
    manual "Re-enable the display" \
    "OmaDoctor never edits your monitor configuration" \
    "active outputs: 0" \
    "outputs seen: $_d_total"
  emit_json display "$MODE"
  exit 0
fi

_d_names=$(hypr_active_monitor_names "$_d_monitors" | /usr/bin/tr '\n' ' ')
if [ -n "$_d_names" ]; then
  _d_names=$(printf '%s' "$_d_names" | /usr/bin/sed 's/[[:space:]]*$//')
fi
if [ "$_d_total" = "$_d_active" ]; then
  emitd "display.outputs" display ok 0 "Outputs" "$_d_active active" \
    "every detected output is enabled" \
    "" \
    "outputs: $_d_names"
else
  emitd "display.outputs" display ok 0 "Outputs" "$_d_active active" \
    "$_d_active of $_d_total detected outputs are enabled" \
    "" \
    "active: $_d_names" \
    "detected: $_d_total"
fi

# ------------------------------------------------------------ disabled outputs
#
# A disabled output is not itself a fault -- it is normal for a laptop with a
# docked monitor to keep the undocked panel's rule around. It becomes worth
# reporting when the rule refers to hardware that is not present at all, which
# is the stale-rule case.

_d_disabled=$(hypr_monitor_disabled "$_d_monitors")
if [ -n "$_d_disabled" ]; then
  _d_dlist=$(printf '%s' "$_d_disabled" | /usr/bin/tr '\n' ' ')
  _d_dlist=$(printf '%s' "$_d_dlist" | /usr/bin/sed 's/[[:space:]]*$//')
  emitd "display.disabled_outputs" display attention 1 "Inactive outputs" \
    "$(printf '%s' "$_d_disabled" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" \
    "a monitor rule exists for output(s) that are not currently active" \
    "Harmless while unplugged; if a display stops coming back after replugging, this is why" \
    "disabled: $_d_dlist"
else
  emitd "display.disabled_outputs" display ok 0 "Inactive outputs" "none" \
    "no disabled outputs" ""
fi

# ------------------------------------------------------------ mode consistency
#
# Per monitor, because one bad output among several is exactly the case a
# whole-section verdict would hide. Unsupported modes are a warning, not a
# failure: Hyprland can still apply one, it just may not survive a reconnect.

_d_mismatch=""
_d_checked=0
for _d_m in $(hypr_monitor_names "$_d_monitors"); do
  _d_checked=$((_d_checked + 1))
  if ! hypr_mode_is_supported "$_d_monitors" "$_d_m"; then
    _d_mode=$(hypr_monitor_mode "$_d_monitors" "$_d_m")
    if [ -n "$_d_mismatch" ]; then
      _d_mismatch="$_d_mismatch; "
    fi
    _d_mismatch="${_d_mismatch}$_d_m at $_d_mode"
  fi
done

if [ "$_d_checked" -eq 0 ]; then
  emit "display.modes" display info 0 "Modes" "unknown" \
    "no monitor could be read" ""
elif [ -z "$_d_mismatch" ]; then
  emitd "display.modes" display ok 0 "Modes" "supported" \
    "every active output runs a mode that output reports as available" \
    "" \
    "outputs checked: $_d_checked"
else
  emitr "display.modes" display attention 1 "Modes" "unsupported mode set" \
    "an output is running a mode it does not list as available" \
    "This is why a display can revert to another resolution after a reconnect or resume" \
    caution "Adjust the monitor rule's mode" \
    "OmaDoctor never edits your monitor configuration" \
    "affected: $_d_mismatch"
fi

# ------------------------------------------------------------------- mirroring

_d_mirror=$(hypr_mirrored_monitor "$_d_monitors")
if [ -n "$_d_mirror" ]; then
  _d_mirror_txt=$(printf '%s' "$_d_mirror" | /usr/bin/sed 's/\t/ -> /')
  emitd "display.mirroring" display info 0 "Mirroring" "in use" \
    "an output is mirroring another" \
    "Mirroring is a deliberate choice; listed so it is not mistaken for a fault" \
    "mirror: $_d_mirror_txt"
else
  emitd "display.mirroring" display ok 0 "Mirroring" "none" \
    "outputs are independent" ""
fi

# ------------------------------------------------------ scale and orientation
#
# Both are informational, never a fault. A fractional scale is legitimate and
# common; a rotated display is deliberate. They are surfaced because each is a
# frequent cause of "something looks wrong" that the user cannot otherwise
# explain -- blurry text, or an upside-down secondary panel.

_d_frac=$(hypr_fractional_scale "$_d_monitors")
if [ -n "$_d_frac" ]; then
  _d_frac_txt=$(printf '%s' "$_d_frac" | /usr/bin/sed 's/\t/ at scale /')
  emitd "display.scale" display info 0 "Scale" "fractional" \
    "an output is using a fractional scale" \
    "Legitimate, and a common cause of slightly soft text" \
    "scaled: $_d_frac_txt"
else
  emitd "display.scale" display ok 0 "Scale" "integer" \
    "every output uses a whole-number scale" ""
fi

_d_xform=$(hypr_transformed_monitor "$_d_monitors")
if [ -n "$_d_xform" ]; then
  _d_xform_txt=$(printf '%s' "$_d_xform" | /usr/bin/sed 's/\t/ = /')
  emitd "display.orientation" display info 0 "Orientation" "rotated or mirrored" \
    "an output has a non-zero transform" \
    "Intended for a rotated panel; worth checking after re-plugging a cable" \
    "transforms: $_d_xform_txt"
else
  emitd "display.orientation" display ok 0 "Orientation" "normal" \
    "no output is rotated" ""
fi

emit_json display "$MODE"