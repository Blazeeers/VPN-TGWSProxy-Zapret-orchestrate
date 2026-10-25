// Bound: делегаты Repeater видят внешние id (root, Style, Color) как обычные
// привязки, а не как необъявленный контекст — уходят предупреждения qmllint
// «Unqualified access», поведение не меняется.
pragma ComponentBehavior: Bound

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
  // Сколько раз пробовали поднять VPN при входе. При загрузке сеть часто ещё
  // не готова, и первый `omavpn on` падает — без повторов автозапуск молча
  // терялся до перезапуска оболочки.
  property int autoAttempts: 0
  // Сколько раз просыпался таймер повтора. Ограничивает ожидание «сеть вот-вот
  // встанет»: без счётчика таймер перезапускался бы вечно, если список серверов
  // так и не пришёл или действие занято.
  property int autoRetryWakes: 0
  // Лечение, запущенное самим виджетом (не кнопкой): уведомления о нём не нужны.
  property bool healthAuto: false
  property real autoHealAt: 0
  // Лечение уже пробовали в этой сессии — без этого автоподбор сервера не
  // запускаем: сначала надо дать шанс лечению, оно дешевле.
  property bool healTried: false
  // Сколько проверок подряд закончились bad. Две подряд — повод менять сервер.
  property int badStreak: 0
  // Отметки автоматических шагов (подбор сервера, аудит маршрутов): по ним
  // считаем «не чаще раза в час / полчаса». Ноль — берём время из кэша бэкенда.
  property real autoOptimizeAt: 0
  property real autoAuditAt: 0
  // Автозапуск подбора/аудита: об успехе молчим, о неудаче — одно уведомление.
  property bool optimizeAuto: false
  property bool auditAuto: false
  // Кулдаун лечения в бэкенде (HEAL_MIN_GAP в bin/bypass-status — 2700 с).
  // Свой порог обязан быть не меньше: при 900 с каждые 15 минут уходил полный
  // --health, который тут же получал heal.skipped, — лишняя нагрузка и ложное
  // «лечение не помогло».
  readonly property real autoHealGap: 2700

  readonly property bool autoconnect: root.setting("autoconnect", false)
  // Тихая иконка: когда всё в порядке, пиктограмма в баре не красится и не
  // притягивает взгляд. Ключ живёт в настройках плагина (setSetting ниже).
  readonly property bool quietBar: root.setting("quietBar", true)

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
  // Три ошибки, а не одна. Статус опрашивается каждые 4 с и стирал общий текст
  // раньше, чем его успевали прочитать: ошибки health/аудита/действий жили
  // меньше одного опроса. statusError живёт до следующего удачного снимка --json
  // (это главный опрос: пока он мёртв, данных нет вовсе), vpnError — до удачного
  // --vpn (список серверов: без него нет регионов, но статус VPN ещё есть),
  // opError — до следующей операции (или до её успешного завершения).
  property string statusError: ""
  property string vpnError: ""
  property string opError: ""
  readonly property string errorText: {
    var seen = {}
    var out = []
    var all = [root.opError, root.statusError, root.vpnError]
    for (var i = 0; i < all.length; i++) {
      var s = all[i]
      if (s === "" || seen[s]) continue
      seen[s] = true
      out.push(s)
    }
    return out.join("\n")
  }
  // Процесс мог не запуститься вовсе (нет файла, нет прав): в quickshell 0.3.1
  // FailedToStart не эмитит exited, поэтому у пассивных опросов свои метки —
  // по ним onRunningChanged понимает, что сброс из onExited не придёт.
  property bool statusAwait: false
  property bool vpnAwait: false
  // Одно и то же сообщение нужно в нескольких местах — держим его строкой.
  readonly property string startErrorText: "bypass-status не запускается — проверь " + root.scriptPath
  // Время последнего УДАЧНОГО снимка --json. Нужен, чтобы честно писать
  // «данные от HH:MM» и помечать залипшие значения, а не делать вид, что они свежие.
  property real statusAt: 0
  // Ключ сети: подтверждённый, кандидат на смену и время последней смены. Ключ
  // собирается каскадом источников (iwgetid → nmcli → MAC шлюза) и может мигнуть
  // одним снимком, поэтому новому ключу верим только со второго раза подряд.
  property string netSeen: ""
  property string netCandidate: ""
  property real netChangeAt: 0
  property real healthStartedAt: 0
  // Кто именно не ответил (для понятного сообщения вместо «ошибка»).
  // Метка на каждый процесс отдельная: два сторожа могут сработать подряд, и
  // общий признак «что-то зависло» доставался бы не тому onExited — сообщение
  // уходило бы о чужом процессе, а второй сбой терял свою метку.
  property var timeouts: ({})
  // Тик раз в секунду только для надписей («проверяю… N с», возраст данных).
  property real nowSec: Date.now() / 1000

  // Подтверждение разрушительных действий.
  property string confirmKind: ""
  property string confirmMessage: ""

  // ---- экран настроек и маршруты сайтов ------------------------------------
  // Действия, тумблеры и правила маршрутов живут за шестернёй в шапке: основная
  // панель показывает состояние, настройки — то, что его меняет.
  property bool settingsOpen: false
  // Путь для нового правила: "direct" — напрямую, "proxy" — через VPN.
  property string routePath: "direct"
  // Свои правила из `omavpn route list`: [{domain, path, reason, ts}].
  property var routeOverrides: []
  // Список правил прочитан хотя бы раз: до этого «правил нет» было бы выдумкой.
  property bool routeLoaded: false
  property string routeError: ""
  // «Список маршрутов в пути». FailedToStart не эмитит exited, и без этой метки
  // ошибка о недоступном omavpn не появилась бы вовсе.
  property bool routeListAwait: false
  // Список просили обновить, пока он уже читался: повторим после ответа, иначе
  // правило, добавленное в этот момент, осталось бы вне списка до переоткрытия.
  property bool routeListDirty: false

  // ---- Re:filter (заблокированное в РФ) и подписка -------------------------
  // Состояние списка читаем отдельной командой, а не из общего снимка статуса:
  // размеры файлов и дата обновления нужны только на экране настроек. Сами
  // 80 тысяч доменов в QML не попадают никогда — только сводка.
  property var rf: ({})
  property bool rfLoadedOnce: false
  property bool rfAwait: false      // статус в пути, ответа ещё нет
  property bool rfBusy: false       // идёт on/off/update
  property string rfError: ""
  // Ошибку поставило действие (on/off/update), а не чтение статуса: успешный
  // перезапрос статуса не должен стирать её с экрана.
  property bool rfActionError: false
  // Поле подписки: пустое значение — ещё не читали. dirty не даёт ответу
  // `subscription get` затереть то, что человек уже начал печатать.
  property string subUrl: ""
  property bool subLoaded: false
  property bool subDirty: false
  property bool subBusy: false
  property string subError: ""
  property bool subAwait: false
  // Ответ на служебную перечитку URL не должен стирать текст ошибки сохранения.
  property bool subQuiet: false
  property bool resetBusy: false
  property string resetError: ""
  // URL задан переменной OMAVPN_SUB_URL: файл в этом случае ничего не решает,
  // и «Сохранить» было бы обманом.
  property bool subEnv: false

  readonly property bool rfEnabled: root.rf.enabled === true
  readonly property bool rfReady: root.rf.loaded === true
  readonly property string rfUpdated: String(root.rf.updated_text || "")
  // Причина, по которой набор не годится (битый файл, нет файла): `status`
  // проверяет сигнатуру и разбирает набор sing-box'ом, поэтому текст конкретный.
  readonly property string rfProblem: {
    if (!root.rfLoadedOnce || root.rfReady) return ""
    var f = root.rf.files || {}
    var parts = []
    for (var k in f) {
      if (f[k] && f[k].ok !== true && f[k].error) parts.push(String(f[k].error))
    }
    return parts.join("; ")
  }
  // Сводка для строки состояния. Объём — в мегабайтах с запятой: список весит
  // ~0,6 МБ, и «0.6» в русской подписи выглядит опечаткой.
  readonly property string rfSummary: {
    if (root.cliPath === "") return "omavpn не найден — списки недоступны"
    if (!root.rfLoadedOnce) return "читаю состояние…"
    var head = root.rfEnabled ? "Re:filter" : "Re:filter · выключено"
    if (!root.rfReady) return head + " · список не загружен — нажми «Обновить»"
    var mb = (Number(root.rf.total_bytes || 0) / 1048576).toFixed(1).replace(".", ",")
    var s = head + " · загружен · " + mb + " МБ"
    if (root.rfUpdated !== "") s += " · обновлён " + root.rfUpdated
    return s
  }

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
  // Реальная доступность bypass-status: раз снимок --json пришёл, скрипт есть и
  // исполняется. Прежнее «scriptPath !== ""» ничего не проверяло — путь
  // собирается из $HOME и пустым не бывает, поэтому кнопки были «включены» даже
  // без установленного CLI.
  readonly property bool scriptOk: root.statusAt > 0

  readonly property bool vpnOn: !!root.vpn.running
  readonly property bool capsOk: root.vpn.caps_ok !== false
  readonly property bool zapTesting: !!root.zap.testing || root.zap.autotune === "activating"
  // Штатный подбор стратегии — отдельное нейтральное состояние, а не тревога:
  // его показывает и свежий status, и уже записанный health.json.
  readonly property bool zapTuning: root.zapTesting || root.hState("zapret", "") === "tuning"

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
  // Отметка последней проверки. Свежесть считаем именно по ней: в свежем ответе
  // --health-json поля age нет (его добавляет только чтение кэша health.json),
  // поэтому проверка «hl.age > 600» не срабатывала никогда.
  readonly property real healthChecked: Number(root.hl.checked || 0)
  // Порог устаревания берём из политики проверок (healthMaxAge: 600 с без guard,
  // 900/1200 с ним), а не из жёстких 600: иначе на здоровой системе с guard бар
  // желтел каждые 5–10 минут между штатными проверками. +60 с — запас на тик.
  readonly property bool healthStale: root.hl.stale === true
    || (root.healthChecked > 0
        && (root.nowSec - root.healthChecked) > root.healthMaxAge() + 60)
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
  // Аудит считается провалившимся, если бэкенд так и сказал (verdict=error),
  // вернул ok=false без единой пробы или раздел не собрался. Отдельный случай —
  // файл без verdict и без проб, но с отметкой checked: это не провал, а
  // отсутствие результата (raUnclear ниже), иначе он давал ложное зелёное.
  readonly property bool raFailed: {
    if (root.raDegraded) return true
    if (String(root.ra.verdict || "") === "error") return true
    if (root.raProbes.length === 0 && root.ra.ok === false) return true
    if (String(root.ra.verdict || "") === "bad" && root.raProbes.length === 0) return true
    return false
  }
  // Страховка от ложного зелёного: в файле стоит отметка checked, но при этом
  // ни verdict, ни единой пробы — значит результата аудита в нём нет (битый или
  // очень старый файл). Зелёное «маршруты в порядке» здесь было бы выдумкой, а
  // красное «аудит не выполнился» — перебором: показываем нейтрально-жёлтым.
  readonly property bool raUnclear: !root.raFailed
    && root.raProbes.length === 0
    && String(root.ra.verdict || "") === ""
    && Number(root.ra.checked || 0) > 0
  readonly property bool raHas: !root.raFailed && !root.raUnclear
    && (Number(root.ra.checked || 0) > 0 || root.raProbes.length > 0)
  readonly property var raBroken: {
    var bad = []
    for (var i = 0; i < root.raProbes.length; i++) {
      var p = root.raProbes[i]
      // advisory-пробы (redirector.googlevideo.com) не делают вердикт плохим —
      // иначе панель краснела бы из-за вспомогательного домена
      if (p.after || p.advisory) continue
      // not_applied — правило записано, но VPN не перезапустился: проба не
      // выполнялась вовсе, это не «домен не отвечает», а «переключение не
      // применено» (лечится рестартом, а не маршрутом).
      // kept — домен намеренно оставлен в туннеле: в direct он не работает.
      if (p.not_applied || p.kept) continue
      bad.push(p.domain)
    }
    return bad
  }
  readonly property var raPending: {
    var out = []
    for (var i = 0; i < root.raProbes.length; i++)
      if (root.raProbes[i].not_applied) out.push(root.raProbes[i].domain)
    return out
  }
  readonly property var raKept: {
    var out = []
    for (var i = 0; i < root.raProbes.length; i++)
      if (root.raProbes[i].kept) out.push(root.raProbes[i].domain)
    return out
  }
  // Свои счётчики — запасной вариант на случай старого кэша без summary.
  readonly property string raCounters: {
    var parts = []
    if (root.raCount > 0) parts.push("проверено " + root.raCount)
    if (root.raFixed > 0) parts.push("исправлено " + root.raFixed)
    if (root.raKept.length > 0) parts.push("оставил в VPN: " + root.raKept.join(", "))
    if (root.raPending.length > 0)
      parts.push("не применено (VPN не перезапустился): " + root.raPending.join(", "))
    if (root.raBroken.length > 0) parts.push("не отвечают " + root.raBroken.join(", "))
    return parts.length > 0 ? parts.join("; ") : "в порядке"
  }
  readonly property string raText: {
    if (root.raFailed) {
      var why = String(root.ra.summary || root.ra.error || "")
      if (why === "" && root.raDegraded) why = "раздел route_audit не собрался"
      return "маршруты: аудит не выполнился" + (why !== "" ? " — " + why : "")
    }
    if (root.raUnclear) return "маршруты: аудит не дал результата — нажми «Проверить маршруты»"
    if (!root.raHas) return ""
    // Бэкенд отдаёт готовую человеческую строку (проверено / исправлено /
    // оставил в VPN / не применено) — дублировать её своими счётчиками незачем.
    var s = String(root.ra.summary || "").trim()
    if (s === "") s = root.raCounters
    // В фолбэке бэкенд уже пишет «маршруты в порядке» — префикс не нужен.
    return s.indexOf("маршрут") === 0 ? s : "маршруты: " + s
  }
  readonly property string raLineText: {
    if (root.raText === "") return ""
    var t = root.raText
    if (root.ra.checked) t += " · " + root.fmtAge(root.ra.age || 0)
    if (root.ra.stale === true) t += " · устарело"
    return t
  }
  readonly property color raColor: root.raFailed ? root.urgent
    : (root.raUnclear ? root.warn
      : (root.raFixed > 0 ? root.warn
        : (root.raBroken.length > 0 ? root.urgent
          : ((root.raPending.length > 0 || root.raKept.length > 0) ? root.warn : root.okColor))))

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
    if (state === "tuning") return Color.accent
    return root.dim
  }
  function stateWord(state) {
    if (state === "ok") return "ок"
    if (state === "warn") return "внимание"
    if (state === "bad") return "сбой"
    if (state === "idle") return "выкл"
    if (state === "tuning") return "подбор"
    return ""
  }

  // ---- тест серверов / подбор региона --------------------------------------
  readonly property var vt: (root.bs && root.bs.vpn_test) ? root.bs.vpn_test : ({})
  readonly property var vtResults: (root.vt.results instanceof Array) ? root.vt.results : []
  readonly property bool vtRunning: root.vt.running === true
  readonly property int vtDone: Number(root.vt.nodes_done) || 0
  readonly property int vtTotal: Number(root.vt.nodes_total) || 0
  readonly property var vtBest: (root.vt.best && root.vt.best.index !== undefined) ? root.vt.best : null
  readonly property bool vtHasData: root.vtResults.length > 0 || root.vtRunning
  readonly property real vtProgress: root.vtTotal > 0 ? Math.min(1, root.vtDone / root.vtTotal) : 0
  // Результат подбора живёт в кэше до следующего теста. «Применён» от вчерашнего
  // прогона — ложь: настройки с тех пор могли сменить руками. nowSec тикает при
  // открытой панели, поэтому там возраст честный; в закрытой панели привязка не
  // пересчитывается — это допустимо, важно не врать на экране.
  readonly property bool vtAppliedFresh: root.vt.applied === true
    && (root.nowSec - Number(root.vt.finished || root.vt.updated || 0)) < 3600
  // Регион, к которому относится результат. В режиме `omavpn probe` у best нет
  // profile_index (пишется только index/tag/med/score), поэтому берём регион
  // прогона: иначе звезда зажигалась бы во всех регионах и на одноимённом
  // номере в чужом регионе. -1 — регион неизвестен, звезды нет.
  readonly property int vtBestProfile: {
    if (!root.vtBest) return -1
    var pi = NaN
    if (root.vtBest.profile_index !== undefined) pi = Number(root.vtBest.profile_index)
    else if (root.vt.profile !== undefined) pi = Number(root.vt.profile)
    else pi = Number(root.vpnInfo.profile_index)
    return isNaN(pi) ? -1 : pi
  }
  // В режиме `omavpn probe` бэкенд не кладёт profile_name — подставляем имя
  // региона прогона, иначе панель показывает «лучший: ?».
  readonly property string vtBestName: {
    if (!root.vtBest) return ""
    if (root.vtBest.profile_name) return root.vtBest.profile_name
    var pi = root.vtBestProfile
    if (pi < 0) return ""
    for (var i = 0; i < root.vpnProfiles.length; i++)
      if (Number(root.vpnProfiles[i].index) === pi) return root.vpnProfiles[i].name
    return ""
  }
  // Туннель занят тем, что нельзя перебивать: идёт подбор серверов или лечение.
  // Обычная (read-only) проверка сюда не входит — она короткая и ничего не
  // перезапускает, поэтому не должна отбирать у человека кнопку VPN.
  readonly property bool tunnelBusy: root.vtRunning || root.healthRunning === "heal"
  // Занятость «боковых» операций: обновление списков Re:filter, смена подписки,
  // полный сброс. Все три трогают туннель и/или ctrl.lock, поэтому остальные
  // действия (проверка, подбор, маршруты) на это время гасятся — иначе человек
  // получит ложное «другой процесс управляет VPN».
  readonly property bool sideBusy: root.rfBusy || root.subBusy || root.resetBusy
  // Бюджеты «боковых» операций: один источник и для таймера-сторожа, и для
  // текста ошибки — раньше сторожа уже подняли, а в сообщении остались минуты.
  readonly property int rfStatusTimeout: 120000
  readonly property int rfActionTimeout: 360000
  readonly property int subGetTimeout: 120000
  readonly property int subSetTimeout: 240000
  readonly property int resetTimeout: 480000

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
    if (root.vtBest) t = "лучший: " + (root.vtBestName || "?") + " · #" + root.vtBest.index + " " + root.vtBest.tag
    else t = "живых серверов " + alive
    if (root.vtAppliedFresh) t += " · применён"
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
      t = "лучший " + (root.vtBestName || "?") + " · #" + root.vtBest.index + " " + root.vtBest.tag
    } else {
      var alive = 0
      for (var i = 0; i < root.vtResults.length; i++) if (!root.vtResults[i].dead) alive++
      t = "живых серверов " + alive
    }
    t += root.vtAppliedFresh ? " · применён" : " · не применён"
    if (root.vtWhen !== "") t += " · " + root.vtWhen
    return "подбор: " + t
  }
  readonly property color vtResultColor: root.vt.error ? root.urgent
    : (root.vtAppliedFresh ? root.okColor : root.dim)
  readonly property string vtWhen: {
    var t = Number(root.vt.finished || root.vt.updated || 0)
    return t > 0 ? Qt.formatTime(new Date(t * 1000), "HH:mm") : ""
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
    root.statusError !== "" ? "warning"
    : root.verdict === "bad" ? "warning"
    : root.verdict === "warn" ? "warning"
    : (root.verdict === "tuning" || root.zapTuning) ? "refresh"
    : (root.vtRunning || root.healthBusy) ? "refresh"
    : (root.healthStale && !root.healthBusy) ? "refresh"
    : root.verdict === "ok" ? "check"
    : "vpn"
  readonly property color healthColorBase:
    root.statusError !== "" ? root.urgent
    : root.verdict === "bad" ? root.urgent
    : root.verdict === "warn" ? root.warn
    // Устаревшая проверка — не «всё хорошо»: пока свежего ответа нет, зелёный
    // цвет врал бы (последний вердикт мог быть «ок» час назад).
    : (root.healthStale && !root.healthBusy) ? root.warn
    // Подбор стратегии — нейтральная активность, не ошибка: акцентный цвет,
    // а не warning. Так иконка не выглядит красной, пока autotune работает.
    : (root.verdict === "tuning" || root.zapTuning) ? Color.accent
    : (root.vtRunning || root.healthBusy) ? root.warn
    : root.verdict === "ok" ? root.okColor
    : (root.vpnOn ? root.okColor : root.dim)

  // «Всё хорошо и делать нечего»: только тогда тихая иконка гасит цвет.
  // Не гасит его тревога (ошибка статуса, идущая проверка/действие) и наличие
  // новых версий (upAny). А вот ошибки самих обновлений (upError: молчит
  // апдейтер, нет сети) бар НЕ красят — это не авария VPN, и подсвечивать их
  // в баре значило бы держать иконку цветной из-за недоступного GitHub.
  readonly property bool allCalm: root.verdict === "ok" && !root.upAny
    && !root.vtRunning && !root.zapTuning && !root.healthBusy
    && !root.healthStale
    && root.busy === "" && root.statusError === ""
  readonly property color healthColor:
    (root.quietBar && root.allCalm) ? root.dim : root.healthColorBase

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
    if (root.zapTuning || root.verdict === "tuning") return "подбор стратегии zapret"
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
    if (root.healthStale) {
      // «Идёт обновление» — только если оно правда идёт (healthBusy проверен
      // раньше); иначе честно говорим, когда была последняя проверка.
      var staleAt = root.healthChecked > 0
        ? Qt.formatTime(new Date(root.healthChecked * 1000), "HH:mm") : ""
      return "данные устарели" + (staleAt !== "" ? " · проверка была в " + staleAt : "")
    }
    return (root.vpnOn ? "VPN включён · " : "") + "всё работает"
  }

  readonly property string healthText: {
    // Мёртвый бэкенд важнее любого кэша: иначе в баре висит зелёное «всё работает».
    if (root.statusError !== "") return "нет данных: " + root.statusError
    if (root.healthBusy) return "идёт проверка · " + root.healthElapsed + " с"
    if (root.vtRunning) return "идёт подбор серверов"
    if (root.zapTuning || root.verdict === "tuning") return "идёт подбор стратегии zapret"
    if (!root.hl.checked) return root.vpnOn ? "VPN подключён, проверка не запускалась" : "VPN выключен"
    if (root.healthStale) {
      // Зелёное «всё работает» из старого кэша — ложь: честно говорим, когда
      // проверяли в последний раз.
      var at = root.healthChecked > 0
        ? Qt.formatTime(new Date(root.healthChecked * 1000), "HH:mm") : ""
      return "данные устарели" + (at !== "" ? " · проверка была в " + at : "")
    }
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
    // Последняя ошибка CLI: settings.json читается криво, конфиг битый — без
    // этого поля панель молчала, хотя бэкенд всё знает.
    var bad = String(v.settings_error || v.error || "")
    if (!v.running) {
      if (v.installed === false) return "не установлен"
      // running=false при живом процессе — это поломка, а не выключение:
      // трафик уходит в мёртвый socks.
      if (v.xray_alive || v.sbox_alive) {
        var alive = []
        if (v.xray_alive) alive.push("xray")
        if (v.sbox_alive) alive.push("sing-box")
        var split = "процессы разъехались: " + alive.join(" и ")
          + (alive.length > 1 ? " живы" : " жив") + ", туннеля нет · "
          + (v.profile || "профиль не выбран")
        return bad !== "" ? split + " · " + bad : split
      }
      var off = "выключен · " + ((v.profile || "профиль не выбран"))
        + ((v.node && v.node !== "auto") ? " · " + v.node : "")
      return bad !== "" ? off + " · " + bad : off
    }
    var on = (v.profile || "") + " · " + (v.mode === "tun" ? "TUN" : "SOCKS")
      + " · " + ((v.node && v.node !== "auto") ? v.node : "авто")
      + " · " + root.fmtUptime(v.uptime)
    return bad !== "" ? on + " · " + bad : on
  }

  // ---- обновления и журнал (omavpn-updater) --------------------------------
  // Отдельный инструмент: проверка раз в сутки (его собственный кэш), в виджете
  // — только чтение снимка раз в 5 минут. Без подтверждения ничего не ставит.
  readonly property string updaterPath: Quickshell.env("HOME") + "/.local/bin/omavpn-updater"
  property var up: ({})
  property bool upLoaded: false
  property bool stateAwait: false
  // Мягкая ошибка раздела обновлений. Отдельная от statusError: молчащий
  // апдейтер или отсутствие сети не должны выглядеть как «нет данных» о VPN.
  property string upError: ""
  // Скачивание апдейтера — ровно одна попытка за сессию: иначе при пустой
  // сети он лез бы за ним на каждом тике.
  property bool updaterFetching: false
  property real upChecked: 0
  // Очередь записей журнала: --note пишется по одной строке за процесс.
  property var noteQueue: []
  // Тихий уведомлятор об обновлениях: одно сообщение в сутки, без спама.
  property real upNotifiedAt: 0

  readonly property var upUpdates: (root.up && root.up.updates) ? root.up.updates : ({})

  // Состояние guard из снимка апдейтера: "active" / "inactive" / "unknown".
  // Нет снимка (апдейтер недоступен) — считаем guard активным: иначе виджет
  // начнёт лечить туннель параллельно guard, и они будут перезапускать VPN
  // друг у друга. Ложная «активность» тут безопаснее ложной «выключенности».
  readonly property string guardTimerState: String((root.up.guard || {}).timer || "unknown")
  readonly property bool guardKnown:
    root.guardTimerState === "active" || root.guardTimerState === "inactive"
  readonly property bool guardActive: root.guardKnown ? root.guardTimerState === "active" : true
  // Аудит маршрутов: аудит рвёт трафик, поэтому без данных автоаудит не
  // запускаем — только известное "inactive" разрешает.
  readonly property string auditTimerState: String((root.up.guard || {}).route_audit || "unknown")
  readonly property bool auditTimerActive: root.auditTimerState !== "inactive"
  // Питание неизвестно (нет up.power) — ведём себя как на батарее: автоподбор
  // и автоаудит не гоняем, проверяем реже. Это дешевле, чем будить туннель.
  readonly property bool powerKnown:
    !!root.up && !!root.up.power && typeof root.up.power === "object"
  readonly property bool onBattery: root.powerKnown ? (root.up.power.on_battery === true) : true

  // Фолбэк на снимок статуса: если апдейтера нет (виджет новее CLI) или он
  // молчит, но bypass-status уже проверял zapret/tg-ws-proxy, показываем хотя
  // бы эти строки — иначе раздел пуст, хотя данные есть.
  readonly property var bsUpdates: {
    var u = root.bs ? root.bs.updates : null
    return (u && typeof u === "object") ? u : ({})
  }
  readonly property real bsUpdatesChecked: Number(root.bsUpdates.checked || 0)
  readonly property bool upFallbackActive:
    root.bsUpdatesChecked > 0 && (!root.upLoaded || root.upError !== "")
  readonly property var updFallbackItems: {
    var out = []
    if (!root.upFallbackActive) return out
    var u = root.bsUpdates
    var comp = [["zapret", "zapret"], ["tgwsproxy", "tg-ws-proxy"]]
    for (var i = 0; i < comp.length; i++) {
      var p = u[comp[i][0]]
      if (!p || !p.update) continue
      out.push({ name: comp[i][1],
                 text: comp[i][1] + " " + (p.installed || "?") + " → " + (p.latest || "?") })
    }
    return out
  }

  // Строки обновлений: по одной на компонент, у которого есть новая версия.
  readonly property var updItems: {
    var u = root.upUpdates
    var out = []
    if (u && typeof u === "object") {
      var w = u.widget
      if (w && w.update)
        out.push({ name: "Виджет", text: "Виджет " + (w.installed || "?") + " → " + (w.latest || "?") })
      var core = [["xray", "Xray"], ["singbox", "sing-box"]]
      for (var i = 0; i < core.length; i++) {
        var c = u[core[i][0]]
        if (!c || !c.update) continue
        // Ядро ставим до проверенной версии из install.sh; последний релиз —
        // только справка, иначе человек ждёт версию, которую мы не ставим.
        var t = core[i][1] + " " + (c.installed || "?") + " → проверенная " + (c.pinned || "?")
        if (c.latest && c.latest !== c.pinned) t += " · в апстриме " + c.latest
        out.push({ name: core[i][1], text: t })
      }
      var comp = [["zapret", "zapret"], ["tgwsproxy", "tg-ws-proxy"]]
      for (var j = 0; j < comp.length; j++) {
        var p = u[comp[j][0]]
        if (!p || !p.update) continue
        out.push({ name: comp[j][1],
                   text: comp[j][1] + " " + (p.installed || "?") + " → " + (p.latest || "?") })
      }
    }
    if (out.length === 0 && root.upFallbackActive) return root.updFallbackItems
    return out
  }
  readonly property bool upAny: root.updItems.length > 0
  // Строка «нет обновлений / нет данных»: три разных состояния, один текст.
  readonly property string upStatusText: {
    if (root.upFallbackActive) {
      var bsAt = Qt.formatTime(new Date(root.bsUpdatesChecked * 1000), "HH:mm")
      return "проверено " + bsAt + " (по данным статуса)"
        + (root.upError !== "" ? " · " + root.upError : "")
    }
    if (root.upError !== "") return root.upError
    if (!root.upLoaded) return "обновления: проверяю…"
    var at = root.upChecked > 0 ? Qt.formatTime(new Date(root.upChecked * 1000), "HH:mm") : ""
    return "всё актуально" + (at !== "" ? " · проверено " + at : "")
  }
  // Что именно обновится — прямо в диалоге подтверждения, а не «обновить всё?».
  readonly property string updateAllMessage: {
    var names = []
    for (var i = 0; i < root.updItems.length; i++) names.push(root.updItems[i].name)
    var lines = ["Обновить всё?"]
    if (names.length > 0) lines.push("Новое: " + names.join(", ") + ".")
    lines.push("Если нужно ядро (Xray, sing-box), откроется терминал — понадобится пароль (pkexec): "
      + "установщик обновит не только ядро, но и CLI, скрипты и виджет, "
      + "а после него оболочка перезапустится сама.")
    if (root.upUpdates.widget && root.upUpdates.widget.update)
      lines.push("Виджет подменится с бэкапом; без терминала оболочка перезапустится через 4 секунды.")
    return lines.join("\n")
  }

  // Последние 5 записей журнала — новые сверху, только за последние 2 часа.
  // Бэкенд уже чистит файл и отдаёт свежее, но панель не должна показывать
  // вчерашнее, если файл успел накопить старое до обновления. Окно считаем от
  // наблюдаемого `root.nowSec` (тик при открытой панели), иначе привязка не
  // пересчитывалась бы между обновлениями `root.up` (раз в 5 минут) и после
  // сбоя updater показывала бы записи старше двух часов. Панель закрыта — список
  // не виден; при открытии тик подставит свежее время и всё пересчитает.
  readonly property var upActions: {
    var a = (root.up && root.up.actions instanceof Array) ? root.up.actions : []
    var now = root.nowSec > 0 ? root.nowSec : Date.now() / 1000
    var cutoff = now - 7200
    var out = []
    for (var i = a.length - 1; i >= 0 && out.length < 5; i--) {
      var it = a[i]
      if (!it || !it.text) continue
      var ts = Number(it.ts)
      // Без валидного ts запись не фильтруется по времени — не показываем.
      if (!(ts > 0) || ts < cutoff) continue
      out.push({
        when: Qt.formatTime(new Date(ts * 1000), "HH:mm"),
        text: String(it.text),
        kind: String(it.kind || "")
      })
    }
    return out
  }

  // ---- действия ------------------------------------------------------------
  function refreshStatus() {
    if (statusProc.running) return
    root.statusAwait = true
    statusProc.running = true
  }
  function refreshVpn() {
    if (vpnProc.running) return
    root.vpnAwait = true
    vpnProc.running = true
  }

  // ---- экран настроек -------------------------------------------------------
  // Переключение экранов сбрасывает прокрутку: иначе «Настройки» открывались бы
  // на середине, где остался contentY основной панели.
  function openSettings() {
    root.settingsOpen = true
    root.keyIndex = -1
    root.routeError = ""
    root.rfError = ""
    root.rfActionError = false
    root.subError = ""
    root.resetError = ""
    panelFlick.contentY = 0
    root.refreshRoutes()
    // Список Re:filter и URL подписки нужны только здесь, поэтому читаем их при
    // открытии настроек, а не в общем четырёхсекундном опросе.
    root.refreshRefilter()
    root.refreshSubscription()
  }
  function closeSettings() {
    root.settingsOpen = false
    root.keyIndex = -1
    root.routeError = ""
    root.rfError = ""
    root.rfActionError = false
    root.subError = ""
    root.resetError = ""
    panelFlick.contentY = 0
  }

  // ---- маршруты сайтов ------------------------------------------------------
  function refreshRoutes() {
    if (root.cliPath === "") return
    if (routeListProc.running) { root.routeListDirty = true; return }
    // Команду ставим явно: привязка к cliPath в момент onCliPathChanged ещё не
    // пересчитана, и Process с пустым argv уходил в FailedToStart.
    routeListProc.command = [root.cliPath, "--json", "route", "list"]
    root.routeListAwait = true
    routeListProc.running = true
  }
  // Одно место для set и unset: busy="route" гасит кнопки, а команда собирается
  // здесь же, чтобы набор аргументов не разъезжался между вызовами.
  function changeRoute(action, domain, path) {
    if (root.cliPath === "" || root.busy !== "" || root.healthBusy || root.vtRunning) return false
    root.routeError = ""
    root.busy = "route"
    routeChangeProc.action = action
    routeChangeProc.command = action === "unset"
      ? [root.cliPath, "--json", "route", "unset", domain]
      : [root.cliPath, "--json", "route", "set", domain, path, "--reason", "виджет: настройки"]
    routeChangeProc.running = true
    return true
  }
  // Ввод принимает и домен, и ссылку из браузера — разбирает бэкенд.
  function addRoute() {
    var text = String(routeInput.text || "").trim()
    if (text === "") return
    root.changeRoute("set", text, root.routePath)
  }
  function confirmUnsetRoute(domain) {
    root.askConfirm("route-unset:" + domain,
      "Снять правило для " + domain + "? VPN перезапустится на несколько секунд.")
  }

  // ---- Re:filter ------------------------------------------------------------
  // «Свободно ли управление»: те же условия, что у остальных действий, плюс свои
  // флаги — иначе сброс и «Обновить список» пошли бы одновременно.
  // «6 минут» / «2 минуты» / «1 минуту» — по числу, без расхождений с таймером.
  function timeoutText(ms) {
    var mins = Math.max(1, Math.round(Number(ms) / 60000))
    var word = "минут"
    var tail = mins % 100
    if (tail < 11 || tail > 14) {
      var last = mins % 10
      if (last === 1) word = "минуту"
      else if (last >= 2 && last <= 4) word = "минуты"
    }
    return "за " + mins + " " + word
  }
  function refilterFree() {
    return root.cliPath !== "" && !root.sideBusy
      && root.busy === "" && !root.healthBusy && !root.vtRunning && !root.tunnelBusy
  }
  function refreshRefilter() {
    if (root.cliPath === "" || rfStatusProc.running) return
    // Команду ставим явно: привязка к cliPath в первый момент ещё пустая.
    rfStatusProc.command = [root.cliPath, "--json", "refilter", "status"]
    root.rfAwait = true
    rfStatusProc.running = true
  }
  // on / off / update — один процесс: набор аргументов собирается здесь же.
  function refilterAction(action) {
    if (!root.refilterFree()) return false
    root.rfError = ""
    root.rfActionError = false
    root.rfBusy = true
    rfActionProc.action = action
    rfActionProc.command = [root.cliPath, "--json", "refilter", action]
    rfActionProc.running = true
    return true
  }
  function refilterToggle() {
    root.refilterAction(root.rfEnabled ? "off" : "on")
  }

  // ---- подписка -------------------------------------------------------------
  // quiet=true — только перечитать фактический URL, не трогая текст ошибки
  // (после неудачного сохранения ошибка должна остаться на экране).
  function refreshSubscription(quiet) {
    if (root.cliPath === "" || subGetProc.running) return
    subGetProc.command = [root.cliPath, "--json", "subscription", "get"]
    root.subQuiet = quiet === true
    root.subAwait = true
    subGetProc.running = true
  }
  function applySubUrl(url) {
    root.subUrl = String(url || "")
    // Начатый ввод не затираем: ответ мог прийти, пока человек печатал.
    if (!root.subDirty) subInput.text = root.subUrl
  }
  function subscriptionSave() {
    if (!root.refilterFree()) return false
    var url = String(subInput.text || "").trim()
    if (url === "") { root.subError = "введите URL подписки"; return false }
    root.subError = ""
    root.subBusy = true
    subSetProc.command = [root.cliPath, "--json", "subscription", "set", url]
    subSetProc.running = true
    return true
  }

  // ---- полный сброс ---------------------------------------------------------
  // Специально не ждём «свободно»: сброс запускают именно тогда, когда всё
  // зависло и обычные действия не отвечают. Защищает только собственный флаг.
  function runReset() {
    if (root.cliPath === "" || root.resetBusy) return false
    root.resetError = ""
    root.resetBusy = true
    resetProc.command = [root.cliPath, "--json", "reset"]
    resetProc.running = true
    return true
  }

  function run(args, label) {
    // sideBusy: пока идёт обновление списков Re:filter, смена подписки или
    // сброс, туннель и ctrl.lock заняты — иначе действие вернёт ложное
    // «другой процесс управляет VPN».
    if (actionProc.running || root.cliPath === "" || root.busy !== ""
        || root.sideBusy) return false
    root.opError = ""
    root.busy = label || "…"
    actionProc.command = [root.cliPath, "--json"].concat(args)
    actionProc.running = true
    return true
  }

  // heal=false — только чтение (--health-json). Лечение VPN запускается кнопкой
  // «Проверить всё» либо самим виджетом при плохом результате (auto=true).
  // Пока идёт подбор серверов или другое действие, проверку не начинаем:
  // heal перезапускает туннель и испортит результаты подбора.
  function startHealth(heal, auto) {
    if (healthProc.running || root.vtRunning || root.busy !== "" || root.sideBusy)
      return false
    root.healthAuto = auto === true
    // Лечение пробовали (кнопкой или сами): это условие автоподбора сервера.
    if (heal) root.healTried = true
    root.healthRunning = heal ? "heal" : "quick"
    root.healthStartedAt = Date.now() / 1000
    healthProc.command = [root.scriptPath, heal ? "--health" : "--health-json"]
    healthProc.running = true
    return true
  }

  // Сторож: Process без таймаута при зависании оставлял флаг занятым навсегда.
  // Метка ставится конкретному процессу и снимается только его собственным
  // onExited — соседние сторожа друг другу не мешают.
  function killProc(which) {
    var t = {}
    for (var k in root.timeouts) t[k] = true
    t[which] = true
    root.timeouts = t
    if (which === "status") statusProc.running = false
    else if (which === "vpn") vpnProc.running = false
    else if (which === "health") healthProc.running = false
    else if (which === "audit") auditProc.running = false
    else if (which === "optimize") optimizeProc.running = false
    else if (which === "rescan") rescanProc.running = false
    else if (which === "state") stateProc.running = false
    else if (which === "upall") updateAllProc.running = false
    else if (which === "note") noteProc.running = false
    else if (which === "action") actionProc.running = false
    else if (which === "route") routeChangeProc.running = false
    else if (which === "route-list") routeListProc.running = false
    else if (which === "refilter") rfStatusProc.running = false
    else if (which === "refilter-act") rfActionProc.running = false
    else if (which === "sub") subGetProc.running = false
    else if (which === "sub-set") subSetProc.running = false
    else if (which === "reset") resetProc.running = false
  }

  // Забрать метку «не ответил» у своего процесса (и только у него).
  function takeTimeout(which) {
    if (root.timeouts[which] !== true) return false
    var t = {}
    for (var k in root.timeouts) if (k !== which) t[k] = true
    root.timeouts = t
    return true
  }

  // Пора ли перезапустить проверку: результата нет или он старше sec секунд.
  // Считаем по отметке checked, а не по age: в свежем ответе --health-json поля
  // age нет вовсе (его добавляет только чтение кэша), из-за чего прежнее условие
  // «hl.age > 600» не срабатывало никогда.
  function healthDue(sec) {
    if (!(root.healthChecked > 0)) return true
    return (Date.now() / 1000 - root.healthChecked) > (sec || 600)
  }

  // Порог «пора перепроверить». Под guard проверки реже: восстановлением
  // занимается он, а лишние опросы только шумят и греют сеть.
  function healthMaxAge() {
    if (!root.guardActive) return 600
    return root.onBattery ? 1200 : 900
  }

  // Смена сети по ключу из снимка. Ключ может мигнуть (каскад источников в
  // net_key: iwgetid → nmcli → MAC шлюза), поэтому верим только второму подряд
  // снимку с новым ключом и не дёргаем проверку чаще раза в минуту.
  function noteNetwork(net) {
    if (net === "") return
    // Первый снимок задаёт базу и ничего не запускает.
    if (root.netSeen === "") { root.netSeen = net; root.netCandidate = ""; return }
    if (net === root.netSeen) { root.netCandidate = ""; return }
    if (net !== root.netCandidate) { root.netCandidate = net; return }
    // Новый ключ пришёл два раза подряд — это смена, а не мигание. Но если
    // предыдущую смену отработали только что, ждём: за минуту сеть успевает
    // переподключиться, и второй заход был бы лишним перезапуском проверки.
    var now = Date.now() / 1000
    if (now - root.netChangeAt < 60) return
    root.netChangeAt = now
    root.netSeen = net
    root.netCandidate = ""
    root.refreshVpn()
    if (!root.healthBusy && !root.vtRunning && root.busy === "" && root.scriptOk)
      root.startHealth(false)
  }

  function notify(title, body) {
    // Долгие операции идут минутами — человек успевает отойти от экрана.
    notifyProc.command = ["notify-send", "-a", "Обходы", title, body || ""]
    notifyProc.running = true
  }

  // ---- обновления: запуск, скачивание апдейтера, журнал --------------------
  function refreshUpdater() {
    if (stateProc.running) return
    root.stateAwait = true
    stateProc.running = true
  }

  // Апдейтера нет (виджет обновился раньше CLI) — скачиваем один раз.
  function fetchUpdater() {
    if (root.updaterFetching) return
    root.updaterFetching = true
    root.upError = "обновления: нет omavpn-updater — скачиваю"
    fetchProc.running = true
  }

  // Единственный запуск подбора: команда собирается здесь, чтобы ни один путь
  // не унаследовал флаг от предыдущего вызова. auto=true → --keep-profile
  // (регион не меняем), ручная кнопка — полный подбор.
  function startOptimize(auto) {
    if (root.vtRunning || optimizeProc.running || root.healthBusy
        || root.busy !== "" || root.sideBusy) return false
    root.opError = ""
    root.busy = "vtest"
    root.optimizeAuto = auto === true
    optimizeProc.command = auto === true
      ? [root.scriptPath, "--optimize", "--keep-profile"]
      : [root.scriptPath, "--optimize"]
    optimizeProc.running = true
    return true
  }

  function startUpdateAll() {
    if (root.busy !== "" || updateAllProc.running || root.healthBusy || root.vtRunning) return false
    root.busy = "upall"
    root.opError = ""
    root.notice = ""
    updateAllProc.running = true
    return true
  }

  // Запись в журнал действий: одна строка "kind|текст". Очередь на один
  // процесс — иначе вторая запись затирала команду первой и терялась.
  function logNote(kind, text) {
    var line = (kind || "note") + "|" + text
    var q = root.noteQueue.slice()
    q.push(line)
    if (noteProc.running) { root.noteQueue = q; return }
    root.noteQueue = q
    root.noteNext()
  }
  function noteNext() {
    if (noteProc.running || root.noteQueue.length === 0) return
    var q = root.noteQueue.slice()
    var line = q.shift()
    root.noteQueue = q
    noteProc.command = [root.updaterPath, "--note", line]
    noteProc.running = true
  }

  // Тихий уведомлятор: об обновлениях сообщаем не чаще раза в сутки.
  function maybeNotifyUpdates() {
    if (!root.upAny) return
    var now = Date.now() / 1000
    if (root.upNotifiedAt > 0 && (now - root.upNotifiedAt) < 86400) return
    root.upNotifiedAt = now
    var names = []
    for (var i = 0; i < root.updItems.length; i++) names.push(root.updItems[i].name)
    root.notify("Обходы: есть обновления", names.join(", "))
  }

  // Автоподбор сервера — фолбэк без guard: лечение уже пробовали, плохо две
  // проверки подряд. Туннель перезапускается, поэтому на батарее не трогаем.
  // Триггер — только пункт `vpn`: YouTube/Discord чинятся маршрутами и zapret,
  // и менять из-за них сервер (то есть рвать туннель) нельзя.
  function maybeAutoOptimize() {
    if (root.guardActive || root.onBattery) return
    if (!root.vpnOn || root.vpn.installed === false) return
    if (root.badStreak < 2 || !root.healTried) return
    if (root.hState("vpn", "") !== "bad") return
    if (root.busy !== "" || root.healthBusy || root.vtRunning || optimizeProc.running) return
    var now = Date.now() / 1000
    // Ноль — берём время прошлого подбора из кэша: сразу после ручного подбора
    // автоматический был бы лишним.
    var last = root.autoOptimizeAt > 0 ? root.autoOptimizeAt
      : Number(root.vt.finished || root.vt.updated || 0)
    if (last > 0 && (now - last) < 3600) return
    root.autoOptimizeAt = now
    // Автоподбор не меняет регион (его выбирает человек), только сервер.
    if (!root.startOptimize(true)) return
    root.logNote("auto", "плохо две проверки подряд — подбираю другой сервер")
  }

  // Автоаудит маршрутов — только если аудитом не занимается таймер guard.
  // Аудит рвёт трафик на минуту, поэтому: две плохие проверки подряд и
  // предупреждение человеку до запуска (уведомление, а не тихий разрыв).
  function maybeAutoAudit() {
    if (root.auditTimerActive || root.onBattery || !root.vpnOn) return
    if (root.busy !== "" || root.healthBusy || root.vtRunning || auditProc.running) return
    // Сломан сам туннель — его чинит лечение/подбор, а не маршруты: аудит лишь
    // перезапустил бы sing-box и не помог.
    if (root.hState("vpn", "") === "bad") return
    if (root.hState("youtube", "") !== "bad" && root.hState("discord", "") !== "bad") return
    if (root.badStreak < 2) return
    var now = Date.now() / 1000
    var last = root.autoAuditAt > 0 ? root.autoAuditAt : Number(root.ra.checked || 0)
    if (last > 0 && (now - last) < 1800) return
    root.autoAuditAt = now
    root.auditAuto = true
    root.busy = "audit"
    root.notify("Обходы: домены не отвечают",
      "проверяю маршруты (трафик прервётся на минуту)")
    auditProc.running = true
    root.logNote("auto", "домены не отвечают — запускаю аудит маршрутов")
  }

  function askConfirm(kind, message) {
    root.confirmKind = kind
    root.confirmMessage = message
    // Каждый новый диалог начинается на «Продолжить», но выбор переключается
    // Tab/стрелками — и Enter обязан его уважать.
    confirmDlg.selectedIndex = 1
    confirmDlg.opened = true
  }
  function cancelConfirm() {
    root.confirmKind = ""
    confirmDlg.opened = false
  }
  // Enter/Space в открытом диалоге: подтвердить выбранную кнопку, а не всегда
  // «Продолжить». Раньше подсветка не двигалась, и выбор был фикцией.
  function confirmAccept() {
    if (!confirmDlg.opened) return
    if (confirmDlg.selectedIndex === 0) root.cancelConfirm()
    else root.confirmRun()
  }
  function confirmToggle() {
    if (!confirmDlg.opened) return
    confirmDlg.selectedIndex = confirmDlg.selectedIndex === 0 ? 1 : 0
  }

  // Клавиатура без мыши: Tab ходит по кнопкам действий, Enter/Space нажимает
  // выбранную, стрелки прокручивают панель. В открытом диалоге те же клавиши
  // управляют подтверждением.
  property int keyIndex: -1
  // Единственный список кнопок обхода: и длина для Tab, и адресация для Enter.
  // Функция, а не property: при инициализации соседние id ещё могут быть null,
  // а к моменту нажатия клавиши они уже существуют.
  function actionButtons() {
    return [checkAllBtn, bestBtn, rescanBtn, auditBtn, updateBtn, updateAllBtn,
            mainHeader.gearButton, settingsHeader.backButton,
            routeDirectBtn, routeProxyBtn, routeAddBtn, routeInput,
            subInput, subSaveBtn, rfUpdateBtn, resetBtn]
  }
  // Эффективная видимость: у ребёнка скрытого Column собственный visible остаётся
  // true, поэтому проверяем всю цепочку родителей — иначе Tab заходил бы в
  // кнопки другого экрана.
  function isShown(item) {
    var o = item
    while (o) {
      if (o.visible === false) return false
      o = o.parent
    }
    return true
  }
  // Видимые кнопки в порядке keyIndex. keyTab/keyActivate ищут кнопку по её
  // собственному номеру, а не по позиции в массиве: номера идут с пропусками,
  // и подсветка не съезжает, когда часть кнопок скрыта.
  function keyButtons() {
    var all = root.actionButtons()
    var out = []
    for (var i = 0; i < all.length; i++) {
      var b = all[i]
      if (!b || b.keyIndex === undefined || b.keyIndex < 0) continue
      if (!root.isShown(b)) continue
      out.push(b)
    }
    // По возрастанию номера: Tab идёт в визуальном порядке, а не в порядке
    // объявления — кнопки маршрута стоят в форме раньше «Добавить».
    out.sort(function(a, b) { return a.keyIndex - b.keyIndex })
    return out
  }
  function keyTab(dir) {
    if (confirmDlg.opened) { root.confirmToggle(); return }
    var list = root.keyButtons()
    if (list.length === 0) { root.keyIndex = -1; return }
    var pos = -1
    for (var i = 0; i < list.length; i++) if (list[i].keyIndex === root.keyIndex) pos = i
    if (pos < 0) root.keyIndex = dir < 0 ? list[list.length - 1].keyIndex : list[0].keyIndex
    else root.keyIndex = list[(pos + dir + list.length) % list.length].keyIndex
  }
  function keyActivate() {
    if (confirmDlg.opened) { root.confirmAccept(); return }
    if (root.keyIndex < 0) return
    var list = root.keyButtons()
    for (var i = 0; i < list.length; i++) {
      if (list[i].keyIndex !== root.keyIndex) continue
      if (list[i] === routeInput) { routeInput.forceActiveFocus(); return }
      if (list[i] === subInput) { subInput.forceActiveFocus(); return }
      if (list[i].enabled) list[i].clicked()
      return
    }
  }
  function keyScroll(dx, dy) {
    if (confirmDlg.opened) {
      // В диалоге листаем выбор только влево/вправо: Up/Down не должны
      // переключать «Отмена/Продолжить» — ими листают панель под диалогом.
      if (dx !== 0) root.confirmToggle()
      return
    }
    if (dy === 0) return
    var maxY = Math.max(0, panelFlick.contentHeight - panelFlick.height)
    panelFlick.contentY = Math.max(0, Math.min(maxY, panelFlick.contentY + Style.space(48) * dy))
  }
  function confirmRun() {
    var kind = root.confirmKind
    root.cancelConfirm()
    // Диалог мог провисеть, пока состояние изменилось (началась проверка или
    // подбор). Молча закрыть его — худший вариант: человек нажал «Продолжить»
    // и не понял, почему ничего не произошло.
    function refuse() {
      root.notice = "сейчас занято — дождись окончания"
      noticeTimer.restart()
    }
    var blocked = root.busy !== "" || root.healthBusy || root.vtRunning
    // Сброс стоит первым: он специально игнорирует занятость — его запускают,
    // когда всё зависло именно поэтому.
    if (kind === "reset") {
      if (root.resetBusy) { refuse(); return }
      if (!root.runReset()) root.notice = "omavpn не найден — сброс недоступен"
      return
    }
    // Снятие правила: префикс разбираем до остальных ветвей, занятость учитываем
    // ту же — route set/unset поднимает туннель заново.
    if (kind.indexOf("route-unset:") === 0) {
      if (blocked || routeChangeProc.running) { refuse(); return }
      root.changeRoute("unset", kind.slice("route-unset:".length), "")
      return
    }
    if (kind === "audit") {
      // Идущая health-проверка тоже трогает маршруты: перекрывать их нельзя,
      // иначе результаты обеих проверок будут мусорными. Пока идёт подбор
      // серверов (vtRunning) туннель тоже занят.
      if (auditProc.running || blocked) { refuse(); return }
      root.opError = ""
      root.busy = "audit"
      auditProc.running = true
    } else if (kind === "update") {
      if (blocked) { refuse(); return }
      root.run(["update"], "update")
    } else if (kind === "updateall") {
      if (blocked) { refuse(); return }
      root.startUpdateAll()
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
    // Автоподключение — ровно один раз за сессию и только на первом валидном
    // снимке. Раньше флаг ставился лишь в ветке «VPN выключен»: если VPN был
    // поднят к моменту старта, флаг оставался false, и после ручного
    // выключения виджет тут же включал VPN обратно.
    var v = root.vpn
    if (root.autoTried || !root.autoconnect) return
    if (!v || v.installed === false || root.cliPath === "") return
    root.autoTried = true
    if (v.running) return
    root.autoAttempts = 1
    root.autoRetryWakes = 0
    if (!root.run(["on"], "auto")) {
      // Действие уже занято — не сбрасываем «одно подключение за сессию», а
      // откладываем повтор. Сброс флага означал бы новую попытку на каждом
      // тике статуса: uptime в снимке меняется каждые 4 с, и `omavpn on`
      // запускался бы заново без конца.
      autoRetryTimer.restart()
    }
  }

  onOpenedChanged: {
    // Панель закрыли, не ответив на подтверждение, — диалог не должен ждать
    // следующего открытия (иначе Enter случайно подтвердит старое действие).
    if (!opened) {
      if (confirmDlg.opened) root.cancelConfirm()
      // Панель закрыли из настроек — следующее открытие начинается с основной
      // и сверху: иначе основная панель открылась бы на прокрутке настроек.
      root.settingsOpen = false
      root.routeError = ""
      root.keyIndex = -1
      panelFlick.contentY = 0
      return
    }
    // Клавиатурный курсор не переносим между открытиями: иначе первый же Enter
    // после открытия мышью нажимал кнопку, которую человек не выбирал.
    root.keyIndex = -1
    root.refreshStatus()
    // Открытие панели — повод перечитать и обновления: снимок --state-json
    // дешёвый (systemctl + чтение кэша), сеть он не трогает.
    root.refreshUpdater()
    if (!root.vpnLoaded || (Date.now() / 1000 - (root.vpnInfo.updated || 0)) > 120)
      root.refreshVpn()
    // Открытие панели — это не повод лечить VPN и не повод занимать busy:
    // только чтение готового health.json, лечение — по кнопке. Перезапускаем
    // проверку, если результата нет или он старше 10 минут (по отметке checked).
    if (!root.healthBusy && root.healthDue(root.healthMaxAge())) root.startHealth(false)
  }

  // Настройки могли открыть раньше первого снимка --json: тогда cliPath ещё
  // пуст и список правил не читался вовсе. Догружаем, как только путь появился.
  onCliPathChanged: {
    if (root.settingsOpen && !root.routeLoaded && root.cliPath !== "") root.refreshRoutes()
    // То же для Re:filter и подписки: настройки могли открыть до первого снимка.
    if (root.settingsOpen && root.cliPath !== "") {
      if (!root.rfLoadedOnce) root.refreshRefilter()
      if (!root.subLoaded) root.refreshSubscription()
    }
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function vpn(): string {
      if (root.tunnelBusy || root.busy !== "") return "busy"
      return root.run(["toggle"], "vpn") ? "ok" : "busy"
    }
    function health(): string { return root.startHealth(false) ? "ok" : "busy" }
    function heal(): string { return root.startHealth(true) ? "ok" : "busy" }
    function audit(): string {
      if (auditProc.running || root.busy !== "" || root.healthBusy || root.vtRunning) return "busy"
      root.opError = ""
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
    // Индекс в клавиатурном обходе (Tab/Enter) — подсвечиваем выбранную кнопку.
    // У кнопок без индекса (-1) подсветки нет: иначе сравнение -1 === -1
    // рисовало бы «Включить/Выключить» вечно наведённой.
    property int keyIndex: -1
    bordered: true
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    hasCursor: keyIndex >= 0 && root.keyIndex === keyIndex
    opacity: enabled ? 1 : 0.5
  }

  // Маленькая кнопка-глиф без рамки — шестерёнка в шапке. У Ui/Button нет
  // своего keyIndex, а клавиатурный обход ищет именно его, поэтому добавляем.
  component IconButton: Button {
    property int keyIndex: -1
    foreground: root.foreground
    fontFamily: root.fontFamily
    fontSize: Style.font.bodySmall
    iconSize: Style.font.subtitle
    horizontalPadding: Style.space(6)
    verticalPadding: Style.space(2)
    hasCursor: keyIndex >= 0 && root.keyIndex === keyIndex
    opacity: enabled ? 1 : 0.5
  }

  // ---- процесс опроса статуса ---------------------------------------------
  Process {
    id: statusProc
    command: [root.scriptPath, "--json"]
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    // FailedToStart (нет файла, нет прав) не эмитит exited — только
    // runningChanged. Флаг «ждём ответ» снимаем здесь, иначе панель навсегда
    // считала бы, что снимок в пути. В обычном пути onExited успевает раньше
    // (в quickshell exited идёт до runningChanged), и метка уже false.
    onRunningChanged: {
      if (running || !root.statusAwait) return
      root.statusAwait = false
      root.statusError = root.startErrorText
    }
    onExited: function(code) {
      root.statusAwait = false
      if (root.takeTimeout("status")) {
        root.statusError = "статус не ответил за 60 с — данные могли устареть"
        return
      }
      if (code !== 0) {
        root.statusError = "статус не получен (код " + code + ")"
        return
      }
      var d = null
      try { d = JSON.parse(statusOut.text) } catch (e) { d = null }
      if (!d || typeof d !== "object") {
        root.statusError = "статус: битый ответ"
        return
      }
      if (d.ok !== true) {
        root.statusError = "статус: " + (d.error || "сервис вернул ошибку")
        return
      }
      root.statusError = ""
      root.statusAt = Date.now() / 1000
      var merged = root.mergeSections(root.bs, d)
      if (merged !== root.bs) root.bs = merged
      // Сменилась сеть (Wi-Fi → кабель, дача → дом) — стратегии и маршруты
      // могли стать неактуальны. Перепроверяем обходы, не дожидаясь
      // пятиминутного таймера, но только по подтверждённой смене ключа.
      root.noteNetwork(root.zap.network || "")
    }
  }

  Process {
    id: vpnProc
    command: [root.scriptPath, "--vpn"]
    stdout: StdioCollector { id: vpnOut; waitForEnd: true }
    onRunningChanged: {
      if (running || !root.vpnAwait) return
      root.vpnAwait = false
      root.vpnError = "список серверов: " + root.startErrorText
    }
    onExited: function(code) {
      root.vpnAwait = false
      if (root.takeTimeout("vpn")) {
        root.vpnError = "список серверов не получен за 60 с"
        return
      }
      if (code !== 0) {
        root.vpnError = "список серверов не получен (код " + code + ")"
        return
      }
      var d = null
      try { d = JSON.parse(vpnOut.text) } catch (e) { d = null }
      if (!d || typeof d !== "object") {
        root.vpnError = "список серверов: битый ответ"
        return
      }
      if (d.ok === false) {
        root.vpnError = "список серверов: " + (d.error || "ошибка")
        return
      }
      root.vpnError = ""
      root.vpnInfo = d
      root.vpnLoaded = true
    }
  }

  // Комплексный тест конфигурации: страница/видео YouTube, Discord, DeepSeek,
  // Telegram, tg-ws-proxy, zapret и реальный выход VPN. Раз в 5 минут —
  // без лечения (--health-json); с лечением — по кнопке «Проверить всё» или
  // автоматически, если проверка нашла поломку при включённом VPN.
  Process {
    id: healthProc
    command: [root.scriptPath, "--health-json"]
    stdout: StdioCollector { id: healthOut; waitForEnd: true }
    // Не запустился — exited не придёт, флаг «идёт проверка · N с» снимаем тут,
    // иначе он висел бы до перезапуска оболочки и глушил healthTimer.
    onRunningChanged: {
      if (running || root.healthRunning === "") return
      root.healthRunning = ""
      // Режим «авто» тоже сбрасываем: процесс не стартовал, значит следующее
      // лечение не должно считаться автоматическим и молчать об уведомлении.
      root.healthAuto = false
      root.opError = "проверка не выполнена: " + root.startErrorText
    }
    onExited: function(code) {
      var was = root.healthRunning
      var auto = root.healthAuto
      root.healthRunning = ""
      root.healthAuto = false
      var timedOut = root.takeTimeout("health")
      if (timedOut) {
        root.opError = "проверка не ответила за 9 минут — прервана"
      } else if (code !== 0) {
        root.opError = "проверка завершилась ошибкой (код " + code + ")"
      } else {
        var d = null
        try { d = JSON.parse(healthOut.text) } catch (e) { d = null }
        if (d && d.reason === "already_running") {
          // run_health при занятом локе отдаёт {ok:false, reason:"already_running"}
          // без items — это не «непонятный ответ», а «кто-то уже проверяет».
          root.opError = "проверка уже идёт — дождись её окончания"
        } else if (!d || !(d.items instanceof Array)) {
          root.opError = "проверка: непонятный ответ"
        } else {
          root.health = d
          root.opError = d.error ? ("проверка прервалась: " + d.error) : ""
          var h = d.heal || {}
          if (h.skipped) {
            // «лечили недавно» — тоже результат: раньше он терялся молча.
            root.notice = "VPN: " + h.skipped
            noticeTimer.restart()
            // Бэкенд сказал, сколько ещё ждать (heal_allowed). Сдвигаем свою
            // отметку так, чтобы следующая попытка была не раньше его кулдауна:
            // лечить может и omavpn-guard, наш autoHealAt об этом не знает.
            var wait = Number(h.wait || 0)
            if (wait > 0) {
              var until = Date.now() / 1000 + wait - root.autoHealGap
              if (until > root.autoHealAt) root.autoHealAt = until
            }
          }
          if (h.actions && h.actions.length > 0) {
            root.notice = "VPN: " + h.actions.join("; ")
            noticeTimer.restart()
          }
          // Серия плохих проверок ИМЕННО по VPN: общий verdict "bad" бывает и
          // из-за YouTube/Discord/DeepSeek/zapret, и раньше любая такая проверка
          // крутила badStreak, а тот запускал лечение и смену сервера — то есть
          // перезапуск здорового туннеля по чужой проблеме. Берём пункт `vpn`
          // прямо из ответа, а не через root.hState(): порядок обновления
          // привязок тут не важен.
          var vpnBad = false
          var hItems = d.items || []
          for (var vi = 0; vi < hItems.length; vi++)
            if (hItems[vi] && hItems[vi].id === "vpn") vpnBad = hItems[vi].state === "bad"
          root.badStreak = vpnBad ? root.badStreak + 1 : 0
          if (was === "heal") {
            // Лечение могло переключить профиль/сервер — список серверов устарел.
            root.refreshVpn()
            // Автоматическое лечение не должно дёргать человека уведомлением:
            // философия виджета — он работает незаметно.
            if (!auto) root.notify("Обходы: проверка", d.summary || "готово")
          } else {
            // Плохо при включённом VPN — повод что-то делать; хорошо — сброс серии.
            // Туннель (лечение/подбор сервера) трогаем только при плохом пункте
            // `vpn`; не-VPN проблемы лечатся аудитом маршрутов и zapret.
            if (vpnBad && root.vpnOn && root.vpn.installed !== false) {
              if (root.guardActive) {
                // Единый лечащий контур: туннель восстанавливает guard, виджет
                // только показывает результат. Своё лечение здесь означало бы
                // два перезапуска VPN подряд — они мешают друг другу.
                root.maybeAutoOptimize()
              } else if ((Date.now() / 1000 - root.autoHealAt) > root.autoHealGap) {
                // Фолбэк без guard: лечим сами, без нажатий. Порог равен
                // HEAL_MIN_GAP бэкенда: при меньшем каждые 15 минут уходил полный
                // --health, который тут же получал heal.skipped.
                root.autoHealAt = Date.now() / 1000
                root.logNote("auto", "плохо при выключенном guard — лечу VPN")
                Qt.callLater(function() { root.startHealth(true, true) })
              } else {
                // Лечение уже пробовали и не помогло — дальше имеет смысл менять
                // сервер, а не повторять то же лечение.
                root.maybeAutoOptimize()
              }
            }
            Qt.callLater(function() { root.maybeAutoAudit() })
          }
        }
      }
      root.refreshStatus()
    }
  }

  Process {
    id: rescanProc
    command: [root.scriptPath, "--rescan-request"]
    stdout: StdioCollector { id: rescanOut; waitForEnd: true }
    onRunningChanged: {
      if (running || root.busy !== "rescan") return
      root.busy = ""
      root.opError = "тест стратегий не выполнен: " + root.startErrorText
    }
    onExited: function(code) {
      var timedOut = root.takeTimeout("rescan")
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
    // Команду всегда ставит startOptimize(): статическая привязка была мёртвой
    // и могла передать чужой флаг от предыдущего вызова.
    stdout: StdioCollector { id: optimizeOut; waitForEnd: true }
    onRunningChanged: {
      if (running || root.busy !== "vtest") return
      root.busy = ""
      root.opError = "подбор не выполнен: " + root.startErrorText
    }
    onExited: function(code) {
      var timedOut = root.takeTimeout("optimize")
      var auto = root.optimizeAuto
      root.optimizeAuto = false
      root.busy = ""
      var msg = timedOut ? "подбор не ответил за 4 минуты — прерван" : "не удалось запустить подбор"
      var failed = timedOut || code !== 0
      if (code === 0 && !timedOut) {
        try {
          var d = JSON.parse(optimizeOut.text)
          if (d && d.message) msg = d.message
          else if (d && d.error) msg = d.error
          if (d && d.error) failed = true
        } catch (e) { /* пустой вывод */ }
      }
      root.notice = msg
      noticeTimer.restart()
      // Автоматический подбор работает незаметно: уведомление только о неудаче.
      if (!auto || failed) root.notify("Обходы: подбор", msg)
      if (auto) root.logNote("auto", failed ? ("подбор не удался: " + msg) : ("подобрал сервер: " + msg))
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
    onRunningChanged: {
      if (running || root.busy !== "audit") return
      root.busy = ""
      root.opError = "аудит маршрутов не выполнен: " + root.startErrorText
    }
    onExited: function(code) {
      var timedOut = root.takeTimeout("audit")
      var auto = root.auditAuto
      root.auditAuto = false
      root.busy = ""
      var msg = timedOut ? "аудит маршрутов не ответил за 20 минут" : "не удалось проверить маршруты"
      var failed = timedOut || code !== 0
      var d = null
      try { d = JSON.parse(auditOut.text) } catch (e) { d = null }
      if (!timedOut && code === 0 && d) {
        if (d.reason === "already_running") msg = "аудит маршрутов уже идёт"
        else if (d.reason === "lock_error") msg = "уже идёт проверка — лок занят"
        else if (d.verdict === "error") msg = "аудит не выполнился: " + (d.error || d.summary || "неизвестная ошибка")
        else if (d.summary) msg = d.summary
        if (d.verdict === "error" || d.reason === "already_running" || d.reason === "lock_error")
          failed = true
      } else if (!timedOut) {
        root.opError = "аудит маршрутов завершился ошибкой (код " + code + ")"
      }
      root.notice = msg
      noticeTimer.restart()
      // Автоматический аудит молчит об успехе: он и должен работать незаметно.
      if (!auto || failed) root.notify("Обходы: маршруты", msg)
      if (auto) root.logNote("auto", failed ? ("аудит не удался: " + msg) : ("аудит: " + msg))
      root.refreshStatus()
    }
  }

  // ---- обновления (omavpn-updater) -----------------------------------------
  // Снимок: обновления (кэш 24 ч), guard, питание и журнал действий. Ничего не
  // меняет, поэтому спрашивать можно и раз в 5 минут, и при открытии панели.
  Process {
    id: stateProc
    command: [root.updaterPath, "--state-json"]
    stdout: StdioCollector { id: stateOut; waitForEnd: true }
    onRunningChanged: {
      if (running || !root.stateAwait) return
      root.stateAwait = false
      // Таймаут сторожа — не отсутствие апдейтера: скачивание тут не помогает.
      if (root.timeouts.state === true) return
      // Не запустился — почти всегда апдейтера нет: скачиваем один раз.
      root.fetchUpdater()
    }
    onExited: function(code) {
      root.stateAwait = false
      if (root.takeTimeout("state")) {
        root.upError = "обновления: проверка не ответила за 90 с"
        return
      }
      var d = null
      try { d = JSON.parse(stateOut.text) } catch (e) { d = null }
      if (code !== 0 || !d || d.ok !== true) {
        root.upError = (d && d.error) ? ("обновления: " + d.error)
          : ("обновления: проверка не удалась (код " + code + ")")
        return
      }
      root.upError = ""
      root.up = d
      root.upChecked = Number(d.checked || 0)
      root.upLoaded = true
      root.maybeNotifyUpdates()
    }
  }

  // Апдейтера может не быть (виджет обновился раньше CLI): одна попытка за
  // сессию, результат — мягким текстом в разделе обновлений.
  Process {
    id: fetchProc
    command: ["bash", "-lc",
      "mkdir -p ~/.local/bin && curl -fsSL https://raw.githubusercontent.com/Blazeeers/VPN-TGWSProxy-Zapret-orchestrate/main/bin/omavpn-updater -o ~/.local/bin/omavpn-updater && chmod 755 ~/.local/bin/omavpn-updater"]
    stderr: StdioCollector { id: fetchErr; waitForEnd: true }
    // Не запустился сам bash — снимаем флаг, иначе повторов не будет вовсе.
    onRunningChanged: {
      if (running || !root.updaterFetching) return
      root.updaterFetching = false
      root.upError = "обновления: не удалось получить omavpn-updater (нет сети?)"
    }
    onExited: function(code) {
      root.updaterFetching = false
      if (code === 0) {
        root.upError = ""
        root.refreshUpdater()
      } else {
        root.upError = "обновления: не удалось получить omavpn-updater (нет сети?)"
      }
    }
  }

  // Обновление всего: компоненты, ядро (в терминале) и виджет. Только по
  // подтверждению — апдейтер ядра сам спрашивает пароль через pkexec.
  Process {
    id: updateAllProc
    command: [root.updaterPath, "--update-json", "--only", "all"]
    stdout: StdioCollector { id: updateAllOut; waitForEnd: true }
    onRunningChanged: {
      if (running || root.busy !== "upall") return
      root.busy = ""
      root.upError = "обновление не выполнено: нет " + root.updaterPath
    }
    onExited: function(code) {
      var timedOut = root.takeTimeout("upall")
      root.busy = ""
      var d = null
      try { d = JSON.parse(updateAllOut.text) } catch (e) { d = null }
      var msg = ""
      if (d && d.messages && d.messages.length) msg = d.messages.join("; ")
      var failed = timedOut || code !== 0 || (d && d.ok === false)
      if (timedOut) msg = "обновление не ответило за 60 минут"
      else if (msg === "") msg = failed ? "обновление завершилось ошибкой (код " + code + ")" : "обновлять нечего"
      if (failed) root.opError = msg
      else { root.notice = msg; noticeTimer.restart() }
      // В журнал не пишем: апдейтер сам добавляет строку "update: …" — иначе
      // на одно обновление появлялись две записи с разным текстом.
      if (d && d.restart_required) {
        root.notify("Обходы: обновления", "оболочка перезапустится через 4 секунды")
        restartShellProc.running = true
      } else {
        root.refreshUpdater()
      }
      root.refreshStatus()
    }
  }

  // Перезапуск оболочки после подмены Panel.qml. Отдельная сессия (setsid
  // --fork): quickshell при выходе убивает своего потомка, и обычный дочерний
  // процесс не успел бы довести перезапуск до конца.
  Process {
    id: restartShellProc
    command: ["setsid", "--fork", "bash", "-lc", "sleep 4; omarchy restart shell"]
    onExited: function(code) { root.refreshUpdater() }
  }

  // Журнал действий: одна строка "kind|текст" на запуск.
  Process {
    id: noteProc
    command: [root.updaterPath, "--note", "note|"]
    onExited: function(code) {
      // Сторож noteWatch мог прервать запись: метку забираем здесь, иначе она
      // висит до конца сессии (никто, кроме нас, её не читает).
      root.takeTimeout("note")
      root.noteNext()
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector { id: actionOut; waitForEnd: true }
    stderr: StdioCollector { id: actionErr; waitForEnd: true }
    // Команда идёт через cliPath (omavpn), поэтому и подсказка про него.
    onRunningChanged: {
      if (running || root.busy === "") return
      var label = root.busy
      root.busy = ""
      root.opError = (label !== "" ? "«" + label + "»: " : "")
        + "omavpn не запускается — проверь " + root.cliPath
    }
    onExited: function(code) {
      var label = root.busy
      var timedOut = root.takeTimeout("action")
      root.busy = ""
      if (timedOut) {
        root.opError = "действие «" + (label || "?") + "» не ответило за 3 минуты"
      } else if (code !== 0) {
        var t = (actionErr.text || actionOut.text || "").trim()
        try { var j = JSON.parse(t); if (j.error) t = j.error } catch (e) { /* plain */ }
        root.opError = t || "ошибка"
      } else {
        root.opError = ""
      }
      if (label === "vpn" || label === "update") {
        // vpnOn здесь ещё старый (статус обновится ниже), поэтому без «включён/выключен».
        root.notify("Обходы: " + (label === "vpn" ? "VPN" : "подписка"),
          root.opError !== "" ? root.opError
            : (label === "vpn" ? "переключено" : "обновлена"))
      }
      // Автозапуск при входе мог упасть просто потому, что сеть ещё не встала:
      // повторяем в фоне, пока не выйдет (не больше трёх попыток).
      if (label === "auto" && root.opError !== "" && root.autoAttempts < 3 && !root.vpnOn)
        autoRetryTimer.restart()
      root.refreshStatus()
      root.refreshVpn()
      // Лечение после переключения не запускаем: остальное покажет обычный опрос.
    }
  }

  // ---- маршруты сайтов: чтение и изменение правил --------------------------
  // Список правил — только чтение файла оверрайдов, поэтому его можно звать и
  // при открытии настроек, и после каждого изменения.
  Process {
    id: routeListProc
    // Команда ставится в refreshRoutes() перед запуском: привязка к cliPath здесь
    // в момент первого вызова ещё пустая.
    stdout: StdioCollector { id: routeListOut; waitForEnd: true }
    onRunningChanged: {
      if (running || !root.routeListAwait) return
      root.routeListAwait = false
      root.routeError = "маршруты: omavpn не запускается — проверь " + root.cliPath
    }
    onExited: function(code) {
      root.routeListAwait = false
      // За время чтения список могли попросить обновить ещё раз (например,
      // правило добавили сразу после открытия настроек): повторяем один раз.
      function finish() {
        if (root.routeListDirty) {
          root.routeListDirty = false
          root.refreshRoutes()
        }
      }
      if (root.takeTimeout("route-list")) {
        root.routeError = "список маршрутов не ответил за 30 с"
        finish()
        return
      }
      var d = null
      try { d = JSON.parse(routeListOut.text) } catch (e) { d = null }
      if (code !== 0 || !d || typeof d !== "object" || d.ok !== true) {
        root.routeError = "маршруты: " + ((d && d.error)
          ? d.error : ("список не получен, код " + code))
        finish()
        return
      }
      root.routeError = ""
      root.routeOverrides = (d.overrides instanceof Array) ? d.overrides : []
      root.routeLoaded = true
      finish()
    }
  }

  // Изменение правила. Один процесс на set и unset: команда собирается в
  // changeRoute(), чтобы набор аргументов был ровно один.
  Process {
    id: routeChangeProc
    property string action: ""
    stdout: StdioCollector { id: routeOut; waitForEnd: true }
    stderr: StdioCollector { id: routeErr; waitForEnd: true }
    onRunningChanged: {
      if (running || root.busy !== "route") return
      root.busy = ""
      root.routeError = "omavpn не запускается — проверь " + root.cliPath
    }
    onExited: function(code) {
      var timedOut = root.takeTimeout("route")
      var action = routeChangeProc.action
      root.busy = ""
      var d = null
      try { d = JSON.parse(routeOut.text) } catch (e) { d = null }
      if (timedOut) {
        root.routeError = "маршрут не изменён: omavpn не ответил за 3 минуты"
      } else if (code !== 0 || !d || d.ok !== true) {
        var msg = (d && d.error) ? String(d.error) : ""
        if (msg === "") msg = (routeErr.text || routeOut.text || "").trim()
        root.routeError = msg || ("маршрут не изменён, код " + code)
      } else if (action === "unset") {
        root.notice = d.removed === false
          ? ("правила для " + d.domain + " не было") : ("правило снято: " + d.domain)
        noticeTimer.restart()
        root.routeError = ""
      } else if (d.changed === false) {
        root.notice = "уже так и было"
        noticeTimer.restart()
        root.routeError = ""
      } else {
        root.notice = d.domain + " → " + (d.path === "proxy" ? "через VPN" : "напрямую")
          + (d.restarted ? " · VPN перезапущен" : "")
        noticeTimer.restart()
        root.routeError = ""
        routeInput.text = ""
      }
      // Перечитываем в любом исходе: частичное изменение тоже меняет список.
      root.refreshRoutes()
      root.refreshStatus()
    }
  }

  Process {
    id: notifyProc
    // notify-send есть на этой машине (libnotify); если его нет — уведомление
    // просто не появится, на работу виджета это не влияет.
    command: ["notify-send", "-a", "Обходы", "Обходы", ""]
    onExited: function(code) { /* код не важен: уведомление — необязательный бонус */ }
  }

  // ---- Re:filter: состояние, переключение, обновление списков ---------------
  Process {
    id: rfStatusProc
    stdout: StdioCollector { id: rfStatusOut; waitForEnd: true }
    onRunningChanged: {
      if (running || !root.rfAwait) return
      root.rfAwait = false
      root.rfError = "Re:filter: omavpn не запускается — проверь " + root.cliPath
    }
    onExited: function(code) {
      root.rfAwait = false
      if (root.takeTimeout("refilter")) {
        root.rfError = "Re:filter: состояние не получено " + root.timeoutText(root.rfStatusTimeout)
        return
      }
      var d = null
      try { d = JSON.parse(rfStatusOut.text) } catch (e) { d = null }
      if (code !== 0 || !d || typeof d !== "object" || d.ok !== true) {
        root.rfError = "Re:filter: " + ((d && d.error)
          ? d.error : ("состояние не получено, код " + code))
        return
      }
      // Успешный статус не повод стирать ошибку только что упавшего действия.
      if (!root.rfActionError) root.rfError = ""
      root.rf = d
      root.rfLoadedOnce = true
    }
  }

  // on / off / update — один процесс: аргументы собирает refilterAction().
  Process {
    id: rfActionProc
    property string action: ""
    stdout: StdioCollector { id: rfActionOut; waitForEnd: true }
    stderr: StdioCollector { id: rfActionErr; waitForEnd: true }
    onRunningChanged: {
      if (running || !root.rfBusy) return
      root.rfBusy = false
      root.rfActionError = true
      root.rfError = "Re:filter: omavpn не запускается — проверь " + root.cliPath
    }
    onExited: function(code) {
      var action = rfActionProc.action
      var timedOut = root.takeTimeout("refilter-act")
      root.rfBusy = false
      var d = null
      try { d = JSON.parse(rfActionOut.text) } catch (e) { d = null }
      root.rfActionError = false
      if (timedOut) {
        root.rfActionError = true
        root.rfError = "Re:filter: «" + action + "» не ответило " + root.timeoutText(root.rfActionTimeout)
      } else if (code !== 0 || !d || d.ok !== true) {
        root.rfActionError = true
        var msg = (d && d.error) ? String(d.error)
          : (rfActionErr.text || rfActionOut.text || "").trim()
        root.rfError = "Re:filter: " + (msg || ("код " + code))
      } else {
        root.rfError = ""
        if (action === "update") {
          root.notice = d.changed
            ? ("список Re:filter обновлён" + (d.restarted ? " · VPN перезапущен" : ""))
            : "список Re:filter без изменений"
        } else {
          root.notice = "Re:filter: " + (d.enabled ? "включён" : "выключен")
            + (d.restarted ? " · VPN перезапущен" : "")
            + (d.note ? " · " + d.note : "")
        }
        noticeTimer.restart()
      }
      // Размеры и дата меняются после обновления, настройка — после переключения:
      // в обоих случаях сводку надо перечитать, а не показывать старую.
      root.refreshRefilter()
      root.refreshStatus()
    }
  }

  // ---- подписка: чтение и замена URL ---------------------------------------
  Process {
    id: subGetProc
    stdout: StdioCollector { id: subGetOut; waitForEnd: true }
    onRunningChanged: {
      if (running || !root.subAwait) return
      root.subAwait = false
      if (!root.subQuiet)
        root.subError = "подписка: omavpn не запускается — проверь " + root.cliPath
    }
    onExited: function(code) {
      var quiet = root.subQuiet
      root.subQuiet = false
      root.subAwait = false
      if (root.takeTimeout("sub")) {
        if (!quiet) root.subError = "подписка: URL не получен " + root.timeoutText(root.subGetTimeout)
        return
      }
      var d = null
      try { d = JSON.parse(subGetOut.text) } catch (e) { d = null }
      if (code !== 0 || !d || typeof d !== "object" || d.ok !== true) {
        if (!quiet) root.subError = "подписка: " + ((d && d.error)
          ? d.error : ("URL не получен, код " + code))
        return
      }
      if (!quiet) root.subError = ""
      root.subLoaded = true
      root.subEnv = d.env === true
      root.applySubUrl(d.url)
    }
  }

  Process {
    id: subSetProc
    stdout: StdioCollector { id: subSetOut; waitForEnd: true }
    stderr: StdioCollector { id: subSetErr; waitForEnd: true }
    onRunningChanged: {
      if (running || !root.subBusy) return
      root.subBusy = false
      root.subError = "подписка: omavpn не запускается — проверь " + root.cliPath
    }
    onExited: function(code) {
      var timedOut = root.takeTimeout("sub-set")
      root.subBusy = false
      var d = null
      try { d = JSON.parse(subSetOut.text) } catch (e) { d = null }
      if (timedOut) {
        root.subError = "подписка не изменена: omavpn не ответил " + root.timeoutText(root.subSetTimeout)
      } else if (code !== 0 || !d || d.ok !== true) {
        var msg = (d && d.error) ? String(d.error)
          : (subSetErr.text || subSetOut.text || "").trim()
        // Поле не чистим: человек должен видеть, что вводил, и поправить сам.
        root.subError = msg || ("подписка не изменена, код " + code)
        if (d && d.url_changed === true) {
          // Адрес уже сменён и проверен — не сработал только перезапуск VPN.
          // Показываем это предупреждением, но поле и состояние ведём за новым
          // URL: иначе человек решит, что сохранение провалилось, и введёт заново.
          root.subDirty = false
          root.subUrl = String(d.url || "")
          subInput.text = root.subUrl
        } else {
          // Новый адрес не принят, файл откатился — перечитываем фактический URL.
          // Ввод при этом не затирается: applySubUrl уважает subDirty, а тихая
          // перечитка не стирает только что показанную ошибку.
          root.refreshSubscription(true)
        }
      } else {
        root.subError = ""
        root.subDirty = false
        root.subUrl = String(d.url || "")
        subInput.text = root.subUrl
        root.notice = (d.changed === false ? "URL подписки не изменился" : "подписка обновлена")
          + (d.restarted ? " · VPN перезапущен" : "")
        noticeTimer.restart()
        // Подписка могла принести другие регионы и серверы — список перечитываем.
        root.refreshRoutes()
        root.refreshVpn()
      }
      root.refreshStatus()
    }
  }

  // ---- полный сброс --------------------------------------------------------
  Process {
    id: resetProc
    stdout: StdioCollector { id: resetOut; waitForEnd: true }
    stderr: StdioCollector { id: resetErr; waitForEnd: true }
    onRunningChanged: {
      if (running || !root.resetBusy) return
      root.resetBusy = false
      root.resetError = "сброс: omavpn не запускается — проверь " + root.cliPath
    }
    onExited: function(code) {
      var timedOut = root.takeTimeout("reset")
      root.resetBusy = false
      var d = null
      try { d = JSON.parse(resetOut.text) } catch (e) { d = null }
      if (timedOut) {
        root.resetError = "сброс не ответил " + root.timeoutText(root.resetTimeout)
      } else if (code !== 0 || !d || d.ok !== true) {
        var msg = (d && d.errors && d.errors.length) ? d.errors.join("; ")
          : ((d && d.error) ? String(d.error) : (resetErr.text || resetOut.text || "").trim())
        root.resetError = "сброс: " + (msg || ("код " + code))
      }
      if (!timedOut && code === 0 && d && d.ok === true) {
        // Процессы убиты и подняты заново — оболочка перечитает конфиги и
        // плагины сама. Отдельная сессия (setsid) нужна, чтобы перезапуск
        // пережил закрытие quickshell, который убивает своих потомков.
        restartShellProc.running = true
      } else {
        root.refreshStatus()
        root.refreshVpn()
      }
    }
  }

  Timer {
    id: noticeTimer
    interval: 9000
    onTriggered: root.notice = ""
  }

  // Повтор автоподключения: при входе сеть может подниматься позже оболочки.
  Timer {
    id: autoRetryTimer
    interval: 20000
    repeat: false
    onTriggered: {
      if (!root.autoconnect || root.vpnOn || root.autoAttempts >= 3) return
      // Шесть проб по 20 с — две минуты на то, чтобы сеть поднялась. Дольше
      // ждать бессмысленно, а вечный таймер — это тихая утечка.
      root.autoRetryWakes += 1
      if (root.autoRetryWakes > 6) return
      if (root.cliPath === "" || root.busy !== "") { autoRetryTimer.restart(); return }
      root.autoAttempts += 1
      root.run(["on"], "auto")
    }
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

  // Монитор работоспособности: комплексная проверка — только чтение.
  // Под guard проверки реже (15 минут, на батарее 20): туннель восстанавливает
  // он, а частые опросы только шумят. Без guard — 5 минут, на батарее 15.
  Timer {
    id: healthTimer
    interval: root.guardActive ? (root.onBattery ? 1200000 : 900000)
      : (root.onBattery ? 900000 : 300000)
    running: true
    repeat: true
    onTriggered: {
      if (root.busy !== "" || root.healthBusy || root.vtRunning) return
      root.startHealth(false)
    }
  }

  // Снимок обновлений и журнала: раз в 5 минут и при открытии панели.
  // Апдейтер сам ходит в сеть не чаще раза в сутки (его кэш), остальное — чтение.
  Timer {
    id: stateTimer
    interval: 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshUpdater()
  }

  // Сторожа процессов: интервал = предел ожидания, взводится вместе с запуском.
  Timer { id: statusWatch; interval: 60000; running: statusProc.running; onTriggered: root.killProc("status") }
  Timer { id: vpnWatch; interval: 60000; running: vpnProc.running; onTriggered: root.killProc("vpn") }
  // 9 минут, а не 5: законный heal — это health_items (до ~125 с на плохой
  // сети), omavpn heal (до 180 с) и повторный health_items. Пятиминутный
  // сторож убивал его на середине, HEALTH_LOCK оставался лежать, и следующие
  // три минуты все проверки отвечали «already_running».
  Timer { id: healthWatch; interval: 540000; running: healthProc.running; onTriggered: root.killProc("health") }
  // 20 минут, а не 15: юнит разрешает 1200 с, и законный прогон (до четырёх
  // рестартов туннеля) в него укладывается. Ранний SIGTERM не давал Python
  // выполнить finally — терялись кулдауны доменов.
  Timer { id: auditWatch; interval: 1200000; running: auditProc.running; onTriggered: root.killProc("audit") }
  Timer { id: optimizeWatch; interval: 240000; running: optimizeProc.running; onTriggered: root.killProc("optimize") }
  Timer { id: rescanWatch; interval: 120000; running: rescanProc.running; onTriggered: root.killProc("rescan") }
  // 90 с, а не 30: --state-json делает четыре сетевых запроса (GitHub, AUR,
  // репозитории ядра) и на плохой сети честно идёт до ~80 с. Тридцатисекундный
  // сторож рубил законную проверку и показывал ошибку.
  Timer { id: stateWatch; interval: 90000; running: stateProc.running; onTriggered: root.killProc("state") }
  // 60 минут: ядро тянется с GitHub, а один шаг установки идёт в терминале с
  // паролем — человеку нужно время вернуться. Компоненты (zapret, tg-ws-proxy)
  // на плохой сети идут до 15–30 минут каждая.
  Timer { id: updateAllWatch; interval: 3600000; running: updateAllProc.running; onTriggered: root.killProc("upall") }
  Timer { id: noteWatch; interval: 20000; running: noteProc.running; onTriggered: root.killProc("note") }
  Timer { id: actionWatch; interval: 180000; running: actionProc.running; onTriggered: root.killProc("action") }
  // 3 минуты: сам set/unset короткий (перезапуск туннеля ~20 с), но на плохой
  // сети лок ctrl.lock ждётся дольше — ранний SIGTERM оставил бы полуприменённое
  // правило.
  Timer { id: routeWatch; interval: 180000; running: routeChangeProc.running; onTriggered: root.killProc("route") }
  // Чтение списка — секунды; 30 с достаточно и не держит метку вечно.
  Timer { id: routeListWatch; interval: 30000; running: routeListProc.running; onTriggered: root.killProc("route-list") }
  // Re:filter: чтение состояния — секунды; обновление качает ~0,6 МБ с GitHub
  // (юнит разрешает 300 с: два файла по 120 с + перезапуск), поэтому сторож
  // действия должен быть не меньше бюджета сервиса.
  Timer { id: rfWatch; interval: root.rfStatusTimeout; running: rfStatusProc.running; onTriggered: root.killProc("refilter") }
  Timer { id: rfActionWatch; interval: root.rfActionTimeout; running: rfActionProc.running; onTriggered: root.killProc("refilter-act") }
  // Подписка: чтение — секунды; замена качает новую подписку (HTTP_TIMEOUT 40 с)
  // и перезапускает туннель.
  Timer { id: subWatch; interval: root.subGetTimeout; running: subGetProc.running; onTriggered: root.killProc("sub") }
  Timer { id: subSetWatch; interval: root.subSetTimeout; running: subSetProc.running; onTriggered: root.killProc("sub-set") }
  // Сброс: остановка служб + ожидание чужих omavpn + до трёх попыток поднять VPN.
  // Ранний SIGTERM оставил бы туннель выключенным.
  Timer { id: resetWatch; interval: root.resetTimeout; running: resetProc.running; onTriggered: root.killProc("reset") }

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
        // Пока идёт подбор серверов или лечение, туннель занят: переключение
        // испортит результаты и сам туннель.
        if (root.cliPath !== "" && root.busy === "" && !root.tunnelBusy)
          root.run(["toggle"], "vpn")
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
    contentHeight: panel.fittedContentHeight(
      root.settingsOpen ? settingsColumn.implicitHeight : column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // Поле ввода маршрута забирает клавиши себе: иначе стрелки и пробел
      // уходили бы в обход кнопок и мешали печатать домен.
      blocked: root.settingsOpen && (routeInput.activeFocus || subInput.activeFocus)
      onCloseRequested: {
        if (confirmDlg.opened) root.cancelConfirm()
        // Escape в настройках возвращает в основную панель, а не закрывает её.
        else if (root.settingsOpen) root.closeSettings()
        else root.close()
      }
      // Enter/Space: в открытом диалоге подтверждают выбранную кнопку, иначе
      // нажимают выбранную клавиатурой кнопку действия. Tab/стрелки листают.
      // Enter в PanelKeyCatcher эмитит и returnRequested, и activateRequested —
      // намеренно слушаем только второй, иначе действие сработало бы дважды.
      onActivateRequested: root.keyActivate()
      onTabRequested: function(direction) { root.keyTab(direction) }
      onMoveRequested: function(dx, dy) { root.keyScroll(dx, dy) }
    }

    Flickable {
      id: panelFlick
      anchors.fill: parent
      contentWidth: width
      contentHeight: root.settingsOpen ? settingsColumn.implicitHeight : column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        visible: !root.settingsOpen
        width: panelFlick.width
        spacing: Style.space(10)

        // Обёртка нужна из-за PanelHero.trailingControl: внутри Component `root`
        // резолвится в сам PanelHero, поэтому к состоянию панели обращаемся
        // через mainHeader.panel (тот же приём, что в плагине tailscale).
        Item {
          id: mainHeader
          width: parent.width
          implicitHeight: mainHero.implicitHeight
          readonly property var panel: root
          // Шестерёнка объявлена внутри Component — её id снаружи не виден,
          // поэтому клавиатурный обход берёт её отсюда.
          property var gearButton: null

          PanelHero {
            id: mainHero
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

            // Шестерёнка: единственный вход в настройки — на правом краю шапки,
            // чтобы не занимать строку в теле панели.
            trailingControl: Component {
              IconButton {
                id: settingsBtn
                keyIndex: 6
                iconText: "⚙"
                tooltipText: "Настройки"
                onClicked: mainHeader.panel.openSettings()
                Component.onCompleted: mainHeader.gearButton = settingsBtn
              }
            }
          }
        }

        Text {
          width: parent.width
          visible: root.errorText !== ""
          textFormat: Text.PlainText
          text: root.errorText
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
                  // Ошибку конфига (settings_error/error) дописываем в хвост —
                  // elide её бы съел, поэтому здесь перенос, а не обрезка.
                  wrapMode: Text.WordWrap
                }
              }

              ActionButton {
                id: toggleBtn
                anchors.verticalCenter: parent.verticalCenter
                text: root.busy === "vpn" ? "…" : (root.vpnOn ? "Выключить" : "Включить")
                accent: root.vpnOn ? root.okColor : Color.accent
                enabled: root.cliPath !== "" && root.busy === "" && !root.tunnelBusy
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
                  text: root.vtBest ? ("★ " + (root.vtBestName || root.vtBest.tag)) : ""
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
                      && root.vtBestProfile >= 0
                      && root.vtBestProfile === Number(modelData.index)
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
                      onClicked: if (root.busy === "" && !root.tunnelBusy) root.run(["profile", String(prow.modelData.index)], "profile")
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
                    onClicked: if (root.busy === "" && !root.tunnelBusy) root.run(["node", "-1"], "node")
                  }
                }

                Repeater {
                  model: root.nodesOfProfile

                  Rectangle {
                    id: trow
                    required property var modelData
                    readonly property int nodeIdx: Number(modelData.index)
                    readonly property bool isBest: {
                      if (root.vtBest === null || root.vtBest.index === undefined) return false
                      // vtBest.index — номер внутри своего региона: без сверки
                      // региона звезда оставалась на том же номере в чужом.
                      if (root.vtBestProfile < 0) return false
                      var cur = Number(root.vpnInfo.profile_index)
                      if (isNaN(cur) || root.vtBestProfile !== cur) return false
                      return Number(root.vtBest.index) === nodeIdx
                    }
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
                                 : ("медиана " + trow.modelData.med + " с · потери " + (trow.modelData.loss || 0)))
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
                      onClicked: if (root.busy === "" && !root.tunnelBusy) root.run(["node", String(trow.nodeIdx)], "node")
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
                tint: root.zapTuning ? Color.accent : root.stateColor(root.hState("zapret", ""))
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
                  text: root.zapTuning ? "идёт подбор стратегии…" : root.hDetail("zapret", "", "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
              Text {
                textFormat: Text.PlainText
                text: root.zapTuning ? "подбор" : root.stateWord(root.hState("zapret", ""))
                color: root.zapTuning ? Color.accent : root.stateColor(root.hState("zapret", ""))
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

        }

        // ---------- обновления ----------
        // Отдельный раздел, а не строка в списке статусов: тут видно, что именно
        // и на какую версию обновится, и одна кнопка на всё.
        Rectangle {
          width: parent.width
          radius: Style.cornerRadius > 0 ? Style.space(12) : 0
          color: root.cardFill
          border.width: 1
          border.color: root.hairline
          implicitHeight: updBox.implicitHeight + Style.space(24)

          Column {
            id: updBox
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(10)

              Pictogram {
                name: "update"
                tint: root.upAny ? root.warn : root.dim
                px: Style.space(18)
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
                text: "ОБНОВЛЕНИЯ"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 0.8
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // по строке на компонент с новой версией
            Repeater {
              model: root.updItems

              Text {
                required property var modelData
                width: parent.width
                textFormat: Text.PlainText
                text: modelData.text
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                wrapMode: Text.WordWrap
              }
            }

            // ничего нового или ошибка проверки — одна приглушённая строка
            Text {
              width: parent.width
              // В фолбэке (апдейтер недоступен, данные из снимка статуса) строки
              // компонентов показаны, но «проверено HH:mm» всё равно нужно.
              visible: !root.upAny || root.upFallbackActive
              textFormat: Text.PlainText
              text: root.upStatusText
              color: root.upError !== "" ? root.warn : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            ActionButton {
              id: updateAllBtn
              keyIndex: 5
              visible: root.upAny
              text: root.busy === "upall" ? "обновляю…" : "Обновить всё"
              accent: root.warn
              tooltipText: "Компоненты, ядро (в терминале с паролем) и виджет с перезапуском оболочки"
              // Туннель занят подбором или лечением — обновление подождёт.
              enabled: root.upAny && root.busy === "" && !root.healthBusy && !root.tunnelBusy
              onClicked: root.askConfirm("updateall", root.updateAllMessage)
            }
          }
        }

        // ---------- журнал: что виджет сделал сам ----------
        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.upActions.length > 0 || (root.guardActive && root.guardKnown)

          Text {
            textFormat: Text.PlainText
            visible: root.upActions.length > 0
            text: "ЧТО ВИДЖЕТ СДЕЛАЛ САМ"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
            font.letterSpacing: 0.8
          }

          Repeater {
            model: root.upActions

            Row {
              id: arow
              required property var modelData
              width: parent.width
              spacing: Style.space(8)

              Text {
                textFormat: Text.PlainText
                text: arow.modelData.when
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                width: Style.space(38)
              }
              Text {
                textFormat: Text.PlainText
                text: arow.modelData.text
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
                width: parent.width - Style.space(46)
              }
            }
          }

          // Единый лечащий контур: видно, кто именно держит туннель. Без снимка
          // апдейтера состояние неизвестно — не утверждаем, что guard работает.
          Text {
            textFormat: Text.PlainText
            visible: root.guardActive && root.guardKnown
            text: "автовосстановление: guard"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
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

        // Аудит маршрутов: строку не обрезаем — переносим. Подсказка-дубль на
        // весь текст (было ~50 строк) убрана: она показывала то же самое, что
        // и так видно целиком.
        Text {
          width: parent.width
          visible: root.raLineText !== ""
          textFormat: Text.PlainText
          text: root.raLineText
          color: root.raColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }

      // ---- экран настроек ----------------------------------------------------
      // Второй экран той же панели, а не отдельное окно: сброс прокрутки,
      // клавиатурный обход и закрытие по Escape работают как в основной.
      Column {
        id: settingsColumn
        visible: root.settingsOpen
        width: panelFlick.width
        spacing: Style.space(10)

        // Обёртка из-за trailingControl: внутри Component `root` резолвится в
        // сам PanelHero, поэтому панель доступна только через settingsHeader.panel.
        Item {
          id: settingsHeader
          width: parent.width
          implicitHeight: settingsHero.implicitHeight
          readonly property var panel: root
          // Кнопка «Готово» объявлена внутри Component — её id снаружи не виден,
          // поэтому клавиатурный обход берёт её отсюда.
          property var backButton: null

          PanelHero {
            id: settingsHero
            width: parent.width
            title: "Настройки"
            meta: "действия и маршруты"
            foreground: root.foreground
            fontFamily: root.fontFamily

            iconComponent: Component {
              Pictogram {
                name: "settings"
                tint: root.foreground
                px: Style.font.display * 1.1
              }
            }

            trailingControl: Component {
              ActionButton {
                id: settingsBackBtn
                keyIndex: 7
                text: "Готово"
                // root в этом контексте может указывать на PanelHero — панель
                // берём явно, чтобы подсветка клавиатуры не потерялась.
                hasCursor: settingsHeader.panel !== null
                  && settingsHeader.panel.keyIndex === 7
                onClicked: settingsHeader.panel.closeSettings()
                Component.onCompleted: settingsHeader.backButton = settingsBackBtn
              }
            }
          }
        }

        // Ошибки действий показываются на том экране, где их нажали: без этого
        // провал «Проверить всё» оставался бы за кадром.
        Text {
          width: parent.width
          visible: root.errorText !== ""
          textFormat: Text.PlainText
          text: root.errorText
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }
        // ---------- тумблеры ----------
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

        // Тихая иконка: когда всё в порядке, пиктограмма в баре не красится.
        Rectangle {
          id: quietRowBox
          width: parent.width
          implicitHeight: quietRow.implicitHeight + Style.space(12)
          radius: Style.cornerRadius > 0 ? Style.space(10) : 0
          color: quietMouse.containsMouse ? root.hoverFill : "transparent"

          Row {
            id: quietRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(10)

            Pictogram {
              name: "check"
              tint: root.quietBar ? Color.accent : root.dim
              px: Style.space(18)
              anchors.verticalCenter: parent.verticalCenter
            }
            Text {
              textFormat: Text.PlainText
              text: "Тихая иконка"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              width: parent.width - Style.space(90)
            }
            Text {
              textFormat: Text.PlainText
              text: root.quietBar ? "вкл" : "выкл"
              color: root.quietBar ? Color.accent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          MouseArea {
            id: quietMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.setSetting("quietBar", !root.quietBar)
          }
        }

        // ---------- действия ----------
        PanelSeparator { foreground: root.foreground }

        Flow {
          width: parent.width
          spacing: Style.space(8)

          ActionButton {
            id: checkAllBtn
            keyIndex: 0
            text: root.healthBusy ? ("… " + root.healthElapsed + " с") : "Проверить всё"
            tooltipText: "Полная проверка с попыткой самовосстановления VPN (до 9 минут)"
            // scriptOk, а не «scriptPath !== ""»: путь всегда непустой, поэтому
            // кнопка была бы живой и без установленного bypass-status.
            // vtRunning тоже блокирует: heal перезапускает туннель и испортит
            // результаты идущего подбора серверов.
            enabled: root.scriptOk && !root.healthBusy && root.busy === ""
              && !root.vtRunning && !root.sideBusy
            onClicked: {
              if (root.vtRunning || root.busy !== "" || root.healthBusy || root.sideBusy) return
              root.startHealth(true)
            }
          }

          ActionButton {
            id: bestBtn
            keyIndex: 1
            text: root.vtRunning ? ("подбор " + root.vtDone + "/" + root.vtTotal) : "Подобрать лучший"
            accent: Color.accent
            // Пока идёт health-проверка (особенно лечение), подбор недоступен:
            // обе операции трогают туннель и мешают друг другу.
            tooltipText: root.healthBusy
              ? "Идёт проверка — дождись её окончания"
              : "Прогнать все регионы и серверы и подключить лучший (туннель перезапустится)"
            enabled: root.cliPath !== "" && root.busy === "" && !root.vtRunning
              && !root.healthBusy && !root.sideBusy
            onClicked: {
              if (root.vtRunning || optimizeProc.running || root.healthBusy || root.busy !== ""
                || root.sideBusy) return
              root.vpnExpanded = true
              // Ручной подбор — явный выбор человека: он вправе сменить регион.
              root.startOptimize(false)
            }
          }

          ActionButton {
            id: rescanBtn
            keyIndex: 2
            text: root.busy === "rescan" ? "…" : "Тест стратегий"
            tooltipText: root.healthBusy
              ? "Идёт проверка — дождись её окончания"
              : (root.vtRunning
                ? "Идёт подбор серверов — дождись его окончания"
                : "Перебрать стратегии zapret и выбрать рабочую")
            // busy гасит все действия, health-проверка и подбор серверов — те,
            // что сами трогают маршруты и zapret; открытая панель остаётся живой.
            enabled: root.scriptOk && root.busy === "" && !root.healthBusy
              && !root.vtRunning && !root.sideBusy
            onClicked: {
              if (root.busy !== "" || rescanProc.running || root.healthBusy || root.vtRunning
                || root.sideBusy) return
              root.opError = ""
              root.busy = "rescan"
              rescanProc.running = true
            }
          }

          ActionButton {
            id: auditBtn
            keyIndex: 3
            text: root.busy === "audit" ? "… маршруты" : "Проверить маршруты"
            tooltipText: root.healthBusy
              ? "Идёт проверка — дождись её окончания"
              : (root.vtRunning
                ? "Идёт подбор серверов — дождись его окончания"
                : "Аудит доменов: может перевести домен на другой путь и перезапустить туннель (~1 минута)")
            // Аудит запускает scriptPath (bypass-status), а не cliPath (omavpn):
            // проверять надо именно его, иначе кнопка мертва без CLI.
            enabled: root.scriptOk && root.busy === "" && !root.healthBusy
              && !root.vtRunning && !root.sideBusy
            onClicked: root.askConfirm("audit",
              "Проверить маршруты доменов?\nАудит может перевести домены на другой путь и перезапустить туннель — трафик прервётся примерно на минуту.")
          }

          ActionButton {
            id: updateBtn
            keyIndex: 4
            text: root.busy === "update" ? "…" : "Обновить подписку"
            tooltipText: root.healthBusy
              ? "Идёт проверка — дождись её окончания"
              : (root.vtRunning
                ? "Идёт подбор серверов — дождись его окончания"
                : "Перечитать подписку (туннель перезапустится)")
            enabled: root.cliPath !== "" && root.busy === "" && !root.tunnelBusy
              && !root.healthBusy && !root.sideBusy
            onClicked: root.askConfirm("update",
              "Обновить подписку?\nТуннель перезапустится, трафик прервётся на несколько секунд.")
          }
        }


        // Тот же notice, что и в основной панели: результат действия виден там,
        // где человек нажал кнопку.
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

        // ---------- маршруты сайтов ----------
        // Своё правило поверх встроенных списков: человек решает, что идёт через
        // туннель, не правя конфиги. Правило сильнее direct_domains.txt и аудита
        // (первое совпадение в sing-box), поэтому подсказка про перезапуск VPN.
        Rectangle {
          width: parent.width
          radius: Style.cornerRadius > 0 ? Style.space(12) : 0
          color: root.cardFill
          border.width: 1
          border.color: root.hairline
          implicitHeight: routeBox.implicitHeight + Style.space(24)

          Column {
            id: routeBox
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(10)

              Pictogram {
                name: "settings"
                tint: root.dim
                px: Style.space(18)
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
                text: "МАРШРУТЫ САЙТОВ"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 0.8
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Без CLI правило некуда записать: форма была бы обманом.
            Text {
              width: parent.width
              visible: root.cliPath === ""
              textFormat: Text.PlainText
              text: "omavpn не найден — маршруты недоступны"
              color: root.warn
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              visible: root.cliPath !== ""
              textFormat: Text.PlainText
              text: "Домен или ссылка. Твой выбор важнее встроенных правил; "
                + "изменение перезапускает VPN на несколько секунд."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            TextField {
              id: routeInput
              // Поле входит в клавиатурный обход наравне с кнопками: Tab
              // доводит до него, Enter открывает ввод, Escape возвращает панели.
              property int keyIndex: 8
              width: parent.width
              visible: root.cliPath !== ""
              foreground: root.foreground
              font.family: root.fontFamily
              placeholderText: "x.com или https://x.com/страница"
              enabled: root.busy === ""
              hasCursor: root.keyIndex === 8
              onAccepted: root.addRoute()
              // Escape из поля возвращает клавиатуру панели: иначе фокус
              // оставался в скрытом поле и остальные клавиши терялись.
              Keys.onEscapePressed: function(event) {
                event.accepted = true
                root.keyIndex = -1
                keyCatcher.forceActiveFocus()
              }
              // Tab из заполненного поля продолжает обход кнопок, а не уводит
              // фокус в никуда.
              Keys.onTabPressed: function(event) {
                event.accepted = true
                root.keyTab((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
                keyCatcher.forceActiveFocus()
              }
              Keys.onBacktabPressed: function(event) {
                event.accepted = true
                root.keyTab(-1)
                keyCatcher.forceActiveFocus()
              }
            }

            Row {
              width: parent.width
              visible: root.cliPath !== ""
              spacing: Style.space(8)

              ActionButton {
                id: routeDirectBtn
                keyIndex: 9
                text: "Напрямую"
                selected: root.routePath === "direct"
                onClicked: root.routePath = "direct"
              }

              ActionButton {
                id: routeProxyBtn
                keyIndex: 10
                text: "Через VPN"
                selected: root.routePath === "proxy"
                onClicked: root.routePath = "proxy"
              }

              Item {
                width: Math.max(0, parent.width - routeDirectBtn.width - routeProxyBtn.width
                  - routeAddBtn.width - Style.space(24))
                height: 1
              }

              ActionButton {
                id: routeAddBtn
                keyIndex: 11
                text: root.busy === "route" ? "…" : "Добавить"
                tooltipText: "Записать правило и перезапустить VPN, если он включён"
                // Пустое поле или занятое действие — нечего отправлять.
                enabled: root.cliPath !== "" && root.busy === "" && !root.healthBusy
                  && !root.vtRunning && String(routeInput.text || "").trim() !== ""
                onClicked: root.addRoute()
              }
            }

            Text {
              width: parent.width
              visible: root.routeError !== ""
              textFormat: Text.PlainText
              text: root.routeError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Свои правила: домен, путь и (для авто-правил аудита) пометка.
            Column {
              width: parent.width
              spacing: Style.space(2)
              visible: root.cliPath !== ""

              Repeater {
                model: root.routeOverrides

                Rectangle {
                  id: rrow
                  required property var modelData
                  readonly property string dom: String(modelData.domain || "")
                  // Аудит подписывает свои записи «аудит: …» — человек должен
                  // отличать их от своих.
                  readonly property bool fromAudit:
                    String(modelData.reason || "").indexOf("аудит") === 0
                  width: parent.width
                  implicitHeight: rline.implicitHeight + Style.space(8)
                  radius: Style.cornerRadius > 0 ? Style.space(8) : 0
                  color: "transparent"

                  Row {
                    id: rline
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(8)
                    anchors.rightMargin: Style.space(2)
                    spacing: Style.space(8)

                    Text {
                      textFormat: Text.PlainText
                      text: rrow.dom
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      // Запас под путь, пометку «аудит» и кнопку снятия: без
                      // него строка с пометкой вылезала за край карточки.
                      width: Math.max(0, parent.width - Style.space(190))
                      elide: Text.ElideRight
                    }
                    Text {
                      textFormat: Text.PlainText
                      text: rrow.modelData.path === "proxy" ? "через VPN" : "напрямую"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                    Text {
                      visible: rrow.fromAudit
                      textFormat: Text.PlainText
                      text: "аудит"
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      opacity: 0.7
                    }
                    PanelActionButton {
                      iconText: "✕"
                      tooltipText: "Снять правило"
                      foreground: root.foreground
                      hoverColor: root.urgent
                      fontFamily: root.fontFamily
                      enabled: root.busy === "" && !root.healthBusy && !root.vtRunning
                      anchors.verticalCenter: parent.verticalCenter
                      onClicked: root.confirmUnsetRoute(rrow.dom)
                    }
                  }
                }
              }
            }

            Text {
              width: parent.width
              visible: root.cliPath !== "" && !root.routeLoaded
              textFormat: Text.PlainText
              text: "читаю правила…"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: root.cliPath !== "" && root.routeLoaded
                && root.routeOverrides.length === 0
              textFormat: Text.PlainText
              text: "Пока своих правил нет — трафик идёт по общим правилам."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }

        // ---------- Re:filter: заблокированное в РФ ----------
        // Сами списки (80 тыс. доменов и 25 тыс. адресов) в QML не попадают:
        // здесь только сводка, размер и дата, их отдаёт `omavpn refilter status`.
        Rectangle {
          width: parent.width
          radius: Style.cornerRadius > 0 ? Style.space(12) : 0
          color: root.cardFill
          border.width: 1
          border.color: root.hairline
          implicitHeight: rfBox.implicitHeight + Style.space(24)

          Column {
            id: rfBox
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(10)

              Pictogram {
                name: "vpn"
                tint: root.dim
                px: Style.space(18)
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
                text: "БЛОКИРОВКИ РФ"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 0.8
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Переключатель — строка, как тумблеры выше: кнопкой в обходе
            // клавиатуры он бы мешал, а состояние читается так же.
            Rectangle {
              width: parent.width
              implicitHeight: rfToggleRow.implicitHeight + Style.space(10)
              radius: Style.cornerRadius > 0 ? Style.space(8) : 0
              color: rfToggleMouse.containsMouse ? root.hoverFill : "transparent"
              opacity: root.cliPath !== "" && !root.rfBusy ? 1 : 0.5

              Row {
                id: rfToggleRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(8)
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(10)

                Text {
                  textFormat: Text.PlainText
                  text: "Заблокированные в РФ — через VPN"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  width: parent.width - Style.space(50)
                  wrapMode: Text.WordWrap
                }
                Text {
                  textFormat: Text.PlainText
                  // До первого ответа состояние неизвестно: «выкл» было бы враньём.
                  text: !root.rfLoadedOnce || root.rfBusy
                    ? "…" : (root.rfEnabled ? "вкл" : "выкл")
                  color: root.rfEnabled ? root.okColor : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                id: rfToggleMouse
                anchors.fill: parent
                hoverEnabled: true
                // Сброс и чужие операции блокируют переключение: все они трогают
                // туннель, а молчаливое «нажал и ничего» — худший вариант.
                enabled: root.cliPath !== "" && !root.sideBusy && root.busy === ""
                  && !root.healthBusy && !root.vtRunning
                cursorShape: Qt.PointingHandCursor
                onClicked: root.refilterToggle()
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.rfSummary
              color: root.rfReady ? root.dim : root.warn
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            // Почему список не годится — словами бэкенда, а не «ошибка».
            Text {
              width: parent.width
              visible: root.rfProblem !== ""
              textFormat: Text.PlainText
              text: root.rfProblem
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              ActionButton {
                id: rfUpdateBtn
                keyIndex: 12
                text: root.rfBusy ? "…" : "Обновить список"
                tooltipText: "Скачать свежие списки Re:filter; если они изменились, VPN перезапустится"
                enabled: root.cliPath !== "" && !root.rfBusy && root.busy === ""
                  && !root.resetBusy && !root.subBusy && !root.healthBusy
                  && !root.vtRunning && !root.tunnelBusy
                onClicked: root.refilterAction("update")
              }
            }

            Text {
              width: parent.width
              visible: root.rfError !== ""
              textFormat: Text.PlainText
              text: root.rfError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }

        // ---------- подписка ----------
        // Замена URL без редактора: новый адрес сразу проверяется загрузкой, а
        // при ошибке остаётся прежний (бэкенд откатывает файл сам).
        Rectangle {
          width: parent.width
          radius: Style.cornerRadius > 0 ? Style.space(12) : 0
          color: root.cardFill
          border.width: 1
          border.color: root.hairline
          implicitHeight: subBox.implicitHeight + Style.space(24)

          Column {
            id: subBox
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(10)

              Pictogram {
                name: "region"
                tint: root.dim
                px: Style.space(18)
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
                text: "ПОДПИСКА"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 0.8
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              width: parent.width
              visible: root.cliPath === ""
              textFormat: Text.PlainText
              text: "omavpn не найден — адрес подписки менять нечем"
              color: root.warn
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              visible: root.cliPath !== ""
              textFormat: Text.PlainText
              text: "Адрес подписки (файл ~/.config/omavpn/subscription). После "
                + "сохранения туннель перезапустится, если VPN включён; если новый "
                + "адрес не загрузится, останется прежний."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            TextField {
              id: subInput
              // Как и поле маршрута: Tab доводит до него, Escape возвращает панели.
              property int keyIndex: 13
              width: parent.width
              visible: root.cliPath !== ""
              foreground: root.foreground
              font.family: root.fontFamily
              placeholderText: "https://…"
              enabled: root.cliPath !== "" && !root.subBusy && !root.subEnv
              hasCursor: root.keyIndex === 13
              // Ввод помечаем «грязным»: ответ subscription get не должен
              // затирать то, что человек уже напечатал.
              onTextEdited: root.subDirty = true
              onAccepted: root.subscriptionSave()
              Keys.onEscapePressed: function(event) {
                event.accepted = true
                root.keyIndex = -1
                keyCatcher.forceActiveFocus()
              }
              Keys.onTabPressed: function(event) {
                event.accepted = true
                root.keyTab((event.modifiers & Qt.ShiftModifier) ? -1 : 1)
                keyCatcher.forceActiveFocus()
              }
              Keys.onBacktabPressed: function(event) {
                event.accepted = true
                root.keyTab(-1)
                keyCatcher.forceActiveFocus()
              }
            }

            Text {
              width: parent.width
              visible: root.subEnv
              textFormat: Text.PlainText
              text: "URL задан переменной OMAVPN_SUB_URL — это поле и файл на него "
                + "не влияют. Убери переменную и открой настройки заново."
              color: root.warn
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              ActionButton {
                id: subSaveBtn
                keyIndex: 14
                text: root.subBusy ? "…" : "Сохранить"
                tooltipText: "Записать адрес и перезапустить VPN, если он включён"
                enabled: root.cliPath !== "" && !root.subBusy && !root.subEnv
                  && root.busy === "" && !root.resetBusy && !root.healthBusy
                  && !root.vtRunning && !root.tunnelBusy
                  && String(subInput.text || "").trim() !== ""
                  && String(subInput.text || "").trim() !== root.subUrl
                onClicked: root.subscriptionSave()
              }
            }

            Text {
              width: parent.width
              visible: root.subError !== ""
              textFormat: Text.PlainText
              text: root.subError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }
        }

        // ---------- полный сброс ----------
        // Крайняя мера на случай, когда всё зависло. Данные человека (подписка,
        // маршруты, настройки, списки Re:filter) остаются — удаляется только
        // транзиентное состояние и блокировки.
        Rectangle {
          width: parent.width
          radius: Style.cornerRadius > 0 ? Style.space(12) : 0
          color: root.cardFill
          border.width: 1
          border.color: root.hairline
          implicitHeight: resetBox.implicitHeight + Style.space(24)

          Column {
            id: resetBox
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            Row {
              width: parent.width
              spacing: Style.space(10)

              Pictogram {
                name: "warning"
                tint: root.urgent
                px: Style.space(18)
                anchors.verticalCenter: parent.verticalCenter
              }
              Text {
                textFormat: Text.PlainText
                text: "СБРОС"
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
                font.letterSpacing: 0.8
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Text {
              width: parent.width
              visible: root.cliPath !== ""
              textFormat: Text.PlainText
              text: "Если всё зависло: остановит VPN и службы, удалит кэш и "
                + "блокировки, поднимет VPN заново и перезапустит оболочку. "
                + "Подписка, маршруты и настройки сохранятся."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(8)

              ActionButton {
                id: resetBtn
                keyIndex: 15
                text: root.resetBusy ? "… сброс" : "Полный сброс"
                // Красный текст — предупреждение до нажатия, а не после.
                foreground: root.urgent
                tooltipText: "Остановить VPN и службы, удалить кэш и блокировки, поднять VPN и перезапустить оболочку"
                enabled: root.cliPath !== "" && !root.resetBusy
                onClicked: root.askConfirm("reset",
                  "Полный сброс?\nОстановит VPN и службы, удалит кэш и блокировки, перезапустит VPN и оболочку. Подписка, маршруты и настройки сохранятся.")
              }
            }

            Text {
              width: parent.width
              visible: root.resetError !== ""
              textFormat: Text.PlainText
              text: root.resetError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
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
