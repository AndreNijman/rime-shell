#!/usr/bin/env node
// Tests for src/services/computers.js: what the Phone page and Settings →
// Paired devices read out of `rime remote computers list --json`, the words
// they show, and every argv they may run. The list below is in the shape
// rime-os rimed/rime/src/remote.rs prints (serde_json::to_string_pretty of
// Vec<rime_remote_core::peer::Listed>), plus the M3b `handoff` switch.
//
//   node tests/computers-test.js

"use strict";

const path = require("path");
const C = require(path.join(__dirname, "..", "src", "services", "computers.js"));

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

const NOW = 1789155000000;
const MIN = 60 * 1000;

const LIST = [
    {   // paired with a code, reached two minutes ago, on battery, Wi-Fi
        id: "-DeskAQIDBAUGBwg", name: "Desk", public_key: "-DeskAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRo",
        paired_ms: 1789000000000, last_seen_ms: NOW - 2 * MIN, revoked_ms: null,
        requires_user_verification: false, last_path: "lan", addresses: ["192.168.1.20:47321"],
        presence: { name: "Desk", battery: { percent: 80, charging: true }, on_ac: true, power_mode: "balanced",
                    locked: false, network: "wifi", uptime_s: 7200 },
        presence_ms: NOW - 2 * MIN,
        clipboard_send: true, clipboard_receive: false, files: true, handoff: false
    },
    {   // paired, not reached for an hour, no presence since the daemon started
        id: "Lap0AQIDBAUGBwgJ", name: "Laptop", public_key: "x", paired_ms: 1789000000000,
        last_seen_ms: NOW - 60 * MIN, revoked_ms: null, requires_user_verification: false,
        last_path: "relay", clipboard_send: false, clipboard_receive: true, files: false
    },
    {   // introduced by the phone, not allowed yet; a hostile name
        id: "IntrAQIDBAUGBwgJ", name: "<b>Evil</b> $(touch x)\nline two\u202egnp.exe", public_key: "y",
        paired_ms: 1789000000000, last_seen_ms: null, revoked_ms: null, requires_user_verification: false,
        introduced_by: { id: "-PhoneAQIDBAUGBwg", name: "Pixel 8" },
        clipboard_send: false, clipboard_receive: false, files: false, handoff: true
    },
    {   // removed
        id: "GoneAQIDBAUGBwgJ", name: "Old desk", public_key: "z", paired_ms: 1, last_seen_ms: 2,
        revoked_ms: 3, requires_user_verification: false, handoff: true
    },
    {   // an id no Shell will pass on: dropped
        id: "$(touch y)", name: "bad id", public_key: "w", paired_ms: 1, revoked_ms: null
    }
];
const list = C.parseComputers(JSON.stringify(LIST, null, 2));

// ── parsing ──────────────────────────────────────────────────────────────────

check("an answer that is not a list is no list", C.parseComputers("{}"), null);
check("an empty answer is no list", C.parseComputers(""), null);
check("clap's usage text (an older rime) is no list", C.parseComputers("error: unrecognized subcommand 'computers'"), null);
check("an empty list is an empty list", C.parseComputers("[]"), []);
check("a row whose id is not base64url is dropped", list.map(c => c.id),
      ["-DeskAQIDBAUGBwg", "Lap0AQIDBAUGBwgJ", "IntrAQIDBAUGBwgJ", "GoneAQIDBAUGBwgJ"]);
check("paired leaves out the removed one", C.paired(list).map(c => c.id),
      ["-DeskAQIDBAUGBwg", "Lap0AQIDBAUGBwgJ", "IntrAQIDBAUGBwgJ"]);
check("the switches are the effective ones", [list[0].clipboardSend, list[0].clipboardReceive, list[0].files, list[0].handoff],
      [true, false, true, false]);
check("handoff from an older daemon (absent) is null: no switch, no open", list[1].handoff, null);
check("handoff listed on is off for one not allowed", list[2].handoff, false);
check("handoff listed on is off for a removed one", list[3].handoff, false);
check("a removed computer is never trusted (open, link and send rely on it)", [list[3].active, list[3].trusted], [false, false]);
check("handoff listed on for a trusted computer is on",
      C.parseComputers('[{"id":"AAAA","name":"a","handoff":true}]')[0].handoff, true);
