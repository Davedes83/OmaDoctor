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
  "findCheck", "weight", "normStatus", "fmtAge", "glyph", "stateLabel", "redact", "buildReport",
  "buildReportText", "findingRows", "strArray", "normRepair",
  "shouldNotify", "notificationText", "diffScans", "changeSummary",
  "summaryLine", "breakdownLine"
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

// Category order is the machine's shape, not alphabetical: what you are, then
// what it depends on, then what makes noise. It also has to be STABLE, or the
// panel reshuffles between scans. An unlisted category sorts last rather than
// disappearing, so a future section needs no change here to appear.
eq("byCategory orders categories by machine shape, not alphabetically",
  "system,services,hyprland,audio,storage",
  M.byCategory([
    { category: "storage" }, { category: "audio" }, { category: "hyprland" },
    { category: "services" }, { category: "system" }
  ]).map(b => b.category).join(","));
eq("an unlisted category sorts last rather than vanishing",
  "system,gpu",
  M.byCategory([{ category: "gpu" }, { category: "system" }])
    .map(b => b.category).join(","));
eq("byCategory ordering is stable regardless of input order",
  "system,services,hyprland",
  M.byCategory([{ category: "hyprland" }, { category: "services" }, { category: "system" }])
    .map(b => b.category).join(","));

// --------------------------------------------------------------- what changed
//
// The point of diffScans is to be QUIET. Almost every value in a scan moves on
// every scan -- uptime ticks, latency jitters, memory drifts -- so a value diff
// would always have something in it and the user would learn to ignore it.
// Only a STATUS transition by check id is news.

function scanOf(checks) {
  return M.parseDoctor(JSON.stringify({ mode: "quick", ts: 1700000000, checks }));
}

const C = (id, cat, title, status, value) =>
  ({ id, category: cat, title, status, severity: status === "problem" ? 3 : (status === "attention" ? 1 : 0), value: value || "" });

// A value moving while the status holds is not a change.
{
  const a = scanOf([C("s.uptime", "system", "Uptime", "info", "2d 3h")]);
  const b = scanOf([C("s.uptime", "system", "Uptime", "info", "2d 4h")]);
  const d = M.diffScans(a, b);
  eq("a value moving under an unchanged status is not a change", false, d.changed);
  eq("an unchanged check is counted as same", 1, d.same);
}

// A status transition IS a change.
{
  const a = scanOf([C("n.gw", "network", "Gateway", "ok", "12 ms")]);
  const b = scanOf([C("n.gw", "network", "Gateway", "problem", "unreachable")]);
  const d = M.diffScans(a, b);
  eq("ok -> problem is a change", true, d.changed);
  eq("the worse transition is reported", 1, d.worse.length);
  eq("nothing is reported as better", 0, d.better.length);
  eq("the transition records where it came from", "ok", d.worse[0].from);
  eq("the transition records where it went", "problem", d.worse[0].to);
  // The CURRENT reading is what the user needs, not the old one.
  eq("the transition carries the current value", "unreachable", d.worse[0].value);
  eq("the transition carries the check title", "Gateway", d.worse[0].title);
}

// Recovery is a change too, and lands in `better`.
{
  const a = scanOf([C("a.vol", "audio", "Output volume", "problem", "0%")]);
  const b = scanOf([C("a.vol", "audio", "Output volume", "ok", "62%")]);
  const d = M.diffScans(a, b);
  eq("problem -> ok is a change", true, d.changed);
  eq("the recovery is reported as better", 1, d.better.length);
  eq("nothing is reported as worse", 0, d.worse.length);
}

// ok and info are the same weight, so moving between them is NOT a transition.
{
  const a = scanOf([C("s.os", "system", "OS", "ok", "Omarchy")]);
  const b = scanOf([C("s.os", "system", "OS", "info", "Omarchy")]);
  eq("ok -> info is not a change", false, M.diffScans(a, b).changed);
}

