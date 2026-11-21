// ─── peeragents.js ───────────────────────────────────────────────────────────
// The agent sessions on this person's other Rime computers, for the Agent
// Center: which computers to ask, what `rime remote computers agents --json`
// and `… peek --json` answered, turned into what a row shows, and the argv the
// Shell may run. No I/O and no Theme or Quickshell: data in, data out, so
// `node` drives all of it (tests/peer-agents-test.js), as with computers.js.
//
// ── Which computers ──────────────────────────────────────────────────────────
//
// `rime remote computers list --json` (read by ComputersService, parsed by
// computers.js) gives each computer `can_agents`: what THAT computer says it
// lets this one do with its agent sessions (off, view, control). It is a
// claim, learned the last time this computer dialed it, so a listing can be
// refused when the claim is stale; that is one quiet line, never an error.
// Only an active, trusted computer (paired with a code, or introduced and then
// allowed here) whose claim is view or control is asked. An introduced one not
// yet allowed is not asked whatever it claims.
//
// ── The shapes it reads ──────────────────────────────────────────────────────
//
// `computers agents <id> --json` (rime-os rimed/rime/src/remote.rs,
// computers_agents): {id, name, sessions: [SessionInfo…], truncated,
// unreadable}, exit 0. A refusal or an unreachable computer: {"error": "…"},
// exit 1. Read from each session (rime_agent_core::protocol::SessionInfo),
// field by field:
//
//   id             u32; the only session field ever put in argv
//   agent          adapter id ("claude", "codex", …)
//   name, title    what a person called it, the agent's own terminal title
//   project_name   project for display, when known
//   cwd            its working directory there
//   state          starting|working|waiting_for_user|permission_request|
//                  complete|failed|exited (anything else is read as exited
//                  or starting, by whether it has exited)
//   exit_code, exit_signal   null while it runs
//   started, last_activity   seconds since the epoch
//   attached       how many terminals are attached there
//
// `computers peek <id> <session> --json`: {id, name, session, text, cols,
// rows, state}; the CLI has already taken every escape sequence out of `text`.
//
// ── Everything here came from another machine ────────────────────────────────
//
// rime-remoted makes every text field plain where it is received (agents.rs,
// plain_session), and this file does it again: control characters, line and
// paragraph separators and bidi controls become a space, and each field is
// capped. A row shows them as Text.PlainText, one line, elided. Nothing from a
// session reaches a command line except its number, checked to be a u32, and
// the computer's id, checked to be base64url, each its own argument after "--".
// ─────────────────────────────────────────────────────────────────────────────

"use strict"

// The closed set of a grant, lowest first.
var LEVELS = ["off", "view", "control"]

function level(v) { return LEVELS.indexOf(v) >= 0 ? v : null }
function rank(v) { return LEVELS.indexOf(v) }

// The words a page shows for a level.
var LEVEL_WORDS = { off: "Off", view: "Can watch", control: "Can work in them" }
function levelWord(v) { return LEVEL_WORDS[v] || "" }

// The same test as computers.js validId (copied: this file stays loadable by
// node alone).
function validId(v) {
    return typeof v === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(v)
}

function validSession(n) {
    return typeof n === "number" && isFinite(n) && Math.floor(n) === n && n >= 0 && n <= 4294967295
}

// A parsed computer (computers.js) whose agents this one may list there.
function shares(c) {
    return !!c && c.active === true && c.trusted === true && validId(c.id)
        && (c.canAgents === "view" || c.canAgents === "control")
}
function canAttach(c) { return shares(c) && c.canAgents === "control" }

function hosts(list) {
    return (list || []).filter(shares)
}

// ── Text from another machine ────────────────────────────────────────────────

var STRIP = /[\u0000-\u001f\u007f-\u009f\u2028\u2029\u200e\u200f\u202a-\u202e\u2066-\u2069]/g

