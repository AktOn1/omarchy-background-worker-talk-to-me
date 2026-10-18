// Background Worker Talk To Me: service. Shows a TESTING banner while a script or agent changes the
// desktop, a countdown at the start, and a one-key question card on request.
//
// The start countdown is a top bar, questions a card in the bottom-right corner, the TESTING banner a badge with a time ring in the
// top-right corner. All show on every screen. The keyboard is grabbed only while the countdown or a question is on screen. The banner
// never takes the keyboard.
//
// IPC (target "talk-to-me"; the `talk-to-me` command wraps these and polls the result files):
//   start <id> <label> <countdownSec> <maxMinutes> <help> <estimateSec> <shield> <kind> <hide>   countdown (Ctrl+Y only when <help> is non-empty), result file: human | solo | cancelled | postpone:<min>
//   ask <id> <question> <timeoutSec> <choice|text>   result file: yes | no | unsure | text:<typed> | postpone:<min> | timeout | ended
//   quick <id> <question> <timeoutSec> <choice|text>  (experimental) like ask, but also works with no session: a plain
//                                                question card, no banner. result file adds: busy | dismissed
//   say <text> | eta <seconds> | end | cancel <id> | status | ping
//   notice <text> <seconds>   "agent activity" banner with no session (sent by bin/talk-to-me-watch)
// Result files: $XDG_RUNTIME_DIR/talk-to-me/<id>.result (the id is validated, no paths from callers).

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "TalkToMeModel.js" as Model

