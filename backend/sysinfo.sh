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
if [ -n "$arch" ]; then
  emit "system.arch" system ok 0 "Architecture" "$arch" "" ""
else
  # A failed uname is an unread fact, not a healthy one.
  emit "system.arch" system info 0 "Architecture" "unknown" \
    "uname -m did not report an architecture" ""
fi
if [ -n "$kernel" ]; then
  emit "system.kernel" system ok 0 "Kernel" "$kernel" \
    "release $(printf '%s' "$kernel" | /usr/bin/cut -d- -f1)" ""
else
  emit "system.kernel" system info 0 "Kernel" "unknown" \
    "uname -r did not report a kernel release" ""
fi

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
    spct=$(printf '%s %s' "$sused" "$stotal" | /usr/bin/awk '{printf "%d", ($2>0 ? $1*100/$2 : 0)}')
    # Swap in use is not, by itself, a symptom. With zram (Omarchy's default)
    # the kernel moves idle pages into compressed RAM long before memory is
    # short, so "any swap used" warned on every healthy machine (issue #3).
    # Warn on what actually hurts: total swap mostly used, or the kernel
    # reporting that tasks stall on memory (PSI "some" avg60, a percentage of
    # wall time). PSI is only consulted here, while swap is in use.
    if [ "$sused" -gt 0 ]; then
      psi=$(/usr/bin/awk '/^some / { for (i = 2; i <= NF; i++)
              if ($i ~ /^avg60=[0-9]+(\.[0-9]+)?$/) { sub(/^avg60=/, "", $i); print $i } }' \
              /proc/pressure/memory 2>/dev/null)
      psi_int=${psi%%.*}
      case "$psi_int" in '' | *[!0-9]*) psi=""; psi_int="" ;; esac
      # /proc/swaps also gives the fullest zram device. Omarchy pairs zram with
      # an equally sized hibernation swapfile at a lower priority, so a
      # completely full zram is only ~50% of total swap and the 80% rule alone
      # would not see it.
      swapinfo=$(/usr/bin/awk 'NR > 1 && $3 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
                if ($1 ~ /^\/dev\/zram/) { z = 1; if ($3 > 0 && $4 * 100 / $3 > zmax) zmax = int($4 * 100 / $3) }
                else d = 1 }
              END { if (z && d) k = "zram and disk swap"; else if (z) k = "zram swap";
                    else if (d) k = "disk swap"; else k = "swap"
                    printf "%d %s", zmax + 0, k }' /proc/swaps 2>/dev/null)
      zpct=${swapinfo%% *}
      devs=${swapinfo#* }
      case "$zpct" in '' | *[!0-9]*) zpct=0 ;; esac
      [ -n "$devs" ] && [ "$devs" != "$swapinfo" ] || devs="swap"
      if [ -n "$psi" ]; then
        pressure="memory pressure ${psi}% (avg60)"
        [ "$psi_int" -lt 10 ] && pressure="$pressure, below the 10% warning level"
      else
        pressure="memory pressure unavailable"
      fi
      if [ "$spct" -ge 80 ]; then
        emit "system.swap" system attention 1 "Swap" "${spct}% used" \
          "$devs, ${spct}% of total used; $pressure" \
          "Little swap capacity remains. If memory keeps growing, the kernel will start killing processes."
      elif [ "$zpct" -ge 80 ]; then
        emit "system.swap" system attention 1 "Swap" "${spct}% used" \
          "zram ${zpct}% full; further swapping goes to slower swap or fails; $pressure" \
          "Compressed RAM swap is nearly full. If memory keeps growing, close memory-heavy apps."
      elif [ -n "$psi_int" ] && [ "$psi_int" -ge 10 ]; then
        emit "system.swap" system attention 1 "Swap" "${spct}% used" \
          "$devs in use; $pressure" \
          "Tasks are stalling on memory. If this persists, close memory-heavy apps or add RAM."
      else
        emit "system.swap" system ok 0 "Swap" "${spct}% used" \
          "$devs in use; $pressure" ""
      fi
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
  # Capture the output AND the exit status separately. The old pipeline made
  # the shell see `grep -c`'s status, so a systemctl that failed to run (no
  # system bus, a wedged manager) yielded an empty list that grep counted as 0
  # -- and the section reported "no failed units", a clean bill of health from
  # a probe that never answered.
  _units=$(/usr/bin/systemctl list-units --state=failed --no-legend --plain --no-pager 2>/dev/null)
  _units_rc=$?
  if [ "$_units_rc" -ne 0 ]; then
    emit "system.failed_units" system info 0 "Failed services" "unknown" \
      "systemctl list-units failed (exit $_units_rc)" ""
  else
    failed=$(printf '%s\n' "$_units" | /usr/bin/grep -c . || true)
    case "$failed" in '' | *[!0-9]*) failed=0 ;; esac
    if [ "$failed" -gt 0 ]; then
      names=$(printf '%s\n' "$_units" \
              | /usr/bin/awk '{print $1}' | /usr/bin/head -n 4 | /usr/bin/tr '\n' ' ')
      emit "system.failed_units" system problem 3 "Failed services" "$failed failed" \
        "$names" \
        "Inspect with: systemctl --failed --no-pager"
    else
      emit "system.failed_units" system ok 0 "Failed services" "none" \
        "no failed systemd units" ""
    fi
  fi
