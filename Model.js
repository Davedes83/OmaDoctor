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
      suggestion: str(c.suggestion)
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
function overallState(checks) {
  if (!Array.isArray(checks) || checks.length === 0) return "ok"
  var worst = 0
  for (var i = 0; i < checks.length; i++) {
    var w = weight(checks[i].status)
    if (w > worst) worst = w
  }
  return worst >= 3 ? "problem" : worst >= 1 ? "attention" : "ok"
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

// byCategory(checks) -> ordered array of { category, checks, state }
// Categories keep a stable order so the panel does not reshuffle between scans.
function byCategory(checks) {
  var order = ["system", "network", "audio", "storage", "bluetooth", "boot"],
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
  // The pattern accepts both full (8-group) and compressed ("::") forms. The
  // leading group is optional so bare "::1" matches; the trailing part allows
  // an embedded IPv4 form. Boundaries are non-hex/non-colon on the left and
  // non-hex/non-dot on the right, so "2001:db8::8a2e:370:7334" is consumed
  // whole rather than up to its first dot.
  s = s.replace(
    /(?<![0-9a-fA-F:.])(?:[0-9a-fA-F]{1,4}:){2,}(?:[0-9a-fA-F]{1,4}(?::[0-9a-fA-F]{1,4})*|(?::[0-9a-fA-F]{1,4})+)|(?<![0-9a-fA-F:])(?:[0-9a-fA-F]{0,4}:){2,}[0-9a-fA-F]{0,4}(?![0-9a-fA-F:])/g,
    "<ipv6>"
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
    for (var f = 0; f < found.length; f++) {
      var x = found[f]
      out.push("")
      out.push("  " + (f + 1) + ". [" + x.status.toUpperCase() + "] " + str(x.title) +
        (x.value ? " — " + str(x.value) : ""))
      if (x.detail) out.push("     Evidence : " + str(x.detail))
      if (x.suggestion) out.push("     Suggested: " + str(x.suggestion))
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