#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-updates-page-test.sh — Config → Updates and the `shell` IPC target,
#  built, drawn and called on a compositor of their own.
#
#  The OS's live update engine (`sudo rime update`) writes
#  /run/rime-live/status.json, the checker writes /run/rime-update/state, and
#  before replacing the running shell the engine calls
#  `qs -p /usr/share/rime-shell ipc call shell state`, then `... shell revision`
#  on the new one. This runner exercises all three from the outside:
#
#    page        every state the page tells apart, from fixtures copied into
#                the paths it reads (tests/updates-page-test.qml)
#    buttons     pressed; the terminal helper is a stub that records its argv
#                and runs NOTHING, and the record must equal liveupdate.js's
#                three constants exactly — nothing more, nothing else
#    ipc         `quickshell ipc show` lists the shell target with revision
#                and state and nothing else, and `call shell state` from
#                outside reports locked=true while the real lock is held
#    revision    read once at startup: the runner rewrites .rime-shell-commit
#                mid-run and the shell must still report the one it loaded
#
#  Skips cleanly (status 0) without quickshell or without a compositor.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck source=tests/lib/headless.sh
. "$here/lib/headless.sh"

headless_require quickshell
headless_require node

staged="$root/.updates-page-test.qml"
commit="$root/.rime-shell-commit"
commit_backup=""
cleanup() {
    rm -f "$staged"
    if [ -n "$commit_backup" ]; then mv -f "$commit_backup" "$commit"; else rm -f "$commit"; fi
    headless_cleanup
}
trap cleanup EXIT INT TERM

headless_begin
W="$HEADLESS_W"

# Never clobber a real one (an installed tree carries it).
if [ -e "$commit" ]; then commit_backup="$W/rime-shell-commit.backup"; cp -p "$commit" "$commit_backup"; fi
REVISION="0123abcdtest"
printf '%s\n' "$REVISION" > "$commit"

TERMLOG="$W/terminal-calls.log"
: > "$TERMLOG"
cat > "$W/bin/xdg-terminal-exec" <<'STUB'
#!/usr/bin/env bash
# Records the argv it was handed and runs none of it.
# One write per call, so two calls can never interleave their lines.
rec="$(printf '%s\n' "---" "$@")"
printf '%s\n' "$rec" >> "$RIME_UP_TERMLOG"
exit 0
STUB
chmod +x "$W/bin/xdg-terminal-exec"
# Nothing may reach sudo, whatever happens.
printf '#!/bin/sh\necho "sudo was run: $*" >> "%s"\nexit 1\n' "$W/sudo-calls.log" > "$W/bin/sudo"
chmod +x "$W/bin/sudo"

# The status directory does NOT exist at the start, as /run/rime-live does not
# on most machines: the page must cope, quietly, until the engine creates it.
mkdir -p "$W/run-update"
STATUS="$W/run-live/status.json"
CHECKER="$W/run-update/state"
READY="$W/ipc-ready"
DONE="$W/ipc-done"

cp "$here/updates-page-test.qml" "$staged"

headless_start || exit 0

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

log="$W/page.log"
( cd "$root" && env \
    RIME_UP_FIXTURES="$here/fixtures/live-update" \
    RIME_LIVE_STATUS="$STATUS" \
    RIME_UPDATE_STATE="$CHECKER" \
    RIME_UP_READY="$READY" \
    RIME_UP_DONE="$DONE" \
    RIME_UP_REVISION="$REVISION" \
    RIME_UP_TERMLOG="$TERMLOG" \
    RIME_UP_GRAB="$W/updates-page.png" \
    RIME_RELEASE_JSON="$here/fixtures/live-update/release.json" \
    QT_LOGGING_RULES="qml=true" \
    timeout 240 quickshell -p "$staged" ) > "$log" 2>&1 &
qs_pid=$!

# ── the external IPC calls, while the page holds the lock ───────────────────
ipc() { ( cd "$root" && timeout 20 quickshell ipc -p "$staged" "$@" ) 2>&1; }
for _ in $(seq 1 1800); do
    [ -f "$READY" ] && break
    kill -0 "$qs_pid" 2>/dev/null || break
    sleep 0.1
done
echo
echo "── the shell IPC target, from outside ─────────────────────"
if [ ! -f "$READY" ]; then
    bad "the page reached its IPC step"
