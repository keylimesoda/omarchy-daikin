import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

Panel {
  id: root
  moduleName: "daikinsplit"
  ipcTarget: "daikinsplit"
  // Own the IpcHandler so other widgets can drive the unit
  // (togglePower / setMode / setFan / setSwing / setTempC / refresh).
  manageIpc: false

  // The CLI ships inside the plugin (bin/daikin) so no installation step
  // is needed; the path is resolved relative to this QML file.
  // Path to the bundled CLI, resolved relative to this QML file.
  function pluginBin(): string {
    var u = String(Qt.resolvedUrl("bin/daikin"))
    if (u.startsWith("file://")) u = u.substring(7)
    return u
  }
  readonly property string bin: pluginBin()

  // Empty = auto-discover (recommended); a pinned IP skips discovery.
  readonly property string ipOverride: root.setting("deviceIp", "")
  readonly property string units: root.setting("units", "f") === "c" ? "c" : "f"

  readonly property color fg: root.bar ? root.bar.foreground : Color.foreground
  readonly property string ff: root.bar ? root.bar.fontFamily : Style.font.family
  readonly property bool vertical: root.bar ? root.bar.vertical : false
  readonly property real controlH: Style.spacing.controlHeight

  // ---- live device state (parsed `daikin status` JSON) ----
  property var state: ({})
  readonly property bool online: root.state.online === true
  readonly property bool poweredOn: root.online && root.state.power === true
  readonly property string mode: root.online ? (root.state.mode || "auto") : "off"
  readonly property bool tempEnabled: root.online
    && ["auto", "cool", "heat"].indexOf(root.mode) >= 0
  readonly property bool applying: actionProc.running
  property string lastError: ""
  property bool statusSawOutput: false

  // ---- first-run setup: no adapter IP known yet ----
  readonly property bool needsIp: root.state.noConfig === true
  property bool discovering: false
  property var discovered: []          // [{ip, room, mac, firmware, ...}]
  property bool autoDiscoverTried: false

  // Display setpoint in Celsius; hysteresis is compensated by the CLI.
  readonly property real tempDisplayC: root.online
    ? (root.state.stemp_c == null ? 22.0 : root.state.stemp_c)
    : 22.0

  // ---- keyboard cursor ----
  property string focusSection: "hero"   // hero | temp | mode | fan | swing | actions
  property int selectedIndex: 0
  property bool cursorActive: false

  readonly property var sectionOrder: ["hero", "temp", "mode", "fan", "swing", "actions"]
  readonly property var modeOptions: ["auto", "cool", "heat", "dry", "fan"]
  readonly property var fanOptions: ["auto", "quiet", "low", "medium", "high"]
  readonly property var swingOptions: ["off", "vertical", "horizontal", "both"]
  // Adapter picker rows (built from the discovery results).
  readonly property var adapterOptions: root.discovered.map(function(a) {
    return { value: String(a.ip), label: (a.room ? a.room + "  " : "") + a.ip }
  })

  // ---- actions ----
  function refresh() { if (!statusProc.running) statusProc.running = true }

  function ingest(raw) {
    const text = String(raw == null ? "" : raw).trim()
    if (!text) { root.state = ({ online: false }); root.lastError = "no response"; return }
    const parsed = Model.parseStatus(text)
    root.state = parsed
    root.lastError = parsed.online ? "" : (parsed.error || "offline")
    // First run: no IP configured anywhere -> scan the local subnet once.
    if (parsed.noConfig === true && !root.ipOverride && !root.autoDiscoverTried) {
      root.autoDiscoverTried = true
      root.startDiscovery()
    }
  }

  function startDiscovery() {
    if (discoverProc.running) return
    root.discovering = true
    root.lastError = ""
    discoverProc.running = true
  }

  function ingestDiscovery(raw) {
    var t = String(raw == null ? "" : raw).trim()
    var list = []
    if (t) {
      try {
        var d = JSON.parse(t)
        if (Array.isArray(d)) list = d
      } catch (e) { list = [] }
    }
    root.discovering = false
    root.discovered = list
    if (list.length === 1) {
      root.selectAdapter(String(list[0].ip))   // persist + re-poll
    } else if (list.length > 1) {
      root.lastError = ""                        // picker takes over
    } else {
      root.lastError = "No Daikin adapter found on the local subnet"
    }
  }

  function selectAdapter(ip) {
    if (configProc.running) return
    configProc.command = [root.bin, "config", "set", String(ip)]
    configProc.running = true
  }

  function sectionOptions() {
    if (root.focusSection === "mode") return root.modeOptions
    if (root.focusSection === "fan") return root.fanOptions
    if (root.focusSection === "swing") return root.swingOptions
    return []
  }

  function activateSelected() {
    if (!root.online) return
    var opts = root.sectionOptions()
    if (!opts.length) return
    var v = opts[root.selectedIndex]
    if (root.focusSection === "mode") root.applyPart({ mode: v })
    else if (root.focusSection === "fan") root.applyPart({ fan: v })
    else if (root.focusSection === "swing") root.applyPart({ swing: v })
  }

  // Merge with the device's current state (the CLI re-reads before writing),
  // so a partial change never clobbers unrelated settings.
  function applyPart(parts) {
    if (actionProc.running) return
    var argv = [root.bin, "set"]
    if (root.ipOverride) argv.push("--ip", root.ipOverride)
    if (parts.power !== undefined) argv.push("--power", parts.power)
    if (parts.mode !== undefined) argv.push("--mode", parts.mode)
    if (parts.fan !== undefined) argv.push("--fan", parts.fan)
    if (parts.swing !== undefined) argv.push("--swing", parts.swing)
    if (parts.tempC !== undefined) argv.push("--temp-c", String(Math.round(parts.tempC * 2) / 2))
    root.lastAction = { argv: argv, at: new Date().toISOString() }
    actionProc.command = argv
    actionProc.running = true
  }

  // Device-safe action test: `daikin set --dry-run` (prints the request it
  // WOULD send; never touches the adapter).
  function dryRunAction(partsJson: string): string {
    if (actionProc.running) return "busy"
    var parts = {}
    try { parts = JSON.parse(partsJson || "{}") } catch (e) { return "bad json" }
    var argv = [root.bin, "set", "--dry-run"]
    if (root.ipOverride) argv.push("--ip", root.ipOverride)
    if (parts.power !== undefined) argv.push("--power", String(parts.power))
    if (parts.mode !== undefined) argv.push("--mode", String(parts.mode))
    if (parts.fan !== undefined) argv.push("--fan", String(parts.fan))
    if (parts.swing !== undefined) argv.push("--swing", String(parts.swing))
    if (parts.tempC !== undefined) argv.push("--temp-c", String(Math.round(Number(parts.tempC) * 2) / 2))
    root.lastAction = { argv: argv, at: new Date().toISOString(), dryRun: true }
    actionProc.command = argv
    actionProc.running = true
    return "started"
  }

  // Last `set` attempt (argv, exit code, captured output/error) so a failed
  // write is visible instead of silent.
  property var lastAction: ({})
  property string _outBuf: ""
  property string _errBuf: ""

  function togglePower() {
    if (root.needsIp) { root.startDiscovery(); return }
    if (!root.online) root.refresh()
    else root.applyPart({ power: root.poweredOn ? "off" : "on" })
  }

  function nudgeTemp(delta) {
    if (!root.tempEnabled) return
    var t = Math.max(18, Math.min(30, root.tempDisplayC + delta))
    root.applyPart({ tempC: t })
  }

  IpcHandler {
    target: "daikinsplit"

    function open() { root.open() }
    function close() { root.close() }
    function show() { root.open() }
    function hide() { root.close() }
    function toggle() { root.toggle() }
    function togglePower() { root.togglePower() }
    function setMode(m: string) { root.applyPart({ mode: m }) }
    function setFan(f: string) { root.applyPart({ fan: f }) }
    function setSwing(s: string) { root.applyPart({ swing: s }) }
    function setTempC(c: real) { root.applyPart({ tempC: c }) }
    function refresh() { root.refresh() }
    function discover() { root.startDiscovery() }
    // Device-safe: run `daikin set --dry-run` with the given parts
    // ({power, mode, fan, swing, tempC}); inspect the result via dumpState.
    function dryRun(partsJson: string): string {
      return root.dryRunAction(partsJson)
    }

    // Debug: which sub-objects exist on this instance?
    function probe(): string {
      return "sp=" + (statusProc !== undefined ? "y" : "n")
        + " ap=" + (actionProc !== undefined ? "y" : "n")
        + " dp=" + (discoverProc !== undefined ? "y" : "n")
        + " panel=" + (panel !== undefined ? "y" : "n")
        + " button=" + (button !== undefined ? "y" : "n")
        + " opened=" + root.opened
    }

    // Debug: this instance's view of the data path (read-only).
    function dumpState(): string {
      return JSON.stringify({
        state: root.state,
        online: root.online,
        needsIp: root.needsIp,
        discovering: root.discovering,
        discovered: root.discovered,
        ipOverride: root.ipOverride,
        statusProcRunning: statusProc.running,
        lastError: root.lastError,
        lastAction: root.lastAction
      })
    }
  }

  onOpenedChanged: {
    if (root.opened) {
      root.refresh()
      if (root.needsIp && !root.discovering && root.discovered.length === 0)
        root.startDiscovery()
      root.cursorActive = false
      root.focusSection = "hero"
      root.selectedIndex = 0
    }
  }

  Process {
    id: statusProc
    // No --ip: the CLI uses its own config (which first-run discovery
    // populates). A pinned deviceIp setting overrides it.
    // Note: no `+` array concatenation in declarative bindings — QML
    // coerces the result to a comma-joined string, which breaks the spawn.
    command: root.ipOverride
      ? [root.bin, "status", "--ip", root.ipOverride]
      : [root.bin, "status"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.statusSawOutput = true
        root.ingest(text)
      }
    }

    onExited: function(code, status) {
      // The offline/no-config JSON still exits non-zero; only flag failure
      // when the command produced nothing at all (missing binary, crash).
      if (!root.statusSawOutput) {
        root.state = ({ online: false })
        root.lastError = "status command failed"
      }
      root.statusSawOutput = false
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._outBuf = String(text)
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root._errBuf = String(text)
    }
    onExited: function(code, status) {
      // Re-read once the write lands; surface failures instead of dropping them.
      var err = String(root._errBuf).trim()
      var out = String(root._outBuf).trim()
      root._outBuf = ""
      root._errBuf = ""
      if (root.lastAction.argv) {
        root.lastAction.exitCode = code
        root.lastAction.output = out
        if (code !== 0) {
          root.lastAction.error = err || out
          root.lastError = (err || out).split("\n").slice(-2).join(" ")
        } else {
          root.lastError = ""
        }
      }
      postApplyTimer.restart()
    }
  }

  // First-run / on-demand subnet scan (read-only; never in the poll loop).
  Process {
    id: discoverProc
    command: [root.bin, "discover", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.ingestDiscovery(text)
    }
  }

  // Persist the selected adapter IP into the CLI's config file.
  Process {
    id: configProc
    command: [root.bin, "config", "set", "127.0.0.1"]
    onExited: function(code, status) {
      if (code === 0) {
        root.discovered = []
        root.lastError = ""
        root.refresh()
      } else {
        root.lastError = "Could not save the adapter IP"
      }
    }
  }

  Timer {
    id: postApplyTimer
    interval: 1200
    repeat: false
    onTriggered: root.refresh()
  }

  // The adapter's web server is single-threaded; 30s keeps us far outside
  // the 5-10s minimum request spacing.
  Timer { id: pollTimer; interval: 30000; repeat: true; running: true; onTriggered: root.refresh() }

  Component.onCompleted: {
    console.log("DAIKIN-INIT bar=" + (root.bar ? "y" : "n")
      + " sp=" + (statusProc !== undefined ? "y" : "n")
      + " ap=" + (actionProc !== undefined ? "y" : "n")
      + " dp=" + (discoverProc !== undefined ? "y" : "n"))
    root.refresh()
  }

  // ---------- bar chip: color-only fan mark ----------
  // State is carried by the mark's color (grey off / red heat / blue cool),
  // not by a text label, so the taskbar stays clean.

  // Taskbar color language: grey = off, red = heating, blue = cooling.
  readonly property color chipInk: !root.online ? Util.alpha(root.fg, 0.35)
    : !root.poweredOn ? Util.alpha(root.fg, 0.55)
    : (Model.modeTint(root.mode) || root.fg)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    x: 0
    y: 0
    bar: root.bar
    iconComponent: fanBar
    active: root.poweredOn
    activeColor: root.chipInk
    tooltipText: root.needsIp
      ? "No adapter configured — click to find one on your network"
      : Model.tooltip(root.state, root.ipOverride, root.units)
    onPressed: function(b) {
      if (b === Qt.RightButton) root.togglePower()
      else root.toggle()
    }
  }

  // ---------- control panel ----------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(600))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) {
          var order = root.sectionOrder
          var i = order.indexOf(root.focusSection)
          var target = order[dy > 0 ? Math.min(order.length - 1, i + 1) : Math.max(0, i - 1)]
          if (target === "temp" && !root.tempEnabled)
            target = dy > 0 ? "mode" : "hero"
          root.focusSection = target
          root.selectedIndex = 0
        } else if (dx !== 0) {
          if (root.focusSection === "temp") {
            root.nudgeTemp(dx < 0 ? -0.5 : 0.5)
          } else {
            var opts = root.sectionOptions()
            if (opts.length > 1) {
              root.selectedIndex = (root.selectedIndex + (dx > 0 ? 1 : opts.length - 1)) % opts.length
              root.activateSelected()
            }
          }
        }
      }
      onActivateRequested: {
        if (!root.cursorActive) return
        if (root.focusSection === "hero") root.togglePower()
        else if (root.focusSection === "actions") {
          if (root.needsIp) root.startDiscovery()
          else root.refresh()
        }
        else root.activateSelected()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(14)

          // ---------- Hero: fan mark · Daikin [state] · power switch ----------
          PanelHero {
            iconComponent: fanHero
            title: "Daikin"
            detail: root.needsIp ? "SET UP"
              : Model.heroDetail(root.state, root.units)
            meta: root.needsIp ? "NO ADAPTER CONFIGURED"
              : Model.heroMeta(root.state, root.units)
            foreground: root.fg
            fontFamily: root.ff

            trailingControl: Component {
              ToggleSwitch {
                id: powerSwitch
                checked: root.poweredOn
                busy: root.applying
                interactive: root.online
                hasCursor: root.cursorActive && root.focusSection === "hero"
                foreground: root.fg
                onHovered: function(on) {
                  if (on) {
                    root.cursorActive = true
                    root.focusSection = "hero"
                    root.selectedIndex = 0
                  }
                }
                onToggled: root.togglePower()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: root.needsIp ? "Find an adapter"
                    : root.poweredOn ? "Turn off" : "Turn on"
                  fontFamily: root.ff
                }
              }
            }
          }

          // ---------- First-run setup: find / pick the adapter ----------
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.needsIp || root.discovered.length > 0

            PanelSectionHeader {
              text: "SETUP"
              foreground: root.fg
              fontFamily: root.ff
            }

            Text {
              width: parent.width
              visible: root.discovering
              text: "Scanning the local network for Daikin adapters…"
              color: root.fg
              opacity: 0.75
              font.family: root.ff
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              visible: !root.discovering && root.discovered.length === 0 && root.needsIp
              text: root.lastError || "No adapter configured yet."
              color: root.fg
              opacity: 0.75
              font.family: root.ff
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.Wrap
            }

            // Multiple adapters found: pick one.
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.discovered.length > 1

              Text {
                text: "Multiple adapters found — pick yours:"
                color: root.fg
                font.family: root.ff
                font.pixelSize: Style.font.bodySmall
              }

              ButtonGroup {
                id: adapterGroup
                width: parent.width
                options: root.adapterOptions
                foreground: root.fg
                fontFamily: root.ff
                onChanged: function(v) {
                  if (v) root.selectAdapter(v)
                }
              }
            }
          }

          // ---------- Live at-a-glance strip ----------
          Row {
            width: parent.width
            spacing: Style.space(12)

            StatCell { label: "INDOOR"; value: Model.indoorLabel(root.state, root.units) }
            StatCell { label: "OUTDOOR"; value: Model.outdoorLabel(root.state, root.units) }
            StatCell { label: "COMPRESSOR"; value: Model.compressorLabel(root.state) }
          }

          PanelSeparator {
            foreground: root.fg
          }

          // ---------- Temperature ----------
          Column {
            width: parent.width
            spacing: Style.space(8)
            opacity: root.tempEnabled ? 1.0 : 0.45

            Row {
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: "TEMPERATURE"
                foreground: root.fg
                fontFamily: root.ff
                anchors.verticalCenter: parent.verticalCenter
              }

              Item {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - parent.children[0].implicitWidth
                        - tempReadout.implicitWidth - parent.spacing * 2)
                height: 1
              }

              Text {
                id: tempReadout
                text: root.online
                  ? (root.units === "c" ? Model.fmtC(root.state.stemp_c) : Model.fmtF(root.state.stemp_f))
                  : "—"
                color: root.fg
                font.family: root.ff
                font.pixelSize: Style.font.subtitle
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              Button {
                id: tempMinus
                width: Style.space(44)
                height: root.controlH
                text: "–"
                bordered: true
                foreground: root.fg
                fontFamily: root.ff
                enabled: root.tempEnabled
                onClicked: root.nudgeTemp(-0.5)
              }

              PanelSlider {
                id: tempSlider
                bar: root.bar
                width: parent.width - tempMinus.width - tempPlus.width - parent.spacing * 2
                height: root.controlH
                minimum: 18
                maximum: 30
                step: 0.5
                value: root.tempDisplayC
                enabled: root.tempEnabled
                onReleased: function(v) {
                  if (root.tempEnabled) root.applyPart({ tempC: v })
                }
              }

              Button {
                id: tempPlus
                width: Style.space(44)
                height: root.controlH
                text: "+"
                bordered: true
                foreground: root.fg
                fontFamily: root.ff
                enabled: root.tempEnabled
                onClicked: root.nudgeTemp(0.5)
              }
            }
          }

          // ---------- Mode ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "MODE"
              foreground: root.fg
              fontFamily: root.ff
            }

            ButtonGroup {
              id: modeGroup
              width: parent.width
              options: [
                { value: "auto", label: "Auto" },
                { value: "cool", label: "Cool" },
                { value: "heat", label: "Heat" },
                { value: "dry", label: "Dry" },
                { value: "fan", label: "Fan" }
              ]
              value: root.online ? root.state.mode : ""
              foreground: root.fg
              fontFamily: root.ff
              cursorIndex: (root.cursorActive && root.focusSection === "mode")
                ? root.selectedIndex : -1
              onChanged: function(v) {
                if (root.online) root.applyPart({ mode: v })
              }
              onHovered: function(i, h) {
                if (h) {
                  root.cursorActive = true
                  root.focusSection = "mode"
                  root.selectedIndex = i
                }
              }
            }
          }

          // ---------- Fan speed ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "FAN SPEED"
              foreground: root.fg
              fontFamily: root.ff
            }

            ButtonGroup {
              id: fanGroup
              width: parent.width
              options: [
                { value: "auto", label: "Auto" },
                { value: "quiet", label: "Quiet" },
                { value: "low", label: "Low" },
                { value: "medium", label: "Medium" },
                { value: "high", label: "High" }
              ]
              value: root.online ? root.state.fan : ""
              foreground: root.fg
              fontFamily: root.ff
              cursorIndex: (root.cursorActive && root.focusSection === "fan")
                ? root.selectedIndex : -1
              onChanged: function(v) {
                if (root.online) root.applyPart({ fan: v })
              }
              onHovered: function(i, h) {
                if (h) {
                  root.cursorActive = true
                  root.focusSection = "fan"
                  root.selectedIndex = i
                }
              }
            }
          }

          // ---------- Swing ----------
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "SWING"
              foreground: root.fg
              fontFamily: root.ff
            }

            ButtonGroup {
              id: swingGroup
              width: parent.width
              options: [
                { value: "off", label: "Off" },
                { value: "vertical", label: "Vertical" },
                { value: "horizontal", label: "Horizontal" },
                { value: "both", label: "Both" }
              ]
              value: root.online ? root.state.swing : ""
              foreground: root.fg
              fontFamily: root.ff
              cursorIndex: (root.cursorActive && root.focusSection === "swing")
                ? root.selectedIndex : -1
              onChanged: function(v) {
                if (root.online) root.applyPart({ swing: v })
              }
              onHovered: function(i, h) {
                if (h) {
                  root.cursorActive = true
                  root.focusSection = "swing"
                  root.selectedIndex = i
                }
              }
            }
          }

          PanelSeparator {
            foreground: root.fg
          }

          // ---------- Device ----------
          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            PanelSectionHeader {
              text: "DEVICE"
              foreground: root.fg
              fontFamily: root.ff
            }

            InfoPair { label: "Room"; value: root.online ? (root.state.room || "—") : "—" }
            InfoPair { label: "Address"; value: root.online ? (root.state.ip || "—") : "not configured" }
            InfoPair { label: "Firmware"; value: root.online ? root.state.firmware : "—" }
            InfoPair { label: "MAC"; value: root.online ? (root.state.mac || "—") : "—" }
            InfoPair {
              label: "Error"
              value: root.online ? Model.errorLabel(root.state) : "—"
            }
          }

          Text {
            width: parent.width
            visible: root.lastError !== ""
            text: root.lastError
            color: Color.urgent
            opacity: 0.9
            font.family: root.ff
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          // ---------- Actions ----------
          PanelSeparator {
            foreground: root.fg
          }

          Row {
            width: parent.width
            spacing: Style.space(6)

            Button {
              id: refreshBtn
              width: parent.width
              text: root.needsIp
                ? (root.discovering ? "Scanning…" : "Find adapter")
                : (root.online ? "Refresh now" : "Retry connection")
              bordered: true
              foreground: root.fg
              fontFamily: root.ff
              hasCursor: root.cursorActive && root.focusSection === "actions"
              onClicked: {
                if (root.needsIp) root.startDiscovery()
                else root.refresh()
              }
              onHovered: function(h) {
                if (h) {
                  root.cursorActive = true
                  root.focusSection = "actions"
                  root.selectedIndex = 0
                }
              }
            }
          }
        }
      }
    }
  }

  // ---------- Reusable inline components ----------

  // Four-petal fan mark, pure vector so it never depends on the icon font.
  // The petals orbit the hub while the unit is running.
  component FanMark: Item {
    id: fanMark
    property real size: Style.space(20)
    property color ink: root.fg
    property bool spinning: false

    width: size
    height: size

    Item {
      id: blades
      x: fanMark.width / 2
      y: fanMark.height / 2
      width: 0
      height: 0

      RotationAnimation on rotation {
        running: fanMark.spinning
        from: 0
        to: 360
        duration: 1600
        loops: Animation.Infinite
      }

      // Petals are placed explicitly instead of rotated per-item: this
      // quickshell build rejects transformOrigin assignments (both the
      // grouped and QPointF syntax). The whole assembly spins via the
      // `blades` container rotation, whose default origin is the hub.
      Rectangle {   // up
        width: fanMark.size * 0.30
        height: fanMark.size * 0.50
        radius: width / 2
        color: fanMark.ink
        x: -width / 2
        y: -height - fanMark.size * 0.10

        Behavior on color { ColorAnimation { duration: 200 } }
      }
      Rectangle {   // right
        width: fanMark.size * 0.50
        height: fanMark.size * 0.30
        radius: width / 2
        color: fanMark.ink
        x: fanMark.size * 0.10
        y: -height / 2

        Behavior on color { ColorAnimation { duration: 200 } }
      }
      Rectangle {   // down
        width: fanMark.size * 0.30
        height: fanMark.size * 0.50
        radius: width / 2
        color: fanMark.ink
        x: -width / 2
        y: fanMark.size * 0.10

        Behavior on color { ColorAnimation { duration: 200 } }
      }
      Rectangle {   // left
        width: fanMark.size * 0.50
        height: fanMark.size * 0.30
        radius: width / 2
        color: fanMark.ink
        x: -(width + fanMark.size * 0.10)
        y: -height / 2

        Behavior on color { ColorAnimation { duration: 200 } }
      }

      Rectangle {
        width: fanMark.size * 0.16
        height: fanMark.size * 0.16
        x: -width / 2
        y: -height / 2
        radius: width / 2
        color: fanMark.ink

        Behavior on color { ColorAnimation { duration: 200 } }
      }
    }
  }

  // Bar-sized mark.
  Component {
    id: fanBar
    FanMark {
      size: Style.bar.iconCanvas
      ink: root.chipInk
      spinning: root.poweredOn
    }
  }

  // Hero-sized mark.
  Component {
    id: fanHero
    FanMark {
      size: Style.font.display
      ink: root.chipInk
      spinning: root.poweredOn && root.opened
    }
  }

  // Vertical stat chip: bold value over a dim label.
  component StatCell: Item {
    id: statCell
    property string label: ""
    property string value: ""

    width: parent ? (parent.width - parent.spacing * 2) / 3 : 0
    implicitHeight: statInner.implicitHeight

    Column {
      id: statInner
      spacing: Style.space(2)

      Text {
        textFormat: Text.PlainText
        text: statCell.value
        color: root.fg
        font.family: root.ff
        font.pixelSize: Style.font.body
        font.bold: true
        opacity: statCell.value === "—" ? 0.45 : 1.0
      }

      Text {
        textFormat: Text.PlainText
        text: statCell.label
        color: root.fg
        opacity: 0.55
        font.family: root.ff
        font.pixelSize: Style.font.caption
        font.letterSpacing: 0.8
      }
    }
  }

  // Label left, flexible gap, value right.
  component InfoPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    InfoLabel { text: label }
    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth
              - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }
    InfoValue { text: value }
  }

  component InfoLabel: Text {
    textFormat: Text.PlainText
    color: root.fg
    opacity: 0.6
    font.family: root.ff
    font.pixelSize: Style.font.bodySmall
  }

  component InfoValue: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.ff
    font.pixelSize: Style.font.bodySmall
    elide: Text.ElideRight
  }
}