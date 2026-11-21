// Agent sessions on this person's other Rime computers: the Agent Center's
// "Your computers" section and the agents rows in Settings → Paired devices,
// against a stub `rime` (tests/run-peer-agents-test.sh writes it, and says what
// each phase proves). Staged at the repo root so "./src/…" resolves;
// RIME_PA_SCENE picks the phase.
import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/theme"
import "./src/services"
import "./src/nexus"

ShellRoot {
    id: root

    readonly property string scene: Quickshell.env("RIME_PA_SCENE") || "centre"
    readonly property string callLog: Quickshell.env("RIME_PA_CALLS") || ""
    readonly property string work: Quickshell.env("RIME_PA_W") || ""
    readonly property string shots: Quickshell.env("RIME_PA_SHOTS") || ""
    readonly property bool settingsScene: root.scene === "settings"

    readonly property string desk: "-DeskAQIDBAUGBwg"
    readonly property string lap: "LaptAQIDBAUGBwgJ"
    readonly property string spare: "SpareAQIDBAUGBwg"
    readonly property string intro: "IntrAQIDBAUGBwgJ"
    readonly property string gone: "GoneAQIDBAUGBwgJ"
    readonly property string away: "AwayAQIDBAUGBwgJ"
    readonly property string stale: "StaleAQIDBAUGBwg"
    readonly property string older: "OlderAQIDBAUGBwg"
    // The hostile session text as a row must show it: every character kept
    // but the escape, the line break, the line separator and the direction
    // override, nothing interpreted.
    readonly property string hostileShown: "$(touch PWNED) <b>bold</b> [31mred [0m line two three evil"

    property int passed: 0
    property int failed: 0
    function check(name, cond) {
        if (cond) { root.passed++; console.warn("  PASS  " + name) }
        else      { root.failed++; console.warn("  FAIL  " + name) }
    }

    // ── Finding things ───────────────────────────────────────────────────────
    function find(obj, name) {
        if (!obj) return null
        if (obj.objectName === name) return obj
        const kids = obj.children
        if (kids)
            for (let i = 0; i < kids.length; i++) {
                const f = root.find(kids[i], name)
                if (f) return f
            }
        return null
    }
    function findAll(obj, name, out) {
        if (!obj) return out
        if (obj.objectName === name) out.push(obj)
        const kids = obj.children
        if (kids)
            for (let i = 0; i < kids.length; i++) root.findAll(kids[i], name, out)
        return out
    }
    function hostRow(id) {
        const all = root.findAll(page, "peerHost", [])
        for (let i = 0; i < all.length; i++)
            if (all[i].computerId === id) return all[i]
        return null
    }
    // The PeerSessionRow for one session of one computer.
    function sessionRow(id, n) {
        const h = root.hostRow(id)
        if (!h) return null
        const out = []
        root._rowsIn(h, out)
        for (let i = 0; i < out.length; i++)
            if (out[i].session && out[i].session.id === n) return out[i]
        return null
    }
    function _rowsIn(obj, out) {
        if (!obj) return
        if (obj.computerId !== undefined && obj.session !== undefined) out.push(obj)
        const kids = obj.children
        if (kids) for (let i = 0; i < kids.length; i++) root._rowsIn(kids[i], out)
    }
    function sessionCount(id) { const out = []; root._rowsIn(root.hostRow(id), out); return out.length }
    function block(id) {
        const all = root.findAll(page, "computerSettings", [])
        for (let i = 0; i < all.length; i++)
            if (all[i].computerId === id) return all[i]
        return null
    }
    function inBlock(id, name) { return root.find(root.block(id), name) }
    function showing(needle, obj) { return root._showing(obj === undefined ? page : obj, needle) }
    function _showing(obj, needle) {
        if (!obj) return false
        if (obj.visible === false) return false
        if (obj.truncated !== undefined && String(obj.text).indexOf(needle) >= 0) return true
        const kids = obj.children
        if (kids)
            for (let i = 0; i < kids.length; i++)
                if (root._showing(kids[i], needle)) return true
        return false
    }
    // Every Text under obj that is visible: their formats, for the plain-text checks.
    function texts(obj, out) {
        if (!obj || obj.visible === false) return out
        if (obj.truncated !== undefined && obj.textFormat !== undefined) out.push(obj)
        const kids = obj.children
        if (kids) for (let i = 0; i < kids.length; i++) root.texts(kids[i], out)
        return out
    }

    // ── Steps ────────────────────────────────────────────────────────────────
    property var steps: []
    property int stepIndex: 0
    function next() {
        if (root.stepIndex >= root.steps.length) {
            console.warn("")
            console.warn("passed=" + root.passed + " failed=" + root.failed)
            Qt.exit(root.failed === 0 ? 0 : 1)
            return
        }
        root.steps[root.stepIndex++]()
    }
    property int _ticks: 0
    property var _cond: null
    property var _then: null
    property string _waitName: ""
    function waitFor(name, cond, then) {
        root._waitName = name
        root._cond = cond
        root._then = then
        root._ticks = 0
        waiter.restart()
    }
    Timer {
        id: waiter
        interval: 50
        repeat: true
        onTriggered: {
            if (root._cond()) {
                stop()
                const t = root._then
                root._then = null
                t()
                return
            }
            if (++root._ticks >= 300) {
                stop()
                root.check("waited for: " + root._waitName, false)
                root.next()
            }
        }
    }
    property var _sleepThen: null
    Timer {
        id: sleeper
        onTriggered: { const t = root._sleepThen; root._sleepThen = null; t() }
    }
    function sleep(ms, then) { root._sleepThen = then; sleeper.interval = ms; sleeper.restart() }

    // ── The stub's records ───────────────────────────────────────────────────
    property var lines: []
    property var _afterRead: null
    property string _readBuf: ""
    readonly property Process catProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._readBuf = this.text }
        onExited: function () {
            const f = root._afterRead
            root._afterRead = null
            if (f) f(root._readBuf)
        }
    }
    function readFile(path, then) {
        root._readBuf = ""
        root._afterRead = then
        catProc.command = ["cat", path]
        catProc.running = true
    }
    property var _afterRun: null
    readonly property Process runProc: Process {
        command: []
        running: false
        onExited: function () { const f = root._afterRun; root._afterRun = null; if (f) f() }
    }
    function setFile(name, text, then) {
        root._afterRun = then
        runProc.command = text === null
            ? ["rm", "-f", root.work + "/" + name]
            : ["sh", "-c", "printf %s \"$1\" > \"$2\"", "sh", text, root.work + "/" + name]
        runProc.running = true
    }
    function readLog(then) {
        root.readFile(root.callLog, function (t) {
            root.lines = t.split("\n").filter(function (l) { return l !== "" })
            then()
        })
    }
    function count(needle) { return root.lines.filter(function (l) { return l.indexOf(needle) >= 0 }).length }
    function ran(exact) { return root.lines.indexOf(exact) >= 0 }
    function agentsLine(id) { return "[remote][computers][agents][--json][--][" + id + "]" }

    function grab(name, then) {
        if (root.shots === "") { then(); return }
        host.grabToImage(function (r) {
            console.warn("  picture " + name + (r.saveToFile(root.shots + "/" + name + ".png") ? " saved" : " NOT SAVED"))
            then()
        })
    }

    // ── The page ─────────────────────────────────────────────────────────────
    FloatingWindow {
        id: win
        implicitWidth: root.settingsScene ? 900 : 760
        implicitHeight: root.settingsScene ? 1500 : 760
        visible: true
        color: Theme.surfaceBase

        Item {
            id: host
            anchors.fill: parent
            Rectangle { anchors.fill: parent; color: Theme.surfaceBase }

            Loader {
                id: centreLoader
                anchors.fill: parent
                anchors.margins: 16
                active: !root.settingsScene
                sourceComponent: Component { AgentCenter { onScreen: false } }
            }
            Loader {
                id: settingsLoader
                anchors.fill: parent
                active: root.settingsScene
                sourceComponent: {
                    const ps = PageRegistry.pages
                    for (let i = 0; i < ps.length; i++)
                        if (ps[i].id === "remote-devices") return ps[i].component
                    return null
                }
            }
        }
    }
    readonly property var page: root.settingsScene ? settingsLoader.item : centreLoader.item

    Component.onCompleted: {
        root.steps = root.settingsScene ? root.settingsSteps() : root.centreSteps()
        root.next()
    }

    function openPage() {
        root.sleep(1000, function () {
            root.readLog(function () {
                // The local AgentService keeps a slow poll at rest by design
                // (`rime agent list`, `rime request pending`); nothing else may run.
                const early = root.lines.filter(function (l) {
                    return l.indexOf("[agent][list]") !== 0 && l.indexOf("[request][pending]") !== 0
                })
                root.check("nothing ran before the page was shown (saw " + early.length + ": " + early.join(" ") + ")",
                           early.length === 0 && root.count("[remote]") === 0)
                page.onScreen = true
                root.next()
            })
        })
    }

    // ── centre ───────────────────────────────────────────────────────────────
    property real _hiddenAt: 0
    property int _linesAtHide: 0

    function centreSteps() { return [
        root.openPage,
        function () {
            root.waitFor("every computer asked once", function () {
                const r = PeerAgentService.results
                return PeerAgentService.hostIds.length === 4 && r[root.desk] && r[root.lap] && r[root.away] && r[root.stale]
            }, root.next)
        },
        function () { root.sleep(500, root.next) },
        function () {
            root.check("the section is there, named", root.find(page, "peerHeading").visible
                       && root.find(page, "peerHeading").text === "Your computers")
            root.check("one row per computer that shares (view or control), in the list's order",
                       PeerAgentService.hostIds.join(",") === [root.desk, root.lap, root.away, root.stale].join(",")
                       && root.findAll(page, "peerHost", []).length === 4)
            root.check("no row for off, for one not allowed yet, or for a removed one",
                       root.hostRow(root.spare) === null && root.hostRow(root.intro) === null
                       && root.hostRow(root.gone) === null)
            root.check("the local session is still there, under This machine",
                       root.showing("This machine") && root.showing("Local work"))
            root.readLog(function () {
                root.check("each was asked with the exact argv, the id after --",
                           root.ran(root.agentsLine(root.desk)) && root.ran(root.agentsLine(root.lap))
                           && root.ran(root.agentsLine(root.away)) && root.ran(root.agentsLine(root.stale)))
                root.check("off, not allowed yet and removed were never asked",
                           root.count("[" + root.spare + "]") === 0 && root.count("[" + root.intro + "]") === 0
                           && root.count("[" + root.gone + "]") === 0)
                root.next()
            })
        },
        function () {
            root.check("the desk's three sessions, live first then latest",
                       root.sessionCount(root.desk) === 3
                       && PeerAgentService.sessionsFor(root.desk).map(function (s) { return s.id }).join(",") === "3,7,2")
            root.check("the laptop's one session", root.sessionCount(root.lap) === 1)
            const row = root.sessionRow(root.desk, 7)
            const name = root.find(row, "peerSessionName")
            root.check("a hostile name is drawn as it came, one line, nothing interpreted (" + (name ? name.text : "none") + ")",
                       name && name.text === root.hostileShown)
            root.check("and as plain text, never rich", name && name.textFormat === Text.PlainText
                       && name.maximumLineCount === 1 && name.lineCount === 1)
            const meta = root.find(row, "peerSessionMeta")
            root.check("its project is plain, one line, with the state word (" + (meta ? meta.text : "none") + ")",
                       meta && meta.text.indexOf(root.hostileShown + "  ·  ") === 0 && meta.text.indexOf("\n") < 0
                       && meta.textFormat === Text.PlainText && meta.lineCount === 1)
            // Every Text in the row that is not plain is a fixed glyph drawn by
            // a shared control (the state badge, an icon button, the tree line),
            // never anything the other computer sent.
            const all = root.texts(root.hostRow(root.desk), [])
            const rich = all.filter(function (t) { return t.textFormat !== Text.PlainText })
            const fixed = rich.every(function (t) { return String(t.text).length <= 2 })
            root.check("every text in the desk's row that carries its words is plain (" + all.length + " texts, "
                       + rich.length + " glyphs: " + rich.map(function (t) { return JSON.stringify(t.text) }).join(" ") + ")",
                       all.length > 5 && fixed)
            root.check("a name without a title or a person's name falls back to its title",
                       root.find(root.sessionRow(root.desk, 3), "peerSessionName").text === "Fixing the tests")
            const awayLine = root.find(root.hostRow(root.away), "peerHostLine")
            const staleLine = root.find(root.hostRow(root.stale), "peerHostLine")
            root.check("an unreachable computer: one quiet line, no sessions",
                       awayLine.text === "Not reachable right now" && root.sessionCount(root.away) === 0
                       && Qt.colorEqual(awayLine.color, Theme.subtext))
            root.check("a stale claim (it refused): one quiet line, never its words",
                       staleLine.text === "It no longer shares its agents with this computer"
                       && root.sessionCount(root.stale) === 0 && Qt.colorEqual(staleLine.color, Theme.subtext)
                       && !root.showing("does not let this computer"))
            root.check("the desk says what it has", root.find(root.hostRow(root.desk), "peerHostLine").text
                       === "3 sessions · 2 running · 1 needs you")
            root.check("what each lets you do is said",
                       root.find(root.hostRow(root.desk), "peerHostLevel").text === "You can work in them"
                       && root.find(root.hostRow(root.lap), "peerHostLevel").text === "You can watch")
            root.next()
        },
        function () {
            const vis = function (id, n, what) { const b = root.find(root.sessionRow(id, n), what); return b !== null && b.visible }
            root.check("Attach is offered with control, for a live session",
                       vis(root.desk, 3, "peerAttach") && vis(root.desk, 7, "peerAttach"))
            root.check("no Attach for a finished session", !vis(root.desk, 2, "peerAttach"))
            root.check("no Attach where it only lets you watch", !vis(root.lap, 5, "peerAttach"))
            root.check("Peek is offered for every session, view or control",
                       vis(root.desk, 3, "peerPeek") && vis(root.desk, 2, "peerPeek") && vis(root.lap, 5, "peerPeek"))
            root.next()
        },

        // Peek.
        function () {
            root.find(root.sessionRow(root.desk, 7), "peerPeek").activated()
            root.waitFor("the peek", function () {
                return PeerAgentService.peekFor === root.desk && !PeerAgentService.peeking && PeerAgentService.peekText !== ""
            }, root.next)
        },
        function () { root.sleep(200, root.next) },
        function () {
            const pane = root.find(root.hostRow(root.desk), "peerPeekPane")
            const text = root.find(pane, "peerPeekText")
            root.check("the peek pane opens under that computer", pane && pane.visible
                       && !root.find(root.hostRow(root.lap), "peerPeekPane").visible)
            root.check("it shows the tail, lines kept, as plain text",
                       text.textFormat === Text.PlainText
                       && text.text === "$ cargo test\nrunning 12 tests\n$(touch PWNED) <b>bold</b> [31mred[0m\nline two three evil\ntest result: ok")
            root.check("its title is plain", root.find(pane, "peerPeekTitle").textFormat === Text.PlainText)
            root.readLog(function () {
                root.check("peek ran with the exact argv",
                           root.ran("[remote][computers][peek][--json][--][" + root.desk + "][7]"))
                root.grab("agent-center-peer", root.next)
            })
        },
        function () {
            root.find(root.hostRow(root.desk), "peerPeekClose").activated()
            root.check("Close closes it", !root.find(root.hostRow(root.desk), "peerPeekPane").visible
                       && PeerAgentService.peekFor === "")
            root.grab("agent-center-peer-closed", root.next)
        },

        // Attach.
        function () {
            root.find(root.sessionRow(root.desk, 3), "peerAttach").activated()
            root.waitFor("the terminal", function () { return true }, function () { root.sleep(600, root.next) })
        },
        function () {
            const v = PeerAgentService.attach(root.lap, 5)
            const f = PeerAgentService.attach(root.desk, 2)
            const u = PeerAgentService.attach(root.desk, 99)
            const i = PeerAgentService.attach(root.intro, 1)
            const p = PeerAgentService.peekAt(root.spare, 1) || PeerAgentService.peekAt(root.desk, 99)
            root.sleep(600, function () {
                root.readLog(function () {
                    root.check("Attach opened the terminal with exactly the attach argv",
                               root.ran("[xdg-terminal-exec][rime][remote][computers][attach][--][" + root.desk + "][3]"))
                    root.check("the service refuses an attach for view, finished, unlisted or not shared, and a peek not shared",
                               !v && !f && !u && !i && !p && root.count("[xdg-terminal-exec]") === 1
                               && root.count("[peek]") === 1)
                    root.next()
                })
            })
        },

        // The pace: repeats while shown, never sooner than the list's interval.
        function () {
            root.readLog(function () {
                const before = root.count(root.agentsLine(root.desk))
                root.sleep(4000, function () {
                    root.readFile(root.work + "/times.log", function (t) {
                        const desk = t.split("\n").filter(function (l) { return l.indexOf(root.desk + " ") === 0 })
                                      .map(function (l) { return Number(l.split(" ")[1]) })
                        let gap = 1e9
                        for (let i = 1; i < desk.length; i++) gap = Math.min(gap, desk[i] - desk[i - 1])
                        root.check("asked again while shown (" + desk.length + " times), never sooner than "
                                   + ComputersService.pollMs + " ms apart, 50 ms of process start allowed (smallest gap " + gap + " ms)",
                                   desk.length >= 3 && gap >= ComputersService.pollMs - 50)
                        root.next()
                    })
                })
            })
        },

        // Hidden while a call is in flight: killed, nothing more runs.
        function () { root.setFile("slow-agents", "1", root.next) },
        function () {
            root.find(root.sessionRow(root.desk, 7), "peerPeek").activated()
            root.waitFor("a slow call to the desk", function () { return PeerAgentService.checking === root.desk },
                         function () { root.sleep(400, root.next) })
        },
        function () {
            page.onScreen = false
            root._hiddenAt = Date.now()
            root.sleep(300, function () {
                root.check("hiding kills the call in flight and closes the peek",
                           !PeerAgentService.active && PeerAgentService.checking === ""
                           && !PeerAgentService._queryProc.running && PeerAgentService.peekFor === ""
                           && !PeerAgentService._cooldown.running)
                root.readLog(function () { root._linesAtHide = root.lines.length; root.next() })
            })
        },
        function () {
            root.sleep(4500, function () {
                root.readLog(function () {
                    const fresh = root.lines.slice(root._linesAtHide)
                    root.check("a hidden Agent Center runs nothing (" + fresh.length + " new: " + fresh.join(" ") + ")",
                               fresh.length === 0 && root.count("[slow-done]") === 0 && root.count("[slow-start]") === 1)
                    root.next()
                })
            })
        },

        // Still hidden, but another page (Settings, Phone) keeps the computer
        // list polling, and a computer starts sharing: the list changes, the
        // section's hosts change, and still no computer is asked.
        function () {
            ComputersService.refCount += 1
            root.setFile("spare-shares", "1", function () {
                root.waitFor("Spare in the hosts while hidden",
                             function () { return PeerAgentService.hostIds.indexOf("SpareAQIDBAUGBwg") >= 0 },
                             function () { root.sleep(2500, root.next) })
            })
        },
        function () {
            root.readLog(function () {
                const fresh = root.lines.slice(root._linesAtHide)
                const asked = fresh.filter(function (l) { return l.indexOf("[agents]") >= 0 || l.indexOf("[peek]") >= 0 })
                root.check("hidden, a changed list asks no computer (" + fresh.length + " list reads, "
                           + asked.length + " asks: " + asked.join(" ") + ")",
                           fresh.length > 0 && asked.length === 0 && PeerAgentService.checking === ""
                           && !PeerAgentService._queryProc.running && !PeerAgentService._cooldown.running)
                ComputersService.refCount -= 1
                root.next()
            })
        }
    ] }

    // ── settings ─────────────────────────────────────────────────────────────
    function settingsSteps() { return [
        root.openPage,
        function () {
            root.waitFor("the computers", function () { return ComputersService.computers.length === 4 }, root.next)
        },
        function () { root.sleep(500, root.next) },
        function () {
            const d = root.inBlock(root.desk, "computerAgents")
            root.check("Its agents on this computer: shown in words", d && d.visible
                       && d.label === "Its agents on this computer" && d.status === "Can work in them")
            root.check("Turn off is offered when it has more than off",
                       root.inBlock(root.desk, "computerAgentsOff").visible)
            const cmds = root.findAll(root.block(root.desk), "computerAgentsCommand", [])
            root.check("the one higher-than-off level it lacks is a terminal command, by id (" + cmds.map(function (c) { return c.text }).join(" | ") + ")",
                       cmds.length === 1 && cmds[0].text === "rime remote computers grant -- " + root.desk + " agents view"
                       && cmds[0].readOnly && cmds[0].textFormat === TextEdit.PlainText)
            const l = root.inBlock(root.lap, "computerAgents")
            const lcmds = root.findAll(root.block(root.lap), "computerAgentsCommand", []).map(function (c) { return c.text })
            root.check("off: no Turn off, and both raises as commands",
                       l.status === "Off" && !root.inBlock(root.lap, "computerAgentsOff").visible
                       && lcmds.join("|") === "rime remote computers grant -- " + root.lap + " agents view|rime remote computers grant -- " + root.lap + " agents control")
            root.check("not allowed yet: it can be turned off, but no raise is offered",
                       root.inBlock(root.intro, "computerAgents").status === "Can watch"
                       && root.inBlock(root.intro, "computerAgentsOff").visible
                       && root.findAll(root.block(root.intro), "computerAgentsCommand", []).length === 0
                       && root.showing("Allow this computer first to let it see your agent sessions.", root.block(root.intro)))
            const can = root.inBlock(root.desk, "computerCanAgents")
            root.check("Your agents on it: its claim, and when it was heard (" + can.description + ")",
                       can.visible && can.status === "Can watch" && can.description.indexOf("Last heard 2m ago.") >= 0)
            root.check("an older rime-remoted (no fields): no agents rows",
                       !root.inBlock(root.older, "computerAgents").visible && !root.inBlock(root.older, "computerCanAgents").visible
                       && !root.inBlock(root.older, "computerAgentsRaise").visible)
            const blk = root.block(root.desk)
            const flick = root._flickIn(page)
            if (flick) flick.contentY = Math.max(0, blk.mapToItem(flick.contentItem, 0, 0).y - 20)
            root.sleep(300, function () { root.grab("settings-agents", root.next) })
        },
        function () {
            root.find(root.block(root.desk), "computerAgentsCopy").press()
            root.sleep(500, function () {
                root.readLog(function () {
                    root.check("Copy hands the command to wl-copy as one argument",
                               root.ran("[wl-copy][--][rime remote computers grant -- " + root.desk + " agents view]"))
                    root.next()
                })
            })
        },
        function () {
            const r = ComputersService.agentsOff(root.lap)
            root.check("lowering one that is already off runs nothing", r === false)
            root.inBlock(root.desk, "computerAgentsOff").press()
            root.waitFor("the grant", function () {
                return ComputersService.busyFor === "" && ComputersService.row(root.desk).agents === "off"
            }, root.next)
        },
        function () { root.sleep(400, root.next) },
        function () {
            root.check("after Turn off it reads Off, offers no Turn off, and both raises",
                       root.inBlock(root.desk, "computerAgents").status === "Off"
                       && !root.inBlock(root.desk, "computerAgentsOff").visible
                       && root.findAll(root.block(root.desk), "computerAgentsCommand", []).length === 2)
            root.check("the CLI's sentence is said", root.inBlock(root.desk, "computerNote").text
                       === "Desk (" + root.desk + ") may not reach your agent sessions here.")
            root.readLog(function () {
                root.check("Turn off ran exactly the grant to off, the id after --",
                           root.ran("[remote][computers][grant][--][" + root.desk + "][agents][off]"))
                const grants = root.lines.filter(function (l) { return l.indexOf("[grant]") >= 0 })
                root.check("no grant but off was ever run, and never --yes (" + grants.length + ")",
                           grants.length === 1 && grants.every(function (l) { return /\[agents\]\[off\]$/.test(l) && l.indexOf("--yes") < 0 }))
                root.next()
            })
        }
    ] }

    function _flickIn(obj) {
        if (!obj) return null
        if (obj.contentY !== undefined && obj.flickableDirection !== undefined) return obj
        const kids = obj.children
        if (kids)
            for (let i = 0; i < kids.length; i++) {
                const f = root._flickIn(kids[i])
                if (f) return f
            }
        return null
    }
}
