#!/bin/sh
# OmaDoctor backend test suite.
#
# Scope: the JSON contract the UI depends on, plus the quick/full split.
# Parser, roll-up and redaction behaviour live in tests/model-tests.js.
#
# Each script is executed exactly ONCE and its output cached in a variable;
# every assertion then reads the cache. Re-running the probes per assertion
# made the suite both slow (~25s of live system calls) and non-deterministic,
# since two runs a second apart can legitimately disagree.
. "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

# --------------------------------------------------------------- capture once

run() {
  # run SCRIPT ARG...  -> stdout only, stdin closed, hard deadline
  #
  # 150s, not 90: doctor.sh runs its sections SEQUENTIALLY behind per-section
  # deadlines that now sum to ~97s worst case for a full scan. A harness
  # deadline near the product's own budget will kill a slow-but-legitimate run
  # mid-document and report it as a malformed payload, which looks exactly like
  # a real failure and is not one.
  /usr/bin/timeout -k 2 150 /bin/sh "$@" 2>/dev/null </dev/null
}

SYSINFO=$(run "$BACKEND_DIR/sysinfo.sh")
AUDIO=$(run "$BACKEND_DIR/audio.sh")
STORAGE=$(run "$BACKEND_DIR/storage.sh")
SERVICES=$(run "$BACKEND_DIR/services.sh")
HYPRLAND=$(run "$BACKEND_DIR/hyprland.sh")
DISPLAY=$(run "$BACKEND_DIR/display.sh")
SYSINFO_BARE=$(run "$BACKEND_DIR/sysinfo.sh" --checks-only)
QUICK=$(run "$BACKEND_DIR/doctor.sh" quick)
FULL=$(run "$BACKEND_DIR/doctor.sh" full)

# ------------------------------------------------------------ JSON validity

