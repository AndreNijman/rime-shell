#!/usr/bin/env bash
# The volume and brightness panel opens when the pointer is put on the right
# edge on purpose, and not when it passes. See tests/edge-intent-test.qml.
#
#     ./tests/run-edge-intent-test.sh
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell labwc

# Quickshell resolves imports only inside the config's own folder, so the test
# runs from a copy at the repository root, where src/ is inside it.
staged="$root/.edge-intent-test.qml"
sed -e 's#"\.\./src/windows"#"src/windows"#' -e 's#"\.\./src"#"src"#' \
    "$here/edge-intent-test.qml" >"$staged"

cleanup() { rm -f "$staged"; headless_cleanup; }
trap cleanup EXIT INT TERM

headless_begin
headless_start labwc || exit 0

log="$HEADLESS_W/shell.log"
QT_LOGGING_RULES="qml=true" timeout 90 quickshell -p "$staged" >"$log" 2>&1

probe() { sed -n "s/.*PROBE $1=//p" "$log" | tail -1; }

pass=0; fail=0
ok()  { printf '  PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s\n' "$1"; fail=$((fail+1)); }
is()  { if [ "$(probe "$2")" = "$3" ]; then ok "$1"; else bad "$1 (got '$(probe "$2")', want '$3')"; fi; }

if [ "$(probe "done")" != yes ]; then
    echo "--- shell output ---"; sed 's/\x1b\[[0-9;]*m//g' "$log" | tail -40
    echo "FAIL: the test did not run to the end"; exit 1
fi

is "resting 12 px short of the edge, inside the old hover zone, does not open it" near.rises 0
is "touching the edge for 80 ms and leaving does not open it"                     flick.rises 0
is "resting at the edge opens it"                                                 rest.open true
is "  ...and leaving the strip closes it again"                                   rest.afterLeave false
is "sliding along the edge does not open it"                                      slide.risesWhileMoving 0
is "  ...and stopping there does"                                                 slide.openAfterStop true
is "resting at the edge with a +-5 px tremble opens it"                           tremor.open true
is "closed from elsewhere with the pointer parked: it was open first"             spent.openBefore true
is "  ...it closes"                                                               spent.closed false
is "  ...and stays closed while the pointer rests there"                          spent.risesWhileParked 0
is "  ...and opens again once the pointer leaves and comes back"                  spent.reopenAfterReturn true
is "a click on the strip opens it"                                                click.open true
is "  ...and another closes it"                                                   click.closed true

echo "--- $pass passed, $fail failed ---"
[ "$fail" -eq 0 ]
