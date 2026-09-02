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

  readonly property color barIconColor: bar ? bar.barForeground : Color.foreground

  readonly property bool foregroundIsLight: (0.299 * barIconColor.r + 0.587 * barIconColor.g + 0.114 * barIconColor.b) > 0.5
  readonly property url iconSource: foregroundIsLight
    ? Qt.resolvedUrl("assets/ollama-white.svg")
    : Qt.resolvedUrl("assets/ollama-black.svg")

  readonly property real iconOpacity: {
    if (!ollama.installed || !ollama.hasService) return 0.35
    if (ollama.running) return 1.0
    return 0.6
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
      if (!ollama.installed) return "Ollama \u00b7 Not installed"
      if (!ollama.hasService) return "Ollama \u00b7 No service"
      if (ollama.running) return "Ollama \u00b7 Running"
      return "Ollama \u00b7 Stopped"
    }
    iconComponent: Component {
      Item {
        Image {
          anchors.centerIn: parent
          width: Style.bar.iconFont
          height: Style.bar.iconFont
          source: root.iconSource
          fillMode: Image.PreserveAspectFit
          sourceSize.width: Style.bar.iconFont * 2
          sourceSize.height: Style.bar.iconFont * 2
          smooth: true
          opacity: root.iconOpacity

          Behavior on opacity { NumberAnimation { duration: 240 } }
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
      else if (buttonCode === Qt.RightButton) ollama.toggleService()
      else if (buttonCode === Qt.MiddleButton) ollama.refresh()
    }
  }
}