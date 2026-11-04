#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-focus-mode-test.sh — Focus Mode (SUPER+B) works before the dashboard has
#  ever been shown, and a press while the gaps settle is queued, not dropped.
#
#  The harness (tests/focus-mode-test.qml) holds IpcManager and nothing else,
#  in a headless compositor. Presses go through the shipped focus-toggle IPC
#  target, which is what SUPER+B runs.
#
#    first press   no dashboard, no QuickSettings: the first press turns Focus
#                  Mode on and the second turns it off (labwc: no runtime gaps,
#                  so only the bar flips and no gaps are written)
#    double press  two presses while the gaps read is out: the second is queued
#                  and lands after the shrink settles, so Focus Mode ends OFF
#                  with the user's gaps back (writes 0/6 then 5/10); the queued
#                  press is logged
#    two IPC calls the same through two separate `qs ipc call` presses
#    triple press  three presses in the window end ON (one shrink, no restore
#                  in between), and the next press restores
#    no answer     a gaps read that never answers releases the queue after 3 s:
#                  the bar flips, no gaps are written, the next press works
#
#  Mutants: tests/mutate-focus-mode.sh. SKIPS (status 0) without quickshell or
#  a wlroots compositor.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"
headless_require quickshell

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

staged="$root/.focus-mode-test.qml"
qs=""
cleanup() { [ -n "$qs" ] && kill "$qs" 2>/dev/null; rm -f "$staged"; headless_cleanup; }
trap cleanup EXIT INT TERM

headless_begin
headless_start || exit 0
cp "$here/focus-mode-test.qml" "$staged"

: > "$HEADLESS_W/qs.log"
quickshell -p "$staged" > "$HEADLESS_W/qs.log" 2>&1 &
qs=$!
for _ in $(seq 1 80); do grep -q "Configuration Loaded" "$HEADLESS_W/qs.log" && break; sleep 0.25; done
grep -q "Configuration Loaded" "$HEADLESS_W/qs.log" || { echo "harness did not load"; tail -20 "$HEADLESS_W/qs.log"; exit 1; }

t()     { quickshell -p "$staged" ipc call fmtest "$@" 2>/dev/null; }
focus() { quickshell -p "$staged" ipc call focus-toggle "$@" 2>/dev/null; }
# wait_for <value> <seconds>: Focus Mode reaches <value> and nothing is pending
wait_for() {
    local i
    for i in $(seq 1 $(( $2 * 10 ))); do
        [ "$(t state)" = "$1" ] && [ "$(t busy)" = idle ] && return 0
        sleep 0.1
    done
    return 1
}

echo "first press: no dashboard has been built"
[ "$(focus state)" = off ] && ok "starts off" || bad "starts '$(focus state)'"
focus toggle >/dev/null
if wait_for on 3; then ok "the first press turns Focus Mode on"; else bad "the first press did nothing (state '$(t state)')"; fi
focus toggle >/dev/null
if wait_for off 3; then ok "the second press turns it off"; else bad "the second press did nothing (state '$(t state)')"; fi
grep -q "QuickSettings" "$HEADLESS_W/qs.log" && bad "QuickSettings was loaded" || ok "QuickSettings was never loaded"

echo "double press: the second press arrives while the gaps read is out"
t fake 800 >/dev/null
t press 2 >/dev/null
sleep 0.1
[ "$(focus state)" = "off queued" ] && ok "the second press shows as queued" || bad "no sign of the second press (state '$(focus state)')"
if wait_for off 3; then ok "two presses end off"; else bad "two presses left Focus Mode '$(t state)' (a press was dropped)"; fi
[ "$(t writes)" = "0/6,5/10" ] && ok "shrunk, then the user's gaps put back (0/6,5/10)" || bad "gap writes '$(t writes)', expected 0/6,5/10"
[ "$(t gaps)" = 5/10 ] && ok "gaps are 5/10 again" || bad "gaps are '$(t gaps)'"
grep -q "press queued until the gaps settle" "$HEADLESS_W/qs.log" && ok "the queued press is logged" || bad "the queued press left no log line"

echo "two IPC calls inside the window"
t fake 400 >/dev/null
focus toggle >/dev/null
focus toggle >/dev/null
if wait_for off 3; then ok "two separate presses end off"; else bad "two separate presses left Focus Mode '$(t state)'"; fi
[ "$(t writes)" = "0/6,5/10" ] && ok "writes 0/6,5/10" || bad "gap writes '$(t writes)', expected 0/6,5/10"

echo "triple press"
t fake 300 >/dev/null
t press 3 >/dev/null
if wait_for on 3; then ok "three presses end on"; else bad "three presses left Focus Mode '$(t state)'"; fi
[ "$(t writes)" = "0/6" ] && ok "one shrink, no restore in between" || bad "gap writes '$(t writes)', expected 0/6"
focus toggle >/dev/null
if wait_for off 3; then ok "the next press turns it off"; else bad "the next press left Focus Mode '$(t state)'"; fi
[ "$(t gaps)" = 5/10 ] && ok "and restores 5/10" || bad "gaps are '$(t gaps)' after the restore"

echo "no answer: the gaps read never comes back"
t fake -1 >/dev/null
focus toggle >/dev/null
sleep 1
[ "$(t busy)" = busy ] && ok "waits for the read" || bad "did not wait for the read (busy '$(t busy)')"
if wait_for on 5; then ok "released after the deadline: the bar flipped"; else bad "a read that never answers held Focus Mode (state '$(t state)', $(t busy))"; fi
[ -z "$(t writes)" ] && ok "no gaps written" || bad "gaps written with no read: '$(t writes)'"
focus toggle >/dev/null
if wait_for off 3; then ok "the next press turns it off"; else bad "after the deadline the next press did nothing (state '$(t state)')"; fi
[ -z "$(t writes)" ] && ok "nothing restored that was never shrunk" || bad "restored gaps it never shrunk: '$(t writes)'"

echo "RESULT: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
