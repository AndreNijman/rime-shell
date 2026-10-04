import QtQuick
import QtTest
import Quickshell
import "../src"
import "../src/windows"

// ─────────────────────────────────────────────────────────────────────────────
// edge-intent-test.qml — the volume and brightness panel opens when the pointer
// is put on the right edge on purpose, and not when it passes.
//
// Driven by tests/run-edge-intent-test.sh on a headless compositor. It builds
// the real right strip (windows/Border.qml) and moves the pointer over it with
// QtTest, so the strip's own HoverHandler, EdgeIntent and timers decide; the
// test only reads Popups.quickTriggerHovered (what opens the panel) and
// Popups.quickOpen (what a click sets), and counts every time the trigger rose.
//
//   near    rests 12 px from the edge, inside the old hover zone: no open.
//   flick   touches the edge for 80 ms and leaves: no open.
//   rest    rests at the edge: opens; leaving the strip closes it again.
//   slide   slides along the edge: no open while sliding; opens once it stops.
//   tremor  rests at the edge with a ±5 px tremble: opens.
//   spent   closed from elsewhere with the pointer still at the edge: stays
//           closed while it rests there; opens again after it leaves and
//           comes back.
//   click   a click on the strip opens it; another closes it.
// ─────────────────────────────────────────────────────────────────────────────

ShellRoot {
    Border {
        id: strip
        edge: "right"
    }

    TestCase {
        id: tc
        name: "EdgeIntent"
        when: false
    }

    QtObject {
        id: t
        property int rises: 0
        function report(k, v) { console.log("PROBE " + k + "=" + v) }
        function at(x, y) { tc.mouseMove(strip.contentItem, x, y) }
        // The strip's x for a pointer `d` px from the screen's edge, and the
        // middle of its 300 px trigger band.
        function x(d) { return strip.width - 1 - d }
        function midY() { return strip.height / 2 }
        function away() { tc.mouseMove(strip.contentItem, t.x(0), 4) }
    }
    Connections {
        target: Popups
        function onQuickTriggerHoveredChanged() { if (Popups.quickTriggerHovered) t.rises++ }
    }

    // Steps: [what to do, how long to wait after it, in ms].
    property var steps: [
        [function () { t.away() }, 900],
        // near: inside the strip's input, short of the edge.
        [function () { t.rises = 0; t.at(t.x(12), t.midY()) }, 120],
        [function () { t.at(t.x(12), t.midY() + 2) }, 900],
        [function () { t.report("near.rises", t.rises); t.away() }, 900],
        // flick: to the edge and straight back out.
        [function () { t.rises = 0; t.at(t.x(0), t.midY()) }, 80],
        [function () { t.away() }, 700],
        [function () { t.report("flick.rises", t.rises) }, 50],
        // rest: to the edge, and stay.
        [function () { t.rises = 0; t.at(t.x(0), t.midY()) }, 450],
        [function () { t.report("rest.open", Popups.quickTriggerHovered); t.away() }, 1200],
        [function () { t.report("rest.afterLeave", Popups.quickTriggerHovered) }, 50],
        // slide: along the edge, 20 px every 60 ms, then stop.
        [function () { t.rises = 0; t.at(t.x(0), t.midY() - 120) }, 60],
        [function () { t.at(t.x(0), t.midY() - 100) }, 60],
        [function () { t.at(t.x(0), t.midY() - 80) }, 60],
        [function () { t.at(t.x(0), t.midY() - 60) }, 60],
        [function () { t.at(t.x(0), t.midY() - 40) }, 60],
        [function () { t.at(t.x(0), t.midY() - 20) }, 60],
        [function () { t.at(t.x(0), t.midY()) }, 60],
        [function () { t.at(t.x(0), t.midY() + 20) }, 60],
        [function () { t.at(t.x(0), t.midY() + 40) }, 60],
        [function () { t.report("slide.risesWhileMoving", t.rises) }, 450],
        [function () { t.report("slide.openAfterStop", Popups.quickTriggerHovered); t.away() }, 1200],
        // tremor: at the edge, trembling ±5 px.
        [function () { t.rises = 0; t.at(t.x(0), t.midY()) }, 50],
        [function () { t.at(t.x(1), t.midY() + 5) }, 50],
        [function () { t.at(t.x(0), t.midY() - 4) }, 50],
        [function () { t.at(t.x(2), t.midY() + 3) }, 50],
        [function () { t.at(t.x(0), t.midY() - 5) }, 50],
        [function () { t.at(t.x(1), t.midY() + 2) }, 50],
        [function () { t.at(t.x(0), t.midY()) }, 350],
        [function () { t.report("tremor.open", Popups.quickTriggerHovered); t.away() }, 1200],
        // spent: open by resting, close from elsewhere, keep resting.
        [function () { t.at(t.x(0), t.midY()) }, 450],
        [function () { t.report("spent.openBefore", Popups.quickTriggerHovered); t.rises = 0; Popups.closeAll() }, 100],
        [function () { t.report("spent.closed", Popups.quickTriggerHovered); t.at(t.x(0), t.midY() + 1) }, 900],
        [function () { t.report("spent.risesWhileParked", t.rises); t.away() }, 1200],
        [function () { t.at(t.x(0), t.midY()) }, 450],
        [function () { t.report("spent.reopenAfterReturn", Popups.quickTriggerHovered); t.away() }, 1200],
        // click: open, then close.
        [function () { tc.mouseClick(strip.contentItem, t.x(4), t.midY()) }, 150],
        [function () { t.report("click.open", Popups.quickOpen); tc.mouseClick(strip.contentItem, t.x(4), t.midY()) }, 150],
        [function () { t.report("click.closed", !Popups.quickOpen); t.away() }, 100],
        [function () { t.report("done", "yes"); Qt.quit() }, 0],
    ]
    property int i: 0
    Timer {
        id: clock
        interval: 1500        // the strip's first frame
        running: true
        onTriggered: {
            if (strip.width <= 0 || strip.height <= 0) { clock.restart(); return }
            const s = steps[i++]
            s[0]()
            clock.interval = Math.max(1, s[1])
            if (i < steps.length) clock.restart()
        }
    }
}
