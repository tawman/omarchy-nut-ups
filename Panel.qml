import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// UPS detail panel. Polls NUT's `upsc` for the UPS, checks that nut-monitor
// (the service that does the clean shutdown) is running, and reads recent
// power events from nut-monitor's journal. Everything read from those
// commands is shown as plain text.
Panel {
  id: root
  moduleName: "io.github.tawman.nut-ups"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // ------------------------------------------------------------ settings
  // Blank means the first UPS this machine's NUT server lists.
  readonly property string configuredUps: {
    var v = String(setting("ups", "")).trim()
    return /^[A-Za-z0-9_.:@-]{1,96}$/.test(v) ? v : ""
  }
  property string detectedUps: ""
  readonly property string upsName: configuredUps || (detectedUps ? detectedUps + "@localhost" : "")
  readonly property int pollSeconds: Math.max(2, Math.min(60, parseInt(setting("pollSeconds", 5), 10) || 5))

  // ------------------------------------------------------------ state
  property var vars: ({})
  property bool reachable: false
  property bool everRead: false
  property bool armed: true
  property double lastReadMs: 0
  property double onBatterySinceMs: 0
  property var events: []
  property double nowMs: Date.now()

  readonly property string status: String(vars["ups.status"] || "")
  readonly property var flags: status.split(/\s+/)
  readonly property bool onBattery: reachable && flags.indexOf("OB") !== -1
  readonly property bool lowBattery: reachable && flags.indexOf("LB") !== -1
  readonly property bool charging: flags.indexOf("CHRG") !== -1
  readonly property bool replaceBattery: flags.indexOf("RB") !== -1
  readonly property int charge: Math.max(0, Math.min(100, parseInt(vars["battery.charge"], 10) || 0))
  readonly property int lowAt: Math.max(0, Math.min(100, parseInt(vars["battery.charge.low"], 10) || 30))
  // Some UPSes report a placeholder runtime (days); hide implausible values.
  readonly property int runtimeSec: {
    var r = parseInt(vars["battery.runtime"], 10)
    return isFinite(r) && r > 0 && r < 86400 ? r : -1
  }

  readonly property color good: "#7fb77e"
  readonly property color warn: "#e0b45c"
  readonly property color bad: Commons.Color.urgent
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property color levelColor: !reachable ? dim
    : (lowBattery || charge <= lowAt) ? bad
    : onBattery ? warn : good

  readonly property string barGlyph: {
    if (!reachable) return "󰂑"
    if (!onBattery) return "󰂄"
    var icons = ["󰂎", "󰁺", "󰁻", "󰁼", "󰁽", "󰁾", "󰁿", "󰂀", "󰂁", "󰂂", "󰁹"]
    return icons[Math.round(charge / 10)]
  }

  readonly property string tooltip: !reachable ? strings.t("noUps")
    : onBattery ? strings.t("tooltipBattery").arg(charge)
    : strings.t("tooltipMains").arg(charge)

  readonly property string stateLine: {
    if (!reachable) return strings.t("noUpsHint")
    if (lowBattery) return strings.t("lowBattery")
    if (flags.indexOf("OVER") !== -1) return strings.t("overload")
    if (flags.indexOf("BYPASS") !== -1) return strings.t("bypass")
    if (replaceBattery) return strings.t("replaceBattery")
    if (onBattery) return onBatterySinceMs > 0
      ? strings.t("discharging") + " · " + strings.t("forDuration").arg(duration((nowMs - onBatterySinceMs) / 1000))
      : strings.t("discharging")
    return charging && charge < 100 ? strings.t("charging") : strings.t("full")
  }

  function duration(sec) {
    sec = Math.max(0, Math.floor(sec))
    var h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = sec % 60
    if (h > 0) return h + "h " + m + "m"
    if (m > 0) return m + "m " + (s < 10 ? "0" : "") + s + "s"
    return s + "s"
  }

  // ------------------------------------------------------------ open/close
  function openFromHotkey() { root.controller.show(); refresh(); refreshEvents() }
  function open() { openFromHotkey() }
  function close() { root.controller.hide() }
  function toggle() { if (root.opened) close(); else openFromHotkey() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refresh() {
    if (root.upsName === "") {
      if (!listProc.running) listProc.running = true
      root.reachable = false
      return
    }
    if (!upscProc.running) upscProc.running = true
    if (!monitorProc.running) monitorProc.running = true
  }
  function refreshEvents() { if (!eventsProc.running) eventsProc.running = true }

  function parseVars(text) {
    var next = {}
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length && i < 200; i++) {
      var at = lines[i].indexOf(": ")
      if (at > 0) next[lines[i].slice(0, at).slice(0, 64)] = lines[i].slice(at + 2).slice(0, 128)
    }
    return next
  }

  function eventKind(msg) {
    var m = msg.toLowerCase()
    // upsmon's own wording; systemd's "Starting/Stopping ... shutdown controller" lines don't match.
    if (/^ups \S+ on battery/.test(m)) return "evOnBattery"
    if (/^ups \S+ on line power/.test(m)) return "evOnline"
    if (/^ups \S+ battery is low/.test(m)) return "evLow"
    if (m.indexOf("power-fail shutdown") !== -1 || m.indexOf("forced shutdown") !== -1) return "evShutdown"
    if (m.indexOf("communications") !== -1 && m.indexOf("lost") !== -1) return "evCommBad"
    if (m.indexOf("communications") !== -1 && m.indexOf("established") !== -1) return "evCommOk"
    return ""
  }

  // Lists the UPS names the local NUT server knows; the first one is used.
  Process {
    id: listProc
    command: ["upsc", "-l"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var first = String(text || "").split("\n")[0].trim()
        if (/^[A-Za-z0-9_.:-]{1,64}$/.test(first)) {
          root.detectedUps = first
          Qt.callLater(root.refresh)
        }
      }
    }
  }

  // The detail tiles: whichever of these the UPS reports, in this order.
  function num(key, decimals) {
    var v = parseFloat(vars[key])
    return isFinite(v) ? Commons.I18n.formatNumber(decimals === undefined ? v : Number(v.toFixed(decimals))) : ""
  }
  readonly property var statItems: {
    var out = []
    function add(title, value) { if (value !== "" && out.length < 9) out.push({ title: title, value: value }) }
    add(strings.t("load"), num("ups.load") ? num("ups.load") + " %" : "")
    add(strings.t("power"), num("ups.realpower") ? num("ups.realpower") + " W" : "")
    add(strings.t("runtime"), runtimeSec > 0 ? duration(runtimeSec) : "")
    add(strings.t("inputV"), num("input.voltage", 0) ? num("input.voltage", 0) + " V" : "")
    add(strings.t("outputV"), num("output.voltage", 0) ? num("output.voltage", 0) + " V" : "")
    add(strings.t("frequency"), num("input.frequency", 1) ? num("input.frequency", 1) + " Hz" : "")
    add(strings.t("temperature"), num("ups.temperature", 0) ? num("ups.temperature", 0) + " °C"
      : (num("battery.temperature", 0) ? num("battery.temperature", 0) + " °C" : ""))
    add(strings.t("voltage"), num("battery.voltage", 1) ? num("battery.voltage", 1) + " V" : "")
    add(strings.t("chemistry"), String(vars["battery.type"] || "").replace(/^Lion$/i, "Li-ion").replace(/^PbAc$/i, "Lead-acid").slice(0, 24))
    add(strings.t("capacity"), num("ups.realpower.nominal") ? num("ups.realpower.nominal") + " W"
      : (num("ups.power.nominal") ? num("ups.power.nominal") + " VA" : ""))
    add(strings.t("shutdownDelay"), num("ups.delay.shutdown") ? strings.t("seconds").arg(num("ups.delay.shutdown")) : "")
    add(strings.t("restartDelay"), num("ups.delay.start") ? strings.t("seconds").arg(num("ups.delay.start")) : "")
    if (runtimeSec <= 0 && out.length < 9 && reachable) out.push({ title: strings.t("runtime"), value: strings.t("notReported") })
    return out
  }

  Process {
    id: upscProc
    command: ["upsc", root.upsName]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var parsed = root.parseVars(text)
        var ok = parsed["ups.status"] !== undefined
        var wasOnBattery = root.onBattery
        root.reachable = ok
        if (ok) {
          root.vars = parsed
          root.everRead = true
          root.lastReadMs = Date.now()
          if (root.onBattery && !wasOnBattery && root.onBatterySinceMs === 0) root.onBatterySinceMs = Date.now()
          if (!root.onBattery) root.onBatterySinceMs = 0
          if (root.onBattery !== wasOnBattery) root.refreshEvents()
        }
      }
    }
    onExited: function(code) { if (code !== 0) root.reachable = false }
  }

  Process {
    id: monitorProc
    command: ["systemctl", "is-active", "nut-monitor.service"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.armed = String(text || "").trim() === "active"
    }
  }

  Process {
    id: eventsProc
    command: ["journalctl", "-b", "-u", "nut-monitor.service", "-o", "short-unix", "--no-pager", "-n", "400",
              "-g", "^(UPS .* (on battery|on line power|battery is low)|.*power-fail shutdown|.*forced shutdown|Communications with UPS)"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var out = []
        var lines = String(text || "").split("\n")
        for (var i = lines.length - 1; i >= 0 && out.length < 5; i--) {
          var line = lines[i]
          var t = parseFloat(line)
          var colon = line.indexOf(": ")
          if (!isFinite(t) || colon < 0) continue
          var kind = root.eventKind(line.slice(colon + 2))
          if (kind === "") continue
          out.push({ kind: kind, ms: t * 1000 })
        }
        root.events = out
        if (root.onBattery && root.onBatterySinceMs === 0) {
          for (var j = 0; j < out.length; j++) if (out[j].kind === "evOnBattery") { root.onBatterySinceMs = out[j].ms; break }
        }
      }
    }
  }

  Timer {
    interval: root.pollSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }
  Timer {
    interval: 1000
    running: root.opened || root.onBattery
    repeat: true
    onTriggered: root.nowMs = Date.now()
  }

  // ------------------------------------------------------------ view
  component Label: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.bar ? root.bar.fontFamily : Style.font.family
    font.pixelSize: Style.font.body
  }

  component Stat: Column {
    property string title: ""
    property string value: ""
    spacing: Style.space(4)
    width: (statsGrid.width - statsGrid.columnSpacing * 2) / 3
    Label { text: title; color: root.dim; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
    Label { text: value; font.pixelSize: Style.font.title; elide: Text.ElideRight; width: parent.width }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    centerOnBar: false
    focusTarget: panel.loadedContent
    contentWidth: panel.fittedContentWidth(Style.space(440))
    contentHeight: panel.fittedContentHeight(panel.loadedContentHeight)

    content: PanelKeyCatcher {
      implicitHeight: column.implicitHeight
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(18)

        // ---- Hero: charge ring on the left, power state on the right.
        Item {
          width: parent.width
          height: ring.height

          Canvas {
            id: ring
            width: Style.space(132)
            height: width
            anchors.left: parent.left
            anchors.leftMargin: Style.space(8)
            antialiasing: true

            property real shown: root.charge
            property color tone: root.levelColor
            Behavior on shown { NumberAnimation { duration: Style.duration(260); easing.type: Easing.OutCubic } }
            onShownChanged: requestPaint()
            onToneChanged: requestPaint()
            Connections { target: root; function onLowAtChanged() { ring.requestPaint() } function onFgChanged() { ring.requestPaint() } }

            onPaint: {
              var ctx = getContext("2d")
              ctx.reset()
              var cx = width / 2, cy = height / 2, r = width / 2 - Style.space(9)
              var start = Math.PI * 0.75, sweep = Math.PI * 1.5
              ctx.lineCap = "round"
              ctx.lineWidth = Style.space(9)
              ctx.strokeStyle = Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.12)
              ctx.beginPath(); ctx.arc(cx, cy, r, start, start + sweep); ctx.stroke()
              if (shown > 0) {
                ctx.strokeStyle = tone
                ctx.beginPath(); ctx.arc(cx, cy, r, start, start + sweep * shown / 100); ctx.stroke()
              }
              // Shutdown threshold tick.
              var a = start + sweep * root.lowAt / 100
              ctx.lineWidth = Style.space(2)
              ctx.lineCap = "butt"
              ctx.strokeStyle = root.bad
              ctx.beginPath()
              ctx.moveTo(cx + Math.cos(a) * (r - Style.space(9)), cy + Math.sin(a) * (r - Style.space(9)))
              ctx.lineTo(cx + Math.cos(a) * (r + Style.space(9)), cy + Math.sin(a) * (r + Style.space(9)))
              ctx.stroke()
            }

            Column {
              anchors.centerIn: parent
              anchors.verticalCenterOffset: -Style.space(2)
              spacing: Style.space(2)
              Row {
                anchors.horizontalCenter: parent.horizontalCenter
                LayoutMirroring.enabled: false
                Label {
                  id: bigNumber
                  text: root.everRead ? String(root.charge) : "—"
                  font.pixelSize: root.charge >= 100 ? 36 : 44
                  font.bold: true
                }
                Label {
                  text: root.everRead ? "%" : ""
                  color: root.dim
                  font.pixelSize: Style.font.title
                  anchors.top: bigNumber.top
                  anchors.topMargin: Style.space(8)
                }
              }
              Label {
                anchors.horizontalCenter: parent.horizontalCenter
                text: strings.t("battery")
                color: root.dim
                font.pixelSize: Style.font.caption
                font.letterSpacing: 2
              }
            }
          }

          Column {
            anchors.left: ring.right
            anchors.leftMargin: Style.space(20)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)

            Label {
              text: [strings.t("title"), String(root.vars["device.mfr"] || root.vars["ups.mfr"] || "").replace(/^-+|-+$/g, ""),
                     String(root.vars["device.model"] || root.vars["ups.model"] || "")].filter(function(x) { return x !== "" }).join("  ·  ").slice(0, 80)
              color: root.dim
              font.pixelSize: Style.font.caption
              font.letterSpacing: 2
              elide: Text.ElideRight
              width: parent.width
            }
            Row {
              spacing: Style.space(8)
              Rectangle {
                width: Style.space(10); height: width; radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: root.levelColor
                SequentialAnimation on opacity {
                  running: root.onBattery && !Style.reduceMotion
                  loops: Animation.Infinite
                  NumberAnimation { to: 0.35; duration: Style.duration(700); easing.type: Easing.InOutSine }
                  NumberAnimation { to: 1; duration: Style.duration(700); easing.type: Easing.InOutSine }
                }
              }
              Label {
                text: !root.reachable ? strings.t("noUps") : root.onBattery ? strings.t("onBattery") : strings.t("onMains")
                font.pixelSize: Style.font.title
                font.bold: true
                color: root.onBattery || !root.reachable ? root.levelColor : root.fg
              }
            }
            Label {
              text: root.stateLine
              color: root.dim
              wrapMode: Text.WordWrap
              width: parent.width
            }

            // Protection pill.
            Rectangle {
              height: pill.implicitHeight + Style.space(10)
              width: Math.min(parent.width, pill.implicitWidth + Style.space(20))
              radius: height / 2
              color: Qt.rgba(pillTone.r, pillTone.g, pillTone.b, 0.14)
              border.color: Qt.rgba(pillTone.r, pillTone.g, pillTone.b, 0.45)
              border.width: 1
              property color pillTone: root.armed ? root.good : root.bad
              Label {
                id: pill
                anchors.centerIn: parent
                width: Math.min(implicitWidth, parent.width - Style.space(20))
                elide: Text.ElideRight
                text: root.armed ? "󰒘  " + strings.t("protectionOn").arg(root.lowAt) : "󰒙  " + strings.t("protectionOff")
                color: parent.pillTone
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // ---- Linear charge bar with the shutdown line.
        Item {
          width: parent.width
          height: Style.space(30)
          Rectangle {
            id: track
            y: Style.space(4)
            width: parent.width
            height: Style.space(8)
            radius: height / 2
            color: Qt.rgba(root.fg.r, root.fg.g, root.fg.b, 0.10)
            Rectangle {
              height: parent.height
              radius: parent.radius
              width: parent.width * root.charge / 100
              color: root.levelColor
              Behavior on width { NumberAnimation { duration: Style.duration(260); easing.type: Easing.OutCubic } }
            }
            Rectangle {
              x: parent.width * root.lowAt / 100 - width / 2
              y: -Style.space(4)
              width: Style.space(2)
              height: parent.height + Style.space(8)
              color: root.bad
            }
          }
          Label {
            x: Math.max(0, Math.min(parent.width - width, track.width * root.lowAt / 100 - width / 2))
            anchors.top: track.bottom
            anchors.topMargin: Style.space(6)
            text: strings.t("shutdownAt").arg(root.lowAt)
            color: root.bad
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { width: parent.width }

        // ---- Details.
        Grid {
          id: statsGrid
          width: parent.width
          columns: 3
          columnSpacing: Style.space(14)
          rowSpacing: Style.space(14)
          Repeater {
            model: root.statItems
            Stat { required property var modelData; title: modelData.title; value: modelData.value }
          }
        }

        PanelSeparator { width: parent.width }

        // ---- Recent power events (this boot).
        Column {
          width: parent.width
          spacing: Style.space(8)
          Label { text: strings.t("recent"); color: root.dim; font.pixelSize: Style.font.caption; font.letterSpacing: 1 }
          Label {
            visible: root.events.length === 0
            text: strings.t("noEvents")
            color: root.dim
          }
          Repeater {
            model: root.events
            Row {
              required property var modelData
              spacing: Style.space(10)
              Rectangle {
                width: Style.space(7); height: width; radius: width / 2
                anchors.verticalCenter: parent.verticalCenter
                color: modelData.kind === "evOnline" || modelData.kind === "evCommOk" ? root.good
                  : modelData.kind === "evOnBattery" ? root.warn : root.bad
              }
              Label {
                width: Style.space(120)
                text: new Date(modelData.ms).toLocaleString(Qt.locale(Commons.I18n.formatLocale), "ddd h:mm:ss ap")
                color: root.dim
              }
              Label { text: strings.t(modelData.kind) }
            }
          }
        }

        Label {
          width: parent.width
          horizontalAlignment: Text.AlignRight
          text: (root.upsName ? root.upsName + "  ·  " : "")
            + (root.vars["driver.name"] ? String(root.vars["driver.name"]) + "  ·  " : "")
            + (root.lastReadMs > 0 ? strings.t("updated").arg(Math.max(0, Math.round((root.nowMs - root.lastReadMs) / 1000))) : "")
          color: Qt.darker(root.fg, 2.0)
          font.pixelSize: Style.font.caption
          elide: Text.ElideLeft
        }
      }
    }
  }
}
