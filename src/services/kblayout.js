// ─── kblayout.js ─────────────────────────────────────────────────────────────
// The keyboard-layout arithmetic, away from any compositor so node can test it.
//
// Hyprland's `devices` gives the configured codes ("us,ru"), their variants and
// the ACTIVE keymap by its xkb DESCRIPTION ("Russian"), never by index. The
// description is matched back to a configured slot through xkb's own rules list
// (evdev.lst); when that file is missing the slot is unknown and the first one
// is assumed, which is the layout a session starts on.
"use strict";

function parseLst(text) {
    var out = { layouts: {}, variants: {} }, sect = ""
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
        var l = lines[i]
        if (l.charAt(0) === "!") { sect = l.replace(/^!\s*/, "").trim(); continue }
        var m = l.match(/^\s+(\S+)\s+(.*\S)\s*$/)
        if (!m) continue
        if (sect === "layout") out.layouts[m[1]] = m[2]
        else if (sect === "variant") {
            var v = m[2].match(/^(\S+):\s*(.*)$/)       // "us: English (US, intl.)"
            if (v) out.variants[v[1] + ":" + m[1]] = v[2]
        }
    }
    return out
}

function label(code) {
    var c = String(code || "").trim()
    return c === "" ? "??" : c.toUpperCase()
}

// A Hyprland `devices -j` document → { device, codes, labels, index } or null.
function fromHypr(doc, lst) {
    var kbs = doc && doc.keyboards ? doc.keyboards : []
    if (!kbs.length) return null
    var kb = kbs[0]
    for (var i = 0; i < kbs.length; i++) if (kbs[i].main) { kb = kbs[i]; break }
    var codes = String(kb.layout || "").split(",").map(function (s) { return s.trim() }).filter(Boolean)
    var variants = String(kb.variant || "").split(",").map(function (s) { return s.trim() })
    if (!codes.length) return null
    var idx = 0, active = String(kb.active_keymap || "")
    if (lst) {
        for (var j = 0; j < codes.length; j++) {
            var v = variants[j] || ""
            var desc = v ? (lst.variants[codes[j] + ":" + v] || lst.layouts[codes[j]]) : lst.layouts[codes[j]]
            if (desc && desc === active) { idx = j; break }
        }
    }
    return { device: kb.name, codes: codes, labels: codes.map(label), index: idx, active: active }
}

// niri `msg -j keyboard-layouts` → { names, current_idx }.
function fromNiri(doc, lst) {
    if (!doc || !doc.names || !doc.names.length) return null
    var rev = {}
    if (lst) for (var c in lst.layouts) rev[lst.layouts[c]] = c
    var labels = doc.names.map(function (n) {
        return rev[n] ? label(rev[n]) : String(n).replace(/\s*\(.*$/, "").slice(0, 2).toUpperCase()
    })
    return { device: "", codes: doc.names.slice(), labels: labels, index: doc.current_idx | 0, active: doc.names[doc.current_idx | 0] }
}

if (typeof module !== "undefined" && module.exports)
    module.exports = { parseLst: parseLst, fromHypr: fromHypr, fromNiri: fromNiri, label: label }
