// ─── phone.js ────────────────────────────────────────────────────────────────
// What `rime remote messages|calls|photos --json` says, turned into what the
// Dashboard's Phone page shows, and the argv the page may run.
//
// Nothing here does I/O or knows about Theme or Quickshell: data in, data out,
// so `node tests/phone-test.js` drives all of it (the arrangement
// remotepairing.js and firewall.js use).
//
// ── Where the shapes come from ───────────────────────────────────────────────
//
// rime-os rimed/rime/src/remote.rs prints each reply's fields with `--json`
// (docs/remote-live-contract.md §2.11 to §2.13):
//
//   messages        {"device","threads":[{id,addresses,name?,snippet,date_ms,unread,count}],"changed_ms"?}
//   messages --thread N
//                   {"device","thread":N,"messages":[{id,date_ms,from_me,body,status}],"changed_ms"?}
//   messages send   {"sent":true,"device"}
//   calls           {"device","current":{state,number?,name?,since_ms}|null,"calls"?:[…],"history_error"?}
//   calls dial|hangup {"done":true,"device","action"}
//   photos          {"device","partial","photos":[{id,name,date_ms,width,height,size,mime,thumb?}]}
//   photos save     {"saved":true,"device","photo","path","len"}
//
// and on every refusal `{"error":"<the daemon's sentence>"}` with exit 1. A
// failure before the daemon answered (it is not running) prints nothing on
// stdout and one `rime: …` line on stderr.
//
// ── State comes from structure, never from prose ─────────────────────────────
//
// Whether a phone is paired, connected, and offers a feature is read from
// `rime remote devices --json` (the phone's last report, `can`) and
// `rime remote status --json` (the connections open now). The daemon's error
// sentences are shown as they are and never matched against: they are prose,
// and the first rewording would turn a "turned off" into a blank page.
//
// ── Nothing is kept ──────────────────────────────────────────────────────────
//
// The contract promises nothing about a message, a call or a photo is stored
// on the computer. These functions return new objects for the page to hold in
// memory while it is open; nothing here writes, logs or caches.

"use strict"

// ── the CLI's answer ─────────────────────────────────────────────────────────

// The last non-empty stderr line, without the CLI's "rime: " prefix.
function lastLine(text) {
    var lines = String(text || "").split("\n").filter(function (l) { return l.trim() !== "" })
    return lines.length ? lines[lines.length - 1].replace(/^rime: /, "").trim() : ""
}

// One run of a `--json` verb: {ok, data, error}. `what` names the command for
// the sentence used when it said nothing at all (a binary that is missing, or
// killed).
function outcome(code, stdout, stderr, what) {
    var obj = null
    try { obj = JSON.parse(String(stdout || "")) } catch (e) { obj = null }
    if (obj && typeof obj === "object" && !Array.isArray(obj)) {
        if (typeof obj.error === "string")
            return { ok: false, data: null, error: obj.error || lastLine(stderr) || (what + " failed") }
        if (code === 0) return { ok: true, data: obj, error: "" }
    }
    var said = lastLine(stderr)
    if (code === 0 && !said) said = what + " gave an answer this Shell cannot read"
    return { ok: false, data: null, error: said || (what + " exited " + code) }
}

// ── small readers ────────────────────────────────────────────────────────────

// An id is a u64 on the wire. One past 2^53 cannot round-trip through a JS
// number, so it is refused rather than turned into a neighbouring id: asking
// the phone for the wrong conversation, or saving the wrong photo, is worse
// than not listing one.
function wholeId(v) {
    return typeof v === "number" && Number.isSafeInteger(v) && v >= 0 ? v : null
}
function whole(v) {
    return typeof v === "number" && isFinite(v) && v >= 0 ? Math.floor(v) : 0
}
function str(v) { return typeof v === "string" ? v : "" }

// ── messages ─────────────────────────────────────────────────────────────────

