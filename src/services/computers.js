// ─── computers.js ────────────────────────────────────────────────────────────
// What `rime remote computers … --json` says about this person's other Rime
// computers, turned into what the Dashboard's Phone page and Settings → Paired
// devices show, and the argv they may run. Nothing here does I/O or knows
// about Theme or Quickshell: data in, data out, so `node` drives all of it
// (tests/computers-test.js), as with remotepairing.js and phone.js.
//
// ── The shape it reads ───────────────────────────────────────────────────────
//
// `rime remote computers list --json` prints a JSON ARRAY, one object per
// computer this one ever paired, removed ones included: the record
// (rime_remote_core::device::Device, flattened) plus the presence the daemon
// last heard and the sharing switches as they count right now
// (rime_remote_core::peer::Listed). Read here, field by field:
//
//   id                  16 base64url characters; the ONLY thing put in argv
//   name                what the other computer calls itself (plain text)
//   last_seen_ms        last completed handshake, either direction, or null
//   revoked_ms          set once removed (here, or by it): the row is history
//   forgotten_ms        removed, then `forget` run here
//   introduced_by       {id, name} when a phone introduced it, else absent
//   allowed_ms          when a person here allowed an introduced one
//   presence            {name, battery: {percent, charging} | null, on_ac,
//                        power_mode, locked, network: wired|wifi|none,
//                        uptime_s}, absent until it was reached since the
//                        daemon started (kept in memory only)
//   presence_ms         when that presence arrived
//   clipboard_send      this computer's copies go there (effective: false for
//   clipboard_receive   its copies are taken here       a removed computer
//   files               its files are saved here        or one not allowed)
//   handoff             its links are shown here as cards (effective, like
//                       the three above). Absent from a rime-remoted older
//                       than handoff cards: then `handoff` is null, and the
//                       pages offer neither the switch nor "Open link there",
//                       since that daemon has no `computers open` either.
//   agents              off|view|control: what THIS computer lets that one do
//                       with the agent sessions here (`computers grant`)
//   can_agents          off|view|control: what THAT computer says it lets
//                       this one do with its agent sessions (a claim, learned
//                       when this computer last reached it)
//   can_agents_ms       when that claim arrived; absent when it is unknown
//                       Both read as null when absent or not one of the
//                       three (an older rime-remoted): the pages then show
//                       no agents rows.
//
// There is no "online" field. The daemon dials each paired computer every 5
// minutes on AC and every 15 on battery, and nothing in power saver, so a
// computer reached within ONLINE_MS is called online and any other one "not
// reached" with how long ago, which is what is known.
//
// ── Names come from another machine ──────────────────────────────────────────
//
// A computer's name and its introducer's name are chosen on that other
// machine. They are only ever displayed, as plain text (every Text that shows
// one sets Text.PlainText), and cleaned here of line breaks and the
// direction-override characters that would let a name reorder the words
// around it. A row whose id is not base64url is dropped, so nothing another
// machine wrote can reach a command line through an id.
// ─────────────────────────────────────────────────────────────────────────────

"use strict"

var ONLINE_MS = 20 * 60 * 1000

// How often a visible page reads the list again: every 30 s on AC, every 60 s
// on battery (the phone service reads every 30 s whatever the power, and this
// must never read more often than it). A positive whole number in the
// environment (tests) wins.
var POLL_AC_MS = 30000
var POLL_BATTERY_MS = 60000
function pollInterval(envValue, onBattery) {
    var v = /^[0-9]+$/.test(String(envValue || "")) ? parseInt(envValue, 10) : 0
    if (v > 0) return v
    return onBattery ? POLL_BATTERY_MS : POLL_AC_MS
}

// The base64url characters an id is made of (Device::id_for: the first 16 of
// the key). Anything else is not an id this Shell will pass on.
function validId(v) {
    return typeof v === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(v)
}

