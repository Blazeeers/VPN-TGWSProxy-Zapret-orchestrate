import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  // Канонический id плагина — тот же, что в манифесте и в каталоге установки
  // (~/.config/omarchy/plugins/io.github.blazeeers.omavpn).
  moduleName: "io.github.blazeeers.omavpn"
  // IPC-цель обязана совпадать с moduleName. Раньше здесь был захардкожен id
  // «соседнего» плагина — отсюда двойные «Обходы» в баре и путаница команд.
  ipcTarget: root.moduleName
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

  // Два независимых флага. busy — действие пользователя (только он гасит
  // кнопки), healthRunning — фоновая проверка: панель при ней остаётся живой,
  // иначе открытая панель «умирала» ровно тогда, когда её открыли починить.
  property string busy: ""
  property string healthRunning: ""

  property string notice: ""
  property string lastError: ""
  // Время последнего УДАЧНОГО снимка --json. Нужен, чтобы честно писать
  // «данные от HH:MM» и помечать залипшие значения, а не делать вид, что они свежие.
  property real statusAt: 0
  property real healthStartedAt: 0
  // Кто именно не ответил (для понятного сообщения вместо «ошибка»).
  property string timeoutHit: ""
  // Тик раз в секунду только для надписей («проверяю… N с», возраст данных).
  property real nowSec: Date.now() / 1000

  // Подтверждение разрушительных действий.
  property string confirmKind: ""
  property string confirmMessage: ""

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

  // Разделы, которые бэкенд не смог собрать (битый файл, исключение). Вместо
  // «всё хорошо» показываем это отдельной строкой.
  readonly property var degraded: (root.bs && root.bs.degraded instanceof Array) ? root.bs.degraded : []
  readonly property string degradedText: {
    var names = []
    for (var i = 0; i < root.degraded.length; i++)
      if (root.degraded[i] !== "route_audit") names.push(root.degraded[i])
    return names.length > 0 ? "часть данных недоступна: " + names.join(", ") : ""
  }
  readonly property bool raDegraded: root.degraded.indexOf("route_audit") >= 0

  readonly property bool statusStale: root.statusAt > 0 && (root.nowSec - root.statusAt) > 60
  readonly property string statusStamp: root.statusAt > 0
    ? Qt.formatTime(new Date(root.statusAt * 1000), "HH:mm") : ""

  // ---- комплексная проверка (health.json из bypass-status --health) ---------
  readonly property var hl: (root.health && root.health.items instanceof Array)
    ? root.health : ((root.bs && root.bs.health && root.bs.health.items instanceof Array) ? root.bs.health : ({}))
  readonly property string verdict: root.hl.verdict || ""
  readonly property bool healthStale: root.hl.stale === true
  // VPN выключен намеренно: плохой YouTube/Discord — не поломка.
  readonly property bool vpnIdle: root.hl.vpn_idle === true
  readonly property bool healthBusy: root.healthRunning !== ""
  readonly property int healthElapsed: root.healthRunning === ""
    ? 0 : Math.max(0, Math.floor(root.nowSec - root.healthStartedAt))

  // ---- аудит маршрутов (route-audit.json из bypass-status --route-audit) ----
  readonly property var ra: (root.bs && root.bs.route_audit) ? root.bs.route_audit : ({})
  readonly property var raProbes: (root.ra.probes instanceof Array) ? root.ra.probes : []
  readonly property int raCount: Number(root.ra.count) || root.raProbes.length
  // Только fixed: в actions теперь попадают и откаты (rollback), и длину
  // actions нельзя выдавать за «исправлено» — виджет врал «исправлено: 1»
  // после отката.
  readonly property int raFixed: Number(root.ra.fixed) || 0
  // Аудит считается невыполненным, если бэкенд так и сказал (verdict=error),
  // если проб нет вовсе (нечего проверять) или если раздел не собрался.
  // Раньше пустой список проб давал зелёное «маршруты в порядке» — ложь.
  readonly property bool raFailed: {
    if (root.raDegraded) return true
    if (String(root.ra.verdict || "") === "error") return true
    if (root.raProbes.length === 0 && root.ra.ok === false) return true
    if (String(root.ra.verdict || "") === "bad" && root.raProbes.length === 0) return true
    return false
  }
  readonly property bool raHas: !root.raFailed
    && (Number(root.ra.checked || 0) > 0 || root.raProbes.length > 0)
  readonly property var raBroken: {
    var bad = []
    for (var i = 0; i < root.raProbes.length; i++)
      if (!root.raProbes[i].after) bad.push(root.raProbes[i].domain)
    return bad
  }
  readonly property string raText: {
    if (root.raFailed) {
      var why = String(root.ra.summary || root.ra.error || "")
      if (why === "" && root.raDegraded) why = "раздел route_audit не собрался"
      return "маршруты: аудит не выполнился" + (why !== "" ? " — " + why : "")
    }
    if (!root.raHas) return ""
    if (root.raFixed > 0)
      return "маршруты: проверено " + root.raCount + ", исправлено " + root.raFixed
    if (root.raBroken.length > 0) return "маршруты: не отвечают " + root.raBroken.join(", ")
    return "маршруты в порядке"
  }
  readonly property string raLineText: {
    if (root.raText === "") return ""
    var t = root.raText
    if (root.ra.checked) t += " · " + root.fmtAge(root.ra.age || 0)
    if (root.ra.stale === true) t += " · устарело"
    return t
  }
  readonly property color raColor: root.raFailed ? root.urgent
    : (root.raFixed > 0 ? root.warn
      : (root.raBroken.length > 0 ? root.urgent : root.okColor))

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
  // Итог подбора отдельной строкой: раньше он жил внутри блока, видимого лишь
  // во время запуска, и после завершения (вместе с ошибкой) просто исчезал.
  readonly property string vtResultText: {
    if (root.vtRunning) return ""
    if (root.vt.error) return "подбор не удался: " + root.vt.error
    if (!root.vtHasData) return ""
    var t = ""
    if (root.vtBest) {
      t = "лучший " + (root.vtBest.profile_name || "?") + " · #" + root.vtBest.index + " " + root.vtBest.tag
    } else {
      var alive = 0
      for (var i = 0; i < root.vtResults.length; i++) if (!root.vtResults[i].dead) alive++
      t = "живых серверов " + alive
    }
    t += root.vt.applied ? " · применён" : " · не применён"
    if (root.vtWhen !== "") t += " · " + root.vtWhen
    return "подбор: " + t
  }
  readonly property color vtResultColor: root.vt.error ? root.urgent
    : (root.vt.applied ? root.okColor : root.dim)
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
    : (root.vtRunning || root.zapTesting || root.healthBusy) ? "refresh"
    : root.verdict === "ok" ? "check"
    : "vpn"
  readonly property color healthColor:
    root.verdict === "bad" ? root.urgent
    : root.verdict === "warn" ? root.warn
    : (root.vtRunning || root.zapTesting || root.healthBusy) ? root.warn
    : root.verdict === "ok" ? root.okColor
    : (root.vpnOn ? root.okColor : root.dim)

  // Одна строка «что сломано и что нажать» — вместо перечисления имён.
  readonly property string advice: {
    if (!root.hl.checked || root.healthBusy) return ""
    var names = {
      vpn: "VPN не работает", youtube: "YouTube не грузит видео",
      discord: "Discord не открывается", deepseek: "DeepSeek API недоступен",
      tgwsproxy: "tg-ws-proxy молчит", telegram: "Telegram API молчит",
      zapret: "zapret не обходит DPI"
    }
    var actions = {
      vpn: "«Проверить всё»", youtube: "«Проверить маршруты»",
      discord: "«Проверить маршруты»", deepseek: "«Проверить всё»",
      tgwsproxy: "«Проверить всё»", telegram: "«Проверить всё»",
      zapret: "«Тест стратегий»"
    }
    var items = root.hl.items || []
    var firstBad = "", firstWarn = ""
    for (var i = 0; i < items.length; i++) {
      if (items[i].state === "bad" && firstBad === "") firstBad = items[i].id
      else if (items[i].state === "warn" && firstWarn === "") firstWarn = items[i].id
    }
    var id = firstBad !== "" ? firstBad : firstWarn
    if (id === "") return ""
    if (root.vpnIdle && (id === "youtube" || id === "discord")) return "VPN выключен → включи VPN"
    var what = names[id] || id
    var act = actions[id] || ""
    return act !== "" ? (what + " → " + act) : what
  }

  // Короткая подпись для шапки панели (PanelHero пишет её капсом).
  readonly property string heroMeta: {
    if (root.vtRunning) return "подбор серверов"
    if (root.zapTesting) return "подбор стратегии zapret"
    if (root.healthBusy) return "идёт проверка"
    if (!root.hl.checked) return root.vpnOn ? "VPN включён · проверки ещё не было" : "VPN выключен"
    // Считаем по состояниям пунктов, а не по полю verdict: старый кэш
    // health.json мог не иметь verdict, и шапка врала «всё работает».
    var items = root.hl.items || []
    var firstBad = "", firstWarn = ""
    for (var i = 0; i < items.length; i++) {
      if (items[i].state === "bad" && firstBad === "") firstBad = items[i].name
      else if (items[i].state === "warn" && firstWarn === "") firstWarn = items[i].name
    }
    if (firstBad !== "") return "не работает: " + firstBad
    if (firstWarn !== "") return "замечания: " + firstWarn
    if (root.verdict === "bad") return "не работает: проверка сорвалась"
    return (root.vpnOn ? "VPN включён · " : "") + "всё работает"
  }

  readonly property string healthText: {
    if (root.healthBusy) return "идёт проверка · " + root.healthElapsed + " с"
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
  function refreshStatus() {
    if (!statusProc.running) statusProc.running = true
  }
  function refreshVpn() {
    if (!vpnProc.running) vpnProc.running = true
  }

  function run(args, label) {
    if (actionProc.running || root.cliPath === "" || root.busy !== "") return
    root.busy = label || "…"
    actionProc.command = [root.cliPath, "--json"].concat(args)
    actionProc.running = true
  }

  // heal=false — только чтение (--health-json). Лечение VPN запускается
  // единственным явным действием — кнопкой «Проверить всё».
  function startHealth(heal) {
    if (healthProc.running) return
    root.healthRunning = heal ? "heal" : "quick"
    root.healthStartedAt = Date.now() / 1000
    healthProc.command = [root.scriptPath, heal ? "--health" : "--health-json"]
    healthProc.running = true
  }

  // Сторож: Process без таймаута при зависании оставлял флаг занятым навсегда.
  function killProc(which) {
    root.timeoutHit = which
    if (which === "status") statusProc.running = false
    else if (which === "vpn") vpnProc.running = false
    else if (which === "health") healthProc.running = false
    else if (which === "audit") auditProc.running = false
    else if (which === "optimize") optimizeProc.running = false
    else if (which === "rescan") rescanProc.running = false
    else if (which === "upd") updProc.running = false
    else if (which === "action") actionProc.running = false
  }

  function notify(title, body) {
    // Долгие операции идут минутами — человек успевает отойти от экрана.
    notifyProc.command = ["notify-send", "-a", "Обходы", title, body || ""]
    notifyProc.running = true
  }

  function askConfirm(kind, message) {
    root.confirmKind = kind
    root.confirmMessage = message
    confirmDlg.opened = true
  }
  function cancelConfirm() {
    root.confirmKind = ""
    confirmDlg.opened = false
  }
  function confirmRun() {
    var kind = root.confirmKind
    root.cancelConfirm()
    if (kind === "audit") {
      if (auditProc.running || root.busy !== "") return
      root.busy = "audit"
      auditProc.running = true
    } else if (kind === "update") {
      root.run(["update"], "update")
    } else if (kind === "upd") {
      if (updProc.running || root.busy !== "") return
      root.busy = "upd"
      updProc.running = true
    }
  }

  // opendata: снимок --json пересобирается каждые 4 с, но чаще всего меняется
  // лишь пара полей. Неизменившиеся разделы сохраняем тем же объектом, чтобы
  // привязки (vtResults → nodesOfProfile → Repeater) не инвалидировались и
  // список серверов не пересоздавался под курсором.
  function sameValue(a, b) {
    return JSON.stringify(a) === JSON.stringify(b)
  }
  function mergeSections(prev, next) {
    if (!prev || typeof prev !== "object") return next
    var out = {}
    var changed = false
    for (var k in next) {
      if (prev[k] !== undefined && root.sameValue(prev[k], next[k])) out[k] = prev[k]
      else { out[k] = next[k]; changed = true }
    }
    for (var p in prev) if (!(p in next)) changed = true
    return changed ? out : prev
  }

  onBsChanged: {
    var v = root.vpn
    if (!root.autoTried && root.autoconnect && v && v.installed !== false && !v.running
        && root.cliPath !== "") {
      root.autoTried = true
      root.run(["on"], "auto")
    }
  }

  onOpenedChanged: {
    if (!opened) return
    root.refreshStatus()
    if (!vpnProc.running && (!root.vpnLoaded || (Date.now() / 1000 - (root.vpnInfo.updated || 0)) > 120))
      vpnProc.running = true
    // Открытие панели — это не повод лечить VPN и не повод занимать busy:
    // только чтение готового health.json, лечение — по кнопке.
    if (!root.healthBusy && (!root.hl.checked || root.hl.age > 600)) root.startHealth(false)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function vpn(): string { root.run(["toggle"], "vpn"); return "ok" }
    function health(): string { root.startHealth(false); return "ok" }
    function heal(): string { root.startHealth(true); return "ok" }
    function audit(): string {
      if (auditProc.running || root.busy !== "") return "busy"
      root.busy = "audit"
      auditProc.running = true
      return "ok"
    }
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

  // Кнопка действия: Ui/Button не показывает disabled сам, поэтому гасим руками —
  // иначе недоступная кнопка выглядит рабочей.
  component ActionButton: Button {
    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    opacity: enabled ? 1 : 0.5
  }

  // ---- процесс опроса статуса ---------------------------------------------
  Process {
    id: statusProc
    command: [root.scriptPath, "--json"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(code) {
      if (root.timeoutHit === "status") {
        root.timeoutHit = ""
        root.lastError = "статус не ответил за 60 с — данные могли устареть"
        return
      }
      if (code !== 0) {
        root.lastError = "статус не получен (код " + code + ")"
        return
      }
      var d = null
      try { d = JSON.parse(statusOut.text) } catch (e) { d = null }
      if (!d || typeof d !== "object") {
        root.lastError = "статус: битый ответ"
        return
      }
      if (d.ok !== true) {
        root.lastError = "статус: " + (d.error || "сервис вернул ошибку")
        return
      }
      root.lastError = ""
      root.statusAt = Date.now() / 1000
      var merged = root.mergeSections(root.bs, d)
      if (merged !== root.bs) root.bs = merged
    }
  }

  Process {
    id: vpnProc
    command: [root.scriptPath, "--vpn"]
    stdout: StdioCollector { id: vpnOut; waitForEnd: true }
    onExited: function(code) {
      if (root.timeoutHit === "vpn") {
        root.timeoutHit = ""
        root.lastError = "список серверов не получен за 60 с"
        return
      }
      if (code !== 0) {
        root.lastError = "список серверов не получен (код " + code + ")"
        return
      }
      var d = null
      try { d = JSON.parse(vpnOut.text) } catch (e) { d = null }
      if (!d || typeof d !== "object") {
        root.lastError = "список серверов: битый ответ"
        return
      }
      if (d.ok === false) {
        root.lastError = "список серверов: " + (d.error || "ошибка")
        return
      }
      root.vpnInfo = d
      root.vpnLoaded = true
    }
  }

  // Комплексный тест конфигурации: страница/видео YouTube, Discord, DeepSeek,
  // Telegram, tg-ws-proxy, zapret и реальный выход VPN. Раз в 5 минут —
  // без лечения (--health-json); с лечением — только по кнопке «Проверить всё».
  Process {
    id: healthProc
    command: [root.scriptPath, "--health-json"]
    stdout: StdioCollector { id: healthOut; waitForEnd: true }
    onExited: function(code) {
      var was = root.healthRunning
      root.healthRunning = ""
      var timedOut = root.timeoutHit === "health"
      if (timedOut) root.timeoutHit = ""
      if (timedOut) {
        root.lastError = "проверка не ответила за 5 минут — прервана"
      } else if (code !== 0) {
        root.lastError = "проверка завершилась ошибкой (код " + code + ")"
      } else {
        var d = null
        try { d = JSON.parse(healthOut.text) } catch (e) { d = null }
        if (!d || !(d.items instanceof Array)) {
          root.lastError = "проверка: непонятный ответ"
        } else {
          root.health = d
          root.lastError = d.error ? ("проверка прервалась: " + d.error) : ""
          var h = d.heal || {}
          if (h && h.actions && h.actions.length > 0) {
            root.notice = "VPN: " + h.actions.join("; ")
            noticeTimer.restart()
          }
          if (was === "heal") root.notify("Обходы: проверка", d.summary || "готово")
        }
      }
      root.refreshStatus()
    }
  }

  Process {
    id: rescanProc
    command: [root.scriptPath, "--rescan-request"]
    stdout: StdioCollector { id: rescanOut; waitForEnd: true }
    onExited: function(code) {
      var timedOut = root.timeoutHit === "rescan"
      if (timedOut) root.timeoutHit = ""
      root.busy = ""
      var msg = timedOut ? "запрос перебора не ответил — попробуй ещё раз" : "не удалось запросить перебор"
      if (code === 0 && !timedOut) {
        msg = "перебор запрошен — стратегии тестируются"
        try {
          var d = JSON.parse(rescanOut.text)
          if (d && d.message) msg = d.message
        } catch (e) { /* пустой вывод */ }
      }
      root.notice = msg
      noticeTimer.restart()
      root.refreshStatus()
    }
  }

  // «Подобрать лучший»: тест всех регионов и серверов, применение победителя.
  Process {
    id: optimizeProc
    command: [root.scriptPath, "--optimize"]
    stdout: StdioCollector { id: optimizeOut; waitForEnd: true }
    onExited: function(code) {
      var timedOut = root.timeoutHit === "optimize"
      if (timedOut) root.timeoutHit = ""
      root.busy = ""
      var msg = timedOut ? "подбор не ответил за 4 минуты — прерван" : "не удалось запустить подбор"
      if (code === 0 && !timedOut) {
        try {
          var d = JSON.parse(optimizeOut.text)
          if (d && d.message) msg = d.message
          else if (d && d.error) msg = d.error
        } catch (e) { /* пустой вывод */ }
      }
      root.notice = msg
      noticeTimer.restart()
      root.notify("Обходы: подбор", msg)
      root.refreshStatus()
      root.refreshVpn()
    }
  }

  // Аудит маршрутов: домен, который не отвечает по текущему пути, уходит на
  // рабочий (omavpn route set ... proxy). Настройки VPN не трогает, но туннель
  // перезапускает — поэтому запускается только после подтверждения.
  Process {
    id: auditProc
    command: [root.scriptPath, "--route-audit"]
    stdout: StdioCollector { id: auditOut; waitForEnd: true }
    onExited: function(code) {
      var timedOut = root.timeoutHit === "audit"
      if (timedOut) root.timeoutHit = ""
      root.busy = ""
      var msg = timedOut ? "аудит маршрутов не ответил за 3 минуты" : "не удалось проверить маршруты"
      var d = null
      try { d = JSON.parse(auditOut.text) } catch (e) { d = null }
      if (!timedOut && code === 0 && d) {
        if (d.reason === "already_running") msg = "аудит маршрутов уже идёт"
        else if (d.reason === "lock_error") msg = "уже идёт проверка — лок занят"
        else if (d.verdict === "error") msg = "аудит не выполнился: " + (d.error || d.summary || "неизвестная ошибка")
        else if (d.summary) msg = d.summary
      } else if (!timedOut) {
        root.lastError = "аудит маршрутов завершился ошибкой (код " + code + ")"
      }
      root.notice = msg
      noticeTimer.restart()
      root.notify("Обходы: маршруты", msg)
      root.refreshStatus()
    }
  }

  Process {
    id: updProc
    command: [root.scriptPath, "--update-components"]
    stdout: StdioCollector { id: updOut; waitForEnd: true }
    onExited: function(code) {
      var timedOut = root.timeoutHit === "upd"
      if (timedOut) root.timeoutHit = ""
      root.busy = ""
      var msg = timedOut ? "обновление не ответило за 4 минуты" : "не удалось обновить"
      if (code === 0 && !timedOut) {
        try {
          var d = JSON.parse(updOut.text)
          if (d && d.messages && d.messages.length) msg = d.messages.join("; ")
        } catch (e) { /* пустой вывод */ }
      }
      root.notice = msg
      noticeTimer.restart()
      root.notify("Обходы: обновления", msg)
      root.refreshStatus()
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    onExited: function(code) {
      var label = root.busy
      var timedOut = root.timeoutHit === "action"
      if (timedOut) root.timeoutHit = ""
      root.busy = ""
      if (timedOut) {
        root.lastError = "действие «" + (label || "?") + "» не ответило за 3 минуты"
      } else if (code !== 0) {
        var t = (actionErr.text || actionOut.text || "").trim()
        try { var j = JSON.parse(t); if (j.error) t = j.error } catch (e) { /* plain */ }
        root.lastError = t || "ошибка"
      } else {
        root.lastError = ""
      }
      if (label === "vpn" || label === "update") {
        // vpnOn здесь ещё старый (статус обновится ниже), поэтому без «включён/выключен».
        root.notify("Обходы: " + (label === "vpn" ? "VPN" : "подписка"),
          root.lastError !== "" ? root.lastError
            : (label === "vpn" ? "переключено" : "обновлена"))
      }
      root.refreshStatus()
      root.refreshVpn()
      // Лечение после переключения не запускаем: остальное покажет обычный опрос.
    }
  }

  Process {
    id: notifyProc
    // notify-send есть на этой машине (libnotify); если его нет — уведомление
    // просто не появится, на работу виджета это не влияет.
    command: ["notify-send", "-a", "Обходы", "Обходы", ""]
    onExited: function(code) { /* код не важен: уведомление — необязательный бонус */ }
  }

  Timer {
    id: noticeTimer
    interval: 9000
    onTriggered: root.notice = ""
  }

  // Тик для надписей «проверяю… N с» и возраста данных — без спавнов.
  Timer {
    id: tick
    interval: 1000
    running: root.opened
    repeat: true
    onTriggered: root.nowSec = Date.now() / 1000
  }

  // Опрос статуса: открытая панель — 4 с (живые строки), закрытая — 25 с.
  // Раньше --json шёл каждые 4 с круглосуточно (~100 спавнов в минуту, ~10 % ядра).
  Timer {
    id: statusTimer
    interval: root.opened ? 4000 : 25000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  // Монитор работоспособности: комплексная проверка каждые 5 минут — только чтение.
  Timer {
    id: healthTimer
    interval: 300000
    running: true
    repeat: true
    onTriggered: {
      if (root.busy !== "" || root.healthBusy) return
      root.startHealth(false)
    }
  }

  // Сторожа процессов: интервал = предел ожидания, взводится вместе с запуском.
  Timer { id: statusWatch; interval: 60000; running: statusProc.running; onTriggered: root.killProc("status") }
  Timer { id: vpnWatch; interval: 60000; running: vpnProc.running; onTriggered: root.killProc("vpn") }
  Timer { id: healthWatch; interval: 300000; running: healthProc.running; onTriggered: root.killProc("health") }
  Timer { id: auditWatch; interval: 180000; running: auditProc.running; onTriggered: root.killProc("audit") }
  Timer { id: optimizeWatch; interval: 240000; running: optimizeProc.running; onTriggered: root.killProc("optimize") }
  Timer { id: rescanWatch; interval: 120000; running: rescanProc.running; onTriggered: root.killProc("rescan") }
  Timer { id: updWatch; interval: 240000; running: updProc.running; onTriggered: root.killProc("upd") }
  Timer { id: actionWatch; interval: 180000; running: actionProc.running; onTriggered: root.killProc("action") }

  // ---- кнопка в панели -----------------------------------------------------
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: true
    activeColor: root.healthColor
    tooltipText: "Обходы: " + root.healthText + (root.raText !== "" ? " · " + root.raText : "")
      + " · ПКМ — включить/выключить VPN"
    iconComponent: Component {
      Pictogram {
        name: root.healthIcon
        tint: root.healthColor
        px: Style.space(15)
      }
    }
    onPressed: function(buttonCode) {
      // Правый клик — VPN включить/выключить, без открытия панели.
      if (buttonCode === Qt.RightButton) {
        if (root.cliPath !== "" && root.busy === "") root.run(["toggle"], "vpn")
        return
      }
      root.toggle()
    }
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
      onCloseRequested: {
        if (confirmDlg.opened) root.cancelConfirm()
        else root.close()
      }
      onReturnRequested: if (confirmDlg.opened) root.confirmRun()
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

        Text {
          width: parent.width
          visible: root.degradedText !== ""
          textFormat: Text.PlainText
          text: root.degradedText
          color: root.warn
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }

        // Одна строка «что сломано и что нажать».
        Text {
          width: parent.width
          visible: root.advice !== ""
          textFormat: Text.PlainText
          text: root.advice
          color: root.verdict === "bad" ? root.urgent : root.warn
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
                tint: root.vpnOn ? root.stateColor(root.hState("vpn", "")) : root.dim
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
                    color: root.vpnOn ? root.stateColor(root.hState("vpn", "")) : root.dim
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

              ActionButton {
                id: toggleBtn
                anchors.verticalCenter: parent.verticalCenter
                text: root.busy === "vpn" ? "…" : (root.vpnOn ? "Выключить" : "Включить")
                accent: root.vpnOn ? root.okColor : Color.accent
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

            // итог подбора — остаётся после завершения (с «применён» или ошибкой)
            Text {
              width: parent.width
              visible: root.vtResultText !== ""
              textFormat: Text.PlainText
              text: root.vtResultText
              color: root.vtResultColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
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

                // Авто (omavpn node -1): без этой строки из UI нельзя было
                // вернуться к балансировке — при node_index < 0 ничего не подсвечено.
                Rectangle {
                  id: autoNodeRow
                  readonly property bool isCurrent: Number(root.vpnInfo.node_index) < 0
                  width: parent.width
                  implicitHeight: anodeRow.implicitHeight + Style.space(8)
                  radius: Style.cornerRadius > 0 ? Style.space(8) : 0
                  color: autoNodeRow.isCurrent ? root.selectedFill
                         : (anodeMouse.containsMouse ? root.hoverFill : "transparent")

                  Row {
                    id: anodeRow
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
                      color: autoNodeRow.isCurrent ? root.okColor : root.dim
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: "Авто (лучший по задержке)" + (autoNodeRow.isCurrent ? " ●" : "")
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      width: Style.space(180)
                      elide: Text.ElideRight
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: "балансировка между серверами региона"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                      width: parent.width - Style.space(240)
                    }
                  }

                  MouseArea {
                    id: anodeMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: if (root.busy === "") root.run(["node", "-1"], "node")
                  }
                }

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
        // При устаревшем снимке (> 60 с) значения больше не «живые» — гасим их.
        Column {
          width: parent.width
          spacing: Style.space(2)
          opacity: root.statusStale ? 0.6 : 1.0

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
                tint: root.zapTesting ? root.warn : root.stateColor(root.hState("zapret", ""))
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
                // Обновление компонентов идёт через pkexec, то есть с паролем.
                root.askConfirm("upd",
                  "Обновить zapret и tg-ws-proxy?\nПонадобится пароль (pkexec) и 1–2 минуты. Трафик может прерваться.")
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

          ActionButton {
            text: root.healthBusy ? ("… " + root.healthElapsed + " с") : "Проверить всё"
            tooltipText: "Полная проверка с попыткой самовосстановления VPN (до 3 минут)"
            enabled: root.scriptPath !== "" && !root.healthBusy && root.busy === ""
            onClicked: root.startHealth(true)
          }

          ActionButton {
            text: root.vtRunning ? ("подбор " + root.vtDone + "/" + root.vtTotal) : "Подобрать лучший"
            accent: Color.accent
            tooltipText: "Прогнать все регионы и серверы и подключить лучший (туннель перезапустится)"
            enabled: root.cliPath !== "" && root.busy === "" && !root.vtRunning
            onClicked: {
              if (root.vtRunning || optimizeProc.running) return
              root.busy = "vtest"
              root.vpnExpanded = true
              optimizeProc.running = true
            }
          }

          ActionButton {
            text: root.busy === "rescan" ? "…" : "Тест стратегий"
            // Фоновая проверка не должна гасить действия — только своё занятие.
            enabled: root.scriptPath !== "" && root.busy === ""
            onClicked: {
              if (root.busy !== "" || rescanProc.running) return
              root.busy = "rescan"
              rescanProc.running = true
            }
          }

          ActionButton {
            text: root.busy === "audit" ? "… маршруты" : "Проверить маршруты"
            tooltipText: "Аудит доменов: может перевести домен на другой путь и перезапустить туннель (~1 минута)"
            // Аудит запускает scriptPath (bypass-status), а не cliPath (omavpn):
            // проверять надо именно его, иначе кнопка мертва без CLI.
            enabled: root.scriptPath !== "" && root.busy === ""
            onClicked: root.askConfirm("audit",
              "Проверить маршруты доменов?\nАудит может перевести домены на другой путь и перезапустить туннель — трафик прервётся примерно на минуту.")
          }

          ActionButton {
            text: root.busy === "update" ? "…" : "Обновить подписку"
            tooltipText: "Перечитать подписку (туннель перезапустится)"
            enabled: root.cliPath !== "" && root.busy === ""
            onClicked: root.askConfirm("update",
              "Обновить подписку?\nТуннель перезапустится, трафик прервётся на несколько секунд.")
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

        // Возраст снимка --json: если бэкенд молчит, значения помечены как старые.
        Text {
          width: parent.width
          visible: root.statusStamp !== ""
          textFormat: Text.PlainText
          text: "данные от " + root.statusStamp
            + (root.statusStale ? " · устарели, обновление не отвечает" : "")
          color: root.statusStale ? root.warn : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }

        // Аудит маршрутов: полный список доменов не обрезаем — перенос + подсказка.
        Text {
          id: raLine
          width: parent.width
          visible: root.raLineText !== ""
          textFormat: Text.PlainText
          text: root.raLineText
          color: root.raColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap

          // MouseArea внутри Text: как ребёнок Column она попала бы под
          // позиционер и потеряла anchors.
          MouseArea {
            id: raHover
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            hoverEnabled: true
          }

          ToolTip {
            id: raTip
            visible: raHover.containsMouse && raLine.visible
            delay: 500
            padding: Style.space(8)
            text: root.raLineText
            contentItem: Text {
              textFormat: Text.PlainText
              text: raTip.text
              color: Color.tooltip.text
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              width: Style.space(340)
              wrapMode: Text.WordWrap
            }
            background: Rectangle {
              color: Color.tooltip.background
              radius: Style.cornerRadius > 0 ? Style.space(6) : 0
              border.width: 1
              border.color: Color.tooltip.border
            }
          }
        }
      }
    }

    // Подтверждение разрушительных действий: обновление подписки, аудит
    // маршрутов и обновление компонентов (pkexec) рвут трафик.
    ConfirmDialog {
      id: confirmDlg
      anchors.fill: parent
      z: 10
      opened: false
      message: root.confirmMessage
      cancelText: "Отмена"
      confirmText: "Продолжить"
      background: root.bar ? root.bar.background : Color.background
      foreground: root.foreground
      selectedText: Color.accent
      fontFamily: root.fontFamily
      onCanceled: root.cancelConfirm()
      onConfirmed: root.confirmRun()
    }
  }
}
