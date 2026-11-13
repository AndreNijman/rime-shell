#!/usr/bin/env python3
"""rime-mark-check.py ROOT < MARK records — judge tests/rime-mark-test.qml's pictures.

  geometry   RimeMark.qml's origin and radii equal the brand masters in
             src/assets/brand/rime-origin-symbol{,-small}.svg, circle for
             circle (drift = FAIL), and every master circle touches the outer
             one at the origin.
  colours    for every drawn mark, along the axis from the origin through the
             centres (where every band is at its widest): the middle of each
             body (coat, ring, core) is the mark's colour and the middle of each
             gap is the surface, within a small tolerance, wherever the band is
             at least 3 px wide; a thinner band must still show its colour
             somewhere along its stretch of the axis.
  live       after the accent changed, the mark shows the NEW accent.
  binding    the bar's and the About page's mark: accent == Theme.active,
             surface == Theme.background, ink == Theme.text, read back from the
             drawn items, and the picture shows the colour the rule picks.
  fallback   an accent within CIE76 dE 15 of its surface is drawn in the ink.
Prints "  ok   ..." / "  FAIL ..." lines and a summary; exit 1 on any FAIL.
"""
import json
import math
import re
import sys
import xml.etree.ElementTree as ET

from PIL import Image

root = sys.argv[1]
recs = []
for line in sys.stdin:
    line = line.strip()
    if line:
        recs.append(json.loads(line))

passed = failed = 0


def ok(msg):
    global passed
    passed += 1
    print("  ok   " + msg)


def bad(msg):
    global failed
    failed += 1
    print("  FAIL " + msg)


VB = 84.0
NS = {"s": "http://www.w3.org/2000/svg"}


def svg_circles(path):
    cs = ET.parse(path).getroot().findall(".//s:circle", NS)
    return [(c.get("id"), float(c.get("cx")), float(c.get("cy")), float(c.get("r"))) for c in cs]


qml = open(root + "/src/components/RimeMark.qml", encoding="utf-8").read()


def qnum(name):
    m = re.search(r"readonly property real " + name + r":\s*([-\d.]+)", qml)
    return float(m.group(1)) if m else None


def qlist(name):
    m = re.search(r"readonly property var " + name + r":\s*\[([^\]]*)\]", qml)
    return [float(v) for v in m.group(1).split(",")] if m else None


OX, OY, AX = qnum("originX"), qnum("originY"), qnum("axis")
RADII = {}
for name, svg in (("masterRadii", "rime-origin-symbol.svg"), ("smallRadii", "rime-origin-symbol-small.svg")):
    cs = svg_circles(root + "/src/assets/brand/" + svg)
    radii = qlist(name)
    RADII[name] = radii
    errs = []
    if [c[0] for c in cs] != ["c1", "c2", "c3", "c4", "c5"]:
        errs.append("the master is not five circles c1..c5: %r" % [c[0] for c in cs])
    elif radii is None or None in (OX, OY, AX) or len(radii) != 5:
        errs.append("RimeMark has no origin/axis/%s" % name)
    else:
        for (cid, cx, cy, r), qr in zip(cs, radii):
            qx, qy = OX + AX * qr, OY - AX * qr
            if abs(r - qr) > 1e-9 or abs(cx - qx) > 0.002 or abs(cy - qy) > 0.002:
                errs.append("%s: master (%g, %g) r %g, RimeMark (%.3f, %.3f) r %g" % (cid, cx, cy, r, qx, qy, qr))
        x1, y1, r1 = cs[0][1:]
        for cid, cx, cy, r in cs[1:]:
            if abs(math.hypot(cx - x1, cy - y1) - (r1 - r)) > 0.01:
                errs.append("%s does not touch c1 at the origin" % cid)
    if errs:
        for e in errs:
            bad("RimeMark %s vs src/assets/brand/%s: %s" % (name, svg, e))
    else:
        ok("RimeMark %s matches src/assets/brand/%s circle for circle (one origin)" % (name, svg))

