// OmaDoctor data parsing, health roll-up, redaction and report rendering.
// Pure JS with no QML dependency so the whole thing is unit-testable under
// node (see tests/model-tests.js).
//
// Input is always the JSON emitted by backend/doctor.sh.

//.pragma library

// ------------------------------------------------------------------ parsing

// parseDoctor(text) -> scan object, or null when the payload is unusable.
//
// Returns null rather than a partially-populated object: a malformed scan must
// leave the UI showing its last known good state, never a half-rendered one.
function parseDoctor(text) {
  if (typeof text !== "string" || text.length === 0) return null
  var raw
  try {
    raw = JSON.parse(text)
  } catch (e) {
    return null
  }
  if (!raw || typeof raw !== "object" || !Array.isArray(raw.checks)) return null

  // Normalise every field so the UI never has to guard against missing data.
  var checks = []
  for (var i = 0; i < raw.checks.length; i++) {
    checks.push(normCheck(raw.checks[i]))
  }

  return {
    // mode is validated, not merely stringified. The report prints "quick
    // (local only)" for anything that is not exactly "full", so an
    // unrecognised value made the document state a scope it did not have while
    // still listing NETWORK findings underneath it.
    mode: raw.mode === "full" ? "full" : "quick",
    version: str(raw.version),
    ts: num(raw.ts),
    sections: str(raw.sections),
    checks: checks
  }
}

// str(v) -> a string, or "" for anything that has no sensible string form.
//
// The guard is not cosmetic. `String(obj)` THROWS "Cannot convert object to
// primitive value" when the object carries a non-callable own toString, and JSON
// can express exactly that: {"status":{"toString":"ok"}} parses fine and then
// detonates inside String(). JSON.parse was guarded but the coercion that
// followed it was not, so a malformed field threw straight through
// Panel.qml's onStreamFinished.
//
// The policy is also consistent with strArray(): "[object Object]" in a
// diagnostic report is worse than an absent line.
// normCheck(raw) -> a fully normalised check.
//
// The ONE definition of what a check is. parseDoctor applies it to a decoded
// document and buildReport applies it again to anything handed to it directly,
// so a check is guaranteed to have a string id/category/title/value/detail/
// suggestion, a valid status, a numeric severity, a details array and either a
// normalised repair or null -- no caller needs its own guard, and no field can
// throw at the point of use.
function normCheck(raw) {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) raw = {}
  return {
    id: str(raw.id),
    category: str(raw.category) || "system",
    title: str(raw.title),
    status: normStatus(raw.status),
    severity: num(raw.severity),
    value: str(raw.value),
    detail: str(raw.detail),
    suggestion: str(raw.suggestion),
    // Both of these are OPTIONAL and purely additive: a check that does not
    // carry them normalises to an empty list / null, so existing producers
    // and renderers keep working untouched.
    details: strArray(raw.details),
    repair: normRepair(raw.repair)
  }
}

function str(v) {
  if (v === undefined || v === null) return ""
  var t = typeof v
  if (t === "string") return v
  if (t === "number") return isFinite(v) ? String(v) : ""
  if (t === "boolean") return v ? "true" : "false"
  return ""
}

function num(v) {
  var n = Number(v)
  return isFinite(n) ? n : 0
}

// normStatus(s) -> one of ok | info | attention | problem.
//
// Fails CLOSED: anything unrecognised, and anything that is not a plain string,
// becomes "problem". A malformed producer must not be able to make a finding
// disappear by shipping a status the parser has never heard of.
function normStatus(s) {
  if (typeof s !== "string") return "problem"
  var t = s.trim().toLowerCase()
  if (t === "ok" || t === "info" || t === "attention" || t === "problem") return t
  return "problem"
}

// strArray(v) -> a list of strings, never null.
//
// Accepts an array or a single scalar (coerced to one element) so a producer
// may emit either. Non-string, non-scalar entries are dropped rather than
// stringified -- "[object Object]" in a diagnostic report is worse than an
// absent line.
function strArray(v) {
  if (v === undefined || v === null || v === "") return []
  var raw = Array.isArray(v) ? v : [v]
  var out = []
  for (var i = 0; i < raw.length; i++) {
    var e = raw[i]
    if (e === undefined || e === null) continue
    if (typeof e === "object" || typeof e === "function") continue
    var s = str(e)
    if (s !== "") out.push(s)
  }
  return out
}

// normRepair(v) -> null, or a repair descriptor { tier, label, detail }.
//
// DESCRIPTIVE ONLY. Nothing in this file (or the plugin) ever executes a
// repair; OmaDoctor is read-only by design. The descriptor exists so a finding
// can say what a fix WOULD be, and so a future repair phase has a defined
// place to hang real affordances.
//
// "tier" is one of safe | caution | manual. An unrecognised or missing tier
// degrades to "manual" -- the most dangerous tier -- for the same reason
// normStatus never degrades to "ok": an unknown value must never be treated as
// the reassuring one.
function normRepair(v) {
  if (!v || typeof v !== "object" || Array.isArray(v)) return null
  var label = str(v.label)
  var tier = str(v.tier).toLowerCase()
  if (tier !== "safe" && tier !== "caution" && tier !== "manual") tier = "manual"
  // A repair with no label says nothing useful, so it is not a repair.
  if (label === "") return null
  return {
    tier: tier,
    label: label,
    detail: str(v.detail)
  }
}

