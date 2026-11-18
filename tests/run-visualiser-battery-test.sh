#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/visualiser-battery-test.qml — the audio visualisers never run on
#  battery.
#
#  cava (the notch/dashboard bars, CavaService; the recording level meter,
#  ScreenRecService) costs 0.3-1 W on the L16 while music plays, out of a ~5 W
#  floor. On battery neither may run: not a frame, not at start-up, and both
#  come back when the charger is plugged in.
#
#  The real services run under quickshell (offscreen: no window). UPower is a
#  fake on a private second bus that stands in for the system bus
#  (DBUS_SYSTEM_BUS_ADDRESS); a fake MPRIS player plays on the private session
#  bus; `cava` is a stub first on PATH that records its PID and prints bars.
#  The runner flips OnBattery the way upowerd does (PropertiesChanged) and
#  checks which stubs are alive.
#
#  Skips cleanly (status 0) without quickshell, dbus-daemon or python3-dbus.
#
#  Run from the repository root: ./tests/run-visualiser-battery-test.sh
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }
command -v dbus-daemon >/dev/null 2>&1 || { echo "SKIP: dbus-daemon not installed"; exit 0; }
python3 -c 'import dbus, gi' 2>/dev/null || { echo "SKIP: python3-dbus / gi not installed"; exit 0; }

W="$(mktemp -d)"
staged="$root/.visualiser-battery-test.qml"
sys_pid=""
qs_pid=""
fake_pid=""
STUB_LOG="$W/stub.log"
export STUB_LOG
: > "$STUB_LOG"

stop_run() {
    [ -n "$qs_pid" ] && kill "$qs_pid" 2>/dev/null && wait "$qs_pid" 2>/dev/null
    [ -n "$fake_pid" ] && kill "$fake_pid" 2>/dev/null && wait "$fake_pid" 2>/dev/null
    qs_pid=""; fake_pid=""
    # Stubs that outlived their quickshell, by exact PID.
    while read -r _k p; do kill "$p" 2>/dev/null; done < "$STUB_LOG"
    return 0
}
cleanup() {
    stop_run
    [ -n "$sys_pid" ] && kill "$sys_pid" 2>/dev/null
    rm -f "$staged"; rm -rf "$W"; return 0
}
trap cleanup EXIT INT TERM
cp "$here/visualiser-battery-test.qml" "$staged"

export HOME="$W/home" XDG_CONFIG_HOME="$W/config" XDG_CACHE_HOME="$W/cache" XDG_STATE_HOME="$W/state"
export XDG_RUNTIME_DIR="$W/run"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

# ── The stand-in system bus (UPower lives there) ─────────────────────────────
cat > "$W/sys.conf" <<CONF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:dir=$W</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
CONF
dbus-daemon --config-file="$W/sys.conf" --fork --print-address=3 --print-pid=4 3>"$W/sys.addr" 4>"$W/sys.pid"
sys_pid="$(cat "$W/sys.pid")"
DBUS_SYSTEM_BUS_ADDRESS="$(head -1 "$W/sys.addr")"
export DBUS_SYSTEM_BUS_ADDRESS

# ── The stub cava: records "<kind> <pid>", prints full bars at 10 fps ────────
mkdir -p "$W/bin"
cat > "$W/bin/cava" <<'STUB'
#!/usr/bin/env bash
cfg="${2:-}"
case "$cfg" in *cava_rec.ini) kind=rec n=12 ;; *) kind=shared n=32 ;; esac
echo "$kind $$" >> "$STUB_LOG"
line=""; for _ in $(seq 1 "$n"); do line+="50;"; done
while :; do echo "$line"; sleep 0.1; done
STUB
chmod +x "$W/bin/cava"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

alive() {  # kind -> 0 when a stub of that kind is running
    local k p
    while read -r k p; do
        [ "$k" = "$1" ] && kill -0 "$p" 2>/dev/null && return 0
    done < "$STUB_LOG"
    return 1
}
started() { grep -q "^$1 " "$STUB_LOG"; }
until_true() {  # seconds command...
    local end=$((SECONDS + $1)); shift
    while [ "$SECONDS" -lt "$end" ]; do "$@" && return 0; sleep 0.2; done
    "$@"
}
none_alive() { ! alive shared && ! alive rec; }
both_alive() { alive shared && alive rec; }
battery() {
    dbus-send --bus="$DBUS_SYSTEM_BUS_ADDRESS" --print-reply --dest=org.freedesktop.UPower \
        /org/freedesktop/UPower org.rimeos.Test.SetOnBattery "boolean:$1" >/dev/null
}

start_run() {  # on_battery(0|1) [players(local|phone)]
    : > "$STUB_LOG"
    rm -f "$W/ready"
    python3 -I "$here/fake-upower-mpris.py" "$1" "$W/ready" "${2:-local}" > "$W/fake.log" 2>&1 &
    fake_pid=$!
    until_true 10 test -e "$W/ready" || { echo "RESULT: the fake services did not start"; cat "$W/fake.log"; exit 1; }
    ( cd "$root" && exec env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE PATH="$W/bin:$PATH" \
        QT_QPA_PLATFORM=offscreen QT_LOGGING_RULES="qml=true" \
        timeout 120 quickshell -p "$staged" ) > "$W/qs.log" 2>&1 &
    qs_pid=$!
}
log_has() { sed -e 's/\x1b\[[0-9;]*m//g' "$W/qs.log" | grep -q "$1"; }

