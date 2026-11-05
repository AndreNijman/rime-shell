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
#              a set writes ActiveProfile (one `busctl set-property` per press);
#              a hold shows as the held tier; a write rimed refuses shows the
#              pick at once, then the reason (`error`) and the tier in force
#              again, as soon as the refusal comes back; over the whole run the
#              Shell read with exactly ONE busctl (the owner check) and read
#              rimed's Tier zero times
#    fallback  the name has no owner (an older rimed): backend "rimed", the
#              tier read from org.rimeos.Rimed1 Power.Tier, a set runs
#              `rime tier <id>`
#    other     the name is owned by another daemon (bootc runs
#              power-profiles-daemon beside rimed): backend "rimed", a set
#              runs `rime tier <id>` and never reaches that daemon
#    queued    the owner check answers 3 s late and a set arrives first: it
#              waits and lands on the backend the check finds (ActiveProfile
#              under ppd, one `rime tier` in the fallback)
#    no consumer  nothing holds the service (the Settings page off screen)
#              and a set comes over IPC: it starts the owner check itself
#
#  Mutants (tests/mutate-settings-app.sh): fallback removed; polling put back;
#  owner check by name only (NameHasOwner); no queue (a set before the check
#  goes to `rime tier`); no kick (a queued set with no consumer never asks);
#  Quickshell writes (the old path: no reason, the refused pick stays); the
#  refused pick kept; the refusal's reason dropped.
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
SLOW="$HEADLESS_W/slow-owner-check"
# With $SLOW present the owner check (and only it) answers 3 s late, logged
# before the wait so the count stays one call.
cat > "$HEADLESS_W/bin/busctl" <<WRAP
#!/usr/bin/env bash
echo "busctl \$*" >> "$CALLS"
case "\$*" in *"call org.freedesktop.UPower.PowerProfiles /org/rimeos/Rimed1 "*) [ -e "$SLOW" ] && sleep 3 ;; esac
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
    for _ in $(seq 1 $(( $3 * 4 ))); do [ "$(ipc "$1")" = "$2" ] && return 0; sleep 0.25; done
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

# A write rimed refuses (polkit said no). The refusal comes back after 1.5 s,
# so the pick must show at once, then give way to the tier in force, with why.
fake_rimed_call() { "$real_busctl" --address="$DBUS_SYSTEM_BUS_ADDRESS" call org.rimeos.Rimed1 /org/rimeos/Rimed1 org.rimeos.Rimed1.Test "$@" >/dev/null; }
fake_rimed_call RefuseSets su "not authorized for net.hadess.PowerProfiles.switch-profile" 1500
ipc set performance >/dev/null
[ "$(ipc current)" = performance ] && ok "refused: the pick shows at once (no wait for rimed)" \
    || bad "refused: the pick did not show at once (current '$(ipc current)')"
if wait_for current power-saver 4; then ok "refused: the label is back on the tier in force (power-saver)"; else bad "refused: the refused pick stayed (current '$(ipc current)')"; fi
case "$(ipc error)" in
    *"Not allowed"*) ok "refused: says why ('$(ipc error)')" ;;
    *) bad "refused: no reason shown (error '$(ipc error)', detail '$(ipc errorDetail)')" ;;
esac
grep -q "ActiveProfile performance refused" "$FAKE_RIMED_LOG" && ok "refused: rimed refused the write" \
    || bad "refused: the write never reached rimed's refusal$(sed 's/^/ | /' "$FAKE_RIMED_LOG")"
[ "$($B get-property org.rimeos.Rimed1 /org/rimeos/Rimed1 org.rimeos.Rimed1.Power Tier)" = 's "power-saver"' ] \
    && ok "refused: rimed's Tier did not move" || bad "refused: rimed's Tier moved"
fake_rimed_call RefuseSets su "" 0
ipc set balanced >/dev/null
if wait_for current balanced 3; then ok "after a refusal the next set lands (balanced)"; else bad "after a refusal: current is '$(ipc current)'"; fi
[ -z "$(ipc error)" ] && ok "the next press cleared the reason" || bad "the reason stayed: '$(ipc error)'"

# Polling: give a timer 9 s to show itself.
sleep 9
n="$(grep '^busctl ' "$CALLS" | grep -vc ' set-property ' || true)"
[ "$n" = 1 ] && ok "one busctl read in the whole run (the owner check): no polling" \
    || bad "the Shell started $n busctl calls that were not writes (expected 1):$(sed 's/^/ | /' "$CALLS")"
w="$(grep -c '^busctl --system set-property org.freedesktop.UPower.PowerProfiles ' "$CALLS" || true)"
[ "$w" = 3 ] && ok "one busctl write per press (3 presses)" \
    || bad "$w busctl writes for 3 presses:$(sed 's/^/ | /' "$CALLS")"
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
fake_rimed_stop

