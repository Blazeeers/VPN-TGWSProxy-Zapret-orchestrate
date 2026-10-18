import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.blazeeers.omavpn"
  ipcTarget: "io.github.blazeeers.omavpn"
  manageIpc: false

  readonly property string scriptPath: Quickshell.env("HOME") + "/.local/bin/bypass-status"
  // Пиктограммы лежат рядом с Panel.qml (icons/), поэтому путь относительный —
  // и в локальной установке, и в пакете для маркетплейса.
  readonly property string iconDir: "icons"

  property bool autoTried: false

  readonly property bool autoconnect: root.setting("autoconnect", false)

  function setSetting(key, value) {
    if (!root.bar || !root.bar.shell || typeof root.bar.shell.updateEntryInline !== "function") return
    var entry = { id: root.moduleName }
    for (var k in settings) if (k !== "id") entry[k] = settings[k]
    entry[key] = value
    root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  property var bs: ({ ok: false })
  property var vpnInfo: ({})
  property var health: ({})
  property bool vpnLoaded: false
  property bool vpnExpanded: false
  property string busy: ""
  property string notice: ""
  property string refreshedAt: ""
  property string lastError: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color warn: "#ff9f0a"
  readonly property color okColor: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color cardFill: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.05)
  readonly property color chipFill: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.07)
  readonly property color hairline: Qt.rgba(foreground.r, foreground.g, foreground.b, 0.12)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: bar ? Style.hoverFillFor(bar.foreground, Color.accent) : "transparent"
  readonly property color selectedFill: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "transparent"

  readonly property var vpn: (root.bs && root.bs.vpn) ? root.bs.vpn : ({})
  readonly property var zap: (root.bs && root.bs.zapret) ? root.bs.zapret : ({})
  readonly property var tg: (root.bs && root.bs.tgwsproxy) ? root.bs.tgwsproxy : ({})
  readonly property string cliPath: (root.bs && root.bs.cli) ? root.bs.cli : ""

  readonly property bool vpnOn: !!root.vpn.running
  readonly property bool capsOk: root.vpn.caps_ok !== false
  readonly property bool zapTesting: !!root.zap.testing || root.zap.autotune === "activating"

  // ---- комплексная проверка (health.json из bypass-status --health) ---------
  readonly property var hl: (root.health && root.health.items instanceof Array)
    ? root.health : ((root.bs && root.bs.health && root.bs.health.items instanceof Array) ? root.bs.health : ({}))
  readonly property string verdict: root.hl.verdict || ""
  readonly property bool healthStale: root.hl.stale === true

  function hItem(id) {
    var it = root.hl && root.hl.items ? root.hl.items : []
    for (var i = 0; i < it.length; i++) if (it[i].id === id) return it[i]
    return null
  }
  function hState(id, fallback) {
    var it = root.hItem(id)
    return it ? it.state : (fallback || "")
  }
  function hDetail(id, fallback, emptyText) {
    var it = root.hItem(id)
    if (it) return it.detail
    return fallback || emptyText || "нет данных — нажми «Проверить всё»"
  }
  function stateColor(state) {
    if (state === "ok") return root.okColor
    if (state === "warn") return root.warn
    if (state === "bad") return root.urgent
    return root.dim
  }
  function stateWord(state) {
    if (state === "ok") return "ок"
    if (state === "warn") return "внимание"
    if (state === "bad") return "сбой"
    if (state === "idle") return "выкл"
    return ""
  }

  // ---- тест серверов / подбор региона --------------------------------------
  readonly property var vt: (root.bs && root.bs.vpn_test) ? root.bs.vpn_test : ({})
  readonly property var vtResults: (root.vt.results instanceof Array) ? root.vt.results : []
  readonly property bool vtRunning: root.vt.running === true
  readonly property bool vtIsBest: root.vt.mode === "best"
  readonly property int vtDone: Number(root.vt.nodes_done) || 0
  readonly property int vtTotal: Number(root.vt.nodes_total) || 0
  readonly property int vtProfilesDone: Number(root.vt.profiles_done) || 0
  readonly property int vtProfilesTotal: Number(root.vt.profiles_total) || 0
  readonly property var vtBest: (root.vt.best && root.vt.best.index !== undefined) ? root.vt.best : null
  readonly property bool vtHasData: root.vtResults.length > 0 || root.vtRunning
  readonly property real vtProgress: root.vtTotal > 0 ? Math.min(1, root.vtDone / root.vtTotal) : 0

  readonly property string vtSummary: {
    if (root.vtRunning) {
      var s = root.vt.phase === "confirm" ? "подтверждаю лучший сервер"
            : ("быстрый проход " + root.vtDone + "/" + root.vtTotal)
      if (root.vt.current) s += " · " + root.vt.current
      return s
    }
    if (root.vt.error) return "подбор прервался: " + root.vt.error
    if (!root.vtHasData) return ""
    var alive = 0
    for (var i = 0; i < root.vtResults.length; i++) if (!root.vtResults[i].dead) alive++
    var t = ""
    if (root.vtBest) t = "лучший: " + (root.vtBest.profile_name || "?") + " · #" + root.vtBest.index + " " + root.vtBest.tag
    else t = "живых серверов " + alive
    if (root.vt.applied) t += " · применён"
    return t
  }
  readonly property string vtWhen: {
    var t = Number(root.vt.finished || root.vt.updated || 0)
    return t > 0 ? Qt.formatTime(new Date(t * 1000), "HH:mm") : ""
  }

  function vtNodeDetail(r) {
    if (!r) return ""
    if (r.dead) return r.note ? ("нет ответа · " + r.note) : "нет ответа через сервер"
    var s = "med " + r.med + " с · p90 " + r.p90 + " с · потери " + (r.loss || 0) + "/" + (r.probes || 0)
    if (r.tls_med) s += " · TLS " + r.tls_med + " с"
    return s
  }

  // Серверы текущего региона: полный список из подписки + результаты проб, если есть.
  readonly property var nodesOfProfile: {
    var pi = Number(root.vpnInfo.profile_index === undefined ? 0 : root.vpnInfo.profile_index)
    var list = (root.vpnInfo && root.vpnInfo.nodes instanceof Array) ? root.vpnInfo.nodes : []
    var byIdx = {}
    for (var i = 0; i < root.vtResults.length; i++) {
      var r = root.vtResults[i]
      var rp = Number(r.profile === undefined ? pi : r.profile)
      if (rp === pi) byIdx[Number(r.index)] = r
    }
    var out = []
    for (var j = 0; j < list.length; j++) {
      var n = list[j]
      var res = byIdx[Number(n.index)]
      out.push({
        index: Number(n.index),
        tag: n.tag,
        detail: n.detail,
        ping_ms: n.ping_ms,
        tested: res !== undefined,
        dead: res ? !!res.dead : false,
        loss: res ? Number(res.loss) : 0,
        med: res ? res.med : null,
        note: res ? res.note : ""
      })
    }
    return out
  }

  // ---- общее состояние -----------------------------------------------------
  readonly property string healthIcon:
    root.verdict === "bad" ? "warning"
    : root.verdict === "warn" ? "warning"
    : (root.vtRunning || root.zapTesting) ? "refresh"
    : root.verdict === "ok" ? "check"
    : "vpn"
  readonly property color healthColor:
    root.verdict === "bad" ? root.urgent
    : root.verdict === "warn" ? root.warn
    : (root.vtRunning || root.zapTesting) ? root.warn
    : root.verdict === "ok" ? root.okColor
    : (root.vpnOn ? root.okColor : root.dim)
  // Короткая подпись для шапки панели (PanelHero пишет её капсом).
  readonly property string heroMeta: {
    if (root.vtRunning) return "подбор серверов"
    if (root.zapTesting) return "подбор стратегии zapret"
    if (!root.hl.checked) return root.vpnOn ? "VPN включён · проверки ещё не было" : "VPN выключен"
    if (root.verdict === "bad") {
      var bad = []
      for (var i = 0; i < root.hl.items.length; i++)
        if (root.hl.items[i].state === "bad") bad.push(root.hl.items[i].name)
      return "не работает: " + bad.join(", ")
    }
    if (root.verdict === "warn") {
      var warn = []
      for (var j = 0; j < root.hl.items.length; j++)
        if (root.hl.items[j].state === "warn") warn.push(root.hl.items[j].name)
      return "замечания: " + warn.join(", ")
    }
    return (root.vpnOn ? "VPN включён · " : "") + "всё работает"
  }

  readonly property string healthText: {
    if (root.vtRunning) return "идёт подбор серверов"
    if (root.zapTesting) return "идёт подбор стратегии zapret"
    if (!root.hl.checked) return root.vpnOn ? "VPN подключён, проверка не запускалась" : "VPN выключен"
    return root.hl.summary || ""
  }

  readonly property var vpnProfiles: (root.vpnInfo && root.vpnInfo.profiles instanceof Array) ? root.vpnInfo.profiles : []

  function fmtUptime(s) {
    s = Math.max(0, Number(s) || 0)
    var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), sec = Math.floor(s % 60)
    function pad(x) { return (x < 10 ? "0" : "") + x }
    return (h > 0 ? h + ":" + pad(m) : pad(m)) + ":" + pad(sec)
  }
  function fmtAge(sec) {
    sec = Math.max(0, Number(sec) || 0)
    if (sec < 60) return sec + " с назад"
    if (sec < 3600) return Math.round(sec / 60) + " мин назад"
    return Math.round(sec / 3600) + " ч назад"
  }
  function markRefreshed() { root.refreshedAt = Qt.formatTime(new Date(), "HH:mm:ss") }

  readonly property string vpnDetail: {
    var v = root.vpn
    if (!v.running) {
      if (v.installed === false) return "не установлен"
      return "выключен · " + ((v.profile || "профиль не выбран"))
        + ((v.node && v.node !== "auto") ? " · " + v.node : "")
    }
    return (v.profile || "") + " · " + (v.mode === "tun" ? "TUN" : "SOCKS")
      + " · " + ((v.node && v.node !== "auto") ? v.node : "авто")
      + " · " + root.fmtUptime(v.uptime)
  }

  // ---- действия ------------------------------------------------------------
  function run(args, label) {
    if (actionProc.running || root.cliPath === "") return
    root.busy = label || "…"
    actionProc.command = [root.cliPath, "--json"].concat(args)
    actionProc.running = true
  }

  function startHealth() {
    if (healthProc.running) return
    root.busy = "health"
    healthProc.running = true
  }

  onBsChanged: {
    var v = root.vpn
    if (!root.autoTried && root.autoconnect && v && v.installed !== false && !v.running
        && root.cliPath !== "") {
      root.autoTried = true
      root.run(["on"], "auto")
    }
  }

  onOpenedChanged: if (opened) {
    if (!statusProc.running) statusProc.running = true
    if (!vpnProc.running && (!root.vpnLoaded || (Date.now() / 1000 - (root.vpnInfo.updated || 0)) > 120))
      vpnProc.running = true
    if (!root.hl.checked || root.hl.age > 600) root.startHealth()
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function health(): string { root.startHealth(); return "ok" }
  }

  // ---- пиктограмма из сгенерированных иконок -------------------------------
  component Pictogram: Item {
    id: pic

    property string name: "vpn"
    property color tint: root.foreground
    property int px: Style.space(18)

    implicitWidth: px
    implicitHeight: px

    Image {
      id: picImg
      anchors.fill: parent
      source: root.iconDir + "/" + pic.name + ".png"
      sourceSize.width: Math.round(pic.px * 2)
      sourceSize.height: Math.round(pic.px * 2)
      fillMode: Image.PreserveAspectFit
      smooth: true
      visible: false
      layer.enabled: true
    }
    MultiEffect {
      anchors.fill: picImg
      source: picImg
      colorization: 1.0
      colorizationColor: pic.tint
    }
  }

  // ---- процесс опроса статуса ---------------------------------------------
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
    id: vpnProc
    command: [root.scriptPath, "--vpn"]
    stdout: StdioCollector { id: vpnOut; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) return
      try {
        var d = JSON.parse(vpnOut.text)
        if (d && d.ok) { root.vpnInfo = d; root.vpnLoaded = true }
      } catch (e) { /* ignore */ }
    }
  }

  // Комплексный тест конфигурации: страница/видео YouTube, Discord, DeepSeek,
  // Telegram, tg-ws-proxy, zapret и реальный выход VPN. Раз в 5 минут.
  Process {
    id: healthProc
    command: [root.scriptPath, "--health"]
    stdout: StdioCollector { id: healthOut; waitForEnd: true }
    onExited: function(code) {
      root.busy = ""
      root.markRefreshed()
      try {
        var d = JSON.parse(healthOut.text)
        if (d && d.items) {
          root.health = d
          var h = d.heal || {}
          if (h && h.actions && h.actions.length > 0) {
            root.notice = "VPN: " + h.actions.join("; ")
            noticeTimer.restart()
          }
        }
      } catch (e) { root.lastError = "нет ответа от проверки" }
      if (!statusProc.running) statusProc.running = true
    }
  }

  Process {
    id: rescanProc
    command: [root.scriptPath, "--rescan-request"]
    stdout: StdioCollector { id: rescanOut; waitForEnd: true }
    onExited: function(code) {
      root.busy = ""
      var msg = "не удалось запросить перебор"
      if (code === 0) {
        msg = "перебор запрошен — стратегии тестируются"
        try {
          var d = JSON.parse(rescanOut.text)
          if (d && d.message) msg = d.message
        } catch (e) { /* ignore */ }
      }
      root.notice = msg
      noticeTimer.restart()
      if (!statusProc.running) statusProc.running = true
    }
  }

  // «Подобрать лучший»: тест всех регионов и серверов, применение победителя.
  Process {
    id: optimizeProc
    command: [root.scriptPath, "--optimize"]
    stdout: StdioCollector { id: optimizeOut; waitForEnd: true }
    onExited: function(code) {
      root.busy = ""
      var msg = "не удалось запустить подбор"
      try {
        var d = JSON.parse(optimizeOut.text)
        if (d && d.message) msg = d.message
        else if (d && d.error) msg = d.error
      } catch (e) { /* ignore */ }
      root.notice = msg
      noticeTimer.restart()
      if (!statusProc.running) statusProc.running = true
    }
  }

  Process {
    id: updProc
    command: [root.scriptPath, "--update-components"]
    stdout: StdioCollector { id: updOut; waitForEnd: true }
    onExited: function(code) {
      root.busy = ""
      var msg = "не удалось обновить"
      try {
        var d = JSON.parse(updOut.text)
        if (d && d.messages && d.messages.length) msg = d.messages.join("; ")
      } catch (e) { /* ignore */ }
      root.notice = msg
      noticeTimer.restart()
      if (!statusProc.running) statusProc.running = true
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(code) {
      var wasVpn = root.busy === "vpn"
      root.busy = ""
      root.markRefreshed()
      if (code !== 0) {
        var t = (actionErr.text || actionOut.text || "").trim()
        try { var j = JSON.parse(t); if (j.error) t = j.error } catch (e) { /* plain */ }
        root.lastError = t || "ошибка"
      } else { root.lastError = "" }
      if (!statusProc.running) statusProc.running = true
      if (!vpnProc.running) vpnProc.running = true
      if (wasVpn) root.startHealth()
    }
  }

  Timer {
    id: noticeTimer
    interval: 9000
    onTriggered: root.notice = ""
  }

  // Быстрый опрос статуса — для живого состояния строк.
  Timer {
    interval: 4000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: if (!statusProc.running) statusProc.running = true
  }

  // Монитор работоспособности: комплексная проверка каждые 5 минут.
  Timer {
    interval: 300000
    running: true
    repeat: true
    onTriggered: root.startHealth()
  }

  // ---- кнопка в панели -----------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: true
    activeColor: root.healthColor
    tooltipText: "Обходы: " + root.healthText
    iconComponent: Component {
      Pictogram {
        name: root.healthIcon
        tint: root.healthColor
        px: Style.space(15)
      }
    }
    onPressed: function(buttonCode) { root.toggle() }
  }

  // ---- всплывающая панель --------------------------------------------------
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

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
        spacing: Style.space(10)

        PanelHero {
          width: parent.width
          title: "Обходы"
          meta: root.heroMeta
          foreground: root.foreground
          fontFamily: root.fontFamily

          iconComponent: Component {
            Pictogram {
              name: root.healthIcon
              tint: root.healthColor
              px: Style.font.display * 1.1
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

        // ---------- карточка VPN ----------
        Rectangle {
          width: parent.width
          radius: Style.cornerRadius > 0 ? Style.space(12) : 0
          color: root.cardFill
          border.width: 1
          border.color: root.hairline
          implicitHeight: vpnCard.implicitHeight + Style.space(24)

          Column {
            id: vpnCard
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(10)

            Row {
              width: parent.width
              spacing: Style.space(10)

              Pictogram {
                name: "vpn"
                tint: root.vpnOn ? root.stateColor(root.hState("vpn", "ok")) : root.dim
                px: Style.space(22)
                anchors.verticalCenter: parent.verticalCenter
              }

              Column {
                width: parent.width - Style.space(22) - toggleBtn.width - Style.space(30)
                spacing: Style.space(1)

                Row {
                  spacing: Style.space(8)
                  Text {
                    textFormat: Text.PlainText
                    text: "VPN"
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.subtitle
                    font.bold: true
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: root.vpnOn ? (root.stateWord(root.hState("vpn", "")) || "") : "выкл"
                    color: root.vpnOn ? root.stateColor(root.hState("vpn", "ok")) : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.vpnDetail
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Button {
                id: toggleBtn
                anchors.verticalCenter: parent.verticalCenter
                text: root.busy === "vpn" ? "…" : (root.vpnOn ? "Выключить" : "Включить")
                bordered: true
                foreground: root.foreground
                accent: root.vpnOn ? root.okColor : Color.accent
                fontFamily: root.fontFamily
                fontSize: Style.font.bodySmall
                enabled: root.cliPath !== "" && root.busy === ""
                onClicked: root.run(["toggle"], "vpn")
              }
            }

            // предупреждение о правах: включать/выключать VPN пароль не нужен
            Text {
              width: parent.width
              visible: !root.capsOk && root.vpn.installed !== false
              textFormat: Text.PlainText
              text: "Нет cap_net_admin у sing-box — TUN попросит пароль. Один раз: sudo setcap cap_net_admin,cap_net_raw+ep ~/.local/share/omavpn/bin/sing-box"
              color: root.warn
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // прогресс подбора
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: root.vtRunning

              Rectangle {
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                Rectangle {
                  width: parent.width * root.vtProgress
                  height: parent.height
                  radius: height / 2
                  color: Color.accent
                }
              }
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: root.vtSummary
                color: root.warn
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
              }
            }

            // строка-переключатель регионов/серверов
            Rectangle {
              width: parent.width
              implicitHeight: expandRow.implicitHeight + Style.space(8)
              radius: Style.cornerRadius > 0 ? Style.space(8) : 0
              color: expandMouse.containsMouse ? root.hoverFill : "transparent"

              Row {
                id: expandRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(6)
                anchors.rightMargin: Style.space(6)
                spacing: Style.space(8)

                Pictogram {
                  name: "region"
                  tint: root.dim
                  px: Style.space(15)
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  textFormat: Text.PlainText
                  text: "Регионы и серверы"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.vtBest ? ("★ " + (root.vtBest.profile_name || "") + " · " + root.vtBest.tag) : ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                  width: parent.width - Style.space(150)
                  visible: text !== ""
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.vpnExpanded ? "▾" : "▸"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }
              }

              MouseArea {
                id: expandMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.vpnExpanded = !root.vpnExpanded
              }
            }

            // ---------- развёрнутый список ----------
            Column {
              width: parent.width
              spacing: Style.space(8)
              visible: root.vpnExpanded

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "РЕГИОНЫ"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 0.8
              }

              Column {
                width: parent.width
                spacing: Style.space(2)

                Repeater {
                  model: root.vpnProfiles

                  Rectangle {
                    id: prow
                    required property var modelData
                    readonly property bool isBest: root.vtBest !== null
                      && Number(root.vtBest.profile_index) === Number(modelData.index)
                    width: parent.width
                    implicitHeight: pcol.implicitHeight + Style.space(8)
                    radius: Style.cornerRadius > 0 ? Style.space(8) : 0
                    color: Number(prow.modelData.index) === Number(root.vpnInfo.profile_index || 0)
                             ? root.selectedFill
                             : (pmouse.containsMouse ? root.hoverFill : "transparent")

                    Row {
                      id: pcol
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(8)
                      spacing: Style.space(8)

                      Text {
                        textFormat: Text.PlainText
                        text: prow.modelData.name
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        width: parent.width - Style.space(120)
                        elide: Text.ElideRight
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: (prow.modelData.node_count || 0) + " серв."
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                      Text {
                        visible: prow.isBest
                        textFormat: Text.PlainText
                        text: "★ лучший"
                        color: Color.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                      Text {
                        visible: Number(prow.modelData.index) === Number(root.vpnInfo.profile_index || 0)
                        textFormat: Text.PlainText
                        text: "●"
                        color: Color.accent
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                    }

                    MouseArea {
                      id: pmouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: if (root.busy === "") root.run(["profile", String(prow.modelData.index)], "profile")
                    }
                  }
                }
              }

              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "СЕРВЕРЫ РЕГИОНА · " + (root.vtHasData
                  ? (root.vtRunning ? "тест идёт" : "тест " + (root.vtWhen || ""))
                  : "тест не запускался")
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 0.8
                topPadding: Style.space(4)
              }

              Column {
                width: parent.width
                spacing: Style.space(2)

                Repeater {
                  model: root.nodesOfProfile

                  Rectangle {
                    id: trow
                    required property var modelData
                    readonly property int nodeIdx: Number(modelData.index)
                    readonly property bool isBest: root.vtBest !== null && Number(root.vtBest.index) === nodeIdx
                    readonly property bool isCurrent: Number(root.vpnInfo.node_index) === nodeIdx
                    width: parent.width
                    implicitHeight: tcol.implicitHeight + Style.space(8)
                    radius: Style.cornerRadius > 0 ? Style.space(8) : 0
                    color: trow.isCurrent ? root.selectedFill : (tmouse.containsMouse ? root.hoverFill : "transparent")

                    Row {
                      id: tcol
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(8)
                      spacing: Style.space(8)

                      Rectangle {
                        width: Style.space(7)
                        height: width
                        radius: width / 2
                        anchors.verticalCenter: parent.verticalCenter
                        color: !trow.modelData.tested ? root.dim
                             : (trow.modelData.dead ? root.urgent
                                : (Number(trow.modelData.loss) > 0 ? root.warn : root.okColor))
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: trow.modelData.tag + (trow.isBest ? " ★" : "") + (trow.isCurrent ? " ●" : "")
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.bodySmall
                        width: Style.space(120)
                        elide: Text.ElideRight
                      }
                      Text {
                        textFormat: Text.PlainText
                        text: !trow.modelData.tested
                              ? ("не тестировался" + (trow.modelData.ping_ms ? " · TCP " + trow.modelData.ping_ms + " мс" : ""))
                              : (trow.modelData.dead
                                 ? "нет ответа" + (trow.modelData.note ? " · " + trow.modelData.note : "")
                                 : ("med " + trow.modelData.med + " с · потери " + (trow.modelData.loss || 0)))
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                        width: parent.width - Style.space(180)
                      }
                    }

                    MouseArea {
                      id: tmouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: if (root.busy === "") root.run(["node", String(trow.nodeIdx)], "node")
                    }
                  }
                }
              }

              Text {
                width: parent.width
                visible: !root.vtHasData
                textFormat: Text.PlainText
                text: "Нажми «Подобрать лучший» — прогоню все регионы и серверы и подключу оптимальный."
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }

        // ---------- строки состояния ----------
        Column {
          width: parent.width
          spacing: Style.space(2)

          // zapret
          Rectangle {
            width: parent.width
            implicitHeight: zrow.implicitHeight + Style.space(14)
            radius: Style.cornerRadius > 0 ? Style.space(10) : 0
            color: "transparent"

            Row {
              id: zrow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)

              Pictogram {
                name: "zapret"
                tint: root.zapTesting ? root.warn : root.stateColor(root.hState("zapret", "ok"))
                px: Style.space(18)
                anchors.verticalCenter: parent.verticalCenter
              }
              Column {
                width: parent.width - Style.space(120)
                spacing: Style.space(1)
                Text {
                  textFormat: Text.PlainText
                  text: "zapret · обход DPI"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.zapTesting ? "идёт подбор стратегии…" : root.hDetail("zapret", "", "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              Text {
                textFormat: Text.PlainText
                text: root.zapTesting ? "…" : root.stateWord(root.hState("zapret", ""))
                color: root.zapTesting ? root.warn : root.stateColor(root.hState("zapret", ""))
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // YouTube / Discord / DeepSeek / tg-ws-proxy
          Repeater {
            model: [
              { id: "youtube", icon: "youtube", title: "YouTube", hint: "видео и страница" },
              { id: "discord", icon: "discord", title: "Discord", hint: "страница и шлюз" },
              { id: "deepseek", icon: "ai", title: "DeepSeek API", hint: "нужен ассистенту" },
              { id: "tgwsproxy", icon: "telegram", title: "tg-ws-proxy", hint: "локальный прокси Telegram" }
            ]

            Rectangle {
              id: srow
              required property var modelData
              readonly property string st: root.hState(srow.modelData.id, "")
              width: parent.width
              implicitHeight: sr.implicitHeight + Style.space(14)
              radius: Style.cornerRadius > 0 ? Style.space(10) : 0
              color: "transparent"

              Row {
                id: sr
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(10)

                Pictogram {
                  name: srow.modelData.icon
                  tint: root.stateColor(srow.st)
                  px: Style.space(18)
                  anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                  width: parent.width - Style.space(120)
                  spacing: Style.space(1)
                  Text {
                    textFormat: Text.PlainText
                    text: srow.modelData.title
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width
                    textFormat: Text.PlainText
                    text: root.hDetail(srow.modelData.id, "", srow.modelData.hint + " · нет данных")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }
                Text {
                  textFormat: Text.PlainText
                  text: root.stateWord(srow.st)
                  color: root.stateColor(srow.st)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // обновления компонентов
          Rectangle {
            id: updRow
            readonly property var u: root.bs ? root.bs.updates : null
            readonly property bool has: !!(u && ((u.zapret && u.zapret.update) || (u.tgwsproxy && u.tgwsproxy.update)))
            visible: has
            width: parent.width
            implicitHeight: ur.implicitHeight + Style.space(14)
            radius: Style.cornerRadius > 0 ? Style.space(10) : 0
            color: umouse.containsMouse ? root.hoverFill : "transparent"

            Row {
              id: ur
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(10)

              Pictogram {
                name: "update"
                tint: root.warn
                px: Style.space(18)
                anchors.verticalCenter: parent.verticalCenter
              }
              Column {
                width: parent.width - Style.space(120)
                spacing: Style.space(1)
                Text {
                  textFormat: Text.PlainText
                  text: "Обновления"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                Text {
                  width: parent.width
                  textFormat: Text.PlainText
                  text: root.busy === "upd" ? "обновляю…" : "есть новые версии — нажми, чтобы обновить"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              Text {
                textFormat: Text.PlainText
                text: "обновить"
                color: root.warn
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }

            MouseArea {
              id: umouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (root.busy !== "") return
                root.busy = "upd"
                updProc.running = true
              }
            }
          }
        }

        // ---------- настройка ----------
        Rectangle {
          id: autoRowBox
          width: parent.width
          implicitHeight: autoRow.implicitHeight + Style.space(12)
          radius: Style.cornerRadius > 0 ? Style.space(10) : 0
          color: autoMouse.containsMouse ? root.hoverFill : "transparent"

          Row {
            id: autoRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(10)

            Pictogram {
              name: "vpn"
              tint: root.autoconnect ? Color.accent : root.dim
              px: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
              text: "Подключаться при входе"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              width: parent.width - Style.space(90)
            }
            Text {
              textFormat: Text.PlainText
              text: root.autoconnect ? "вкл" : "выкл"
              color: root.autoconnect ? Color.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: autoMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setSetting("autoconnect", !root.autoconnect)
          }
        }

        // ---------- действия ----------
        PanelSeparator { foreground: root.foreground }

        Flow {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: root.busy === "health" ? "… проверяю" : "Проверить всё"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            enabled: root.busy === ""
            onClicked: root.startHealth()
          }

          Button {
            text: root.vtRunning ? ("подбор " + root.vtDone + "/" + root.vtTotal) : "Подобрать лучший"
            bordered: true
            foreground: root.foreground
            accent: Color.accent
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            enabled: root.cliPath !== "" && root.busy === "" && !root.vtRunning
            onClicked: {
              if (root.vtRunning || optimizeProc.running) return
              root.busy = "vtest"
              root.vpnExpanded = true
              optimizeProc.running = true
            }
          }

          Button {
            text: root.busy === "rescan" ? "…" : "Тест стратегий"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            enabled: root.busy === ""
            onClicked: {
              if (root.busy !== "" || rescanProc.running) return
              root.busy = "rescan"
              rescanProc.running = true
            }
          }

          Button {
            text: root.busy === "update" ? "…" : "Обновить подписку"
            bordered: true
            foreground: root.foreground
            fontFamily: root.fontFamily
            fontSize: Style.font.bodySmall
            enabled: root.cliPath !== "" && root.busy === ""
            onClicked: root.run(["update"], "update")
          }
        }

        Text {
          width: parent.width
          visible: root.notice !== ""
          textFormat: Text.PlainText
          text: root.notice
          color: root.warn
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Row {
          width: parent.width
          spacing: Style.space(6)

          Text {
            textFormat: Text.PlainText
            text: root.hl.checked
              ? ("проверено " + Qt.formatTime(new Date(root.hl.checked * 1000), "HH:mm")
                 + (root.hl.secs ? " · " + root.hl.secs + " с" : "")
                 + (root.healthStale ? " · устарело" : ""))
              : "проверка не запускалась"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
          Text {
            textFormat: Text.PlainText
            visible: root.hItem("telegram") !== null
            text: "· Telegram API: " + (root.hItem("telegram") ? root.hDetail("telegram", "", "") : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
            width: parent.width * 0.5
          }
        }
      }
    }
  }
}
