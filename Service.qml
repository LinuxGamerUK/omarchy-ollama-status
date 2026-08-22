import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property var settings: ({})

  // ── State ─────────────────────────────────────────────────────────
  property bool installed: false       // ollama binary on PATH
  property bool hasService: false      // systemd unit file exists
  property bool running: false
  property bool busy: false
  property string actionLabel: ""
  property string lastError: ""

  // ── API health ─────────────────────────────────────────────────────
  property bool apiReachable: false
  property int apiLatencyMs: -1

  // ── Model info (bounded to maxModels) ──────────────────────────────
  readonly property int maxModels: 50
  readonly property int maxRunning: 10
  property var models: []
  property var runningModels: []

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

  // ── Sanitize external strings for safe display ──────────────────────
  // Strip any markup-like characters so QML Text never interprets them.
  function sanitize(str) {
    return String(str || "").replace(/[<>&]/g, function(c) {
      if (c === "<") return "&lt;"
      if (c === ">") return "&gt;"
      if (c === "&") return "&amp;"
      return c
    })
  }

  // Truncate a string to maxLen characters, appending "…" if truncated.
  function truncate(str, maxLen) {
    var s = String(str || "")
    if (s.length <= maxLen) return s
    return s.substring(0, maxLen) + "…"
  }

  function refresh() {
    if (!installed) {
      if (!whichProcess.running) whichProcess.running = true
      return
    }
    if (!hasService) {
      if (!checkServiceProcess.running) checkServiceProcess.running = true
      return
    }
    if (!serviceProcess.running) serviceProcess.running = true
  }

  function refreshApi() {
    if (!running) {
      apiReachable = false
      apiLatencyMs = -1
      return
    }
    if (!apiHealthProcess.running) {
      apiLatencyMs = -1
      apiHealthProcess.running = true
    }
    if (!listProcess.running) listProcess.running = true
    if (!psProcess.running) psProcess.running = true
    if (!versionProcess.running) versionProcess.running = true
  }

  function startService() {
    if (busy || !installed || !hasService) return
    busy = true
    actionLabel = "Starting Ollama…"
    lastError = ""
    startProcess.running = true
  }

  function stopService() {
    if (busy || !installed || !hasService) return
    busy = true
    actionLabel = "Stopping Ollama…"
    lastError = ""
    stopProcess.running = true
  }

  function toggleService() {
    if (running) stopService()
    else startService()
  }

  // ── Parsers (bounded) ──────────────────────────────────────────────

  function parseServiceStatus(raw) {
    var lines = String(raw || "").trim().split("\n").slice(0, 20)
    var state = ""
    var subState = ""
    var since = ""
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.indexOf("ActiveState=") === 0) state = truncate(line.substring(12), 64)
      else if (line.indexOf("SubState=") === 0) subState = truncate(line.substring(9), 64)
      else if (line.indexOf("ActiveEnterTimestamp=") === 0) since = truncate(line.substring(21), 128)
    }
    running = (state === "active" && subState === "running")
    activeSince = since
  }

  function parseModelList(raw) {
    var lines = String(raw || "").trim().split("\n")
    var result = []
    for (var i = 1; i < lines.length && result.length < root.maxModels; i++) {
      var parts = lines[i].trim().split(/\s{2,}/)
      if (parts.length >= 4) {
        result.push({
          name: truncate(parts[0] || "", 128),
          id: truncate(parts[1] || "", 64),
          size: truncate(parts[2] || "", 32),
          modified: truncate(parts.slice(3).join("  ") || "", 64),
          isCloud: false
        })
      }
    }
    // Mark cloud models
    for (var j = 0; j < result.length; j++) {
      if (isCloudModel(result[j].name)) result[j].isCloud = true
    }
    models = result
  }

  function parseRunningModels(raw) {
    var lines = String(raw || "").trim().split("\n")
    var result = []
    for (var i = 1; i < lines.length && result.length < root.maxRunning; i++) {
      var parts = lines[i].trim().split(/\s{2,}/)
      if (parts.length >= 2) {
        result.push({
          name: truncate(parts[0] || "", 128),
          id: truncate(parts[1] || "", 64),
          size: truncate(parts[2] || "", 32),
          processor: truncate(parts[3] || "", 32),
          context: truncate(parts[4] || "", 32),
          until: truncate(parts.slice(5).join("  ") || "", 64)
        })
      }
    }
    runningModels = result
  }

  function isCloudModel(name) {
    var n = String(name || "").toLowerCase()
    return n.indexOf(":cloud") !== -1 || n.indexOf(":server") !== -1
  }

  // ── Processes (bounded StdioCollectors) ────────────────────────────

  Process {
    id: whichProcess
    running: false
    command: ["which", "ollama"]
    onExited: function(exitCode) {
      root.installed = exitCode === 0
      if (root.installed) {
        root.refresh()
      } else {
        root.hasService = false
        root.running = false
        root.models = []
        root.runningModels = []
        root.apiReachable = false
      }
    }
  }

  Process {
    id: checkServiceProcess
    running: false
    command: ["systemctl", "list-unit-files", "ollama.service", "--no-legend"]
    stdout: StdioCollector {
      id: checkServiceStdout
      waitForEnd: true
      onStreamFinished: {
        var output = truncate(String(text || "").trim(), 512)
        root.hasService = output.length > 0 && output.indexOf("ollama.service") !== -1
        if (root.hasService) {
          root.refresh()
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.hasService = false
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
        root.parseServiceStatus(truncate(text, 2048))
        if (root.running) {
          root.refreshApi()
        } else {
          root.runningModels = []
          root.apiReachable = false
          root.apiLatencyMs = -1
        }
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.running = false
        root.activeSince = ""
        root.apiReachable = false
      }
    }
  }

  Process {
    id: apiHealthProcess
    running: false
    command: ["bash", "-c", "start=$(date +%s%3N); status=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 http://127.0.0.1:11434/); end=$(date +%s%3N); echo \"$status $((end - start))\""]
    stdout: StdioCollector {
      id: apiHealthStdout
      waitForEnd: true
      onStreamFinished: {
        var raw = truncate(String(text || "").trim(), 128)
        var parts = raw.split(/\s+/)
        var code = parseInt(parts[0], 10)
        var latency = parseInt(parts[1], 10)
        root.apiReachable = (code === 200)
        root.apiLatencyMs = isFinite(latency) && latency >= 0 ? latency : -1
      }
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.apiReachable = false
        root.apiLatencyMs = -1
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
      onStreamFinished: root.parseModelList(truncate(text, 65536))
    }
  }

  Process {
    id: psProcess
    running: false
    command: ["ollama", "ps"]
    stdout: StdioCollector {
      id: psStdout
      waitForEnd: true
      onStreamFinished: root.parseRunningModels(truncate(text, 16384))
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
        root.ollamaVersion = truncate(String(text || "").trim(), 128)
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
        root.lastError = "Failed to start Ollama"
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
        root.lastError = "Failed to stop Ollama"
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