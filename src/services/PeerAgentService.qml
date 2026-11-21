pragma Singleton

// ─── PeerAgentService ────────────────────────────────────────────────────────
// The agent sessions on this person's other Rime computers, for the Agent
// Center's "Your computers" section (rime-os docs/remote-live-contract.md
// §2.15, M4). The computers come from ComputersService (`computers list`):
// those that are active, trusted here, and say they let this computer view or
// control their sessions (peeragents.js shares()). For each one this asks
// `rime remote computers agents --json -- <id>`, one computer at a time.
//
// ── When it asks ─────────────────────────────────────────────────────────────
// Only while something holds a ServiceRef (the Agent Center on screen), and a
// sweep never STARTS sooner than ComputersService.pollMs after the last one
// started: the same 30 s on AC / 60 s on battery the computer list itself is
// read at, so this page never dials the other computers faster than the list
// that names them is refreshed. When the last ServiceRef goes, the call in
// flight is killed, the queue is dropped and nothing is re-armed: a hidden
// Agent Center runs nothing.
//
// ── What a computer that does not answer looks like ──────────────────────────
// One quiet line, from peeragents.js hostLine(): "Not reachable right now" for
// anything that is not an answer (asleep, off, busy, a crash), "It no longer
// shares its agents with this computer" when it refused because the claim this
// computer had was stale. The daemon's own words are never shown for a list.
//
// ── Peek and Attach ──────────────────────────────────────────────────────────
// Peek (view or control) runs `computers peek --json -- <id> <session>` once
// and keeps the text for a read-only pane. Attach (control only) opens the
// user's terminal through src/scripts/rime-terminal.sh running
// `rime remote computers attach -- <id> <session>`; the attach itself is the
// CLI's, in that terminal. Both check here, again, that the computer shares at
// the right level and that the session is one it listed: the buttons being
// hidden is not the guard. Nothing here ends, starts or types into a session.
//
// Process behaviour relied on is the one RemoteAgentService.qml measured: a
// binary that cannot exec only drops `running` (the callLater settles below),
// streamFinished comes before exited, and a kill exits 15.
// ─────────────────────────────────────────────────────────────────────────────

import QtQuick
import Quickshell
import Quickshell.Io
import "peeragents.js" as P

