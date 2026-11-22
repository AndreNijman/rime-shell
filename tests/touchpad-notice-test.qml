import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/services"
import "./src/nexus"
import "./src/windows"

// ─────────────────────────────────────────────────────────────────────────────
// "A phone is using this computer as a touchpad", BUILT: the shipped TopBar on
// a headless labwc, fed by writing rime-remoted's
// $XDG_RUNTIME_DIR/rime-remote/input.json the way the daemon writes it (whole,
// renamed into place; rime-os docs/remote-live-contract.md §2.16).
// Run via tests/run-touchpad-notice-test.sh, which gives it a private runtime
// dir, HOME and session bus, and puts recording stubs first on PATH:
//   rime         one JSON argv per line in $TP_RIME_LOG; for
//                `remote devices touchpad stop` it does what $TP_MODE says:
//                "obey" writes {"v":1,"live":false} like the daemon, "ignore"
//                does nothing, "fail" exits 1
//   notify-send  one JSON argv per line in $TP_NOTIFY_LOG
//
// The indicator counts as SHOWN when the carousel holds "touchpad", is
// scrolled to it, and its TouchpadNotice is visible; HIDDEN when no notice is
// visible and the carousel has no "touchpad".
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    id: t

    // Compiled first, as in the Shell (tests/visualiser-battery-test.qml).
    readonly property var _pages: NexusState

    readonly property string run: Quickshell.env("XDG_RUNTIME_DIR")
    readonly property string inputPath: t.run + "/rime-remote/input.json"
    readonly property string rimeLog: Quickshell.env("TP_RIME_LOG")
    readonly property string notifyLog: Quickshell.env("TP_NOTIFY_LOG")
    readonly property string modePath: Quickshell.env("TP_MODE")
    readonly property string shotDir: Quickshell.env("TP_SHOT_DIR") || ""
    readonly property string shotTag: Quickshell.env("TP_SHOT_TAG") || "dark"
    readonly property bool wantReduced: (Quickshell.env("REDUCE_MOTION") || "false") === "true"

    property int passed: 0
    property int failed: 0
    function check(name, cond, detail) {
        if (cond) { t.passed++; console.warn("  PASS  " + name) }
        else { t.failed++; console.warn("  FAIL  " + name + (detail ? "  [" + detail + "]" : "")) }
    }
    function eq(name, got, want) {
        const same = (typeof want === "object" && want !== null) ? JSON.stringify(got) === JSON.stringify(want) : got === want
        t.check(name, same, "got " + JSON.stringify(got) + ", want " + JSON.stringify(want))
    }

    // ── the bar under test ──────────────────────────────────────────────────
    TopBar { id: bar; screen: Quickshell.screens[0] }

    function collect(obj, pred, out) {
        if (!obj) return out
        if (pred(obj)) out.push(obj)
        const kids = obj.children
        if (kids) for (let i = 0; i < kids.length; i++) t.collect(kids[i], pred, out)
        return out
    }
    function centre() {
        const c = t.collect(bar.contentItem, o => o._items !== undefined && o._carouselIndex !== undefined, [])
        return c.length === 1 ? c[0] : null
    }
    function notices() { return t.collect(bar.contentItem, o => o.objectName === "touchpadNotice", []) }
    function shownNotice() {
        const v = t.notices().filter(n => n.visible)
        return v.length === 1 ? v[0] : null
    }
    function currentItem() { const c = t.centre(); return c ? c._items[c._carouselIndex] : "(no centre)" }
    function isShown() {
        const c = t.centre()
        return c !== null && c._items.indexOf("touchpad") >= 0 && t.currentItem() === "touchpad" && t.shownNotice() !== null
    }
    function isHidden() {
        const c = t.centre()
        return c !== null && c._items.indexOf("touchpad") < 0 && t.notices().every(n => !n.visible)
    }

    // ── files and logs ──────────────────────────────────────────────────────
    property var _afterSh: null
    Process {
        id: sh
        onExited: function () { const f = t._afterSh; t._afterSh = null; if (f) f() }
    }
    function sh_(argv, then) { t._afterSh = then; sh.command = argv; sh.running = true }
    // As rime-remoted writes it: a temporary file renamed into place.
    function place(text, then) {
        t.sh_(["sh", "-c", 'mkdir -p "${2%/*}" && chmod 700 "${2%/*}" && printf "%s" "$1" > "$2.tmp" && chmod 600 "$2.tmp" && mv -f "$2.tmp" "$2"',
               "sh", text, t.inputPath], then)
    }
    function removeFile(then) { t.sh_(["rm", "-f", t.inputPath], then) }
    function setMode(mode, then) { t.sh_(["sh", "-c", 'printf "%s" "$1" > "$2"', "sh", mode, t.modePath], then) }
    function live(name, since) {
        return JSON.stringify({ v: 1, live: true, device: "d-0123456789abcdef", name: name, since_ms: since })
    }
    readonly property string notLive: '{"v":1,"live":false}'

    property string _logText: ""
    Process {
        id: cat
        stdout: StdioCollector { onStreamFinished: t._logText = String(this.text) }
        onExited: function () { const f = t._afterCat; t._afterCat = null; if (f) f(t._parse(t._logText)) }
    }
    property var _afterCat: null
    function readLog(path, then) { t._logText = ""; t._afterCat = then; cat.command = ["sh", "-c", 'cat "$1" 2>/dev/null; true', "sh", path]; cat.running = true }
    function _parse(text) {
        return String(text).split("\n").filter(l => l.trim() !== "").map(l => { try { return JSON.parse(l) } catch (e) { return ["<unparsable>", l] } })
    }
    // The log once it holds at least `n` notifications (notify-send runs
    // detached, so its line lands a moment after the notice shows), or after 3 s.
    function readToasts(n, then, tries) {
        const left = tries === undefined ? 30 : tries
        t.readLog(t.notifyLog, function (calls) {
            if (t.toasts(calls).length >= n || left <= 0) then(calls)
            else t.after(100, () => t.readToasts(n, then, left - 1))
        })
    }
    function toasts(calls) { return calls.filter(a => a.indexOf("Phone in use as a touchpad") >= 0) }
    function stops(calls) { return calls.filter(a => a.join(" ") === "remote devices touchpad stop") }
    function touchpadCalls(calls) { return calls.filter(a => a.join(" ").indexOf("touchpad") >= 0) }

    // ── the harness ─────────────────────────────────────────────────────────
    property var steps: []
    property int stepIndex: 0
    function next() {
        if (t.stepIndex >= t.steps.length) {
            console.warn("touchpad-notice: passed=" + t.passed + " failed=" + t.failed)
            Qt.exit(t.failed === 0 ? 0 : 1)
            return
        }
        t.steps[t.stepIndex++]()
    }
    property var _cond: null
    property var _then: null
    property string _waitName: ""
    property int _ticks: 0
    property int _maxTicks: 60
    function waitFor(name, cond, then, maxTicks) {
        t._waitName = name; t._cond = cond; t._then = then
        t._ticks = 0; t._maxTicks = maxTicks || 60
        waiter.restart()
    }
    Timer {
        id: waiter
        interval: 100
        repeat: true
        onTriggered: {
            if (t._cond()) { stop(); const f = t._then; t._then = null; f(); return }
            if (++t._ticks >= t._maxTicks) {
                stop()
                t.check("waited for: " + t._waitName, false, "carousel on '" + t.currentItem() + "', live=" + TouchpadService.live)
                const f = t._then; t._then = null; f()
            }
        }
    }
    Timer { id: pause; property var then: null; onTriggered: { const f = pause.then; pause.then = null; f() } }
    function after(ms, then) { pause.interval = ms; pause.then = then; pause.restart() }

    // Plain text, measured: the same string in a Text that is certainly plain.
    // A name drawn as rich text ("<b>…</b>" as bold, tags gone) measures
    // differently.
    Text { id: plainRef; visible: false; textFormat: Text.PlainText }
    function drawnPlain(item) {
        plainRef.font = item.font
        plainRef.text = item.text
        return Math.abs(plainRef.implicitWidth - item.implicitWidth) < 0.5
    }

    property bool _shot: false
    Process { id: grim }
    function shoot(name, then) {
        if (t.shotDir === "") { then(); return }
        const w = bar.width, cw = bar.cWidth
        const x = Math.max(0, Math.round((w - cw) / 2) - 70), wd = Math.min(w, cw + 140)
        t.sh_(["sh", "-c", 'grim -s 2 -g "$1" "$2" && grim "$3"', "sh",
               x + ",0 " + wd + "x64", t.shotDir + "/" + name + "-" + t.shotTag + ".png",
               t.shotDir + "/" + name + "-" + t.shotTag + "-full.png"], then)
    }

    readonly property real t0: Date.now()
    readonly property string hostile: {
        const rlo = String.fromCharCode(0x202e), bel = String.fromCharCode(7), zw = String.fromCharCode(0x200b)
        const lri = String.fromCharCode(0x2066), arabic = String.fromCharCode(0x0647, 0x0627, 0x062a, 0x0641)
        return "<b>Evil</b>&amp;<img src=x>" + rlo + bel + zw + lri + arabic + "\n" + "x".repeat(10000)
    }

    Component.onCompleted: {
        t.steps = [
            function () {
                t.waitFor("the bar built and the settings read", () => t.centre() !== null && SettingsService._loaded, function () {
                    t.eq("Reduce Motion is " + (t.wantReduced ? "on" : "off") + " for this run", Motion.reduced, t.wantReduced)
                    t.check("no input.json: hidden", t.isHidden())
                    t.check("no input.json: not live", !TouchpadService.live)
                    t.next()
                })
            },
            function () {
                t.setMode("obey", () => t.place(t.live("Pixel 8", Date.now()), function () {
                    t.waitFor("live: shown", t.isShown, function () {
                        const n = t.shownNotice()
                        t.check("live: shown, and the carousel scrolled to it", t.isShown())
                        t.eq("live: the name", n ? n.nameItem.text : "", "Pixel 8")
                        t.eq("live: the name is plain text", n ? n.nameItem.textFormat : -1, Text.PlainText)
                        t.eq("live: says touchpad", n ? n.suffixItem.text : "", "· touchpad")
                        t.eq("live: a screen reader hears the whole sentence", n ? String(n.Accessible.name) : "",
                             "Pixel 8 is using this computer as a touchpad and keyboard")
                        t.eq("live: Stop is a button", n ? n.stopItem.Accessible.role : -1, Accessible.Button)
                        t.eq("live: Stop has a name", n ? String(n.stopItem.Accessible.name) : "", "Stop the touchpad")
                        t.check("live: Stop is a 24 px target at least",
                                n && Math.min(n.stopItem.width, n.stopItem.height) + 2 * n.stopItem.hitMargin >= 24)
                        // Reduce Motion: the dot holds still (sampled for 1.2 s).
                        t._opacities = []
                        t.sampleDot(n, 6, function () {
                            if (t.wantReduced) t.check("Reduce Motion: the dot does not pulse", t._opacities.every(o => o === 1),
                                                       JSON.stringify(t._opacities))
                            else t.check("motion: the dot pulses", t._opacities.some(o => o < 0.99), JSON.stringify(t._opacities))
                            t.shoot("touchpad-notice", function () {
                                t.readToasts(1, function (calls) {
                                    const ts = t.toasts(calls)
                                    t.eq("live: one notification", ts.length, 1)
                                    if (ts.length === 1) {
                                        const a = ts[0]
                                        t.eq("notification: its argv", a.slice(0, 6), ["-a", "Rime", "-i", "input-touchpad", "--", "Phone in use as a touchpad"])
                                        t.check("notification: the body names the phone and the way to stop it",
                                                a[6].indexOf("Pixel 8") >= 0 && a[6].indexOf("top bar") >= 0, a[6])
                                    }
                                    t.next()
                                })
                            })
                        })
                    })
                }))
            },
            function () {
                // The same file again (a re-armed watch, a second rename): no second notification.
                t.place(t.live("Pixel 8", TouchpadService.since), () => t.after(800, function () {
                    t.readToasts(2, function (calls) {
                        t.eq("the same session written again: still one notification", t.toasts(calls).length, 1)
                        t.check("the same session written again: still shown", t.isShown())
                        t.next()
                    })
                }))
            },
            function () {
                t.place(t.notLive, () => t.waitFor("live:false: hidden", t.isHidden, function () {
                    t.check("live:false: hidden", t.isHidden())
                    t.next()
                }))
            },
            // Each of these must read as not live. Shown first, so "hidden" is a change.
            ...[["garbage", "{\"v\":1,\"live\":tr"], ["binary garbage", "\u0001\u0002 not json"],
                ["another version", "{\"v\":2,\"live\":true,\"name\":\"Pixel 8\",\"since_ms\":1}"],
                ["live as a string", "{\"v\":1,\"live\":\"true\",\"name\":\"Pixel 8\"}"],
                ["oversized (100 KiB)", "{\"v\":1,\"live\":true,\"name\":\"Pixel 8\",\"since_ms\":1,\"pad\":\"" + "a".repeat(100000) + "\"}"],
                ["absent", null]].map(function (c) {
                return function () {
                    t.place(t.live("Pixel 8", Date.now()), () => t.waitFor(c[0] + ": shown before", t.isShown, function () {
                        const then = () => t.waitFor(c[0] + ": hidden", t.isHidden, function () {
                            t.check(c[0] + ": hidden", t.isHidden())
                            t.check(c[0] + ": not live", !TouchpadService.live)
                            t.next()
                        })
                        if (c[1] === null) t.removeFile(then); else t.place(c[1], then)
                    }))
                }
            }),
            function () {
                // Every "shown before" above was a new session (a new since_ms): one notification each.
                t.readToasts(7, function (calls) {
                    t._toastsBefore = t.toasts(calls).length
                    t.eq("one notification per session so far (live, then six more)", t._toastsBefore, 7)
                    t.next()
                })
            },
            function () {
                t.place(t.live(t.hostile, Date.now()), () => t.waitFor("hostile name: shown", t.isShown, function () {
                    const n = t.shownNotice()
                    const name = n ? n.nameItem.text : ""
                    t.check("hostile name: shown", t.isShown())
                    t.eq("hostile name: plain text", n ? n.nameItem.textFormat : -1, Text.PlainText)
                    t.check("hostile name: drawn as the characters it has, not as markup", n && t.drawnPlain(n.nameItem))
                    t.check("hostile name: the markup is there as text", name.indexOf("<b>Evil</b>&amp;<img src=x>") === 0, name.slice(0, 40))
                    t.check("hostile name: no control, zero-width or direction characters",
                            !/[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2066-\u2069]/.test(name))
                    t.check("hostile name: kept to 64 characters", Array.from(name).length <= 64, String(Array.from(name).length))
                    t.check("hostile name: elided inside the notch", n && n.nameItem.truncated)
                    t.check("hostile name: \"· touchpad\" still shows, left of Stop",
                            n && n.suffixItem.text === "· touchpad" && n.suffixItem.width > 0
                            && n.suffixItem.mapToItem(n, n.suffixItem.width, 0).x <= n.stopItem.x + 0.5)
                    t.shoot("touchpad-notice-long-name", () => t.readToasts(t._toastsBefore + 1, function (calls) {
                        const ts = t.toasts(calls)
                        t.eq("hostile name: a notification for the new session", ts.length, t._toastsBefore + 1)
                        const body = ts.length ? ts[ts.length - 1][6] : ""
                        t.check("hostile name: the notification body escapes the markup",
                                body.indexOf("&lt;b&gt;Evil&lt;/b&gt;&amp;amp;&lt;img src=x&gt;") >= 0 && body.indexOf("<") < 0, body.slice(0, 80))
                        t.check("hostile name: the summary is fixed text", ts.length && ts[ts.length - 1][5] === "Phone in use as a touchpad")
                        t.next()
                    }))
                }))
            },
            function () {
                // Stop: the button's own action, as a click or Space gives it.
                const n = t.shownNotice()
                t.check("Stop: the button is there and pressable", n !== null && n.stopItem.interactive)
                if (n) n.stopItem.activated()
                t.check("Stop: says stopping at once", TouchpadService.stopping)
                t.waitFor("Stop: hidden once the daemon says live:false", t.isHidden, function () {
                    t.check("Stop: hidden", t.isHidden())
                    t.check("Stop: no failure shown", !TouchpadService.stopFailed && !TouchpadService.stopping)
                    t.readLog(t.rimeLog, function (calls) {
                        t.eq("Stop: exactly one stop request", t.stops(calls).length, 1)
                        t.eq("Stop: and nothing else about the touchpad", t.touchpadCalls(calls).length, 1)
                        t.check("Stop: no call carries the name",
                                calls.every(a => a.join(" ").indexOf("Evil") < 0 && a.join(" ").indexOf("Pixel") < 0),
                                JSON.stringify(calls).slice(0, 200))
                        t.next()
                    })
                }, 50)
            },
            function () {
                // A daemon that takes the request and does not stop: failure, said.
                t.setMode("ignore", () => t.place(t.live("Pixel 8", Date.now()), () => t.waitFor("again: shown", t.isShown, function () {
                    const n = t.shownNotice()
                    if (n) n.stopItem.activated()
                    t.waitFor("a stop that does not land: failure said", () => TouchpadService.stopFailed, function () {
                        const m = t.shownNotice()
                        const waited = Date.now() - t._pressedAt
                        t.check("a stop that does not land: said within ~3 s", waited >= 2500 && waited <= 4500, waited + " ms")
                        t.check("a stop that does not land: still shown", t.isShown())
                        t.eq("a stop that does not land: says so", m ? m.suffixItem.text : "", "· couldn't stop")
                        t.eq("a stop that does not land: Stop is Retry", m ? m.stopItem.Accessible.name : "", "Try to stop the touchpad again")
                        t.check("a stop that does not land: Retry can be pressed", m && m.stopItem.interactive)
                        // Retry fades back in from the disabled look first.
                        t.after(500, () => t.shoot("touchpad-notice-failed", function () {
                            t.place(t.notLive, () => t.waitFor("stopped later: hidden", t.isHidden, function () {
                                t.check("stopped later: the failure is cleared", !TouchpadService.stopFailed)
                                t.next()
                            }))
                        }))
                    }, 60)
                    t._pressedAt = Date.now()
                })))
            },
            function () {
                // A CLI that fails: failure at once, not after the wait.
                t.setMode("fail", () => t.place(t.live("Pixel 8", Date.now()), () => t.waitFor("fail: shown", t.isShown, function () {
                    t._pressedAt = Date.now()
                    const f = t.shownNotice()
                    t.check("a stop the CLI refuses: the button is there", f !== null)
                    if (f) f.stopItem.activated()
                    t.waitFor("a stop the CLI refuses: failure said", () => TouchpadService.stopFailed, function () {
                        t.check("a stop the CLI refuses: said at once", Date.now() - t._pressedAt < 2000, (Date.now() - t._pressedAt) + " ms")
                        t.place(t.notLive, () => t.waitFor("end: hidden", t.isHidden, function () { t.next() }))
                    }, 40)
                })))
            },
            function () {
                t.readLog(t.rimeLog, function (calls) {
                    t.eq("in all: three stop requests, one per press", t.stops(calls).length, 3)
                    t.check("in all: no rime call carries a name", calls.every(a => a.join(" ").indexOf("Evil") < 0 && a.join(" ").indexOf("Pixel") < 0))
                    t.next()
                })
            }
        ]
        t.next()
    }
    property real _pressedAt: 0
    property int _toastsBefore: 0
    property var _opacities: []
    function sampleDot(n, k, then) {
        if (k <= 0 || !n) { then(); return }
        const dots = t.collect(n, o => o.radius === 4 && o.width === 8 && o.height === 8, [])
        t._opacities = t._opacities.concat([dots.length ? Math.round(dots[0].opacity * 100) / 100 : -1])
        t.after(200, () => t.sampleDot(n, k - 1, then))
    }
}
