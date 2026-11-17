#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/inline-reply-test.qml — answering a notification from the desktop.
#
#  The phone link (rime-remoted) posts a phone's message notifications with the
#  freedesktop inline-reply action when the server advertises the capability,
#  and sends the reply from the phone when NotificationReplied comes back; KDE
#  apps and some chat clients use the same extension. This runs the shipped
#  NotificationService, centre list and toast on the offscreen platform, on a
#  private session bus, and checks both halves:
#
#    the bus     GetCapabilities lists inline-reply; over the whole run exactly
#                ONE NotificationReplied is emitted, for the notification that
#                was answered, carrying exactly the typed text — the empty and
#                blank attempts the QML makes first must emit nothing;
#    the shell   what tests/inline-reply-test.qml asserts (its header).
#
#  Keys are not posted here (quickshell has no way to post an input event);
#  tests/run-inline-reply-keys-test.sh types into the real shell under labwc.
#
#  HOME, XDG_* and the session bus are private, and the platform is offscreen:
#  nothing reaches the desktop's notification server or its screen.
#  Skips cleanly (status 0) without quickshell or gdbus.
#
#  RIME_REPLY_ROOT runs it against another tree (a mutant copy).
#  Run from the repository root: ./tests/run-inline-reply-test.sh
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${RIME_REPLY_ROOT:-$(cd "$here/.." && pwd)}"

for tool in quickshell gdbus dbus-monitor python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed"; exit 0; }
done

W="$(mktemp -d)"
staged="$root/.inline-reply-test.qml"
qs=""; mon=""
cleanup() {
    [ -n "$qs" ] && kill "$qs" 2>/dev/null
    [ -n "$mon" ] && kill "$mon" 2>/dev/null
    rm -f "$staged"; rm -rf "$W"; return 0
}
trap cleanup EXIT INT TERM
cp "$here/inline-reply-test.qml" "$staged"

export HOME="$W/home" XDG_DATA_HOME="$W/home/.local/share" XDG_CONFIG_HOME="$W/config"
export XDG_CACHE_HOME="$W/cache" XDG_STATE_HOME="$W/state" XDG_RUNTIME_DIR="$W/run"
mkdir -p "$HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

N=(--session -d org.freedesktop.Notifications -o /org/freedesktop/Notifications)

dbus-monitor --session "type='signal',interface='org.freedesktop.Notifications'" > "$W/mon.txt" 2>&1 &
mon=$!

env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
    QT_QPA_PLATFORM=offscreen timeout 90 quickshell -p "$staged" > "$W/qs.log" 2>&1 &
qs=$!

owned=0
for _ in $(seq 1 100); do
    gdbus call --session -d org.freedesktop.DBus -o /org/freedesktop/DBus \
        -m org.freedesktop.DBus.GetNameOwner org.freedesktop.Notifications >/dev/null 2>&1 && { owned=1; break; }
    sleep 0.1
done
if [ "$owned" != 1 ]; then
    sed 's/\x1b\[[0-9;]*m//g' "$W/qs.log" | tail -20
    echo "RESULT: the shell never became the notification server"
    exit 1
fi

caps="$(gdbus call "${N[@]}" -m org.freedesktop.Notifications.GetCapabilities 2>&1)"
[[ "$caps" == *"'inline-reply'"* ]] && ok "GetCapabilities lists inline-reply" \
                                     || bad "GetCapabilities lacks inline-reply: $caps"

# Past NotificationService's 500 ms startup grace, so the first one toasts.
sleep 1.5
notify() {   # notify <summary> <actions as a GVariant array>
    gdbus call "${N[@]}" -m org.freedesktop.Notifications.Notify -- \
        "Phone" 0 "" "$1" "body of $1" "$2" "{}" 0 >/dev/null
}
notify reply-a '["inline-reply", "Reply"]'
notify plain-b '["open", "Open"]'   # an ordinary action: its row shows, Reply must not
notify reply-c '["inline-reply", "Antworten"]'

wait "$qs"; qs=""
sleep 0.3
kill "$mon" 2>/dev/null; wait "$mon" 2>/dev/null; mon=""

out="$(sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*WARN qml: //' "$W/qs.log")"
printf '%s\n' "$out" | grep -E "^( *PASS| *FAIL|inline-reply:)" || true

summary="$(printf '%s\n' "$out" | grep -o 'inline-reply: passed=[0-9]* failed=[0-9]*' | tail -1)"
if [[ -z "$summary" ]]; then
    printf '%s\n' "$out" | tail -30
    echo "RESULT: the test did not run to completion"
    exit 1
fi
qfail="${summary##*failed=}"
qpass="${summary#*passed=}"; qpass="${qpass%% *}"
pass=$((pass + qpass)); fail=$((fail + qfail))

errs="$(printf '%s\n' "$out" | grep -E "TypeError|ReferenceError|Cannot read propert" || true)"
[ -z "$errs" ] && ok "no script error while replying" || bad "script errors: $(printf '%s' "$errs" | head -3 | tr '\n' '|')"

want_id="$(printf '%s\n' "$out" | sed -n 's/^REPLY_ID=//p' | tail -1)"
want_text="$(printf '%s\n' "$out" | sed -n 's/^REPLY_TEXT=//p' | tail -1)"

# Every NotificationReplied on the bus, as "<id>\t<text>", and A's NotificationClosed reasons.
python3 - "$W/mon.txt" "$want_id" > "$W/signals.txt" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
want = sys.argv[2]
i = 0
while i < len(lines):
    l = lines[i]
    if "member=NotificationReplied" in l:
        m1 = re.match(r'\s*uint32 (\d+)', lines[i + 1]) if i + 1 < len(lines) else None
        m2 = re.match(r'\s*string "(.*)"\s*$', lines[i + 2]) if i + 2 < len(lines) else None
        print("REPLIED\t%s\t%s" % (m1.group(1) if m1 else "?", m2.group(1) if m2 else "?"))
    elif "member=NotificationClosed" in l:
        m1 = re.match(r'\s*uint32 (\d+)', lines[i + 1]) if i + 1 < len(lines) else None
        m2 = re.match(r'\s*uint32 (\d+)', lines[i + 2]) if i + 2 < len(lines) else None
        if m1 and m1.group(1) == want:
            print("CLOSED\t%s\t%s" % (m1.group(1), m2.group(1) if m2 else "?"))
    i += 1
PY
replied="$(grep -c '^REPLIED' "$W/signals.txt" || true)"
if [ -z "$want_id" ]; then
    bad "the QML never reported which notification it answered"
elif [ "$replied" = 1 ]; then
    IFS=$'\t' read -r _ got_id got_text < <(grep '^REPLIED' "$W/signals.txt")
    [ "$got_id" = "$want_id" ] && ok "exactly one NotificationReplied, for the answered notification ($got_id)" \
                               || bad "NotificationReplied for id $got_id, want $want_id"
    [ "$got_text" = "$want_text" ] && ok "... carrying exactly the typed text: \"$got_text\"" \
                                   || bad "NotificationReplied text \"$got_text\", want \"$want_text\""
else
    bad "want exactly one NotificationReplied (the empty and blank attempts must emit none), got $replied: $(tr '\n' '|' < "$W/signals.txt")"
fi
grep -q "^CLOSED	$want_id	" "$W/signals.txt" \
    && ok "the answered notification is closed after the reply ($(grep "^CLOSED" "$W/signals.txt" | head -1 | cut -f3 | sed 's/^/reason /'))" \
    || bad "no NotificationClosed for the answered notification"

echo "RESULT: inline-reply: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
