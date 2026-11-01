// ─── terminals.js ────────────────────────────────────────────────────────────
// What the shell knows about terminal emulators, in one place, so the launch
// paths, Settings → Misc → Default terminal and the centre notch agree, and so
// tests/terminals-test.js drives the file the shell loads rather than a copy.
//
// ── Who decides which terminal opens ─────────────────────────────────────────
//
// Not this file. The system default is whatever `xdg-terminal-exec` resolves
// (the freedesktop terminal spec): the first usable desktop id in
//   $XDG_CONFIG_HOME/[<desktop>-]xdg-terminals.list   (the user's, wins)
//   /etc/xdg/xdg-terminals.list                        (the OS's: Ghostty)
// Every shell launch goes through that helper (DesktopExec, the context menu,
// SUPER+T, src/scripts/rime-terminal.sh), so the Settings choice is one line in
// the user's list and nothing else has to be told.
//
// ── Measured, not assumed (nixpkgs Ghostty 1.4.0, headless sway, 2026-11-02) ─
//
//   desktop id   com.mitchellh.ghostty.desktop   (its Exec= is
//                `ghostty --gtk-single-instance=true`, X-TerminalArgExec=-e)
//   app id       com.mitchellh.ghostty           (swaymsg get_tree)
//   Alacritty    Alacritty.desktop, app id "Alacritty"
//
// Ghostty runs single-instance by default on Linux (`detect`), so a bare
// `ghostty` may hand its window to a running instance and exit at once. `-e`
// forces gtk-single-instance=false (Ghostty's own docs, and measured: a second
// `ghostty --gtk-single-instance=true -e sleep 40` lived the full 40 s), so a
// launch with a command keeps its PID. `execArgs` still names the flag for a
// direct launch, because "it happens to be forced" is not a contract.
//
// Plain JS, no `.pragma library`, so node can require it (as title.js does).

var KNOWN = [
    {
        key:       "ghostty",
        name:      "Ghostty",
        desktopId: "com.mitchellh.ghostty.desktop",
        appIds:    ["com.mitchellh.ghostty", "ghostty"],
        bin:       "ghostty",
        execArgs:  ["--gtk-single-instance=false", "-e"]
    },
    {
        key:       "alacritty",
        name:      "Alacritty",
        desktopId: "Alacritty.desktop",
        appIds:    ["Alacritty", "alacritty"],
        bin:       "alacritty",
        execArgs:  ["-e"]
    }
];

// The OS default when nothing says otherwise (Rime on NixOS ships Ghostty).
var DEFAULT_KEY = "ghostty";

function byKey(key) {
    for (var i = 0; i < KNOWN.length; i++)
        if (KNOWN[i].key === key) return KNOWN[i];
    return null;
}

// A desktop id as xdg-terminal-exec prints it (`--print-id`), or as a list
// line names it, to a known key. "" for anything else: a user who chose
// kitty by hand is shown neither option selected, not a wrong one.
function keyForDesktopId(id) {
    var s = String(id || "").trim();
    for (var i = 0; i < KNOWN.length; i++)
        if (KNOWN[i].desktopId === s) return KNOWN[i].key;
    return "";
}

// Is this toplevel app id (Wayland app_id / X11 class) a known terminal?
function keyForAppId(appId) {
    var s = String(appId || "").trim();
    if (s === "") return "";
    for (var i = 0; i < KNOWN.length; i++)
        for (var j = 0; j < KNOWN[i].appIds.length; j++)
            if (KNOWN[i].appIds[j].toLowerCase() === s.toLowerCase()) return KNOWN[i].key;
    return "";
}

// The name the notch shows for a focused app. niri and labwc report the app
// id, and Ghostty's is reverse-DNS: capitalising it gave
// "Com.mitchellh.ghostty". Anything not a known terminal is returned as given.
function displayName(appId) {
    var k = keyForAppId(appId);
    return k !== "" ? byKey(k).name : String(appId || "");
}

// ── xdg-terminals.list ───────────────────────────────────────────────────────
// One entry per line: a desktop id, `+id` (same), `-id` (exclude it from the
// fallback), `/directive...`, `#` comments and blank lines.

function _entryId(line) {
    var s = String(line).trim();
    if (s === "" || s.charAt(0) === "#" || s.charAt(0) === "/") return null;
    if (s.charAt(0) === "+" || s.charAt(0) === "-") s = s.slice(1).trim();
    return s === "" ? null : s;
}

// The first desktop id the user's own list prefers, "" if it names none.
function firstPreferred(text) {
    var lines = String(text || "").split("\n");
    for (var i = 0; i < lines.length; i++) {
        var raw = String(lines[i]).trim();
        if (raw.charAt(0) === "-") continue;
        var id = _entryId(raw);
        if (id !== null) return id;
    }
    return "";
}

// The user's list with `key` first. Every line the user wrote that is about
// neither known terminal is kept, in order; lines about the known terminals
// (including a `-` exclusion of the chosen one, which would defeat the
// choice) are replaced by: the chosen terminal, then the other known one as
// its fallback. Returns null for an unknown key.
var HEADER = "# Written by Rime Shell (Settings > Misc > Default terminal).";

function withDefault(text, key) {
    var chosen = byKey(key);
    if (!chosen) return null;
    var known = ({});
    for (var i = 0; i < KNOWN.length; i++) known[KNOWN[i].desktopId] = true;

    var kept = [];
    var lines = String(text || "").split("\n");
    for (var j = 0; j < lines.length; j++) {
        var line = String(lines[j]);
        if (line.trim() === HEADER) continue;
        var id = _entryId(line);
        if (id !== null && known[id]) continue;
        kept.push(line);
    }
    while (kept.length > 0 && kept[kept.length - 1].trim() === "") kept.pop();
    while (kept.length > 0 && kept[0].trim() === "") kept.shift();

    var out = [HEADER, chosen.desktopId];
    for (var k = 0; k < KNOWN.length; k++)
        if (KNOWN[k].key !== key) out.push(KNOWN[k].desktopId);
    return out.concat(kept).join("\n") + "\n";
}

if (typeof module !== "undefined" && module.exports) {
    module.exports = {
        KNOWN: KNOWN, DEFAULT_KEY: DEFAULT_KEY, HEADER: HEADER,
        byKey: byKey, keyForDesktopId: keyForDesktopId, keyForAppId: keyForAppId,
        displayName: displayName, firstPreferred: firstPreferred, withDefault: withDefault
    };
}