for pair in "sysinfo:$SYSINFO" "audio:$AUDIO" "storage:$STORAGE" \
            "services:$SERVICES" "hyprland:$HYPRLAND" "display:$DISPLAY"; do
  name=${pair%%:*}
  doc=${pair#*:}
  if printf '%s' "$doc" | jq -e . >/dev/null 2>&1; then
    ok "$name emits valid JSON"
  else
    fail "$name emits valid JSON" "$(printf '%s' "$doc" | head -c 200)"
  fi
done

# Every check must carry the full field set the UI reads.
REQUIRED='.checks | length > 0 and all(.[]; has("id") and has("category") and has("title") and has("status") and has("severity") and has("value") and has("detail") and has("suggestion"))'
missing=""
for pair in "sysinfo:$SYSINFO" "audio:$AUDIO" "storage:$STORAGE" \
            "services:$SERVICES" "hyprland:$HYPRLAND" "display:$DISPLAY"; do
  name=${pair%%:*}
  doc=${pair#*:}
  if ! printf '%s' "$doc" | jq -e "$REQUIRED" >/dev/null 2>&1; then
    missing="$missing $name"
  fi
done
check_eq "every check carries the required fields" "" "$missing"

# The optional fields are additive: when present they must have a valid shape,
# and when absent Model.js treats them as [] / null. Nothing may emit a
# half-formed descriptor, because the report would render it verbatim.
#   details -> absent, or an array in which every entry is a string
#   repair  -> absent, null, or an object with a known tier and a label
#
# `(.details // [])` and `(.repair // null)` matter: referencing an ABSENT key
# yields null in jq, and `null | type == "array"` is false, so testing the raw
# key would fail every check that legitimately omits it. Coercing first makes
# absent and empty mean the same thing -- which is exactly the contract.
OPTIONAL='all(.checks[];
  (((.details // []) | type == "array") and all((.details // [])[]; type == "string"))
  and
  (((.repair // null) == null)
    or ((.repair | type == "object") and (.repair | has("tier")) and (.repair | has("label"))
        and ((.repair.tier) == "safe" or (.repair.tier) == "caution" or (.repair.tier) == "manual")))
)'
bad_optional=""
for pair in "sysinfo:$SYSINFO" "audio:$AUDIO" "storage:$STORAGE" \
            "services:$SERVICES" "hyprland:$HYPRLAND" "display:$DISPLAY"; do
  name=${pair%%:*}
  doc=${pair#*:}
  if ! printf '%s' "$doc" | jq -e "$OPTIONAL" >/dev/null 2>&1; then
    bad_optional="$bad_optional $name"
  fi
done
check_eq "optional details/repair fields are well-formed" "" "$bad_optional"

# --------------------------------------------------------------- schema rules

# severity must be a JSON number, not a string -- Model.js compares numerically.
check_eq "severity is a JSON number" "number" \
  "$(printf '%s' "$SYSINFO" | jq -r '.checks[0].severity | type')"

# status must always be one of the four known states.
bad=$(printf '%s' "$SYSINFO" "$AUDIO" "$STORAGE" "$SERVICES" "$HYPRLAND" "$DISPLAY" \
  | jq -s -r '[.[] | .checks[].status | select(. != "ok" and . != "info" and . != "attention" and . != "problem")] | length')
check_eq "status values are within the known set" "0" "$bad"

# ids must be unique, otherwise the UI cannot address a check by id.
dupes=$(printf '%s' "$SYSINFO" "$AUDIO" "$STORAGE" "$SERVICES" "$HYPRLAND" "$DISPLAY" \
  | jq -s -r '[.[] | .checks[].id] | (length - (unique | length))')
check_eq "check ids are unique across sections" "0" "$dupes"

# --checks-only must emit BARE objects (no enclosing brackets): doctor.sh
# concatenates section output and wraps the result in exactly one array.
case "$(printf '%s' "$SYSINFO_BARE" | cut -c1)" in
  '[') fail "--checks-only omits the array brackets" "output starts with '['" ;;
  '{') ok "--checks-only omits the array brackets" ;;
  *)   fail "--checks-only omits the array brackets" "unexpected output" ;;
esac

# Every element of the merged array must be a CHECK, never a whole
# {section,checks} document spliced in as an element.
#
# The bug this guards: a section that parses `--checks-only` away instead of
# passing it through to emit_json emits the full document form, so doctor.sh
# concatenates that document into the array. The result is still valid JSON and
# still parses -- the checks simply have no `id`, which breaks every consumer
# downstream (findingRows, findCheck, the report) with no error anywhere. A
# nested document here is the fingerprint, so assert both that nothing lacks an
# id and that nothing looks like a wrapped section.
nested=$(printf '%s' "$QUICK" "$FULL" \
  | jq -s -r '[.[] | .checks[] | select(((.id // "") == "") or has("section"))] | length')
check_eq "no section document is spliced into the merged array" "0" "$nested"

# ------------------------------------------------------------- doctor merging

# The bug this guards: two sections merged into "[a],[b]" is invalid JSON.
if printf '%s' "$QUICK" | jq -e '.checks | type == "array"' >/dev/null 2>&1; then
  ok "doctor.sh quick emits a single merged array"
else
  fail "doctor.sh quick emits a single merged array" "$(printf '%s' "$QUICK" | head -c 200)"
fi

# quick must exclude network: it is the expensive section and runs on a timer.
case "$(printf '%s' "$QUICK" | jq -r '.sections')" in
  *network*) fail "quick scan omits network" "sections=$(printf '%s' "$QUICK" | jq -r '.sections')" ;;
  *)         ok "quick scan omits network" ;;
esac

# full must include it.
case "$(printf '%s' "$FULL" | jq -r '.sections')" in
  *network*) ok "full scan includes network" ;;
  *)         fail "full scan includes network" "sections=$(printf '%s' "$FULL" | jq -r '.sections')" ;;
esac

# The local sections are cheap and must run in the TIMED scan too. If one of
# these ever drops out of quick, it silently stops being checked until a user
# happens to open the panel -- which is precisely when they least expect to
# wait.
for want in services hyprland display; do
  case "$(printf '%s' "$QUICK" | jq -r '.sections')" in
    *"$want"*) ok "quick scan includes $want" ;;
    *)         fail "quick scan includes $want" "sections=$(printf '%s' "$QUICK" | jq -r '.sections')" ;;
  esac
done

# full must be a strict superset of quick in check count.
q_n=$(printf '%s' "$QUICK" | jq -r '.checks | length')
f_n=$(printf '%s' "$FULL" | jq -r '.checks | length')
if [ "$f_n" -gt "$q_n" ]; then
  ok "full scan yields more checks than quick ($f_n > $q_n)"
else
  fail "full scan yields more checks than quick" "quick=$q_n full=$f_n"
fi

# A timestamp lets the UI detect a stale scan.
ts=$(printf '%s' "$QUICK" | jq -r '.ts')
if [ "$ts" -gt 1600000000 ] 2>/dev/null; then
  ok "doctor.sh stamps a plausible epoch timestamp"
