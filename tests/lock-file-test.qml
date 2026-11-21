import Quickshell
import Quickshell.Io
import QtQuick
import "./src/services"
import "./src/state"
import "./src/windows"

// LockFileService and the lock path that drives it, run for real: the file
// rime-remoted reads before letting a phone used as a touchpad type anything
// ($XDG_RUNTIME_DIR/rime-remote/lock.json, rime-os docs/remote-live-contract.md
// §2.16).
//
// Run through tests/run-lock-file-test.sh, which stages this at the repo root,
// puts fake loginctl and busctl first on PATH (they record argv; nothing here
// touches the real logind), gives it a private XDG_RUNTIME_DIR and HOME, and
// hosts it on a headless labwc. The only session lock it can engage is that
// compositor's.
//
// What only a live run can show:
//   * the ORDER: at the instant the shipped WlSessionLock is asked for the lock
//     (its `locked` turning true) and at the instant a lock starts waiting for
//     its picture (LockState.capturing), the file on disk already says locked.
//     Sampled synchronously inside those signal handlers, not afterwards. (On
//     an immediate lock the binding writes true as well, so the capture-start
//     probe is the one that catches a missing lockStarting write.)
//   * that an unlock is written only once the session lock is gone: at every
//     write of false, LockState says nothing is locked AND `secure` is false.
//     ext-session-lock has no unlock acknowledgement; Quickshell 0.3.2 drops
//     `secure` synchronously when WlSessionLock.locked turns false, so in the
//     lock path above both happen in one step and this check is an invariant,
//     not a discriminator: scenario `direct` is what proves the file follows
//     `secure`.
//   * that the file follows the compositor's lock, not only LockState's
//     intent: scenario `direct` engages WlSessionLock with LockState knowing
//     nothing (the shape of a reload takeover), and the file must say locked.
//   * the start state, a reload mid-lock and a restart mid-lock.
//   * every value this generation wrote, in order (the service's FileView
//     `saved` signal: synchronous with blockWrites), so a transient wrong value
//     is caught even when the end state is right.
//
// $LF_SCENARIO picks the run; the runner launches quickshell once per scenario
// against the same runtime dir.
//   main          start (no file) → lock → release → lock with a capture wait →
//                 release → lock → RELOAD mid-lock → checks → lock → release
//   hold          start, lock, print "lock-file: holding" and wait: the runner
//                 SIGTERMs it while locked
//   after-restart a fresh process after that: the start state, then a lock and
//                 release of its own
//   direct        a fresh process: the compositor's lock engaged directly
//                 (WlSessionLock.locked set, its LockState binding broken), so
//                 only `secure` says locked; then released