// ------------------------------------------------------------- health roll-up

// severity weight per status. The weights are internal only -- they are never
// surfaced to the user as a number.
function weight(status) {
  switch (normStatus(status)) {
    case "problem": return 3
    case "attention": return 1
    default: return 0
  }
}

// checkWeight(check) -> the weight of one check, in 0..3.
//
// `severity` is the producer's OWN ranking and is authoritative when it is a
// recognised value; the status is the fallback. Before this existed, severity
// was parsed, round-tripped by the test suite as "a number", and then read by
// nothing at all -- so {"status":"ok","severity":3} counted as healthy and
// {"status":"problem","severity":0} counted as a problem. A field that is
// documented in the check contract and pinned by a test, but inert, is worse
// than an absent one: it looks like it is doing something.
//
// A producer that disagrees with itself is treated as the more serious of the
// two. That is the fail-closed direction, and it is consistent with
// normStatus, which turns an unrecognised status into "problem" rather than
// "ok".
function checkWeight(check) {
  if (!check || typeof check !== "object") return 3
  var byStatus = weight(check.status)
  var sev = num(check.severity)
  // Only 1 and 3 carry meaning: 0 is the default for a producer that does not
  // rank at all, and any other value is not a rank this code understands.
  if (sev !== 1 && sev !== 3) return byStatus
  var bySeverity = sev === 3 ? 3 : 1
  return bySeverity > byStatus ? bySeverity : byStatus
}

// overallState(checks) -> "ok" | "attention" | "problem"
//
// Worst-wins. A single problem check makes the whole scan a problem, because a
// single unreadable thing is more actionable than an averaged score.
// ------------------------------------------------------------- what changed
//
// diffScans(before, after) -> the HEALTH transitions between two scans.
//
// Why not diff the values? Because almost every value moves on every scan:
// uptime ticks, latency jitters, memory drifts, pending-update counts shift.
// Reporting those would mean a "what changed" line that always has something
// in it, which is the same noise problem as a chatty notification.
//
// So only the STATUS of each check is compared, by id. A check that went from
// healthy to broken, or broken to healthy, is news. A check whose reading moved
// while its status held is not -- and that distinction is exactly what makes
// this usable at a glance.
//
// Returns { changed: bool, worse: [], better: [], same: n }.
//   worse  - ok/info -> attention/problem
//   better - problem/attention -> ok/info
//   same   - how many checks kept their status (including brand-new and removed
//            ids, which are not transitions and are counted here)
//
// before/after may be anything parseDoctor accepts; a null or malformed side
// yields changed:false, never a fabricated transition.
function diffScans(before, after) {
  var out = { changed: false, worse: [], better: [], same: 0 }
  var b = (before && Array.isArray(before.checks)) ? before : null
  var a = (after && Array.isArray(after.checks)) ? after : null
  // With no baseline there is nothing to have changed FROM. That is the honest
  // answer on the first scan, not "everything changed".
  if (!b || !a) return out

  // hasOwnProperty, not truthiness: `seen[id] = true` is a silent no-op for an
  // id of "__proto__" (the inherited setter) and an unrecorded own shadow for
  // "toString", so the removal loop below read an inherited truthy value,
  // skipped its increment, and undercounted `same`.
  var seen = Object.create(null)
  for (var i = 0; i < a.checks.length; i++) {
    var now = a.checks[i]
    var id = str(now.id)
    seen[id] = true
    var then = findCheck(b.checks, id)
    if (!then) { out.same++; continue }
    var beforeW = checkWeight(then)
    var afterW = checkWeight(now)
    if (beforeW === afterW) { out.same++; continue }
    var entry = {
      id: id,
      category: str(now.category) || str(then.category) || "system",
      title: str(now.title) || str(then.title),
      from: normStatus(then.status),
      to: normStatus(now.status),
      // The current reading is what the user needs to see; the old one is
      // usually noise ("4 problems" -> "3 problems").
      value: str(now.value)
    }
    if (afterW > beforeW) out.worse.push(entry)
    else out.better.push(entry)
  }

  // A check that existed before and is gone now is not a transition -- it is a
  // check that stopped running (a section failed, or a tool vanished). Count it
  // as unchanged so a section going silent is never reported as "fixed".
  //
  // hasOwnProperty, not truthiness: `seen[id] = true` is a silent no-op for an
  // id of "__proto__" (inherited setter) and an unrecorded own shadow for
  // "toString" and friends, so the truthiness test below read an INHERITED
  // value, skipped its increment, and undercounted `same`.
  for (var j = 0; j < b.checks.length; j++) {
    var oldId = str(b.checks[j].id)
    if (!Object.prototype.hasOwnProperty.call(seen, oldId)) out.same++
  }

  // Worst-first within each group, so the panel can render straight through.
  out.worse.sort(function (x, y) {
    return weight(y.to) - weight(x.to) || String(x.category).localeCompare(String(y.category))
  })
  out.better.sort(function (x, y) {
    return weight(x.to) - weight(y.to) || String(x.category).localeCompare(String(y.category))
  })
  out.changed = out.worse.length > 0 || out.better.length > 0
  return out
}

