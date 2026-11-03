import QtQuick
import Quickshell
import Quickshell.Io
import "./src/services"
import "./src/components"
import "./src/modules/Center"

// Staged into the repo root by tests/run-power-profile-test.sh. Drives the REAL
// PowerProfileService (and the Dashboard's PowerPanel) against the runner's
// stubbed `rime` and `busctl`: the stub rime writes the tier the stub busctl
// reads back, or refuses the way rimed does, as the runner's mode file says.
//
// What it proves:
//   1. A set that works: the label shows the pick at once, a poll during the
//      call does not flip it back, and it settles on the daemon's value.
//   2. A refused set (polkit: not the active local user) says so in words and
//      the label shows the real tier again.
//   3. A set with rimed down says so too.
//   4. The Dashboard's PowerPanel shows that message.
ShellRoot {
    id: root
    property int passed: 0
    property int failed: 0
    property int phase: 0
    property int ticks: 0
    property bool sawMidSet: false
    readonly property string w: Quickshell.env("STUB_DIR")

    function check(name, cond) {
        if (cond) { root.passed++; console.log("  PASS  " + name) }
        else      { root.failed++; console.log("  FAIL  " + name) }
    }
    function mode(m) {
        writer.command = ["sh", "-c", "printf %s \"$1\" > \"$2\"", "sh", m, root.w + "/mode"]
        writer.running = true
    }
    function findByName(item, name) {
        if (!item) return null
        if (item.objectName === name) return item
        const kids = item.children || []
        for (let i = 0; i < kids.length; i++) {
            const f = root.findByName(kids[i], name)
            if (f) return f
        }
        return null
    }

    Process { id: writer; running: false }

    ServiceRef { service: PowerProfileService; active: true }

    FloatingWindow {
        id: win
        implicitWidth: 420; implicitHeight: 200
        visible: true
        PowerPanel { id: panel; width: 400; powerProfileService: PowerProfileService }
    }

    Component.onCompleted: PowerProfileService.interval = 100

    Timer {
        interval: 50; repeat: true; running: true
        onTriggered: {
            const S = PowerProfileService
            root.ticks++
            if (root.ticks > 600) { root.check("finished in time (phase " + root.phase + ")", false); root.phase = 99 }
            switch (root.phase) {
            case 0:   // the first read lands
                if (S.current === "balanced" && root.ticks > 4) {
                    root.mode("ok")
                    root.phase = 1
                }
                break
            case 1:
                S.setProfile("power-saver")
                root.check("the label shows the pick at once", S.current === "power-saver")
                root.ticks = 0; root.phase = 2
                break
            case 2:   // the stub rime takes 0.8 s; polls every 100 ms meanwhile
                if (S.setProc.running && root.ticks === 8) {
                    root.sawMidSet = true
                    root.check("a poll during the call does not flip the label back", S.current === "power-saver")
                }
                if (!S.setProc.running && root.ticks > 2) {
                    root.check("the call was still running mid-way (the poll check ran)", root.sawMidSet)
                    root.ticks = 0; root.phase = 3
                }
                break
            case 3:
                if (root.ticks === 6) {
                    root.check("it settles on the daemon's tier (power-saver)", S.current === "power-saver")
                    root.check("no error after a set that worked", S.error === "")
                    root.mode("refuse")
                    root.phase = 4
                }
                break
            case 4:
                if (root.ticks === 8) { S.setProfile("performance"); root.ticks = 0; root.phase = 5 }
                break
            case 5:
                if (!S.setProc.running && root.ticks === 20) {
                    root.check("a refused set reads the real tier back (power-saver)", S.current === "power-saver")
                    root.check("a refused set says why: " + S.error, /only the person signed in/.test(S.error))
                    root.check("rime's own line is kept: " + S.errorDetail, /AccessDenied/.test(S.errorDetail))
                    const t = root.findByName(panel, "powerProfileError")
                    root.check("the Dashboard's power panel shows it", !!t && t.visible && t.text === S.error)
                    root.mode("down")
                    root.ticks = 0; root.phase = 6
                }
                break
            case 6:
                if (root.ticks === 4) { S.setProfile("balanced"); root.ticks = 0; root.phase = 7 }
                break
            case 7:
                if (!S.setProc.running && root.ticks === 20) {
                    root.check("rimed down says so: " + S.error, /not running/.test(S.error))
                    root.check("and the label is the real tier again", S.current === "power-saver")
                    root.mode("ok")
                    root.ticks = 0; root.phase = 8
                }
                break
            case 8:
                if (root.ticks === 4) {
                    S.setProfile("balanced")
                    root.check("the next press clears the message at once", S.error === "")
                    root.ticks = 0; root.phase = 9
                }
                break
            case 9:
                if (!S.setProc.running && root.ticks === 24) {
                    root.check("and that set lands (balanced)", S.current === "balanced" && S.error === "")
                    const t = root.findByName(panel, "powerProfileError")
                    root.check("the panel's message is gone", !!t && !t.visible)
                    root.phase = 99
                }
                break
            case 99:
                console.log("passed=" + root.passed + " failed=" + root.failed)
                Qt.exit(root.failed === 0 ? 0 : 1)
                root.phase = 100
                break
            }
        }
    }
}
