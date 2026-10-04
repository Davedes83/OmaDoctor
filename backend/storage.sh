#!/bin/sh
# OmaDoctor storage check.
#
# Emits: {"section":"storage","checks":[ ... ]}
#   with --checks-only: prints just the JSON array (used by doctor.sh).
#
# Read-only. Uses df -P so each filesystem is guaranteed single-line
# (POSIX format), which keeps parsing unambiguous.
# bootstrap.sh is sourced FIRST so that running this section directly -- which
# is exactly what its own failure messages tell the user to do -- gets the
# same pinned PATH, umask and locale as a dispatcher-driven run. Without it,
# a shadow executable anywhere on the caller's PATH is resolved here.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/bootstrap.sh"
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
# Read the mount option rather than attempting a write. `touch /` mutates the
# mtime and atime of / when it succeeds, which contradicts the read-only claim
# every file header in this directory makes, and on a hardened system it fails
# for the wrong reason (an ordinary user cannot write / for many reasons that
# have nothing to do with the root mount being writable).
_root_opts=$(/usr/bin/findmnt -no OPTIONS / 2>/dev/null)
# Accept only a single comma-separated option token. Real output looks like
# "rw,noatime,compress=zstd:3,ssd,space_cache=v2,subvol=/@" -- digits, colons,
# slashes and an at-sign are all normal, so the guard has to be a positive
# whitelist rather than a "contains a non-letter" test, which rejected every
# real value and reported the root filesystem as unknown.
#
# A writable root is reported as ok, never attention. It is the normal state of a
# desktop -- the kernel writes /var, /run, /tmp and the logs -- so flagging it
# meant every healthy machine finished a scan on ATTENTION, which is the one
# word a reader is meant to act on. There is no desktop configuration in which
# "writable" is actionable, so there is nothing to suggest.
_root_flat=$(printf '%s' "$_root_opts" | /usr/bin/tr -d '\n\r')
case "$_root_flat" in
  '')
    emit "storage.root_writable" storage info 0 "Root filesystem" "unknown" \
      "findmnt did not report options for /" ""
    ;;
  *[!A-Za-z0-9,=_:./@+-]*)
    emit "storage.root_writable" storage info 0 "Root filesystem" "unknown" \
      "findmnt reported an unrecognised option string" ""
    ;;
  # The ro/rw flag is the first field of the vfs option list, so match that
  # field exactly. A substring glob for *ro* across the whole option string also
  # matched any option merely containing those two letters -- errors=remount-ro
  # being the realistic case -- and called the root read-only.
  *)
    case "${_root_flat%%,*}" in
      ro)
        emit "storage.root_writable" storage ok 0 "Root filesystem" "read-only" \
          "/ is mounted read-only" ""
        ;;
      rw)
        emit "storage.root_writable" storage ok 0 "Root filesystem" "writable" \
          "/ is mounted rw, which is normal for a desktop root filesystem" ""
        ;;
      *)
        emit "storage.root_writable" storage info 0 "Root filesystem" "unknown" \
          "findmnt reported no ro/rw flag for /" ""
        ;;
    esac
    ;;
esac

# ---------------------------------------------------------------- largest dirs
# Bounded: depth-1 only under $HOME, behind a hard timeout, so this cannot
# become a long-running full-filesystem walk inside the long-lived shell.
#
# `du -0` is load-bearing. Two bugs came from parsing its default output:
#
#   * `awk 'NR>1'` assumed the $HOME total is the FIRST line. It is not --
#     GNU du emits it last -- so this silently dropped whichever real directory
#     happened to be walked first, and on a small $HOME that was the largest
#     one. The total is now matched by path instead of by line number.
#   * `$1" "$2` split on whitespace, so a directory named "my dir" was reported
#     as the non-existent path "~/my" with its size attached to it. `du -0`
#     emits NUL-terminated "<size>TAB<path>" records, and splitting at the
#     FIRST tab leaves spaces (and anything else) inside the path intact.
#
# The count is derived from the same records that are displayed, so the two can
# no longer disagree.
if have du; then
  raw=$(/usr/bin/timeout -k 2 8 /usr/bin/du -x -m -d 1 -0 "$_home" 2>/dev/null \
        | /usr/bin/awk -v RS='\0' -v home="$_home" '
            NF >= 1 {
              i = index($0, "\t")
              if (i == 0) next
              sz = substr($0, 1, i - 1)
              p = substr($0, i + 1)
              if (p == home) next
              printf "%d\t%s\n", sz + 0, p
            }
          ' | /usr/bin/sort -rn | /usr/bin/head -n 3)
  if [ -n "$raw" ]; then
    # Build the summary with a single awk pass rather than a `while read`
    # pipeline: a pipeline body runs in a subshell, so any variable it set
    # would be discarded before the emit below.
    pretty=$(printf '%s\n' "$raw" | /usr/bin/awk -v home="$_home" '
      NF >= 2 {
        sz = $1
        p = $0
        sub(/^[^\t]*\t/, "", p)
        if (index(p, home) == 1) p = "~" substr(p, length(home) + 1)
        printf "%s%s %sM", (n++ ? ", " : ""), p, sz
      }
      END { if (!n) exit 1 }
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
