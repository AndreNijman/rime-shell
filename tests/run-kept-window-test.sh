#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-kept-window-test.sh — a surface keeps its window between opens.
#
#  The real shell in headless.sh's private labwc, with the frame-pacing log on
#  (RIME_PACING_LOG=1). The Dashboard and the right panel (Wi-Fi pane) are
#  opened and closed three times each over IPC, and grim takes the screen at
#  every open. It must hold that:
#
#    * each lifecycle got ONE window for all its opens (the pacing log's
#      `<name> window=<n>` never passes 1): a reopen reuses the parked window
#      instead of creating, mapping and configuring a new layer surface;
#    * every reopen DRAWS: its screen differs from the screen just before it
#      at least half as much as the first open's did (a parked window whose content
#      never comes back would open as an empty, transparent layer);
#    * once closed, a parked window presents nothing (no `swap-closed` while
#      idle for 5 s).
#
#  Then the same on two mutated copies of the tree, each of which must FAIL:
#  the Dashboard's window hidden on close (not kept), and the parked content
#  hidden through the window's root item (which never shows again).
#
#  KEEP_KEPT_OUT=<dir> keeps the pictures and logs. Skips (status 0) without
#  quickshell, labwc, grim or Pillow.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"
headless_require quickshell labwc grim python3
python3 -c 'import PIL' 2>/dev/null || { echo "SKIP: python3 Pillow not installed"; exit 0; }

headless_begin
ln -sf "$root/tests/lib/fake-nmcli" "$HEADLESS_W/bin/nmcli"
ln -sf "$root/tests/lib/fake-bluetoothctl" "$HEADLESS_W/bin/bluetoothctl"
ln -sf "$root/tests/lib/fake-brightnessctl" "$HEADLESS_W/bin/brightnessctl"
qs=""
# KEEP_KEPT_OUT=<dir> keeps the pictures and the shell's logs.
trap '[ -n "$qs" ] && kill "$qs" 2>/dev/null; [ -n "${KEEP_KEPT_OUT:-}" ] && cp -r "$HEADLESS_W"/real "$HEADLESS_W"/mutant-* "$KEEP_KEPT_OUT"/ 2>/dev/null; headless_cleanup' EXIT INT TERM
headless_start labwc 1920x1080 || exit 0

ud="$HOME/.config/rime-shell/src/user_data"; mkdir -p "$ud"
printf '%s' '{"barEnabled":true,"dashboardWidth":900,"dashboardHeight":520}' > "$ud/settings.json"
printf '{"currentWall":"%s","mode":"dark"}' "$HEADLESS_WALLPAPER" > "$ud/wallpaper.json"
headless_rime_palette dark

# run_tree TREE LABEL — 0 when every check holds for that tree.
run_tree() {
    local tree="$1" label="$2" w="$HEADLESS_W/$2" bad=0
    mkdir -p "$w"
    local log="$w/shell.log"
    : > "$log"
    # No release page: the shell would open the booted release's notes in a
    # browser on this compositor 8 s in.
    env RIME_PACING_LOG=1 RIME_RELEASE_JSON=/nonexistent RIME_RELEASE_OPENER=/bin/false \
        quickshell -p "$tree/shell.qml" >> "$log" 2>&1 & qs=$!
    for _ in $(seq 1 160); do grep -q "Configuration Loaded" "$log" && break; sleep 0.25; done
    grep -q "Configuration Loaded" "$log" || { echo "  FAIL  [$label] the shell did not load"; tail -20 "$log"; kill "$qs"; qs=""; return 1; }
    sleep 4
    ipc() { quickshell -p "$tree/shell.qml" ipc call "$@" >/dev/null 2>&1; }

    local s i
    for s in "dashboard-home" "wifi-toggle"; do
        for i in 1 2 3; do
            grim "$w/$s-$i-closed.png"
            ipc "$s" toggle; sleep 1.3
            grim "$w/$s-$i.png"
            ipc "$s" toggle; sleep 1.3
        done
    done
    local idle_from; idle_from="$(wc -l < "$log")"
    sleep 5
    kill "$qs" 2>/dev/null; wait "$qs" 2>/dev/null; qs=""

    # One window per lifecycle.
    local max
    for s in dashboard right-panel; do
        max="$(sed -n "s/.*Rime pacing: $s window=\([0-9]*\).*/\1/p" "$log" | sort -n | tail -1)"
        if [ "${max:-0}" = 1 ]; then echo "  PASS  [$label] $s: one window for three opens"
        else echo "  FAIL  [$label] $s: ${max:-no} window(s) for three opens"; bad=1; fi
    done
    # Every reopen draws.
    python3 -I - "$w" <<'PY' || bad=1
import sys
from PIL import Image, ImageChops
w = sys.argv[1]
def changed(s, i):
    closed = Image.open(f"{w}/{s}-{i}-closed.png").convert("RGB")
    d = ImageChops.difference(closed, Image.open(f"{w}/{s}-{i}.png").convert("RGB")).convert("L")
    return sum(d.point(lambda v: 255 if v > 24 else 0).histogram()[255:])
bad = 0
for s, label in (("dashboard-home", "Dashboard"), ("wifi-toggle", "right panel")):
    first = changed(s, 1)
    if first < 2000:
        print(f"  FAIL  {label}: the first open drew only {first} px"); bad = 1; continue
    for i in (2, 3):
        n = changed(s, i)
        ok = n >= first / 2
        print(f"  {'PASS' if ok else 'FAIL'}  {label}: open {i} drew {n} px (first open {first})")
        bad |= not ok
sys.exit(bad)
PY
    # A parked window presents nothing while idle.
    local idle_swaps; idle_swaps="$(tail -n +"$((idle_from + 1))" "$log" | grep -c 'swap-closed')"
    if [ "$idle_swaps" = 0 ]; then echo "  PASS  [$label] no frames from a closed surface while idle"
    else echo "  FAIL  [$label] $idle_swaps frames from a closed surface while idle"; bad=1; fi
    return $bad
}

echo "the tree as it is:"
run_tree "$root" real; real=$?

# ── Can it fail? ─────────────────────────────────────────────────────────────
selffail=0
mutant() {   # mutant <label> <file> <old> <new>
    local m="$HEADLESS_W/mutant"
    rm -rf "$m"; mkdir -p "$m"
    (cd "$root" && tar --exclude=.git -cf - .) | tar -xf - -C "$m"
    python3 -I - "$m/$2" "$3" "$4" <<'PY' || { echo "  FAIL self-test $1: the mutation did not apply"; selffail=1; return; }
import sys
f, old, new = sys.argv[1:4]
s = open(f).read()
if s.count(old) != 1: sys.exit(3)
open(f, "w").write(s.replace(old, new, 1))
PY
    echo "mutant: $1"
    if run_tree "$m" "mutant-$(echo "$1" | tr -c 'a-z\n' '-')" >/dev/null; then
        echo "  FAIL self-test $1: still passes"; selffail=1
    else
        echo "  ok   self-test $1: caught"
    fi
}
mutant "Dashboard window hidden on close" src/popups/Dashboard.qml \
    'visible: life.windowVisible' 'visible: life.mapped'
mutant "parked content hidden through the window's root item" src/components/SurfaceLifecycle.qml \
    'target: life._veiled' 'target: life._win ? life._win.contentItem : null'

if [ "$real" -ne 0 ]; then echo "RESULT: FAIL — a kept window misbehaved"; exit 1; fi
if [ "$selffail" -ne 0 ]; then echo "RESULT: FAIL — a mutant was not caught"; exit 1; fi
echo "RESULT: kept windows are reused, draw on every reopen and stay quiet while parked"