// changeSummary(diff) -> one line describing what changed, or null.
//
// The "what changed?" feature reduced to a sentence, so it can sit under the
// panel header or in the report without the reader having to parse structure.
function changeSummary(diff) {
  if (!diff || !diff.changed) return null
  var parts = []
  if (diff.worse.length > 0) {
    parts.push(diff.worse.length === 1
      ? "1 new issue (" + str(diff.worse[0].title) + ")"
      : diff.worse.length + " new issues")
  }
  if (diff.better.length > 0) {
    parts.push(diff.better.length === 1
      ? "1 issue resolved"
      : diff.better.length + " issues resolved")
  }
  return parts.join(", ") + " since the last scan"
}

function overallState(checks) {
  // An EMPTY scan is NOT healthy. It means the producer produced no findings,
  // which is indistinguishable at this layer from a machine with nothing wrong
  // with it -- and doctor.sh documents the opposite invariant ("a missing check
  // must never be mistaken for a healthy one"). Returning "ok" here made the
  // panel read HEALTHY, suppressed the notification, and produced a report
  // saying "Nothing needs attention" for a scan that had checked nothing.
  //
  // "problem" is the fail-closed answer, and weight("problem") is the maximum,
  // so an empty first scan still cannot notify (see shouldNotify Rule 3).
  if (!Array.isArray(checks) || checks.length === 0) return "problem"
  var worst = 0
  var seenAny = false
  for (var i = 0; i < checks.length; i++) {
    var c = checks[i]
    if (!c || typeof c !== "object") continue
    seenAny = true
    var w = checkWeight(c)
    if (w > worst) worst = w
  }
  // Every element was null or a non-object: nothing was actually inspected.
  if (!seenAny) return "problem"
  return worst >= 3 ? "problem" : worst >= 1 ? "attention" : "ok"
}
// ------------------------------------------------------------- notifications
//
// The policy lives here, not in Panel.qml, so it is unit-testable. A
// notification rule that can only be verified by waiting for something to go
// wrong on a real machine is a rule that ships broken.
//
// The four rules, in priority order:
//
//   1. Only a WORSENING transition notifies. Healthy is silent, and so is
//      recovery: a panel that congratulates you for fixing a problem you
//      already knew about is noise. (Design brief: "Healthy -> no
//      notification, Attention -> once, Critical -> immediately".)
//   2. Only ONCE per state. The quick scan runs on a timer, so a machine that
//      stays broken would otherwise notify every thirty seconds until the
//      user turned the panel off. Repeating an unacknowledged warning trains
//      people to ignore the one that mattered.
//   3. Never on the FIRST scan. A baseline is not a transition. Without this,
//      every shell start would notify about whatever was already wrong --
//      which is precisely the state the user has been living with, not news.
//      NOTE: this is NOT a separate code path. It falls out of the weight
//      comparison, because weight() degrades an absent/unknown state through
//      normStatus to "problem" (3) -- the maximum -- so nothing can be worse
//      than "no baseline" and Rule 2 rejects every first scan. That makes Rule
//      3 dependent on a property of weight(), which tests/model-tests.js pins
//      explicitly. Do not "simplify" normStatus to default to "ok": that
//      silently turns every shell start into a notification.
//   4. Never for a scan the USER asked for. If they just ran a full diagnosis,
//      they are looking at the result; a notification restating it is noise.
//
// opts.userInitiated  the user triggered this scan (panel action, IPC call)
// opts.prevState      the state BEFORE this scan; falsy on the first scan
//
// Returns true only when a notification should fire now.
function shouldNotify(prevState, nextState, opts) {
  var o = opts || {}
  // Rule 4: they just asked; they can see it.
  if (o.userInitiated) return false
  var before = weight(prevState)
  var after = weight(nextState)
  // Rule 2: same or lower weight. Equal covers "problem stays problem", which
  // is the common case on a machine that is simply broken.
  if (after <= before) return false
  // Rule 1: recovery and healthy are silent (both have weight 0 or lower).
  return true
}

// notificationText(scan) -> the notification body, or null when there is
// nothing worth saying.
//
// Separate from shouldNotify so the content is testable on its own: a correct
// policy with an unreadable message is still a broken notification.
function notificationText(scan) {
  if (!scan || !Array.isArray(scan.checks)) return null
  var found = issues(scan.checks)
  if (found.length === 0) return null

  // Name the categories, worst first, rather than listing individual checks:
  // a notification is one glance, and the panel has the detail.
  var cats = byCategory(scan.checks)
  var names = []
  for (var i = 0; i < cats.length; i++) {
    if (cats[i].issueCount > 0) names.push(String(cats[i].category).toUpperCase())
  }
  if (names.length === 0) return null

  var worst = weight(overallState(scan.checks)) >= 3 ? "problem" : "needs attention"
  var where = names.length <= 3
    ? names.join(", ")
    : names.slice(0, 3).join(", ") + " +" + (names.length - 3)
  return where + " " + worst + " -- " + found.length +
    (found.length === 1 ? " check to review" : " checks to review") +
    ". Click the icon for detail."
}
// eachReal(checks) -> the elements that are usable check objects.
//
// Every aggregation helper funnels through this. Two crashes came from not
// doing so: a null element made counts([null]), issues([null]) and
// overallState([null]) throw "Cannot read properties of null", and these
// functions are exported, so a caller that filtered nothing -- or a document
// from a producer that emitted a literal null -- took the panel's hot path down
// with it. A non-object element carries no status, so it is not a check and is
// simply not counted.
function eachReal(checks) {
  var out = []
  if (!Array.isArray(checks)) return out
  for (var i = 0; i < checks.length; i++) {
    var c = checks[i]
    if (c && typeof c === "object") out.push(c)
  }
  return out
}

