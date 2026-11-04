import QtQuick
import "../../components"
import "../../nexus"
import "../../services"
import "../../"

// The bar's update icon: there only when an update asks something of the user.
//
//   󰚰  an update is available                (the 6-hourly checker)
//   󰜉  an update is installed, restart (or log out) to finish it
//   󰕍  a live update was undone
//   󰅙  an update could not be applied
//
// Nothing to do (up to date, never checked, an update running in a terminal)
// draws nothing and takes no width, so the notch does not grow for it. The
// decision is liveupdate.js's indicator(); the files are read once for every
// screen by UpdateStateService.
//
// A click (or Return/Space on the focused icon) opens a small menu when there
// is an update to come — available, or installed and waiting for a restart:
// "What's in this update" opens that release's page on rimeos.com in the
// default browser (liveupdate.js whatsNew(), ReleaseService.openUrl), and
// "Open Updates settings" opens Settings → Updates on this screen, which says
// the rest and has the Update now button. A failure with nothing queued has
// no release to show, so there the click opens Settings → Updates directly.
Item {
    id: root

    // This bar's output, for the Settings window to open on (TopBar → RightContent).
    property string screenName: ""

    readonly property var view: UpdateStateService.indicator
    readonly property bool shown: root.view.kind !== ""
    // The "What's in this update" link, or null: then a click goes straight
    // to Settings.
    readonly property var whatsNew: UpdateStateService.whatsNew
    readonly property bool hasMenu: root.whatsNew !== null
    readonly property bool menuOpen: menuLoader.item !== null && menuLoader.item.visible
    // The menu grabs the pointer and keyboard, so a click anywhere else closes
    // it. Off only in tests/update-indicator-test.qml: a grab opened without a
    // real click's serial is dismissed by the compositor at once (measured for
    // TrayMenu, tests/traymenu-keys-test.qml), and that harness clicks in code.
    property bool menuGrab: true

    function openSettings() {
        Popups.closeAll()
        NexusState.openAt("updates", root.screenName)
    }
    function openNotes() {
        if (root.whatsNew) ReleaseService.openUrl(root.whatsNew.url)
    }
    function toggleMenu() {
        if (menuLoader.active) { menuLoader.active = false; return }
        Popups.closeAll()
        menuLoader.active = true
    }
    // The icon went away (the update was installed, the checker changed its
    // mind): so does its menu.
    onShownChanged: if (!root.shown) menuLoader.active = false
    onHasMenuChanged: if (!root.hasMenu) menuLoader.active = false

    visible: root.shown
    implicitWidth:  root.shown ? btn.implicitWidth : 0
    implicitHeight: btn.implicitHeight

    // The bar's colour rule: passive at rest unless there is a state to show,
    // and these are all states. The same tones as the Updates page's hero.
    function toneColor(tone) {
        switch (tone) {
            case "warn": return Theme.attention
            case "bad":  return Theme.danger
            default:     return Theme.iconDefault
        }
    }

    IconBtn {
        id: btn
        anchors.centerIn: parent
        text: root.view.glyph
        label: root.view.tooltip + (root.hasMenu
               ? ". Opens a menu: what's in this update, or Updates in Settings"
               : ". Opens Updates in Settings")
        Accessible.role: root.hasMenu ? Accessible.ButtonMenu : Accessible.Button
        textColor: root.toneColor(root.view.tone)
        onClicked: {
            if (root.hasMenu) root.toggleMenu()
            else root.openSettings()
        }
    }

    BarTooltip {
        target: btn
        text: root.view.tooltip
        shown: root.shown && btn.hovered && !btn.pressed && !root.menuOpen
    }

    Loader {
        id: menuLoader
        active: false
        sourceComponent: UpdateMenu {
            target: btn
            grabFocus: root.menuGrab
            view: root.view
            whatsNew: root.whatsNew
            onOpenNotes: root.openNotes()
            onOpenSettings: root.openSettings()
            // Dismissed by a click elsewhere, Escape or a choice: unbuilt again.
            onDismissed: Qt.callLater(function () { menuLoader.active = false })
        }
    }
}
