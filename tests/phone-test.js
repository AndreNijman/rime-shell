#!/usr/bin/env node
// Tests for src/services/phone.js: what the Phone page reads out of
// `rime remote messages|calls|photos --json`, the states it can be in, and the
// argv it may run. The JSON below is in the shapes rime-os
// rimed/rime/src/remote.rs prints (its own fixtures, re-serialised the way the
// CLI does), plus the error and empty answers.
//
//   node tests/phone-test.js

"use strict";

const path = require("path");
const P = require(path.join(__dirname, "..", "src", "services", "phone.js"));

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

// ── what the CLI answered ────────────────────────────────────────────────────

check("a JSON answer with exit 0 is the data",
      P.outcome(0, '{"device":"Pixel","threads":[]}', "", "Messages"),
      {ok: true, data: {device: "Pixel", threads: []}, error: ""});
check("a refusal is the daemon's sentence, as it said it",
      P.outcome(1, '{"error":"Pixel has Messages turned off. Turn on Messages on your computer in Rime Remote on the phone."}\n',
                "rime: Pixel has Messages turned off. Turn on Messages on your computer in Rime Remote on the phone.\n", "Messages"),
      {ok: false, data: null,
       error: "Pixel has Messages turned off. Turn on Messages on your computer in Rime Remote on the phone."});
check("a refusal with exit 0 is still a refusal",
      P.outcome(0, '{"error":"busy"}', "", "Messages").ok, false);
check("a daemon that is not running: stderr's last line, without rime:",
      P.outcome(1, "", "rime: could not reach rime-remoted\nrime: is it running? rime remote enable\n", "Messages"),
      {ok: false, data: null, error: "is it running? rime remote enable"});
check("nothing said at all names the command and the code",
      P.outcome(127, "", "", "Calls").error, "Calls exited 127");
check("exit 0 with something unreadable is an error, not data",
      P.outcome(0, "Pixel: 2 conversations", "", "Messages"),
      {ok: false, data: null, error: "Messages gave an answer this Shell cannot read"});
check("a JSON array is not an answer",
      P.outcome(0, "[]", "", "Photos").ok, false);

// ── messages ─────────────────────────────────────────────────────────────────

const THREADS = JSON.stringify({
    device: "Pixel",
    threads: [
        {id: 7, addresses: ["+15555215556"], snippet: "hi there", date_ms: NOW - 120000, unread: 2, count: 5},
        {id: 8, addresses: ["5556"], name: "Test Name", snippet: "x", date_ms: NOW - 7200000, unread: 0, count: 1},
        {id: 9, addresses: ["5556", "5557"], snippet: "group", date_ms: NOW - 9000000, unread: 0, count: 3}
    ],
    changed_ms: NOW - 1000
}, null, 2);

const threads = P.parseThreads(JSON.parse(THREADS));
check("three conversations, in the phone's order",
      threads.threads.map(t => t.id), [7, 8, 9]);
check("a conversation with no contact is titled by its number",
      threads.threads[0].title, "+15555215556");
check("a contact's name wins over the number",
      threads.threads[1].title, "Test Name");
check("unread and snippet come through",
      [threads.threads[0].unread, threads.threads[0].snippet], [2, "hi there"]);
check("a thread with two addresses is a group (no reply box)",
      threads.threads.map(t => t.group), [false, false, true]);
check("changed_ms is kept",
      threads.changedMs, NOW - 1000);
check("an empty list is an empty list, not null",
      P.parseThreads({device: "Pixel", threads: []}).threads, []);
check("a thread reply is not a list reply",
      P.parseThreads({device: "Pixel", thread: 7, messages: []}), null);
check("an id past 2^53 is dropped, not rounded into another thread",
      P.parseThreads({device: "P", threads: [{id: 9007199254740993, addresses: ["1"], snippet: "", date_ms: 1, unread: 0, count: 1},
                                              {id: 3, addresses: ["1"], snippet: "", date_ms: 1, unread: 0, count: 1}]}).threads.map(t => t.id),
      [3]);
check("a thread with no address and no name still has a title",
      P.parseThreads({device: "P", threads: [{id: 1, addresses: [], snippet: "", date_ms: 1, unread: 0, count: 0}]}).threads[0].title,
      "Unknown number");

