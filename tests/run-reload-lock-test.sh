#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/reload-lock-test.qml — a reload or a restart never unlocks.
#
#  Quickshell 0.3.2 hands a reloaded generation the old generation's session
#  lock, and a new generation that does not want it at that moment releases it
#  (ext_session_lock_v1.unlock_and_destroy): any configuration reload while the
#  screen was locked unlocked the session with no password. LockKeeper
#  (src/services/system/LockKeeper.qml) closes that; this drives it for real.
#
#  Each scenario gets its own headless labwc and private runtime dir, and runs
#  THREE clients on it: the test Shell (the shipped Lockscreen, LockState,
#  LockKeeper, LockFileService), an out-of-process probe window with a focused
#  text field (tests/reload-lock-probe.qml), and a virtual keyboard (wtype)
#  typing letters at whatever has focus for the whole run. Never Return: the
#  lock screen starts a PAM conversation only on Enter, and the unlock here is
#  Lockscreen.release(), what PAM success calls.
#
#  Proved, from the probe's side (what a normal client was given):
#   * not one letter reaches the probe, and it never becomes the active window,
#     from the moment the lock is acknowledged until the authenticated release,
#     through each of: a raw Quickshell.reload(false) and reload(true) while
#     locked (a, which ends the process: the Shell is started again and locks at
#     once), the hot reload of a changed file (b, which must not happen at all
#     while locked, and happens once after the unlock), a reload asked for
#     through LockKeeper.reload() (deferred the same way), a raw reload while the
#     lock waits for its picture and just after the lock was sent (c), a raw and
#     a requested reload while the accepted password's release is running (d:
#     the raw one comes back to a password prompt, not locked forever), a Shell
#     killed while locked and started again (e);
#   * letters DO reach the probe before the lock and after the release
#     (positive controls: the keyboard and the focus work);
#   * from the Shell's side: `secure` sampled every 10 ms never drops while the
#     lock must hold; a held record from another compositor instance never
#     locks;
#   * rime-shell-relaunch.sh waits for the exact process (pid + start time),
#     never starts a second Shell, and does nothing for a process still running
#     after its deadline.
#  Then the core of the fix is broken on a copy of the tree, a mutant at a time,
#  and each must fail.
#
#  Skips cleanly (status 0) without quickshell, labwc or wtype.
#  Run from the repository root: ./tests/run-reload-lock-test.sh
#  RELOAD_LOCK_TEST_NO_MUTANTS=1 skips the mutants; RELOAD_LOCK_TEST_ONLY="soft hard"
#  runs only those scenarios (no mutants).
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
relaunch_rel="src/scripts/rime-shell-relaunch.sh"

for f in src/services/system/LockKeeper.qml src/windows/Lockscreen.qml src/state/LockState.qml "$relaunch_rel"; do
    [[ -f "$root/$f" ]] || { echo "FAIL: this tree has no $f"; exit 1; }
done

