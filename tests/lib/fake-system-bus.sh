# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
#  tests/lib/fake-system-bus.sh — a PRIVATE bus standing in for the system bus,
#  with tests/lib/fake-rimed.py on it. Source it; do not execute it.
#
#      . "$here/lib/fake-system-bus.sh"
#      fake_bus_start "$dir"            # a dbus-daemon of our own; exports DBUS_SYSTEM_BUS_ADDRESS
#      fake_rimed_start [--no-ppd]      # the fake rimed on it; waits until it owns its names
#      fake_rimed_change org.rimeos.Rimed1.Mode Active s gaming    # "from elsewhere"
#      fake_rimed_calls                 # the call log so far, one call per line
#      fake_bus_stop
#
#  Nothing here ever talks to the real system bus: DBUS_SYSTEM_BUS_ADDRESS is
#  exported before anything starts, and fake-rimed.py refuses to run without
#  it. The bus lists no service directories, so nothing can be activated on it.
# ─────────────────────────────────────────────────────────────────────────────
FAKE_BUS_DIR=""
FAKE_BUS_PID=""
FAKE_RIMED_PID=""
FAKE_RIMED_LOG=""
_fake_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fake_bus_start() {
    FAKE_BUS_DIR="$1"
    mkdir -p "$FAKE_BUS_DIR"
    cat > "$FAKE_BUS_DIR/bus.conf" <<CONF
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:path=$FAKE_BUS_DIR/system_bus_socket</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
CONF
    dbus-daemon --config-file="$FAKE_BUS_DIR/bus.conf" --nofork --nopidfile >"$FAKE_BUS_DIR/daemon.log" 2>&1 &
    FAKE_BUS_PID=$!
    local _
    for _ in $(seq 1 50); do [ -S "$FAKE_BUS_DIR/system_bus_socket" ] && break; sleep 0.1; done
    [ -S "$FAKE_BUS_DIR/system_bus_socket" ] || { echo "fake bus did not start"; cat "$FAKE_BUS_DIR/daemon.log"; return 1; }
    export DBUS_SYSTEM_BUS_ADDRESS="unix:path=$FAKE_BUS_DIR/system_bus_socket"
}

fake_rimed_start() {
    FAKE_RIMED_LOG="$FAKE_BUS_DIR/rimed-calls.log"
    : > "$FAKE_RIMED_LOG"
    rm -f "$FAKE_BUS_DIR/rimed.ready"
    PYTHONDONTWRITEBYTECODE=1 python3 "$_fake_lib/fake-rimed.py" --log "$FAKE_RIMED_LOG" \
        --ready "$FAKE_BUS_DIR/rimed.ready" "$@" >"$FAKE_BUS_DIR/rimed.out" 2>&1 &
    FAKE_RIMED_PID=$!
    local _
    for _ in $(seq 1 100); do [ -s "$FAKE_BUS_DIR/rimed.ready" ] && return 0; sleep 0.1; done
    echo "fake rimed did not come up"; cat "$FAKE_BUS_DIR/rimed.out"; return 1
}

fake_rimed_stop() {
    [ -n "$FAKE_RIMED_PID" ] && kill "$FAKE_RIMED_PID" 2>/dev/null && wait "$FAKE_RIMED_PID" 2>/dev/null
    FAKE_RIMED_PID=""
}

# fake_rimed_change <iface> <prop> <dbus-type> <value>
fake_rimed_change() {
    "${FAKE_BUSCTL:-busctl}" --address="$DBUS_SYSTEM_BUS_ADDRESS" call org.rimeos.Rimed1 /org/rimeos/Rimed1 \
        org.rimeos.Rimed1.Test Change ssv "$1" "$2" "$3" "$4" >/dev/null
}

fake_rimed_calls() { cat "$FAKE_RIMED_LOG"; }

# fake_ppd_hold <profile> <reason> <app-id> <seconds> — a client that holds a
# profile and stays connected (a hold dies with its caller's bus name), in the
# background; prints nothing.
fake_ppd_hold() {
    PYTHONDONTWRITEBYTECODE=1 python3 - "$@" <<'PY' &
import os, sys, time
from gi.repository import Gio, GLib
c = Gio.DBusConnection.new_for_address_sync(os.environ["DBUS_SYSTEM_BUS_ADDRESS"],
    Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
c.call_sync("org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles",
    "org.freedesktop.UPower.PowerProfiles", "HoldProfile", GLib.Variant("(sss)", tuple(sys.argv[1:4])),
    GLib.VariantType("(u)"), Gio.DBusCallFlags.NONE, -1, None)
time.sleep(float(sys.argv[4]))
PY
}

fake_bus_stop() {
    fake_rimed_stop
    [ -n "$FAKE_BUS_PID" ] && kill "$FAKE_BUS_PID" 2>/dev/null && wait "$FAKE_BUS_PID" 2>/dev/null
    FAKE_BUS_PID=""
}
