import QtQuick
import Quickshell
import Quickshell.Io
import "./src/components"
import "./src/services"
import "./src/nexus"
import "./src/popups"
import "./src"
import "./src/services/system"

// Harness for tests/run-focus-mode-test.sh. Staged into the repository root by
// the runner so the relative import resolves.
//
// It holds IpcManager (as shell.qml does) and nothing else: no dashboard, no
// QuickSettings. So the focus-toggle target answers here only if Focus Mode
// works without the dashboard ever having been built.
//
// `fmtest fake <readMs>` hands FocusMode a fake compositor with runtime gaps,
// whose gaps read answers after <readMs> (never, when negative) and which logs
// every write. Until then FocusMode drives the real CompositorService (labwc
// here: no runtime gaps, so only the bar flips).
ShellRoot {
    id: root
    property var _ipc: IpcManager

    property var fake: QtObject {
        property int readMs: 0
        property var writes: []
        property int inner: 5
        property int outer: 10
        property var _pending: null
        property Timer _answer: Timer {
            repeat: false
            onTriggered: {
                const cb = root.fake._pending
                root.fake._pending = null
                if (cb) cb(true, { inner: root.fake.inner, outer: root.fake.outer })
            }
        }
        function setGaps(i, o) {
            writes = writes.concat([i + "/" + o])
            inner = i; outer = o
            return true
        }
        function readGaps(cb) {
            _pending = cb
            if (readMs >= 0) { _answer.interval = Math.max(1, readMs); _answer.restart() }
            return true
        }
    }

    IpcHandler {
        target: "fmtest"
        function fake(readMs: int): string {
            root.fake.readMs = readMs
            root.fake.writes = []
            root.fake.inner = 5; root.fake.outer = 10
            FocusMode.compositor = root.fake
            return "ok"
        }
        // Presses in one go, as a key repeat or a fast double-press lands.
        function press(n: int): string {
            for (let i = 0; i < n; i++) FocusMode.toggle()
            return "ok"
        }
        function state(): string { return ShellState.focusMode ? "on" : "off" }
        function busy(): string { return FocusMode.busy ? "busy" : "idle" }
        function writes(): string { return root.fake.writes.join(",") }
        function gaps(): string { return root.fake.inner + "/" + root.fake.outer }
    }
}