// Control characters, line and paragraph separators, and bidi embeddings,
// overrides and isolates become a space; the result is trimmed and capped.
function cleanName(v) {
    if (typeof v !== "string") return ""
    var s = v.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, " ")
    s = s.replace(/\s+/g, " ").trim()
    return s.length > 80 ? s.slice(0, 80) : s
}

function ms(v) {
    return typeof v === "number" && isFinite(v) && v > 0 ? v : null
}

function parsePresence(p) {
    if (!p || typeof p !== "object" || Array.isArray(p)) return null
    var b = p.battery
    var battery = null
    if (b && typeof b === "object" && typeof b.percent === "number" && b.percent >= 0 && b.percent <= 100)
        battery = { percent: Math.round(b.percent), charging: b.charging === true }
    var net = p.network === "wired" || p.network === "wifi" || p.network === "none" ? p.network : ""
    return {
        battery: battery,
        onAc: p.on_ac === true,
        locked: p.locked === true ? true : p.locked === false ? false : null,
        network: net
    }
}

// The list, or null for an answer that is not one (the caller keeps a quiet,
// empty state: an older rime without `computers`, no daemon).
function parseComputers(text) {
    var a
    try { a = JSON.parse(String(text || "")) } catch (e) { return null }
    if (!Array.isArray(a)) return null
    var out = []
    for (var i = 0; i < a.length; i++) {
        var c = a[i]
        if (!c || typeof c !== "object" || !validId(c.id)) continue
        var revoked = ms(c.revoked_ms)
        var by = c.introduced_by && typeof c.introduced_by === "object" ? cleanName(c.introduced_by.name) : ""
        var introduced = !!(c.introduced_by && typeof c.introduced_by === "object")
        var allowed = ms(c.allowed_ms) !== null
        var active = revoked === null
        var trusted = active && (!introduced || allowed)
        var presenceMs = ms(c.presence_ms)
        var lastSeen = ms(c.last_seen_ms)
        out.push({
            id: c.id,
            name: cleanName(c.name) || c.id,
            active: active,
            state: !active ? (ms(c.forgotten_ms) !== null && ms(c.forgotten_ms) >= revoked ? "forgotten" : "removed")
                 : (introduced && !allowed ? "introduced" : "paired"),
            introducedBy: introduced ? (by || "another device") : "",
            needsAllow: active && introduced && !allowed,
            trusted: trusted,
            lastSeenMs: lastSeen,
            presence: parsePresence(c.presence),
            presenceMs: presenceMs,
            reachedMs: Math.max(lastSeen || 0, presenceMs || 0) || null,
            clipboardSend: c.clipboard_send === true,
            clipboardReceive: c.clipboard_receive === true,
            files: c.files === true,
            // null: this daemon has no handoff cards (see the header).
            handoff: typeof c.handoff === "boolean" ? (trusted && c.handoff) : null,
            agents: agentLevel(c.agents),
            canAgents: agentLevel(c.can_agents),
            canAgentsMs: ms(c.can_agents_ms)
        })
    }
    return out
}

function paired(list) {
    return (list || []).filter(function (c) { return c.active })
}

function online(c, nowMs) {
    return !!c && c.active && c.reachedMs !== null && nowMs - c.reachedMs <= ONLINE_MS
}

// The same units as `rime remote computers list` (remote.rs::ago).
function ago(t, nowMs) {
    if (t === null || t === undefined) return "never"
    var secs = Math.floor(Math.max(0, nowMs - t) / 1000)
    if (secs < 60) return secs + "s ago"
    if (secs < 3600) return Math.floor(secs / 60) + "m ago"
    if (secs < 86400) return Math.floor(secs / 3600) + "h ago"
    return Math.floor(secs / 86400) + "d ago"
}

// {word, token, weight}: the state word and the Theme token NAME a row looks
// up, with a weight that is not hue (remotepairing.js's rule).
function stateOf(c, nowMs) {
    if (!c.active) return { word: c.state === "forgotten" ? "removed, may pair again" : "removed", token: "danger", weight: "solid" }
    if (c.needsAllow) return { word: "not allowed yet", token: "warning", weight: "outline" }
    if (online(c, nowMs)) return { word: "online", token: "success", weight: "tint" }
    if (c.reachedMs === null) return { word: "not reached yet", token: "subtext", weight: "plain" }
    return { word: "asleep or out of reach", token: "subtext", weight: "plain" }
}

