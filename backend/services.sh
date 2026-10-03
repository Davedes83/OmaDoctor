#!/bin/sh
# OmaDoctor Services Doctor.
#
# Reports the health of the daemons a working Omarchy session depends on. This
# is a REPEAT of state, not a repair: restarting a service is a repair (a
# future v0.3 concern) and nothing here ever does it. Every probe is
# `systemctl show`, which is read-only.
#
# USER vs SYSTEM matters and is easy to get wrong. `networkmanager.service` and
# `bluetooth.service` are SYSTEM units: asking systemctl --user for them yields
# LoadState=not-found, so a user-only allowlist would report two perfectly
# healthy daemons as missing. Each unit below therefore declares its scope.
#
# A unit that is not installed is reported as "not installed" (info), never as a
# problem: a machine without bluetooth hardware is not broken.
#
# No overall verdict check is emitted. The per-daemon checks already roll up to
# the category via worst-wins in Model.js, so an extra summary check would
# double-count the same failure in the panel and the report.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

CHECKS=""

# Capture the RAW first argument, not a validated mode. doctor.sh invokes this
# script as `services.sh --checks-only`, and it is emit_json that switches on
# that literal to emit BARE comma-separated objects so the dispatcher can
# concatenate sections and wrap one array. Parsing --checks-only away and
# storing "quick" instead makes emit_json emit a whole {section,checks}
# document, which the dispatcher then splices into the array as an ELEMENT --
# producing checks that are nested documents with no `id`, which breaks every
# consumer downstream.
MODE=${1:-}

if ! have systemctl; then
  emit "services.systemctl" services info 0 "Service inspection" "unavailable" \
    "systemctl not found on PATH" ""
  emit_json services "$MODE"
  exit 0
fi

# svc_state SCOPE UNIT -> "<LoadState> <ActiveState> <SubState>", or nothing.
#
# `systemctl show -p ... --value` prints the three values space separated in a
# fixed order. A bare "--value" with an unrecognised verb would print something
# else entirely -- notably `systemctl --user frobnicate` answers "Unknown
# command verb 'frobnicate'." and still EXITS 0. So the result is only accepted
# when it is exactly three words, each drawn from the known systemd state
# vocabulary. Anything else yields nothing and the caller reports "unknown",
# never an invented state.
svc_state() {
  # `systemctl show --value` prints one property PER LINE, not space separated,
  # so the three values arrive newline-delimited. Flatten to single spaces first
  # -- otherwise a later `cut -d' '` sees no space at all and returns the whole
  # multi-line blob, which would sail past the field-count guard as a
  # plausible-looking but wrong "state".
  _sv_out=$(/usr/bin/systemctl "$1" show "$2" \
    -p LoadState -p ActiveState -p SubState --value 2>/dev/null \
    | /usr/bin/tr '\n' ' ')
  _sv_n=$(printf '%s' "$_sv_out" | /usr/bin/wc -w | /usr/bin/tr -d ' ')
  [ "$_sv_n" = "3" ] || return 1
  _sv_load=0; _sv_active=0; _sv_sub=0
  for _sv_w in $_sv_out; do
    case "$_sv_w" in
      loaded | not-found | masked | error | bad-setting | merged | stub)
        _sv_load=1 ;;
      active | inactive | failed | activating | deactivating | reloading)
        _sv_active=1 ;;
      running | dead | exited | listening | failed | start | stop | sigchld)
        _sv_sub=1 ;;
      *)
        return 1 ;;
    esac
  done
  [ "$_sv_load" = "1" ] && [ "$_sv_active" = "1" ] && [ "$_sv_sub" = "1" ] || return 1
  # Collapse to single spaces so the caller can cut on a space deterministically.
  printf '%s' "$_sv_out" | /usr/bin/tr -s ' '
}

