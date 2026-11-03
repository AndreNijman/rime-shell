#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-power-profile-service-test.sh — the Shell's power control follows rimed
#  through the power-profiles-daemon API, and falls back to rimed's own Tier
#  when nothing serves that API.
#
#  A fake rimed (tests/lib/fake-rimed.py) on a PRIVATE bus that stands in for
#  the system bus (DBUS_SYSTEM_BUS_ADDRESS), and PowerProfileService held by a
#  small harness (tests/power-profile-service-test.qml) in a headless
#  compositor. busctl and rime are wrapped first on PATH and every call is
#  logged, so the suite can count them.
#
#    ppd       rimed owns org.freedesktop.UPower.PowerProfiles: the backend is
#              "ppd"; a tier changed elsewhere (another desktop, `rime tier`)
#              shows within 2 s with no read by the Shell (PropertiesChanged);
#              a set writes ActiveProfile; a hold shows as the held tier; over
#              the whole run the Shell started exactly ONE busctl (the owner
#              check) and read rimed's Tier zero times
#    fallback  the name has no owner (an older rimed): backend "rimed", the
#              tier read from org.rimeos.Rimed1 Power.Tier, a set runs
#              `rime tier <id>`
#
#  Mutants (tests/mutate-settings-app.sh): fallback removed; polling put back.
#  Skips (status 0) without quickshell, dbus-daemon, busctl or python3-gi.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"
headless_require quickshell dbus-daemon busctl python3
python3 -c 'from gi.repository import Gio' 2>/dev/null || { echo "SKIP: python3-gi not installed"; exit 0; }
. "$here/lib/fake-system-bus.sh"

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

staged="$root/.power-profile-service-test.qml"
qs=""
cleanup() { [ -n "$qs" ] && kill "$qs" 2>/dev/null; rm -f "$staged"; fake_bus_stop; headless_cleanup; }
trap cleanup EXIT INT TERM

