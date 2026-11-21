#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/lock-file-test.qml — the lock file a phone's touchpad waits on.
#
#  rime-remoted lets a paired phone move the pointer and type on this desktop
#  (rime-os docs/remote-live-contract.md §2.16), and injected input reaches the
#  lock screen on every compositor Rime ships. On labwc and niri, which have no
#  lock notifier, the daemon's only early warning of a lock is the Shell's
#  $XDG_RUNTIME_DIR/rime-remote/lock.json: {"locked":true|false}, a regular file
#  owned by the user, no group or other write bit (rime-remoted/src/input.rs,
#  read_shell_file). services/system/LockFileService.qml writes it.
#
#  Proved here, on the shipped Lockscreen + LockState + LockFileService:
#   * start with no file → {"locked":false}, mode 0600, directory 0700, even
#     under umask 002 (Fedora's for a user with a private group, where a plain
#     write would make 0664 and the daemon would refuse it);
#   * the file says locked AT THE INSTANT the compositor is asked for the lock,
#     and at the instant a lock starts waiting for its picture (sampled inside
#     those signal handlers);
#   * an unlock is written only once the session lock is gone: at every write
#     of false, LockState says nothing is locked and `secure` is false (it drops
#     when the Shell sends the unlock: ext-session-lock has no unlock ack); a lock
#     the compositor holds that LockState knows nothing of (scenario `direct`,
#     the shape of a reload takeover) still makes the file say locked;
#   * each write is a rename (the inode changes);
#   * a configuration reload mid-lock keeps saying locked (1.5 s of 10 ms
#     reads), and so does a Shell restarted after being killed mid-lock; logind
#     is not told unlocked by either; a lock + unlock of the new Shell's own
#     clears it.
#  Then each of these is broken on a copy of the tree and must fail:
#   ordering swapped, reload/restart writes unlocked, non-atomic write, wrong
#   mode, the file not following `secure`, logind told unlocked at a restart
#   mid-lock. (The ordering mutant dies at the capture-start probe; the
#   `secure` mutant dies in scenario `direct`.)
#
#  ── IT BRINGS ITS OWN COMPOSITOR, logind AND RUNTIME DIR, ALWAYS ────────────
#  A headless labwc in a private XDG_RUNTIME_DIR (so the lock file and the
#  session lock land there and nowhere else), with fake loginctl and busctl
#  first on PATH that record argv. Nothing here reads or writes the real logind
#  or the desktop's lock file, and nothing locks the developer's session.
#
#  Skips cleanly (status 0) without quickshell or labwc.
#  Run from the repository root: ./tests/run-lock-file-test.sh
#  LOCK_FILE_TEST_NO_MUTANTS=1 skips the mutants (the real tree only).
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }
command -v labwc >/dev/null 2>&1 || { echo "SKIP: no labwc to host the test"; exit 0; }

for f in src/services/system/LockFileService.qml src/windows/Lockscreen.qml src/state/LockState.qml; do
    [[ -f "$root/$f" ]] || { echo "FAIL: this tree has no $f"; exit 1; }
done
grep -q "^singleton LockFileService " "$root/src/services/qmldir" || {
    echo "FAIL: LockFileService is not registered in src/services/qmldir"; exit 1; }

W="$(mktemp -d)"
comp_pid=""
qs_pid=""
# Killed by pid, never by name: a pkill for a compositor on a developer's
# machine takes down the session they are working in.
stop_pid() {
    local p="$1"
    [[ -n "$p" ]] || return 0
    kill "$p" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$p" 2>/dev/null
    wait "$p" 2>/dev/null
    return 0
}
cleanup() {
    stop_pid "$qs_pid"; qs_pid=""
    stop_pid "$comp_pid"; comp_pid=""
    rm -f "$root/.lock-file-test.qml"
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

# ── the fakes ────────────────────────────────────────────────────────────────
mkdir -p "$W/bin"
cat > "$W/bin/loginctl" <<'FAKE'
#!/usr/bin/env bash
printf 'loginctl %s\n' "$*" >> "$HINT_LOG"
echo "3"
FAKE
cat > "$W/bin/busctl" <<'FAKE'
#!/usr/bin/env bash
printf 'busctl %s\n' "$*" >> "$HINT_LOG"
case "$*" in *GetSession*) printf 'o "/org/freedesktop/login1/session/_33"\n' ;; esac
exit 0
FAKE
cat > "$W/bin/_stub" <<'FAKE'
#!/usr/bin/env bash
case "$*" in *json*) echo "{}" ;; esac
exit 0
FAKE
chmod +x "$W/bin/loginctl" "$W/bin/busctl" "$W/bin/_stub"
for n in rime hyprctl wlr-randr niri matugen xdg-open playerctl wpctl \
         brightnessctl pkcheck notify-send swww hypridle grim; do
    ln -sf "$W/bin/_stub" "$W/bin/$n"
done
export PATH="$W/bin:$PATH"

