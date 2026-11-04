import QtQuick
import Quickshell
import "../../"

// ============================================================
// UpdateMenu — what a click on the bar's update icon offers.
//
//   What's in this update     the release's page on rimeos.com, with
//                             ?from= the release this machine runs, so
//                             the page lists every release in between
//   Open Updates settings     Settings → Updates on this screen
//
// The icon used to open Settings straight away; the page on the
// site is the one thing it could not say ("what will this update
// actually include"), so a click now opens this menu with both.
// A header names the release when the checker said which one.
//
// TrayMenu's card, rows and keys (the bar's other click menu):
// grabFocus, so a click anywhere else dismisses it; Up/Down share
// one highlight with the pointer; Return/Enter/Space choose;
// Escape closes. Built only while open (Updates.qml's Loader), so
// at idle it costs nothing.
// ============================================================

PopupWindow {
    id: root

    required property Item target
    // UpdateStateService.indicator and .whatsNew, read when built.
    property var view: ({ kind: "", tooltip: "" })
    property var whatsNew: null

    signal openNotes()
    signal openSettings()
    signal dismissed()

    readonly property ThemeSet theme: ThemeSet {
        scale: Theme.factorForScreen(root.anchor.window ? root.anchor.window.screen : null)
    }

    readonly property int rowH: theme.px(30)
    readonly property int pad: theme.px(6)
    readonly property int radius: Math.min(theme.cornerRadius, theme.px(12))
    readonly property int cardW: theme.px(280)

    // The menu's two choices, for the keys and the tests.
    readonly property var rows: [notesRow, settingsRow]
    property Item curItem: notesRow
    function _step(d) {
        const i = root.rows.indexOf(root.curItem)
        root.curItem = root.rows[Math.max(0, Math.min(root.rows.length - 1, (i < 0 ? 0 : i + d)))]
    }
    function close() { root.visible = false }

    readonly property string headline: root.view && root.view.tooltip ? root.view.tooltip : "Rime update"
    readonly property string subline: {
        const w = root.whatsNew
        if (!w || w.release === "") return ""
        return "Rime " + (w.from !== "" ? w.from + " → " : "") + w.release
    }

    // Hangs below the icon, from its right edge leftwards: the icon sits in
    // the right notch, near the screen's edge.
    anchor.item: target
    anchor.edges: Edges.Bottom | Edges.Right
    anchor.gravity: Edges.Bottom | Edges.Left
    anchor.margins.top: theme.px(6)

    grabFocus: true
    color: "transparent"
    visible: true
    onVisibleChanged: if (!visible) root.dismissed()

    // Two rows and a header that never change while it is open: the window
    // is the card's size from the first frame (a mapped popup that is resized
    // is not redrawn; TrayMenu.qml).
    implicitWidth: card.width
    implicitHeight: card.height
    mask: Region { item: card }

    Rectangle {
        id: card
        width: root.cardW
        height: list.implicitHeight + root.pad * 2
        radius: root.radius
        color: Theme.background
        border.color: Theme.border
        border.width: 1

        focus: true
        Accessible.role: Accessible.PopupMenu
        Accessible.name: root.headline
        Keys.onEscapePressed: root.close()
        Keys.onPressed: function (event) {
            if      (event.key === Qt.Key_Down || event.key === Qt.Key_Tab)      root._step(1)
            else if (event.key === Qt.Key_Up   || event.key === Qt.Key_Backtab)  root._step(-1)
            else if (event.key === Qt.Key_Home) root.curItem = root.rows[0]
            else if (event.key === Qt.Key_End)  root.curItem = root.rows[root.rows.length - 1]
            else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter
                      || event.key === Qt.Key_Space) && root.curItem) root.curItem.activated()
            else return
            event.accepted = true
        }

        // TrayMenu's entrance: a fade on the state beat and a scale from the
        // corner at the icon. No exit: a dismissing click unmaps it first.
        transformOrigin: Item.TopRight
        ParallelAnimation {
            running: true
            NumberAnimation {
                target: card; property: "opacity"; from: 0; to: 1
                duration: Motion.state
                easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.standardDecel
            }
            NumberAnimation {
                target: card; property: "scale"; from: Motion.selection > 0 ? 0.97 : 1; to: 1
                duration: Motion.selection
                easing.type: Easing.BezierSpline; easing.bezierCurve: Motion.emphasizedDecel
            }
        }

        Column {
            id: list
            x: root.pad
            y: root.pad
            width: card.width - root.pad * 2
            spacing: 2

            // ── What the icon is about (not a choice) ────────────────
            Column {
                width: parent.width
                topPadding: root.theme.px(4)
                bottomPadding: root.theme.px(6)
                leftPadding: root.theme.px(10)
                rightPadding: root.theme.px(10)
                spacing: root.theme.px(2)
                Text {
                    width: parent.width - parent.leftPadding - parent.rightPadding
                    text: root.headline
                    textFormat: Text.PlainText
                    color: Theme.textPrimary
                    font.pixelSize: root.theme.fs(13)
                    font.weight: Font.DemiBold
                    elide: Text.ElideRight
                }
                Text {
                    width: parent.width - parent.leftPadding - parent.rightPadding
                    visible: root.subline !== ""
                    text: root.subline
                    textFormat: Text.PlainText
                    color: Theme.subtext
                    font.pixelSize: root.theme.fs(12)
                    elide: Text.ElideRight
                }
            }
            Rectangle { width: parent.width; height: 1; color: Theme.border }

            MenuRow {
                id: notesRow
                objectName: "whatsNewRow"
                glyph: "󰖟"
                label: qsTr("What's in this update")
                hint: "rimeos.com"
                onActivated: { root.close(); root.openNotes() }
            }
            MenuRow {
                id: settingsRow
                objectName: "settingsRow"
                glyph: "󰒓"
                label: qsTr("Open Updates settings")
                onActivated: { root.close(); root.openSettings() }
            }
        }
    }

    component MenuRow: Rectangle {
        id: row
        property string glyph: ""
        property string label: ""
        property string hint: ""
        signal activated()

        readonly property bool lit: hov.hovered || root.curItem === row
        Accessible.role: Accessible.MenuItem
        Accessible.name: row.hint !== "" ? row.label + ", opens " + row.hint : row.label
        Accessible.onPressAction: row.activated()

        width: parent ? parent.width : 0
        height: root.rowH
        radius: root.radius - 2
        color: lit ? Theme.surfaceHover(Theme.background) : "transparent"
        Behavior on color { MotionColor { role: "state" } }

        Row {
            anchors.left: parent.left
            anchors.leftMargin: root.theme.px(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.theme.px(8)
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: row.glyph
                font.family: Theme.fontIcon
                color: Theme.textPrimary
                font.pixelSize: root.theme.fs(14)
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: row.label
                color: Theme.textPrimary
                font.pixelSize: root.theme.fs(13)
            }
        }
        Text {
            visible: row.hint !== ""
            anchors.right: parent.right
            anchors.rightMargin: root.theme.px(10)
            anchors.verticalCenter: parent.verticalCenter
            text: row.hint
            color: Theme.subtext
            font.pixelSize: root.theme.fs(11)
        }

        HoverHandler {
            id: hov
            cursorShape: Qt.PointingHandCursor
            onHoveredChanged: if (hovered) root.curItem = row
        }
        MouseArea {
            anchors.fill: parent
            onClicked: row.activated()
        }
    }
}