// issues(checks) -> the checks a user should act on, worst first.
function issues(checks) {
  var list = eachReal(checks)
  var out = []
  for (var i = 0; i < list.length; i++) {
    if (checkWeight(list[i]) > 0) out.push(list[i])
  }
  out.sort(function (a, b) {
    var d = checkWeight(b) - checkWeight(a)
    return d !== 0 ? d : String(a.category).localeCompare(String(b.category))
  })
  return out
}

// counts(checks) -> { ok, info, attention, problem, total }
//
// Buckets by checkWeight, the SAME rule overallState, byCategory and the report
// header use, so severity wins when a producer contradicts itself. Bucketing on
// status alone made the summary read "1 check passed" for a scan the report
// called PROBLEM and the findings list rendered as a failure -- one scan, three
// verdicts. A recognised severity of 1 or 3 now moves the bucket in the more
// serious direction, exactly as it already does everywhere else.
function counts(checks) {
  var c = { ok: 0, info: 0, attention: 0, problem: 0, total: 0 }
  var list = eachReal(checks)
  for (var i = 0; i < list.length; i++) {
    var chk = list[i]
    var s = normStatus(chk.status)
    var w = checkWeight(chk)
    if (w >= 3) s = "problem"
    else if (w >= 1) s = "attention"
    c[s]++
    c.total++
  }
  return c
}

// summaryLine(counts) -> the headline for a scan that has nothing to report.
//
// Deliberately not a score. A "34/34" style ratio reads as a grade and implies
// that 33/34 would be a failure, which is a different claim from "nothing here
// needs attention". This says exactly what is true: how many checks ran, and how
// many of them are fine. Returns "" when there is nothing to say, so a caller
// can bind it straight to a Text and let an empty string hide the row.
//
// Accepts either a counts() object or a raw check list, so it cannot be handed
// something it silently misreads: a list is counted first.
function summaryLine(countsOrChecks) {
  var c = asCounts(countsOrChecks)
  if (c.total === 0) return ""
  var healthy = c.ok + c.info
  if (c.attention === 0 && c.problem === 0) {
    return c.total + (c.total === 1 ? " check passed" : " checks passed")
  }
  // Something needs review: name the clean part and the rest, rather than
  // rounding the whole scan up to a number that looks like a grade.
  return healthy + " of " + c.total + " checks fine, " +
    (c.attention + c.problem) + " to review"
}

// breakdownLine(counts) -> a compact "ok 34 · info 2 · attention 1" style summary.
//
// Only non-zero buckets appear, so a healthy machine gets one short clause
// instead of a row of zeroes. Returns "" for an empty scan. Bucket order is
// fixed (ok, info, attention, problem) so the line does not reshuffle between
// scans as counts move.
function breakdownLine(countsOrChecks) {
  var c = asCounts(countsOrChecks)
  if (c.total === 0) return ""
  var parts = []
  var order = ["ok", "info", "attention", "problem"]
  for (var i = 0; i < order.length; i++) {
    var n = c[order[i]]
    if (n > 0) parts.push(n + " " + order[i])
  }
  return parts.join("  ·  ")
}

// asCounts(v) -> a counts() object, whether handed one or a list of checks.
//
// Keeping this coercion in one place means summaryLine/breakdownLine cannot be
// called with the wrong shape by accident -- the failure mode of a helper that
// assumes its argument is already aggregated is a silent "0 checks" that looks
// like a real empty scan.
function asCounts(v) {
  if (Array.isArray(v)) return counts(v)
  if (!v || typeof v !== "object") return counts([])
  var c = counts([])
  c.ok = num(v.ok)
  c.info = num(v.info)
  c.attention = num(v.attention)
  c.problem = num(v.problem)
  c.total = num(v.total)
  return c
}

// byCategory(checks) -> ordered array of { category, checks, state }
// Categories keep a stable order so the panel does not reshuffle between scans.
function byCategory(checks) {
  // The order is the machine's shape, not alphabetical: what you are, then what
  // it is connected to, then what makes noise. Any category not listed here
  // sorts last, then alphabetically, so a new section appears predictably
  // without needing a line added here first.
  var order = ["system", "services", "hyprland", "display", "network", "audio",
               "storage", "bluetooth", "boot"],
    seen = Object.create(null), buckets = []
  var list = eachReal(checks)
  if (!Array.isArray(checks)) return buckets

  for (var i = 0; i < list.length; i++) {
    var cat = str(list[i].category) || "system"
    // A bare {} has Object.prototype in its chain, so for a category named
    // "toString", "constructor", "__proto__" and friends, seen[cat] is an
    // INHERITED truthy value: the bucket is never created and seen[cat].checks
    // is undefined, so the push below throws. parseDoctor normalises the
    // category straight through, so this was reachable from a document and
    // crashed byCategory -- which is on the panel's hot path, in
    // notificationText and in buildReport. Object.create(null) gives the map a
    // null prototype, so only real keys are ever found.
    if (!Object.prototype.hasOwnProperty.call(seen, cat)) {
      seen[cat] = { category: cat, checks: [] }
      buckets.push(seen[cat])
    }
    seen[cat].checks.push(list[i])
  }

  buckets.sort(function (a, b) {
    var ia = order.indexOf(a.category), ib = order.indexOf(b.category)
    if (ia === -1) ia = order.length
    if (ib === -1) ib = order.length
    if (ia !== ib) return ia - ib
    return String(a.category).localeCompare(String(b.category))
  })

  for (var j = 0; j < buckets.length; j++) {
    buckets[j].state = overallState(buckets[j].checks)
    buckets[j].issueCount = issues(buckets[j].checks).length
  }
  return buckets
}