Singleton {
    id: root

    //     ServiceRef { service: PeerAgentService; active: root.onScreen }
    property int refCount: 0
    readonly property bool active: root.refCount > 0

    // Longer than the CLI's own 60 s wait for a computer (remote.rs
    // COMPUTER_WAIT), so the CLI's answer normally wins.
    readonly property int queryTimeout: 65000

    // The computers asked, in the list's order. `hostIds` is reassigned only
    // when the set changes, so a Repeater over its length keeps its delegates.
    readonly property var hosts: P.hosts(ComputersService.computers)
    property var hostIds: []
    onHostsChanged: root._hostsChanged()

    // id → {status, sessions, truncated, unreadable}; reassigned whole.
    property var results: ({})
    property string checking: ""     // the computer being asked right now

    // What a row draws for the instant between a shorter list arriving and
    // its Repeater dropping the extra delegate: a finished, nameless session.
    readonly property var blankSession: P.parseSession({ id: 0, exit_code: 0 })

    function host(id) {
        for (let i = 0; i < root.hosts.length; i++)
            if (root.hosts[i].id === id) return root.hosts[i]
        return null
    }
    function resultFor(id) { return root.results[id] || null }
    function hostLine(id) {
        return P.hostLine(root.resultFor(id), root.checking === id || root._queue.indexOf(id) >= 0)
    }
    function sessionsFor(id) {
        const r = root.resultFor(id)
        return P.visible(r && r.status === "ok" ? r.sessions : []).shown
    }
    function hiddenFor(id) {
        const r = root.resultFor(id)
        return P.visible(r && r.status === "ok" ? r.sessions : []).hidden
    }
    function canAttach(id) { return P.canAttach(root.host(id)) }
    function sessionOf(id, session) {
        const r = root.resultFor(id)
        if (!r || r.status !== "ok") return null
        for (let i = 0; i < r.sessions.length; i++)
            if (r.sessions[i].id === session) return r.sessions[i]
        return null
    }

    function _hostsChanged() {
        const ids = root.hosts.map(function (c) { return c.id })
        if (ids.join("\n") === root.hostIds.join("\n")) return
        root.hostIds = ids
        const keep = {}
        for (let i = 0; i < ids.length; i++)
            if (root.results[ids[i]]) keep[ids[i]] = root.results[ids[i]]
        root.results = keep
        if (root.peekFor !== "" && ids.indexOf(root.peekFor) < 0) root.closePeek()
        root._maybeSweep()
    }

    // ── The sweep ────────────────────────────────────────────────────────────
    property var _queue: []
    property real _lastSweepStart: 0
    property bool _sweeping: false

    function _maybeSweep() {
        if (!root.active || root._sweeping || root.hostIds.length === 0) return
        const wait = root._lastSweepStart + ComputersService.pollMs - Date.now()
        if (root._lastSweepStart > 0 && wait > 0) {
            root._cooldown.interval = Math.max(50, wait)
            root._cooldown.restart()
            return
        }
        root._cooldown.stop()
        root._lastSweepStart = Date.now()
        root._sweeping = true
        root._queue = root.hostIds.slice()
        root._next()
    }

    function _next() {
        if (!root.active) { root._standDown(); return }
        if (root._queue.length === 0) {
            root._sweeping = false
            root._maybeSweep()       // re-arms the cooldown while watched
            return
        }
        const id = root._queue[0]
        root._queue = root._queue.slice(1)
        const cmd = P.agentsCommand(id)
        if (!cmd || !root.host(id)) { root._advance.restart(); return }
        root.checking = id
        root._out = ""
        root._queryProc.command = cmd
        root._queryProc.running = true
        root._watchdog.restart()
    }

    property string _out: ""
    function _resolve(code) {
        if (root.checking === "") return
        const id = root.checking
        root.checking = ""
        root._watchdog.stop()
        root._set(id, P.readAgents(code, root._out))
        root._advance.restart()
    }
    function _set(id, r) {
        const next = {}
        const keys = Object.keys(root.results)
        for (let i = 0; i < keys.length; i++) next[keys[i]] = root.results[keys[i]]
        next[id] = r
        root.results = next
    }
    property Process _queryProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._out = this.text }
        stderr: StdioCollector {}
        onExited: function (code) { root._resolve(code) }
        onRunningChanged: if (!running && root.checking !== "") Qt.callLater(function () {
            if (root.checking !== "" && !root._queryProc.running) root._resolve(127)
        })
    }
    // One turn of the event loop between computers, so a late signal from the
    // one just finished cannot land on the next one's slot.
    property Timer _advance: Timer { interval: 30; onTriggered: root._next() }
    property Timer _watchdog: Timer {
        interval: root.queryTimeout
        onTriggered: {
            if (root.checking === "") return
            const id = root.checking
            root.checking = ""                // before the kill: its exit is ignored
            root._queryProc.running = false
            root._set(id, P.readAgents(124, ""))
            root._advance.restart()
        }
    }
    property Timer _cooldown: Timer { interval: 1000; onTriggered: root._maybeSweep() }

    function _standDown() {
        root._cooldown.stop()
        root._advance.stop()
        root._watchdog.stop()
        root._queue = []
        root._sweeping = false
        if (root.checking !== "") {
            root.checking = ""                // the computer keeps its last answer
            root._queryProc.running = false
        }
        root.closePeek()
    }

    onActiveChanged: {
        if (root.active) root._maybeSweep()
        else root._standDown()
    }

    // ── Peek ─────────────────────────────────────────────────────────────────
    property string peekFor: ""
    property int peekSession: -1
    property string peekText: ""
    property string peekError: ""
    property bool peeking: false
    property string _peekOut: ""

    function peekAt(id, session) {
        if (!root.active || !P.shares(root.host(id)) || !root.sessionOf(id, session)) return false
        const cmd = P.peekCommand(id, session)
        if (!cmd) return false
        if (root.peeking) { root.peeking = false; root._peekProc.running = false }
        root.peekFor = id
        root.peekSession = session
        root.peekText = ""
        root.peekError = ""
        root._peekOut = ""
        root.peeking = true
        root._peekProc.command = cmd
        root._peekProc.running = true
        return true
    }
    function closePeek() {
        const was = root.peeking
        root.peeking = false
        if (was) root._peekProc.running = false
        root.peekFor = ""
        root.peekSession = -1
        root.peekText = ""
        root.peekError = ""
    }
    function _peekDone(code) {
        if (!root.peeking) return
        root.peeking = false
        const r = P.readPeek(code, root._peekOut)
        root.peekText = r.text
        root.peekError = r.ok ? "" : r.error
    }
    property Process _peekProc: Process {
        command: []
        running: false
        stdout: StdioCollector { onStreamFinished: root._peekOut = this.text }
        stderr: StdioCollector {}
        onExited: function (code) { root._peekDone(code) }
        onRunningChanged: if (!running && root.peeking) Qt.callLater(function () {
            if (root.peeking && !root._peekProc.running) root._peekDone(127)
        })
    }

    // ── Attach ───────────────────────────────────────────────────────────────
    function attach(id, session) {
        if (!P.canAttach(root.host(id))) return false
        const s = root.sessionOf(id, session)
        if (!s || !P.isLive(s)) return false
        const cmd = P.terminalCommand(Quickshell.shellDir + "/src/scripts/rime-terminal.sh", id, session)
        if (!cmd) return false
        Quickshell.execDetached(cmd)
        return true
    }
}
