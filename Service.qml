import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property var settings: ({})

  // ── State ─────────────────────────────────────────────────────────
  property bool installed: false
  property bool running: false
  property bool busy: false
  property string actionLabel: ""
  property string lastError: ""

  // ── Model info ─────────────────────────────────────────────────────
  property var models: []       // [{ name, id, size, modified }]
  property var runningModels: [] // [{ name, id, size, processor, context, until }]

  // ── Service info ───────────────────────────────────────────────────
  property string activeSince: ""
  property string ollamaVersion: ""

  // ── Refresh ────────────────────────────────────────────────────────
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 300)

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  function refresh() {
    if (!installed) {
      if (!whichProcess.running) whichProcess.running = true
      return
    }
    if (!serviceProcess.running) serviceProcess.running = true
  }

  function startService() {
    if (busy || !installed) return
    busy = true
    actionLabel = "Starting Ollama…"
    lastError = ""
    startProcess.running = true
  }

  function stopService() {
    if (busy || !installed) return
    busy = true
    actionLabel = "Stopping Ollama…"
    lastError = ""
    stopProcess.running = true
  }

  function toggleService() {
    if (running) stopService()
    else startService()
  }

  // ── Parsers ────────────────────────────────────────────────────────

  function parseServiceStatus(raw) {
    var lines = String(raw || "").trim().split("\n")
    var state = ""
    var subState = ""
    var since = ""
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.indexOf("ActiveState=") === 0) state = line.substring(12)
      else if (line.indexOf("SubState=") === 0) subState = line.substring(9)
      else if (line.indexOf("ActiveEnterTimestamp=") === 0) since = line.substring(21)
    }
    running = (state === "active" && subState === "running")
    activeSince = since
  }

  function parseModelList(raw) {
    var lines = String(raw || "").trim().split("\n")
    var result = []
    for (var i = 1; i < lines.length; i++) {
      var parts = lines[i].trim().split(/\s{2,}/)
      if (parts.length >= 4) {
        result.push({
          name: parts[0] || "",
          id: parts[1] || "",
          size: parts[2] || "",
          modified: parts.slice(3).join("  ") || ""
        })
      }
    }
    models = result
  }

  function parseRunningModels(raw) {
    var lines = String(raw || "").trim().split("\n")
    var result = []
    for (var i = 1; i < lines.length; i++) {
      var parts = lines[i].trim().split(/\s{2,}/)
      if (parts.length >= 2) {
        result.push({
          name: parts[0] || "",
          id: parts[1] || "",
          size: parts[2] || "",
          processor: parts[3] || "",
          context: parts[4] || "",
          until: parts.slice(5).join("  ") || ""
        })
      }
    }
    runningModels = result
  }

  // ── Processes ──────────────────────────────────────────────────────

  Process {
    id: whichProcess
    running: false
    command: ["which", "ollama"]
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      if (root.installed) root.refresh()
      else {
        root.running = false
        root.models = []
        root.runningModels = []
      }
    }
  }

  Process {
    id: serviceProcess
    running: false
    command: ["systemctl", "show", "ollama", "--property=ActiveState,SubState,ActiveEnterTimestamp"]
    stdout: StdioCollector {
      id: serviceStdout
      waitForEnd: true
      onStreamFinished: {
        root.parseServiceStatus(text)
        if (root.running) {
          if (!listProcess.running) listProcess.running = true
          if (!psProcess.running) psProcess.running = true
          if (!versionProcess.running) versionProcess.running = true
        } else {
          root.runningModels = []
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.running = false
        root.activeSince = ""
      }
    }
  }

  Process {
    id: listProcess
    running: false
    command: ["ollama", "list"]
    stdout: StdioCollector {
      id: listStdout
      waitForEnd: true
      onStreamFinished: root.parseModelList(text)
    }
  }

  Process {
    id: psProcess
    running: false
    command: ["ollama", "ps"]
    stdout: StdioCollector {
      id: psStdout
      waitForEnd: true
      onStreamFinished: root.parseRunningModels(text)
    }
  }

  Process {
    id: versionProcess
    running: false
    command: ["ollama", "--version"]
    stdout: StdioCollector {
      id: versionStdout
      waitForEnd: true
      onStreamFinished: {
        root.ollamaVersion = String(text || "").trim()
      }
    }
  }

  Process {
    id: startProcess
    running: false
    command: ["sudo", "systemctl", "start", "ollama"]
    onExited: function(exitCode) {
      root.busy = false
      root.actionLabel = ""
      if (exitCode !== 0) {
        root.lastError = "Failed to start Ollama (need root)"
      }
      startDelay.restart()
    }
  }

  Process {
    id: stopProcess
    running: false
    command: ["sudo", "systemctl", "stop", "ollama"]
    onExited: function(exitCode) {
      root.busy = false
      root.actionLabel = ""
      if (exitCode !== 0) {
        root.lastError = "Failed to stop Ollama (need root)"
      }
      root.refresh()
    }
  }

  // ── Timers ─────────────────────────────────────────────────────────

  Timer {
    id: refreshTimer
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // After starting the service, give it a moment before checking status
  Timer {
    id: startDelay
    interval: 1500
    repeat: false
    onTriggered: root.refresh()
  }

  Component.onCompleted: {
    whichProcess.running = true
  }
}