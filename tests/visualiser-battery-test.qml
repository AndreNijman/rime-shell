import Quickshell
import QtQuick
import "./src"
import "./src/services"
import "./src/nexus"
import Quickshell.Services.Mpris
import "./src/services/players.js" as Players

// The audio visualisers, run for real (tests/run-visualiser-battery-test.sh stages this file at the repository
// root and provides a fake UPower, a playing MPRIS player and a stub `cava`). This file only asks for the bars, the
// way the notch and a recording do, and reports what the services do; the runner flips the charger and watches
// the stub processes.

ShellRoot {
    id: t

    // Compiled first, as in the Shell: with CavaService as the first type compiled, the settings pages it
    // reaches through src/qmldir import it back while it is still compiling ("is not a type").
    readonly property var _pages: NexusState

    function bars(a) {
        for (var i = 0; i < a.length; i++) if (a[i] !== 0) return "live"
        return "flat"
    }

    // The notch's bars are on screen.
    Binding { target: CavaService; property: "centerWants"; value: true }

    // Which players Quickshell sees, and the one the notch would show (CenterContent uses the same call).
    property string seen: {
        var v = Mpris.players.values, out = []
        for (var i = 0; i < v.length; i++)
            out.push(v[i].dbusName + (Players.isPhone(v[i]) ? "=phone" : "=local") + ":" + v[i].canControl)
        return out.join(",")
    }
    onSeenChanged: {
        var n = Players.preferLocal(Mpris.players.values)
        console.log("VIS players " + t.seen + " notch " + (n ? n.dbusName : "none"))
    }
    readonly property bool localPlaying: CavaService.isPlaying
    onLocalPlayingChanged: console.log("VIS isPlaying " + t.localPlaying)

    property string shared: t.bars(CavaService.bars)
    property string rec: t.bars(ScreenRecService.audioBars)
    onSharedChanged: console.log("VIS shared bars " + t.shared)
    onRecChanged: console.log("VIS rec bars " + t.rec)

    Connections {
        target: CavaService
        function onWantedChanged() { console.log("VIS shared wanted " + CavaService.wanted) }
        function onOnBatteryChanged() { console.log("VIS onBattery " + CavaService.onBattery) }
    }

    // A recording with audio has started (what _launch does once wf-recorder runs).
    Component.onCompleted: {
        console.log("VIS start onBattery " + CavaService.onBattery + " wanted " + CavaService.wanted)
        ScreenRecService.recording = true
        ScreenRecService._startCavaWithSource("rimetest.monitor")
    }
}
