import QtQuick
// QtQuick.Controls is deliberately NOT imported: qs.Ui also exports Button
// and TextField, and the ambiguity fails the whole file. qs.Ui.Button
// resolves to the shell's own type, which is what this file wants.
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// OmaDoctor -- a bar widget that runs read-only diagnostics and explains what
// it finds.
//
// The entry point is the panel itself (see manifest.json: a bar-widget may
// point straight at a Panel.qml, which is what the shell's own audio, network
// and power widgets do). The Panel owns the bar icon via a BarIconButton and
// hosts the popup content in a KeyboardPanel.
//
// All logic lives in Model.js and backend/*.sh -- this file only spawns the
// scanner and renders what comes back.
Panel {
  id: root
  moduleName: "davedes.omadoctor"
  ipcTarget: "davedes.omadoctor"
  // manageIpc: false so this panel can own the single IpcHandler the target
  // permits -- required for the extra methods (state/runFullScan/copyReport)
  // below. Same pattern as the shell's power panel.
  manageIpc: false

  // ------------------------------------------------------------ scan state
  property var scan: null
  property string lastRawJson: ""
  property bool scanning: false
  property string lastError: ""
  property string lastMode: "quick"
  property string pluginVersion: "0.5.0"

  readonly property var checks: scan && Array.isArray(scan.checks) ? scan.checks : []
  readonly property string state: Model.overallState(checks)
  readonly property var totals: Model.counts(checks)
  readonly property bool ready: scan !== null
  readonly property int issueCount: Model.issues(checks).length

  // Flat, UI-ready list of section headers and finding rows. Built in Model.js
  // so it is unit-testable and so the panel needs only a single Repeater -- see
  // the note on the findings Repeater below.
  readonly property var rows: Model.findingRows(checks)
  readonly property int alertCategories: {
    var n = 0
    for (var i = 0; i < root.rows.length; i++) {
      if (root.rows[i].kind === "header") n++
    }
    return n
  }

  // The id of the finding row the pointer is over, or "" for none.
  //
  // Deliberately NOT part of the keyboard cursor model: rowCount covers only
  // the three action buttons, so the arrow keys still walk just those and
  // Enter activates them. Findings are hover-highlighted only, which is the
  // whole premium win without turning every finding into a tab stop.
  //
  // A single id (rather than a per-row flag) is what guarantees the kit's "one
  // highlight at a time" contract -- two rows can never claim the cursor.
  // Cleared on every scan and on close so an id from a finished scan can never
  // light up a row that no longer exists.
  property string hoveredCheckId: ""

  // ------------------------------------------------- settings (shell.json)
  //
  // A bar widget's settings are the keys of its OWN entry in
  // bar.layout.<section>, beside the id -- never nested under a `settings:`
  // sub-object, which arrives as settings.settings.size and silently does
  // nothing at every value. `settings` is injected by the bar
  // (Bar.qml ModuleSlot.injectProps probes for the property name).
  //
  // barWidget.defaults in the manifest is NEVER read by the shell -- it is
  // forwarded into registry metadata and only metadata.firstParty is consumed
  // -- so these defaults are duplicated here deliberately. Change both.
  readonly property int pollMs: {
    var m = root.setting("pollSeconds", 0)
    return m > 0 ? m * 1000 : 0            // 0 disables the background poll
  }
  readonly property bool notifyEnabled: root.setting("notifyOnProblem", true) !== false


  // setSetting(key, value) -> persist one setting.
  //
  // bar.shell.updateEntryInline REWRITES the entry as { id, ...settings } and
  // DROPS every key it was not given, so the existing entry is round-tripped
  // from root.settings first. Sending only the key being changed would silently
  // delete every other setting on the widget.
  function setSetting(key, value) {
    var entry = { id: root.moduleName }
    var base = root.settings && typeof root.settings === "object" ? root.settings : {}
    for (var k in base) {
      if (k !== "id") entry[k] = base[k]
    }
    entry[key] = value
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    }
  }

  function toggleNotifications() {
    root.setSetting("notifyOnProblem", !root.notifyEnabled)
  }

  function togglePolling() {
    root.setSetting("pollSeconds", root.pollMs > 0 ? 0 : 300)
  }

  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color urgent: Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Glyph and colour follow the worst-wins state, never a percentage. A
  // healthy machine and a machine with one unreadable thing must not look
  // alike, so "ok" is its own distinct state rather than a percentage.
  readonly property string stateGlyph: Model.glyph(state)
  readonly property color stateColor: {
    if (state === "problem") return urgent
    if (state === "attention") return accent
    return foreground
  }

  // A reactive "now". Date.now() is not a QML dependency, so a binding on it
  // would freeze the moment the scan stops changing and the age readout could
  // never age. This timer keeps it moving.
  property int clockSec: Math.floor(Date.now() / 1000)
  readonly property int nowSec: Math.max(root.clockSec, scan ? Number(scan.ts || 0) : 0)

  // ------------------------------------------------------------- scanning
  //
  // doctor.sh runs its sections sequentially behind per-section deadlines, so
  // the outer budget must exceed the SUM of them or a legitimately slow scan
  // gets truncated mid-document and arrives unparseable -- which the panel
  // would then report as "could not read scan output".
  //
  //   quick: system 15 + services 10 + hyprland 10 + display 10
  //         + audio 12 + storage 15                                        = 72
  //   full:  the above + network 25                                        = 97
  //
  // Both figures are worst case. Measured real timings are far lower (a few
  // seconds), so these are headroom against a stalling probe, not an estimate
  // of a normal scan. Keep them in step with deadline_for() in doctor.sh --
  // adding a section without raising this is how a scan gets killed mid-write.
  function budgetFor(mode) {
    return mode === "full" ? 110 : 85
  }

  function refresh(mode, userInitiated) {
    var requested = mode || "quick"
    // The row under the pointer is about to be replaced by a fresh scan, so the
    // highlight must not survive into the new one. Cleared here rather than on
    // completion because the pointer may well still be sitting over the panel
    // when the scan lands, and a stale id would light an unrelated row.
    hoveredCheckId = ""
    if (scanProc.running) {
      // A scan is already in flight. Opening the panel during a quick scan must
      // still end up with the network section, so remember the upgrade and
      // honour it once the current scan lands rather than dropping it.
      if (requested === "full") {
        queuedFull = true
        queuedUserInitiated = userInitiated === true
      }
      return
    }
    pendingMode = requested
    // Whether the USER asked for this scan. A notification after a scan someone
    // just ran restates what is already on screen, so the policy suppresses it.
    // Panel.open() and the IPC methods pass true; the background timer does not.
    pendingUserInitiated = userInitiated === true
    scanProc.command = [
      "/usr/bin/timeout", "-k", "2", String(root.budgetFor(requested)),
      "/bin/sh", root.runnerPath,
      "/bin/sh", root.doctorPath,
      requested
    ]
    scanProc.running = true
    scanning = true
    // lastRawJson is deliberately NOT cleared here: it feeds buildReport while
    // the rescan runs. The failure path below uses scanProc.finished instead,
    // which is per-scan -- lastRawJson is stale after any earlier success and
    // cannot tell "this scan produced nothing" from "a previous one succeeded".
    scanProc.finished = false
  }

  property string pendingMode: "quick"
  property bool queuedFull: false
  property bool queuedUserInitiated: false
  property bool pendingUserInitiated: false

  // The state as of the last COMPLETED scan, used only to decide whether the
  // next scan represents a worsening.
  //
  // "" means "no baseline yet", which is what makes the very first scan
  // silent -- there is no transition to report. It is NOT null: QML rejects a
  // null assignment to a string property outright ("Invalid property
  // assignment: string expected") and the whole plugin fails to load, which
  // the editor's diagnostics do not surface. Model.shouldNotify treats "" as a
  // missing baseline, which weight() degrades to "problem" -- see the note on
  // Rule 3 in Model.js.
  property string lastNotifiedState: ""

  // -------------------------------------------------------- what changed
  //
  // The scan to compare the NEXT one against. Seeded from the on-disk history
  // at startup so a shell restart does not blind the feature, then replaced by
  // each completed scan.
  //
  // Only a STATUS transition is reported, never a changed value: uptime ticks,
  // latency jitters and memory drifts on every scan, and a "what changed" line
  // that always has something in it is the same noise problem as a chatty
  // notification. See Model.diffScans.
  property var baselineScan: null
  property var lastDiff: null
  readonly property string changeLine: root.lastDiff ? (Model.changeSummary(root.lastDiff) || "") : ""

  // backend/bootstrap.sh defaults the state dir to $HOME/.local/state/omadoctor,
  // and the spawner passes HOME through, so this is the same path the backend
  // writes. Derived from HOME rather than from runnerPath: the plugin's
  // location has nothing to do with where user state belongs.
  readonly property string stateDir: (Quickshell.env("HOME") || "") + "/.local/state/omadoctor"

  // Newest history entry, picked up once at startup. Declared as a property
  // rather than constructed inside the function -- that is the shell's own
  // idiom (see Commons/Color.qml), and a FileView built in a function body has
  // no stable parent to load against.
  //
  // printErrors is off because a missing history directory on a first run is a
  // normal state, not something to shout about: a diagnostic tool must never be
  // the reason the panel misbehaves.
  property FileView historyDirView: FileView {
    id: historyDirView
    path: root.stateDir + "/history"
    watchChanges: false
    printErrors: false
  }
  property FileView baselineFileView: FileView {
    id: baselineFileView
    path: ""
    watchChanges: false
    printErrors: false
    onLoaded: root.applyBaseline(text())
    // A truncated or absent entry simply leaves the baseline unset.
    onLoadFailed: {}
  }

  // Seed the "what changed" baseline from disk so a shell restart does not
  // leave the feature blind -- otherwise it is silent exactly when a user most
  // wants to know what moved, which is right after logging in.
  //
  // The stored form is a compact {"id":"status"} map. diffScans reads only id
  // and status from the baseline side (titles and values come from the current
  // scan), so no other fields are needed.
  function loadBaselineFromHistory() {
    var newest = ""
    var newestTs = -1
    var n = historyDirView.count
    for (var i = 0; i < n; i++) {
      var name = historyDirView.itemAt(i).fileName
      // Only <epoch>.json. Skips the .tmp.$$ file an in-flight write leaves.
      if (!/^[0-9]+\.json$/.test(name)) continue
      var ts = parseInt(name, 10)
      if (ts > newestTs) { newestTs = ts; newest = name }
    }
    if (newest === "") return
    baselineFileView.path = root.stateDir + "/history/" + newest
  }

  function applyBaseline(text) {
    // The first scan may complete before this file finishes loading. If that
    // has happened, the live baseline is newer and more accurate than the
    // on-disk one, so the disk read must not clobber it.
    if (root.scan !== null) return
    try {
      var parsed = JSON.parse(text)
      if (!parsed || !parsed.status) return
      var checks = []
      for (var id in parsed.status) {
        if (!Object.prototype.hasOwnProperty.call(parsed.status, id)) continue
        checks.push({ id: id, status: parsed.status[id] })
      }
      if (checks.length > 0) root.baselineScan = { checks: checks }
    } catch (e) {
      // Malformed history is not worth reporting.
    }
  }

  function onScanFinished(raw, exitCode, stderrText) {
    scanning = false
    lastMode = pendingMode
    var parsed = Model.parseDoctor(root.capText(raw))

    // stderr is captured rather than discarded. It used to be dropped at three
    // independent layers (no StdioCollector here, `2>/dev/null` in run-capped.sh,
    // `2>/dev/null` in doctor.sh), so the user-facing message could only ever be
    // the single fixed string "could not read scan output" -- useless to someone
    // filing a bug report, because it does not distinguish a timeout, bad JSON,
    // empty stdout or a crashed backend. The shell only ever console.warn()s, so
    // journalctl was the sole place any of it was visible.
    var err = root.firstLine(stderrText)

    if (!parsed) {
      // A malformed payload must not replace a good scan: keep the last known
      // state on screen and surface the failure rather than blanking the panel.
      lastError = err
        ? "could not read scan output: " + err
        : (exitCode !== 0 && exitCode !== undefined && exitCode !== null
            ? "scan failed (exit " + exitCode + ")"
            : "could not read scan output")
    } else {
      scan = parsed
      lastError = err ? "scan completed with warnings: " + err : ""
      // Diff BEFORE advancing the baseline: the comparison is against what was
      // true before this scan, not against itself.
      root.lastDiff = root.baselineScan ? Model.diffScans(root.baselineScan, parsed) : null
      root.baselineScan = parsed
      root.maybeNotify(parsed)
    }

    // Deliberately AFTER the notification, and NOT inside maybeNotify(). A throw
    // in the notify path used to skip this block entirely, leaving queuedFull
    // stuck true so the next panel open ran an unrequested second full scan.
    if (root.queuedFull) {
      root.queuedFull = false
      var queuedUser = root.queuedUserInitiated
      root.queuedUserInitiated = false
      root.refresh("full", queuedUser)
    }
  }

  function firstLine(text) {
    if (typeof text !== "string") return ""
    var t = text.replace(/[\r\n]+/g, " ").replace(/[ \t]+/g, " ").trim()
    if (t.length > 200) t = t.slice(0, 200) + "..."
    return t
  }

  // ------------------------------------------------------------ notification
  //
  // The policy lives in Model.js so it is unit-testable; this is only the
  // plumbing. ShouldNotify fires at most once per WORSENING transition, so a
  // machine that stays broken notifies once rather than on every 30s poll, and
  // a machine that gets fixed stays quiet.
  function maybeNotify(parsed) {
    var next = Model.overallState(parsed.checks)
    if (!Model.shouldNotify(root.lastNotifiedState, next,
          { userInitiated: root.pendingUserInitiated || root.queuedFull })) {
      // The baseline still advances even when nothing fires, otherwise a
      // transition that was suppressed (because the user ran the scan) would
      // re-fire on the next background poll and announce stale news.
      root.lastNotifiedState = next
      return
    }
    root.lastNotifiedState = next
    var body = Model.notificationText(parsed)
    if (body) root.notify("OmaDoctor", body)
  }

  // notify() is implemented HERE because the type this widget extends,
  // qs.Ui.Panel, has no such function: it defines exactly open, close,
  // closeForPopoutSwitch, toggle, switchPanel and setting. The previous
  // root.notify(...) therefore threw "Property 'notify' of object
  // Panel_QMLTYPE_... is not a function" on every call -- six occurrences in
  // journalctl -- so no notification was ever posted, while Model.shouldNotify
  // sat fully unit-tested against a dead path.
  //
  // omarchy-notification-send, not notify-send: Omarchy's own wrapper calls
  // org.freedesktop.Notifications.Notify directly, because notify-send's argv
  // parsing is the surface that reinterprets a relayed headline like "--hint=.."
  // as options. Its -g maps to the omarchy-glyph hint, which the notification
  // card renders as a Nerd Font glyph in the icon slot -- the native way to put
  // an icon in a notification. -a matters too: without it the daemon classifies
  // the toast as ephemeral noise and never writes it to history.
  //
  // A bar widget is not injected with omarchyPath (only services and panels
  // are), so the path comes from OMARCHY_PATH, which Omarchy exports into the
  // session. The literal is the same path omarchy-notification-send itself
  // lives at, used only if the variable is somehow absent.
  readonly property string omarchyRoot: (Quickshell.env("OMARCHY_PATH") || "/usr/share/omarchy")

  function notify(headline, body, glyph, urgency) {
    if (root.notifyEnabled === false) return
    if (notifyProc.running) return
    notifyProc.command = [
      root.omarchyRoot + "/bin/omarchy-notification-send",
      "--app-name", "OmaDoctor",
      "-g", String(glyph || Model.glyph(root.state)),
      "-u", String(urgency || (root.state === "problem" ? "critical" : "normal")),
      String(headline),
      String(body || "")
    ]
    notifyProc.running = true
  }

  Process {
    id: notifyProc
    clearEnvironment: true
    environment: root.trustedEnv()
    stdout: SplitParser {}
    stderr: SplitParser {}
  }

  // --------------------------------------------------------------- report
  function reportText() {
    // Gated on `ready`, not on lastRawJson. lastRawJson is assigned by the
    // stdout collector BEFORE the parse is attempted, so after a parse failure
    // it still held the unparseable payload, buildReportText returned its
    // "No scan data available." fallback, and that non-empty string was copied
    // to the clipboard and announced as "Diagnostic report copied (redacted)"
    // while the panel showed an error.
    if (!root.ready) return ""
    return Model.buildReportText(root.lastRawJson, {
      now: root.clockSec,
      redactInfo: root.redactInfo,
      redact: true,
      pluginVersion: root.pluginVersion
    })
  }

  // Redaction inputs, read fresh each time.
  //
  // HOSTNAME is not exported into the process environment on many systems --
  // it is a bash/shell variable, not an environment variable -- so
  // Quickshell.env("HOSTNAME") returned "" and the hostname was never masked
  // while the report footer still claimed redaction. Reading
  // /proc/sys/kernel/hostname is authoritative and needs no environment
  // variable. USER and HOME are genuinely exported, but a shell fallback keeps
  // the redaction honest if that ever changes.
  // The hostname, read from the kernel rather than from $HOSTNAME.
  //
  // HOSTNAME is a shell variable, not an environment variable, so on many
  // systems it is simply absent from the process environment -- verified on this
  // machine, where the omarchy-shell process has no HOSTNAME at all. Reading
  // Quickshell.env("HOSTNAME") therefore returned "", Model.js's
  // `if (o.hostname)` guard was always false, and the real hostname was pasted
  // verbatim into every report the README tells users to publish -- while the
  // footer still claimed redaction.
  //
  // One tiny read-only process at startup, through the same hardened spawner.
  // FileIO is deliberately not used: it is not present anywhere in this shell's
  // QML and relying on a type nothing else imports would be a gamble.
  property string hostname: ""
  Process {
    id: hostnameProc
    clearEnvironment: true
    environment: root.trustedEnv()
    command: ["/usr/bin/cat", "/proc/sys/kernel/hostname"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var h = String(text || "").replace(/[\r\n]+/g, "").trim()
        if (h) root.hostname = h
      }
    }
  }

  function readHostname() {
    return root.hostname
  }

  readonly property var redactInfo: ({
    hostname: root.hostname,
    username: Quickshell.env("USER") || "",
    home: Quickshell.env("HOME") || ""
  })

  function copyReport() {
    if (copyProc.running) return
    var text = root.reportText()
    if (!text) {
      root.notify("OmaDoctor", "No scan yet -- run a diagnosis first.", Model.glyph("info"), "normal")
      return
    }
    // Fed over stdin rather than argv: the report is large and carries user
    // data, and argv is world-readable in /proc.
    copyProc.pending = text
    copyProc.running = true
  }

  // ----------------------------------------------------------- IPC surface
  IpcHandler {
    target: "davedes.omadoctor"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }

    function runFullScan(): void { root.refresh("full", true) }

    function copyReport(): void { root.copyReport() }

    // Ask AI is scriptable too, but it still goes through the confirmation
    // sheet -- an IPC caller cannot bypass consent.
    function askAi(): void { root.askAi() }
    function copyAiPrompt(): void { root.copyAiPrompt() }

    function state(): string {
      return JSON.stringify({
        ai: root.resolvedAiCommand,
        aiDetected: Object.keys(root.aiOnPath).sort(),
        aiRunning: root.aiRunning,
        aiAnswerPath: root.aiAnswerPath,
        ready: root.ready,
        opened: root.opened,
        scanning: root.scanning,
        state: root.state,
        mode: root.lastMode,
        totals: root.totals,
        issueCount: root.issueCount,
        categories: root.alertCategories,
        lastError: root.lastError
      })
    }
  }

  // ------------------------------------------------------ hardened spawner
  // Every helper is launched through a GNU coreutils timeout (own process
  // group -> group-level SIGTERM then SIGKILL after a 2s grace), the stdout
  // cap wrapper, and an explicit minimal environment. Nothing inherited from
  // the shell's environment can influence the scanner or let a shadow
  // executable be resolved. Copied from davedes.omcontrol.
  // Qt.resolvedUrl(...).toString() PERCENT-ENCODES: a space in the path becomes
  // %20 and a literal % becomes %25. Handing that to Process.command yields empty
  // stdout, so the only symptom would be "could not read scan output" with no
  // other clue. Stripping the 7-character scheme and leaving the rest intact is
  // the form the shell's own plugins use.
  function localPath(relative) {
    var u = Qt.resolvedUrl(relative).toString()
    return u.indexOf("file://") === 0 ? u.slice(7) : u
  }
  readonly property string runnerPath: root.localPath("backend/run-capped.sh")
  readonly property string doctorPath: root.localPath("backend/doctor.sh")
  readonly property int maxOutputBytes: 1048576
  // Two more variables, added deliberately and NOT by inheriting the shell's
  // environment wholesale.
  //
  // hyprctl talks to the compositor over a per-instance socket whose path is
  // carried in HYPRLAND_INSTANCE_SIGNATURE. Without it, hyprctl does not fail
  // loudly -- it prints "HYPRLAND_INSTANCE_SIGNATURE not set!" and EXITS 0.
  // A Hyprland section would then read that error text as its result and
  // report a healthy machine as having no compositor, which is exactly the
  // fabricated-reading-as-healthy bug the audio checks once had.
  //
  // XDG_RUNTIME_DIR is the standard user runtime directory; hyprctl uses it to
  // locate that socket. Neither variable grants a capability beyond talking to
  // the user's own compositor, so the hardened spawner stays hardened: PATH is
  // still a fixed root-owned allowlist and nothing else is inherited.
  //
  // Quickshell.env() is a ONE-TIME read, not a reactive binding. Latching the
  // instance signature into a readonly property froze the socket path at widget
  // construction, so after a compositor restart the signature was stale but
  // NON-EMPTY -- and hyprctl's "signature not set" path never triggered.
  // hyprctl instead printed "Couldn't connect to .../.socket.sock. (4)" and
  // exited 4, which the backend now detects, so the worst case is an honest
  // "unknown" rather than a fabricated "your display is off". It is a FUNCTION
  // now, so each scan asks the environment again.
  function trustedEnv() {
    return {
      "PATH": "/usr/bin:/bin",
      "HOME": Quickshell.env("HOME"),
      "LC_ALL": "C",
      "HYPRLAND_INSTANCE_SIGNATURE": Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "",
      "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR") || ""
    }
  }

  // The clipboard needs one more variable than the scanner does.
  //
  // wl-copy talks to the compositor over WAYLAND_DISPLAY, and on this machine
  // that is "wayland-1" -- Hyprland does not use the "wayland-0" name wl-copy
  // falls back to. Under trustedEnv() alone, wl-copy failed with "Failed to
  // connect to a Wayland server" and exited 1, so Copy report silently copied
  // NOTHING on every run, while the README documented it as the way to get a
  // report. The old code announced success without reading the exit status, so
  // even the failure was invisible.
  //
  // WAYLAND_DISPLAY grants no capability beyond writing to the user's own
  // clipboard, which is the entire point of the button. PATH stays pinned.
  function clipboardEnv() {
    var env = root.trustedEnv()
    env.WAYLAND_DISPLAY = Quickshell.env("WAYLAND_DISPLAY") || ""
    return env
  }

  function capText(text) {
    return typeof text === "string" && text.length > root.maxOutputBytes
      ? text.slice(0, root.maxOutputBytes) : (text || "")
  }

  Process {
    id: scanProc
    clearEnvironment: true
    environment: root.trustedEnv()
    // stderr is collected, not discarded. run-capped.sh and doctor.sh both
    // redirect it to /dev/null internally, so this catches anything a section
    // writes before those redirections, plus the timeout's own diagnostics --
    // which is the difference between "could not read scan output" and a message
    // a user can act on.
    property string stderrText: ""
    // Per-scan "onScanFinished already ran" latch. stdout's collector and
    // onExited both want to finish the scan; whichever gets there first wins,
    // the other stands down -- otherwise an empty-output failure ran
    // onScanFinished twice and the second call clobbered the useful message.
    property bool finished: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        if (scanProc.finished) return
        scanProc.finished = true
        root.lastRawJson = root.capText(text)
        root.onScanFinished(text, undefined, scanProc.stderrText)
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: scanProc.stderrText = root.capText(text)
    }
    // scanning was cleared ONLY from onStreamFinished. If the collector never
    // fires -- the Process cannot spawn at all, the command array is malformed,
    // the timeout binary is missing -- nothing ever cleared the flag and the
    // panel sat on "scanning..." indefinitely. The asymmetry was visible in the
    // file: copyProc had an onExited and scanProc did not.
    onExited: function(exitCode) {
      root.scanning = false
      // onStreamFinished normally gets here first; if the process died without
      // producing stdout, finish the scan so queuedFull is honoured and the UI
      // reports the failure instead of waiting.
      if (!scanProc.finished) {
        scanProc.finished = true
        root.onScanFinished("", exitCode, scanProc.stderrText)
      }
    }
  }

  // Copies the report via stdin so a multi-kilobyte report never becomes an
  // argv entry.
  Process {
    id: copyProc
    clearEnvironment: true
    environment: root.clipboardEnv()
    stdinEnabled: true
    command: ["/usr/bin/wl-copy"]
    property string pending: ""
    property bool succeeded: false
    onStarted: {
      if (copyProc.pending !== "") {
        copyProc.write(copyProc.pending)
      }
      // wl-copy reads stdin until EOF, so the write end must be closed on the
      // same tick or the process never exits and the clipboard never updates.
      copyProc.stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (copyProc.stdinEnabled === false) copyProc.stdinEnabled = true
      copyProc.succeeded = (exitCode === 0)
      var ok = copyProc.succeeded
      copyProc.pending = ""
      // Confirm AFTER the exit status, not before. The old code announced
      // success at the moment it queued the copy, so it claimed success even
      // when a second click silently dropped the payload (setting running=true
      // on a live Process is a no-op, so onStarted never re-fired and onExited
      // then discarded the text), and even when wl-copy itself failed.
      if (root.notifyEnabled) {
        root.notify("OmaDoctor",
          ok ? "Diagnostic report copied (redacted)."
             : "Could not copy the report -- wl-copy exited " + exitCode + ".",
          Model.glyph(ok ? "ok" : "problem"),
          ok ? "normal" : "critical")
      }
    }
  }

  // The background poll. Disabled entirely when pollSeconds is 0, which is the
  // default: a quick scan is a multi-process ~2s run, and doing that every 30
  // seconds forever on every monitor, purely to keep a bar glyph fresh, is the
  // plugin's largest steady-state cost. The panel still runs a full scan when
  // opened, so nothing is lost except background freshness.
  Timer {
    id: pollTimer
    interval: root.pollMs > 0 ? root.pollMs : 60000
    running: root.pollMs > 0
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!root.opened) root.refresh("quick")
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.clockSec = Math.floor(Date.now() / 1000)
  }

  // Seed the "what changed" baseline from disk before the first scan, so a
  // shell restart does not leave the feature blind. Wrapped because the history
  // directory may not exist yet on a first run, and a missing baseline is a
  // normal state rather than an error.
  Component.onCompleted: {
    root.loadBaselineFromHistory()
    hostnameProc.running = true
    root.probeAi()
    refresh("quick")
  }

  // Opening the panel is the moment the user is actually looking, so this is
  // where a full (network-inclusive) scan earns its cost. It counts as
  // user-initiated: they opened the panel to read the result, so a notification
  // restating it would be noise.
  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      selectedIndex = -1
      refresh("full", true)
    } else {
      // Closing hands the pointer back to the desktop; without this a row would
      // stay lit the whole time the panel is shut.
      hoveredCheckId = ""
    }
  }

  // ---------------------------------------------------------- keyboard nav
  // One cursor, shared by keyboard and mouse, so the highlight is never
  // ambiguous. The rows are the two actions; findings are listed, not walked.
  // The actions come first because they are what a user opens the panel to do.
  property bool cursorActive: false
  property int selectedIndex: -1
  // Three actions: full diagnosis, copy report, ask AI. Ask AI is last because
  // it is the only one that can leave the machine.
  readonly property int rowCount: 3

  function moveCursor(dy) {
    var n = root.rowCount
    if (n <= 0) return
    if (!root.cursorActive) {
      root.cursorActive = true
      root.selectedIndex = 0
      return
    }
    var next = root.selectedIndex + dy
    if (next < 0) next = n - 1
    if (next > n - 1) next = 0
    root.selectedIndex = next
  }

  function activateCursor() {
    if (!root.cursorActive) return
    if (root.selectedIndex === 0) root.refresh("full", true)
    else if (root.selectedIndex === 1) root.copyReport()
    else root.askAi()
  }

  // ================================================================= Ask AI
  //
  // The point of a diagnostic tool is that the person reading it often does not
  // already know the answer. This hands the redacted report to WHATEVER AI the
  // user has installed, asks it to research the problem and propose a fix, and
  // puts the answer where they can read it.
  //
  // It is discover-first, not opencode-first. Hardcoding one assistant would
  // make the plugin useless for everyone who does not have that one installed,
  // so the AI is resolved from the user's own PATH at runtime -- probed once at
  // startup, off the UI thread -- and can be overridden with a single setting
  // for anything this list does not know about.
  //
  // Privacy posture, stated plainly because it is the whole tension here: this
  // plugin promises nothing leaves the machine, and an AI query does. So nothing
  // is ever sent on the plugin's initiative. It resolves a command, shows it,
  // shows what will be sent, and waits for confirmation. The no-send path (copy
  // the prompt and paste it yourself) is always available.

  // Each candidate accepts a prompt on STDIN and prints a reply on stdout.
  //
  // This list is a convenience, not a contract. Anything not in it works
  // through the askAiCommand setting, which takes a full command line.
  readonly property var aiCandidates: [
    "opencode",            // interactive TUI; given the report via --prompt
    "mods -s",
    "llm -s",
    "aichat",
    "fabric",
    "aider --message",
    "gemini",
    "claude -p",
    "codex exec"
  ]

  // Probed once at startup, under the hardened PATH so a shadow executable on
  // the interactive PATH can never be what gets run. Maps command name -> true.
  property var aiOnPath: ({})

  readonly property string aiModel: String(root.setting("askAiModel", "") || "")
  readonly property string aiOverride: String(root.setting("askAiCommand", "") || "").trim()

  readonly property string resolvedAiCommand: {
    if (root.aiOverride !== "") return root.aiOverride
    for (var i = 0; i < root.aiCandidates.length; i++) {
      var line = root.aiCandidates[i]
      var bin = line.split(" ")[0]
      if (!root.aiOnPath[bin]) continue
      return line
    }
    // ollama is probed for, but unlike the candidates above it has no
    // "use the default model" mode, so it can only be selected when a
    // model has been configured. Without one, skip it rather than guess.
    if (root.aiOnPath["ollama"] && root.aiModel !== "")
      return "ollama run " + root.aiModel
    return ""
  }

  function probeAi() {
    var found = {}
    var lines = []
    for (var i = 0; i < root.aiCandidates.length; i++) {
      lines.push(root.aiCandidates[i].split(" ")[0])
    }
    lines.push("ollama")
    // one "which" per distinct binary, run sequentially so the fork cost is a
    // single short burst at startup rather than ten at once
    var queue = []
    var seen = {}
    for (var j = 0; j < lines.length; j++) {
      if (!lines[j] || seen[lines[j]]) continue
      seen[lines[j]] = true
      queue.push(lines[j])
    }
    aiProbeQueue = queue
    aiProbeFound = found
    aiProbeNext()
  }

  property var aiProbeQueue: []
  property var aiProbeFound: ({})
  property int aiProbeIndex: 0

  function aiProbeNext() {
    if (aiProbeIndex >= aiProbeQueue.length) {
      aiOnPath = aiProbeFound
      return
    }
    aiProbeProc.name = aiProbeQueue[aiProbeIndex]
    aiProbeProc.command = ["/usr/bin/which", aiProbeProc.name]
    aiProbeProc.running = true
  }

  // Probed WITHOUT clearEnvironment, unlike every other process in this file.
  //
  // The backend's pinned PATH=/usr/bin:/bin is a security control: it stops a
  // shadow executable anywhere on the interactive PATH from being resolved for
  // something that inspects the machine. That reasoning does not transfer to
  // finding the USER'S OWN assistant. Package managers put these in
  // ~/.local/bin, nix profiles, mise shims, /opt; opencode on this machine is
  // under ~/.local/share/mise and is simply not visible to /usr/bin. Probing
  // with the hardened PATH finds nothing and reports "no AI installed" on a
  // machine that has one.
  //
  // Nothing is executed during discovery -- only `which <name>` -- and the
  // result is still only a suggestion the user confirms before anything runs.
  Process {
    id: aiProbeProc
    property string name: ""
    // SplitParser inherits DataStreamParser's `read(data)` and re-emits it per
    // split chunk. It has no onStreamReceived: naming one is not a warning, it
    // is "Cannot assign to non-existent property", which fails the whole
    // widget load and silently removes it from the bar.
    stdout: SplitParser {
      onRead: function(data) {
        if (String(data).trim() !== "") aiProbeFound[aiProbeProc.name] = true
      }
    }
    // Sequentially, one `which` at a time: ten short-lived processes at once is
    // a burst of forks for something whose answer is needed exactly once.
    onExited: function(exitCode) {
      aiProbeIndex = aiProbeIndex + 1
      aiProbeNext()
    }
  }

  // Split a command line into an argv, honouring quotes so a path or model name
  // containing a space survives. The result is passed straight to Process.command
  // -- never to a shell, so nothing in it can be interpreted as syntax.
  function splitCommand(line) {
    var out = []
    var cur = ""
    var quote = ""
    var has = false
    for (var i = 0; i < line.length; i++) {
      var ch = line.charAt(i)
      if (quote !== "") {
        if (ch === quote) { quote = ""; continue }
        cur += ch; has = true; continue
      }
      if (ch === "'" || ch === "\"") { quote = ch; has = true; continue }
      if (ch === " " || ch === "\t") {
        if (has) { out.push(cur); cur = ""; has = false }
        continue
      }
      cur += ch; has = true
    }
    if (has) out.push(cur)
    return out
  }

  function askAiPrompt() {
    return "A system diagnostic report from OmaDoctor, a read-only diagnostic " +
      "tool for Omarchy, is below. It has already been redacted.\n\n" +
      root.reportText() +
      "\n\n---\n\nPlease do the following:\n" +
      "1. Identify every finding that indicates a real fault, and say which are " +
      "expected on a healthy machine.\n" +
      "2. Search the web for each real fault: the upstream issue tracker, the " +
      "Arch Linux forums, the Hyprland or Omarchy documentation, or the " +
      "project's own bug tracker.\n" +
      "3. For each, give the most likely cause and a specific fix, with the " +
      "commands to run or the file to edit.\n" +
      "4. Say plainly where you are guessing, and cite a URL for every claim " +
      "you did not derive from the report itself.\n\n" +
      "OmaDoctor never repairs anything, so nothing in the report has already " +
      "been changed."
  }

  // askAi() -> resolve, confirm, run. Never sends without the confirmation.
  function askAi() {
    if (!root.ready) {
      root.notify("OmaDoctor", "No scan yet -- run a diagnosis first.",
        Model.glyph("info"), "normal")
      return
    }
    if (root.aiRunning) {
      root.notify("OmaDoctor", "An AI query is already running.",
        Model.glyph("info"), "normal")
      return
    }
    if (root.resolvedAiCommand === "") {
      // Nothing installed that this plugin knows how to drive. Do not silently
      // do nothing: hand over the prompt so the feature still works with
      // whatever the user actually has.
      if (root.copyText(root.askAiPrompt()))
        root.notify("OmaDoctor",
          "No supported AI CLI found -- the prompt is on your clipboard.",
          Model.glyph("attention"), "normal")
      else
        root.notify("OmaDoctor",
          "No supported AI CLI found, and the clipboard is busy -- the prompt was not copied.",
          Model.glyph("attention"), "normal")
      return
    }
    root.aiPendingPrompt = root.askAiPrompt()
    root.aiConfirmOpened = true
  }

  // The no-send path: always available, works with any assistant at all.
  function copyAiPrompt() {
    if (!root.copyText("Ask AI about these OmaDoctor findings:\n\n" + root.askAiPrompt()))
      root.notify("OmaDoctor", "Clipboard is busy with the previous copy -- try again in a moment.",
        Model.glyph("attention"), "normal")
  }

  // copyText(text) -> the clipboard, via one guarded stdin writer.
  function copyText(text) {
    if (copyProc.running) return false
    copyProc.pending = String(text || "")
    copyProc.running = true
    return true
  }

  function runAi() {
    var argv = root.splitCommand(root.resolvedAiCommand)
    if (argv.length === 0) return
    root.aiConfirmOpened = false
    root.aiRunning = true
    // Stage the prompt on disk: the AI runs in a terminal, not a hidden pipe,
    // so its stdin comes from the terminal itself. The file path therefore has
    // to be the hand-off, never argv (world-readable in /proc).
    aiPromptProc.command = ["/usr/bin/tee", root.aiPromptPath]
    aiPromptProc.pending = root.aiPendingPrompt
    aiPromptProc.running = true
  }

  // Launch the AI as an interactive program: its TUI/REPL needs a terminal
  // window, so it opens in the user's default terminal and runs there directly.
  // The staged prompt file is the hand-off, so the report never appears in
  // argv (world-readable in /proc).
  function launchAiInTerminal() {
    var argv = root.splitCommand(root.resolvedAiCommand)
    if (argv.length === 0) { root.aiRunning = false; return }
    var bin = String(argv[0]).split("/").pop()
    var script
    if (bin === "opencode") {
      // opencode's TUI cannot take the prompt on stdin; --prompt is its
      // documented pre-loaded prompt. Point it at the staged file so the
      // report itself never lands in argv either.
      argv = ["opencode", "--prompt",
              "Read the diagnostic report in \"" + root.aiPromptPath +
              "\" and carry out its instructions in full."]
      script = null
    } else {
      var esc = String(root.aiPromptPath).replace(/(["\\$`])/g, "\\$1")
      script = '"$@" < "' + esc + '"'
    }
    var cmd = script !== null
      ? ["/bin/sh", "-c", script, "sh"].concat(argv)
      : argv
    aiLaunchProc.command = ["/usr/share/omarchy/bin/omarchy-launch-terminal"].concat(cmd)
    aiLaunchProc.running = true
    root.aiRunning = false
    root.notify("OmaDoctor",
      "Sent the report to " + root.resolvedAiCommand + ".",
      Model.glyph("ok"), "normal")
  }

  function cancelAi() {
    root.aiConfirmOpened = false
  }

  // The text that will be sent, IN FULL, put through the SAME redactor as the
  // report so the preview cannot leak what the report itself would not.
  //
  // Deliberately NOT truncated. This used to slice to 300 chars, and the preview
  // box capped its own height at 150px, so the report could not actually be read
  // -- which defeats the entire point of a consent screen. The sheet now scrolls
  // (see the Flickable around this text), so the whole prompt is reachable
  // rather than hidden behind an ellipsis.
  readonly property string aiPreview: {
    if (!root.aiPendingPrompt) return ""
    return Model.redact(root.aiPendingPrompt, root.redactInfo)
  }

  property string aiPendingPrompt: ""
  property bool aiConfirmOpened: false
  property bool aiRunning: false
  readonly property string aiAnswerPath: root.stateDir + "/ai-answer.txt"
  readonly property string aiPromptPath: root.stateDir + "/ai-prompt.txt"

  // Also inherits the environment, and this is deliberate for the same reason.
  // An assistant CLI needs the things the hardened environment deliberately
  // withholds: its API credentials, its own PATH entry so it can find node or
  // python, and its config directory. Running one under PATH=/usr/bin:/bin
  // with no HOME-derived variables would fail on most machines.
  //
  // The trade-off is explicit: this process runs the user's own tool, with the
  // user's own environment, on a command the user has just confirmed. It is not
  // a security boundary -- which is exactly why it cannot be triggered by
  // anything except a click or an explicit IPC call that still opens the
  // confirmation sheet.
  Process {
    id: aiPromptProc
    clearEnvironment: true
    environment: root.trustedEnv()
    stdinEnabled: true
    property string pending: ""
    onStarted: {
      if (aiPromptProc.pending !== "") aiPromptProc.write(aiPromptProc.pending)
      aiPromptProc.stdinEnabled = false
    }
    onExited: function(exitCode) {
      if (aiPromptProc.stdinEnabled === false) aiPromptProc.stdinEnabled = true
      aiPromptProc.pending = ""
      if (exitCode !== 0) {
        root.aiRunning = false
        root.notify("OmaDoctor",
          "Could not stage the report for the AI (tee exited " + exitCode + ").",
          Model.glyph("problem"), "critical")
        return
      }
      root.launchAiInTerminal()
    }
  }

  // The AI itself. Deliberately NOT the hardened environment (see above) --
  // the user's assistant needs their real PATH, credentials and config.
  Process {
    id: aiLaunchProc
    onExited: function() {
      // omarchy-launch-terminal setsids the terminal away, so this exits
      // immediately after spawning; nothing to report.
    }
  }

  // ---------------------------------------------------------- the bar icon
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // NEVER empty. BarIconButton reports hasVisualContent === false for empty
    // text, which makes WidgetButton.visible false, which makes the bar slot
    // report implicitWidth 0 -- so the widget occupied no space at all until the
    // first scan landed (~2s after every shell start and after every plugin
    // reload), and the "checking..." tooltip below could never be seen, because
    // WidgetButton hides the tooltip of an invisible button. A neutral glyph
    // keeps the slot correctly sized from the first frame.
    text: root.ready ? root.stateGlyph : Model.glyph("info")
    tooltipText: root.ready
      ? "OmaDoctor - " + Model.stateLabel(root.state).toLowerCase() +
        (root.issueCount > 0 ? " - " + root.issueCount + " to review" : "")
      : "OmaDoctor - checking..."
    onPressed: function(b) {
      if (b === Qt.RightButton) root.refresh("full", true)
      else root.toggle()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: button.glyphPaintedWidth
  readonly property real openPanelIndicatorHeight: Math.max(
    Style.space(10), Math.round(Style.bar.iconSlot * 0.55))

  // ------------------------------------------------------------- the panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // WIDER and TALLER while the sheet is up. A diagnostic report is a
    // fixed-width, 52-column monospace document; rendered at 420px in the
    // caption font it was not legible, and a consent screen you cannot read is
    // not consent. The sheet inside scrolls, so the extra height buys readable
    // lines rather than more lines. fittedContentWidth/Height cap both to the
    // screen, so this degrades safely on a small display rather than
    // overflowing it.
    contentWidth: panel.fittedContentWidth(
      root.aiConfirmOpened ? Style.space(760) : Style.space(420))
    contentHeight: panel.fittedContentHeight(
      root.aiConfirmOpened ? Style.space(560) : body.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the AI confirmation is up, the panel's own cursor must not move
      // and Enter must not start another scan. The overlay handles its own keys.
      onMoveRequested: function(dx, dy) { if (!root.aiConfirmOpened) root.moveCursor(dx !== 0 ? dx : dy) }
      onActivateRequested: if (!root.aiConfirmOpened) root.activateCursor()
      onCloseRequested: root.aiConfirmOpened ? root.cancelAi() : root.close()
      onTabRequested: function(direction) { if (!root.aiConfirmOpened) root.switchPanel(direction) }

      Flickable {
        id: scroll
        width: parent.width
        height: parent.height
        // Hidden while the Ask AI sheet is up. The sheet paints over this area
        // (it is declared LAST in this keyCatcher -- see below), but a Flickable
        // underneath a visible overlay still accepts drags, and the FindingRow
        // MouseAreas still fire hover, so the body could be scrolled and
        // highlight-lit from behind a modal.
        //
        // Safe for sizing: both this Flickable's contentHeight and the panel's
        // own contentHeight bind to body.implicitHeight, which does not depend
        // on this item's `visible` -- so the panel does not resize when the
        // sheet opens or closes.
        visible: !root.aiConfirmOpened
        contentHeight: body.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: body
          width: scroll.width
          spacing: Style.spacing.lg

          // ---------------------------------------------------------- hero
          PanelHero {
            id: hero
            width: parent.width
            foreground: root.foreground
            fontFamily: root.fontFamily
            title: root.ready ? Model.stateLabel(root.state) : "Checking..."
            meta: root.ready
              ? root.totals.total + " checks - " +
                (root.issueCount > 0 ? root.issueCount + " need attention" : "nothing to review")
              : "running first scan"
            detail: root.ready
              ? "checked " + Model.fmtAge(Number(root.scan.ts || 0), root.nowSec) +
                " - " + (root.lastMode === "full" ? "full scan" : "quick scan")
              : ""
            iconComponent: Component {
              Text {
                text: root.ready ? root.stateGlyph : ""
                textFormat: Text.PlainText
                color: root.stateColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // A parse failure is surfaced, never silently swallowed.
          Text {
            width: parent.width
            visible: root.lastError !== ""
            text: "! " + root.lastError
            color: root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          // What moved since the previous scan. Deliberately a single line and
          // deliberately muted: it is context, not an alarm. It appears only
          // when a check's STATUS changed -- never for a value that merely
          // shifted, because uptime and latency move on every single scan and a
          // line that always has something to say is noise.
          Text {
            width: parent.width
            visible: root.changeLine !== ""
            text: root.changeLine
            // Urgent when something got worse, plain when something recovered.
            // The summary does not carry the direction, so take it from the
            // diff itself rather than guessing from the wording.
            color: root.lastDiff && root.lastDiff.worse.length > 0
              ? root.accent : Qt.darker(root.foreground, 1.3)
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // ------------------------------------------------- action buttons
          // Labelled Buttons rather than icon-only PanelActionButtons. Two
          // bare icons read as utilitarian; naming the two actions is what makes
          // them obvious without a tooltip round-trip.
          //
          // Emphasis is a LOW-ALPHA accent tint, never a solid accent fill:
          // Button paints its own label in `foreground`, and this theme has
          // accent == foreground, so a solid accent fill would render the label
          // invisible (light text on light background). The tint separates the
          // primary without fighting the label.
          Row {
            spacing: Style.spacing.sm
            width: parent.width

            Button {
              id: fullButton
              iconText: "󰃬"
              text: "Run full diagnosis"
              tooltipText: "Run full diagnosis (includes network)"
              foreground: root.foreground
              accent: root.accent
              background: Util.alpha(root.accent, 0.10)
              bordered: true
              hasCursor: root.cursorActive && root.selectedIndex === 0
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX - Style.space(2)
              verticalPadding: Style.spacing.controlPaddingY - Style.space(1)
              onClicked: root.refresh("full", true)
            }

            Button {
              id: copyButton
              iconText: "󰅏"
              text: "Copy report"
              tooltipText: "Copy redacted report"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              enabled: root.ready
              hasCursor: root.cursorActive && root.selectedIndex === 1
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX - Style.space(2)
              verticalPadding: Style.spacing.controlPaddingY - Style.space(1)
              onClicked: root.copyReport()
            }

            Button {
              id: aiButton
              iconText: "󰚩"
              text: "Ask AI"
              tooltipText: root.resolvedAiCommand !== ""
                ? "Send the redacted report to " + root.resolvedAiCommand
                : "Copy a ready-to-paste prompt (no AI CLI found)"
              foreground: root.foreground
              accent: root.accent
              bordered: true
              enabled: root.ready && !root.aiRunning
              hasCursor: root.cursorActive && root.selectedIndex === 2
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX - Style.space(2)
              verticalPadding: Style.spacing.controlPaddingY - Style.space(1)
              onClicked: root.askAi()
            }

            // Fill whatever horizontal space the two labelled buttons leave,
            // whatever their theme-driven widths turn out to be. The old fixed
            // subtraction (two 22px icon buttons) would now overflow the Row.
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(0, parent.width
                     - fullButton.width - copyButton.width - aiButton.width
                     - Style.spacing.sm * 3)
              text: root.scanning
                ? "scanning..."
                : (root.ready ? "last checked " + Model.fmtAge(Number(root.scan.ts || 0), root.nowSec) : "")
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          PanelSeparator { width: parent.width; foreground: root.foreground }

          // ------------------------------------------------------ findings
          // Grouped by category, and only categories with something to
          // report. A wall of passing checks buries the finding; the copied
          // report still carries the full picture.

          // The all-clear state. When nothing needs review this is the WHOLE
          // panel body, so a lone muted sentence left it looking unfinished
          // rather than calm. Instead: a large state glyph, a bold headline
          // drawn from the actual counts, and the per-bucket breakdown -- so
          // the healthy case reads as a composed result, not an absence.
          //
          // Wording comes from Model.summaryLine/breakdownLine rather than being
          // hardcoded, so it can never disagree with the scan it describes.
          Column {
            width: parent.width
            visible: root.ready && root.rows.length === 0
            // Breathing room above and below: this block is centred in what is
            // left of the panel, not crammed under the separator.
            topPadding: Style.spacing.huge
            bottomPadding: Style.spacing.huge
            spacing: Style.spacing.sm

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: Model.glyph("ok")
              color: root.stateColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.displayLarge
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              text: Model.summaryLine(root.totals)
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              horizontalAlignment: Text.AlignHCenter
              visible: Model.breakdownLine(root.totals) !== ""
              text: Model.breakdownLine(root.totals)
              color: Qt.darker(root.foreground, 1.35)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          // Pre-first-scan placeholder, before there is any tally to compose.
          Text {
            width: parent.width
            visible: !root.ready
            text: "No scan data yet."
            color: Qt.darker(root.foreground, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
          }

          // ONE flat Repeater over Model.findingRows(). The previous version
          // nested a Repeater inside the delegate of another; the inner one
          // could not see the outer delegate's modelData, so headers rendered
          // with no rows beneath them. Flat list, flat Repeater, no scoping
          // to get wrong.
          Repeater {
            model: root.rows

            Column {
              width: body.width
              // A header needs breathing room above it; a check row only needs
              // a hairline gap from the one above it.
              spacing: 0
              topPadding: modelData.kind === "header" ? Style.spacing.lg : 0
              bottomPadding: modelData.kind === "check" ? Style.spacing.xs : 0

              PanelSectionHeader {
                width: parent.width
                visible: modelData.kind === "header"
                text: modelData.kind === "header" ? String(modelData.category) : ""
              }

              // The check row is a real CursorSurface so it highlights on hover
              // with the kit's own fill and border. Everything inside it is the
              // previous content, unchanged -- only the wrapper is new.
              FindingRow {
                width: parent.width
                visible: modelData.kind === "check"
                rowData: modelData
              }
            }
          }
        }
      }

      // ------------------------------------------------- Ask AI confirmation
      //
      // A modal over the panel, because this is the one action that can send
      // data off the machine. It states the exact command that will run, shows
      // a preview of the text that will be sent, and offers three ways out:
      // send it, copy it instead, or cancel.
      // BorderSurface, not Rectangle: `borderSpec` is a BorderSurface property,
      // and assigning it to a plain Rectangle is "Cannot assign to non-existent
      // property" -- which fails the whole widget load and silently removes the
      // plugin from the bar with nothing but one journal line to show for it.
      //
      // It MUST stay the LAST child of this keyCatcher. QML paints siblings in
      // declaration order, so with the sheet declared before the Flickable the
      // body painted straight over it: both fill the same rect (anchors.fill
      // here, width/height = parent on the Flickable), so the sheet's text and
      // the hero/findings text interleaved into an unreadable overlap instead
      // of one opaque modal covering the other.
      BorderSurface {
        id: aiSheet
        anchors.fill: parent
        visible: root.aiConfirmOpened
        // FULLY OPAQUE, and on the popup surface rather than Color.background.
        //
        // Util.alpha(c, a) SETS alpha to a -- it does not multiply -- so the
        // previous Util.alpha(Color.background, 0.94) meant 6% of whatever was
        // behind the sheet showed through, and on a bright wallpaper that
        // bleed-through was plainly readable as ghosting behind the prompt.
        //
        // Color.popups.background is what the card underneath is painted with
        // (see PopupCard: `color: Color.popups.background`), so using it makes
        // the seam between sheet and card invisible. The alpha is forced to 1
        // on top of that, because a theme may set popups.background-alpha below
        // 1.0 for the card's sake -- but a consent dialog must not be see-through
        // whatever the theme says.
        color: Util.alpha(Color.popups.background, 1.0)
        borderSpec: Border.flat(root.accent, Style.normalBorderWidth)
        radius: Style.cornerRadius

        FocusScope {
          anchors.fill: parent
          // root.aiConfirmOpened, NOT the bare `visible` identifier. Inside this
          // binding, `visible` resolves to the FocusScope's OWN visible property
          // -- which is never assigned, so it is a constant true. That left the
          // sheet's key handler (Esc / Enter / c) permanently live rather than
          // scoped to "sheet is showing".
          focus: root.aiConfirmOpened
          Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) { root.cancelAi(); event.accepted = true; return }
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
              root.runAi(); event.accepted = true; return
            }
            if (event.text === "c") { root.copyAiPrompt(); root.cancelAi(); event.accepted = true }
          }

          // Header pinned top, actions pinned bottom, and the REPORT in the
          // scrollable space between them.
          //
          // This was one Column sized to the card, and it broke two ways: the
          // preview box clamped its own height to 150px, so the report was cut
          // off mid-line with no way to reach the rest of it, and the column
          // could grow taller than the card, laying the footer and the three
          // buttons out BELOW the card's bottom border, floating over the
          // desktop. Pinning the ends and giving the middle its own Flickable
          // fixes both, and means the actions stay reachable no matter how long
          // the report is.
          //
          // Nothing here depends on an implicitHeight, which matters: the
          // card's size is decided by the KeyboardPanel's contentWidth and
          // contentHeight above, and the previous version reached back up into
          // that binding for an id this sheet no longer had.
          Item {
            id: aiSheetBody
            anchors.fill: parent
            anchors.margins: Style.space(16)

            Column {
              id: aiHeader
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              spacing: Style.spacing.sm

              Text {
                width: parent.width
                text: "Send this report to your AI?"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.title
                font.bold: true
              }

              Text {
                width: parent.width
                text: "Command:  " + root.resolvedAiCommand
                color: root.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WrapAnywhere
                elide: Text.ElideRight
                maximumLineCount: 2
              }

              Text {
                width: parent.width
                text: root.resolvedAiCommand.indexOf("ollama ") === 0
                  ? "A LOCAL model runs this. Nothing leaves your machine."
                  : "This sends the redacted report to a remote provider. Read it before you continue."
                color: root.resolvedAiCommand.indexOf("ollama ") === 0
                  ? root.foreground : root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            // Exactly what will leave the machine. This is the whole point of
            // the sheet, so it takes all the space the header and the actions
            // do not need, and scrolls.
            //
            // Anchored between the two rather than sized from its text: on a
            // small display fittedContentHeight caps the card, and this simply
            // gets shorter instead of pushing the buttons off the bottom.
            BorderSurface {
              id: aiPreviewBox
              anchors.top: aiHeader.bottom
              anchors.topMargin: Style.spacing.md
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: aiFooter.top
              anchors.bottomMargin: Style.spacing.md
              color: Util.alpha(root.foreground, 0.06)
              radius: Style.cornerRadius
              borderSpec: Border.flat(Util.alpha(root.foreground, 0.15), 1)
              clip: true

              Flickable {
                id: aiPreviewScroll
                anchors.fill: parent
                anchors.margins: Style.space(6)
                contentHeight: aiPreviewText.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Text {
                  id: aiPreviewText
                  width: aiPreviewScroll.width
                  text: root.aiPreview
                  color: root.foreground
                  font.family: root.fontFamily
                  // One step up from caption. The card is now wide enough that
                  // the report's 52-column rule fits on one line without
                  // wrapping, so the only thing standing between the reader and
                  // a legible document was the size of the type.
                  font.pixelSize: Style.font.bodySmall
                  // WordWrap, NOT WrapAnywhere. The report is monospace with
                  // deliberate column alignment; breaking mid-token is what
                  // destroys the only thing that makes it readable.
                  wrapMode: Text.WordWrap
                }
              }
            }

            Text {
              id: aiFooter
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: aiActions.top
              anchors.bottomMargin: Style.spacing.sm
              text: "Enter sends   ·   c copies the prompt instead   ·   Esc cancels"
              color: Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              id: aiActions
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: Style.spacing.sm

              Button {
                width: Math.max(1, (parent.width - Style.spacing.sm * 2) / 3)
                text: "Send"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontSize: Style.font.bodySmall
                onClicked: root.runAi()
              }
              Button {
                width: Math.max(1, (parent.width - Style.spacing.sm * 2) / 3)
                text: "Copy"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontSize: Style.font.bodySmall
                onClicked: { root.copyAiPrompt(); root.cancelAi() }
              }
              Button {
                width: Math.max(1, (parent.width - Style.spacing.sm * 2) / 3)
                text: "Cancel"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                fontSize: Style.font.bodySmall
                onClicked: root.cancelAi()
              }
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------ reusable inline component

  // One finding row: a hover-highlighted CursorSurface wrapping the check's
  // glyph, title, value, evidence and suggested fix.
  //
  // An inline component (like SinkRow/SourceRow in the first-party audio panel)
  // rather than a nested Repeater delegate, so it can be reasoned about as one
  // unit and reused if the layout changes. It must NOT read containsMouse for
  // its own fill or border -- the MouseArea below only writes the root's
  // hoveredCheckId, and hasCursor is the single source of truth, which is what
  // keeps exactly one row highlighted at a time.
  component FindingRow: CursorSurface {
    id: findingRow

    // The flat findingRows entry: { kind: "header" | "check", check }.
    required property var rowData

    // Header entries have no `check`. Every access below goes through these two
    // guards rather than testing rowData.check directly, because QML evaluates
    // bindings on invisible items too -- reading rowData.check.id unguarded
    // would throw "Cannot read property of undefined" for header rows.
    readonly property bool isCheck: !!rowData && rowData.kind === "check"
    readonly property var check: isCheck ? rowData.check : null
    readonly property string checkId: check ? String(check.id) : ""

    hasCursor: checkId !== "" && root.hoveredCheckId === checkId

    foreground: root.foreground
    accent: root.stateColor
    // Tint the hover with the row's own state so a problem row reads hotter on
    // hover than an attention row, matching the glyph. CursorSurface already
    // paints the hover-cursor border off hasCursor, so borderSpec is left to it.
    fill: Style.hoverFillFor(root.foreground, root.stateColor)
    currentFill: Style.selectedFillFor(root.foreground, root.stateColor)
    radius: Style.cornerRadius

    implicitHeight: findingInner.implicitHeight + Style.spacing.xl

    Row {
      id: findingInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.spacing.sm

      Text {
        width: Style.space(18)
        text: findingRow.isCheck ? Model.glyph(findingRow.check.status) : ""
        color: !findingRow.isCheck ? root.foreground
             : (findingRow.check.status === "problem" ? root.urgent
             : (findingRow.check.status === "attention" ? root.accent : root.foreground))
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }

      Column {
        width: parent.width - Style.space(18) - Style.spacing.sm
        spacing: 1

        Text {
          width: parent.width
          visible: findingRow.isCheck
          text: findingRow.isCheck ? findingRow.check.title : ""
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: findingRow.isCheck && findingRow.check.status === "problem"
          elide: Text.ElideRight
        }

        Text {
          width: parent.width
          visible: findingRow.isCheck && findingRow.check.value !== ""
          text: findingRow.isCheck ? findingRow.check.value : ""
          color: Qt.darker(root.foreground, 1.25)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideRight
        }

        // Evidence and the suggested fix are the reason the panel exists, so
        // both are always shown for a finding.
        Text {
          width: parent.width
          visible: findingRow.isCheck && findingRow.check.detail !== ""
          text: findingRow.isCheck ? findingRow.check.detail : ""
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: findingRow.isCheck && findingRow.check.suggestion !== ""
          text: findingRow.isCheck ? "-> " + findingRow.check.suggestion : ""
          color: root.accent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }

    // The ONLY writer of root.hoveredCheckId. Hover in, highlight; hover out,
    // clear -- but only clear if this row still owns the highlight, so moving
    // between two rows does not flicker.
    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      acceptedButtons: Qt.NoButton
      onContainsMouseChanged: {
        if (containsMouse) {
          root.hoveredCheckId = findingRow.checkId
        } else if (root.hoveredCheckId === findingRow.checkId) {
          root.hoveredCheckId = ""
        }
      }
    }
  }
}