function plain(v, cap) {
    if (typeof v !== "string") return ""
    var s = v.replace(STRIP, " ").replace(/\s+/g, " ").trim()
    var n = cap || 120
    return s.length > n ? s.slice(0, n) + "…" : s
}
function plainOrNull(v, cap) {
    var s = plain(v, cap)
    return s === "" ? null : s
}

// A peek's text: lines kept (a tab becomes spaces), everything else plain, at
// most PEEK_LINES lines of at most PEEK_COLS characters, the last ones.
var PEEK_LINES = 14
var PEEK_COLS = 240
function peekText(v) {
    if (typeof v !== "string") return ""
    var lines = v.replace(/\r\n?/g, "\n").replace(/\t/g, "    ").split("\n").map(function (l) {
        var s = l.replace(STRIP, " ").replace(/\s+$/, "")
        return s.length > PEEK_COLS ? s.slice(0, PEEK_COLS) + "…" : s
    })
    while (lines.length > 0 && lines[lines.length - 1].trim() === "") lines.pop()
    return lines.slice(-PEEK_LINES).join("\n")
}

// ── Sessions ─────────────────────────────────────────────────────────────────

var STATES = ["starting", "working", "waiting_for_user", "permission_request", "complete", "failed", "exited"]

function intOrNull(v) {
    return typeof v === "number" && isFinite(v) && Math.floor(v) === v ? v : null
}
function secs(v) {
    return typeof v === "number" && isFinite(v) && v > 0 ? v : 0
}

function parseSession(s) {
    if (!s || typeof s !== "object" || Array.isArray(s) || !validSession(s.id)) return null
    var exitCode = intOrNull(s.exit_code)
    var exitSignal = intOrNull(s.exit_signal)
    var live = exitCode === null && exitSignal === null
    var state = STATES.indexOf(s.state) >= 0 ? s.state : (live ? "starting" : "exited")
    var attached = intOrNull(s.attached)
    return {
        id: s.id,
        agent: plain(s.agent, 40),
        name: plainOrNull(s.name, 120),
        title: plainOrNull(s.title, 120),
        project_name: plainOrNull(s.project_name, 80),
        cwd: plain(s.cwd, 240),
        state: state,
        exit_code: exitCode,
        exit_signal: exitSignal,
        started: secs(s.started),
        last_activity: secs(s.last_activity),
        attached: attached !== null && attached > 0 ? attached : 0
    }
}

function isLive(s) { return !!s && s.exit_code === null && s.exit_signal === null }

// Live first, then most recently active: the Agent Center's own order.
function sortSessions(list) {
    return (list || []).slice().sort(function (a, b) {
        var al = isLive(a), bl = isLive(b)
        if (al !== bl) return al ? -1 : 1
        return (b.last_activity || 0) - (a.last_activity || 0)
    })
}

// What a row is called: a person's name, then the agent's title, then the
// adapter (agentstate.js's order). Already plain.
function sessionLabel(s) {
    if (!s) return ""
    return s.name || s.title || ""
}

// Where it runs, for the row: the project, else the last part of its cwd.
function where(s) {
    if (!s) return ""
    if (s.project_name) return s.project_name
    var parts = String(s.cwd || "").replace(/\/+$/, "").split("/")
    return parts[parts.length - 1] || ""
}

// ── What `computers agents --json` answered ──────────────────────────────────
//
// {status, sessions, truncated, unreadable}. status: "ok"; "stopped" (it
// refused: the claim this computer had was stale); "away" (anything else: it
// was not reached, was busy, or the answer was not one).
var REFUSED_LIST = /does not let this computer see its agent sessions/

function readAgents(code, stdout) {
    var o = null
    try { o = JSON.parse(String(stdout || "")) } catch (e) { o = null }
    if (code === 0 && o && typeof o === "object" && !Array.isArray(o) && Array.isArray(o.sessions)) {
        var out = []
        for (var i = 0; i < o.sessions.length && out.length < 200; i++) {
            var s = parseSession(o.sessions[i])
            if (s) out.push(s)
        }
        return {
            status: "ok",
            sessions: sortSessions(out),
            truncated: o.truncated === true,
            unreadable: intOrNull(o.unreadable) || 0
        }
    }
    var said = o && typeof o === "object" && typeof o.error === "string" ? o.error : ""
    return { status: REFUSED_LIST.test(said) ? "stopped" : "away", sessions: [], truncated: false, unreadable: 0 }
}