// `rime remote messages --json`: the conversation list, newest first as the
// phone sent it. null for anything that is not a list reply.
function parseThreads(obj) {
    if (!obj || typeof obj !== "object" || !Array.isArray(obj.threads)) return null
    var out = []
    for (var i = 0; i < obj.threads.length; i++) {
        var t = obj.threads[i]
        if (!t || typeof t !== "object") continue
        var id = wholeId(t.id)
        if (id === null) continue
        var addresses = Array.isArray(t.addresses) ? t.addresses.filter(function (a) { return typeof a === "string" && a !== "" }) : []
        var name = str(t.name)
        out.push({
            id: id,
            addresses: addresses,
            name: name,
            title: name || addresses.join(", ") || "Unknown number",
            snippet: str(t.snippet),
            dateMs: whole(t.date_ms),
            unread: whole(t.unread),
            count: whole(t.count),
            // A send into a thread with more than one address is refused by
            // the phone (`group`): the reply box is not offered there.
            group: addresses.length > 1
        })
    }
    return { device: str(obj.device), threads: out, changedMs: whole(obj.changed_ms) }
}

var SENT_STATUSES = ["received", "sent", "delivered", "sending", "failed"]

// `rime remote messages --thread N --json`. The phone sends newest first; the
// page reads down like a chat, so `messages` here is OLDEST first. `oldestMs`
// is what `--before` takes for the page before it.
function parseThread(obj) {
    if (!obj || typeof obj !== "object" || !Array.isArray(obj.messages)) return null
    var thread = wholeId(obj.thread)
    if (thread === null) return null
    var out = []
    for (var i = 0; i < obj.messages.length; i++) {
        var m = obj.messages[i]
        if (!m || typeof m !== "object") continue
        var id = wholeId(m.id)
        if (id === null) continue
        var status = SENT_STATUSES.indexOf(m.status) >= 0 ? m.status : "received"
        out.push({ id: id, dateMs: whole(m.date_ms), fromMe: m.from_me === true, body: str(m.body), status: status })
    }
    out.sort(function (a, b) { return a.dateMs - b.dateMs || a.id - b.id })
    return {
        device: str(obj.device),
        thread: thread,
        messages: out,
        oldestMs: out.length ? out[0].dateMs : 0,
        received: obj.messages.length
    }
}

// An older page put in front of what is shown, without a message twice.
function prependOlder(older, shown) {
    var seen = {}
    for (var i = 0; i < shown.length; i++) seen[shown[i].id] = true
    return older.filter(function (m) { return !seen[m.id] }).concat(shown)
}

// The words under a message of mine that has not simply gone.
function messageStatus(m) {
    if (!m || !m.fromMe) return ""
    if (m.status === "sending") return "Sending"
    if (m.status === "failed") return "Not sent"
    return ""
}

var MAX_TEXT = 2000

// What the reply box may send: 1 to 2,000 characters, no control characters
// but newlines (contract §2.11). Checked here so a refusal is a sentence by the
// field, not a round trip to the phone. The text is sent as typed.
function replyCheck(text) {
    var t = String(text === undefined || text === null ? "" : text)
    if (t.trim() === "") return { ok: false, text: "", error: "Type a message first." }
    if (Array.from(t).length > MAX_TEXT) return { ok: false, text: "", error: "A message is at most 2,000 characters." }
    if (/[\u0000-\u0009\u000b-\u001f\u007f]/.test(t)) return { ok: false, text: "", error: "The message has control characters in it." }
    return { ok: true, text: t, error: "" }
}

// ── calls ────────────────────────────────────────────────────────────────────

var CALL_STATES = ["ringing", "active", "held"]
var CALL_TYPES = ["incoming", "outgoing", "missed", "rejected"]

