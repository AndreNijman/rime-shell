#!/usr/bin/env node
// Tests for src/services/peeragents.js: which of this person's other computers
// the Agent Center asks for their agent sessions, what it makes of
// `rime remote computers agents|peek --json` (the shapes rime-os
// rimed/rime/src/remote.rs prints: computers_agents, computers_peek), and the
// argv it may run. The assertions that pay for it: the computer's id and the
// session's number are the only things from another machine that reach argv,
// each its own argument after "--"; every text field comes out one plain line;
// a refusal and an unreachable computer each give one fixed, quiet line.
//
//   node tests/peer-agents-test.js

"use strict";

const path = require("path");
const P = require(path.join(__dirname, "..", "src", "services", "peeragents.js"));
const C = require(path.join(__dirname, "..", "src", "services", "computers.js"));

let failed = 0;
let passed = 0;
function check(name, got, want) {
    const ok = JSON.stringify(got) === JSON.stringify(want);
    if (!ok) {
        failed++;
        console.error(`FAIL ${name}\n  got:  ${JSON.stringify(got)}\n  want: ${JSON.stringify(want)}`);
    } else {
        passed++;
        console.log(`ok   ${name}`);
    }
}

// ── Which computers ──────────────────────────────────────────────────────────

const LIST = C.parseComputers(JSON.stringify([
    { id: "desk-AAAA", name: "Desk", agents: "off", can_agents: "control", can_agents_ms: 1 },
    { id: "lap-BBBB", name: "Laptop", agents: "view", can_agents: "view" },
    { id: "spare-CCC", name: "Spare", agents: "control", can_agents: "off" },
    { id: "intro-DDD", name: "Intro", introduced_by: { id: "p", name: "Phone" }, can_agents: "control" },
    { id: "intro-EEE", name: "Allowed", introduced_by: { id: "p", name: "Phone" }, allowed_ms: 9, can_agents: "view" },
    { id: "gone-FFFF", name: "Gone", revoked_ms: 5, can_agents: "control" },
    { id: "old-GGGG", name: "Older" }
]));
check("hosts: view and control, active and trusted only",
      P.hosts(LIST).map(function (c) { return c.id }), ["desk-AAAA", "lap-BBBB", "intro-EEE"]);
check("hosts: off is absent", P.shares(LIST[2]), false);
check("hosts: an introduced one not allowed yet is never asked", P.shares(LIST[3]), false);
check("hosts: a removed one is never asked", P.shares(LIST[5]), false);
check("hosts: an older daemon (no claim) is never asked", P.shares(LIST[6]), false);
check("attach: control only", LIST.map(P.canAttach), [true, false, false, false, false, false, false]);
check("hosts: a bad id is never asked", P.shares({ id: "a b", active: true, trusted: true, canAgents: "view" }), false);

// ── The argv ─────────────────────────────────────────────────────────────────

check("agents argv", P.agentsCommand("desk-AAAA"), ["rime", "remote", "computers", "agents", "--json", "--", "desk-AAAA"]);
check("agents argv: a hyphen id after --", P.agentsCommand("-x"), ["rime", "remote", "computers", "agents", "--json", "--", "-x"]);
check("peek argv", P.peekCommand("desk-AAAA", 7), ["rime", "remote", "computers", "peek", "--json", "--", "desk-AAAA", "7"]);
check("attach argv", P.attachCommand("desk-AAAA", 4294967295),
      ["rime", "remote", "computers", "attach", "--", "desk-AAAA", "4294967295"]);
check("attach in a terminal", P.terminalCommand("/s/rime-terminal.sh", "desk-AAAA", 3),
      ["sh", "/s/rime-terminal.sh", "rime", "remote", "computers", "attach", "--", "desk-AAAA", "3"]);
check("argv: no bad id",
      [P.agentsCommand("$(touch PWNED)"), P.peekCommand("a;b", 1), P.attachCommand("", 1), P.agentsCommand(null)],
      [null, null, null, null]);
check("argv: no bad session",
      [P.peekCommand("d", -1), P.peekCommand("d", 1.5), P.peekCommand("d", "3"), P.attachCommand("d", 4294967296),
       P.attachCommand("d", NaN), P.terminalCommand("", "d", 1)],
      [null, null, null, null, null, null]);

// ── What `computers agents --json` answered ──────────────────────────────────

