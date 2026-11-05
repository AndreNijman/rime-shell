#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  mutate-focus-mode.sh — prove run-focus-mode-test.sh can go red.
#
#  Each mutant breaks ONE thing the suite claims, in a copy of the tree (the
#  worktree is never edited), and the named assertion must fail:
#
#    not-routed      the focus-toggle target does not reach FocusMode (what
#                    happened before: a signal only QuickSettings heard, and
#                    QuickSettings is built with the dashboard)
#                    → "the first press did nothing"
#    drop-press      a press while the gaps settle is dropped again
#                    → "no sign of the second press", "a press was dropped"
#    no-deadline     a gaps read that never answers holds every later press
#                    → "a read that never answers held Focus Mode"
#    restore-always  turning Focus Mode off writes the saved gaps even when it
#                    never shrank them → "restored gaps it never shrunk"
#
#  A mutant whose sed changed nothing is reported NOT APPLIED and fails the run,
#  as does a suite that printed no RESULT line (a crash is not a catch).
#  Logs: $MUTATE_LOG_DIR (default: a temp dir), one file per mutant.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
logs="${MUTATE_LOG_DIR:-$(mktemp -d)}"; mkdir -p "$logs"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT

caught=0; survived=0; broken=0

# mutant <name> <expect-regex> <file> <sed-expr>
mutant() {
    local name="$1" expect="$2" file="$3" expr="$4" tree="$work/$1"
    mkdir -p "$tree"
    (cd "$root" && git ls-files -co --exclude-standard -z | xargs -0 cp --parents -t "$tree")
    cp "$tree/$file" "$tree/$file.orig"
    sed -i -E "$expr" "$tree/$file"
    if cmp -s "$tree/$file" "$tree/$file.orig"; then
        echo "NOT APPLIED  $name ($file unchanged)"; broken=$((broken + 1)); return
    fi
    rm -f "$tree/$file.orig"
    bash "$tree/tests/run-focus-mode-test.sh" > "$logs/mutant-$name.log" 2>&1
    local r; r="$(grep -E '^RESULT:' "$logs/mutant-$name.log" | tail -1)"
    if [ -z "$r" ]; then
        echo "CRASHED      $name (no RESULT line; see $logs/mutant-$name.log)"; broken=$((broken + 1))
    elif grep -E "FAIL .*($expect)" "$logs/mutant-$name.log" >/dev/null; then
        echo "CAUGHT       $name: $(grep -E "FAIL .*($expect)" "$logs/mutant-$name.log" | head -1 | sed 's/^ *//')"
        caught=$((caught + 1))
    else
        echo "SURVIVED     $name ($r)"; survived=$((survived + 1))
    fi
}

mutant not-routed "the first press did nothing" \
    src/state/IpcManager.qml 's/^( +)FocusMode\.toggle\(\)$/\1void 0/'
mutant drop-press "no sign of the second press|a press was dropped" \
    src/state/FocusMode.qml 's/^( +)root\.queued = !root\.queued$/\1return/'
mutant no-deadline "a read that never answers held Focus Mode" \
    src/state/FocusMode.qml 's/interval: 3000/interval: 600000/'
mutant restore-always "restored gaps it never shrunk" \
    src/state/FocusMode.qml '/if \(!root\._shrunk\) return/d'

echo "mutate-focus-mode: caught=$caught survived=$survived broken=$broken (logs: $logs)"
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
