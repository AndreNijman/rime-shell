#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/phone-focus-test.qml — Do Not Disturb follows your phone.
#
#  The real PhoneFocusService runs under quickshell (offscreen: no window) with
#  a private HOME, XDG_RUNTIME_DIR and session bus. The runner plays
#  rime-remoted (it writes $XDG_RUNTIME_DIR/rime-remote/focus.json whole, by
#  rename, as the daemon does) and the person (a command file the test QML
#  reads: a Do Not Disturb toggle, or the Settings switch). `rime` is a stub
#  first on PATH that records its arguments.
#
#  Checked: off by default and with the switch off, nothing is read and nothing
#  is run; a file written before following started is not applied; a newer one
#  is, also when its directory appears only later; a change from the file is
#  never sent back; the person's own toggles run `rime remote focus on|off`.
#
#  Skips cleanly (status 0) without quickshell.
#
#  Run from the repository root: ./tests/run-phone-focus-test.sh
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }

W="$(mktemp -d)"
staged="$root/.phone-focus-test.qml"
qs_pid=""

stop_run() {
    [ -n "$qs_pid" ] && kill "$qs_pid" 2>/dev/null && wait "$qs_pid" 2>/dev/null
    qs_pid=""
    return 0
}
cleanup() { stop_run; rm -f "$staged"; rm -rf "$W"; return 0; }
trap cleanup EXIT INT TERM
cp "$here/phone-focus-test.qml" "$staged"

export HOME="$W/home" XDG_CONFIG_HOME="$W/config" XDG_CACHE_HOME="$W/cache" XDG_STATE_HOME="$W/state"
export XDG_RUNTIME_DIR="$W/run"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
settings="$HOME/.config/rime-shell/src/user_data/settings.json"
focus_dir="$XDG_RUNTIME_DIR/rime-remote"
export PF_CMD="$W/cmd"
export RIME_LOG="$W/rime.log"
export RIME_PHONE_FOCUS_REARM_MS=300

# ── The stub rime: one line per call, a little slow like a real round trip ──
mkdir -p "$W/bin"
cat > "$W/bin/rime" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$RIME_LOG"
sleep 0.2
STUB
chmod +x "$W/bin/rime"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

until_true() {  # seconds command...
    local end=$((SECONDS + $1)); shift
    while [ "$SECONDS" -lt "$end" ]; do "$@" && return 0; sleep 0.2; done
    "$@"
}
log_has() { sed -e 's/\x1b\[[0-9;]*m//g' "$W/qs.log" | grep -q "$1"; }
log_count() { sed -e 's/\x1b\[[0-9;]*m//g' "$W/qs.log" | grep -c "$1"; }
calls() { if [ -f "$RIME_LOG" ]; then wc -l < "$RIME_LOG"; else echo 0; fi; }
last_call() { tail -1 "$RIME_LOG" 2>/dev/null; }
now_ms() { date +%s%3N; }
called() { [ "$(calls)" = "$1" ] && [ "$(last_call)" = "$2" ]; }  # count last-args
last_is() { [ "$(last_call)" = "$1" ]; }
count_is() { [ "$(log_count "$1")" -ge "$2" ]; }  # line at-least

# What rime-remoted does: the whole file, private, by rename.
phone_says() {  # true|false [at_ms]
    mkdir -p "$focus_dir"; chmod 0700 "$focus_dir"
    printf '{"dnd":%s,"device":"pixel-8","at_ms":%s}\n' "$1" "${2:-$(now_ms)}" > "$focus_dir/.focus.json.t"
    chmod 0600 "$focus_dir/.focus.json.t"
    mv -f "$focus_dir/.focus.json.t" "$focus_dir/focus.json"
}
seq_n=0
person() {  # dnd|follow on|off
    seq_n=$((seq_n + 1))
    echo "$seq_n $1 $2" > "$W/cmd.t" && mv -f "$W/cmd.t" "$PF_CMD"
    until_true 5 log_has "PF did $seq_n\$" || bad "the test QML did not take command $seq_n ($1 $2)"
}
follow_setting() {  # true|false|absent
    rm -f "$settings"
    [ "$1" = absent ] && return 0
    mkdir -p "$(dirname "$settings")"
    printf '{"phoneFocus": %s}\n' "$1" > "$settings"
}

start_run() {
    rm -f "$RIME_LOG" "$PF_CMD"; seq_n=0
    ( cd "$root" && exec env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE PATH="$W/bin:$PATH" \
        QT_QPA_PLATFORM=offscreen QT_LOGGING_RULES="qml=true" \
        timeout 120 quickshell -p "$staged" ) > "$W/qs.log" 2>&1 &
    qs_pid=$!
    until_true 20 log_has "PF ready" || { echo "RESULT: quickshell did not start"; sed -e 's/\x1b\[[0-9;]*m//g' "$W/qs.log" | tail -30; exit 1; }
}

