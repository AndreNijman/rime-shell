#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-touchpad-notice-test.sh — "<phone> is using this computer as a
#  touchpad", with its Stop, on the shipped TopBar (tests/touchpad-notice-test.qml).
#
#  rime-remoted lets a paired phone move the pointer and type here (rime-os
#  docs/remote-live-contract.md §2.16) and keeps
#  $XDG_RUNTIME_DIR/rime-remote/input.json saying whether one is. The Shell
#  (services/TouchpadService.qml, modules/Center/TouchpadNotice.qml) shows it
#  in the notch with a Stop button and announces a new session once.
#
#  Proved here, on the real bar, by writing the file the way the daemon does:
#   * absent at the start (no directory either) → hidden; live → shown, the
#     carousel scrolled to it, the name as plain text, "· touchpad", a screen
#     reader's sentence, Stop a named button with a 24 px target;
#   * one notification per session (fixed summary; the same file written again
#     raises none); live:false, garbage, binary garbage, another version, live
#     as a string, a 100 KiB file and a deleted file are all hidden;
#   * a hostile name (markup, a right-to-left override, a bell, a zero-width
#     space, an isolate, Arabic, a newline, 10,000 characters) shows as plain
#     text measured against a certainly-plain Text, cleaned, kept to 64
#     characters, elided, with "· touchpad" still left of Stop; the
#     notification body carries it escaped;
#   * Stop runs exactly `rime remote devices touchpad stop` once per press,
#     with no name in any call, and the notice goes when the file says
#     live:false; a stop that does not land says so after ~3 s (and Retry);
#     a CLI that fails says so at once;
#   * the dot pulses with motion on and holds still under Reduce Motion.
#  Run twice: dark palette with motion, light palette with Reduce Motion.
#  Then each of these is broken on a copy of the tree and must fail:
#   shown when live:false, the name drawn as rich text, Stop does nothing, the
#   notice left out of the carousel when live, the notification body not
#   escaped, Stop naming the phone.
#
#  ── ITS OWN COMPOSITOR, RUNTIME DIR, HOME AND BUS (tests/lib/headless.sh) ───
#  `rime` and `notify-send` are recording stubs first on PATH: nothing reaches
#  the real rime-remoted, the real $XDG_RUNTIME_DIR/rime-remote, or the
#  desktop's notifications.
#
#  Skips cleanly (status 0) without quickshell or a compositor.
#  TP_SHOT_DIR=<dir> keeps pictures of the notch there (needs grim).
#  TOUCHPAD_NOTICE_NO_MUTANTS=1 runs the shipped tree only.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
# shellcheck source=tests/lib/headless.sh
. "$here/lib/headless.sh"

headless_require quickshell python3

for f in src/services/TouchpadService.qml src/modules/Center/TouchpadNotice.qml src/windows/TopBar.qml; do
    [[ -f "$root/$f" ]] || { echo "FAIL: this tree has no $f"; exit 1; }
done
grep -q "^singleton TouchpadService " "$root/src/qmldir" || {
    echo "FAIL: TouchpadService is not registered in src/qmldir"; exit 1; }
if grep -rq "^singleton TouchpadService " "$root/src/services/qmldir" 2>/dev/null; then
    echo "FAIL: TouchpadService is registered twice (a second copy would disagree)"; exit 1
fi

M_ROOT="$(mktemp -d)"
cleanup() {
    rm -f "$root/.touchpad-notice-test.qml"
    rm -rf "$M_ROOT"
    headless_cleanup
}
trap cleanup EXIT INT TERM

headless_begin
W="$HEADLESS_W"

# ── the recording stubs ──────────────────────────────────────────────────────
# headless_begin made both names symlinks to its shared _stub: removed first,
# or writing through them would rewrite _stub (and every other stub with it).
rm -f "$W/bin/rime" "$W/bin/notify-send"
cat > "$W/bin/rime" <<'FAKE'
#!/usr/bin/env bash
python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "$@" >> "$TP_RIME_LOG"
if [ "$*" = "remote devices touchpad stop" ]; then
    case "$(cat "$TP_MODE" 2>/dev/null)" in
        obey)
            f="$XDG_RUNTIME_DIR/rime-remote/input.json"
            printf '{"v":1,"live":false}' > "$f.tmp" && chmod 600 "$f.tmp" && mv -f "$f.tmp" "$f"
            echo "rime: the touchpad was stopped." >&2 ;;
        fail) echo "rime: rime-remoted is not running" >&2; exit 1 ;;
        *) : ;;
    esac
    exit 0