// A check that appears or disappears is not a transition. A vanished check
// usually means a section stopped running, and calling that "fixed" would be
// the most misleading thing this feature could do.
{
  const a = scanOf([C("a.b", "audio", "Devices", "problem", "0")]);
  const b = scanOf([]);
  const d = M.diffScans(a, b);
  eq("a vanished check is not reported as resolved", 0, d.better.length);
  eq("a vanished check is not a worsening", 0, d.worse.length);
  eq("a vanished check counts as same", 1, d.same);
}
{
  const a = scanOf([]);
  const b = scanOf([C("a.b", "audio", "Devices", "problem", "0")]);
  eq("a newly appeared check is not a new issue", 0, M.diffScans(a, b).worse.length);
}

// No baseline means nothing can have changed. That is the first-scan case.
eq("no baseline is not a change", false,
  M.diffScans(null, scanOf([C("a", "audio", "x", "problem", "y")])).changed);
eq("no current scan is not a change", false,
  M.diffScans(scanOf([C("a", "audio", "x", "problem", "y")]), null).changed);
eq("two nulls are not a change", false, M.diffScans(null, null).changed);
eq("malformed scans do not fabricate a change", false,
  M.diffScans({}, { checks: "not an array" }).changed);
// A no-baseline diff must also be empty, not merely flagged unchanged, so a
// caller that reads .worse/.better cannot pick up a phantom.
eq("a no-baseline diff carries no transitions", "0/0",
  M.diffScans(null, scanOf([C("a", "audio", "x", "problem", "y")]))
    .worse.length + "/" + M.diffScans(null, null).better.length);

// Both directions at once, and worst-first ordering within each group.
{
  const a = scanOf([
    C("n.1", "network", "Gateway", "ok", "12 ms"),
    C("a.1", "audio", "Output volume", "ok", "62%"),
    C("s.1", "system", "Failed services", "attention", "1 failed"),
    C("d.1", "display", "Outputs", "ok", "2 active")
  ]);
  const b = scanOf([
    C("n.1", "network", "Gateway", "problem", "unreachable"),
    C("a.1", "audio", "Output volume", "ok", "62%"),
    C("s.1", "system", "Failed services", "problem", "2 failed"),
    C("d.1", "display", "Outputs", "ok", "2 active")
  ]);
  const d = M.diffScans(a, b);
  eq("mixed changes are detected", true, d.changed);
  eq("both worsenings are reported", 2, d.worse.length);
  // A problem outranks an attention in the same group.
  eq("worsenings are ordered worst-first", "problem", d.worse[0].to);
  eq("unchanged checks are counted", 2, d.same);
  eq("nothing improved", 0, d.better.length);
}

// Identical scans are the common case and must be completely silent.
{
  const same = scanOf([C("a", "audio", "x", "ok", "1"), C("b", "system", "y", "problem", "2")]);
  const d = M.diffScans(same, same);
  eq("an identical scan is not a change", false, d.changed);
  eq("an identical scan counts every check as same", 2, d.same);
}

// ------------------------------------------------------------ changeSummary
{
  const a = scanOf([C("n.1", "network", "Gateway", "ok", "12 ms")]);
  const b = scanOf([C("n.1", "network", "Gateway", "problem", "unreachable")]);
  const one = M.changeSummary(M.diffScans(a, b)) || "";
  if (/1 new issue/.test(one) && /Gateway/.test(one)) ok("a single new issue names the check");
  else fail("a single new issue names the check", one);
  if (/since the last scan/.test(one)) ok("the summary says since when");
  else fail("the summary says since when", one);

  const b2 = scanOf([C("n.1", "network", "Gateway", "ok", "12 ms")]);
  eq("a summary with nothing to say is null", null,
    M.changeSummary(M.diffScans(a, b2)));
  eq("a null diff has no summary", null, M.changeSummary(null));

  // Grammatical agreement matters in a user-facing line.
  const two = M.changeSummary(M.diffScans(
    scanOf([C("x", "audio", "x", "ok", ""), C("y", "system", "y", "ok", "")]),
    scanOf([C("x", "audio", "x", "problem", ""), C("y", "system", "y", "problem", "")])
  )) || "";
  if (/2 new issues/.test(two)) ok("several new issues are pluralised");
  else fail("several new issues are pluralised", two);

  const resolved = M.changeSummary(M.diffScans(
    scanOf([C("x", "audio", "x", "problem", "")]),
    scanOf([C("x", "audio", "x", "ok", "")])
  )) || "";
  if (/1 issue resolved/.test(resolved)) ok("a single resolution is singular");
  else fail("a single resolution is singular", resolved);

  // Both at once reads as a sentence, not as two fragments.
  const both = M.changeSummary(M.diffScans(
    scanOf([C("x", "audio", "x", "ok", ""), C("y", "system", "y", "problem", "")]),
    scanOf([C("x", "audio", "x", "problem", ""), C("y", "system", "y", "ok", "")])
  )) || "";
  if (both.indexOf("1 new issue") !== -1 && both.indexOf("1 issue resolved") !== -1) {
    ok("a mixed change reports both directions");
  } else {
    fail("a mixed change reports both directions", both);
  }
}