// findCheck(checks, id) -> the matching check, or null.
function findCheck(checks, id) {
  var list = eachReal(checks)
  var want = str(id)
  for (var i = 0; i < list.length; i++) {
    if (str(list[i].id) === want) return list[i]
  }
  return null
}

// ------------------------------------------------------------- display rows

// findingRows(checks) -> a FLAT list of rows for the panel to render.
//
// Each entry is { kind: "header", category } or { kind: "check", check }.
//
// Flat rather than nested on purpose. A QML Repeater nested inside another
// Repeater's delegate does not reliably see the outer delegate's modelData,
// which silently produced category headers with no rows under them. One flat
// list, one Repeater, no scoping to get wrong -- and it is testable here
// rather than only on screen.
//
// Categories with nothing to report are omitted entirely, so the panel never
// shows a heading above an empty list.
function findingRows(checks) {
  var rows = []
  var buckets = byCategory(checks)
  for (var i = 0; i < buckets.length; i++) {
    var found = issues(buckets[i].checks)
    if (found.length === 0) continue
    rows.push({ kind: "header", category: str(buckets[i].category).toUpperCase() })
    for (var j = 0; j < found.length; j++) {
      rows.push({ kind: "check", check: found[j] })
    }
  }
  return rows
}

// ------------------------------------------------------------------ formatting

// fmtAge(tsSeconds, nowSeconds) -> human relative age, e.g. "3m ago".
function fmtAge(ts, now) {
  var t = num(ts), n = num(now)
  if (t <= 0) return "never"
  var d = Math.floor(n - t)
  if (d < 0) return "just now"
  if (d < 60) return d + "s ago"
  if (d < 3600) return Math.floor(d / 60) + "m ago"
  if (d < 86400) return Math.floor(d / 3600) + "h ago"
  return Math.floor(d / 86400) + "d ago"
}

// glyph(status) -> a nerd-font glyph for the check row.
function glyph(status) {
  switch (normStatus(status)) {
    case "problem": return "󰅚"   // heavy cross
    case "attention": return "󰗖" // warning
    case "info": return "󰋝"     // info
    default: return "󰄬"         // check
  }
}

// stateLabel(state) -> the headline word for the overall state.
function stateLabel(state) {
  switch (normStatus(state)) {
    case "problem": return "PROBLEM"
    case "attention": return "ATTENTION"
    default: return "HEALTHY"
  }
}

// ------------------------------------------------------------------- redaction

