pragma Singleton
import QtQuick
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// KeyboardLayoutService — the keyboard layouts the compositor has loaded, which
// one is active, and the verbs to change it, for the bar's layout chip.
//
// A thin reader over CompositorService.keyboardLayouts: the compositor IPC
// (`hyprctl devices`, `switchxkblayout`) lives in the adapter, where the rest of
// it does. `available` is false until there is more than one layout to switch
// between, and on a compositor that cannot report them (niri, labwc) it stays
// false, so the chip never appears.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: root

    readonly property var    labels:  CompositorService.keyboardLayouts.labels
    readonly property var    names:   CompositorService.keyboardLayouts.names
    readonly property int    index:   CompositorService.keyboardLayouts.index
    readonly property bool   available: CompositorService.can.keyboardLayouts && root.labels.length > 1
    readonly property string current:     root.labels[root.index] ?? ""
    readonly property string currentName: root.names[root.index] ?? root.current

    function next() { CompositorService.switchKeyboardLayout("next") }
    function prev() { CompositorService.switchKeyboardLayout("prev") }
}