# ── 3. another daemon owns the API (bootc: power-profiles-daemon) ────────────
# rimed runs without the API and a second process, standing in for
# power-profiles-daemon, owns org.freedesktop.UPower.PowerProfiles. The name
# HAS an owner, but it is not rimed: the Shell must keep driving rimed.
echo "other owner: org.freedesktop.UPower.PowerProfiles is another daemon's"
fake_rimed_start --no-ppd || exit 1
other_ready="$HEADLESS_W/other-ppd.ready"; rm -f "$other_ready"
PYTHONDONTWRITEBYTECODE=1 python3 "$here/lib/fake-rimed.py" --no-rimed --ready "$other_ready" \
    > "$HEADLESS_W/other-ppd.out" 2>&1 &
other=$!
for _ in $(seq 1 100); do [ -s "$other_ready" ] && break; sleep 0.1; done
[ -s "$other_ready" ] || { echo "the other power-profiles owner did not come up"; cat "$HEADLESS_W/other-ppd.out"; exit 1; }
: > "$CALLS"
start_shell
if wait_for backend rimed 10; then ok "another daemon's power-profiles name: backend is rimed"; else bad "backend is '$(ipc backend)' with another daemon owning the API, expected rimed"; fi
ipc set power-saver >/dev/null
sleep 1
grep -qx "rime tier power-saver" "$CALLS" && ok "set runs rime tier power-saver, not the other daemon" \
    || bad "set did not run rime tier:$(sed 's/^/ | /' "$CALLS")"
stop_shell
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
fake_rimed_stop

# ── 4. a set before the owner check answers (ppd) ───────────────────────────
# The check answers 3 s late; a set sent the moment the harness loads must wait
# for it and then go to the power-profiles API, not to `rime tier`.
echo "queued: a set before the owner check answers, rimed owns the API"
fake_rimed_start || exit 1
: > "$CALLS"; touch "$SLOW"
start_shell
ipc set power-saver >/dev/null
early="$(ipc backend)"
[ -z "$early" ] && ok "the set landed before the owner check answered" \
    || bad "the owner check had already answered ('$early'): this case tested nothing"
if wait_for backend ppd 10; then ok "queued: backend is ppd"; else bad "queued: backend is '$(ipc backend)', expected ppd"; fi
if wait_for current power-saver 4; then ok "queued: the early set shows power-saver"; else bad "queued: current is '$(ipc current)'"; fi
grep -q "Set org.freedesktop.UPower.PowerProfiles.ActiveProfile power-saver" "$FAKE_RIMED_LOG" \
    && ok "queued: the early set wrote ActiveProfile" || bad "queued: the early set did not write ActiveProfile"
[ "$(count '^rime ' "$CALLS")" = 0 ] && ok "queued: no rime CLI call (the early set waited for the owner check)" \
    || bad "queued: the early set went to the rime CLI:$(sed 's/^/ | /' "$CALLS")"
stop_shell
fake_rimed_stop
rm -f "$SLOW"

# ── 5. a set before the owner check answers (fallback) ──────────────────────
echo "queued: a set before the owner check answers, nothing owns the API"
fake_rimed_start --no-ppd || exit 1
: > "$CALLS"; touch "$SLOW"
start_shell
ipc set performance >/dev/null
[ -z "$(ipc backend)" ] && ok "fallback: the set landed before the owner check answered" \
    || bad "fallback: the owner check had already answered: this case tested nothing"
if wait_for backend rimed 10; then ok "queued fallback: backend is rimed"; else bad "queued fallback: backend is '$(ipc backend)'"; fi
sleep 1
[ "$(grep -cx "rime tier performance" "$CALLS")" = 1 ] && ok "queued fallback: the early set ran rime tier performance once" \
    || bad "queued fallback: rime tier calls:$(sed 's/^/ | /' "$CALLS")"
stop_shell
fake_rimed_stop
rm -f "$SLOW"

# ── 6. a set with nothing holding the service (the IPC hook, page off screen) ─
echo "no consumer: a set over IPC with no page holding the service"
fake_rimed_start || exit 1
: > "$CALLS"
export PPS_TEST_NO_REF=1
start_shell
unset PPS_TEST_NO_REF
sleep 1
[ "$(count '^busctl ' "$CALLS")" = 0 ] && ok "no consumer: no owner check before the set" \
    || bad "no consumer: busctl ran before any set:$(sed 's/^/ | /' "$CALLS")"
ipc set performance >/dev/null
if wait_for backend ppd 10; then ok "no consumer: the set asked who owns the API (ppd)"; else bad "no consumer: backend is '$(ipc backend)', expected ppd"; fi
for _ in $(seq 1 12); do grep -q "ActiveProfile performance" "$FAKE_RIMED_LOG" && break; sleep 0.25; done
grep -q "Set org.freedesktop.UPower.PowerProfiles.ActiveProfile performance" "$FAKE_RIMED_LOG" \
    && ok "no consumer: the set wrote ActiveProfile" || bad "no consumer: the set did not write ActiveProfile"
[ "$(count '^rime ' "$CALLS")" = 0 ] && ok "no consumer: no rime CLI call" \
    || bad "no consumer: the set went to the rime CLI:$(sed 's/^/ | /' "$CALLS")"
stop_shell
fake_rimed_stop

echo "RESULT: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