// redact(text, opts) -> text safe to paste into a public bug report.
//
// Defaults to redacting on. The report is the main way a user's machine details
// leave their machine, so the safe behaviour is the default behaviour.
//
// Order matters. MACs go before IPv6 (whose hex groups would otherwise look
// similar), IPv4-embedded IPv6 before bare IPv6, IPv6 before IPv4, and the
// filesystem paths before the bare username (otherwise /home/<user> is
// rewritten first and o.home never matches).
//
// Escape hatch: redact(text, { raw: true }) returns the text untouched. It
// exists for the "review before copying" path, never for the clipboard.
function redact(text, opts) {
  var o = opts || {}
  if (o.raw === true) return String(text === undefined || text === null ? "" : text)

  var s = String(text === undefined || text === null ? "" : text)
  if (!s) return s

  // ------------------------------------------- storage identifiers FIRST
  // These run before the MAC rules because a UUID and a volume serial are full
  // of hex that the separator-based MAC patterns also match: masking the MACs
  // first turned "/mnt/3f8a1c2e-7d4b-4e6a-9b3c-2a5f0e8d7c11" into
  // "/mnt/<volume><uuid>b4cd-<mac>", which is both wrong and no less revealing.
  //
  // A filesystem UUID or a disk serial is a stable hardware fingerprint, and on
  // a typical Omarchy box the two mounted data volumes are named by exactly
  // these.
  s = s.replace(/\/mnt\/[A-Za-z0-9._-]+/g, "/mnt/<volume>");
  s = s.replace(/\/media\/[A-Za-z0-9._-]+/g, "/media/<volume>");
  s = s.replace(/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/g, "<uuid>");
  // Truncated or malformed UUIDs: mask the WHOLE token rather than only the
  // middle all-digit group. The old form left the first two groups (12 hex
  // chars, the bulk of the fingerprint) in clear, so a shortened id published
  // publicly was barely redacted at all.
  s = s.replace(/\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4,}/g, "<uuid>");
  // 16 hex digits, upper- or lowercase, is the NTFS/volume-serial convention;
  // an explicit "serial" label covers hdparm/lsblk/udev output in any width.
  s = s.replace(/\b([0-9A-Fa-f]{16})\b/g, "<serial>");
  // An explicit "serial" label. Two forms, because they are genuinely
  // different in practice: with punctuation (hdparm "serial: X", udev
  // "SERIAL=X") the label is unambiguous; without it (prose "serial X") the
  // word "serial" also appears in phrases like "serial number is not shown",
  // so the value must additionally look like a serial -- six characters or
  // more AND containing a digit -- before it is treated as one.
  s = s.replace(
    /\b(serials?(?:\s+number)?|serial_number)(\s*[:=]\s*)"?[A-Za-z0-9_-]{4,}"?/gi,
    function (m, label, sep) { return label + sep + "<serial>"; }
  );
  s = s.replace(/\bserial\s+([A-Za-z0-9][A-Za-z0-9_-]{5,})\b/gi, function (m, value) {
    return /\d/.test(value) ? "serial <serial>" : m;
  });

  // ---------------------------------------------------------------- MAC
  // Six separator conventions are in real use: ip/udev/bluetoothctl print the
  // Cisco form aabb.ccdd.eeff, some tools print aa.bb.cc.dd.ee.ff, sysfs
  // exposes a bare 12-hex perm_address, and underscore separators appear in
  // config files. Only the colon and dash forms were handled before, so the
  // others reached a public issue untouched.
  //
  // The bare 12-hex rule is deliberately greedy. It will occasionally mask a
  // non-MAC token, which costs a little detail; masking too little costs
  // privacy in a document whose entire purpose is to be pasted to strangers.
  s = s.replace(/\b[0-9a-fA-F]{2}(?:[:-][0-9a-fA-F]{2}){5}\b/g, "<mac>");
  s = s.replace(/\b[0-9a-fA-F]{4}(?:\.[0-9a-fA-F]{4}){2}\b/g, "<mac>");
  s = s.replace(/\b[0-9a-fA-F]{2}(?:\.[0-9a-fA-F]{2}){5}\b/g, "<mac>");
  s = s.replace(/\b[0-9a-fA-F]{2}(?:_[0-9a-fA-F]{2}){5}\b/g, "<mac>");
  s = s.replace(/\b[0-9a-fA-F]{12}\b/g, "<mac>");

  // ---------------------------------------------------------------- IPv6
  // Two patterns, both anchored so a match cannot begin inside a longer token.
  //
  // (1) IPv4-embedded: a colon-bearing run followed by a dotted quad. This is
  //     every IPv4-mapped ("::ffff:1.2.3.4"), IPv4-compatible ("::1.2.3.4"),
  //     NAT64 ("64:ff9b::1.2.3.4") and 6to4 ("2002::1.2.3.4") address.
  //     It must be matched BEFORE plain IPv4, because otherwise the IPv4 rule
  //     consumes the quad first and the reader is left with a bare, meaningless
  //     "<ipv6>.168.1.5" -- which also leaks three of the four octets of a real
  //     address.
  s = s.replace(
    /(?<![0-9a-fA-F:.])(?=[0-9a-fA-F:]*[0-9a-fA-F:])[0-9a-fA-F]*:[0-9a-fA-F:.]*\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?![0-9.])/g,
    "<ipv6>"
  );

  // (2) Plain hex groups. A run of 2..8 colon-separated hex groups is a
  //     candidate, and is only masked when it is genuinely an address:
  //     either it uses "::" compression, or it has the full 8 groups.
  //
  //     This predicate is what protects file:line:col. Omarchy's Hyprland
  //     config is hyprland.lua, so `hyprctl configerrors` hands us
  //     "hyprland.lua:42:12: unknown keyword" and the report -- whose own
  //     advice is "open the file and line named in each error" -- used to
  //     print "hyprland.lu<ipv6>". The earlier matcher used a `{0,4}`
  //     quantifier that could match EMPTY hex groups, so ":12:4" and
  //     ":ffff:192" were both eligible; "css:12:4" is a three-group run and
  //     is now correctly left alone, as are "08:04:18" and "1:2:3".
  s = s.replace(
    /(?<![0-9a-fA-F:.])(?:[0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}(?![0-9a-fA-F:])/g,
    function (match) {
      if (match.indexOf("::") !== -1) return "<ipv6>"
      var groups = match.split(":")
      while (groups.length && groups[groups.length - 1] === "") groups.pop()
      return groups.length >= 8 ? "<ipv6>" : match
    }
  );

  // An IPv6 zone suffix identifies the interface as surely as the address
  // identifies the host: "fe80::1%wlp3s0" used to become "<ipv6>%wlp3s0".
  s = s.replace(/(<ipv6>)(?:%[0-9A-Za-z._-]+)+/g, "$1");

  // ---------------------------------------------------------------- IPv4
  // Keep the first two octets as the subnet, mask the host part.
  s = s.replace(/\b(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}\b/g, "$1.$2.x.x")

  // ------------------------------------------------------------- network
  // SSID / ESSID is the name of the user's home network. The optional closing
  // quote is consumed with the value so no stray " is left behind.
  s = s.replace(/\b((?:E?SSID)\s*[:=]\s*)(?:"[^"\n]*"|'[^'\n]*'|[^\n",]+)/gi, "$1<ssid>");
  // The interface name in an ARP/NDP line is a PCI-derived name that discloses
  // the DMI product string. The keyword is kept because "dev <iface>" still
  // says which line of evidence this is.
  s = s.replace(/\b(dev|iface|interface|ifname)\s+([A-Za-z0-9_.:-]+)/gi, "$1 <iface>");
  // Kernel-derived interface names, which are unambiguous -- no diagnostic prose
  // contains "eno1" or "wlp3s0" by accident -- so they need no keyword.
  //
  // Every real name has DIGITS after the prefix (enp7s0, wlp0s20f3, eno1, eth0),
  // and requiring them keeps ordinary words out: "ethereal" is not matched.
  //
  // The trailing \w* is what makes this correct. A pattern ending at the digits
  // consumed "wlp0s20" out of "wlp0s20f3" and left a dangling "f3", so the
  // report read "Interfaces: <iface> <iface>f3" -- which redacts nothing useful
  // while looking like it did.
  // wlx/wwan/wwp are included because they are MAC-derived names: wlx<12hex>
  // embeds the interface's MAC in its own name, so leaving the token intact
  // leaked both the interface and the MAC (the bare-12-hex rule cannot see it,
  // since there is no word boundary inside "wlx001122334455").
  s = s.replace(/\b(?:wlp|wlan|wlx|wwan|wwp|enp|eno|ens|enx|eth|wl)\d+[a-z0-9]*/g, "<iface>");

  // ------------------------------------------------------- hostname / user
  //
  // A bare token equal to the machine's hostname IS the hostname and is always
  // masked. A DOTTED token is treated as a domain name and left alone, because
  // OmaDoctor's own default hostname is "omarchy" and the DNS evidence quotes
  // the public site "omarchy.org" -- masking that would destroy a fact about a
  // website in order to redact a fact about the local machine, leaving the
  // report unable to say which lookup failed. The residual exposure is a local
  // domain name (also published by mDNS on every LAN), not the host identity.
  if (o.hostname && o.hostname.length >= 2) {
    var host = o.hostname.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    s = s.replace(new RegExp("(^|[^0-9A-Za-z._-])" + host + "(?![0-9A-Za-z-]|\\.[A-Za-z])", "g"),
      "$1<host>")
  }
  if (o.home) {
    // Applied BEFORE the username rule. The old order rewrote /home/<user>
    // first, which made o.home unreachable -- it was dead code in production,
    // since Panel.qml always passes both.
    s = s.split(o.home).join("~")
  }
  if (o.username && o.username.length >= 2) {
    // The /home/<user> form is substituted exactly first.
    s = s.split("/home/" + o.username).join("/home/<user>")
    // Then the bare name, but only on word boundaries. An unconditional
    // split/join on a one- or two-character username rewrites unrelated words:
    // username "d" turned "Devices detected" into "Devices <user>etecte<user>".
    var user = o.username.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    s = s.replace(new RegExp("(^|[^0-9A-Za-z._/-])" + user + "(?![0-9A-Za-z_-])", "g"),
      "$1<user>")
  }

  // ---------------------------------------------------------------- paths
  // /root belongs to the same person as $HOME for every practical purpose in a
  // report, and o.home does not cover it.
  s = s.replace(/(^|[^0-9A-Za-z._\/-])\/root(?=\/|$)/g, "$1~")

  return s
}

