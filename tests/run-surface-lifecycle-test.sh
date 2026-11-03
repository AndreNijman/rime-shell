#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-surface-lifecycle-test.sh — the transient-surface state machine
#  (UI/UX roadmap v3, Phase 6).
#
#  Stages the REAL src/components/SurfaceLifecycle.qml and the real motion
#  system (tests/lib/theme-stub.sh's stage_motion) and runs
#  tests/surface-lifecycle-test.qml under qmltestrunner on the offscreen
#  platform: no compositor, no window on anybody's desk.
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

runner=""
for c in qmltestrunner-qt6 qmltestrunner \
         /usr/lib64/qt6/bin/qmltestrunner /usr/lib/qt6/bin/qmltestrunner; do
    if command -v "$c" >/dev/null 2>&1; then runner="$c"; break; fi
done
[[ -n "$runner" ]] || { echo "SKIP: qmltestrunner not installed (qt6-qtdeclarative-devel)"; exit 0; }

stage="$(mktemp -d)"
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT INT TERM

mkdir -p "$stage/components"
cp "$root/src/components/SurfaceLifecycle.qml" "$root/src/components/Spring.qml" "$stage/components/"
# The lifecycle resets the focus-ring modality when a surface opens
# (components/controls/InputModality), so the controls directory comes too.
cp -r "$root/src/components/controls" "$stage/components/controls"
# A FluidShape on a lifecycle's frame: its path builds are counted.
mkdir -p "$stage/shapes"
cp -r "$root/src/shapes/fluid" "$stage/shapes/fluid"
cp "$here/surface-lifecycle-test.qml" "$stage/"
: > "$stage/qmldir"

. "$here/lib/theme-stub.sh"
stage_motion "$stage" "$root" || { echo "RESULT: the staged motion system could not be built"; exit 1; }

run_suite() {
    QT_QPA_PLATFORM=offscreen timeout 120 "$runner" -platform offscreen \
        -input "$stage/surface-lifecycle-test.qml" 2>&1
}
out="$(run_suite)"
rc=$?
echo "$out" | grep -E -A3 "^(PASS|FAIL|Totals)|QWARN|is not a type|Error" | grep -v "^PASS" | head -60

if grep -q 'is not a type\|module .* is not installed' <<<"$out"; then
    echo "RESULT: the staged lifecycle did not load"; exit 1
fi
passed="$(sed -n 's/^Totals: \([0-9]*\) passed.*/\1/p' <<<"$out")"
[[ -n "$passed" && "$passed" -ge 10 ]] || { echo "RESULT: too few assertions ran (${passed:-0})"; exit 1; }
[[ $rc -eq 0 ]] || { echo "RESULT: failing assertions"; exit 1; }

# ── Can it fail? ─────────────────────────────────────────────────────────────
# Each mutant is applied to the staged lifecycle and must FAIL the suite (repo
# idiom: a mutant that did not apply is reported as such, never as caught).
selffail=0
mutant() {   # mutant <label> <old> <new>
    python3 - "$root/src/components/SurfaceLifecycle.qml" "$stage/components/SurfaceLifecycle.qml" "$2" "$3" <<'PY' \
        || { echo "  FAIL self-test $1: the mutation did not apply"; selffail=1; return; }
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if s.count(old) != 1: sys.exit(3)
open(dst, "w").write(s.replace(old, new, 1))
PY
    if run_suite >/dev/null; then
        echo "  FAIL self-test $1: the suite still passes"; selffail=1
    else
        echo "  ok   self-test $1: caught"
    fi
}
mutant "window hidden on close (not kept)" \
    'readonly property bool windowVisible: life.mapped
        || (life.keepWindow && life.parkable && life._everOpened)' \
    'readonly property bool windowVisible: life.mapped'
mutant "parked window keeps updating" \
    'readonly property bool windowUpdates: !life.parked || !life._parkFlushed' \
    'readonly property bool windowUpdates: true'
mutant "body released a frame late (no analytic handoff)" \
    'const tc = L.crossingTime(dt, life.openRelease)' 'const tc = -1'
mutant "lead released a frame late on close" \
    'const tc = B.crossingTime(dt, life.closeRelease)' 'const tc = -1'
mutant "frame republished when nothing moved" \
    'if (f.body === B.value' 'if (false && f.body === B.value'
cp "$root/src/components/SurfaceLifecycle.qml" "$stage/components/SurfaceLifecycle.qml"
[[ $selffail -eq 0 ]] || { echo "RESULT: a mutant was not caught"; exit 1; }
echo "RESULT: the surface lifecycle maps, reverses and unmaps on completion; kept windows park, released channels start at the crossing, the path builds once a moved frame"