Scope {
  id: root

  property var omarchyPath
  property var shell
  property var manifest

  readonly property string runtimeBase: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string runtimeDir: runtimeBase + "/talk-to-me"

  // idle | countdown | active | paused (human postponed the test; banner counts down, agent restarts it)
  property string phase: "idle"
  // human | solo (only meaningful while active)
  property string mode: ""
  property string label: ""
  // test | work: "work" = the agent restarts the shell or similar, not testing; the screens say WORKING instead of TESTING
  property string kind: "test"
  readonly property bool working: kind === "work"
  // what the agent asks the person to help with; empty = no help wanted, so the countdown has no Ctrl+Y key
  property string helpText: ""
  property string startId: ""
  property int countdownTotal: 5
  property int countdownLeft: 0
  property string askId: ""
  property string question: ""
  property int askTotal: 60
  property int askLeft: 0
  // true while the free-text box is open; typeOnly = the question was asked as "text" (Ctrl+Q stops the test)
  property bool typing: false
  property bool typeOnly: false
  // true while the "postpone for how many minutes" box is open (typing is true too)
  property bool postponing: false
  // seconds the countdown stays paused while the postpone box is open
  property int countdownTypeLeft: 0
  property double pausedEnd: 0
  property int pausedLeft: 0
  property int pausedTotal: 0
  property string sayText: ""
  // banner shown when an agent touches the desktop without a session (see bin/talk-to-me-watch)
  property string noticeText: ""
  property double sessionEnd: 0
  property int estimateSec: 0
  // solo tests put an invisible mouse shield over every screen (the person is not helping, so stray clicks would spoil the test)
  property bool shieldOn: true
  // while the agent works every screen is switched to an empty workspace (bin/talk-to-me-hide) and switched back at the end
  property bool hideOn: true
  property bool desktopCleared: false
  property real bannerW: 0
  property real bannerH: 0
  property double activeStart: 0
  property int elapsedSec: 0
  property int sessionLeft: 0
  // Ctrl alone freezes the countdown / question timer so the text can be read (auto-resumes)
  property bool held: false
  property int holdLeft: 0
  property bool ctrlArmed: false
  // input guard: a card that just appeared ignores keys and clicks so typing or clicking elsewhere cannot trigger it
  property bool inputGuarded: false
  property double guardOpenAt: 0
  // text typed in the reply / postpone box (shared by the cards on every screen)
  property string replyText: ""
  // screen whose card owns the keyboard while a prompt is open
  property var promptScreen: null
  // "work is done" card (green checkmark) shown after the agent ends an active session
  // hardware announcements (talk-to-me need cpu|vm|gpu): bin/talk-to-me-hw keeps hw/state.json, this only draws it
  property var hwEntries: []
  property double hwNow: Math.floor(Date.now() / 1000)
  property int hwIdle: 0
  readonly property var hwPills: Model.hwView(root.hwEntries, root.hwNow)

  property bool doneShow: false
  property bool doneFading: false
  property string doneLabel: ""
  property string doneTime: ""

  // gap from the top bar / the screen edge for the corner badge, the question card and the start bar
  readonly property real cornerTop: Style.bar.sizeHorizontal + Style.gapsOut * 2
  readonly property real cornerSide: Style.gapsOut * 2

  signal focusRequested()

  readonly property bool promptOpen: phase === "countdown" || askId !== ""
  // a question card with no testing session behind it (talk-to-me question)
  readonly property bool standalone: phase === "idle" && askId !== ""
  readonly property string promptKind: phase === "countdown" ? "countdown" : "ask"

  readonly property var focusedScreen: {
    const name = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
    const screens = Quickshell.screens
    for (let i = 0; i < screens.length; i++) {
      if (screens[i].name === name) return screens[i]
    }
    return screens.length > 0 ? screens[0] : null
  }

  // ---- result files ------------------------------------------------------------

  Component {
    id: writerComp
    Process {
      id: writer
      property string payload: ""
      stdinEnabled: true
      onStarted: { writer.write(writer.payload); writer.stdinEnabled = false }
      onExited: writer.destroy()
    }
  }

  function writeResult(id, text) {
    const cid = Model.cleanId(id)
    if (!cid || root.runtimeBase === "") return
    const path = root.runtimeDir + "/" + cid + ".result"
    writerComp.createObject(root, {
      command: ["sh", "-c", 'umask 077; mkdir -p "${1%/*}" && cat > "$1.tmp" && mv "$1.tmp" "$1"', "sh", path],
      payload: text + "\n",
      running: true
    })
  }

  // ---- session ----------------------------------------------------------------

  function finishSession(quiet) {
    const celebrate = !quiet && root.phase === "active"
    const label = root.label
    const took = Model.remainingText(root.elapsedSec)
    root.endSession("cancelled", "ended")
    if (!celebrate) return
    root.doneLabel = label
    root.doneTime = took
    root.doneFading = false
    root.doneShow = true
    doneFadeTimer.restart()
    doneHideTimer.restart()
  }

  function startSession(id, rawLabel, rawCountdown, rawMax, rawHelp, rawEstimate, rawShield, rawKind, rawHide) {
    const cid = Model.cleanId(id)
    if (!cid) return "error:bad id"
    if (root.runtimeBase === "") return "error:no XDG_RUNTIME_DIR"
    if (root.phase === "paused") {
      // the person postponed: a start before the pause is over (a retry, another agent) must not override it
      root.writeResult(cid, "postpone:" + Math.max(1, Math.ceil((root.pausedEnd - Date.now()) / 60000)))
      return "ok"
    }
    if (root.phase !== "idle") root.endSession("cancelled", "ended")
    else if (root.askId !== "") root.answer("superseded")
    root.doneShow = false
    root.kind = Model.cleanKind(rawKind)
    root.label = Model.cleanText(rawLabel, Model.DEFAULTS.labelMax) || (root.working ? "Desktop work" : "Desktop testing")
    root.helpText = Model.cleanText(rawHelp, Model.DEFAULTS.longMax)
    root.startId = cid
    root.countdownTotal = Model.clampInt(rawCountdown, 1, 30, Model.DEFAULTS.countdown)
    root.countdownLeft = root.countdownTotal
    const maxMin = Model.clampInt(rawMax, 1, 240, Model.DEFAULTS.maxMinutes)
    root.sessionEnd = Date.now() + (root.countdownTotal + maxMin * 60) * 1000
    root.estimateSec = Model.clampInt(rawEstimate, 0, maxMin * 60, 0)
    root.elapsedSec = 0
    root.shieldOn = String(rawShield) !== "0"
    root.hideOn = String(rawHide) !== "0"
    root.mode = ""
    root.phase = "countdown"
    ticker.restart()
    return "ok"
  }

  function beginActive(nextMode) {
    if (root.phase !== "countdown") return
    root.writeResult(root.startId, nextMode)
    root.startId = ""
    root.mode = nextMode
    root.activeStart = Date.now()
    root.elapsedSec = 0
    root.sessionLeft = Math.max(0, Math.round((root.sessionEnd - Date.now()) / 1000))
    root.phase = "active"
  }

  function endSession(startResult, askResult) {
    if (root.startId !== "") root.writeResult(root.startId, startResult)
    if (root.askId !== "") root.writeResult(root.askId, askResult)
    root.startId = ""
    root.askId = ""
    root.question = ""
    root.typing = false
    root.typeOnly = false
    root.postponing = false
    root.sayText = ""
    root.mode = ""
    root.label = ""
    root.kind = "test"
    root.helpText = ""
    root.sessionLeft = 0
    root.estimateSec = 0
    root.elapsedSec = 0
    root.phase = "idle"
    ticker.stop()
    sayTimer.stop()
  }

  function askQuestion(id, rawQuestion, rawTimeout, rawKind) {
    const cid = Model.cleanId(id)
    if (!cid) return "error:bad id"
    if (root.phase !== "active") {
      root.writeResult(cid, "nosession")
      return "ok"
    }
    if (root.mode === "solo") {
      root.writeResult(cid, "timeout")
      return "ok"
    }
    if (root.askId !== "") root.writeResult(root.askId, "superseded")
    const kind = Model.askKind(rawKind)
    root.question = Model.cleanText(rawQuestion, Model.DEFAULTS.longMax) || "?"
    root.askTotal = Model.clampInt(rawTimeout, 3, 600, kind === "text" ? Model.DEFAULTS.textTimeout : Model.DEFAULTS.askTimeout)
    root.askLeft = root.askTotal
    root.typeOnly = kind === "text"
    root.typing = root.typeOnly
    root.askId = cid
    return "ok"
  }

  function quickQuestion(id, rawQuestion, rawTimeout, rawKind) {
    const cid = Model.cleanId(id)
    if (!cid) return "error:bad id"
    if (root.runtimeBase === "") return "error:no XDG_RUNTIME_DIR"
    if (root.phase === "active") return root.askQuestion(id, rawQuestion, rawTimeout, rawKind)
    if (root.phase !== "idle" || root.askId !== "") {
      root.writeResult(cid, "busy")
      return "ok"
    }
    const kind = Model.askKind(rawKind)
    root.question = Model.cleanText(rawQuestion, Model.DEFAULTS.longMax) || "?"
    root.askTotal = Model.clampInt(rawTimeout, 3, 600, kind === "text" ? Model.DEFAULTS.textTimeout : Model.DEFAULTS.askTimeout)
    root.askLeft = root.askTotal
    root.typeOnly = kind === "text"
    root.typing = root.typeOnly
    root.askId = cid
    ticker.restart()
    return "ok"
  }

  function answer(result) {
    if (root.askId === "") return
    root.writeResult(root.askId, result)
    root.askId = ""
    root.question = ""
    root.typing = false
    root.typeOnly = false
    root.postponing = false
  }

  function openTyping() {
    root.typing = true
    root.askTotal = Math.max(root.askLeft, 90)
    root.askLeft = root.askTotal
  }

  function openPostpone() {
    if (root.standalone) return
    if (root.phase === "countdown") {
      root.countdownTypeLeft = 60
      root.typing = true
    } else if (!root.typing) root.openTyping()
    root.postponing = true
  }

  function submitText(raw) {
    if (root.postponing) {
      const pr = Model.postponeResult(raw)
      if (pr !== "") root.postpone(pr)
      return
    }
    const result = Model.textResult(raw)
    if (result !== "") root.answer(result)
  }

  // Ends the test now; the banner turns into a "paused" pill and the agent gets postpone:<min>.
  function postpone(result) {
    const minutes = parseInt(result.slice(9), 10)
    const lbl = root.label
    const knd = root.kind
    root.endSession(result, result)
    root.label = lbl
    root.kind = knd
    root.pausedEnd = Date.now() + minutes * 60 * 1000
    root.pausedLeft = minutes * 60
    root.pausedTotal = minutes * 60
    root.phase = "paused"
    ticker.restart()
  }

  function escapeTyping() {
    if (root.postponing) {
      root.postponing = false
      if (!root.typeOnly) root.typing = false
    } else if (root.typeOnly) {
      if (root.standalone) root.answer("dismissed")
      else root.endSession("cancelled", "ended")
    }
    else root.typing = false
  }

  function say(rawText) {
    if (root.phase === "idle" || root.phase === "paused") return "error:no session"
    root.sayText = Model.cleanText(rawText, Model.DEFAULTS.longMax)
    if (root.sayText !== "") sayTimer.restart()
    return "ok"
  }

  // Revises the expected duration (seconds from now on, 0 = unknown) while a test runs.
  function eta(rawSeconds) {
    if (root.phase !== "active" && root.phase !== "countdown") return "error:no session"
    const sec = Model.clampInt(rawSeconds, 0, 240 * 60, 0)
    root.estimateSec = sec > 0 ? root.elapsedSec + sec : 0
    return "ok"
  }

  function notice(rawText, rawSeconds) {
    const text = Model.cleanText(rawText, Model.DEFAULTS.longMax)
    if (text === "") return "error:empty"
    if (root.phase !== "idle") return "ok"
    root.noticeText = text
    noticeTimer.interval = Model.clampInt(rawSeconds, 3, 120, 12) * 1000
    noticeTimer.restart()
    return "ok"
  }

  function cancel(id) {
    const cid = Model.cleanId(id)
    if (cid === "") return "error:bad id"
    if (cid === root.startId) root.endSession("cancelled", "ended")
    else if (cid === root.askId) { root.askId = ""; root.question = ""; root.typing = false; root.typeOnly = false; root.postponing = false }
    return "ok"
  }

  function statusText() {
    return Model.statusJson({
      phase: root.phase,
      mode: root.mode,
      label: root.label,
      kind: root.kind,
      question: root.question,
      remainingSec: root.phase === "paused" ? root.pausedLeft : root.sessionLeft,
      estimateSec: root.estimateSec,
      elapsedSec: root.elapsedSec
    })
  }

  function toggleHold() {
    if (!root.promptOpen) return
    root.held = !root.held
    root.holdLeft = Model.DEFAULTS.holdSec
  }

  // true when the press was the Ctrl key (armed for a Ctrl-alone tap)
  function ctrlPress(event) {
    if (event.key === Qt.Key_Control) {
      if (!event.isAutoRepeat) root.ctrlArmed = true
      event.accepted = true
      return true
    }
    root.ctrlArmed = false
    return false
  }

  function ctrlRelease(event) {
    if (event.key !== Qt.Key_Control || event.isAutoRepeat) return
    event.accepted = true
    if (root.ctrlArmed) root.toggleHold()
    root.ctrlArmed = false
  }

  function armGuard() {
    root.guardOpenAt = Date.now()
    root.inputGuarded = true
    guardTimer.interval = Model.DEFAULTS.guardMs
    guardTimer.restart()
  }

  // true when the input must be ignored (and the guard is extended while the person keeps typing or clicking)
  function guardHit() {
    if (!root.inputGuarded) return false
    const now = Date.now()
    guardTimer.interval = Math.max(50, Model.guardUntil(now, root.guardOpenAt) - now)
    guardTimer.restart()
    return true
  }

  Timer { id: guardTimer; onTriggered: root.inputGuarded = false }

  function keyName(event) {
    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) return "enter"
    if (event.key === Qt.Key_Slash || event.key === Qt.Key_Question) return "/"
    if (event.key >= Qt.Key_A && event.key <= Qt.Key_Z) return String.fromCharCode(event.key).toLowerCase()
    return ""
  }

  function handleKey(event) {
    if (event.key !== Qt.Key_Control && root.guardHit()) {
      root.ctrlArmed = false
      event.accepted = true
      return
    }
    if (root.ctrlPress(event)) return
    if (event.isAutoRepeat) { event.accepted = true; return }
    if (root.typing) return
    const action = Model.keyAction(root.promptKind, root.keyName(event), (event.modifiers & Qt.ControlModifier) !== 0)
    if (action === "") return
    event.accepted = true
    root.act(action)
  }

  function resetPrompt() {
    root.replyText = ""
    Qt.callLater(root.focusRequested)
  }

  onTypingChanged: root.resetPrompt()
  onPostponingChanged: root.resetPrompt()
  onAskIdChanged: {
    root.held = false
    if (root.askId !== "") { root.armGuard(); root.resetPrompt() }
  }
  onHeldChanged: if (!root.held && root.promptOpen) root.armGuard()
  onPhaseChanged: {
    if (root.phase === "active" || root.phase === "paused") root.armGuard()
    root.syncHidden()
  }
  onPromptOpenChanged: {
    root.held = false
    if (root.promptOpen) {
      root.armGuard()
      root.promptScreen = root.focusedScreen
      root.resetPrompt()
    }
  }

  function act(action) {
    if (action === "end") {
      if (root.standalone) root.answer("dismissed")
      else root.endSession("cancelled", "ended")
    }
    else if (action === "hold") root.toggleHold()
    else if (action === "type") root.openTyping()
    else if (action === "postpone") root.openPostpone()
    else if (action === "send") root.submitText(root.replyText)
    else if (action === "esc") root.escapeTyping()
    else if (root.promptKind === "countdown") {
      if (action === "start") root.beginActive("solo")
      else if (action !== "human" || root.helpText !== "") root.beginActive(action)
    }
    else root.answer(action)
  }

  Timer {
    id: ticker
    interval: 1000
    repeat: true
    onTriggered: {
      if (root.phase === "idle" && root.askId === "") { ticker.stop(); return }
      if (root.held && root.promptOpen) {
        root.sessionEnd += 1000
        root.activeStart += 1000
        root.holdLeft -= 1
        if (root.holdLeft <= 0) root.held = false
        return
      }
      if (root.phase === "paused") {
        root.pausedLeft = Math.max(0, Math.round((root.pausedEnd - Date.now()) / 1000))
        if (root.pausedLeft <= 0) root.endSession("cancelled", "ended")
        return
      }
      if (root.phase === "countdown" && root.typing) {
        root.countdownTypeLeft -= 1
        if (root.countdownTypeLeft <= 0) root.escapeTyping()
        return
      }
      if (root.phase === "countdown") {
        root.countdownLeft -= 1
        if (root.countdownLeft <= 0) root.beginActive("solo")
      }
      if (root.askId !== "") {
        root.askLeft -= 1
        if (root.askLeft <= 0) root.answer("timeout")
      }
      root.sessionLeft = Math.max(0, Math.round((root.sessionEnd - Date.now()) / 1000))
      if (root.phase === "active") root.elapsedSec = Math.max(0, Math.round((Date.now() - root.activeStart) / 1000))
      if (root.phase !== "idle" && root.sessionLeft <= 0) root.endSession("cancelled", "ended")
    }
  }


  // Hides the person's windows (empty workspace per screen) for as long as a session is working; always switches back.
  readonly property string hideScript: decodeURIComponent(Qt.resolvedUrl("bin/talk-to-me-hide").toString().replace(/^file:\/\//, ""))
  property string hideWanted: ""
  function launchHide() {
    hider.doing = root.hideWanted
    hider.running = true
  }
  function syncHidden() {
    const want = root.phase === "active" && root.hideOn
    if (want === root.desktopCleared) return
    root.desktopCleared = want
    root.hideWanted = want ? "hide" : "restore"
    if (!hider.running) root.launchHide()
  }
  Process {
    id: hider
    property string doing: "restore"
    command: [root.hideScript, hider.doing]
    onExited: if (root.hideWanted !== hider.doing) root.launchHide()
  }
  // a shell restart or crash during a session must not leave the desktop cleared
  Component.onCompleted: { root.hideWanted = "restore"; root.launchHide() }

  // Agent watcher: tells the user when any agent (Claude, Codex, OpenCode, Gemini, ...) opens a window with no session.
  readonly property string watchScript: decodeURIComponent(Qt.resolvedUrl("bin/talk-to-me-watch").toString().replace(/^file:\/\//, ""))
  Process {
    id: watcher
    command: [root.watchScript]
    running: root.watchScript !== ""
    onExited: watchRestart.restart()
  }
  Timer { id: watchRestart; interval: 15000; onTriggered: watcher.running = true }

  Timer { id: noticeTimer; onTriggered: root.noticeText = "" }

  Timer { id: sayTimer; interval: Model.DEFAULTS.sayMs; onTriggered: root.sayText = "" }

  Timer { id: doneFadeTimer; interval: 3000; onTriggered: root.doneFading = true }
  Timer { id: doneHideTimer; interval: 3500; onTriggered: root.doneShow = false }

  IpcHandler {
    target: "talk-to-me"
    function start(id: string, label: string, countdown: string, maxMinutes: string, help: string, estimate: string, shield: string, kind: string, hide: string): string { return root.startSession(id, label, countdown, maxMinutes, help, estimate, shield, kind, hide) }
    function ask(id: string, question: string, timeout: string, kind: string): string { return root.askQuestion(id, question, timeout, kind) }
    function quick(id: string, question: string, timeout: string, kind: string): string { return root.quickQuestion(id, question, timeout, kind) }
    function say(text: string): string { return root.say(text) }
    function eta(seconds: string): string { return root.eta(seconds) }
    function notice(text: string, seconds: string): string { return root.notice(text, seconds) }
    function end(): string { root.finishSession(false); return "ok" }
    function endquiet(): string { root.finishSession(true); return "ok" }
    function cancel(id: string): string { return root.cancel(id) }
    function status(): string { return root.statusText() }
    function ping(): string { return "ok" }
  }

  // ---- banner: corner badge with a time ring (every screen, never takes the keyboard) ----

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: banner
      required property var modelData
      screen: modelData
      visible: root.phase === "active" || root.phase === "paused" || (root.phase === "idle" && root.noticeText !== "")
      anchors { top: true; right: true }
      margins.top: root.cornerTop
      margins.right: root.cornerSide
      implicitWidth: badge.width
      implicitHeight: badge.height
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "background-worker-talk-to-me-banner"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Rectangle {
        id: badge
        readonly property color tone: root.phase === "paused" ? Color.accent : Color.urgent
        readonly property var ringInfo: root.phase === "paused"
          ? { text: Model.remainingText(root.pausedLeft), fraction: root.pausedTotal > 0 ? root.pausedLeft / root.pausedTotal : 0 }
          : Model.badgeRing(root.estimateSec, root.elapsedSec)
        width: Math.min(Style.space(460), Math.max(Style.space(240), badgeRow.implicitWidth + Style.space(24)))
        height: badgeRow.implicitHeight + Style.space(20)
        onWidthChanged: root.bannerW = width
        onHeightChanged: root.bannerH = height
        radius: Style.cornerRadius
        color: Util.alpha(Color.background, 0.96)
        border.width: Math.max(2, Style.space(2))
        border.color: tone

        Row {
          id: badgeRow
          anchors.centerIn: parent
          spacing: Style.space(12)

          Item {
            visible: root.phase !== "idle"
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(54)
            height: width

            Canvas {
              id: ring
              anchors.fill: parent
              readonly property real fraction: badge.ringInfo.fraction
              readonly property string tone: badge.tone.toString()
              onFractionChanged: requestPaint()
              onToneChanged: requestPaint()
              onWidthChanged: requestPaint()
              onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                const lw = Math.max(3, Math.round(width / 11))
                const r = (width - lw) / 2
                ctx.lineWidth = lw
                ctx.strokeStyle = tone
                ctx.globalAlpha = 0.25
                ctx.beginPath()
                ctx.arc(width / 2, height / 2, r, 0, Math.PI * 2)
                ctx.stroke()
                ctx.globalAlpha = 1
                if (fraction > 0) {
                  ctx.beginPath()
                  ctx.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * Math.min(1, fraction))
                  ctx.stroke()
                }
              }
            }
            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: badge.ringInfo.text
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
            }
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              color: badge.tone
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              text: root.phase === "idle" ? "AGENT ACTIVITY: hands off" : root.phase === "paused" ? (root.working ? "Work paused" : "Testing paused") : root.mode === "human" ? (root.working ? "WORKING · you are helping" : "TESTING · you are helping") : (root.working ? "WORKING · hands off" : "TESTING · hands off")
            }
            Text {
              width: Math.min(implicitWidth, Style.space(340))
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              text: root.phase === "idle" ? root.noticeText : root.phase === "paused" ? root.label + "  ·  resumes in " + Model.remainingText(root.pausedLeft) : root.label + (root.mode === "solo" && root.shieldOn ? "  ·  mouse blocked" : "")
            }
            Text {
              readonly property string line: Model.timeLine(root.phase, root.estimateSec, root.elapsedSec)
              visible: line !== ""
              textFormat: Text.PlainText
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              font.bold: true
              text: line
            }
            Text {
              visible: root.sayText !== ""
              width: Math.min(implicitWidth, Style.space(340))
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              text: root.sayText
            }
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: {
            if (root.guardHit()) return
            if (root.phase === "idle") root.noticeText = ""; else root.endSession("cancelled", "ended")
          }
        }
      }
    }
  }

  // ---- hardware pills: who holds or waits for CPU/RAM, a VM or the GPU (every screen, below the badge, click-through) ----

  FileView {
    id: hwFile
    path: root.runtimeDir + "/hw/state.json"
    onLoaded: root.hwEntries = Model.hwParse(hwFile.text())
    onLoadFailed: root.hwEntries = []
  }
  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: {
      root.hwNow = Math.floor(Date.now() / 1000)
      root.hwIdle = (root.hwIdle + 1) % 3
      if (root.hwPills.length > 0 || root.hwIdle === 0) hwFile.reload()
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: hwWin
      required property var modelData
      screen: modelData
      visible: root.hwPills.length > 0
      anchors { bottom: true; right: true }
      margins.bottom: Style.space(16)
      margins.right: root.cornerSide
      implicitWidth: hwCol.width
      implicitHeight: hwCol.height
      color: "transparent"
      mask: Region {}
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "background-worker-talk-to-me-hardware"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Column {
        id: hwCol
        spacing: Style.space(6)

        Repeater {
          model: root.hwPills

          Rectangle {
            id: pill
            required property var modelData
            readonly property color tone: modelData.queued ? Qt.darker(Color.accent, 1.6) : Color.accent
            width: Math.min(Style.space(460), Math.max(Style.space(240), pillRow.implicitWidth + Style.space(20)))
            height: pillRow.implicitHeight + Style.space(14)
            radius: Style.cornerRadius
            color: Util.alpha(Color.background, 0.96)
            border.width: Math.max(2, Style.space(2))
            border.color: tone

            Row {
              id: pillRow
              anchors.centerIn: parent
              spacing: Style.space(10)

              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: kindText.implicitWidth + Style.space(14)
                height: kindText.implicitHeight + Style.space(8)
                radius: height / 2
                color: pill.tone
                Text {
                  id: kindText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: pill.modelData.label
                  color: Color.background
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                }
              }

              Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(2)
                Text {
                  width: Math.min(implicitWidth, Style.space(340))
                  wrapMode: Text.WordWrap
                  textFormat: Text.PlainText
                  color: Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  text: pill.modelData.title
                }
                Text {
                  textFormat: Text.PlainText
                  color: Color.popups.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.bodySmall
                  font.bold: true
                  text: (pill.modelData.queued ? "" : "in use  ·  ") + pill.modelData.line
                }
              }
            }
          }
        }
      }
    }
  }

  // ---- done card: green checkmark that draws itself when the agent ends a test (every screen, no input) ----

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: doneWin
      required property var modelData
      screen: modelData
      visible: root.doneShow
      anchors { top: true; right: true }
      margins.top: root.cornerTop
      margins.right: root.cornerSide
      implicitWidth: doneCard.width
      implicitHeight: doneCard.height
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      mask: Region {}
      WlrLayershell.namespace: "background-worker-talk-to-me-done"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Rectangle {
        id: doneCard
        readonly property color good: "#3fb950"
        property real progress: 0
        width: Math.min(Style.space(420), Math.max(Style.space(240), doneRow.implicitWidth + Style.space(28)))
        height: doneRow.implicitHeight + Style.space(24)
        radius: Style.cornerRadius
        color: Util.alpha(Color.background, 0.96)
        border.width: Math.max(2, Style.space(2))
        border.color: good
        opacity: root.doneFading ? 0 : 1
        transformOrigin: Item.Right
        Behavior on opacity { NumberAnimation { duration: 450; easing.type: Easing.InOutQuad } }

        ParallelAnimation {
          running: root.doneShow
          NumberAnimation { target: doneCard; property: "progress"; from: 0; to: 1; duration: 750; easing.type: Easing.InOutCubic }
          NumberAnimation { target: doneCard; property: "scale"; from: 0.8; to: 1; duration: 500; easing.type: Easing.OutBack }
        }
        onProgressChanged: tick.requestPaint()

        Row {
          id: doneRow
          anchors.centerIn: parent
          spacing: Style.space(14)

          Item {
            anchors.verticalCenter: parent.verticalCenter
            width: Style.space(54)
            height: width

            Canvas {
              id: tick
              anchors.fill: parent
              onWidthChanged: requestPaint()
              onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                const p = doneCard.progress
                const lw = Math.max(3, Math.round(width / 10))
                const r = (width - lw) / 2
                ctx.lineWidth = lw
                ctx.lineCap = "round"
                ctx.lineJoin = "round"
                ctx.strokeStyle = doneCard.good.toString()
                const circle = Math.min(1, p / 0.6)
                if (circle > 0) {
                  ctx.beginPath()
                  ctx.arc(width / 2, height / 2, r, -Math.PI / 2, -Math.PI / 2 + Math.PI * 2 * circle)
                  ctx.stroke()
                }
                const check = Math.max(0, (p - 0.55) / 0.45)
                if (check > 0) {
                  const ax = width * 0.28, ay = height * 0.52
                  const bx = width * 0.44, by = height * 0.67
                  const cx = width * 0.73, cy = height * 0.36
                  ctx.beginPath()
                  ctx.moveTo(ax, ay)
                  const first = Math.min(1, check / 0.4)
                  ctx.lineTo(ax + (bx - ax) * first, ay + (by - ay) * first)
                  if (check > 0.4) {
                    const second = (check - 0.4) / 0.6
                    ctx.lineTo(bx + (cx - bx) * second, by + (cy - by) * second)
                  }
                  ctx.stroke()
                }
              }
            }
          }

          Column {
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              color: doneCard.good
              font.family: Style.font.family
              font.pixelSize: Style.font.body
              font.bold: true
              text: "DONE"
            }
            Text {
              width: Math.min(implicitWidth, Style.space(300))
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              text: root.doneLabel
            }
            Text {
              textFormat: Text.PlainText
              color: Color.popups.text
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
              text: "Finished in " + root.doneTime + " · desktop is yours"
            }
          }
        }
      }
    }
  }

  // ---- mouse shield (solo tests only; the person is not helping, so clicks must not reach the windows) ----
  // Fully transparent so screenshots stay clean; the banner area is cut out so the banner can still end the test.
  // The keyboard is not blocked: the agent's own key presses (wtype) go to the focused window.

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: shield
      required property var modelData
      screen: modelData
      visible: root.phase === "active" && root.mode === "solo" && root.shieldOn && !root.held
      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "background-worker-talk-to-me-shield"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      mask: Region {
        item: shieldFill
        Region {
          intersection: Intersection.Subtract
          x: Math.round(shield.width - root.bannerW - root.cornerSide)
          y: Math.round(root.cornerTop)
          width: root.bannerW
          height: root.bannerH
        }
      }

      Item {
        id: shieldFill
        anchors.fill: parent
        MouseArea {
          anchors.fill: parent
          hoverEnabled: true
          acceptedButtons: Qt.AllButtons
          onWheel: wheel => wheel.accepted = true
        }
      }
    }
  }

  // ---- prompt: top bar for the start countdown, corner card for questions (every screen; the keyboard goes to the focused screen) ----

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: prompt
      required property var modelData
      readonly property bool owner: modelData === root.promptScreen
      readonly property bool bar: root.promptKind === "countdown"
      screen: modelData
      visible: root.promptOpen
      anchors { top: bar; bottom: !bar; right: !bar || root.held }
      margins.top: root.cornerTop
      margins.bottom: root.cornerSide
      margins.right: root.cornerSide
      implicitWidth: card.width
      implicitHeight: card.height
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "background-worker-talk-to-me-prompt"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: !root.promptOpen || !owner ? WlrKeyboardFocus.None : bar && !root.held ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.OnDemand

      function refocus() {
        if (!owner || !visible) return
        if (root.typing && replyField.visible) replyField.forceActiveFocus()
        else keys.forceActiveFocus()
      }

      onVisibleChanged: if (visible) Qt.callLater(refocus)
      onOwnerChanged: Qt.callLater(refocus)

      Connections {
        target: root
        function onFocusRequested() { prompt.refocus() }
      }

      component KeyChip: Rectangle {
        id: chip
        required property var chipData
        readonly property bool primary: chipData.primary === true
        width: chipRow.implicitWidth + Style.space(18)
        height: Math.round(Style.spacing.controlHeight * card.zoom)
        radius: Style.cornerRadius
        color: primary ? Color.accent : chipHover.containsMouse ? Style.hoverFill : Style.normalFill
        border.width: 1
        border.color: primary ? Color.accent : Style.normalBorderColor
        opacity: root.inputGuarded && chipData.action !== "hold" ? 0.4 : 1

        Row {
          id: chipRow
          anchors.centerIn: parent
          spacing: Style.space(6)
          Text {
            textFormat: Text.PlainText
            text: chip.chipData.key
            font.family: Style.font.family
            font.pixelSize: Math.round(Style.font.body * card.zoom)
            font.bold: true
            color: chip.primary ? Color.background : Color.accent
          }
          Text {
            textFormat: Text.PlainText
            text: chip.chipData.text
            font.family: Style.font.family
            font.pixelSize: Math.round(Style.font.body * card.zoom)
            font.bold: chip.primary
            color: chip.primary ? Color.background : Color.popups.text
          }
        }
        MouseArea {
          id: chipHover
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: { if (chip.chipData.action === "hold" || !root.guardHit()) root.act(chip.chipData.action) }
        }
      }

      Rectangle {
        id: card
        readonly property bool compact: root.held
        readonly property real zoom: prompt.bar && !compact ? 1.2 : 1.0
        width: compact ? Style.space(340) : prompt.bar ? Style.space(720) : Style.space(440)
        height: cardCol.implicitHeight + Style.space(28)
        radius: Style.cornerRadius
        color: Util.alpha(Color.background, 0.97)
        border.width: Math.max(2, Style.space(2))
        border.color: root.held ? Color.accent : prompt.bar ? Color.urgent : Color.popups.border

        readonly property var chips: {
          const ctrl = { key: "Ctrl", action: "hold", primary: true, text: root.held ? "resume (auto " + root.holdLeft + " s)" : "pause timer" }
          if (root.postponing) return [ ctrl, { key: "Enter", text: "postpone (min)", action: "send" }, { key: "Ctrl+Q", text: "back", action: "esc" } ]
          if (prompt.bar) {
            const list = [ ctrl ]
            if (root.helpText !== "") list.push({ key: "Ctrl+Y", text: "I'll help", action: "human" })
            list.push({ key: "Ctrl+Enter", text: "start now", action: "start" }, { key: "Ctrl+P", text: "postpone", action: "postpone" }, { key: "Ctrl+Q", text: "cancel", action: "end" })
            return list
          }
          if (root.typing) {
            return root.standalone
              ? [ ctrl, { key: "Enter", text: "send", action: "send" }, { key: "Ctrl+Q", text: root.typeOnly ? "dismiss" : "back", action: "esc" } ]
              : [ ctrl, { key: "Enter", text: "send", action: "send" }, { key: "Ctrl+P", text: "postpone", action: "postpone" }, { key: "Ctrl+Q", text: root.typeOnly ? (root.working ? "stop work" : "stop test") : "back", action: "esc" } ]
          }
          const answers = [ { key: "Ctrl+Y", text: "yes", action: "yes" }, { key: "Ctrl+N", text: "no", action: "no" }, { key: "Ctrl+/", text: "unsure", action: "unsure" }, { key: "Ctrl+T", text: "type", action: "type" } ]
          return root.standalone
            ? [ ctrl ].concat(answers, [ { key: "Ctrl+Q", text: "dismiss", action: "end" } ])
            : [ ctrl ].concat(answers, [ { key: "Ctrl+P", text: "postpone", action: "postpone" }, { key: "Ctrl+Q", text: root.working ? "stop work" : "stop test", action: "end" } ])
        }

        MouseArea {
          anchors.fill: parent
          onPressed: mouse => { prompt.refocus(); mouse.accepted = false }
        }

        FocusScope {
          id: keys
          anchors.fill: parent
          focus: true
          Keys.onPressed: event => root.handleKey(event)
          Keys.onReleased: event => root.ctrlRelease(event)
        }

        Column {
          id: cardCol
          anchors.centerIn: parent
          width: card.width - Style.space(32)
          spacing: Style.space(10)

          Row {
            width: parent.width
            spacing: Style.space(16)

            Text {
              visible: prompt.bar
              anchors.verticalCenter: parent.verticalCenter
              width: visible ? Style.space(card.compact ? 56 : 96) : 0
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: root.countdownLeft
              font.family: Style.font.family
              font.pixelSize: Math.round(Style.font.displayLarge * (card.compact ? 1.0 : 1.8))
              font.bold: true
              color: root.held ? Util.alpha(Color.popups.text, 0.4) : Color.urgent
            }

            Column {
              width: parent.width - (prompt.bar ? Style.space(card.compact ? 72 : 112) : 0)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)

              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                color: Color.urgent
                font.family: Style.font.family
                font.pixelSize: Math.round(Style.font.bodySmall * card.zoom)
                font.bold: true
                font.letterSpacing: 1
                text: root.inputGuarded
                  ? "KEYS AND CLICKS IGNORED FOR A MOMENT · KEEP TYPING, NOTHING TRIGGERS"
                  : prompt.bar
                  ? (root.held ? "PAUSED: NOTHING STARTS · YOUR KEYBOARD AND MOUSE ARE FREE" : "HEADS UP: AN AGENT STARTS " + (root.working ? "WORKING ON YOUR DESKTOP" : "TESTING") + " IN " + root.countdownLeft + " s")
                  : (root.standalone ? "AGENT ASKS" : "AGENT ASKS · " + root.askLeft + " s")
              }
              Text {
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Math.round((prompt.bar ? Style.font.title : Style.font.heading) * card.zoom)
                font.bold: true
                text: prompt.bar ? root.label : root.question
              }
              Text {
                visible: prompt.bar && !card.compact && root.helpText !== ""
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                color: Color.popups.text
                font.family: Style.font.family
                font.pixelSize: Math.round(Style.font.body * card.zoom)
                font.bold: true
                text: "Faster with your help: " + root.helpText
              }
              Text {
                visible: prompt.bar && !card.compact
                width: parent.width
                wrapMode: Text.WordWrap
                textFormat: Text.PlainText
                color: Util.alpha(Color.popups.text, 0.8)
                font.family: Style.font.family
                font.pixelSize: Math.round(Style.font.body * card.zoom)
                text: (root.estimateSec > 0 ? "Expected: " + Model.estimateLabel(root.estimateSec) + ". " : "") + "It starts alone if you do nothing. Keep your hands off keyboard and mouse once it runs."
              }
            }
          }

          // Drawn by the plugin (no Qt text input): those read the clipboard by themselves. Paste goes through a separate `wl-paste` process on Ctrl+V / Shift+Insert only.
          PlainField {
            id: replyField
            visible: root.typing
            width: parent.width
            height: Style.spacing.controlHeight
            horizontalPadding: Style.space(10)
            maximumLength: root.postponing ? 4 : 500
            digitsOnly: root.postponing
            foreground: Color.popups.text
            placeholderText: root.postponing ? "Postpone for how many minutes? Enter sends" : "Click here, type your answer, Enter sends"
            font: Qt.font({ family: Style.font.family, pixelSize: Math.round(Style.font.body * card.zoom) })
            onVisibleChanged: if (visible) prompt.refocus()
            onTextEdited: root.replyText = text
            Binding { target: replyField; property: "text"; value: root.replyText }
            onKeyDown: event => root.ctrlPress(event)
            Keys.onReturnPressed: root.submitText(text)
            Keys.onEnterPressed: root.submitText(text)
            Keys.onReleased: event => root.ctrlRelease(event)
            Keys.onPressed: event => {
              if ((event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_Q) {
                event.accepted = true
                root.escapeTyping()
                return
              }
              if (!root.postponing && (event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_P) {
                event.accepted = true
                root.openPostpone()
              }
            }
          }

          Flow {
            width: parent.width
            spacing: Style.space(8)
            Repeater {
              model: card.chips
              KeyChip { required property var modelData; chipData: modelData }
            }
          }

          Text {
            visible: !prompt.bar && !card.compact && !root.typing && !root.postponing
            width: parent.width
            wrapMode: Text.WordWrap
            textFormat: Text.PlainText
            font.family: Style.font.family
            font.pixelSize: Math.round(Style.font.bodySmall * card.zoom)
            color: Util.alpha(Color.popups.text, 0.6)
            text: "Your keyboard stays free. Click this card to answer with keys, or click a button."
          }

          Rectangle {
            width: parent.width
            height: Math.max(Style.space(3), Style.spacing.xs)
            color: Util.alpha(Color.popups.text, 0.2)
            Rectangle {
              height: parent.height
              readonly property real total: prompt.bar ? root.countdownTotal : root.askTotal
              readonly property real remaining: prompt.bar ? root.countdownLeft : root.askLeft
              width: parent.width * (total > 0 ? remaining / total : 0)
              color: root.held ? Util.alpha(Color.popups.text, 0.4) : prompt.bar ? Color.urgent : Color.accent
              Behavior on width { NumberAnimation { duration: 900 } }
            }
          }
        }
      }
    }
  }
}
