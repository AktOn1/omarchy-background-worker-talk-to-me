// Human Test Mode: service. Shows a TESTING banner while a script or agent changes the
// desktop, a countdown at the start, and a one-key question card on request.
//
// The keyboard is grabbed only while the countdown or a question is on screen. The banner
// never takes the keyboard.
//
// IPC (target "htm"; the `htm` command wraps these and polls the result files):
//   start <id> <label> <countdownSec> <maxMinutes>   countdown, result file: human | solo | cancelled
//   ask <id> <question> <timeoutSec>                 result file: yes | no | unsure | timeout | ended
//   say <text> | end | cancel <id> | status | ping
// Result files: $XDG_RUNTIME_DIR/htm/<id>.result (the id is validated, no paths from callers).

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import "HtmModel.js" as Model

Scope {
  id: root

  property var omarchyPath
  property var shell
  property var manifest

  readonly property string runtimeBase: Quickshell.env("XDG_RUNTIME_DIR") || ""
  readonly property string runtimeDir: runtimeBase + "/htm"

  // idle | countdown | active
  property string phase: "idle"
  // human | solo (only meaningful while active)
  property string mode: ""
  property string label: ""
  property string startId: ""
  property int countdownTotal: 5
  property int countdownLeft: 0
  property string askId: ""
  property string question: ""
  property int askTotal: 60
  property int askLeft: 0
  property string sayText: ""
  property double sessionEnd: 0
  property int sessionLeft: 0

  readonly property bool promptOpen: phase === "countdown" || askId !== ""
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
      onExited: writer.destroy()
    }
  }

  function writeResult(id, text) {
    const cid = Model.cleanId(id)
    if (!cid || root.runtimeBase === "") return
    const path = root.runtimeDir + "/" + cid + ".result"
    writerComp.createObject(root, {
      command: ["sh", "-c", 'umask 077; mkdir -p "${2%/*}" && printf "%s\\n" "$1" > "$2.tmp" && mv "$2.tmp" "$2"', "sh", text, path],
      running: true
    })
  }

  // ---- session ----------------------------------------------------------------

  function startSession(id, rawLabel, rawCountdown, rawMax) {
    const cid = Model.cleanId(id)
    if (!cid) return "error:bad id"
    if (root.runtimeBase === "") return "error:no XDG_RUNTIME_DIR"
    if (root.phase !== "idle") root.endSession("cancelled", "ended")
    root.label = Model.cleanText(rawLabel, 60) || "Desktop testing"
    root.startId = cid
    root.countdownTotal = Model.clampInt(rawCountdown, 1, 30, Model.DEFAULTS.countdown)
    root.countdownLeft = root.countdownTotal
    const maxMin = Model.clampInt(rawMax, 1, 240, Model.DEFAULTS.maxMinutes)
    root.sessionEnd = Date.now() + (root.countdownTotal + maxMin * 60) * 1000
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
    root.sessionLeft = Math.max(0, Math.round((root.sessionEnd - Date.now()) / 1000))
    root.phase = "active"
  }

  function endSession(startResult, askResult) {
    if (root.startId !== "") root.writeResult(root.startId, startResult)
    if (root.askId !== "") root.writeResult(root.askId, askResult)
    root.startId = ""
    root.askId = ""
    root.question = ""
    root.sayText = ""
    root.mode = ""
    root.label = ""
    root.sessionLeft = 0
    root.phase = "idle"
    ticker.stop()
    sayTimer.stop()
  }

  function askQuestion(id, rawQuestion, rawTimeout) {
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
    root.question = Model.cleanText(rawQuestion, 160) || "?"
    root.askTotal = Model.clampInt(rawTimeout, 3, 600, Model.DEFAULTS.askTimeout)
    root.askLeft = root.askTotal
    root.askId = cid
    return "ok"
  }

  function answer(result) {
    if (root.askId === "") return
    root.writeResult(root.askId, result)
    root.askId = ""
    root.question = ""
  }

  function say(rawText) {
    if (root.phase === "idle") return "error:no session"
    root.sayText = Model.cleanText(rawText, 160)
    if (root.sayText !== "") sayTimer.restart()
    return "ok"
  }

  function cancel(id) {
    const cid = Model.cleanId(id)
    if (cid === "") return "error:bad id"
    if (cid === root.startId) root.endSession("cancelled", "ended")
    else if (cid === root.askId) { root.askId = ""; root.question = "" }
    return "ok"
  }

  function statusText() {
    return Model.statusJson({
      phase: root.phase,
      mode: root.mode,
      label: root.label,
      question: root.question,
      remainingSec: root.sessionLeft
    })
  }

  function handleKey(event) {
    const action = Model.keyAction(root.promptKind, event.text, event.key === Qt.Key_Escape)
    if (action === "") return
    event.accepted = true
    root.act(action)
  }

  function act(action) {
    if (action === "end") root.endSession("cancelled", "ended")
    else if (root.promptKind === "countdown") root.beginActive(action)
    else root.answer(action)
  }

  Timer {
    id: ticker
    interval: 1000
    repeat: true
    onTriggered: {
      if (root.phase === "countdown") {
        root.countdownLeft -= 1
        if (root.countdownLeft <= 0) root.beginActive("solo")
      }
      if (root.askId !== "") {
        root.askLeft -= 1
        if (root.askLeft <= 0) root.answer("timeout")
      }
      root.sessionLeft = Math.max(0, Math.round((root.sessionEnd - Date.now()) / 1000))
      if (root.phase !== "idle" && root.sessionLeft <= 0) root.endSession("cancelled", "ended")
    }
  }

  Timer { id: sayTimer; interval: Model.DEFAULTS.sayMs; onTriggered: root.sayText = "" }

  IpcHandler {
    target: "htm"
    function start(id: string, label: string, countdown: string, maxMinutes: string): string { return root.startSession(id, label, countdown, maxMinutes) }
    function ask(id: string, question: string, timeout: string): string { return root.askQuestion(id, question, timeout) }
    function say(text: string): string { return root.say(text) }
    function end(): string { root.endSession("cancelled", "ended"); return "ok" }
    function cancel(id: string): string { return root.cancel(id) }
    function status(): string { return root.statusText() }
    function ping(): string { return "ok" }
  }

  // ---- banner (every screen, never takes the keyboard) -------------------------

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: banner
      required property var modelData
      screen: modelData
      visible: root.phase !== "idle"
      anchors { top: true }
      margins.top: Style.bar.sizeHorizontal + Style.gapsOut * 2
      implicitWidth: pill.width
      implicitHeight: pill.height
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore
      WlrLayershell.namespace: "human-test-mode-banner"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      Rectangle {
        id: pill
        width: Math.max(Style.space(220), bannerCol.implicitWidth + Style.space(28))
        height: bannerCol.implicitHeight + Style.space(14)
        radius: Style.cornerRadius
        color: Color.urgent
        border.width: Math.max(1, Style.space(1))
        border.color: Util.alpha(Color.background, 0.6)

        Column {
          id: bannerCol
          anchors.centerIn: parent
          spacing: Style.space(2)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            color: Color.background
            font.family: Style.font.family
            font.pixelSize: Style.font.title
            font.bold: true
            text: "TESTING in progress"
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            color: Color.background
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
            text: root.label + (root.mode === "" ? "" : "  ·  " + (root.mode === "human" ? "you are helping" : "solo")) + (root.phase === "active" ? "  ·  " + Model.remainingText(root.sessionLeft) : "")
          }
          Text {
            visible: root.sayText !== ""
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.min(implicitWidth, Style.space(520))
            horizontalAlignment: Text.AlignHCenter
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Color.background
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            text: root.sayText
          }
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.PointingHandCursor
          onClicked: root.endSession("cancelled", "ended")
        }
      }
    }
  }

  // ---- prompt card (focused screen, keyboard grab only while open) ------------

  PanelWindow {
    id: prompt
    screen: root.focusedScreen
    visible: root.promptOpen
    anchors { bottom: true }
    margins.bottom: Style.space(67)
    implicitWidth: card.width
    implicitHeight: card.height
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "human-test-mode-prompt"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: root.promptOpen ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None

    onVisibleChanged: if (visible) keys.forceActiveFocus()

    Rectangle {
      id: card
      width: Math.max(Style.space(380), Math.min(Style.space(640), cardCol.implicitWidth + Style.space(40)))
      height: cardCol.implicitHeight + Style.space(32)
      radius: Style.cornerRadius
      color: Util.alpha(Color.background, 0.97)
      border.width: Math.max(1, Style.space(2))
      border.color: Color.popups.border

      FocusScope {
        id: keys
        anchors.fill: parent
        focus: true
        Keys.onPressed: event => root.handleKey(event)
      }

      Column {
        id: cardCol
        anchors.centerIn: parent
        width: card.width - Style.space(40)
        spacing: Style.space(12)

        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          color: Color.popups.text
          font.family: Style.font.family
          font.pixelSize: root.promptKind === "countdown" ? Style.font.title : Style.font.heading
          font.bold: true
          text: root.promptKind === "countdown" ? root.label + " is about to start" : root.question
        }

        Row {
          visible: root.promptKind === "countdown"
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(14)
          Repeater {
            model: root.countdownTotal
            Text {
              required property int index
              readonly property int n: root.countdownTotal - index
              textFormat: Text.PlainText
              text: n
              font.family: Style.font.family
              font.pixelSize: Style.font.displayLarge
              font.bold: n === root.countdownLeft
              color: n === root.countdownLeft ? Color.accent : Util.alpha(Color.popups.text, n > root.countdownLeft ? 0.25 : 0.6)
            }
          }
        }

        Rectangle {
          visible: root.promptKind === "ask"
          width: parent.width
          height: Math.max(Style.space(3), Style.spacing.xs)
          color: Util.alpha(Color.popups.text, 0.2)
          Rectangle {
            height: parent.height
            width: parent.width * (root.askTotal > 0 ? root.askLeft / root.askTotal : 0)
            color: Color.accent
            Behavior on width { NumberAnimation { duration: 900 } }
          }
        }

        Row {
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(10)

          Repeater {
            model: root.promptKind === "countdown"
              ? [ { key: "Y", text: "I'm here", action: "human" }, { key: "Esc", text: "cancel", action: "end" } ]
              : [ { key: "Y", text: "yes", action: "yes" }, { key: "N", text: "no", action: "no" }, { key: "?", text: "can't tell", action: "unsure" }, { key: "Esc", text: "stop test", action: "end" } ]

            Rectangle {
              required property var modelData
              width: keyRow.implicitWidth + Style.space(20)
              height: Style.spacing.controlHeight
              radius: Style.cornerRadius
              color: hover.containsMouse ? Style.hoverFill : Style.normalFill
              border.width: 1
              border.color: Style.normalBorderColor

              Row {
                id: keyRow
                anchors.centerIn: parent
                spacing: Style.space(6)
                Text {
                  textFormat: Text.PlainText
                  text: modelData.key
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                  color: Color.accent
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData.text
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  color: Color.popups.text
                }
              }
              MouseArea {
                id: hover
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.act(modelData.action)
              }
            }
          }
        }
      }
    }
  }
}
