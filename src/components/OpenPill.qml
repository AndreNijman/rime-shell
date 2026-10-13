import QtQuick
import "../"

// ─────────────────────────────────────────────────────────────────────────────
// OpenPill — a bar control's open state.
//
// While the surface a control opened is up, its glyph sits on a small
// full-radius pill in the selection tint (brief §D.5). It replaces the right
// notch's old open state, which faded every status icon out and drew a ▾ in
// their place: the readout vanished exactly while the panel it opened was
// showing the same thing. Now every other icon stays where it is.
//
// Put it inside the glyph's own item; it centres on the glyph and draws
// beneath it.
//
// On the glyph's INK, not on the box it sits in. A centred item lands on a
// whole pixel, so a 15 px advance in a 20 px box is half a pixel to one side,
// and an icon's ink need not fill its advance or the middle of its line box:
// measured at 1x the wifi glyph sat 0.63 px left of a pill centred on the box
// (one more grey column on its right than its left), and about a pixel high at
// 1.35 and 1.5. The pill moves to the glyph, never the glyph to the pill, so the
// glyph stays on whole pixels and nothing else in the bar shifts.
// tests/run-open-pill-centre-test.sh holds every bar pill to its glyph's pixels.
// ─────────────────────────────────────────────────────────────────────────────
Rectangle {
    id: pill
    property bool shown: false
    property real size: 24
    // What it marks. Unset: the glyph of the IconBtn it is in (`glyphItem`),
    // else the Text it is in, else the middle of its parent. A Text is centred
    // on its ink; any other item on its box.
    property Item glyph: null

    readonly property Item _glyph: pill.glyph ? pill.glyph
        : pill.parent && pill.parent.glyphItem ? pill.parent.glyphItem
        : pill._isText(pill.parent) ? pill.parent
        : null

    function _isText(item) {
        return !!item && item.font !== undefined && typeof item.text === "string"
            && item.contentWidth !== undefined
    }

    // The glyph's outline, measured at a large size and scaled down: at the
    // size it is drawn, a tight bounding rect comes back in whole pixels and
    // padded (the bell at 15 px: -12..+2 for ink drawn at -11.9..+1.0).
    readonly property real _probePx: 1000
    TextMetrics {
        id: ink
        font: pill._isText(pill._glyph)
              ? Qt.font({ family: pill._glyph.font.family, weight: pill._glyph.font.weight,
                          italic: pill._glyph.font.italic, styleName: pill._glyph.font.styleName,
                          pixelSize: pill._probePx })
              : Qt.font({ pixelSize: pill._probePx })
        text: pill._isText(pill._glyph) ? pill._glyph.text : ""
    }
    function _inkCentre() {
        const p = pill.parent, g = pill._glyph
        if (!p) return Qt.point(0, 0)
        if (!g) return Qt.point(p.width / 2, p.height / 2)
        // Named so the binding follows the glyph when it moves or resizes.
        const gx = g.x, gy = g.y, gw = g.width, gh = g.height
        let cx = gw / 2, cy = gh / 2
        const r = ink.tightBoundingRect
        const k = pill._isText(g) ? g.font.pixelSize / pill._probePx : 0
        if (k > 0 && r.width > 0 && r.height > 0) {
            const lead = g.horizontalAlignment === Text.AlignHCenter ? (gw - g.contentWidth) / 2
                       : g.horizontalAlignment === Text.AlignRight   ? gw - g.contentWidth
                       : 0
            cx = lead + (r.x + r.width / 2) * k
            cy = g.baselineOffset + (r.y + r.height / 2) * k
        }
        return g === p ? Qt.point(cx, cy) : g.mapToItem(p, cx, cy)
    }
    readonly property point _centre: pill._inkCentre()

    x: pill._centre.x - pill.width / 2
    y: pill._centre.y - pill.height / 2
    z: -1
    width: pill.size; height: pill.size
    radius: height / 2
    // The one selected tint the shell uses (the nav pill's too).
    color: Theme.surfaceSelected

    visible: pill.opacity > 0
    opacity: pill.shown ? 1 : 0
    scale:   pillScale.value
    // The state beat. The scale is the spatial half and goes with Reduce
    // Motion (the follower jumps); the fade stays.
    Behavior on opacity { MotionFade { role: "state" } }
    SpringFollower { id: pillScale; role: "toggle"; epsilon: 0.0005; target: pill.shown ? 1 : 0.9 }
}
