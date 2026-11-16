#!/usr/bin/env python3
"""Fake UPower (on DBUS_SYSTEM_BUS_ADDRESS) and a fake playing MPRIS player (on the session bus), for
tests/run-visualiser-battery-test.sh.

UPower: /org/freedesktop/UPower with OnBattery, EnumerateDevices, GetDisplayDevice, and a laptop battery as the
display device. `org.rimeos.Test.SetOnBattery(b)` flips OnBattery and emits PropertiesChanged, the way upowerd
does when the charger is pulled.

MPRIS: org.mpris.MediaPlayer2.rimetest, PlaybackStatus "Playing".

Usage: fake-upower-mpris.py ON_BATTERY(0|1) READY_FILE
"""
import sys

import dbus
import dbus.bus
import dbus.service
from dbus.mainloop.glib import DBusGMainLoop
from gi.repository import GLib

PROPS = "org.freedesktop.DBus.Properties"
UP = "org.freedesktop.UPower"
UPDEV = "org.freedesktop.UPower.Device"
DISPLAY = "/org/freedesktop/UPower/devices/DisplayDevice"


class Props(dbus.service.Object):
    def __init__(self, bus, path, props):
        super().__init__(bus, path)
        self.props = props  # {interface: {name: value}}

    @dbus.service.method(PROPS, in_signature="ss", out_signature="v")
    def Get(self, iface, name):
        return self.props[iface][name]

    @dbus.service.method(PROPS, in_signature="s", out_signature="a{sv}")
    def GetAll(self, iface):
        return dbus.Dictionary(self.props.get(iface, {}), signature="sv")

    @dbus.service.method(PROPS, in_signature="ssv")
    def Set(self, iface, name, value):
        raise dbus.exceptions.DBusException("read only")

    @dbus.service.signal(PROPS, signature="sa{sv}as")
    def PropertiesChanged(self, iface, changed, invalidated):
        pass


class UPower(Props):
    def __init__(self, bus, on_battery):
        super().__init__(bus, "/org/freedesktop/UPower", {UP: {
            "DaemonVersion": dbus.String("1.90.9"),
            "OnBattery": dbus.Boolean(on_battery),
            "LidIsClosed": dbus.Boolean(False),
            "LidIsPresent": dbus.Boolean(True),
        }})

    @dbus.service.method(UP, out_signature="ao")
    def EnumerateDevices(self):
        return dbus.Array([dbus.ObjectPath(DISPLAY)], signature="o")

    @dbus.service.method(UP, out_signature="o")
    def GetDisplayDevice(self):
        return dbus.ObjectPath(DISPLAY)

    @dbus.service.method(UP, out_signature="s")
    def GetCriticalAction(self):
        return "PowerOff"

    @dbus.service.method("org.rimeos.Test", in_signature="b")
    def SetOnBattery(self, value):
        self.props[UP]["OnBattery"] = dbus.Boolean(value)
        self.PropertiesChanged(UP, dbus.Dictionary({"OnBattery": dbus.Boolean(value)}, signature="sv"),
                               dbus.Array([], signature="s"))


def battery(bus, on_battery):
    return Props(bus, DISPLAY, {UPDEV: {
        "NativePath": dbus.String(""), "Vendor": dbus.String(""), "Model": dbus.String(""),
        "Type": dbus.UInt32(2), "PowerSupply": dbus.Boolean(True), "IsPresent": dbus.Boolean(True),
        "State": dbus.UInt32(2 if on_battery else 1), "Percentage": dbus.Double(80.0),
        "Energy": dbus.Double(40.0), "EnergyFull": dbus.Double(50.0), "EnergyRate": dbus.Double(5.0),
        "TimeToEmpty": dbus.Int64(28800), "TimeToFull": dbus.Int64(0), "IconName": dbus.String("battery-good"),
        "IsRechargeable": dbus.Boolean(True), "Capacity": dbus.Double(100.0), "WarningLevel": dbus.UInt32(1),
        "BatteryLevel": dbus.UInt32(1), "HealthPercent": dbus.Double(100.0), "Online": dbus.Boolean(False),
    }})


class Player(Props):
    def __init__(self, bus):
        root = "org.mpris.MediaPlayer2"
        super().__init__(bus, "/org/mpris/MediaPlayer2", {
            root: {"Identity": dbus.String("Rime test player"), "CanQuit": dbus.Boolean(False),
                   "CanRaise": dbus.Boolean(False), "HasTrackList": dbus.Boolean(False),
                   "DesktopEntry": dbus.String(""),
                   "SupportedUriSchemes": dbus.Array([], signature="s"),
                   "SupportedMimeTypes": dbus.Array([], signature="s")},
            root + ".Player": {
                "PlaybackStatus": dbus.String("Playing"), "LoopStatus": dbus.String("None"),
                "Rate": dbus.Double(1.0), "Shuffle": dbus.Boolean(False), "Volume": dbus.Double(1.0),
                "Position": dbus.Int64(0), "MinimumRate": dbus.Double(1.0), "MaximumRate": dbus.Double(1.0),
                "CanGoNext": dbus.Boolean(False), "CanGoPrevious": dbus.Boolean(False),
                "CanPlay": dbus.Boolean(True), "CanPause": dbus.Boolean(True), "CanSeek": dbus.Boolean(False),
                "CanControl": dbus.Boolean(True),
                "Metadata": dbus.Dictionary({"mpris:trackid": dbus.ObjectPath("/rimetest/1"),
                                             "xesam:title": dbus.String("Test tone"),
                                             "mpris:length": dbus.Int64(600000000)}, signature="sv"),
            }})


def main():
    on_battery = sys.argv[1] == "1"
    DBusGMainLoop(set_as_default=True)
    sysbus = dbus.bus.BusConnection(dbus.bus.BUS_SYSTEM)
    names = [dbus.service.BusName(UP, sysbus)]
    objs = [UPower(sysbus, on_battery), battery(sysbus, on_battery)]
    sess = dbus.SessionBus()
    names.append(dbus.service.BusName("org.mpris.MediaPlayer2.rimetest", sess))
    objs.append(Player(sess))
    with open(sys.argv[2], "w") as f:
        f.write("ready\n")
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
