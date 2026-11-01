import QtQuick
import "../../components"
import "../../"

IconBtn {
    id: root

    // ── Rime mark ─────────────────────────────────────
    // Rime OS override (rime-logs 15-rime-logo.md): upstream rendered a
    // per-distro nerd-font glyph from /etc/os-release. On Rime OS the brand is
    // Rime whatever the base (Fedora then, NixOS now, whose os-release would
    // have picked the NixOS snowflake), so this button is the Rime layered
    // ridge (src/components/RimeMark.qml): vectors, with ONLY plane 3 in the
    // live accent and the other planes in the bar's ink, so it follows the
    // wallpaper and both light and dark palettes, crisp at every scale. It
    // replaced the chartreuse "spark" PNG that a MultiEffect recoloured whole,
    // and the glyph map, which only ever showed when that PNG failed to load.
    text: ""
    label: "Rime menu"
    // The Rime mark is accent-coloured by design (brief §D.3's one exception).
    textColor: Theme.accentText

    // Hover and press. The other bar icons answer by lighting their glyph; this
    // one is the mark (Andre, 2026-09-27: "the rime button … when you hover
    // should show its interactable"). A soft state layer behind the mark — the
    // controls' own 6 % / 10 % — and the accent plane itself lifts a little.
    Rectangle {
        anchors.centerIn: parent
        width: root.height + theme.px(8)
        height: width
        radius: width / 2
        color: root.stateLayer()
        Behavior on color { MotionColor { role: "hover" } }
    }

    RimeMark {
        id: logo
        objectName: "rimeMark"
        anchors.centerIn: parent
        // The mark is wider than tall (240:175); 20 px wide keeps it inside the
        // IconBtn at the height the spark had.
        width: theme.px(20)
        height: Math.round(width * 175 / 240)
        accent: root.hovered || root.pressed ? Qt.lighter(Theme.active, 1.25) : Theme.active
        foreground: root.hovered || root.pressed ? Theme.textPrimary : Theme.text
        Behavior on accent { MotionColor { role: "hover" } }
        Behavior on foreground { MotionColor { role: "hover" } }
    }

    // The open state of the control that opened the power menu (brief §D.5:
    // the same rule on the left notch as on the right).
    OpenPill { shown: Popups.archMenuOpen; glyph: logo }

    onClicked: {
        var next = !Popups.archMenuOpen
        Popups.closeAll()
        Popups.archMenuOpen = next
    }
}
