#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  motion-bench.sh — what an open/close costs, how smooth it is, and what the
#  shell costs at rest (the before/after table for perf/smooth-motion).
#
#      tests/visual/motion-bench.sh OUTDIR [cycles] [idle-seconds]
#
#  The whole shell runs in headless.sh's private labwc at 60 Hz, on the
#  integrated GPU (gles2 on the first render node, the iGPU on a hybrid
#  machine), with RIME_PACING_LOG=1. The shell AND the compositor are pinned to
#  BENCH_CPUS (default 16,17: two E-cores on a 12th-gen Intel) to stand in for a
#  laptop at low clocks, where a frame's CPU work is what decides whether it is
#  late.
#
#  Measured, per surface, over `cycles` open/close cycles (default 20):
#    frame time   every animation tick's interval during an open or a close
#                 (SurfaceLifecycle's pacing log, FrameAnimation.frameTime):
#                 p50/p95/p99, late (> 1.25 x 16.67 ms) and missed vsyncs
#                 (sum of round(interval / 16.67) - 1)
#    motion       open trigger -> the first frame presented after a spring left
#                 0: the input-to-motion latency (median, p95)
#    cpu/cycle    the shell's CPU time (all threads, /proc) per open+close
#  And once, with every surface closed AFTER each was opened once:
#    idle         `idle-seconds` (default 60) of the shell's CPU time and its
#                 context switches (every thread; a wakeup proxy), and the
#                 compositor's CPU time over the same window
#    swap-closed  frames a CLOSED surface's window presented while idle (must
#                 be 0; a kept window presents one 1x1 frame as it parks)
#    rss          VmRSS after warm-up and after the cycles
#
#  It cannot measure scan-out on a real panel, GPU power, or a real compositor's
#  frame clock: it is the A/B harness, not the verdict on a laptop. Run main
#  and a branch interleaved (A B A B) on a quiet machine and compare medians.
#
#  BENCH_SURFACES="dashboard network" limits the surfaces; BENCH_CPUS="0-19"
#  removes the pin. Writes OUTDIR/report.txt, OUTDIR/summary.json,
#  OUTDIR/pacing.log, OUTDIR/shell.log.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# BENCH_ROOT: the tree whose shell is measured (this script stays the same
# for an A/B of two trees).
root="$(cd "${BENCH_ROOT:-$here/../..}" && pwd)"
. "$root/tests/lib/headless.sh"
headless_require quickshell labwc python3 taskset

out="${1:-}"; [ -n "$out" ] || { echo "usage: $0 OUTDIR [cycles] [idle-seconds]"; exit 2; }
cycles="${2:-20}"
idle="${3:-60}"
cpus="${BENCH_CPUS:-16,17}"
mkdir -p "$out"; out="$(cd "$out" && pwd)"

headless_begin
ln -sf "$root/tests/lib/fake-nmcli" "$HEADLESS_W/bin/nmcli"
ln -sf "$root/tests/lib/fake-bluetoothctl" "$HEADLESS_W/bin/bluetoothctl"
ln -sf "$root/tests/lib/fake-brightnessctl" "$HEADLESS_W/bin/brightnessctl"
# The integrated GPU, for the compositor and (through Mesa's EGL) the shell.
node=""
for n in /dev/dri/renderD*; do
    [ -e "$n" ] || continue
    v="$(cat "/sys/class/drm/${n##*/}/device/vendor" 2>/dev/null)"
    case "$v" in 0x8086|0x1002) node="$n"; break ;; esac
done
[ -n "$node" ] || node="$(ls /dev/dri/renderD* 2>/dev/null | head -1)"
if [ -n "$node" ]; then
    export HEADLESS_WLR_RENDERER=gles2 WLR_RENDER_DRM_DEVICE="$node"
    [ -e /usr/share/glvnd/egl_vendor.d/50_mesa.json ] &&
        export __EGL_VENDOR_LIBRARY_FILENAMES=/usr/share/glvnd/egl_vendor.d/50_mesa.json
fi
headless_start labwc 1920x1080 || exit 0
comp_pid="${HEADLESS_COMP_PID:-}"
[ -n "$comp_pid" ] && taskset -a -p -c "$cpus" "$comp_pid" >/dev/null 2>&1
python3 "$root/tests/lib/fake-mpris.py" /dev/null & player=$!
qs=""
trap 'kill $player $qs 2>/dev/null; headless_cleanup' EXIT

ud="$HOME/.config/rime-shell/src/user_data"; mkdir -p "$ud"
printf '%s' '{"barEnabled":true,"animDuration":320,"motionScale":1,"dashboardWidth":900,"dashboardHeight":520}' > "$ud/settings.json"
printf '{"currentWall":"%s","mode":"dark"}' "$HEADLESS_WALLPAPER" > "$ud/wallpaper.json"
headless_rime_palette dark

