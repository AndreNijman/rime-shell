#!/usr/bin/env node
// Settings → Updates: drives src/services/liveupdate.js — the file the shell
// loads — over the fixtures in tests/fixtures/live-update/, one per state the
// page has to tell apart, plus a missing file, a truncated one and a hostile
// one. Run: node tests/liveupdate-test.js
//
// The hostile fixture is the one that matters most: status.json is written by
// root, but the page treats it as display data and nothing more. A field this
// file does not know is dropped, a value outside the contract's enums is not
// echoed back, every string is capped, and the only argv the page can start
// is a constant here.

"use strict";

const path = require("path");
const fs = require("fs");
const L = require(path.join(__dirname, "..", "src", "services", "liveupdate.js"));

const FIX = path.join(__dirname, "fixtures", "live-update");
const read = (n) => fs.readFileSync(path.join(FIX, n), "utf8");

let pass = 0, fail = 0;
function check(name, cond, detail) {
    if (cond) { pass++; console.log("  PASS  " + name); }
    else { fail++; console.log("  FAIL  " + name + (detail !== undefined ? "  [" + detail + "]" : "")); }
}
const eq = (name, got, want) =>
    check(name, JSON.stringify(got) === JSON.stringify(want), "got " + JSON.stringify(got) + ", want " + JSON.stringify(want));

const NONE = L.parseChecker("");
const AVAILABLE = L.parseChecker(read("checker-available"));
const UPTODATE = L.parseChecker(read("checker-none"));

console.log("── the checker ──");
eq("state=available is read", AVAILABLE.state, "available");
check("its digest is read", AVAILABLE.digest.indexOf("sha256:2222") === 0);
eq("state=none is read", UPTODATE.state, "none");
eq("no file is not present", NONE.present, false);
eq("an unknown state is not echoed", L.parseChecker("state=rm -rf /\n").state, "");
eq("lines without = and unknown keys are ignored",
   L.parseChecker("garbage\nexec=sh\nstate=none\n").state, "none");

console.log("── no status file ──");
const missing = L.parseStatus("");
eq("an absent file is not present", missing.present, false);
eq("and not ok", missing.ok, false);
eq("no file, no checker: not checked yet", L.hero(missing, NONE).kind, "unknown");
eq("no file, checker says available", L.hero(missing, AVAILABLE).title, "Update available");
eq("no file, checker says none", L.hero(missing, UPTODATE).title, "Up to date");
eq("whitespace only is absent too", L.parseStatus("  \n").present, false);

console.log("── active ──");
const active = L.parseStatus(read("active.json"));
check("parsed", active.ok, active.error);
eq("three components", active.components.length, 3);
eq("hero", L.hero(active, UPTODATE).title, "Activated live");
eq("tone ok", L.hero(active, UPTODATE).tone, "ok");
eq("summary is the detail", L.hero(active, NONE).detail, "3 components active live; nothing else is needed.");
eq("booted release", active.booted.release, "2026.10.10");
eq("target release", active.target.release, "2026.10.11");
eq("an active component's chip", L.chip(active.components[0].state).text, "Active");
eq("next-use chip", L.chip(active.components[2].state).text, "At next use");
eq("detail and versions on one line", L.componentLine(active.components[0]),
   "Activated live; the running shell is revision 3dd0eb6b. · quickshell 0.3.1-1 → 0.3.2-1");

console.log("── deferred while locked ──");
const deferred = L.parseStatus(read("deferred-locked.json"));
check("parsed", deferred.ok, deferred.error);
eq("hero names what it waits for", L.hero(deferred, NONE).title, "Waiting for Rime Shell");
eq("tone warn", L.hero(deferred, NONE).tone, "warn");
eq("the deferred chip", L.chip(deferred.components[0].state), { text: "Waiting", tone: "warn" });
eq("the recommendation is kept", deferred.recommendation, "unlock to finish");
const deferredNoComp = L.parseStatus(JSON.stringify({ schema: 1, state: "deferred", components: [] }));
eq("deferred with no component still says something", L.hero(deferredNoComp, NONE).title, "Waiting for the next step");