headless_begin
real_busctl="$(PATH="${PATH#"$HEADLESS_W/bin:"}" command -v busctl)"
CALLS="$HEADLESS_W/calls.log"; : > "$CALLS"
# Logging wrappers: every busctl and rime the Shell starts is counted.
cat > "$HEADLESS_W/bin/busctl" <<WRAP
#!/usr/bin/env bash
echo "busctl \$*" >> "$CALLS"
exec "$real_busctl" "\$@"
WRAP
cat > "$HEADLESS_W/bin/rime" <<WRAP
#!/usr/bin/env bash
echo "rime \$*" >> "$CALLS"
exit 0
WRAP
chmod +x "$HEADLESS_W/bin/busctl" "$HEADLESS_W/bin/rime"
headless_start || exit 0

cp "$here/power-profile-service-test.qml" "$staged"
fake_bus_start "$HEADLESS_W/sysbus" || exit 1
B="$real_busctl --address=$DBUS_SYSTEM_BUS_ADDRESS"
export FAKE_BUSCTL="$real_busctl"

start_shell() {
    : > "$HEADLESS_W/qs.log"
    quickshell -p "$staged" > "$HEADLESS_W/qs.log" 2>&1 &
    qs=$!
    local _
    for _ in $(seq 1 80); do grep -q "Configuration Loaded" "$HEADLESS_W/qs.log" && break; sleep 0.25; done
    grep -q "Configuration Loaded" "$HEADLESS_W/qs.log" || { echo "harness did not load"; tail -20 "$HEADLESS_W/qs.log"; exit 1; }
}
stop_shell() { [ -n "$qs" ] && kill "$qs" 2>/dev/null; wait "$qs" 2>/dev/null; qs=""; }
ipc() { quickshell -p "$staged" ipc call pps "$@" 2>/dev/null; }
# wait_for <fn> <value> <seconds>
wait_for() {
    local i
    for i in $(seq 1 $(( $3 * 4 ))); do [ "$(ipc "$1")" = "$2" ] && return 0; sleep 0.25; done
    return 1
}
count() { grep -c -- "$1" "$2" 2>/dev/null || true; }

# ── 1. rimed serves the power-profiles API ───────────────────────────────────
echo "ppd: rimed owns org.freedesktop.UPower.PowerProfiles"
fake_rimed_start || exit 1
start_shell
if wait_for backend ppd 10; then ok "backend is ppd"; else bad "backend is '$(ipc backend)', expected ppd"; fi
if wait_for current balanced 5; then ok "starts on rimed's tier (balanced)"; else bad "current is '$(ipc current)'"; fi

: > "$FAKE_RIMED_LOG"
fake_rimed_change org.rimeos.Rimed1.Power Tier s performance
if wait_for current performance 2; then ok "a tier set elsewhere shows within 2 s"; else bad "a tier set elsewhere did not show (current '$(ipc current)')"; fi
reads="$(count 'Get org.rimeos.Rimed1.Power.Tier' "$FAKE_RIMED_LOG")"
[ "$reads" = 0 ] && ok "followed by PropertiesChanged: rimed's Tier read 0 times" || bad "rimed's Tier was read $reads times"

ipc set power-saver >/dev/null
if wait_for current power-saver 3; then ok "set shows power-saver"; else bad "set: current is '$(ipc current)'"; fi
if grep -q "Set org.freedesktop.UPower.PowerProfiles.ActiveProfile power-saver" "$FAKE_RIMED_LOG"; then
    ok "set writes ActiveProfile"
else bad "set did not write ActiveProfile"; fi
[ "$($B get-property org.rimeos.Rimed1 /org/rimeos/Rimed1 org.rimeos.Rimed1.Power Tier)" = 's "power-saver"' ] \
    && ok "rimed's Tier is power-saver" || bad "rimed's Tier did not move"
[ "$(count '^rime ' "$CALLS")" = 0 ] && ok "no rime CLI call" || bad "the rime CLI was called: $(grep '^rime ' "$CALLS")"

# A hold (Gaming Mode holds performance): the Shell shows the held tier.
fake_ppd_hold performance "Gaming Mode" org.rimeos.GameMode 4
holder=$!
if wait_for current performance 3; then ok "a performance hold shows as performance"; else bad "hold: current is '$(ipc current)'"; fi
case "$(ipc holds)" in *org.rimeos.GameMode*) ok "the hold is listed" ;; *) bad "holds: $(ipc holds)" ;; esac
wait "$holder" 2>/dev/null
if wait_for current power-saver 3; then ok "the hold's end returns to the chosen tier"; else bad "after the hold: current is '$(ipc current)'"; fi

# Polling: give a timer 9 s to show itself.
sleep 9
n="$(count '^busctl ' "$CALLS")"
[ "$n" = 1 ] && ok "one busctl in the whole run (the owner check): no polling" \
    || bad "the Shell started $n busctl calls (expected 1):$(sed 's/^/ | /' "$CALLS")"
stop_shell
fake_rimed_stop

# ── 2. nothing serves the API: the rimed fallback ────────────────────────────
echo "fallback: org.freedesktop.UPower.PowerProfiles has no owner"
fake_rimed_start --no-ppd || exit 1
: > "$CALLS"
start_shell
if wait_for backend rimed 10; then ok "backend is rimed"; else bad "backend is '$(ipc backend)', expected rimed"; fi
fake_rimed_change org.rimeos.Rimed1.Power Tier s power-saver
if wait_for current power-saver 6; then ok "reads rimed's Tier"; else bad "fallback current is '$(ipc current)'"; fi
ipc set performance >/dev/null
sleep 1
grep -qx "rime tier performance" "$CALLS" && ok "set runs rime tier performance" || bad "set did not run rime tier:$(sed 's/^/ | /' "$CALLS")"
stop_shell

echo "RESULT: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
