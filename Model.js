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
    var c = raw.checks[i]
    if (!c || typeof c !== "object") continue
    checks.push({
      id: str(c.id),
      category: str(c.category) || "system",
      title: str(c.title),
      status: normStatus(c.status),
      severity: num(c.severity),
      value: str(c.value),
      detail: str(c.detail),
      suggestion: str(c.suggestion),
      // Both of these are OPTIONAL and purely additive: a check that does not
      // carry them normalises to an empty list / null, so existing producers
      // and renderers keep working untouched.
      details: strArray(c.details),
      repair: normRepair(c.repair)
    })
  }

  return {
    mode: str(raw.mode) || "quick",
    version: str(raw.version),
    ts: num(raw.ts),
    sections: str(raw.sections),
    checks: checks
  }
}

function str(v) {
  return v === undefined || v === null ? "" : String(v)
}

function num(v) {
  var n = Number(v)
  return isFinite(n) ? n : 0
}

function normStatus(s) {
  s = String(s === undefined || s === null ? "" : s).toLowerCase()
  if (s === "ok" || s === "info" || s === "attention" || s === "problem") return s
  // An unrecognised status must never be silently treated as healthy.
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

  var seen = {}
  for (var i = 0; i < a.checks.length; i++) {
    var now = a.checks[i]
    var id = str(now.id)
    seen[id] = true
    var then = findCheck(b.checks, id)
    if (!then) { out.same++; continue }
    var beforeW = weight(then.status)
    var afterW = weight(now.status)
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
  for (var j = 0; j < b.checks.length; j++) {
    if (!seen[str(b.checks[j].id)]) out.same++
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
  if (!Array.isArray(checks) || checks.length === 0) return "ok"
  var worst = 0
  for (var i = 0; i < checks.length; i++) {
    var w = weight(checks[i].status)
    if (w > worst) worst = w
  }
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
// issues(checks) -> the checks a user should act on, worst first.
function issues(checks) {
  if (!Array.isArray(checks)) return []
  var out = []
  for (var i = 0; i < checks.length; i++) {
    if (weight(checks[i].status) > 0) out.push(checks[i])
  }
  out.sort(function (a, b) {
    var d = weight(b.status) - weight(a.status)
    return d !== 0 ? d : String(a.category).localeCompare(String(b.category))
  })
  return out
}

// counts(checks) -> { ok, info, attention, problem, total }
function counts(checks) {
  var c = { ok: 0, info: 0, attention: 0, problem: 0, total: 0 }
  if (!Array.isArray(checks)) return c
  for (var i = 0; i < checks.length; i++) {
    var s = normStatus(checks[i].status)
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
  var order = ["system", "services", "hyprland", "network", "audio", "storage",
               "bluetooth", "boot"],
    seen = {}, buckets = []
  if (!Array.isArray(checks)) return buckets

  for (var i = 0; i < checks.length; i++) {
    var cat = str(checks[i].category) || "system"
    if (!seen[cat]) {
      seen[cat] = { category: cat, checks: [] }
      buckets.push(seen[cat])
    }
    seen[cat].checks.push(checks[i])
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
  if (!Array.isArray(checks)) return null
  for (var i = 0; i < checks.length; i++) {
    if (String(checks[i].id) === String(id)) return checks[i]
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
function redact(text, opts) {
  var o = opts || {}
  var s = String(text === undefined || text === null ? "" : text)

  // MAC addresses (before IPv6, whose hex groups would otherwise look similar).
  s = s.replace(/\b([0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5})\b/g, "<mac>")
  s = s.replace(/\b([0-9a-fA-F]{2}-[0-9a-fA-F]{2}(-[0-9a-fA-F]{2}){4})\b/g, "<mac>")

// IPv4-mapped and IPv4-compatible IPv6 ("::ffff:1.2.3.4", "::1.2.3.4").
// These embed a dotted quad, so the trailing-group lookahead below would stop
// at the first dot and leave "192.168.1.1" exposed. Match them first.
  s = s.replace(/(?<![0-9a-fA-F:.])(?:::(?:ffff:)?)\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?![0-9.])/g, "<ipv6>");

  // IPv6 must be handled before plain IPv4, and must match the WHOLE address.
  // Doing it the other way round leaves `::ffff:192.168.x.x` (exposing the
  // "::ffff:" prefix) and splits long addresses into a real prefix plus a
  // masked tail, e.g. "2001:db8::<ipv6>" -- which still leaks the prefix.
  //
  // The patterns accept both full (8-group) and compressed ("::") forms, with
  // the leading group optional so bare "::1" matches and the trailing part
  // allowing an embedded IPv4 form. Boundaries are non-hex/non-colon on the
  // left and non-hex/non-dot on the right, so "2001:db8::8a2e:370:7334" is
  // consumed whole rather than up to its first dot.
  //
  // Both patterns run through maskIPv6, which rejects the clock-time shapes
  // ("08:04:18", "1:2:3") that are hex-legal and would otherwise eat every
  // timestamp in the report header. A real address either uses "::", or has
  // 4+ groups, or carries a group that is not a bare 1-2 digit decimal --
  // "2001:db8::1", "fe80:0:0:0:0:0:0:1", and "abcd:ef01:..." all do.
  function maskIPv6(match) {
    if (match.indexOf("::") !== -1) return "<ipv6>"
    var groups = match.split(":")
    if (groups.length >= 4) return "<ipv6>"
    // 2 or 3 groups, no compression: only an address if some group is not a
    // short decimal run ("0d 3h 57m" and "2.42 / 1.73" must survive).
    for (var i = 0; i < groups.length; i++) {
      if (!/^\d{1,2}$/.test(groups[i])) return "<ipv6>"
    }
    return match
  }

  s = s.replace(
    /(?<![0-9a-fA-F:.])(?:[0-9a-fA-F]{1,4}:){2,}(?:[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4})*|(?::[0-9a-fA-F]{1,4})+)|(?<![0-9a-fA-F:])(?:[0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F]{0,4}(?![0-9a-fA-F:])/g,
    maskIPv6
  );
  // Compressed forms with few groups, e.g. "::1", "fe80::", "2001:db8::1".
  s = s.replace(/(?<![0-9a-fA-F:])(?:[0-9a-fA-F]{1,4})?::(?:[0-9a-fA-F]{1,4}){0,3}(?![0-9a-fA-F:])/g, "<ipv6>");

  // Plain IPv4: keep the first two octets as the subnet, mask the host part.
  s = s.replace(/\b(\d{1,3})\.(\d{1,3})\.\d{1,3}\.\d{1,3}\b/g, "$1.$2.x.x")

  if (o.hostname) {
    s = s.split(o.hostname).join("<host>")
  }
  if (o.username) {
    s = s.split(o.username).join("<user>")
    // Also catch the home directory form (/home/<user>).
    s = s.split("/home/" + o.username).join("/home/<user>")
  }
  if (o.home) {
    s = s.split(o.home).join("~")
  }
  return s
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
  var s = scan && Array.isArray(scan.checks) ? scan : null
  if (!s) return "OmaDoctor\n\nNo scan data available."

  var redactOn = o.redact !== false
  var ri = o.redactInfo || {}

  var state = overallState(s.checks)
  var c = counts(s.checks)
  var found = issues(s.checks)

  var out = []
  out.push("OMADOCTOR DIAGNOSTIC REPORT")
  out.push("=".repeat(52))
  out.push("")
  out.push("Generated : " + new Date(num(o.now) * 1000).toISOString().replace("T", " ").slice(0, 19) + " UTC")
  out.push("Scan       : " + (s.mode === "full" ? "full (includes network)" : "quick (local only)"))
  out.push("Plugin     : OmaDoctor " + str(o.pluginVersion || s.version))
  if (s.ts) out.push("Scan taken : " + fmtAge(s.ts, num(o.now)))
  if (o.redact === false) out.push("Redaction  : DISABLED -- this report may identify you")

  var sys = findCheck(s.checks, "system.os")
  var kern = findCheck(s.checks, "system.kernel")
  var arch = findCheck(s.checks, "system.arch")
  if (sys) out.push("System     : " + sys.value)
  if (kern) out.push("Kernel     : " + kern.value)
  if (arch) out.push("Arch       : " + arch.value)

  out.push("")
  out.push("RESULT: " + stateLabel(state) +
    "  (" + c.total + " checks: " + c.ok + " ok, " + c.info + " info, " +
    c.attention + " attention, " + c.problem + " problem)")
  out.push("")

  // Sections
  var buckets = byCategory(s.checks)
  for (var i = 0; i < buckets.length; i++) {
    var b = buckets[i]
    out.push(str(b.category).toUpperCase())
    out.push("-".repeat(Math.max(4, str(b.category).length)))
    for (var j = 0; j < b.checks.length; j++) {
      var k = b.checks[j]
      var mark = k.status === "ok" ? "ok  " : (k.status === "info" ? "info" : k.status === "attention" ? "WARN" : "FAIL")
      out.push("  [" + mark + "] " + str(k.title) +
        (k.value ? ": " + str(k.value) : ""))
      if (k.detail && (k.status === "attention" || k.status === "problem" || k.status === "info")) {
        out.push("         " + str(k.detail))
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
      out.push("  " + (f + 1) + ". [" + x.status.toUpperCase() + "] " + str(x.title) +
        (x.value ? " — " + str(x.value) : ""))
      if (x.detail) out.push("     Evidence : " + str(x.detail))
      // Structured evidence: the multi-line "here is what I measured" block a
      // detail string cannot carry (per-monitor state, config error lines).
      if (x.details && x.details.length > 0) {
        for (var d = 0; d < x.details.length; d++) {
          out.push("       - " + str(x.details[d]))
        }
      }
      if (x.suggestion) out.push("     Suggested: " + str(x.suggestion))
      // Descriptive only: what a fix WOULD be. Never executed.
      if (x.repair) {
        out.push("     Repair   : " + String(x.repair.tier).toUpperCase() +
          " — " + str(x.repair.label))
        if (x.repair.detail) {
          out.push("       " + str(x.repair.detail))
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