console.log("── pending reboot ──");
const reboot = L.parseStatus(read("pending-reboot.json"));
check("parsed", reboot.ok, reboot.error);
eq("hero", L.hero(reboot, NONE).title, "Restart recommended");
eq("pending chip", L.chip(reboot.components[1].state), { text: "After restart", tone: "warn" });
eq("recommendation", reboot.recommendation, "restart when convenient");
const idleStaged = L.parseStatus(JSON.stringify({ schema: 1, state: "idle", staged_for_boot: true }));
eq("idle with an image staged for boot: restart", L.hero(idleStaged, AVAILABLE).kind, "restart");
const activeAppRestart = L.parseStatus(JSON.stringify({ schema: 1, state: "active", remaining: "app-restart" }));
eq("an app restart is not a restart of the computer", L.hero(activeAppRestart, NONE).kind, "active");

console.log("── rolled back ──");
const rb = L.parseStatus(read("rolled-back.json"));
check("parsed", rb.ok, rb.error);
eq("hero", L.hero(rb, AVAILABLE).title, "Live activation rolled back");
eq("tone bad", L.hero(rb, AVAILABLE).tone, "bad");
eq("target null is null", rb.target, null);
eq("chip", L.chip(rb.components[0].state), { text: "Rolled back", tone: "bad" });

console.log("── other states ──");
const st = (s) => L.parseStatus(JSON.stringify({ schema: 1, state: s }));
eq("failed", L.hero(st("failed"), NONE).kind, "failed");
eq("activating", L.hero(st("activating"), NONE).kind, "applying");
eq("verifying", L.hero(st("verifying"), NONE).kind, "applying");
eq("superseded falls through to the checker", L.hero(st("superseded"), AVAILABLE).kind, "available");
eq("idle falls through to the checker", L.hero(st("idle"), UPTODATE).kind, "up-to-date");
eq("an unknown state falls through", L.hero(st("teleporting"), UPTODATE).kind, "up-to-date");

console.log("── malformed and foreign ──");
const bad = L.parseStatus(read("malformed.json"));
eq("truncated JSON is present", bad.present, true);
eq("and not ok", bad.ok, false);
check("and says so", bad.error !== "");
eq("hero falls back to the checker", L.hero(bad, AVAILABLE).kind, "available");
check("without a checker it carries the error", L.hero(bad, NONE).detail === bad.error);
eq("schema 2 is not read", L.parseStatus(JSON.stringify({ schema: 2, state: "active" })).ok, false);
eq("a missing schema is not read", L.parseStatus(JSON.stringify({ state: "active" })).ok, false);
eq("an array is not read", L.parseStatus("[1,2]").ok, false);
eq("a string is not read", L.parseStatus("\"active\"").ok, false);
eq("components not a list: empty", L.parseStatus(JSON.stringify({ schema: 1, components: "x" })).components, []);

console.log("── hostile ──");
const h = L.parseStatus(read("hostile.json"));
check("parsed", h.ok, h.error);
eq("unknown fields are dropped", h.unknown_field, undefined);
eq("a target that is not an object is null", h.target, null);
eq("non-object components are dropped", h.components.length, 1);
eq("an unknown component state is 'unknown'", h.components[0].state, "unknown");
eq("an unknown requirement is not echoed", h.components[0].requirement, "");
eq("versions not a list: none", h.components[0].versions, []);
eq("control characters become spaces", h.components[0].detail, "line one line two");
// The markup is KEPT as characters: the page draws it as plain text, and
// stripping it here would hide what root actually wrote.
check("markup is kept verbatim for a plain-text renderer", h.components[0].label.indexOf("<b>bold</b>") === 0);
eq("an unknown chip", L.chip("exploded").text, "Unknown");
const long = L.parseStatus(JSON.stringify({ schema: 1, summary: "x".repeat(5000),
    components: Array.from({ length: 100 }, (_, i) => ({ component: "c" + i, label: "y".repeat(500),
        versions: Array.from({ length: 50 }, () => "v") })) }));
eq("summary capped at 300", long.summary.length, 300);
eq("components capped", long.components.length, L.MAX_COMPONENTS);
eq("labels capped at 60", long.components[0].label.length, 60);
eq("versions capped at 8", long.components[0].versions.length, 8);
eq("a label-less component is named by its id", L.parseStatus(JSON.stringify({ schema: 1,
    components: [{ component: "kernel" }] })).components[0].label, "kernel");

