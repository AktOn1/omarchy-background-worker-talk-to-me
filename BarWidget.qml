import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "TalkToMeModel.js" as Model

// The bar icon of Agent Handshake: a small chip. It shows who is using the screen, the CPU/RAM, a VM or the GPU right now
// (and who waits in line), lets you release an entry, and holds every setting of the plugin. Hardware state is read from
// $XDG_RUNTIME_DIR/talk-to-me/hw/state.json (written by bin/talk-to-me-hw); settings go through `talk-to-me settings [set KEY VALUE]`.
BarWidget {
  id: root
  moduleName: "io.github.akton1.background-worker-talk-to-me"

  readonly property string pluginId: "io.github.akton1.background-worker-talk-to-me"
  readonly property string cli: decodeURIComponent(Qt.resolvedUrl("bin/talk-to-me").toString().replace(/^file:\/\//, ""))
  readonly property string runtimeDir: (Quickshell.env("XDG_RUNTIME_DIR") || ("/run/user/" + Quickshell.env("UID"))) + "/talk-to-me"
  // popup content sits on Color.popups.background; bar.barForeground flips dark over a bright wallpaper, so only the bar icon may use it
  readonly property color fg: Color.popups.text

  property var entries: []
  property double nowSec: Date.now() / 1000
  readonly property var pills: Model.hwView(root.entries, root.nowSec)
  property var conf: ({})
  property string screenLine: ""
  property string flash: ""

  function fgA(a) { return Qt.rgba(fg.r, fg.g, fg.b, a) }
  function say(t) { root.flash = t; flashTimer.restart() }
  Timer { id: flashTimer; interval: 2500; onTriggered: root.flash = "" }

  // ---------------------------------------------------------------- state
  FileView {
    id: hwFile
    path: root.runtimeDir + "/hw/state.json"
    printErrors: false
    onLoaded: root.entries = Model.hwParse(text())
    onLoadFailed: root.entries = []
  }
  Timer {
    interval: 1000
    running: true
    repeat: true
    property int tick: 0
    onTriggered: {
      root.nowSec = Date.now() / 1000
      tick++
      if (root.popupOpen || root.pills.length > 0 || tick % 3 === 0) hwFile.reload()
      if (root.popupOpen && tick % 2 === 0) statusProc.running = true
    }
  }
  Process {
    id: statusProc
    command: ["bash", "-c", '"$1" status 2>/dev/null', "bash", root.cli]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var s = JSON.parse(String(text).trim())
          if (s.phase === "idle" || !s.phase) root.screenLine = "Screen: free"
          else root.screenLine = "Screen: " + (s.label || s.phase) + " (" + s.phase + ")"
        } catch (e) { root.screenLine = "" }
      }
    }
  }
  Process {
    id: confProc
    command: ["bash", "-c", '"$1" settings 2>/dev/null', "bash", root.cli]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var c = {}
        String(text).split("\n").forEach(function(l) {
          var m = l.trim().split(/\s+/)
          if (m.length >= 2) c[m[0]] = m[1]
        })
        root.conf = c
      }
    }
  }
  Process {
    id: setProc
    onExited: confProc.running = true
  }
  function setKey(k, v) {
    var c = Object.assign({}, root.conf); c[k] = String(v); root.conf = c
    setProc.command = [root.cli, "settings", "set", k, String(v)]
    setProc.running = true
  }
  function isOn(k) { return root.conf[k] === "on" }
  function num(k, d) { var n = parseInt(root.conf[k]); return isNaN(n) ? d : n }
  function release(args) {
    relProc.command = [root.cli, "release"].concat(args)
    relProc.running = true
  }
  Process {
    id: relProc
    onExited: { hwFile.reload(); root.say("Released") }
  }

  // ---------------------------------------------------------------- open / close
  property bool popupOpen: false
  readonly property bool opened: popupOpen
  property bool popoutSwitchClosing: false
  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function toggle() { popupOpen = !popupOpen }
  function closeForPopoutSwitch() {
    popoutSwitchClosing = true
    popupOpen = false
    Qt.callLater(function() { popoutSwitchClosing = false })
  }
  onPopupOpenChanged: {
    if (popupOpen) {
      confProc.running = true
      statusProc.running = true
      hwFile.reload()
      wn.refresh()
    } else {
      wn.close()
    }
  }

  IpcHandler {
    target: "io.github.akton1.background-worker-talk-to-me.menu"
    function toggle(): void { root.toggle() }
    function open(): void { root.open() }
    function close(): void { root.close() }
  }

  // ---------------------------------------------------------------- the bar icon
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    active: root.pills.length > 0 || root.popupOpen
    tooltipText: {
      if (root.pills.length === 0) return "Agent Handshake\nno hardware announced\nclick: settings and queue"
      return "Agent Handshake\n" + root.pills.map(function(p) {
        return p.label + (p.queued ? " (waiting #" + p.position + ")" : "") + ": " + p.title
      }).join("\n") + "\nclick: settings and queue"
    }
    iconComponent: Component {
      Item {
        Canvas {
          id: chip
          anchors.centerIn: parent
          width: Style.bar.iconCanvas
          height: Style.bar.iconCanvas
          property color ink: root.bar.barForeground // bar-icon
          property bool busy: root.pills.length > 0
          onInkChanged: requestPaint()
          onBusyChanged: requestPaint()
          onWidthChanged: requestPaint()
          onPaint: {
            var ctx = getContext("2d")
            ctx.reset()
            var w = width
            ctx.strokeStyle = ink
            ctx.fillStyle = Qt.rgba(ink.r, ink.g, ink.b, busy ? 0.45 : 0)
            ctx.lineWidth = Math.max(1.3, w * 0.07)
            ctx.lineCap = "round"
            ctx.lineJoin = "round"
            var l = w * 0.26, r = w * 0.74, t = w * 0.26, b = w * 0.74
            ctx.beginPath(); ctx.rect(l, t, r - l, b - t); ctx.fill(); ctx.stroke()
            ctx.beginPath()
            for (var i = 0; i < 3; i++) {
              var p = l + (r - l) * (i + 0.5) / 3
              ctx.moveTo(p, t); ctx.lineTo(p, w * 0.12)
              ctx.moveTo(p, b); ctx.lineTo(p, w * 0.88)
              ctx.moveTo(l, p - l + t); ctx.lineTo(w * 0.12, p - l + t)
              ctx.moveTo(r, p - l + t); ctx.lineTo(w * 0.88, p - l + t)
            }
            ctx.stroke()
          }
        }
      }
    }
    onPressed: function(b) { root.toggle() }
  }

  // ---------------------------------------------------------------- the panel
  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(440))
    contentHeight: popup.fittedContentHeight(body.implicitHeight, Style.space(640))

    Item { id: overlay; anchors.fill: parent; z: 10 }

    Flickable {
      id: flick
      anchors.fill: parent
      contentWidth: width
      contentHeight: body.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds

      Column {
        id: body
        width: flick.width
        spacing: Style.space(4)

        Item {
          width: body.width
          height: Style.space(28)
          Text {
            anchors.left: parent.left
            anchors.leftMargin: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter
            text: "Agent Handshake"
            color: root.fg
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
          }
          WhatsNewButton {
            id: wn
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            pluginId: root.pluginId
            flyoutParent: overlay
            fg: root.fg
            fontFamily: root.bar.fontFamily
            keyHint: ""
          }
        }

        Text {
          width: body.width
          leftPadding: Style.space(6)
          text: root.screenLine
          visible: text !== ""
          color: root.fg
          opacity: 0.75
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }

        // ---------------- hardware in use
        Text {
          width: body.width
          topPadding: Style.space(6)
          leftPadding: Style.space(6)
          text: "Hardware"
          color: root.fg
          opacity: 0.6
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body * 0.9
          font.capitalization: Font.AllUppercase
        }
        Text {
          visible: root.pills.length === 0
          width: body.width
          leftPadding: Style.space(6)
          wrapMode: Text.WordWrap
          text: "Nothing announced. Agents run: talk-to-me need cpu|vm|gpu \"what\" --estimate 10m"
          color: root.fg
          opacity: 0.6
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }
        Repeater {
          model: root.pills
          delegate: Rectangle {
            required property var modelData
            width: body.width
            height: Style.space(40)
            radius: Style.space(6)
            color: root.fgA(0.06)
            Column {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.right: relBtn.left
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: modelData.label + (modelData.queued ? "  ·  waiting" : "") + "  ·  " + modelData.title
                color: root.fg
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }
              Text {
                width: parent.width
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: modelData.line
                color: root.fg
                opacity: 0.65
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body * 0.85
              }
            }
            Rectangle {
              id: relBtn
              anchors.right: parent.right
              anchors.rightMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              width: relText.implicitWidth + Style.space(16)
              height: Style.space(26)
              radius: Style.space(6)
              color: relMouse.containsMouse ? root.fgA(0.2) : root.fgA(0.1)
              Text {
                id: relText
                anchors.centerIn: parent
                text: modelData.queued ? "Leave" : "Release"
                color: root.fg
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }
              MouseArea {
                id: relMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.release(["--id", modelData.id])
              }
            }
          }
        }
        Row {
          visible: root.pills.length > 1
          spacing: Style.space(6)
          leftPadding: Style.space(6)
          Rectangle {
            width: allText.implicitWidth + Style.space(16)
            height: Style.space(26)
            radius: Style.space(6)
            color: allMouse.containsMouse ? root.fgA(0.2) : root.fgA(0.1)
            Text { id: allText; anchors.centerIn: parent; text: "Release all"; color: root.fg; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body }
            MouseArea { id: allMouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.release(["all"]) }
          }
        }

        // ---------------- settings
        Text {
          width: body.width; topPadding: Style.space(10); leftPadding: Style.space(6)
          text: "Hardware rules"; color: root.fg; opacity: 0.6
          font.family: root.bar.fontFamily; font.pixelSize: Style.font.body * 0.9; font.capitalization: Font.AllUppercase
        }
        Repeater {
          model: [
            { k: "hw-queue", t: "Queue", d: "A busy resource makes the next agent wait in line" },
            { k: "hw-enforce", t: "Force announcing", d: "The guard blocks heavy commands nobody announced" },
            { k: "hw-cpu", t: "Heavy CPU / RAM", d: "Agents announce big builds and encodes" },
            { k: "hw-vm", t: "Big VMs", d: "Agents announce VMs with lots of resources" },
            { k: "hw-gpu", t: "Heavy GPU", d: "Agents announce GPU-heavy work" }
          ]
          delegate: Toggle {
            required property var modelData
            width: body.width
            label: modelData.t
            description: modelData.d
            checked: root.isOn(modelData.k)
            foreground: root.fg
            fontFamily: root.bar.fontFamily
            onClicked: root.setKey(modelData.k, root.isOn(modelData.k) ? "off" : "on")
          }
        }
        Repeater {
          model: [
            { k: "hw-slots", t: "Holders at a time", u: "", lo: 1, hi: 4, st: 1 },
            { k: "hw-max", t: "Longest hold", u: "min", lo: 1, hi: 480, st: 5 },
            { k: "hw-wait", t: "Longest wait in line", u: "s", lo: 10, hi: 3600, st: 60 },
            { k: "hw-gpu-vram", t: "GPU counts as heavy from", u: "GB VRAM", lo: 1, hi: 128, st: 1 },
            { k: "hw-vm-ram", t: "VM counts as big from", u: "GB RAM", lo: 1, hi: 128, st: 1 },
            { k: "hw-cpu-ram", t: "Job counts as heavy from", u: "GB RAM", lo: 1, hi: 128, st: 1 },
            { k: "hw-cpu-threads", t: "Job counts as heavy from", u: "threads", lo: 1, hi: 256, st: 1 },
            { k: "hw-minutes", t: "Heavy means longer than", u: "min", lo: 1, hi: 60, st: 1 }
          ]
          delegate: Item {
            id: stepRow
            required property var modelData
            width: body.width
            height: Style.space(30)
            readonly property int val: root.num(modelData.k, modelData.lo)
            Text {
              anchors.left: parent.left
              anchors.leftMargin: Style.space(6)
              anchors.verticalCenter: parent.verticalCenter
              text: stepRow.modelData.t
              color: root.fg
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }
            Row {
              anchors.right: parent.right
              anchors.rightMargin: Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(4)
              Rectangle {
                width: Style.space(26); height: Style.space(26); radius: Style.space(6)
                color: minusM.containsMouse ? root.fgA(0.2) : root.fgA(0.1)
                Text { anchors.centerIn: parent; text: "−"; color: root.fg; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body }
                MouseArea {
                  id: minusM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                  onClicked: root.setKey(stepRow.modelData.k, Math.max(stepRow.modelData.lo, stepRow.val - stepRow.modelData.st))
                }
              }
              Text {
                width: Style.space(86)
                height: Style.space(26)
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: stepRow.val + (stepRow.modelData.u !== "" ? " " + stepRow.modelData.u : "")
                color: root.fg
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
              }
              Rectangle {
                width: Style.space(26); height: Style.space(26); radius: Style.space(6)
                color: plusM.containsMouse ? root.fgA(0.2) : root.fgA(0.1)
                Text { anchors.centerIn: parent; text: "+"; color: root.fg; font.family: root.bar.fontFamily; font.pixelSize: Style.font.body }
                MouseArea {
                  id: plusM; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                  onClicked: root.setKey(stepRow.modelData.k, Math.min(stepRow.modelData.hi, stepRow.val + stepRow.modelData.st))
                }
              }
            }
          }
        }

        Text {
          width: body.width; topPadding: Style.space(10); leftPadding: Style.space(6)
          text: "Screen sessions"; color: root.fg; opacity: 0.6
          font.family: root.bar.fontFamily; font.pixelSize: Style.font.body * 0.9; font.capitalization: Font.AllUppercase
        }
        Repeater {
          model: [
            { k: "watch", t: "Agent watcher", d: "Banner when an agent opens a window without announcing" },
            { k: "shield", t: "Mouse shield", d: "Invisible shield over the screens during solo tests" },
            { k: "hide", t: "Empty workspace", d: "Switch the screens to an empty workspace while an agent works" },
            { k: "questions", t: "Questions", d: "Let agents ask standalone questions (experimental)" }
          ]
          delegate: Toggle {
            required property var modelData
            width: body.width
            label: modelData.t
            description: modelData.d
            checked: root.isOn(modelData.k)
            foreground: root.fg
            fontFamily: root.bar.fontFamily
            onClicked: root.setKey(modelData.k, root.isOn(modelData.k) ? "off" : "on")
          }
        }

        Text {
          width: body.width
          topPadding: Style.space(6)
          leftPadding: Style.space(6)
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: root.flash !== "" ? root.flash : "Changes apply at once. Command line: talk-to-me settings"
          opacity: 0.6
          color: root.fg
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body * 0.85
        }
      }
    }
  }
}
