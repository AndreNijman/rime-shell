// ─── scaling.js ──────────────────────────────────────────────────────────────
// The shell's size arithmetic, in one place, testable from node.
//
// It lived in theme/Metrics.qml, where nothing could reach it except a running
// quickshell — and tests/scaling-test.qml therefore RE-IMPLEMENTED the
// breakpoint table as its own `bucket()` function and asserted the copy against
// itself. Every breakpoint assertion passed no matter what Metrics said. This
// module exists so that the shell and the test read the same function.
//
// Two questions live here and they are not the same question:
//
//   scaleForHeight(h)     given a LOGICAL height, how much does the shell
//                         magnify its own tokens
//   recommendedScale(w,h) given a PHYSICAL mode, what compositor scale puts
//                         that output into the band the shell was calibrated
//                         for in the first place
// ─────────────────────────────────────────────────────────────────────────────

// ── The shell's own factor ──────────────────────────────────────────────────
//
// Sublinear in resolution: a 4K panel is usually also physically larger, so a
// literal 2x would be enormous. Fixed breakpoints rather than a continuous
// height/1080 ratio, because a continuous factor produces awkward fractional
// pixel values and shifts the whole UI on any mode change.
//
// The input is the LOGICAL height — what Wayland hands the client after the
// compositor's own output scale. That is deliberate: an output at compositor
// scale 2 reports half its pixels, lands in a lower bucket, and the two
// magnifications multiply out to the right physical size. Measured on
// quickshell 0.3.1 / Qt 6.10: a 3840x2160 output at compositor scale 2 arrives
// as 1920x1080 with devicePixelRatio 2.
//
// [maximum logical height (exclusive), factor]
var BREAKPOINTS = [
    [900,  0.85],   // 1366x768 and friends
    [1250, 1.00],   // 1080p and 1200p — the calibrated baseline
    [1600, 1.20],   // 1440p
    [2000, 1.35]    // 1600p / 1800p
]
var TOP_SCALE = 1.50   // 2160p and up

// The band the token set was calibrated against. An output whose logical height
// lands in here needs no shell magnification at all, which is why it is also
// the target recommendedScale() aims for.
var BASELINE_MIN = 1000
var BASELINE_MAX = 1250

function scaleForHeight(h) {
    for (var i = 0; i < BREAKPOINTS.length; i++)
        if (h < BREAKPOINTS[i][0]) return BREAKPOINTS[i][1]
    return TOP_SCALE
}

// ── The compositor's factor ─────────────────────────────────────────────────
//
// INTEGERS ONLY, and that is a measurement rather than a preference.
//
// Qt does not render at a fractional device pixel ratio here. Asked for output
// scale 1.5 on a 3840x2160 panel, the compositor reported a 2560x1440 logical
// size and Qt took devicePixelRatio 2 — so the shell drew a 2x buffer and the
// compositor downsampled it to 1.5x. Text goes through a resample. Measured at
// 1.25, 1.5 and 1.6; all three came back with devicePixelRatio 2. At scale 2
// the logical size was 1920x1080 and devicePixelRatio was 2, which is the same
// number the client drew at: no resample.
//
// A non-integer scale is also the one thing Hyprland refuses outright when it
// cannot resolve to a whole buffer size, and it errors the whole monitor rule
// rather than falling back.
var CANDIDATES = [1, 2, 3]

/// The compositor scale that brings a mode into the calibrated band.
///
/// The largest candidate that divides the mode evenly and still leaves at least
/// BASELINE_MIN logical rows — largest, because that is the one that puts the
/// most physical pixels behind each logical one, and "at least", because an
/// output that lands under the band gets a UI that is too small to read rather
/// than merely too large.
function recommendedScale(w, h) {
    var best = 1
    for (var i = 0; i < CANDIDATES.length; i++) {
        var s = CANDIDATES[i]
        if (w % s !== 0 || h % s !== 0) continue
        if (h / s < BASELINE_MIN) continue
        if (s > best) best = s
    }
    return best
}

