import Quickshell
import Quickshell.Io
import QtQuick
import "./src/services"
import "./src/state"
import "./src/windows"

// A configuration reload, or a Shell restart, while the screen is locked must
// never leave the session usable without a password (services/system/
// LockKeeper.qml). Run through tests/run-reload-lock-test.sh, which stages this
// at the tree's root, hosts it on a headless labwc in a private runtime dir,
// and runs an OUT-OF-PROCESS probe beside it: an ordinary window with a focused
// text field that a virtual keyboard types letters at the whole time (never
// Return). The runner checks the probe's log; this file checks the Shell's side
// and prints the instants the probe's log is judged against.
//
// Lines: "RL <ms> pid <n>", "RL <ms> mark <name>", "  PASS/FAIL <what>",
// "RL <ms> done". A Shell relaunched after a reload inherits this process's
// stdout, so every process of a run writes to the same log.
//
// $RL_SCENARIO:
//   soft, hard        lock; raw Quickshell.reload(false/true) while locked
//   files             lock; this file changes on disk (the hot reload)
//   request           lock; LockKeeper.reload() asked for while locked
//   capture           a lock waiting for its picture: a file change and a
//                     LockKeeper.reload() then (both deferred)
//   capture-raw       a lock waiting for its picture; raw reload then
//   engage            a raw reload just after the lock was sent
//   unlocking         lock; the password accepted (release() running); raw reload
//   unlocking-request the same, with LockKeeper.reload()
//   restart           lock; the runner kills this process and starts another
//   foreign           a record from another compositor instance: no lock
// $RL_DIR: the runner's scratch dir (markers).

