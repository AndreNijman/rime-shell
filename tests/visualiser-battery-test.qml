import Quickshell
import QtQuick
import "./src"
import "./src/services"
import "./src/nexus"

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
