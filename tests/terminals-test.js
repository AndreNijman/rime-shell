#!/usr/bin/env node
// tests/terminals-test.js — src/services/terminals.js, the file the shell
// loads (TerminalService.qml, CenterContent.qml), not a copy of it.
//
// What it pins:
//   * the MEASURED identities of the two terminals Rime ships (nixpkgs Ghostty
//     1.4.0: desktop id com.mitchellh.ghostty.desktop, Wayland app id
//     com.mitchellh.ghostty; Alacritty.desktop / "Alacritty"), so a typo that
//     would make the Settings choice write a desktop id xdg-terminal-exec
//     cannot find fails here, not on a user's machine;
//   * Ghostty is the default, and a direct Ghostty launch never runs
//     single-instance (the PID would be gone at once);
//   * withDefault(): the chosen terminal first, the other as fallback, every
//     user line about neither kept in order, an exclusion of the chosen one
//     dropped, idempotent, no duplicated header;
//   * displayName(): the notch names Ghostty, not "Com.mitchellh.ghostty".
"use strict";
const T = require("../src/services/terminals.js");

let passed = 0, failed = 0;
function check(name, cond, detail) {
    if (cond) { passed++; console.log("  ok   " + name); }
    else { failed++; console.log("  FAIL " + name + (detail !== undefined ? "  -- " + JSON.stringify(detail) : "")); }
}

// ── identities ───────────────────────────────────────────────────────────────
const g = T.byKey("ghostty"), a = T.byKey("alacritty");
check("Ghostty is known", g !== null);
check("Alacritty is known (kept as the alternative)", a !== null);
check("Ghostty's desktop id is the measured one", g && g.desktopId === "com.mitchellh.ghostty.desktop", g && g.desktopId);
check("Alacritty's desktop id is the measured one", a && a.desktopId === "Alacritty.desktop", a && a.desktopId);
check("Ghostty's measured Wayland app id is recognised", T.keyForAppId("com.mitchellh.ghostty") === "ghostty");
check("Alacritty's app id is recognised", T.keyForAppId("Alacritty") === "alacritty");
check("app ids match case-insensitively (X11 class vs app_id)", T.keyForAppId("alacritty") === "alacritty");
check("an unknown app id is not a terminal", T.keyForAppId("firefox") === "");
check("an empty app id is not a terminal", T.keyForAppId("") === "" && T.keyForAppId(undefined) === "");
check("the default terminal is Ghostty", T.DEFAULT_KEY === "ghostty");
check("a direct Ghostty launch turns single-instance off before -e",
      g && g.execArgs.join(" ") === "--gtk-single-instance=false -e", g && g.execArgs);
check("keyForDesktopId maps --print-id output", T.keyForDesktopId("com.mitchellh.ghostty.desktop\n") === "ghostty"
      && T.keyForDesktopId("Alacritty.desktop") === "alacritty" && T.keyForDesktopId("kitty.desktop") === "");

// ── names in the notch ──────────────────────────────────────────────────────
check("the notch names Ghostty by name", T.displayName("com.mitchellh.ghostty") === "Ghostty");
check("the notch names Alacritty", T.displayName("Alacritty") === "Alacritty");
check("any other app id is passed through untouched", T.displayName("org.gnome.Nautilus") === "org.gnome.Nautilus");

// ── reading a list ──────────────────────────────────────────────────────────
check("firstPreferred skips comments, directives and exclusions",
      T.firstPreferred("# c\n\n/execarg_default:x.desktop:-e\n-kitty.desktop\n+Alacritty.desktop\nfoot.desktop\n") === "Alacritty.desktop");
check("firstPreferred of nothing is empty", T.firstPreferred("") === "" && T.firstPreferred(undefined) === "");

// ── writing a list ──────────────────────────────────────────────────────────
const fresh = T.withDefault("", "ghostty");
check("a fresh list names Ghostty first, then Alacritty",
      fresh === T.HEADER + "\ncom.mitchellh.ghostty.desktop\nAlacritty.desktop\n", fresh);
check("choosing Alacritty puts it first and keeps Ghostty as the fallback",
      T.firstPreferred(T.withDefault(fresh, "alacritty")) === "Alacritty.desktop"
      && T.withDefault(fresh, "alacritty").indexOf("com.mitchellh.ghostty.desktop") > 0);

const user = "# mine\nkitty.desktop\n-com.mitchellh.ghostty.desktop\n/execarg_default:kitty.desktop:--\nAlacritty.desktop\n";
const out = T.withDefault(user, "ghostty");
check("choosing Ghostty makes it the first preference", T.firstPreferred(out) === "com.mitchellh.ghostty.desktop", out);
check("an exclusion of the chosen terminal is dropped (it would defeat the choice)",
      out.indexOf("-com.mitchellh.ghostty.desktop") < 0, out);
check("the user's own lines about other terminals are kept, in order",
      out.indexOf("# mine") >= 0 && out.indexOf("kitty.desktop") >= 0
      && out.indexOf("/execarg_default:kitty.desktop:--") > out.indexOf("\nkitty.desktop"), out);
check("each known terminal appears exactly once",
      out.split("\n").filter(l => l === "com.mitchellh.ghostty.desktop").length === 1
      && out.split("\n").filter(l => l === "Alacritty.desktop").length === 1, out);
check("writing twice is the same as writing once", T.withDefault(out, "ghostty") === out);
check("switching back and forth does not grow the file",
      T.withDefault(T.withDefault(out, "alacritty"), "ghostty") === out);
check("the header is never duplicated", T.withDefault(out, "alacritty").split(T.HEADER).length === 2);
check("an unknown key writes nothing", T.withDefault(user, "kitty") === null);

console.log("\npassed=" + passed + " failed=" + failed);
process.exit(failed === 0 ? 0 : 1);
