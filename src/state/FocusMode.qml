pragma Singleton
import QtQuick
import "../."

// ─────────────────────────────────────────────────────────────────────────────
//  Focus Mode (SUPER+B, the Quick Settings tile, `qs ipc call focus-toggle`)
//
//  Shrinks the bar, and on a compositor that has runtime gaps, closes those
//  too. A compositor without runtime gaps refuses both gap calls and only the
//  bar flips.
//
//  This lived in QuickSettings, which the dashboard builds only when its home
//  page is first shown. IpcManager's focus-toggle target emitted a signal that
//  only QuickSettings listened to, so SUPER+B did nothing until the dashboard
//  had been opened once. A singleton is built on its first use, which is the
//  first press, from any of the three routes.
//
//  A press while a gaps write settles (or while the read before a shrink is
//  out) is QUEUED, not dropped: it runs once the write has settled. Two presses
//  inside the window cancel out, as two presses do. The old code returned and
//  the press was lost with no sign: SUPER+B twice quickly left focus mode on.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: root

    // The compositor facade. A property so a test can hand it a fake; the
    // shell never sets it.
    property var compositor: CompositorService

    property int _savedGapsIn:  5
    property int _savedGapsOut: 10

    // Why a busy window exists: flipping focusMode before the restore write
    // had landed let a second press take the READ branch while that write was
    // still running; if the read won, the saved gaps were overwritten with the
    // shrunken 0/6 and the user's real gaps were gone for the session.
    property bool busy: false
    // A press that arrived while busy. A second one cancels it.
    property bool queued: false

    // How long a gaps write is given to land before the next press reads.
    property Timer _settled: Timer {
        interval: 250
        repeat:   false
        onTriggered: root._settle()
    }
    // A read that never answers must not hold every later press forever.
    property Timer _readDeadline: Timer {
        interval: 3000
        repeat:   false
        onTriggered: {
            console.warn("Rime focus mode: the gaps read did not answer in 3 s; only the bar follows")
            root._reading = false
            if (!ShellState.focusMode) ShellState.focusMode = true
            root._settle()
        }
    }
    property bool _reading: false
    // Whether this focus mode closed the gaps. Turning it off restores them
    // only then: after a failed read nothing was shrunk, and writing the
    // 5/10 default back would replace the user's own gaps.
    property bool _shrunk: false

    function toggle() {
        if (root.busy) {
            root.queued = !root.queued
            console.info("Rime focus mode: press queued until the gaps settle (" +
                         (root.queued ? "will toggle" : "two presses, no change") + ")")
            return
        }
        root._apply()
    }

    function _settle() {
        root.busy = false
        if (root.queued) {
            root.queued = false
            root._apply()
        }
    }

    function _apply() {
        const c = root.compositor
        if (ShellState.focusMode) {
            ShellState.focusMode = false
            if (!root._shrunk) return
            root._shrunk = false
            if (c.setGaps(root._savedGapsIn, root._savedGapsOut)) {
                root.busy = true
                root._settled.restart()
            }
            return
        }

        // Read before shrinking, so what gets restored is what the user had and
        // not the 5/10 default. If the read fails, or gaps are not a runtime
        // concept here, flip the bar alone rather than apply a shrink we could
        // never undo.
        root.busy = true
        root._reading = true
        root._readDeadline.restart()
        c.readGaps(function (ok, g) {
            if (!root._reading) return          // the deadline already gave up on it
            root._reading = false
            root._readDeadline.stop()
            ShellState.focusMode = true
            if (ok) {
                root._savedGapsIn  = g.inner
                root._savedGapsOut = g.outer
                if (c.setGaps(0, 6)) {
                    root._shrunk = true
                    root._settled.restart()
                    return
                }
            }
            root._settle()
        })
    }
}
