#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/phone-clipboard-test.qml — "Send my clipboard to my phone".
#
#  The real PhoneClipboardService runs under quickshell (offscreen: no window)
#  with a private HOME, XDG_RUNTIME_DIR and session bus, and no Wayland
#  display: the clipboard is a stub `wl-paste` first on PATH, which runs the
#  service's own watch script once per change the runner writes, with
#  CLIPBOARD_STATE set as wl-clipboard 2.3.0 sets it (measured). `rime` is a
#  stub that records its arguments and its stdin. The person's real clipboard
#  is never read or written.
#
#  Checked: off by default and with the switch off nothing watches and nothing
#  runs; the clipboard as it was when watching started (also when the switch
#  goes on later) is not sent; text goes
#  to `rime remote clipboard` on stdin, byte for byte, never in argv; a
#  sensitive copy, nothing, an empty selection and text over 64 KiB are not
#  sent, exactly 64 KiB is; quick copies send the first at once and then the
#  latest, at most one per 500 ms; a sensitive copy drops the text still
#  waiting; a watcher that exits is started again; the switch is kept.
#
#  Skips cleanly (status 0) without quickshell.
#
#  Run from the repository root: ./tests/run-phone-clipboard-test.sh
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }

W="$(mktemp -d)"
staged="$root/.phone-clipboard-test.qml"
qs_pid=""

stop_run() {
    [ -n "$qs_pid" ] && kill "$qs_pid" 2>/dev/null && wait "$qs_pid" 2>/dev/null
    qs_pid=""
    return 0
}
cleanup() { stop_run; rm -f "$staged"; rm -rf "$W"; return 0; }
trap cleanup EXIT INT TERM
cp "$here/phone-clipboard-test.qml" "$staged"

export HOME="$W/home" XDG_CONFIG_HOME="$W/config" XDG_CACHE_HOME="$W/cache" XDG_STATE_HOME="$W/state"
export XDG_RUNTIME_DIR="$W/run"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
settings="$HOME/.config/rime-shell/src/user_data/settings.json"
export PC_CMD="$W/cmd"
export CLIP="$W/clip"          # the stub clipboard: initial.{state,data}, ev/<n>.{state,data}
export SENT="$W/sent"          # what the stub rime got: <n>.data, and one log line per call
export RIME_LOG="$W/rime.log"
export WLP_LOG="$W/wl-paste.log"

mkdir -p "$W/bin"
# ── The stub wl-paste: `--type text --watch <cmd…>`, one run of <cmd> per change ──
cat > "$W/bin/wl-paste" <<'STUB'
#!/usr/bin/env bash
echo "start $$ $*" >> "$WLP_LOG"
echo "$$" > "$CLIP/pid"
while [ "$#" -gt 0 ] && [ "$1" != "--watch" ]; do shift; done
shift
cmd=("$@")
fire() {  # state [data file]
    if [ -n "${2:-}" ] && [ -f "$2" ]; then CLIPBOARD_STATE="$1" "${cmd[@]}" < "$2"
    else CLIPBOARD_STATE="$1" "${cmd[@]}" < /dev/null; fi
}
# As wl-paste does: the clipboard as it is, once, at the start.
fire "$(cat "$CLIP/initial.state" 2>/dev/null || echo nil)" "$CLIP/initial.data"
n="$(cat "$CLIP/seen" 2>/dev/null || echo 0)"
while :; do
    next=$((n + 1))
    if [ -f "$CLIP/ev/$next.state" ]; then
        st="$(cat "$CLIP/ev/$next.state")"
        n=$next; echo "$n" > "$CLIP/seen"
        # As `wl-copy --clear` does to a real watcher (measured): it ends.
        [ "$st" = die ] && exit 1
        fire "$st" "$CLIP/ev/$next.data"
    else
        sleep 0.05
    fi
done
STUB
# ── The stub rime: its stdin kept whole, then one line: start-ms n args ──
cat > "$W/bin/rime" <<'STUB'
#!/usr/bin/env bash
start="$(date +%s%3N)"
n=$(( $(find "$SENT" -name '*.data' | wc -l) + 1 ))
cat > "$SENT/$n.data"
echo "$start $n $*" >> "$RIME_LOG"
sleep 0.2
STUB
chmod +x "$W/bin/wl-paste" "$W/bin/rime"

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

