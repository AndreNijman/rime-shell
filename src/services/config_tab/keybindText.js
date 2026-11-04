// Text that KeybindService splices into the generated keybind files
// (~/.config/hypr/rime/shell-keybinds.lua and niri's KDL include). Kept out of
// the QML so tests/keybind-text-test.js exercises the file the shell loads, not
// a copy of it.
//
// The combos come from the saved keybinds JSON, which the user (or anything that
// writes their home) can edit by hand. A key holding a newline used to go into a
// Lua string raw: Lua refuses an unfinished string, so the whole module failed to
// load and every shell keybind was gone. Inside a `--` comment the same newline
// ended the comment and the rest of the key was Lua; in the KDL file the key is a
// bare node name, so `T { spawn ... }` in a key was a niri bind of its own.

// What a combo may be made of. A key is one keysym name (T, EQUAL, PRINT,
// XF86AudioRaiseVolume) or Hyprland's code:NN / mouse:NNN; modifiers are names
// joined by "+". Anything else in the saved file is ignored and the action keeps
// its default, rather than being spliced into a config.
function comboOk(mods, key) {
    return /^[A-Za-z0-9_]*$/.test(String(mods).replace(/[ +]/g, ""))
        && /^[A-Za-z0-9_:]*$/.test(String(key))
}

// A Lua string literal for any text: quote, backslash and every control
// character are written as \ddd, so nothing in `s` can end the literal or the
// line it is on.
function str(s) {
    var t = String(s)
    var out = '"'
    for (var i = 0; i < t.length; i++) {
        var c = t.charCodeAt(i)
        if (c === 0x22 || c === 0x5c || c < 0x20 || c === 0x7f)
            out += "\\" + ("00" + c).slice(-3)
        else
            out += t[i]
    }
    return out + '"'
}

// Text for a `-- ` comment: a line break would end the comment, so every
// control character becomes a space.
function comment(s) {
    return String(s).replace(/[\x00-\x1f\x7f]/g, " ")
}

// Node (tests) sees `module`; the QML engine does not, and ignores this.
if (typeof module !== "undefined" && module.exports)
    module.exports = { str: str, comment: comment, comboOk: comboOk }
