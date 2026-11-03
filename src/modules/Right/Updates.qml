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
// screen by UpdateStateService. A click opens Settings → Updates on this
// screen, which says the rest and has the Update now button.
Item {
    id: root

    // This bar's output, for the Settings window to open on (TopBar → RightContent).
    property string screenName: ""

    readonly property var view: UpdateStateService.indicator
    readonly property bool shown: root.view.kind !== ""

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
        label: root.view.tooltip + ". Opens Updates in Settings"
        textColor: root.toneColor(root.view.tone)
        onClicked: {
            Popups.closeAll()
            NexusState.openAt("updates", root.screenName)
        }
    }

    BarTooltip {
        target: btn
        text: root.view.tooltip
        shown: root.shown && btn.hovered && !btn.pressed
    }
}
