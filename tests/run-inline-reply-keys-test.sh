#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-inline-reply-keys-test.sh — answering a notification from the keyboard.
#
#  The real shell in a headless labwc, typed into with wtype, on a PRIVATE
#  session bus with no service directories (nothing can be activated on it):
#  the shell owns org.freedesktop.Notifications there, the notifications are
#  sent with gdbus, and what the shell tells the sender is read off the bus
#  with gdbus monitor. Nothing reaches the desktop. This is the half
#  tests/run-inline-reply-test.sh cannot do: keys through the centre's
#  exclusive-keyboard layer surface into the field.
#
#    R      the newest card takes an inline reply ("Reply"); Tab ×2 reaches
#           the cards, a third Tab its Reply button, Space opens the field. In
#           the EMPTY field BackSpace, Delete, Up and Down must stay in it (on
#           the list, BackSpace and Delete dismiss, which the phone link reads
#           as the user swiping it away), and Return must send nothing. Then
#           half the text, a replace-id update of R (a phone conversation
#           re-sends its notification on every message), the rest, and Return
#                                        → NotificationReplied (R, '<whole text>')
#    R2     arrives with the centre open; Up reaches it, r, some text, Escape:
#           the field closes, nothing is sent, and the pane stays open with
#           the keys on the list — proved by r, new text, Return
#                                        → NotificationReplied (R2, '<new text>')
#    P      a plain card: r does nothing, and nothing typed at it reaches the bus.
#    Escape on the list closes the centre.
#
#  Skips (status 0) without quickshell, labwc, wtype, gdbus or dbus-run-session.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
if [ "${RIME_CAPTURE_BUS:-}" != private ]; then
    command -v dbus-run-session >/dev/null 2>&1 || { echo "SKIP: dbus-run-session is not installed"; exit 0; }
    conf="$(mktemp "${TMPDIR:-/tmp}/rime-reply-bus.XXXXXX.conf")"
    cat > "$conf" <<'CONF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
</busconfig>
CONF
    exec env -u WAYLAND_DISPLAY -u DISPLAY RIME_REPLY_BUS_CONF="$conf" \
        dbus-run-session --config-file="$conf" -- env RIME_CAPTURE_BUS=private "$0" "$@"
fi
[ -n "${RIME_REPLY_BUS_CONF:-}" ] && rm -f "$RIME_REPLY_BUS_CONF"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="${RIME_REPLY_ROOT:-$(cd "$here/.." && pwd)}"
. "$here/lib/headless.sh"
headless_require quickshell labwc wtype gdbus

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

