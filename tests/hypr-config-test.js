#!/usr/bin/env node
// The Hyprland config probe's decisions (src/state/hyprConfig.js, the file
// ShellState and HyprlandBackend load):
//   * "unknown" is not a verdict: it changes neither the state nor the guard
//     that keeps a problem's critical notice to one per problem;
//   * "loaded again" is logged only when a problem clears;
//   * a check asked for while the probe runs is queued, never a restart.
//
//   node tests/hypr-config-test.js

"use strict";

const path = require("path");
const H = require(path.join(__dirname, "..", "src", "state", "hyprConfig.js"));

let failed = 0;
function check(name, got, want) {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    if (!ok) {
        failed++;
        console.error(`FAIL ${name}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`);
    } else {
        console.log(`ok   ${name}`);
    }
}

// Drive ShellState's sequence of answers and record what it would do.
function drive(answers) {
    let state = "unknown", notified = "", out = [];
    for (const a of answers) {
        const v = H.step(state, notified, a);
        if (!v.verdict) { out.push(a + ":-"); continue; }
        state = v.state; notified = v.notified;
        out.push(a + ":" + (v.loadedAgain ? "again" : "") + (v.notify ? "notify" : "")
                 + (v.problem && !v.notify ? "log" : ""));
    }
    return { state, notified, out };
}

check("first ok at startup logs nothing",
      drive(["ok"]).out, ["ok:"]);
check("unknown before any answer records nothing",
      drive(["unknown", "unknown"]), { state: "unknown", notified: "", out: ["unknown:-", "unknown:-"] });
check("a problem is notified once, then only logged",
      drive(["modules-missing", "modules-missing"]).out, ["modules-missing:notify", "modules-missing:log"]);
check("unknown during a problem keeps the problem and its guard (no second notice)",
      drive(["modules-missing", "unknown", "modules-missing"]),
      { state: "modules-missing", notified: "modules-missing",
        out: ["modules-missing:notify", "unknown:-", "modules-missing:log"] });
check("unknown during a problem does not log loaded again",
      drive(["modules-missing", "unknown"]).out, ["modules-missing:notify", "unknown:-"]);
check("ok after a problem logs loaded again once and clears the guard",
      drive(["modules-missing", "ok", "ok"]), { state: "ok", notified: "", out: ["modules-missing:notify", "ok:again", "ok:"] });
check("ok, unknown, ok: nothing to say",
      drive(["ok", "unknown", "ok"]).out, ["ok:", "unknown:-", "ok:"]);
check("the same problem after it was fixed is notified again",
      drive(["not-lua", "ok", "not-lua"]).out, ["not-lua:notify", "ok:again", "not-lua:notify"]);
check("a different problem is notified",
      drive(["no-config", "modules-missing"]).out, ["no-config:notify", "modules-missing:notify"]);
check("an empty or unrecognised answer is not a verdict",
      [H.step("ok", "", "").verdict, H.step("ok", "", "garbage").verdict], [false, false]);

// The probe queue.
check("idle: a request starts the probe", H.request(false, false), { start: true, pending: false });
check("running: a request is queued, not a restart", H.request(true, false), { start: false, pending: true });
check("running: two requests queue one probe", H.request(true, true), { start: false, pending: true });
check("finished with a queued request: one more probe", H.finished(true), { start: true, pending: false });
check("finished with nothing queued: done", H.finished(false), { start: false, pending: false });

if (failed) {
    console.error(`\n${failed} failed`);
    process.exit(1);
}
console.log("\nall passed");
