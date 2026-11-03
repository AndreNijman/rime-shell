#!/usr/bin/env python3
# ─────────────────────────────────────────────────────────────────────────────
#  tests/lib/fake-rimed.py — rimed's D-Bus surface, for clients under test.
#
#  It implements exactly the contract the desktop integrations and the Shell
#  build against (rime-os docs/nixos/desktops.md §6.2 and §7), on whatever bus
#  DBUS_SYSTEM_BUS_ADDRESS names. Point it at a PRIVATE bus: it owns
#  org.rimeos.Rimed1 and the power-profiles-daemon names.
#
#    org.rimeos.Rimed1          /org/rimeos/Rimed1
#      .Mode      Active (s daily|gaming), Held (s)         Set(s), Hold(s)
#      .GameMode  Active (b), Supported (b)                 SetActive(b)
#      .Updates   State, Available, Running, Message (s)    Check(), Apply()
#      .Power     Tier, Tiers, OnAcPower, AutoSwitch        SetTier(s), SetAutoSwitch(b), TierChanged(s)
#      .Battery   ChargeStart, ChargeEnd (y), Supported (b) SetChargeThresholds(yy)
#      .Test      (this fake only) Change(s iface, s prop, v value), Calls() -> as
#    org.freedesktop.UPower.PowerProfiles  /org/freedesktop/UPower/PowerProfiles
#    net.hadess.PowerProfiles              /net/hadess/PowerProfiles
#      ActiveProfile (rw), Profiles, PerformanceDegraded, PerformanceInhibited,
#      ActiveProfileHolds, Actions, BatteryAware, Version; HoldProfile, ReleaseProfile
#
#  Every property change emits org.freedesktop.DBus.Properties.PropertiesChanged,
#  as rimed does. Every method call AND every property read is appended to the
#  call log (--log FILE, one line each, "iface.Member args"), so a suite can
#  count reads: a client that polls shows up as a growing number of Get lines.
#
#  `Test.Change` is how a suite changes state "from elsewhere" (the CLI, another
#  desktop): the property moves and PropertiesChanged goes out, exactly as if
#  rimed had done it, without any client method being involved.
#
#  Options: --no-ppd (do not own the power-profiles names: the "older rimed"
#  case), --no-rimed (own only the power-profiles names), --log FILE,
#  --ready FILE (written once every name is owned).
# ─────────────────────────────────────────────────────────────────────────────
import argparse
import sys

from gi.repository import Gio, GLib

RIMED_PATH = "/org/rimeos/Rimed1"
PPD = [
    ("org.freedesktop.UPower.PowerProfiles", "/org/freedesktop/UPower/PowerProfiles"),
    ("net.hadess.PowerProfiles", "/net/hadess/PowerProfiles"),
]

RIMED_XML = """
<node>
  <interface name="org.rimeos.Rimed1.Mode">
    <property name="Active" type="s" access="read"/>
    <property name="Held" type="s" access="read"/>
    <method name="Set"><arg name="mode" type="s" direction="in"/></method>
    <method name="Hold"><arg name="mode" type="s" direction="in"/></method>
  </interface>
  <interface name="org.rimeos.Rimed1.GameMode">
    <property name="Active" type="b" access="read"/>
    <property name="Supported" type="b" access="read"/>
    <method name="SetActive"><arg name="active" type="b" direction="in"/></method>
    <signal name="ActiveChanged"><arg name="active" type="b"/></signal>
  </interface>
  <interface name="org.rimeos.Rimed1.Updates">
    <property name="State" type="s" access="read"/>
    <property name="Available" type="s" access="read"/>
    <property name="Running" type="s" access="read"/>
    <property name="Message" type="s" access="read"/>
    <method name="Check"/>
    <method name="Apply"/>
  </interface>
  <interface name="org.rimeos.Rimed1.Power">
    <property name="Tier" type="s" access="read"/>
    <property name="Tiers" type="as" access="read"/>
    <property name="OnAcPower" type="b" access="read"/>
    <property name="AutoSwitch" type="b" access="read"/>
    <method name="SetTier"><arg name="tier" type="s" direction="in"/></method>
    <method name="SetAutoSwitch"><arg name="on" type="b" direction="in"/></method>
    <signal name="TierChanged"><arg name="tier" type="s"/></signal>
  </interface>
  <interface name="org.rimeos.Rimed1.Battery">
    <property name="ChargeStart" type="y" access="read"/>
    <property name="ChargeEnd" type="y" access="read"/>
    <property name="Supported" type="b" access="read"/>
    <property name="Capacity" type="y" access="read"/>
    <property name="Status" type="s" access="read"/>
    <method name="SetChargeThresholds">
      <arg name="start" type="y" direction="in"/><arg name="end" type="y" direction="in"/>
    </method>
  </interface>
  <interface name="org.rimeos.Rimed1.Test">
    <method name="Change">
      <arg name="iface" type="s" direction="in"/><arg name="prop" type="s" direction="in"/>
      <arg name="value" type="v" direction="in"/>
    </method>
    <method name="Calls"><arg name="calls" type="as" direction="out"/></method>
  </interface>
</node>
"""

