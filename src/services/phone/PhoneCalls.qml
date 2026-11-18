import QtQuick
import QtQuick.Controls
import "../"
import "../../"
import "../../components"
import "../../components/config"
import "../phone.js" as P

// ─── PhoneCalls ──────────────────────────────────────────────────────────────
// The call the phone has now (with Hang up when the phone allows it), a dial
// field (when it allows that), and the recent calls. There is no sound here:
// the call stays on the phone, and the page says so.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForSize(Screen.width, Screen.height) }   // P1-040: this output's sizes

    readonly property bool featureOn: PhoneService.offers("calls")
    readonly property var can: PhoneService.callAbilities
    readonly property var current: PhoneService.current

    EmptyState {
        objectName: "phoneCallsOff"
        anchors.centerIn: parent
        width: parent.width * 0.8
        visible: !root.featureOn
        plain: true
        glyph: "󰏲"
        title: PhoneService.offMessage("calls").title
        hint: PhoneService.offMessage("calls").hint
    }

    Column {
        id: head
        visible: root.featureOn
        anchors { left: parent.left; right: parent.right; top: parent.top }
        spacing: theme.px(8)

        // ── The call now ─────────────────────────────────────────────────────

        Rectangle {
            objectName: "phoneCurrentCall"
            width: parent.width
            height: visible ? theme.px(56) : 0
            visible: root.current !== null
            radius: theme.radiusM
            color: Theme.accentContainer

            Column {
                anchors { left: parent.left; right: hangup.left; verticalCenter: parent.verticalCenter
                          leftMargin: theme.px(12); rightMargin: theme.px(10) }
                spacing: theme.px(2)
                Text {
                    objectName: "phoneCurrentCallState"
                    width: parent.width
                    text: root.current ? P.callStateLabel(root.current.state) + ": "
                                         + P.caller(root.current.number, root.current.name) : ""
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    color: Theme.textOnAccentContainer
                    font.pixelSize: theme.typeBodyStrong
                    font.weight: Font.DemiBold
                }
                Text {
                    width: parent.width
                    text: "Talk on the phone. There is no sound on this computer."
                    color: Theme.textOnAccentContainer
                    font.pixelSize: theme.typeCaption
                    elide: Text.ElideRight
                }
            }
            CfgButton {
                id: hangup
                objectName: "phoneHangup"
                anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: theme.px(12) }
                visible: root.can.answer
                label: PhoneService.callAction === "hangup" ? "Ending" : "Hang up"
                variant: "danger"
                enabled: PhoneService.callAction === ""
                onClicked: PhoneService.hangup()
            }
        }

        // ── Dial ─────────────────────────────────────────────────────────────

        Row {
            width: parent.width
            spacing: theme.px(8)
            visible: root.can.dial

            CfgTextField {
                id: number
                objectName: "phoneDialNumber"
                fieldWidth: theme.px(240)
                height: theme.controlStandard
                placeholder: "Phone number"
                Accessible.name: "Phone number to call"
                onAccepted: callButton.press()
            }
            CfgButton {
                id: callButton
                objectName: "phoneDial"
                label: PhoneService.callAction === "dial" ? "Calling" : "Call"
                variant: "accent"
                enabled: PhoneService.callAction === "" && number.text.trim() !== ""
                onClicked: if (PhoneService.dial(number.text)) number.text = ""
            }
        }

        Text {
            objectName: "phoneCallNote"
            width: parent.width
            visible: text !== ""
            text: PhoneService.callActionError !== "" ? PhoneService.callActionError
                : PhoneService.callActionNote !== "" ? PhoneService.callActionNote
                : !root.can.dial ? "Dialling from this computer is not available on this connection. Dial on the phone."
                : ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: PhoneService.callActionError !== "" ? Theme.danger : Theme.textSecondary
            font.pixelSize: theme.typeCaption
        }

        Text {
            objectName: "phoneCallsNote"
            width: parent.width
            visible: text !== ""
            text: PhoneService.callsError !== "" ? PhoneService.callsError
                : !PhoneService.callsLoaded ? "Asking the phone for its calls"
                : PhoneService.historyError !== "" ? "No call history: " + PhoneService.historyError
                : !root.can.history ? "The phone does not share its call history."
                : PhoneService.calls !== null && PhoneService.calls.length === 0 ? "No recent calls" : ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: PhoneService.callsError !== "" ? Theme.danger : Theme.textSecondary
            font.pixelSize: theme.typeCaption
        }
    }

    // ── Recent calls ─────────────────────────────────────────────────────────

    ListView {
        id: history
        objectName: "phoneCallList"
        visible: root.featureOn
        anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: parent.bottom; topMargin: theme.px(8) }
        clip: true
        spacing: theme.px(2)
        model: PhoneService.calls || []
        boundsBehavior: Flickable.StopAtBounds
        Accessible.role: Accessible.List
        Accessible.name: "Recent calls"
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        delegate: Rectangle {
            id: call
            required property var modelData
            width: history.width - theme.px(8)
            height: theme.rowHeight
            radius: theme.radiusS
            color: Theme.surfaceRaised
            Accessible.role: Accessible.StaticText
            Accessible.name: P.callTypeLabel(call.modelData.type) + ", " + P.caller(call.modelData.number, call.modelData.name)

            Text {
                id: kind
                anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: theme.px(10) }
                width: theme.px(70)
                text: P.callTypeLabel(call.modelData.type)
                color: call.modelData.type === "missed" ? Theme.danger : Theme.textSecondary
                font.pixelSize: theme.typeCaption
            }
            Text {
                anchors { left: kind.right; right: meta.left; verticalCenter: parent.verticalCenter; rightMargin: theme.px(8) }
                text: P.caller(call.modelData.number, call.modelData.name)
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: Theme.textPrimary
                font.pixelSize: theme.typeBody
            }
            Text {
                id: meta
                anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: theme.px(10) }
                text: [P.duration(call.modelData.durationS), P.when(call.modelData.dateMs, PhoneService.nowMs)]
                    .filter(function (s) { return s !== "" }).join(" · ")
                color: Theme.textTertiary
                font.pixelSize: theme.typeCaption
            }
        }
    }
}
