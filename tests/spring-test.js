#!/usr/bin/env node
// ─── spring-test.js ──────────────────────────────────────────────────────────
// src/theme/spring.js — the closed-form damped spring behind Spring.qml — held
// to the physics it claims. Run by CI's "The motion system" step.
const path = require("path");
const S = require(path.join(__dirname, "..", "src", "theme", "spring.js"));

let pass = 0, fail = 0;
function check(name, cond, detail) {
    if (cond) { pass++; console.log("  ok   " + name); }
    else { fail++; console.log("  FAIL " + name + (detail !== undefined ? "  [" + detail + "]" : "")); }
}
function run(response, z, from, target, dt, seconds) {
    let x = from, v = 0, peak = from, t = 0;
    const trace = [];
    while (t < seconds) {
        const r = S.step(x, v, target, response, z, dt); x = r[0]; v = r[1]; t += dt;
        peak = target >= from ? Math.max(peak, x) : Math.min(peak, x);
        trace.push(x);
    }
    return { x, v, peak, trace };
}

// It arrives, and stays.
for (const z of [0.7, 0.86, 1.0, 1.3]) {
    const r = run(0.5, z, 0, 1, 1 / 60, 3);
    check(`ζ=${z}: at rest on the target after 3 s`, S.atRest(r.x, r.v, 1, 0.0005), r.x.toFixed(6) + " v=" + r.v.toFixed(6));
}
// Overshoot matches theory: e^{-πζ/√(1-ζ²)}.
{
    const z = 0.86, r = run(0.5, z, 0, 1, 1 / 1000, 2);
    const theory = Math.exp(-Math.PI * z / Math.sqrt(1 - z * z));
    check("ζ=0.86 overshoots by the theoretical amount (~0.5 %)", Math.abs((r.peak - 1) - theory) < 2e-4,
          (100 * (r.peak - 1)).toFixed(3) + "% vs " + (100 * theory).toFixed(3) + "%");
}
check("critical damping never overshoots", run(0.5, 1.0, 0, 1, 1 / 1000, 2).peak <= 1 + 1e-9);
check("overdamped never overshoots", run(0.5, 1.4, 0, 1, 1 / 1000, 2).peak <= 1 + 1e-9);
// Frame-rate independence: sixty 1/60 s steps land where one 1 s step does.
for (const z of [0.86, 1.0, 1.3]) {
    let x = 0, v = 0;
    for (let i = 0; i < 60; i++) { const r = S.step(x, v, 1, 0.5, z, 1 / 60); x = r[0]; v = r[1]; }
    const one = S.step(0, 0, 1, 0.5, z, 1);
    check(`ζ=${z}: 60 steps of 1/60 s = one step of 1 s`, Math.abs(x - one[0]) < 1e-9 && Math.abs(v - one[1]) < 1e-9,
          x + " vs " + one[0]);
}
// Retargeting keeps velocity: turn around at 40 % and the first step back still
// moves forward (it bends, it does not snap).
{
    let x = 0, v = 0;
    while (x < 0.4) { const r = S.step(x, v, 1, 0.5, 0.86, 1 / 120); x = r[0]; v = r[1]; }
    const before = v;
    const r = S.step(x, v, 0, 0.5, 0.86, 1 / 120);
    check("a reversal keeps the velocity it had (the first step back still moves on)",
          before > 0 && r[0] > x, "v=" + before.toFixed(3) + " x " + x.toFixed(4) + "→" + r[0].toFixed(4));
}
// `response` is how quick: a longer response takes longer to settle.
{
    const a = S.settleTime(0.35, 1, 0, 1, 0.001), b = S.settleTime(0.55, 1, 0, 1, 0.001);
    check("a longer response settles later", b > a, a.toFixed(3) + " < " + b.toFixed(3));
}
// Continuity: no step jumps (the value moves at most velocity × dt + a margin).
{
    const r = run(0.5, 0.86, 0, 1, 1 / 60, 2);
    let worst = 0;
    for (let i = 1; i < r.trace.length; i++) worst = Math.max(worst, Math.abs(r.trace[i] - r.trace[i - 1]));
    check("no frame moves more than 12 % of the travel at 60 Hz (response 0.5)", worst < 0.12, (100 * worst).toFixed(2) + "%");
}

// (Qt's SpringAnimation was measured to be a fixed 16 ms integrator,
// v += k·(to − x) − c·v; x += 0.016·v, and an exact mapping onto it lived here
// with MotionSpring. Both are gone: at 16 ms a step it updated at ~62 Hz on a
// 144 Hz panel. SpringFollower steps this closed form per frame instead.)

// crossing(): the instant a step reaches a level, for a channel released by
// another (SurfaceLifecycle's openRelease / closeRelease).
{
    const dt = 1 / 60;
    // A lead from rest at 0 toward 1: find the frame where it crosses 0.12.
    let x = 0, v = 0, t = 0, found = false;
    for (let i = 0; i < 120 && !found; i++) {
        const tc = S.crossing(x, v, 1, 0.3, 0.84, dt, 0.12);
        const r = S.step(x, v, 1, 0.3, 0.84, dt);
        if (tc >= 0) {
            found = true;
            const at = S.step(x, v, 1, 0.3, 0.84, tc)[0];
            check("crossing: the value at the returned instant is the level", Math.abs(at - 0.12) < 1e-6, at);
            check("crossing: inside the step", tc > 0 && tc <= dt, tc);
            check("crossing: the step starts below and ends at or above the level", x < 0.12 && r[0] >= 0.12, x + " -> " + r[0]);
        } else {
            check("crossing: -1 on a step that stays below (frame " + i + ")", r[0] < 0.12 || x >= 0.12, r[0]);
        }
        x = r[0]; v = r[1]; t += dt;
    }
    check("crossing: found on the way up", found);
    // Downward: a body from 1 toward 0 crosses 0.35.
    let y = 1, w = 0, down = -1;
    for (let i = 0; i < 120 && down < 0; i++) {
        const tc = S.crossing(y, w, 0, 0.25, 1.0, dt, 0.35);
        if (tc >= 0) { down = tc; check("crossing: downward value at the instant", Math.abs(S.step(y, w, 0, 0.25, 1.0, tc)[0] - 0.35) < 1e-6); }
        const r = S.step(y, w, 0, 0.25, 1.0, dt); y = r[0]; w = r[1];
    }
    check("crossing: found on the way down", down > 0, down);
    check("crossing: no step, no crossing", S.crossing(0, 0, 1, 0.3, 1, 0, 0.12) === -1);
    check("crossing: already moving away from the level", S.crossing(0.5, 2, 1, 0.3, 1, dt, 0.12) === -1);
}

console.log("\nspring: passed=" + pass + " failed=" + fail);
process.exit(fail === 0 ? 0 : 1);
