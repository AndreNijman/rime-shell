import QtQuick

// ─────────────────────────────────────────────────────────────────────────────
// EdgeIntent — the pointer was put on a screen edge on purpose.
//
// A screen-edge strip that opens a panel on plain hover opens it for anyone
// passing: aiming at a window's scrollbar or close button beside the frame,
// overshooting a fast move, crossing to a second monitor (Andre, 2026-10-04:
// "it just opens when you get remotely close"). This decides when a pointer
// on the strip means it.
//
// What counts: the pointer at the very edge (within `band` of it: the visible
// frame strip, where a pointer pushed against the side of the screen stops),
// resting there for `dwell` ms. A flick that overshoots and comes back, a slide
// along the edge toward a corner, and a crossing between monitors all keep
// moving, so none of them rests.
//
//   armed     the pointer is not at the edge.
//   dwelling  at the edge; the timer runs. Leaving the band ends it (back to
//             armed). Drifting along the edge more than `tolerance` from
//             where it settled starts the wait again from the new spot, so a
//             hand that is not perfectly still still gets there, and a slide
//             along the edge never does.
//   fired     rested long enough: `active` while the pointer is on the zone.
//             It stays fired for `linger` ms after the pointer leaves the zone,
//             so crossing onto the panel and back is one visit.
//   spent     the panel was closed some other way (Escape, close-all, a click)
//             with the pointer still here. Quiet until the pointer leaves the
//             zone and the linger runs out; then armed again. Without this, a
//             pointer parked at the edge would reopen what was just closed.
//
// The strip feeds `hovered`, `edgeDistance` and `along` from its HoverHandler
// and calls `spend()` when its panel is closed from elsewhere.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: intent
    visible: false

    // ── Inputs ────────────────────────────────────────────────────────────────
    property bool hovered: false        // the pointer is over the trigger zone
    property real edgeDistance: 1e9     // its distance from the screen edge, px
    property real along: 0              // its position along the edge, px

    // ── Tuning ────────────────────────────────────────────────────────────────
    property real band: 6               // px from the edge that count as "at it"
    property int dwell: 300             // ms it has to rest there
    property real tolerance: 12         // px it may drift along the edge meanwhile
    property int linger: 400            // ms off the zone that still count as there

    // ── Output ────────────────────────────────────────────────────────────────
    readonly property bool active: intent._state === intent._fired && intent.hovered
    signal fired()

    function spend() {
        dwellTimer.stop()
        if (intent.hovered || lingerTimer.running) intent._state = intent._spent
        else intent._state = intent._armed
    }

    readonly property int _armed: 0
    readonly property int _dwelling: 1
    readonly property int _fired: 2
    readonly property int _spent: 3
    property int _state: _armed
    property real _anchor: 0

    function _update() {
        const atEdge = intent.hovered && intent.edgeDistance <= intent.band
        switch (intent._state) {
        case intent._armed:
            if (atEdge) {
                intent._anchor = intent.along
                intent._state = intent._dwelling
                dwellTimer.restart()
            }
            break
        case intent._dwelling:
            if (!atEdge) {
                dwellTimer.stop()
                intent._state = intent._armed
            } else if (Math.abs(intent.along - intent._anchor) > intent.tolerance) {
                intent._anchor = intent.along
                dwellTimer.restart()
            }
            break
        case intent._fired:
        case intent._spent:
            if (intent.hovered) lingerTimer.stop()
            else if (!lingerTimer.running) lingerTimer.restart()
            break
        }
    }
    onHoveredChanged: intent._update()
    onEdgeDistanceChanged: intent._update()
    onAlongChanged: intent._update()

    Timer {
        id: dwellTimer
        interval: intent.dwell
        onTriggered: {
            if (intent._state !== intent._dwelling) return
            intent._state = intent._fired
            intent.fired()
        }
    }
    Timer {
        id: lingerTimer
        interval: intent.linger
        onTriggered: {
            if (intent.hovered) return
            intent._state = intent._armed
        }
    }
}
