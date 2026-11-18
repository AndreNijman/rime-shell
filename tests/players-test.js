#!/usr/bin/env node
// players-test.js — what src/services/players.js decides about a phone's player.
//
//      node tests/players-test.js
//
// Rime Remote shows a paired phone's media as org.mpris.MediaPlayer2.rime_phone.<id>
// (rime-os docs/remote-live-contract.md §2.8). The visualiser must not run for it
// and the notch prefers the computer's own player. The real-Quickshell half is in
// tests/run-visualiser-battery-test.sh (section 3).
const P = require("../src/services/players.js");

let pass = 0, fail = 0;
function is(name, got, want) {
    const g = JSON.stringify(got), w = JSON.stringify(want);
    if (g === w) { console.log("PASS  " + name); pass++; }
    else { console.log("FAIL  " + name + "\n      want " + w + "\n      got  " + g); fail++; }
}

const PLAYING = 1, PAUSED = 2;
const phone = (id, st) => ({ dbusName: "org.mpris.MediaPlayer2.rime_phone." + id, playbackState: st, id: "phone-" + id });
const local = (n, st) => ({ dbusName: "org.mpris.MediaPlayer2." + n, playbackState: st, id: n });

is("a phone's bus name is a phone's", P.isPhone(phone("d0102", PLAYING)), true);
is("playerctl's short spelling is a phone's too", P.isPhone({ dbusName: "rime_phone.d01" }), true);
is("spotify is the computer's", P.isPhone(local("spotify", PLAYING)), false);
is("a name merely containing rime_phone later is not a phone's",
   P.isPhone(local("vlc.rime_phone.x", PLAYING)), false);
is("a player with no bus name is the computer's", P.isPhone({}), false);
is("null is not a phone", P.isPhone(null), false);

is("only a phone playing: nothing local plays", P.localPlaying([phone("a", PLAYING)], PLAYING), false);
is("a local player paused and a phone playing: nothing local plays",
   P.localPlaying([local("spotify", PAUSED), phone("a", PLAYING)], PLAYING), false);
is("a local player playing counts", P.localPlaying([phone("a", PLAYING), local("mpv", PLAYING)], PLAYING), true);
is("no players: nothing plays", P.localPlaying([], PLAYING), false);
is("a missing list: nothing plays", P.localPlaying(undefined, PLAYING), false);

is("the notch prefers the computer's player listed after a phone's",
   P.preferLocal([phone("a", PLAYING), local("mpv", PAUSED)]).id, "mpv");
is("the first computer player wins among computer players",
   P.preferLocal([local("spotify", PAUSED), phone("a", PLAYING), local("mpv", PLAYING)]).id, "spotify");
is("a phone's player alone is shown", P.preferLocal([phone("a", PLAYING), phone("b", PAUSED)]).id, "phone-a");
is("no players: none", P.preferLocal([]), null);
is("a missing list: none", P.preferLocal(undefined), null);

console.log("players-test: passed=" + pass + " failed=" + fail);
process.exit(fail ? 1 : 0);