BANDS = ("coat", "gap between coat and ring", "ring", "gap between ring and core", "core")


def bands(radii):
    """Along the axis from the origin, circle i covers [0, 2 r_i]; even-odd leaves
    band k = [2 r_(k+1), 2 r_k] (r_6 = 0): ink for k even, open for k odd."""
    d = [2 * r for r in radii] + [0.0]
    return [(d[k + 1], d[k]) for k in range(5)]


def lab(h):
    c = [int(h.lstrip("#")[k:k + 2], 16) / 255 for k in (0, 2, 4)]
    c = [v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in c]

    def f(t):
        return t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    x = f((0.4124 * c[0] + 0.3576 * c[1] + 0.1805 * c[2]) / 0.95047)
    y = f(0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2])
    z = f((0.0193 * c[0] + 0.1192 * c[1] + 0.9505 * c[2]) / 1.08883)
    return (116 * y - 16, 500 * (x - y), 200 * (y - z))


def delta_e(a, b):
    p, q = lab(a), lab(b)
    return sum((p[k] - q[k]) ** 2 for k in range(3)) ** 0.5


def expected_colour(accent, surface, ink):
    """The rule, restated: the accent, unless it is within CIE76 dE 15 of the surface; then the ink."""
    return accent if delta_e(accent, surface) >= 15 else ink


def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[k:k + 2], 16) for k in (0, 2, 4))


def dist(a, b):
    return max(abs(a[k] - b[k]) for k in range(3))


def check_mark(r, label, mark_hex, surface_hex):
    """Pixel colours of one drawn mark along its axis. Returns the findings (list of str)."""
    if None in (OX, OY, AX):
        return ["%s: no geometry to check against" % label]
    img = Image.open(r["file"]).convert("RGB")
    dpr = r.get("dpr", 1) or 1
    s = min(r["w"], r["h"]) / VB
    ox = r["x"] + (r["w"] - VB * s) / 2
    oy = r["y"] + (r["h"] - VB * s) / 2
    radii = RADII["smallRadii" if r["small"] else "masterRadii"]

    def px(t):  # the point t units from the origin along the axis, in image pixels
        return ((ox + (OX + AX * t) * s) * dpr, (oy + (OY - AX * t) * s) * dpr)

    errs = []
    for k, (a, b) in enumerate(bands(radii)):
        want = rgb(mark_hex if k % 2 == 0 else surface_hex)
        half = (b - a) / 2
        if half * s * dpr >= 1.5:          # >= 3 px wide here: its middle pixel is pure
            x, y = px((a + b) / 2)
            got = img.getpixel((int(x), int(y)))
            if dist(got, want) > 6:
                errs.append("%s %s at (%d,%d) is %s, want %s" % (label, BANDS[k], x, y,
                                                                 "#%02x%02x%02x" % got, "#%02x%02x%02x" % want))
        else:
            best = 999
            for i in range(21):
                x, y = px(a + (b - a) * i / 20)
                for X in (int(x) - 1, int(x), int(x) + 1):
                    for Y in (int(y) - 1, int(y), int(y) + 1):
                        if 0 <= X < img.width and 0 <= Y < img.height:
                            best = min(best, dist(img.getpixel((X, Y)), want))
            if best > 48:
                errs.append("%s %s (thin) never shows its colour (closest %d off)" % (label, BANDS[k], best))
    return errs


plain = [r for r in recs if r["kind"] == "plain"]
if not plain:
    bad("no plain marks were drawn")