// ── What an output can actually hold ────────────────────────────────────────
//
// A factor is only usable if the surfaces drawn at it still fit the output. The
// Dashboard is the binding one: it is DASH_W wide BETWEEN the two side notches,
// whose caps scale with the factor too, so its room is
//     width - 2 * (NOTCH_CAP + NOTCH_PAD) * f      against      DASH_W * f
// and on a 1920-wide output that stops holding at about 1.15. Past it
// DashboardLayout yields and the panel shrinks while everything INSIDE it keeps
// growing, so the clock, calendar and tiles draw over each other (measured at
// 1.5, 2.0 and 3.0 on 1920x1080). Settings clips the same way on height.
//
// All in 1080p-baseline units; FIT_SLACK is how far the Dashboard may yield
// before its content stops reflowing (measured: clean at 1.2, cramped at 1.3 on 1920x1080).
var DASH_W = 900
var DASH_H = 620          // 520 body + notch + borders
var NOTCH_CAP = 360
var NOTCH_PAD = 30
var FIT_SLACK = 1.1

/// The largest factor an output of this LOGICAL size can carry, never below 1.
function maxFitScale(w, h) {
    var fw = (w > 0) ? w * FIT_SLACK / (DASH_W + 2 * (NOTCH_CAP + NOTCH_PAD)) : 99
    var fh = (h > 0) ? h / DASH_H : 99
    return Math.max(1.0, Math.floor(Math.min(fw, fh) * 20) / 20)
}

/// A requested factor, brought inside what the output can hold. Never raises
/// a factor, and never takes it below 1.0 (a small output is handled by
/// DashboardLayout's own yielding, as before).
function clampToFit(f, w, h) {
    return Math.max(Math.min(f, maxFitScale(w, h)), Math.min(f, 1.0))
}

/// What `scaleForHeight` would answer for a mode at a given compositor scale.
/// Both halves of the magnification in one call, so a caller does not have to
/// remember which of them takes physical pixels.
function shellScaleFor(w, h, compositorScale) {
    var s = compositorScale > 0 ? compositorScale : 1
    return scaleForHeight(Math.round(h / s))
}

/// True when a set of outputs cannot share one shell factor.
///
/// Theme and Metrics are QML singletons, so the factor they carry is
/// process-wide, and a desk whose outputs land in different buckets is a desk
/// where THAT factor is wrong for at least one of them. This is what lets the
/// Display page say so instead of leaving the user to notice that the bar is
/// half the height of the other monitor's.
///
/// It is no longer the whole story: since P1-040 a surface resolves its own
/// output's factor through theme/OutputScale and reads a ThemeSet built at it,
/// so the singleton's factor is the fallback rather than the only answer. The
/// disagreement is still worth reporting, because a mixed desk is still a desk
/// where one global compositor scale would serve the user better.
///
/// `outputs` is [{ width, height, scale }] — physical mode plus compositor scale.
function bucketsDisagree(outputs) {
    var seen = null
    for (var i = 0; i < outputs.length; i++) {
        var o = outputs[i]
        if (!o || o.enabled === false || !o.height) continue
        var f = shellScaleFor(o.width || 0, o.height, o.scale || 1)
        if (seen === null) seen = f
        else if (seen !== f) return true
    }
    return false
}

if (typeof module !== "undefined" && module.exports)
    module.exports = {
        BREAKPOINTS: BREAKPOINTS,
        TOP_SCALE: TOP_SCALE,
        BASELINE_MIN: BASELINE_MIN,
        BASELINE_MAX: BASELINE_MAX,
        CANDIDATES: CANDIDATES,
        scaleForHeight: scaleForHeight,
        recommendedScale: recommendedScale,
        shellScaleFor: shellScaleFor,
        maxFitScale: maxFitScale,
        clampToFit: clampToFit,
        bucketsDisagree: bucketsDisagree
    }
