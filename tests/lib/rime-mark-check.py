#!/usr/bin/env python3
"""rime-mark-check.py ROOT < MARK records — judge tests/rime-mark-test.qml's pictures.

  geometry   RimeMark.qml's point lists equal the brand masters in
             src/assets/brand/*.svg, plane for plane (drift = FAIL).
  colours    for every drawn mark: the pixel at the deepest point of each plane
             is that plane's colour (plane 3 the accent, 1/2/4 the ink), within
             a small tolerance, at every size where a plane is at least 3 px
             thick there; below that the plane must still show (some pixel close
             to its colour inside the mark's box).
  live       after the accent changed, plane 3 shows the NEW accent.
  binding    the bar's and the About page's mark: accent == Theme.active and
             ink == Theme.text, read back from the drawn items, and the picture
             shows the accent in plane 3.
Prints "  ok   ..." / "  FAIL ..." lines and a summary; exit 1 on any FAIL.
"""
import json
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


VB_W, VB_H = 240.0, 175.0


def svg_planes(path):
    ns = {"s": "http://www.w3.org/2000/svg"}
    out = []
    for i in range(1, 5):
        poly = ET.parse(path).getroot().find(".//s:polygon[@id='plane-%d']" % i, ns)
        pts = [tuple(float(v) for v in p.split(",")) for p in poly.get("points").split()]
        out.append(pts)
    return out


def qml_planes(src, name):
    m = re.search(r"property var " + name + r":\s*\[(.*?)\n\s*\]", src, re.S)
    if not m:
        return None
    rows = re.findall(r"\[(\[[^\n]*?\])\]", m.group(1))
    return [[tuple(float(v) for v in pt) for pt in re.findall(r"\[([-\d.]+),\s*([-\d.]+)\]", r)] for r in rows]


qml = open(root + "/src/components/RimeMark.qml", encoding="utf-8").read()
for name, svg in (("masterPlanes", "rime-ridge-symbol.svg"), ("smallPlanes", "rime-ridge-symbol-small.svg")):
    want = svg_planes(root + "/src/assets/brand/" + svg)
    got = qml_planes(qml, name)
    if got == want:
        ok("RimeMark %s matches src/assets/brand/%s point for point" % (name, svg))
    else:
        bad("RimeMark %s drifted from src/assets/brand/%s: %r vs %r" % (name, svg, got, want))
MASTER = svg_planes(root + "/src/assets/brand/rime-ridge-symbol.svg")
SMALL = svg_planes(root + "/src/assets/brand/rime-ridge-symbol-small.svg")


def inside(pt, poly):
    x, y = pt
    c = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi:
            c = not c
        j = i
    return c


def seg_dist(p, a, b):
    px, py = p
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    t = 0.0 if dx == dy == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
    return ((px - ax - t * dx) ** 2 + (py - ay - t * dy) ** 2) ** 0.5


def deepest(planes, i):
    """The point of plane i farthest from every plane edge (in viewBox units)."""
    best, bd = None, -1.0
    poly = planes[i]
    for gx in range(0, 481):
        for gy in range(0, 351):
            p = (gx / 2.0, gy / 2.0)
            if not inside(p, poly):
                continue
            d = min(seg_dist(p, pl[k], pl[(k + 1) % len(pl)]) for pl in planes for k in range(len(pl)))
            if d > bd:
                best, bd = p, d
    return best, bd


DEEP = {"master": [deepest(MASTER, i) for i in range(4)], "small": [deepest(SMALL, i) for i in range(4)]}


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


BRAND = "#91c2dc"


def expected_plane3(accent, ink):
    """The rule, restated: the accent, unless it is within CIE76 dE 15 of the ink."""
    a = delta_e(accent, ink)
    if a >= 15:
        return accent
    return BRAND if delta_e(BRAND, ink) > a else accent


def rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[k:k + 2], 16) for k in (0, 2, 4))


def dist(a, b):
    return max(abs(a[k] - b[k]) for k in range(3))


def check_mark(r, label, accent_hex, ink_hex):
    """Pixel colours of one drawn mark. Returns the findings (list of str)."""
    img = Image.open(r["file"]).convert("RGB")
    dpr = r.get("dpr", 1) or 1
    s = min(r["w"] / VB_W, r["h"] / VB_H)
    ox = r["x"] + (r["w"] - VB_W * s) / 2
    oy = r["y"] + (r["h"] - VB_H * s) / 2
    deep = DEEP["small" if r["small"] else "master"]
    planes = SMALL if r["small"] else MASTER
    want = [rgb(ink_hex), rgb(ink_hex), rgb(accent_hex), rgb(ink_hex)]
    errs = []
    for i in range(4):
        (vx, vy), depth = deep[i]
        px, py = (ox + vx * s) * dpr, (oy + vy * s) * dpr
        if depth * s * dpr >= 1.5:     # the plane is >= 3 px thick here: its centre pixel is pure
            got = img.getpixel((int(px), int(py)))
            if dist(got, want[i]) > 6:
                errs.append("%s plane %d at (%d,%d) is %s, want %s" % (label, i + 1, px, py, "#%02x%02x%02x" % got, "#%02x%02x%02x" % want[i]))
        else:
            # Too thin to have a pure pixel: the colour must still show inside
            # the plane's own bounding box (anti-aliased toward the surface).
            xs = [(ox + x * s) * dpr for x, _ in planes[i]]
            ys = [(oy + y * s) * dpr for _, y in planes[i]]
            best = 999
            for X in range(max(0, int(min(xs))), min(img.width, int(max(xs)) + 1)):
                for Y in range(max(0, int(min(ys))), min(img.height, int(max(ys)) + 1)):
                    best = min(best, dist(img.getpixel((X, Y)), want[i]))
            if best > 40:
                errs.append("%s plane %d (thin) never shows its colour (closest %d off)" % (label, i + 1, best))
    return errs


