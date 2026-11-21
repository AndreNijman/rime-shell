import QtQuick
import QtQuick.Controls
import "../"
import "../../"
import "../../components"
import "../../components/config"

// ─── PhoneComputers ──────────────────────────────────────────────────────────
// The Phone page's Computers section: this person's other paired Rime
// computers, how each was when last reached, and the two things to DO with
// one from here: open a link there, send it a file. Deciding what a computer
// may do (the sharing switches, allowing one your phone introduced, removing
// one) is in Settings → Paired devices, beside the phone's own settings, the
// same split the phone has between this page and that one.
//
// "Open link there" sends the clipboard's link when there is one (the Shell
// never reads it, see ComputersService) and otherwise opens a field here.
// "Send file…" needs a file dialog, which a window cannot show over the
// Dashboard, so the Dashboard closes and the dialog opens; how the send went
// is on the card when the page is next opened.
//
// Names come from the other computer: every Text that shows one is plain
// text, one line, elided.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForSize(Screen.width, Screen.height) }   // P1-040: this output's sizes

    ListView {
        id: list
        objectName: "computerList"
        anchors.fill: parent
        clip: true
        spacing: theme.px(8)
        model: ComputersService.pairedIds
        boundsBehavior: Flickable.StopAtBounds
        Accessible.role: Accessible.List
        Accessible.name: "Your computers"
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Rectangle {
            id: card
            // The model is the ids, so a list read that changes only what is
            // known about a computer updates its card rather than rebuilding
            // it (a half-typed link would go with a rebuilt card).
            required property var modelData
            readonly property string computerId: card.modelData
            readonly property var c: ComputersService.row(card.computerId)
            readonly property var st: ComputersService.stateOf(card.c)
            readonly property bool askingLink: ComputersService.linkWanted === card.computerId
            readonly property string note: ComputersService.noteOf(card.computerId)
            readonly property string busyLine:
                ComputersService.sendingFor === card.computerId ? "Sending " + ComputersService.sendingName + "…"
                : ComputersService.openingFor === card.computerId ? "Sending the link…"
                : ""

            objectName: "computerCard"
            width: list.width - theme.px(8)
            height: body.implicitHeight + theme.px(24)
            radius: theme.radiusM
            color: Theme.surfaceRaised
            Accessible.role: Accessible.Grouping
            Accessible.name: card.c.name + ", " + card.st.word

            Column {
                id: body
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: theme.px(12) }
                spacing: theme.px(6)

                Item {
                    width: parent.width
                    height: Math.max(words.implicitHeight, actions.height)

                    Column {
                        id: words
                        anchors { left: parent.left; right: actions.left; rightMargin: theme.px(12)
                                  verticalCenter: parent.verticalCenter }
                        spacing: theme.px(2)

                        Text {
                            objectName: "computerName"
                            width: parent.width
                            text: card.c.name
                            textFormat: Text.PlainText
                            maximumLineCount: 1
                            elide: Text.ElideRight
                            color: Theme.textPrimary
                            font.pixelSize: theme.typeBodyStrong
                            font.weight: Font.DemiBold
                        }
                        Text {
                            objectName: "computerStatus"
                            width: parent.width
                            text: [card.st.word.charAt(0).toUpperCase() + card.st.word.slice(1),
                                   ComputersService.reachedLine(card.c),
                                   ComputersService.presenceLine(card.c)]
                                .filter(function (s) { return s !== "" }).join(" · ")
                            textFormat: Text.PlainText
                            maximumLineCount: 1
                            elide: Text.ElideRight
                            color: card.st.token === "success" ? Theme.success
                                 : card.st.token === "warning" ? Theme.warning : Theme.textSecondary
                            font.pixelSize: theme.typeCaption
                        }
                        Text {
                            objectName: "computerIntroduced"
                            width: parent.width
                            visible: card.c.needsAllow
                            text: ComputersService.introducedLine(card.c) + ". Allow it in Settings, Paired devices."
                            textFormat: Text.PlainText
                            maximumLineCount: 1
                            elide: Text.ElideRight
                            color: Theme.textSecondary
                            font.pixelSize: theme.typeCaption
                        }
                    }

                    Row {
                        id: actions
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                        spacing: theme.px(6)

                        CfgButton {
                            objectName: "computerOpenLink"
                            label: "Open link there"
                            icon: "󰌹"
                            // A rime-remoted without handoff cards has no `open`;
                            // one not allowed yet refuses it (and a file), so
                            // its card says only "Allow it in Settings".
                            visible: card.c.handoff !== null && card.c.trusted
                            enabled: ComputersService.openingFor === ""
                            Accessible.name: "Open a link on " + card.c.name
                            onClicked: ComputersService.openFromClipboard(card.computerId)
                        }
                        CfgButton {
                            objectName: "computerSendFile"
                            label: "Send file…"
                            icon: "󰈔"
                            visible: ComputersService.canPick && card.c.trusted
                            enabled: ComputersService.sendingFor === "" && ComputersService.pickingFor === ""
                            Accessible.name: "Send a file to " + card.c.name
                            onClicked: {
                                // The dialog is a window, and the Dashboard
                                // is an overlay above every window.
                                if (ComputersService.pickAndSend(card.computerId)) Popups.closeAll()
                            }
                        }
                    }
                }

                // The clipboard held no link: type or paste one.
                Row {
                    width: parent.width
                    spacing: theme.px(8)
                    visible: card.askingLink

                    CfgTextField {
                        id: link
                        objectName: "computerLinkField"
                        fieldWidth: theme.px(360)
                        height: theme.controlStandard
                        placeholder: "https://…"
                        Accessible.name: "Link to open on " + card.c.name
                        onAccepted: openBtn.press()
                    }
                    CfgButton {
                        id: openBtn
                        objectName: "computerLinkSend"
                        label: ComputersService.openingFor === card.computerId ? "Sending" : "Open there"
                        variant: "accent"
                        enabled: ComputersService.openingFor === "" && link.text.trim() !== ""
                        onClicked: if (ComputersService.openLink(card.computerId, link.text)) link.text = ""
                    }
                    CfgButton {
                        objectName: "computerLinkCancel"
                        label: "Cancel"
                        onClicked: { link.text = ""; ComputersService.cancelLink() }
                    }
                }

                Text {
                    objectName: "computerNote"
                    width: parent.width
                    visible: text !== ""
                    text: card.busyLine !== "" ? card.busyLine
                        : card.note !== "" ? card.note
                        : card.askingLink ? "There is no link on the clipboard. Type or paste one; " + card.c.name + " shows it, and someone there opens it."
                        : ""
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    color: card.busyLine === "" && card.note !== "" && !ComputersService.noteOk ? Theme.danger : Theme.textSecondary
                    font.pixelSize: theme.typeCaption
                }
            }
        }
    }
}
