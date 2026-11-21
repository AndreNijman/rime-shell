import Quickshell
import QtQuick

// The desktop, as far as tests/run-reload-lock-test.sh is concerned: an
// ordinary window with a focused text field, in its OWN process, so it sees
// what the compositor gives a normal client whatever happens to the Shell.
// A virtual keyboard types letters at whatever has focus the whole run; every
// letter this field receives, and every change of the window's active state,
// is printed with the time. While the session is locked it must receive
// nothing.
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 320
        implicitHeight: 160
        visible: true
        color: "white"

        TextInput {
            id: field
            anchors.fill: parent
            focus: true
            onTextChanged: console.warn("PROBE " + Date.now() + " key " + text.length)
        }

        property bool wasActive: false
        Timer {
            interval: 10
            repeat: true
            running: true
            onTriggered: {
                const a = field.Window.active === true
                if (a !== win.wasActive) {
                    win.wasActive = a
                    console.warn("PROBE " + Date.now() + " active " + a)
                }
            }
        }
    }
    Component.onCompleted: console.warn("PROBE " + Date.now() + " up")
}
