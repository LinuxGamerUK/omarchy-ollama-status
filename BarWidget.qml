import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "com.github.linuxgameruk.ollama-status"

  readonly property bool opened: panelLoader.item
    ? panelLoader.item.opened === true
    : false
  readonly property bool popoutSwitchClosing: panelLoader.item
    ? panelLoader.item.popoutSwitchClosing === true
    : false

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = root.bar
    panelLoader.item.anchorItem = button
    panelLoader.item.hostWidget = root
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()

  Service {
    id: ollama
    settings: root.settings
  }

  readonly property color barIconColor: {
    if (!ollama.installed || !ollama.hasService)
      return bar ? Qt.darker(bar.barForeground, 2.0) : Qt.darker(Color.foreground, 2.0)
    if (ollama.running)
      return bar ? bar.barForeground : Color.foreground
    return bar ? Qt.darker(bar.barForeground, 1.55) : Qt.darker(Color.foreground, 1.55)
  }

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
    tooltipText: {
      if (!ollama.installed) return "Ollama · Not installed"
      if (!ollama.hasService) return "Ollama · No service · Click to install"
      if (ollama.running) return "Ollama · Running"
      return "Ollama · Stopped"
    }
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: "󰚩"
          color: root.barIconColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering

          Behavior on color { ColorAnimation { duration: 240 } }
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) {
        if (ollama.installed && !ollama.hasService) ollama.installService()
        else ollama.toggleService()
      }
      else if (buttonCode === Qt.MiddleButton) ollama.refresh()
    }
  }
}