const THREAD = JSON.stringify({
    device: "Pixel", thread: 7,
    messages: [
        {id: 2, date_ms: 2000, from_me: true, body: "second", status: "failed"},
        {id: 1, date_ms: 1000, from_me: false, body: "first\nline", status: "received"}
    ]
}, null, 2);
const thread = P.parseThread(JSON.parse(THREAD));
check("messages read down: oldest first",
      thread.messages.map(m => m.id), [1, 2]);
check("a newline in a message body is kept",
      thread.messages[0].body, "first\nline");
check("--before for the page before is the oldest shown",
      thread.oldestMs, 1000);
check("a failed send says so under the message",
      P.messageStatus(thread.messages[1]), "Not sent");
check("a received message says nothing under it",
      P.messageStatus(thread.messages[0]), "");
check("an unknown status is read as received, not invented",
      P.parseThread({device: "P", thread: 1, messages: [{id: 1, date_ms: 1, from_me: false, body: "", status: "zzz"}]}).messages[0].status,
      "received");
check("a list reply is not a thread reply",
      P.parseThread(JSON.parse(THREADS)), null);
check("an older page goes in front, without a message twice",
      P.prependOlder([{id: 0, dateMs: 500}, {id: 1, dateMs: 1000}], thread.messages).map(m => m.id), [0, 1, 2]);
check("an empty conversation page",
      P.parseThread({device: "P", thread: 4, messages: []}).oldestMs, 0);

check("a reply of plain text is sent as typed",
      P.replyCheck("On my way\nsee you"), {ok: true, text: "On my way\nsee you", error: ""});
check("an empty reply is refused by the field",
      P.replyCheck("   \n").ok, false);
check("2,000 characters is allowed",
      P.replyCheck("a".repeat(2000)).ok, true);
check("2,001 characters is not",
      P.replyCheck("a".repeat(2001)).error, "A message is at most 2,000 characters.");
check("characters are counted, not UTF-16 units (emoji)",
      P.replyCheck("\u{1F600}".repeat(2000)).ok, true);
check("a tab is a control character",
      P.replyCheck("a\tb").ok, false);
check("a reply that starts with -- is just text",
      P.replyCheck("--thread 9").ok, true);

// ── calls ────────────────────────────────────────────────────────────────────

const CALLS = JSON.stringify({
    device: "Pixel",
    current: {state: "ringing", number: "5556", since_ms: NOW - 5000},
    calls: [
        {number: "5556", name: "Test Name", type: "missed", date_ms: NOW - 60000, duration_s: 0},
        {number: "", type: "incoming", date_ms: NOW - 3600000, duration_s: 75}
    ]
}, null, 2);
const calls = P.parseCalls(JSON.parse(CALLS));
check("the call now",
      calls.current, {state: "ringing", number: "5556", name: "", sinceMs: NOW - 5000});
check("two calls in the history",
      calls.calls.map(c => c.type), ["missed", "incoming"]);
check("no call now is null",
      P.parseCalls({device: "Pixel", current: null, calls: []}).current, null);
check("a history that could not be read: null, with why",
      (c => [c.calls, c.historyError])(P.parseCalls({device: "Pixel", current: null, history_error: "not allowed"})),
      [null, "not allowed"]);
check("an empty history is an empty list",
      P.parseCalls({device: "Pixel", current: null, calls: []}).calls, []);
check("a call of a type the contract does not name is dropped",
      P.parseCalls({device: "P", current: null, calls: [{number: "1", type: "voicemail", date_ms: 1, duration_s: 0}]}).calls, []);
check("a current call in an unknown state is no call",
      P.parseCalls({device: "P", current: {state: "dialing", since_ms: 1}}).current, null);
check("a name with a number",
      P.caller("5556", "Test Name"), "Test Name (5556)");
check("no number at all",
      P.caller("", ""), "Withheld number");
check("durations in the CLI's words",
      [P.duration(0), P.duration(45), P.duration(75), P.duration(600)], ["", "45s", "1m 15s", "10m 00s"]);
check("call types in plain words",
      ["incoming", "outgoing", "missed", "rejected"].map(P.callTypeLabel), ["Incoming", "Outgoing", "Missed", "Declined"]);
check("call states in plain words",
      ["ringing", "active", "held"].map(P.callStateLabel), ["Ringing", "On a call", "On hold"]);

check("a number with spaces and brackets is dialled clean",
      P.dialNumber(" +61 (8) 9555-0123 "), "+61895550123");
