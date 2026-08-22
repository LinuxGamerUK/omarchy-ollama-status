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
  property bool apiReachable: false    // / endpoint responds
  property int apiLatencyMs: -1        // response time in ms, -1 = unknown

  // ── Model info ────────────────────────────────────────────────────
  property var models: []              // [{ name, id, size, modified, isCloud }]
  property var runningModels: []       // [{ name, id, size, processor, context, until }]
  property var cloudModels: []         // [{ name, family, parameterSize, capabilities }]

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

  function installService() {
    if (busy || !installed || hasService) return
    busy = true
    actionLabel = "Installing service…"
    lastError = ""
    installProcess.running = true
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
          modified: parts.slice(3).join("  ") || "",
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

  function isCloudModel(name) {
    var n = String(name || "").toLowerCase()
    return n.indexOf(":cloud") !== -1 || n.indexOf(":server") !== -1
  }

  function parseCloudModels(raw) {
    try {
      var data = JSON.parse(String(raw || "{}"))
      var models = data.models || []
      var result = []
      for (var i = 0; i < models.length; i++) {
        var m = models[i]
        var details = m.details || {}
        result.push({
          name: m.name || m.model || "",
          family: details.family || "",
          parameterSize: details.parameter_size || "",
          capabilities: details.capabilities || [],
          modified: m.modified_at || ""
        })
      }
      return result
    } catch (e) {
      return []
    }
  }

  // ── Processes ──────────────────────────────────────────────────────

  // Check if ollama binary exists
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
        root.cloudModels = []
        root.apiReachable = false
      }
    }
  }

  // Check if systemd unit file exists
  Process {
    id: checkServiceProcess
    running: false
    command: ["systemctl", "list-unit-files", "ollama.service", "--no-legend"]
    stdout: StdioCollector {
      id: checkServiceStdout
      waitForEnd: true
      onStreamFinished: {
        var output = String(text || "").trim()
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

  // systemd service state
  Process {
    id: serviceProcess
    running: false
    command: ["systemctl", "show", "ollama", "--property=ActiveState,SubState,ActiveEnterTimestamp"]
    stdout: StdioCollector {
      id: serviceStdout
      waitForEnd: true
      onStreamFinished: {
        root.parseServiceStatus(text)
        // When running, also poll API health and models
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

  // API health check — curl the root endpoint and measure latency
  Process {
    id: apiHealthProcess
    running: false
    command: ["bash", "-c", "start=$(date +%s%3N); status=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 http://127.0.0.1:11434/); end=$(date +%s%3N); echo \"$status $((end - start))\""]
    stdout: StdioCollector {
      id: apiHealthStdout
      waitForEnd: true
      onStreamFinished: {
        var parts = String(text || "").trim().split(/\s+/)
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

  // ollama list — includes cloud models tagged :cloud etc.
  Process {
    id: listProcess
    running: false
    command: ["ollama", "list"]
    stdout: StdioCollector {
      id: listStdout
      waitForEnd: true
      onStreamFinished: {
        root.parseModelList(text)
        // After listing local models, also fetch all models via API
        // to discover cloud models that don't appear in `ollama list`
        if (!apiModelsProcess.running) apiModelsProcess.running = true
      }
    }
  }

  // Fetch all models via API (includes cloud models)
  Process {
    id: apiModelsProcess
    running: false
    command: ["curl", "-s", "--connect-timeout", "3", "--max-time", "10", "http://127.0.0.1:11434/v1/models"]
    stdout: StdioCollector {
      id: apiModelsStdout
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || "{}"))
          var apiModels = data.data || []
          // Find models that exist in the API but not in our local list
          var localNames = {}
          for (var i = 0; i < root.models.length; i++) {
            localNames[root.models[i].name] = true
          }
          var newCloud = []
          for (var j = 0; j < apiModels.length; j++) {
            var m = apiModels[j]
            var name = String(m.id || m.name || "")
            if (name && !localNames[name]) {
              newCloud.push({
                name: name,
                id: name,
                size: "cloud",
                modified: m.created ? String(m.created).split("T")[0] : "",
                isCloud: true
              })
            }
          }
          // Merge cloud-only models into the main list
          if (newCloud.length > 0) {
            root.models = root.models.concat(newCloud)
          }
          // Track cloud model details separately
          var cloudDetails = []
          for (var k = 0; k < apiModels.length; k++) {
            var am = apiModels[k]
            cloudDetails.push({
              name: String(am.id || am.name || ""),
              family: "",
              parameterSize: "",
              capabilities: [],
              modified: am.created ? String(am.created).split("T")[0] : ""
            })
          }
          root.cloudModels = cloudDetails
        } catch (e) {
          // API not reachable or parse error — leave cloud models empty
        }
      }
    }
  }

  // ollama ps (running models)
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

  // ollama version
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

  // systemctl start ollama
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

  // systemctl stop ollama
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

  // Install systemd service
  Process {
    id: installProcess
    running: false
    command: ["bash", "-c", "sudo systemctl enable ollama 2>&1 || (sudo tee /etc/systemd/system/ollama.service > /dev/null << 'EOF\\n[Unit]\\nDescription=Ollama Service\\nAfter=network-online.target\\n\\n[Service]\\nExecStart=/usr/bin/ollama serve\\nWorkingDirectory=/var/lib/ollama\\nEnvironment=HOME=/var/lib/ollama\\nEnvironment=OLLAMA_MODELS=/var/lib/ollama\\nUser=ollama\\nGroup=ollama\\nRestart=on-failure\\nRestartSec=3\\nType=simple\\n\\n[Install]\\nWantedBy=multi-user.target\\nEOF\\nsudo systemctl daemon-reload && sudo systemctl enable ollama)"]
    onExited: function(exitCode) {
      root.busy = false
      root.actionLabel = ""
      if (exitCode !== 0) {
        root.lastError = "Failed to install Ollama service"
      } else {
        root.hasService = true
        root.lastError = ""
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

  // After start, poll API once service is likely up
  Timer {
    id: startDelay
    interval: 1500
    repeat: false
    onTriggered: root.refresh()
  }
}