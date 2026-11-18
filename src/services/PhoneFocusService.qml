pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"
import "remotepairing.js" as RP

// ────────────────────────────────────────────────────────────────────────────
// PhoneFocusService — Do Not Disturb follows your phone, both ways.
//
// Off unless Settings → Paired devices → "Do Not Disturb follows your phone"
// is on. While it is off this reads no file and runs no command.
//
// Phone → here: rime-remoted writes $XDG_RUNTIME_DIR/rime-remote/focus.json
// (whole, by rename) when a phone that follows Focus reports a CHANGED Do Not
// Disturb. A FileView with watchChanges watches the file's directory
// (measured, Quickshell 0.3.2); it cannot watch a directory that does not
// exist yet, so while the file is absent a slow timer re-arms the watch, as
// UpdateStateService does.
//
// Start rule: a file written before following was switched on -- or before
// this Shell started, if it was already on -- is not applied. It describes a
// moment that has passed, and a Shell restart must not put back a phone's
// state over one the person has since chosen here. The next change on the
// phone applies; the daemon also writes the file again for each phone's first
// report after the daemon starts.
//
// Here → phone: when the PERSON changes Do Not Disturb in the Shell (Quick
// Settings, Settings → Data), `rime remote focus on|off` tells every connected
// phone that follows Focus. A change this service made from the file is never
// sent back: both sides send state, never a toggle, so even an echo would
// stop at once, but there is nothing to gain from sending it.
// ────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    readonly property bool enabled: SettingsService._loaded && SettingsService.phoneFocus
    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
    readonly property string focusPath: root.runtimeDir === "" ? "" : root.runtimeDir + "/rime-remote/focus.json"
    // How often an ABSENT file is looked for again. Tests shorten it.
    readonly property int rearmInterval: parseInt(Quickshell.env("RIME_PHONE_FOCUS_REARM_MS") || "15000", 10)

    // When following was switched on (or the Shell started with it on):
    // files written before this are history. See the start rule above.
    property real _sinceMs: 0
    // The last write acted on, so a reload of the same file does nothing.
    property var _last: null
    property bool _present: false
    // True only while this service itself is setting ShellState.dnd.
    property bool _fromFile: false
    // The Do Not Disturb last handed to the CLI, so a change made while one
    // command is running is sent once that one ends, in order.
    property var _sent: null
    property bool _pending: false

    onEnabledChanged: root._arm()
    Component.onCompleted: root._arm()

    function _arm() {
        root._present = false
        if (!root.enabled) return
        root._sinceMs = Date.now()
        root._last = null
        focusFile.reload()
    }

    function _apply(text) {
        if (!root.enabled) return
        const f = RP.parseFocus(text)
        if (!RP.focusIsNew(f, root._sinceMs, root._last)) return
        root._last = f
        if (ShellState.dnd === f.dnd) return
        root._fromFile = true
        ShellState.dnd = f.dnd
        root._fromFile = false
    }

    function _send() {
        if (sender.running) { root._pending = true; return }
        root._pending = false
        root._sent = ShellState.dnd
        sender.command = RP.focusCommand(ShellState.dnd)
        sender.running = true
    }

    Connections {
        target: ShellState
        function onDndChanged() {
            if (root.enabled && !root._fromFile) root._send()
        }
    }

    // Fire and forget: whether 0 or 3 phones were reached, the Shell's own
    // Do Not Disturb has already changed, and nothing here would say so.
    Process {
        id: sender
        onExited: {
            if (root._pending && root.enabled && ShellState.dnd !== root._sent) root._send()
            root._pending = false
        }
    }

    FileView {
        id: focusFile
        path: root.enabled ? root.focusPath : ""
        watchChanges: root.enabled
        printErrors: false
        onFileChanged: reload()
        onLoaded: { root._present = true; root._apply(String(text())) }
        onLoadFailed: root._present = false
    }

    Timer {
        interval: Math.max(250, root.rearmInterval)
        repeat: true
        running: root.enabled && root.focusPath !== "" && !root._present
        onTriggered: {
            focusFile.watchChanges = false
            focusFile.watchChanges = true
            focusFile.reload()
        }
    }
}