W="$(mktemp -d /tmp/rlt.XXXXXX)"
pids=()            # everything this run started, killed by pid
comp_pid=""
cleanup_tree() {   # cleanup_tree <tree> — relaunchers for that tree first, then the rest
    local tree="$1" p a
    for p in /proc/[0-9]*; do
        a="$( { tr '\0' '\n' < "$p/cmdline"; } 2>/dev/null | sed -n 2p)"
        [[ "$a" == "$tree/$relaunch_rel" ]] && kill -9 "${p#/proc/}" 2>/dev/null
    done
    return 0
}
stop_pid() {
    local p="$1"
    [[ -n "$p" ]] || return 0
    kill "$p" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$p" 2>/dev/null || break; sleep 0.1; done
    kill -9 "$p" 2>/dev/null
    wait "$p" 2>/dev/null
    return 0
}
# A pid printed by a test Shell is killed only if it is still that Shell.
stop_shell_pid() {
    local p="$1" tree="$2"
    [[ "$p" =~ ^[0-9]+$ ]] || return 0
    { tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null | grep -qF "$tree/.reload-lock-test.qml" || return 0
    stop_pid "$p"
}
cleanup() {
    local p
    for p in "${pids[@]}"; do stop_pid "$p"; done
    pids=()
    stop_pid "$comp_pid"; comp_pid=""
    rm -f "$root/.reload-lock-test.qml"
    cleanup_tree "$root"
    rm -rf "$W"
    return 0
}
trap cleanup EXIT INT TERM

# ── rime-shell-relaunch.sh on its own (no compositor needed) ────────────────
starttime() { local s; s="$(cat "/proc/$1/stat")"; s="${s##*) }"; set -- $s; shift 19; echo "$1"; }
rpass=0; rfail=0
rok()  { echo "  PASS  relaunch: $1"; rpass=$((rpass + 1)); }
rbad() { echo "  FAIL  relaunch: $1"; rfail=$((rfail + 1)); }
relaunch_suite() {   # relaunch_suite <script> — sets RS_FAIL
    local script="$1" out="$W/relaunch-out" t0 t1 te p st r
    local before=$rfail
    # 1. waits for the process to end, then starts the command
    rm -f "$out"; sleep 0.6 & p=$!; st="$(starttime "$p")"
    sh "$script" "$p" "$st" sh -c 'date +%s%N > "$1"' sh "$out" & r=$!
    wait "$p"; te="$(date +%s%N)"
    wait "$r"
    if [[ -s "$out" ]] && (( $(cat "$out") >= te - 5000000 )); then rok "starts the Shell only after the process ended"
    else rbad "started before the process ended (or never)"; fi
    # 2. a recycled pid (another start time) is not waited on
    rm -f "$out"; sleep 5 & p=$!
    t0="$(date +%s%N)"
    sh "$script" "$p" "999999999999" sh -c 'date +%s%N > "$1"' sh "$out"
    t1="$(cat "$out" 2>/dev/null || echo 0)"
    stop_pid "$p"
    if (( t1 > 0 && t1 - t0 < 1000000000 )); then rok "a recycled pid is not waited on"
    else rbad "waited on a pid with another start time"; fi
    # 3. bad arguments start nothing
    rm -f "$out"
    sh "$script" "x1" "1" sh -c 'echo ran > "$1"' sh "$out"; r=$?
    if [[ "$r" -eq 2 && ! -e "$out" ]]; then rok "refuses a malformed pid"; else rbad "ran with a malformed pid (rc $r)"; fi
    sh "$script" "$$" 2>/dev/null; r=$?
    [[ "$r" -eq 2 ]] && rok "refuses a missing command" || rbad "missing command gave rc $r"
    # 4. a process still running after the deadline: nothing is started
    if [[ "${RELAUNCH_QUICK:-0}" != 1 ]]; then
        rm -f "$out"; sleep 13 & p=$!; st="$(starttime "$p")"
        t0="$(date +%s)"
        sh "$script" "$p" "$st" sh -c 'echo ran > "$1"' sh "$out"
        t1="$(date +%s)"
        stop_pid "$p"
        if [[ ! -e "$out" ]] && (( t1 - t0 >= 9 )); then rok "a process still running after 10 s: nothing started, no second Shell"
        else rbad "started a second Shell beside a running one (or gave up early: $((t1 - t0)) s)"; fi
    fi
    RS_FAIL=$((rfail - before))
}
echo "== rime-shell-relaunch.sh"
relaunch_suite "$root/$relaunch_rel"
# Its mutant: a relauncher that does not wait.
cp "$root/$relaunch_rel" "$W/relaunch-mutant.sh"
sed -i 's/^while running; do$/while false; do/' "$W/relaunch-mutant.sh"
if cmp -s "$root/$relaunch_rel" "$W/relaunch-mutant.sh"; then
    rbad "mutant 'the relauncher does not wait' did not apply"
else
    saved_pass=$rpass saved_fail=$rfail
    RELAUNCH_QUICK=1 relaunch_suite "$W/relaunch-mutant.sh" > "$W/relaunch-mutant.out" 2>&1
    rpass=$saved_pass rfail=$saved_fail
    if [[ "$RS_FAIL" -gt 0 ]]; then rok "mutant 'the relauncher does not wait': killed"
    else rbad "mutant 'the relauncher does not wait': SURVIVED"; fi
fi

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed (relaunch: passed=$rpass failed=$rfail)"; [[ $rfail -eq 0 ]]; exit; }
command -v labwc >/dev/null 2>&1 || { echo "SKIP: no labwc to host the test (relaunch: passed=$rpass failed=$rfail)"; [[ $rfail -eq 0 ]]; exit; }
command -v wtype >/dev/null 2>&1 || { echo "SKIP: no wtype to type at the probe (relaunch: passed=$rpass failed=$rfail)"; [[ $rfail -eq 0 ]]; exit; }

# ── the fakes ────────────────────────────────────────────────────────────────
mkdir -p "$W/bin"
cat > "$W/bin/loginctl" <<'FAKE'
#!/usr/bin/env bash
echo "3"
FAKE
cat > "$W/bin/busctl" <<'FAKE'
#!/usr/bin/env bash
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
unset WAYLAND_DISPLAY DISPLAY HYPRLAND_INSTANCE_SIGNATURE NIRI_SOCKET SWAYSOCK
export WLR_BACKENDS=headless WLR_LIBINPUT_NO_DEVICES=1 WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
export XDG_SESSION_TYPE=wayland QT_QPA_PLATFORM=wayland
cp "$here/reload-lock-probe.qml" "$W/probe.qml"

# ── one scenario ────────────────────────────────────────────────────────────
# scenario <tree> <name> — prints its lines; adds to SUITE_PASS/SUITE_FAIL/SUITE_BROKE.
scenario() {
    local tree="$1" sc="$2"
    local S; S="$(mktemp -d "$W/sc.XXXX")"
    export XDG_RUNTIME_DIR="$S/run" HOME="$S/home" RL_DIR="$S" RL_SCENARIO="$sc"
    export XDG_STATE_HOME="$S/state" XDG_CONFIG_HOME="$S/config" XDG_CACHE_HOME="$S/cache"
    mkdir -p "$XDG_RUNTIME_DIR" "$HOME/.config/rime-shell/src/user_data" "$HOME/.local/share" \
             "$XDG_STATE_HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
    chmod 0700 "$XDG_RUNTIME_DIR"
    ln -sfn "$real_home/.local/share/fonts" "$HOME/.local/share/fonts" 2>/dev/null

    mkdir -p "$S/labwc/labwc"
    cp "$here/labwc-test-rc.xml" "$S/labwc/labwc/rc.xml" 2>/dev/null || true
    XDG_CONFIG_HOME="$S/labwc" labwc -d > "$S/comp.log" 2>&1 &
    comp_pid=$!
    local sock="" f
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
        stop_pid "$comp_pid"; comp_pid=""; exit 0
    fi
    export WAYLAND_DISPLAY="$sock"
    # What labwc exports to its clients, so LockKeeper keys its record the same
    # way it would under labwc's autostart.
    export LABWC_PID="$comp_pid"

    if [[ "$sc" == foreign ]]; then
        mkdir -p "$XDG_RUNTIME_DIR/rime-shell"
        printf '{"held":true,"engaged":true,"pid":1,"compositor":"LABWC_PID=1;WAYLAND_DISPLAY=%s"}\n' "$sock" \
            > "$XDG_RUNTIME_DIR/rime-shell/lock-held.json"
    fi

    # The probe, then the keyboard, then (once the probe has letters) the Shell.
    quickshell -p "$W/probe.qml" > "$S/probe.log" 2>&1 &
    local probe_pid=$!; pids+=("$probe_pid")
    for _ in $(seq 1 80); do grep -q "PROBE .* up" "$S/probe.log" && break; sleep 0.1; done
    local keys=()
    for _ in $(seq 1 50); do keys+=(-s 40 x); done
    (
        trap 'kill "$w" 2>/dev/null; exit 0' TERM
        while :; do wtype -k Shift_L "${keys[@]}" 2>/dev/null & w=$!; wait "$w"; done
    ) &
    local kb_pid=$!; pids+=("$kb_pid")
    for _ in $(seq 1 50); do grep -q "PROBE .* key" "$S/probe.log" && break; sleep 0.1; done

    local log="$S/shell.log"
    ( cd "$tree" && exec env ${RL_WAYLAND_DEBUG:+WAYLAND_DEBUG=1} quickshell -p "$tree/.reload-lock-test.qml" ) > "$log" 2>&1 &
    local qs_pid=$!; pids+=("$qs_pid")
    local i killed_once=""
    for i in $(seq 1 400); do
        grep -q "^ *WARN qml: RL [0-9]* done" "$log" 2>/dev/null && break
        if [[ "$sc" == restart && -z "$killed_once" ]] && grep -q "mark holding" "$log" && kill -0 "$qs_pid" 2>/dev/null; then
            killed_once=1
            sleep 0.5
            echo "RL $(date +%s%3N) runner: kill -9 the locked Shell (pid $qs_pid)" >> "$log"
            kill -9 "$qs_pid" 2>/dev/null; wait "$qs_pid" 2>/dev/null
            sleep 1
            ( cd "$tree" && exec env RL_LEG=2 quickshell -p "$tree/.reload-lock-test.qml" ) >> "$log" 2>&1 &
            qs_pid=$!; pids+=("$qs_pid")
        fi
        sleep 0.1
    done
    sleep 0.5
    # Every Shell process this run made, relaunched ones included.
    local p
    cleanup_tree "$tree"
    for p in $(sed -n 's/.*RL [0-9]* pid \([0-9]*\).*/\1/p' "$log"); do stop_shell_pid "$p" "$tree"; done
    for p in "${pids[@]}"; do stop_pid "$p"; done
    pids=()
    stop_pid "$comp_pid"; comp_pid=""
    [[ -n "${RL_KEEP:-}" ]] && cp -r "$S" "$RL_KEEP/$sc.$(date +%s)"

    echo "── $sc"
    python3 - "$sc" "$log" "$S/probe.log" "$S/comp.log" <<'PY'
import re, sys
sc, logp, probep, compp = sys.argv[1:5]
clean = lambda s: re.sub(r'\x1b\[[0-9;]*m', '', s)
log = [clean(l).rstrip("\n") for l in open(logp, errors="replace")]
probe = [clean(l) for l in open(probep, errors="replace")]
comp = open(compp, errors="replace").read()
lines = [re.sub(r'^\s*WARN qml: ', '', l) for l in log]
for l in lines:
    if re.match(r'^ *(PASS|FAIL|note:)', l): print(l)
p = sum(1 for l in lines if re.match(r'^ *PASS', l))
f = sum(1 for l in lines if re.match(r'^ *FAIL', l))
done = any(re.match(r'^RL \d+ done', l) for l in lines)
def marks(name):
    return [int(m.group(1)) for l in lines for m in [re.match(r'^RL (\d+) mark ' + name + r'\b', l)] if m]
keys = [int(m.group(1)) for l in probe for m in [re.search(r'PROBE (\d+) key', l)] if m]
active = [(int(m.group(1)), m.group(2)) for l in probe for m in [re.search(r'PROBE (\d+) active (\w+)', l)] if m]
def ok(w): global p; p += 1; print("  PASS  " + sc + ": " + w)
def bad(w): global f; f += 1; print("  FAIL  " + sc + ": " + w)
lock = marks("lock"); locked = marks("locked"); released = marks("released")
if sc == "foreign":
    d = [int(m.group(1)) for l in lines for m in [re.match(r'^RL (\d+) done', l)] if m]
    if d and any(d[0] - 1500 <= k <= d[0] for k in keys): ok("letters still reach the probe (no lock)")
    else: bad("letters stopped reaching the probe")
elif lock and locked and released:
    t0, t1, t2, t3 = lock[0], locked[0], released[-1], locked[0] + 150
    if any(k < t0 for k in keys): ok("positive control: letters reached the probe before the lock")
    else: bad("no letter reached the probe before the lock (the probe proves nothing)")
    leaked = [k for k in keys if t3 < k < t2]
    if not leaked: ok("not one letter reached the probe from the lock until the authenticated release (%.1f s)" % ((t2 - t3) / 1000))
    else: bad("%d letters reached the probe while the session had to be locked (first %d ms after the lock)" % (len(leaked), leaked[0] - t1))
    act = [a for a in active if t3 < a[0] < t2 and a[1] == "true"]
    if not act: ok("the probe never became the active window while locked")
    else: bad("the probe became the active window while locked (%d ms after the lock)" % (act[0][0] - t1))
    if any(k > t2 for k in keys): ok("positive control: letters reached the probe after the release")
    else: bad("no letter reached the probe after the release (focus did not come back)")
    if t1 - t0 > 300 or sc == "capture-raw":
        print("  note: %s: the lock was acknowledged %d ms after it was asked for" % (sc, t1 - t0))
    if sc == "capture-raw":
        early = [k for k in keys if t0 < k <= t3]
        print("  note: %s: %d letters reached the probe between the lock request and the lock (no lock had been sent yet)"
              % (sc, len(early)))
    if "replacing abandoned lock" in comp: print("  note: %s: labwc: replacing abandoned lock" % sc)
else:
    bad("the run never reached the lock and the authenticated release (lock=%s locked=%s released=%s)" % (bool(lock), bool(locked), bool(released)))
if not done: bad("the run did not finish")
print("SCENARIO %s passed=%d failed=%d" % (sc, p, f))
PY
    return 0
}

suite() {   # suite <tree> <scenario>... — sets SUITE_PASS SUITE_FAIL
    local tree="$1"; shift
    SUITE_PASS=0; SUITE_FAIL=0
    local sc out
    for sc in "$@"; do
        out="$(scenario "$tree" "$sc")"
        printf '%s\n' "$out"
        local s; s="$(printf '%s\n' "$out" | grep -o 'SCENARIO [a-z-]* passed=[0-9]* failed=[0-9]*' | tail -1)"
        if [[ -z "$s" ]]; then SUITE_FAIL=$((SUITE_FAIL + 1)); continue; fi
        local pp="${s#*passed=}"; pp="${pp%% *}"
        SUITE_PASS=$((SUITE_PASS + pp)); SUITE_FAIL=$((SUITE_FAIL + ${s##*failed=}))
    done
}
stage() { cp "$here/reload-lock-test.qml" "$1/.reload-lock-test.qml"; }

all_scenarios=(soft hard files request capture capture-raw engage unlocking unlocking-request restart foreign)
if [[ -n "${RELOAD_LOCK_TEST_ONLY:-}" ]]; then
    read -r -a all_scenarios <<<"$RELOAD_LOCK_TEST_ONLY"
fi

stage "$root"
echo "== the shipped tree"
suite "$root" "${all_scenarios[@]}"
real_pass=$SUITE_PASS real_fail=$SUITE_FAIL
rm -f "$root/.reload-lock-test.qml"
if [[ "$real_fail" -ne 0 || "$rfail" -ne 0 || "$real_pass" -lt $((${#all_scenarios[@]} * 4)) ]]; then
    echo
    echo "RESULT: reload-lock: passed=$real_pass failed=$real_fail (relaunch failed=$rfail) — the shipped tree fails"
    exit 1
fi
[[ "${RELOAD_LOCK_TEST_NO_MUTANTS:-0}" == 1 || -n "${RELOAD_LOCK_TEST_ONLY:-}" ]] && {
    echo; echo "RESULT: reload-lock: passed=$((real_pass + rpass)) failed=0 (mutants skipped)"; exit 0; }

# ── mutants: each must make the suite fail ──────────────────────────────────
echo
echo "== mutants (each must fail)"
killed=0; survived=0; unapplied=0
mutant() {   # mutant <label> "<scenario>..." <file> <old> <new> [<file> <old> <new>]...
    local label="$1" scs="$2"; shift 2
    local M; M="$(mktemp -d "$W/mut.XXXX")"
    cp -r "$root/src" "$M/src"
    while [[ $# -ge 3 ]]; do
        if ! python3 - "$M/$1" "$2" "$3" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1: sys.exit(3)
open(p, "w").write(s.replace(old, new, 1))
PY
        then echo "  FAIL  mutant '$label': the mutation did not apply ($1)"; unapplied=$((unapplied + 1)); return; fi
        shift 3
    done
    stage "$M"
    local -a list; read -r -a list <<<"$scs"
    suite "$M" "${list[@]}" > "$M/out.txt" 2>&1
    cleanup_tree "$M"
    if [[ "$SUITE_FAIL" -ne 0 ]]; then
        echo "  PASS  mutant '$label': killed ($SUITE_FAIL failed)"
        grep -E "^ *FAIL" "$M/out.txt" | head -3 | sed 's/^/          /'
        killed=$((killed + 1))
    else
        echo "  FAIL  mutant '$label': SURVIVED ($SUITE_PASS passed)"
        survived=$((survived + 1))
    fi
}
K=src/services/system/LockKeeper.qml
mutant "a reloaded or restarted Shell does not take the lock back (today's Shell)" "soft hard restart" \
    "$K" "if (rec === null || rec.held !== true || rec.compositor !== root.compositor) return" "return"
mutant "nothing starts the Shell again after the reload ended it" "soft unlocking" \
    "$K" "            root._relaunchAfterExit()
" ""
mutant "the lock is taken back after the handover, not before it" "soft engage" \
    "$K" "if (rec.engaged !== true) {" "if (true) {"
mutant "the file watcher stays on while locked" "files" \
    "$K" "            Quickshell.watchFiles = false
" "" \
    "$K" "if (root.holding && Quickshell.watchFiles) Quickshell.watchFiles = false" ""
mutant "LockKeeper.reload() does not wait for the unlock" "request unlocking-request" \
    "$K" "    function reload(hard) {
        if (root.holding) {" "    function reload(hard) {
        if (false) {"
mutant "nothing reloads after the unlock" "files request" \
    "$K" "        root._after.restart()
" ""
mutant "the record is honoured on any compositor" "foreign" \
    "$K" " || rec.compositor !== root.compositor) return" ") return"

echo
total_pass=$((real_pass + rpass))
echo "shipped tree: passed=$total_pass failed=0; mutants: killed=$killed survived=$survived not-applied=$unapplied"
if [[ "$survived" -ne 0 || "$unapplied" -ne 0 ]]; then
    echo "RESULT: reload-lock: a mutant survived or did not apply"
    exit 1
fi
echo "RESULT: reload-lock: passed=$total_pass failed=0, $((killed + 1)) mutants killed — no reload or restart while"
echo "        locked lets a normal window have focus or input before the authenticated release"