real_home="$(getent passwd "$(id -u)" | cut -d: -f6)"
unset WAYLAND_DISPLAY DISPLAY HYPRLAND_INSTANCE_SIGNATURE NIRI_SOCKET
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
export XDG_SESSION_TYPE=wayland QT_QPA_PLATFORM=wayland
LF_UID="$(id -u)"
export LF_UID
# Fedora gives a user with a private group umask 002. A file the Shell makes
# without setting its mode is then 0664, which the daemon refuses: the mode
# checks below only mean something under it.
umask 002

# ── one suite: a fresh runtime dir, compositor and logind log ───────────────
# suite <tree> <scenario>... — prints the runs' lines; sets SUITE_PASS,
# SUITE_FAIL, SUITE_BROKE.
suite() {
    local tree="$1"; shift
    local S; S="$(mktemp -d "$W/suite.XXXX")"
    export XDG_RUNTIME_DIR="$S/run" HOME="$S/home"
    export XDG_STATE_HOME="$S/state" XDG_CONFIG_HOME="$S/config" XDG_CACHE_HOME="$S/cache"
    mkdir -p "$XDG_RUNTIME_DIR" "$HOME/.config/rime-shell/src/user_data" "$HOME/.local/share" \
             "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
    chmod 0700 "$XDG_RUNTIME_DIR"
    ln -sfn "$real_home/.local/share/fonts" "$HOME/.local/share/fonts" 2>/dev/null
    export HINT_LOG="$S/calls.log"; : > "$HINT_LOG"
    SUITE_PASS=0; SUITE_FAIL=0; SUITE_BROKE=0

    mkdir -p "$S/labwc/labwc"
    cp "$here/labwc-test-rc.xml" "$S/labwc/labwc/rc.xml" 2>/dev/null || true
    XDG_CONFIG_HOME="$S/labwc" labwc > "$S/comp.log" 2>&1 &
    comp_pid=$!
    local sock=""
    for _ in $(seq 1 60); do
        for f in "$XDG_RUNTIME_DIR"/wayland-*; do
            [[ -S "$f" ]] || continue
            case "${f##*/wayland-}" in '' | *[!0-9]*) continue ;; esac
            sock="${f##*/}"; break
        done
        [[ -n "$sock" ]] && break
        sleep 0.25
    done
    if [[ -z "$sock" ]]; then
        echo "SKIP: labwc did not come up headless"; tail -5 "$S/comp.log"
        stop_pid "$comp_pid"; comp_pid=""
        exit 0
    fi
    export WAYLAND_DISPLAY="$sock"
    [[ -S "$XDG_RUNTIME_DIR/$WAYLAND_DISPLAY" ]] || { echo "FAIL: the socket is not in the private runtime dir"; exit 1; }

    local sc out log
    for sc in "$@"; do
        log="$S/qs-$sc.log"
        # Each Shell process reads only its own words to logind.
        [[ -s "$HINT_LOG" ]] && mv "$HINT_LOG" "$S/calls-before-$sc.log"
        : > "$HINT_LOG"
        ( cd "$tree" && exec env LF_SCENARIO="$sc" quickshell -p "$tree/.lock-file-test.qml" ) > "$log" 2>&1 &
        qs_pid=$!
        if [[ "$sc" == hold ]]; then
            for _ in $(seq 1 240); do
                grep -q "lock-file: holding" "$log" && break
                kill -0 "$qs_pid" 2>/dev/null || break
                sleep 0.25
            done
            # SIGTERM while locked: what a service manager does.
            kill -TERM "$qs_pid" 2>/dev/null
        else
            for _ in $(seq 1 720); do kill -0 "$qs_pid" 2>/dev/null || break; sleep 0.25; done
            # A reload mid-lock ends the process; LockKeeper's relauncher starts
            # the Shell again, writing to the same log. Wait for that one too.
            if grep -q "lock-file: reloading mid-lock" "$log"; then
                for _ in $(seq 1 720); do
                    grep -q "lock-file: passed=" "$log" && break
                    sleep 0.25
                done
                sleep 1
            fi
        fi
        stop_pid "$qs_pid"; qs_pid=""
        # Every Shell process of this run, by the pid it printed (checked
        # against its command line: never a stranger's pid).
        local p
        for p in $(sed -n 's/.*lock-file: pid \([0-9]*\).*/\1/p' "$log"); do
            { tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null | grep -qF "$tree/.lock-file-test.qml" && stop_pid "$p"
        done
        out="$(sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*WARN qml: //' "$log")"
        echo "── $sc"
        printf '%s\n' "$out" | grep -E "^( *PASS| *FAIL| *note:|lock-file:)" || true
        if [[ "$out" == *"Failed to load configuration"* ]]; then
            printf '%s\n' "$out" | tail -20
            SUITE_BROKE=1; continue
        fi
        local summary
        summary="$(printf '%s\n' "$out" | grep -o 'lock-file: passed=[0-9]* failed=[0-9]*' | tail -1)"
        if [[ -z "$summary" ]]; then
            printf '%s\n' "$out" | tail -20
            echo "  (the $sc run did not report)"
            SUITE_BROKE=1; continue
        fi
        local p="${summary#*passed=}"; p="${p%% *}"
        local fl="${summary##*failed=}"
        SUITE_PASS=$((SUITE_PASS + p)); SUITE_FAIL=$((SUITE_FAIL + fl))
    done
    stop_pid "$comp_pid"; comp_pid=""
    return 0
}

