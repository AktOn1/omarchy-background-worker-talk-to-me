// Background Worker Talk To Me: service. Shows a TESTING banner while a script or agent changes the
// desktop, a countdown at the start, and a one-key question card on request.
//
// The start countdown is a top bar, questions a card in the bottom-right corner, the TESTING banner a badge with a time ring in the
// top-right corner. All show on every screen. The keyboard is grabbed only while the countdown or a question is on screen. The banner
// never takes the keyboard.
//
// IPC (target "talk-to-me"; the `talk-to-me` command wraps these and polls the result files):
//   start <id> <label> <countdownSec> <maxMinutes> <help> <estimateSec> <shield>   countdown (Y only when <help> is non-empty), result file: human | solo | cancelled | postpone:<min>
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
  // what the agent asks the person to help with; empty = no help wanted, so the countdown has no Y key
  property string helpText: ""
  property string startId: ""
  property int countdownTotal: 5
  property int countdownLeft: 0
  property string askId: ""
  property string question: ""
  property int askTotal: 60
  property int askLeft: 0
  // true while the free-text box is open; typeOnly = the question was asked as "text" (Esc stops the test)
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
  property real bannerW: 0
  property real bannerH: 0
  property double activeStart: 0
  property int elapsedSec: 0
  property int sessionLeft: 0
  // Ctrl alone freezes the countdown / question timer so the text can be read (auto-resumes)
  property bool held: false
  property int holdLeft: 0
  property bool ctrlArmed: false
  // text typed in the reply / postpone box (shared by the cards on every screen)
  property string replyText: ""
  // screen whose card owns the keyboard while a prompt is open
  property var promptScreen: null

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

  function startSession(id, rawLabel, rawCountdown, rawMax, rawHelp, rawEstimate, rawShield) {
    const cid = Model.cleanId(id)
    if (!cid) return "error:bad id"
    if (root.runtimeBase === "") return "error:no XDG_RUNTIME_DIR"
    if (root.phase !== "idle") root.endSession("cancelled", "ended")
    else if (root.askId !== "") root.answer("superseded")
    root.label = Model.cleanText(rawLabel, 60) || "Desktop testing"
    root.helpText = Model.cleanText(rawHelp, 160)
    root.startId = cid
    root.countdownTotal = Model.clampInt(rawCountdown, 1, 30, Model.DEFAULTS.countdown)
    root.countdownLeft = root.countdownTotal
    const maxMin = Model.clampInt(rawMax, 1, 240, Model.DEFAULTS.maxMinutes)
    root.sessionEnd = Date.now() + (root.countdownTotal + maxMin * 60) * 1000
    root.estimateSec = Model.clampInt(rawEstimate, 0, maxMin * 60, 0)
    root.elapsedSec = 0
    root.shieldOn = String(rawShield) !== "0"
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
    root.question = Model.cleanText(rawQuestion, 160) || "?"
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
    root.question = Model.cleanText(rawQuestion, 160) || "?"
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
    root.endSession(result, result)
    root.label = lbl
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
    root.sayText = Model.cleanText(rawText, 160)
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
    const text = Model.cleanText(rawText, 160)
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

  function handleKey(event) {
    if (root.ctrlPress(event)) return
    if (root.typing) return
    const enter = event.key === Qt.Key_Return || event.key === Qt.Key_Enter
    const action = Model.keyAction(root.promptKind, enter ? "\n" : event.text, event.key === Qt.Key_Escape)
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
    if (root.askId !== "") root.resetPrompt()
  }
  onPromptOpenChanged: {
    root.held = false
    if (root.promptOpen) {
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

  RegularExpressionValidator { id: minutesValidator; regularExpression: /[0-9]{0,4}/ }

  // Agent watcher: tells the user when any agent (Claude, Codex, OpenCode, Gemini, ...) opens a window with no session.
  readonly property string watchScript: Qt.resolvedUrl("bin/talk-to-me-watch").toString().replace(/^file:\/\//, "")
  Process {
    id: watcher
    command: [root.watchScript]
    running: root.watchScript !== ""
    onExited: watchRestart.restart()
  }
  Timer { id: watchRestart; interval: 15000; onTriggered: watcher.running = true }

  Timer { id: noticeTimer; onTriggered: root.noticeText = "" }

  Timer { id: sayTimer; interval: Model.DEFAULTS.sayMs; onTriggered: root.sayText = "" }

  IpcHandler {
    target: "talk-to-me"
    function start(id: string, label: string, countdown: string, maxMinutes: string, help: string, estimate: string, shield: string): string { return root.startSession(id, label, countdown, maxMinutes, help, estimate, shield) }
    function ask(id: string, question: string, timeout: string, kind: string): string { return root.askQuestion(id, question, timeout, kind) }
    function quick(id: string, question: string, timeout: string, kind: string): string { return root.quickQuestion(id, question, timeout, kind) }
    function say(text: string): string { return root.say(text) }
    function eta(seconds: string): string { return root.eta(seconds) }
    function notice(text: string, seconds: string): string { return root.notice(text, seconds) }
    function end(): string { root.endSession("cancelled", "ended"); return "ok" }
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
              text: root.phase === "idle" ? "AGENT ACTIVITY: hands off" : root.phase === "paused" ? "Testing paused" : root.mode === "human" ? "TESTING · you are helping" : "TESTING · hands off"
            }
            Text {
              width: Math.min(implicitWidth, Style.space(340))
              elide: Text.ElideRight
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
          onClicked: { if (root.phase === "idle") root.noticeText = ""; else root.endSession("cancelled", "ended") }
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
      anchors { top: bar; bottom: !bar; right: !bar }
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
        if (root.typing) replyInput.forceActiveFocus()
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
          onClicked: root.act(chip.chipData.action)
        }
      }

      Rectangle {
        id: card
        readonly property real zoom: prompt.bar ? 1.2 : 1.0
        width: prompt.bar ? Style.space(720) : Style.space(440)
        height: cardCol.implicitHeight + Style.space(28)
        radius: Style.cornerRadius
        color: Util.alpha(Color.background, 0.97)
        border.width: Math.max(2, Style.space(2))
        border.color: root.held ? Color.accent : prompt.bar ? Color.urgent : Color.popups.border

        readonly property var chips: {
          const ctrl = { key: "Ctrl", action: "hold", primary: true, text: root.held ? "resume (auto " + root.holdLeft + " s)" : "pause timer" }
          if (root.postponing) return [ ctrl, { key: "Enter", text: "postpone (min)", action: "send" }, { key: "Esc", text: "back", action: "esc" } ]
          if (prompt.bar) {
            const list = [ ctrl ]
            if (root.helpText !== "") list.push({ key: "Y", text: "I'll help", action: "human" })
            list.push({ key: "Enter", text: "start now", action: "start" }, { key: "P", text: "postpone", action: "postpone" }, { key: "Esc", text: "cancel", action: "end" })
            return list
          }
          if (root.typing) {
            return root.standalone
              ? [ ctrl, { key: "Enter", text: "send", action: "send" }, { key: "Esc", text: root.typeOnly ? "dismiss" : "back", action: "esc" } ]
              : [ ctrl, { key: "Enter", text: "send", action: "send" }, { key: "Ctrl+P", text: "postpone", action: "postpone" }, { key: "Esc", text: root.typeOnly ? "stop test" : "back", action: "esc" } ]
          }
          const answers = [ { key: "Y", text: "yes", action: "yes" }, { key: "N", text: "no", action: "no" }, { key: "?", text: "unsure", action: "unsure" }, { key: "T", text: "type", action: "type" } ]
          return root.standalone
            ? [ ctrl ].concat(answers, [ { key: "Esc", text: "dismiss", action: "end" } ])
            : [ ctrl ].concat(answers, [ { key: "P", text: "postpone", action: "postpone" }, { key: "Esc", text: "stop test", action: "end" } ])
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
              width: visible ? Style.space(96) : 0
              horizontalAlignment: Text.AlignHCenter
              textFormat: Text.PlainText
              text: root.countdownLeft
              font.family: Style.font.family
              font.pixelSize: Math.round(Style.font.displayLarge * 1.8)
              font.bold: true
              color: root.held ? Util.alpha(Color.popups.text, 0.4) : Color.urgent
            }

            Column {
              width: parent.width - (prompt.bar ? Style.space(112) : 0)
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
                text: prompt.bar
                  ? (root.held ? "PAUSED: NOTHING STARTS · YOUR KEYBOARD AND MOUSE ARE FREE" : "HEADS UP: AN AGENT STARTS TESTING IN " + root.countdownLeft + " s")
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
                visible: prompt.bar && root.helpText !== ""
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
                visible: prompt.bar
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

          Rectangle {
            visible: root.typing
            width: parent.width
            height: Style.spacing.controlHeight
            radius: Style.cornerRadius
            color: Style.normalFill
            border.width: 1
            border.color: replyInput.activeFocus ? Color.accent : Style.normalBorderColor

            TextInput {
              id: replyInput
              anchors.fill: parent
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              verticalAlignment: TextInput.AlignVCenter
              clip: true
              maximumLength: root.postponing ? 4 : 500
              inputMethodHints: root.postponing ? Qt.ImhDigitsOnly : Qt.ImhNone
              validator: root.postponing ? minutesValidator : null
              color: Color.popups.text
              selectionColor: Color.accent
              font.family: Style.font.family
              font.pixelSize: Math.round(Style.font.body * card.zoom)
              Keys.onReturnPressed: root.submitText(text)
              Keys.onEnterPressed: root.submitText(text)
              Keys.onEscapePressed: root.escapeTyping()
              onTextEdited: root.replyText = text
              Binding { target: replyInput; property: "text"; value: root.replyText }
              Keys.onReleased: event => root.ctrlRelease(event)
              Keys.onPressed: event => {
                if (root.ctrlPress(event)) return
                if (!root.postponing && (event.modifiers & Qt.ControlModifier) && event.key === Qt.Key_P) {
                  event.accepted = true
                  root.openPostpone()
                }
              }
            }
            Text {
              visible: replyInput.text === ""
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.postponing ? "Postpone for how many minutes? Enter sends" : "Click here, type your answer, Enter sends"
              font.family: Style.font.family
              font.pixelSize: Math.round(Style.font.body * card.zoom)
              color: Util.alpha(Color.popups.text, 0.45)
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
            visible: !prompt.bar && !root.typing && !root.postponing
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