until_true() {  # seconds command...
    local end=$((SECONDS + $1)); shift
    while [ "$SECONDS" -lt "$end" ]; do "$@" && return 0; sleep 0.1; done
    "$@"
}
log_has() { sed -e 's/\x1b\[[0-9;]*m//g' "$W/qs.log" | grep -q "$1"; }
calls() { if [ -f "$RIME_LOG" ]; then wc -l < "$RIME_LOG"; else echo 0; fi; }
calls_are() { [ "$(calls)" = "$1" ]; }
starts() { if [ -f "$WLP_LOG" ]; then wc -l < "$WLP_LOG"; else echo 0; fi; }
starts_are() { [ "$(starts)" = "$1" ]; }
call_start() { sed -n "${1}p" "$RIME_LOG" | awk '{print $1}'; }
call_args() { sed -n "${1}p" "$RIME_LOG" | cut -d' ' -f3-; }
sent_is() {  # n file
    [ "$(call_args "$1")" = "remote clipboard" ] && cmp -s "$SENT/$1.data" "$2"
}
watcher_dead() { local p; p="$(cat "$CLIP/pid" 2>/dev/null)"; [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; }

ev_n=0
copied() {  # state [data file]: a change on the stub clipboard
    ev_n=$((ev_n + 1))
    [ -n "${2:-}" ] && cp "$2" "$CLIP/ev/$ev_n.data"
    echo "$1" > "$CLIP/ev/.t" && mv -f "$CLIP/ev/.t" "$CLIP/ev/$ev_n.state"
}
text() { printf '%b' "$2" > "$W/$1"; echo "$W/$1"; }  # name content -> path
seq_n=0
person() {  # send on|off
    seq_n=$((seq_n + 1))
    echo "$seq_n $1 $2" > "$W/cmd.t" && mv -f "$W/cmd.t" "$PC_CMD"
    until_true 5 log_has "PC did $seq_n\$" || bad "the test QML did not take command $seq_n ($1 $2)"
}
send_setting() {  # true|false|absent
    rm -f "$settings"
    [ "$1" = absent ] && return 0
    mkdir -p "$(dirname "$settings")"
    printf '{"phoneClipboard": %s}\n' "$1" > "$settings"
}
fresh_clipboard() {  # initial text
    rm -rf "$CLIP" "$SENT" "$RIME_LOG" "$WLP_LOG"; mkdir -p "$CLIP/ev" "$SENT"; ev_n=0
    printf '%s' "$1" > "$CLIP/initial.data"; echo data > "$CLIP/initial.state"
}

start_run() {
    rm -f "$PC_CMD"; seq_n=0
    ( cd "$root" && exec env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE PATH="$W/bin:$PATH" \
        QT_QPA_PLATFORM=offscreen QT_LOGGING_RULES="qml=true" \
        timeout 120 quickshell -p "$staged" ) > "$W/qs.log" 2>&1 &
    qs_pid=$!
    until_true 20 log_has "PC ready" || { echo "RESULT: quickshell did not start"; sed -e 's/\x1b\[[0-9;]*m//g' "$W/qs.log" | tail -30; exit 1; }
}

# ── 1. Switched on: what is sent and what is not ─────────────────────────────
fresh_clipboard "copied before the Shell started"
send_setting true
start_run
if log_has "PC ready enabled true"; then ok "with the switch on, the service watches"; else bad "the service watches (log: $(grep 'PC ready' "$W/qs.log"))"; fi
if until_true 5 starts_are 1 && grep -q -- '--type text --watch sh -c' "$WLP_LOG"; then ok "it runs wl-paste --type text --watch"
else bad "it runs wl-paste --type text --watch ($(cat "$WLP_LOG" 2>/dev/null | head -c 200))"; fi
sleep 1
if calls_are 0; then ok "the clipboard as it was when watching started is not sent"
else bad "the clipboard from before was sent ($(calls) calls)"; fi

f="$(text one ' two\nlines\t\xc3\xa9 ')"
copied data "$f"
if until_true 5 calls_are 1 && sent_is 1 "$f"; then ok "a copy goes to 'rime remote clipboard' on stdin, byte for byte, nothing in argv"
else bad "a copy reaches rime on stdin (calls $(calls), args '$(call_args 1)')"; fi

sleep 0.7   # past the 500 ms gap: anything sendable would go at once
copied sensitive "$(text pw 'hunter2')"
sleep 1.2
if calls_are 1; then ok "a sensitive copy is not sent"; else bad "a sensitive copy was sent ($(calls) calls)"; fi
copied nil
copied data "$(text empty '')"
head -c 65537 /dev/zero | tr '\0' 'a' > "$W/over"; copied data "$W/over"
sleep 1.2
if calls_are 1; then ok "nothing, an empty selection and 64 KiB + 1 are not sent"
else bad "something that must not be sent was ($(calls) calls: $(cut -d' ' -f2- "$RIME_LOG" | tr '\n' '|'))"; fi
head -c 65536 /dev/urandom | base64 -w0 | head -c 65536 > "$W/most"
copied data "$W/most"
if until_true 5 calls_are 2 && sent_is 2 "$W/most"; then ok "exactly 64 KiB is sent whole"
else bad "exactly 64 KiB is sent whole (calls $(calls))"; fi

# Quick copies: the first at once, then the latest, 500 ms on.
sleep 0.7
for w in a b c d e; do copied data "$(text "q$w" "quick $w")"; done
sleep 1.6
if calls_are 4 && sent_is 3 "$W/qa" && sent_is 4 "$W/qe"; then ok "quick copies: the first goes at once, then only the latest"
else bad "quick copies: first and latest only ($(calls) calls: $(for i in 3 4 5 6 7; do [ -f "$SENT/$i.data" ] && cat "$SENT/$i.data"; echo -n '|'; done))"; fi
gap=$(( $(call_start 4) - $(call_start 3) ))
if [ "$gap" -ge 450 ]; then ok "and 500 ms apart ($gap ms)"; else bad "quick copies 500 ms apart: $gap ms"; fi

sleep 0.7
copied data "$(text f 'sent at once')"; copied data "$(text g 'waiting')"; copied sensitive "$(text pw2 'hunter3')"
sleep 1.5
if calls_are 5 && sent_is 5 "$W/f"; then ok "a sensitive copy drops the text still waiting"
else bad "a sensitive copy drops the text still waiting ($(calls) calls)"; fi

# The watcher ends (as on wl-copy --clear): started again, its first report skipped.
printf '%s' "on the clipboard when it came back" > "$CLIP/initial.data"
copied die
if until_true 8 starts_are 2; then ok "a watcher that exits is started again"; else bad "a watcher that exits is started again ($(starts) starts)"; fi
sleep 1
if calls_are 5; then ok "and what the new one finds first is not sent"; else bad "the restarted watcher's first report was sent"; fi
copied data "$(text h 'after the restart')"
if until_true 5 calls_are 6 && sent_is 6 "$W/h"; then ok "the next copy after it is"; else bad "the next copy after a restart is sent ($(calls))"; fi
stop_run

# ── 2. Off by default; switched on and off again ─────────────────────────────
fresh_clipboard "before"
send_setting absent
start_run
if log_has "PC ready enabled false"; then ok "off by default"; else bad "off by default (log: $(grep 'PC ready' "$W/qs.log"))"; fi
# A copy while off: with nothing watching, it is only what the clipboard holds
# when a watcher does start, which is then its first report.
printf '%s' "copied while off" > "$CLIP/initial.data"
sleep 1.2
if starts_are 0 && calls_are 0; then ok "off: nothing watches the clipboard and nothing runs"
else bad "off: wl-paste started $(starts) times, rime $(calls) times"; fi

person send on
if until_true 5 log_has "PC enabled true" && until_true 5 starts_are 1; then ok "the Settings switch starts the watcher"
else bad "the Settings switch starts the watcher ($(starts))"; fi
sleep 1
if calls_are 0; then ok "switched on: what was copied while off is not sent"; else bad "switched on: the copy from while off was sent"; fi
copied data "$(text j 'switched on')"
if until_true 5 calls_are 1 && sent_is 1 "$W/j"; then ok "switched on: the next copy is sent"; else bad "switched on: the next copy is sent ($(calls))"; fi
if until_true 5 grep -q '"phoneClipboard": *true' "$settings"; then ok "the switch is kept in settings.json"
else bad "the switch is kept in settings.json ($(tr -d '\n' < "$settings" 2>/dev/null | head -c 300))"; fi

person send off
if until_true 5 watcher_dead; then ok "switched off: the watcher is stopped"; else bad "switched off: the watcher is still running"; fi
sleep 1
if starts_are 1; then ok "and not started again"; else bad "the watcher came back after the switch went off ($(starts))"; fi
stop_run

echo "phone-clipboard: passed=$pass failed=$fail"
if [ "$fail" -ne 0 ]; then
    echo "--- quickshell log (last run) ---"; sed -e 's/\x1b\[[0-9;]*m//g' "$W/qs.log" | tail -40
    exit 1
fi
