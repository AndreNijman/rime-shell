#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-rime-mark-test.sh — the Rime layered ridge, as the shell draws it.
#
#  src/components/RimeMark.qml draws the brand mark as four vector planes:
#  plane 3 in the accent, the other three in the ink of whatever it sits on.
#  This holds it to that, in pixels, in a private headless compositor
#  (tests/lib/headless.sh), against a STAGED copy of src/:
#    - its point lists are the brand masters in src/assets/brand/ (no drift);
#    - drawn on charcoal and on off-white at 16-240 px, each plane is its
#      colour, the 32 px-and-below small master takes over where it should;
#    - an accent changed while it is on screen is redrawn;
#    - the bar's mark and Settings → About's mark follow Theme.active (plane 3)
#      and Theme.text (ink), with the shipped Rime palette, dark and light;
#    - an accent within CIE76 dE 15 of the ink (the shipped LIGHT palette's
#      #000613 on #1b1c1e) is drawn in the brand's Rime Blue instead.
#  Then plane 3's colour is swapped with the ink in the staged tree, and the
#  same run must FAIL, so a test that cannot see the defect cannot pass.
#
#  MARK_SHOTS=<dir> also copies the review pictures there (bar and About, dark
#  and light, plus the 240 px marks) as shell-*.png.
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }
python3 -c 'import PIL' 2>/dev/null || { echo "SKIP: python3 Pillow not installed"; exit 0; }

headless_begin
trap 'headless_cleanup' EXIT INT TERM
headless_start || exit 0

# Settings → Misc also shows the Default terminal row: give the private home
# what a Rime install has (a Ghostty entry, the list naming it first), so the
# picture shows the shipped state, not whatever this host has. The ghostty on
# PATH is a stub: `xdg-terminal-exec --print-id` only checks that it exists.
mkdir -p "$HOME/.local/share/applications" "$HOME/.config"
printf '#!/bin/sh\nexit 0\n' > "$HEADLESS_W/bin/ghostty"; chmod +x "$HEADLESS_W/bin/ghostty"
printf '[Desktop Entry]\nType=Application\nName=Ghostty\nTryExec=ghostty\nExec=ghostty --gtk-single-instance=true\nCategories=System;TerminalEmulator;\nX-TerminalArgExec=-e\n' \
    > "$HOME/.local/share/applications/com.mitchellh.ghostty.desktop"
printf 'com.mitchellh.ghostty.desktop\n' > "$HOME/.config/xdg-terminals.list"

tree="$HEADLESS_W/tree"
mkdir -p "$tree"
cp -r "$root/src" "$tree/src"
cp "$here/rime-mark-test.qml" "$tree/shell.qml"

# run <label> <scheme> → the judged records on stdout; exit status = verdict.
run() {
    local out="$HEADLESS_W/out-$1-$2" log="$HEADLESS_W/log-$1-$2"
    rm -rf "$out"; mkdir -p "$out"
    headless_rime_palette "$2"
    MARK_OUT="$out" MARK_SCHEME="$2" timeout 120 quickshell -p "$tree/shell.qml" >"$log" 2>&1
    grep 'MARKDONE' "$log" >/dev/null || {
        echo "  FAIL the test shell stopped early ($1, $2)"; grep -iE 'error|is not a type' "$log" | head -20; return 2; }
    sed -n 's/.*MARK \({.*}\)$/\1/p' "$log" | python3 -I "$here/lib/rime-mark-check.py" "$tree"
}

rc=0
for scheme in dark light; do
    echo "── $scheme palette ──"
    run shipped "$scheme" || rc=1
done

if [[ -n "${MARK_SHOTS:-}" ]]; then
    mkdir -p "$MARK_SHOTS"
    for scheme in dark light; do
        cp "$HEADLESS_W/out-shipped-$scheme/0-bar-controlpanel-$scheme.png" "$MARK_SHOTS/shell-bar-mark-$scheme.png"
        cp "$HEADLESS_W/out-shipped-$scheme/0-settings-misc-$scheme.png" "$MARK_SHOTS/shell-settings-about-$scheme.png"
    done
    for s in 16 24 48 240; do
        cp "$HEADLESS_W/out-shipped-dark/0-mark-dark-$s.png" "$MARK_SHOTS/shell-mark-on-dark-$s.png"
        cp "$HEADLESS_W/out-shipped-dark/0-mark-light-$s.png" "$MARK_SHOTS/shell-mark-on-light-$s.png"
    done
    cp "$HEADLESS_W/out-shipped-dark/1-mark-dark-240.png" "$MARK_SHOTS/shell-mark-accent-changed-240.png"
    echo "  review pictures: $MARK_SHOTS/shell-*.png"
fi

[[ $rc -eq 0 ]] || { echo "RESULT: the mark is not drawn as the brand says"; exit 1; }

# ── Can it fail? Plane 3 in the ink, plane 1 in the accent. ─────────────────
python3 -I - "$tree/src/components/RimeMark.qml" <<'PY' || { echo "RESULT: the self-test mutation did not apply"; exit 1; }
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "function planeColor(i) { return i === 2 ? root.drawnAccent : root.foreground }"
if old not in s: sys.exit(3)
open(p, "w", encoding="utf-8").write(s.replace(old, "function planeColor(i) { return i === 0 ? root.drawnAccent : root.foreground }", 1))
PY
if run swapped dark >/dev/null; then
    echo "  FAIL self-test: the accent on the wrong plane SURVIVED"
    echo "RESULT: the test cannot tell plane 3 from plane 1"
    exit 1
fi
echo "  ok   self-test: the accent on the wrong plane is caught"

# ── Can it fail? A master point moved by half a unit. ───────────────────────
cp "$root/src/components/RimeMark.qml" "$tree/src/components/RimeMark.qml"
python3 -I - "$tree/src/components/RimeMark.qml" <<'PY' || { echo "RESULT: the drift mutation did not apply"; exit 1; }
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "[[47.5, 136], [149, 75], [231, 45], [217.5, 76]]"
if old not in s: sys.exit(3)
open(p, "w", encoding="utf-8").write(s.replace(old, "[[47.5, 136], [149, 75.5], [231, 45], [217.5, 76]]", 1))
PY
if run drift dark >/dev/null; then
    echo "  FAIL self-test: a plane drifted from the brand master SURVIVED"
    exit 1
fi
echo "  ok   self-test: a plane drifted from the brand master is caught"

# ── Can it fail? The accent drawn as is, however close to the ink. ──────────
cp "$root/src/components/RimeMark.qml" "$tree/src/components/RimeMark.qml"
python3 -I - "$tree/src/components/RimeMark.qml" <<'PY' || { echo "RESULT: the separation mutation did not apply"; exit 1; }
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "if (a >= root.minSeparation) return root.accent"
if old not in s: sys.exit(3)
open(p, "w", encoding="utf-8").write(s.replace(old, "return root.accent", 1))
PY
if run noseparation light >/dev/null; then
    echo "  FAIL self-test: an accent the ink swallows, drawn as is, SURVIVED"
    exit 1
fi
echo "  ok   self-test: an accent the ink swallows, drawn as is, is caught"
echo "RESULT: the Rime mark is the brand master, plane 3 in the accent, crisp at 16-240 px, on light and dark, live"