console.log("── the top bar's indicator ──");
// What the icon in the bar's right notch shows, or "" for nothing at all.
const ind = (status, checker) => L.indicator(status, checker).kind;
const js = (o) => L.parseStatus(JSON.stringify(Object.assign({ schema: 1 }, o)));
const D1 = "sha256:" + "1".repeat(64), D2 = "sha256:" + "2".repeat(64), D3 = "sha256:" + "3".repeat(64);
const avail = (d) => L.parseChecker("state=available\ndigest=" + d + "\n");
eq("nothing known: nothing shown", ind(missing, NONE), "");
eq("no arguments at all: nothing shown", ind(undefined, undefined), "");
eq("the checker says none: nothing shown", ind(missing, UPTODATE), "");
eq("the checker says available: available", ind(missing, AVAILABLE), "available");
eq("available: its glyph is the page's", L.indicator(missing, AVAILABLE).glyph, L.hero(missing, AVAILABLE).glyph);
eq("available: its tooltip", L.indicator(missing, AVAILABLE).tooltip, "A Rime update is available");
eq("available without a digest is a partial write", ind(missing, L.parseChecker("state=available\n")), "");
eq("the fallback text: digest still counts as new", ind(missing, avail("text:abc")), "available");
eq("an unreadable status leaves it to the checker", ind(bad, AVAILABLE), "available");
eq("available, but it is the image already booted", ind(js({ state: "superseded", booted: { digest: D2 } }), avail(D2)), "");
eq("available, a different one from the booted", ind(js({ state: "superseded", booted: { digest: D1 } }), avail(D2)), "available");
eq("available, already queued by rime update (plain staged, nothing owed)",
   ind(js({ state: "active", booted: { digest: D1 }, target: { digest: D2 }, staged_for_boot: true, remaining: "nothing" }), avail(D2)), "");
eq("available, already applied live (live-only, nothing owed)",
   ind(js({ state: "active", booted: { digest: D1 }, target: { digest: D2 }, staged_for_boot: false, remaining: "nothing" }), avail(D2)), "");
eq("available, only planned (downloaded, not queued): still available",
   ind(js({ state: "deferred", booted: { digest: D1 }, target: { digest: D2 }, staged_for_boot: false, remaining: "soft-reboot" }), avail(D2)), "available");
eq("available, a newer one than the target: available",
   ind(js({ state: "active", booted: { digest: D1 }, target: { digest: D2 }, staged_for_boot: true, remaining: "nothing" }), avail(D3)), "available");
eq("pending reboot: restart", ind(reboot, NONE), "restart");
eq("restart: its glyph is the page's", L.indicator(reboot, NONE).glyph, L.hero(reboot, NONE).glyph);
eq("restart: its tooltip", L.indicator(reboot, NONE).tooltip, "Restart to finish the update");
eq("pending reboot outranks the stale checker", ind(reboot, AVAILABLE), "restart");
eq("deferred while locked: nothing, unlocking finishes it", ind(deferred, AVAILABLE), "");
eq("deferred with a restart owed, queued for boot: restart",
   ind(js({ state: "deferred", staged_for_boot: true, remaining: "soft-reboot" }), NONE), "restart");
eq("idle with an image staged for boot: restart", ind(idleStaged, NONE), "restart");
eq("everything live, a boot queued: nothing", ind(active, AVAILABLE), "");
eq("an app restart is not the computer's", ind(js({ state: "active", staged_for_boot: true, remaining: "app-restart" }), NONE), "");
const relogin = js({ state: "active", staged_for_boot: true, remaining: "session-restart" });
eq("a session restart: restart", ind(relogin, NONE), "restart");
eq("a session restart says to log out", L.indicator(relogin, NONE).tooltip, "Log out and back in to finish the update");
eq("a restart owed but nothing queued (plan only): nothing",
   ind(js({ state: "deferred", staged_for_boot: false, remaining: "soft-reboot" }), NONE), "");
