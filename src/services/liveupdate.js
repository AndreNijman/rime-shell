// ─── liveupdate.js ───────────────────────────────────────────────────────────
// Pure logic behind Settings → Updates: reading what the OS's live update
// engine and its update checker left in /run, and turning it into something the
// page can render without holding any of the reasoning itself.
//
// Kept out of the QML for the same reason firewall.js is: this is the part with
// edge cases, and tests/liveupdate-test.js exercises THIS file — the one the
// shell loads. Nothing here does I/O, nothing knows about Theme, and every
// function is data → data.
//
// ── The two files ───────────────────────────────────────────────────────────
//
//   /run/rime-live/status.json   written atomically by root (`sudo rime update`
//                                and the engine behind it), schema 1
//   /run/rime-update/state       key=value lines from the 6-hourly checker:
//                                state=available|none, digest=sha256:…
//
// Both are absent on most machines most of the time, and both are DISPLAY DATA.
// The shell never runs anything named in them: the only commands this page can
// start are the three constants at the bottom of this file. Every string is
// capped and stripped of control characters, unknown fields are dropped, and a
// document that is not schema 1 is reported as unreadable rather than guessed at.
// ─────────────────────────────────────────────────────────────────────────────

var SCHEMA = 1

var MAX_COMPONENTS = 32
var MAX_VERSIONS = 8

var STATES = ["idle", "staged", "activating", "verifying", "active", "deferred",
              "rolled-back", "failed", "superseded"]
var COMPONENT_STATES = ["unchanged", "active", "active-at-next-use", "deferred", "pending",
                        "failed-rolled-back", "failed", "not-applicable"]
// What is still needed after a transaction, from least to most disruptive.
var REQUIREMENTS = ["nothing", "next-use", "live-reload", "service-restart", "app-restart",
                    "driver-reload", "compositor-handover", "session-restart", "soft-reboot",
                    "kernel-transition", "reboot"]
// From here up, only a restart of some kind finishes the job.
var RESTART_FROM = REQUIREMENTS.indexOf("session-restart")

// A string from the file, made safe to show: control characters (newlines
// included) become spaces, runs of whitespace collapse, and anything longer
// than `max` is cut with an ellipsis. Not a string at all is "".
function clean(v, max) {
    if (typeof v !== "string") return ""
    var s = v.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ")
             .replace(/\s+/g, " ").trim()
    if (s.length > max) s = s.slice(0, Math.max(0, max - 1)) + "…"
    return s
}

function oneOf(v, list) {
    return typeof v === "string" && list.indexOf(v) >= 0 ? v : ""
}

function _release(o) {
    if (!o || typeof o !== "object" || Array.isArray(o)) return null
    return { digest: clean(o.digest, 80), release: clean(o.release, 40) }
}

function _component(o) {
    if (!o || typeof o !== "object" || Array.isArray(o)) return null
    var versions = []
    if (Array.isArray(o.versions))
        for (var i = 0; i < o.versions.length && versions.length < MAX_VERSIONS; i++) {
            var v = clean(o.versions[i], 120)
            if (v !== "") versions.push(v)
        }
    var id = clean(o.component, 40)
    var label = clean(o.label, 60)
    return {
        component:   id,
        label:       label !== "" ? label : (id !== "" ? id : "Unnamed component"),
        state:       oneOf(o.state, COMPONENT_STATES) || "unknown",
        requirement: oneOf(o.requirement, REQUIREMENTS),
        detail:      clean(o.detail, 300),
        versions:    versions
    }
}

// parseStatus(text) → { present, ok, error, …fields }
//   present  false: there is no file (or it is empty) — the normal case
//   ok       true only for a JSON object that says schema 1
function parseStatus(text) {
    var t = typeof text === "string" ? text.trim() : ""
    var none = { present: t !== "", ok: false, error: "" }
    if (t === "") return none
    var d
    try { d = JSON.parse(t) } catch (e) { none.error = "The live update status could not be read."; return none }
    if (!d || typeof d !== "object" || Array.isArray(d)) {
        none.error = "The live update status could not be read."
        return none
    }
    if (d.schema !== SCHEMA) {
        none.error = "The live update status is in a format this version of Rime Shell does not know."
        return none
    }
    var comps = []
    if (Array.isArray(d.components))
        for (var i = 0; i < d.components.length && comps.length < MAX_COMPONENTS; i++) {
            var c = _component(d.components[i])
            if (c) comps.push(c)
        }
    return {
        present:        true,
        ok:             true,
        error:          "",
        updated:        typeof d.updated === "number" && isFinite(d.updated) ? d.updated : 0,
        txn:            clean(d.txn, 64),
        state:          oneOf(d.state, STATES) || "unknown",
        booted:         _release(d.booted),
        target:         _release(d.target),
        stagedForBoot:  d.staged_for_boot === true,
        components:     comps,
        remaining:      oneOf(d.remaining, REQUIREMENTS),
        recommendation: clean(d.recommendation, 200),
        summary:        clean(d.summary, 300)
    }
}

// parseChecker(text) → { present, state: "available"|"none"|"", digest }
// key=value lines; anything else on a line is ignored, as are unknown keys.
function parseChecker(text) {
    var out = { present: false, state: "", digest: "" }
    if (typeof text !== "string" || text.trim() === "") return out
    out.present = true
    var lines = text.split("\n")
    for (var i = 0; i < lines.length && i < 64; i++) {
        var l = lines[i]
        var eq = l.indexOf("=")
        if (eq <= 0) continue
        var k = l.slice(0, eq).trim()
        var v = l.slice(eq + 1).trim()
        if (k === "state") out.state = oneOf(v, ["available", "none"])
        else if (k === "digest") out.digest = clean(v, 80)
    }
    return out
}

