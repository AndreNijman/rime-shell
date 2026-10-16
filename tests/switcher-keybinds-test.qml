import Quickshell
import QtQuick
import "./src/components"
import "./src/services"
import "./src/nexus"
import "./src/popups"
import "./src"

// The window switcher's keybinds, as the shipped KeybindService generates them.
//
//     quickshell -p tests/switcher-keybinds-test.qml
//
// Nothing is written: _genLua()/_genKdl() return strings, and this harness never
// calls save() or _writeFiles(). The model is replaced in memory to ask what a
// rebound switcher would produce.
ShellRoot {
    id: root

    property int passed: 0
    property int failed: 0
    function check(name, cond) {
        if (cond) { root.passed++; console.log("  PASS  " + name) }
        else      { root.failed++; console.log("  FAIL  " + name) }
    }
    function count(hay, needle) { return hay.split(needle).length - 1 }

    property Timer _wait: Timer {
        interval: 250
        repeat: true
        running: true
        property int tries: 0
        onTriggered: {
            tries++
            if (Object.keys(KeybindService.keybinds || {}).length > 0) { running = false; root.run() }
            else if (tries > 40) {
                running = false
                console.log("  FAIL  KeybindService never loaded its model")
                console.log("passed=" + root.passed + " failed=" + (root.failed + 1))
                Qt.exit(1)
            }
        }
    }

    // every `hl.bind("<combo>"` combo in a generated file, as a sorted list
    function combos(lua, needle) {
        return lua.split("\n").filter(function (l) { return l.indexOf("hl.bind(") === 0 && l.indexOf(needle) >= 0 })
            .map(function (l) { return l.slice(9, l.indexOf('"', 9)) }).sort()
    }
    function claims(lua) {
        return lua.split("\n").filter(function (l) { return l.indexOf("claim(") === 0 })
            .map(function (l) { return l.slice(6, -1).replace(/"/g, "").replace(", ", "|") })
    }
    function rebound(mods, key) {
        const copy = Object.assign({}, KeybindService.keybinds)
        copy["window-switcher"] = Object.assign({}, copy["window-switcher"], { mods: mods, key: key })
        KeybindService.keybinds = copy
        return KeybindService._genLua()
    }

    function run() {
        const def = KeybindService._genLua()
        check("the default is ALT+TAB next", def.indexOf('hl.bind("ALT + TAB", hl.dsp.exec_cmd(switcher .. " next")') >= 0)
        check("and the reverse is ALT+SHIFT+TAB", def.indexOf('hl.bind("ALT + SHIFT + TAB", hl.dsp.exec_cmd(switcher .. " prev")') >= 0)
        check("exactly the four Alt releases commit: both hands, with and without SHIFT",
              JSON.stringify(root.combos(def, "release = true"))
              === JSON.stringify(["ALT + Alt_L", "ALT + Alt_R", "ALT + SHIFT + Alt_L", "ALT + SHIFT + Alt_R"]))
        check("the release binds do not consume the key",
              def.split("\n").filter(function (l) { return l.indexOf("release = true") >= 0 })
                 .every(function (l) { return l.indexOf("non_consuming = true") >= 0 }))
        check("Tab itself is consumed",
              def.split("\n").filter(function (l) { return l.indexOf('" next")') >= 0 })
                 .every(function (l) { return l.indexOf("non_consuming") < 0 }))
        check("the OS default is claimed before it is rebound",
              def.indexOf('claim("ALT", "TAB")') >= 0 && def.indexOf('claim("ALT + SHIFT", "Alt_L")') >= 0)

        const sup = rebound("SUPER", "GRAVE")
        check("rebound: the new combo is next", sup.indexOf('hl.bind("SUPER + GRAVE", hl.dsp.exec_cmd(switcher .. " next")') >= 0)
        check("rebound: exactly the four Super releases commit",
              JSON.stringify(root.combos(sup, "release = true"))
              === JSON.stringify(["SUPER + SHIFT + Super_L", "SUPER + SHIFT + Super_R", "SUPER + Super_L", "SUPER + Super_R"]))
        check("rebound: nothing of the switcher is left on Alt",
              sup.split("\n").filter(function (l) { return l.indexOf("hl.bind(") === 0 && /"ALT( \+ SHIFT)? \+ (TAB|Escape|Return)"|Alt_[LR]/.test(l) }).length === 0)
        const cl = root.claims(sup)
        check("rebound: every one of the OS's Alt switcher binds is switched off",
              ["ALT|TAB", "ALT + SHIFT|TAB", "ALT|Escape", "ALT|Return", "ALT|Alt_L", "ALT|Alt_R",
               "ALT + SHIFT|Alt_L", "ALT + SHIFT|Alt_R"].every(function (c) { return cl.indexOf(c) >= 0 }))

        check("rebound to SUPER: Escape, owned by the power menu, is not also the cancel bind",
              sup.indexOf('hl.bind("SUPER + Escape", hl.dsp.exec_cmd(switcher') < 0
              && sup.indexOf("is another action's; not bound here") >= 0)

        const ctrl = rebound("CTRL", "TAB")
        check("rebound to CTRL: releases are on Control", ctrl.indexOf('hl.bind("CTRL + Control_L"') >= 0)

        // invalid combos never reach the file
        const bad = rebound("ALT + SHIFT", "TAB")
        check("an invalid combo falls back to the default and says so",
              bad.indexOf("Falling back to the default") >= 0 && bad.indexOf('hl.bind("ALT + TAB"') >= 0)
        check("no modifier is not a switcher", KeybindService._switcherProblem("", "TAB") !== "")
        check("two modifiers are not a switcher", KeybindService._switcherProblem("CTRL + ALT", "TAB") !== "")
        check("SHIFT is the reverse direction, not a modifier choice", KeybindService._switcherProblem("SHIFT", "TAB") !== "")

        KeybindService.keybinds = Object.assign({}, KeybindService.keybinds, { "window-switcher": Object.assign({}, KeybindService.keybinds["window-switcher"], { mods: "ALT", key: "TAB" }) })
        KeybindService.stage("window-switcher", "ALT + SHIFT", "TAB")
        check("staging an invalid combo is refused", KeybindService.staged["window-switcher"] === undefined
              && KeybindService.lastError !== "")
        KeybindService.stage("window-switcher", "SUPER", "TAB")
        check("staging a valid one is kept, exactly",
              JSON.stringify(KeybindService.staged["window-switcher"]) === JSON.stringify({ mods: "SUPER", key: "TAB" }))
        KeybindService.unstage("window-switcher")
        KeybindService.stage("window-switcher", "", "")
        check("clearing the switcher can be staged",
              JSON.stringify(KeybindService.staged["window-switcher"]) === JSON.stringify({ mods: "", key: "" }))
        check("Escape and Return cannot be the key",
              KeybindService._switcherProblem("ALT", "Escape") !== "" && KeybindService._switcherProblem("SUPER", "RETURN") !== "")
        KeybindService.unstage("window-switcher")

        const owned = KeybindService._ownedCombos({})
        check("the switcher's own release binds are not foreign", owned["8+alt_l"] === true && owned["9+alt_r"] === true)

        const un = (function () {
            const c = Object.assign({}, KeybindService.keybinds)
            c["window-switcher"] = Object.assign({}, c["window-switcher"], { mods: "", key: "" })
            KeybindService.keybinds = c
            return KeybindService._genLua()
        })()
        check("unbound: nothing of the switcher is bound, the OS default is switched off",
              un.indexOf('exec_cmd(switcher') < 0 && un.indexOf('claim("ALT + SHIFT", "Alt_L")') >= 0)

        const kdl = (function () {
            const c = Object.assign({}, KeybindService.keybinds)
            c["window-switcher"] = Object.assign({}, c["window-switcher"], { mods: "SUPER", key: "GRAVE" })
            KeybindService.keybinds = c
            return KeybindService._genKdl()
        })()
        check("niri keeps its own switcher at Alt+Tab whatever Hyprland's is bound to",
              kdl.indexOf("Alt+Tab       { next-window; }") >= 0 && kdl.indexOf("GRAVE") < 0)
        check("niri: the switcher is not also a shell IPC toggle", kdl.indexOf('"window-switcher" "toggle"') < 0)

        console.log("passed=" + root.passed + " failed=" + root.failed)
        Qt.exit(root.failed === 0 ? 0 : 1)
    }
}