eq("rolled back: shown", ind(rb, NONE), "rolled-back");
eq("rolled back: the page's glyph", L.indicator(rb, NONE).glyph, L.hero(rb, NONE).glyph);
eq("rolled back, nothing queued: its tooltip", L.indicator(rb, NONE).tooltip, "An update was undone");
eq("rolled back, queued for boot: says when it applies",
   L.indicator(js({ state: "rolled-back", staged_for_boot: true }), NONE).tooltip,
   "An update was undone and applies at the next restart");
eq("failed: shown", ind(st("failed"), AVAILABLE), "failed");
eq("failed: the page's glyph", L.indicator(st("failed"), NONE).glyph, L.hero(st("failed"), NONE).glyph);
eq("failed: drawn as bad", L.indicator(st("failed"), NONE).tone, "bad");
eq("failed, nothing queued: its tooltip", L.indicator(st("failed"), NONE).tooltip, "An update could not be applied");
eq("failed after it was queued for boot: says when it applies",
   L.indicator(js({ state: "failed", staged_for_boot: true }), NONE).tooltip,
   "An update could not be applied live; it applies at the next restart");
eq("staged (in progress, queued): nothing yet", ind(js({ state: "staged", staged_for_boot: true, remaining: "reboot" }), AVAILABLE), "");
eq("activating: nothing yet", ind(st("activating"), AVAILABLE), "");
eq("verifying: nothing yet", ind(st("verifying"), AVAILABLE), "");
eq("superseded leaves it to the checker", ind(st("superseded"), AVAILABLE), "available");
eq("an unknown state leaves it to the checker", ind(st("teleporting"), UPTODATE), "");
const kinds = {};
for (const [s, c] of [[missing, AVAILABLE], [reboot, NONE], [rb, NONE], [st("failed"), NONE]])
    kinds[L.indicator(s, c).glyph] = true;
eq("four kinds, four glyphs", Object.keys(kinds).length, 4);
eq("nothing shown has no glyph and no tooltip", [L.indicator(missing, NONE).glyph, L.indicator(missing, NONE).tooltip], ["", ""]);

console.log("── what's in this update ──");
// The bar's menu and Settings → Updates link to the release page on rimeos.com.
const W = (s, c, b) => L.whatsNew(s, c, b);
const offer = (rel, run, d) => L.parseChecker("state=available\ndigest=" + (d || D2) + "\nrelease=" + rel +
                                              (run !== undefined ? "\nrunning=" + run : "") + "\n");
eq("the checker's release= is read", offer("2026.11.04.4").release, "2026.11.04.4");
eq("the checker's running= is read", offer("2026.11.04.4", "2026.11.03").running, "2026.11.03");
eq("a checker without them reads as empty", [AVAILABLE.release, AVAILABLE.running], ["", ""]);
for (const bad of ["dev", "2026.11.04.1", "2026.11.4", "2026.11.04.", "2026.11.04.02", "../../x",
                   "2026.11.04?x=1", "2026.11.04/../../evil", "https://evil.example/", "2026.11.04#a",
                   "2026.11.04 4", "x2026.11.04", "2026.11.04x"])
    eq("release= that is not a release ID is dropped: " + JSON.stringify(bad), L.parseChecker("release=" + bad).release, "");
eq("release IDs .2 and .10 are kept", [L.releaseId("2026.11.04.2"), L.releaseId("2026.11.04.10")], ["2026.11.04.2", "2026.11.04.10"]);
eq("releaseId of a non-string is empty", [L.releaseId(undefined), L.releaseId(20261104), L.releaseId(null)], ["", "", ""]);

eq("available, release and running known: the page, from what runs",
   W(missing, offer("2026.11.04.4", "2026.11.03"), "").url, "https://rimeos.com/updates/2026.11.04.4?from=2026.11.03");
eq("the image's own release.json wins for from",
   W(missing, offer("2026.11.04.4", "2026.11.01"), "2026.11.02").url, "https://rimeos.com/updates/2026.11.04.4?from=2026.11.02");
eq("then status.json's booted release",
   W(js({ state: "superseded", booted: { release: "2026.10.30" } }), offer("2026.11.04.4", "2026.11.01"), "").url,
   "https://rimeos.com/updates/2026.11.04.4?from=2026.10.30");
eq("a booted id that is not a release ID is skipped for the next source",
   W(missing, offer("2026.11.04.4", "2026.11.03"), "dev").url, "https://rimeos.com/updates/2026.11.04.4?from=2026.11.03");
