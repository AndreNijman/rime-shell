"""Read tests/open-pill-centre-test.qml's records (one JSON object per line on
stdin) and compare each pill's centre with its glyph's ink.

The ink is found in the picture of the cell drawn WITHOUT the pill, inside the
pill's own square widened by 3 px. Its edges are sub-pixel: an edge column (or
row) only partly covered contributes its coverage, so a glyph drawn half a
pixel to one side reads as half a pixel to that side.
"""
import json
import sys

from PIL import Image

# How far the pill's centre may be from the ink's, in px. Andre's 1x wifi was
# 0.63 px out sideways; at 1.35 and 1.5 every glyph was about 1 px high.
#
# Sideways nothing is quantised, so 0.3. Up and down, half a device pixel:
# Qt's tightBoundingRect is FreeType's CONTROL box, which takes in a curve's
# off-curve points, so for a glyph made of arcs (the speaker's waves) the box
# reaches past the drawn ink (measured: the 50 % speaker at 23 px, box bottom
# 0.0, ink bottom -1.2) and the centre it gives is up to ~0.4 px out. Getting
# the exact ink would mean rasterising text inside the bar at run time.
TOL_X = 0.3
TOL_Y = 0.5
INK = 24        # a pixel darker than this is background (the cell is black)

# Cells that may legitimately have no ink, and why.
NO_INK_OK = {}

# The real bar modules: each must have been built and measured at every factor
# (a delegate that failed to load is a warning in the log, not an error).
REQUIRED = ["module-network", "module-notifications", "module-audio", "module-systray",
            "module-controlpanel", "module-layout-dwindle", "module-layout-master",
            "module-layout-monocle", "module-layout-scrolling"]
FACTORS = [0.85, 1.0, 1.2, 1.35, 1.5]


def edges(cov):
    """First and last covered position along one axis, sub-pixel."""
    idx = [i for i, v in enumerate(cov) if v > 0]
    if not idx:
        return None
    lo, hi = idx[0], idx[-1]
    peak = max(cov) or 1
    return lo + (1 - cov[lo] / peak), hi + cov[hi] / peak


def measure(rec):
    im = Image.open(rec["file"]).convert("L")
    dpr = rec.get("dpr", 1) or 1
    W, H = im.size
    half = max(rec["pw"], rec["ph"]) / 2 + 3
    x0 = max(0, int((rec["cx"] - half) * dpr))
    x1 = min(W, int((rec["cx"] + half) * dpr) + 1)
    y0 = max(0, int((rec["cy"] - half) * dpr))
    y1 = min(H, int((rec["cy"] + half) * dpr) + 1)
    px = im.load()
    assert px is not None
    cols = [max((px[x, y] if px[x, y] > INK else 0) for y in range(y0, y1)) for x in range(x0, x1)]
    rows = [max((px[x, y] if px[x, y] > INK else 0) for x in range(x0, x1)) for y in range(y0, y1)]
    ex, ey = edges(cols), edges(rows)
    if ex is None or ey is None:
        return None
    ix = (x0 + (ex[0] + ex[1]) / 2) / dpr
    iy = (y0 + (ey[0] + ey[1]) / 2) / dpr
    return ix, iy


def main():
    bad = 0
    n = 0
    seen = set()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        seen.add((round(rec["f"], 2), rec["name"]))
        tag = "%.2f %-22s" % (rec["f"], rec["name"])
        if rec.get("missing"):
            print("  FAIL %s no open pill found in it" % tag)
            bad += 1
            continue
        ink = measure(rec)
        if ink is None:
            if rec["name"] in NO_INK_OK:
                print("  skip %s %s" % (tag, NO_INK_OK[rec["name"]]))
                continue
            print("  FAIL %s no glyph drawn (a missing font would make every check vacuous)" % tag)
            bad += 1
            continue
        n += 1
        dx, dy = ink[0] - rec["cx"], ink[1] - rec["cy"]
        ok = abs(dx) <= TOL_X and abs(dy) <= TOL_Y
        print("  %s %s ink-pill dx %+.2f dy %+.2f" % ("ok  " if ok else "FAIL", tag, dx, dy))
        if not ok:
            bad += 1
    for f in FACTORS:
        for name in REQUIRED:
            if (f, name) not in seen:
                print("  FAIL %.2f %-22s never measured (did it load?)" % (f, name))
                bad += 1
    if n < 20:
        print("  FAIL only %d cells measured" % n)
        bad += 1
    sys.exit(1 if bad else 0)


main()
