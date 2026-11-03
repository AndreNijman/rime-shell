#!/usr/bin/env node
// The keyboard-layout arithmetic (src/services/kblayout.js): which configured
// layout is active, read back from the compositor's own answer.
//     node tests/kblayout-test.js
"use strict";
const path = require("path");
const K = require(path.join(process.env.RIME_SHELL_SRC || path.join(__dirname, "..", "src"), "services", "kblayout.js"));
let passed = 0, failed = 0;
function check(n, c) { if (c) { passed++; console.log("  PASS  " + n) } else { failed++; console.log("  FAIL  " + n) } }

const lst = K.parseLst("! layout\n  us              English (US)\n  ru              Russian\n  kr              Korean\n\n! variant\n  intl            us: English (US, intl., with dead keys)\n  phonetic        ru: Russian (phonetic)\n");
check("layouts are read from the rules list", lst.layouts.us === "English (US)" && lst.layouts.ru === "Russian");
check("variants are keyed by layout", lst.variants["ru:phonetic"] === "Russian (phonetic)");

const dev = (layout, variant, active) => ({ keyboards: [{ name: "aux", main: false, layout: "xx", active_keymap: "x" },
    { name: "kbd", main: true, layout, variant, active_keymap: active }] });
let m = K.fromHypr(dev("us,ru", ",", "Russian"), lst);
check("the second layout is found by its description", m.index === 1 && m.labels.join() === "US,RU");
check("the main keyboard is the one read", m.device === "kbd");
m = K.fromHypr(dev("us,ru", ",phonetic", "Russian (phonetic)"), lst);
check("a variant is matched by its own description", m.index === 1);
m = K.fromHypr(dev("us,kr", "", "English (US)"), lst);
check("the first layout is active at session start", m.index === 0);
check("an unknown description falls back to the first layout", K.fromHypr(dev("us,ru", "", "Klingon"), lst).index === 0);
check("no rules list still yields the codes", K.fromHypr(dev("us,ru", "", "Russian"), null).labels.join() === "US,RU");
check("a single layout is reported as one (the chip stays hidden)", K.fromHypr(dev("us", "", "English (US)"), lst).labels.length === 1);
check("no keyboards is null", K.fromHypr({ keyboards: [] }, lst) === null && K.fromHypr(null, lst) === null);
const n = K.fromNiri({ names: ["English (US)", "Russian"], current_idx: 1 }, lst);
check("niri: labels and index come through", n.labels.join() === "US,RU" && n.index === 1);
check("niri: unknown names get a two-letter label", K.fromNiri({ names: ["Klingon (x)"], current_idx: 0 }, lst).labels[0] === "KL");
console.log("\npassed=" + passed + " failed=" + failed);
process.exit(failed ? 1 : 0);
