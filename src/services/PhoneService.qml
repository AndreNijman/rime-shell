pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "phone.js" as P

// ─── PhoneService ────────────────────────────────────────────────────────────
// The paired phone's Messages, Calls and Photos, for the Dashboard's Phone
// page. Everything goes through `rime remote … --json` (the CLI is the
// stability surface, and under test it is the stub on PATH); parsing is in
// phone.js.
//
// ── Demand ───────────────────────────────────────────────────────────────────
//
//     ServiceRef { service: PhoneService; active: root.onScreen }
//
// The page also holds RemotePairingService, which says which phone is paired
// and whether it is connected. With no holder nothing here runs: no read, no
// timer. A read in flight when the page closes is killed; an ACTION the person
// took (a send, a dial, a hang up, a save) is not, because killing the CLI
// would not stop the phone, only hide what it did.
//
// ── One messages request at a time ───────────────────────────────────────────
//
// The daemon answers `busy` to a second messages request for the same phone
// while one is waiting (contract §2.11), and the request belongs to the
// daemon, not to the CLI: killing a read does not free the phone. So every
// messages verb goes through one lane, one at a time, a send first. Calls and
// photos allow one of each kind at a time, so a read and an action each get
// their own Process.
//
// ── Nothing is kept ──────────────────────────────────────────────────────────
//
// What the phone sent lives in these properties while the page is held, and
// is dropped when it is not. A send is never retried by this service: the
// person sees why it failed and presses Send again. The draft stays in the
// page's field until `sent()`.
// ─────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    property int refCount: 0
    readonly property bool active: root.refCount > 0

    // Which part of the page is showing: messages, calls or photos. Only that
    // part is read.
    property string section: "messages"

    // How often an open section is read again. Long: the phone is asked over
    // the network each time, and a person reading a conversation does not need
    // it re-asked every few seconds. Tests shorten it.
    readonly property int pollMs: {
        const v = parseInt(Quickshell.env("RIME_PHONE_POLL_MS") || "", 10)
        return v > 0 ? v : 30000
    }

    property real nowMs: Date.now()

    // ── The phone ────────────────────────────────────────────────────────────

    readonly property var phone: P.choosePhone(RemotePairingService.devices, RemotePairingService.connectedIds)
    readonly property string pageState: P.pageState(root.phone, RemotePairingService.connectedIds,
        RemotePairingService.devicesChecked && RemotePairingService.statusChecked,
        RemotePairingService.devicesError)
    readonly property var pageMessage: P.pageMessage(root.pageState, root.phone, RemotePairingService.devicesError)
    readonly property string deviceId: root.phone ? root.phone.id : ""
    readonly property bool ready: root.pageState === "ready"

    function offers(feature) { return root.ready && P.offers(root.phone, feature) }
    function offMessage(feature) { return P.offMessage(root.phone, feature) }
    readonly property var callAbilities: P.callAbilities(root.phone)

    // The one thing that says a section should be (re)read: held, showing, and
    // offered by a connected phone. A change to any part reads it again.
    readonly property bool _live: root.active && root.offers(root.section)
    readonly property string _key: root._live ? root.deviceId + "|" + root.section : ""
    on_KeyChanged: {
        if (root._key === "") return
        root.nowMs = Date.now()
        root.refreshSection()
    }

    function refreshSection() {
        if (!root._live) return
        if (root.section === "messages") {
            root._want("threads")
            if (root.openThread) root._want("thread")
        } else if (root.section === "calls") {
            root.readCalls()
        } else if (root.section === "photos") {
            root.readPhotos(false)
        }
    }

    // Messages and calls are read again while open. Photos are not: a new
    // photo is not something a person waits on, and the grid is re-read when
    // the section is opened again.
    property Timer _poll: Timer {
        interval: root.pollMs
        repeat: true
        running: root._live && (root.section === "messages" || root.section === "calls")
        onTriggered: {
            root.nowMs = Date.now()
            root.refreshSection()
        }
    }

    // ── Messages ─────────────────────────────────────────────────────────────

    property var threads: []
    property bool threadsLoaded: false
    property string threadsError: ""

    // The conversation open on the page (one of `threads`), or null.
    property var openThread: null
    property var messages: []
    property bool messagesLoaded: false
    property string messagesError: ""
    // True while the last page read was full, so an older one may exist.
    property bool olderAvailable: false
    property bool loadingOlder: false

    property bool sending: false
    property string sendError: ""
    // Emitted once the phone's network took the message. The page clears its
    // draft on this, and only on this.
    signal sent()

    function openConversation(t) {
        if (!t) return
        root.openThread = t
        root.messages = []
        root.messagesLoaded = false
        root.messagesError = ""
        root.olderAvailable = false
        root.sendError = ""
        root._want("thread")
    }
    function closeConversation() {
        root.openThread = null
        root.messages = []
        root.messagesLoaded = false
        root.messagesError = ""
        root.sendError = ""
        root._queue = root._queue.filter(function (q) { return q.kind !== "thread" && q.kind !== "older" })
    }
    function loadOlder() {
        if (!root.openThread || !root.olderAvailable || root.loadingOlder) return
        root.loadingOlder = true
        root._want("older")
    }

    // Send `text` into the open conversation. Refused here, in words, when the
    // field's text is not something the phone would take; otherwise queued
    // ahead of any read.
    function send(text) {
        if (!root.openThread || root.sending || !root.ready) return false
        if (root.openThread.group) {
            root.sendError = "Replying to a group conversation is not supported. Reply on the phone."
            return false
        }
        const c = P.replyCheck(text)
        if (!c.ok) { root.sendError = c.error; return false }
        root.sending = true
        root.sendError = ""
        root._queue = [{ kind: "send", thread: root.openThread.id, device: root.deviceId, text: c.text }]
            .concat(root._queue.filter(function (q) { return q.kind !== "send" }))
        root._pump()
        return true
    }

    // The lane. Each entry {kind, …}; one Process runs them in turn.
    property var _queue: []
    property var _running: null
    property string _msgOut: ""
    property string _msgErr: ""
    property string _sendText: ""

    function _want(kind) {
        if (root._queue.some(function (q) { return q.kind === kind })) { root._pump(); return }
        root._queue = root._queue.concat([{ kind: kind }])
        root._pump()
    }

    function _pump() {
        if (root._running || root._queue.length === 0) return
        const q = root._queue[0]
        root._queue = root._queue.slice(1)
        let cmd = null
        if (q.kind === "send") {
            cmd = P.sendCommand(q.device, q.thread)
        } else if (!root._live || root.section !== "messages") {
            // A read for a page nobody is looking at: dropped, and the next.
            if (q.kind === "older") root.loadingOlder = false
            root._pump()
            return
        } else if (q.kind === "threads") {
            cmd = P.threadsCommand(root.deviceId)
        } else if (q.kind === "thread" || q.kind === "older") {
            if (!root.openThread) { root._pump(); return }
            q.thread = root.openThread.id
            cmd = P.threadCommand(root.deviceId, q.thread,
                q.kind === "older" && root.messages.length ? root.messages[0].dateMs : 0)
        }
        q.device = q.device || root.deviceId
        root._running = q
        root._msgOut = ""
        root._msgErr = ""
        root._sendText = q.kind === "send" ? q.text : ""
        root._msgProc.stdinEnabled = q.kind === "send"
        root._msgProc.command = cmd
        root._msgProc.running = true
    }

    function _msgDone(code) {
        const q = root._running
        if (!q) return
        root._running = null
        root._sendText = ""
        const what = q.kind === "send" ? "Sending" : "Messages"
        const r = P.outcome(code, root._msgOut, root._msgErr, what)
        // An answer for a phone or a conversation that is no longer the one on
        // the page is dropped (the person switched while it was out).
        const samePhone = q.device === root.deviceId
        const sameThread = root.openThread && q.thread === root.openThread.id
        if (q.kind === "send") {
            root.sending = false
            if (r.ok && r.data.sent === true) {
                root.sendError = ""
                root.sent()
                if (sameThread) root._want("thread")
            } else {
                root.sendError = r.ok ? "The phone did not say it sent the message." : r.error
            }
        } else if (q.kind === "threads") {
            if (samePhone) {
                const t = r.ok ? P.parseThreads(r.data) : null
                root.threadsLoaded = true
                if (t) {
                    root.threads = t.threads
                    root.threadsError = ""
                } else {
                    root.threadsError = r.ok ? "Messages gave an answer this Shell cannot read" : r.error
                }
            }
        } else if (samePhone && sameThread) {
            const m = r.ok ? P.parseThread(r.data) : null
            if (q.kind === "older") {
                root.loadingOlder = false
                if (m) {
                    root.messages = P.prependOlder(m.messages, root.messages)
                    root.olderAvailable = m.received >= P.PAGE_LIMIT
                } else {
                    root.messagesError = r.ok ? "Messages gave an answer this Shell cannot read" : r.error
                }
            } else {
                root.messagesLoaded = true
                if (m) {
                    const first = root.messages.length === 0
                    root.messages = P.mergeMessages(root.messages, m.messages)
                    if (first) root.olderAvailable = m.received >= P.PAGE_LIMIT
                    root.messagesError = ""
                } else {
                    root.messagesError = r.ok ? "Messages gave an answer this Shell cannot read" : r.error
                }
            }
        } else if (q.kind === "older") {
            root.loadingOlder = false
        }
        root._pump()
    }

    property Process _msgProc: Process {
        command: []
        running: false
        stdinEnabled: false
        stdout: StdioCollector { onStreamFinished: root._msgOut = this.text }
        stderr: StdioCollector { onStreamFinished: root._msgErr = this.text }
        // The text goes in on standard input and the pipe is closed, so the CLI
        // reads it to the end. It is never in argv.
        onStarted: {
            if (root._sendText !== "") {
                write(root._sendText)
                root._sendText = ""
                stdinEnabled = false
            }
        }
        onExited: function (code) { root._msgDone(code) }
        // The binary is not there at all: no `exited`, only this.
        onRunningChanged: if (!running && root._running) Qt.callLater(function () {
            if (root._running && !root._msgProc.running) root._msgDone(127)
        })
    }

    // ── Calls ────────────────────────────────────────────────────────────────

    property var current: null
    property var calls: null
    property string historyError: ""
    property bool callsLoaded: false
    property string callsError: ""
    property string _callsOut: ""
    property string _callsErr: ""
    property string _callsDevice: ""

    function readCalls() {
        if (!root._live || root.section !== "calls" || root._callsProc.running) return
        root._callsOut = ""
        root._callsErr = ""
        root._callsDevice = root.deviceId
        root._callsProc.command = P.callsCommand(root.deviceId)
        root._callsProc.running = true
    }
    function _callsDone(code) {
        if (root._callsDevice !== root.deviceId) return
        const r = P.outcome(code, root._callsOut, root._callsErr, "Calls")
        const c = r.ok ? P.parseCalls(r.data) : null
        root.callsLoaded = true
        if (c) {
            root.current = c.current
            root.calls = c.calls
            root.historyError = c.historyError
            root.callsError = ""
        } else {
            root.callsError = r.ok ? "Calls gave an answer this Shell cannot read" : r.error
        }
        root._callsDevice = ""
    }
    property Process _callsProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._callsOut = this.text }
        stderr: StdioCollector { onStreamFinished: root._callsErr = this.text }
        onExited: function (code) { root._callsDone(code) }
        onRunningChanged: if (!running && root._callsDevice !== "") Qt.callLater(function () {
            if (root._callsDevice !== "" && !root._callsProc.running) root._callsDone(127)
        })
    }

    // dial and hangup: one at a time.
    property string callAction: ""      // "dial" or "hangup" while one is out
    property string callActionError: ""
    property string callActionNote: ""
    property string _actOut: ""
    property string _actErr: ""

    // Returns false, with callActionError set, when the field is not a number.
    function dial(text) {
        if (!root.ready || root.callAction !== "" || !root.callAbilities.dial) return false
        const n = P.dialNumber(text)
        if (n === "") {
            root.callActionError = "Type a phone number: digits, with an optional + in front."
            return false
        }
        root._act("dial", P.dialCommand(root.deviceId, n), "Calling " + n + " on " + root.phone.name + ".")
        return true
    }
    function hangup() {
        if (!root.ready || root.callAction !== "" || !root.callAbilities.answer) return
        root._act("hangup", P.hangupCommand(root.deviceId), "Call ended.")
    }
    property string _actDone: ""
    function _act(kind, cmd, done) {
        root.callAction = kind
        root.callActionError = ""
        root.callActionNote = ""
        root._actOut = ""
        root._actErr = ""
        root._actDone = done
        root._actProc.command = cmd
        root._actProc.running = true
    }
    function _actFinished(code) {
        if (root.callAction === "") return
        const r = P.outcome(code, root._actOut, root._actErr, root.callAction === "dial" ? "Dialling" : "Hanging up")
        if (r.ok && r.data.done === true) {
            root.callActionNote = root._actDone
        } else {
            root.callActionError = r.ok ? "The phone did not say it did that." : r.error
        }
        root.callAction = ""
        root.readCalls()
    }
    property Process _actProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._actOut = this.text }
        stderr: StdioCollector { onStreamFinished: root._actErr = this.text }
        onExited: function (code) { root._actFinished(code) }
        onRunningChanged: if (!running && root.callAction !== "") Qt.callLater(function () {
            if (root.callAction !== "" && !root._actProc.running) root._actFinished(127)
        })
    }

    // ── Photos ───────────────────────────────────────────────────────────────

    property var photos: []
    property bool photosPartial: false
    property bool photosLoaded: false
    property string photosError: ""
    property bool morePhotos: false
    property bool loadingMorePhotos: false
    property string _photosOut: ""
    property string _photosErr: ""
    property string _photosDevice: ""
    property bool _photosMore: false

    function readPhotos(more) {
        if (!root._live || root.section !== "photos" || root._photosProc.running) return
        if (more && (!root.morePhotos || root.photos.length === 0)) return
        root._photosOut = ""
        root._photosErr = ""
        root._photosDevice = root.deviceId
        root._photosMore = more
        root.loadingMorePhotos = more
        root._photosProc.command = P.photosCommand(root.deviceId,
            more ? root.photos[root.photos.length - 1].dateMs : 0)
        root._photosProc.running = true
    }
    function _photosDone(code) {
        root.loadingMorePhotos = false
        if (root._photosDevice !== root.deviceId) return
        root._photosDevice = ""
        const r = P.outcome(code, root._photosOut, root._photosErr, "Photos")
        const p = r.ok ? P.parsePhotos(r.data) : null
        root.photosLoaded = true
        if (p) {
            root.photos = root._photosMore ? P.appendOlder(root.photos, p.photos) : p.photos
            root.photosPartial = p.partial
            root.morePhotos = p.received >= P.PAGE_LIMIT
            root.photosError = ""
        } else {
            root.photosError = r.ok ? "Photos gave an answer this Shell cannot read" : r.error
        }
    }
    property Process _photosProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._photosOut = this.text }
        stderr: StdioCollector { onStreamFinished: root._photosErr = this.text }
        onExited: function (code) { root._photosDone(code) }
        onRunningChanged: if (!running && root._photosDevice !== "") Qt.callLater(function () {
            if (root._photosDevice !== "" && !root._photosProc.running) root._photosDone(127)
        })
    }

    // One save at a time. `savingId` is the photo being saved, or -1.
    property real savingId: -1
    property real savedId: -1
    property string savedPath: ""
    property string saveError: ""
    property string _saveOut: ""
    property string _saveErr: ""

    function save(photoId) {
        if (!root.ready || root.savingId >= 0 || P.wholeId(photoId) === null) return
        root.savingId = photoId
        root.savedId = -1
        root.savedPath = ""
        root.saveError = ""
        root._saveOut = ""
        root._saveErr = ""
        root._saveProc.command = P.saveCommand(root.deviceId, photoId)
        root._saveProc.running = true
    }
    function _saveDone(code) {
        if (root.savingId < 0) return
        const r = P.outcome(code, root._saveOut, root._saveErr, "Saving")
        const s = r.ok ? P.parseSaved(r.data) : null
        if (s) {
            root.savedId = root.savingId
            root.savedPath = s.path
        } else {
            root.saveError = r.ok ? "The phone did not say where the photo went." : r.error
        }
        root.savingId = -1
    }
    property Process _saveProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._saveOut = this.text }
        stderr: StdioCollector { onStreamFinished: root._saveErr = this.text }
        onExited: function (code) { root._saveDone(code) }
        onRunningChanged: if (!running && root.savingId >= 0) Qt.callLater(function () {
            if (root.savingId >= 0 && !root._saveProc.running) root._saveDone(127)
        })
    }

    // ── Holding and letting go ───────────────────────────────────────────────

    // A phone that changed under the page (another one paired, this one
    // revoked) takes everything it said with it.
    onDeviceIdChanged: root._forget()

    function _forget() {
        root.threads = []
        root.threadsLoaded = false
        root.threadsError = ""
        root.closeConversation()
        root.current = null
        root.calls = null
        root.historyError = ""
        root.callsLoaded = false
        root.callsError = ""
        root.callActionError = ""
        root.callActionNote = ""
        root.photos = []
        root.photosPartial = false
        root.photosLoaded = false
        root.photosError = ""
        root.morePhotos = false
        root.savedId = -1
        root.savedPath = ""
        root.saveError = ""
    }

    onActiveChanged: {
        if (root.active) return
        // Reads are killed; actions run to the end (see the header).
        root._queue = root._queue.filter(function (q) { return q.kind === "send" })
        if (root._running && root._running.kind !== "send") {
            root._running = null
            root._msgProc.running = false
        }
        root._callsDevice = ""
        root._callsProc.running = false
        root._photosDevice = ""
        root._photosProc.running = false
        root.loadingOlder = false
        root.loadingMorePhotos = false
        // Nothing the phone sent outlives the page.
        root._forget()
    }
}