ShellRoot {
    id: t

    property string scenario: Quickshell.env("RL_SCENARIO") || "soft"
    property string dir: Quickshell.env("RL_DIR") || "/nonexistent"
    readonly property int pid: Number(Quickshell.processId)

    function say(s) { console.warn("RL " + Date.now() + " " + s) }
    function ok(what)  { console.warn("  PASS  " + t.scenario + ": " + what) }
    function bad(what) { console.warn("  FAIL  " + t.scenario + ": " + what) }
    function check(what, cond) { if (cond) t.ok(what); else t.bad(what) }
    function note(what) { console.warn("  note: " + t.scenario + ": " + what) }
    function done() { t.say("done"); t.mustBeLocked = false; t.exitSoon.start() }
    readonly property Timer exitSoon: Timer { interval: 300; onTriggered: Qt.exit(0) }

    Lockscreen { id: lock }

    // Carries a run across an in-process reload.
    PersistentProperties {
        id: keep
        reloadableId: "reload-lock-test"
        property int gen: 0
        property string step: ""
        property bool everLocked: false
        onLoaded: t.afterLoad()
    }

    // ── markers between processes ───────────────────────────────────────────
    FileView {
        id: marker
        path: t.dir + "/leg1-pid"
        blockLoading: true
        blockAllReads: true
        blockWrites: true
        printErrors: false
    }
    function leg1Pid() {
        marker.reload()
        const s = String(marker.text()).trim()
        return marker.loaded && /^\d+$/.test(s) ? Number(s) : 0
    }

    // This very file, for the hot-reload scenario.
    FileView {
        id: self
        path: Quickshell.shellDir + "/.reload-lock-test.qml"
        blockLoading: true
        blockWrites: true
        atomicWrites: true
        printErrors: true
    }

    // ── the session lock, sampled ───────────────────────────────────────────
    // From the first `secure` of this process until the authenticated release,
    // every 10 ms: the lock must never drop.
    property bool mustBeLocked: false
    property int drops: 0
    readonly property Timer sampler: Timer {
        interval: 10
        repeat: true
        running: t.mustBeLocked
        onTriggered: if (!lock.secure) t.drops++
    }
    Connections {
        target: lock
        function onSecureStateChanged() {
            t.say("secure=" + lock.secure)
            if (lock.secure && !t.mustBeLocked && !t.released) { t.mustBeLocked = true; t.say("mark locked") }
        }
    }
    property bool released: false
    // What PAM success calls (Lockscreen's surface does exactly this).
    function authenticate() {
        t.check("the session lock never dropped while it had to hold (" + t.drops + " of the 10 ms samples)",
                t.drops === 0)
        t.mustBeLocked = false
        t.released = true
        t.say("mark released")
        lock.release()
    }

    // ── waiting ─────────────────────────────────────────────────────────────
    property var waitCond: null
    property var waitThen: null
    readonly property Timer waitTimer: Timer {
        interval: 20
        repeat: true
        property int tries: 0
        property int limit: 100
        onTriggered: {
            tries++
            const c = t.waitCond
            if ((c && c()) || tries >= limit) {
                stop()
                const met = c ? c() : false
                const f = t.waitThen
                t.waitCond = null; t.waitThen = null; tries = 0
                if (f) f(met)
            }
        }
    }
    function waitFor(cond, ms, then) {
        t.waitCond = cond; t.waitThen = then
        t.waitTimer.limit = Math.ceil(ms / 20); t.waitTimer.tries = 0
        t.waitTimer.restart()
    }
    property var afterPause: null
    readonly property Timer pauseTimer: Timer {
        repeat: false
        onTriggered: { const f = t.afterPause; t.afterPause = null; if (f) f() }
    }
    function pause(ms, then) { t.afterPause = then; t.pauseTimer.interval = ms; t.pauseTimer.restart() }

    // A raw reload, as anything outside the Shell's own code could cause one.
    // From a timer, never inside a handler of something the reload destroys.
    property bool rawHard: false
    readonly property Timer rawReload: Timer {
        interval: 1
        repeat: false
        onTriggered: { t.say("mark raw-reload"); Quickshell.reload(t.rawHard) }
    }
    function reloadRaw(hard) {
        keep.step = "reloaded"
        keep.gen = keep.gen + 1
        marker.setText(String(t.pid) + "\n")
        t.rawHard = hard === true
        t.rawReload.restart()
    }

    // ── the run ─────────────────────────────────────────────────────────────
    property bool started: false
    readonly property Timer loadTimer: Timer {
        interval: 200
        onTriggered: t.afterLoad()
    }
    Component.onCompleted: {
        t.say("pid " + t.pid)
        t.loadTimer.start()
    }

    function afterLoad() {
        if (t.started) return
        t.started = true
        t.loadTimer.stop()
        const first = t.leg1Pid()
        if (keep.step !== "") return t.reloadedInProcess()
        // A hard reload carries no PersistentProperties: the marker says
        // this process reloaded.
        if (first === t.pid) { keep.step = "reloaded"; return t.reloadedInProcess() }
        if (first !== 0 && first !== t.pid) return t.relaunched(first)
        if (t.leg2) return t.restarted()
        // A fresh process: wait for the probe to have seen keys first (the
        // runner starts it before this), then lock.
        t.check("premise: the Shell started unlocked", LockState.locked === false)
        if (t.scenario === "foreign") return t.foreign()
        t.pause(1500, t.lockIt)
    }

    function lockIt() {
        t.say("mark lock")
        if (t.scenario === "capture" || t.scenario === "capture-raw") {
            // A lock that waits for its picture: nothing answers, so it waits
            // the whole cap (120 ms). Everything below lands inside that wait.
            LockState.captureEnabled = true
            LockState.lock()
            t.check("premise: the lock is waiting for its picture", LockState.capturing && !LockState.locked)
            keep.everLocked = true
            if (t.scenario === "capture-raw") return t.reloadRaw(false)
            // What the Shell's own triggers do in that wait: this file changes
            // on disk, and a reload is asked for.
            keep.step = "touched"
            self.setText(String(self.text()) + "\n// changed while the lock waits " + Date.now() + "\n")
            t.check("LockKeeper.reload() while the lock waits for its picture waits (returns false)",
                    LockKeeper.reload(false) === false)
            t.check("Quickshell's file watcher is already off", Quickshell.watchFiles === false)
            t.waitFor(function () { return lock.secure }, 3000, function (secure) {
                t.check("premise: the lock engaged after its wait", secure)
                t.pause(2000, function () {
                    t.check("no reload happened while locked (same generation, same process)", keep.gen === 0)
                    t.authenticate()
                    t.expectDeferredReload()
                })
            })
            return
        }
        if (t.scenario === "engage") {
            LockState.lock()
            t.check("premise: the lock was asked for, not yet acknowledged", LockState.locked && !lock.secure)
            keep.everLocked = true
            return t.reloadRaw(false)
        }
        LockState.lock()
        t.waitFor(function () { return lock.secure }, 3000, function (secure) {
            t.check("premise: the headless compositor acknowledged the lock", secure)
            keep.everLocked = true
            t.pause(600, t.whileLocked)
        })
    }

    function whileLocked() {
        switch (t.scenario) {
        case "soft": return t.reloadRaw(false)
        case "hard": return t.reloadRaw(true)
        case "files": return t.touchSelf()
        case "request": return t.requestWhileLocked()
        case "unlocking":
            lock.release()
            t.check("premise: the password was accepted and the release is running",
                    LockState.unlocking && LockState.locked)
            t.say("mark accepted")
            return t.reloadRaw(false)
        case "unlocking-request":
            t.authenticate()
            t.check("premise: the release is running", LockState.unlocking && LockState.locked)
            t.check("LockKeeper.reload() during the release waits (returns false)", LockKeeper.reload(false) === false)
            keep.step = "deferred"
            return t.expectDeferredReload()
        case "restart":
            t.say("mark holding")
            return   // the runner kills this process now
        }
    }

    // (b) The hot reload: this file changes on disk while locked.
    function touchSelf() {
        const before = String(self.text())
        keep.step = "touched"
        self.setText(before + "\n// changed while locked " + Date.now() + "\n")
        t.say("mark touched")
        t.pause(2500, function () {
            t.check("no reload happened while locked (same generation, same process)", keep.gen === 0 && t.started)
            t.check("Quickshell's file watcher is off while locked", Quickshell.watchFiles === false)
            t.check("the session is still locked", lock.secure && LockState.locked)
            t.authenticate()
            t.expectDeferredReload()
        })
    }

    function requestWhileLocked() {
        t.check("LockKeeper.reload() while locked waits (returns false)", LockKeeper.reload(false) === false)
        keep.step = "deferred"
        t.pause(1500, function () {
            t.check("no reload happened while locked", keep.gen === 0)
            t.check("the session is still locked", lock.secure && LockState.locked)
            t.authenticate()
            t.expectDeferredReload()
        })
    }

    // After the authenticated release: one reload, in this process, unlocked.
    function expectDeferredReload() {
        keep.gen = 0
        keep.step = "awaiting-deferred"
        t.waitFor(function () { return false }, 4000, function () {
            // Reaching here means this generation was never replaced.
            t.bad("no reload happened after the unlock")
            t.done()
        })
    }

    // A new generation of THIS process (a reload that did not end it).
    function reloadedInProcess() {
        t.say("mark new-generation step=" + keep.step)
        if (keep.step === "awaiting-deferred") {
            t.ok("the deferred reload ran after the unlock")
            t.check("the new generation came up unlocked", LockState.locked === false && !lock.secure)
            t.check("Quickshell's file watcher is back on", Quickshell.watchFiles === true)
            return t.pause(1500, function () {
                t.check("and stays unlocked", LockState.locked === false && !lock.secure)
                t.done()
            })
        }
        if (keep.step === "reloaded") {
            // This generation runs before the protocol error ends the process
            // (when one does: a soft or hard reload of a held lock). Where no
            // lock had been sent yet (capture) it locks just after the reload
            // and the process lives on; either way the lock must come back.
            t.waitFor(function () { return lock.secure }, 3000, function (secure) {
                t.note("the reload kept this process")
                t.check("the session locked again after the reload, in this process", secure && LockState.locked)
                t.pause(1200, function () { t.authenticate(); t.afterUnlock() })
            })
            return
        }
        t.bad("an unexpected reload (step " + keep.step + ")")
        t.done()
    }

    // A process started by rime-shell-relaunch.sh after the reload ended the
    // locked one.
    function relaunched(first) {
        t.say("mark relaunched")
        t.check("the Shell was started again after the reload ended it (pid " + first + " → " + t.pid + ")",
                ["soft", "hard", "engage", "unlocking", "capture-raw"].indexOf(t.scenario) >= 0)
        t.check("it locked by itself at start", LockState.locked)
        t.waitFor(function () { return lock.secure }, 4000, function (secure) {
            t.check("the compositor gave it the lock (the password prompt is back)", secure)
            t.pause(1500, function () { t.authenticate(); t.afterUnlock() })
        })
    }

    // restart: the second process the runner starts after killing the first.
    function restarted() {
        t.say("mark restarted")
        t.check("a Shell started after one was killed while locked locks by itself at start", LockState.locked)
        t.waitFor(function () { return lock.secure }, 4000, function (secure) {
            t.check("the compositor gave it the lock (replacing the dead client's)", secure)
            t.pause(1500, function () { t.authenticate(); t.afterUnlock() })
        })
    }

    function afterUnlock() {
        t.waitFor(function () { return !LockState.locked && !lock.secure }, 3000, function (gone) {
            t.check("the authenticated release unlocked the session", gone)
            t.pause(2000, t.done)
        })
    }

    function foreign() {
        t.pause(1500, function () {
            t.check("a held record from another compositor instance does not lock", !LockState.locked && !lock.secure)
            t.check("and leaves the file watcher on", Quickshell.watchFiles === true)
            t.pause(1000, t.done)
        })
    }

    // The runner sets RL_LEG=2 on the process it starts after killing one.
    readonly property bool leg2: Quickshell.env("RL_LEG") === "2"
}
