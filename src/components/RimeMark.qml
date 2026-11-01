import QtQuick
import QtQuick.Shapes

// ─────────────────────────────────────────────────────────────────────────────
// RimeMark — the Rime layered-ridge symbol, drawn as vectors.
//
// The mark is four flat planes, drawn bottom to top: base, structure, ACCENT,
// peak. Only plane 3 ever changes colour (brand pack page 4, "adaptive
// accent": never change the layer order or the shape). So the mark is not an
// image here: it is the four polygons of the brand masters, with plane 3
// filled by `accent` and the other three by `foreground`, at any size, crisp
// (QtQuick.Shapes' CurveRenderer anti-aliases on the GPU, like the bar's own
// silhouette), and following the wallpaper the moment the palette changes.
// The spark PNG this replaces was one fixed colour recoloured by MultiEffect.
//
// GEOMETRY. Copied point for point from the masters in
// src/assets/brand/rime-ridge-symbol.svg (and -small.svg, used at 32 px and
// below, where every plane is 20 % thinner so the gaps survive), which are
// copies of rime-os files/branding/ridge/src. tests/run-rime-mark-test.sh fails
// if these lists and those files ever disagree.
//
// NO THEME IMPORT, on purpose: the caller passes the colours, so the login
// screen (rime-greet, which loads components from this tree) can draw the same
// mark with its own palette.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root

    // Plane 3. Rime Blue by default, the shell's live accent where the shell
    // draws it (Theme.active).
    property color accent: root.brandAccent
    // The brand's own accent, drawn instead of `accent` when `accent` cannot
    // be told from the ink. Measured: the shipped Rime wallpaper's LIGHT
    // palette has active #000613 on text #1b1c1e (CIE76 dE 9.9), and the
    // ridge drew as one black shape. Every other shipped palette is at
    // dE >= 17.9 (tests/fixtures/palettes-matugen-4.2.0.json).
    readonly property color brandAccent: "#91C2DC"
    readonly property real minSeparation: 15
    // Planes 1, 2 and 4: the ink of whatever the mark sits on. Charcoal on a
    // light surface, off-white on a dark one; callers pass Theme.text.
    property color foreground: "#212224"
    // The small master below 32 px (brand pack: "min size 16 px symbol").
    property bool small: Math.min(root.width, root.height * root._vbW / root._vbH) <= 32

    implicitWidth: 24
    implicitHeight: Math.round(24 * _vbH / _vbW)

    Accessible.role: Accessible.Graphic
    Accessible.name: "Rime"

    readonly property real _vbW: 240
    readonly property real _vbH: 175

    // [plane 1, plane 2, plane 3 (accent), plane 4], viewBox 0 0 240 175.
    readonly property var masterPlanes: [
        [[11, 175], [162.5, 140], [220, 159], [235.5, 175]],
        [[0, 175], [153, 108], [212, 91.5], [194.5, 139], [160.5, 128]],
        [[47.5, 136], [149, 75], [231, 45], [217.5, 76]],
        [[91.5, 100], [129.5, 58], [240, 0], [222, 36], [142.5, 67]]
    ]
    readonly property var smallPlanes: [
        [[11, 175], [162.5, 147], [220, 162], [235.5, 175]],
        [[0, 165.5], [153, 112], [212, 99], [194.5, 137], [160.5, 128]],
        [[47.5, 125.5], [149, 76.5], [231, 52.5], [217.5, 77.5]],
        [[91.5, 80], [129.5, 46.5], [240, 0], [222, 29], [142.5, 53.5]]
    ]
    readonly property var planes: root.small ? root.smallPlanes : root.masterPlanes

    // Fit the viewBox inside the item, centred, aspect kept.
    readonly property real _s: Math.min(root.width / _vbW, root.height / _vbH)
    readonly property real _ox: (root.width - _vbW * _s) / 2
    readonly property real _oy: (root.height - _vbH * _s) / 2

    function _poly(i) {
        const out = []
        const p = root.planes[i]
        for (let k = 0; k < p.length; k++)
            out.push(Qt.point(root._ox + p[k][0] * root._s, root._oy + p[k][1] * root._s))
        out.push(out[0])
        return out
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

    // What plane 3 is actually filled with: the accent, unless it would vanish
    // into the other planes; then the brand's Rime Blue, unless that is even
    // closer to this ink, in which case the farther of the two.
    readonly property color drawnAccent: {
        const a = root.deltaE(root.accent, root.foreground)
        if (a >= root.minSeparation) return root.accent
        return root.deltaE(root.brandAccent, root.foreground) > a ? root.brandAccent : root.accent
    }

    // The fill each plane gets, by index: what tests read back.
    function planeColor(i) { return i === 2 ? root.drawnAccent : root.foreground }

    Shape {
        id: shape
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            objectName: "plane-1"
            strokeWidth: -1
            strokeColor: "transparent"
            fillColor: root.planeColor(0)
            PathPolyline { path: root._poly(0) }
        }
        ShapePath {
            objectName: "plane-2"
            strokeWidth: -1
            strokeColor: "transparent"
            fillColor: root.planeColor(1)
            PathPolyline { path: root._poly(1) }
        }
        ShapePath {
            objectName: "plane-3"
            strokeWidth: -1
            strokeColor: "transparent"
            fillColor: root.planeColor(2)
            PathPolyline { path: root._poly(2) }
        }
        ShapePath {
            objectName: "plane-4"
            strokeWidth: -1
            strokeColor: "transparent"
            fillColor: root.planeColor(3)
            PathPolyline { path: root._poly(3) }
        }
    }
}
