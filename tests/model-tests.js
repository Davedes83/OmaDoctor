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
  "buildReportText"
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

// ------------------------------------------------------------------- summary

console.log("1.." + checks);
if (fails > 0) {
  console.log("# " + fails + " of " + checks + " checks failed");
  process.exit(1);
} else {
  console.log("# all " + checks + " checks passed");
}