// `rime remote calls --json`. `current` is null when the phone has no call;
// `calls` is null when the history could not be read, and `historyError` then
// says why (the current call is still true).
function parseCalls(obj) {
    if (!obj || typeof obj !== "object" || typeof obj.device !== "string") return null
    var current = null
    var c = obj.current
    if (c && typeof c === "object" && CALL_STATES.indexOf(c.state) >= 0)
        current = { state: c.state, number: str(c.number), name: str(c.name), sinceMs: whole(c.since_ms) }
    var calls = null
    if (Array.isArray(obj.calls)) {
        calls = []
        for (var i = 0; i < obj.calls.length; i++) {
            var e = obj.calls[i]
            if (!e || typeof e !== "object" || CALL_TYPES.indexOf(e.type) < 0) continue
            calls.push({ number: str(e.number), name: str(e.name), type: e.type,
                         dateMs: whole(e.date_ms), durationS: whole(e.duration_s) })
        }
    }
    return { device: obj.device, current: current, calls: calls,
             historyError: typeof obj.history_error === "string" ? obj.history_error : "" }
}

function caller(number, name) {
    if (name && number) return name + " (" + number + ")"
    return name || number || "Withheld number"
}

var CALL_TYPE_LABELS = { incoming: "Incoming", outgoing: "Outgoing", missed: "Missed", rejected: "Declined" }
function callTypeLabel(type) { return CALL_TYPE_LABELS[type] || "" }

var CALL_STATE_LABELS = { ringing: "Ringing", active: "On a call", held: "On hold" }
function callStateLabel(state) { return CALL_STATE_LABELS[state] || "" }

// "-", "45s", "3m 05s": the CLI's own lengths.
function duration(s) {
    s = whole(s)
    if (s === 0) return ""
    if (s < 60) return s + "s"
    var r = s % 60
    return Math.floor(s / 60) + "m " + (r < 10 ? "0" : "") + r + "s"
}

// The number the dial field holds, as the daemon reads it (messages::number):
// digits with an optional + first, spaces, dashes, dots and brackets ignored,
// 3 to 20 digits. Returned in that clean form, or "" when it is not one. The
// dial verb takes the number as an argument, so this is also what keeps a
// leading "-" from ever reaching the CLI's option parser.
function dialNumber(text) {
    var raw = String(text || "").trim()
    var out = ""
    for (var i = 0; i < raw.length; i++) {
        var ch = raw.charAt(i)
        if (ch >= "0" && ch <= "9") out += ch
        else if (ch === "+" && i === 0) out += ch
        else if (" -.()".indexOf(ch) >= 0) continue
        else return ""
    }
    var digits = out.replace(/^\+/, "").length
    return digits >= 3 && digits <= 20 ? out : ""
}

// ── photos ───────────────────────────────────────────────────────────────────

// `rime remote photos --json`, newest first. `thumb` is a file the daemon
// wrote under the runtime directory, or "" when the phone sent none.
function parsePhotos(obj) {
    if (!obj || typeof obj !== "object" || !Array.isArray(obj.photos)) return null
    var out = []
    for (var i = 0; i < obj.photos.length; i++) {
        var p = obj.photos[i]
        if (!p || typeof p !== "object") continue
        var id = wholeId(p.id)
        if (id === null) continue
        var thumb = str(p.thumb)
        out.push({
            id: id, name: str(p.name), dateMs: whole(p.date_ms),
            width: whole(p.width), height: whole(p.height), size: whole(p.size), mime: str(p.mime),
            // Only an absolute path is a file this Shell will draw.
            thumb: thumb.charAt(0) === "/" ? thumb : ""
        })
    }
    out.sort(function (a, b) { return b.dateMs - a.dateMs || b.id - a.id })
    return { device: str(obj.device), partial: obj.partial === true, photos: out,
             oldestMs: out.length ? out[out.length - 1].dateMs : 0, received: obj.photos.length }
}

// A further page after what is shown, without a photo twice.
function appendOlder(shown, older) {
    var seen = {}
    for (var i = 0; i < shown.length; i++) seen[shown[i].id] = true
    return shown.concat(older.filter(function (p) { return !seen[p.id] }))
}

// A file URL for a thumbnail path, each segment escaped.
function fileUrl(path) {
    if (!path || path.charAt(0) !== "/") return ""
    return "file://" + path.split("/").map(encodeURIComponent).join("/")
}