fi
case "$*" in *json*) echo "{}" ;; esac
exit 0
FAKE
cat > "$W/bin/notify-send" <<'FAKE'
#!/usr/bin/env bash
python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "$@" >> "$TP_NOTIFY_LOG"
exit 0
FAKE
chmod +x "$W/bin/rime" "$W/bin/notify-send"

headless_start labwc || exit 0

# ── one run: a fresh runtime/rime-remote state, logs, settings and palette ───
# run_once <tree> <palette dark|light> <reduce true|false> <shot dir or ""> — sets RUN_PASS RUN_FAIL RUN_BROKE
run_once() {
    local tree="$1" palette="$2" reduce="$3" shots="$4"
    local R; R="$(mktemp -d "$W/run.XXXX")"
    rm -rf "$XDG_RUNTIME_DIR/rime-remote"
    export TP_RIME_LOG="$R/rime.log" TP_NOTIFY_LOG="$R/notify.log" TP_MODE="$R/mode"
    : > "$TP_RIME_LOG"; : > "$TP_NOTIFY_LOG"
    printf '{"reduceMotion":%s}' "$reduce" > "$HOME/.config/rime-shell/src/user_data/settings.json"
    headless_rime_palette "$palette"
    local bg=""
    if [[ -n "$shots" ]] && command -v swaybg >/dev/null 2>&1; then
        swaybg -m fill -i "$HEADLESS_WALLPAPER" >/dev/null 2>&1 &
        bg=$!
    fi
    cp "$here/touchpad-notice-test.qml" "$tree/.touchpad-notice-test.qml"
    ( cd "$tree" && exec env \
        RIME_TOUCHPAD_REARM_MS=300 \
        REDUCE_MOTION="$reduce" \
        TP_SHOT_DIR="$shots" TP_SHOT_TAG="$palette$( [[ "$reduce" == true ]] && echo -reduced)" \
        timeout 180 quickshell -p "$tree/.touchpad-notice-test.qml" ) > "$R/qs.log" 2>&1
    [[ -n "$bg" ]] && { kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null; }
    rm -f "$tree/.touchpad-notice-test.qml"
    # TP_LOG_DIR=<dir>: keep this run's logs (the Shell's, and both stubs').
    if [[ -n "${TP_LOG_DIR:-}" ]]; then
        mkdir -p "$TP_LOG_DIR" && cp "$R/qs.log" "$R/rime.log" "$R/notify.log" "$TP_LOG_DIR/" 2>/dev/null
    fi
    local out
    out="$(sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*WARN qml: //' "$R/qs.log")"
    printf '%s\n' "$out" | grep -E "^ *(PASS|FAIL) " || true
    RUN_PASS=0; RUN_FAIL=0; RUN_BROKE=0
    if printf '%s\n' "$out" | grep -E "is not a type|Cannot assign|Unable to assign|Failed to load configuration" >/dev/null; then
        printf '%s\n' "$out" | grep -E "is not a type|Cannot assign|Unable to assign|Failed to load configuration" | head -5
        RUN_BROKE=1
    fi
    if printf '%s\n' "$out" | grep -E "TypeError|ReferenceError" | grep -E "Touchpad|CenterContent|touchpad-notice" >/dev/null; then
        echo "  FAIL  a binding in the notice or its test threw"
        printf '%s\n' "$out" | grep -E "TypeError|ReferenceError" | sort -u | head -5 | sed 's/^/          /'
        RUN_FAIL=$((RUN_FAIL + 1))
    fi
    local summary
    summary="$(printf '%s\n' "$out" | grep -o 'touchpad-notice: passed=[0-9]* failed=[0-9]*' | tail -1)"
    if [[ -z "$summary" ]]; then
        printf '%s\n' "$out" | tail -20
        echo "  (the run did not report)"
        RUN_BROKE=1
        return 0
    fi
    local p="${summary#*passed=}"; p="${p%% *}"
    RUN_PASS=$((RUN_PASS + p)); RUN_FAIL=$((RUN_FAIL + ${summary##*failed=}))
    return 0
}

# ── the shipped tree, both looks ─────────────────────────────────────────────
total_pass=0
shots="${TP_SHOT_DIR:-}"
if [[ -n "$shots" ]]; then
    if command -v grim >/dev/null 2>&1; then mkdir -p "$shots"; shots="$(cd "$shots" && pwd)"; else shots=""; fi
fi
for look in "dark false" "light true"; do
    read -r palette reduce <<< "$look"
    echo "== the shipped tree ($palette palette, Reduce Motion $reduce)"
    run_once "$root" "$palette" "$reduce" "$shots"
    if [[ "$RUN_BROKE" -ne 0 || "$RUN_FAIL" -ne 0 || "$RUN_PASS" -lt 50 ]]; then
        echo
        echo "RESULT: touchpad-notice: passed=$RUN_PASS failed=$RUN_FAIL broke=$RUN_BROKE — the shipped tree fails"
        exit 1
    fi
    total_pass=$((total_pass + RUN_PASS))
done
if [[ -n "$shots" ]]; then
    echo "  pictures: $shots"
fi

# The lock screen is its own surface over the bar; it must not show the
# phone or its Stop of its own accord.
if grep -nE "TouchpadService|TouchpadNotice" "$root/src/windows/Lockscreen.qml" >/dev/null; then
    echo "  FAIL  the lock screen reads the touchpad state"; exit 1
fi
echo "  PASS  the lock screen shows nothing of the touchpad (it reads neither TouchpadService nor the notice)"

[[ "${TOUCHPAD_NOTICE_NO_MUTANTS:-0}" == 1 ]] && {
    echo; echo "RESULT: touchpad-notice: passed=$total_pass failed=0 (mutants skipped)"; exit 0; }

# ── mutants: each must make the suite fail ──────────────────────────────────
echo
echo "== mutants (each must fail)"
killed=0; survived=0; unapplied=0
mutant() {   # mutant <label> <file> <old> <new>
    local label="$1" file="$2" old="$3" new="$4"
    local M; M="$(mktemp -d "$M_ROOT/mut.XXXX")"
    cp -r "$root/src" "$M/src"
    if ! python3 - "$M/$file" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if s.count(old) != 1: sys.exit(3)
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
    then echo "  FAIL  mutant '$label': the mutation did not apply"; unapplied=$((unapplied + 1)); return; fi
    run_once "$M" dark false "" > "$M/out.txt" 2>&1
    if [[ "$RUN_BROKE" -eq 0 && "$RUN_FAIL" -ne 0 ]]; then
        echo "  PASS  mutant '$label': killed ($RUN_FAIL failed)"
        grep -E "^ *FAIL" "$M/out.txt" | head -3 | sed 's/^/          /'
        killed=$((killed + 1))
    elif [[ "$RUN_BROKE" -ne 0 ]]; then
        # A tree that does not load proves nothing about the check.
        echo "  FAIL  mutant '$label': the run broke instead of failing a check"
        tail -5 "$M/out.txt" | sed 's/^/          /'
        survived=$((survived + 1))
    else
        echo "  FAIL  mutant '$label': SURVIVED ($RUN_PASS passed)"
        survived=$((survived + 1))
    fi
}

mutant "shown when live:false" \
    src/services/remotepairing.js \
    "o.v !== 1 || o.live !== true) return off" "o.v !== 1) return off"
mutant "the name drawn as rich text" \
    src/modules/Center/TouchpadNotice.qml \
    "text: TouchpadService.name
                textFormat: Text.PlainText" "text: TouchpadService.name
                textFormat: Text.StyledText"
mutant "Stop does nothing" \
    src/modules/Center/TouchpadNotice.qml \
    "onActivated: TouchpadService.stop()" "onActivated: {}"
mutant "the notice left out of the carousel when live" \
    src/modules/Center/CenterContent.qml \
    'if (TouchpadService.live) list.push("touchpad")' ''
mutant "the notification body not escaped" \
    src/services/TouchpadService.qml \
    "RP.escapeMarkup(root.name)" "root.name"
mutant "Stop names the phone" \
    src/services/TouchpadService.qml \
    "stopper.command = RP.TOUCHPAD_STOP_COMMAND" "stopper.command = RP.TOUCHPAD_STOP_COMMAND.concat([root.name])"

echo
echo "shipped tree: passed=$total_pass failed=0; mutants: killed=$killed survived=$survived not-applied=$unapplied"
if [[ "$survived" -ne 0 || "$unapplied" -ne 0 ]]; then
    echo "RESULT: touchpad-notice: a mutant survived, broke or did not apply"
    exit 1
fi
echo "RESULT: touchpad-notice: passed=$total_pass failed=0, $killed mutants killed — shown only while"
echo "        input.json says live, the name plain and elided, one notification per session with the"
echo "        name escaped, and Stop sends exactly one nameless stop and reports a stop that did not land"