function reachedLine(c, nowMs) {
    if (!c.active) return ""
    return c.reachedMs === null ? "Not reached since Rime Remote started"
                                : "Reached " + ago(c.reachedMs, nowMs)
}

// "Battery 80%, charging · Wi-Fi · Locked", from the presence alone.
function presenceLine(p) {
    if (!p) return ""
    var parts = []
    if (p.battery) parts.push("Battery " + p.battery.percent + "%" + (p.battery.charging ? ", charging" : p.onAc ? ", on AC" : ""))
    else if (p.onAc) parts.push("On AC power")
    if (p.network === "wired") parts.push("Wired")
    else if (p.network === "wifi") parts.push("Wi-Fi")
    else if (p.network === "none") parts.push("No network")
    if (p.locked === true) parts.push("Locked")
    return parts.join(" · ")
}

function introducedLine(c) {
    if (!c.active || c.introducedBy === "") return ""
    // The state word already says "not allowed yet" while it is not.
    return c.needsAllow ? "Added by " + c.introducedBy : "Added by " + c.introducedBy + ", allowed"
}

function summary(list, nowMs) {
    var p = paired(list)
    if (p.length === 0) return ""
    var on = p.filter(function (c) { return online(c, nowMs) }).length
    return (p.length === 1 ? "1 computer" : p.length + " computers") + " · " + on + " online"
}

// ── The argv ─────────────────────────────────────────────────────────────────
//
// The id is the positional, always after "--": an id may begin with "-", and
// nothing after "--" is an option, whichever way the CLI declares the
// argument. Never the name: a name can match more than one computer, and it
// came from another machine.

var LIST_COMMAND = ["rime", "remote", "computers", "list", "--json"]

var SWITCHES = ["clipboard_send", "clipboard_receive", "files", "handoff"]

// `clipboard` sets both directions in one word, so a change to one keeps the
// other as the list last said.
function switchCommand(c, which, on) {
    if (!c || !validId(c.id) || SWITCHES.indexOf(which) < 0) return null
    if (which === "clipboard_send" || which === "clipboard_receive") {
        var send = which === "clipboard_send" ? !!on : c.clipboardSend
        var recv = which === "clipboard_receive" ? !!on : c.clipboardReceive
        var word = send && recv ? "on" : send ? "send" : recv ? "receive" : "off"
        return ["rime", "remote", "computers", "clipboard", "--", c.id, word]
    }
    return ["rime", "remote", "computers", which, "--", c.id, on ? "on" : "off"]
}

// ── Agent sessions across computers ──────────────────────────────────────────
//
// `agents` is this computer's grant to that one; the Shell may only LOWER it,
// and only to off: rime asks about any other level at a terminal (a stdin that
// is a terminal, and the computer's name typed unless --yes), so lowering
// control to view, and every raise, is a command a person runs there. The
// pages print it; the Shell never runs it and never passes --yes.
var AGENT_LEVELS = ["off", "view", "control"]
var AGENT_WORDS = { off: "Off", view: "Can watch", control: "Can work in them" }

function agentLevel(v) { return AGENT_LEVELS.indexOf(v) >= 0 ? v : null }
function agentWord(v) { return AGENT_WORDS[v] || "" }

function agentsOffCommand(c) {
    if (!c || !validId(c.id) || !c.active) return null
    if (AGENT_LEVELS.indexOf(c.agents) <= 0) return null
    return ["rime", "remote", "computers", "grant", "--", c.id, "agents", "off"]
}