PPD_XML = """
<node>
  <interface name="%s">
    <property name="ActiveProfile" type="s" access="readwrite"/>
    <property name="Profiles" type="aa{sv}" access="read"/>
    <property name="PerformanceDegraded" type="s" access="read"/>
    <property name="PerformanceInhibited" type="s" access="read"/>
    <property name="ActiveProfileHolds" type="aa{sv}" access="read"/>
    <property name="Actions" type="as" access="read"/>
    <property name="BatteryAware" type="b" access="readwrite"/>
    <property name="Version" type="s" access="read"/>
    <method name="HoldProfile">
      <arg name="profile" type="s" direction="in"/><arg name="reason" type="s" direction="in"/>
      <arg name="application_id" type="s" direction="in"/><arg name="cookie" type="u" direction="out"/>
    </method>
    <method name="ReleaseProfile"><arg name="cookie" type="u" direction="in"/></method>
    <signal name="ProfileReleased"><arg name="cookie" type="u"/></signal>
  </interface>
</node>
"""

SIG = {
    # The D-Bus type of every property, for Test.Change and for GetAll.
    "org.rimeos.Rimed1.Mode": {"Active": "s", "Held": "s"},
    "org.rimeos.Rimed1.GameMode": {"Active": "b", "Supported": "b"},
    "org.rimeos.Rimed1.Updates": {"State": "s", "Available": "s", "Running": "s", "Message": "s"},
    "org.rimeos.Rimed1.Power": {"Tier": "s", "Tiers": "as", "OnAcPower": "b", "AutoSwitch": "b"},
    "org.rimeos.Rimed1.Battery": {"ChargeStart": "y", "ChargeEnd": "y", "Supported": "b", "Capacity": "y", "Status": "s"},
}
TIERS = ["performance", "balanced", "power-saver"]


