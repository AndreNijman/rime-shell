#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-rime-mark-test.sh — the Rime Origin mark, as the shell draws it.
#
#  src/components/RimeMark.qml draws the brand mark as five vector circles,
#  tangent at one origin and filled even-odd into three bodies (coat, ring,
#  core), all in ONE colour: the accent, or the ink where the accent would
#  vanish into the surface. This holds it to that, in pixels, in a private
#  headless compositor (tests/lib/headless.sh), against a STAGED copy of src/:
#    - its origin and radii are the brand masters in src/assets/brand/;
#    - drawn on charcoal and on off-white at 16-240 px, every body is the
#      accent and both gaps show the surface, and the 24 px-and-below small
#      master takes over where it should;
#    - an accent changed while it is on screen is redrawn;
#    - the bar's mark and Settings → About's mark follow Theme.active, sit on
#      Theme.background and fall back to Theme.text, with the shipped Rime
#      palette, dark and light (every palette in
#      tests/fixtures/palettes-matugen-4.2.0.json is at dE >= 60.3);
#    - an accent within CIE76 dE 15 of its surface is drawn in the ink.
#  Then four defects are planted in the staged tree (the core in the ink, the
#  coat filled without even-odd, a circle drifted, the fallback removed) and
#  each run must FAIL, so a test that cannot see the defect cannot pass.
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

# ── Can it fail? Each planted defect must be caught. ───────────────────────
# mutate <label> <scheme> <old> <new>: plant one change in a fresh staged copy.
mutate() {
    cp "$root/src/components/RimeMark.qml" "$tree/src/components/RimeMark.qml"
    python3 -I - "$tree/src/components/RimeMark.qml" "$3" "$4" <<'PY' || { echo "RESULT: the $1 mutation did not apply"; exit 1; }
import sys
p, old, new = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if old not in s: sys.exit(3)
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
    if run "$1" "$2" >/dev/null; then
        echo "  FAIL self-test: $5 SURVIVED"
        echo "RESULT: the test cannot see $5"
        exit 1
    fi
    echo "  ok   self-test: $5 is caught"
}
mutate swapped dark "function bodyColor(i) { return root.drawnAccent }" \
    "function bodyColor(i) { return i === 2 ? root.foreground : root.drawnAccent }" "the core drawn in the ink"
mutate winding dark "fillRule: ShapePath.OddEvenFill" "fillRule: ShapePath.WindingFill" \
    "the coat filled without even-odd (its gap closed)"
mutate drift dark "masterRadii: [42, 33, 26, 20, 15]" "masterRadii: [42, 33, 26.5, 20, 15]" \
    "a circle drifted from the brand master"
mutate noseparation light "root.deltaE(root.accent, root.surface) >= root.minSeparation" "true" \
    "an accent its surface swallows, drawn as is"
echo "RESULT: the Rime mark is the brand master, one colour, gaps open, crisp at 16-240 px, on light and dark, live"