headless_begin
qs=""; mon=""
cleanup() {
    [ -n "$mon" ] && kill "$mon" 2>/dev/null
    [ -n "$qs" ] && kill "$qs" 2>/dev/null
    headless_cleanup
}
trap cleanup EXIT INT TERM
[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1920x1080 || exit 0

ud="$HOME/.config/rime-shell/src/user_data"; mkdir -p "$ud" "$HOME/.cache/rime-shell"
printf '{"barEnabled":false,"animDuration":320,"motionScale":1}' > "$ud/settings.json"
headless_rime_palette dark
log="$HEADLESS_W/shell.log"
RIME_PACING_LOG=1 quickshell -p "$root/shell.qml" > "$log" 2>&1 &
qs=$!
for _ in $(seq 1 120); do grep -q "Configuration Loaded" "$log" && break; sleep 0.25; done
grep -q "Configuration Loaded" "$log" || { echo "RESULT: the shell did not load"; tail -20 "$log"; exit 1; }
sleep 3

bus="$HEADLESS_W/bus.log"
ipc()  { quickshell -p "$root/shell.qml" ipc call "$@" >/dev/null 2>&1; }
keys() { local k; for k in "$@"; do wtype -k "$k"; sleep 0.3; done; }
seen() {   # seen <file> <extended regex> <seconds>
    local _
    for _ in $(seq 1 $(( $3 * 4 ))); do grep -qE -- "$2" "$1" && return 0; sleep 0.25; done
    return 1
}
count() { grep -cE -- "$1" "$bus" || true; }
esc()   { printf '%s' "$1" | sed 's/[][\.*^$?+(){}|/]/\\&/g'; }   # typed text as a literal in a regex
notify() {   # notify <summary> <actions> [replaces id] [body] — prints the id
    gdbus call --session --dest org.freedesktop.Notifications \
        --object-path /org/freedesktop/Notifications \
        --method org.freedesktop.Notifications.Notify \
        "Phone" "${3:-0}" "" "$1" "${4:-a message}" "$2" '{}' 0 | sed -E 's/.*uint32 ([0-9]+).*/\1/'
}
mapped() { [ "$(grep -c 'pacing: right-panel mapped=true' "$log")" -gt "$(grep -c 'pacing: right-panel mapped=false' "$log")" ]; }
wtype -k Shift_L; sleep 0.3          # the first wtype key of a session is lost

gdbus monitor --session --dest org.freedesktop.Notifications > "$bus" 2>&1 &
mon=$!
idP="$(notify "plain" '@as []')"
idR="$(notify "reply" '["inline-reply", "Reply"]')"
sleep 1
[ -n "$idP" ] && [ -n "$idR" ] || bad "notifications were accepted (ids: $idP $idR)"

ipc notification-toggle toggle; sleep 1.5
keys Tab Tab Tab space
sleep 0.5
keys BackSpace Delete Up Down Return
sleep 1.5
[ "$(count "NotificationClosed \(uint32 ($idR|$idP),")" = 0 ] \
    && ok "BackSpace, Delete, Up, Down in the empty field dismiss nothing" \
    || bad "a key in the empty field reached the list: $(grep -o 'NotificationClosed[^)]*)' "$bus" | tr '\n' '|')"
[ "$(count "NotificationReplied")" = 0 ] \
    && ok "Return in the empty field sends nothing" \
    || bad "an empty reply was sent: $(grep -o 'NotificationReplied[^)]*)' "$bus" | tr '\n' '|')"

text1="see you at 5, ok?"
wtype "see you "; sleep 0.4
idRr="$(notify "reply" '["inline-reply", "Reply"]' "$idR" "a newer message")"
sleep 1
[ "$idRr" = "$idR" ] || bad "the update replaced R in place (id $idRr, want $idR)"
wtype "at 5, ok?"; sleep 0.4; keys Return
seen "$bus" "NotificationReplied \(uint32 $idR, '$(esc "$text1")'\)" 5 \
    && ok "Tab ×3, Space, text typed across a replace-id update, Return: the whole text answers it: '$text1'" \
    || bad "typed reply — the bus saw: $(grep -o 'NotificationReplied[^)]*)' "$bus" | tr '\n' '|')"
seen "$bus" "NotificationClosed \(uint32 $idR, uint32 2\)" 5 \
    && ok "... and the answered notification closes" \
    || bad "no NotificationClosed for the answered notification"
sleep 1

# A second one arrives with the centre open, on top; the highlight is on P.
idR2="$(notify "reply two" '["inline-reply", "Reply"]')"
sleep 1.5
keys Up r
sleep 0.5
wtype "not this"; sleep 0.4
keys Escape
sleep 1
[ "$(count "NotificationReplied \(uint32 $idR2,")" = 0 ] \
    && ok "Escape in the field sends nothing" \
    || bad "Escape sent the reply: $(grep -o 'NotificationReplied[^)]*)' "$bus" | tr '\n' '|')"
mapped && ok "... and leaves the centre open" || bad "Escape in the field closed the centre"
keys r
sleep 0.5
text2="second try"
wtype "$text2"; sleep 0.4; keys Return
seen "$bus" "NotificationReplied \(uint32 $idR2, '$(esc "$text2")'\)" 5 \
    && ok "after Escape the list has the keys: r, new text, Return answer it ('$text2', the cancelled text gone)" \
    || bad "reply after Escape — the bus saw: $(grep -o 'NotificationReplied[^)]*)' "$bus" | tr '\n' '|')"
sleep 1

# Only P is left, highlighted.
keys r
wtype "x"; sleep 0.3; keys Return
sleep 1
[ "$(count "NotificationReplied \(uint32 $idP,")" = 0 ] && [ "$(count "NotificationClosed \(uint32 $idP,")" = 0 ] \
    && ok "r on a plain card does nothing, and nothing typed at it reaches the bus" \
    || bad "the plain card: $(grep -E -o "(NotificationReplied|NotificationClosed) \(uint32 ${idP}[^)]*\)" "$bus" | tr '\n' '|')"
[ "$(count "NotificationReplied")" = 2 ] && ok "exactly two replies were sent in all" \
    || bad "want 2 NotificationReplied, got $(count "NotificationReplied")"

keys Escape
sleep 1.5
mapped && bad "Escape on the list did not close the centre" || ok "Escape on the list closes the centre"

errs="$(grep -E 'TypeError|ReferenceError|Cannot read propert' "$log" | grep -iE 'Notification|Popups' || true)"
[ -z "$errs" ] && ok "no script error from the notification code" \
               || bad "script errors: $(printf '%s' "$errs" | head -3 | tr '\n' '|')"

printf '\nrun-inline-reply-keys-test: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