const HOSTILE = "$(touch PWNED) <b>bold</b> \u001b[31mred\u001b[0m\nsecond\u2028line\u202eevil";
const OK = JSON.stringify({
    id: "desk-AAAA", name: "Desk", truncated: false, unreadable: 0,
    sessions: [
        { id: 3, agent: "codex", program: "codex", args: [], cwd: "/home/a/old", project: null, project_name: null,
          name: null, title: null, state: "complete", detail: null, paused: false, started: 100, last_activity: 900,
          exit_code: 0, exit_signal: null, attached: 0, cols: 80, rows: 24 },
        { id: 7, agent: "claude", program: "claude", args: [HOSTILE], cwd: "/home/a/" + HOSTILE,
          project: "/home/a/rime", project_name: HOSTILE, name: HOSTILE, title: "t", state: "waiting_for_user",
          detail: null, paused: false, started: 200, last_activity: 300, exit_code: null, exit_signal: null,
          attached: 2, cols: 80, rows: 24 },
        { id: 9, agent: "claude", cwd: "/w/proj/", name: null, title: "Fixing the build", state: "teleporting",
          started: 400, last_activity: 500, exit_code: null, exit_signal: null, attached: null },
        { id: -1, agent: "bad" },
        { id: "8", agent: "bad" },
        "junk"
    ]
});
const r = P.readAgents(0, OK);
check("ok: status", r.status, "ok");
check("ok: bad sessions dropped, live first then latest", r.sessions.map(function (s) { return s.id }), [9, 7, 3]);
const hostile = r.sessions[1];
check("hostile: name is one plain line, capped",
      [hostile.name.indexOf("\n"), hostile.name.indexOf("\u001b"), hostile.name.indexOf("\u2028"), hostile.name.indexOf("\u202e")],
      [-1, -1, -1, -1]);
check("hostile: the text is kept as text (nothing to run, no markup taken)", hostile.name.indexOf("$(touch PWNED) <b>bold</b>"), 0);
check("hostile: project and cwd plain too",
      [/[\u0000-\u001f\u2028\u202e]/.test(hostile.project_name), /[\u0000-\u001f\u2028\u202e]/.test(hostile.cwd)], [false, false]);
check("hostile: args are never read", Object.keys(hostile).indexOf("args"), -1);
check("unknown state of a live session reads as starting", r.sessions[0].state, "starting");
check("attached: a count, 0 when absent", [r.sessions[0].attached, hostile.attached], [0, 2]);
check("label: name, then title, then nothing", r.sessions.map(P.sessionLabel), ["Fixing the build", hostile.name, ""]);
check("where: project, else the last part of cwd", [P.where(r.sessions[0]), P.where(r.sessions[2])], ["proj", "old"]);
check("host line: counts", P.hostLine(r, false), "3 sessions · 2 running · 1 needs you");
check("host line: none", P.hostLine(P.readAgents(0, '{"id":"d","name":"D","sessions":[]}'), false), "No agent sessions");
check("host line: some left out",
      P.hostLine(P.readAgents(0, '{"id":"d","name":"D","sessions":[],"truncated":true,"unreadable":0}'), false),
      "No agent sessions · some were left out");
check("host line: before the first answer", [P.hostLine(null, true), P.hostLine(null, false)], ["Checking…", "Not checked yet"]);

const REFUSED = JSON.stringify({ error: "'Desk' does not let this computer see its agent sessions. A person there can allow it with `rime remote computers grant <this computer> agents view`" });
const stopped = P.readAgents(1, REFUSED);
check("refused (stale claim): stopped, no sessions", [stopped.status, stopped.sessions.length], ["stopped", 0]);
check("refused: one fixed quiet line, never the daemon's words", P.hostLine(stopped, false), "It no longer shares its agents with this computer");
const away = P.readAgents(1, JSON.stringify({ error: "could not reach 'Desk': connection refused" }));
check("offline: away", away.status, "away");
check("offline: one fixed quiet line", P.hostLine(away, false), "Not reachable right now");
check("junk, empty, a crash: away",
      [P.readAgents(0, "nope").status, P.readAgents(1, "").status, P.readAgents(0, '{"error":"x"}').status,
       P.readAgents(0, "[]").status, P.readAgents(137, OK).status],
      ["away", "away", "away", "away", "away"]);
check("a hostile error is never shown", P.hostLine(P.readAgents(1, JSON.stringify({ error: HOSTILE })), false), "Not reachable right now");

const many = { status: "ok", sessions: [1, 2, 3, 4, 5, 6, 7, 8].map(function (i) { return { id: i } }) };
check("at most six rows, the rest counted", [P.visible(many.sessions).shown.length, P.visible(many.sessions).hidden], [6, 2]);

// ── What `computers peek --json` answered ────────────────────────────────────

const peek = P.readPeek(0, JSON.stringify({
    id: "desk-AAAA", name: "Desk", session: 7, cols: 80, rows: 24, state: "working",
    text: "one\ttab\n" + HOSTILE + "\n\n\n"
}));
check("peek: ok", peek.ok, true);
check("peek: lines kept, trailing blank lines dropped, controls gone",
      peek.text, "one    tab\n$(touch PWNED) <b>bold</b>  [31mred [0m\nsecond line evil");
const long = P.readPeek(0, JSON.stringify({ text: Array.from({ length: 40 }, function (_, i) { return "l" + i }).join("\n") }));
check("peek: the last lines only", [long.text.split("\n").length, long.text.split("\n").pop()], [P.PEEK_LINES, "l39"]);
const peekErr = P.readPeek(1, JSON.stringify({ error: "That agent session has exited.\nx" }));
check("peek: an error is one plain line", [peekErr.ok, peekErr.error], [false, "That agent session has exited. x"]);
check("peek: junk", P.readPeek(0, "garbage").ok, false);

if (failed) {
    console.error(`passed=${passed} failed=${failed}`);
    process.exit(1);
}
console.log(`passed=${passed} failed=0`);