// redactGaps(opts) -> array of redaction inputs that were NOT supplied.
//
// A report that silently omits a redaction rule is worse than one that says so:
// the reader cannot distinguish "nothing identifying was found" from
// "redaction was disabled for this field". Panel.qml surfaces this in the UI
// and in the report footer when it is non-empty.
function redactGaps(opts) {
  var o = opts || {}
  var gaps = []
  if (!o.hostname || o.hostname.length < 2) gaps.push("hostname")
  if (!o.username || o.username.length < 2) gaps.push("username")
  if (!o.home) gaps.push("home directory")
  return gaps
}

// ------------------------------------------------------------------- report

// buildReport(scan, opts) -> plain-text diagnostic report.
//
// opts.now          epoch seconds, for the age line
// opts.redactInfo   { hostname, username, home } to redact
// opts.redact       boolean, default true
// opts.pluginVersion
function buildReport(scan, opts) {
  var o = opts || {}
  // A scan is NORMALISED before it is rendered, not merely shape-checked. This
  // function is exported, and buildReportText's happy path is not the only way
  // in: given a hand-built or QML-mutated document it used to throw on
  // `x.status.toUpperCase()` for a missing status, print "Repair : UNDEFINED"
  // when repair was a bare string, and render an uppercase "OK" as [FAIL] while
  // the FINDINGS section said "Nothing needs attention". normCheck is the single
  // definition of what a check is, and everything downstream can rely on it.
  var s = scan && Array.isArray(scan.checks)
    ? {
        mode: scan.mode === "full" ? "full" : "quick",
        version: str(scan.version),
        ts: num(scan.ts),
        checks: eachReal(scan.checks).map(normCheck)
      }
    : null
  if (!s) return "OmaDoctor\n\nNo scan data available."

  var redactOn = o.redact !== false
  var ri = o.redactInfo || {}

  // oneLine(v) -> v flattened to a single line.
  //
  // A producer can put a newline inside a value: hyprctl, journalctl and df all
  // emit multi-line output, and a section that scraped any of it carries the
  // break straight into `value`. That let a check FORGE a line in the report:
  //
  //   value: "line1\n  [ok] Fake check passed: everything is fine"
  //
  // rendered a fabricated passing check beside the real one. The report is meant
  // to be pasted to strangers, so no producer may write into its structure.
  // details[] entries are already one-per-line by construction and are exempt.
  function oneLine(v) {
    return str(v).replace(/[\r\n]+/g, " ").replace(/[ \t]+/g, " ").trim()
  }

  // isoUtc(v) -> a UTC timestamp, or a clear marker instead of a RangeError.
  // new Date(1e21).toISOString() throws, and a non-numeric input silently
  // produced 1970 -- which is a poor thing to print in a document whose whole
  // purpose is temporal evidence.
  function isoUtc(v) {
    var n = Number(v)
    if (!isFinite(n) || Math.abs(n) > 253402300799) return "unknown"
    var ms = n * 1000
    if (Math.abs(ms) > 8.64e15) return "unknown"
    return new Date(ms).toISOString().replace("T", " ").slice(0, 19) + " UTC"
  }

  var state = overallState(s.checks)
  var c = counts(s.checks)
  var found = issues(s.checks)

  var out = []
  out.push("OMADOCTOR DIAGNOSTIC REPORT")
  out.push("=".repeat(52))
  out.push("")
  out.push("Generated : " + isoUtc(o.now))
  out.push("Scan       : " + (s.mode === "full" ? "full (includes network)" : "quick (local only)"))
  out.push("Plugin     : OmaDoctor " + str(o.pluginVersion || s.version).trim())
  if (s.ts) out.push("Scan taken : " + fmtAge(s.ts, num(o.now)))
  if (o.redact === false) out.push("Redaction  : DISABLED -- this report may identify you")
  // A redaction input that never arrived is a SILENT privacy hole, and the
  // reader cannot tell "nothing identifying was found" from "this rule was
  // off". Panel.qml passes Quickshell.env("HOSTNAME"), which is a shell
  // variable rather than an exported one on many systems, so it arrives empty
  // and the hostname was never masked while the footer claimed it was.
  if (redactOn) {
    var gaps = redactGaps(ri)
    if (gaps.length > 0) {
      out.push("Redaction  : INCOMPLETE -- could not determine " + gaps.join(", ") +
        ". Read the report before sharing it.")
    }
  }

  var sys = findCheck(s.checks, "system.os")
  var kern = findCheck(s.checks, "system.kernel")
  var arch = findCheck(s.checks, "system.arch")
  if (sys) out.push("System     : " + oneLine(sys.value))
  if (kern) out.push("Kernel     : " + oneLine(kern.value))
  if (arch) out.push("Arch       : " + oneLine(arch.value))

  out.push("")
  out.push("RESULT: " + stateLabel(state) +
    "  (" + c.total + " checks: " + c.ok + " ok, " + c.info + " info, " +
    c.attention + " attention, " + c.problem + " problem)")
  out.push("")

  // Sections
  var buckets = byCategory(s.checks)
  for (var i = 0; i < buckets.length; i++) {
    var b = buckets[i]
    out.push(oneLine(b.category).toUpperCase())
    out.push("-".repeat(Math.max(4, oneLine(b.category).length)))
    for (var j = 0; j < b.checks.length; j++) {
      var k = b.checks[j]
      var mark = k.status === "ok" ? "ok  " : (k.status === "info" ? "info" : k.status === "attention" ? "WARN" : "FAIL")
      out.push("  [" + mark + "] " + oneLine(k.title) +
        (k.value ? ": " + oneLine(k.value) : ""))
      if (k.detail && (k.status === "attention" || k.status === "problem" || k.status === "info")) {
        out.push("         " + oneLine(k.detail))
      }
    }
    out.push("")
  }

  // Findings
  out.push("FINDINGS")
  out.push("-".repeat(52))
  if (found.length === 0) {
    out.push("  Nothing needs attention.")
  } else {
    // One repair anywhere earns a single global disclaimer rather than a
    // repeated line under every finding.
    var anyRepair = false
    for (var r = 0; r < found.length; r++) {
      if (found[r].repair) { anyRepair = true; break }
    }
    for (var f = 0; f < found.length; f++) {
      var x = found[f]
      out.push("")
      out.push("  " + (f + 1) + ". [" + x.status.toUpperCase() + "] " + oneLine(x.title) +
        (x.value ? " — " + oneLine(x.value) : ""))
      if (x.detail) out.push("     Evidence : " + oneLine(x.detail))
      // Structured evidence: the multi-line "here is what I measured" block a
      // detail string cannot carry (per-monitor state, config error lines).
      // Each entry is already one line by construction, but a producer could
      // still embed a break, so it is flattened too.
      if (x.details && x.details.length > 0) {
        for (var d = 0; d < x.details.length; d++) {
          out.push("       - " + oneLine(x.details[d]))
        }
      }
      if (x.suggestion) out.push("     Suggested: " + oneLine(x.suggestion))
      // Descriptive only: what a fix WOULD be. Never executed.
      if (x.repair) {
        out.push("     Repair   : " + String(x.repair.tier).toUpperCase() +
          " — " + oneLine(x.repair.label))
        if (x.repair.detail) {
          out.push("       " + oneLine(x.repair.detail))
        }
      }
    }
    if (anyRepair) {
      out.push("")
      out.push("  Repairs are listed for information only. OmaDoctor does not")
      out.push("  run them, and never modifies your configuration.")
    }
  }
  out.push("")
  out.push("=".repeat(52))
  out.push("Generated locally by OmaDoctor. No telemetry, no network upload.")

  var text = out.join("\n")
  if (redactOn) text = redact(text, ri)
  return text
}

// buildReportText is a convenience wrapper for the UI layer.
function buildReportText(rawJson, opts) {
  var scan = parseDoctor(rawJson)
  return buildReport(scan, opts)
}