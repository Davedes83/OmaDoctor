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
  /usr/bin/timeout -k 2 90 /bin/sh "$@" 2>/dev/null </dev/null
}

SYSINFO=$(run "$BACKEND_DIR/sysinfo.sh")
AUDIO=$(run "$BACKEND_DIR/audio.sh")
STORAGE=$(run "$BACKEND_DIR/storage.sh")
SYSINFO_BARE=$(run "$BACKEND_DIR/sysinfo.sh" --checks-only)
QUICK=$(run "$BACKEND_DIR/doctor.sh" quick)
FULL=$(run "$BACKEND_DIR/doctor.sh" full)

# ------------------------------------------------------------ JSON validity

for pair in "sysinfo:$SYSINFO" "audio:$AUDIO" "storage:$STORAGE"; do
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
for pair in "sysinfo:$SYSINFO" "audio:$AUDIO" "storage:$STORAGE"; do
  name=${pair%%:*}
  doc=${pair#*:}
  if ! printf '%s' "$doc" | jq -e "$REQUIRED" >/dev/null 2>&1; then
    missing="$missing $name"
  fi
done
check_eq "every check carries the required fields" "" "$missing"

# --------------------------------------------------------------- schema rules

# severity must be a JSON number, not a string -- Model.js compares numerically.
check_eq "severity is a JSON number" "number" \
  "$(printf '%s' "$SYSINFO" | jq -r '.checks[0].severity | type')"

# status must always be one of the four known states.
bad=$(printf '%s' "$SYSINFO" "$AUDIO" "$STORAGE" \
  | jq -s -r '[.[] | .checks[].status | select(. != "ok" and . != "info" and . != "attention" and . != "problem")] | length')
check_eq "status values are within the known set" "0" "$bad"

# ids must be unique, otherwise the UI cannot address a check by id.
dupes=$(printf '%s' "$SYSINFO" "$AUDIO" "$STORAGE" \
  | jq -s -r '[.[] | .checks[].id] | (length - (unique | length))')
check_eq "check ids are unique across sections" "0" "$dupes"

# --checks-only must emit BARE objects (no enclosing brackets): doctor.sh
# concatenates section output and wraps the result in exactly one array.
case "$(printf '%s' "$SYSINFO_BARE" | cut -c1)" in
  '[') fail "--checks-only omits the array brackets" "output starts with '['" ;;
  '{') ok "--checks-only omits the array brackets" ;;
  *)   fail "--checks-only omits the array brackets" "unexpected output" ;;
esac

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
cp "$BACKEND_DIR/doctor.sh" "$BACKEND_DIR/bootstrap.sh" "$BROKEN/" 2>/dev/null
printf '#!/bin/sh\nexit 3\n' > "$BROKEN/sysinfo.sh"
: > "$BROKEN/audio.sh"
: > "$BROKEN/storage.sh"
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
cp "$BACKEND_DIR/doctor.sh" "$BACKEND_DIR/bootstrap.sh" "$SILENT/" 2>/dev/null
printf '#!/bin/sh\nprintf ""\n' > "$SILENT/sysinfo.sh"
: > "$SILENT/audio.sh"
: > "$SILENT/storage.sh"
silent=$(/usr/bin/timeout -k 2 60 /bin/sh "$SILENT/doctor.sh" quick 2>/dev/null </dev/null)
rm -rf "$SILENT"
if printf '%s' "$silent" \
   | jq -e '[.checks[] | select(.id == "sysinfo.section" and .status == "problem")] | length == 1' >/dev/null 2>&1; then
  ok "a silent section is reported as a problem check"
else
  fail "a silent section is reported as a problem check" "$(printf '%s' "$silent" | head -c 200)"
fi

finish