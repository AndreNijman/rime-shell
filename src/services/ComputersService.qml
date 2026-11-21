pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "computers.js" as C

// ─── ComputersService ────────────────────────────────────────────────────────
// This person's other Rime computers, for the Dashboard's Phone page and
// Settings → Paired devices. Everything goes through `rime remote computers …`
// (the CLI is the stability surface, and under test it is the stub on PATH);
// parsing and every argv are in computers.js.
//
// ── Demand ───────────────────────────────────────────────────────────────────
//
//     ServiceRef { service: ComputersService; active: root.onScreen }
//
// With no holder nothing here runs: no list, no timer. A page that becomes
// visible reads the list at once, and again every pollMs while it stays
// visible (slower on battery). The daemon itself only refreshes a computer's
// presence every 5 minutes on AC and 15 on battery, so this never needs to be
// quick. A list read in flight when the last page closes is killed.
//
// ── Actions ──────────────────────────────────────────────────────────────────
//
// One at a time: a switch, allow or remove, each re-reading the list after,
// so the page shows what the daemon now says rather than what was asked. A
// refused switch therefore snaps back by itself. A file send and a link have
// their own Process each (a send can take minutes). An action the person took
// is never killed when the page closes: killing the CLI would not stop the
// other computer, only hide what it did.
//
// ── Nothing from the other computer reaches a shell ──────────────────────────
//
// Every command is an argv array from computers.js with the computer's id as
// one argument after "--". The only `sh -c` is computers.js's constant
// clipboard script, which gets the id as $1. A link typed into the page goes
// in on standard input. Names are display-only, as plain text.
//
// ── The clipboard ────────────────────────────────────────────────────────────
//
// Nothing here watches it. PhoneClipboardService's one `wl-paste --watch`
// hands every copy to `rime remote clipboard`, and rime-remoted itself passes
// a copy a person made on to each computer whose "send" switch is on (rime-os
// rime-remoted/src/share.rs, local_copy). So a computer gets this computer's
// copies only while "Send my clipboard to my phone" is on; the pages say so.
// ─────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    property int refCount: 0
    readonly property bool active: root.refCount > 0

    // How often a visible page reads the list again (computers.js
    // pollInterval: 30 s on AC, 60 s on battery). Tests shorten it.
    readonly property int pollMs: C.pollInterval(Quickshell.env("RIME_COMPUTERS_POLL_MS"), UPower.onBattery)

    property real nowMs: Date.now()

    // Every computer the daemon listed (removed ones included), and the ones
    // still paired. Empty, and quietly so, when the CLI has no `computers`
    // verb or the daemon is not running.
    property var computers: []
    readonly property var paired: C.paired(root.computers)
    // The same, by id, for a page's rows: reassigned only when which
    // computers there are changes, so a read that changes what is known about
    // one updates its row (through row()) rather than rebuilding every row.
    property var computerIds: []
    property var pairedIds: []
    property bool checked: false
    readonly property string summary: C.summary(root.computers, root.nowMs)

    function find(id) {
        for (let i = 0; i < root.computers.length; i++)
            if (root.computers[i].id === id) return root.computers[i]
        return null
    }
    // A row's computer, never null: in the moment between a read dropping a
    // computer and its row going, the row reads a blank one.
    readonly property var _blank: C.parseComputers('[{"id":"0000","name":"","revoked_ms":1}]')[0]
    function row(id) { return root.find(id) || root._blank }

    function stateOf(c) { return C.stateOf(c, root.nowMs) }
    function reachedLine(c) { return C.reachedLine(c, root.nowMs) }
    function presenceLine(c) { return C.presenceLine(c ? c.presence : null) }
    function introducedLine(c) { return c ? C.introducedLine(c) : "" }

    // ── Reading the list ─────────────────────────────────────────────────────

    function refresh() {
        if (!root.active) return
        // A read already running may have started before what just changed:
        // read once more when it ends, so the page never keeps its answer.
        if (root._listProc.running) { root._again = true; return }
        root._again = false
        root.nowMs = Date.now()
        root._listOut = ""
        root._listProc.command = C.LIST_COMMAND
        root._listProc.running = true
    }

    property string _listOut: ""
    property bool _listing: false
    property bool _again: false
    function _listDone(code) {
        if (!root._listing) return
        root._listing = false
        root.nowMs = Date.now()
        if (!root.active) { root.checked = true; return }
        const list = (code === 0 ? C.parseComputers(root._listOut) : null) || []
        root.computers = list
        const ids = list.map(function (c) { return c.id })
        const pids = C.paired(list).map(function (c) { return c.id })
        if (ids.join("\n") !== root.computerIds.join("\n")) root.computerIds = ids
        if (pids.join("\n") !== root.pairedIds.join("\n")) root.pairedIds = pids
        // Last: a page deciding what to show on `checked` sees the list with it
        // (the Phone page would otherwise flick to Messages and ask the phone).
        root.checked = true
        if (root._again) root._againTimer.restart()
    }
    property Process _listProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._listOut = this.text }
        stderr: StdioCollector {}
        onStarted: root._listing = true
        onExited: function (code) { root._listDone(code) }
        onRunningChanged: if (!running && root._listing) Qt.callLater(function () {
            if (root._listing && !root._listProc.running) root._listDone(127)
        })
    }

    // The read once more, a moment after the one that ended (its process is
    // then gone, so refresh() starts a new one rather than waiting on it).
    property Timer _againTimer: Timer { interval: 50; onTriggered: root.refresh() }

    property Timer _poll: Timer {
        interval: root.pollMs
        repeat: true
        running: root.active
        onTriggered: root.refresh()
    }

    onActiveChanged: {
        if (root.active) {
            root.refresh()
            if (root._pickTool === "" && !root._probe.running) root._probe.running = true
            return
        }
        root._listing = false
        root._again = false
        root._listProc.running = false
    }

    // ── What the last action said, per computer ──────────────────────────────

    property string noteFor: ""
    property string note: ""
    property bool noteOk: false
    function _say(id, out) {
        root.noteFor = id
        root.note = out.text
        root.noteOk = out.ok
    }
    function noteOf(id) { return root.noteFor === id ? root.note : "" }

    // ── Switches, allow, remove: one lane ────────────────────────────────────

    property string busyFor: ""     // the computer an action is running for
    property string busyKind: ""    // "clipboard_send" … "allow", "remove"
    property string _actOut: ""
    property string _actErr: ""
    property string _actFallback: ""

    function setSwitch(id, which, on) {
        const c = root.find(id)
        if (!c || !c.trusted) return false
        return root._act(id, which, C.switchCommand(c, which, on), "Changed.")
    }
    function allow(id) {
        const c = root.find(id)
        if (!c || !c.needsAllow) return false
        return root._act(id, "allow", C.allowCommand(id), "Allowed.")
    }
    function remove(id) {
        const c = root.find(id)
        if (!c || !c.active) return false
        return root._act(id, "remove", C.removeCommand(id), "Removed.")
    }

    function _act(id, kind, cmd, fallback) {
        if (!cmd || root.busyFor !== "") return false
        root.busyFor = id
        root.busyKind = kind
        root.noteFor = ""
        root._actOut = ""
        root._actErr = ""
        root._actFallback = fallback
        root._actProc.command = cmd
        root._actProc.running = true
        return true
    }
    function _actDone(code) {
        if (root.busyFor === "") return
        const id = root.busyFor
        root.busyFor = ""
        root.busyKind = ""
        root._say(id, C.actionOutcome(code, root._actErr, root._actFallback))
        root.refresh()
    }
    property Process _actProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._actOut = this.text }
        stderr: StdioCollector { onStreamFinished: root._actErr = this.text }
        onExited: function (code) { root._actDone(code) }
        onRunningChanged: if (!running && root.busyFor !== "") Qt.callLater(function () {
            if (root.busyFor !== "" && !root._actProc.running) root._actDone(127)
        })
    }

    // ── Open a link there ────────────────────────────────────────────────────
    //
    // openFromClipboard: the clipboard's text goes when it is an http(s) link
    // (the Shell never holds it). When it is not one, `linkWanted` names the
    // computer, and the page shows a field whose text goes to openLink().

    property string openingFor: ""
    property string linkWanted: ""
    property string _openOut: ""
    property string _openErr: ""
    property string _openUrl: ""
    property string _openName: ""
    property bool _openFromClip: false

    function openFromClipboard(id) {
        const c = root.find(id)
        if (!c || !c.active || root.openingFor !== "") return false
        return root._open(c, C.clipboardOpenCommand(id), "", true)
    }
    function openLink(id, text) {
        const c = root.find(id)
        if (!c || !c.active || root.openingFor !== "") return false
        const k = C.linkCheck(text)
        if (!k.ok) { root._say(id, { ok: false, text: k.error }); return false }
        return root._open(c, C.openCommand(id), k.url, false)
    }
    function cancelLink() { root.linkWanted = "" }

    function _open(c, cmd, url, fromClip) {
        if (!cmd) return false
        root.openingFor = c.id
        root.noteFor = ""
        root._openOut = ""
        root._openErr = ""
        root._openUrl = url
        root._openName = c.name
        root._openFromClip = fromClip
        root._openProc.stdinEnabled = url !== ""
        root._openProc.command = cmd
        root._openProc.running = true
        return true
    }
    function _openDone(code) {
        if (root.openingFor === "") return
        const id = root.openingFor
        root.openingFor = ""
        root._openUrl = ""
        if (root._openFromClip && code === C.NO_LINK_EXIT) {
            root.linkWanted = id
            return
        }
        const out = C.openOutcome(code, root._openOut, root._openErr, root._openName)
        if (out.ok) root.linkWanted = ""
        root._say(id, out)
    }
    property Process _openProc: Process {
        command: []
        running: false
        stdinEnabled: false
        stdout: StdioCollector { onStreamFinished: root._openOut = this.text }
        stderr: StdioCollector { onStreamFinished: root._openErr = this.text }
        // The link goes in on standard input and the pipe is closed. Never argv.
        onStarted: {
            if (root._openUrl !== "") {
                write(root._openUrl)
                root._openUrl = ""
                stdinEnabled = false
            }
        }
        onExited: function (code) { root._openDone(code) }
        onRunningChanged: if (!running && root.openingFor !== "") Qt.callLater(function () {
            if (root.openingFor !== "" && !root._openProc.running) root._openDone(127)
        })
    }

    // ── Send a file ──────────────────────────────────────────────────────────
    //
    // pickAndSend: zenity's or kdialog's file dialog (whichever is installed;
    // `canPick` is false with neither), then `computers send`. sendPath: a path
    // typed where there is no dialog. The dialog and the send run whether or
    // not a page is open, so the Dashboard can close itself out of the
    // dialog's way.

    readonly property bool canPick: root._pickTool !== ""
    property string _pickTool: ""
    property Process _probe: Process {
        command: C.PICKER_PROBE
        running: false
        stdout: StdioCollector {
            onStreamFinished: root._pickTool = String(this.text).trim().split("\n")[0] || ""
        }
    }

    property string pickingFor: ""
    property string _pickOut: ""
    function pickAndSend(id) {
        const c = root.find(id)
        if (!c || !c.active || !root.canPick || root.pickingFor !== "" || root.sendingFor !== "") return false
        const cmd = C.pickCommand(root._pickTool, Quickshell.env("HOME") || "")
        if (!cmd) return false
        root.pickingFor = id
        root._pickOut = ""
        root._pickProc.command = cmd
        root._pickProc.running = true
        return true
    }
    function _pickDone() {
        if (root.pickingFor === "") return
        const id = root.pickingFor
        root.pickingFor = ""
        const p = C.pickedPath(root._pickOut)
        if (p !== "") root.sendPath(id, p)
    }
    property Process _pickProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._pickOut = this.text }
        onExited: function () { root._pickDone() }
        onRunningChanged: if (!running && root.pickingFor !== "") Qt.callLater(function () {
            if (root.pickingFor !== "" && !root._pickProc.running) root._pickDone()
        })
    }

    property string sendingFor: ""
    property string sendingName: ""
    property string _sendErr: ""
    function sendPath(id, path) {
        const c = root.find(id)
        if (!c || !c.active || root.sendingFor !== "") return false
        const cmd = C.sendCommand(id, String(path || "").trim())
        if (!cmd) {
            root._say(id, { ok: false, text: "Give the whole path of the file, starting with /." })
            return false
        }
        root.sendingFor = id
        root.sendingName = C.baseName(path)
        root.noteFor = ""
        root._sendErr = ""
        root._sendProc.command = cmd
        root._sendProc.running = true
        return true
    }
    function _sendDone(code) {
        if (root.sendingFor === "") return
        const id = root.sendingFor
        root.sendingFor = ""
        root._say(id, C.actionOutcome(code, root._sendErr, "Sent " + root.sendingName + "."))
        root.sendingName = ""
    }
    property Process _sendProc: Process {
        command: []
        running: false
        stdout: StdioCollector {}
        stderr: StdioCollector { onStreamFinished: root._sendErr = this.text }
        onExited: function (code) { root._sendDone(code) }
        onRunningChanged: if (!running && root.sendingFor !== "") Qt.callLater(function () {
            if (root.sendingFor !== "" && !root._sendProc.running) root._sendDone(127)
        })
    }
}
