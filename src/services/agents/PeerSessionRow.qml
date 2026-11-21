import QtQuick
import "../"
import "../../"
import "../agentstate.js" as AgentState
import "../peeragents.js" as P

// ─── PeerSessionRow ──────────────────────────────────────────────────────────
// One agent session on another of this person's Rime computers, under its
// PeerHostRow. The same reading as a local SessionRow, as far as
// `computers agents --json` carries it: state badge, name (a person's, else
// the agent's title, else the adapter), number, project or folder, state word,
// how long. Two controls only: Peek (view or control) and, with control and a
// live session, Attach. No stop, pause, rename or dismiss: those would act on
// the other computer, which M4 does not offer.
//
// Every string here came from the other machine. Each Text is PlainText, one
// line, elided: a title of "<b>x</b>" is drawn as those characters, and
// nothing a session says is ever put in a command (PeerAgentService builds the
// argv from the computer's id and the session's number only).
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: srow
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForSize(Screen.width, Screen.height) }   // P1-040: this output's sizes

    required property string computerId
    required property var session

    readonly property bool live: P.isLive(srow.session)
    readonly property bool control: PeerAgentService.canAttach(srow.computerId)
    readonly property string label: P.sessionLabel(srow.session) || AgentState.agentName(srow.session.agent)
    readonly property string where: P.where(srow.session)
    readonly property bool peekOpen: PeerAgentService.peekFor === srow.computerId
                                     && PeerAgentService.peekSession === srow.session.id

    height: theme.px(30)

    Row {
        id: line
        anchors.left: parent.left
        anchors.right: buttons.left
        anchors.verticalCenter: parent.verticalCenter
        anchors.leftMargin: theme.px(30)
        anchors.rightMargin: theme.px(6)
        spacing: theme.px(8)

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "└"
            textFormat: Text.PlainText
            color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.25)
            font.pixelSize: theme.fs(10)
        }

        StateBadge {
            id: badge
            anchors.verticalCenter: parent.verticalCenter
            sessionState: srow.session.state
            size: theme.px(18)
        }

        Text {
            id: nameText
            objectName: "peerSessionName"
            anchors.verticalCenter: parent.verticalCenter
            text: srow.label
            textFormat: Text.PlainText
            maximumLineCount: 1
            elide: Text.ElideRight
            color: Theme.text
            font.pixelSize: theme.fs(11)
            font.bold: true
            width: Math.min(implicitWidth, theme.px(200), Math.max(theme.px(40), line.width * 0.45))
        }

        Text {
            id: numText
            anchors.verticalCenter: parent.verticalCenter
            text: "#" + srow.session.id
            textFormat: Text.PlainText
            color: Theme.subtext
            font.pixelSize: theme.fs(9)
        }

        Text {
            id: metaText
            objectName: "peerSessionMeta"
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, line.width - nameText.width - numText.implicitWidth
                                - badge.width - theme.px(60))
            text: {
                const parts = []
                if (srow.where !== "") parts.push(srow.where)
                parts.push(AgentService.stateLabel(srow.session.state))
                const e = AgentService.elapsed(srow.session)
                if (e) parts.push(e)
                if (srow.session.attached > 0) parts.push("attached there")
                return parts.join("  ·  ")
            }
            textFormat: Text.PlainText
            maximumLineCount: 1
            elide: Text.ElideRight
            color: Theme.subtext
            font.pixelSize: theme.fs(9)
        }
    }

    Row {
        id: buttons
        anchors.right: parent.right
        anchors.rightMargin: theme.px(8)
        anchors.verticalCenter: parent.verticalCenter
        spacing: theme.px(2)

        SmallIconButton {
            objectName: "peerPeek"
            icon: "󰈈"
            tip: srow.peekOpen ? "Peek again" : "Peek at what it shows"
            onActivated: PeerAgentService.peekAt(srow.computerId, srow.session.id)
        }
        SmallIconButton {
            objectName: "peerAttach"
            visible: srow.control && srow.live
            icon: "󰆍"
            tip: "Attach in a terminal"
            onActivated: PeerAgentService.attach(srow.computerId, srow.session.id)
        }
    }
}