log="$out/shell.log"
# Appending, so the bench's own markers (mark) interleave with the shell's lines.
: > "$log"
# No release page: the shell would open the booted release's notes in a
# browser on this compositor 8 s in, in the middle of the measurement.
env RIME_PACING_LOG=1 RIME_RELEASE_JSON=/nonexistent RIME_RELEASE_OPENER=/bin/false \
    taskset -c "$cpus" quickshell -p "$root/shell.qml" >> "$log" 2>&1 & qs=$!
for _ in $(seq 1 160); do grep -q "Configuration Loaded" "$log" && break; sleep 0.25; done
grep -q "Configuration Loaded" "$log" || { echo "FAIL: the shell did not load"; tail -20 "$log"; exit 1; }
sleep 5

ipc() { quickshell -p "$root/shell.qml" ipc call "$@" >/dev/null 2>&1; }
mark() { echo "Rime bench: $*" >> "$log"; }
# "<cpu ms> <context switches>" of a process, every thread (schedstat: ns).
sample() {
    python3 - "$1" <<'PY'
import os, sys
pid = sys.argv[1]
try:
    ns = cs = 0
    for t in os.listdir(f"/proc/{pid}/task"):
        ns += int(open(f"/proc/{pid}/task/{t}/schedstat").read().split()[0])
        for l in open(f"/proc/{pid}/task/{t}/status"):
            if l.startswith(("voluntary_ctxt_switches", "nonvoluntary_ctxt_switches")):
                cs += int(l.split()[1])
    print(ns // 1000000, cs)
except Exception:
    print("0 0")
PY
}
# Per thread "<tid> <cpu ns> <context switches>", to diff over threads alive
# at both ends (a thread that exits in between would subtract its count).
threads() {
    for t in /proc/"$1"/task/*; do
        printf '%s %s %s\n' "${t##*/}" "$(cut -d' ' -f1 "$t/schedstat" 2>/dev/null)" \
            "$(awk '/ctxt_switches/ { s += $2 } END { print s }' "$t/status" 2>/dev/null)"
    done
}
tdiff() {  # tdiff BEFORE AFTER -> "<cpu ms> <context switches>"
    awk 'NR == FNR { c[$1] = $2; s[$1] = $3; next }
         ($1 in c) { dc += $2 - c[$1]; ds += $3 - s[$1] }
         END { printf "%d %d\n", dc / 1000000, ds }' "$1" "$2"
}
rss() { awk '/^VmRSS/ { print $2 }' "/proc/$1/status" 2>/dev/null; }

# name | open | close
all=(
    "dashboard|dashboard-home toggle|dashboard-home toggle"
    "network|wifi-toggle toggle|wifi-toggle toggle"
    "notifications|notification-toggle toggle|notification-toggle toggle"
    "clipboard|clipboard-toggle toggle|clipboard-toggle toggle"
    "quick|quick-toggle toggle|quick-toggle toggle"
    "power|PowerMenu-toggle toggle|PowerMenu-toggle toggle"
    "wallpaper|wallpaper-toggle toggle|wallpaper-toggle toggle"
    "nexus|nexus open appearance|nexus close"
)
surfaces=()
for e in "${all[@]}"; do
    n="${e%%|*}"
    [ -z "${BENCH_SURFACES:-}" ] || [[ " $BENCH_SURFACES " == *" $n "* ]] || continue
    surfaces+=("$e")
done

# Warm-up: every surface once, so lazy pages are built and kept windows exist.
mark "warmup"
for e in "${surfaces[@]}"; do
    IFS='|' read -r name o c <<<"$e"
    ipc $o; sleep 1.5; ipc $c; sleep 1.5
done
sleep 3
rss0="$(rss "$qs")"

mark "idle-start"
threads "$qs" > "$out/.t0"; read -r k0 _ < <(sample "$comp_pid")
sleep "$idle"
threads "$qs" > "$out/.t1"; read -r k1 _ < <(sample "$comp_pid")
mark "idle-end"
read -r qd sd < <(tdiff "$out/.t0" "$out/.t1"); rm -f "$out/.t0" "$out/.t1"
printf 'idle\t%s\t%s\t%s\t%s\n' "$idle" "$qd" "$sd" "$((k1 - k0))" > "$out/idle.tsv"

: > "$out/cycles.tsv"
for e in "${surfaces[@]}"; do
    IFS='|' read -r name o c <<<"$e"
    mark "cycles $name"
    for i in $(seq 1 "$cycles"); do
        read -r a _ < <(sample "$qs")
        ipc $o; sleep 1.0; ipc $c; sleep 1.0
        read -r b _ < <(sample "$qs")
        printf '%s\t%s\t%s\n' "$name" "$i" "$((b - a))" >> "$out/cycles.tsv"
    done
done
rss1="$(rss "$qs")"
printf 'rss\t%s\t%s\n' "${rss0:-0}" "${rss1:-0}" > "$out/rss.tsv"

