#!/bin/sh
# OmaDoctor wpctl parser tests.
#
# Scope: backend/wpctl-parse.sh, driven by captured fixtures. No live system
# calls, so these run identically on any machine and pin the exact cases that
# produced fabricated readings.
#
# The bug these guard: wpctl has no get-default-sink/get-default-source
# subcommand. Calling one prints a usage banner whose first line is "Usage:",
# and the audio section reported that string as the name of a healthy default
# output device -- status "ok", value "Usage:". A check that read nothing was
# displayed as a check that passed.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"
. "$BACKEND_DIR/wpctl-parse.sh"

# A trimmed capture of real `wpctl status` output. Two graphs are present and
# BOTH contain a starred line: the Audio graph stars a sink and a source, the
# Video graph stars a camera source. A parser that scans globally returns the
# camera for "Sources", which is not an audio input at all.
STATUS_FIXTURE='PipeWire '"'"'pipewire-0'"'"' [1.6.8, davedes@omarchy, cookie:202015368]
 └─ Clients:
        32. WirePlumber                         [1.6.8, davedes@omarchy, pid:1163]

Audio
 ├─ Devices:
 │      48. HDA NVidia                          [alsa]
 │      49. Built-in Audio                      [alsa]
 │
 ├─ Sinks:
 │  *   58. Built-in Audio Analog Stereo        [vol: 0.45]
 │
 ├─ Sources:
 │  *   59. Built-in Audio Analog Stereo        [vol: 0.00]
 │
 ├─ Filters:
 │
 ├─ Streams:

Video
 ├─ Devices:
 │      53. Integrated Camera                   [v4l2]
 │
 ├─ Sinks:
 │
 ├─ Sources:
 │  *   61. Integrated Camera (V4L2)
 │
 ├─ Filters:
 │
 ├─ Streams:

Settings
 ├─ Default Configured Devices:
         1. Audio/Source  alsa_input.pci-0000_00_1f.3.analog-stereo'

# ------------------------------------------------------- default device parsing

check_eq "default sink is the starred Audio sink" \
  "58	Built-in Audio Analog Stereo" \
  "$(wp_default_node "$STATUS_FIXTURE" Sinks)"

# The whole point of scoping to the Audio graph: node 61 is starred too.
check_eq "default source ignores the Video graph camera" \
  "59	Built-in Audio Analog Stereo" \
  "$(wp_default_node "$STATUS_FIXTURE" Sources)"

check_eq "a usage banner yields no device" "" \
  "$(wp_default_node 'Usage:
  wpctl [OPTION…] COMMAND [COMMAND_OPTIONS] - WirePlumber Control CLI' Sinks)"

check_eq "empty status yields no device" "" \
  "$(wp_default_node "" Sinks)"

# No starred node under the requested block: nothing, not the first entry.
NO_DEFAULT='Audio
 ├─ Sinks:
 │      58. Built-in Audio Analog Stereo        [vol: 0.45]
 │
 ├─ Sources:
 │      59. Built-in Audio Analog Stereo        [vol: 0.00]'
check_eq "an unstarred block yields no device" "" \
  "$(wp_default_node "$NO_DEFAULT" Sinks)"

# The bracketed [vol: ...] tag must not end up in the displayed name.
check_eq "the trailing vol tag is stripped from the name" "58" \
  "$(wp_default_node "$STATUS_FIXTURE" Sinks | /usr/bin/cut -f1)"

# ------------------------------------------------------------------ volume

check_eq "0..1 float becomes a percentage" "45" "$(wp_vol_pct 'Volume: 0.45')"
check_eq "an explicit percentage passes through" "45" "$(wp_vol_pct 'Volume: 45%')"
check_eq "full scale is 100" "100" "$(wp_vol_pct 'Volume: 1.0')"
check_eq "silence is 0" "0" "$(wp_vol_pct 'Volume: 0.00')"
check_eq "mute does not disturb the percentage" "45" \
  "$(wp_vol_pct 'Volume: 0.45 [MUTED]')"

# Both of these carry digits. Parsing them would invent a volume reading out of
# a usage banner or an error message.
check_eq "a usage banner yields no volume" "" \
  "$(wp_vol_pct 'Usage:
  wpctl [OPTION…] COMMAND [COMMAND_OPTIONS] - WirePlumber Control CLI')"
check_eq "an error message yields no volume" "" \
  "$(wp_vol_pct 'Object 999 not found')"

check_true "MUTED is detected" wp_vol_muted 'Volume: 0.45 [MUTED]'
check_true "MUTED is detected case-insensitively" wp_vol_muted 'Volume: 0.45 [muted]'
if wp_vol_muted 'Volume: 0.45' 2>/dev/null; then
  fail "an unmuted sink is not reported as muted"
else
  ok "an unmuted sink is not reported as muted"
fi

finish