# ── 1. Plugged in: both run; the charger pulled: both stop; back: both run ───
start_run 0
if until_true 20 both_alive; then ok "on AC: the notch bars and the recording meter run cava"
else bad "on AC: cava runs (stub log: $(tr '\n' ' ' < "$STUB_LOG"))"; fi
if until_true 5 log_has "VIS shared bars live"; then ok "on AC: the notch bars move"; else bad "on AC: the notch bars move"; fi

battery true
if until_true 5 none_alive; then ok "charger pulled: both cava processes stop"
else bad "charger pulled: cava stops (stub log: $(tr '\n' ' ' < "$STUB_LOG"))"; fi
if until_true 5 log_has "VIS shared bars flat"; then ok "charger pulled: the notch bars lie flat"
else bad "charger pulled: the notch bars lie flat"; fi
if until_true 5 log_has "VIS rec bars flat"; then ok "charger pulled: the recording meter lies flat"
else bad "charger pulled: the recording meter lies flat"; fi
before="$(wc -l < "$STUB_LOG")"
sleep 3
if [ "$(wc -l < "$STUB_LOG")" = "$before" ] && none_alive; then ok "on battery: nothing starts cava again"
else bad "on battery: cava started again (stub log: $(tr '\n' ' ' < "$STUB_LOG"))"; fi

battery false
if until_true 10 both_alive; then ok "charger back: both run again"
else bad "charger back: both run again (stub log: $(tr '\n' ' ' < "$STUB_LOG"))"; fi
stop_run

# ── 2. Started on battery: cava never runs, not even for a frame ─────────────
start_run 1
until_true 15 log_has "VIS start" >/dev/null
sleep 6
if ! started shared && ! started rec; then ok "started on battery: cava never ran"
else bad "started on battery: cava ran (stub log: $(tr '\n' ' ' < "$STUB_LOG"))"; fi
battery false
if until_true 10 both_alive; then ok "then plugged in: both run"
else bad "then plugged in: both run (stub log: $(tr '\n' ' ' < "$STUB_LOG"))"; fi
stop_run

# ── 3. Only a phone plays (Rime Remote): its sound is on the phone, so no cava ─
#  The notch's choice is logged by the test file with the same call
#  CenterContent makes. CenterContent itself is not loaded here: its own
#  centerWants binding would fight the one this test sets. So the file is held
#  to that call, and a notch that went back to `Mpris.players.values[0]` fails.
if grep -Eq 'readonly property var +player: +Players\.preferLocal\(Mpris\.players\.values\)' "$root/src/modules/Center/CenterContent.qml" \
   && ! grep -q 'Mpris\.players\.values\[0\]' "$root/src/modules/Center/CenterContent.qml"
then ok "the notch (CenterContent) picks its player with Players.preferLocal"
else bad "the notch (CenterContent) picks its player with Players.preferLocal"; fi

#  The notch bars: never. (The recording meter listens to the recording's own
#  source and is not about players; it is left out here.)
start_run 0 phone
if until_true 15 log_has "VIS players org.mpris.MediaPlayer2.rime_phone.d0102=phone:false notch org.mpris.MediaPlayer2.rime_phone.d0102"
then ok "a phone's player is seen as a phone's, read-only, and the notch shows it while it is alone"
else bad "a phone's player is seen as a phone's (log: $(sed -e 's/\x1b\[[0-9;]*m//g' "$W/qs.log" | grep 'VIS players' | tail -2 | tr '\n' ' '))"; fi
sleep 4
if ! started shared; then ok "only a phone playing: the notch bars never ran cava"
else bad "only a phone playing: cava ran (stub log: $(tr '\n' ' ' < "$STUB_LOG"))"; fi
dbus-send --bus="$DBUS_SYSTEM_BUS_ADDRESS" --print-reply --dest=org.freedesktop.UPower \
    /org/freedesktop/UPower org.rimeos.Test.StartLocal >/dev/null
if until_true 10 alive shared; then ok "then a computer player plays: the notch bars run"
else bad "then a computer player plays: the notch bars run (stub log: $(tr '\n' ' ' < "$STUB_LOG"))"; fi
if until_true 5 log_has "notch org.mpris.MediaPlayer2.rimetest\$"
then ok "with both, the notch shows the computer's player"
else bad "with both, the notch shows the computer's player (log: $(sed -e 's/\x1b\[[0-9;]*m//g' "$W/qs.log" | grep 'VIS players' | tail -2 | tr '\n' ' '))"; fi
stop_run

echo "visualiser-battery: passed=$pass failed=$fail"
if [ "$fail" -ne 0 ]; then
    echo "--- quickshell log (last run) ---"; sed -e 's/\x1b\[[0-9;]*m//g' "$W/qs.log" | tail -40
    exit 1
fi