check("a name from another machine has no line breaks or direction overrides", list[2].name,
      "<b>Evil</b> $(touch x) line two gnp.exe");
check("the introducer is kept, cleaned", list[2].introducedBy, "Pixel 8");
check("introduced and not allowed needs Allow", [list[2].needsAllow, list[2].trusted], [true, false]);
check("a code-paired computer is trusted", [list[0].needsAllow, list[0].trusted], [false, true]);
check("removed and forgotten are told apart",
      C.parseComputers(JSON.stringify([{ id: "AAAA", name: "a", revoked_ms: 5, forgotten_ms: 9 },
                                       { id: "BBBB", name: "b", revoked_ms: 5 }])).map(c => c.state),
      ["forgotten", "removed"]);
check("a nameless row is shown by its id", C.parseComputers('[{"id":"AAAA","name":"\\n"}]')[0].name, "AAAA");
check("an allowed introduced computer is trusted",
      C.parseComputers('[{"id":"AAAA","name":"a","introduced_by":{"id":"p","name":"P"},"allowed_ms":5}]')[0].trusted, true);
check("a battery out of range is dropped",
      C.parseComputers('[{"id":"AAAA","name":"a","presence":{"name":"a","battery":{"percent":300,"charging":true}}}]')[0].presence.battery, null);

// ── words ────────────────────────────────────────────────────────────────────

check("reached within twenty minutes is online", C.stateOf(list[0], NOW).word, "online");
check("online is the success token, tinted", [C.stateOf(list[0], NOW).token, C.stateOf(list[0], NOW).weight], ["success", "tint"]);
check("reached an hour ago is asleep or out of reach", C.stateOf(list[1], NOW).word, "asleep or out of reach");
check("twenty minutes exactly is still online", C.online(list[0], list[0].reachedMs + C.ONLINE_MS), true);
check("a moment past it is not", C.online(list[0], list[0].reachedMs + C.ONLINE_MS + 1), false);
check("introduced and not allowed says so", C.stateOf(list[2], NOW).word, "not allowed yet");
check("removed says removed, solid", [C.stateOf(list[3], NOW).word, C.stateOf(list[3], NOW).weight], ["removed", "solid"]);
check("never reached", C.stateOf(C.parseComputers('[{"id":"AAAA","name":"a"}]')[0], NOW).word, "not reached yet");
check("reached line", C.reachedLine(list[0], NOW), "Reached 2m ago");
check("reached line, an hour", C.reachedLine(list[1], NOW), "Reached 1h ago");
check("never reached line", C.reachedLine(list[2], NOW), "Not reached since Rime Remote started");
check("presence: battery, charging, Wi-Fi", C.presenceLine(list[0].presence), "Battery 80%, charging · Wi-Fi");
check("presence: on AC, wired, locked",
      C.presenceLine({ battery: { percent: 100, charging: false }, onAc: true, locked: true, network: "wired" }),
      "Battery 100%, on AC · Wired · Locked");
check("presence: a desktop with no battery", C.presenceLine({ battery: null, onAc: true, locked: null, network: "none" }),
      "On AC power · No network");
check("no presence, no line", C.presenceLine(null), "");
check("introduced line (the state word says not allowed)", C.introducedLine(list[2]), "Added by Pixel 8");
check("introduced line once allowed",
      C.introducedLine(C.parseComputers('[{"id":"AAAA","name":"a","introduced_by":{"id":"p","name":"P"},"allowed_ms":5}]')[0]),
      "Added by P, allowed");
check("no introduced line for one paired here", C.introducedLine(list[0]), "");
check("summary counts paired and online", C.summary(list, NOW), "3 computers · 1 online");
check("no summary with none paired", C.summary([list[3]], NOW), "");

// ── argv ─────────────────────────────────────────────────────────────────────