// The commands that set every other level, as text to copy into a terminal
// (the id, never the name: a name can be anything another machine sent).
function agentsTerminalLines(c) {
    if (!c || !validId(c.id) || !c.trusted || agentLevel(c.agents) === null) return []
    var out = []
    for (var i = 0; i < AGENT_LEVELS.length; i++) {
        var l = AGENT_LEVELS[i]
        if (l === "off" || l === c.agents) continue
        out.push({ level: l, word: AGENT_WORDS[l], line: "rime remote computers grant -- " + c.id + " agents " + l })
    }
    return out
}

function allowCommand(id) { return validId(id) ? ["rime", "remote", "computers", "allow", "--", id] : null }
function removeCommand(id) { return validId(id) ? ["rime", "remote", "computers", "remove", "--", id] : null }

// The CLI opens the file itself and hands the daemon the descriptor.
function sendCommand(id, path) {
    if (!validId(id) || typeof path !== "string" || path.charAt(0) !== "/" || /[\n\r\u0000]/.test(path)) return null
    return ["rime", "remote", "computers", "send", "--", id, path]
}

// The URL goes in on standard input ("-"), never in argv.
function openCommand(id) {
    return validId(id) ? ["rime", "remote", "computers", "open", "--json", "--", id, "-"] : null
}

// Sends the clipboard's text to `open` when it is an http(s) link, without the
// Shell ever holding it; exits NO_LINK_EXIT (and runs nothing) when it is not
// one, or is a password manager's copy. A constant script: the id arrives as
// $1, never inside the text.
var NO_LINK_EXIT = 75
var MAX_LINK_BYTES = 2048
var CLIPBOARD_OPEN_SCRIPT =
    't=$(wl-paste --list-types 2>/dev/null) || exit ' + NO_LINK_EXIT + '; ' +
    'case "$t" in *x-kde-passwordManagerHint*) exit ' + NO_LINK_EXIT + ';; esac; ' +
    'u=$(wl-paste --no-newline --type text 2>/dev/null | head -c ' + (MAX_LINK_BYTES + 1) + '); ' +
    'case "$u" in http://?*|https://?*) ;; *) exit ' + NO_LINK_EXIT + ';; esac; ' +
    'case "$u" in *[[:space:]]*) exit ' + NO_LINK_EXIT + ';; esac; ' +
    '[ $(( $(printf %s "$u" | wc -c) )) -le ' + MAX_LINK_BYTES + ' ] || exit ' + NO_LINK_EXIT + '; ' +
    'printf %s "$u" | rime remote computers open --json -- "$1" -'

function clipboardOpenCommand(id) {
    return validId(id) ? ["sh", "-c", CLIPBOARD_OPEN_SCRIPT, "sh", id] : null
}

