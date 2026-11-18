import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/services"
import "./src/nexus"

// "Send my clipboard to my phone", run for real (tests/run-phone-clipboard-test.sh stages this file at the
// repository root, with a private HOME and XDG_RUNTIME_DIR, a stub `wl-paste` that plays clipboard changes the
// runner writes, and a stub `rime` first on PATH). No Wayland clipboard is touched. This file only stands in
// for the person: it reads one command at a time from $PC_CMD ("<n> send on|off" = the Settings switch).

ShellRoot {
    id: t

    // Compiled first, as in the Shell (see visualiser-battery-test.qml).
    readonly property var _pages: NexusState
    readonly property var _clip: PhoneClipboardService

    property int _seq: 0

    Connections {
        target: PhoneClipboardService
        function onEnabledChanged() { console.log("PC enabled " + PhoneClipboardService.enabled) }
    }

    FileView {
        id: cmd
        path: Quickshell.env("PC_CMD")
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const w = String(text()).trim().split(" ")
            const n = parseInt(w[0], 10)
            if (!(n > t._seq)) return
            t._seq = n
            if (w[1] === "send") SettingsService.set("phoneClipboard", w[2] === "on")
            console.log("PC did " + n)
        }
    }

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            if (!SettingsService._loaded) return
            running = false
            console.log("PC ready enabled " + PhoneClipboardService.enabled)
        }
    }
}
