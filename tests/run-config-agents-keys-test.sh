#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-config-agents-keys-test.sh — the Dashboard's Agents tab and the
#  settings window on the keyboard (UI/UX roadmap v3 Phase 21j; the settings
#  half moved from the Dashboard's Config tab to Nexus when Phase 19 removed
#  that tab).
#
#  The real shell in a headless labwc, on headless.sh's private session bus,
#  typed into with wtype. Nothing a key does can reach the machine: HOME is
#  the harness's, the wallpaper setters (awww, swww) are fakes that log, and
#  `labwc` is stubbed once the harness's own compositor is up (the apply
#  pipeline runs `labwc --reconfigure`). No agent daemon runs, so the Agents
#  tab shows its empty state and its help strip.
#
#    Agents  Tab to the guide's entry, Return opens the guide; its section
#            list takes the keys (Down moves the section); Escape closes the
#            guide ONLY (the Dashboard stays) and hands the keys back to the
#            entry: Return opens the guide again.
#    Nexus   Appearance: Tab to the wallpaper strip, Right, Return applies the
#            second wallpaper — the fake setter is told that file, and
#            ~/.curr_wall points at it.
#
#  Every verdict waits for the state it names, not for a time: `settle` grabs
#  until the frame has stopped moving and the change is there (up to ${WAIT:-10}
#  s). A fixed sleep before one grab passed or failed with the machine's load.
#
#  PROBE=agents|nexus grabs a frame after every Tab instead, to re-derive the
#  stop counts. Skips (status 0) without quickshell, labwc, wtype, grim or
#  python3 with PIL.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"
headless_require quickshell labwc wtype grim python3
python3 -c 'import PIL' 2>/dev/null || { echo "SKIP: python3 PIL is not installed"; exit 0; }

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

