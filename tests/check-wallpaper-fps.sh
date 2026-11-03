#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-wallpaper-fps.sh — the wallpaper transition runs at the display's
#  refresh rate.
#
#  WallpaperService's setter reads the fastest output's current mode from
#  wlr-randr and hands it to awww/swww as --transition-fps (it was a fixed 60,
#  which held a 144 Hz display to 60). This runs the REAL lines, taken out of
#  WallpaperService.qml, against a fake wlr-randr, and checks the setter uses
#  the result. Then mutants of those lines, each of which must fail.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
src="$root/src/services/WallpaperService.qml"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

# The shell lines, decoded from their QML string literals.
extract() {   # extract FILE -> the FPS lines as shell, or nothing
    python3 -I - "$1" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
out = []
for m in re.finditer(r'^\s*"((?:FPS=|case \\"\$FPS\\").*)"\s*\+\s*$', s, re.M):
    out.append(m.group(1).replace('\\"', '"').replace('\\\\', '\\'))
print("\n".join(out))
PY
}

mkdir -p "$work/bin"
fps_for() {   # fps_for SNIPPET WLR_RANDR_OUTPUT|-none- -> the FPS it settles on
    rm -f "$work/bin/wlr-randr"
    if [ "$2" != "-none-" ]; then
        printf '#!/bin/sh\ncat <<"EOF"\n%s\nEOF\n' "$2" > "$work/bin/wlr-randr"
        chmod +x "$work/bin/wlr-randr"
    fi
    env -i PATH="$work/bin:/usr/bin:/bin" bash -c "$1"$'\necho "$FPS"' 2>/dev/null
}

panel60='eDP-1 "BOE 0x0BCA (eDP-1)"
  Enabled: yes
  Modes:
    2560x1600 px, 60.001999 Hz (preferred, current)
    2560x1600 px, 48.000999 Hz'
dual='eDP-1 "Panel"
  Modes:
    1920x1080 px, 59.951000 Hz (current)
HDMI-A-1 "Monitor"
  Modes:
    2560x1440 px, 59.951000 Hz
    2560x1440 px, 143.912003 Hz (preferred, current)'
high='DP-1 "Monitor"
  Modes:
    2560x1440 px, 165.000000 Hz (current)'

run_cases() {   # run_cases SNIPPET -> number of failures, cases printed
    local snip="$1" bad=0 got
    check() {
        got="$(fps_for "$snip" "$2")"
        if [ "$got" = "$3" ]; then echo "  PASS  $1 → $got"
        else echo "  FAIL  $1 → '${got}', want $3"; bad=$((bad + 1)); fi
    }
    check "a 60 Hz panel"                          "$panel60" 60
    check "59.95 Hz panel + 144 Hz monitor"        "$dual"    144
    check "a 165 Hz monitor"                       "$high"    165
    check "no wlr-randr"                           "-none-"   60
    check "wlr-randr prints nothing"               ""         60
    return $bad
}

pass=1
snip="$(extract "$src")"
if [ "$(grep -c . <<<"$snip")" != 2 ]; then
    echo "  FAIL  the FPS lines were not found in WallpaperService.qml"; pass=0
else
    run_cases "$snip" || pass=0
fi
if grep -F -- '--transition-fps \"$FPS\"' "$src" >/dev/null; then
    echo "  PASS  the setter is given the measured rate"
else
    echo "  FAIL  the setter is not given \$FPS"; pass=0
fi

# ── Can it fail? ─────────────────────────────────────────────────────────────
selffail=0
mutant() {   # mutant <label> <old> <new>
    local m="$work/mut.qml"
    python3 -I - "$src" "$m" "$2" "$3" <<'PY' || { echo "  FAIL self-test $1: the mutation did not apply"; selffail=1; return; }
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
if s.count(old) != 1: sys.exit(3)
open(dst, "w").write(s.replace(old, new, 1))
PY
    if run_cases "$(extract "$m")" >/dev/null; then
        echo "  FAIL self-test $1: still passes"; selffail=1
    else
        echo "  ok   self-test $1: caught"
    fi
}
mutant "truncated, not rounded"      'printf \"%d\", m + 0.5' 'printf \"%d\", m'
mutant "the first output, not the fastest" 'if (v > m) m = v' 'if (!m) m = v'
mutant "no fallback"                 "''|0|*[!0-9]*) FPS=60" "x) FPS=60"

[ $pass = 1 ] || { echo "RESULT: FAIL — the transition rate is wrong"; exit 1; }
[ $selffail = 0 ] || { echo "RESULT: FAIL — a mutant was not caught"; exit 1; }
echo "RESULT: the wallpaper transition follows the fastest output's refresh rate (60 when unknown)"
