import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.blazeeers.bypass-status"
  ipcTarget: "io.github.blazeeers.bypass-status"
  manageIpc: false

  readonly property string scriptPath: Quickshell.env("HOME") + "/.local/bin/bypass-status"

  property var bs: ({ ok: false })
  property var vpnInfo: ({})
  property bool vpnLoaded: false
  property bool vpnExpanded: false
  property string busy: ""
  property string lastError: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color warn: "#ff9f0a"
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property var vpn: (root.bs && root.bs.vpn) ? root.bs.vpn : ({})
  readonly property var zap: (root.bs && root.bs.zapret) ? root.bs.zapret : ({})
  readonly property var tg: (root.bs && root.bs.tgwsproxy) ? root.bs.tgwsproxy : ({})
  readonly property var chk: (root.bs && root.bs.checks) ? root.bs.checks : null
  readonly property string cliPath: (root.bs && root.bs.cli) ? root.bs.cli : ""

  readonly property bool vpnOn: !!root.vpn.running
  readonly property bool zapTesting: !!root.zap.testing || root.zap.autotune === "activating"
  readonly property bool tgDown: !root.tg.listening
  readonly property bool zapretBroken: !root.zapTesting &&
    (root.zap.mode === "vpn" || (root.zap.service !== "active" && root.zap.mode !== "off"))

  // Пиктограмма трея по приоритету: VPN → подбор → tg-ws-proxy → zapret.
  readonly property string statusIcon:
    !root.vpnOn ? "\uf127" :            // разорванная связь — VPN не работает
    root.zapTesting ? "\uf002" :        // лупа — идёт подбор стратегии
    root.tgDown ? "\uf1d8" :            // бумажный самолётик — tg-ws-proxy не работает
    root.zapretBroken ? "\uf071" :      // восклицание — zapret не работает
    "\uf132"                            // щит — всё в порядке
  readonly property color statusColor:
    !root.vpnOn ? root.urgent :
    root.zapTesting ? root.warn :
    root.tgDown ? root.urgent :
    root.zapretBroken ? root.warn :
    Color.accent
  readonly property string statusText:
    !root.vpnOn ? "VPN не работает" :
    root.zapTesting ? "идёт подбор стратегии" :
    root.tgDown ? "tg-ws-proxy не работает" :
    root.zapretBroken ? "zapret не работает" :
    "всё в порядке"

  function fmtUptime(s) {
    s = Math.max(0, Number(s) || 0)
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = Math.floor(s % 60)
    function pad(x) { return (x < 10 ? "0" : "") + x }
    return (h > 0 ? h + ":" + pad(m) : pad(m)) + ":" + pad(sec)
  }

  function codeState(code) { return (code >= 200 && code < 400) ? "ok" : "bad" }

  readonly property var vpnProfiles: (root.vpnInfo && root.vpnInfo.profiles instanceof Array) ? root.vpnInfo.profiles : []

  function retryHint(z) {
    if (!z || !z.retry_seconds) return ""
    var s = Number(z.retry_in) || 0
    if (s <= 0) return " · перепроверка скоро"
    return " · перепроверка через " + Math.ceil(s / 60) + " мин"
  }

  function directSummary(d) {
    d = d || ""
    var a = []
    if (d.indexOf("youtube") >= 0) a.push("youtube")
    if (d.indexOf("discord") >= 0) a.push("discord")
    if (a.length === 0) return "через VPN"
    return a.join(" + ") + " напрямую, остальное через VPN"
  }
  function servicesHint(z) {
    var s = (z && z.services) ? z.services : ""
    if (s === "discord") return " (только discord)"
    if (s === "youtube") return " (только youtube)"
    return ""
  }

  readonly property var rows: {
    var out = [], v = root.vpn, z = root.zap, t = root.tg

    if (v.running) {
      out.push({ name: "VPN", state: "ok", expandable: true,
        detail: (v.profile || "") + " · " + (v.mode === "tun" ? "TUN" : "SOCKS") + " · " + root.fmtUptime(v.uptime) })
    } else {
      out.push({ name: "VPN", state: (v.installed === false ? "bad" : "warn"), expandable: true,
        detail: (v.installed === false ? "не установлен" : "выключен") })
    }

    var zState = "warn", zDetail = "нет данных"
    if (root.zapTesting) {
      var stxt = (Number(z.tested) > 0 && Number(z.total) > 0)
        ? ("попытка " + (Number(z.tested) + 1) + "/" + z.total + " · ") : ""
      zState = "warn"
      zDetail = "идёт подбор: " + stxt + (z.strategy || z.text || "проверка") + (z.isolated ? " · изолированно" : "")
    } else if (z.mode === "vpn") { zState = "warn"; zDetail = "обход не сработал: " + root.directSummary(z.direct) + root.retryHint(z) }
    else if (z.mode === "off") { zState = "ok"; zDetail = "сеть чистая, обход не нужен" }
    else if (z.service !== "active") { zState = "warn"; zDetail = "служба выключена" }
    else if (z.mode === "custom") { zState = "ok"; zDetail = "кастомная стратегия" + root.servicesHint(z) }
    else if (z.mode !== "" && z.mode !== undefined) { zState = "ok"; zDetail = "стратегия #" + z.mode + root.servicesHint(z) }
    else { zState = "warn"; zDetail = "режим неизвестен" }
    out.push({ name: "zapret (DPI)", state: zState, detail: zDetail + (z.network ? " · " + z.network : "") })

    out.push({ name: "tg-ws-proxy", state: t.listening ? "ok" : "bad",
      detail: t.listening ? ("порт " + t.port + ", работает") : "не слушает" })

    if (root.chk) {
      out.push({ name: "Яндекс", state: root.codeState(root.chk.yandex), detail: "HTTP " + root.chk.yandex })
      out.push({ name: "Telegram API", state: root.codeState(root.chk.telegram_api), detail: "HTTP " + root.chk.telegram_api })
      out.push({ name: "YouTube", state: root.codeState(root.chk.youtube), detail: "HTTP " + root.chk.youtube })
      out.push({ name: "Discord", state: root.codeState(root.chk.discord), detail: "HTTP " + root.chk.discord })
    }
    return out
  }

  readonly property bool anyBad: {
    var r = root.rows
    for (var i = 0; i < r.length; i++) if (r[i].state === "bad") return true
    return false
  }
  readonly property bool anyWarn: {
    var r = root.rows
    for (var i = 0; i < r.length; i++) if (r[i].state === "warn") return true
    return false
  }
  readonly property color healthColor: root.anyBad ? root.urgent : (root.anyWarn ? root.warn : Color.accent)
  readonly property string summary:
    "VPN " + (root.vpnOn ? "вкл" : "выкл")
    + " · zapret " + (root.zapTesting ? "подбор…" : (root.zap.mode === "vpn" ? "через VPN" : (root.zap.service === "active" ? "вкл" : "выкл")))
    + " · TG " + (root.tg.listening ? "ок" : "нет")

  // ---- actions ------------------------------------------------------------
  function run(args, label) {
    if (actionProc.running || root.cliPath === "") return
    root.busy = label || "…"
    actionProc.command = [root.cliPath, "--json"].concat(args)
    actionProc.running = true
  }

  onOpenedChanged: if (opened) {
    if (!statusProc.running) statusProc.running = true
    if (!vpnProc.running && (!root.vpnLoaded || (Date.now() / 1000 - (root.vpnInfo.updated || 0)) > 120))
      vpnProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
  }

  Process {
    id: statusProc
    command: [root.scriptPath, "--json"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) return
      try {
        var d = JSON.parse(statusOut.text)
        if (d && d.ok) { root.bs = d; root.lastError = "" }
      } catch (e) { /* неполный вывод */ }
    }
  }

  Process {
    id: checkProc
    command: [root.scriptPath, "--check"]
    stdout: StdioCollector { id: checkOut; waitForEnd: true }
    onExited: function(code) {
      root.busy = ""
      if (code !== 0) { root.lastError = "проверка не удалась"; return }
      try {
        var d = JSON.parse(checkOut.text)
        if (d && d.ok) root.bs = d
      } catch (e) { root.lastError = "нет ответа от bypass-status" }
    }
  }

  Process {
    id: vpnProc
    command: [root.scriptPath, "--vpn"]
    stdout: StdioCollector { id: vpnOut; waitForEnd: true }
    onExited: function(code) {
      root.busy = ""
      if (code !== 0) return
      try {
        var d = JSON.parse(vpnOut.text)
        if (d && d.ok) { root.vpnInfo = d; root.vpnLoaded = true }
      } catch (e) { /* ignore */ }
    }
  }

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
      } else { root.lastError = "" }
      if (!statusProc.running) statusProc.running = true
      if (!vpnProc.running) vpnProc.running = true
    }
  }

  Timer {
    interval: 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statusProc.running) statusProc.running = true
  }

  // ---- bar button ---------------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.statusIcon
    active: true
    activeColor: root.statusColor
    tooltipText: "Обходы: " + root.statusText + " · " + root.summary
    onPressed: function(buttonCode) { root.toggle() }
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
          title: "Обходы"
          meta: root.summary
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Text {
              text: root.statusIcon
              color: root.statusColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.display
            }
          }
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

        Column {
          width: parent.width
          spacing: Style.space(6)

          Repeater {
            model: root.rows

            Rectangle {
              id: srow
              required property var modelData
              width: column.width
              implicitHeight: scol.implicitHeight + Style.space(12)
              radius: Style.cornerRadius > 0 ? Style.space(8) : 0
              color: (srow.modelData.expandable && srmouse.containsMouse) ? root.hoverFill : "transparent"

              Column {
                id: scol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(1)

                Row {
                  spacing: Style.space(8)
                  Rectangle {
                    width: Style.space(8)
                    height: width
                    radius: width / 2
                    anchors.verticalCenter: parent.verticalCenter
                    color: srow.modelData.state === "ok" ? Color.accent
                         : (srow.modelData.state === "warn" ? root.warn : root.urgent)
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: srow.modelData.name
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                  }
                  Text {
                    visible: srow.modelData.expandable === true
                    textFormat: Text.PlainText
                    text: root.vpnExpanded ? "▾" : "▸"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: srow.modelData.detail
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              MouseArea {
                id: srmouse
                anchors.fill: parent
                enabled: srow.modelData.expandable === true
                hoverEnabled: true
                cursorShape: srow.modelData.expandable ? Qt.PointingHandCursor : Qt.ArrowCursor
                onClicked: if (srow.modelData.expandable) root.vpnExpanded = !root.vpnExpanded
              }
            }
          }
        }

        Column {
          width: parent.width
          spacing: Style.space(12)
          visible: root.vpnExpanded

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader { text: "СТРАНА"; foreground: root.foreground; fontFamily: root.fontFamily }

          Column {
            width: parent.width
            spacing: Style.space(4)

            Repeater {
              model: root.vpnProfiles

              Rectangle {
                id: prow
                required property var modelData
                width: column.width
                implicitHeight: pcol.implicitHeight + Style.space(12)
                radius: Style.cornerRadius > 0 ? Style.space(8) : 0
                color: prow.modelData.index === (root.vpnInfo.profile_index || 0)
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
                    text: (prow.modelData.node_count || 0) + " сервер(ов)"
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
        }

        PanelSeparator { foreground: root.foreground }

        Flow {
          width: parent.width
          spacing: Style.space(8)

          Rectangle {
            id: subBtn
            implicitWidth: subTxt.implicitWidth + Style.space(20)
            implicitHeight: subTxt.implicitHeight + Style.space(12)
            radius: Style.cornerRadius > 0 ? Style.space(8) : 0
            opacity: root.cliPath !== "" ? 1.0 : 0.4
            color: smouse.containsMouse && root.cliPath !== "" ? root.hoverFill
                   : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            Text {
              id: subTxt
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.busy === "update" ? "…" : "Обновить подписку"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: smouse
              anchors.fill: parent
              enabled: root.cliPath !== "" && root.busy === ""
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.run(["update"], "update")
            }
          }

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
              text: "Обновить"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: rmouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: if (!statusProc.running) statusProc.running = true
            }
          }

          Rectangle {
            id: checkBtn
            implicitWidth: checkTxt.implicitWidth + Style.space(20)
            implicitHeight: checkTxt.implicitHeight + Style.space(12)
            radius: Style.cornerRadius > 0 ? Style.space(8) : 0
            color: cmouse.containsMouse ? root.hoverFill
                   : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            Text {
              id: checkTxt
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.busy === "check" ? "…" : "Проверить доступность"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: cmouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (checkProc.running) return
                root.busy = "check"
                checkProc.running = true
              }
            }
          }

          Rectangle {
            id: vpnBtn
            implicitWidth: vpnTxt.implicitWidth + Style.space(20)
            implicitHeight: vpnTxt.implicitHeight + Style.space(12)
            radius: Style.cornerRadius > 0 ? Style.space(8) : 0
            opacity: root.cliPath !== "" ? 1.0 : 0.4
            color: vmouse.containsMouse && root.cliPath !== "" ? root.hoverFill
                   : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)
            border.width: 1
            border.color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.15)

            Text {
              id: vpnTxt
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.vpnOn ? "VPN: выключить" : "VPN: включить"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
            MouseArea {
              id: vmouse
              anchors.fill: parent
              enabled: root.cliPath !== ""
              hoverEnabled: true
              cursorShape: root.cliPath !== "" ? Qt.PointingHandCursor : Qt.ArrowCursor
              onClicked: root.run(["toggle"], "vpn")
            }
          }
        }
      }
    }
  }
}
