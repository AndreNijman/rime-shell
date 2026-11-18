// The Dashboard's Phone page against a stub `rime` (tests/run-phone-page-test.sh
// writes it, and says what each phase proves). Staged at the repo root so
// "./src/…" resolves; RIME_PH_SCENE picks the phase.
import Quickshell
import Quickshell.Io
import QtQuick
import "./src"
import "./src/theme"
import "./src/services"

ShellRoot {
    id: root

    readonly property string scene: Quickshell.env("RIME_PH_SCENE") || "full"
    readonly property string callLog: Quickshell.env("RIME_PH_CALLS") || ""
    readonly property string stdinLog: Quickshell.env("RIME_PH_STDIN") || ""
    readonly property string devArg: "[--device=-PhoneAQIDBAUGBwg]"

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
    // A visible Text anywhere in the page containing `needle`.
    function showing(needle) {
        return root._showing(page, needle)
    }
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

    // ── The stub's records ───────────────────────────────────────────────────

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
    function run(cmd, then) {
        root._afterRun = then
        runProc.command = cmd
        runProc.running = true
    }
    function stdinCount(needle) { return root.stdinText.split(needle).length - 1 }

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

    // ── The page ─────────────────────────────────────────────────────────────

    Item {
        width: 900
        height: 640
        visible: true
        PhonePage {
            id: page
            anchors.fill: parent
            onScreen: false
        }
    }

    Component.onCompleted: {
        root.steps = root.scene === "full" ? root.fullSteps()
                   : root.scene === "off" ? root.offSteps()
                   : root.scene === "offline" ? root.offlineSteps()
                   : root.scene === "none" ? root.noneSteps()
                   : root.errorSteps()
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

    // ── full ─────────────────────────────────────────────────────────────────

    function fullSteps() { return [
        root.openPage,
        root.settled("the conversation list", function () { return PhoneService.threads.length === 3 }),
        function () {
            root.check("the header names the phone", root.find(page, "phoneTitle").text === "Pixel 8")
            root.check("the header says connected, battery and network",
                       root.showing("Connected · Battery 62%, charging · Wi-Fi, signal 3/4"))
            root.check("a contact's conversation shows its name", root.showing("Test Name"))
            root.check("a conversation with no contact shows its number", root.showing("+15555215557"))
            root.check("the snippet shows", root.showing("see you at 6"))
            root.check("the unread count shows", root.find(page, "phoneThread_7").Accessible.name.indexOf("2 unread") >= 0)
            root.readLog(function () {
                root.check("the list was asked for with --device=ID as one argument",
                           root.ran("[remote][messages][--json]" + root.devArg + "[--limit][30]"))
                root.check("no argument is a bare device id", root.count("][-PhoneAQIDBAUGBwg]") === 0)
                root.next()
            })
        },
        function () {
            root.find(page, "phoneThread_7").activated()
            root.waitFor("the conversation", function () { return PhoneService.messages.length === 30 }, root.next)
        },
        function () {
            root.check("the conversation is titled", root.find(page, "phoneConversationTitle").text === "Test Name")
            root.check("messages read down, oldest first", PhoneService.messages[0].body === "message 0"
                       && PhoneService.messages[29].body === "message 29")
            root.check("a full page offers older messages", root.find(page, "phoneOlder").visible === true)
            root.find(page, "phoneOlder").press()
            root.waitFor("the older page", function () { return PhoneService.messages.length === 35 }, root.next)
        },
        function () {
            root.check("the older page goes in front", PhoneService.messages[0].body === "older 0")
            root.readLog(function () {
                root.check("the older page asked --before the oldest shown",
                           root.ran("[remote][messages][--json]" + root.devArg + "[--thread][7][--limit][30][--before][1789154000000]"))
                root.next()
            })
        },
        function () {
            // A send the phone's network refuses: the draft stays, and why.
            const reply = root.find(page, "phoneReply")
            reply.text = "NOSIGNAL test"
            root.find(page, "phoneSend").press()
            root.check("the draft stays while the send is out",
                       PhoneService.sending === true && reply.text === "NOSIGNAL test")
            root.waitFor("the refused send", function () { return !PhoneService.sending }, root.next)
        },
        function () {
            root.check("a refused send says why, in the daemon's words",
                       root.showing("Pixel 8 could not send it: no mobile signal."))
            root.check("a refused send keeps the draft", root.find(page, "phoneReply").text === "NOSIGNAL test")
            root.readLog(function () {
                root.check("a refused send is not retried", root.count("[send]") === 1)
                root.next()
            })
        },
        function () {
            // A reply that looks like options, and one with a newline.
            const reply = root.find(page, "phoneReply")
            reply.text = "--thread 9 on my way"
            root.check("Send is enabled with text in the box", root.find(page, "phoneSend").enabled)
            root.find(page, "phoneSend").press()
            root.waitFor("the send", function () { return !PhoneService.sending && reply.text === "" }, root.next)
        },
        function () {
            root.check("the draft is cleared once the phone took it", root.find(page, "phoneReply").text === "")
            PhoneService.send("line one\nline two")
            root.waitFor("the second send", function () { return !PhoneService.sending }, root.next)
        },
        function () {
            root.readStdin(function () {
                root.check("the first reply reached standard input exactly",
                           root.stdinText.indexOf("NOSIGNAL test\n<<END>>\n--thread 9 on my way\n<<END>>") === 0)
                root.check("the second reply kept its newline on standard input",
                           root.stdinText.indexOf("line one\nline two\n<<END>>") > 0)
                root.readLog(function () {
                    root.check("the send's argv is the device, the thread and --json, nothing else",
                               root.count("[remote][messages][send]" + root.devArg + "[--thread][7][--json]") === 3
                               && root.count("[send]") === 3)
                    root.check("no reply text is in any argv",
                               root.count("NOSIGNAL") === 0 && root.count("on my way") === 0 && root.count("line one") === 0 && root.count("line two") === 0)
                    root.next()
                })
            })
        },
        function () {
            root.find(page, "phoneThread_9").activated()
            root.waitFor("the group conversation", function () {
                return PhoneService.openThread && PhoneService.openThread.id === 9 && PhoneService.messagesLoaded
            }, root.next)
        },
        function () {
            root.check("a group has no reply box", root.find(page, "phoneReply").visible === false)
            root.check("a group says to reply on the phone", root.showing("Replying to a group conversation is not supported"))
            root.check("a group refuses a send in the service too", PhoneService.send("hi") === false)
            page.section = "calls"
            root.waitFor("the calls", function () { return PhoneService.callsLoaded }, root.next)
        },
        function () {
            root.check("the call now: ringing, with the caller",
                       root.find(page, "phoneCurrentCallState").text === "Ringing: Test Name (+15555215556)")
            root.check("Hang up is offered", root.find(page, "phoneHangup").visible)
            root.check("two recent calls", root.find(page, "phoneCallList").count === 2)
            root.check("a missed call is labelled", root.showing("Missed"))
            root.check("a call's length in the CLI's words", root.showing("1m 15s"))
            const n = root.find(page, "phoneDialNumber")
            n.text = "555-CALL"
            root.find(page, "phoneDial").press()
            root.check("a number with letters is refused by the field", root.showing("Type a phone number"))
            n.text = "+1 (555) 521-5556"
            root.find(page, "phoneDial").press()
            root.waitFor("the dial", function () { return PhoneService.callAction === "" && PhoneService.callActionNote !== "" }, root.next)
        },
        function () {
            root.check("the dial is confirmed in words", root.showing("Calling +15555215556 on Pixel 8."))
            root.find(page, "phoneHangup").press()
            root.waitFor("the hang up", function () { return PhoneService.callAction === "" && PhoneService.callActionNote === "Call ended." }, root.next)
        },
        function () {
            // The poll: at 700 ms the list is read again while the page is open.
            root.sleep(1600, function () {
                root.readLog(function () {
                    root.check("only the clean number was dialled, as the last argument",
                               root.ran("[remote][calls][dial]" + root.devArg + "[--json][+15555215556]")
                               && root.count("[dial]") === 1)
                    root.check("hang up ran", root.ran("[remote][calls][hangup]" + root.devArg + "[--json]"))
                    root.check("the calls list is read again while open (" + root.count("[remote][calls][--json]") + " reads)",
                               root.count("[remote][calls][--json]") >= 3)
                    root.next()
                })
            })
        },
        function () {
            page.section = "photos"
            root.waitFor("the photos", function () { return PhoneService.photosLoaded }, root.next)
        },
        function () {
            root.check("two photos in the grid", root.find(page, "phonePhotoGrid").count === 2)
            root.check("the newest photo first", PhoneService.photos[0].id === 6)
            root.check("the partial-access note shows", root.find(page, "phonePhotosPartial").visible)
            const thumbs = root.findAll(page, "phonePhotoThumb", [])
            root.check("each preview is drawn from its file",
                       thumbs.length === 2 && thumbs.every(function (t) {
                           return String(t.source).indexOf("file://") === 0 && String(t.source).indexOf("/rime-remote/photos/") > 0
                       }))
            root.find(page, "phonePhoto_5").activated()
            root.check("the picked photo is named with its size", root.showing("IMG_0005.jpg · 2.4 MB"))
            root.find(page, "phoneSave").press()
            root.waitFor("the save", function () { return PhoneService.savedPath !== "" }, root.next)
        },
        function () {
            root.check("the saved path is shown", root.showing("Saved to ") && root.showing("/Pictures/Rime Remote/IMG_0005.jpg"))
            root.readLog(function () {
                root.check("save ran with the id and the device",
                           root.ran("[remote][photos][save][5]" + root.devArg + "[--json]"))
                root.check("photos were listed once (no poll)", root.count("[remote][photos][--json]") === 1)
                root.next()
            })
        },
        function () {
            // A send pressed while a read is out queues behind it (one
            // messages request per phone). Closing the page then must not
            // strand it: it goes out once, now, and never on a later open.
            page.section = "messages"
            root.run(["touch", root.callLog + ".slow"], function () {
                PhoneService.openConversation(PhoneService.threads[0])
                root.sleep(300, function () {
                    root.find(page, "phoneReply").text = "queued behind a read"
                    root.find(page, "phoneSend").press()
                    root.check("the send waits behind the read",
                               PhoneService.sending && PhoneService._running !== null
                               && PhoneService._running.kind !== "send")
                    page.onScreen = false
                    root.waitFor("the queued send after close", function () { return !PhoneService.sending }, root.next)
                })
            })
        },
        function () {
            root.readStdin(function () {
                root.check("the queued send went out once, after the page closed",
                           root.stdinCount("queued behind a read") === 1)
                root.run(["rm", "-f", root.callLog + ".slow"], root.next)
            })
        },
        function () {
            root.readLog(function () {
                const before = root.lines.length
                root.sleep(2500, function () {
                    root.readLog(function () {
                        root.check("nothing ran after the page closed (" + before + " then " + root.lines.length + ")",
                                   root.lines.length === before)
                        root.check("no poll timer runs while the page is closed", PhoneService._poll.running === false)
                        root.check("what the phone sent is gone once the page closed",
                                   PhoneService.threads.length === 0 && PhoneService.messages.length === 0
                                   && PhoneService.photos.length === 0 && PhoneService.calls === null)
                        root.next()
                    })
                })
            })
        },
        function () {
            page.onScreen = true
            root.waitFor("the list again", function () { return PhoneService.threads.length === 3 }, root.next)
        },
        function () {
            root.sleep(1000, function () {
                root.readStdin(function () {
                    root.check("reopening sends nothing again", root.stdinCount("queued behind a read") === 1)
                    page.onScreen = false
                    root.next()
                })
            })
        }
    ] }

    // ── off ──────────────────────────────────────────────────────────────────

    function offSteps() { return [
        root.openPage,
        root.settled("the phone", function () { return PhoneService.pageState === "ready" }),
        function () {
            root.sleep(500, function () {
                root.check("messages off names the switch",
                           root.showing("Messages is off on Pixel 8") && root.showing("\"Messages on your computer\""))
                page.section = "calls"
                root.sleep(500, function () {
                    root.check("calls off names the switch",
                               root.showing("Calls is off on Pixel 8") && root.showing("\"Calls on your computer\""))
                    page.section = "photos"
                    root.sleep(500, function () {
                        root.check("photos off names the switch and the lock",
                                   root.showing("Photos is off on Pixel 8") && root.showing("\"Photos on your computer\"")
                                   && root.showing("unlock Rime Remote"))
                        root.readLog(function () {
                            root.check("the phone was asked nothing",
                                       root.count("[messages]") + root.count("[calls]") + root.count("[photos]") === 0)
                            root.next()
                        })
                    })
                })
            })
        }
    ] }

    // ── offline / none / error ───────────────────────────────────────────────

    function offlineSteps() { return [
        root.openPage,
        root.settled("the page state", function () { return PhoneService.pageState === "offline" }),
        function () {
            root.sleep(500, function () {
                root.check("not connected is said, with the phone's name", root.showing("Pixel 8 is not connected"))
                root.check("the header says not connected", root.showing("Not connected · Battery 62%"))
                root.check("no sections are offered", root.find(page, "phoneSections").visible === false)
                root.readLog(function () {
                    root.check("the phone was asked nothing",
                               root.count("[messages]") + root.count("[calls]") + root.count("[photos]") === 0)
                    root.next()
                })
            })
        }
    ] }

    function noneSteps() { return [
        root.openPage,
        root.settled("the page state", function () { return PhoneService.pageState === "none" }),
        function () {
            root.check("no phone paired is said", root.showing("No phone paired"))
            root.check("it says where to pair one", root.showing("Pair a device"))
            root.next()
        }
    ] }

    function errorSteps() { return [
        root.openPage,
        root.settled("the refusal", function () { return PhoneService.threadsError !== "" }),
        function () {
            root.check("the refusal is shown in its own words",
                       root.showing("Pixel 8 did not answer in time. Is Rime Remote open on it?"))
            root.check("no conversation is invented", root.find(page, "phoneThreadList").count === 0)
            root.next()
        }
    ] }
}