function _needsRestart(req) {
    return REQUIREMENTS.indexOf(req) >= RESTART_FROM
}

// What a requirement still asks of the user, as the end of a sentence.
function requirementLine(req) {
    switch (req) {
        case "next-use":            return "takes effect the next time it is used"
        case "live-reload":         return "reloads on its own"
        case "service-restart":     return "a service restarts"
        case "app-restart":         return "restart the app"
        case "driver-reload":       return "the driver reloads"
        case "compositor-handover": return "the compositor hands over"
        case "session-restart":     return "log out and back in"
        case "soft-reboot":         return "a quick restart"
        case "kernel-transition":   return "restart into the new kernel"
        case "reboot":              return "restart the computer"
        default:                    return ""
    }
}

// hero(status, checker) → { kind, title, detail, tone, glyph }
//   kind  up-to-date | available | unknown | applying | active | deferred |
//         restart | rolled-back | failed
//   tone  ok | warn | bad | neutral
function hero(status, checker) {
    var s = status || { present: false, ok: false }
    var c = checker || { present: false, state: "" }
    var summary = s.ok ? s.summary : ""

    if (s.ok) {
        switch (s.state) {
        case "rolled-back":
            return { kind: "rolled-back", title: "Live activation rolled back", tone: "bad", glyph: "󰕍",
                     detail: summary || "Something did not pass its check, so the running system was put back as it was." }
        case "failed":
            return { kind: "failed", title: "Live activation failed", tone: "bad", glyph: "󰅙",
                     detail: summary || "The update could not be applied to the running system." }
        case "staged":
        case "activating":
        case "verifying":
            return { kind: "applying", title: "Applying the update…", tone: "neutral", glyph: "󰑐",
                     detail: summary }
        case "deferred": {
            var waiting = ""
            for (var i = 0; i < s.components.length; i++)
                if (s.components[i].state === "deferred") { waiting = s.components[i]; break }
            return { kind: "deferred", tone: "warn", glyph: "󰔟",
                     title: "Waiting for " + (waiting ? waiting.label : "the next step"),
                     detail: summary || (waiting ? waiting.detail : "") }
        }
        case "active":
            if (_needsRestart(s.remaining))
                return { kind: "restart", title: "Restart recommended", tone: "warn", glyph: "󰜉",
                         detail: summary || ("Still to do: " + requirementLine(s.remaining) + ".") }
            return { kind: "active", title: "Activated live", tone: "ok", glyph: "󰄬",
                     detail: summary || "The update is running now; nothing else is needed." }
        case "idle":
            if (s.stagedForBoot)
                return { kind: "restart", title: "Restart recommended", tone: "warn", glyph: "󰜉",
                         detail: summary || "An update is ready and starts with the next restart." }
            break
        }
        // superseded, unknown, idle with nothing staged: the checker decides.
    }

    if (c.state === "available")
        return { kind: "available", title: "Update available", tone: "warn", glyph: "󰚰",
                 detail: "A newer Rime release is published. Update now installs it." }
    if (c.state === "none")
        return { kind: "up-to-date", title: "Up to date", tone: "ok", glyph: "󰄬",
                 detail: "The last check found nothing newer than what is running." }
    return { kind: "unknown", title: "Not checked yet", tone: "neutral", glyph: "󰋗",
             detail: s.error || "This computer has not looked for an update since it started." }
}

// chip(componentState) → { text, tone }
function chip(state) {
    switch (state) {
        case "unchanged":          return { text: "Unchanged",     tone: "neutral" }
        case "active":             return { text: "Active",        tone: "ok" }
        case "active-at-next-use": return { text: "At next use",   tone: "ok" }
        case "deferred":           return { text: "Waiting",       tone: "warn" }
        case "pending":            return { text: "After restart", tone: "warn" }
        case "failed-rolled-back": return { text: "Rolled back",   tone: "bad" }
        case "failed":             return { text: "Failed",        tone: "bad" }
        case "not-applicable":     return { text: "Not used",      tone: "neutral" }
        default:                   return { text: "Unknown",       tone: "neutral" }
    }
}

// The description under a component's label: its detail, then what moved.
function componentLine(c) {
    if (!c) return ""
    var parts = []
    if (c.detail !== "") parts.push(c.detail)
    if (c.versions.length > 0) parts.push(c.versions.join(", "))
    return parts.join(" · ")
}

// ── The only commands this page can start ────────────────────────────────────
// Constants, never assembled from the files above. Each runs in the user's
// terminal through DesktopExec.runInTerminal, wrapped so the window stays open
// until Enter: the plan and the explanation are output to READ, and a terminal
// that closes the instant the command exits shows neither. `sudo` asks for the
// password in that terminal; the shell holds no privilege and asks for none.
var HOLD = "\"$@\"; printf '\\nPress Enter to close this window. '; read -r _"
var UPDATE_ARGV  = ["sh", "-c", HOLD, "sh", "sudo", "rime", "update"]
var PLAN_ARGV    = ["sh", "-c", HOLD, "sh", "rime", "update", "--plan"]
var EXPLAIN_ARGV = ["sh", "-c", HOLD, "sh", "rime", "live", "explain"]

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        clean: clean,
        parseStatus: parseStatus,
        parseChecker: parseChecker,
        hero: hero,
        chip: chip,
        componentLine: componentLine,
        requirementLine: requirementLine,
        UPDATE_ARGV: UPDATE_ARGV,
        PLAN_ARGV: PLAN_ARGV,
        EXPLAIN_ARGV: EXPLAIN_ARGV,
        MAX_COMPONENTS: MAX_COMPONENTS
    }