headless_begin
SETTER_LOG="$HEADLESS_W/setter.log"; : > "$SETTER_LOG"
# rm -f FIRST: headless_begin makes bin/swww a SYMLINK to the shared _stub,
# and writing through it turned every stubbed tool into this logger.
for s in awww swww; do
    rm -f "$HEADLESS_W/bin/$s"
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$s" "$SETTER_LOG" > "$HEADLESS_W/bin/$s"; chmod +x "$HEADLESS_W/bin/$s"
done
qs=""
cleanup() { [ -n "$qs" ] && kill "$qs" 2>/dev/null; headless_cleanup; }
trap cleanup EXIT INT TERM
[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1920x1080 || exit 0
ln -sf "$HEADLESS_W/bin/_stub" "$HEADLESS_W/bin/labwc"   # the apply pipeline's --reconfigure

ud="$HOME/.config/rime-shell/src/user_data"; mkdir -p "$ud" "$HOME/.cache/rime-shell"
printf '{"barEnabled":false,"animDuration":320,"motionScale":1,"dashboardWidth":900,"dashboardHeight":520}' > "$ud/settings.json"
headless_rime_palette dark   # the Rime OS default look (tests/lib/headless.sh)
python3 - "$HOME/Pictures/Wallpapers" <<'PY'
import sys
from PIL import Image
for name, rgb in (("aaa-first.png", (40, 60, 90)), ("bbb-second.png", (120, 60, 40))):
    Image.new("RGB", (320, 180), rgb).save(f"{sys.argv[1]}/{name}")
PY
log="$HEADLESS_W/shell.log"
quickshell -p "$root/shell.qml" > "$log" 2>&1 &
qs=$!
for _ in $(seq 1 120); do grep -q "Configuration Loaded" "$log" && break; sleep 0.25; done
grep -q "Configuration Loaded" "$log" || { echo "RESULT: the shell did not load"; tail -20 "$log"; exit 1; }
sleep 3

ipc()  { quickshell -p "$root/shell.qml" ipc call "$@" >/dev/null 2>&1; }
keys() { local k; for k in "$@"; do wtype -k "$k"; sleep 0.3; done; }
# grab <name> — the Dashboard's part of the screen, or GEOM (grim -g) when set.
grab() { grim -g "${GEOM:-480,0 960x600}" "$HEADLESS_W/$1.png"; [ -n "${SHOTS:-}" ] && mkdir -p "$SHOTS" && cp "$HEADLESS_W/$1.png" "$SHOTS/"; }
delta() {   # delta <a> <b> <x0,y0,x1,y1> — mean abs difference of the region
    python3 - "$HEADLESS_W/$1.png" "$HEADLESS_W/$2.png" "$3" <<'PY'
import sys
from PIL import Image, ImageChops, ImageStat
box = tuple(int(v) for v in sys.argv[3].split(","))
a = Image.open(sys.argv[1]).convert("L").crop(box); b = Image.open(sys.argv[2]).convert("L").crop(box)
print(f"{ImageStat.Stat(ImageChops.difference(a, b)).mean[0]:.2f}")
PY
}
# settle <name> <ref> <box> <gt|lt> <threshold> — grab <name> until it is still
# (two grabs 0.25 s apart differ by under 0.3 in <box>) AND its delta from <ref>
# is past <threshold> the way <gt|lt> says; give up after ${WAIT:-10} s. Prints
# the last delta either way: the verdict is the caller's, on what was seen.
settle() {
    local name="$1" ref="$2" box="$3" op="$4" thr="$5" d="" still="" t0=$SECONDS
    grab "$name"
    while :; do
        sleep 0.25
        cp "$HEADLESS_W/$name.png" "$HEADLESS_W/$name.prev.png"
        grab "$name"
        still="$(delta "$name.prev" "$name" "$box")"
        d="$(delta "$ref" "$name" "$box")"
        awk -v s="$still" -v d="$d" -v t="$thr" -v op="$op" \
            'BEGIN { exit !(s < 0.3 && ((op == "gt") ? (d > t) : (d < t))) }' && break
        [ $((SECONDS - t0)) -ge "${WAIT:-10}" ] && break
    done
    echo "$d"
}
wtype -k Shift_L; sleep 0.3          # the first wtype key of a session is lost

if [ -n "${PROBE:-}" ]; then
    out="${PROBE_OUT:-/var/lab-scratch/uiux/probe-$PROBE}"; mkdir -p "$out"
    region="480,0 960x600"
    if [ "$PROBE" = nexus ]; then ipc nexus open appearance; region=""; else ipc "dashboard-$PROBE" toggle; fi
    sleep 1.5
    for k in ${PROBE_PRE:-}; do wtype -k "$k"; sleep 0.5; done   # keys before the Tab walk
    for i in $(seq 1 "${PROBE_TABS:-14}"); do
        wtype -k Tab; sleep 0.45; grim ${region:+-g "$region"} "$out/tab-$(printf %02d "$i").png"
    done
    echo "PROBE: frames in $out"; exit 0
fi

# ── Agents ───────────────────────────────────────────────────────────────────
# Stops (PROBE=agents): the tab bar's list, its Settings action (a stop of its
# own since a46ee749, TabSwitcher `action`), the guide's entry, the onboarding
# card's two buttons. Frames: the guide covers the page (220,40 → 940,560) and
# leaves the tab bar (0,0 → 960,40) alone. Return on the Settings action
# closes the Dashboard for the Nexus, which changes the GUIDE box just as much
# (that passed as "the guide opened" from a46ee749 on), so the tab bar tells
# them apart.
GUIDE="220,40,940,560"; TABBAR="0,0,960,40"
# Arrival is a state too: the frame must differ from the desktop grabbed before
# the toggle, and be still. (Compared with itself it was only a stillness wait,
# which an empty desktop passes at once when the Dashboard is late.)
ALL="0,0,960,600"
grab agents-pre
ipc dashboard-agents toggle
echo "  ....  the Dashboard is up (Δ from the desktop $(settle agents-0 agents-pre "$ALL" gt 5))"
keys Tab Tab Tab Return
d="$(settle agents-1-open agents-0 "$GUIDE" gt 8)"
bar="$(delta agents-0 agents-1-open "$TABBAR")"
awk -v d="$d" -v b="$bar" 'BEGIN { exit !(d > 8 && b < 2) }' \
    && ok "Tab to the guide's entry, Return opens the guide (Δ $d, tab bar Δ $bar)" \
    || bad "the guide did not open from its entry (Δ $d, tab bar Δ $bar: over 2 = the Dashboard left)"
keys Down
d="$(settle agents-2-section agents-1-open "$GUIDE" gt 3)"
awk -v d="$d" 'BEGIN { exit !(d > 3) }' && ok "it opens on its section list: Down moves to the next section (Δ $d)" \
    || bad "Down in the open guide changed nothing (Δ $d) — the section list does not have the keys"
keys Tab Tab Down
d="$(settle agents-3-trapped agents-2-section "$GUIDE" gt 3)"
awk -v d="$d" 'BEGIN { exit !(d > 3) }' && ok "Tab ×2 stays inside the guide (list → Close → list): Down moves the section again (Δ $d)" \
    || bad "after Tab ×2 Down changed nothing (Δ $d) — Tab left the guide"
keys Escape
d="$(settle agents-4-closed agents-0 "$GUIDE" lt 2)"
awk -v d="$d" 'BEGIN { exit !(d < 2) }' && ok "Escape closes the guide only — the page is back as it was (Δ $d)" \
    || bad "after Escape the page differs from before the guide (Δ $d) — the Dashboard closed, or the guide stayed"
keys Return
d="$(settle agents-5-reopened agents-0 "$GUIDE" gt 8)"
bar="$(delta agents-0 agents-5-reopened "$TABBAR")"   # as above: tells a closed Dashboard apart
awk -v d="$d" -v b="$bar" 'BEGIN { exit !(d > 8 && b < 2) }' \
    && ok "and the keys went back to the entry: Return opens the guide again (Δ $d, tab bar Δ $bar)" \
    || bad "Return after Escape did not reopen the guide (Δ $d, tab bar Δ $bar: over 2 = the Dashboard left)"
keys Escape; sleep 0.6
ipc dashboard-agents toggle
echo "  ....  the Dashboard is gone (Δ from the desktop $(settle agents-6-gone agents-pre "$ALL" lt 1))"

# ── Settings (Nexus): Appearance ────────────────────────────────────────────
# Stops (PROBE=nexus): the page list, Close, the profile picture's field, its
# Choose… and its Reset (3fbdd996 added those three), the lock background
# field, its Reset, Rescan, then the wallpaper strip. (In the Dashboard's
# Config tab it was seven: its tab bar and "Open in window" came first; Phase
# 19 removed it.)
# Nexus is its own window, so these two frames are the whole output.
GEOM="0,0 1920x1080" grab nexus-pre
ipc nexus open appearance
echo "  ....  Nexus is up (Δ from the desktop $(GEOM="0,0 1920x1080" settle nexus-0 nexus-pre "0,0,1920,1080" gt 3))"
keys Tab Tab Tab Tab Tab Tab Tab Tab Tab Right Return
for _ in $(seq 1 20); do grep -q 'bbb-second.png' "$SETTER_LOG" && break; sleep 0.25; done
grep -q 'img .*bbb-second.png' "$SETTER_LOG" \
    && ok "Tab ×9 to the wallpaper strip, Right, Return: the setter was told the second wallpaper" \
    || bad "the wallpaper strip by keyboard — the setter was told: $(tr '\n' '|' < "$SETTER_LOG")"
# shellcheck disable=SC2088  # "~/.curr_wall" is prose in the verdicts, not a path
[ "$(readlink "$HOME/.curr_wall" 2>/dev/null)" = "$HOME/Pictures/Wallpapers/bbb-second.png" ] \
    && ok "and ~/.curr_wall points at it" || bad "~/.curr_wall is $(readlink "$HOME/.curr_wall" 2>/dev/null || echo unset)"
ipc nexus close; sleep 1

# SUPER+C and rime-os's keybind helper still call `dashboard-config`; since
# Phase 19 it is a compatibility name that opens Nexus, not a Dashboard tab.
# Asked with `nexus toggle`, which says "nexus closed" only if the window WAS
# open — `nexus open` would report open whatever the alias had done.
ipc dashboard-config toggle; sleep 1.5
nx="$(quickshell -p "$root/shell.qml" ipc call nexus toggle "" 2>&1)"
case "$nx" in
    *"nexus closed"*) ok "dashboard-config opened the settings window (nexus toggle then closed it)" ;;
    *) bad "dashboard-config did not open Nexus (nexus toggle answered: $nx)" ;;
esac
sleep 1

grep -E 'TypeError|ReferenceError|is not a type|Cannot assign' "$log" | head -5
printf '\nrun-config-agents-keys-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