ShellRoot {
    id: t

    property string scenario: Quickshell.env("LF_SCENARIO") || "main"
    property string lockPath: Quickshell.env("XDG_RUNTIME_DIR") + "/rime-remote/lock.json"
    property string hintLog: Quickshell.env("HINT_LOG")
    property string myUid: Quickshell.env("LF_UID")

    property int pass: 0
    property int fail: 0
    function ok(what)  { console.warn("  PASS  " + what); t.pass++ }
    function bad(what) { console.warn("  FAIL  " + what); t.fail++ }
    function check(what, cond) { if (cond) t.ok(what); else t.bad(what) }
    function note(what) { console.warn("  note: " + what) }

    // ── the shipped lock screen, as shell.qml instantiates it ───────────────
    Lockscreen { id: lock }

    // Carries the run across a reload: a new generation gets a fresh test root.
    PersistentProperties {
        id: keep
        reloadableId: "lock-file-test"
        property int phase: 0
        property int pass: 0
        property int fail: 0
        property string hintMark: "0"
        onLoaded: t.afterLoad()
    }

    // ── reading the file NOW ────────────────────────────────────────────────
    // A FileView of its own with blockLoading: reload() reads synchronously, so
    // a read inside a signal handler is the file as it is at that instant.
    FileView {
        id: probe
        path: t.lockPath
        blockLoading: true
        // reload() alone is asynchronous once a load succeeded; this makes
        // text() wait for the fresh read.
        blockAllReads: true
        printErrors: false
    }
    function readNow() {
        probe.reload()
        const text = String(probe.text()).trim()
        return probe.loaded ? text : "<absent>"
    }
    readonly property string lockedText: "{\"locked\":true}"
    readonly property string unlockedText: "{\"locked\":false}"

    // The earliest read this generation can make: before any timer, so after a
    // reload it is the file as the new generation found it (or wrote it).
    property string firstRead: ""

    // ── every write this generation's service made, in order ───────────────
    property var writes: []
    Connections {
        target: LockFileService._file
        function onSaved() {
            t.writes = t.writes.concat([LockFileService._written])
            // The world at the instant a false landed: nothing may still say
            // locked, the compositor included.
            if (LockFileService._written === false)
                t.falseWrites = t.falseWrites.concat([{ locked: LockState.locked, capturing: LockState.capturing,
                                                        unlocking: LockState.unlocking, secure: lock.secure }])
        }
    }
    property var falseWrites: []
    function falseWritesClean() {
        return t.falseWrites.every(function (w) {
            return w.locked === false && w.capturing === false && w.unlocking === false && w.secure === false
        })
    }
    property int writesMark: 0
    function writesSince() { return t.writes.slice(t.writesMark) }
    function markWrites() { t.writesMark = t.writes.length }

    // ── probes at the instants that matter ──────────────────────────────────
    property var atLockRequest: []     // file text when WlSessionLock.locked turned true
    property var atCaptureStart: []    // file text when LockState.capturing turned true
    property var atRelease: []         // file text when LockState.locked turned false
    Connections {
        target: lock
        function onLockStateChanged() {
            if (lock.locked) t.atLockRequest = t.atLockRequest.concat([t.readNow()])
        }
    }
    Connections {
        target: LockState
        function onCapturingChanged() {
            if (LockState.capturing) t.atCaptureStart = t.atCaptureStart.concat([t.readNow()])
        }
        function onLockedChanged() {
            if (!LockState.locked)
                t.atRelease = t.atRelease.concat([t.readNow() + " secure=" + lock.secure])
        }
    }

    // ── stat ────────────────────────────────────────────────────────────────
    property var afterStat: null
    property string statOut: ""
    readonly property Process statProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: t.statOut = text }
        onExited: function () {
            const f = t.afterStat; t.afterStat = null
            if (f) f(t.parseStat(t.statOut))
        }
    }
    // {file: {mode, ino, uid, type}, dir: {...}} or nulls.
    function parseStat(out) {
        const r = { file: null, dir: null }
        String(out).split("\n").forEach(function (l) {
            const m = l.match(/^(\S+) (\d+) (\d+) (\d+) (.+)$/)
            if (!m) return
            const v = { mode: m[2], ino: m[3], uid: m[4], type: m[5] }
            if (m[1] === "F") r.file = v; else if (m[1] === "D") r.dir = v
        })
        return r
    }
    function stat(then) {
        t.afterStat = then
        t.statOut = ""
        const d = t.lockPath.replace(/\/lock\.json$/, "")
        t.statProc.command = ["sh", "-c",
            "stat -c 'F %a %i %u %F' -- \"$1\" 2>/dev/null; stat -c 'D %a %i %u %F' -- \"$2\" 2>/dev/null; true",
            "sh", t.lockPath, d]
        t.statProc.running = false
        t.statProc.running = true
    }

    // ── the fake logind's log ───────────────────────────────────────────────
    property var afterHints: null
    property string hintsOut: ""
    readonly property Process hintsProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: t.hintsOut = text }
        onExited: function () {
            const f = t.afterHints; t.afterHints = null
            const all = String(t.hintsOut).split("\n").filter(function (l) { return l.indexOf("SetLockedHint") >= 0 })
                .map(function (l) { return l.indexOf("b true") >= 0 ? "true" : "false" })
            if (f) f(all)
        }
    }
    function hints(then) {
        t.afterHints = then
        t.hintsOut = ""
        t.hintsProc.command = ["cat", t.hintLog]
        t.hintsProc.running = false
        t.hintsProc.running = true
    }

    // ── waiting ─────────────────────────────────────────────────────────────
    property var waitCond: null
    property var waitThen: null
    readonly property Timer waitTimer: Timer {
        interval: 25
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
    function waitFor(cond, tries, then) {
        t.waitCond = cond; t.waitThen = then
        t.waitTimer.limit = tries; t.waitTimer.tries = 0
        t.waitTimer.restart()
    }
    // The service and LockedHintService idle, and the ensure helper done.
    function settle(then) {
        t.waitFor(function () {
            return !LockFileService._ensureProc.running && !LockedHintService._busy
        }, 200, function () { t.pause(150, then) })
    }
    property var afterPause: null
    readonly property Timer pauseTimer: Timer {
        repeat: false
        onTriggered: { const f = t.afterPause; t.afterPause = null; if (f) f() }
    }
    function pause(ms, then) { t.afterPause = then; t.pauseTimer.interval = ms; t.pauseTimer.restart() }

    // ── assertions shared by phases ────────────────────────────────────────
    function expectFile(what, text, then) {
        t.stat(function (s) {
            t.check(what + ": the file says " + text, t.readNow() === text)
            t.check(what + ": it is a regular file", s.file !== null && s.file.type === "regular file")
            t.check(what + ": mode 0600 (got " + (s.file ? s.file.mode : "none") + ")", s.file !== null && s.file.mode === "600")
            t.check(what + ": owned by this user", s.file !== null && s.file.uid === t.myUid)
            t.check(what + ": its directory is 0700 (got " + (s.dir ? s.dir.mode : "none") + ")", s.dir !== null && s.dir.mode === "700")
            then(s)
        })
    }

    // ── the run ─────────────────────────────────────────────────────────────
    Component.onCompleted: {
        t.firstRead = t.readNow()
        t.loadTimer.start()
    }
    // PersistentProperties restores a reloaded generation's values after
    // construction (onLoaded); a first generation never gets onLoaded, so the
    // timer starts the first phase.
    property bool started: false
    readonly property Timer loadTimer: Timer {
        interval: 300
        onTriggered: t.afterLoad()
    }
    function afterLoad() {
        if (t.started) return
        t.started = true
        t.loadTimer.stop()
        t.pass = keep.pass; t.fail = keep.fail
        if (t.scenario === "hold") return t.settle(t.hold0)
        if (t.scenario === "after-restart") return t.settle(t.restart0)
        if (t.scenario === "direct") return t.settle(t.direct0)
        if (keep.phase === 1) return t.reload1()
        t.settle(t.phase0)
    }

    // Phase 0 — a fresh login: no file before this Shell.
    function phase0() {
        t.check("premise: the run started with no lock file (" + t.firstRead + ")",
                t.firstRead === "<absent>" || t.firstRead === t.unlockedText)
        t.check("premise: the service exists and is not sticky", LockFileService.sticky === false)
        t.expectFile("start", t.unlockedText, function () {
            t.hints(function (h) {
                t.check("logind's first word from this Shell is unlocked", h.length >= 1 && h[0] === "false")
                t.markWrites()
                t.phase1()
            })
        })
    }

    // Phase 1 — a lock with no picture to wait for: engaged at once.
    function phase1() {
        t.stat(function (before) {
            t.atLockRequest = []
            LockState.lock()
            t.check("the file said locked the instant the compositor was asked for the lock ("
                    + JSON.stringify(t.atLockRequest) + ")",
                    t.atLockRequest.length === 1 && t.atLockRequest[0] === t.lockedText)
            t.waitFor(function () { return lock.secure }, 200, function (secure) {
                t.check("premise: the headless compositor acknowledged the lock", secure)
                t.settle(function () {
                    t.expectFile("locked", t.lockedText, function (after) {
                        t.check("the write replaced the file by rename (inode " + (before.file ? before.file.ino : "?")
                                + " → " + (after.file ? after.file.ino : "?") + ")",
                                before.file !== null && after.file !== null && before.file.ino !== after.file.ino)
                        t.check("this lock wrote exactly one value, true (" + JSON.stringify(t.writesSince()) + ")",
                                JSON.stringify(t.writesSince()) === "[true]")
                        t.markWrites()
                        t.phase2()
                    })
                })
            })
        })
    }

    // Phase 2 — the release (what PAM success calls): unlocked only once the
    // compositor has let go.
    function phase2() {
        t.atRelease = []
        lock.release()
        t.waitFor(function () { return !LockState.locked }, 200, function () {
            // What the file said the instant LockState let go depends on which
            // binding Qt runs first (measured: the compositor's release and the
            // service's false both land before this probe). The rule that
            // matters is checked at every false instead: falseWritesClean().
            t.note("the instant LockState let go: " + JSON.stringify(t.atRelease))
            t.waitFor(function () { return !lock.secure }, 200, function (released) {
                t.check("premise: the compositor released the lock", released)
                t.settle(function () {
                    t.expectFile("unlocked", t.unlockedText, function () {
                        t.check("the unlock wrote false once (" + JSON.stringify(t.writesSince()) + ")",
                                t.writesSince().length >= 1 && t.writesSince()[0] === false
                                && t.writesSince().every(function (w) { return w === false }))
                        t.markWrites()
                        t.phase3()
                    })
                })
            })
        })
    }

    // Phase 3 — a lock that waits for its picture (up to 120 ms): the file says
    // locked from the moment the wait starts, not from the engage.
    function phase3() {
        t.atCaptureStart = []
        t.atLockRequest = []
        LockState.captureEnabled = true
        LockState.lock()
        t.check("premise: this lock is waiting for its picture", LockState.capturing && !LockState.locked)
        t.check("the file said locked the instant the lock started waiting ("
                + JSON.stringify(t.atCaptureStart) + ")",
                t.atCaptureStart.length === 1 && t.atCaptureStart[0] === t.lockedText)
        t.waitFor(function () { return lock.secure }, 200, function (secure) {
            LockState.captureEnabled = false
            t.check("premise: the cap engaged the lock", secure)
            t.check("…and still said locked when the compositor was asked (" + JSON.stringify(t.atLockRequest) + ")",
                    t.atLockRequest.length === 1 && t.atLockRequest[0] === t.lockedText)
            lock.release()
            t.waitFor(function () { return !lock.secure }, 200, function () {
                t.settle(function () {
                    t.expectFile("unlocked after a capture lock", t.unlockedText, function () {
                        t.markWrites()
                        t.phase4()
                    })
                })
            })
        })
    }

    // Phase 4 — lock, then reload the configuration mid-lock.
    function phase4() {
        LockState.lock()
        t.waitFor(function () { return lock.secure }, 200, function (secure) {
            t.check("premise: locked before the reload", secure)
            t.settle(function () {
                t.check("the file says locked before the reload", t.readNow() === t.lockedText)
                t.hints(function (h) {
                    keep.hintMark = String(h.length)
                    keep.phase = 1
                    keep.pass = t.pass; keep.fail = t.fail
                    console.warn("lock-file: reloading mid-lock")
                    Quickshell.reload(false)
                })
            })
        })
    }

    // After the reload — a new generation, a new LockFileService, a new test
    // root. It must keep saying locked.
    property var samples: []
    readonly property Timer sampler: Timer {
        interval: 10
        repeat: true
        onTriggered: t.samples = t.samples.concat([t.readNow()])
    }
    function reload1() {
        t.note("first read in the new generation: " + t.firstRead)
        t.check("the new generation found or wrote locked, never unlocked (" + t.firstRead + ")",
                t.firstRead === t.lockedText)
        t.check("the new generation's service is sticky (it found the old lock)", LockFileService.sticky === true)
        t.check("this generation wrote only locked (" + JSON.stringify(t.writes) + ")",
                t.writes.every(function (w) { return w === true }))
        t.note("after the reload: lock.secure=" + lock.secure + " lock.locked=" + lock.locked
               + " LockState.locked=" + LockState.locked
               + " (Quickshell 0.3.2 hands the old lock to the new WlSessionLock, which releases it)")
        t.samples = []
        t.sampler.start()
        t.pause(1500, function () {
            t.sampler.stop()
            const bad = t.samples.filter(function (s) { return s !== t.lockedText })
            t.check("for 1.5 s after the reload every read said locked (" + t.samples.length + " reads, "
                    + bad.length + " other: " + JSON.stringify(bad.slice(0, 3)) + ")",
                    t.samples.length > 20 && bad.length === 0)
            t.settle(function () {
                t.expectFile("after the reload", t.lockedText, function () {
                    t.hints(function (h) {
                        const since = h.slice(parseInt(keep.hintMark, 10))
                        t.check("logind was not told unlocked by the reload (" + JSON.stringify(since) + ")",
                                since.every(function (v) { return v === "true" }))
                        t.markWrites()
                        t.reload2()
                    })
                })
            })
        })
    }

    // A lock and an unlock of this generation's own clear it.
    function reload2() {
        LockState.lock()
        t.waitFor(function () { return lock.secure }, 200, function (secure) {
            if (!secure) {
                t.bad("the new generation could not lock (compositor state after the reload?)")
                return t.finish()
            }
            t.check("a lock of this generation's own clears the sticky state", LockFileService.sticky === false)
            lock.release()
            t.waitFor(function () { return !lock.secure }, 200, function () {
                t.settle(function () {
                    t.expectFile("after a lock and unlock of its own", t.unlockedText, function () {
                        t.hints(function (h) {
                            t.check("…and logind hears the unlock", h.length > 0 && h[h.length - 1] === "false")
                            t.finish()
                        })
                    })
                })
            })
        })
    }

    // ── scenario hold: locked, then killed by the runner ────────────────────
    function hold0() {
        LockState.lock()
        t.waitFor(function () { return lock.secure }, 200, function (secure) {
            t.check("premise: locked", secure)
            t.settle(function () {
                t.check("the file says locked", t.readNow() === t.lockedText)
                console.warn("lock-file: passed=" + t.pass + " failed=" + t.fail)
                console.warn("lock-file: holding")
            })
        })
    }

    // ── scenario after-restart ──────────────────────────────────────────────
    function restart0() {
        t.check("the restarted Shell found locked and did not overwrite it (" + t.firstRead + ")",
                t.firstRead === t.lockedText)
        t.check("…and is sticky", LockFileService.sticky === true)
        t.check("it wrote only locked (" + JSON.stringify(t.writes) + ")",
                t.writes.every(function (w) { return w === true }))
        t.expectFile("after a restart mid-lock", t.lockedText, function () {
            t.hints(function (h) {
                t.check("its first word to logind is locked (" + JSON.stringify(h) + ")",
                        h.length >= 1 && h[0] === "true")
                LockState.lock()
                t.waitFor(function () { return lock.secure }, 200, function (secure) {
                    if (!secure) {
                        t.note("the compositor did not give this Shell a lock after the last one died holding one")
                        t.check("…and with no lock of its own, it keeps saying locked", t.readNow() === t.lockedText)
                        LockState.locked = false
                        return t.finish()
                    }
                    lock.release()
                    t.waitFor(function () { return !lock.secure }, 200, function () {
                        t.settle(function () {
                            t.expectFile("after its own lock and unlock", t.unlockedText, function () {
                                t.finish()
                            })
                        })
                    })
                })
            })
        })
    }

    // ── scenario direct ─────────────────────────────────────────────────────
    function direct0() {
        t.check("premise: starts unlocked, not sticky", !LockFileService.sticky && t.readNow() === t.unlockedText)
        t.markWrites()
        lock.locked = true     // breaks the binding to LockState.locked, on purpose
        t.waitFor(function () { return lock.secure }, 200, function (secure) {
            t.check("premise: the compositor holds the lock", secure)
            t.check("premise: LockState knows nothing of it", !LockState.locked && !LockState.capturing && !LockState.unlocking)
            t.settle(function () {
                t.expectFile("compositor lock only", t.lockedText, function () {
                    t.check("it wrote true, never false, while the compositor held the lock ("
                            + JSON.stringify(t.writesSince()) + ")",
                            t.writesSince().length >= 1 && t.writesSince().every(function (w) { return w === true }))
                    lock.locked = false
                    t.waitFor(function () { return !lock.secure }, 200, function () {
                        t.settle(function () {
                            t.expectFile("compositor let go", t.unlockedText, function () { t.finish() })
                        })
                    })
                })
            })
        })
    }

    function finish() {
        t.check("every false this generation wrote landed with nothing locked, the compositor's lock gone ("
                + JSON.stringify(t.falseWrites) + ")", t.falseWritesClean())
        console.warn("lock-file: passed=" + t.pass + " failed=" + t.fail)
        Qt.exit(t.fail === 0 ? 0 : 1)
    }
}
