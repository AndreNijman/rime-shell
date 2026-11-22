pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "remotepairing.js" as RP

// ────────────────────────────────────────────────────────────────────────────
// TouchpadService — whether a paired phone is this computer's touchpad and
// keyboard right now, and the Stop that ends it (rime-os
// docs/remote-live-contract.md §2.16).
//
// rime-remoted keeps $XDG_RUNTIME_DIR/rime-remote/input.json, 0600, written
// whole and renamed into place:
//     {"v":1,"live":true,"device":"<id>","name":"Pixel 8","since_ms":N}
//     {"v":1,"live":false}
// It writes live:false when it starts and never removes the file, so an
// ABSENT file means no rime-remoted (or one too old to have the touchpad):
// not live. So is anything else that is not exactly the live shape (garbage,
// half a file, a file past 64 KiB): remotepairing.js parseTouchpad.
//
// The phone's name is the phone's choice. The daemon cleans it where it
// writes it; any process of this user can also write the file, so the Shell
// cleans it again (touchpadName) and only ever shows it as PLAIN text: every
// Text that shows it sets Text.PlainText, and the notification, whose body
// the Shell's own toast draws as StyledText, gets it escaped. It never goes
// on a command line: Stop names no phone.
//
// Cheap, because the bar is always mapped: a FileView with watchChanges
// watches the file's DIRECTORY (measured, Quickshell 0.3.2, UpdateStateService)
// and sees the file appear, be renamed over and be deleted. The directory is
// normally there already (LockFileService makes it at start); while the file
// is absent a slow timer re-arms the watch anyway, for a directory removed and
// made again.
//
// Stop: `rime remote devices touchpad stop` (the control request
// {"cmd":"input_stop"}), the way the Shell runs every rime-remote action: an
// argv from remotepairing.js, never a shell string. The file turning
// live:false is the only proof it worked. If it still says live 3 s after
// Stop, `stopFailed` is set and the notch says stopping failed; a non-zero exit
// says so at once. The daemon then holds that phone off for 30 s.
//
// One notification when a session starts, so a person at the computer cannot
// miss it: for a live record (device, since_ms) not seen before. A record
// already live when this service starts (a Shell restart or reload in the
// middle of a session) is not announced again unless it began in the last
// 5 s; the notch shows it either way. Do Not Disturb holds the toast back
// like every other notification (NotificationService); the notch does not.
// ────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
    readonly property string statusPath: root.runtimeDir === "" ? "" : root.runtimeDir + "/rime-remote/input.json"
    // How often an ABSENT file is looked for again. Tests shorten it.
    readonly property int rearmInterval: parseInt(Quickshell.env("RIME_TOUCHPAD_REARM_MS") || "15000", 10)
    // How long Stop waits for the file to say live:false. Tests may shorten it.
    readonly property int stopTimeout: parseInt(Quickshell.env("RIME_TOUCHPAD_STOP_MS") || "3000", 10)

    property string _text: ""
    property bool _present: false
    readonly property var _state: RP.parseTouchpad(root._text)

    // ── What the notch reads ────────────────────────────────────────────────
    readonly property bool live: root._state.live
    // The phone's name, cleaned, as plain text; "A phone" when it gave none.
    readonly property string name: !root.live ? ""
                                  : (root._state.name !== "" ? root._state.name : qsTr("A phone"))
    // When it started (ms since the epoch, the daemon's clock), 0 if unknown.
    readonly property real since: root.live ? root._state.sinceMs : 0
    readonly property string device: root.live ? root._state.device : ""
    // The whole sentence, for a screen reader and the notification.
    readonly property string sentence: root.live
        ? RP.fill(qsTr("%1 is using this computer as a touchpad and keyboard"), root.name) : ""

    property bool stopping: false
    property bool stopFailed: false

    // ── Stop ────────────────────────────────────────────────────────────────
    function stop() {
        if (!root.live || root.stopping) return
        root.stopping = true
        root.stopFailed = false
        stopper.command = RP.TOUCHPAD_STOP_COMMAND
        stopper.running = true
        stopTimer.restart()
    }
    function _failStop() {
        stopTimer.stop()
        root.stopping = false
        root.stopFailed = root.live
    }

    Process {
        id: stopper
        stdout: StdioCollector {}
        stderr: StdioCollector {}
        // Exit 0 means the daemon took the request; the file says whether the
        // channel ended. Anything else is a failure now. A binary that never
        // ran is caught by the timer.
        onExited: function (code) {
            if (code !== 0 && root.stopping) root._failStop()
        }
    }
    Timer {
        id: stopTimer
        interval: Math.max(250, root.stopTimeout)
        onTriggered: if (root.stopping) root._failStop()
    }

    onLiveChanged: {
        if (!root.live) {
            stopTimer.stop()
            root.stopping = false
            root.stopFailed = false
        }
    }

    // ── The notification ───────────────────────────────────────────────────
    readonly property real _startMs: Date.now()
    property bool _settled: false        // the first read (or its failure) is behind us
    property string _announced: ""       // the last session announced or skipped

    function _consider() {
        if (root.live) {
            const key = root.device + "\n" + root.since
            if (key !== root._announced) {
                // A different session: whatever went wrong stopping the last
                // one is not about this one.
                root.stopFailed = false
                if (root._settled || (root.since > 0 && root.since >= root._startMs - 5000))
                    root._announce()
                root._announced = key
            }
        }
        root._settled = true
    }
    function _announce() {
        const body = RP.fill(qsTr("%1 is using this computer as a touchpad and keyboard. Stop it from the top bar."),
                             String.fromCharCode(0x2068) + RP.escapeMarkup(root.name) + String.fromCharCode(0x2069))
        // Detached: a second session starting while the first notification's
        // notify-send is still running must not be swallowed by a busy Process.
        Quickshell.execDetached(["notify-send", "-a", "Rime", "-i", "input-touchpad",
                                 "--", qsTr("Phone in use as a touchpad"), body])
    }

    // ── The file ────────────────────────────────────────────────────────────
    function _read(text) {
        root._text = text
        root._consider()
    }

    FileView {
        id: statusFile
        path: root.statusPath
        watchChanges: root.statusPath !== ""
        printErrors: false
        onFileChanged: reload()
        onLoaded: { root._present = true; root._read(String(text())) }
        // A FileView whose file has gone keeps the text it had: absent is
        // "not live", so the text is dropped here.
        onLoadFailed: { root._present = false; root._read("") }
    }

    Timer {
        interval: Math.max(250, root.rearmInterval)
        repeat: true
        running: root.statusPath !== "" && !root._present
        onTriggered: {
            statusFile.watchChanges = false
            statusFile.watchChanges = true
            statusFile.reload()
        }
    }
}
