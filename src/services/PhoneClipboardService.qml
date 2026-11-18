pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../"
import "remotepairing.js" as RP

// ────────────────────────────────────────────────────────────────────────────
// PhoneClipboardService — this computer's clipboard on the paired phones.
//
// Off unless Settings → Paired devices → "Send my clipboard to my phone" is
// on. While it is off nothing watches the clipboard and nothing is run.
//
// On, `wl-paste --type text --watch` runs a small script per selection change
// (RP.CLIPBOARD_WATCH_SCRIPT). Each new text goes to `rime remote clipboard`
// on STDIN, never in an argument, and rime-remoted puts it on every connected
// phone that asked for this computer's clipboard (contract §2.10). The daemon
// itself never watches the clipboard: this switch is the only thing that
// starts the watching, and only for this person's own session.
//
// What is not sent: a password manager's copy (wl-paste reports it as
// "sensitive"), anything that is not text (an image arrives as "nil"), an
// empty or cleared selection, and text over RP.CLIPBOARD_MAX_BYTES.
//
// Measured on wl-clipboard 2.3.0:
//   * the watcher reports the clipboard once as it starts. That copy was made
//     before the switch went on (or before this Shell started), so it is not
//     sent;
//   * `wl-copy --clear` ends the watcher (a broken pipe), so it is started
//     again after a short wait, which doubles on each quick exit.
//
// Copies close together: the first goes at once and then at most one each
// 500 ms, the latest winning. Anything not sent (a sensitive copy, an image)
// also drops the text still waiting: what is on the clipboard now is what
// counts, and the phone is not handed the copy before a password.
// ────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    readonly property bool enabled: SettingsService._loaded && SettingsService.phoneClipboard
    readonly property int gapMs: 500

    // The first event of each watcher run is the clipboard as it already was.
    property bool _skipFirst: true
    // Base64 of the text waiting to be sent; "" when nothing waits.
    property string _pending: ""
    property real _lastSentMs: 0
    property int _restartMs: 1000

    onEnabledChanged: root._arm()
    Component.onCompleted: root._arm()

    function _arm() {
        root._pending = ""
        gap.stop()
        restart.stop()
        root._restartMs = 1000
        root._skipFirst = true
        watcher.running = root.enabled
    }

    function _event(line) {
        if (!root.enabled) return
        // A line from the watcher means it is working: a later exit waits
        // the shortest time again.
        root._restartMs = 1000
        if (root._skipFirst) { root._skipFirst = false; return }
        const e = RP.clipboardEvent(line)
        root._pending = e.send ? e.b64 : ""
        root._pump()
    }

    function _pump() {
        if (!root.enabled || root._pending === "" || sender.running) return
        const wait = root._lastSentMs + root.gapMs - Date.now()
        if (wait > 0) { gap.interval = wait; gap.restart(); return }
        sender.text = root._pending
        root._pending = ""
        root._lastSentMs = Date.now()
        sender.running = true
    }

    Process {
        id: watcher
        command: RP.clipboardWatchCommand()
        stdout: SplitParser { onRead: function(line) { root._event(line) } }
        onExited: {
            if (!root.enabled) return
            root._skipFirst = true
            restart.interval = root._restartMs
            root._restartMs = Math.min(root._restartMs * 2, 30000)
            restart.restart()
        }
    }

    Timer {
        id: restart
        repeat: false
        onTriggered: if (root.enabled) watcher.running = true
    }

    Timer {
        id: gap
        repeat: false
        onTriggered: root._pump()
    }

    // Fire and forget: how many phones took it is no business of the person
    // copying. The base64 goes in on stdin, then stdin closes.
    Process {
        id: sender
        property string text: ""
        command: RP.clipboardSendCommand()
        stdinEnabled: true
        onStarted: {
            write(sender.text)
            sender.text = ""
            stdinEnabled = false
        }
        onExited: {
            stdinEnabled = true
            root._pump()
        }
    }
}