const desk = list[0];
check("list", C.LIST_COMMAND, ["rime", "remote", "computers", "list", "--json"]);
check("turning off sending keeps receive as it was (off): off",
      C.switchCommand(desk, "clipboard_send", false), ["rime", "remote", "computers", "clipboard", "--", "-DeskAQIDBAUGBwg", "off"]);
check("turning on receiving keeps sending on: on",
      C.switchCommand(desk, "clipboard_receive", true), ["rime", "remote", "computers", "clipboard", "--", "-DeskAQIDBAUGBwg", "on"]);
check("sending only: send",
      C.switchCommand(list[1], "clipboard_send", true).slice(-1), ["on"]);
check("receive only: receive",
      C.switchCommand(desk, "clipboard_send", false) && C.switchCommand(Object.assign({}, desk, { clipboardSend: false }), "clipboard_receive", true).slice(-1),
      ["receive"]);
check("send only from both off: send",
      C.switchCommand(Object.assign({}, list[1], { clipboardReceive: false }), "clipboard_send", true).slice(-1), ["send"]);
check("files off", C.switchCommand(desk, "files", false), ["rime", "remote", "computers", "files", "--", "-DeskAQIDBAUGBwg", "off"]);
check("handoff on", C.switchCommand(desk, "handoff", true), ["rime", "remote", "computers", "handoff", "--", "-DeskAQIDBAUGBwg", "on"]);
check("an unknown switch runs nothing", C.switchCommand(desk, "terminal", true), null);
check("allow", C.allowCommand("IntrAQIDBAUGBwgJ"), ["rime", "remote", "computers", "allow", "--", "IntrAQIDBAUGBwgJ"]);
check("remove", C.removeCommand("-DeskAQIDBAUGBwg"), ["rime", "remote", "computers", "remove", "--", "-DeskAQIDBAUGBwg"]);
check("a bad id runs nothing", [C.allowCommand("a b"), C.removeCommand("$(x)"), C.openCommand(""), C.clipboardOpenCommand("-x;y")],
      [null, null, null, null]);
check("send", C.sendCommand("-DeskAQIDBAUGBwg", "/home/a/My File.pdf"),
      ["rime", "remote", "computers", "send", "--", "-DeskAQIDBAUGBwg", "/home/a/My File.pdf"]);
check("send refuses a relative path", C.sendCommand("-DeskAQIDBAUGBwg", "file.pdf"), null);
check("send refuses a path with a newline", C.sendCommand("-DeskAQIDBAUGBwg", "/a\nb"), null);
check("open takes the link on stdin", C.openCommand("-DeskAQIDBAUGBwg"),
      ["rime", "remote", "computers", "open", "--json", "--", "-DeskAQIDBAUGBwg", "-"]);
check("the clipboard script gets the id as $1, outside the script",
      C.clipboardOpenCommand("-DeskAQIDBAUGBwg").slice(0, 2).concat(C.clipboardOpenCommand("-DeskAQIDBAUGBwg").slice(3)),
      ["sh", "-c", "sh", "-DeskAQIDBAUGBwg"]);
check("the clipboard script is constant (no id in it)", C.CLIPBOARD_OPEN_SCRIPT.indexOf("Desk"), -1);
check("the clipboard script skips a password manager's copy", C.CLIPBOARD_OPEN_SCRIPT.indexOf("x-kde-passwordManagerHint") > 0, true);

// ── links ────────────────────────────────────────────────────────────────────

check("an https link", C.linkCheck("  https://example.org/a?b=c#d  "), { ok: true, url: "https://example.org/a?b=c#d" });
check("an http link", C.linkCheck("http://192.168.1.2:8080/").ok, true);
check("ftp is refused", C.linkCheck("ftp://example.org").ok, false);
check("javascript: is refused", C.linkCheck("javascript:alert(1)").ok, false);
check("file: is refused", C.linkCheck("file:///etc/passwd").ok, false);
check("no host is refused", C.linkCheck("https://").ok, false);
check("a space is refused", C.linkCheck("https://a.org/x y").ok, false);
check("a newline is refused", C.linkCheck("https://a.org/x\nhttps://b.org").ok, false);
check("a user name or password is refused", C.linkCheck("https://me:pw@example.org/").error,
      "A link with a user name or password in it cannot be sent.");