// ---------------------------------------------------------------- notifications
//
// The policy is the opposite of "if there is a problem, pop up a box". It
// notifies on a WORSENING TRANSITION, once, never on the first scan, and never
// for a scan the user asked for. Each of those rules exists because the obvious
// implementation gets it wrong:
//
//   * notify whenever there is a problem  -> the 30s timer re-notifies forever
//   * notify on the first scan             -> every shell start reports the
//                                            state the user has been living with
//   * notify after the user runs a scan   -> restating what is on screen
//
// These are asserted as a truth table because the interaction between the
// rules is where the bugs live.

// Rule 1: only a worsening transition speaks.
eq("healthy -> attention notifies", true,
  M.shouldNotify("ok", "attention", {}));
eq("attention -> problem notifies", true,
  M.shouldNotify("attention", "problem", {}));
eq("ok -> problem notifies", true,
  M.shouldNotify("ok", "problem", {}));

// Rule 1 (negative): recovery and healthy are silent.
eq("problem -> attention does not notify", false,
  M.shouldNotify("problem", "attention", {}));
eq("problem -> ok does not notify", false,
  M.shouldNotify("problem", "ok", {}));
eq("attention -> ok does not notify", false,
  M.shouldNotify("attention", "ok", {}));
eq("ok -> ok does not notify", false,
  M.shouldNotify("ok", "ok", {}));
// info is weight 0, the same as ok, so neither direction is news.
eq("ok -> info does not notify", false,
  M.shouldNotify("ok", "info", {}));
eq("info -> ok does not notify", false,
  M.shouldNotify("info", "ok", {}));

// Rule 2: an unchanged problem is not news. Without this, a machine that stays
// broken re-notifies every poll cycle until the user ignores the panel.
eq("problem -> problem does not re-notify", false,
  M.shouldNotify("problem", "problem", {}));
eq("attention -> attention does not re-notify", false,
  M.shouldNotify("attention", "attention", {}));

// Rule 3: no baseline, no notification.
//
// Rule 3 has NO code path of its own -- it falls out of the weight comparison,
// because weight() degrades an absent or unknown state to "problem" (3), the
// maximum, so nothing can be worse than "no baseline". An explicit
// `if (!prevState) return false` was tried and deleted: removing it changed no
// behaviour, so the guard was untestable decoration.
//
// That makes Rule 3 a DEPENDENCY on weight()'s degradation rather than on its
// own line of code. So the dependency is pinned here instead: if normStatus or
// weight ever stops degrading to the maximum, these go red BEFORE the shell
// start notifications appear.
eq("an absent baseline weighs the maximum", 3, M.weight(null));
eq("an undefined baseline weighs the maximum", 3, M.weight(undefined));
eq("an empty baseline weighs the maximum", 3, M.weight(""));
eq("an unrecognised baseline weighs the maximum", 3, M.weight("banana"));
// This is the load-bearing one. If normStatus ever defaults to "ok" instead of
// "problem", weight(null) becomes 0 and every shell start announces whatever
// the first scan finds.
eq("an absent baseline is treated as a problem, not as healthy", "problem",
  M.normStatus(null));

eq("the first scan never notifies", false,
  M.shouldNotify(null, "problem", {}));
eq("an undefined baseline never notifies", false,
  M.shouldNotify(undefined, "problem", {}));
eq("an empty baseline never notifies", false,
  M.shouldNotify("", "problem", {}));

