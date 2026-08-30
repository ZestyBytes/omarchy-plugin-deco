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
  property bool settingsMode: false

  // Keyed by MAC (stable across DHCP renewals, unlike name/ip): { online, name }.
  // Fires a notification only on an actual state *change*, never for a
  // device that's simply always offline, and never on the very first check
  // each session (nothing to compare against yet) — same reasoning as
  // tapo-cameras' offline/online check.
  //
  // The Deco client_list only ever lists devices that are currently
  // connected — an offline device doesn't appear with online:false, it's
  // just absent from the array. So "offline" has to be inferred as
  // "a MAC we'd previously seen is missing from this fetch", not read off
  // a field on the current entries.
  property var deviceOnlineState: ({})

  // Defaults on (existing users keep getting notified unless they turn it
  // off) — persisted alongside host/username/password in config.json.
  property bool notifyEnabled: true

  function noteOnlineChanges(newDevices) {
    var seenMacs = {}
    for (var i = 0; i < newDevices.length; i++) {
      var device = newDevices[i]
      if (!device.mac) continue
      seenMacs[device.mac] = true
      var previous = root.deviceOnlineState[device.mac]
      root.deviceOnlineState[device.mac] = { online: true, name: device.name }
      if (previous !== undefined && previous.online === false && root.notifyEnabled) {
        Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Deco Mesh",
          "-g", root.routerGlyph, "-u", "low", device.name + " is back online"])
      }
    }
    var macs = Object.keys(root.deviceOnlineState)
    for (var j = 0; j < macs.length; j++) {
      var mac = macs[j]
      if (seenMacs[mac]) continue
      var state = root.deviceOnlineState[mac]
      if (state.online === false) continue // already reported offline
      root.deviceOnlineState[mac] = { online: false, name: state.name }
      if (root.notifyEnabled) {
        Quickshell.execDetached(["omarchy-notification-send", "--app-name", "Deco Mesh",
          "-g", root.routerGlyph, "-u", "normal", state.name + " went offline"])
      }
    }
  }

  property string fieldHost: ""
  property string fieldUsername: "admin"
  property string fieldPassword: ""

  // Outside the plugin directory for the same reason tapo-cameras keeps its
  // config there: Omarchy hot-reloads the whole plugin on any file change
  // under its own directory, and refreshes would otherwise retrigger that.
  readonly property string configPath: Quickshell.env("HOME") + "/.local/state/omarchy/deco-mesh/config.json"
  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.zestybytes.deco-mesh"
  readonly property string pythonBin: root.pluginDir + "/venv/bin/python3"
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
    if (statusProc.running) return
    statusProc.capturedOut = ""
    statusProc.command = [root.pythonBin, root.statusScript]
    statusProc.running = true
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

  Process {
    id: mkdirProc
    command: ["mkdir", "-m", "700", "-p", Quickshell.env("HOME") + "/.local/state/omarchy/deco-mesh"]
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

  // deco_status.py needs requests + pycryptodome, which aren't part of
  // Omarchy's own Python — rather than asking the user to set up a venv by
  // hand, build one the first time this plugin ever loads (a few seconds,
  // once) and reuse it on every load after.
  Process {
    id: setupProc
    command: ["sh", "-c",
      "[ -x '" + root.pythonBin + "' ] || " +
      "(python3 -m venv '" + root.pluginDir + "/venv' && " +
      "'" + root.pythonBin + "' -m pip install -q -r '" + root.pluginDir + "/requirements.txt')"]
    onExited: refreshTimer.running = true
  }

  Component.onCompleted: {
    mkdirProc.running = true
    chmodProc.running = true  // covers a config.json left over from before this fix
    setupProc.running = true
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
      onStreamFinished: statusProc.capturedOut = String(text || "").trim()
    }
    onExited: {
      var newNodes = []
      var errorText = ""
      try {
        var result = JSON.parse(statusProc.capturedOut)
        if (result.error) {
          errorText = result.error === "not_configured" ? "Not set up yet" : root.friendlyError(result.error)
        } else {
          newNodes = result.nodes || []
          var flatClients = []
          for (var i = 0; i < newNodes.length; i++) flatClients = flatClients.concat(newNodes[i].clients)
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
        (root.lastError ? Style.space(40) : 0) +
        (root.allClients.length === 0 && !root.lastError ? Style.space(40) : 0) +
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
              text: "Notifications"
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
            Text {
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
        visible: !root.settingsMode && !root.lastError && root.allClients.length === 0
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

            RowLayout {
              Layout.fillWidth: true
              spacing: Style.space(6)

              Text {
                text: root.routerGlyph
                color: root.barForeground
                opacity: 0.8
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              Text {
                text: modelData.name + (modelData.role === "master" ? " (main)" : "")
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                font.bold: true
                Layout.fillWidth: true
                elide: Text.ElideRight
              }
              Text {
                text: modelData.clients.length + " device" + (modelData.clients.length === 1 ? "" : "s")
                color: root.barForeground
                opacity: 0.5
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
            }

            Text {
              visible: !!modelData.via
              text: "via " + modelData.via + (modelData.via_dbm !== null ? " (" + modelData.via_dbm + "dBm)" : "")
              color: root.barForeground
              opacity: 0.5
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              Layout.leftMargin: Style.space(18)
            }

            Repeater {
              model: modelData.clients
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
                  text: modelData.name
                  color: root.barForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  Layout.fillWidth: true
                  elide: Text.ElideRight
                }
                Text {
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
      }
    }
  }
}
