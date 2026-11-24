import QtQuick
import qs.Commons
import qs.Ui

// Bar icon for the UPS. The panel (Panel.qml) owns the NUT polling and the
// detail view; this widget only draws the icon from what the panel knows.
// On battery the icon turns the urgent colour and shows the charge.
BarWidget {
  id: root
  moduleName: "io.github.tawman.nut-ups"

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }

  // Shape contract for the bar's panel routing (same as omarchy.weather).
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  function open() { if (panelLoader.item && panelLoader.item.openFromHotkey) panelLoader.item.openFromHotkey() }
  function close() { if (panelLoader.item && panelLoader.item.close) panelLoader.item.close() }
  readonly property bool popoutSwitchClosing: panelLoader.item ? panelLoader.item.popoutSwitchClosing === true : false
  function closeForPopoutSwitch() { if (panelLoader.item) panelLoader.item.closeForPopoutSwitch() }

  readonly property var ups: panelLoader.item

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.ups ? root.ups.barGlyph : "󰂑"
    labelText: root.ups && root.ups.onBattery ? root.ups.charge + "%" : ""
    slotSize: root.ups && root.ups.onBattery ? Style.bar.statusSlot * 2 : Style.bar.statusSlot
    active: !!root.ups && (root.ups.onBattery || !root.ups.reachable || !root.ups.armed)
    dimmed: !!root.ups && !root.ups.reachable
    tooltipText: root.ups && !root.ups.opened ? root.ups.tooltip : ""

    onPressed: function(b) {
      if (b === Qt.MiddleButton) { if (root.ups) root.ups.refresh() }
      else root.togglePanel()
    }
  }
}