kill "$qs" "$player" 2>/dev/null; sleep 0.3
grep -aE 'Rime (pacing|bench):' "$log" | sed 's/.*Rime \(pacing\|bench\): /\1 /' > "$out/pacing.log"
grep -aE 'TypeError|ReferenceError|is not a type|Binding loop' "$log" | sort | uniq -c | head -5 > "$out/errors.txt"
headless_cleanup

python3 - "$out" "$cpus" <<'PY'
import sys, json, statistics, collections
out, cpus = sys.argv[1], sys.argv[2]
B = 1000 / 60
def pct(v, p):
    if not v: return float("nan")
    v = sorted(v); return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))]
section = "warmup"; rows = collections.defaultdict(lambda: {"iv": [], "motion": [], "first": [], "swaps": 0, "n": 0})
swap_closed = collections.Counter()
for line in open(f"{out}/pacing.log"):
    kind, rest = line.split(" ", 1)
    if kind == "bench":
        section = rest.strip(); continue
    parts = rest.split()
    if len(parts) >= 2 and parts[1] == "swap-closed":
        if section == "idle-start": swap_closed[parts[0]] += 1
        continue
    if not section.startswith("cycles ") or len(parts) < 3 or parts[1] not in ("Opening", "Closing"): continue
    kv = dict(p.split("=", 1) for p in parts[2:] if "=" in p)
    # Keyed by the surface the bench was cycling (its section) and the
    # lifecycle that logged: the network and notification panes share one.
    sec = section.split(" ", 1)[1]
    r = rows[(sec if sec == parts[0] else f"{sec}/{parts[0]}", parts[1])]
    r["n"] += 1
    r["iv"] += [float(x) for x in kv.get("iv", "").split(",") if x]
    r["swaps"] += int(kv.get("swaps", 0))
    if "motion" in kv and float(kv["motion"]) >= 0: r["motion"].append(float(kv["motion"]))
    r["first"].append(float(kv.get("first", -1)))
cyc = collections.defaultdict(list)
for l in open(f"{out}/cycles.tsv"):
    n, i, ms = l.split("\t"); cyc[n].append(int(ms))
idle = open(f"{out}/idle.tsv").read().split("\t")
rss = open(f"{out}/rss.tsv").read().split("\t")
summary = {"cpus": cpus, "idle_s": int(idle[1]), "idle_cpu_ms": int(idle[2]), "idle_ctxsw": int(idle[3]),
           "idle_comp_cpu_ms": int(idle[4]), "rss_kb_warm": int(rss[1]), "rss_kb_after": int(rss[2]),
           "swap_closed_idle": dict(swap_closed), "surfaces": {}}
lines = [f"motion bench — 60 Hz budget {B:.2f} ms, shell+compositor on CPUs {cpus}", ""]
lines.append(f"{'surface':26} {'phase':8} {'n':>3} {'p50':>6} {'p95':>6} {'p99':>6} {'late':>5} {'missed':>6} {'motion50':>8} {'motion95':>8} {'cpu/cyc':>8}")
for (name, ph), r in sorted(rows.items()):
    iv = r["iv"]
    late = sum(1 for x in iv if x > 1.25 * B)
    missed = sum(max(0, round(x / B) - 1) for x in iv)
    m50 = statistics.median(r["motion"]) if r["motion"] else float("nan")
    m95 = pct(r["motion"], 95)
    key = name.split("/")[0]
    c = statistics.median(cyc[key]) if cyc.get(key) else float("nan")
    s = summary["surfaces"].setdefault(name, {})
    s[ph] = {"n": r["n"], "frames": len(iv), "p50": pct(iv, 50), "p95": pct(iv, 95), "p99": pct(iv, 99),
             "late": late, "missed": missed, "motion_p50": m50, "motion_p95": m95}
    s["cpu_ms_per_cycle_median"] = c
    s["cpu_ms_per_cycle_mean"] = statistics.mean(cyc[key]) if cyc.get(key) else float("nan")
    lines.append(f"{name:26} {ph:8} {r['n']:>3} {pct(iv,50):>6.1f} {pct(iv,95):>6.1f} {pct(iv,99):>6.1f} {late:>5} {missed:>6} "
                 f"{(f'{m50:.0f}' if ph == 'Opening' else '-'):>8} {(f'{m95:.0f}' if ph == 'Opening' else '-'):>8} {c:>8.0f}")
lines += ["", f"idle {idle[1]} s, every surface closed: shell cpu {idle[2]} ms, context switches {idle[3]}, compositor cpu {idle[4]} ms",
          f"frames presented by a closed surface while idle: {sum(swap_closed.values())} {dict(swap_closed) or ''}",
          f"rss: {rss[1]} kB after warm-up, {rss[2].strip()} kB after the cycles"]
err = open(f"{out}/errors.txt").read().strip()
if err: lines += ["", "QML errors in the log:", err]
open(f"{out}/report.txt", "w").write("\n".join(lines) + "\n")
json.dump(summary, open(f"{out}/summary.json", "w"), indent=1)
print("\n".join(lines))
PY
