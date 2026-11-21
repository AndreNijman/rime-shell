pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

// ─────────────────────────────────────────────────────────────────────────────
// LockFileService — tells rime-remoted whether the screen is locked.
//
// A paired phone can be this computer's touchpad and keyboard (rime-os,
// docs/remote-live-contract.md §2.16), and input injected that way reaches the
// lock screen on every compositor Rime ships. rime-remoted stops it whenever
// any lock source it can read says locked. This file is the Shell's source:
//
//   $XDG_RUNTIME_DIR/rime-remote/lock.json    {"locked":true} or {"locked":false}
//
// The daemon's rules (rime-remoted/src/input.rs, read_shell_file and locked):
//   * it reads the file only when it is a regular file (no symlink, opened with
//     O_NOFOLLOW), owned by this user, with no group or other write bit, at most
//     4 KiB, holding {"locked":<bool>}. Anything else there counts as LOCKED.
//   * the file can only ever say locked: "unlocked" also needs logind's
//     LockedHint false.
//   * on a compositor with no lock notifier (labwc, niri) an ABSENT file counts
//     as locked, so there the touchpad works only once this file says false.
//
// What this writes, and when:
//   * {"locked":true} the moment a lock is asked for (LockState.lockStarting(),
//     emitted by LockState.lock() before it captures or engages anything), so
//     the file says locked before the compositor is asked for the lock and
//     before the lock surface can have focus. The write is synchronous: when
//     the signal handler returns, the new file is in place.
//   * {"locked":false} only once nothing says locked any more: LockState not
//     locked, not capturing, not unlocking, and WlSessionLock's `secure`
//     (mirrored in LockState.lockSecure) gone. ext-session-lock has no unlock
//     acknowledgement: `secure` drops when this Shell has sent the unlock
//     (synchronously, on Quickshell 0.3.2) or when the compositor ended the
//     lock. Waiting for it also covers a lock the compositor holds that
//     LockState does not know about, as during a reload takeover.
//   * the current state when the Shell starts or reloads (start rule below).
//
// How: FileView with atomicWrites (a temporary file renamed into place, so a
// reader never sees half a file) and blockWrites (done when setText returns).
// Measured on Quickshell 0.3.2: such a write keeps an existing file's mode, but
// creates a NEW file 0666 & ~umask (0664 under Fedora's umask 002) and a missing
// directory 0775. A 0664 file is one the daemon refuses (locked). So a helper
// (`ensure`) makes the directory 0700 and the file 0600 after the start write
// and after every write of false, then re-reads the file and writes false
// again if that is the state (FileView skips a write of the text it last
// wrote, so the re-read is what makes it happen); every later rename then
// keeps 0600. The helper itself only ever creates the file
// saying {"locked":true}, never false, and never over an existing file, so a
// helper that finishes late can never open the gate.
//
// Start rule. The Shell cannot learn from the compositor whether the session is
// locked when it starts: `WlSessionLock.secure` reads false at
// Component.onCompleted in every case measured, including a reload mid-lock and
// a restart while the compositor still held a lock. The only record that
// survives a reload or a restart is this file. So:
//   * absent → unlocked (nothing has said locked in this runtime dir);
//   * exactly {"locked":false} → unlocked;
//   * anything else (it says locked, it cannot be read, it is not a regular
//     file) → this Shell keeps saying locked (`sticky`) until a lock that THIS
//     Shell engaged has been released. After a reload or restart mid-lock the
//     file therefore says locked until the next lock and unlock.
// Known limit: the runtime dir is per user, not per login. It survives a
// logout while lingering or while another session (ssh) is open, so a session
// that ended locked leaves {"locked":true} and the next login starts sticky
// (the touchpad waits for one lock and unlock). Fail-closed, on purpose.
// LockedHintService's start push and its secure→false push use the same
// `sticky`, so logind and this file cannot disagree about it (Lockscreen.qml).
//
// No exit hook, on purpose. Measured on Quickshell 0.3.2: SIGTERM (how a
// service manager stops the Shell) runs no QML at all, and Qt.quit() runs
// Component.onDestruction, which ALSO runs on every reload, after the new
// generation has written its own state. A removal there would delete the new
// generation's file. So the file keeps the last state written: a Shell that
// exits while locked leaves {"locked":true}; one that exits unlocked leaves
// {"locked":false}, which is the truth about a session nothing has locked.
//
// No $XDG_RUNTIME_DIR, no file: the daemon then reads an absent file (locked on
// labwc and niri).
// ─────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    readonly property string runtimeDir: Quickshell.env("XDG_RUNTIME_DIR") || ""
    readonly property string dir: root.runtimeDir === "" ? "" : root.runtimeDir + "/rime-remote"
    readonly property string path: root.dir === "" ? "" : root.dir + "/lock.json"

    // Locked from the start rule above, until a lock this Shell engaged is
    // released. Set once, at construction; cleared only by the compositor
    // acknowledging a lock of ours (LockState.lockSecure turning true).
    property bool sticky: false

    // What the file says while this Shell runs. Locked unless every flag says
    // otherwise, as IpcManager.shellLockState() counts it for the live update.
    readonly property bool locked: root.sticky
                                   || LockState.locked !== false
                                   || LockState.capturing !== false
                                   || LockState.unlocking !== false
                                   || LockState.lockSecure !== false

    // The value last written by this generation, or undefined.
    property var _written: undefined

    onLockedChanged: {
        root._write(root.locked)
        if (!root.locked) root._ensure()
    }

    readonly property Connections _lockState: Connections {
        target: LockState
        // Before LockState captures or engages anything. Synchronous: the file
        // says locked when this returns.
        function onLockStarting() { root._write(true) }
        function onLockSecureChanged() {
            if (LockState.lockSecure) root.sticky = false
        }
    }

    // The start read, the writes. One FileView. blockAllReads makes the start
    // read (text() in _startsUnlocked) wait for the previous Shell's file, and
    // run its loadFailed handler, before the first write replaces it. Measured
    // on Quickshell 0.3.2: blockLoading alone does not; in a singleton the load
    // is still in flight at Component.onCompleted (loaded false, no loadFailed
    // yet), so an absent file read as "could not read it".
    readonly property FileView _file: FileView {
        path: root.path
        blockLoading: true
        blockAllReads: true
        blockWrites: true
        atomicWrites: true
        watchChanges: false
        printErrors: false
        // Runs inside the start read's text(), before it returns.
        onLoadFailed: function (error) {
            root._absent = error === FileViewError.FileNotFound
        }
        onSaveFailed: function (error) {
            root._written = undefined
            console.warn("LockFileService: could not write " + root.path + ": "
                         + FileViewError.toString(error))
        }
    }

    // Whether the previous Shell's file lets this one start unlocked.
    function _startsUnlocked() {
        const text = String(root._file.text())
        if (!root._file.loaded) return root._absent
        try {
            const v = JSON.parse(text)
            return v !== null && typeof v === "object" && !Array.isArray(v) && v.locked === false
        } catch (e) {
            return false
        }
    }
    // The start read found no file at all (not "could not read it").
    property bool _absent: false

    // `fresh`: re-read the file first. FileView compares a write with the text
    // it last read or wrote and skips an equal one, so without the re-read a
    // false over a file something else changed would never be written.
    function _write(value, fresh) {
        if (root.path === "" || root._written === value) return
        root._written = value
        if (fresh) {
            root._file.reload()
            root._file.text()
        }
        root._file.setText(value ? "{\"locked\":true}\n" : "{\"locked\":false}\n")
    }

    // ── The modes ────────────────────────────────────────────────────────────
    // Directory 0700, file 0600, no symlink at either. Creates the file only
    // when it is missing, and then only as {"locked":true} (mv -n: never over a
    // file a write put there meanwhile). Leaves a directory that is a symlink,
    // or a path that is not a regular file, alone: the daemon counts both as
    // locked, and nothing here can make them safe.
    function _ensure() {
        if (root.path === "") return
        root._ensureAgain = root._ensureProc.running
        if (!root._ensureProc.running) root._ensureProc.running = true
    }
    property bool _ensureAgain: false
    readonly property Process _ensureProc: Process {
        command: ["sh", "-c",
            "umask 077; d=$1; f=$2; " +
            "[ -L \"$d\" ] && exit 1; " +
            "mkdir -p -- \"$d\" && chmod 700 -- \"$d\" || exit 1; " +
            "[ -L \"$f\" ] && rm -f -- \"$f\"; " +
            "if [ ! -e \"$f\" ]; then " +
            "  t=\"$d/.lock.json.$$\"; " +
            "  printf '{\"locked\":true}\\n' > \"$t\" && chmod 600 -- \"$t\" && mv -n -- \"$t\" \"$f\"; " +
            "  rm -f -- \"$t\"; " +
            "fi; " +
            "[ -f \"$f\" ] && [ ! -L \"$f\" ] && chmod 600 -- \"$f\"",
            "sh", root.dir, root.path]
        running: false
        onExited: function (exitCode, exitStatus) {
            if (exitCode !== 0)
                console.warn("LockFileService: could not make " + root.dir + " private (exit " + exitCode + ")")
            // The helper may have put {"locked":true} in place of a missing
            // file: say false again if that is the state now. The rename
            // keeps the 0600 it just set.
            if (!root.locked) {
                root._written = undefined
                root._write(false, true)
            }
            if (root._ensureAgain) {
                root._ensureAgain = false
                root._ensureProc.running = true
            }
        }
    }

    Component.onCompleted: {
        if (root.path === "") return
        root.sticky = !root._startsUnlocked()
        root._write(root.locked)
        root._ensure()
    }
}
