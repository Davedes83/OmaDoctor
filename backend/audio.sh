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
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/wpctl-parse.sh"

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
  # One `wpctl status` call feeds every device lookup. wpctl has no
  # get-default-sink/get-default-source subcommand -- calling one prints the
  # usage banner, whose first line is "Usage:", which reads as a device name.
  wpstatus=$(/usr/bin/timeout -k 2 3 wpctl status 2>/dev/null)

  # A parsed name is only trustworthy alongside a numeric node id, so a partial
  # or unexpected parse degrades to "unknown" rather than reporting a device.
  sink_line=$(wp_default_node "$wpstatus" Sinks)
  sink_id=${sink_line%%	*}
  sink_name=${sink_line#*	}
  case "$sink_id" in
    '' | *[!0-9]*) sink_name="" ;;
  esac

  if [ -n "$sink_name" ]; then
    emit "audio.output" audio ok 0 "Default output" "$sink_name" \
      "wpctl node $sink_id" ""
  elif [ "$pipewire" = "active" ]; then
    emit "audio.output" audio attention 1 "Default output" "none" \
      "no default sink marked in wpctl status" \
      "No output device selected; pick one in Settings > Sound."
  else
    emit "audio.output" audio info 0 "Default output" "unavailable" \
      "audio server is not running" ""
  fi

  # Scoped to the Audio graph: wpctl status also stars the Video graph's camera
  # source, which is not an audio input.
  src_line=$(wp_default_node "$wpstatus" Sources)
  src_id=${src_line%%	*}
  src_name=${src_line#*	}
  case "$src_id" in
    '' | *[!0-9]*) src_name="" ;;
  esac

  if [ -n "$src_name" ]; then
    emit "audio.input" audio ok 0 "Default input" "$src_name" \
      "wpctl node $src_id" ""
  elif [ "$pipewire" = "active" ]; then
    emit "audio.input" audio info 0 "Default input" "none" \
      "no default source marked in wpctl status" \
      "Expected on a desktop without a microphone; harmless if you do not record."
  else
    emit "audio.input" audio info 0 "Default input" "unavailable" \
      "audio server is not running" ""
  fi

  # ----------------------------------------------------------- volume / mute
  # wpctl prints a 0..1 float ("Volume: 0.45"); the parser normalises both that
  # and a percentage form to a percentage.
  vol=$(/usr/bin/timeout -k 2 3 wpctl get-volume "@DEFAULT_AUDIO_SINK@" 2>/dev/null)
  volpct=$(wp_vol_pct "$vol")
  if wp_vol_muted "$vol"; then
    emit "audio.volume" audio attention 1 "Output volume" "muted" \
      "sink is muted at ${volpct:-?}%" \
      "Unmute in Settings > Sound or with the volume key."
  elif [ -n "$volpct" ] && [ "$volpct" -eq 0 ] 2>/dev/null; then
    emit "audio.volume" audio attention 1 "Output volume" "0%" \
      "sink volume is zero" \
      "Raise the volume; the device is connected but silent."
  elif [ -n "$volpct" ]; then
    emit "audio.volume" audio ok 0 "Output volume" "${volpct}%" \
      "sink responds to volume control" ""
  elif [ "$pipewire" = "active" ]; then
    # The server is up but its volume cannot be read: that unreadability is
    # itself the finding. Reporting "unknown"/info here would present a broken
    # audio stack as healthy.
    emit "audio.volume" audio attention 1 "Output volume" "unreadable" \
      "wpctl get-volume returned no volume (got: ${vol:-nothing})" \
      "Inspect with: systemctl --user status pipewire wireplumber"
  else
    emit "audio.volume" audio info 0 "Output volume" "unknown" \
      "audio server is not running" ""
  fi

  # ------------------------------------------------------------ device count
  devs=$(printf '%s\n' "$wpstatus" | /usr/bin/grep -cE '^[[:space:]]+(Sinks|Sources):|Device' || true)
  case "$devs" in '' | *[!0-9]*) devs=0 ;; esac
  emit "audio.devices" audio info 0 "Devices" "$devs" \
    "entries reported by wpctl status" ""
else
  emit "audio.devices" audio info 0 "Audio devices" "unknown" \
    "wpctl (wireplumber) not installed" \
    "Install wireplumber to get audio diagnostics."
fi

emit_json audio "$MODE"