stage() {   # stage <tree> — the test QML at the tree's root
    cp "$here/lock-file-test.qml" "$1/.lock-file-test.qml"
}

# ── the real tree ────────────────────────────────────────────────────────────
stage "$root"
echo "== the shipped tree"
suite "$root" main hold after-restart direct
real_pass=$SUITE_PASS real_fail=$SUITE_FAIL real_broke=$SUITE_BROKE
rm -f "$root/.lock-file-test.qml"
if [[ "$real_broke" -ne 0 || "$real_fail" -ne 0 || "$real_pass" -lt 40 ]]; then
    echo
    echo "RESULT: lock-file: passed=$real_pass failed=$real_fail broke=$real_broke — the shipped tree fails"
    exit 1
fi

[[ "${LOCK_FILE_TEST_NO_MUTANTS:-0}" == 1 ]] && {
    echo; echo "RESULT: lock-file: passed=$real_pass failed=0 (mutants skipped)"; exit 0; }

# ── mutants: each must make the suite fail ──────────────────────────────────
echo
echo "== mutants (each must fail)"
killed=0; survived=0; unapplied=0
mutant() {   # mutant <label> <file> <old> <new> <scenario>...
    local label="$1" file="$2" old="$3" new="$4"; shift 4
    local M; M="$(mktemp -d "$W/mut.XXXX")"
    cp -r "$root/src" "$M/src"
    if ! python3 - "$M/$file" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1: sys.exit(3)
open(p, "w").write(s.replace(old, new, 1))
PY
    then echo "  FAIL  mutant '$label': the mutation did not apply"; unapplied=$((unapplied + 1)); return; fi
    stage "$M"
    suite "$M" "$@" > "$M/out.txt" 2>&1
    if [[ "$SUITE_BROKE" -ne 0 || "$SUITE_FAIL" -ne 0 ]]; then
        echo "  PASS  mutant '$label': killed ($SUITE_FAIL failed$( [[ $SUITE_BROKE -ne 0 ]] && echo ", a run broke"))"
        grep -E "^ *FAIL" "$M/out.txt" | head -3 | sed 's/^/          /'
        killed=$((killed + 1))
    else
        echo "  FAIL  mutant '$label': SURVIVED ($SUITE_PASS passed)"
        survived=$((survived + 1))
    fi
}

mutant "ordering swapped: the file is written after the compositor is asked" \
    src/state/LockState.qml \
    "        root.lockStarting()
        if (root.locked" "        if (root.locked" main
mutant "a reload or restart writes unlocked" \
    src/services/system/LockFileService.qml \
    "root.sticky = !root._startsUnlocked()" "root.sticky = false" main hold after-restart
mutant "non-atomic write" \
    src/services/system/LockFileService.qml \
    "atomicWrites: true" "atomicWrites: false" main
mutant "wrong mode: the file is left as the umask made it" \
    src/services/system/LockFileService.qml \
    "\"[ -f \\\"\$f\\\" ] && [ ! -L \\\"\$f\\\" ] && chmod 600 -- \\\"\$f\\\"\"," "\"true\"," main
mutant "wrong mode: 0644" \
    src/services/system/LockFileService.qml \
    "&& chmod 600 -- \\\"\$f\\\"\"," "&& chmod 644 -- \\\"\$f\\\"\"," main
mutant "the file ignores the session lock (secure)" \
    src/services/system/LockFileService.qml \
    "                                   || LockState.lockSecure !== false" "" main direct
mutant "logind told unlocked at a restart mid-lock" \
    src/windows/Lockscreen.qml \
    "        LockedHintService.setLocked(sessionLock.secure || LockFileService.sticky)
    }" \
    "        LockedHintService.setLocked(sessionLock.secure)
    }" hold after-restart

echo
echo "shipped tree: passed=$real_pass failed=0; mutants: killed=$killed survived=$survived not-applied=$unapplied"
if [[ "$survived" -ne 0 || "$unapplied" -ne 0 ]]; then
    echo "RESULT: lock-file: a mutant survived or did not apply"
    exit 1
fi
echo "RESULT: lock-file: passed=$real_pass failed=0, $killed mutants killed — the file says locked before the"
echo "        compositor is asked, unlocked only once the session lock is gone (secure false), 0600 by"
echo "        rename, and stays locked across a reload or a restart mid-lock"
