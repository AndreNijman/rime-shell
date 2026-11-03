import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/theme"
import "./src/services"
import "./src/nexus"

// ─────────────────────────────────────────────────────────────────────────────
// The settings apply bar, in the real settings host, in a real window. Run by
// tests/run-apply-bar-test.sh, which supplies a private headless compositor,
// HOME and session bus, and stubs everything the pages shell out to.
//
// The bar is one CfgApplyBar hosted by SettingsHost over the bottom of the page
// area, pointed at the current page's CfgCommit. What only a live run can say,
// and so what this asserts:
//
//   * it is not there while nothing is staged, and comes up when something is
//   * it slides on the motion system, and snaps under Reduce Motion
//   * it stays inside the viewport with the page scrolled to the top AND to
//     the bottom, at the same place both times
//   * the page's content is padded by the bar's height while it shows, so the
//     last control scrolls clear of it rather than under it
//   * Apply applies (the draft reaches disk and the bar goes); Revert reverts
//   * Ctrl+Enter and Ctrl+S, typed into the window from outside (wtype), apply
//   * it follows the current page: a page with nothing staged has no bar
//   * the Display page's countdown is asked on the bar, with Keep, and no Apply
//   * a rebuilt host (the window closed and opened again) finds the draft and
//     shows the bar again: closing Settings throws nothing away
//   * the bar's buttons are in the window's Tab chain and the bar has a name
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    id: root

    readonly property string grabDir:   Quickshell.env("RIME_AB_GRAB_DIR") || ""
    readonly property string keysReady: Quickshell.env("RIME_AB_KEYS_READY") || ""
    readonly property string keysSent:  Quickshell.env("RIME_AB_KEYS_SENT") || ""
    readonly property bool   haveKeys:  (Quickshell.env("RIME_AB_WTYPE") || "") === "1"

    property int passed: 0
    property int failed: 0
    function check(name, cond, detail) {
        if (cond) { root.passed++; console.log("  PASS  " + name) }
        else { root.failed++; console.log("  FAIL  " + name + (detail !== undefined ? "  [" + detail + "]" : "")) }
    }

    // ── the window, built the way Nexus builds it ────────────────────────────
    FloatingWindow {
        id: win
        implicitWidth: 900
        implicitHeight: 620
        visible: true
        color: "#101012"

        Loader {
            id: hostLoader
            anchors.fill: parent
            active: true
            sourceComponent: Component {
                SettingsHost {
                    page: "keybinds"
                    live: true
                }
            }
        }
    }
    readonly property var host: hostLoader.item
    readonly property var bar: root.host ? root.host.applyBar : null

    // The action driven throughout: SUPER+T by default, so SUPER+SHIFT+T is a
    // real change that collides with nothing.
    readonly property string action: "app-terminal"
    readonly property string newMods: "SUPER + SHIFT"
    readonly property string newKey: "T"
    function stage() { KeybindService.stage(root.action, root.newMods, root.newKey) }

    // ── finding things by what they are ──────────────────────────────────────
    function collect(obj, test, out) {
        if (!obj) return out
        if (test(obj)) out.push(obj)
        const kids = obj.children
        if (kids) for (let i = 0; i < kids.length; i++) root.collect(kids[i], test, out)
        return out
    }
    function keybindsPage() {
        const p = root.collect(root.host, o => o._pending !== undefined && o.hasPending !== undefined, [])
        return p.length > 0 ? p[0] : null
    }
    function flickOf(page) {
        const f = root.collect(page, o => o.contentY !== undefined && o.flickableDirection !== undefined, [])
        return f.length > 0 ? f[0] : null
    }
    function button(label) {
        const b = root.collect(root.bar, o => o.variant !== undefined && o.label === label && o.visible, [])
        return b.length === 1 ? b[0] : null
    }
    function labels() {
        return root.collect(root.bar, o => o.variant !== undefined && o.visible, []).map(b => String(b.label))
    }
    function barTexts() {
        return root.collect(root.bar, o => o.elide !== undefined && o.visible && String(o.text) !== "", [])
                   .map(t => String(t.text))
    }
    function rectOf(item) {
        const p = item.mapToItem(null, 0, 0)
        return { x: p.x, y: p.y, w: item.width, h: item.height }
    }
    // The bar's visible surface, in window coordinates, at rest.
    function surface() { return root.rectOf(root.bar.surface) }

    // ── the harness ──────────────────────────────────────────────────────────
    property var steps: []
    property int stepIndex: 0
    function next() {
        if (root.stepIndex >= root.steps.length) {
            console.log("")
            console.log("apply-bar: passed=" + root.passed + " failed=" + root.failed)
            Qt.exit(root.failed === 0 ? 0 : 1)
            return
        }
        const s = root.steps[root.stepIndex++]
        Qt.callLater(s)
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
        interval: 50
        repeat: true
        onTriggered: {
            if (root._cond()) { stop(); const t = root._then; root._then = null; t(); return }
            if (++root._ticks >= root._maxTicks) {
                stop()
                root.check("waited for: " + root._waitName, false)
                const t = root._then; root._then = null; t()
            }
        }
    }
    function settled() { return root.bar && !root.bar.moving }
    function shownAndSettled() { return root.bar && root.bar.shown && root.bar.progress === 1 && !root.bar.moving }
    function goneAndSettled() { return root.bar && !root.bar.shown && !root.bar.visible && !root.bar.moving }

    // Samples the bar's travel every few ms while armed, so "it moved through
    // the frames in between" is a reading rather than an assumption.
    property var samples: []
    Timer {
        id: sampler
        interval: 4
        repeat: true
        onTriggered: if (root.bar) root.samples.push(root.bar.progress)
    }
    function inBetween() { return root.samples.filter(v => v > 0.02 && v < 0.98).length }

    // A picture of the window, when the runner asked for them.
    function grab(name, then) {
        if (root.grabDir === "") { then(); return }
        hostLoader.grabToImage(function (r) {
            root.check("picture: " + name, r.saveToFile(root.grabDir + "/" + name + ".png"))
            then()
        })
    }

    // A line to the runner, which answers by typing into the window.
    property var _afterSh: null
    Process {
        id: sh
        onExited: function (code) { const f = root._afterSh; root._afterSh = null; if (f) f(code) }
    }
    function run(argv, then) { root._afterSh = then; sh.command = argv; sh.running = true }
    // The ready file holds the chord; the runner types it into the window and
    // then creates the sent file.
    function askKeys(which, then) {
        root.run(["sh", "-c", "rm -f \"$2\"; printf '%s\\n' \"$3\" > \"$1\"", "sh",
                  root.keysReady, root.keysSent, which], function () { root._pollSent(then, 0) })
    }
    function _pollSent(then, tries) {
        root.run(["test", "-f", root.keysSent], function (code) {
            if (code === 0 || tries >= 100) {
                root.check("the runner typed into the window", code === 0)
                then()
                return
            }
            pause.then = function () { root._pollSent(then, tries + 1) }
            pause.restart()
        })
    }
    Timer { id: pause; interval: 100; property var then: null; onTriggered: then() }

    Component.onCompleted: {
        root.steps = [
            root.opening,
            root.clean,
            root.appears,
            root.viewportTop,
            root.viewportBottom,
            root.padding,
            root.tabAndName,
            root.applyButton,
            root.revertButton,
            root.followsPage,
            root.displayCountdown,
            root.reduceMotion,
            root.survivesRebuild,
            root.ctrlEnter,
            root.ctrlS
        ]
        root.next()
    }

    // ── the steps ────────────────────────────────────────────────────────────
    function opening() {
        root.waitFor("the Keybinds page is built and the defaults merged",
                     function () { return root.keybindsPage() !== null
                                          && Object.keys(KeybindService.keybinds).length > 0 },
                     function () {
                         root.check("the host built the Keybinds page", root.keybindsPage() !== null)
                         root.check("the host has its apply bar", root.bar !== null)
                         KeybindService.revertStaged()
                         root.next()
                     }, 200)
    }
    function clean() {
        root.waitFor("a clean page settles", root.settled, function () {
            root.check("clean: the bar is not shown", root.bar.shown === false)
            root.check("clean: the bar is not visible", root.bar.visible === false)
            root.check("clean: the page is not padded for it", root.keybindsPage().bottomInset === 0,
                       root.keybindsPage().bottomInset)
            root.grab("01-clean", root.next)
        })
    }
    function appears() {
        root.samples = []
        sampler.start()
        root.stage()
        root.check("a change: the bar is shown at once", root.bar.shown === true)
        root.waitFor("the bar comes to rest", root.shownAndSettled, function () {
            sampler.stop()
            root.check("a change: the bar is visible", root.bar.visible === true)
            root.check("it slid in: frames between tucked and at rest", root.inBetween() >= 2,
                       root.inBetween() + " of " + root.samples.length)
            const t = root.barTexts()
            root.check("it says what it holds", t.indexOf("1 staged shortcut") >= 0, t.join(" | "))
            root.check("it offers Apply", root.button("Apply") !== null, root.labels().join(","))
            root.check("it offers Revert", root.button("Revert") !== null, root.labels().join(","))
            root.check("it offers no Save on a page where Apply is the save", root.button("Save") === null)
            root.check("the page is padded by the bar's reserve",
                       Math.abs(root.keybindsPage().bottomInset - root.bar.reserve) < 0.5,
                       root.keybindsPage().bottomInset + " vs " + root.bar.reserve)
            root.next()
        })
    }
    property var restRect: null
    function inWindow(r) { return r.y >= 0 && r.y + r.h <= win.height && r.x >= 0 && r.x + r.w <= win.width }
    function viewportTop() {
        const f = root.flickOf(root.keybindsPage())
        root.check("the Keybinds page has its list", f !== null)
        f.contentY = 0
        Qt.callLater(function () {
            const r = root.surface()
            root.restRect = r
            root.check("scrolled to the top: the bar is inside the window", root.inWindow(r),
                       JSON.stringify(r) + " in " + win.width + "x" + win.height)
            root.check("scrolled to the top: the bar is at the bottom of the window, not the content's end",
                       win.height - (r.y + r.h) < 40, win.height - (r.y + r.h))
            root.check("the content is taller than the view, so scrolling means something",
                       f.contentHeight > f.height * 2, f.contentHeight + " vs " + f.height)
            root.grab("02-dirty-top", root.next)
        })
    }
    function viewportBottom() {
        const f = root.flickOf(root.keybindsPage())
        f.contentY = Math.max(0, f.contentHeight - f.height)
        Qt.callLater(function () {
            const r = root.surface()
            root.check("scrolled to the bottom: the bar is inside the window", root.inWindow(r), JSON.stringify(r))
            root.check("scrolled to the bottom: the bar has not moved",
                       root.restRect && Math.abs(r.y - root.restRect.y) < 0.5 && Math.abs(r.x - root.restRect.x) < 0.5,
                       JSON.stringify(r) + " vs " + JSON.stringify(root.restRect))
            root.grab("03-dirty-bottom", root.next)
        })
    }
    function padding() {
        // Scrolled to the end, the last control must end above the bar.
        const f = root.flickOf(root.keybindsPage())
        const col = f.contentItem.children[0]
        const bottom = col.mapToItem(null, 0, col.height).y
        const top = root.surface().y
        root.check("scrolled to the end, the last control ends above the bar", bottom <= top,
                   "content ends at " + bottom + ", bar starts at " + top)
        // And the lowest row is a real row, hittable above the bar.
        const rows = root.collect(col, o => o.action !== undefined && o.visible && o.height > 0, [])
        const last = rows.length ? rows[rows.length - 1] : null
        root.check("the last row is above the bar",
                   last !== null && last.mapToItem(null, 0, last.height).y <= top,
                   last ? last.mapToItem(null, 0, last.height).y + " vs " + top : "no rows")
        f.contentY = 0
        root.next()
    }
    // The same promise on a CfgScroll page (Display, Blueprint), whose padding
    // comes from CfgScroll.bottomInset rather than the Keybinds list's own.
    function cfgScrollPadding(name) {
        const page = root.collect(root.host, o => o.commit !== undefined && o.commit === root.bar.model, [])[0]
        const f = page ? root.flickOf(page) : null
        root.check(name + ": the page is a CfgScroll with a bottomInset",
                   f !== null && page.bottomInset !== undefined)
        if (!f) return
        root.check(name + ": the page is padded by the bar's reserve",
                   Math.abs(page.bottomInset - root.bar.reserve) < 0.5,
                   page.bottomInset + " vs " + root.bar.reserve)
        const col = f.contentItem.children[0]
        root.check(name + ": the scrollable height includes the padding",
                   f.contentHeight - col.implicitHeight >= root.bar.reserve,
                   f.contentHeight + " - " + col.implicitHeight + " vs " + root.bar.reserve)
        f.contentY = Math.max(0, f.contentHeight - f.height)
        const bottom = col.mapToItem(null, 0, col.height).y
        const top = root.surface().y
        root.check(name + ": scrolled to the end, the last control ends above the bar", bottom <= top,
                   "content ends at " + bottom + ", bar starts at " + top)
        f.contentY = 0
    }
    function tabAndName() {
        const apply = root.button("Apply")
        let seen = false, it = root.host, n = 0
        // The window's Tab chain, followed from the host's first item.
        it = root.host.nextItemInFocusChain(true)
        const first = it
        while (it && n < 400) {
            if (it === apply) { seen = true; break }
            it = it.nextItemInFocusChain(true)
            n++
            if (it === first) break
        }
        root.check("Apply is in the window's Tab chain", seen, n + " stops")
        root.check("Apply takes focus from Tab", apply && apply.activeFocusOnTab === true)
        root.check("the bar names itself for a screen reader",
                   root.bar.surface.Accessible.name === "1 staged shortcut",
                   root.bar.surface.Accessible.name)
        root.check("and is a tool bar", root.bar.surface.Accessible.role === Accessible.ToolBar)
        root.next()
    }
    function applyButton() {
        const apply = root.button("Apply")
        apply.press()
        root.waitFor("Apply clears the draft and the bar goes",
                     function () { return !KeybindService.hasStaged && root.goneAndSettled() },
                     function () {
                         root.check("Apply: the draft is applied",
                                    KeybindService.keybinds[root.action]
                                    && KeybindService.keybinds[root.action].mods === root.newMods,
                                    JSON.stringify(KeybindService.keybinds[root.action]))
                         root.check("Apply: no error", KeybindService.lastError === "", KeybindService.lastError)
                         root.check("Apply: the bar is gone", !root.bar.visible)
                         root.check("Apply: the padding is gone", root.keybindsPage().bottomInset === 0)
                         root.next()
                     }, 200)
    }
    function revertButton() {
        const before = JSON.stringify(KeybindService.keybinds[root.action])
        KeybindService.stage(root.action, "SUPER + ALT", "T")
        root.waitFor("the bar is back", root.shownAndSettled, function () {
            root.button("Revert").press()
            root.waitFor("Revert drops the draft and the bar goes",
                         function () { return !KeybindService.hasStaged && root.goneAndSettled() },
                         function () {
                             root.check("Revert: nothing is staged", !KeybindService.hasStaged)
                             root.check("Revert: the binding is what it was",
                                        JSON.stringify(KeybindService.keybinds[root.action]) === before)
                             root.next()
                         })
        })
    }
    function followsPage() {
        root.stage()
        root.waitFor("the bar shows for the draft", root.shownAndSettled, function () {
            root.host.page = "data"
            root.waitFor("a page with nothing staged has no bar", root.goneAndSettled, function () {
                root.check("another page: no bar", !root.bar.visible)
                root.host.page = "keybinds"
                root.waitFor("back on Keybinds, the bar is back", root.shownAndSettled, function () {
                    root.check("back: the bar holds the same draft",
                               root.barTexts().indexOf("1 staged shortcut") >= 0)
                    KeybindService.revertStaged()
                    root.waitFor("clean again", root.goneAndSettled, root.next)
                })
            })
        })
    }
    function displayCountdown() {
        root.host.page = "display"
        root.waitFor("the Display page has no bar while nothing is staged", root.goneAndSettled, function () {
            DisplayService.confirmSeconds = 9
            root.waitFor("the countdown is asked on the bar", root.shownAndSettled, function () {
                const t = root.barTexts()
                root.check("countdown: the bar asks the question", t.indexOf("Keep this layout?") >= 0, t.join(" | "))
                root.check("countdown: it says what doing nothing does",
                           t.some(x => x.indexOf("comes back in 9 seconds") >= 0), t.join(" | "))
                root.check("countdown: Keep it is there", root.button("Keep it") !== null, root.labels().join(","))
                root.check("countdown: no Apply on top of an unanswered apply", root.button("Apply") === null)
                root.cfgScrollPadding("display")
                root.grab("04-display-countdown", function () {
                    DisplayService.confirmSeconds = 0
                    root.waitFor("the countdown over, the bar goes", root.goneAndSettled, function () {
                        root.host.page = "keybinds"
                        root.waitFor("back on keybinds", root.settled, root.next)
                    })
                })
            })
        })
    }
    function reduceMotion() {
        SettingsService.reduceMotion = true
        root.samples = []
        sampler.start()
        root.stage()
        Qt.callLater(function () {
            root.check("Reduce Motion: at rest the moment it is asked", root.bar.progress === 1 && !root.bar.moving,
                       root.bar.progress)
            KeybindService.revertStaged()
            Qt.callLater(function () {
                sampler.stop()
                root.check("Reduce Motion: gone the moment it is clean", root.bar.progress === 0 && !root.bar.visible,
                           root.bar.progress)
                root.check("Reduce Motion: no frame in between", root.inBetween() === 0,
                           root.inBetween() + " of " + root.samples.length)
                SettingsService.reduceMotion = false
                root.next()
            })
        })
    }
    function survivesRebuild() {
        root.stage()
        hostLoader.active = false
        Qt.callLater(function () {
            hostLoader.active = true
            root.waitFor("the rebuilt host shows the draft",
                         function () { return root.keybindsPage() !== null && root.shownAndSettled() },
                         function () {
                             root.check("closing and reopening Settings keeps the draft", KeybindService.hasStaged)
                             root.check("and the bar is back over it",
                                        root.barTexts().indexOf("1 staged shortcut") >= 0)
                             KeybindService.revertStaged()
                             root.waitFor("clean", root.goneAndSettled, root.next)
                         }, 200)
        })
    }
    function keyStep(chord, name, then) {
        if (!root.haveKeys || root.keysReady === "") {
            console.log("  SKIP  " + name + " (no wtype)")
            then()
            return
        }
        KeybindService.stage(root.action, chord === "ctrl-s" ? "SUPER + CTRL" : "SUPER + ALT", "Y")
        root.waitFor("staged for " + name, root.shownAndSettled, function () {
            root.askKeys(chord, function () {
                root.waitFor(name, function () { return !KeybindService.hasStaged && root.goneAndSettled() },
                             function () {
                                 root.check(name, !KeybindService.hasStaged && KeybindService.lastError === "",
                                            KeybindService.lastError)
                                 then()
                             }, 100)
            })
        })
    }
    function ctrlEnter() { root.keyStep("ctrl-return", "Ctrl+Enter, typed into the window, applies", root.next) }
    function ctrlS() { root.keyStep("ctrl-s", "Ctrl+S, typed into the window, applies", root.next) }
}
