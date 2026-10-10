import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/theme"
import "./src/services"
import "./src/nexus"

// ─────────────────────────────────────────────────────────────────────────────
// Config → Updates, BUILT AND DRAWN, plus the `shell` IPC target the OS's live
// update engine asks before and after it replaces the running shell. Run via
// tests/run-updates-page-test.sh.
//
// The page is built through PageRegistry, the way Nexus builds it, and fed by
// copying fixtures into the paths it reads (RIME_LIVE_STATUS,
// RIME_UPDATE_STATE): it picks each one up on its own poll, which is the path
// that has to work when root writes the file with an atomic rename.
//
// The buttons are pressed and the terminal helper is a stub that records its
// argv and runs nothing; the runner compares that record with liveupdate.js's
// constants after this exits. The lock is the real LockState.lock().
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    id: root

    readonly property string fixtures: Quickshell.env("RIME_UP_FIXTURES") || ""
    readonly property string statusPath: Quickshell.env("RIME_LIVE_STATUS") || ""
    readonly property string checkerPath: Quickshell.env("RIME_UPDATE_STATE") || ""
    readonly property string readyFile: Quickshell.env("RIME_UP_READY") || ""
    readonly property string doneFile: Quickshell.env("RIME_UP_DONE") || ""
    readonly property string expectRevision: Quickshell.env("RIME_UP_REVISION") || ""
    readonly property string grabPath: Quickshell.env("RIME_UP_GRAB") || ""

    property int passed: 0
    property int failed: 0

    function check(name, cond, detail) {
        if (cond) { root.passed++; console.log("  PASS  " + name) }
        else { root.failed++; console.log("  FAIL  " + name + (detail ? "  [" + detail + "]" : "")) }
    }
    function eq(name, got, want) { root.check(name, got === want, "got " + got + ", want " + want) }

    function collect(obj, has, out) {
        if (!obj) return out
        if (obj[has] !== undefined) out.push(obj)
        const kids = obj.children
        if (kids)
            for (let i = 0; i < kids.length; i++) root.collect(kids[i], has, out)
        return out
    }
    function hero() { const h = root.collect(root.page, "titleItem", []); return h.length === 1 ? h[0] : null }
    function heroTitle() { const h = root.hero(); return h ? String(h.titleItem.text) : "(no hero)" }
    function compRows() { return root.collect(root.page, "compChip", []).filter(r => r.visible) }
    function button(label) {
        const b = root.collect(root.page, "press", []).filter(x => x.label === label && x.variant !== undefined)
        return b.length === 1 ? b[0] : null
    }
    function texts() { return root.collect(root.page, "truncated", []) }
    function showing(needle) {
        const ts = root.texts()
        for (let i = 0; i < ts.length; i++)
            if (ts[i].visible && String(ts[i].text).indexOf(needle) >= 0) return ts[i]
        return null
    }

    // ── the harness ──────────────────────────────────────────────────────────
    property var steps: []
    property int stepIndex: 0
    function next() {
        if (root.stepIndex >= root.steps.length) {
            console.log("")
            console.log("passed=" + root.passed + " failed=" + root.failed)
            Qt.exit(root.failed === 0 ? 0 : 1)
            return
        }
        root.steps[root.stepIndex++]()
    }

    property var _cond: null
    property var _then: null
    property string _waitName: ""
    property int _ticks: 0
    property int _maxTicks: 100
    function waitFor(name, cond, then, maxTicks) {
        root._waitName = name; root._cond = cond; root._then = then
        root._ticks = 0; root._maxTicks = maxTicks || 100
        waiter.restart()
    }
    Timer {
        id: waiter
        interval: 100
        repeat: true
        onTriggered: {
            if (root._cond()) { stop(); const t = root._then; root._then = null; t(); return }
            if (++root._ticks >= root._maxTicks) {
                stop()
                root.check("waited for: " + root._waitName, false, "hero says '" + root.heroTitle() + "'")
                const t = root._then; root._then = null; t()
            }
        }
    }

    // Copy a fixture into place (or remove the file) the way the engine
    // would: a new file appears, the old one is gone.
    property var _afterSh: null
    Process {
        id: sh
        onExited: function (code) { const f = root._afterSh; root._afterSh = null; if (f) f(code) }
    }
    function run(argv, then) { root._afterSh = then; sh.command = argv; sh.running = true }
    function place(fixture, dest, then) {
        root.run(["sh", "-c", "mkdir -p \"${2%/*}\" && cp \"$1\" \"$2.tmp\" && mv -f \"$2.tmp\" \"$2\"", "sh",
                  root.fixtures + "/" + fixture, dest], then)
    }
    function remove(dest, then) { root.run(["rm", "-f", dest], then) }

    // One state: put the file in place, wait for the hero to say `title`.
    function expectAfter(fixture, title, extra) {
        return function () {
            root.place(fixture, root.statusPath, function () {
                root.waitFor(fixture + " → '" + title + "'",
                             function () { return root.heroTitle() === title },
                             function () {
                                 root.eq(fixture + ": the hero says " + title, root.heroTitle(), title)
                                 if (extra) extra()
                                 root.next()
                             })
            })
        }
    }

    // ── the page, built the way Nexus builds it ──────────────────────────────
    FloatingWindow {
        id: stage
        width: 980
        height: 900
        visible: true
        color: "#101012"
        Loader {
            id: pageLoader
            anchors.fill: parent
            sourceComponent: {
                const p = PageRegistry.pageFor("updates")
                return p ? p.component : null
            }
        }
    }
    readonly property var page: pageLoader.item

    Component.onCompleted: {
        root.steps = [
            root.opening,
            root.missingBoth,
            root.checkerOnly,
            root.expectAfter("active.json", "Activated live", function () {
                root.eq("active: three component rows", root.compRows().length, 3)
                const rows = root.compRows()
                root.eq("active: the first row is the shell", rows.length ? rows[0].label : "", "Rime Shell")
                root.eq("active: its chip", rows.length ? rows[0].status : "", "Active")
                root.check("active: the summary is on screen",
                           root.showing("3 components active live") !== null)
                root.check("active: the target release is on screen", root.showing("Rime 2026.10.11") !== null)
            }),
            root.expectAfter("deferred-locked.json", "Waiting for Rime Shell", function () {
                const rows = root.compRows()
                root.eq("deferred: its chip", rows.length ? rows[0].status : "", "Waiting")
                root.check("deferred: the chip is drawn as a warning", rows.length > 0 && rows[0].statusWarns)
                root.check("deferred: the recommendation is on screen", root.showing("unlock to finish") !== null)
            }),
            root.expectAfter("pending-reboot.json", "Restart recommended", function () {
                root.check("pending reboot: the recommendation is on screen",
                           root.showing("restart when convenient") !== null)
                root.eq("pending reboot: three rows", root.compRows().length, 3)
            }),
            root.expectAfter("rolled-back.json", "Live activation rolled back", function () {
                root.check("rolled back: no target row for a null target", root.showing("Updating to") === null)
            }),
            // Truncated JSON is not a state: the checker answers.
            root.expectAfter("malformed.json", "Update available", function () {
                root.eq("malformed: no component rows", root.compRows().length, 0)
            }),
            root.expectAfter("hostile.json", "Activated live", function () {
                const rows = root.compRows()
                root.eq("hostile: non-object components dropped", rows.length, 1)
                const t = root.showing("<b>bold</b>")
                root.check("hostile: markup is drawn as its characters", t !== null)
                root.check("hostile: …by a plain-text Text", t !== null && t.textFormat === Text.PlainText)
                const s = root.showing("<img")
                root.check("hostile: the summary's markup too", s !== null && s.textFormat === Text.PlainText)
                root.eq("hostile: an unknown state is not echoed", rows.length ? rows[0].status : "", "Unknown")
            }),
            root.deleted,
            root.presses,
            root.grab,
            root.ipcUnlocked,
            root.ipcLocked,
            root.ipcExternal
        ]
        root.next()
    }

    function opening() {
        root.check("the page is registered under 'updates' and built", root.page !== null)
        if (!root.page) { console.log("passed=" + root.passed + " failed=" + root.failed); Qt.exit(1); return }
        root.check("there is exactly one hero", root.hero() !== null)
        root.page.onScreen = true
        root.next()
    }
    function missingBoth() {
        root.waitFor("the hero with no files", function () { return root.heroTitle() === "Not checked yet" },
                     function () {
                         root.eq("no files: not checked yet", root.heroTitle(), "Not checked yet")
                         root.eq("no files: no component rows", root.compRows().length, 0)
                         root.check("no files: no 'What changed' heading over nothing",
                                    root.showing("What changed") === null)
                         // No status, but the image says what it is.
                         root.check("no status: the running release comes from release.json",
                                    root.showing("Rime 2026.10.09") !== null)
                         root.next()
                     })
    }
    function checkerOnly() {
        root.place("checker-available", root.checkerPath, function () {
            root.waitFor("checker → available", function () { return root.heroTitle() === "Update available" },
                         function () { root.eq("checker only: update available", root.heroTitle(), "Update available"); root.next() })
        })
    }
    function deleted() {
        // The status file goes away: what it said must go with it.
        root.remove(root.statusPath, function () {
            root.waitFor("status removed → checker", function () { return root.heroTitle() === "Update available" },
                         function () {
                             root.eq("a deleted status stops being shown", root.heroTitle(), "Update available")
                             root.eq("and its rows go too", root.compRows().length, 0)
                             root.next()
                         })
        })
    }
    // One press at a time, each waited for in the stub's record: the terminal
    // is started detached, so three presses in a row would race to the log.
    readonly property string termLog: Quickshell.env("RIME_UP_TERMLOG") || ""
    function waitForCalls(n, then, tries) {
        root.run(["sh", "-c", "[ \"$(grep -c '^---$' \"$1\" 2>/dev/null)\" -ge \"$2\" ]", "sh",
                  root.termLog, String(n)],
                 function (code) {
                     if (code === 0) { then(true); return }
                     if ((tries || 0) >= 50) { then(false); return }
                     pressPause.then = function () { root.waitForCalls(n, then, (tries || 0) + 1) }
                     pressPause.restart()
                 })
    }
    Timer { id: pressPause; interval: 100; property var then: null; onTriggered: then() }
    function presses() {
        const order = ["Update now", "Show plan", "Explain"]
        const step = function (i) {
            if (i >= order.length) { root.next(); return }
            const b = root.button(order[i])
            root.check("a " + order[i] + " button", b !== null)
            if (!b) { step(i + 1); return }
            b.press()
            root.waitForCalls(i + 1, function (seen) {
                root.check(order[i] + " reached the terminal helper", seen)
                step(i + 1)
            })
        }
        step(0)
    }
    function grab() {
        if (root.grabPath === "") { root.next(); return }
        // The pending-reboot state is the busiest: draw that one.
        root.place("pending-reboot.json", root.statusPath, function () {
            root.waitFor("pending reboot for the picture",
                         function () { return root.heroTitle() === "Restart recommended" },
                         function () {
                             pageLoader.grabToImage(function (r) {
                                 root.check("the page was drawn", r.saveToFile(root.grabPath))
                                 root.next()
                             })
                         })
        })
    }

    // ── the shell IPC target ─────────────────────────────────────────────────
    function ipcState() { return JSON.parse(IpcManager.shellInfo.state()) }
    function ipcUnlocked() {
        const s = root.ipcState()
        root.eq("state(): unlocked reads locked=false", s.locked, false)
        root.eq("state(): lockSecure false", s.lockSecure, false)
        root.eq("state(): the pid is this process", s.pid, Quickshell.processId)
        root.eq("state(): the revision", s.revision, root.expectRevision)
        root.eq("revision(): the file's contents, trimmed", IpcManager.shellInfo.revision(), root.expectRevision)
        root.eq("there is no unlock on the shell target", IpcManager.shellInfo.unlock, undefined)
        root.eq("there is no lock on the shell target", IpcManager.shellInfo.lock, undefined)
        // A lock asked for and not yet engaged is locked for the engine's
        // purposes. Set by hand: in this harness the lock engages at once.
        LockState.capturing = true
        root.eq("state(): a lock waiting for its picture reads locked", root.ipcState().locked, true)
        LockState.capturing = false
        root.next()
    }
    function ipcLocked() {
        LockState.lock()
        root.waitFor("the lock to engage", function () { return LockState.locked },
                     function () {
                         root.eq("state(): a held lock reads locked=true", root.ipcState().locked, true)
                         root.next()
                     }, 30)
    }
    // The real contract: `quickshell ipc call shell state` from outside, while
    // the lock is held. The runner does the calling once the ready file exists
    // and writes the done file after; it grades what it saw.
    function ipcExternal() {
        root.run(["sh", "-c", "touch \"$1\" && timeout 60 sh -c 'while [ ! -f \"$1\" ]; do sleep 0.2; done' sh \"$2\"",
                  "sh", root.readyFile, root.doneFile],
                 function (code) {
                     root.eq("the runner finished its IPC calls", code, 0)
                     root.next()
                 })
    }
}