// Belt and braces: the first scan must be silent for EVERY possible next state,
// whatever the first scan finds.
{
  let spoke = [];
  for (const missing of [null, undefined, ""]) {
    for (const next of ["ok", "info", "attention", "problem"]) {
      if (M.shouldNotify(missing, next, {}) === true) spoke.push(`${missing}->${next}`);
    }
  }
  if (spoke.length === 0) ok("first scan is silent for every possible next state");
  else fail("first scan is silent for every possible next state", spoke.join(", "));
}

// Rule 4: a scan the user asked for is silent, whatever it finds.
eq("a user-initiated scan never notifies", false,
  M.shouldNotify("ok", "problem", { userInitiated: true }));
eq("a user-initiated worsening still does not notify", false,
  M.shouldNotify("attention", "problem", { userInitiated: true }));

// A missing opts object is tolerated.
eq("a background scan does notify on a real transition", true,
  M.shouldNotify("ok", "problem", { userInitiated: false }));
eq("a missing opts object is tolerated", true,
  M.shouldNotify("ok", "attention"));

// ------------------------------------------- whole sequences, as the panel runs
//
// shouldNotify is called with the PREVIOUS state and the baseline is then
// advanced unconditionally -- exactly what Panel.qml does. Asserting single
// pairs is not enough, because a policy can pass every pair and still
// misbehave in sequence: the empty starting baseline weighs the MAXIMUM (see
// above), so the whole design depends on that baseline being replaced after
// the first scan. These sequences are what prove it actually is.
{
  function run(seq) {
    let prev = "";
    const fired = [];
    for (const next of seq) {
      if (M.shouldNotify(prev, next, {})) fired.push(next);
      prev = next;
    }
    return fired;
  }
  eq("a healthy machine never notifies", [], run(["ok", "ok", "ok", "ok"]));
  eq("breaking a healthy machine notifies exactly once",
    ["problem"], run(["ok", "problem", "problem", "problem"]));
  eq("a machine already broken at login stays silent",
    [], run(["problem", "problem", "problem"]));
  eq("recovery is silent but a later relapse notifies again",
    ["problem", "problem"], run(["ok", "problem", "ok", "ok", "problem"]));
  // ok -> attention and then attention -> problem are TWO distinct
  // worsenings, so both speak: the brief asks for "attention once" AND
  // "critical immediately". Suppressing the second would be wrong -- the
  // machine got worse, and that is exactly the moment worth surfacing.
  eq("attention then problem notifies on each step",
    ["attention", "problem"], run(["ok", "attention", "problem", "problem"]));
  eq("a problem that only ever improves notifies once",
    ["problem"], run(["ok", "problem", "attention", "ok"]));
}

// An unrecognised state must not be treated as the quiet one, or a malformed
// scan would be able to announce itself as an improvement. normStatus degrades
// an unknown value to "problem" (weight 3), so an unknown previous state is
// already the loudest thing there is and nothing can be worse than it: stay
// silent. The mirror case is the one that matters -- an unknown NEXT state must
// not read as "recovered".
eq("an unrecognised previous state gates a notification", false,
  M.shouldNotify("banana", "problem", {}));
eq("an unrecognised next state does not announce an improvement", false,
  M.shouldNotify("problem", "banana", {}));

// ------------------------------------------------------- notification text

const notifScan = M.parseDoctor(JSON.stringify({
  mode: "quick", ts: 1700000000,
  checks: [
    { id: "s.ok", category: "system", title: "OS", status: "ok", severity: 0, value: "Omarchy" },
    { id: "n.1", category: "network", title: "Gateway", status: "attention", severity: 1, value: "182 ms" },
    { id: "a.1", category: "audio", title: "Volume", status: "problem", severity: 3, value: "0%" }
  ]
}));
const notifText = M.notificationText(notifScan);
// Categories come out in the machine-shape order (byCategory's order array
// puts network before audio), NOT severity order. That is deliberate and
// consistent with the panel, so a notification and the panel list the same
// categories in the same sequence -- seeing one order on the notification and
// another in the panel would be worse than either.
if (notifText && notifText.indexOf("NETWORK, AUDIO") !== -1) {
  ok("notification names the affected categories in panel order");
} else {
  fail("notification names the affected categories in panel order", String(notifText));
}
if (notifText && notifText.indexOf("problem") !== -1) ok("notification says how bad it is");
else fail("notification says how bad it is", String(notifText));
if (notifText && /detail/.test(notifText)) ok("notification points at the panel for detail");
else fail("notification points at the panel for detail", String(notifText));

