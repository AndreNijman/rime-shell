// ─── players.js ──────────────────────────────────────────────────────────────
// Which MPRIS players are this computer's own, and which one the notch shows.
//
// Rime Remote shows what a paired phone is playing as an MPRIS player named
// org.mpris.MediaPlayer2.rime_phone.<id> (rime-os, docs/remote-live-contract.md
// §2.8). It is read-only: CanControl is false and every method is refused, and
// its sound comes out of the phone, not this computer. So:
//
//   - the audio visualiser must not run for it: cava would capture this
//     computer's silence and the bars would only cost power (CavaService);
//   - the notch shows a computer player ahead of a phone one, because the
//     computer's player is the one the media keys act on (CenterContent).
//
// Lives in its own file so tests/players-test.js drives the code the Shell
// loads.

var PHONE_NAME = "org.mpris.MediaPlayer2.rime_phone";

// True for a phone's player. Quickshell's dbusName is the bus name; the short
// form ("rime_phone.<id>", as playerctl spells it) is accepted too.
function isPhone(player) {
    if (!player) return false;
    var n = player.dbusName ? String(player.dbusName) : "";
    return n.indexOf(PHONE_NAME + ".") === 0 || n.indexOf("rime_phone.") === 0;
}

// True if one of this computer's own players is playing. `playing` is the
// MprisPlaybackState.Playing value (passed in: this file has no QML imports).
function localPlaying(players, playing) {
    if (!players) return false;
    for (var i = 0; i < players.length; i++) {
        var p = players[i];
        if (p && !isPhone(p) && p.playbackState === playing) return true;
    }
    return false;
}

// The player the notch shows: the first computer player, else the first
// phone player, else null. Order within each kind is the list's own.
function preferLocal(players) {
    if (!players || players.length === 0) return null;
    for (var i = 0; i < players.length; i++)
        if (players[i] && !isPhone(players[i])) return players[i];
    return players[0] || null;
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = { PHONE_NAME: PHONE_NAME, isPhone: isPhone, localPlaying: localPlaying, preferLocal: preferLocal };
}