else
  fail "doctor.sh stamps a plausible epoch timestamp" "ts=$ts"
fi

# A section that cannot run must surface an explicit problem check rather than
# silently disappearing -- an absent check must never read as a healthy one.
failed=$(printf '%s' "$QUICK" "$FULL" \
  | jq -s -r '[.[] | .checks[] | select(.id | test("\\.section$"))] | length')
check_eq "no section-failure placeholders on a healthy run" "0" "$failed"

# Drive the real failure paths by pointing a copy of the dispatcher at sections
# that cannot run. This is the check that keeps "healthy" trustworthy.
BROKEN=$(mktemp -d)
# common.sh is required: doctor.sh sources it for check() and
# json_fragment_ok(), not just bootstrap.sh.
cp "$BACKEND_DIR/doctor.sh" "$BACKEND_DIR/bootstrap.sh" "$BACKEND_DIR/common.sh" "$BROKEN/" 2>/dev/null
printf '#!/bin/sh\nexit 3\n' > "$BROKEN/sysinfo.sh"
: > "$BROKEN/audio.sh"
: > "$BROKEN/storage.sh"
: > "$BROKEN/services.sh"
: > "$BROKEN/hyprland.sh"
: > "$BROKEN/display.sh"
broken=$(/usr/bin/timeout -k 2 60 /bin/sh "$BROKEN/doctor.sh" quick 2>/dev/null </dev/null)
rm -rf "$BROKEN"
if printf '%s' "$broken" \
   | jq -e '[.checks[] | select(.id == "sysinfo.section" and .status == "problem")] | length == 1' >/dev/null 2>&1; then
  ok "a failing section is reported as a problem check"
else
  fail "a failing section is reported as a problem check" "$(printf '%s' "$broken" | head -c 200)"
fi

# A section that produces no output at all must also be flagged.
SILENT=$(mktemp -d)
cp "$BACKEND_DIR/doctor.sh" "$BACKEND_DIR/bootstrap.sh" "$BACKEND_DIR/common.sh" "$SILENT/" 2>/dev/null
printf '#!/bin/sh\nprintf ""\n' > "$SILENT/sysinfo.sh"
: > "$SILENT/audio.sh"
: > "$SILENT/storage.sh"
: > "$SILENT/services.sh"
: > "$SILENT/hyprland.sh"
: > "$SILENT/display.sh"
silent=$(/usr/bin/timeout -k 2 60 /bin/sh "$SILENT/doctor.sh" quick 2>/dev/null </dev/null)
rm -rf "$SILENT"
if printf '%s' "$silent" \
   | jq -e '[.checks[] | select(.id == "sysinfo.section" and .status == "problem")] | length == 1' >/dev/null 2>&1; then
  ok "a silent section is reported as a problem check"
else
  fail "a silent section is reported as a problem check" "$(printf '%s' "$silent" | head -c 200)"
fi

# --------------------------------------------------- no fabricated readings
#
# wpctl answers an unknown subcommand with a usage banner. An earlier version of
# the audio section called `wpctl get-default-sink`, which does not exist, and
# then displayed the banner's first line -- the literal string "Usage:" -- as a
# healthy default output device. A check that read nothing looked like a check
# that passed, which is the one outcome this project exists to prevent.
#
# So: whatever this machine looks like, no check value may ever be text scraped
# out of a command's usage/help output.
fabricated=$(printf '%s' "$SYSINFO" "$AUDIO" "$STORAGE" "$SERVICES" "$HYPRLAND" \
  | jq -s -r '[.[] | .checks[] | select(
      (.value | test("(?i)^(usage|commands?|options?|help)")) or
      (.detail | test("(?i)wpctl \\[OPTION"))
    )] | length')
check_eq "no check reports text scraped from a usage banner" "0" "$fabricated"

