import QtQuick
import "../"
import "controls"

// ─────────────────────────────────────────────────────────────────────────────
// SurfaceLifecycle — Closed → Opening → Open → Closing, driven by springs.
//
// Every transient surface used to keep its window mapped through its own close
// animation with a timer: `interval: Theme.animDuration + 20`. That made a
// window's lifetime a GUESS about how long its slowest animation takes, and
// every surface carried its own copy of the guess. This object is the one clock
// a surface — and the bar notch it grows out of — runs on.
//
// ── Why springs (2026-09-26) ────────────────────────────────────────────────
// Andre: "everything goes way too quick and doesn't feel liquid and fluid, i
// want real apple level animation." The body used to run 240 ms on a fixed
// curve. A curve has one shape whatever came before it: reversed half-way it
// restarted from rest and the shape stopped dead. The body is now a damped
// spring (Spring.qml). A reversal carries the velocity it had into the new
// direction, so the shape bends back; and it lands on a long soft tail.
//
// ── Outputs ─────────────────────────────────────────────────────────────────
//   progress   0..1, SPATIAL: the body channel, clamped. Geometry that is a
//              function of one value reads it. Under Reduce Motion it jumps
//              (its durations are spatial tokens): to 1 on open, and to 0 on
//              close only once `alpha` has faded — the surface leaves as its
//              finished shape, not as its progress-0 geometry.
//   lead, body, trail
//              the three LIQUID channels (only distinct with `liquid: true`;
//              otherwise all three are the body). Raw spring values: with a
//              damping below 1 they pass 1 by a hair before settling, and the
//              geometry soft-caps that into a visible swell of a few pixels.
//                lead   moves first on the way in (a bloom's width, a pour's
//                       depth) and leaves LAST — it is the part touching the bar.
//                body   follows once the lead has crossed `openRelease`; on the
//                       way out it leaves first, and the lead follows once the
//                       body is below `closeRelease`.
//                trail  a critically damped follower of the body: radii,
//                       shoulders, fillets. It lags a few frames and settles
//                       last, which is what reads as liquid rather than rubber.
//   velocity, leadVelocity, bodyFlow, leadFlow
//              the body's and the lead's speed: in 1/s, and as FLOW, relative
//              to a nominal open's peak (about 1 at the fastest, 0 at rest) —
//              for secondary motion proportional to speed (a bowing edge).
//   content    0..1, the content inside the surface. It arrives once the body
//              has substance (`contentAt`) and leaves ahead of it, on effect
//              tokens, so it survives Reduce Motion as a short fade.
//   alpha      0..1, EFFECT. The surface's own opacity for the case where there
//              is no spatial motion to show it arriving: 1 while spatial motion
//              is on, a short fade under Reduce Motion.
//   mapped     the window must exist. True from the moment `open` goes true
//              until every value above has actually reached 0 — completion, not
//              a timer — so the unmap can never cut an animation short.
//   phase      Closed | Opening | Open | Closing. "Open" is PERCEPTUAL: the lead
//              and the body have both crossed 98 %. A spring's last fraction of
//              a pixel takes as long again as the rest, and pages that start
//              their services on Open must not wait for it. A close releases
//              the window at a visual zero (0.4 %, sub-pixel) the same way.
//
// ── The first frame ─────────────────────────────────────────────────────────
// Mapping a window takes a while — Quickshell builds a new backing window on
// every map, and the compositor needs a commit — 50 to 150 ms on the L16. A
// clock that started when `open` flipped had the body a third grown before its
// first frame reached the screen: the notch did not grow, a big shape simply
// appeared (Andre, 2026-09-26: "the middle notch fades away and a big rectangle
// appears"). Give the lifecycle `surface` — any item in the surface's window —
// and the springs hold at 0, where the body IS the notch, until that window
// has swapped a frame since it mapped. Every open starts from the notch.
//
// Usage:
//     SurfaceLifecycle { id: life; open: Popups.networkOpen; surface: body }
//     PanelWindow { visible: life.mapped; … }
//
// ── The kept window (2026-11-03) ────────────────────────────────────────────
// Most of that wait is the window itself: Quickshell destroys a layer window
// the moment it is hidden and builds a new one (and its scene graph) on the
// next show. With `keepWindow: true` the window outlives its first close:
// instead of hiding, it PARKS — shrunk to 1x1, input region empty, keyboard
// focus none — and stops rendering once that 1x1 frame is on screen
// (`windowUpdates`), so a parked window costs no frames, no wakeups and no
// compositor work. The next open only resizes it. A window parks only while
// `parkable` (a surface binds it to "no fullscreen window covers this output",
// so a parked overlay never sits over a game); otherwise it hides as before.
//     PanelWindow {
//         visible: life.windowVisible; updatesEnabled: life.windowUpdates
//         anchors.left: !life.parked  …  implicitWidth: 1; implicitHeight: 1
//     }
// A window that is opening waits for a frame at its real size: the parked
// window's own frames do not count.
//
// It observes `open` from construction, so a popup that a LazyPopup builds BY
// its flag flipping true starts opening on its own; it needs no applyOpenState.
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: life

    // ── Input ────────────────────────────────────────────────────────────────
    property bool open: false
    // Names the surface in the frame-pacing log (Motion.pacingLog, Phase 22).
    property string name: ""
    // An item in the surface's window: the springs wait for its first frame.
    property Item surface: null

    // ── Timing (Motion roles; override per surface family) ───────────────────
    // The body spring's response, in ms: about when the change looks finished.
    // 0 is "no spatial motion" (Reduce Motion, or motion off) and snaps.
    property int enterDuration: Motion.morphEnter
    property int exitDuration:  Motion.morphExit
    // Damping fractions. 1 lands without overshoot. `progress` is clamped, so
    // a non-liquid surface keeps 1 (an overshoot would read as a flat spot).
    property real enterDamping: 1.0
    property real exitDamping:  1.0

    // ── Liquid channels (opt-in) ─────────────────────────────────────────────
    // Responses are fractions of enterDuration / exitDuration, so the speed
    // setting and Reduce Motion (0) reach them with no extra wiring.
    property bool liquid: false
    property real leadIn:    0.72     // × enterDuration
    property real bodyIn:    0.92
    property real leadOut:   0.70     // × exitDuration
    property real bodyOut:   0.80
    property real trailScale: 0.80    // × whichever duration applies
    property real leadDamping: 0.84   // opening; closing is always critical
    property real bodyDamping: 0.80
    property real openRelease:  0.12  // the body starts once the lead is here
    property real closeRelease: 0.35  // the lead leaves once the body is here

    // Content choreography. With spatial motion and a delay, the content starts
    // once the body is `contentAt` open — it arrives when there is something
    // to arrive in, however long the window took to show. `contentDelay` 0
    // means "with the body" (menus, dialogs). Under Reduce Motion there is no
    // body motion to wait for and most of the fade goes too.
    property int contentDelay:   Motion.contentDelay
    property real contentAt:     0.30
    property int contentIn:      Motion.reduced ? Motion.hover : Motion.fadeIn
    property int contentOut:     Motion.fadeOut
    // The curve content LEAVES on. The effects ease by default; a surface
    // whose body starts changing shape at once can leave on standardDecel, a
    // soft start that still drops most of the way early, so detailed content
    // is gone before the silhouette is (the Nexus).
    property var contentOutCurve: Motion.effects

    // A content or alpha fade reversed part-way takes the share of its full
    // duration that is left to travel, with a floor. (The body needs no such
    // rule: the springs' velocity is the continuity.)
    property real minFraction: 0.35

    // ── Output ───────────────────────────────────────────────────────────────
    // All of these change together, ONCE per frame: the springs are stepped
    // in one tick and published as one snapshot (`frame`). A binding that
    // reads several of them — a silhouette's channels — used to re-run for
    // every spring write, six times a frame, each time rebuilding and parsing
    // the whole path. Bind to `frame` to run once.
    readonly property real progress: Math.max(0, Math.min(1, life._f.body))
    readonly property real body:  life._f.body
    readonly property real lead:  life._f.lead
    readonly property real trail: life._f.trail
    readonly property real velocity:     life._f.velocity
    readonly property real leadVelocity: life._f.leadVelocity
    // FLOW: speed relative to the peak of a nominal open — a critically damped
    // spring from rest peaks at 2π/(e·response) ≈ 2.3/response — so about 1 at
    // the fastest and exactly 0 at rest. geometry.js bends edges by it.
    readonly property real bodyFlow: life._f.bodyFlow
    readonly property real leadFlow: life._f.leadFlow
    // The snapshot itself: { progress, body, lead, trail, velocity,
    // leadVelocity, bodyFlow, leadFlow }. A new object only when a value moved.
    readonly property var frame: life._f
    property real content:  0
    property real alpha:    0

    readonly property bool mapped: life.open || life._settling
                                   || life.progress > 0 || life.content > 0 || life.alpha > 0
                                   || (life.liquid && (life._f.lead > 0 || life._f.trail > 0))

    readonly property string phase: {
        if (!life.mapped) return "Closed"
        if (life.open) return life._arrived ? "Open" : "Opening"
        return "Closing"
    }

    // True from a close starting until it has finished (or been reversed).
    // For a binding that must react to the direction: reading `open` from a
    // binding that also reads `alpha` is a binding loop — evaluating `open`
    // there runs _drive(), which writes `alpha` (measured on the spills'
    // opacity). This reads a plain flag that _drive() sets, with no effects.
    readonly property bool closing: life._settling

    // ── Kept window (see the header) ─────────────────────────────────────────
    property bool keepWindow: false
    property bool parkable: true
    // Whether the window should exist: shown, or parked.
    readonly property bool windowVisible: life.mapped
        || (life.keepWindow && life.parkable && life._everOpened)
    // Shown but closed: 1x1, no input, no focus.
    readonly property bool parked: life.windowVisible && !life.mapped
    // False once a parked window has presented its 1x1 frame.
    readonly property bool windowUpdates: !life.parked || !life._parkFlushed
    // The window has its real size: a kept window opening renders at 1x1
    // until the compositor's configure arrives (its state is sent with a frame).
    readonly property bool windowSized: !life.keepWindow || (life._win !== null && life._win.width > 2)
    // A kept window's content is hidden while parked or unsized, as a hidden
    // window's was (Quickshell orphans the content of a window it destroys,
    // and an orphaned item is not visible). So neither its 1x1 frames nor the
    // one it parks with can show a pixel of a surface, and what runs only
    // while visible (a loading pulse) stops while it is parked: a running
    // animation anywhere ticks the whole shell's animation timer.
    // The item hidden is the surface's top item under the window's root (a
    // Quickshell window's own contentItem), never the root itself: the root
    // has no parent item, so once its `visible` is written it computes as
    // hidden for good, whatever is written next.
    readonly property Item _veiled: {
        const root = life._win ? life._win.contentItem : null
        let it = root ? life.surface : null
        while (it && it.parent && it.parent !== root) it = it.parent
        return it && it.parent === root ? it : null
    }
    property Binding _veil: Binding {
        when: life.keepWindow && life._veiled !== null
        target: life._veiled
        property: "visible"
        value: !life.parked && life.windowSized
    }

    signal opened()
    signal closed()

    // ── Internals ────────────────────────────────────────────────────────────
    // True between a close starting and every animation finishing. `mapped`
    // cannot be derived from the values alone: a close begins from progress 1
    // and there is one frame before the springs move it.
    property bool _settling: false
    property bool _announced: false
    // Open: perceptually there (see `phase`). Set by _onStep, never by a timer.
    property bool _arrived: false
    // The content fade is waiting for the body to reach `contentAt`.
    property bool _contentPending: false

    // ── Springs ──────────────────────────────────────────────────────────────
    // Stepped together by `_clock`, once a frame, on the frame clock.
    property Spring _body:  Spring { epsilon: 0.0005; external: true }
    property Spring _lead:  Spring { epsilon: 0.0005; external: true }
    // A follower: its target is wherever the body is right now (set each tick).
    property Spring _trail: Spring { epsilon: 0.0005; external: true; dampingFraction: 1.0 }
    function _anyRunning() {
        return life._body.running || (life.liquid && (life._lead.running || life._trail.running))
    }
    function _snapAll(to) {
        life._body.target = to; life._body.snap()
        life._lead.target = to; life._lead.snap()
        life._trail.target = life.liquid ? life._body.value : 0
        life._trail.snap()
        life._publish()
    }

    property var _f: ({ progress: 0, body: 0, lead: 0, trail: 0, velocity: 0,
                        leadVelocity: 0, bodyFlow: 0, leadFlow: 0 })
    function _publish() {
        const B = life._body, L = life.liquid ? life._lead : life._body
        const T = life.liquid ? life._trail : life._body
        const f = life._f
        if (f.body === B.value && f.lead === L.value && f.trail === T.value
                && f.velocity === B.velocity && f.leadVelocity === L.velocity)
            return
        const bodyFlow = B.response > 0 ? B.velocity * B.response / 2.3 : 0
        life._f = {
            progress: Math.max(0, Math.min(1, B.value)),
            body: B.value, lead: L.value, trail: T.value,
            velocity: B.velocity, leadVelocity: L.velocity,
            bodyFlow: bodyFlow,
            leadFlow: !life.liquid ? bodyFlow
                      : L.response > 0 ? L.velocity * L.response / 2.3 : 0
        }
    }

    // ── The clock ────────────────────────────────────────────────────────────
    // One tick a frame steps every spring, in order, then publishes. A channel
    // released by another (the body once the lead crosses `openRelease`, the
    // lead once the body falls below `closeRelease`) starts at the INSTANT of
    // the crossing, found on the closed form, not at the next frame: checked
    // once a frame, the release lagged up to a whole frame — at the lead's
    // fastest, ~40 px of a Dashboard at 60 Hz.
    property FrameAnimation _clock: FrameAnimation {
        running: life._anyRunning()
        // The first tick after a start carries the time since the start.
        onTriggered: life._tick(Math.min(0.05, frameTime))
    }
    function _tick(dt) {
        const B = life._body, L = life._lead, T = life._trail
        let done = false
        if (life.liquid && life._ready && dt > 0
                && (life.open ? life.enterDuration : life.exitDuration) > 0) {
            if (life.open && B.target < 1) {
                const tc = L.crossingTime(dt, life.openRelease)
                if (tc >= 0) {
                    L.advance(dt)
                    B.advance(tc); B.target = 1; B.advance(dt - tc)
                    done = true
                }
            } else if (!life.open && L.target > 0) {
                const tc = B.crossingTime(dt, life.closeRelease)
                if (tc >= 0) {
                    B.advance(dt)
                    L.advance(tc); L.target = 0; L.advance(dt - tc)
                    done = true
                }
            }
        }
        if (!done) {
            if (life.liquid) L.advance(dt)
            B.advance(dt)
        }
        if (life.liquid) {
            T.target = B.value
            T.advance(dt)
        }
        life._publish()
        life._onStep()
        life._check()
    }

    // ── The first frame ──────────────────────────────────────────────────────
    readonly property var _win: life.surface ? life.surface.Window.window : null
    property bool _presented: false
    // A new backing window (Quickshell builds one per map, unless it is kept)
    // has shown nothing. Counted, for tests/run-kept-window-test.sh.
    property int _windows: 0
    on_WinChanged: {
        life._presented = false
        if (!life._win) return
        life._windows++
        if (Motion.pacingLog) console.info("Rime pacing: " + (life.name || "surface") + " window=" + life._windows)
    }
    onMappedChanged: {
        if (!life.mapped) life._presented = false
        else life._everOpened = true   // see _everOpened
        // For tests/visual/stress-matrix.sh: every map and unmap, by name.
        if (Motion.pacingLog)
            console.info("Rime pacing: " + (life.name || "surface") + " mapped=" + life.mapped)
    }
    property Connections _firstFrame: Connections {
        target: (life.surface && !life._presented) ? life._win : null
        ignoreUnknownSignals: true
        function onFrameSwapped() {
            // A kept window's parked frames, or one presented before the
            // compositor has given it its real size, are not this open's.
            // (A swap queued before the first one disconnected this is late.)
            if (life._presented) return
            if (!life.windowSized || (life.keepWindow && !life.mapped)) return
            if (Motion.pacingLog && life.open)
                console.info("Rime pacing: " + (life.name || "surface") + " first-frame ms="
                             + (Date.now() - life._openedAt))
            life._presented = true
        }
    }
    // Pacing only: frames this window presented during an open or a close, and
    // the first one presented after a spring left 0 — the open's first VISIBLE
    // motion, so `motion` is the input-to-motion latency (UI/UX Phase 22).
    property real _motionAt: 0
    property Connections _paceSwaps: Connections {
        target: (Motion.pacingLog && life.surface) ? life._win : null
        ignoreUnknownSignals: true
        function onFrameSwapped() {
            const now = Date.now()
            if (life.phase === "Opening" || life.phase === "Closing") life._pace.swaps++
            else if (life.phase === "Closed")
                console.info("Rime pacing: " + (life.name || "surface") + " swap-closed")
            if (life.open && life._motionAt > 0 && life._pace.motion < 0)
                life._pace.motion = now - life._openedAt
        }
    }
    property real _openedAt: 0
    // Set in onMappedChanged once `mapped` is true, never from onOpenChanged: a handler there runs
    // before `mapped` has re-evaluated, so windowVisible would see the window
    // as parked and create it parked (1x1, no keyboard focus). With no
    // exclusive layer for that frame, labwc hands focus to a toplevel, and the
    // focus move closes the popup being opened.
    property bool _everOpened: false
    property bool _parkFlushed: false
    // A parked window keeps its active focus item, and a focused text field
    // keeps blinking its cursor: two wakeups a second for as long as it is
    // parked (measured on the wallpaper picker's search field). Parking takes
    // the focus off it, and the next open gives it back unless the opening
    // surface has already focused something itself.
    property Item _parkedFocus: null
    onParkedChanged: {
        const win = life._win
        if (life.parked) {
            const f = win ? win.activeFocusItem : null
            if (f && f !== win.contentItem) { life._parkedFocus = f; f.focus = false }
            return
        }
        life._parkFlushed = false
        const f = life._parkedFocus
        life._parkedFocus = null
        if (f && win && (!win.activeFocusItem || win.activeFocusItem === win.contentItem))
            f.forceActiveFocus()
    }
    property Connections _parkSwaps: Connections {
        target: (life.surface && life.parked && !life._parkFlushed) ? life._win : null
        ignoreUnknownSignals: true
        function onFrameSwapped() { if (life._win.width <= 2) life._parkFlushed = true }
    }
    readonly property bool _ready: !life.surface || life._presented
    on_ReadyChanged: if (life._ready && life.open) life._drive()
    // Never hold longer than this for a window that does not report frames.
    property Timer _presentGuard: Timer {
        interval: 250
        onTriggered: if (life.open && !life._presented) life._presented = true
    }

    // Perceptual thresholds, checked on every step.
    readonly property real _nearOpen:   0.98
    readonly property real _nearClosed: 0.004
    readonly property real _still:      0.35
    function _atOpen() {
        return life._body.value >= life._nearOpen
               && (!life.liquid || life._lead.value >= life._nearOpen)
    }
    function _atClosed() {
        function low(sp) { return sp.value <= life._nearClosed && Math.abs(sp.velocity) < life._still }
        return low(life._body) && (!life.liquid || (low(life._lead) && low(life._trail)))
    }

    function _onStep() {
        if (Motion.pacingLog && life.open && life._motionAt === 0
                && (life._lead.value > 0 || life._body.value > 0))
            life._motionAt = Date.now()
        var spatial = (life.open ? life.enterDuration : life.exitDuration) > 0
        if (life.liquid && spatial && life._ready) {
            // Sequencing, evaluated both ways so a reversal resumes it.
            if (life.open && life._body.target < 1 && life._lead.value >= life.openRelease)
                life._body.target = 1
            if (!life.open && life._lead.target > 0 && life._body.value <= life.closeRelease)
                life._lead.target = 0
        }
        if (life.open) {
            if (life._contentPending && life._ready && life.progress >= life.contentAt) life._startContent()
            if (!life._arrived && life._atOpen()) {
                life._arrived = true
                life._check()
            }
        } else if (life._settling && life._anyRunning() && life._atClosed()) {
            life._snapAll(0)
            life._check()
        }
    }

    // ── Frame pacing (UI/UX Phase 22) ─────────────────────────────────────────
    // Frames DELIVERED during an open or a close, not what each cost to render:
    // a FrameAnimation ticks once per frame the animation driver advances, so
    // its count against the wall-clock duration is the miss count, and the
    // longest gap between ticks is the worst hitch. Logged when the phase ends:
    //     Rime pacing: <name> <Opening|Closing> ms=<n> frames=<n> worst=<ms>
    //                  at=<where the worst gap ended, 0..1 of the phase> first=<ms>
    // `first` is the wait for the first frame after the phase began: a surface
    // that builds its content or starts a process as it opens pays it there.
    // Only while Motion.pacingLog: with it off, this never runs.
    property FrameAnimation _pace: FrameAnimation {
        running: Motion.pacingLog && (life.phase === "Opening" || life.phase === "Closing")
        property real t0: 0
        property real last: 0
        property int n: 0
        property real worst: 0
        property real worstT: 0
        property real first: -1
        property string ph: ""
        property int swaps: 0
        property real motion: -1
        property var iv: []
        onRunningChanged: {
            if (running) {
                t0 = Date.now(); last = t0; n = 0; worst = 0; worstT = t0; first = -1; ph = life.phase
                swaps = 0; iv = []
                if (ph === "Opening") { motion = -1; life._motionAt = 0 }
            } else if (n > 0) {
                const span = Math.max(1, last - t0)
                console.info("Rime pacing: " + (life.name || "surface") + " " + ph
                             + " ms=" + Math.round(last - t0) + " frames=" + n
                             + " worst=" + Math.round(worst)
                             + " at=" + ((worstT - t0) / span).toFixed(2)
                             + " first=" + Math.round(first)
                             + " swaps=" + swaps
                             + (ph === "Opening" ? " motion=" + Math.round(motion) : "")
                             + " iv=" + iv.join(","))
            }
        }
        onTriggered: {
            const now = Date.now()
            if (n > 0) iv.push((frameTime * 1000).toFixed(1))
            if (first < 0) first = now - t0
            if (now - last > worst) { worst = now - last; worstT = now }
            last = now
            n++
        }
    }

    property SequentialAnimation _cAnim: SequentialAnimation {
        PauseAnimation   { id: cDelay }   // duration set before every start
        NumberAnimation  {
            id: cMove
            target: life; property: "content"
            easing.type: Easing.BezierSpline
            easing.bezierCurve: Motion.effects
        }
        onFinished: life._check()
    }
    property NumberAnimation _aAnim: NumberAnimation {
        target: life; property: "alpha"
        easing.type: Easing.BezierSpline
        easing.bezierCurve: Motion.effects
        onFinished: life._check()
    }

    function _dur(full, from, to) {
        var dist = Math.abs(to - from)
        if (full <= 0 || dist <= 0) return 0
        return Math.round(full * Math.max(life.minFraction, dist))
    }

    function _run(anim, from, to, ms) {
        anim.stop()
        if (ms <= 0 || from === to) {
            anim.target[anim.property] = to
            return false
        }
        anim.from = from
        anim.to = to
        anim.duration = ms
        anim.start()
        return true
    }

    // The content fade toward the current direction, from wherever it is.
    function _startContent() {
        life._contentPending = false
        life._cAnim.stop()
        var to = life.open ? 1 : 0
        var cFrom = life.content
        if (cFrom === to) { life.content = to; return }
        cDelay.duration = 0
        cMove.from = cFrom
        cMove.to = to
        cMove.easing.bezierCurve = life.open ? Motion.effects : life.contentOutCurve
        cMove.duration = life._dur(life.open ? life.contentIn : life.contentOut, cFrom, to)
        if (cMove.duration <= 0) life.content = to
        else life._cAnim.start()
    }

    function _retarget() {
        var L = life._lead, B = life._body
        if (life.open) {
            if (life.liquid) {
                L.target = 1
                if (L.value >= life.openRelease) B.target = 1
            } else {
                B.target = 1
            }
        } else {
            B.target = 0
            if (life.liquid && B.value <= life.closeRelease) L.target = 0
        }
    }

    function _drive() {
        var to = life.open ? 1 : 0
        // A close and a reopen in the same tick — `closeAll()` followed by the
        // next surface's flag, with one lifecycle shared by both — must be a
        // no-op, not a close that is still "settling" underneath an open one.
        life._settling = !life.open
        life._announced = false
        var spatial = (life.open ? life.enterDuration : life.exitDuration) > 0

        // Spring parameters for this direction, applied at the retarget: the
        // closed form carries position and velocity across, so it is continuous.
        var dur = (life.open ? life.enterDuration : life.exitDuration) / 1000
        var B = life._body, L = life._lead
        if (life.open) {
            B.response = dur * (life.liquid ? life.bodyIn : 1)
            B.dampingFraction = life.liquid ? life.bodyDamping : life.enterDamping
            L.response = dur * life.leadIn
            L.dampingFraction = life.leadDamping
        } else {
            B.response = dur * (life.liquid ? life.bodyOut : 1)
            B.dampingFraction = life.exitDamping
            L.response = dur * life.leadOut
            L.dampingFraction = life.exitDamping
        }
        life._trail.response = dur * life.trailScale

        // Body. With no spatial motion a close HOLDS the shape: it fades out
        // whole and drops to 0 in _check once alpha has gone (brief B.10:
        // "exits opacity … then unmap"). With it, the springs are retargeted
        // from wherever they are, at whatever speed they have — once the
        // window has a frame on screen.
        if (!spatial) {
            if (life.open) life._snapAll(1)
        } else if (life.open && !life._ready) {
            life._presentGuard.restart()
        } else {
            life._retarget()
        }
        // Perceptually there already (a close and a reopen in one tick): Open
        // stays Open. Otherwise arrival is _onStep's to decide.
        life._arrived = life.open && life._atOpen()

        // Surface opacity. While spatial motion is on, the body is opaque for
        // its whole life — it arrives and leaves by changing shape, and closed()
        // drops alpha only once it has finished. With no spatial motion (Reduce
        // Motion) the shape is simply there, and a short fade is how it arrives.
        if (spatial) {
            life._aAnim.stop()
            life.alpha = 1
        } else {
            life._run(life._aAnim, life.alpha, to,
                      life._dur(life.open ? life.contentIn : life.contentOut, life.alpha, to))
        }

        // Content: on the way in it waits for the window's first frame and, if
        // the surface asked for a delay, for the body to have substance; on the
        // way out it leaves at once, quicker.
        life._cAnim.stop()
        life._contentPending = false
        if (life.open && life.content < 1
                && (!life._ready || (spatial && life.contentDelay > 0 && life.progress < life.contentAt)))
            life._contentPending = true
        else
            life._startContent()
        life._check()
    }

    function _check() {
        // An open is done when the body has ARRIVED (perceptually) and the
        // effects have finished; the springs may still be settling their last
        // fraction of a pixel. A close waits for every spring to stop.
        var busy = life._cAnim.running || life._aAnim.running || life._contentPending
                   || (!life.open && life._anyRunning())
        if (busy) return
        if (life.open) {
            if (life._arrived && !life._announced) {
                life._announced = true
                life.opened()
            }
            return
        }
        // Closing and nothing left moving: make sure every value is at rest,
        // then release the window.
        if (life._settling) {
            // A shape held through a Reduce Motion fade goes once it is unseen.
            if (life.progress > 0 && life.alpha <= 0 && life.exitDuration <= 0)
                life._snapAll(0)
            if (life.progress <= 0 && life.content <= 0
                    && (!life.liquid || (life._lead.value <= 0 && life._trail.value <= 0))) {
                life.alpha = 0
                life._settling = false
                life.closed()
            }
        }
    }

    // Opening a surface hides focus rings until the keyboard is used again:
    // whatever focus a surface sets on its way in is its own doing, not the
    // user's (InputModality). Off for what arrives unasked and takes no focus
    // (a toast, the OSD), so it cannot hide a keyboard user's ring elsewhere.
    property bool resetsFocusRing: true

    onOpenChanged: {
        if (life.open) {
            life._openedAt = Date.now()
            if (life.resetsFocusRing) InputModality.surfaceOpened()
        }
        life._drive()
    }
    Component.onCompleted: if (life.open) { life._openedAt = Date.now(); life._everOpened = true; life._drive() }
}
