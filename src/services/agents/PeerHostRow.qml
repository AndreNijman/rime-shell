import QtQuick
import "../"
import "../../"

// ─── PeerHostRow ─────────────────────────────────────────────────────────────
// One of this person's other Rime computers in the Agent Center, when it lets
// this one view or control its agent sessions (`can_agents`). A header (name,
// what it allows, one line from PeerAgentService.hostLine), then its sessions
// as PeerSessionRows, then the read-only peek pane when one of them is peeked.
//
// A computer that is asleep, off, or no longer shares is one quiet subtext
// line, never an error colour: that is the usual state of a laptop in a bag.
// The name and every session field came from that computer, so each Text is
// PlainText, one line, elided.
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: hrow
    objectName: "peerHost"
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForSize(Screen.width, Screen.height) }   // P1-040: this output's sizes

    required property string computerId

    readonly property var computer: PeerAgentService.host(hrow.computerId)
    readonly property var result: PeerAgentService.resultFor(hrow.computerId)
    readonly property bool answered: hrow.result !== null && hrow.result.status === "ok"
    readonly property var shown: PeerAgentService.sessionsFor(hrow.computerId)
    readonly property int hidden: PeerAgentService.hiddenFor(hrow.computerId)
    readonly property bool peeked: PeerAgentService.peekFor === hrow.computerId

    width: parent ? parent.width : 0
    height: header.height + sessionColumn.height + (peekPane.visible ? peekPane.height + theme.px(4) : 0)
            + theme.fs(4)

    Rectangle {
        id: header
        width: parent.width
        height: theme.px(44)
        radius: theme.px(8)
        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.03)

        Row {
            anchors.fill: parent
            anchors.leftMargin: theme.px(10)
            anchors.rightMargin: theme.px(10)
            spacing: theme.px(10)

            Text {
                anchors.verticalCenter: parent.verticalCenter
                width: theme.px(22)
                horizontalAlignment: Text.AlignHCenter
                text: "󰍹"
                textFormat: Text.PlainText
                font.pixelSize: theme.fs(15)
                color: hrow.answered && hrow.result.sessions.length > 0 ? Theme.text : Theme.subtext
            }

            Column {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - theme.fs(60)
                spacing: theme.px(2)

                Row {
                    width: parent.width
                    spacing: theme.px(6)

                    Text {
                        id: nameText
                        objectName: "peerHostName"
                        text: hrow.computer ? hrow.computer.name : ""
                        textFormat: Text.PlainText
                        maximumLineCount: 1
                        elide: Text.ElideRight
                        width: Math.min(implicitWidth, parent.width - levelChip.width - theme.px(12))
                        color: Theme.text
                        font.pixelSize: theme.fs(12)
                        font.bold: true
                    }

                    Rectangle {
                        id: levelChip
                        anchors.verticalCenter: parent.verticalCenter
                        radius: theme.px(3)
                        color: Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b, 0.18)
                        width: levelLabel.implicitWidth + theme.fs(8)
                        height: levelLabel.implicitHeight + theme.fs(3)
                        Text {
                            id: levelLabel
                            objectName: "peerHostLevel"
                            anchors.centerIn: parent
                            text: hrow.computer && hrow.computer.canAgents === "control"
                                      ? "You can work in them" : "You can watch"
                            textFormat: Text.PlainText
                            color: Theme.active
                            font.pixelSize: theme.fs(9)
                        }
                    }
                }

                Text {
                    objectName: "peerHostLine"
                    width: parent.width
                    text: PeerAgentService.hostLine(hrow.computerId)
                    textFormat: Text.PlainText
                    maximumLineCount: 1
                    elide: Text.ElideRight
                    color: Theme.subtext
                    font.pixelSize: theme.fs(10)
                }
            }
        }
    }

    Column {
        id: sessionColumn
        anchors.top: header.bottom
        anchors.topMargin: hrow.shown.length > 0 || hrow.hidden > 0 ? theme.fs(2) : 0
        width: parent.width
        spacing: 0

        Repeater {
            model: hrow.shown.length

            delegate: PeerSessionRow {
                required property int index
                width: sessionColumn.width
                computerId: hrow.computerId
                session: hrow.shown[index] || PeerAgentService.blankSession
            }
        }

        Text {
            visible: hrow.hidden > 0
            height: visible ? theme.fs(20) : 0
            leftPadding: theme.fs(46)
            text: "and " + hrow.hidden + " more"
            textFormat: Text.PlainText
            color: Theme.subtext
            font.pixelSize: theme.fs(9)
        }
    }

    // ── The peek pane: read-only text, no input of any kind ──────────────────
    Rectangle {
        id: peekPane
        objectName: "peerPeekPane"
        visible: hrow.peeked
        anchors.top: sessionColumn.bottom
        anchors.topMargin: theme.px(4)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: theme.px(30)
        height: peekHead.height + peekBody.height + theme.px(22)
        radius: theme.px(8)
        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.05)
        clip: true

        Item {
            id: peekHead
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.margins: theme.px(8)
            height: theme.px(26)

            Text {
                objectName: "peerPeekTitle"
                anchors.left: parent.left
                anchors.right: peekClose.left
                anchors.rightMargin: theme.px(8)
                anchors.verticalCenter: parent.verticalCenter
                text: {
                    const s = PeerAgentService.sessionOf(hrow.computerId, PeerAgentService.peekSession)
                    const n = s ? (s.name || s.title || s.agent) : ""
                    return "What #" + PeerAgentService.peekSession + (n ? " (" + n + ")" : "") + " shows"
                }
                textFormat: Text.PlainText
                maximumLineCount: 1
                elide: Text.ElideRight
                color: Theme.subtext
                font.pixelSize: theme.fs(10)
                font.bold: true
            }
            SmallIconButton {
                id: peekClose
                objectName: "peerPeekClose"
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                icon: "󰅖"
                tip: "Close"
                onActivated: PeerAgentService.closePeek()
            }
        }

        Text {
            id: peekBody
            objectName: "peerPeekText"
            anchors.top: peekHead.bottom
            anchors.topMargin: theme.px(4)
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.leftMargin: theme.px(10)
            anchors.rightMargin: theme.px(10)
            text: PeerAgentService.peeking ? "Reading…"
                  : PeerAgentService.peekError !== "" ? PeerAgentService.peekError
                  : PeerAgentService.peekText !== "" ? PeerAgentService.peekText
                  : "It shows nothing yet."
            textFormat: Text.PlainText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
            clip: true
            color: PeerAgentService.peekText !== "" && !PeerAgentService.peeking ? Theme.text : Theme.subtext
            font.family: Theme.fontMono
            font.pixelSize: theme.fs(10)
        }
    }
}