# The same hazard exists for the tools the Phase B sections call, with different
# wording. hyprctl answers an unknown subcommand with "unknown request" and a
# missing compositor instance with "HYPRLAND_INSTANCE_SIGNATURE not set!" --
# both on stdout, both with exit status 0. systemctl answers an unknown verb with
# "Unknown command verb". If any of that ever reached a check value or detail,
# a working machine would be reported as broken (or worse, a broken one as
# healthy). None of these strings may appear anywhere in a section's output.
leaked_banner=$(printf '%s' "$SERVICES" "$HYPRLAND" "$DISPLAY" \
  | jq -s -r '[.[] | .checks[] | select(
      ((.value // "") + " " + (.detail // "") + " " + (.suggestion // ""))
      | test("(?i)unknown request|unknown command verb|hyprland_instance_signature|is hyprland running")
    )] | length')
check_eq "no check leaks a tool error banner as data" "0" "$leaked_banner"

# "Not installed" is a legitimate, non-fault state -- a machine with no
# bluetooth hardware is not broken. It must therefore never be escalated to a
# problem, or every optional unit becomes a false alarm.
notinstalled_problem=$(printf '%s' "$SERVICES" \
  | jq -r '[.checks[]
    | select(.value == "not installed")
    | select(.status == "problem" or .status == "attention")] | length')
check_eq "an uninstalled service is never escalated to a fault" "0" "$notinstalled_problem"

# A daemon that could not be read must degrade to unknown, not to a guess.
# "unknown" is the honest answer when systemctl or hyprctl cannot answer.
# Assert the sections never invent a state: every services value is one of the
# known systemd-ish words or an explicit unknown.
bad_svc=$(printf '%s' "$SERVICES" | jq -r '[.checks[]
  | select((.value | test("^(running|dead|exited|listening|failed|inactive|active|"
       + "activating|deactivating|reloading|not installed|masked|unit error|unknown)$")) | not)
  ] | length')
check_eq "every service value is a known state or explicit unknown" "0" "$bad_svc"

# ------------------------------------------------------- display vocabulary
#
# The Display Doctor's whole value depends on NOT inventing a display problem.
# Two specific false alarms are guarded here:
#
#   * an unsupported-mode verdict on every monitor, because the current mode
#     ("1920x1080@59.99800") and the available list ("1920x1080@60.00Hz") are in
#     different formats and never compare equal literally;
#   * a fractional scale or a rotation escalated to a fault, when both are
#     deliberate user choices and legitimate.
#
# A user who sees a warning on every scan learns to ignore the panel, which
# costs more than never shipping the check at all.
#
# The guards are asserted against SYNTHETIC documents as well as the live run.
# Asserting only against live output means the rule is untested whenever this
# machine happens not to have the condition -- which is exactly the case where
# a regression would ship unnoticed. Each synthetic document below is a check
# the section is capable of emitting, so the guard is proven to catch it.
d_esc() { printf '%s' "$1" | jq -r '[.checks[]
  | select((.id == "display.scale" or .id == "display.orientation"
            or .id == "display.mirroring")
           and (.status == "problem" or .status == "attention"))] | length'; }

check_eq "the guard flags an escalated fractional scale" "1" \
  "$(d_esc '{"checks":[{"id":"display.scale","status":"attention","value":"fractional"}]}')"
check_eq "the guard flags an escalated rotation" "1" \
  "$(d_esc '{"checks":[{"id":"display.orientation","status":"problem","value":"rotated"}]}')"
check_eq "the guard flags an escalated mirror" "1" \
  "$(d_esc '{"checks":[{"id":"display.mirroring","status":"attention","value":"in use"}]}')"
check_eq "the guard passes a legitimate fractional scale at info" "0" \
  "$(d_esc '{"checks":[{"id":"display.scale","status":"info","value":"fractional"}]}')"

bad_display=$(printf '%s' "$DISPLAY" | jq -r '[.checks[]
  | select((.id == "display.scale" or .id == "display.orientation"
            or .id == "display.mirroring")
           and (.status == "problem" or .status == "attention"))
  ] | length')
check_eq "a chosen scale, rotation or mirror is never escalated to a fault" "0" "$bad_display"

# "unknown" must be the honest answer when there is no compositor, and must
# never be dressed up as a display fault.
bad_unknown=$(printf '%s' "$DISPLAY" | jq -r '[.checks[]
  | select((.value == "unknown") and (.status == "problem" or .status == "attention"))
  ] | length')
check_eq "an unreachable compositor is never reported as a display fault" "0" "$bad_unknown"

# Every display value must be drawn from the known vocabulary. A value outside
# it means something unparsed leaked through.
bad_display_vocab=$(printf '%s' "$DISPLAY" | jq -r '[.checks[]
  | select((.value | test("^(unknown|unavailable|[0-9]+ active|none|none active|"
       + "supported|unsupported mode set|in use|fractional|integer|normal|"
       + "rotated or mirrored|[0-9]+)$")) | not)
  ] | length')
check_eq "every display value is a known state or explicit unknown" "0" "$bad_display_vocab"

# The audio defaults must be either a real node name or an explicit unknown --
# never a bare number that a user cannot act on.
# $AUDIO is a single JSON document, so -s is not needed (and would make the
# slurped value a 1-element array, hiding .checks behind it).
bad_audio=$(printf '%s' "$AUDIO" | jq -r '[.checks[]
  | select(.id == "audio.output" or .id == "audio.input")
  | select(.value | test("^[0-9]+$"))] | length')
check_eq "audio defaults are names, not raw node ids" "0" "$bad_audio"

# ---------------------------------------------------- optional field emitters
#
# checkd/checkr are the OPTIONAL-field variants of check/emit. Their positional
# tails are the fragile part: a trailing argument that is absent must NOT be
# allowed to duplicate the repair label into repair.detail or leak it into
# details[]. These pin every arity, because that class of bug produces
# well-formed JSON that is simply WRONG -- no validator will catch it.

# emit_one BODY -> run the emitter in a clean shell and print the array.
#
# Uses run_interp from lib.sh rather than invoking $OMC_TEST_SH directly: that
# variable may carry an option word ("bash --posix"), and running the whole
# string as one command name fails. Every suite is expected to pass under
# every interpreter the runner offers.
emit_one() {
  run_interp -c "
    . '$BACKEND_DIR/common.sh'
    CHECKS=''
    $1
    printf '[%s]\n' \"\$CHECKS\"
  " 2>/dev/null
}

# The bare emit() must remain unchanged: it omits the optional keys entirely.
# jq yields empty strings for absent keys, so test presence with has() on the
# object itself rather than reading the (absent) values.
check_eq "emit omits the optional fields entirely" "false false" \
  "$(emit_one 'emit i c ok 0 T V D S' \
    | jq -r '.[0] | [(has("details")|tostring), (has("repair")|tostring)] | join(" ")' 2>/dev/null)"

# checkd: evidence lines only, and empty evidence arguments are dropped.
check_eq "emitd collects evidence lines" '["one","three"]' \
  "$(emit_one 'emitd i c attention 1 T V D S one "" three' | jq -c '.[0].details')"
check_eq "emitd with no evidence yields an empty array" "[]" \
  "$(emit_one 'emitd i c attention 1 T V D S' | jq -c '.[0].details')"
check_eq "emitd carries no repair" "null" \
  "$(emit_one 'emitd i c attention 1 T V D S one' | jq -r '.[0].repair')"

# checkr, by arity. The label must NEVER be duplicated into repair.detail, and
# only genuinely-supplied evidence may appear in details[].
check_eq "checkr label only leaves detail empty and details empty" \
  '{"tier":"safe","label":"L","detail":""}' \
  "$(emit_one 'emitr i c problem 3 T V D S safe L' | jq -c '.[0].repair')"
check_eq "checkr label only does not leak into details" "[]" \
  "$(emit_one 'emitr i c problem 3 T V D S safe L' | jq -c '.[0].details')"
check_eq "checkr with repair detail" \
  '{"tier":"safe","label":"L","detail":"RD"}' \
  "$(emit_one 'emitr i c problem 3 T V D S safe L RD' | jq -c '.[0].repair')"
check_eq "checkr keeps only real evidence lines" '["e1","e2"]' \
  "$(emit_one 'emitr i c problem 3 T V D S safe L RD e1 "" e2' | jq -c '.[0].details')"

# An unrecognised tier must degrade to manual, never to the reassuring one.
check_eq "an unknown repair tier degrades to manual" "manual" \
  "$(emit_one 'emitr i c problem 3 T V D S banana L' | jq -r '.[0].repair.tier')"
check_eq "a missing repair label yields a null repair" "null" \
  "$(emit_one 'emitr i c problem 3 T V D S safe ""' | jq -r '.[0].repair')"

# Values inside the optional fields go through jstr like everything else, so a
# quote, a backslash or a newline cannot corrupt the document.
check_eq "evidence is escaped like any other value" '["a \"q\" & \\ b"]' \
  "$(emit_one 'emitd i c attention 1 T V D S "a \"q\" & \\ b"' | jq -c '.[0].details')"

# ------------------------------------------------------------- scan history
#
# The history exists so "what changed" survives a shell restart. Two properties
# matter and both are checked here rather than trusted:
#
#   * it is written on FULL scans only. A quick scan runs every 30s; writing one
#     file per poll would be thousands of files a day for a feature nobody is
#     looking at.
#   * it stays BOUNDED. An unbounded history is a slow disk leak on a machine
#     that is supposed to be well behaved.
# bootstrap.sh defaults this to $HOME/.local/state/omadoctor. The variable is
# NOT exported into this script, so it must be recomputed here -- reading an
# unset $OMADOCTOR_STATE_DIR yields "/history", a root path that silently
# collects nothing and makes every assertion below fail for the wrong reason.
: "${OMADOCTOR_STATE_DIR:=$HOME/.local/state/omadoctor}"
HIST_DIR="$OMADOCTOR_STATE_DIR/history"

hist_count() { /bin/ls -1 "$HIST_DIR" 2>/dev/null | /usr/bin/grep -c '^[0-9][0-9]*\.json$' || printf '0'; }
# The newest entry by FILENAME, which is the epoch. Sorting by name rather than
# mtime is deliberate and is what doctor.sh does; see the prune assertion below.
hist_newest() { /bin/ls -1 "$HIST_DIR" 2>/dev/null | /usr/bin/grep '^[0-9][0-9]*\.json$' | /usr/bin/sort | tail -n 1; }
# Numeric comparison, not the test builtin: `[ "1791024658" -gt "1791024649" ]`
# is a STRING compare in POSIX sh, and filenames carry a .json suffix. Strip it
# and compare as numbers or the assertion is meaningless.
hist_newest_ts() { h=$(hist_newest); printf '%s' "${h%.json}"; }
# gt NUM_A NUM_B -> true when A is numerically newer than B.
gt() { [ "$1" -gt "$2" ] 2>/dev/null; }

before_newest=$(hist_newest_ts)
run "$BACKEND_DIR/doctor.sh" quick >/dev/null
after_quick_newest=$(hist_newest_ts)
# The check is "no NEWER file", not "more files": the directory is usually
# already at its cap, so a count comparison would pass trivially or fail
# spuriously depending on prior state.
check_eq "a quick scan writes no history" "$before_newest" "$after_quick_newest"

run "$BACKEND_DIR/doctor.sh" full >/dev/null
after_full_newest=$(hist_newest_ts)
if [ -n "$after_full_newest" ] && gt "$after_full_newest" "$before_newest"; then
  ok "a full scan writes a newer history entry"
else
  fail "a full scan writes a newer history entry" \
    "before=$before_newest after=$after_full_newest"
fi

# Every entry must be the COMPACT form -- a status map, not a whole document.
# A full snapshot here would be ~7x the size for data the diff never reads.
newest=$(hist_newest)
if [ -n "$newest" ]; then
  hist_shape=$(jq -r 'if (.status | type) == "object" and (has("checks") | not)
                     then "compact" else "wrong" end' "$HIST_DIR/$newest" 2>/dev/null)
  check_eq "history stores a compact status map, not a full document" "compact" "$hist_shape"

  hist_ids=$(jq -r '.status | keys | length' "$HIST_DIR/$newest" 2>/dev/null)
  scan_ids=$(printf '%s' "$FULL" | jq -r '.checks | length')
  if [ "$hist_ids" -gt 0 ] && [ "$hist_ids" -le "$scan_ids" ]; then
    ok "history covers the scan's checks ($hist_ids of $scan_ids)"
  else
    fail "history covers the scan's checks" "hist=$hist_ids scan=$scan_ids"
  fi
else
  fail "history stores a compact status map, not a full document" "no history file"
  fail "history covers the scan's checks" "no history file"
fi

# The cap. Seed well past the limit with names that sort chronologically (the
# filename IS the epoch), then force a prune.
for i in $(seq 1 26); do
  printf '{"ts":%s,"status":{"a":"ok"}}\n' "$((1700000000 + i))" \
    > "$HIST_DIR/$((1700000000 + i)).json" 2>/dev/null
done
run "$BACKEND_DIR/doctor.sh" full >/dev/null
pruned=$(hist_count)
if [ "$pruned" -le 20 ]; then
  ok "history is capped at 20 entries (kept $pruned)"
else
  fail "history is capped at 20 entries" "kept=$pruned"
fi

# The newest entry must SURVIVE the prune. Sorting by mtime is wrong here: two
# scans in the same second share an mtime and tie-break arbitrarily, which
# silently deleted the genuinely newest file during development.
newest_after=$(hist_newest_ts)
if [ -n "$newest_after" ] && gt "$newest_after" "$((1700000000 + 26))"; then
  ok "the newest history entry survives the prune"
else
  fail "the newest history entry survives the prune" "newest=$newest_after"
fi

finish