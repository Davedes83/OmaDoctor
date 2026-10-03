#!/bin/sh
# OmaDoctor system check.
#
# Emits: {"checks":[ ... ]}
#
# Read-only. Reads /etc/os-release, /proc, and asks systemd for failed units.
# Nothing is modified and no privileged command is used.
# bootstrap.sh is sourced FIRST so that running this section directly -- which
# is exactly what its own failure messages tell the user to do -- gets the
# same pinned PATH, umask and locale as a dispatcher-driven run. Without it,
# a shadow executable anywhere on the caller's PATH is resolved here.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/bootstrap.sh"
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

# Capture the requested output mode before any `set --` in this script
# overwrites the positional parameters.
MODE=${1:-}

CHECKS=""

# emit() is provided by common.sh (comma-separated accumulation; emit_json
# adds the enclosing brackets once at print time). Do not redefine it here.

# ------------------------------------------------------------------ OS / arch
os_name=$(read_file /etc/os-release | /usr/bin/sed -n 's/^PRETTY_NAME="\(.*\)"$/\1/p' | /usr/bin/head -n 1)
os_id=$(read_file /etc/os-release | /usr/bin/sed -n 's/^ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | /usr/bin/head -n 1)
os_ver=$(read_file /etc/os-release | /usr/bin/sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' | /usr/bin/head -n 1)

if [ -n "$os_name" ]; then
  # Omarchy's own /etc/os-release uses ID=omarchy; stock Arch uses ID=arch.
  # Both are expected here. Anything else is worth a gentle nudge.
  case "$os_id" in
    omarchy | arch | archarm | manjaro)
      emit "system.os" system ok 0 "Operating system" "$os_name" \
        "ID=$os_id VERSION_ID=${os_ver:-unknown}" ""
      ;;
    *)
      emit "system.os" system attention 1 "Operating system" "$os_name" \
        "ID=$os_id VERSION_ID=${os_ver:-unknown}" \
        "OmaDoctor targets Omarchy (Arch-based); this reports a different distribution, so some checks may not apply."
      ;;
  esac
else
  emit "system.os" system info 0 "Operating system" "unknown" \
    "/etc/os-release is unreadable" ""
fi

# ---------------------------------------------------------------- arch / kernel
arch=$(uname -m 2>/dev/null)
kernel=$(uname -r 2>/dev/null)
emit "system.arch" system ok 0 "Architecture" "${arch:-unknown}" "" ""
emit "system.kernel" system ok 0 "Kernel" "${kernel:-unknown}" \
  "release $(uname -r 2>/dev/null | /usr/bin/cut -d- -f1)" ""

# ---------------------------------------------------------------------- uptime
up=$(read_file /proc/uptime | /usr/bin/cut -d' ' -f1)
if [ -n "$up" ]; then
  days=$(( ${up%.*} / 86400 ))
  hours=$(( (${up%.*} % 86400) / 3600 ))
  mins=$(( (${up%.*} % 3600) / 60 ))
  emit "system.uptime" system info 0 "Uptime" "${days}d ${hours}h ${mins}m" \
    "up ${days} days ${hours} hours" ""
else
  emit "system.uptime" system info 0 "Uptime" "unknown" "/proc/uptime unreadable" ""
fi

# --------------------------------------------------------------- load average
load=$(read_file /proc/loadavg)
if [ -n "$load" ]; then
  l1=$(printf '%s' "$load" | /usr/bin/awk '{print $1}')
  l5=$(printf '%s' "$load" | /usr/bin/awk '{print $2}')
  cores=$(/usr/bin/nproc 2>/dev/null || printf '1')
  # Compare the 1-minute load to core count. /proc/loadavg is normalised by
  # core count on Linux, so load > cores means runnable work exceeds capacity.
  over=$(printf '%s %s' "$l1" "$cores" | /usr/bin/awk '{printf "%d", ($2>0 && $1/$2 > 1.0) ? 1 : 0}')
  if [ "$over" = "1" ]; then
    emit "system.load" system attention 1 "Load average" \
      "$l1 / $l5 / $(printf '%s' "$load" | /usr/bin/awk '{print $3}')" \
      "$cores CPU(s); 1-min load exceeds core count" \
      "Something is CPU-bound; OmaControl's per-process view can identify it."
  else
    emit "system.load" system ok 0 "Load average" \
      "$l1 / $l5 / $(printf '%s' "$load" | /usr/bin/awk '{print $3}')" \
      "$cores CPU(s)" ""
  fi
else
  emit "system.load" system info 0 "Load average" "unknown" "/proc/loadavg unreadable" ""
fi

