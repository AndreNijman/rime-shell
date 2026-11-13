import QtQuick
import QtQuick.Shapes

// ─────────────────────────────────────────────────────────────────────────────
// RimeMark — the Rime Origin mark, drawn as vectors.
//
// Five circles, every one touching the outer disc at ONE point, the origin
// (lower left, 135°), filled even-odd: three bodies, coat, ring and core, that
// grow from that point the way rime ice grows from where it first touched.
// One system, not a pile of parts. The whole mark is ONE colour: the accent,
// or, where the accent would vanish into what the mark sits on, the ink.
// It is drawn as vectors (the geometry renderer, multisampled) at any size, and it
// follows the wallpaper the moment the palette changes. The bar and About draw
// it only on NixOS (Brand.ridge: the switch keeps the name of the mark it
// first carried); the bootc image keeps the spark PNG.
//
// GEOMETRY. The numbers below are the masters in src/assets/brand/
// rime-origin-symbol.svg (and -small.svg, used at 24 px and below, where the
// ring and core are thinner so the gaps survive), copies of rime-os
// files/branding/ridge/src. viewBox 0 0 84 84; circle i has radius r and
// centre origin + r·(cos 45°, −sin 45°). tests/run-rime-mark-test.sh fails if
// these numbers and those files ever disagree.
//
// NO THEME IMPORT, on purpose: the caller passes the colours, so the login
// screen (rime-greet, which loads components from this tree) can draw the same
// mark with its own palette.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root

    // The mark's colour. Rime Blue by default, the shell's live accent where
    // the shell draws it (Theme.active).
    property color accent: root.brandAccent
    readonly property color brandAccent: "#91C2DC"
    // What the mark sits on (callers pass the surface behind it).
    property color surface: "#212224"
    // The ink of that surface (callers pass Theme.text): the mark's colour when
    // the accent is within CIE76 dE `minSeparation` of the surface. Measured
    // over tests/fixtures/palettes-matugen-4.2.0.json: every shipped palette's
    // active is at dE >= 60.3 from its own surface (the light Rime wallpaper
    // palette #000613 on #faf9fb: 96.6), so the fallback is for a wallpaper
    // that gives an accent close to its surface, not for any shipped one.
    property color foreground: "#FAFAFA"
    readonly property real minSeparation: 15
    // The small master at 24 px and below (brand: minimum 16 px).
    property bool small: Math.min(root.width, root.height) <= 24

    implicitWidth: 24
    implicitHeight: 24

    Accessible.role: Accessible.Graphic
    Accessible.name: "Rime"

    readonly property real _vb: 84
    // The origin, where every circle touches the outer one, and the unit step
    // from it toward every centre (cos 45°, −sin 45°).
    readonly property real originX: 12.301515
    readonly property real originY: 71.698485
    readonly property real axis: 0.7071068
    // Radii, outer to inner: c1 ink, c2 open, c3 ink, c4 open, c5 ink.
    readonly property var masterRadii: [42, 33, 26, 20, 15]
    readonly property var smallRadii: [42, 33, 25, 20, 13]
    readonly property var radii: root.small ? root.smallRadii : root.masterRadii

    // Fit the square viewBox inside the item, centred.
    readonly property real _s: Math.min(root.width, root.height) / _vb
    readonly property real _ox: (root.width - _vb * _s) / 2
    readonly property real _oy: (root.height - _vb * _s) / 2

    function cx(i) { return root._ox + (root.originX + root.axis * root.radii[i]) * root._s }
    function cy(i) { return root._oy + (root.originY - root.axis * root.radii[i]) * root._s }
    function r(i)  { return root.radii[i] * root._s }
    // Circles i..j as SVG subpaths, two half-arcs each.
    function _circles(i, j) {
        let d = ""
        for (let k = i; k <= j; k++) {
            const x = root.cx(k), y = root.cy(k), rr = root.r(k)
            d += "M" + (x - rr) + " " + y + "a" + rr + " " + rr + " 0 1 0 " + (2 * rr) + " 0"
               + "a" + rr + " " + rr + " 0 1 0 " + (-2 * rr) + " 0Z"
        }
        return d
    }

    // CIE76 colour difference: sRGB in, Lab (D65) underneath.
    function _lab(c) {
        const lin = v => v <= 0.04045 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)
        const r = lin(c.r), g = lin(c.g), b = lin(c.b)
        const f = t => t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116
        const x = f((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047)
        const y = f(0.2126 * r + 0.7152 * g + 0.0722 * b)
        const z = f((0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883)
        return [116 * y - 16, 500 * (x - y), 200 * (y - z)]
    }
    function deltaE(a, b) {
        const p = root._lab(a), q = root._lab(b)
        return Math.hypot(p[0] - q[0], p[1] - q[1], p[2] - q[2])
    }

    // What the mark is actually filled with: the accent, or the ink when the
    // accent would vanish into the surface (the brand's mono rule).
    readonly property color drawnAccent: root.deltaE(root.accent, root.surface) >= root.minSeparation
                                         ? root.accent : root.foreground

    // The fill each body gets, 0 coat, 1 ring, 2 core: what tests read back.
    function bodyColor(i) { return root.drawnAccent }

    Shape {
        id: shape
        anchors.fill: parent
        // NOT the CurveRenderer the ridge used: measured (Quickshell 0.3.2, Qt 6),
        // it resolves even-odd wrongly when the contours are TANGENT, as every
        // circle here is at the origin: at 32 px it drew one solid disc, at
        // 48 px torn shards. The geometry renderer triangulates them correctly;
        // the 8x multisampled layer gives it the anti-aliased edge.
        preferredRendererType: Shape.GeometryRenderer
        layer.enabled: true
        layer.samples: 8

        // Each body is two circles (one for the core), filled even-odd, so the
        // inner circle opens the hole. One PathSvg string per body (rebuilt
        // whole when the size changes) rather than a PathAngleArc per circle,
        // whose late binding updates also left the holes uncut.
        ShapePath {
            objectName: "coat"
            strokeWidth: -1
            strokeColor: "transparent"
            fillColor: root.bodyColor(0)
            fillRule: ShapePath.OddEvenFill
            PathSvg { path: root._circles(0, 1) }
        }
        ShapePath {
            objectName: "ring"
            strokeWidth: -1
            strokeColor: "transparent"
            fillColor: root.bodyColor(1)
            fillRule: ShapePath.OddEvenFill
            PathSvg { path: root._circles(2, 3) }
        }
        ShapePath {
            objectName: "core"
            strokeWidth: -1
            strokeColor: "transparent"
            fillColor: root.bodyColor(2)
            fillRule: ShapePath.OddEvenFill
            PathSvg { path: root._circles(4, 4) }
        }
    }
}
