import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/services"
import "./src/nexus"

// Do Not Disturb follows your phone, run for real (tests/run-phone-focus-test.sh stages this file at the
// repository root, with a private HOME and XDG_RUNTIME_DIR and a stub `rime` first on PATH). This file only
// stands in for the person: it reads one command at a time from $PF_CMD ("<n> dnd on|off" = a Quick Settings
// toggle, "<n> follow on|off" = the Settings switch) and reports what the Shell's Do Not Disturb does.

ShellRoot {
    id: t

    // Compiled first, as in the Shell (see visualiser-battery-test.qml).
    readonly property var _pages: NexusState
    readonly property var _focus: PhoneFocusService

    property int _seq: 0

    Connections {
        target: ShellState
        function onDndChanged() { console.log("PF dnd " + ShellState.dnd) }
    }
    Connections {
        target: PhoneFocusService
        function onEnabledChanged() { console.log("PF enabled " + PhoneFocusService.enabled) }
    }

    FileView {
        id: cmd
        path: Quickshell.env("PF_CMD")
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const w = String(text()).trim().split(" ")
            const n = parseInt(w[0], 10)
            if (!(n > t._seq)) return
            t._seq = n
            if (w[1] === "dnd") ShellState.dnd = (w[2] === "on")
            else if (w[1] === "follow") SettingsService.set("phoneFocus", w[2] === "on")
            console.log("PF did " + n)
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            if (!SettingsService._loaded) return
            running = false
            console.log("PF ready enabled " + PhoneFocusService.enabled + " dnd " + ShellState.dnd)
        }
    }
}
