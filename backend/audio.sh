#!/bin/sh
# OmaDoctor audio check.
#
# Emits: {"section":"audio","checks":[ ... ]}
#   with --checks-only: prints just the JSON array (used by doctor.sh).
#
# Read-only. Queries the user session's PipeWire/WirePlumber state via wpctl and
# systemctl --user. Never restarts a service -- restarting audio is a repair
# action and is out of scope for this read-only milestone.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

MODE=${1:-}
CHECKS=""

# user_service_state NAME -> active | inactive | failed | unknown
user_service_state() {
  _st=$(/usr/bin/systemctl --user is-active "$1" 2>/dev/null | /usr/bin/head -n 1)
  case "$_st" in
    active | inactive | failed | activating | deactivating | "") printf '%s' "${_st:-unknown}" ;;
    *) printf 'unknown' ;;
  esac
}

# --------------------------------------------------------------- audio server
pipewire=$(user_service_state pipewire.service)
wpulse=$(user_service_state pipewire-pulse.service)
wplumber=$(user_service_state wireplumber.service)

server_detail="pipewire=$pipewire pulse=$wpulse wireplumber=$wplumber"

if [ "$pipewire" = "failed" ] || [ "$wplumber" = "failed" ]; then
  emit "audio.server" audio problem 3 "Audio server" "failed" "$server_detail" \
    "Inspect with: systemctl --user --failed"
elif [ "$pipewire" = "active" ] && [ "$wplumber" = "active" ]; then
  emit "audio.server" audio ok 0 "Audio server" "running" "$server_detail" ""
elif [ "$pipewire" = "active" ]; then
  emit "audio.server" audio attention 1 "Audio server" "degraded" "$server_detail" \
    "WirePlumber is not running; device routing and volume control will misbehave."
else
  emit "audio.server" audio problem 3 "Audio server" "not running" "$server_detail" \
    "Audio will not work at all. Restart it with: systemctl --user restart pipewire wireplumber"
fi

# ------------------------------------------------------------- default devices
if have wpctl; then
  # wpctl prints the object id on success and a diagnostic line on failure.
  sink=$(/usr/bin/timeout -k 2 3 wpctl get-default-sink 2>/dev/null | /usr/bin/head -n 1)
  case "$sink" in
    '' | *'"'* | *'not found'* | *'No '*)
      if [ "$pipewire" = "active" ]; then
        emit "audio.output" audio attention 1 "Default output" "none" \
          "wpctl returned no default sink" \
          "No output device selected; pick one in Settings > Sound."
      else
        emit "audio.output" audio info 0 "Default output" "unavailable" \
          "audio server is not running" ""
      fi
      ;;
    *)
      # Make the numeric id readable: wpctl ids look like "45" or "@DEFAULT_SINK@".
      case "$sink" in
        @*) sink_name=$(/usr/bin/timeout -k 2 3 wpctl status 2>/dev/null \
                       | /usr/bin/grep -F "$sink" | /usr/bin/head -n 1 \
                       | /usr/bin/sed 's/^[[:space:]]*//; s/\..*//') ;;
        *)  sink_name=$sink ;;
      esac
      emit "audio.output" audio ok 0 "Default output" "${sink_name:-$sink}" \
        "wpctl default sink" ""
      ;;
  esac

  source=$(/usr/bin/timeout -k 2 3 wpctl get-default-source 2>/dev/null | /usr/bin/head -n 1)
  case "$source" in
    '' | *'"'* | *'not found'* | *'No '*)
      emit "audio.input" audio info 0 "Default input" "none" \
        "no default source" \
        "Expected on a desktop without a microphone; harmless if you do not record."
      ;;
    *)
      emit "audio.input" audio ok 0 "Default input" "$source" \
        "wpctl default source" ""
      ;;
  esac

  # ----------------------------------------------------------- volume / mute
  vol=$(/usr/bin/timeout -k 2 3 wpctl get-volume "@DEFAULT_AUDIO_SINK@" 2>/dev/null | /usr/bin/head -n 1)
  case "$vol" in
    *VOLUME*)
      volpct=$(printf '%s' "$vol" | /usr/bin/sed -n 's/.*\([0-9]\{1,3\}\)%.*/\1/p' | /usr/bin/head -n 1)
      muted=no
      case "$vol" in *MUTED*) muted=yes ;; esac
      if [ "$muted" = yes ]; then
        emit "audio.volume" audio attention 1 "Output volume" "muted" \
          "sink is muted at ${volpct:-?}%" \
          "Unmute in Settings > Sound or with the volume key."
      elif [ -n "$volpct" ] && [ "$volpct" -eq 0 ] 2>/dev/null; then
        emit "audio.volume" audio attention 1 "Output volume" "0%" \
          "sink volume is zero" \
          "Raise the volume; the device is connected but silent."
      else
        emit "audio.volume" audio ok 0 "Output volume" "${volpct:-?}%" \
          "sink responds to volume control" ""
      fi
      ;;
    *)
      emit "audio.volume" audio info 0 "Output volume" "unknown" \
        "wpctl get-volume returned nothing" ""
      ;;
  esac

  # ------------------------------------------------------------ device count
  devs=$(/usr/bin/timeout -k 2 3 wpctl status 2>/dev/null | /usr/bin/grep -cE '^\s+(Sinks|Sources):|Device' || true)
  case "$devs" in '' | *[!0-9]*) devs=0 ;; esac
  emit "audio.devices" audio info 0 "Devices" "$devs" \
    "entries reported by wpctl status" ""
else
  emit "audio.devices" audio info 0 "Audio devices" "unknown" \
    "wpctl (wireplumber) not installed" \
    "Install wireplumber to get audio diagnostics."
fi

emit_json audio "$MODE"