# ------------------------------------------------------------------- memory
if have free; then
  mem=$(/usr/bin/free -b 2>/dev/null | /usr/bin/awk '/^Mem:/ {printf "%d %d", $2, $3}')
  set -- $mem
  total=${1:-0}
  used=${2:-0}
  if [ "$total" -gt 0 ]; then
    mpct=$(printf '%s %s' "$used" "$total" | /usr/bin/awk '{printf "%d", ($2>0 ? $1*100/$2 : 0)}')
    if [ "$mpct" -ge 95 ]; then
      emit "system.memory" system problem 3 "Memory" "${mpct}% used" \
        "$(printf '%s %s' "$used" "$total" | /usr/bin/awk '{printf "%.1f GiB of %.1f GiB", $1/1073741824, $2/1073741824}')" \
        "Memory is nearly exhausted; expect OOM kills and stalled apps."
    elif [ "$mpct" -ge 88 ]; then
      emit "system.memory" system attention 1 "Memory" "${mpct}% used" \
        "$(printf '%s %s' "$used" "$total" | /usr/bin/awk '{printf "%.1f GiB of %.1f GiB", $1/1073741824, $2/1073741824}')" \
        "Memory pressure building; check for a runaway process."
    else
      emit "system.memory" system ok 0 "Memory" "${mpct}% used" \
        "$(printf '%s %s' "$used" "$total" | /usr/bin/awk '{printf "%.1f GiB of %.1f GiB", $1/1073741824, $2/1073741824}')" ""
    fi
  else
    # free(1) answered but carried no Mem: line. Emitting nothing here would
    # make the check VANISH, and a check that is absent is indistinguishable
    # from a check that passed.
    emit "system.memory" system info 0 "Memory" "unknown" \
      "free(1) reported no memory totals" ""
  fi
else
  emit "system.memory" system info 0 "Memory" "unknown" "free(1) unavailable" ""
fi

# --------------------------------------------------- swap (OOM safety net)
if have free; then
  swap=$(/usr/bin/free -b 2>/dev/null | /usr/bin/awk '/^Swap:/ {printf "%d %d", $2, $3}')
  set -- $swap
  stotal=${1:-0}
  sused=${2:-0}
  if [ "$stotal" -gt 0 ]; then
    spct=$(printf '%s %s' "$sused" "$stotal" | /usr/bin/awk '{printf "%d", ($1>0 ? $2*100/$1 : 0)}')
    if [ "$sused" -gt 0 ]; then
      emit "system.swap" system attention 1 "Swap" "${spct}% used" \
        "swap in use" \
        "Swap activity usually means memory pressure. Fine occasionally; concerning under sustained load."
    else
      emit "system.swap" system ok 0 "Swap" "configured, unused" \
        "$(printf '%s' "$stotal" | /usr/bin/awk '{printf "%.1f GiB", $1/1073741824}')" ""
    fi
  else
    emit "system.swap" system info 0 "Swap" "not configured" \
      "no swap device" \
      "Without swap, memory exhaustion triggers an OOM kill instead of slowing down."
  fi
else
  # Same reasoning as system.memory above: one of the two free(1) guards
  # reporting "unknown" while the other disappeared would be inconsistent, and
  # a missing check reads as a passing one.
  emit "system.swap" system info 0 "Swap" "unknown" "free(1) unavailable" ""
fi

# ------------------------------------------------------- failed systemd units
if have systemctl; then
  failed=$(/usr/bin/systemctl list-units --state=failed --no-legend --plain --no-pager 2>/dev/null | /usr/bin/grep -c . || true)
  case "$failed" in '' | *[!0-9]*) failed=0 ;; esac
  if [ "$failed" -gt 0 ]; then
    names=$(/usr/bin/systemctl list-units --state=failed --no-legend --plain --no-pager 2>/dev/null \
            | /usr/bin/awk '{print $1}' | /usr/bin/head -n 4 | /usr/bin/tr '\n' ' ')
    emit "system.failed_units" system problem 3 "Failed services" "$failed failed" \
      "$names" \
      "Inspect with: systemctl --failed --no-pager"
  else
    emit "system.failed_units" system ok 0 "Failed services" "none" \
      "no failed systemd units" ""
  fi
else
  emit "system.failed_units" system info 0 "Failed services" "unknown" \
    "systemctl unavailable" ""
fi

# ---------------------------------------------- pending package updates (read-only)
#
# checkupdates SYNCS THE PACMAN DATABASE over the network before comparing, so
# it is neither local nor cheap: ~10s worst case on the dominant cost of a
# quick scan, and a repeated pacman-db sync every poll is exactly the pattern
# that makes `pacman -Sy` warn about partial upgrades. The quick scan is
# documented as local-only and runs on a timer, so this probe is reserved for
# full scans (doctor.sh exports OMADOCTOR_MODE). Everywhere else the check
# reports "not checked" rather than inventing a number.
if [ "${OMADOCTOR_MODE:-quick}" = "full" ]; then
  if have checkupdates; then
    cu=$(/usr/bin/timeout -k 2 10 checkupdates 2>/dev/null | /usr/bin/grep -c . || true)
    case "$cu" in '' | *[!0-9]*) cu=0 ;; esac
    if [ "$cu" -gt 0 ]; then
      emit "system.updates" system info 0 "Pending updates" "$cu packages" \
        "checkupdates reports $cu available" \
        "Review with: omarchy update"
    else
      emit "system.updates" system ok 0 "Pending updates" "none" "system is up to date" ""
    fi
  else
    emit "system.updates" system info 0 "Pending updates" "unknown" \
      "checkupdates not installed" ""
  fi
else
  emit "system.updates" system info 0 "Pending updates" "not checked" \
    "checking requires a network sync, so it runs on a full diagnosis only" \
    "Open the panel, or run: sh backend/doctor.sh full"
fi

emit_json system "$MODE"
