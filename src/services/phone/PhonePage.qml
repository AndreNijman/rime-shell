import QtQuick
import "../"
import "../../"
import "../../components"
import "../remotepairing.js" as RP

// ─── PhonePage ───────────────────────────────────────────────────────────────
// The Dashboard's Phone tab: the paired phone's Messages, Calls and Photos,
// the way a phone-link app on another desktop shows them.
//
// It lives in the Dashboard, beside Agents, because it is a place you go to do
// something (read, reply, dial, save) rather than a setting: Settings, Paired
// devices stays where a phone is paired, rung and revoked, and this page sends
// people there when nothing is paired.
//
// Every state that is not "ready" says so in words: not asked yet, nothing
// paired, not connected, a phone that never said what it shares, a feature
// switched off on the phone (naming the switch), and a command that failed
// (its own sentence). Nothing is shown that the phone did not send.
//
// `onScreen` is the Dashboard's word for "this page is the one showing". The
// services run only while it is true; see PhoneService's header.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForSize(Screen.width, Screen.height) }   // P1-040: this output's sizes

    property bool onScreen: false

    ServiceRef { service: RemotePairingService; active: root.onScreen }
    ServiceRef { service: PhoneService; active: root.onScreen }

    readonly property var phone: PhoneService.phone
    readonly property string state: PhoneService.pageState

    // The section survives a close and reopen: it is where the person was.
    property string section: "messages"
    Binding { target: PhoneService; property: "section"; value: root.section; when: root.onScreen }

    readonly property var _sections: [
        { key: "messages", icon: "󰍡", label: "Messages" },
        { key: "calls",    icon: "󰏲", label: "Calls" },
        { key: "photos",   icon: "󰉏", label: "Photos" }
    ]

    // ── Header: which phone, how it is ───────────────────────────────────────

    Item {
        id: header
        anchors { top: parent.top; left: parent.left; right: parent.right }
        anchors.topMargin: theme.px(6)
        anchors.leftMargin: theme.px(12)
        anchors.rightMargin: theme.px(12)
        height: theme.px(44)

        Column {
            anchors.left: parent.left
            anchors.right: tabs.left
            anchors.rightMargin: theme.px(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: theme.px(2)

            Text {
                objectName: "phoneTitle"
                width: parent.width
                text: root.phone ? root.phone.name : "Phone"
                textFormat: Text.PlainText
                color: Theme.textPrimary
                font.pixelSize: theme.typeBodyStrong
                font.weight: Font.DemiBold
                elide: Text.ElideRight
            }
            Text {
                objectName: "phoneStatus"
                width: parent.width
                visible: text !== ""
                text: {
                    if (!root.phone) return ""
                    const connected = root.state === "ready" || root.state === "noreport"
                    const line = root.phone.phone ? RP.phoneLine(root.phone.phone, PhoneService.nowMs) : ""
                    return (connected ? "Connected" : "Not connected") + (line ? " · " + line : "")
                }
                textFormat: Text.PlainText
                color: Theme.textSecondary
                font.pixelSize: theme.typeCaption
                elide: Text.ElideRight
            }
        }

        TabSwitcher {
            id: tabs
            objectName: "phoneSections"
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: theme.px(330)
            height: theme.px(34)
            visible: root.state === "ready"
            model: root._sections
            currentPage: root.section
            onPageChanged: function (key) { root.section = key }
        }
    }

    // ── Body ─────────────────────────────────────────────────────────────────

    Item {
        id: body
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: parent.bottom }
        anchors.topMargin: theme.px(6)
        anchors.margins: theme.px(10)

        EmptyState {
            objectName: "phonePageState"
            anchors.centerIn: parent
            width: parent.width * 0.8
            visible: root.state !== "ready"
            plain: true
            glyph: root.state === "loading" ? "󰄜" : root.state === "error" ? "󰅚" : "󰥐"
            title: PhoneService.pageMessage.title
            hint: PhoneService.pageMessage.hint
        }

        PhoneMessages {
            anchors.fill: parent
            visible: root.state === "ready" && root.section === "messages"
        }
        PhoneCalls {
            anchors.fill: parent
            visible: root.state === "ready" && root.section === "calls"
        }
        PhonePhotos {
            anchors.fill: parent
            visible: root.state === "ready" && root.section === "photos"
        }
    }
}