// A clean scan has nothing to say, and a notification saying so would be noise.
const cleanNotifScan = M.parseDoctor(JSON.stringify({
  mode: "quick", ts: 1700000000,
  checks: [{ id: "s.ok", category: "system", title: "OS", status: "ok", severity: 0, value: "Omarchy" }]
}));
eq("a clean scan produces no notification text", null, M.notificationText(cleanNotifScan));
eq("a null scan produces no notification text", null, M.notificationText(null));
eq("a scan with no checks produces no notification text", null, M.notificationText({ checks: [] }));

// Many affected categories must be summarised, not dumped -- a notification is
// one glance, and the panel has the detail.
const manyNotif = M.parseDoctor(JSON.stringify({
  mode: "quick", ts: 1700000000,
  checks: [
    { id: "a", category: "network", title: "n", status: "attention", severity: 1, value: "x" },
    { id: "b", category: "audio", title: "a", status: "attention", severity: 1, value: "x" },
    { id: "c", category: "storage", title: "s", status: "attention", severity: 1, value: "x" },
    { id: "d", category: "hyprland", title: "h", status: "attention", severity: 1, value: "x" },
    { id: "e", category: "services", title: "v", status: "attention", severity: 1, value: "x" }
  ]
}));
const manyNotifText = M.notificationText(manyNotif) || "";
if (/\+2/.test(manyNotifText)) ok("a notification summarises more than three categories");
else fail("a notification summarises more than three categories", manyNotifText);

// --------------------------------------------------- optional details + repair
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

// ------------------------------------------------- summaryLine / breakdownLine

// The panel's all-clear copy is generated from these, so they must reflect the
// real tally and never invent a reassuring number.

eq("summaryLine is empty for an empty scan", "",
  M.summaryLine(M.counts([])));
eq("summaryLine singular for one passing check", "1 check passed",
  M.summaryLine(M.counts([{ status: "ok" }])));
eq("summaryLine plural for many passing checks", "34 checks passed",
  M.summaryLine(M.counts(Array(34).fill({ status: "ok" }))));
eq("summaryLine counts info as healthy when nothing needs review",
  "3 checks passed",
  M.summaryLine(M.counts([
    { status: "ok" }, { status: "info" }, { status: "info" }
  ])));
eq("summaryLine names the review count when something needs attention",
  "3 of 5 checks fine, 2 to review",
  M.summaryLine(M.counts([
    { status: "ok" }, { status: "ok" }, { status: "ok" },
    { status: "attention" }, { status: "problem" }
  ])));

// Accepts a raw check list directly, so a caller cannot silently hand it the
// wrong shape and get a believable "0 checks" line.
eq("summaryLine accepts a raw check list", "2 checks passed",
  M.summaryLine([{ status: "ok" }, { status: "ok" }]));

// A malformed argument must degrade to the empty scan, never to a fabricated
// pass. This is the "unknown must never read as healthy" rule.
eq("summaryLine rejects a malformed argument", "",
  M.summaryLine({ ok: "lots" }));
eq("summaryLine rejects null", "", M.summaryLine(null));

eq("breakdownLine is empty for an empty scan", "",
  M.breakdownLine(M.counts([])));
eq("breakdownLine lists only non-zero buckets", "34 ok  ·  2 info",
  M.breakdownLine(M.counts([
    ...Array(34).fill({ status: "ok" }),
    { status: "info" }, { status: "info" }
  ])));
eq("breakdownLine keeps a fixed bucket order regardless of input order",
  "1 ok  ·  1 attention  ·  1 problem",
  M.breakdownLine(M.counts([
    { status: "problem" }, { status: "ok" }, { status: "attention" }
  ])));
eq("breakdownLine accepts a raw check list", "1 problem",
  M.breakdownLine([{ status: "problem" }]));
eq("breakdownLine rejects a malformed argument", "",
  M.breakdownLine({ ok: {} }));

// ------------------------------------------------------------------- summary

console.log("1.." + checks);
if (fails > 0) {
  console.log("# " + fails + " of " + checks + " checks failed");
  process.exit(1);
} else {
  console.log("# all " + checks + " checks passed");
}