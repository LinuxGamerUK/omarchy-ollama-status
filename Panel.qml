import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "com.github.linuxgameruk.ollama-status"
  ipcTarget: "com.github.linuxgameruk.ollama-status"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property string statusText: {
    if (ollama.busy) return ollama.actionLabel
    if (!ollama.installed) return "Not installed"
    if (!ollama.hasService) return "No service"
    if (ollama.running) return "Running"
    return "Stopped"
  }
  readonly property color statusColor: {
    if (ollama.busy) return foreground
    if (!ollama.installed) return urgent
    if (!ollama.hasService) return urgent
    if (ollama.running) return Color.accent
    return dim
  }
  readonly property string toggleHint: {
    if (!ollama.installed) return ""
    if (!ollama.hasService) return "See setup instructions below"
    if (ollama.running) return "Turn Ollama off"
    return "Turn Ollama on"
  }
  property string focusSection: "header"
  property bool cursorActive: false

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    ollama.refresh()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  Service {
    id: ollama
    settings: root.settings
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function startService(): string { ollama.startService(); return "ok" }
    function stopService(): string { ollama.stopService(); return "ok" }
    function refresh(): string { ollama.refresh(); return "ok" }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        if (dx !== 0 && root.focusSection === "header") root.moveCursor(dx)
      }
      onActivateRequested: {
        if (root.cursorActive && root.focusSection === "header") ollama.toggleService()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") ollama.startService()
        else if (t === "x" || t === "X") ollama.stopService()
        else if (t === "r" || t === "R") ollama.refresh()
      }
    }

    Flickable {
      id: panelFlick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: panelFlick.width
        spacing: Style.space(12)

        // ── Hero ────────────────────────────────────────────────────
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroActions.implicitHeight)

          Text {
            id: heroIcon
            text: "󰚩"
            color: root.statusColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            opacity: ollama.installed ? 1.0 : 0.5
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          RowLayout {
            id: heroActions
            spacing: Style.space(8)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            ToggleSwitch {
              id: powerSwitch
              visible: ollama.installed && ollama.hasService
              checked: ollama.running
              busy: ollama.busy
              hasCursor: root.cursorActive && root.focusSection === "header"
              foreground: root.foreground
              Layout.alignment: Qt.AlignVCenter
              onHovered: function(on) { if (on) { root.cursorActive = true; root.focusSection = "header" } }
              onToggled: ollama.toggleService()

              PanelToolTip {
                visible: powerSwitch.containsMouse
                text: root.toggleHint
                fontFamily: root.fontFamily
              }
            }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(14)
            anchors.right: parent.right
            anchors.rightMargin: heroActions.width > 0 ? heroActions.width + Style.space(12) : 0
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "Ollama"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              text: root.statusText.toUpperCase()
              color: root.statusColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }
        }

        // ── Error ───────────────────────────────────────────────────
        Text {
          visible: ollama.lastError !== ""
          width: parent.width
          text: ollama.sanitize(ollama.lastError)
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
        }

        // ── Not installed ────────────────────────────────────────────
        CursorSurface {
          visible: !ollama.installed
          width: parent.width
          implicitHeight: missingText.implicitHeight + Style.spacing.rowPaddingX
          foreground: root.foreground

          Text {
            id: missingText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(12)
            text: "Ollama is not installed or not on PATH.\nInstall it from ollama.com and try again."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
          }
        }

        // ── No service ────────────────────────────────────────────────
        CursorSurface {
          visible: ollama.installed && !ollama.hasService
          width: parent.width
          implicitHeight: noServiceText.implicitHeight + Style.spacing.rowPaddingX
          foreground: root.foreground

          Text {
            id: noServiceText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.margins: Style.space(12)
            text: "Ollama is installed but has no systemd service.\nSet one up with:\n\nsudo systemctl enable ollama\n\nSee the README for a unit file if none is packaged."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
          }
        }

        // ── Service details ─────────────────────────────────────────
        Column {
          visible: ollama.installed && ollama.hasService
          width: parent.width
          spacing: Style.spacing.labelGap

          GridLayout {
            width: parent.width
            columns: 2
            columnSpacing: Style.space(20)
            rowSpacing: Style.spacing.labelGap

            InfoLabel { text: "Status" }
            InfoValue {
              text: ollama.running ? "Running" : "Stopped"
              color: root.statusColor
            }

            InfoLabel { text: "Version" }
            InfoValue {
              text: ollama.sanitize(ollama.ollamaVersion) || "\u2014"
            }

            InfoLabel {
              visible: ollama.running
              text: "API"
            }
            InfoValue {
              visible: ollama.running
              text: {
                if (!ollama.apiReachable) return "\u2014"
                return ollama.apiLatencyMs >= 0 ? ollama.apiLatencyMs + " ms" : "Reachable"
              }
              color: {
                if (!ollama.apiReachable) return root.urgent
                if (ollama.apiLatencyMs > 500) return root.urgent
                if (ollama.apiLatencyMs > 200) return Color.accent
                return root.foreground
              }
            }

            InfoLabel {
              visible: ollama.running && ollama.activeSince !== ""
              text: "Since"
            }
            InfoValue {
              visible: ollama.running && ollama.activeSince !== ""
              text: ollama.activeSince ? ollama.sanitize(ollama.activeSince.replace(/^\w+\s+/, "")) : ""
            }

            InfoLabel {
              visible: ollama.running
              text: "Models"
            }
            InfoValue {
              visible: ollama.running
              text: {
                if (ollama.models.length === 0) return "No local models"
                var local = 0
                var cloud = 0
                for (var i = 0; i < ollama.models.length; i++) {
                  if (ollama.models[i].isCloud) cloud++
                  else local++
                }
                var parts = []
                if (local > 0) parts.push(local + " local")
                if (cloud > 0) parts.push(cloud + " cloud")
                return parts.length > 0 ? parts.join(" \u00b7 ") : "0"
              }
            }
          }
        }

        // ── Running models ──────────────────────────────────────────
        PanelSeparator {
          visible: ollama.running && ollama.runningModels.length > 0
          foreground: root.foreground
        }

        Column {
          visible: ollama.running && ollama.runningModels.length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: "LOADED MODELS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: ollama.runningModels

              CursorSurface {
                required property var modelData
                width: parent.width
                foreground: root.foreground
                implicitHeight: modelRow.implicitHeight + Style.spacing.rowPaddingX

                RowLayout {
                  id: modelRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  Text {
                    text: "\u{F32A9}"
                    color: Color.accent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    Layout.alignment: Qt.AlignVCenter
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(1)

                    Text {
                      Layout.fillWidth: true
                      text: ollama.sanitize(modelData.name || "Unknown")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }

                    Text {
                      Layout.fillWidth: true
                      text: {
                        var parts = []
                        if (modelData.size) parts.push(String(modelData.size))
                        if (modelData.processor) parts.push(String(modelData.processor))
                        return ollama.sanitize(parts.join(" \u00b7 "))
                      }
                      visible: text !== ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }
                  }
                }
              }
            }
          }
        }

        // ── Available models ─────────────────────────────────────────
        PanelSeparator {
          visible: ollama.installed && ollama.models.length > 0
          foreground: root.foreground
        }

        Column {
          visible: ollama.installed && ollama.models.length > 0
          width: parent.width
          spacing: Style.space(10)

          PanelSectionHeader {
            text: ollama.running ? "ALL MODELS" : "AVAILABLE MODELS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Column {
            width: parent.width
            spacing: Style.space(6)

            Repeater {
              model: ollama.models

              CursorSurface {
                required property var modelData
                width: parent.width
                foreground: root.foreground
                implicitHeight: availRow.implicitHeight + Style.spacing.rowPaddingX

                RowLayout {
                  id: availRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  Text {
                    text: {
                      if (modelData.isCloud) return "\u2601"
                      for (var i = 0; i < ollama.runningModels.length; i++) {
                        if (String(ollama.runningModels[i].name) === String(modelData.name)) return "\u25cf"
                      }
                      return "\u25cb"
                    }
                    color: {
                      if (modelData.isCloud) return Color.accent
                      for (var i = 0; i < ollama.runningModels.length; i++) {
                        if (String(ollama.runningModels[i].name) === String(modelData.name)) return Color.accent
                      }
                      return root.dim
                    }
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    Layout.alignment: Qt.AlignVCenter
                  }

                  ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Style.space(1)

                    Text {
                      Layout.fillWidth: true
                      text: ollama.sanitize(modelData.name || "Unknown")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }

                    Text {
                      Layout.fillWidth: true
                      text: {
                        var parts = []
                        if (modelData.isCloud) parts.push("Cloud")
                        else if (modelData.size) parts.push(String(modelData.size))
                        if (modelData.modified) parts.push(String(modelData.modified))
                        return ollama.sanitize(parts.join(" \u00b7 "))
                      }
                      visible: text !== ""
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                    }
                  }
                }
              }
            }
          }
        }

        // ── No models loaded ─────────────────────────────────────────
        PanelSeparator {
          visible: ollama.running && ollama.runningModels.length === 0
          foreground: root.foreground
        }

        Text {
          visible: ollama.running && ollama.runningModels.length === 0
          width: parent.width
          text: ollama.models.length === 0 ? "No local models. Cloud models accessed via API are not listed by Ollama." : "No models currently loaded. Service is idle."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
        }
      }
    }
  }

  // ── Inline components matching Omarchy panel style ──────────────────

  component InfoLabel: Text {
    color: root.foreground
    opacity: 0.6
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    textFormat: Text.PlainText
  }

  component InfoValue: Text {
    color: root.foreground
    font.family: root.fontFamily
    font.pixelSize: Style.font.bodySmall
    textFormat: Text.PlainText
  }

  // Keyboard cursor movement across sections
  function moveCursor(dy) {
    cursorActive = true
  }
}