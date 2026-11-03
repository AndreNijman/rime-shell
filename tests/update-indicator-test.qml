import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/services"
import "./src/nexus"
import "./src/modules/Right" as Right

// ─────────────────────────────────────────────────────────────────────────────
// The top bar's update icon, BUILT: two bars' real right notches (RightContent,
// as TopBar builds it, one per screen) fed by writing the two files the OS
// writes, the way it writes them. Run via tests/run-update-indicator-test.sh.
//
// It starts with neither /run directory there, as on a machine that has not
// checked yet, so the files are found through UpdateStateService's re-arm.
// Then: the checker says available (created, then rewritten in place, then
// replaced by a rename), `sudo rime update` leaves a restart owed, a failed
// update, both files deleted. Each time both bars must agree, and with nothing
// to show the icon takes no width: the notch is exactly as wide as without it.
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    id: root

    readonly property string fixtures: Quickshell.env("RIME_UI_FIXTURES") || ""
    readonly property string statusPath: Quickshell.env("RIME_LIVE_STATUS") || ""
    readonly property string checkerPath: Quickshell.env("RIME_UPDATE_STATE") || ""
    readonly property bool wantReduced: (Quickshell.env("REDUCE_MOTION") || "false") === "true"

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
    // The Updates module in a bar: the one item with both `view` and `shown`.
    function icon(bar) {
        const found = root.collect(bar, "shown", []).filter(x => x.view !== undefined && x.screenName !== undefined)
        return found.length === 1 ? found[0] : null
    }
    function btn(ic) { const b = root.collect(ic, "glyphItem", []); return b.length === 1 ? b[0] : null }
    readonly property var bars: [barA, barB]
    function kindOf(bar) { const i = root.icon(bar); return i ? (i.shown ? i.view.kind : "") : "(no icon)" }

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
                root.check("waited for: " + root._waitName, false, "bar A shows '" + root.kindOf(barA) + "'")
                const t = root._then; root._then = null; t()
            }
        }
    }
    property var _afterSh: null
    Process {
        id: sh
        onExited: function (code) { const f = root._afterSh; root._afterSh = null; if (f) f(code) }
    }
    function run(argv, then) { root._afterSh = then; sh.command = argv; sh.running = true }
    // As the live engine (and the NixOS checker) writes: a new file renamed over.
    function placeRename(fixture, dest, then) {
        root.run(["sh", "-c", "mkdir -p \"${2%/*}\" && cp \"$1\" \"$2.tmp\" && mv -f \"$2.tmp\" \"$2\"", "sh",
                  root.fixtures + "/" + fixture, dest], then)
    }
    // As the bootc checker writes: in place, the directory made first.
    function writeInPlace(text, dest, then) {
        root.run(["sh", "-c", "mkdir -p \"${2%/*}\" && printf '%s' \"$1\" > \"$2\"", "sh", text, dest], then)
    }
    function remove(dest, then) { root.run(["rm", "-f", dest], then) }

    // Both bars show `kind` (or nothing for ""), then `extra`.
    function expect(label, kind, extra) {
        root.waitFor(label + " → " + (kind || "nothing"),
                     function () { return root.kindOf(barA) === kind && root.kindOf(barB) === kind },
                     function () {
                         root.eq(label + ": bar A shows " + (kind || "nothing"), root.kindOf(barA), kind)
                         root.eq(label + ": bar B shows the same", root.kindOf(barB), kind)
                         if (extra) extra()
                         root.next()
                     }, 60)
    }
    // Nothing shown: invisible, zero width, and the notch no wider than its noIconWidth.
    function hidden(label) {
        for (const bar of root.bars) {
            const ic = root.icon(bar)
            root.check(label + ": " + bar.objectName + " icon is not visible", ic && !ic.visible)
            root.eq(label + ": " + bar.objectName + " icon takes no width", ic ? ic.implicitWidth : -1, 0)
            root.eq(label + ": " + bar.objectName + " notch is its width without the icon",
                    bar.implicitWidth, bar.noIconWidth)
        }
    }
    function showing(label, glyph, tooltip) {
        for (const bar of root.bars) {
            const ic = root.icon(bar)
            const b = root.btn(ic)
            root.check(label + ": " + bar.objectName + " icon is visible", ic && ic.visible)
            root.check(label + ": " + bar.objectName + " icon has width", ic && ic.implicitWidth > 0)
            root.eq(label + ": " + bar.objectName + " glyph", b ? String(b.glyphItem.text) : "", glyph)
            root.eq(label + ": " + bar.objectName + " glyph in the icon font", b ? b.glyphItem.font.family : "", Theme.fontIcon)
            root.eq(label + ": " + bar.objectName + " tooltip", ic ? ic.view.tooltip : "", tooltip)
            root.check(label + ": " + bar.objectName + " screen reader name says what it is",
                       b && String(b.label).indexOf(tooltip) === 0)
            root.check(label + ": " + bar.objectName + " notch grew by the icon and one gap",
                       ic && Math.abs(bar.implicitWidth - (bar.noIconWidth + ic.implicitWidth + bar.gap)) < 0.5,
                       "notch " + bar.implicitWidth + ", noIconWidth " + bar.noIconWidth)
        }
    }

    // ── two bars, as TopBar builds them per screen ───────────────────────────
    FloatingWindow {
        implicitWidth: 900
        implicitHeight: 160
        visible: true
        color: "#101012"
        Right.RightContent {
            id: barA
            objectName: "bar A"
            screenName: "TEST-A"
            anchors.right: parent.right
            anchors.top: parent.top
            property real noIconWidth: -1
            readonly property real gap: theme.spaceS   // RightContent's own ThemeSet
        }
        Right.RightContent {
            id: barB
            objectName: "bar B"
            screenName: "TEST-B"
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            property real noIconWidth: -1
            readonly property real gap: theme.spaceS   // RightContent's own ThemeSet
        }
    }

    Component.onCompleted: {
        root.steps = [
            function () {
                // Settle what the other modules show (fonts, network), then
                // take the notch's width with no update as the noIconWidth.
                root.waitFor("settings loaded", function () { return SettingsService._loaded }, function () {
                    root.eq("Reduce Motion is " + (root.wantReduced ? "on" : "off") + " for this run",
                            Motion.reduced, root.wantReduced)
                    root.check("each bar has exactly one update icon", root.icon(barA) !== null && root.icon(barB) !== null)
                    settle.start()
                })
            },
            function () {
                barA.noIconWidth = barA.implicitWidth
                barB.noIconWidth = barB.implicitWidth
                root.check("the notches have a width to compare", barA.noIconWidth > 0 && barB.noIconWidth > 0)
                root.eq("no files, no directories: nothing", root.kindOf(barA), "")
                root.hidden("no files")
                root.check("no files: the absent-file timer runs", UpdateStateService.rearming)
                root.next()
            },
            function () {
                // The directory does not exist when the shell starts: only the
                // re-arm can find it.
                root.writeInPlace("state=available\ndigest=sha256:" + "2".repeat(64) + "\n", root.checkerPath, function () {
                    root.expect("checker created", "available", function () {
                        root.showing("checker created", "󰚰", "A Rime update is available")
                        root.check("available: drawn in the attention colour",
                                   Qt.colorEqual(root.btn(root.icon(barA)).glyphColor, Theme.attention))
                    })
                })
            },
            function () {
                root.writeInPlace("state=none\ndigest=\n", root.checkerPath, function () {
                    root.expect("checker rewritten in place: none", "", function () { root.hidden("checker says none") })
                })
            },
            function () {
                root.placeRename("checker-available", root.checkerPath, function () {
                    root.expect("checker renamed over: available", "available")
                })
            },
            function () {
                // `sudo rime update` queued 2222… for boot and a restart is owed:
                // the checker's stale "available" for that digest is not news.
                root.placeRename("pending-reboot.json", root.statusPath, function () {
                    root.expect("update installed, restart owed", "restart", function () {
                        root.showing("restart owed", "󰜉", "Restart to finish the update")
                    })
                })
            },
            function () {
                root.check("both files there: the absent-file timer has stopped", !UpdateStateService.rearming)
                root.writeInPlace('{"schema": 1, "state": "failed", "staged_for_boot": false}', root.statusPath, function () {
                    root.expect("failed update", "failed", function () {
                        root.showing("failed", "󰅙", "An update could not be applied")
                        root.check("failed: drawn in the danger colour",
                                   Qt.colorEqual(root.btn(root.icon(barA)).glyphColor, Theme.danger))
                    })
                })
            },
            function () {
                root.placeRename("rolled-back.json", root.statusPath, function () {
                    root.expect("rolled back", "rolled-back", function () {
                        root.showing("rolled back", "󰕍", "An update was undone")
                    })
                })
            },
            function () {
                root.remove(root.statusPath, function () {
                    root.expect("status deleted: the checker answers again", "available")
                })
            },
            function () {
                // Click bar B's icon: Settings opens on Updates, on bar B's screen.
                NexusState.close()
                Popups.notificationsOpen = true
                const b = root.btn(root.icon(barB))
                if (b) b.activated()
                root.waitFor("the click opened Settings", function () { return NexusState.open }, function () {
                    root.check("the click opened Settings", NexusState.open)
                    root.eq("on the Updates page", NexusState.page, "updates")
                    root.eq("on the screen whose bar was clicked", NexusState.screenName, "TEST-B")
                    root.check("and closed the bar's open panel", !Popups.notificationsOpen)
                    NexusState.close()
                    root.next()
                }, 20)
            },
            function () {
                root.remove(root.checkerPath, function () {
                    root.expect("both files deleted", "", function () {
                        root.hidden("both files deleted")
                        root.check("both files gone: the absent-file timer runs again", UpdateStateService.rearming)
                    })
                })
            },
            function () {
                // A directory removed and made again (a fresh /run) is found
                // again by the re-arm.
                root.run(["rm", "-rf", root.checkerPath.replace(/\/[^/]*$/, "")], function () {
                    root.writeInPlace("state=available\ndigest=sha256:" + "3".repeat(64) + "\n", root.checkerPath, function () {
                        root.expect("directory made again", "available")
                    })
                })
            },
            function () {
                root.remove(root.checkerPath, function () {
                    root.expect("and gone again", "", function () { root.hidden("end") })
                })
            }
        ]
        root.next()
    }
    Timer { id: settle; interval: 1500; onTriggered: root.next() }
}