for r in plain:
    if r.get("missing"):
        bad("%s: no mark found" % r["name"])
        continue
    dark = "-dark-" in r["name"]
    bg = "#212224" if dark else "#fafafa"
    acc = "#91c2dc" if r["pass"] == 0 else "#e0457b"
    if r["accent"] != acc:
        bad("%s pass %d: the mark's accent is %s, the test set %s" % (r["name"], r["pass"], r["accent"], acc))
        continue
    want_small = min(r["w"], r["h"]) <= 24
    if r["small"] != want_small:
        bad("%s: small master %s at %d px" % (r["name"], "used" if r["small"] else "not used", r["w"]))
    if r["bodies"] != [acc, acc, acc]:
        bad("%s pass %d: bodyColor() = %s, want the accent %s for all three" % (r["name"], r["pass"], r["bodies"], acc))
        continue
    errs = check_mark(r, "%s pass %d" % (r["name"], r["pass"]), acc, bg)
    if errs:
        for e in errs:
            bad(e)
    else:
        ok("%s%s: coat, ring, core %s, gaps open (%s master)" % (
            r["name"], " after the accent changed" if r["pass"] else "", acc, "small" if r["small"] else "full"))

# The bootc image keeps the spark: the modules draw the mark only where rime-os's
# NixOS build flips Brand.ridge (src/state/Brand.qml). The test flips it itself.
if recs and {r.get("brandDefault") for r in recs} == {False}:
    ok("Brand.ridge is false as shipped (the bootc spark), so the Origin mark is the NixOS build's choice")
else:
    bad("Brand.ridge as shipped: %s, want false" % sorted({str(r.get("brandDefault")) for r in recs}))

for kind, what in (("bar", "the bar's mark (Left/ControlPanel)"), ("about", "the About mark (Settings → Misc)")):
    rs = [r for r in recs if r["kind"] == kind]
    if not rs:
        bad("%s was not drawn" % what)
        continue
    for r in rs:
        if r.get("missing"):
            bad("%s: no RimeMark found in %s" % (what, r["name"]))
            continue
        if not r.get("visible"):
            bad("%s (%s): the mark is not shown with Brand.ridge on" % (what, r["scheme"]))
            continue
        if (r["accent"], r["surface"], r["foreground"]) != (r["themeActive"], r["themeBackground"], r["themeText"]):
            bad("%s (%s): accent %s / surface %s / ink %s, but Theme.active %s / background %s / text %s" % (
                what, r["scheme"], r["accent"], r["surface"], r["foreground"],
                r["themeActive"], r["themeBackground"], r["themeText"]))
            continue
        if r.get("accessibleName") != "Rime":
            bad("%s: accessible name %r" % (what, r.get("accessibleName")))
            continue
        want = expected_colour(r["accent"], r["surface"], r["foreground"])
        if r["bodies"] != [want] * 3:
            bad("%s (%s): the bodies are %s, the rule says %s (accent %s on %s, dE %.1f)" % (
                what, r["scheme"], r["bodies"], want, r["accent"], r["surface"], delta_e(r["accent"], r["surface"])))
            continue
        errs = check_mark(r, "%s (%s)" % (what, r["scheme"]), want, r["surface"])
        if errs:
            for e in errs:
                bad(e)
        else:
            ok("%s (%s palette): accent = Theme.active %s on Theme.background %s (dE %.1f), drawn %s" % (
                what, r["scheme"], r["accent"], r["surface"], delta_e(r["accent"], r["surface"]), want))

# The separation rule on its own: an accent its surface swallows.
coll = [x for x in recs if x["kind"] == "collapse"]
if not coll:
    bad("the collapse case was not drawn")
for r in coll:
    if r.get("missing"):
        bad("collapse cell: no mark")
        continue
    if r["bodies"] != [r["foreground"]] * 3:
        bad("an accent within dE 15 of its surface (%s on %s) is drawn as %s, not in the ink %s" % (
            r["accent"], r["surface"], r["bodies"], r["foreground"]))
        continue
    errs = check_mark(r, "collapse (pass %d)" % r["pass"], r["foreground"], r["surface"])
    if errs:
        for e in errs:
            bad(e)
    else:
        ok("an accent its surface would swallow (%s on %s, dE %.1f) is drawn in the ink %s" % (
            r["accent"], r["surface"], delta_e(r["accent"], r["surface"]), r["foreground"]))

print("\nrime-mark: passed=%d failed=%d" % (passed, failed))
sys.exit(1 if failed else 0)