check("a number with a letter is not a number",
      P.dialNumber("555-CALL"), "");
check("a + in the middle is not a number",
      P.dialNumber("55+5"), "");
check("two digits is too short",
      P.dialNumber("12"), "");
check("21 digits is too long",
      P.dialNumber("1".repeat(21)), "");
check("a leading dash never reaches the CLI",
      P.dialNumber("--device=x"), "");

// ── photos ───────────────────────────────────────────────────────────────────

const PHOTOS = JSON.stringify({
    device: "Pixel", partial: true,
    photos: [
        {id: 5, name: "IMG_1.jpg", date_ms: 1000, width: 4000, height: 3000, size: 2500000, mime: "image/jpeg",
         thumb: "/run/user/1/rime-remote/photos/d/5.jpg"},
        {id: 6, name: "Screenshot.png", date_ms: 2000, width: 1080, height: 2400, size: 640000, mime: "image/png"},
        {id: 4, name: "x.jpg", date_ms: 500, width: 1, height: 1, size: 1, mime: "image/jpeg", thumb: "relative/4.jpg"}
    ]
}, null, 2);
const photos = P.parsePhotos(JSON.parse(PHOTOS));
check("photos newest first",
      photos.photos.map(p => p.id), [6, 5, 4]);
check("partial access is kept",
      photos.partial, true);
check("a photo with no preview has an empty thumb",
      photos.photos[0].thumb, "");
check("a relative thumb path is not drawn",
      photos.photos[2].thumb, "");
check("the next page starts before the oldest",
      photos.oldestMs, 500);
check("full access is not partial",
      P.parsePhotos({device: "P", partial: false, photos: []}).partial, false);
check("no photos is an empty grid",
      P.parsePhotos({device: "P", partial: false, photos: []}).photos, []);
check("a further page goes after, without a photo twice",
      P.appendOlder([{id: 6}, {id: 5}], [{id: 5}, {id: 3}]).map(p => p.id), [6, 5, 3]);
check("a thumb path becomes a file URL, escaped",
      P.fileUrl("/run/user/1/rime-remote/photos/a b/5.jpg"), "file:///run/user/1/rime-remote/photos/a%20b/5.jpg");
check("no path, no URL",
      P.fileUrl(""), "");

const SAVED = JSON.stringify({saved: true, device: "Pixel", photo: 42,
                              path: "/home/a/Pictures/Rime Remote/IMG_1.jpg", len: 2500000});
check("where the photo went",
      P.parseSaved(JSON.parse(SAVED)), {path: "/home/a/Pictures/Rime Remote/IMG_1.jpg", len: 2500000, photo: 42});
check("a save answer without a path is not a save",
      P.parseSaved({saved: true, device: "P", photo: 1}), null);
check("sizes",
      [P.bytes(512), P.bytes(640000), P.bytes(2500000)], ["512 B", "625 KB", "2.4 MB"]);

// ── the phone, and what the page says ────────────────────────────────────────

function dev(id, name, can, extra) {
    return Object.assign({id: id, name: name, revokedMs: null,
                          phone: can === null ? null : {battery: 62, can: can}}, extra || {});
}
const pixel = dev("dA", "Pixel", ["ring", "messages", "calls", "calls_history", "calls_answer", "calls_dial", "photos"]);
const tablet = dev("dB", "Tablet", ["ring"]);
const old = dev("dC", "Old phone", null);
const gone = dev("dD", "Gone", ["messages"], {revokedMs: 5});

check("no devices, no phone",
      P.choosePhone([], []), null);
check("only a revoked device, no phone",
      P.choosePhone([gone], ["dD"]), null);
check("a connected phone is chosen over an earlier one",
      P.choosePhone([tablet, pixel], ["dA"]).id, "dA");
check("with none connected, the first that reported",
      P.choosePhone([old, tablet, pixel], []).id, "dB");
check("a device that never reported is still the phone when it is the only one",
      P.choosePhone([old], []).id, "dC");

check("not asked yet is loading, never 'no phone'",
      P.pageState(null, [], false, ""), "loading");
check("an error wins",
      P.pageState(pixel, ["dA"], true, "rime remote devices exited 1"), "error");
check("asked, nothing paired",
      P.pageState(null, [], true, ""), "none");
