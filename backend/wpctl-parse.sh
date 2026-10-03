#!/bin/sh
# OmaDoctor wpctl output parsers.
#
# Pure functions over wpctl output text. No bootstrap, no PATH assumptions, no
# external commands beyond /usr/bin/awk -- so the awkward cases can be pinned in
# tests/wpctl-tests.sh with captured fixtures instead of only being observable
# on a live machine.
#
# These exist because wpctl has NO `get-default-sink` / `get-default-source`
# subcommand. Calling one prints the usage banner, and the first line of that
# banner is "Usage:" -- which a naive parser reads as the name of a device. The
# default device therefore has to be read from `wpctl status`, where it is the
# node marked with `*`.
#
# Sourced by backend/audio.sh. Not a section: doctor.sh never runs it.

# wp_default_node STATUS_TEXT KIND
#
# Print "<id><TAB><description>" for the default node of KIND ("Sinks" or
# "Sources"), or nothing when there is none.
#
# Scoped to the Audio graph on purpose. `wpctl status` renders one Sinks/Sources
# block per graph, so an unscoped scan happily returns the Video graph's camera
# source -- a starred line that is not an audio device at all.
wp_default_node() {
  printf '%s\n' "$1" | /usr/bin/awk -v want="$2" '
    # Locale-proof cleaning.
    #
    # wpctl draws its tree with box-drawing characters, so a node line looks
    # like "\u2502  *  58. Name [vol: 0.45]" -- decoration, then the star.
    # That decoration is removed by MATCHING a leading run of non-ASCII
    # characters, not by deleting bytes.
    #
    # The earlier implementation deleted every byte outside 0x20-0x7E. Under
    # the pinned LC_ALL=C a UTF-8 character is several such bytes, so that
    # silently destroyed the non-ASCII part of any device name:
    # "Beyerdynamic DT 770 Pro (80 \u03a9)" was reported as
    # "... (80 )" at status ok, and any CJK or emoji name was mangled beyond
    # recognition while still being presented as a healthy measurement.
    #
    # Expressing the strip as octal BYTE ranges instead (\342[\224-\227]...)
    # is worse: those are not valid range endpoints in a UTF-8 locale, where awk
    # reads them as code points, so the whole parser failed to compile. A
    # bracket that means "not printable ASCII" is valid and equivalent in every
    # locale -- bytes in C, code points otherwise.
    function clean(s) {
      gsub(/[\001-\037\177]/, "", s)
      # Decoration and indent are interleaved: " <box><box>  *  58. Name".
      # One repeated class over "space, tab, or non-ASCII" consumes the lot in
      # any order. "*" is printable ASCII, so the star that marks the default
      # node always survives.
      sub(/^([ \t]|[^\040-\177])+/, "", s)
      sub(/[ \t]+$/, "", s)
      return s
    }
    BEGIN { inaudio = 0; inblock = 0 }
    {
      # A top-level heading (no tree character, starts with a letter) that is
      # not "Audio" ends the Audio graph we care about.
      if ($0 !~ /[^\040-\177]/ && $0 ~ /^[A-Za-z]/ && clean($0) != "Audio" && inaudio) {
        inaudio = 0
      }
      if (!inaudio) {
        if (clean($0) == "Audio") inaudio = 1
        next
      }
      c = clean($0)
      # Block headers, e.g. "Sinks:". Anything else in these lists is a node.
      if (c ~ /^(Devices|Sinks|Sources|Filters|Streams|Clients):$/) {
        inblock = (c == want ":")
        next
      }
      if (!inblock) next
      # Node lines are "* 58. Some Device [vol: 0.45]". Only the starred one is
      # the default, so an unstarred node never terminates the search.
      if (c ~ /^\*/) {
        if (match(c, /\* *[0-9]+\./)) {
          idpart = substr(c, RSTART, RLENGTH)
          gsub(/[^0-9]/, "", idpart)
          desc = substr(c, RSTART + RLENGTH)
          sub(/\[.*$/, "", desc)          # drop the trailing [vol: ...] tag
          gsub(/^[ \t]+|[ \t]+$/, "", desc)
          printf "%s\t%s\n", idpart, desc
        }
        exit
      }
    }
  '
}

# wp_vol_pct GETVOLUME_TEXT -> integer percentage, or nothing.
#
# wpctl prints a 0..1 float ("Volume: 0.45"), but its own set-volume takes a
# percentage, so both forms are normalised to a percentage here. Anything that
# is not a Volume line yields nothing: the usage banner and "Object not found"
# both carry digits, and parsing those would invent a reading.
wp_vol_pct() {
  printf '%s\n' "$1" | /usr/bin/awk '
    $0 !~ /[Vv]olume/ { next }
    match($0, /[0-9]+(\.[0-9]+)?/) {
      v = substr($0, RSTART, RLENGTH) + 0
      if (v <= 1.0) v = v * 100
      printf "%d", (v + 0.5)
    }
  '
}

# wp_vol_muted GETVOLUME_TEXT -> true when the sink is muted.
wp_vol_muted() {
  case "$1" in
    *[Mm][Uu][Tt][Ee][Dd]*) return 0 ;;
  esac
  return 1
}