class Fake:
    def __init__(self, args):
        self.args = args
        self.log = open(args.log, "a", buffering=1) if args.log else None
        self.calls = []
        self.state = {
            "org.rimeos.Rimed1.Mode": {"Active": "daily", "Held": ""},
            "org.rimeos.Rimed1.GameMode": {"Active": False, "Supported": True},
            "org.rimeos.Rimed1.Updates": {"State": "up-to-date", "Available": "", "Running": "2026.11.03", "Message": ""},
            "org.rimeos.Rimed1.Power": {"Tier": "balanced", "Tiers": TIERS, "OnAcPower": True, "AutoSwitch": True},
            "org.rimeos.Rimed1.Battery": {"ChargeStart": 0, "ChargeEnd": 100, "Supported": True, "Capacity": 80, "Status": "Charging"},
        }
        self.holds = {}  # cookie -> (profile, reason, app_id, sender)
        self.next_cookie = 1
        self.conn = None

    # ── bookkeeping ─────────────────────────────────────────────────────────
    def note(self, line):
        self.calls.append(line)
        if self.log:
            self.log.write(line + "\n")

    def emit_changed(self, path, iface, changed):
        if not changed:
            return
        body = GLib.Variant("(sa{sv}as)", (iface, changed, []))
        self.conn.emit_signal(None, path, "org.freedesktop.DBus.Properties", "PropertiesChanged", body)

    def set_rimed(self, iface, prop, value):
        if self.state[iface].get(prop) == value:
            return
        self.state[iface][prop] = value
        self.emit_changed(RIMED_PATH, iface, {prop: GLib.Variant(SIG[iface][prop], value)})
        if iface == "org.rimeos.Rimed1.Power" and prop == "Tier":
            self.conn.emit_signal(None, RIMED_PATH, iface, "TierChanged", GLib.Variant("(s)", (value,)))
            self.ppd_changed(["ActiveProfile"])
        if iface == "org.rimeos.Rimed1.GameMode" and prop == "Active":
            self.conn.emit_signal(None, RIMED_PATH, iface, "ActiveChanged", GLib.Variant("(b)", (value,)))

    # ── power profiles ──────────────────────────────────────────────────────
    def effective(self):
        held = [h[0] for h in self.holds.values()]
        if "power-saver" in held:
            return "power-saver"
        if "performance" in held:
            return "performance"
        return self.state["org.rimeos.Rimed1.Power"]["Tier"]

    def ppd_value(self, prop):
        if prop == "ActiveProfile":
            return GLib.Variant("s", self.effective())
        if prop == "Profiles":
            return GLib.Variant("aa{sv}", [
                {"Profile": GLib.Variant("s", t), "Driver": GLib.Variant("s", "rimed"),
                 "PlatformDriver": GLib.Variant("s", "platform_profile"), "CpuDriver": GLib.Variant("s", "intel_pstate")}
                for t in TIERS])
        if prop in ("PerformanceDegraded", "PerformanceInhibited"):
            return GLib.Variant("s", "")
        if prop == "ActiveProfileHolds":
            return GLib.Variant("aa{sv}", [
                {"Profile": GLib.Variant("s", p), "Reason": GLib.Variant("s", r), "ApplicationId": GLib.Variant("s", a)}
                for (p, r, a, _s) in self.holds.values()])
        if prop == "Actions":
            return GLib.Variant("as", [])
        if prop == "BatteryAware":
            return GLib.Variant("b", self.state["org.rimeos.Rimed1.Power"]["AutoSwitch"])
        if prop == "Version":
            return GLib.Variant("s", "0.30")
        return None

    def ppd_changed(self, props):
        if self.args.no_ppd:
            return
        for name, path in PPD:
            self.emit_changed(path, name, {p: self.ppd_value(p) for p in props})

    def release(self, cookie):
        if cookie in self.holds:
            del self.holds[cookie]
            for name, path in PPD:
                self.conn.emit_signal(None, path, name, "ProfileReleased", GLib.Variant("(u)", (cookie,)))
            self.ppd_changed(["ActiveProfileHolds", "ActiveProfile"])

    # ── handlers ────────────────────────────────────────────────────────────
    def rimed_call(self, conn, sender, path, iface, method, params, inv):
        args = params.unpack()
        self.note("%s.%s %s" % (iface, method, " ".join(str(a) for a in args)))
        ret = None
        if iface == "org.rimeos.Rimed1.Mode" and method in ("Set", "Hold"):
            mode = args[0]
            if mode not in ("daily", "gaming", "") or (method == "Set" and mode == ""):
                inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "unknown mode %r" % mode)
                return
            self.set_rimed("org.rimeos.Rimed1.Mode", "Held", mode)
            if method == "Set":
                self.set_rimed("org.rimeos.Rimed1.Mode", "Active", mode)
        elif iface == "org.rimeos.Rimed1.GameMode" and method == "SetActive":
            self.set_rimed("org.rimeos.Rimed1.GameMode", "Active", bool(args[0]))
        elif iface == "org.rimeos.Rimed1.Updates" and method == "Check":
            pass
        elif iface == "org.rimeos.Rimed1.Updates" and method == "Apply":
            self.set_rimed("org.rimeos.Rimed1.Updates", "State", "installing")
        elif iface == "org.rimeos.Rimed1.Power" and method == "SetTier":
            if args[0] not in TIERS:
                inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "unknown tier %r" % args[0])
                return
            self.set_rimed("org.rimeos.Rimed1.Power", "Tier", args[0])
        elif iface == "org.rimeos.Rimed1.Power" and method == "SetAutoSwitch":
            self.set_rimed("org.rimeos.Rimed1.Power", "AutoSwitch", bool(args[0]))
            self.ppd_changed(["BatteryAware"])
        elif iface == "org.rimeos.Rimed1.Battery" and method == "SetChargeThresholds":
            start, end = int(args[0]), int(args[1])
            if not (0 <= start < end <= 100):
                inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "bad thresholds")
                return
            self.set_rimed("org.rimeos.Rimed1.Battery", "ChargeStart", start)
            self.set_rimed("org.rimeos.Rimed1.Battery", "ChargeEnd", end)
        elif iface == "org.rimeos.Rimed1.Test" and method == "Change":
            t_iface, prop, value = args
            if t_iface in SIG:
                self.set_rimed(t_iface, prop, value)
            else:
                inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "no interface %s" % t_iface)
                return
        elif iface == "org.rimeos.Rimed1.Test" and method == "Calls":
            ret = GLib.Variant("(as)", (list(self.calls),))
        else:
            inv.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)
            return
        inv.return_value(ret)

    def rimed_get(self, conn, sender, path, iface, prop):
        self.note("Get %s.%s" % (iface, prop))
        return GLib.Variant(SIG[iface][prop], self.state[iface][prop])

    def ppd_call(self, conn, sender, path, iface, method, params, inv):
        args = params.unpack()
        self.note("%s.%s %s" % (iface, method, " ".join(str(a) for a in args)))
        if method == "HoldProfile":
            profile, reason, app = args
            if profile not in ("performance", "power-saver"):
                inv.return_dbus_error("org.freedesktop.DBus.Error.InvalidArgs", "cannot hold %r" % profile)
                return
            cookie = self.next_cookie
            self.next_cookie += 1
            self.holds[cookie] = (profile, reason, app, sender)
            self.ppd_changed(["ActiveProfileHolds", "ActiveProfile"])
            inv.return_value(GLib.Variant("(u)", (cookie,)))
        elif method == "ReleaseProfile":
            self.release(int(args[0]))
            inv.return_value(None)
        else:
            inv.return_dbus_error("org.freedesktop.DBus.Error.UnknownMethod", method)

    def ppd_get(self, conn, sender, path, iface, prop):
        self.note("Get %s.%s" % (iface, prop))
        return self.ppd_value(prop)

    def ppd_set(self, conn, sender, path, iface, prop, value):
        self.note("Set %s.%s %s" % (iface, prop, value.unpack()))
        if prop == "ActiveProfile":
            target = value.unpack()
            if target not in TIERS:
                return False
            # PPD 0.30: an explicit choice releases every hold.
            for cookie in list(self.holds):
                self.release(cookie)
            self.set_rimed("org.rimeos.Rimed1.Power", "Tier", target)
            self.ppd_changed(["ActiveProfile"])
            return True
        if prop == "BatteryAware":
            self.set_rimed("org.rimeos.Rimed1.Power", "AutoSwitch", bool(value.unpack()))
            self.ppd_changed(["BatteryAware"])
            return True
        return False

    # ── bus ─────────────────────────────────────────────────────────────────
    def run(self):
        addr = GLib.getenv("DBUS_SYSTEM_BUS_ADDRESS")
        if not addr:
            sys.exit("fake-rimed: DBUS_SYSTEM_BUS_ADDRESS is not set; refusing to touch the real system bus")
        self.conn = Gio.DBusConnection.new_for_address_sync(
            addr, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        names = []
        if not self.args.no_rimed:
            node = Gio.DBusNodeInfo.new_for_xml(RIMED_XML)
            for info in node.interfaces:
                self.conn.register_object(RIMED_PATH, info, self.rimed_call, self.rimed_get, None)
            names.append("org.rimeos.Rimed1")
        if not self.args.no_ppd:
            for name, path in PPD:
                info = Gio.DBusNodeInfo.new_for_xml(PPD_XML % name).interfaces[0]
                self.conn.register_object(path, info, self.ppd_call, self.ppd_get, self.ppd_set)
                names.append(name)
        # Holds die with their caller's bus name, as rimed's do.
        self.conn.signal_subscribe("org.freedesktop.DBus", "org.freedesktop.DBus", "NameOwnerChanged",
                                   "/org/freedesktop/DBus", None, Gio.DBusSignalFlags.NONE, self.on_owner, None)
        for n in names:
            r = self.conn.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                                    "RequestName", GLib.Variant("(su)", (n, 4)), GLib.VariantType("(u)"),
                                    Gio.DBusCallFlags.NONE, -1, None).unpack()[0]
            if r != 1:
                sys.exit("fake-rimed: could not own %s (%d)" % (n, r))
        if self.args.ready:
            with open(self.args.ready, "w") as f:
                f.write(" ".join(names) + "\n")
        GLib.MainLoop().run()

    def on_owner(self, conn, sender, path, iface, signal, params, data):
        name, _old, new = params.unpack()
        if new == "" and name.startswith(":"):
            for cookie, h in list(self.holds.items()):
                if h[3] == name:
                    self.release(cookie)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--no-ppd", action="store_true")
    p.add_argument("--no-rimed", action="store_true")
    p.add_argument("--log")
    p.add_argument("--ready")
    Fake(p.parse_args()).run()


if __name__ == "__main__":
    main()
