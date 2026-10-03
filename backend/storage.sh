#!/bin/sh
# OmaDoctor storage check.
#
# Emits: {"section":"storage","checks":[ ... ]}
#   with --checks-only: prints just the JSON array (used by doctor.sh).
#
# Read-only. Uses df -P so each filesystem is guaranteed single-line
# (POSIX format), which keeps parsing unambiguous.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/common.sh"

MODE=${1:-}
CHECKS=""

# check_fs MOUNT LABEL
#
# df -P columns: Filesystem 1024-blocks Used Available Capacity Mounted-on
check_fs() {
  _mount=$1
  _label=$2
  _line=$(/usr/bin/df -P "$_mount" 2>/dev/null | /usr/bin/sed -n '2p')
  if [ -z "$_line" ]; then
    emit "storage.fs.$_label" storage info 0 "Filesystem: $_label" "unavailable" \
      "df could not read $_mount" ""
    return 0
  fi
  # shellcheck disable=SC2086
  set -- $_line
  _src=${1-}
  _blocks=${2-}
  _used=${3-}
  _avail=${4-}
  _cap=${5-}

  _pct=$(fs_usage_percent "$_mount")
  severity_for_pct "$_pct"

  # df -P reports 1024-blocks, so the starting unit is KiB, not bytes.
  # Dividing three times turns KiB -> MiB -> GiB -> TiB, and the loop breaks
  # before dividing once the value is already small enough, so the unit index
  # equals the number of divisions performed.
  _human=$(printf '%s %s' "${_avail:-0}" "${_blocks:-0}" | /usr/bin/awk '{
    b = $1; tot = $2
    for (i = 1; i <= 3; i++) {
      if (b < 1024) break
      b /= 1024; tot /= 1024
    }
    unit = (i == 1) ? "KiB" : (i == 2) ? "MiB" : (i == 3) ? "GiB" : "TiB"
    printf "%.1f %s free of %.1f %s", b, unit, tot, unit
  }')

  emit "storage.fs.$_label" storage "$STATUS" "$SEVERITY" "Filesystem: $_label" \
    "${_pct:-?}% used" "$_src, ${_human:-unknown}" "$SUGGESTION"
}

# ------------------------------------------------------------------ filesystems
check_fs "/" "root"

_home=$HOME
case "$_home" in
  /) ;;
  "") ;;
  *) check_fs "$_home" "home" ;;
esac

# ---------------------------------------------------------------------- inodes
# Distinguish "df -i could not read this mount" from "this filesystem does not
# report inode usage". btrfs and zfs answer with "-" for IUse%, which used to be
# flattened into the same "df -i unavailable" message as a genuine failure --
# a misleading reason for a check that in fact had nothing to report.
inode_pct=""
inode_reason=""
for m in / "$_home"; do
  [ -n "$m" ] || continue
  [ "$m" = "/" ] || [ "$m" = "$_home" ] || continue
  line=$(/usr/bin/df -P -i "$m" 2>/dev/null | /usr/bin/sed -n '2p')
  if [ -z "$line" ]; then
    inode_reason="df -i could not read $m"
    continue
  fi
  # shellcheck disable=SC2086
  set -- $line
  cap=${5-}
  case "$cap" in
    '' | *[!0-9%]*) inode_reason="$m does not report inode usage via df -i" ;;
    *) inode_pct=${cap%\%} ;;
  esac
  break
done

if [ -n "$inode_pct" ]; then
  # Inodes run out before bytes on many small-file workloads (package caches,
  # mail spools, node_modules), and the failure mode looks like "disk is full"
  # with free space showing. Worth its own check.
  severity_for_pct "$inode_pct"
  emit "storage.inodes" storage "$STATUS" "$SEVERITY" "Inodes" \
    "${inode_pct}% used" "small-file capacity" "$SUGGESTION"
elif [ -n "$inode_reason" ]; then
  # Not a fault: btrfs and zfs do not track a fixed inode count, so there is no
  # percentage to report and nothing to act on.
  emit "storage.inodes" storage info 0 "Inodes" "not reported" \
    "$inode_reason" ""
else
  emit "storage.inodes" storage info 0 "Inodes" "unknown" \
    "df -i unavailable" ""
fi

# ---------------------------------------------------------------- read-only root
if [ -w / ] || touch / 2>/dev/null; then
  emit "storage.root_writable" storage problem 3 "Root filesystem" "writable" \
    "/ accepts writes as $(id -un 2>/dev/null)" \
    "Unexpected for a hardened system; confirm this is intentional."
else
  emit "storage.root_writable" storage ok 0 "Root filesystem" "read-only" \
    "/ correctly refuses writes" ""
fi

# ---------------------------------------------------------------- largest dirs
# Bounded: depth-1 only under $HOME, behind a hard timeout, so this cannot
# become a long-running full-filesystem walk inside the long-lived shell.
if have du; then
  raw=$(/usr/bin/timeout -k 2 8 /usr/bin/du -x -m -d 1 "$_home" 2>/dev/null \
        | /usr/bin/awk 'NR>1 {print $1" "$2}' | /usr/bin/sort -rn | /usr/bin/head -n 3)
  if [ -n "$raw" ]; then
    # Build the summary with a single awk pass rather than a `while read`
    # pipeline: a pipeline body runs in a subshell, so any variable it set
    # would be discarded before the emit below.
    pretty=$(printf '%s\n' "$raw" | /usr/bin/awk -v home="$_home" '
      NF >= 2 {
        p = $2
        if (p == home) next
        if (index(p, home) == 1) p = "~" substr(p, length(home) + 1)
        printf "%s%s %sM", (n++ ? ", " : ""), p, $1
      }
      END { if (n) printf ""; else exit 1 }
    ' 2>/dev/null)
    if [ -n "$pretty" ]; then
      count=$(printf '%s\n' "$raw" | /usr/bin/awk 'NF>=2' | /usr/bin/wc -l | /usr/bin/tr -d ' ')
      emit "storage.big_dirs" storage info 0 "Largest in ~" "$count entries" \
        "$pretty" \
        "Review these when reclaiming space."
    fi
  fi
fi

emit_json storage "$MODE"
