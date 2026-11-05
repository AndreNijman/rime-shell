import QtQuick
import "../theme/spring.js" as S

// ─────────────────────────────────────────────────────────────────────────────
// Spring — a damped harmonic oscillator, the physics behind fluid motion.
//
// Andre, 2026-09-26: "everything goes way too quick and doesn't feel like liquid
// and fluid, i want real apple level animation." A fixed-length bezier cannot
// give that: it has one shape whatever happened before it, and reversing it
// half-way starts a new curve from rest — the motion snaps. A spring keeps its
// velocity. Retarget it mid-flight and it bends toward the new target from
// where and how fast it already was, so an open caught by a close flows back
// instead of stopping dead; and it lands on a long, soft tail rather than a
// hard stop.
//
// Parameterised like SwiftUI: `response` is the period of the undamped
// oscillation in seconds (how quick), `dampingFraction` 1 is critical (no
// overshoot), below 1 settles with a whisper of overshoot (0.85 → ~0.6 %).
// The maths is theme/spring.js — closed form, so the motion is independent of
// the frame rate — and tests/spring-test.js holds it to the physics.
//
// Time is the frame clock (FrameAnimation.frameTime: the interval between the
// animation ticks, in ns), clamped to 50 ms a step: a stalled frame costs one
// slower step, not a teleport. It used to be Date.now(), which counts in whole
// milliseconds — up to 6 % of a 60 Hz frame of jitter in every step.
//
// `external: true` hands the clock to an owner, which calls `advance(dt)`:
// SurfaceLifecycle steps its three springs in one tick, in a known order, so
// one channel can start the instant another crosses its release level.
//
// `snap()` puts it on its target at rest (Reduce Motion, or a surface built
// already open).
// ─────────────────────────────────────────────────────────────────────────────
QtObject {
    id: spring

    property real target: 0
    property real value: 0
    property real velocity: 0
    property real response: 0.5
    property real dampingFraction: 0.86
    property real epsilon: 0.0005
    // Stepped by its owner through advance(dt), not by its own frame clock.
    property bool external: false
    readonly property bool running: spring._moving
    property bool _moving: false

    signal settled()

    function snap() {
        spring._moving = false
        velocity = 0
        value = target
    }

    // Retargeting keeps the velocity: a spring already moving just bends
    // toward the new target. One that is already at rest on it stays put — a
    // target changed and changed back in the same tick moves nothing.
    onTargetChanged: spring._moving = !S.atRest(value, velocity, target, epsilon)

    // Advance by dt seconds (closed form: exact for any dt). Settles — and says
    // so — once it is at rest on the target.
    function advance(dt) {
        if (!spring._moving) return
        if (dt > 0) {
            const r = S.step(spring.value, spring.velocity, spring.target,
                             spring.response, spring.dampingFraction, dt)
            // Velocity first: writing the value runs its listeners, and one
            // of them may snap this spring to rest (a lifecycle reaching a
            // visual zero) — a velocity written after that would leave it
            // "at rest" and still moving.
            spring.velocity = r[1]
            spring.value = r[0]
            if (!spring._moving) return
        }
        if (S.atRest(spring.value, spring.velocity, spring.target, spring.epsilon)) {
            spring._moving = false
            spring.velocity = 0
            spring.value = spring.target
            spring.settled()
        }
    }

    // When, within the next dt seconds, this spring reaches `level` (-1: not
    // in this step). See spring.js crossing().
    function crossingTime(dt, level) {
        if (!spring._moving) return -1
        return S.crossing(spring.value, spring.velocity, spring.target,
                          spring.response, spring.dampingFraction, dt, level)
    }

    // The first tick after a start carries the time since the start (Qt resets
    // the interval on every start), so motion begins on the first frame.
    property FrameAnimation _frames: FrameAnimation {
        running: spring._moving && !spring.external
        onTriggered: spring.advance(Math.min(0.05, frameTime))
    }
}
