import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.blazeeers.omavpn"
  ipcTarget: "io.github.blazeeers.omavpn"
  manageIpc: false

  readonly property string cliPath: Quickshell.env("HOME") + "/.local/bin/omavpn"

  property var st: ({ ok: false, running: false, installed: true, profiles: [], nodes: [] })
  property string lastError: ""
  property string busy: ""
  property bool autoTried: false
  property string exitIp: ""
  property string directIp: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property bool running: !!st.running
  readonly property var profilesList: st.profiles instanceof Array ? st.profiles : []
  readonly property var nodesList: st.nodes instanceof Array ? st.nodes : []

  // ---- helpers ------------------------------------------------------------
  function run(args, label) {
    if (actionProc.running) return
    root.busy = label || "…"
    actionProc.command = [root.cliPath, "--json"].concat(args)
    actionProc.running = true
  }

  function setSetting(key, value) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var k in settings) if (k !== "id") entry[k] = settings[k]
    entry[key] = value
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function fmtBytes(b) {
    b = Number(b) || 0
    var u = ["B", "KB", "MB", "GB", "TB"]
    var i = 0
    while (b >= 1024 && i < u.length - 1) { b /= 1024; i++ }
    return (i === 0 ? b.toFixed(0) : b.toFixed(1)) + " " + u[i]
  }

  function fmtUptime(s) {
    s = Math.max(0, Number(s) || 0)
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = Math.floor(s % 60)
    function pad(x) { return (x < 10 ? "0" : "") + x }
    return (h > 0 ? h + ":" + pad(m) : pad(m)) + ":" + pad(sec)
  }

  readonly property string metaText: {
    if (!root.running) return root.st.installed ? "Отключено" : "Не установлено"
    var mode = root.st.mode === "tun" ? "TUN" : "SOCKS/HTTP"
    return "Подключено · " + mode + " · " + root.fmtUptime(root.st.uptime)
  }

  // ---- lifecycle ----------------------------------------------------------
  onOpenedChanged: if (opened && !statusProc.running) statusProc.running = true

  onStChanged: {
    if (!root.autoTried && root.setting("autoconnect", false)
        && root.st && root.st.installed && !root.st.running) {
      root.autoTried = true
      root.run(["on"], "on")
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function vpnToggle(): string { root.run(["toggle"], "toggle"); return "ok" }
    function vpnUp(): string { root.run(["on"], "on"); return "ok" }
    function vpnDown(): string { root.run(["off"], "off"); return "ok" }
  }

  // ---- status poll --------------------------------------------------------
  Process {
    id: statusProc
    command: [root.cliPath, "--json", "status"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) return
      try {
        var d = JSON.parse(statusOut.text)
        if (d && d.ok) root.st = d
      } catch (e) { /* неполный вывод — пропускаем */ }
    }
  }

  Timer {
    interval: root.running ? 2000 : 5000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statusProc.running) statusProc.running = true
  }

  // ---- actions ------------------------------------------------------------
  Process {
    id: actionProc
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(code) {
      root.busy = ""
      if (code !== 0) {
        var t = (actionErr.text || actionOut.text || "").trim()
        try { var j = JSON.parse(t); if (j.error) t = j.error } catch (e) { /* plain */ }
        root.lastError = t || "ошибка"
      } else {
        root.lastError = ""
      }
      if (!statusProc.running) statusProc.running = true
    }
  }

  Process {
    id: checkProc
    stdout: StdioCollector { id: checkOut; waitForEnd: true }
    onExited: function(code) {
      root.busy = ""
      try {
        var j = JSON.parse(checkOut.text)
        root.exitIp = j.proxy_ip || ""
        root.directIp = j.direct_ip || ""
        if (!j.ok) root.lastError = j.error || "не удалось проверить IP"
      } catch (e) { root.lastError = "нет ответа от omavpn" }
    }
  }

  // ---- bar button ---------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf023"
    active: root.running
    activeColor: Color.accent
    tooltipText: root.running
      ? "omavpn: " + (root.st.profile_name || "подключено")
      : "omavpn: отключено"
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.run(["toggle"], "toggle")
      else root.toggle()
    }
  }

  // ---- popup --------------------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.run(["toggle"], "toggle")
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

        PanelHero {
          width: parent.width
          title: root.running ? (root.st.profile_name || "omavpn") : "omavpn"
          meta: root.metaText
          foreground: root.foreground
          fontFamily: root.fontFamily
          iconOpacity: root.running ? 1.0 : 0.5

          iconComponent: Component {
            Text {
              text: "\uf023"
              color: root.running ? root.foreground : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }

          trailingControl: Component {
            ToggleSwitch {
              checked: root.running
              busy: root.busy !== ""
              foreground: root.foreground
              accent: Color.accent
              onToggled: root.run(["toggle"], "toggle")
            }
          }
        }

        Text {
          width: parent.width
          visible: root.running
          textFormat: Text.PlainText
          text: "↓ " + root.fmtBytes(root.st.rx) + "   ↑ " + root.fmtBytes(root.st.tx)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Text {
          width: parent.width
          visible: root.exitIp !== ""
          textFormat: Text.PlainText
          text: "Внешний IP: " + root.exitIp
                + (root.directIp && root.exitIp !== root.directIp ? "  (было " + root.directIp + ")" : "")
          color: root.exitIp !== root.directIp ? Color.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          visible: root.lastError !== ""
          textFormat: Text.PlainText
          text: root.lastError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader { text: "ПРОФИЛЬ"; foreground: root.foreground; fontFamily: root.fontFamily }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Repeater {
            model: root.profilesList

            Rectangle {
              id: prow
              required property var modelData
              required property int index
              width: column.width
              implicitHeight: pcol.implicitHeight + Style.space(12)
              radius: Style.cornerRadius > 0 ? Style.space(8) : 0
              color: prow.modelData.index === root.st.profile_index
                       ? root.selectedFill
                       : (pmouse.containsMouse ? root.hoverFill : "transparent")

              Column {
                id: pcol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: prow.modelData.name
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: prow.modelData.node_count + " сервер(ов)"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: pmouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.run(["profile", String(prow.modelData.index)], "profile")
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        PanelSectionHeader { text: "СЕРВЕР"; foreground: root.foreground; fontFamily: root.fontFamily }

        Column {
          width: parent.width
          spacing: Style.space(4)

          Rectangle {
            id: autoRow
            width: column.width
            implicitHeight: acol.implicitHeight + Style.space(12)
            radius: Style.cornerRadius > 0 ? Style.space(8) : 0
            color: root.st.node_index < 0
                     ? root.selectedFill
                     : (amouse.containsMouse ? root.hoverFill : "transparent")

            Column {
              id: acol
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(1)

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Авто (балансировка)"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                elide: Text.ElideRight
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "Выбор лучшего сервера"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            MouseArea {
              id: amouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.run(["node", "-1"], "node")
            }
          }

          Repeater {
            model: root.nodesList

            Rectangle {
              id: nrow
              required property var modelData
              required property int index
              width: column.width
              implicitHeight: ncol.implicitHeight + Style.space(12)
              radius: Style.cornerRadius > 0 ? Style.space(8) : 0
              color: nrow.modelData.index === root.st.node_index
                       ? root.selectedFill
                       : (nmouse.containsMouse ? root.hoverFill : "transparent")

              Column {
                id: ncol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(1)

                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: nrow.modelData.tag
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: nrow.modelData.detail
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: nmouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.run(["node", String(nrow.modelData.index)], "node")
              }
            }
          }
        }

        PanelSeparator { foreground: root.foreground }

        Flow {
          width: parent.width
          spacing: Style.space(8)

          Rectangle {
            id: refreshBtn
            implicitWidth: refreshTxt.implicitWidth + Style.space(20)
            implicitHeight: refreshTxt.implicitHeight + Style.space(12)
            radius: Style.cornerRadius > 0 ? Style.space(8) : 0
            color: rmouse.containsMouse ? root.hoverFill
                   : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            Text {
              id: refreshTxt
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.busy !== "" ? "…" : "Обновить подписку"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: rmouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.run(["update"], "update")
            }
          }

          Rectangle {
            id: checkBtn
            implicitWidth: checkTxt.implicitWidth + Style.space(20)
            implicitHeight: checkTxt.implicitHeight + Style.space(12)
            radius: Style.cornerRadius > 0 ? Style.space(8) : 0
            opacity: root.running ? 1.0 : 0.4
            color: cmouse.containsMouse && root.running ? root.hoverFill
                   : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            Text {
              id: checkTxt
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: "Проверить IP"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: cmouse
              anchors.fill: parent
              enabled: root.running
              hoverEnabled: true
              cursorShape: root.running ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: {
                if (checkProc.running) return
                root.busy = "check"
                checkProc.running = true
              }
            }
          }

          Rectangle {
            id: modeBtn
            implicitWidth: modeTxt.implicitWidth + Style.space(20)
            implicitHeight: modeTxt.implicitHeight + Style.space(12)
            radius: Style.cornerRadius > 0 ? Style.space(8) : 0
            color: mmouse.containsMouse ? root.hoverFill
                   : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            Text {
              id: modeTxt
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.st.mode === "tun" ? "Режим: TUN" : "Режим: SOCKS"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: mmouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.run(["mode", root.st.mode === "tun" ? "proxy" : "tun"], "mode")
            }
          }

          Rectangle {
            id: autoBtn
            property bool on: root.setting("autoconnect", false)
            implicitWidth: autoTxt.implicitWidth + Style.space(20)
            implicitHeight: autoTxt.implicitHeight + Style.space(12)
            radius: Style.cornerRadius > 0 ? Style.space(8) : 0
            color: autoBtn.on ? root.selectedFill
                   : (aumouse.containsMouse ? root.hoverFill
                     : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06))
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            Text {
              id: autoTxt
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: "Автозапуск: " + (autoBtn.on ? "вкл" : "выкл")
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: aumouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.setSetting("autoconnect", !autoBtn.on)
            }
          }
        }
      }
    }
  }
}
