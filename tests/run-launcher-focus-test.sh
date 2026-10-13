#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-launcher-focus-test.sh — every open of the launcher (Alt+Space) takes
#  the keys, however soon it follows a close.
#
#  The real shell in a headless labwc, the launcher opened over the same IPC
#  call Alt+Space makes, typed into with wtype. Each round types the name of
#  an application of its own and presses Return; the application writing its
#  name to a log is the observable. A round whose keys went nowhere launches
#  nothing (or the list's first row, with an empty query).
#
#    fresh       the first open of the session
#    quick N     closed, then opened again N ms later — before the close has
#                finished, so the page never changed and the launcher's
#                visibility never flickered: the case that used to leave the
#                keys with the Dashboard's outer item ("I close and open it a
#                few times and then it lets me type")
#    settled     closed, opened again once the close has finished
#    from home   opened on Home, then switched to the launcher
#
#  REDUCE_MOTION=true runs it with Reduce Motion on (CI runs both), minus the
#  first open's assertion: under Reduce Motion the session's first open gives
#  the field the keys but never starts the search (`onScreen` stays false), so
#  nothing is found to launch. That gap is the Dashboard lifecycle's, not
#  focus, and is tracked on its own.
#  Skips (status 0) without quickshell, labwc or wtype.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"
headless_require quickshell labwc wtype

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

headless_begin
for n in nmcli bluetoothctl brightnessctl nmtui blueman-manager rfkill hyprshade hyprsunset systemd-inhibit; do
    ln -sf "$HEADLESS_W/bin/_stub" "$HEADLESS_W/bin/$n"
done
qs=""
cleanup() { [ -n "$qs" ] && kill "$qs" 2>/dev/null; headless_cleanup; }
trap cleanup EXIT INT TERM
[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1920x1080 || exit 0

ud="$HOME/.config/rime-shell/src/user_data"; mkdir -p "$ud" "$HOME/.cache/rime-shell"
printf '{"barEnabled":false,"animDuration":320,"motionScale":1,"reduceMotion":%s,"dashboardWidth":900,"dashboardHeight":520}' \
    "${REDUCE_MOTION:-false}" > "$ud/settings.json"
headless_rime_palette dark

# One application per round, no two sharing a prefix, so a launch names the
# round whose keys arrived.
rounds=(Jabiru Kestrel Lorikeet Magpie Nightjar Osprey Pardalote Quail Rosella)
apps="$HOME/.local/share/applications"; mkdir -p "$apps"
LAUNCH_LOG="$HEADLESS_W/launched.log"; : > "$LAUNCH_LOG"
for a in "${rounds[@]}"; do
    printf '#!/bin/sh\necho %s >> "%s"\n' "$a" "$LAUNCH_LOG" > "$HEADLESS_W/$a.sh"; chmod +x "$HEADLESS_W/$a.sh"
    printf '[Desktop Entry]\nType=Application\nName=%s\nExec=%s\n' "$a" "$HEADLESS_W/$a.sh" > "$apps/$a.desktop"
done

log="$HEADLESS_W/shell.log"
RIME_PACING_LOG=1 quickshell -p "$root/shell.qml" > "$log" 2>&1 &
qs=$!
for _ in $(seq 1 120); do grep -q "Configuration Loaded" "$log" && break; sleep 0.25; done
grep -q "Configuration Loaded" "$log" || { echo "RESULT: the shell did not load"; tail -20 "$log"; exit 1; }
sleep 3

ipc() { quickshell -p "$root/shell.qml" ipc call "$@" >/dev/null 2>&1; }
dash_open() { [ "$(grep -c 'pacing: dashboard mapped=true' "$log")" -gt "$(grep -c 'pacing: dashboard mapped=false' "$log")" ]; }
settle_closed() { local _; for _ in $(seq 1 20); do dash_open || return 0; sleep 0.1; done; ipc dashboard-launcher toggle; sleep 1.2; }
launched() {   # launched <name> — the log's newest line, within 4 s
    local _
    for _ in $(seq 1 16); do [ "$(tail -1 "$LAUNCH_LOG")" = "$1" ] && return 0; sleep 0.25; done
    return 1
}
type_launch() {   # type_launch <name> <what>
    local lower; lower="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    # Shift first: this seat has no keyboard until wtype makes one, and the
    # keyboard's enter carries the key that made it as already held, which a
    # client must ignore. A real seat has its keyboard before the open.
    wtype -k Shift_L "$lower"; sleep 0.5; wtype -k Return
    launched "$1" && ok "$2: typed \"$lower\", Return launches $1" \
                  || bad "$2: typed \"$lower\" — launched: $(tail -1 "$LAUNCH_LOG" 2>/dev/null || true)"
    sleep 0.3; settle_closed
}

i=0
if [ "${REDUCE_MOTION:-false}" = true ]; then
    echo "  SKIP  fresh open under Reduce Motion (the first open's search never starts; see the header)"
    ipc dashboard-launcher toggle; sleep 0.6; ipc dashboard-launcher toggle; sleep 1.2
else
    ipc dashboard-launcher toggle; sleep 0.6
    type_launch "${rounds[i]}" "fresh open"
fi
i=$((i + 1))

# Opened and closed by the same call Alt+Space makes, then opened again before
# the close has finished.
for ms in 50 120 200 300; do
    ipc dashboard-launcher toggle; sleep 0.6
    ipc dashboard-launcher toggle; sleep "0.$(printf '%03d' "$ms")"
    ipc dashboard-launcher toggle; sleep 0.6
    type_launch "${rounds[i]}" "reopened ${ms} ms after a close"; i=$((i + 1))
done

ipc dashboard-launcher toggle; sleep 0.6
ipc dashboard-launcher toggle; sleep 1.5
ipc dashboard-launcher toggle; sleep 0.6
type_launch "${rounds[i]}" "reopened after the close finished"; i=$((i + 1))

# Escape closes too; a quick reopen after it.
ipc dashboard-launcher toggle; sleep 0.6
wtype -k Escape; sleep 0.1
ipc dashboard-launcher toggle; sleep 0.6
type_launch "${rounds[i]}" "reopened 100 ms after Escape"; i=$((i + 1))

ipc dashboard-home toggle; sleep 0.8
ipc dashboard-launcher toggle; sleep 0.6
type_launch "${rounds[i]}" "switched to from Home"; i=$((i + 1))

grep -E "ReferenceError|TypeError" "$log" | grep -iE "AppLauncher|Dashboard|LazyPage" >/dev/null \
    && bad "script errors: $(grep -E 'ReferenceError|TypeError' "$log" | grep -iE 'AppLauncher|Dashboard|LazyPage' | head -3 | tr '\n' '|')" \
    || ok "no script error from the Dashboard or the launcher"

echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
