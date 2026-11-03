#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-update-indicator-test.sh — the top bar's update icon, built and fed on
#  a compositor of its own (tests/update-indicator-test.qml).
#
#  Two bars' real right notches read the two files the OS writes, at paths
#  under this run's scratch directory (RIME_UPDATE_STATE, RIME_LIVE_STATUS),
#  whose directories do NOT exist at the start. The QML side writes them the
#  way the OS does (in place, renamed over, deleted, the directory removed and
#  made again) and checks each bar: hidden with zero width and the notch at its
#  baseline width when there is nothing to do, the right glyph and tooltip
#  otherwise, and a click opening Settings → Updates on that bar's screen.
#
#  REDUCE_MOTION=true runs the same with Reduce Motion on (CI runs both).
#  Skips cleanly (status 0) without quickshell or without a compositor.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck source=tests/lib/headless.sh
. "$here/lib/headless.sh"

headless_require quickshell

staged="$root/.update-indicator-test.qml"
cleanup() {
    rm -f "$staged"
    headless_cleanup
}
trap cleanup EXIT INT TERM

headless_begin
W="$HEADLESS_W"

ud="$HOME/.config/rime-shell/src/user_data"; mkdir -p "$ud"
printf '{"reduceMotion":%s}' "${REDUCE_MOTION:-false}" > "$ud/settings.json"

cp "$here/update-indicator-test.qml" "$staged"

headless_start || exit 0

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

echo "── the bar's update icon (Reduce Motion: ${REDUCE_MOTION:-false}) ──"
log="$W/indicator.log"
( cd "$root" && env \
    RIME_UI_FIXTURES="$here/fixtures/live-update" \
    RIME_LIVE_STATUS="$W/run-live/status.json" \
    RIME_UPDATE_STATE="$W/run-update/state" \
    RIME_UPDATE_REARM_MS=300 \
    REDUCE_MOTION="${REDUCE_MOTION:-false}" \
    QT_LOGGING_RULES="qml=true" \
    timeout 120 quickshell -p "$staged" ) > "$log" 2>&1
sed -i -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //' "$log"

grep -E "^(  PASS|  FAIL)" "$log" || true
if grep -E "is not a type|Cannot assign|Unable to assign|Failed to load configuration" "$log" >/dev/null; then
    bad "the bar built without QML errors"
    grep -E "is not a type|Cannot assign|Unable to assign|Failed to load configuration" "$log" | head -5 | sed 's/^/          /'
else
    ok "the bar built without QML errors"
fi
if grep -E "TypeError|ReferenceError" "$log" | grep -E "Updates\.qml|UpdateStateService|liveupdate\.js|RightContent" >/dev/null; then
    bad "no binding in the icon threw"
    grep -E "TypeError|ReferenceError" "$log" | sort -u | head -5 | sed 's/^/          /'
else
    ok "no binding in the icon threw"
fi
# Absent files are the normal case: a warning per re-arm would fill the journal.
if grep -E "WARN|ERROR" "$log" | grep -E "run-live|run-update|status\.json" >/dev/null; then
    bad "an absent file or directory logs nothing"
    grep -E "WARN|ERROR" "$log" | grep -E "run-live|run-update|status\.json" | sort -u | head -5 | sed 's/^/          /'
else
    ok "an absent file or directory logs nothing"
fi
summary="$(grep -o 'passed=[0-9]* failed=[0-9]*' "$log" | tail -1)"
if [ -z "$summary" ]; then
    bad "the test ran to completion"; tail -20 "$log" | sed 's/^/          /'
else
    ok "the test ran to completion"
    got_pass="${summary%% *}"; got_pass="${got_pass#passed=}"
    got_fail="${summary##*failed=}"
    pass=$((pass + got_pass)); fail=$((fail + got_fail))
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
