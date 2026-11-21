pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

// ─────────────────────────────────────────────────────────────────────────────
// LockKeeper — a configuration reload or a Shell restart never unlocks.
//
// Quickshell 0.3.2 cannot carry a held session lock across a reload. Measured
// with WAYLAND_DEBUG on labwc, the lock in windows/Lockscreen.qml
// (WlSessionLock::onReload, the ext-session-lock-v1 protocol):
//   * a new generation whose lock is NOT wanted at the moment Quickshell hands
//     it the old one takes the old ext_session_lock_v1 over and sends
//     unlock_and_destroy: the session is unlocked with no password. Today's
//     Shell was exactly that (LockState.locked starts false), on a soft reload.
//   * a new generation that DOES want it asks for a second lock surface on an
//     output that has one (get_lock_surface while the old surface lives):
//     protocol error 3, duplicate_output, and the process exits.
//   * a hard reload destroys the old generation's lock while locked: error 0,
//     invalid_destroy, and the process exits.
// A config cannot refuse a reload (RootWrapper::reloadGraph has no veto), so:
//
// 1. Nothing the Shell controls reloads while a lock is held or being taken.
//    The two triggers a config owns are the file watcher, switched off here
//    from LockState.lockStarting() until the lock is over (Quickshell.watchFiles;
//    turned off again after a failed reload, which turns it back on), and
//    Quickshell.reload(), which nothing in src/ calls except reload() below
//    (tests/check-lock-writes.sh, RELOADS). A reload asked for meanwhile, or a
//    file changed meanwhile, reloads once the lock is over.
// 2. If a reload happens anyway, it fails CLOSED. A record of the held lock
//    ($XDG_RUNTIME_DIR/rime-shell/lock-held.json, below) makes the new
//    generation call LockState.resume() while it is being created, before
//    Quickshell hands it the old lock, so it cannot take that lock over and
//    release it. It then dies on the protocol error, the compositor keeps the
//    session locked (an abandoned lock), and rime-shell-relaunch.sh, started
//    from here first, starts the Shell again once that process has ended. The
//    new Shell finds the record and locks at once, which brings the password
//    prompt back. A reload while a lock is still waiting for its picture (no
//    lock sent yet) resumes just after the reload instead, in the same process.
// 3. A Shell killed while locked and started again (by anything) locks at once
//    on the same record. Whether the compositor lets it replace the dead
//    client's lock is the compositor's call: labwc does ("replacing abandoned
//    lock", measured); Hyprland needs misc:allow_session_lock_restore.
//
// The record can only ever ADD locking: it makes a Shell lock at start, and
// nothing reads it to unlock. It is honoured only for the compositor instance
// that wrote it (`compositor`, from the variables each compositor exports to
// its clients), so a stale record from an earlier login never locks a new one.
// It says {"held":true} from lockStarting() and {"held":false} once the lock is
// over: not locked, not capturing, not unlocking, `secure` gone.
// ─────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
    readonly property string path: root.runtimeDir === "" ? "" : root.runtimeDir + "/rime-shell/lock-held.json"
    readonly property int pid: Number(Quickshell.processId)

    // The compositor instance this Shell runs on. A new login, or a compositor
    // restarted, gets a new value; a reload or a Shell restart keeps it.
    readonly property string compositor: {
        const parts = []
        for (const v of ["HYPRLAND_INSTANCE_SIGNATURE", "LABWC_PID", "NIRI_SOCKET", "SWAYSOCK", "WAYLAND_DISPLAY"]) {
            const x = Quickshell.env(v)
            if (x) parts.push(v + "=" + x)
        }
        return parts.join(";")
    }

    // A lock is held or being taken: what the record and the reload gate follow.
    readonly property bool holding: LockState.locked !== false
                                    || LockState.capturing !== false
                                    || LockState.unlocking !== false
                                    || LockState.lockSecure !== false

    // ── 1. The reload gate ──────────────────────────────────────────────────
    // The ONE way to reload the Shell. While a lock is held or being taken the
    // reload waits until it is over. Returns whether it reloaded now.
    function reload(hard) {
        if (root.holding) {
            root._pending = true
            root._pendingHard = root._pendingHard || hard === true
            console.info("LockKeeper: reload deferred until the session is unlocked")
            return false
        }
        Quickshell.reload(hard === true)
        return true
    }
    property bool _pending: false
    property bool _pendingHard: false
    // When the current lock started (ms since the epoch), for the changed-file
    // check after it.
    property real _since: 0

    function _gate() {
        if (root.holding && Quickshell.watchFiles) Quickshell.watchFiles = false
    }

    readonly property Connections _lockState: Connections {
        target: LockState
        // Before LockState captures or engages anything: no file change can
        // reload from here on, and the record says held before the compositor
        // is asked for the lock.
        function onLockStarting() {
            if (!root.holding) root._since = Date.now()
            Quickshell.watchFiles = false
            root._write(true, false)
        }
        // The lock has been sent (or is about to be: the WlSessionLock binding
        // runs on the same change). From here a reload must fail closed in the
        // new generation's creation rather than resume after it.
        function onLockedChanged() {
            if (LockState.locked) root._write(true, true)
        }
    }

    // Quickshell turns the file watcher back on at the start of every reload
    // (QuickshellSettings::reset), even one that then fails and leaves this
    // generation running.
    readonly property Connections _reloads: Connections {
        target: Quickshell
        function onReloadFailed(errorString) { root._gate() }
        function onWatchFilesChanged() { root._gate() }
    }

    onHoldingChanged: {
        if (root.holding) { root._gate(); return }
        // The lock is over. The record first: a reload from here on must not
        // lock again.
        root._write(false, false)
        Quickshell.watchFiles = true
        root._after.restart()
    }

    // After the unlock: the reload asked for during the lock, or one for files
    // the watcher did not see change while it was off. A beat later, so the
    // unlock's own frames are not rebuilt under it.
    readonly property Timer _after: Timer {
        interval: 500
        repeat: false
        onTriggered: {
            if (root.holding) return
            if (root._pending) {
                const hard = root._pendingHard
                root._pending = false
                root._pendingHard = false
                Quickshell.reload(hard)
                return
            }
            if (root._since > 0 && Quickshell.shellDir) {
                root._changed.command = ["find", Quickshell.shellDir,
                    "(", "-name", "*.qml", "-o", "-name", "*.js", "-o", "-name", "qmldir", ")",
                    "-newermt", "@" + (root._since / 1000).toFixed(3), "-print", "-quit"]
                root._changed.running = true
            }
        }
    }
    readonly property Process _changed: Process {
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                if (text.trim() !== "" && !root.holding) {
                    console.info("LockKeeper: files changed while the session was locked; reloading")
                    Quickshell.reload(false)
                }
            }
        }
    }

    // ── 2./3. The record ─────────────────────────────────────────────────────
    readonly property FileView _file: FileView {
        path: root.path
        blockLoading: true
        blockAllReads: true
        blockWrites: true
        atomicWrites: true
        watchChanges: false
        printErrors: false
        onSaveFailed: function (error) {
            root._written = ""
            console.warn("LockKeeper: could not write " + root.path + ": " + FileViewError.toString(error))
        }
    }
    property string _written: ""
    function _write(held, engaged) {
        if (root.path === "") return
        const text = JSON.stringify({ "held": held === true, "engaged": held === true && engaged === true,
                                      "pid": root.pid, "compositor": root.compositor }) + "\n"
        if (text === root._written) return
        root._written = text
        root._file.setText(text)
    }
    function _read() {
        if (root.path === "") return null
        const text = String(root._file.text())
        if (!root._file.loaded) return null
        try {
            const v = JSON.parse(text)
            return v !== null && typeof v === "object" && !Array.isArray(v) ? v : null
        } catch (e) {
            return null
        }
    }

    // This process's command line and start time, for the relauncher. Read at
    // the moment it is needed: /proc/self is this process.
    readonly property FileView _cmdline: FileView {
        path: "/proc/self/cmdline"
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    readonly property FileView _stat: FileView {
        path: "/proc/self/stat"
        blockLoading: true
        blockAllReads: true
        printErrors: false
    }
    function _relaunchAfterExit() {
        const argv = String(root._cmdline.text()).split("\u0000").filter(function (a, i, all) {
            return !(a === "" && i === all.length - 1)
        })
        const stat = String(root._stat.text())
        const fields = stat.slice(stat.lastIndexOf(")") + 2).split(" ")
        const starttime = fields.length > 19 ? fields[19] : ""
        if (argv.length === 0 || argv[0] === "" || starttime === "") {
            console.warn("LockKeeper: cannot read this process's command line; it will not be started again")
            return
        }
        Quickshell.execDetached({
            "command": ["sh", Quickshell.shellDir + "/src/scripts/rime-shell-relaunch.sh",
                        String(root.pid), starttime].concat(argv),
            "workingDirectory": Quickshell.workingDirectory,
            // The new Shell writes where this one did (the session's journal).
            "unbindStdout": false
        })
    }

    // ── Start ────────────────────────────────────────────────────────────────
    // Runs while this generation is being created: the first reference is
    // shell.qml's and Lockscreen.qml's Component.onCompleted, both of which
    // run before Quickshell hands a new generation the old one's lock.
    property bool _started: false
    function start() {
        if (root._started) return
        root._started = true
        const rec = root._read()
        if (rec === null || rec.held !== true || rec.compositor !== root.compositor) return
        if (rec.pid === root.pid) {
            // A reload of this very process while it held the lock.
            console.warn("LockKeeper: the configuration was reloaded while the session was locked; keeping it locked")
            root._relaunchAfterExit()
            if (rec.engaged !== true) {
                // No lock was sent yet (it was waiting for its picture): there
                // is no old lock to hand over, and a lock wanted during the
                // handover would collide with itself. Lock just after it.
                Qt.callLater(function () { LockState.resume() })
                return
            }
        } else {
            console.warn("LockKeeper: the Shell was restarted while the session was locked; locking again")
        }
        LockState.resume()
    }
    Component.onCompleted: root.start()
}
