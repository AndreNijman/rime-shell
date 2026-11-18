import QtQuick
import QtQuick.Controls
import "../"
import "../../"
import "../../components"
import "../../components/config"
import "../../components/controls"
import "../phone.js" as P

// ─── PhoneMessages ───────────────────────────────────────────────────────────
// The phone's SMS conversations on the left, the open one on the right, and a
// reply box under it. Everything shown is what the phone sent this time: the
// list and the open conversation are asked again while the page is open, and
// dropped when it closes.
//
// The reply is sent with `rime remote messages send`, the text on standard
// input (PhoneService). The draft stays in the field until the phone's network
// took it; a failed send keeps it and says why.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForSize(Screen.width, Screen.height) }   // P1-040: this output's sizes

    readonly property bool featureOn: PhoneService.offers("messages")
    readonly property var openThread: PhoneService.openThread

    EmptyState {
        objectName: "phoneMessagesOff"
        anchors.centerIn: parent
        width: parent.width * 0.8
        visible: !root.featureOn
        plain: true
        glyph: "󰍡"
        title: PhoneService.offMessage("messages").title
        hint: PhoneService.offMessage("messages").hint
    }

    // ── The conversation list ────────────────────────────────────────────────

    Item {
        id: listPane
        visible: root.featureOn
        anchors { top: parent.top; bottom: parent.bottom; left: parent.left }
        width: Math.round(parent.width * 0.38)

        Text {
            objectName: "phoneThreadsNote"
            anchors { left: parent.left; right: parent.right; top: parent.top }
            visible: text !== ""
            text: PhoneService.threadsError !== "" ? PhoneService.threadsError
                : !PhoneService.threadsLoaded ? "Asking the phone for its conversations"
                : PhoneService.threads.length === 0 ? "No conversations on the phone" : ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: PhoneService.threadsError !== "" ? Theme.danger : Theme.textSecondary
            font.pixelSize: theme.typeCaption
        }

        ListView {
            id: threadList
            objectName: "phoneThreadList"
            anchors.fill: parent
            anchors.topMargin: PhoneService.threadsError !== "" ? theme.px(36) : 0
            clip: true
            spacing: theme.px(2)
            model: PhoneService.threads
            boundsBehavior: Flickable.StopAtBounds
            Accessible.role: Accessible.List
            Accessible.name: "Conversations"
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

            delegate: RimePressable {
                id: row
                required property var modelData
                readonly property bool current: root.openThread !== null && root.openThread.id === row.modelData.id
                objectName: "phoneThread_" + row.modelData.id
                width: threadList.width - theme.px(8)
                height: theme.rowHeightTwoLine
                Accessible.role: Accessible.Button
                Accessible.name: row.modelData.title
                    + (row.modelData.unread > 0 ? ", " + row.modelData.unread + " unread" : "")
                    + ", " + row.modelData.snippet
                onActivated: PhoneService.openConversation(row.modelData)

                Rectangle {
                    anchors.fill: parent
                    radius: theme.radiusS
                    color: row.current ? Theme.surfaceSelected : row.tint(Theme.surfaceRaised)
                }
                Text {
                    id: whenText
                    anchors { right: parent.right; top: parent.top; rightMargin: theme.px(10); topMargin: theme.px(8) }
                    text: P.when(row.modelData.dateMs, PhoneService.nowMs)
                    color: Theme.textTertiary
                    font.pixelSize: theme.typeCaption
                }
                Text {
                    anchors { left: parent.left; right: whenText.left; top: parent.top
                              leftMargin: theme.px(10); rightMargin: theme.px(8); topMargin: theme.px(6) }
                    text: row.modelData.title
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: row.current ? Theme.surfaceOnSelected : Theme.textPrimary
                    font.pixelSize: theme.typeBody
                    font.weight: row.modelData.unread > 0 ? Font.DemiBold : Font.Normal
                }
                Text {
                    anchors { left: parent.left; right: badge.left; bottom: parent.bottom
                              leftMargin: theme.px(10); rightMargin: theme.px(8); bottomMargin: theme.px(6) }
                    text: row.modelData.snippet.replace(/\s+/g, " ")
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: Theme.textSecondary
                    font.pixelSize: theme.typeCaption
                }
                Rectangle {
                    id: badge
                    anchors { right: parent.right; bottom: parent.bottom; rightMargin: theme.px(10); bottomMargin: theme.px(7) }
                    visible: row.modelData.unread > 0
                    width: visible ? Math.max(height, unreadText.implicitWidth + theme.px(10)) : 0
                    height: theme.px(16)
                    radius: height / 2
                    color: Theme.accentContainer
                    Text {
                        id: unreadText
                        anchors.centerIn: parent
                        text: row.modelData.unread
                        color: Theme.textOnAccentContainer
                        font.pixelSize: theme.typeCaption
                    }
                }
            }
        }
    }

    // ── The open conversation ────────────────────────────────────────────────

    Rectangle {
        id: convPane
        visible: root.featureOn
        anchors { top: parent.top; bottom: parent.bottom; right: parent.right; left: listPane.right }
        anchors.leftMargin: theme.px(10)
        radius: theme.radiusM
        color: Theme.surfaceRaised

        Text {
            objectName: "phoneConversationHint"
            anchors.centerIn: parent
            visible: root.openThread === null
            text: "Pick a conversation"
            color: Theme.textSecondary
            font.pixelSize: theme.typeBody
        }

        Item {
            anchors.fill: parent
            anchors.margins: theme.px(10)
            visible: root.openThread !== null

            Text {
                id: convTitle
                objectName: "phoneConversationTitle"
                anchors { left: parent.left; right: parent.right; top: parent.top }
                text: root.openThread ? root.openThread.title : ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Theme.textPrimary
                font.pixelSize: theme.typeBodyStrong
                font.weight: Font.DemiBold
            }

            Text {
                id: convNote
                objectName: "phoneConversationNote"
                anchors { left: parent.left; right: parent.right; top: convTitle.bottom; topMargin: theme.px(4) }
                visible: text !== ""
                text: PhoneService.messagesError !== "" ? PhoneService.messagesError
                    : !PhoneService.messagesLoaded ? "Asking the phone for this conversation"
                    : PhoneService.messages.length === 0 ? "No messages in this conversation" : ""
                textFormat: Text.PlainText
                wrapMode: Text.WordWrap
                color: PhoneService.messagesError !== "" ? Theme.danger : Theme.textSecondary
                font.pixelSize: theme.typeCaption
            }

            ListView {
                id: messageList
                objectName: "phoneMessageList"
                anchors { left: parent.left; right: parent.right; top: convNote.visible ? convNote.bottom : convTitle.bottom
                          bottom: replyArea.top; topMargin: theme.px(6); bottomMargin: theme.px(8) }
                clip: true
                spacing: theme.px(6)
                model: PhoneService.messages
                boundsBehavior: Flickable.StopAtBounds
                Accessible.role: Accessible.List
                Accessible.name: "Messages"
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                // Newest at the bottom, where a chat is read from; an older page
                // put in front keeps the view where it was.
                onCountChanged: if (!PhoneService.loadingOlder) Qt.callLater(messageList.positionViewAtEnd)

                header: Item {
                    width: messageList.width
                    height: PhoneService.olderAvailable ? theme.px(40) : 0
                    visible: PhoneService.olderAvailable
                    CfgButton {
                        objectName: "phoneOlder"
                        anchors.centerIn: parent
                        label: PhoneService.loadingOlder ? "Loading" : "Older messages"
                        enabled: !PhoneService.loadingOlder
                        onClicked: PhoneService.loadOlder()
                    }
                }

                delegate: Item {
                    id: msg
                    required property var modelData
                    width: messageList.width - theme.px(8)
                    height: bubble.height + (statusText.visible ? statusText.height + theme.px(2) : 0)

                    Rectangle {
                        id: bubble
                        anchors.right: msg.modelData.fromMe ? parent.right : undefined
                        anchors.left: msg.modelData.fromMe ? undefined : parent.left
                        width: Math.min(msg.width * 0.78, bodyText.implicitWidth + theme.px(20))
                        height: bodyText.implicitHeight + timeText.implicitHeight + theme.px(14)
                        radius: theme.radiusM
                        color: msg.modelData.fromMe ? Theme.accentContainer : Theme.surfaceHigh
                        Accessible.role: Accessible.StaticText
                        Accessible.name: (msg.modelData.fromMe ? "You: " : "Them: ") + msg.modelData.body

                        Text {
                            id: bodyText
                            anchors { left: parent.left; right: parent.right; top: parent.top
                                      leftMargin: theme.px(10); rightMargin: theme.px(10); topMargin: theme.px(6) }
                            text: msg.modelData.body
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            color: msg.modelData.fromMe ? Theme.textOnAccentContainer : Theme.textPrimary
                            font.pixelSize: theme.typeBody
                        }
                        Text {
                            id: timeText
                            anchors { right: parent.right; top: bodyText.bottom; rightMargin: theme.px(10); topMargin: theme.px(2) }
                            text: P.when(msg.modelData.dateMs, PhoneService.nowMs)
                            color: msg.modelData.fromMe ? Theme.textOnAccentContainer : Theme.textTertiary
                            opacity: 0.8
                            font.pixelSize: theme.typeCaption
                        }
                    }
                    Text {
                        id: statusText
                        anchors { right: parent.right; top: bubble.bottom; topMargin: theme.px(2) }
                        visible: text !== ""
                        text: P.messageStatus(msg.modelData)
                        color: msg.modelData.status === "failed" ? Theme.danger : Theme.textTertiary
                        font.pixelSize: theme.typeCaption
                    }
                }
            }

            // ── Reply ────────────────────────────────────────────────────────

            Column {
                id: replyArea
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
                spacing: theme.px(4)

                Text {
                    objectName: "phoneReplyNote"
                    width: parent.width
                    visible: text !== ""
                    text: PhoneService.sendError !== "" ? PhoneService.sendError
                        : root.openThread && root.openThread.group ? "Replying to a group conversation is not supported. Reply on the phone."
                        : ""
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    color: PhoneService.sendError !== "" ? Theme.danger : Theme.textSecondary
                    font.pixelSize: theme.typeCaption
                }

                Row {
                    width: parent.width
                    spacing: theme.px(8)
                    visible: root.openThread !== null && !root.openThread.group

                    CfgTextField {
                        id: reply
                        objectName: "phoneReply"
                        fieldWidth: parent.width - sendButton.width - parent.spacing
                        height: theme.controlStandard
                        placeholder: "Text message"
                        Accessible.name: "Reply"
                        onAccepted: sendButton.press()
                    }
                    CfgButton {
                        id: sendButton
                        objectName: "phoneSend"
                        label: PhoneService.sending ? "Sending" : "Send"
                        variant: "accent"
                        enabled: !PhoneService.sending && reply.text.trim() !== ""
                        onClicked: PhoneService.send(reply.text)
                    }
                }
            }
        }
    }

    // The draft goes only when the phone's network took it.
    Connections {
        target: PhoneService
        function onSent() { reply.text = "" }
    }
}
