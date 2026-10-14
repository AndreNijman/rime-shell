#!/usr/bin/env bash
# check-calendar-today.sh — the Dashboard calendar's "today" must follow the wall
# clock. A one-shot timer set to "time until midnight" never fires after a
# suspend (monotonic timers stop), so the card kept the date the session started.
set -euo pipefail
f="$(dirname "$0")/../src/services/home/CalendarCard.qml"
fail=0
bad() { echo "FAIL: $1"; fail=1; }
has() { grep "$@" >/dev/null; }

has -E 'repeat: *true' "$f" || bad "no repeating timer re-reads the date"
has '_syncToday(false)' "$f" || bad "timer/visibility does not call _syncToday"
has 'on_LiveChanged' "$f" || bad "card does not resync when shown"
has -E 'running: *root._live' "$f" || bad "timer keeps running while hidden"
has -E '86400000|tomorrow' "$f" && bad "one-shot midnight timer is back"
# the highlight must compare against stored today, not a fresh Date() per cell
has 'new Date' <(sed -n '/Repeater {/,$p' "$f") && bad "highlight builds a Date per cell"
[ "$fail" = 0 ] && echo "calendar today: ok"
exit "$fail"
