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

  // ── Model info (bounded) ──────────────────────────────────────────
  readonly property int maxModels: 50
  readonly property int maxRunning: 10
  property var models: []
  property var runningModels: []

  // ── Service info ───────────────────────────────────────────────────
  property string activeSince: ""
  property string ollamaVersion: ""

  // ── Refresh ────────────────────────────────────────────────────────
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 300)

  // ── Process deadlines ─────────────────────────────────────────────
  //
  // Two layers of deadline protection:
  //
  // 1. `timeout` (primary): runs each command in its own process group
  //    and kills the entire group on expiry — no orphaned children.
  //    `timeout -k 2 N` sends SIGTERM after N seconds, then SIGKILL 2s
  //    later if still running. Exit code 124 (timeout) or 137 (SIGKILL)
  //    is discarded by the exitCode === 0 guard in onExited.
  //
  // 2. QML watchdog (backup): if timeout itself somehow hangs, the
  //    watchdog sets process.running = false, which calls
  //    QProcess::terminate() on the timeout PID. This is a fallback only.
  //
  // The watchdog interval is set slightly above the timeout duration so
  // timeout (which handles the process group) always fires first.

  readonly property int processTimeoutSec: 8       // timeout duration for regular commands
  readonly property int startTimeoutSec: 15        // systemctl start can be slow
  readonly property int watchdogMs: 12000          // backup watchdog for regular commands
  readonly property int startWatchdogMs: 20000     // backup watchdog for start

  // ── Output caps at the OS pipe level ──────────────────────────────
  // Every command is piped through `head -c N` so the producer cannot
  // force unbounded allocation in SplitParser's internal line buffer.
  // `set -o pipefail` preserves the producer's exit code; SIGPIPE from
  // head truncation yields exit 141, which our exitCode === 0 guard
  // discards so truncated output is never parsed.
  readonly property int capService: 2048     // systemctl show output
  readonly property int capCheck: 512       // systemctl list-unit-files output
  readonly property int capList: 65536      // ollama list output
  readonly property int capPs: 16384       // ollama ps output
  readonly property int capVersion: 256    // ollama --version output
  readonly property int capApi: 128        // API health check output
  readonly property int capAction: 512     // start/stop stderr capture

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
  function sanitize(str) {
    return String(str || "").replace(/[<>&]/g, function(c) {
      if (c === "<") return "&lt;"
      if (c === ">") return "&gt;"
      if (c === "&") return "&amp;"
      return c
    })
  }

  function truncate(str, maxLen) {
    var s = String(str || "")
    if (s.length <= maxLen) return s
    return s.substring(0, maxLen) + "…"
  }

  // Classify a start/stop failure into an actionable message.
  //
  // Start/stop goes through `pkexec /usr/bin/systemctl …`, which shows a graphical
  // polkit prompt (Omarchy ships a polkit agent inside omarchy-shell).
  // Detect the common failure modes — cancelled prompt, no polkit agent,
  // explicit denial — and surface actionable text instead of raw output.
  function _actionError(output, verb) {
    var s = String(output || "").trim()
    if (/request dismissed|dismissed by user|was not shown|cancelled|canceled/i.test(s)) {
      return (verb === "start" ? "Start": "Stop") + " cancelled — authentication was dismissed."
    }
    if (/not authorized|permission denied|access denied/i.test(s)) {
      return "Cannot " + verb + " Ollama: you are not authorized to manage system services."
    }
    if (/no authentication agent|error creating textual authentication agent/i.test(s)) {
      return "Cannot " + verb + " Ollama: no polkit authentication agent found.\n" +
             "Make sure the Polkit plugin is enabled in omarchy-shell settings."
    }
    return "Failed to " + verb + " Ollama" + (s !== "" ? ": " + truncate(s, 160) : "")
  }

  // ── Process management ──────────────────────────────────────────────
  function launch(process, watchdog) {
    if (!process.running) {
      process.running = true
      watchdog.restart()
    }
  }

  function reap(process, watchdog) {
    watchdog.stop()
    if (process.running) process.running = false
  }

  function refresh() {
    if (!installed) {
      launch(whichProcess, whichWatchdog)
      return
    }
    if (!hasService) {
      launch(checkServiceProcess, checkServiceWatchdog)
      return
    }
    launch(serviceProcess, serviceWatchdog)
  }

  function refreshApi() {
    if (!running) {
      apiReachable = false
      apiLatencyMs = -1
      return
    }
    // Clear transient errors on a fresh successful refresh cycle
    lastError = ""
    launch(apiHealthProcess, apiHealthWatchdog)
    launch(listProcess, listWatchdog)
    launch(psProcess, psWatchdog)
    // Only fetch version once — it never changes during a session
    if (ollamaVersion === "" && !versionProcess.running) {
      launch(versionProcess, versionWatchdog)
    }
  }

  function startService() {
    if (busy || !installed || !hasService) return
    busy = true
    actionLabel = "Starting Ollama…"
    lastError = ""
    startProcess.running = true
    startActionWatchdog.restart()
  }

  function stopService() {
    if (busy || !installed || !hasService) return
    busy = true
    actionLabel = "Stopping Ollama…"
    lastError = ""
    stopProcess.running = true
    stopActionWatchdog.restart()
  }

  function toggleService() {
    if (running) stopService()
    else startService()
  }

  // ── Streaming parsers ──────────────────────────────────────────────
  //
  // Output is bounded at the OS pipe level by `head -c N` (see cap*
  // properties above).  SplitParser then hands each line to onRead as it
  // arrives.  These parsers cap their own accumulation and the arrays
  // they feed as a second layer of defence.

  // systemctl show → service state
  property string _serviceBuffer: ""
  readonly property int _serviceBufferMax: 2048

  function _onServiceLine(line) {
    var s = String(line || "")
    if (_serviceBuffer.length + s.length + 1 <= _serviceBufferMax) {
      _serviceBuffer += s + "\n"
    }
  }

  function _parseServiceBuffer() {
    var raw = _serviceBuffer
    _serviceBuffer = ""
    var lines = raw.trim().split("\n").slice(0, 20)
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
    if (running) refreshApi()
    else {
      runningModels = []
      apiReachable = false
      apiLatencyMs = -1
    }
  }

  // systemctl list-unit-files → service existence
  property string _checkBuffer: ""
  readonly property int _checkBufferMax: 512

  function _onCheckLine(line) {
    var s = String(line || "")
    if (_checkBuffer.length + s.length + 1 <= _checkBufferMax) {
      _checkBuffer += s + "\n"
    }
  }

  function _parseCheckBuffer() {
    var output = truncate(_checkBuffer.trim(), 512)
    _checkBuffer = ""
    hasService = output.length > 0 && output.indexOf("ollama.service") !== -1
    if (hasService) refresh()
  }

  // ollama list → model list
  property var _listModels: []
  property bool _listHeaderSeen: false

  function _onListLine(line) {
    if (_listModels.length >= maxModels) return
    var s = String(line || "").trim()
    if (s === "") return
    if (!_listHeaderSeen) { _listHeaderSeen = true; return }
    var parts = s.split(/\s{2,}/)
    if (parts.length >= 4) {
      var name = truncate(parts[0] || "", 128)
      _listModels.push({
        name: name,
        id: truncate(parts[1] || "", 64),
        size: truncate(parts[2] || "", 32),
        modified: truncate(parts.slice(3).join("  ") || "", 64),
        isCloud: isCloudModel(name)
      })
    }
  }

  function _finishList() {
    models = _listModels
    _listModels = []
    _listHeaderSeen = false
  }

  // ollama ps → running models
  property var _psModels: []
  property bool _psHeaderSeen: false

  function _onPsLine(line) {
    if (_psModels.length >= maxRunning) return
    var s = String(line || "").trim()
    if (s === "") return
    if (!_psHeaderSeen) { _psHeaderSeen = true; return }
    var parts = s.split(/\s{2,}/)
    if (parts.length >= 2) {
      _psModels.push({
        name: truncate(parts[0] || "", 128),
        id: truncate(parts[1] || "", 64),
        size: truncate(parts[2] || "", 32),
        processor: truncate(parts[3] || "", 32),
        context: truncate(parts[4] || "", 32),
        until: truncate(parts.slice(5).join("  ") || "", 64)
      })
    }
  }

  function _finishPs() {
    runningModels = _psModels
    _psModels = []
    _psHeaderSeen = false
  }

  // ollama --version → version string (only fetched once per session)
  function _onVersionLine(line) {
    if (ollamaVersion === "") {
      ollamaVersion = truncate(String(line || "").trim(), 128)
    }
  }

  // API health → latency
  property string _apiBuffer: ""
  readonly property int _apiBufferMax: 128

  function _onApiLine(line) {
    var s = String(line || "")
    if (_apiBuffer.length + s.length + 1 <= _apiBufferMax) {
      _apiBuffer += s + "\n"
    }
  }

  function _parseApiBuffer() {
    var raw = truncate(_apiBuffer.trim(), 128)
    _apiBuffer = ""
    var parts = raw.split(/\s+/)
    var code = parseInt(parts[0], 10)
    var latency = parseInt(parts[1], 10)
    apiReachable = (code === 200)
    apiLatencyMs = isFinite(latency) && latency >= 0 ? latency : -1
  }

  function isCloudModel(name) {
    var n = String(name || "").toLowerCase()
    return n.indexOf(":cloud") !== -1 || n.indexOf(":server") !== -1
  }

  // ── Processes ──────────────────────────────────────────────────────
  //
  // Every command is wrapped in `timeout -k 2 N` which runs the command
  // in its own process group and kills the entire group on expiry,
  // preventing orphaned children.  Inside timeout, commands are further
  // wrapped in `bash -c "set -o pipefail; CMD 2>&1 | head -c N"` to bound
  // output at the OS pipe level before SplitParser sees it.
  //
  // With pipefail, SIGPIPE from head truncation yields exit 141.
  // timeout expiry yields exit 124 (TERM) or 137 (KILL).
  // All non-zero exits are discarded by the exitCode === 0 guard.

  Process {
    id: whichProcess
    running: false
    // which has no children and no stdout handler — timeout not needed
    command: ["which", "ollama"]
    onExited: function(exitCode) {
      whichWatchdog.stop()
      installed = exitCode === 0
      if (installed) refresh()
      else {
        hasService = false
        running = false
        models = []
        runningModels = []
        apiReachable = false
      }
    }
  }

  Process {
    id: checkServiceProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", "set -o pipefail; systemctl list-unit-files ollama.service --no-legend 2>&1 | head -c " + root.capCheck]
    stdout: SplitParser { onRead: function(line) { root._onCheckLine(line) } }
    onExited: function(exitCode) {
      checkServiceWatchdog.stop()
      if (exitCode === 0) _parseCheckBuffer()
      else { _checkBuffer = ""; hasService = false }
    }
  }

  Process {
    id: serviceProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", "set -o pipefail; systemctl show ollama --property=ActiveState,SubState,ActiveEnterTimestamp 2>&1 | head -c " + root.capService]
    stdout: SplitParser { onRead: function(line) { root._onServiceLine(line) } }
    onExited: function(exitCode) {
      serviceWatchdog.stop()
      if (exitCode === 0) {
        _parseServiceBuffer()
      } else {
        _serviceBuffer = ""
        running = false
        activeSince = ""
        apiReachable = false
      }
    }
  }

  Process {
    id: apiHealthProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", "set -o pipefail; start=$(date +%s%3N); status=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 5 http://127.0.0.1:11434/); end=$(date +%s%3N); echo \"$status $((end - start))\" | head -c " + root.capApi]
    stdout: SplitParser { onRead: function(line) { root._onApiLine(line) } }
    onExited: function(exitCode) {
      apiHealthWatchdog.stop()
      if (exitCode === 0) {
        _parseApiBuffer()
      } else {
        _apiBuffer = ""
        apiReachable = false
        apiLatencyMs = -1
      }
    }
  }

  Process {
    id: listProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", "set -o pipefail; ollama list 2>&1 | head -c " + root.capList]
    stdout: SplitParser { onRead: function(line) { root._onListLine(line) } }
    onExited: function(exitCode) {
      listWatchdog.stop()
      if (exitCode === 0) _finishList()
      else { _listModels = []; _listHeaderSeen = false }
    }
  }

  Process {
    id: psProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", "set -o pipefail; ollama ps 2>&1 | head -c " + root.capPs]
    stdout: SplitParser { onRead: function(line) { root._onPsLine(line) } }
    onExited: function(exitCode) {
      psWatchdog.stop()
      if (exitCode === 0) _finishPs()
      else { _psModels = []; _psHeaderSeen = false }
    }
  }

  Process {
    id: versionProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", "set -o pipefail; ollama --version 2>&1 | head -c " + root.capVersion]
    stdout: SplitParser { onRead: function(line) { root._onVersionLine(line) } }
    onExited: function(exitCode) {
      versionWatchdog.stop()
    }
  }

  // ── Start/stop stderr capture ──────────────────────────────────────
  property string _startBuffer: ""
  property string _stopBuffer: ""

  function _onStartLine(line) {
    var s = String(line || "")
    if (_startBuffer.length + s.length + 1 <= capAction) _startBuffer += s + "\n"
  }

  function _onStopLine(line) {
    var s = String(line || "")
    if (_stopBuffer.length + s.length + 1 <= capAction) _stopBuffer += s + "\n"
  }

  Process {
    id: startProcess
    running: false
    command: ["timeout", "-k", "2", "" + startTimeoutSec,
              "bash", "-c", "set -o pipefail; pkexec /usr/bin/systemctl start ollama 2>&1 | head -c " + root.capAction]
    stdout: SplitParser { onRead: function(line) { root._onStartLine(line) } }
    onExited: function(exitCode) {
      startActionWatchdog.stop()
      busy = false
      actionLabel = ""
      if (exitCode !== 0) lastError = _actionError(_startBuffer, "start")
      else lastError = ""
      _startBuffer = ""
      startDelay.restart()
    }
  }

  Process {
    id: stopProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", "set -o pipefail; pkexec /usr/bin/systemctl stop ollama 2>&1 | head -c " + root.capAction]
    stdout: SplitParser { onRead: function(line) { root._onStopLine(line) } }
    onExited: function(exitCode) {
      stopActionWatchdog.stop()
      busy = false
      actionLabel = ""
      if (exitCode !== 0) lastError = _actionError(_stopBuffer, "stop")
      else lastError = ""
      _stopBuffer = ""
      refresh()
    }
  }

  // ── Watchdog timers (backup layer) ────────────────────────────────
  // These fire slightly after the `timeout` deadline so timeout (which
  // handles the process group) is the primary killer.  If timeout
  // itself hangs, the watchdog falls back to QProcess::terminate().

  Timer {
    id: whichWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: if (whichProcess.running) whichProcess.running = false
  }

  Timer {
    id: checkServiceWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(checkServiceProcess, checkServiceWatchdog)
  }

  Timer {
    id: serviceWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(serviceProcess, serviceWatchdog)
  }

  Timer {
    id: apiHealthWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(apiHealthProcess, apiHealthWatchdog)
  }

  Timer {
    id: listWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(listProcess, listWatchdog)
  }

  Timer {
    id: psWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(psProcess, psWatchdog)
  }

  Timer {
    id: versionWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(versionProcess, versionWatchdog)
  }

  Timer {
    id: startActionWatchdog
    interval: startWatchdogMs
    repeat: false
    onTriggered: if (startProcess.running) startProcess.running = false
  }

  Timer {
    id: stopActionWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: if (stopProcess.running) stopProcess.running = false
  }

  // ── Refresh timers ─────────────────────────────────────────────────

  Timer {
    id: refreshTimer
    interval: refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: refresh()
  }

  Timer {
    id: startDelay
    interval: 1500
    repeat: false
    onTriggered: refresh()
  }

  Component.onCompleted: {
    whichProcess.running = true
    whichWatchdog.restart()
  }
}