// A typed link: one http or https URL with a host, no spaces, at most
// MAX_LINK_BYTES. {ok, url} or {ok: false, error}.
function linkCheck(text) {
    var u = String(text || "").trim()
    if (u === "") return { ok: false, error: "Type or paste a link that starts with http:// or https://." }
    if (/\s/.test(u)) return { ok: false, error: "A link has no spaces in it." }
    if (!/^https?:\/\/[^\/?#\s]+/i.test(u)) return { ok: false, error: "Only http:// and https:// links can be opened on another computer." }
    // rime-remoted refuses a link carrying a user name or password; say so here.
    if (/^https?:\/\/[^\/?#]*@/i.test(u)) return { ok: false, error: "A link with a user name or password in it cannot be sent." }
    var bytes = 0
    for (var i = 0; i < u.length; i++) {
        var c = u.charCodeAt(i)
        bytes += c < 0x80 ? 1 : c < 0x800 ? 2 : (c >= 0xd800 && c < 0xdc00) ? 4 : (c >= 0xdc00 && c < 0xe000) ? 0 : 3
    }
    if (bytes > MAX_LINK_BYTES) return { ok: false, error: "That link is too long to send." }
    return { ok: true, url: u }
}

function lastLine(stderr) {
    var lines = String(stderr || "").split("\n").filter(function (l) { return l.trim() !== "" })
    return lines.length ? cleanLine(lines[lines.length - 1].replace(/^rime: /, "")) : ""
}

// One line of CLI prose for display: no line breaks or bidi controls (it may
// carry another computer's name), capped.
function cleanLine(v) {
    var s = String(v || "").replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, " ")
    s = s.replace(/\s+/g, " ").trim()
    return s.length > 300 ? s.slice(0, 300) + "…" : s
}

// A switch, allow, remove or send: the CLI writes one sentence to stderr
// whichever way it went, and it is shown as said.
function actionOutcome(code, stderr, fallback) {
    var said = lastLine(stderr)
    if (code === 0) return { ok: true, text: said || fallback }
    return { ok: false, text: said || ("rime remote computers exited " + code) }
}

// What `computers open --json` answered.
var OPEN_WHY = {
    off: " does not take links from this computer. Turn on \"Take its links\" for this computer there, or allow this computer there first.",
    busy: " already has links from this computer waiting. Try again in a moment.",
    offline: " could not be reached. It may be asleep or off.",
    unsupported: " runs a Rime that cannot show links yet."
}
function openOutcome(code, stdout, stderr, name) {
    var o = null
    try { o = JSON.parse(String(stdout || "")) } catch (e) { o = null }
    if (o && typeof o === "object" && !Array.isArray(o)) {
        if (o.shown === true)
            return { ok: true, text: "Showing the link on " + name + ". Someone there has to open it." }
        if (o.shown === false)
            return { ok: false, text: name + (OPEN_WHY[o.why] || " did not show the link.") }
        if (typeof o.error === "string" && o.error !== "")
            return { ok: false, text: cleanLine(o.error) }
    }
    var said = lastLine(stderr)
    return { ok: false, text: said || ("rime remote computers open exited " + code) }
}

// The file picker: zenity or kdialog, whichever the probe found. One file.
var PICKER_PROBE = ["sh", "-c", "command -v zenity || command -v kdialog || true"]
function pickCommand(tool, home) {
    var from = (home || "") + "/"
    if (/zenity$/.test(tool)) return ["zenity", "--file-selection", "--title", "Choose a file to send", "--filename", from]
    if (/kdialog$/.test(tool)) return ["kdialog", "--getopenfilename", from, "--title", "Choose a file to send"]
    return null
}
function pickedPath(stdout) {
    var p = String(stdout || "").replace(/\n$/, "")
    return p.charAt(0) === "/" && p.indexOf("\n") < 0 ? p : ""
}
function baseName(path) {
    var s = String(path || "")
    return cleanLine(s.slice(s.lastIndexOf("/") + 1))
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        ONLINE_MS: ONLINE_MS,
        LIST_COMMAND: LIST_COMMAND,
        SWITCHES: SWITCHES,
        NO_LINK_EXIT: NO_LINK_EXIT,
        MAX_LINK_BYTES: MAX_LINK_BYTES,
        CLIPBOARD_OPEN_SCRIPT: CLIPBOARD_OPEN_SCRIPT,
        PICKER_PROBE: PICKER_PROBE,
        validId: validId,
        cleanName: cleanName,
        cleanLine: cleanLine,
        parseComputers: parseComputers,
        paired: paired,
        pollInterval: pollInterval,
        online: online,
        ago: ago,
        stateOf: stateOf,
        reachedLine: reachedLine,
        presenceLine: presenceLine,
        introducedLine: introducedLine,
        summary: summary,
        switchCommand: switchCommand,
        allowCommand: allowCommand,
        AGENT_LEVELS: AGENT_LEVELS,
        agentLevel: agentLevel,
        agentWord: agentWord,
        agentsOffCommand: agentsOffCommand,
        agentsTerminalLines: agentsTerminalLines,
        removeCommand: removeCommand,
        sendCommand: sendCommand,
        openCommand: openCommand,
        clipboardOpenCommand: clipboardOpenCommand,
        linkCheck: linkCheck,
        lastLine: lastLine,
        actionOutcome: actionOutcome,
        openOutcome: openOutcome,
        pickCommand: pickCommand,
        pickedPath: pickedPath,
        baseName: baseName
    }
