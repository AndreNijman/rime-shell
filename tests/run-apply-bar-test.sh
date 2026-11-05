#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/apply-bar-test.qml — the settings apply bar, in the real settings
#  host, in a real window: hidden while clean, up on a change, in the viewport
#  at either end of the scroll, padding the page so it never covers the last
#  control, Apply / Revert / Ctrl+Enter / Ctrl+S, the Display countdown, and
#  Reduce Motion.
#
#  On a headless labwc from tests/lib/headless.sh: private XDG_RUNTIME_DIR,
#  HOME and session bus, and stubs first on PATH for everything a page shells
#  out to. The Apply it presses writes keybinds.json into that private HOME and
#  "reloads" a stub hyprctl, so nothing here touches the desktop running it.
#
#  The two shortcuts are typed into the window from outside with wtype, the way
#  a user's keyboard reaches it: the QML writes the chord it wants into a ready
#  file, this script types it and answers. Without wtype those two steps SKIP
#  and say so; everything else still runs.
#
#  RIME_AB_GRAB_DIR=DIR keeps the window pictures (clean, dirty at the top and
#  at the bottom of the scroll, the Display countdown) in DIR.
#
#  Skips (status 0) without quickshell or a wlroots compositor.
#
#  Run from anywhere: ./tests/run-apply-bar-test.sh
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell

for f in src/components/config/CfgApplyBar.qml src/components/config/CfgCommit.qml \
         src/nexus/SettingsHost.qml src/services/config_tab/KeybindsPage.qml; do
    [ -f "$root/$f" ] || { echo "FAIL: this tree has no $f"; exit 1; }
done

staged="$root/.apply-bar-test.qml"
qs_pid=""
cleanup() {
    [ -n "$qs_pid" ] && kill "$qs_pid" 2>/dev/null
    rm -f "$staged"
    headless_cleanup
}
trap cleanup EXIT INT TERM

headless_begin
W="$HEADLESS_W"
cp "$here/apply-bar-test.qml" "$staged"
mkdir -p "$HOME/.config/rime-shell/src/user_data"

headless_start labwc || exit 0

wtype_ok=0
command -v wtype >/dev/null 2>&1 && wtype_ok=1

grab_dir="${RIME_AB_GRAB_DIR:-}"
[ -n "$grab_dir" ] && mkdir -p "$grab_dir" && grab_dir="$(cd "$grab_dir" && pwd)"

READY="$W/keys-ready"
SENT="$W/keys-sent"
log="$W/apply-bar.log"
( cd "$root" && env \
    RIME_AB_GRAB_DIR="$grab_dir" \
    RIME_AB_KEYS_READY="$READY" \
    RIME_AB_KEYS_SENT="$SENT" \
    RIME_AB_WTYPE="$wtype_ok" \
    QT_LOGGING_RULES="qml=true" \
    timeout 240 quickshell -p "$staged" ) > "$log" 2>&1 &
qs_pid=$!

# Answer the QML's requests for keys until it exits.
shift_done=0
while kill -0 "$qs_pid" 2>/dev/null; do
    if [ -f "$READY" ]; then
        chord="$(cat "$READY")"
        rm -f "$READY"
        if [ "$shift_done" -eq 0 ]; then
            # Shift first: this seat has no keyboard until wtype makes one, and
            # the first key wtype sends arrives as already held.
            wtype -k Shift_L; sleep 0.3; shift_done=1
        fi
        case "$chord" in
            ctrl-return) wtype -M ctrl -k Return -m ctrl ;;
            ctrl-s)      wtype -M ctrl -k s -m ctrl ;;
        esac
        : > "$SENT"
    fi
    sleep 0.05
done
wait "$qs_pid"
qs_pid=""

sed -i -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //' "$log"
grep -E "^(  PASS|  FAIL|  SKIP)" "$log" || true

fail=0
if grep -qE "is not a type|Cannot assign|Unable to assign|Failed to load configuration" "$log"; then
    echo "  FAIL  the test built without QML errors"
    grep -E "is not a type|Cannot assign|Unable to assign|Failed to load configuration" "$log" | head -5 | sed 's/^/          /'
    fail=1
fi
if grep -qE "TypeError|ReferenceError" "$log"; then
    echo "  FAIL  no binding threw"
    grep -E "TypeError|ReferenceError" "$log" | sort -u | head -8 | sed 's/^/          /'
    fail=1
fi

summary="$(grep -o 'apply-bar: passed=[0-9]* failed=[0-9]*' "$log" | tail -1)"
if [ -z "$summary" ]; then
    tail -30 "$log"
    echo "RESULT: the test did not run to completion"
    exit 1
fi
passed="${summary#*passed=}"; passed="${passed%% *}"
failed="${summary##*failed=}"
echo "$summary"

# A run that asserts nothing passes nothing: every early exit in the driver
# would otherwise reach the summary with a handful of checks behind it.
if [ "$passed" -lt 40 ]; then
    echo "RESULT: only $passed assertions ran; the driver did not reach the end"
    exit 1
fi
if [ "$failed" -ne 0 ] || [ "$fail" -ne 0 ]; then
    echo "RESULT: the apply bar does not behave"
    exit 1
fi
echo "RESULT: the apply bar floats over the page, stays in view, pads the page,"
echo "        applies and reverts, answers its keys, and snaps under Reduce Motion"