// `rime remote photos save ID --json`: where the photo went.
function parseSaved(obj) {
    if (!obj || obj.saved !== true || typeof obj.path !== "string" || obj.path === "") return null
    return { path: obj.path, len: whole(obj.len), photo: wholeId(obj.photo) }
}

// "2.4 MB", "640 KB": the original's size, for the Save line.
function bytes(n) {
    n = whole(n)
    if (n >= 1048576) return (n / 1048576).toFixed(1) + " MB"
    if (n >= 1024) return Math.round(n / 1024) + " KB"
    return n + " B"
}

// ── the phone, and what the page can say about it ────────────────────────────

// Rime Remote's three switches, in the app's own words (rime-os android
// MachinesScreen.kt), and what else turns the word off: Android's permission,
// and for photos the lock (never on a companion connection, §2.13).
var FEATURES = {
    messages: {
        word: "messages", label: "Messages", switchName: "Messages on your computer",
        also: "allow it to read SMS"
    },
    calls: {
        word: "calls", label: "Calls", switchName: "Calls on your computer",
        also: "allow it to see phone calls"
    },
    photos: {
        word: "photos", label: "Photos", switchName: "Photos on your computer",
        also: "allow it to see photos, and unlock Rime Remote on the phone"
    }
}

// The device the page is about: an active device that reported itself as a
// phone, a connected one first. Without any report, the first active device
// (an app too old to report, or one that never connected). null: none paired.
function choosePhone(devices, connectedIds) {
    var list = Array.isArray(devices) ? devices : []
    var ids = Array.isArray(connectedIds) ? connectedIds : []
    var active = list.filter(function (d) {
        return d && d.id && (d.revokedMs === null || d.revokedMs === undefined)
    })
    var phones = active.filter(function (d) { return d.phone })
    for (var i = 0; i < phones.length; i++)
        if (ids.indexOf(phones[i].id) >= 0) return phones[i]
    if (phones.length) return phones[0]
    return active.length ? active[0] : null
}

// What the whole page is in, before any section: loading, error, none,
// offline, noreport, or ready.
function pageState(phone, connectedIds, checked, error) {
    if (error) return "error"
    if (!checked) return "loading"
    if (!phone) return "none"
    if ((connectedIds || []).indexOf(phone.id) < 0) return "offline"
    if (!phone.phone) return "noreport"
    return "ready"
}

// The sentences for a page state that has nothing else to show.
function pageMessage(state, phone, error) {
    var name = phone ? phone.name : "The phone"
    switch (state) {
    case "loading": return { title: "Looking for your phone", hint: "" }
    case "error": return { title: "Could not reach Rime Remote", hint: error || "" }
    case "none": return { title: "No phone paired",
                          hint: "Pair one in Settings, Pair a device, and scan the code with Rime Remote." }
    case "offline": return { title: name + " is not connected",
                             hint: "Open Rime Remote on the phone. Its messages, calls and photos show here while it is connected." }
    case "noreport": return { title: name + " has not said what it shares",
                              hint: "Open Rime Remote on the phone. If this stays, update the app." }
    }
    return { title: "", hint: "" }
}

// Whether the phone offers a section, from its last report's `can` words.
function offers(phone, feature) {
    var f = FEATURES[feature]
    return !!(f && phone && phone.phone && Array.isArray(phone.phone.can) && phone.phone.can.indexOf(f.word) >= 0)
}

// The off state for a section: which switch to turn on in the app. The word is
// missing for any of its reasons (the switch, Android's permission, the lock),
// so all of them are named.
function offMessage(phone, feature) {
    var f = FEATURES[feature]
    if (!f) return { title: "", hint: "" }
    var name = phone ? phone.name : "the phone"
    return {
        title: f.label + " is off on " + name,
        hint: "In Rime Remote on the phone, turn on \"" + f.switchName + "\" and " + f.also + "."
    }
}

