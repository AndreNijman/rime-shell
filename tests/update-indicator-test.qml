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
    // The browser stand-in (RIME_RELEASE_OPENER) appends each URL it is handed here.
    readonly property string openedPath: Quickshell.env("RIME_TEST_OPENED") || ""
    // Where to save a picture of the open menu ("" = none).
    readonly property string shotPath: Quickshell.env("RIME_TEST_SHOT") || ""

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
    // The icon's menu (UpdateMenu, built by its Loader only while open), or null.
    function menuOf(ic) {
        const l = ic ? root.collect(ic, "sourceComponent", []) : []
        return l.length === 1 && l[0].item ? l[0].item : null
    }
    // What the browser stand-in was handed, one URL per line.
    property string opened: ""
    Process {
        id: readOpened
        command: ["cat", root.openedPath]
        stdout: StdioCollector { onStreamFinished: root.opened = String(this.text) }
    }
    function lastOpened() { const l = root.opened.trim().split("\n"); return l[l.length - 1] }
    // Opens bar `bar`'s menu the way a click does, and waits for it.
    function openMenu(bar, then) {
        const ic = root.icon(bar)
        ic.menuGrab = false
        root.btn(ic).activated()
        root.waitFor(bar.objectName + "'s menu opened", function () {
            const m = root.menuOf(ic); return m !== null && m.visible
        }, function () { then(root.menuOf(ic)) }, 30)
    }
    // Chooses `row` in an open menu and waits for the browser stand-in to be
    // handed a URL (n lines in its log).
    function waitOpened(n, then) {
        root.waitFor("the browser was handed " + n + " URL(s)", function () {
            if (!readOpened.running) readOpened.running = true
            return root.opened.trim() !== "" && root.opened.trim().split("\n").length >= n
        }, then, 50)
    }
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
                // An update available from a checker that does not name its
                // release: the icon is a menu button now, for screen readers too.
                const b = root.btn(root.icon(barB))
                root.check("available: the screen reader name says it opens a menu",
                           b && String(b.label).indexOf("Opens a menu: what's in this update, or Updates in Settings") > 0,
                           b ? b.label : "")
                root.eq("available: its role is a menu button", b ? b.Accessible.role : -1, Accessible.ButtonMenu)
                NexusState.close()
                Popups.notificationsOpen = true
                root.openMenu(barB, function (m) {
                    root.check("a click opened the update menu, not Settings", m && m.visible && !NexusState.open)
                    root.check("and closed the bar's open panel", !Popups.notificationsOpen)
                    root.eq("the menu is headed by what the icon says", m ? m.headline : "", "A Rime update is available")
                    root.eq("no release named: no second line", m ? m.subline : "x", "")
                    root.eq("two choices", m ? m.rows.length : 0, 2)
                    root.eq("the first is what's in this update", m ? m.rows[0].label : "", "What's in this update")
                    root.eq("the second opens Settings", m ? m.rows[1].label : "", "Open Updates settings")
                    root.eq("the first row's screen reader name says where it goes",
                            m ? m.rows[0].Accessible.name : "", "What's in this update, opens rimeos.com")
                    root.eq("rows are menu items", m ? m.rows[0].Accessible.role : -1, Accessible.MenuItem)
                    root.eq("the highlight starts on the first row", m ? m.curItem : null, m ? m.rows[0] : undefined)
                    m.rows[0].activated()
                    root.waitOpened(1, function () {
                        root.eq("release unknown: the list of updates, never a guessed page",
                                root.lastOpened(), "https://rimeos.com/updates")
                        root.check("choosing closed the menu", root.menuOf(root.icon(barB)) === null
                                   || !root.menuOf(root.icon(barB)).visible)
                        root.check("looking at the notes is not 'seen' (releases.json untouched)",
                                   ReleaseService.lastUserUrl === "https://rimeos.com/updates" && ReleaseService.state === null)
                        root.next()
                    })
                })
            },
            function () {
                // "Open Updates settings": Settings on Updates, on bar B's screen.
                root.openMenu(barB, function (m) {
                    m._step(1)
                    root.eq("Down moves to Open Updates settings", m.curItem, m.rows[1])
                    m._step(1)
                    root.eq("and stops at the last row", m.curItem, m.rows[1])
                    m.curItem.activated()
                    root.waitFor("the menu opened Settings", function () { return NexusState.open }, function () {
                        root.check("Open Updates settings opened Settings", NexusState.open)
                        root.eq("on the Updates page", NexusState.page, "updates")
                        root.eq("on the screen whose bar was clicked", NexusState.screenName, "TEST-B")
                        root.check("and the menu closed", !root.icon(barB).menuOpen)
                        NexusState.close()
                        root.next()
                    }, 20)
                })
            },
            function () {
                // A checker that names the release on offer and the running one.
                root.writeInPlace("state=available\ndigest=sha256:" + "4".repeat(64)
                                  + "\nrelease=2026.11.04.4\nrunning=2026.11.03\n", root.checkerPath, function () {
                    root.waitFor("the checker's release is read", function () {
                        return UpdateStateService.whatsNew && UpdateStateService.whatsNew.release === "2026.11.04.4"
                    }, function () {
                        root.openMenu(barA, function (m) {
                            root.eq("the menu names what this computer runs (its release.json) and the release on offer",
                                    m.subline, "Rime 2026.10.10 → 2026.11.04.4")
                            if (root.shotPath !== "") {
                                shot.command = ["grim", root.shotPath]
                                shot.running = true
                            }
                            // Down, Up, choose: the keyboard's way to the first row.
                            m._step(1); m._step(-1)
                            root.eq("Up comes back to What's in this update", m.curItem, m.rows[0])
                            shotWait.then = function () {
                                m.curItem.activated()
                                root.waitOpened(2, function () {
                                    root.eq("the release's page, from the release this computer runs",
                                            root.lastOpened(), "https://rimeos.com/updates/2026.11.04.4?from=2026.10.10")
                                    root.next()
                                })
                            }
                            shotWait.start()
                        })
                    }, 40)
                })
            },
            function () {
                // `sudo rime update` installed 2026.10.11 for the next restart:
                // the link is to what runs after it.
                root.placeRename("pending-reboot.json", root.statusPath, function () {
                    root.expect("restart owed again", "restart", function () {
                        root.eq("restart owed: the link is the installed release",
                                UpdateStateService.whatsNew ? UpdateStateService.whatsNew.url : "",
                                "https://rimeos.com/updates/2026.10.11?from=2026.10.10")
                    })
                })
            },
            function () {
                // Only rimeos.com's update pages reach the browser: the runner
                // fails the run if this one is in its log.
                root.eq("openUrl refuses anything but a rimeos.com update page",
                        [ReleaseService.openUrl("https://evil.example/updates/2026.11.04"),
                         ReleaseService.openUrl("https://rimeos.com/updates/2026.11.04?from=x;rm"),
                         ReleaseService.openUrl("https://rimeos.com.evil.example/updates")].join(","), "false,false,false")
                root.openMenu(barB, function (m) {
                    root.eq("restart owed: headed by the restart", m.headline, "Restart to finish the update")
                    m.rows[0].activated()
                    root.waitOpened(3, function () {
                        root.eq("restart owed: the browser got the installed release's page",
                                root.lastOpened(), "https://rimeos.com/updates/2026.10.11?from=2026.10.10")
                        root.next()
                    })
                })
            },
            function () {
                // A menu open when the icon goes away goes with it.
                root.openMenu(barA, function (m) {
                    root.writeInPlace('{"schema": 1, "state": "failed", "staged_for_boot": false}', root.statusPath, function () {
                        root.expect("failed, nothing queued", "failed", function () {
                            root.check("the menu closed when the update it was about failed",
                                       !root.icon(barA).menuOpen && root.menuOf(root.icon(barA)) === null)
                            root.eq("failed with nothing queued: no link", UpdateStateService.whatsNew, null)
                            const b = root.btn(root.icon(barA))
                            root.check("no link: the screen reader name says Settings",
                                       b && String(b.label).indexOf(". Opens Updates in Settings") > 0, b ? b.label : "")
                            root.eq("no link: a plain button", b ? b.Accessible.role : -1, Accessible.Button)
                        })
                    })
                })
            },
            function () {
                // No link: a click goes straight to Settings, as it always did.
                NexusState.close()
                Popups.notificationsOpen = true
                const b = root.btn(root.icon(barB))
                if (b) b.activated()
                root.waitFor("the click opened Settings", function () { return NexusState.open }, function () {
                    root.check("the click opened Settings", NexusState.open)
                    root.check("without a menu", !root.icon(barB).menuOpen)
                    root.eq("on the Updates page", NexusState.page, "updates")
                    root.eq("on the screen whose bar was clicked", NexusState.screenName, "TEST-B")
                    root.check("and closed the bar's open panel", !Popups.notificationsOpen)
                    NexusState.close()
                    root.remove(root.statusPath, function () { root.next() })
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
    Process { id: shot }
    // Lets the menu finish its entrance before it is photographed and chosen.
    Timer {
        id: shotWait
        property var then: null
        interval: 600
        onTriggered: { const t = shotWait.then; shotWait.then = null; if (t) t() }
    }
}