else
  emit "system.failed_units" system info 0 "Failed services" "unknown" \
    "systemctl unavailable" ""
fi

# ----------------------------------------------------- user-scope failed units
if have systemctl; then
  # The system manager is only half the picture. A failed user service
  # (wireplumber, portal, pipewire) breaks the session just as surely, and
  # systemctl --user is a separate manager with its own failure list.
  _user_units=$(/usr/bin/systemctl --user list-units --state=failed --no-legend --plain --no-pager 2>/dev/null)
  _user_rc=$?
  if [ "$_user_rc" -ne 0 ]; then
    emit "system.user_failed_units" system info 0 "User services" "unknown" \
      "systemctl --user list-units failed (exit $_user_rc)" ""
  else
    user_failed=$(printf '%s\n' "$_user_units" | /usr/bin/grep -c . || true)
    case "$user_failed" in '' | *[!0-9]*) user_failed=0 ;; esac
    if [ "$user_failed" -gt 0 ]; then
      user_names=$(printf '%s\n' "$_user_units" \
              | /usr/bin/awk '{print $1}' | /usr/bin/head -n 4 | /usr/bin/tr '\n' ' ')
      emit "system.user_failed_units" system attention 1 "User services" "$user_failed failed" \
        "$user_names" \
        "A user service has failed. Inspect with: systemctl --user --failed"
    else
      emit "system.user_failed_units" system ok 0 "User services" "none" \
        "no failed user systemd units" ""
    fi
  fi
else
  emit "system.user_failed_units" system info 0 "User services" "unknown" \
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
    # checkupdates encodes its answer in the EXIT STATUS: 0 = updates present,
    # 2 = up to date, anything else (typically 1) = it failed. The old pipeline
    # read `grep -c`'s status instead, so a failed sync was counted as "0 lines"
    # and reported as "none -- system is up to date": a false clean bill of
    # health from a network probe that never completed.
    cu_out=$(/usr/bin/timeout -k 2 10 checkupdates 2>/dev/null)
    cu_rc=$?
    case "$cu_rc" in
      0)
        cu=$(printf '%s\n' "$cu_out" | /usr/bin/grep -c . || true)
        case "$cu" in '' | *[!0-9]*) cu=0 ;; esac
        if [ "$cu" -gt 0 ]; then
          emit "system.updates" system info 0 "Pending updates" "$cu packages" \
            "checkupdates reports $cu available" \
            "Review with: omarchy update"
        else
          emit "system.updates" system info 0 "Pending updates" "unknown" \
            "checkupdates exited 0 but listed no packages" ""
        fi
        ;;
      2)
        emit "system.updates" system ok 0 "Pending updates" "none" \
          "system is up to date" ""
        ;;
      124 | 137)
        emit "system.updates" system info 0 "Pending updates" "unknown" \
          "checkupdates timed out while syncing the package database" ""
        ;;
      *)
        emit "system.updates" system info 0 "Pending updates" "unknown" \
          "checkupdates failed (exit $cu_rc)" \
          "Run 'checkupdates' directly to see the error"
        ;;
    esac
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