plain = [r for r in recs if r["kind"] == "plain"]
if not plain:
    bad("no plain marks were drawn")
for r in plain:
    if r.get("missing"):
        bad("%s: no mark found" % r["name"])
        continue
    surface = "dark" if "-dark-" in r["name"] else "light"
    ink = "#fafafa" if surface == "dark" else "#212224"
    acc = "#91c2dc" if r["pass"] == 0 else "#e0457b"
    if r["accent"] != acc:
        bad("%s pass %d: the mark's accent is %s, the test set %s" % (r["name"], r["pass"], r["accent"], acc))
        continue
    want_small = min(r["w"], r["h"] * VB_W / VB_H) <= 32
    if r["small"] != want_small:
        bad("%s: small master %s at %d px" % (r["name"], "used" if r["small"] else "not used", r["w"]))
    if r["planes"] != [ink, ink, acc, ink]:
        bad("%s pass %d: planeColor() = %s, want ink/ink/accent/ink %s/%s" % (r["name"], r["pass"], r["planes"], ink, acc))
        continue
    errs = check_mark(r, "%s pass %d" % (r["name"], r["pass"]), acc, ink)
    if errs:
        for e in errs:
            bad(e)
    else:
        ok("%s%s: plane 3 %s, planes 1/2/4 %s (%s master)" % (
            r["name"], " after the accent changed" if r["pass"] else "", acc, ink, "small" if r["small"] else "full"))

for kind, what in (("bar", "the bar's mark (Left/ControlPanel)"), ("about", "the About mark (Settings → Misc)")):
    rs = [r for r in recs if r["kind"] == kind]
    if not rs:
        bad("%s was not drawn" % what)
        continue
    for r in rs:
        if r.get("missing"):
            bad("%s: no RimeMark found in %s" % (what, r["name"]))
            continue
        if r["accent"] != r["themeActive"] or r["foreground"] != r["themeText"]:
            bad("%s (%s): accent %s / ink %s, but Theme.active %s / Theme.text %s" % (
                what, r["scheme"], r["accent"], r["foreground"], r["themeActive"], r["themeText"]))
            continue
        if r.get("accessibleName") != "Rime":
            bad("%s: accessible name %r" % (what, r.get("accessibleName")))
            continue
        p3 = expected_plane3(r["accent"], r["foreground"])
        if r["planes"][2] != p3:
            bad("%s (%s): plane 3 is %s, the rule says %s (accent %s, ink %s, dE %.1f)" % (
                what, r["scheme"], r["planes"][2], p3, r["accent"], r["foreground"],
                delta_e(r["accent"], r["foreground"])))
            continue
        errs = check_mark(r, "%s (%s)" % (what, r["scheme"]), p3, r["foreground"])
        if errs:
            for e in errs:
                bad(e)
        else:
            ok("%s (%s palette): accent = Theme.active %s, ink = Theme.text %s (dE %.1f), plane 3 drawn %s%s" % (
                what, r["scheme"], r["accent"], r["foreground"], delta_e(r["accent"], r["foreground"]), p3,
                "" if p3 == r["accent"] else " (Rime Blue: the accent would vanish into the ink)"))

# The separation rule on its own: an accent the ink swallows.
coll = [x for x in recs if x["kind"] == "collapse"]
if not coll:
    bad("the collapse case was not drawn")
for r in coll:
    if r.get("missing"):
        bad("collapse cell: no mark")
        continue
    if r["planes"][2] != BRAND:
        bad("an accent within dE 15 of the ink (%s on %s) is drawn as is (%s), not in Rime Blue" % (
            r["accent"], r["foreground"], r["planes"][2]))
        continue
    errs = check_mark(r, "collapse (pass %d)" % r["pass"], BRAND, r["foreground"])
    if errs:
        for e in errs:
            bad(e)
    else:
        ok("an accent the ink would swallow (%s on %s, dE %.1f) is drawn in Rime Blue" % (
            r["accent"], r["foreground"], delta_e(r["accent"], r["foreground"])))

print("\nrime-mark: passed=%d failed=%d" % (passed, failed))
sys.exit(1 if failed else 0)