check("an @ in the path is fine", C.linkCheck("https://example.org/@someone").ok, true);
check("too long is refused", C.linkCheck("https://a.org/" + "x".repeat(C.MAX_LINK_BYTES)).ok, false);
// 14 + 2 × 1017 = 2048 bytes, though only 1031 characters
check("multibyte counts as bytes", C.linkCheck("https://a.org/" + "é".repeat(1017)).ok, true);
check("multibyte over the cap is refused", C.linkCheck("https://a.org/" + "é".repeat(1017) + "x").ok, false);
check("empty asks for a link", C.linkCheck("").error, "Type or paste a link that starts with http:// or https://.");

// ── outcomes ─────────────────────────────────────────────────────────────────

check("shown", C.openOutcome(0, '{"id":"-DeskAQ","name":"Desk","shown":true,"why":null}', "", "Desk"),
      { ok: true, text: "Showing the link on Desk. Someone there has to open it." });
check("off", C.openOutcome(1, '{"id":"-DeskAQ","name":"Desk","shown":false,"why":"off"}', "", "Desk").text,
      "Desk does not take links from this computer. Turn on \"Take its links\" for this computer there, or allow this computer there first.");
check("busy", C.openOutcome(1, '{"shown":false,"why":"busy"}', "", "Desk").text, "Desk already has links from this computer waiting. Try again in a moment.");
check("offline", C.openOutcome(1, '{"shown":false,"why":"offline"}', "", "Desk").text, "Desk could not be reached. It may be asleep or off.");
check("unsupported", C.openOutcome(1, '{"shown":false,"why":"unsupported"}', "", "Desk").text, "Desk runs a Rime that cannot show links yet.");
check("an unknown why", C.openOutcome(1, '{"shown":false,"why":"zzz"}', "", "Desk").text, "Desk did not show the link.");
check("a JSON error", C.openOutcome(1, '{"error":"no such computer"}', "", "Desk"), { ok: false, text: "no such computer" });
check("the CLI's own line", C.openOutcome(2, "", "error: unrecognized subcommand 'open'\n", "Desk").text, "error: unrecognized subcommand 'open'");
check("an action's sentence, without rime:", C.actionOutcome(1, "rime: a scheduled-job request cannot remove a paired computer\n", "x"),
      { ok: false, text: "a scheduled-job request cannot remove a paired computer" });
check("an action's sentence keeps to one line", C.actionOutcome(0, "rime: Evil\u2028x (abc): files taken.\n", "x").text, "Evil x (abc): files taken.");
check("a silent success says the fallback", C.actionOutcome(0, "", "Allowed."), { ok: true, text: "Allowed." });
check("a silent failure says the exit", C.actionOutcome(127, "", "x").text, "rime remote computers exited 127");

// ── the picker ───────────────────────────────────────────────────────────────

check("zenity", C.pickCommand("/usr/bin/zenity", "/home/a"),
      ["zenity", "--file-selection", "--title", "Choose a file to send", "--filename", "/home/a/"]);
check("kdialog", C.pickCommand("/usr/bin/kdialog", "/home/a"), ["kdialog", "--getopenfilename", "/home/a/", "--title", "Choose a file to send"]);
check("no tool", C.pickCommand("", "/home/a"), null);
check("a picked path", C.pickedPath("/home/a/x y.pdf\n"), "/home/a/x y.pdf");
check("a cancelled pick", C.pickedPath(""), "");
check("two lines is not one path", C.pickedPath("/a\n/b\n"), "");
check("base name", C.baseName("/home/a/report.pdf"), "report.pdf");