else
    # The revision was read at startup. A replacement writes a new one into
    # the same directory before the new shell starts; the old shell must not
    # start reporting it.
    printf '%s\n' "ffffffffnew" > "$commit"
    show="$(ipc show)"
    shell_block="$(awk '/^target /{on = ($2 == "shell")} on' <<<"$show")"
    if [ -z "$shell_block" ]; then
        bad "ipc show lists a 'shell' target"; sed 's/^/          /' <<<"$show" | head -20
    else
        ok "ipc show lists a 'shell' target"
        fns="$(grep -oE 'function [A-Za-z_]+' <<<"$shell_block" | awk '{print $2}' | sort | tr '\n' ' ')"
        [ "$fns" = "revision state " ] && ok "it has exactly revision and state" \
            || bad "it has exactly revision and state (got: $fns)"
    fi
    state="$(ipc call shell state)"
    if node -e '
        const s = JSON.parse(process.argv[1]);
        const ok = s.locked === true && s.revision === process.argv[2] && Number.isInteger(s.pid) && s.pid > 0
                   && typeof s.lockSecure === "boolean";
        process.exit(ok ? 0 : 1)' "$state" "$REVISION" 2>/dev/null; then
        ok "call shell state, lock held: locked=true, the loaded revision, a pid ($state)"
    else
        bad "call shell state, lock held: locked=true, the loaded revision, a pid (got: $state)"
    fi
    rev="$(ipc call shell revision)"
    [ "$rev" = "$REVISION" ] && ok "call shell revision is the one loaded at startup, not the file now" \
        || bad "call shell revision is the one loaded at startup (got: $rev)"
    unl="$(ipc call shell unlock)"
    if grep -qiE "function not found|no such function" <<<"$unl"; then
        ok "call shell unlock is refused: there is no such function"
    else
        bad "call shell unlock is refused (got: $unl)"
    fi
fi
printf 'done\n' > "$DONE"

wait "$qs_pid"
sed -i -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //' "$log"

echo
echo "── the page ──────────────────────────────────────────────"
grep -E "^(  PASS|  FAIL)" "$log" || true
if grep -qE "is not a type|Cannot assign|Unable to assign|Failed to load configuration" "$log"; then
    bad "the page built without QML errors"
    grep -E "is not a type|Cannot assign|Unable to assign|Failed to load configuration" "$log" | head -5 | sed 's/^/          /'
else
    ok "the page built without QML errors"
fi
if grep -qE "TypeError|ReferenceError" "$log"; then
    bad "no binding threw"; grep -E "TypeError|ReferenceError" "$log" | sort -u | head -5 | sed 's/^/          /'
else
    ok "no binding threw"
fi
# Absent files are the normal case: a warning per poll would fill the journal.
if grep -E "WARN|ERROR" "$log" | grep -qE "run-live|run-update|status\.json"; then
    bad "an absent or missing-directory status file logs nothing"
    grep -E "WARN|ERROR" "$log" | grep -E "run-live|run-update|status\.json" | sort -u | head -5 | sed 's/^/          /'
else
    ok "an absent or missing-directory status file logs nothing"
fi
summary="$(grep -o 'passed=[0-9]* failed=[0-9]*' "$log" | tail -1)"
if [ -z "$summary" ]; then
    bad "the page test ran to completion"; tail -20 "$log" | sed 's/^/          /'
else
    ok "the page test ran to completion"
    got_pass="${summary%% *}"; got_pass="${got_pass#passed=}"
    got_fail="${summary##*failed=}"
    pass=$((pass + got_pass)); fail=$((fail + got_fail))
fi

echo
echo "── what the buttons started ──────────────────────────────"
expected="$(node -e '
    const L = require(process.argv[1]);
    for (const a of [L.UPDATE_ARGV, L.PLAN_ARGV, L.EXPLAIN_ARGV]) { console.log("---"); for (const x of a) console.log(x) }
' "$root/src/services/liveupdate.js")"
if [ "$(cat "$TERMLOG")" = "$expected" ]; then
    ok "the terminal was asked for exactly Update, Plan and Explain's constant argv, in that order"
else
    bad "the terminal was asked for exactly the constant argv"
    diff <(printf '%s\n' "$expected") "$TERMLOG" | head -20 | sed 's/^/          /'
fi
# The comparison above trusts liveupdate.js for what the constants ARE, so a
# changed constant would pass it. Pinned here independently: the command each
# button hands its hold wrapper (everything after `sh -c HOLD sh`).
tails="$(awk '/^---$/ { if (n) print s; s = ""; n = 1; i = 0; next }
              { i++; if (i > 4) s = s (s == "" ? "" : " ") $0 }
              END { if (n) print s }' "$TERMLOG")"
want_tails=$'sudo rime update\nrime update --plan\nrime live explain'
[ "$tails" = "$want_tails" ] && ok "the three commands are sudo rime update, rime update --plan, rime live explain" \
    || bad "the three commands are sudo rime update, rime update --plan, rime live explain (got: ${tails//$'\n'/ | })"
[ ! -s "$W/sudo-calls.log" ] && ok "nothing ran sudo" || bad "nothing ran sudo ($(cat "$W/sudo-calls.log"))"

png="$W/updates-page.png"
if [ -f "$png" ] && command -v python3 >/dev/null 2>&1; then
    if python3 "$here/lib/png-ink.py" "$png" 2000 980 400; then
        ok "the raster is the right size and carries ink"
    else
        bad "the raster is the wrong size, blank, or near-blank"
    fi
    [ -n "${UPDATES_PAGE_PNG:-}" ] && cp "$png" "$UPDATES_PAGE_PNG" && echo "  kept: $UPDATES_PAGE_PNG"
fi

echo
echo "passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
