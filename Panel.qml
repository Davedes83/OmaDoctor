import QtQuick
import QtQuick.Controls
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

  // A background quick scan is local-only and cheap, so the bar stays current
  // without the panel ever being opened.
  readonly property int pollMs: 30000

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
    if (scanProc.running) {
      // A scan is already in flight. Opening the panel during a quick scan must
      // still end up with the network section, so remember the upgrade and
      // honour it once the current scan lands rather than dropping it.
      if (requested === "full") queuedFull = true
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
  }

  property string pendingMode: "quick"
  property bool queuedFull: false
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

  function onScanFinished(raw) {
    scanning = false
    lastMode = pendingMode
    var parsed = Model.parseDoctor(root.capText(raw))
    if (!parsed) {
      // A malformed payload must not replace a good scan: keep the last known
      // state on screen and surface the failure rather than blanking the panel.
      lastError = "could not read scan output"
    } else {
      scan = parsed
      lastError = ""
      // Diff BEFORE advancing the baseline: the comparison is against what was
      // true before this scan, not against itself.
      root.lastDiff = root.baselineScan ? Model.diffScans(root.baselineScan, parsed) : null
      root.baselineScan = parsed
      root.maybeNotify(parsed)
    }
    if (root.queuedFull) {
      root.queuedFull = false
      root.refresh("full", false)
    }
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
          { userInitiated: root.pendingUserInitiated })) {
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

  // --------------------------------------------------------------- report
  function reportText() {
    if (!root.lastRawJson) return ""
    return Model.buildReportText(root.lastRawJson, {
      now: root.clockSec,
      redactInfo: {
        hostname: Quickshell.env("HOSTNAME") || "",
        username: Quickshell.env("USER") || "",
        home: Quickshell.env("HOME") || ""
      },
      redact: true,
      pluginVersion: root.pluginVersion
    })
  }

  function copyReport() {
    var text = root.reportText()
    if (!text) {
      root.notify("OmaDoctor", "No scan yet -- run a diagnosis first.")
      return
    }
    // Fed over stdin rather than argv: the report is large and carries user
    // data, and argv is world-readable in /proc.
    copyProc.pending = text
    copyProc.running = true
    root.notify("OmaDoctor", "Diagnostic report copied (redacted).")
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

    function state(): string {
      return JSON.stringify({
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
  readonly property string runnerPath: Qt.resolvedUrl("backend/run-capped.sh").toString().replace("file://", "")
  readonly property string doctorPath: Qt.resolvedUrl("backend/doctor.sh").toString().replace("file://", "")
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
  readonly property var trustedEnv: ({
    "PATH": "/usr/bin:/bin",
    "HOME": Quickshell.env("HOME"),
    "LC_ALL": "C",
    "HYPRLAND_INSTANCE_SIGNATURE": Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || "",
    "XDG_RUNTIME_DIR": Quickshell.env("XDG_RUNTIME_DIR") || ""
  })

  function capText(text) {
    return typeof text === "string" && text.length > root.maxOutputBytes
      ? text.slice(0, root.maxOutputBytes) : (text || "")
  }

  Process {
    id: scanProc
    clearEnvironment: true
    environment: root.trustedEnv
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.lastRawJson = root.capText(text)
        root.onScanFinished(text)
      }
    }
  }

  // Copies the report via stdin so a multi-kilobyte report never becomes an
  // argv entry.
  Process {
    id: copyProc
    clearEnvironment: true
    environment: root.trustedEnv
    stdinEnabled: true
    command: ["/usr/bin/wl-copy"]
    property string pending: ""
    onStarted: {
      if (copyProc.pending !== "") {
        copyProc.write(copyProc.pending)
      }
      copyProc.stdinEnabled = false
    }
    onExited: function(exitCode, exitStatus) {
      if (copyProc.stdinEnabled === false) copyProc.stdinEnabled = true
      copyProc.pending = ""
    }
  }

  Timer {
    id: pollTimer
    interval: root.pollMs
    running: true
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
    }
  }

  // ---------------------------------------------------------- keyboard nav
  // One cursor, shared by keyboard and mouse, so the highlight is never
  // ambiguous. The rows are the two actions; findings are listed, not walked.
  // The actions come first because they are what a user opens the panel to do.
  property bool cursorActive: false
  property int selectedIndex: -1
  readonly property int rowCount: 2

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
  }

  // ---------------------------------------------------------- the bar icon
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.ready ? root.stateGlyph : ""
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
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(body.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: scroll
        width: parent.width
        height: parent.height
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
          Row {
            spacing: Style.spacing.sm
            width: parent.width

            PanelActionButton {
              id: fullButton
              iconText: "󰃬"
              tooltipText: "Run full diagnosis (includes network)"
              foreground: root.foreground
              hasCursor: root.cursorActive && root.selectedIndex === 0
              size: Style.spacing.controlHeight
              onClicked: root.refresh("full", true)
            }

            PanelActionButton {
              iconText: "󰅏"
              tooltipText: "Copy redacted report"
              foreground: root.foreground
              hasCursor: root.cursorActive && root.selectedIndex === 1
              enabled: root.ready
              size: Style.spacing.controlHeight
              onClicked: root.copyReport()
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.max(0, parent.width - Style.space(22) * 2 - Style.spacing.sm * 2)
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
          Text {
            width: parent.width
            visible: root.ready && root.rows.length === 0
            text: root.ready ? "Nothing needs attention." : "No scan data yet."
            color: root.ready ? root.foreground : Qt.darker(root.foreground, 1.4)
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

              Row {
                width: parent.width
                visible: modelData.kind === "check"
                spacing: Style.spacing.sm

                Text {
                  width: Style.space(18)
                  text: modelData.kind === "check" ? Model.glyph(modelData.check.status) : ""
                  color: modelData.kind !== "check" ? root.foreground
                       : (modelData.check.status === "problem" ? root.urgent
                       : (modelData.check.status === "attention" ? root.accent : root.foreground))
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.icon
                }

                Column {
                  width: parent.width - Style.space(18) - Style.spacing.sm
                  spacing: 1

                  Text {
                    width: parent.width
                    visible: modelData.kind === "check"
                    text: modelData.kind === "check" ? modelData.check.title : ""
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: modelData.kind === "check" && modelData.check.status === "problem"
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    visible: modelData.kind === "check" && modelData.check.value !== ""
                    text: modelData.kind === "check" ? modelData.check.value : ""
                    color: Qt.darker(root.foreground, 1.25)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    elide: Text.ElideRight
                  }

                  // Evidence and the suggested fix are the reason the panel
                  // exists, so both are always shown for a finding.
                  Text {
                    width: parent.width
                    visible: modelData.kind === "check" && modelData.check.detail !== ""
                    text: modelData.kind === "check" ? modelData.check.detail : ""
                    color: Qt.darker(root.foreground, 1.5)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }

                  Text {
                    width: parent.width
                    visible: modelData.kind === "check" && modelData.check.suggestion !== ""
                    text: modelData.kind === "check" ? "-> " + modelData.check.suggestion : ""
                    color: root.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}