# svc_check SCOPE ID LABEL UNIT
#
# One daemon, one check. The unit name is a fixed literal from the allowlist
# below -- never user input -- and is always passed as its own argv entry.
svc_check() {
  _sc_scope=$1; _sc_id=$2; _sc_label=$3; _sc_unit=$4
  _sc_hint="systemctl $_sc_scope status $_sc_unit"

  if ! _sc_state=$(svc_state "$_sc_scope" "$_sc_unit"); then
    emitd "$_sc_id" services info 0 "$_sc_label" "unknown" \
      "systemctl did not report a state for $_sc_unit" \
      "Inspect with: $_sc_hint" \
      "probed scope: $_sc_scope"
    return 0
  fi

  # word 1 = LoadState, word 2 = ActiveState, word 3 = SubState
  _sc_load=$(printf '%s' "$_sc_state" | /usr/bin/cut -d' ' -f1)
  _sc_active=$(printf '%s' "$_sc_state" | /usr/bin/cut -d' ' -f2)
  _sc_sub=$(printf '%s' "$_sc_state" | /usr/bin/cut -d' ' -f3)

  case "$_sc_load" in
    not-found)
      # Not installed. Not a fault: plenty of healthy machines have no
      # bluetooth stack, and Omarchy may not use every listed unit.
      emit "$_sc_id" services info 0 "$_sc_label" "not installed" \
        "$_sc_unit is not installed on this system" ""
      return 0 ;;
    masked)
      emit "$_sc_id" services attention 1 "$_sc_label" "masked" \
        "$_sc_unit is masked and will not start" \
        "Unmask with: systemctl $_sc_scope unmask $_sc_unit"
      return 0 ;;
    error | bad-setting)
      emitr "$_sc_id" services problem 3 "$_sc_label" "unit error" \
        "systemd cannot load $_sc_unit ($_sc_load)" \
        "Run '$_sc_hint' and read the unit file" \
        manual "Repair the unit file" \
        "A malformed unit file cannot be fixed automatically" \
        "LoadState=$_sc_load" \
        "unit: $_sc_unit"
      return 0 ;;
  esac

  case "$_sc_active" in
    active)
      emitd "$_sc_id" services ok 0 "$_sc_label" "$_sc_sub" \
        "$_sc_unit is active ($_sc_sub)" \
        "" \
        "unit: $_sc_unit" \
        "scope: $_sc_scope"
      return 0 ;;
    failed)
      # The one genuinely actionable state. The restart itself is a repair and
      # is deliberately NOT performed -- only described.
      emitr "$_sc_id" services problem 3 "$_sc_label" "failed" \
        "$_sc_unit is in a failed state" \
        "Inspect the logs before restarting anything" \
        safe "Restart $_sc_unit" \
        "Restarts the $_sc_scope unit. OmaDoctor does not run this." \
        "unit: $_sc_unit" \
        "substate: $_sc_sub"
      return 0 ;;
    activating | deactivating | reloading)
      emit "$_sc_id" services info 0 "$_sc_label" "$_sc_active" \
        "$_sc_unit is $_sc_active" ""
      return 0 ;;
    inactive)
      # Inactive is only a fault for a unit that must be running. Every unit
      # here is optional, so this stays info and the value says which it is.
      emit "$_sc_id" services info 0 "$_sc_label" "inactive" \
        "$_sc_unit is installed but not running" \
        "Start it with: systemctl $_sc_scope start $_sc_unit"
      return 0 ;;
  esac

  emit "$_sc_id" services info 0 "$_sc_label" "$_sc_active" \
    "$_sc_unit reported state $_sc_active" ""
}

# ------------------------------------------------------------------ allowlist
#
# A fixed set, at a fixed scope, with fixed argv. Nothing here comes from
# output, a config file, or anything the user typed.
#
# omarchy-shell is deliberately absent: the bar is not a systemd user service,
# so listing it would report a healthy plugin as "not installed" forever.

# --- user scope: the desktop session's own daemons
svc_check --user  services.pipewire     "PipeWire"        pipewire.service
svc_check --user  services.wireplumber  "WirePlumber"     wireplumber.service
svc_check --user  services.portal       "Desktop portal"  xdg-desktop-portal.service
svc_check --user  services.portal_hypr  "Hyprland portal" xdg-desktop-portal-hyprland.service

# --- system scope: networking and bluetooth live here, not in the user manager
svc_check --system services.networkmanager "NetworkManager"    NetworkManager.service
svc_check --system services.bluetooth      "Bluetooth service" bluetooth.service

emit_json services "$MODE"