eq("nothing known about what runs: the page alone",
   W(missing, offer("2026.11.04.4"), "").url, "https://rimeos.com/updates/2026.11.04.4");
eq("from is never the target itself",
   W(missing, offer("2026.11.04.4", "2026.11.04.4"), "").url, "https://rimeos.com/updates/2026.11.04.4");
eq("it says which release and from where",
   [W(missing, offer("2026.11.04.4", "2026.11.03"), "").release, W(missing, offer("2026.11.04.4", "2026.11.03"), "").from],
   ["2026.11.04.4", "2026.11.03"]);
eq("available, release unknown (an older checker): the list of updates, no ?from=",
   W(missing, AVAILABLE, "2026.11.03"), { url: "https://rimeos.com/updates", release: "", from: "" });
eq("a hostile release= falls back to the list too",
   W(missing, L.parseChecker("state=available\ndigest=" + D2 + "\nrelease=../../../etc\n"), "").url, "https://rimeos.com/updates");
eq("restart owed: the release installed for the next boot, from the booted one",
   W(reboot, NONE, "").url, "https://rimeos.com/updates/2026.10.11?from=2026.10.10");
eq("restart owed: the checker's stale release= is not used",
   W(reboot, offer("2026.12.01", "2026.10.10", D2), "").release, "2026.10.11");
eq("restart owed with no target release: the list",
   W(js({ state: "idle", staged_for_boot: true }), NONE, "").url, "https://rimeos.com/updates");
eq("failed but queued for the next restart: what will run",
   W(js({ state: "failed", staged_for_boot: true, booted: { release: "2026.11.01" }, target: { release: "2026.11.02" } }), NONE, "").url,
   "https://rimeos.com/updates/2026.11.02?from=2026.11.01");
eq("undone but queued for the next restart: what will run",
   W(js({ state: "rolled-back", staged_for_boot: true, target: { release: "2026.11.02" } }), NONE, "2026.11.01").url,
   "https://rimeos.com/updates/2026.11.02?from=2026.11.01");
eq("failed with nothing queued: no link", W(js({ state: "failed", target: { release: "2026.11.02" } }), NONE, ""), null);
eq("undone with nothing queued: no link", W(rb, NONE, ""), null);
eq("nothing shown: no link", W(missing, NONE, "2026.11.03"), null);
eq("up to date: no link", W(missing, UPTODATE, "2026.11.03"), null);
eq("an update running in a terminal: no link",
   W(js({ state: "activating", staged_for_boot: true, target: { release: "2026.11.02" } }), offer("2026.11.02"), ""), null);
eq("the release already running is not offered", W(js({ state: "idle", booted: { digest: D2 } }), offer("2026.11.04.4"), ""), null);
eq("no arguments at all: no link", W(undefined, undefined, undefined), null);
check("every URL is on rimeos.com/updates",
      [W(missing, offer("2026.11.04.4", "2026.11.03"), ""), W(missing, AVAILABLE, ""), W(reboot, NONE, "")]
          .every(v => v && /^https:\/\/rimeos\.com\/updates(\/\d{4}\.\d{2}\.\d{2}(\.\d+)?(\?from=\d{4}\.\d{2}\.\d{2}(\.\d+)?)?)?$/.test(v.url)));

console.log("── the only commands ──");
const HOLD = "\"$@\"; printf '\\nPress Enter to close this window. '; read -r _";
eq("Update now", L.UPDATE_ARGV, ["sh", "-c", HOLD, "sh", "sudo", "rime", "update"]);
eq("Show plan", L.PLAN_ARGV, ["sh", "-c", HOLD, "sh", "sudo", "rime", "update", "--plan"]);
eq("Explain", L.EXPLAIN_ARGV, ["sh", "-c", HOLD, "sh", "rime", "live", "explain"]);
const src = fs.readFileSync(path.join(__dirname, "..", "src", "services", "liveupdate.js"), "utf8");
check("nothing in the module evaluates text", !/\beval\s*\(|new\s+Function\b|Qt\.include/.test(src));

console.log("");
console.log("liveupdate: " + pass + " passed, " + fail + " failed");
process.exit(fail === 0 ? 0 : 1);
