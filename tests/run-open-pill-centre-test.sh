#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-open-pill-centre-test.sh — every bar control's open pill sits centred on
#  the glyph it marks, at every factor the shell scales to.
#
#  Andre: "when i open the wifi dialog thing, the selector on the wifi button is
#  off centre". The pill was centred on the glyph's BOX, and the glyph is not
#  centred in its box: a centred item lands on a whole pixel (an odd advance in
#  an even box is half a pixel out), and a glyph's ink need not fill its advance
#  or the middle of its line box. Measured on 1x: the wifi ink 0.5-0.65 px left
#  of the pill's centre, one more grey column on the right than the left.
#
#  Runs tests/open-pill-centre-test.qml against a STAGED copy of src/ in a
#  private headless compositor (tests/lib/headless.sh): the real bar modules and
#  every glyph they can show, at 0.85, 1, 1.2, 1.35 and 1.5. For each one, the
#  pill's centre comes from its laid-out geometry and the glyph's ink from the
#  pixels of the cell drawn without the pill. They must agree within 0.3 px across
#  and 0.5 px up and down (tests/lib/pill-ink.py says why). Then the fix is
#  taken out of the staged tree and the same run must FAIL, so a test that
#  cannot see the defect cannot pass.
#
#  KEEP_PILL_OUT=<dir> copies the pictures and the shell's logs there on exit,
#  to look at a failure.
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
trap '[[ -n "${KEEP_PILL_OUT:-}" ]] && cp -r "$HEADLESS_W"/out-* "$HEADLESS_W"/log-* "$KEEP_PILL_OUT"/ 2>/dev/null; headless_cleanup' EXIT INT TERM
headless_start || exit 0

tree="$HEADLESS_W/tree"
mkdir -p "$tree"
cp -r "$root/src" "$tree/src"
cp "$here/open-pill-centre-test.qml" "$tree/shell.qml"

# run <label> → prints the measurement table; exit status is the verdict.
run() {
    local out="$HEADLESS_W/out-$1" log="$HEADLESS_W/log-$1"
    rm -rf "$out"; mkdir -p "$out"
    PILL_OUT="$out" timeout 120 quickshell -p "$tree/shell.qml" >"$log" 2>&1
    grep 'PILLDONE' "$log" >/dev/null || {
        echo "RESULT: the test shell stopped early ($1)"; grep -iE 'error|is not a type' "$log" | head -20; return 2; }
    sed -n 's/.*PILL \({.*}\)$/\1/p' "$log" | python3 -I "$here/lib/pill-ink.py"
}

run fixed
rc=$?
[[ $rc -eq 0 ]] || { echo "RESULT: a pill is off its glyph"; exit 1; }

# ── Can it fail? Each pill put back on its box, as before the fix. ──────────
# A mutation that did not apply is reported as such, never as caught.
python3 -I - "$tree/src/components/OpenPill.qml" <<'PY' || { echo "RESULT: the self-test mutation did not apply"; exit 1; }
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "readonly property point _centre: pill._inkCentre()"
if old not in s: sys.exit(3)
s = s.replace(old, "readonly property point _centre: Qt.point(pill.parent ? Math.round((pill.parent.width - pill.width) / 2) + pill.width / 2 : 0, pill.parent ? Math.round((pill.parent.height - pill.height) / 2) + pill.height / 2 : 0)", 1)
open(p, "w", encoding="utf-8").write(s)
PY
if run unfixed >/dev/null; then
    echo "  FAIL self-test: pills centred on their boxes SURVIVED"
    echo "RESULT: the test cannot tell a pill on its box from a pill on its glyph"
    exit 1
fi
echo "  ok   self-test: pills centred on their boxes are caught"
echo "RESULT: every bar pill is centred on its glyph's ink (0.3 px across, 0.5 px up/down), at every scale factor"