// What the Calls section may do beyond showing the current call (§2.12).
function callAbilities(phone) {
    var can = phone && phone.phone && Array.isArray(phone.phone.can) ? phone.phone.can : []
    return {
        history: can.indexOf("calls_history") >= 0,
        answer: can.indexOf("calls_answer") >= 0,
        dial: can.indexOf("calls_dial") >= 0
    }
}

// ── time ─────────────────────────────────────────────────────────────────────

var MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

// "now", "5m", "3h", "2d", then "12 Nov". Short, for a row's right edge.
function when(ms, nowMs) {
    if (!ms) return ""
    var secs = Math.floor(Math.max(0, nowMs - ms) / 1000)
    if (secs < 60) return "now"
    if (secs < 3600) return Math.floor(secs / 60) + "m"
    if (secs < 86400) return Math.floor(secs / 3600) + "h"
    if (secs < 7 * 86400) return Math.floor(secs / 86400) + "d"
    var d = new Date(ms)
    return d.getDate() + " " + MONTHS[d.getMonth()]
}

// ── the argv the page may run ────────────────────────────────────────────────
//
// Everything through the `rime` CLI, for the reasons RemotePairingService
// gives: it is the stability surface, and under test it is the stub on PATH.
// The device is always named, as `--device=ID` in one argument: a device id is
// base64url and may begin with "-", which a separate argument would hand to
// the option parser as a flag. Message text is NEVER here: `messages send`
// reads it from standard input (the service writes it there).

var PAGE_LIMIT = 30

function dev(id) { return "--device=" + String(id) }

function threadsCommand(device) {
    return ["rime", "remote", "messages", "--json", dev(device), "--limit", String(PAGE_LIMIT)]
}

function threadCommand(device, thread, beforeMs) {
    var c = ["rime", "remote", "messages", "--json", dev(device), "--thread", String(thread), "--limit", String(PAGE_LIMIT)]
    if (beforeMs) c.push("--before", String(beforeMs))
    return c
}

function sendCommand(device, thread) {
    return ["rime", "remote", "messages", "send", dev(device), "--thread", String(thread), "--json"]
}

function callsCommand(device) {
    return ["rime", "remote", "calls", "--json", dev(device), "--limit", String(PAGE_LIMIT)]
}

// `number` must already be dialNumber()'s clean form.
function dialCommand(device, number) {
    return ["rime", "remote", "calls", "dial", dev(device), "--json", String(number)]
}

function hangupCommand(device) {
    return ["rime", "remote", "calls", "hangup", dev(device), "--json"]
}

function photosCommand(device, beforeMs) {
    var c = ["rime", "remote", "photos", "--json", dev(device), "--limit", String(PAGE_LIMIT)]
    if (beforeMs) c.push("--before", String(beforeMs))
    return c
}

function saveCommand(device, photo) {
    return ["rime", "remote", "photos", "save", String(photo), dev(device), "--json"]
}

// Node (tests) sees `module`; the QML engine does not, and ignores this.
if (typeof module !== "undefined" && module.exports)
    module.exports = {
        FEATURES: FEATURES, PAGE_LIMIT: PAGE_LIMIT, MAX_TEXT: MAX_TEXT,
        lastLine: lastLine, outcome: outcome, wholeId: wholeId,
        parseThreads: parseThreads, parseThread: parseThread, prependOlder: prependOlder,
        messageStatus: messageStatus, replyCheck: replyCheck,
        parseCalls: parseCalls, caller: caller, callTypeLabel: callTypeLabel,
        callStateLabel: callStateLabel, duration: duration, dialNumber: dialNumber,
        parsePhotos: parsePhotos, appendOlder: appendOlder, fileUrl: fileUrl,
        parseSaved: parseSaved, bytes: bytes,
        choosePhone: choosePhone, pageState: pageState, pageMessage: pageMessage,
        offers: offers, offMessage: offMessage, callAbilities: callAbilities, when: when,
        threadsCommand: threadsCommand, threadCommand: threadCommand, sendCommand: sendCommand,
        callsCommand: callsCommand, dialCommand: dialCommand, hangupCommand: hangupCommand,
        photosCommand: photosCommand, saveCommand: saveCommand
    }
