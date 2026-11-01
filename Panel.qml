import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Single-file bar-widget: a router icon in the bar (BarIconButton) with the
// online device count, plus a floating popup (KeyboardPanel) listing every
// connected device. Settings mode (cog icon) is where host/username/
// password get entered once, saved to configPath — deco_status.py (a
// separate Python helper, since the Deco's local API needs RSA+AES that
// QML has no business doing) reads that file and does the actual login.
Panel {
  id: root
  moduleName: "io.github.zestybytes.deco-mesh"
  ipcTarget: "deco-mesh"
  manageIpc: false

  // Each node is { name, mac, role, clients: [{ name, ip, mac, online }] }.
  property var nodes: []
  readonly property var allClients: {
    var result = []
    for (var i = 0; i < root.nodes.length; i++) result = result.concat(root.nodes[i].clients)
    return result
  }
  readonly property int onlineCount: allClients.filter(function (d) { return d.online }).length
  readonly property real totalDownKbps: allClients.reduce(function (sum, d) { return sum + (d.down_kbps || 0) }, 0)
  readonly property real totalUpKbps: allClients.reduce(function (sum, d) { return sum + (d.up_kbps || 0) }, 0)
  property string lastError: ""

  // deco_status.py needs requests + pycryptodome, which aren't part of
  // Omarchy's own Python. Installing them is a network fetch + code
  // execution the user should ask for, not something enabling the plugin
  // decides on its own — so this starts false and only flips once the user
  // has clicked "Install dependencies" (see installDeps()) and the pinned,
  // hash-verified install has actually succeeded.
  property bool depsReady: false
  property bool installingDeps: false

  // Ticks once a minute purely so the offline list's "Xm ago" labels stay
  // live while the panel is open, independent of the 60s poll cycle (see
  // the offline row's Text binding for why that alone isn't enough).
  property int clock: 0
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: root.clock++
  }
  property bool settingsMode: false

  // Auto-expanded when there are few enough offline devices to be worth
  // seeing at a glance (5 or fewer); collapsed for a longer list so it
  // doesn't push the online tree below the fold. Once the user manually
  // toggles it, that choice sticks — offlineDevicesChanged (below) stops
  // overriding it — until the next plugin reload.
  property bool offlineSectionExpanded: false
  property bool offlineSectionUserOverridden: false
  readonly property int offlineAutoExpandThreshold: 5

  onOfflineDevicesChanged: {
    if (root.offlineSectionUserOverridden) return
    root.offlineSectionExpanded = root.offlineDevices.length > 0
      && root.offlineDevices.length <= root.offlineAutoExpandThreshold
  }

  // Per-node collapse state, keyed by node mac. Absent (or false) means
  // expanded — only explicit collapses are stored, so a mesh node added
  // later shows up expanded by default rather than needing an entry first.
  property var nodeCollapsed: ({})
  function isNodeCollapsed(mac) { return !!root.nodeCollapsed[mac] }
  function toggleNodeCollapsed(mac) {
    var next = Object.assign({}, root.nodeCollapsed)
    next[mac] = !next[mac]
    root.nodeCollapsed = next
    root.saveUiState()
  }

  // Both the per-node collapse state above and the offline section's
  // expand/override state, kept together in one small file so reopening
  // the panel (or restarting the shell) remembers exactly how it was left.
  readonly property string uiStatePath: Quickshell.env("HOME") + "/.local/state/omarchy/deco-mesh/ui-state.json"
  function saveUiState() {
    uiStateFile.setText(JSON.stringify({
      nodeCollapsed: root.nodeCollapsed,
      offlineSectionExpanded: root.offlineSectionExpanded,
      offlineSectionUserOverridden: root.offlineSectionUserOverridden
    }, null, 2))
    uiStateFile.waitForJob()
    uiStateChmodProc.running = true
  }

  FileView {
    id: uiStateFile
    path: root.uiStatePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var state = JSON.parse(text())
        root.nodeCollapsed = state.nodeCollapsed || {}
        root.offlineSectionExpanded = !!state.offlineSectionExpanded
        root.offlineSectionUserOverridden = !!state.offlineSectionUserOverridden
      } catch (e) { /* first run: no ui state yet */ }
    }
    onLoadFailed: {}
  }

  Process {
    id: uiStateChmodProc
    command: ["chmod", "600", root.uiStatePath]
  }

  // Keyed by MAC (stable across DHCP renewals, unlike name/ip):
  // { online, name, nodeName, missCount }.
  //
  // The Deco client_list only ever lists devices that are currently
  // connected — an offline device doesn't appear with online:false, it's
  // just absent from the array. So "offline" has to be inferred as
  // "a MAC we'd previously seen is missing from this fetch", not read off
  // a field on the current entries.
  //
  // A device has to be missing for `offlineMissThreshold` consecutive polls
  // before it's actually marked offline / notified about, not just one —
  // roaming between this mesh's 3 nodes, or a client whose OS rotates its
  // MAC ("private Wi-Fi address"), can both make a still-connected device
  // vanish from a single poll's client_list. Requiring 2 misses in a row
  // (worst case ~60s slower to notice a real disconnect) filters that out
  // without meaningfully delaying real offline detection.
  // Persisted to deviceStatePath (see below) so this survives an
  // omarchy-restart-shell or a plugin reload — without that, a device that
  // went offline just before a restart is never noticed: the very first
  // poll after restart has nothing to compare against (see the "never on
  // the very first check" reasoning below), so its absence is silently
  // taken as "never seen it, nothing to report" instead of "was online,
  // now isn't".
  property var deviceState: ({})
  readonly property int offlineMissThreshold: 2

  // Devices offline longer than this are dropped from deviceState entirely
  // (not just hidden) — a guest's phone seen once months ago shouldn't be
  // remembered, and reported as "offline", forever. Pruned in
  // noteOnlineChanges, right before offlineDevices is rebuilt.
  readonly property int offlineRetentionMs: 24 * 60 * 60 * 1000

  // Every currently-known-offline device, for the collapsible "Offline"
  // section below — explicitly reassigned (not mutated in place) whenever
  // it changes so the Repeater bound to it actually re-renders, same
  // reasoning as `nodes` further down.
  property var offlineDevices: []

  // Fires a notification only on an actual state *change*, never for a
  // device that's simply always offline, and never on the very first check
  // each session (nothing to compare against yet) — same reasoning as
  // tapo-cameras' offline/online check.
  //
  // Defaults on (existing users keep getting notified unless they turn it
  // off) — persisted alongside host/username/password in config.json.
  property bool notifyEnabled: true

  function formatElapsed(ms) {
    var s = Math.floor(ms / 1000)
    if (s < 60) return "just now"
    var m = Math.floor(s / 60)
    if (m < 60) return m + "m ago"
    var h = Math.floor(m / 60)
    if (h < 24) return h + "h ago"
    return Math.floor(h / 24) + "d ago"
  }

  function noteOnlineChanges(newDevices) {
    var now = Date.now()
    var seenMacs = {}
    for (var i = 0; i < newDevices.length; i++) {
      var device = newDevices[i]
      if (!device.mac) continue
      seenMacs[device.mac] = true
      var previous = root.deviceState[device.mac]
      var wasOffline = previous !== undefined && previous.online === false
      root.deviceState[device.mac] = {
        online: true, name: device.name, mac: device.mac,
        nodeName: device.nodeName, missCount: 0, offlineSince: 0
      }
      if (wasOffline && root.notifyEnabled) {
        Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Deco Mesh",
          "-g", root.routerGlyph, "-u", "low", device.name + " is back online"])
      }
    }

    var macs = Object.keys(root.deviceState)
    for (var j = 0; j < macs.length; j++) {
      var mac = macs[j]
      if (seenMacs[mac]) continue
      var state = root.deviceState[mac]
      if (state.online === false) {
        // Already offline — drop it entirely once it's been gone long
        // enough that it's not worth remembering any more.
        if (now - state.offlineSince > root.offlineRetentionMs) delete root.deviceState[mac]
        continue
      }

      var missCount = (state.missCount || 0) + 1
      if (missCount < root.offlineMissThreshold) {
        // Not offline yet — could be a roaming blip or a mid-handoff poll.
        root.deviceState[mac] = { online: true, name: state.name, mac: mac,
          nodeName: state.nodeName, missCount: missCount, offlineSince: 0 }
        continue
      }
      root.deviceState[mac] = { online: false, name: state.name, mac: mac,
        nodeName: state.nodeName, missCount: missCount, offlineSince: now }
      if (root.notifyEnabled) {
        Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Deco Mesh",
          "-g", root.routerGlyph, "-u", "normal", state.name + " went offline"])
      }
    }

    root.offlineDevices = Object.keys(root.deviceState)
      .map(function (m) { return root.deviceState[m] })
      .filter(function (d) { return !d.online })
      .sort(function (a, b) { return a.name.localeCompare(b.name) })

    root.saveDeviceState()
  }

  function saveDeviceState() {
    deviceStateFile.setText(JSON.stringify(root.deviceState, null, 2))
    deviceStateFile.waitForJob()
    deviceStateChmodProc.running = true
  }

  property string fieldHost: ""
  property string fieldUsername: "admin"
  property string fieldPassword: ""

  // Outside the plugin directory for the same reason tapo-cameras keeps its
  // config there: Omarchy hot-reloads the whole plugin on any file change
  // under its own directory, and refreshes would otherwise retrigger that.
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/deco-mesh"
  readonly property string configPath: root.stateDir + "/config.json"
  readonly property string deviceStatePath: Quickshell.env("HOME") + "/.local/state/omarchy/deco-mesh/device-state.json"
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.zestybytes.deco-mesh"
  // The venv lives in the state dir, NOT the plugin dir: venvs contain
  // symlinks (bin/python, lib64), which `omarchy plugin update` rejects
  // inside a plugin folder (rolling the update back), and writing there
  // also triggers Omarchy's plugin hot-reload. A missing venv here (e.g.
  // after upgrading from a version that built it in the plugin dir) just
  // shows the "Install dependencies" flow again.
  readonly property string venvDir: root.stateDir + "/venv"
  readonly property string pythonBin: root.venvDir + "/bin/python3"
  readonly property string statusScript: root.pluginDir + "/deco_status.py"
  readonly property string routerGlyph: "󱂇"

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function open() {
    configFile.reload()
    configFile.waitForJob()
    root.controller.show()
    root.refresh()
  }
  function formatSpeed(kbps) {
    if (!kbps || kbps <= 0) return "0"
    var mbps = kbps / 1000
    return mbps >= 1 ? mbps.toFixed(1) + "Mb" : Math.round(kbps) + "Kb"
  }
  function close() { root.controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }

  function refresh() {
    if (!root.depsReady || statusProc.running) return
    statusProc.capturedOut = ""
    statusProc.command = [root.pythonBin, root.statusScript]
    statusProc.running = true
  }

  // Only reached by an explicit "Install dependencies" click — never run
  // automatically. Builds the venv, then installs the pinned, hashed
  // requirements.txt with --require-hashes so the bytes that end up
  // executing are exactly the ones this repo committed to, not whatever
  // PyPI happens to serve that day.
  function installDeps() {
    if (root.installingDeps) return
    root.installingDeps = true
    root.lastError = ""
    venvDirProc.running = true
  }

  function friendlyError(msg) {
    if (!msg) return ""
    if (msg.indexOf("Login rejected") !== -1) return "Wrong username or password."
    if (msg.indexOf("Max retries exceeded") !== -1 || msg.indexOf("Failed to establish") !== -1 ||
        msg.indexOf("Connection refused") !== -1 || msg.indexOf("timed out") !== -1) {
      return "Couldn't reach " + root.fieldHost + " — check the router IP."
    }
    return msg
  }

  property bool testingConnection: false
  property string testMessage: ""

  function saveSettings() {
    var config = {
      host: root.fieldHost,
      username: root.fieldUsername,
      password: root.fieldPassword,
      notifyEnabled: root.notifyEnabled
    }
    configFile.setText(JSON.stringify(config, null, 2))
    configFile.waitForJob()
    chmodProc.running = true
    root.testingConnection = true
    root.testMessage = ""
    root.refresh()
  }

  // Flipping the notification toggle shouldn't re-test the router
  // connection (that's what the "Save" button on the credential fields is
  // for) — just persist the current field values quietly.
  function persistSettingsQuietly() {
    var config = {
      host: root.fieldHost,
      username: root.fieldUsername,
      password: root.fieldPassword,
      notifyEnabled: root.notifyEnabled
    }
    configFile.setText(JSON.stringify(config, null, 2))
    configFile.waitForJob()
    chmodProc.running = true
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try {
        var config = JSON.parse(text())
        root.fieldHost = config.host || ""
        root.fieldUsername = config.username || "admin"
        root.fieldPassword = config.password || ""
        root.notifyEnabled = config.notifyEnabled !== false
      } catch (e) { /* first run: no config yet */ }
    }
    onLoadFailed: {}
  }

  // See deviceState above for why this exists — without it, "offline"
  // history is lost on every restart. Loaded synchronously in
  // Component.onCompleted, before setupProc can let the first poll run, so
  // that poll always has real prior state to diff against.
  FileView {
    id: deviceStateFile
    path: root.deviceStatePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: {
      try { root.deviceState = JSON.parse(text()) } catch (e) { root.deviceState = {} }
    }
    onLoadFailed: { root.deviceState = {} }
  }

  Process {
    id: mkdirProc
    command: ["mkdir", "-m", "700", "-p", root.stateDir]
  }

  // FileView has no way to set the mode it writes with, and Omarchy's
  // FileView has been observed writing 644 in a 755 dir — that would leave
  // the router's admin password world-readable. Lock both down explicitly
  // right after every write (mkdirProc above covers the directory on first
  // run, but re-chmod it here too in case something else loosened it).
  Process {
    id: chmodProc
    command: ["sh", "-c",
      "chmod 700 '" + Quickshell.env("HOME") + "/.local/state/omarchy/deco-mesh' && " +
      "chmod 600 '" + root.configPath + "'"]
  }

  // device-state.json isn't credential-bearing like config.json, but it's a
  // history of MACs/device names seen on the network — still worth keeping
  // to the same 600 as everything else in this directory.
  Process {
    id: deviceStateChmodProc
    command: ["chmod", "600", root.deviceStatePath]
  }

  // Pure existence check, run on every load — no shell involved, just argv.
  // Only flips depsReady; never installs anything on its own.
  Process {
    id: checkDepsProc
    command: ["test", "-x", root.pythonBin]
    onExited: function (exitCode) {
      root.depsReady = exitCode === 0
      if (root.depsReady) refreshTimer.running = true
    }
  }

  // installDeps() → venvDirProc → venvProc → ensurepipProc → pipInstallProc. Kept as
  // separate argv-only Processes (no "sh -c" string) so nothing here is ever
  // built by interpolating a path into a shell program. ensurepip installs the
  // pip wheel bundled with CPython (offline, no PyPI fetch), because some
  // distros (e.g. Arch) can create a venv without pip, which made the pip
  // step fail with "No module named pip".
  function installStepFailed(step, exitCode, stderrText) {
    root.installingDeps = false
    var detail = String(stderrText || "").trim().split("\n").pop()
    root.lastError = step + " failed (exit " + exitCode + ")" + (detail ? ": " + detail : ".")
    console.warn("deco-mesh: " + step + " failed (exit " + exitCode + "): " + stderrText)
  }

  // Make sure the 0700 state dir exists before building the venv inside it
  // (mkdirProc on load is async, so don't rely on it having finished).
  Process {
    id: venvDirProc
    command: ["mkdir", "-m", "700", "-p", root.stateDir]
    stderr: StdioCollector { id: venvDirErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode === 0) {
        venvProc.running = true
      } else {
        root.installStepFailed("Creating the state directory", exitCode, venvDirErr.text)
      }
    }
  }

  Process {
    id: venvProc
    command: ["python3", "-m", "venv", root.venvDir]
    stderr: StdioCollector { id: venvErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode === 0) {
        ensurepipProc.running = true
      } else {
        root.installStepFailed("Creating the Python environment", exitCode, venvErr.text)
      }
    }
  }

  Process {
    id: ensurepipProc
    command: [root.pythonBin, "-m", "ensurepip", "--default-pip"]
    stderr: StdioCollector { id: ensurepipErr; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode === 0) {
        pipInstallProc.running = true
      } else {
        root.installStepFailed("Installing pip into the venv", exitCode, ensurepipErr.text)
      }
    }
  }

  Process {
    id: pipInstallProc
    command: [root.pythonBin, "-m", "pip", "install", "-q",
      "--require-hashes", "-r", root.pluginDir + "/requirements.txt"]
    stderr: StdioCollector { id: pipErr; waitForEnd: true }
    onExited: function (exitCode) {
      root.depsReady = exitCode === 0
      if (root.depsReady) {
        root.installingDeps = false
        refreshTimer.running = true
      } else {
        root.installStepFailed("Dependency install", exitCode, pipErr.text)
      }
    }
  }

  Component.onCompleted: {
    mkdirProc.running = true
    chmodProc.running = true  // covers a config.json left over from before this fix
    deviceStateFile.reload()
    deviceStateFile.waitForJob()  // must land before refresh() can be called
    uiStateFile.reload()
    uiStateFile.waitForJob()
    checkDepsProc.running = true
  }

  Timer {
    id: refreshTimer
    interval: 60000
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProc
    property string capturedOut: ""
    stdout: StdioCollector {
      waitForEnd: true
      // Parse here, not in onExited: Process.exited can fire before the
      // stdout collector has delivered its text, which made JSON.parse("")
      // throw and show "Couldn't read status" intermittently.
      onStreamFinished: {
        statusProc.capturedOut = String(text || "").trim()
        statusProc.handleResult()
      }
    }
    function handleResult() {
      var newNodes = []
      var errorText = ""
      try {
        var result = JSON.parse(statusProc.capturedOut)
        if (result.error) {
          errorText = result.error === "not_configured" ? "Not set up yet" : root.friendlyError(result.error)
        } else {
          newNodes = result.nodes || []
          var flatClients = []
          for (var i = 0; i < newNodes.length; i++) {
            var nodeName = newNodes[i].name
            var tagged = newNodes[i].clients.map(function (c) {
              return { name: c.name, ip: c.ip, mac: c.mac, online: c.online,
                down_kbps: c.down_kbps, up_kbps: c.up_kbps, nodeName: nodeName }
            })
            flatClients = flatClients.concat(tagged)
          }
          root.noteOnlineChanges(flatClients)
        }
      } catch (e) {
        errorText = "Couldn't read status"
      }

      if (root.testingConnection) {
        root.testingConnection = false
        root.testMessage = errorText ? errorText
          : "Connected — found " + newNodes.reduce(function (n, node) { return n + node.clients.length }, 0)
            + " device(s) across " + newNodes.length + " node(s)."
      }
      root.lastError = errorText
      root.nodes = newNodes
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.routerGlyph
    slotSize: Style.bar.statusSlot
    tooltipText: root.lastError ? "Deco Mesh: " + root.lastError
      : "Deco Mesh: " + root.onlineCount + " device(s) online"
        + (root.totalDownKbps > 0 || root.totalUpKbps > 0
           ? "\n↓" + root.formatSpeed(root.totalDownKbps) + " ↑" + root.formatSpeed(root.totalUpKbps)
           : "")
    onPressed: root.toggle()
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: Style.space(340)
    contentHeight: root.settingsMode
      ? Style.space(70) + settingsColumn.implicitHeight + Style.space(24)
      : Style.space(70) +
        (!root.depsReady ? Style.space(80) : 0) +
        (root.lastError ? Style.space(40) : 0) +
        (root.depsReady && root.allClients.length === 0 && !root.lastError ? Style.space(40) : 0) +
        deviceColumn.implicitHeight + Style.space(20)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
    }

    ColumnLayout {
      anchors.fill: parent
      anchors.margins: Style.space(16)
      spacing: Style.space(10)

      RowLayout {
        Layout.fillWidth: true
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          text: root.settingsMode ? "Deco Settings" : "Deco Mesh"
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
          Layout.fillWidth: true
        }

        PanelActionButton {
          iconText: root.settingsMode ? "" : "" // fa-arrow-left : fa-cog
          tooltipText: root.settingsMode ? "Back" : "Deco settings"
          foreground: root.barForeground
          onClicked: {
            root.settingsMode = !root.settingsMode
            root.testMessage = ""
          }
        }
      }

      // ------------------------------------------------------ settings

      ColumnLayout {
        id: settingsColumn
        visible: root.settingsMode
        Layout.fillWidth: true
        spacing: Style.space(8)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(8)

          ColumnLayout {
            Layout.fillWidth: true
            spacing: 0

            Text {
              textFormat: Text.PlainText
              text: "Notifications"
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
              textFormat: Text.PlainText
              text: "Alert when a device goes offline or comes back online"
              color: Qt.darker(root.barForeground, 1.5)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption * 0.85
              wrapMode: Text.WordWrap
              Layout.fillWidth: true
            }
          }

          ToggleSwitch {
            checked: root.notifyEnabled
            foreground: root.barForeground
            onToggled: {
              root.notifyEnabled = !root.notifyEnabled
              root.persistSettingsQuietly()
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          text: "Router IP (e.g. 192.168.68.1)"
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        TextField {
          Layout.fillWidth: true
          foreground: root.barForeground
          text: root.fieldHost
          onTextChanged: root.fieldHost = text
        }

        Text {
          textFormat: Text.PlainText
          text: "Admin username"
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        TextField {
          Layout.fillWidth: true
          foreground: root.barForeground
          text: root.fieldUsername
          onTextChanged: root.fieldUsername = text
        }

        Text {
          textFormat: Text.PlainText
          text: "Admin password"
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
        TextField {
          Layout.fillWidth: true
          foreground: root.barForeground
          echoMode: TextInput.Password
          text: root.fieldPassword
          onTextChanged: root.fieldPassword = text
        }

        Button {
          text: root.testingConnection ? "Testing…" : "Save"
          enabled: !root.testingConnection
          bordered: true
          focusable: true
          foreground: root.barForeground
          onClicked: root.saveSettings()
        }

        Text {
          visible: root.testMessage !== ""
          text: root.testMessage
          textFormat: Text.PlainText
          color: root.testMessage.indexOf("Connected") === 0
            ? "#4caf50" : (root.bar ? root.bar.urgent : Color.urgent)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          Layout.fillWidth: true
        }
      }

      // ---------------------------------------------------------- view

      Text {
        visible: !root.settingsMode && !root.depsReady
        text: root.installingDeps ? "Installing dependencies…" : "Dependencies not installed yet."
        textFormat: Text.PlainText
        color: root.barForeground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
      }

      Button {
        visible: !root.settingsMode && !root.depsReady
        text: root.installingDeps ? "Installing…" : "Install dependencies"
        enabled: !root.installingDeps
        bordered: true
        focusable: true
        foreground: root.barForeground
        onClicked: root.installDeps()
      }

      Text {
        visible: !root.settingsMode && root.lastError !== ""
        text: root.lastError
        textFormat: Text.PlainText
        color: root.bar ? root.bar.urgent : Color.urgent
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
        Layout.fillWidth: true
      }

      Text {
        textFormat: Text.PlainText
        visible: !root.settingsMode && root.depsReady && !root.lastError && root.allClients.length === 0
        text: "No devices found."
        color: root.barForeground
        font.family: Style.font.family
        font.pixelSize: Style.font.caption
      }

      // Tree: each mesh node as a header row, its connected clients
      // indented underneath. A node with no clients still gets a header
      // (so "nothing's on the Kitchen node" is visible, not just absent).
      ColumnLayout {
        id: deviceColumn
        visible: !root.settingsMode
        Layout.fillWidth: true
        spacing: Style.space(10)

        Repeater {
          model: root.nodes
          delegate: ColumnLayout {
            Layout.fillWidth: true
            spacing: Style.space(3)

            MouseArea {
              Layout.fillWidth: true
              implicitHeight: nodeHeaderRow.implicitHeight
              cursorShape: Qt.PointingHandCursor
              onClicked: root.toggleNodeCollapsed(modelData.mac)

              RowLayout {
                id: nodeHeaderRow
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: root.isNodeCollapsed(modelData.mac) ? "" : "" // fa-chevron-right : fa-chevron-down
                  color: root.barForeground
                  opacity: 0.6
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.routerGlyph
                  color: root.barForeground
                  opacity: 0.8
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData.name + (modelData.role === "master" ? " (main)" : "")
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData.clients.length + " device" + (modelData.clients.length === 1 ? "" : "s")
                  color: root.barForeground
                  opacity: 0.5
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: !!modelData.via && !root.isNodeCollapsed(modelData.mac)
              text: "via " + modelData.via + (modelData.via_dbm !== null ? " (" + modelData.via_dbm + "dBm)" : "")
              color: root.barForeground
              opacity: 0.5
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              Layout.leftMargin: Style.space(18)
            }

            Repeater {
              model: root.isNodeCollapsed(modelData.mac) ? [] : modelData.clients
              delegate: RowLayout {
                Layout.fillWidth: true
                Layout.leftMargin: Style.space(18)
                spacing: Style.space(6)

                Rectangle {
                  width: Style.space(8)
                  height: Style.space(8)
                  radius: width / 2
                  color: modelData.online ? "#4caf50" : "#888888"
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData.name
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                }
                Text {
                  textFormat: Text.PlainText
                  // Active traffic is more useful to see at a glance than
                  // the IP, so it takes over this slot when there is any —
                  // both come from the same 60s poll, no extra fetch.
                  text: (modelData.down_kbps > 0 || modelData.up_kbps > 0)
                    ? "↓" + root.formatSpeed(modelData.down_kbps) + " ↑" + root.formatSpeed(modelData.up_kbps)
                    : modelData.ip
                  color: root.barForeground
                  opacity: 0.6
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }
        }

        // Collapsed by default — a big offline count from a first-ever poll
        // (nothing to compare against yet, see noteOnlineChanges) or a
        // household with several always-off devices would otherwise push
        // the online tree below the fold every time the panel opens.
        ColumnLayout {
          Layout.fillWidth: true
          visible: root.offlineDevices.length > 0
          spacing: Style.space(3)

          RowLayout {
            Layout.fillWidth: true
            spacing: Style.space(6)

            MouseArea {
              Layout.fillWidth: true
              implicitHeight: offlineHeaderRow.implicitHeight
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.offlineSectionUserOverridden = true
                root.offlineSectionExpanded = !root.offlineSectionExpanded
                root.saveUiState()
              }

              RowLayout {
                id: offlineHeaderRow
                anchors.left: parent.left
                anchors.right: parent.right
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: root.offlineSectionExpanded ? "" : "" // fa-chevron-down : fa-chevron-right
                  color: root.barForeground
                  opacity: 0.6
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.routerGlyph
                  color: root.barForeground
                  opacity: 0.8
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
                Text {
                  textFormat: Text.PlainText
                  text: "Offline"
                  color: root.barForeground
                  opacity: 0.7
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  Layout.fillWidth: true
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.offlineDevices.length + " device" + (root.offlineDevices.length === 1 ? "" : "s")
                  color: root.barForeground
                  opacity: 0.5
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          Repeater {
            model: root.offlineSectionExpanded ? root.offlineDevices : []
            delegate: RowLayout {
              Layout.fillWidth: true
              Layout.leftMargin: Style.space(18)
              spacing: Style.space(6)

              Rectangle {
                width: Style.space(8)
                height: Style.space(8)
                radius: width / 2
                color: "#e05c5c"
              }
              Text {
                textFormat: Text.PlainText
                text: modelData.name
                color: root.barForeground
                opacity: 0.7
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                Layout.fillWidth: true
                elide: Text.ElideRight
              }
              Text {
                textFormat: Text.PlainText
                // root.clock is read purely to create a binding dependency:
                // Date.now() itself isn't a notifying property, so without
                // something to re-trigger this binding on, it only ever
                // recomputes when the delegate is freshly created — leaving
                // it stuck on "just now" until the next full model reset,
                // which isn't guaranteed every poll (see the clock Timer
                // below).
                text: { var _t = root.clock; return root.formatElapsed(Date.now() - modelData.offlineSince) }
                color: root.barForeground
                opacity: 0.4
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }
          }
        }
      }
    }
  }
}