// At most SESSION_CAP rows a computer; the rest are counted.
var SESSION_CAP = 6
function visible(sessions) {
    var all = sessions || []
    return { shown: all.slice(0, SESSION_CAP), hidden: Math.max(0, all.length - SESSION_CAP) }
}

// The one line under a computer's name. Never an error colour, never the
// daemon's own words: a computer that is asleep is the usual state of one.
function hostLine(result, checking) {
    if (!result) return checking ? "Checking…" : "Not checked yet"
    if (result.status === "stopped") return "It no longer shares its agents with this computer"
    if (result.status === "away") return "Not reachable right now"
    var all = result.sessions || []
    var live = all.filter(isLive).length
    var needs = all.filter(function (s) {
        return isLive(s) && (s.state === "waiting_for_user" || s.state === "permission_request")
    }).length
    var parts = []
    if (all.length === 0) parts.push("No agent sessions")
    else {
        parts.push(all.length === 1 ? "1 session" : all.length + " sessions")
        if (live > 0) parts.push(live + " running")
        if (needs > 0) parts.push(needs === 1 ? "1 needs you" : needs + " need you")
    }
    if (result.truncated || result.unreadable > 0) parts.push("some were left out")
    return parts.join(" · ")
}

// ── What `computers peek --json` answered ────────────────────────────────────

function readPeek(code, stdout) {
    var o = null
    try { o = JSON.parse(String(stdout || "")) } catch (e) { o = null }
    if (code === 0 && o && typeof o === "object" && !Array.isArray(o) && typeof o.text === "string")
        return { ok: true, text: peekText(o.text), error: "" }
    var said = o && typeof o === "object" && typeof o.error === "string" ? plain(o.error, 300) : ""
    return { ok: false, text: "", error: said || "Could not read it. The computer may be asleep or off." }
}

// ── The argv ─────────────────────────────────────────────────────────────────
//
// Options first, then "--", then the computer's id and the session's number:
// an id may begin with "-", and nothing after "--" is an option. These three
// need a person at this machine (rime-remoted's §7 local-origin rule); the
// Shell's own processes run in the login session, so they count, and the
// terminal Attach opens is started from the Shell, so the attach in it does too.

function agentsCommand(id) {
    return validId(id) ? ["rime", "remote", "computers", "agents", "--json", "--", id] : null
}
function peekCommand(id, session) {
    return validId(id) && validSession(session)
        ? ["rime", "remote", "computers", "peek", "--json", "--", id, String(session)] : null
}
function attachCommand(id, session) {
    return validId(id) && validSession(session)
        ? ["rime", "remote", "computers", "attach", "--", id, String(session)] : null
}
// The attach, in the user's terminal, through the Shell's one terminal
// launcher (src/scripts/rime-terminal.sh), which passes it on as argv.
function terminalCommand(launcher, id, session) {
    var a = attachCommand(id, session)
    if (!a || typeof launcher !== "string" || launcher === "") return null
    return ["sh", launcher].concat(a)
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        LEVELS: LEVELS,
        PEEK_LINES: PEEK_LINES,
        SESSION_CAP: SESSION_CAP,
        level: level,
        rank: rank,
        levelWord: levelWord,
        validId: validId,
        validSession: validSession,
        shares: shares,
        canAttach: canAttach,
        hosts: hosts,
        plain: plain,
        peekText: peekText,
        parseSession: parseSession,
        isLive: isLive,
        sortSessions: sortSessions,
        sessionLabel: sessionLabel,
        where: where,
        readAgents: readAgents,
        visible: visible,
        hostLine: hostLine,
        readPeek: readPeek,
        agentsCommand: agentsCommand,
        peekCommand: peekCommand,
        attachCommand: attachCommand,
        terminalCommand: terminalCommand
    }
