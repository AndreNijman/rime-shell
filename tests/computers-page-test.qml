// Your other paired computers on the Dashboard's Phone page and in Settings →
// Paired devices, against a stub `rime` (tests/run-computers-page-test.sh
// writes it, and says what each phase proves). Staged at the repo root so
// "./src/…" resolves; RIME_CP_SCENE picks the phase.
import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/theme"
import "./src/services"
import "./src/nexus"

ShellRoot {
    id: root

    readonly property string scene: Quickshell.env("RIME_CP_SCENE") || "dash"
    readonly property string callLog: Quickshell.env("RIME_CP_CALLS") || ""
    readonly property string stdinLog: Quickshell.env("RIME_CP_STDIN") || ""
    readonly property string work: Quickshell.env("RIME_CP_W") || ""
    readonly property string shots: Quickshell.env("RIME_CP_SHOTS") || ""
    readonly property bool settingsScene: root.scene === "settings"

    readonly property string desk: "-DeskAQIDBAUGBwg"
    readonly property string lap: "LaptAQIDBAUGBwgJ"
    readonly property string intro: "IntrAQIDBAUGBwgJ"
    readonly property string gone: "GoneAQIDBAUGBwgJ"
    // The hostile name as the page must show it: every character kept but the
    // line break and the direction override, nothing interpreted.
    readonly property string hostileShown: "<b>Bold</b> $(touch PWNED) `touch PWNED2` line two gnp.exe"

    property int passed: 0
    property int failed: 0

    function check(name, cond) {
        if (cond) { root.passed++; console.warn("  PASS  " + name) }
        else      { root.failed++; console.warn("  FAIL  " + name) }
    }

    // ── Finding things in the page ───────────────────────────────────────────

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
    // The card (Dashboard) or settings block for one computer.
    function blockFor(id) {
        const all = root.findAll(page, root.settingsScene ? "computerSettings" : "computerCard", [])
        for (let i = 0; i < all.length; i++)
            if (all[i].computerId === id) return all[i]
        return null
    }
    function inBlock(id, name) { return root.find(root.blockFor(id), name) }
    // The CfgSwitch inside a switch row.
    function switchOf(id, which) {
        return root._switchIn(root.inBlock(id, "computerSwitch_" + which))
    }
    function _switchIn(obj) {
        if (!obj) return null
        if (obj !== null && typeof obj.toggle === "function" && obj.checked !== undefined) return obj
        const kids = obj.children
        if (kids)
            for (let i = 0; i < kids.length; i++) {
                const f = root._switchIn(kids[i])
                if (f) return f
            }
        return null
    }
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
    // A visible Text anywhere in `obj` (the page by default) containing `needle`.
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
            if (++root._ticks >= 200) {
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

    // ── The stub's records, and setting up what it answers ──────────────────

    property var lines: []
    property string stdinText: ""
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
        onExited: function () {
            const f = root._afterRun
            root._afterRun = null
            if (f) f()
        }
    }
    // A file in the runner's work dir: `$W/<name>` holds `text` (printf, no
    // shell sees the text: it is an argument), or is removed when text is null.
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
    function readStdin(then) {
        root.readFile(root.stdinLog, function (t) { root.stdinText = t; then() })
    }
    function count(needle) {
        return root.lines.filter(function (l) { return l.indexOf(needle) >= 0 }).length
    }
    function ran(exact) { return root.lines.indexOf(exact) >= 0 }
    readonly property string listLine: "[remote][computers][list][--json]"

    // A picture of the window, when the runner asked for them (RIME_CP_SHOTS).
    function grab(name, then) {
        if (root.shots === "") { then(); return }
        host.grabToImage(function (r) {
            // Not an assertion: the counts must not depend on whether pictures were asked for.
            console.warn("  picture " + name + (r.saveToFile(root.shots + "/" + name + ".png") ? " saved" : " NOT SAVED"))
            then()
        })
    }

    // ── The page ─────────────────────────────────────────────────────────────

    FloatingWindow {
        id: win
        implicitWidth: root.settingsScene ? 900 : 960
        implicitHeight: root.settingsScene ? 1500 : 620
        visible: true
        color: Theme.surfaceBase

        Item {
            id: host
            anchors.fill: parent

            // A grab is of the item, not the window: paint the surface here.
            Rectangle { anchors.fill: parent; color: Theme.surfaceBase }

            Loader {
                id: dashLoader
                anchors.fill: parent
                anchors.margins: root.settingsScene ? 0 : 20
                active: !root.settingsScene
                sourceComponent: Component { PhonePage { onScreen: false } }
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
    readonly property var page: root.settingsScene ? settingsLoader.item : dashLoader.item

    Component.onCompleted: {
        root.steps = root.scene === "dash" ? root.dashSteps()
                   : root.scene === "alone" ? root.aloneSteps()
                   : root.scene === "old" ? root.oldSteps()
                   : root.settingsSteps()
        root.next()
    }

    // Nothing may run before the page is shown: wait, read the log, then open.
    function openPage() {
        root.sleep(1000, function () {
            root.readLog(function () {
                root.check("nothing ran before the page was shown (saw " + root.lines.length + ")",
                           root.lines.length === 0)
                page.onScreen = true
                root.next()
            })
        })
    }
    function settled(name, cond) {
        return function () { root.waitFor(name, cond, root.next) }
    }
    function idle() {
        return ComputersService.busyFor === "" && ComputersService.openingFor === ""
            && ComputersService.sendingFor === "" && ComputersService.pickingFor === ""
            && !ComputersService._listProc.running && !ComputersService._again
    }

    // ── dash ─────────────────────────────────────────────────────────────────

    function dashSteps() { return [
        function () { page.section = "computers"; root.next() },
        root.openPage,
        root.settled("the computers", function () { return ComputersService.paired.length === 3 }),
        function () { root.sleep(400, root.next) },
        function () {
            const cards = root.findAll(page, "computerCard", [])
            root.check("one card per paired computer (saw " + cards.length + ")", cards.length === 3)
            root.check("the removed computer has no card", root.blockFor(root.gone) === null)
            const tabs = root.find(page, "phoneSections")
            root.check("the section tabs offer the phone's three and Computers",
                       tabs.visible && page._sections.map(function (s) { return s.key }).join(",")
                                       === "messages,calls,photos,computers")
            root.check("the header says what is shown", root.find(page, "phoneTitle").text === "Your computers"
                       && root.showing("3 computers · 1 online"))
            root.check("online: the state, when reached, battery and network",
                       root.inBlock(root.desk, "computerStatus").text === "Online · Reached 2m ago · Battery 80%, charging · Wi-Fi")
            root.check("asleep: said, with when it was last reached",
                       root.inBlock(root.lap, "computerStatus").text === "Asleep or out of reach · Reached 1h ago")
            root.check("introduced: not allowed yet, by whom, and where to allow it",
                       root.inBlock(root.intro, "computerStatus").text.indexOf("Not allowed yet") === 0
                       && root.inBlock(root.intro, "computerIntroduced").visible
                       && root.inBlock(root.intro, "computerIntroduced").text
                          === "Added by Pixel 8. Allow it in Settings, Paired devices.")
            root.check("a paired computer has no introduced line", !root.inBlock(root.desk, "computerIntroduced").visible)
            const name = root.inBlock(root.intro, "computerName")
            root.check("the hostile name is shown as it came, one line, nothing interpreted",
                       name.text === root.hostileShown)
            root.check("the hostile name is plain text, never rich", name.textFormat === Text.PlainText
                       && name.maximumLineCount === 1 && name.lineCount === 1)
            root.readLog(function () {
                root.check("the list was read with its exact argv", root.ran(root.listLine))
                root.check("the phone was asked for no section while Computers shows" + (root.count("[messages]") ? " (" + root.lines.join(" ") + ")" : ""), root.count("[messages]") === 0)
                root.grab("dash-computers", root.next)
            })
        },

        // Open link there, with an https link on the clipboard.
        function () { root.setFile("clip", "https://example.org/a?b=c#d", root.next) },
        function () {
            root.inBlock(root.desk, "computerOpenLink").press()
            root.waitFor("the link to be shown", function () {
                return ComputersService.openingFor === "" && ComputersService.noteOf(root.desk) !== ""
            }, root.next)
        },
        function () {
            root.check("the other computer's answer is said",
                       root.inBlock(root.desk, "computerNote").text === "Showing the link on Desk. Someone there has to open it.")
            root.readStdin(function () {
                root.check("the clipboard's link went in on standard input",
                           root.stdinText === "https://example.org/a?b=c#d\n<<END>>\n")
                root.readLog(function () {
                    root.check("open ran with the id after -- and - for stdin",
                               root.ran("[remote][computers][open][--json][--][-DeskAQIDBAUGBwg][-]"))
                    root.check("the link is in no argv", root.count("example.org") === 0)
                    root.next()
                })
            })
        },

        // The same for the computer with the hostile name: the clipboard script
        // runs for it, and its answer names it as plain text.
        function () {
            root.inBlock(root.intro, "computerOpenLink").press()
            root.waitFor("its answer", function () {
                return ComputersService.openingFor === "" && ComputersService.noteOf(root.intro) !== ""
            }, root.next)
        },
        function () {
            const note = root.inBlock(root.intro, "computerNote")
            root.check("its \"off\" answer is said, naming it as plain text (" + note.text + ")",
                       note.text === root.hostileShown + " does not take links from this computer. Turn on \"Take its links\" "
                                     + "for this computer there, or allow this computer there first."
                       && note.textFormat === Text.PlainText)
            root.readLog(function () {
                root.check("open ran for it with its id after --, the link on stdin",
                           root.ran("[remote][computers][open][--json][--][" + root.intro + "][-]")
                           && root.count("example.org") === 0)
                root.next()
            })
        },

        // Not a link on the clipboard: ftp://, then a password manager's copy.
        function () { root.setFile("clip", "ftp://example.org/x", root.next) },
        function () {
            root.inBlock(root.lap, "computerOpenLink").press()
            root.waitFor("the field instead", function () { return ComputersService.linkWanted === root.lap }, root.next)
        },
        function () {
            root.check("an ftp:// clipboard asks for a link instead",
                       root.inBlock(root.lap, "computerLinkField").visible
                       && root.inBlock(root.lap, "computerNote").text.indexOf("There is no link on the clipboard") === 0)
            root.setFile("clip", "javascript:alert(1)", root.next)
        },
        function () {
            ComputersService.cancelLink()
            root.inBlock(root.lap, "computerOpenLink").press()
            root.waitFor("the field again", function () { return ComputersService.linkWanted === root.lap }, root.next)
        },
        function () { root.setFile("clip", "https://bank.example/reset?token=secret", root.next) },
        function () { root.setFile("clip-hint", "1", root.next) },
        function () {
            ComputersService.cancelLink()
            root.inBlock(root.lap, "computerOpenLink").press()
            root.waitFor("the field for a password copy", function () { return ComputersService.linkWanted === root.lap }, root.next)
        },
        function () {
            root.readLog(function () {
                root.check("javascript: and a password manager's copy ran no open",
                           root.count("[open]") === 2 && root.count("bank.example") === 0)
                root.next()
            })
        },

        // A list read changes what is known, never which card is which: the
        // card, and a link half typed into it, are still there after reads.
        function () {
            const card = root.blockFor(root.lap)
            root.inBlock(root.lap, "computerLinkField").text = "https://example.org/half"
            root.readLog(function () {
                const before = root.count(root.listLine)
                root.sleep(1800, function () {
                    root.readLog(function () {
                        root.check("after " + (root.count(root.listLine) - before) + " list reads the card is the same one, the half-typed link kept",
                                   root.count(root.listLine) - before >= 2 && root.blockFor(root.lap) === card
                                   && root.inBlock(root.lap, "computerLinkField").text === "https://example.org/half")
                        root.next()
                    })
                })
            })
        },

        // A typed link: ftp refused with nothing run, then https on stdin.
        function () {
            const f = root.inBlock(root.lap, "computerLinkField")
            f.text = "ftp://example.org/typed"
            root.inBlock(root.lap, "computerLinkSend").press()
            root.sleep(400, function () {
                root.check("a typed ftp:// link is refused, saying why",
                           root.inBlock(root.lap, "computerNote").text === "Only http:// and https:// links can be opened on another computer.")
                root.readLog(function () {
                    root.check("and nothing ran for it", root.count("[open]") === 2)
                    f.text = "https://example.org/typed path"
                    root.inBlock(root.lap, "computerLinkSend").press()
                    root.sleep(300, function () {
                        root.check("a link with a space is refused", root.inBlock(root.lap, "computerNote").text === "A link has no spaces in it.")
                        f.text = "https://example.org/typed"
                        root.inBlock(root.lap, "computerLinkSend").press()
                        root.waitFor("the typed link", function () {
                            return ComputersService.openingFor === "" && ComputersService.noteOf(root.lap).indexOf("waiting") >= 0
                        }, root.next)
                    })
                })
            })
        },
        function () {
            root.check("the other computer's busy answer is said",
                       root.inBlock(root.lap, "computerNote").text === "Laptop already has links from this computer waiting. Try again in a moment.")
            root.check("the field stays for another try", root.inBlock(root.lap, "computerLinkField").visible)
            root.readStdin(function () {
                root.check("the typed link went in on standard input, alone",
                           root.stdinText === "https://example.org/a?b=c#d\n<<END>>\nhttps://example.org/a?b=c#d\n<<END>>\n"
                                              + "https://example.org/typed\n<<END>>\n")
                root.readLog(function () {
                    root.check("open ran for the laptop with its id after --",
                               root.ran("[remote][computers][open][--json][--][LaptAQIDBAUGBwgJ][-]"))
                    root.check("the typed link is in no argv", root.count("typed") === 0)
                    root.inBlock(root.lap, "computerLinkCancel").press()
                    root.next()
                })
            })
        },

        // Send file…: the dialog, then the send.
        function () { root.setFile("pick", "/home/test/My Report.pdf", root.next) },
        function () {
            root.check("Send file… is offered when a file dialog exists", root.inBlock(root.desk, "computerSendFile").visible)
            root.inBlock(root.desk, "computerSendFile").press()
            root.waitFor("the send", function () {
                return ComputersService.sendingFor === "" && ComputersService.pickingFor === ""
                    && ComputersService.noteOf(root.desk).indexOf("Downloads") >= 0
            }, root.next)
        },
        function () {
            root.check("the CLI's sentence about the send is shown",
                       root.inBlock(root.desk, "computerNote").text === "Desk has My Report.pdf and saved it in its Downloads.")
            root.readLog(function () {
                root.check("the dialog ran with its argv",
                           root.ran("[zenity][--file-selection][--title][Choose a file to send][--filename]["
                                    + Quickshell.env("HOME") + "/]"))
                root.check("send ran with the id after -- and the path as one argument",
                           root.ran("[remote][computers][send][--][-DeskAQIDBAUGBwg][/home/test/My Report.pdf]"))
                root.next()
            })
        },

        // The list is read again while the page shows, never once it closes.
        function () {
            root.readLog(function () {
                const before = root.count(root.listLine)
                root.sleep(2600, function () {
                    root.readLog(function () {
                        const during = root.count(root.listLine) - before
                        root.check("the list is read again while the page shows (" + during + " in 2.6 s)", during >= 2)
                        page.onScreen = false
                        root.sleep(400, root.next)
                    })
                })
            })
        },
        function () {
            root.readLog(function () {
                const closed = root.lines.length
                root.sleep(2600, function () {
                    root.readLog(function () {
                        root.check("nothing runs once the page is hidden (" + (root.lines.length - closed) + " new)",
                                   root.lines.length === closed && !ComputersService.active
                                   && !ComputersService._poll.running)
                        root.next()
                    })
                })
            })
        }
    ] }

    // ── alone: no phone paired ───────────────────────────────────────────────

    function aloneSteps() { return [
        root.openPage,
        root.settled("the computers", function () {
            return ComputersService.paired.length === 3 && PhoneService.pageState === "none"
        }),
        function () { root.sleep(400, root.next) },
        function () {
            root.check("Computers is the whole page", page.shown === "computers"
                       && root.findAll(page, "computerCard", []).length === 3)
            root.check("with no tabs", !root.find(page, "phoneSections").visible)
            root.check("and no \"No phone paired\" over it", !root.find(page, "phonePageState").visible)
            root.check("the header names what is shown", root.find(page, "phoneTitle").text === "Your computers")
            root.check("a daemon without handoff cards: no Open link there, Send file still offered",
                       ComputersService.find(root.desk).handoff === null
                       && !root.inBlock(root.desk, "computerOpenLink").visible
                       && root.inBlock(root.desk, "computerSendFile").visible)
            root.grab("dash-computers-no-phone", root.next)
        }
    ] }

    // ── old: a rime with no `computers` verb ─────────────────────────────────

    function oldSteps() { return [
        root.openPage,
        root.settled("the phone and the computers read", function () {
            return ComputersService.checked && PhoneService.pageState === "ready"
        }),
        function () { root.sleep(400, root.next) },
        function () {
            root.check("no computers", ComputersService.computers.length === 0 && root.findAll(page, "computerCard", []).length === 0)
            root.check("the tabs are the phone's own three",
                       page._sections.map(function (s) { return s.key }).join(",") === "messages,calls,photos")
            root.check("the phone's page shows as before", page.shown === "messages" && root.find(page, "phoneTitle").text === "Pixel 8")
            root.check("no error from the older rime is shown", !root.showing("unrecognized") && !root.showing("computers exited"))
            root.readLog(function () {
                root.check("the list was asked for", root.ran(root.listLine))
                root.next()
            })
        }
    ] }

    // ── settings ─────────────────────────────────────────────────────────────

    // Toggle one switch and wait for the re-read; `then` gets the switch.
    function toggleAndSettle(id, which, then) {
        const sw = root.switchOf(id, which)
        const before = sw.checked
        sw.toggle()
        root.waitFor(which + " on " + id, function () {
            return root.idle() && ComputersService.noteOf(id) !== ""
        }, function () { root.sleep(150, function () { then(root.switchOf(id, which), before, sw) }) })
    }
    function switchStep(id, which, wantLine, wantChecked) {
        return function () {
            root.toggleAndSettle(id, which, function (sw, before, old) {
                root.readLog(function () {
                    root.check(which + " on " + id + " runs " + wantLine, root.ran(wantLine))
                    root.check("and the switch, the same one, shows what the daemon now says",
                               sw === old && sw.checked === wantChecked)
                    root.next()
                })
            })
        }
    }

    function settingsSteps() { return [
        root.openPage,
        root.settled("the computers and the phone", function () {
            return ComputersService.computers.length === 4 && RemotePairingService.devices.length === 1
        }),
        function () { root.sleep(500, root.next) },
        function () {
            const rows = root.findAll(page, "computerSettings", [])
            root.check("a block per computer, removed included (saw " + rows.length + ")", rows.length === 4)
            root.check("the removed one says so, with nothing to do",
                       root.showing("removed", root.blockFor(root.gone))
                       && !root.inBlock(root.gone, "computerRemove").visible
                       && !root.inBlock(root.gone, "computerSendFile").visible
                       && !root.inBlock(root.gone, "computerSwitch_files").visible)
            root.check("the online one shows its presence",
                       root.inBlock(root.desk, "computerPresence").text === "Battery 80%, charging · Wi-Fi")
            const introFiles = root.inBlock(root.intro, "computerSwitch_files")
            root.check("an introduced computer's switches are off, saying why",
                       introFiles.unavailable && root.showing("Allow this computer first.", introFiles)
                       && root.inBlock(root.intro, "computerSwitch_clipboard_send").unavailable
                       && root.inBlock(root.intro, "computerSwitch_handoff").unavailable)
            root.check("its daemon-side switches read off (untrusted gets nothing)",
                       !root.switchOf(root.intro, "files").checked && !root.switchOf(root.intro, "clipboard_send").checked)
            root.check("the reached line keeps Rime Remote's capitals",
                       root.showing("·  not reached since Rime Remote started", root.blockFor(root.intro))
                       && root.showing("·  reached 2m ago", root.blockFor(root.desk)))
            root.check("only the introduced one offers Allow",
                       root.inBlock(root.intro, "computerAllow").visible && !root.inBlock(root.desk, "computerAllow").visible)
            const name = root.inBlock(root.intro, "computerName")
            root.check("the hostile name is plain text on one line here too",
                       name.text === root.hostileShown && name.textFormat === Text.PlainText && name.lineCount === 1)
            root.check("the phone is still listed above", root.showing("Pixel 8"))
            root.grab("settings-devices", root.next)
        },
        // A second picture, scrolled to the introduced and the removed one.
        function () {
            if (root.shots === "") { root.next(); return }
            const flick = root._flickIn(page)
            const blk = root.blockFor(root.intro)
            flick.contentY = Math.max(0, blk.mapToItem(flick.contentItem, 0, 0).y - 20)
            root.sleep(300, function () {
                root.grab("settings-devices-introduced", function () {
                    flick.contentY = 0
                    root.next()
                })
            })
        },

        // The four switches, each its exact command. Desk starts send off,
        // receive off, files on, links off; the laptop starts with all on.
        root.switchStep(root.desk, "clipboard_send", "[remote][computers][clipboard][--][-DeskAQIDBAUGBwg][send]", true),
        root.switchStep(root.desk, "clipboard_receive", "[remote][computers][clipboard][--][-DeskAQIDBAUGBwg][on]", true),
        root.switchStep(root.desk, "files", "[remote][computers][files][--][-DeskAQIDBAUGBwg][off]", false),
        root.switchStep(root.desk, "handoff", "[remote][computers][handoff][--][-DeskAQIDBAUGBwg][on]", true),
        root.switchStep(root.lap, "clipboard_send", "[remote][computers][clipboard][--][LaptAQIDBAUGBwgJ][receive]", false),
        root.switchStep(root.lap, "clipboard_receive", "[remote][computers][clipboard][--][LaptAQIDBAUGBwgJ][off]", false),

        // A change made while a list read that began before it is running:
        // that read's answer is stale, so the list is read once more.
        function () { root.setFile("slow-list", "1", function () { root.sleep(900, root.next) }) },
        // Past one poll, so the read now running is a slow one.
        root.settled("a slow list read in flight", function () { return ComputersService._listProc.running }),
        function () {
            root.switchOf(root.desk, "handoff").toggle()
            root.waitFor("the switch command", function () {
                return ComputersService.busyFor === "" && ComputersService.noteOf(root.desk) !== ""
            }, function () { root.setFile("slow-list", null, root.next) })
        },
        root.settled("the reads after it", root.idle),
        function () {
            root.check("a switch changed during an older list read shows the change once it ends",
                       root.switchOf(root.desk, "handoff").checked === false
                       && ComputersService.find(root.desk).handoff === false)
            root.next()
        },

        // A refused switch: the CLI's sentence, and the switch snaps back.
        function () { root.setFile("refuse-switch", "1", root.next) },
        function () {
            root.toggleAndSettle(root.desk, "files", function (sw, before) {
                root.check("a refused switch shows the CLI's own sentence",
                           root.inBlock(root.desk, "computerNote").text
                           === "a scheduled-job request cannot change a paired computer. Do it from a terminal or Rime Settings.")
                root.check("and snaps back to what the daemon says", sw.checked === false && before === false)
                root.setFile("refuse-switch", null, root.next)
            })
        },

        // An introduced computer's switch runs nothing even when driven.
        function () {
            root.switchOf(root.intro, "files").toggle()
            root.switchOf(root.intro, "clipboard_receive").toggle()
            root.sleep(500, function () {
                root.readLog(function () {
                    root.check("switches on a computer not allowed yet run nothing",
                               root.count("[IntrAQIDBAUGBwgJ]") === 0)
                    root.next()
                })
            })
        },

        // Allow.
        function () {
            root.inBlock(root.intro, "computerAllow").press()
            root.waitFor("allow", function () {
                return root.idle() && ComputersService.find(root.intro) && ComputersService.find(root.intro).trusted
            }, function () { root.sleep(200, root.next) })
        },
        function () {
            root.readLog(function () {
                root.check("Allow runs allow with the id after --", root.ran("[remote][computers][allow][--][IntrAQIDBAUGBwgJ]"))
                root.check("then its switches are offered and Allow is gone",
                           !root.inBlock(root.intro, "computerSwitch_files").unavailable
                           && !root.inBlock(root.intro, "computerAllow").visible)
                root.check("the CLI's sentence is shown, as plain text",
                           root.inBlock(root.intro, "computerNote").text.indexOf("is allowed") > 0
                           && root.inBlock(root.intro, "computerNote").textFormat === Text.PlainText)
                root.next()
            })
        },

        // Remove: one click arms, a refusal is said, then it removes.
        function () { root.setFile("refuse-remove", "1", root.next) },
        function () {
            const b = root.inBlock(root.lap, "computerRemove")
            b.press()
            root.sleep(400, function () {
                root.readLog(function () {
                    root.check("the first click on Remove only asks to confirm",
                               root.inBlock(root.lap, "computerRemove") === b
                               && b.label === "Click to confirm" && root.count("[remove]") === 0)
                    b.press()
                    root.waitFor("the refused removal", function () {
                        return root.idle() && ComputersService.noteOf(root.lap) !== ""
                    }, function () { root.sleep(200, root.next) })
                })
            })
        },
        function () {
            root.check("a refused removal shows the CLI's own sentence",
                       root.inBlock(root.lap, "computerNote").text
                       === "a scheduled-job request cannot remove a paired computer. Remove it from a terminal or Rime Settings.")
            root.check("and the computer stays", ComputersService.find(root.lap).active
                       && root.inBlock(root.lap, "computerRemove").visible)
            root.setFile("refuse-remove", null, root.next)
        },
        function () {
            const b = root.inBlock(root.lap, "computerRemove")
            b.press()
            b.press()
            root.waitFor("the removal", function () {
                return root.idle() && ComputersService.find(root.lap) && !ComputersService.find(root.lap).active
            }, function () { root.sleep(200, root.next) })
        },
        function () {
            root.readLog(function () {
                root.check("Remove runs remove with the id after --", root.ran("[remote][computers][remove][--][LaptAQIDBAUGBwgJ]"))
                root.check("the removed computer says removed and offers nothing",
                           root.showing("removed", root.blockFor(root.lap))
                           && !root.inBlock(root.lap, "computerRemove").visible
                           && !root.inBlock(root.lap, "computerSwitch_files").visible)
                root.check("no command ever named a computer without -- before it",
                           root.lines.filter(function (l) {
                               return l.indexOf("[remote][computers]") === 0 && l.indexOf("[list]") < 0
                                   && l.indexOf("[--]") < 0
                           }).length === 0)
                root.next()
            })
        }
    ] }
}