# ── 1. Following on, the directory not there yet (no phone has reported) ─────
rm -rf "$focus_dir"
follow_setting true
start_run
if log_has "PF ready enabled true dnd false"; then ok "with the switch on, the service follows"; else bad "the service follows (log: $(grep 'PF ready' "$W/qs.log"))"; fi
sleep 0.5
phone_says true
if until_true 5 log_has "PF dnd true"; then ok "a phone's Do Not Disturb reaches the Shell, also when its directory appeared after start"
else bad "a phone's Do Not Disturb reaches the Shell"; fi
sleep 0.6
if [ "$(calls)" = 0 ]; then ok "a change that came from the phone is not sent back"
else bad "a change from the phone was sent back: $(tr '\n' '|' < "$RIME_LOG")"; fi

person dnd off
if until_true 5 called 1 "remote focus off"; then ok "the person turning it off runs 'rime remote focus off'"
else bad "the person turning it off runs the verb (calls: $(tr '\n' '|' < "$RIME_LOG" 2>/dev/null))"; fi
person dnd on
if until_true 5 called 2 "remote focus on"; then ok "and on runs 'rime remote focus on'"
else bad "and on runs the verb (calls: $(tr '\n' '|' < "$RIME_LOG" 2>/dev/null))"; fi

# Two toggles while the first command is still running: both arrive, in order.
person dnd off; person dnd on; person dnd off
if until_true 5 last_is "remote focus off" && sleep 0.8 && last_is "remote focus off"
then ok "quick toggles end with the phone told the state the Shell ended in"
else bad "quick toggles end in the Shell's state (calls: $(tr '\n' '|' < "$RIME_LOG"))"; fi

before="$(calls)"
phone_says true
if until_true 5 count_is "PF dnd true" 4; then ok "the phone turning it on again reaches the Shell"
else bad "the phone turning it on again reaches the Shell ($(log_count 'PF dnd true'))"; fi
phone_says false
if until_true 5 count_is "PF dnd false" 4; then ok "and off again"
else bad "the phone turning it off again reaches the Shell ($(log_count 'PF dnd false'))"; fi
sleep 0.6
if [ "$(calls)" = "$before" ]; then ok "neither change from the phone ran the verb"
else bad "a change from the phone ran the verb: $(tr '\n' '|' < "$RIME_LOG")"; fi
stop_run

# ── 2. A file written before the Shell started is history ────────────────────
follow_setting true
phone_says true "$(( $(now_ms) - 60000 ))"
start_run
sleep 1.5
if ! log_has "PF dnd true"; then ok "a phone's state written before the Shell started is not applied"
else bad "a stale focus.json was applied at start"; fi
phone_says true
if until_true 5 log_has "PF dnd true"; then ok "the next write after start is"
else bad "the next write after start is applied"; fi
stop_run

# ── 3. Off by default: nothing read, nothing run; then switched on ───────────
follow_setting absent
start_run
if log_has "PF ready enabled false"; then ok "off by default"; else bad "off by default (log: $(grep 'PF ready' "$W/qs.log"))"; fi
phone_says true
sleep 1.5
if ! log_has "PF dnd true"; then ok "off: a phone's Do Not Disturb is not read"
else bad "off: focus.json was applied"; fi
person dnd on
person dnd off
sleep 0.6
if [ "$(calls)" = 0 ]; then ok "off: the person's toggles run nothing"
else bad "off: the verb ran: $(tr '\n' '|' < "$RIME_LOG")"; fi

trues="$(log_count 'PF dnd true')"   # the person's own toggle above is one
person follow on
if until_true 5 log_has "PF enabled true"; then ok "the Settings switch turns following on"; else bad "the Settings switch turns following on"; fi
sleep 1
if [ "$(log_count 'PF dnd true')" = "$trues" ]; then ok "switched on later: the file from before is not applied"
else bad "switched on later: the earlier file was applied"; fi
phone_says true
if until_true 5 count_is "PF dnd true" $((trues + 1)); then ok "switched on later: the next write is"
else bad "switched on later: the next write is applied"; fi
if until_true 5 grep -q '"phoneFocus": *true' "$settings"; then ok "the switch is kept in settings.json"
else bad "the switch is kept in settings.json ($(cat "$settings" 2>/dev/null | tr -d '\n' | head -c 300))"; fi
stop_run

echo "phone-focus: passed=$pass failed=$fail"
if [ "$fail" -ne 0 ]; then
    echo "--- quickshell log (last run) ---"; sed -e 's/\x1b\[[0-9;]*m//g' "$W/qs.log" | tail -40
    exit 1
fi
