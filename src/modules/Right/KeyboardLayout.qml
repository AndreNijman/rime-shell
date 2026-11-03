import QtQuick
import "../../"
import "../../services"

// The bar's keyboard-layout chip: the active layout's code ("US", "RU"). Shown
// only when the compositor has more than one layout loaded. Left-click goes to
// the next layout, right-click to the previous one; the compositor's own
// keybind keeps working and the label follows it.
Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForSize(Screen.width, Screen.height) }

    visible: KeyboardLayoutService.available
    implicitWidth:  visible ? label.implicitWidth + theme.px(8) : 0
    implicitHeight: Math.max(label.implicitHeight, theme.hitBar)

    Accessible.role: Accessible.Button
    Accessible.name: "Keyboard layout: " + KeyboardLayoutService.currentName + ". Click to switch"

    HoverHandler { id: hov }

    Text {
        id: label
        anchors.centerIn: parent
        text:  KeyboardLayoutService.current
        color: hov.hovered ? Theme.textPrimary : Theme.textSecondary
        font.family:    Theme.fontUi
        font.weight:    Font.DemiBold
        font.pixelSize: theme.typeBodySmall
        Behavior on color { MotionColor {} }
    }

    MouseArea {
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        cursorShape: Qt.PointingHandCursor
        onClicked: function (mouse) {
            if (mouse.button === Qt.RightButton) KeyboardLayoutService.prev()
            else                                 KeyboardLayoutService.next()
        }
    }
}
