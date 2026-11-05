#!/usr/bin/env node
// keybindText.js: what KeybindService splices into shell-keybinds.lua and the
// niri include. Run: node tests/keybind-text-test.js
// When luajit is on PATH, every literal is also compiled by a real Lua lexer.
"use strict"
const path = require("path")
const cp = require("child_process")
const T = require(path.join(__dirname, "..", "src/services/config_tab/keybindText.js"))

let pass = 0, fail = 0
function check(name, cond) {
    if (cond) { pass++; console.log("PASS " + name) }
    else { fail++; console.log("FAIL " + name) }
}

const evil = 'T")\nos.execute("touch /tmp/rime-pwned")\n--'
const lit = T.str(evil)
check("a newline never reaches the Lua literal raw", !/[\x00-\x1f\x7f]/.test(lit))
check("quote and backslash are escaped", T.str('a"b\\c') === '"a\\034b\\092c"')
check("plain combos are unchanged", T.str("SUPER + SHIFT") === '"SUPER + SHIFT"')
check("a comment holds no line break", !/[\r\n]/.test(T.comment(evil)))

let luajit = ""
try { luajit = cp.execFileSync("sh", ["-c", "command -v luajit lua lua5.4 | head -n1"]).toString().trim() } catch (e) {}
if (luajit) {
    // The literal round-trips to the exact text, and the comment line stays a
    // comment: compiling and running the chunk calls nothing.
    const chunk = "local s = " + lit + "\nassert(s == " + JSON.stringify(evil).replace(/\\n/g, "\\010") + ")\n"
                + "-- " + T.comment(evil) + " is another action's\n"
                + "os.exit(0)\n"
    const r = cp.spawnSync(luajit, ["-e", "os.execute = function() error('ran') end", "-"], { input: chunk })
    check("a real Lua compiles the escaped text back to the same string (" + path.basename(luajit) + ")",
          r.status === 0)
} else {
    console.log("SKIP no Lua interpreter on PATH")
}

for (const [m, k] of [["SUPER + SHIFT", "T"], ["", "PRINT"], ["CTRL + SUPER", "EQUAL"],
                      ["SUPER", "XF86AudioRaiseVolume"], ["SUPER", "code:10"], ["SUPER", "bracketleft"],
                      ["", ""]])
    check("comboOk accepts " + JSON.stringify(m + "|" + k), T.comboOk(m, k))
for (const [m, k] of [["SUPER", evil], ["SUPER", 'T { spawn "sh"; }'], ["SUPER\n", "T"],
                      ["SUPER", "T\r"], ['SUPER"', "T"], ["SUPER", "a b"]])
    check("comboOk refuses " + JSON.stringify(m + "|" + k), !T.comboOk(m, k))

console.log(pass + " passed, " + fail + " failed")
process.exit(fail ? 1 : 0)