console.log("");
// How often a visible page reads the list: never more often than the phone
// service on battery. The phone's interval is read from PhoneService.qml, so
// a change there is noticed here.
const phoneSrc = require("fs").readFileSync(path.join(__dirname, "..", "src", "services", "PhoneService.qml"), "utf8");
const phonePoll = Number((phoneSrc.match(/RIME_PHONE_POLL_MS[\s\S]*?v > 0 \? v : (\d+)/) || [])[1]);
check("the phone's interval was found", phonePoll > 0, true);
check("on battery: no faster than the phone", C.pollInterval("", true) >= phonePoll, true);
check("on battery: 60 s", C.pollInterval(undefined, true), 60000);
check("on AC: 30 s", C.pollInterval("", false), 30000);
check("on battery slower than on AC", C.pollInterval("", true) > C.pollInterval("", false), true);
check("a test's interval wins", C.pollInterval("400", true), 400);
check("zero, a negative or junk is ignored",
      [C.pollInterval("0", true), C.pollInterval("-5", true), C.pollInterval("12ms", false)], [60000, 60000, 30000]);

// ── Agent sessions across computers (M4) ─────────────────────────────────────
// `agents` / `can_agents` / `can_agents_ms` as remote.rs prints them (its own
// test: {"agents":"control","can_agents":"view","can_agents_ms":1}).
const AG = C.parseComputers(JSON.stringify([
    { id: "desk-AAAA", name: "Desk", agents: "control", can_agents: "view", can_agents_ms: 1 },
    { id: "lap-BBBB", name: "Laptop", agents: "off", can_agents: "off" },
    { id: "old-CCCC", name: "Older" },
    { id: "odd-DDDD", name: "Odd", agents: "admin", can_agents: 3 },
    { id: "-intro-E", name: "Intro", introduced_by: { id: "p", name: "Phone" }, agents: "view", can_agents: "control" },
    { id: "gone-FFF", name: "Gone", revoked_ms: 5, agents: "view", can_agents: "view" }
]));
check("agents: read as given", [AG[0].agents, AG[0].canAgents, AG[0].canAgentsMs], ["control", "view", 1]);
check("agents: off is off, an unknown claim time is null", [AG[1].agents, AG[1].canAgents, AG[1].canAgentsMs], ["off", "off", null]);
check("agents: an older daemon gives null (no rows)", [AG[2].agents, AG[2].canAgents], [null, null]);
check("agents: anything outside the closed set is null", [AG[3].agents, AG[3].canAgents], [null, null]);
check("agents: the words", ["off", "view", "control", "admin"].map(C.agentWord), ["Off", "Can watch", "Can work in them", ""]);
check("grant off: the id after --, no --yes",
      C.agentsOffCommand(AG[0]), ["rime", "remote", "computers", "grant", "--", "desk-AAAA", "agents", "off"]);
check("grant off: a hyphen id stays after --",
      C.agentsOffCommand(AG[4]), ["rime", "remote", "computers", "grant", "--", "-intro-E", "agents", "off"]);
check("grant off: nothing when it is already off", C.agentsOffCommand(AG[1]), null);
check("grant off: nothing when the level is unknown", [C.agentsOffCommand(AG[2]), C.agentsOffCommand(AG[3])], [null, null]);
check("grant off: nothing for a removed computer", C.agentsOffCommand(AG[5]), null);
check("grant off: nothing for a bad id", C.agentsOffCommand({ id: "a b", active: true, agents: "view" }), null);
check("terminal lines: every other non-off level, by id",
      C.agentsTerminalLines(AG[0]), [{ level: "view", word: "Can watch", line: "rime remote computers grant -- desk-AAAA agents view" }]);
check("terminal lines: from off, both raises",
      C.agentsTerminalLines(AG[1]).map(function (l) { return l.line }),
      ["rime remote computers grant -- lap-BBBB agents view", "rime remote computers grant -- lap-BBBB agents control"]);
check("terminal lines: none for a computer not allowed yet", C.agentsTerminalLines(AG[4]), []);
check("terminal lines: none for a removed computer or an unknown level",
      [C.agentsTerminalLines(AG[5]), C.agentsTerminalLines(AG[2])], [[], []]);
check("terminal lines: never the name", C.agentsTerminalLines(AG[0]).every(function (l) { return l.line.indexOf("Desk") < 0 }), true);

if (failed) {
    console.error(`${failed} assertion(s) failed`);
    process.exit(1);
}
console.log("all assertions passed");
