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
        check("both Alt releases commit, with and without SHIFT",
              root.count(def, "release = true") === 4
              && def.indexOf('hl.bind("ALT + Alt_R"') >= 0
              && def.indexOf('hl.bind("ALT + SHIFT + Alt_L"') >= 0)
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
        check("rebound: letting go of SUPER commits, both hands",
              sup.indexOf('hl.bind("SUPER + Super_L"') >= 0 && sup.indexOf('hl.bind("SUPER + SHIFT + Super_R"') >= 0)
        check("rebound: nothing of the switcher is left on Alt",
              sup.split("\n").filter(function (l) { return l.indexOf("hl.bind(") === 0 && /Alt_[LR]|"ALT \+ TAB"/.test(l) }).length === 0)
        check("rebound: every OS Alt bind is switched off",
              sup.indexOf('claim("ALT", "TAB")') >= 0 && sup.indexOf('claim("ALT", "Alt_R")') >= 0
              && sup.indexOf('claim("ALT + SHIFT", "TAB")') >= 0)

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
        check("staging a valid one is kept", KeybindService.staged["window-switcher"] !== undefined)
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
            c["window-switcher"] = Object.assign({}, c["window-switcher"], { mods: "SUPER", key: "TAB" })
            KeybindService.keybinds = c
            return KeybindService._genKdl()
        })()
        check("niri: recent-windows follows the combo", kdl.indexOf("Mod+Tab { next-window; }") >= 0
              && kdl.indexOf("Mod+Shift+Tab { previous-window; }") >= 0)
        check("niri: the switcher is not also a shell IPC toggle", kdl.indexOf('"window-switcher" "toggle"') < 0)

        console.log("passed=" + root.passed + " failed=" + root.failed)
        Qt.exit(root.failed === 0 ? 0 : 1)
    }
}
