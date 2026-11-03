#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  mutate-settings-app.sh — prove run-settings-app-test.sh and
#  run-power-profile-service-test.sh can go red.
#
#  Each mutant breaks ONE thing the suites claim, in a copy of the tree (the
#  worktree is never edited), and the named assertion must fail:
#
#    app-id        QS_APP_ID dropped from bin/rime-settings
#                  → "one toplevel with app id org.rimeos.Settings" fails
#    duplicate     --no-duplicate and the IPC hand-over to a running app dropped
#                  → a second launch maps a second window
#    display-in    the Display page not marked shellOnly
#                  → Display is listed in the app and calls hyprctl/wlr-randr
#    no-fallback   PowerProfileService always takes the power-profiles path
#                  → the Rimed1 fallback assertions fail
#    polling       the 4 s Tier poll runs on the power-profiles path too
#                  → "exactly one busctl" / "Tier read 0 times" fail
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

# mutant <name> <suite> <expect-regex> <file> <sed-expr>
mutant() {
    local name="$1" suite="$2" expect="$3" file="$4" expr="$5" tree="$work/$1"
    mkdir -p "$tree"
    (cd "$root" && git ls-files -co --exclude-standard -z | xargs -0 cp --parents -t "$tree")
    cp "$tree/$file" "$tree/$file.orig"
    sed -i -E "$expr" "$tree/$file"
    if cmp -s "$tree/$file" "$tree/$file.orig"; then
        echo "NOT APPLIED  $name ($file unchanged)"; broken=$((broken + 1)); return
    fi
    rm -f "$tree/$file.orig"
    bash "$tree/tests/$suite" > "$logs/mutant-$name.log" 2>&1
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

mutant app-id run-settings-app-test.sh "one org.rimeos.Settings toplevel" \
    bin/rime-settings 's/QS_APP_ID=org\.rimeos\.Settings //'
mutant duplicate run-settings-app-test.sh "Rime Settings windows after a second launch" \
    bin/rime-settings 's/ -n -p / -p /; s/^if "\$qs" -p "\$app" ipc show/if false \&\& "$qs" -p "$app" ipc show/'
mutant display-in run-settings-app-test.sh "page display is listed|Hyprland/monitor tools were called" \
    src/nexus/PageRegistry.qml '/"id": "display"/,/shellOnly/ s/"shellOnly": true/"shellOnly": false/'
mutant no-fallback run-power-profile-service-test.sh "expected rimed|did not run rime tier" \
    src/services/system/PowerProfileService.qml 's/root\.backend = root\.ownerProc\.owned \? "ppd" : "rimed"/root.backend = "ppd"/'
mutant polling run-power-profile-service-test.sh "busctl calls|Tier was read" \
    src/services/system/PowerProfileService.qml 's/running: root\.refCount > 0 \&\& root\.backend === "rimed"/running: root.refCount > 0/'

echo "mutate-settings-app: caught=$caught survived=$survived broken=$broken (logs: $logs)"
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
