import QtQuick
import QtQuick.Shapes
import "../.."
import "geometry.js" as Geo

// ─────────────────────────────────────────────────────────────────────────────
// FluidShape — one fluid surface silhouette, drawn from parameters.
//
// `family` names a function in geometry.js (centerBloom, rightPour, …),
// `progress` is the surface's lifecycle progress, `geometry` the record of
// sizes it connects to. The path is rebuilt from those every time one changes;
// nothing here tweens a path.
//
// `channels` — { w, d, n, fw, fd } from a liquid SurfaceLifecycle — drives the
// family by its springs instead of by `progress` (see geometry.js, Channels).
//
// `motion` — a SurfaceLifecycle's `frame` — is the cheap way to give it both:
// one object, published once a frame. A channels literal built from the
// lifecycle's separate outputs re-ran this whole family (path, bounds, clip)
// and re-parsed the SVG for EVERY spring write: three springs, value and
// velocity each, six times a frame. With `motion` the path is built once a
// frame, and not at all on a frame where nothing it reads moved. `depthLeads`
// maps the lead to the depth (a pour) instead of the width (a bloom);
// `flow: false` leaves the edges unbent, for a family that took no flow.
// `hole` — SVG for a sub-path inside the body — is cut out of it (odd-even
// fill): the Dashboard leaves the notch's content window open so the bar's
// own label is seen fading as the bloom grows, rather than covered at once.
//
// Rendered by QtQuick.Shapes' CurveRenderer, which anti-aliases on the GPU by
// itself. Do NOT wrap this in `layer.samples` — the 8x MSAA layer the Canvas
// shapes needed is most of what made them cost 1.65 ms a frame against this
// renderer's 0.17 (roadmaps/baseline/BASELINE.md §3).
// ─────────────────────────────────────────────────────────────────────────────
Shape {
    id: shape

    property string family: "centerBloom"
    property real   progress: 0
    property var    geometry: ({})
    property var    channels: null
    property var    motion: null
    property bool   depthLeads: false
    property bool   flow: true
    property string hole: ""
    // Odd-even by default (it is what cuts `hole` out). A family built of
    // overlapping sub-paths wound the same way takes the non-zero rule, so
    // they union instead of cancelling.
    property int    fillRule: ShapePath.OddEvenFill
    property color  color: Theme.background

    // How many times `result` was built (tests: once a frame, never at rest).
    // A plain object, so counting notifies nothing.
    readonly property var _stats: ({ builds: 0 })

    // The inputs as ONE value, so `result` has one dependency that moves a
    // frame: with `motion`, the channels and the progress both come from it.
    readonly property var _in: {
        const m = shape.motion
        if (!m) return { p: shape.progress, ch: shape.channels }
        const lw = !shape.depthLeads
        const ch = { w: lw ? m.lead : m.body, d: lw ? m.body : m.lead, n: m.trail }
        if (shape.flow) { ch.fw = lw ? m.leadFlow : m.bodyFlow; ch.fd = lw ? m.bodyFlow : m.leadFlow }
        return { p: m.progress, ch: ch }
    }
    /// The channels the family is drawn with ({ w, d, n, fw, fd }), or null.
    readonly property var ch: shape._in.ch

    /// The family's full result: path, bounds, clip, bar (see geometry.js).
    readonly property var result: {
        shape._stats.builds++
        const i = shape._in
        return Geo[shape.family](i.p, i.ch ? Object.assign({}, shape.geometry, { ch: i.ch }) : shape.geometry)
    }

    preferredRendererType: Shape.CurveRenderer

    ShapePath {
        fillColor:   shape.color
        fillRule:    shape.fillRule
        strokeWidth: -1
        strokeColor: "transparent"
        PathSvg { path: shape.hole !== "" ? shape.result.path + " " + shape.hole : shape.result.path }
    }
}