check("paired, not connected",
      P.pageState(pixel, [], true, ""), "offline");
check("connected, never reported what it shares",
      P.pageState(old, ["dC"], true, ""), "noreport");
check("connected and reported",
      P.pageState(pixel, ["dA"], true, ""), "ready");
check("the no-phone sentence says where to pair",
      P.pageMessage("none", null, "").title, "No phone paired");
check("the offline sentence names the phone",
      P.pageMessage("offline", pixel, "").title, "Pixel is not connected");

check("offers reads the can words",
      ["messages", "calls", "photos"].map(f => P.offers(pixel, f)), [true, true, true]);
check("a phone without the words offers none",
      ["messages", "calls", "photos"].map(f => P.offers(tablet, f)), [false, false, false]);
check("a phone that never reported offers nothing",
      P.offers(old, "messages"), false);
check("messages off names the exact switch",
      P.offMessage(tablet, "messages"),
      {title: "Messages is off on Tablet",
       hint: "In Rime Remote on the phone, turn on \"Messages on your computer\" and allow it to read SMS."});
check("calls off names the exact switch",
      P.offMessage(tablet, "calls").hint.includes("\"Calls on your computer\""), true);
check("photos off also names the lock",
      P.offMessage(tablet, "photos").hint,
      "In Rime Remote on the phone, turn on \"Photos on your computer\" and allow it to see photos, and unlock Rime Remote on the phone.");
check("no UI string has an em dash",
      ["messages", "calls", "photos"].map(f => JSON.stringify(P.offMessage(pixel, f)))
          .concat(["loading", "error", "none", "offline", "noreport"].map(s => JSON.stringify(P.pageMessage(s, pixel, ""))))
          .some(s => s.includes("—")), false);

check("everything a full connection can do",
      P.callAbilities(pixel), {history: true, answer: true, dial: true});
check("calls without dial (a companion connection never has it)",
      P.callAbilities(dev("dE", "C", ["calls", "calls_history", "calls_answer"])), {history: true, answer: true, dial: false});
check("no report, no abilities",
      P.callAbilities(old), {history: false, answer: false, dial: false});

check("short times",
      [P.when(NOW - 10000, NOW), P.when(NOW - 300000, NOW), P.when(NOW - 3 * 3600000, NOW), P.when(NOW - 2 * 86400000, NOW)],
      ["now", "5m", "3h", "2d"]);
check("no time, nothing",
      P.when(0, NOW), "");

// ── argv ─────────────────────────────────────────────────────────────────────

check("the conversation list",
      P.threadsCommand("dA"), ["rime", "remote", "messages", "--json", "--device=dA", "--limit", "30"]);
check("one conversation",
      P.threadCommand("dA", 7, 0), ["rime", "remote", "messages", "--json", "--device=dA", "--thread", "7", "--limit", "30"]);
check("the page before",
      P.threadCommand("dA", 7, 1000).slice(-2), ["--before", "1000"]);
check("send: the device, the thread, and no text anywhere in argv",
      P.sendCommand("dA", 7), ["rime", "remote", "messages", "send", "--device=dA", "--thread", "7", "--json"]);
check("a device id that starts with a dash stays one argument",
      P.sendCommand("-x9", 7)[4], "--device=-x9");
check("calls",
      P.callsCommand("dA"), ["rime", "remote", "calls", "--json", "--device=dA", "--limit", "30"]);
check("dial",
      P.dialCommand("dA", "+61895550123"), ["rime", "remote", "calls", "dial", "--device=dA", "--json", "+61895550123"]);
check("hang up",
      P.hangupCommand("dA"), ["rime", "remote", "calls", "hangup", "--device=dA", "--json"]);
check("photos, and the page after",
      [P.photosCommand("dA", 0), P.photosCommand("dA", 500).slice(-2)],
      [["rime", "remote", "photos", "--json", "--device=dA", "--limit", "30"], ["--before", "500"]]);
check("save",
      P.saveCommand("dA", 42), ["rime", "remote", "photos", "save", "42", "--device=dA", "--json"]);
check("page sizes stay inside the CLI's limits (messages 50, calls 50, photos 60)",
      P.PAGE_LIMIT >= 1 && P.PAGE_LIMIT <= 50, true);

if (failed > 0) {
    console.error(`\n${failed} assertion(s) failed`);
    process.exit(1);
}
console.log("\nall assertions passed");
