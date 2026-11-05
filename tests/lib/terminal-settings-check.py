#!/usr/bin/env python3
"""terminal-settings-check.py MODE LIST < TERM records — judge tests/terminal-settings-test.qml.

MODE is "normal" (start / picked / back) or "shadow"; LIST is the user's
~/.config/xdg-terminals.list as the run left it. Prints ok/FAIL lines; exit 1
on any FAIL. Called by tests/run-terminal-settings-test.sh.
"""
import json, sys
mode, listpath = sys.argv[1], sys.argv[2]
recs = {r["step"]: r for r in (json.loads(l) for l in sys.stdin if l.strip())}
fails = 0
def check(cond, msg, rec=None):
    global fails
    if cond:
        print("  ok   " + msg)
    else:
        fails += 1
        print("  FAIL " + msg + ("  -- " + json.dumps(rec) if rec is not None else ""))
try:
    lines = [l for l in open(listpath).read().splitlines() if l and not l.startswith("#")]
except OSError:
    lines = None
if mode == "normal":
    s, p, b = recs.get("start"), recs.get("picked"), recs.get("back")
    check(s is not None and p is not None and b is not None, "every step reported", recs)
    if s and p and b:
        check(s["installed"] == {"ghostty": True, "alacritty": True} and s["segDimmed"] == [False, False],
              "both terminals show as installed (entries found after the late scan)", s)
        check(s["current"] == "ghostty" and s["resolvedId"] == "com.mitchellh.ghostty.desktop" and s["segValue"] == "ghostty",
              "the page starts on what the OS list resolves: Ghostty", s)
        check(s["appIdEntry"] == "com.mitchellh.ghostty",
              "Ghostty's Wayland app id finds its desktop entry", s)
        check(p["current"] == "alacritty" and p["resolvedId"] == "Alacritty.desktop" and p["segValue"] == "alacritty"
              and p["shadowed"] == "" and p["error"] == "" and not p["busy"],
              "choosing Alacritty on the page: xdg-terminal-exec now resolves Alacritty", p)
        check(b["current"] == "ghostty" and b["resolvedId"] == "com.mitchellh.ghostty.desktop" and b["shadowed"] == "",
              "choosing Ghostty again: resolves Ghostty", b)
        check(lines == ["com.mitchellh.ghostty.desktop", "Alacritty.desktop"],
              "the list holds the choice first, the other as fallback, once each", lines)
else:
    r = recs.get("shadow")
    check(r is not None and r["requested"] == "ghostty" and r["current"] == "alacritty"
          and "Alacritty.desktop" in r["shadowed"] and not r["busy"],
          "a desktop-specific list in the way: the page says the choice is shadowed", r)
    check(lines is not None and lines[:1] == ["com.mitchellh.ghostty.desktop"],
          "the choice is still saved to the user's list", lines)
sys.exit(1 if fails else 0)
