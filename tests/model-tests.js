#!/usr/bin/env node
// OmaDoctor Model.js unit tests.
//
// Model.js is a QML `.pragma library`, not a CommonJS module, so it is loaded
// into a vm context and its top-level functions are read back off the global.
// Running this catches the class of bug that unit tests exist for: a green
// shell build that still renders wrong in the panel.
//
// Usage: node tests/model-tests.js

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const modelPath = path.join(__dirname, "..", "Model.js");
const src = fs.readFileSync(modelPath, "utf8");

// Expose the library functions we want to test on the context global.
const EXPORTS = [
  "parseDoctor", "overallState", "issues", "counts", "byCategory",
  "findCheck", "fmtAge", "glyph", "stateLabel", "redact", "buildReport",
  "buildReportText", "findingRows", "strArray", "normRepair"
];

const ctx = vm.createContext({ JSON, Math, String, Number, Array, Object, isFinite, Date });
vm.runInContext(
  `${src}\n;globalThis.__M = { ${EXPORTS.join(", ")} };`,
  ctx,
  { filename: modelPath }
);
const M = ctx.__M;

let checks = 0;
let fails = 0;
const failures = [];

function ok(name) {
  checks++;
  console.log("ok " + checks + " - " + name);
}
function fail(name, detail) {
  checks++;
  fails++;
  failures.push(name);
  console.log("not ok " + checks + " - " + name);
  if (detail !== undefined) console.log("  # " + detail);
}
function eq(name, expected, actual) {
  if (JSON.stringify(expected) === JSON.stringify(actual)) ok(name);
  else fail(name, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

// --------------------------------------------------------------- parseDoctor

eq("parseDoctor rejects empty input", null, M.parseDoctor(""));
eq("parseDoctor rejects non-string", null, M.parseDoctor(null));
eq("parseDoctor rejects malformed JSON", null, M.parseDoctor("{not json"));
eq("parseDoctor rejects a valid JSON that is not a scan", null, M.parseDoctor('{"foo":1}'));
eq("parseDoctor rejects an array", null, M.parseDoctor("[]"));

const goodScan = {
  mode: "full",
  version: "0.1.0",
  ts: 1700000000,
  sections: "sysinfo,audio,storage,network",
  checks: [
    { id: "system.os", category: "system", title: "Operating system", status: "ok", severity: 0, value: "Omarchy", detail: "", suggestion: "" },
    { id: "storage.fs.root", category: "storage", title: "Filesystem: root", status: "attention", severity: 1, value: "85% used", detail: "free", suggestion: "clean up" },
    { id: "network.internet", category: "network", title: "Internet", status: "problem", severity: 3, value: "unreachable", detail: "no route", suggestion: "check cable" }
  ]
};
const parsed = M.parseDoctor(JSON.stringify(goodScan));
ok("parseDoctor accepts a well-formed scan");
eq("parseDoctor preserves mode", "full", parsed.mode);
eq("parseDoctor preserves check count", 3, parsed.checks.length);
eq("parseDoctor keeps severity numeric", 3, parsed.checks[2].severity);
eq("typeof severity is number", "number", typeof parsed.checks[2].severity);

// A missing optional field must become "" rather than undefined.
const sparse = M.parseDoctor('{"checks":[{"id":"a","category":"system"}]}');
eq("missing fields normalise to empty strings", "", sparse.checks[0].title);
eq("missing status normalises to problem", "problem", sparse.checks[0].status);

// An unknown status must never be read as healthy.
const bogus = M.parseDoctor('{"checks":[{"id":"a","status":"fine"}]}');
eq("unknown status becomes problem", "problem", bogus.checks[0].status);

// ------------------------------------------------------------------ roll-up

eq("overallState: all ok", "ok", M.overallState([{ status: "ok" }]));
eq("overallState: info alone is still ok", "ok", M.overallState([{ status: "ok" }, { status: "info" }]));
eq("overallState: one attention", "attention", M.overallState([{ status: "ok" }, { status: "attention" }]));
eq("overallState: one problem wins", "problem", M.overallState([{ status: "attention" }, { status: "problem" }]));
eq("overallState: worst wins regardless of order", "problem", M.overallState([{ status: "problem" }, { status: "ok" }]));
eq("overallState: empty is ok", "ok", M.overallState([]));
eq("overallState: null is ok", "ok", M.overallState(null));

eq("counts tallies each state", { ok: 2, info: 1, attention: 1, problem: 1, total: 5 },
  M.counts([
    { status: "ok" }, { status: "ok" }, { status: "info" },
    { status: "attention" }, { status: "problem" }
  ]));

eq("issues returns only actionable checks, worst first", 2, M.issues(parsed.checks).length);
eq("issues sorts problem before attention", "problem", M.issues(parsed.checks)[0].status);

const buckets = M.byCategory(parsed.checks);
eq("byCategory makes one bucket per category", 3, buckets.length);
eq("byCategory keeps a stable canonical order", "system", buckets[0].category);
eq("byCategory places network after system", "network", buckets[1].category);
eq("byCategory rolls up per-bucket state", "problem", buckets[1].state);

eq("findCheck locates by id", "system.os", M.findCheck(parsed.checks, "system.os").id);
eq("findCheck returns null for unknown id", null, M.findCheck(parsed.checks, "nope"));

// ----------------------------------------------------------------- formatting

eq("fmtAge never", "never", M.fmtAge(0, 1000));
eq("fmtAge seconds", "30s ago", M.fmtAge(1000, 1030));
eq("fmtAge minutes", "5m ago", M.fmtAge(1000, 1000 + 300));
eq("fmtAge hours", "2h ago", M.fmtAge(1000, 1000 + 7200));
eq("fmtAge days", "3d ago", M.fmtAge(1000, 1000 + 3 * 86400));

eq("stateLabel healthy", "HEALTHY", M.stateLabel("ok"));
eq("stateLabel attention", "ATTENTION", M.stateLabel("attention"));
eq("stateLabel problem", "PROBLEM", M.stateLabel("problem"));

// -------------------------------------------------------------------- redact

// The report is how a user's machine details leave their machine, so redaction
// defaults on and must cover every identifier class.
eq("redact masks IPv4 host part", "gateway 192.168.x.x is fine",
  M.redact("gateway 192.168.10.1 is fine", {}));
eq("redact masks MAC (colon)", "<mac>", M.redact("aa:bb:cc:dd:ee:ff", {}));
eq("redact masks MAC (dash)", "<mac>", M.redact("aa-bb-cc-dd-ee-ff", {}));
eq("redact masks IPv6", "addr <ipv6> here", M.redact("addr fe80:1:2:3:4:5:6:7 here", {}));
eq("redact masks compressed IPv6", "<ipv6>", M.redact("fe80::1", {}));
eq("redact masks full IPv6 loopback", "<ipv6>", M.redact("::1", {}));
eq("redact masks IPv4-mapped IPv6", "<ipv6>",
  M.redact("::ffff:192.168.1.1", {}));
eq("redact masks hostname", "host <host>", M.redact("host mybox", { hostname: "mybox" }));
eq("redact masks username", "user <user>", M.redact("user dave", { username: "dave" }));
eq("redact masks home path", "~ is home", M.redact("/home/dave is home", { home: "/home/dave" }));
eq("redact is idempotent", "<ipv6>", M.redact(M.redact("fe80::1", {}), {}));

// Clock times are hex-legal, so the IPv6 patterns used to swallow them and
// the report header rendered its own timestamp as "<ipv6>". A time has no
// "::", fewer than four groups, and every group is a short decimal run.
eq("redact keeps an h:mm:ss clock time", "08:04:18",
  M.redact("08:04:18", {}));
eq("redact keeps a short colon group run", "1:2:3", M.redact("1:2:3", {}));
eq("redact keeps uptime text", "0d 3h 57m", M.redact("0d 3h 57m", {}));
eq("redact keeps load-average slashes", "2.42 / 1.73 / 1.72",
  M.redact("2.42 / 1.73 / 1.72", {}));
eq("redact keeps a dated timestamp intact", "2026-10-03 08:04:18 UTC",
  M.redact("2026-10-03 08:04:18 UTC", {}));

// A 4+ group address with no "::" is still a real address and must be masked,
// so the guard above cannot be satisfied by simply dropping the pattern.
eq("redact masks uncompressed 8-group IPv6", "<ipv6>",
  M.redact("fe80:0:0:0:0:0:0:1", {}));
eq("redact masks a group that is not short-decimal", "<ipv6>",
  M.redact("abcd:ef01:2345", {}));
eq("redact masks the all-zero shorthand", "<ipv6>", M.redact("::", {}));
eq("redact masks fe80 with empty tail", "<ipv6>", M.redact("fe80::", {}));

// The original IP must not survive anywhere in a redacted report.
const report = M.buildReport(goodScan ? parsed : null, {
  now: 1700000100,
  redactInfo: { hostname: "mybox", username: "dave", home: "/home/dave" }
});
checkNoLeak: {
  const leaks = ["192.168.10.1", "mybox", "dave", "aa:bb:cc:dd:ee:ff"]
    .filter((needle) => report.includes(needle));
  if (leaks.length === 0) ok("report leaks no hostname/username/IP/MAC");
  else fail("report leaks no hostname/username/IP/MAC", "leaked: " + leaks.join(", "));
}

// -------------------------------------------------------------------- report

ok("report includes a headline state");
if (report.includes("PROBLEM")) ok("report shows PROBLEM for a problem scan");
else fail("report shows PROBLEM for a problem scan");

if (report.includes("FINDINGS")) ok("report includes a findings section");
else fail("report includes a findings section");

if (report.includes("Suggested: check cable")) ok("report surfaces suggestions");
else fail("report surfaces suggestions", report.slice(0, 200));

if (report.includes("No telemetry")) ok("report states the privacy posture");
else fail("report states the privacy posture");

// Redaction can be turned off explicitly, but must say so.
const rawReport = M.buildReport(parsed, { now: 1700000100, redact: false });
if (rawReport.includes("DISABLED")) ok("report warns when redaction is disabled");
else fail("report warns when redaction is disabled");

eq("buildReport survives a null scan gracefully",
  "OmaDoctor\n\nNo scan data available.", M.buildReport(null, {}));

// A scan with nothing wrong must say so plainly.
const cleanScan = M.parseDoctor(JSON.stringify({
  mode: "quick", ts: 1700000000,
  checks: [{ id: "system.os", category: "system", title: "OS", status: "ok", severity: 0, value: "Omarchy" }]
}));
if (M.buildReport(cleanScan, { now: 1700000100 }).includes("Nothing needs attention")) {
  ok("report says so when nothing needs attention");
} else {
  fail("report says so when nothing needs attention");
}

// buildReportText takes the raw JSON straight from the process.
if (M.buildReportText(JSON.stringify(goodScan), { now: 1700000100 }).includes("OMADOCTOR")) {
  ok("buildReportText accepts raw JSON");
} else {
  fail("buildReportText accepts raw JSON");
}

// The "Generated" line is generated from an ISO timestamp, so redaction used
// to eat the time half of it and print "2026-10-03 <ipv6> UTC".
const stamped = M.buildReport(goodScan ? parsed : null, { now: 1700000100 });
if (!/<ipv6>/.test(stamped.split("\n").filter(function(l) {
  return l.indexOf("Generated") === 0;
}).join(" "))) {
  ok("report keeps its own Generated timestamp");
} else {
  fail("report keeps its own Generated timestamp");
}

// ----------------------------------------------------------- findingRows
//
// findingRows is what the panel's single Repeater renders. It replaced a
// nested Repeater that produced category headers with no rows under them,
// because the inner delegate could not see the outer delegate's modelData.
// These tests pin the flat shape so that regression cannot come back.

const rowScan = {
  checks: [
    { id: "s.ok", category: "system", title: "OS", status: "ok", severity: 0, value: "Omarchy", detail: "", suggestion: "" },
    { id: "s.bad", category: "system", title: "Failed services", status: "problem", severity: 3, value: "1 failed", detail: "d", suggestion: "s" },
    { id: "a.warn", category: "audio", title: "Muted", status: "attention", severity: 1, value: "yes", detail: "", suggestion: "" },
    { id: "a.ok", category: "audio", title: "Devices", status: "info", severity: 0, value: "2", detail: "", suggestion: "" },
    { id: "t.ok", category: "storage", title: "Root", status: "ok", severity: 0, value: "40%", detail: "", suggestion: "" }
  ]
};
const rows = M.findingRows(rowScan.checks);

// Only categories with findings get a header: system and audio, not storage.
eq("findingRows omits categories with nothing to report",
  "SYSTEM,AUDIO", rows.filter(r => r.kind === "header").map(r => r.category).join(","));

// Every header is immediately followed by at least one check -- the exact
// shape the nested Repeater failed to produce.
if (rows.filter(r => r.kind === "check").length === 2) {
  ok("findingRows emits one check per finding");
} else {
  fail("findingRows emits one check per finding");
}

if (rows.length === 4 && rows[0].kind === "header" && rows[1].kind === "check"
    && rows[2].kind === "header" && rows[3].kind === "check") {
  ok("findingRows interleaves headers and checks in order");
} else {
  fail("findingRows interleaves headers and checks in order");
}

eq("findingRows carries the check payload on a check row",
  "Failed services", (rows.filter(r => r.kind === "check")[0] || { check: {} }).check.title);

eq("findingRows returns nothing for an all-clear scan",
  0, M.findingRows([
    { id: "a", category: "system", title: "OS", status: "ok", severity: 0, value: "x", detail: "", suggestion: "" },
    { id: "b", category: "audio", title: "Info", status: "info", severity: 0, value: "y", detail: "", suggestion: "" }
  ]).length);

eq("findingRows tolerates empty input", 0, M.findingRows([]).length);
eq("findingRows tolerates null input", 0, M.findingRows(null).length);
eq("findingRows tolerates non-array input", 0, M.findingRows("nope").length);

// ------------------------------------------------- optional details + repair
//
// details[] and repair are ADDITIVE: a producer that omits them must parse to
// an empty list / null, and the pre-existing detail/suggestion strings must
// still work. These pin that contract so widening the schema can never break a
// section script that has not been updated.

eq("strArray wraps a bare scalar", ["one"], M.strArray("one"));
eq("strArray keeps an array as-is", ["a", "b"], M.strArray(["a", "b"]));
// "[object Object]" in a diagnostic report is worse than an absent line.
eq("strArray drops objects, null and empty strings", ["a", "0", "b"],
  M.strArray(["a", {}, null, "", 0, "b"]));
eq("strArray treats absent as empty", [], M.strArray(undefined));
eq("strArray tolerates null", [], M.strArray(null));

// An unknown tier must degrade to the most dangerous one, exactly as an
// unknown status degrades to "problem" rather than "ok".
eq("normRepair keeps a known tier", "safe", M.normRepair({ tier: "safe", label: "x" }).tier);
eq("normRepair lowercases the tier", "caution", M.normRepair({ tier: "CAUTION", label: "x" }).tier);
eq("normRepair degrades an unknown tier to manual", "manual",
  M.normRepair({ tier: "banana", label: "x" }).tier);
eq("normRepair degrades a missing tier to manual", "manual",
  M.normRepair({ label: "x" }).tier);
// A repair with no label says nothing, so it is not a repair.
eq("normRepair drops a repair with no label", null, M.normRepair({ tier: "safe" }));
eq("normRepair drops a non-object", null, M.normRepair("restart everything"));
eq("normRepair drops an array", null, M.normRepair([{ tier: "safe", label: "x" }]));

// A check that carries none of the new fields must still normalise cleanly.
const legacy = M.parseDoctor(JSON.stringify({
  mode: "quick", ts: 1700000000,
  checks: [{ id: "l.1", category: "system", title: "OS", status: "ok", severity: 0, value: "Omarchy", detail: "d", suggestion: "s" }]
}));
eq("a legacy check normalises details to an empty list", [], legacy.checks[0].details);
eq("a legacy check normalises repair to null", null, legacy.checks[0].repair);
eq("a legacy check keeps its detail and suggestion", "d/s",
  legacy.checks[0].detail + "/" + legacy.checks[0].suggestion);

// And a check that carries them keeps both intact through the round trip.
const rich = M.parseDoctor(JSON.stringify({
  mode: "full", ts: 1700000000,
  checks: [{
    id: "h.1", category: "hyprland", title: "Config errors", status: "problem",
    severity: 3, value: "1 error", detail: "configerror", suggestion: "open config",
    details: ["line 42: unknown keyword", "line 7: bad rule"],
    repair: { tier: "manual", label: "Edit hypr config", detail: "OmaDoctor will not do this" }
  }]
}));
eq("a rich check keeps its details array", 2, rich.checks[0].details.length);
eq("a rich check keeps its repair tier", "manual", rich.checks[0].repair.tier);
eq("a rich check keeps its repair label", "Edit hypr config", rich.checks[0].repair.label);

// The report renders the new fields. Repairs are advisory, so the report must
// also state plainly that nothing is executed.
const richReport = M.buildReport(rich, { now: 1700000100 });
if (richReport.includes("unknown keyword")) ok("report renders details[] entries");
else fail("report renders details[] entries", richReport.slice(0, 300));
if (richReport.includes("MANUAL")) ok("report renders the repair tier");
else fail("report renders the repair tier", richReport.slice(0, 300));
if (/does not/.test(richReport.split("FINDINGS")[1] || "")) {
  ok("report disclaims running repairs");
} else {
  fail("report disclaims running repairs", richReport.slice(0, 300));
}

// The new fields go through the same redaction as everything else, otherwise
// widening the schema opens a leak.
const leaky = M.parseDoctor(JSON.stringify({
  mode: "full", ts: 1700000000,
  checks: [{
    id: "n.1", category: "network", title: "Gateway", status: "problem", severity: 3,
    value: "192.168.1.1", detail: "", suggestion: "",
    details: ["mybox is at 192.168.1.1", "user dave on aa:bb:cc:dd:ee:ff"],
    repair: { tier: "manual", label: "Check mybox", detail: "dave's machine" }
  }]
}));
const leakyReport = M.buildReport(leaky, {
  now: 1700000100,
  redactInfo: { hostname: "mybox", username: "dave", home: "/home/dave" }
});
{
  const leaks = ["192.168.1.1", "mybox", "dave", "aa:bb:cc:dd:ee:ff"]
    .filter(n => leakyReport.includes(n));
  if (leaks.length === 0) ok("details[] and repair are redacted like any other field");
  else fail("details[] and repair are redacted like any other field", "leaked: " + leaks.join(", "));
}

// A report for a scan with no repairs must NOT carry the disclaimer, or it
// advertises a repair capability the scan does not have.
const legacyFindings = M.buildReport(legacy, { now: 1700000100 }).split("FINDINGS")[1] || "";
if (legacyFindings.indexOf("Repairs are listed") === -1) {
  ok("no repair disclaimer when nothing suggests a repair");
} else {
  fail("no repair disclaimer when nothing suggests a repair", legacyFindings);
}

// ------------------------------------------------------------------- summary

console.log("1.." + checks);
if (fails > 0) {
  console.log("# " + fails + " of " + checks + " checks failed");
  process.exit(1);
} else {
  console.log("# all " + checks + " checks passed");
}