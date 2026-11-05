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
#                  → Display is listed in the app and can be opened (it is
#                  caught there: opening it under labwc calls no hyprctl or
#                  wlr-randr stub, so this mutant does not exercise the stub)
#    hyprctl-page  a kept page (Updates) runs `hyprctl monitors -j` when built
#                  → "no hyprctl, wlr-randr or niri call" fails (the stub check)
#    no-fallback   PowerProfileService always takes the power-profiles path
#                  → the Rimed1 fallback assertions fail
#    polling       the 4 s Tier poll runs on the power-profiles path too
#                  → "exactly one busctl" / "Tier read 0 times" fail
#    owner-by-name the owner check asks only whether the power-profiles name
#                  HAS an owner (NameHasOwner), as on bootc's
#                  power-profiles-daemon → "another daemon ... expected rimed"
#    no-queue      a set before the owner check answers is sent at once
#                  (backend "" → the `rime tier` path) → "went to the rime CLI"
#    no-kick       a queued set does not start the owner check itself → with
#                  no consumer the backend stays "" ("no consumer: backend is")
#    quickshell-write  the power-profiles set goes through Quickshell's own
#                  PowerProfiles.profile write again (it shows the pick and only
#                  logs a refusal) → "the refused pick stayed", "no reason shown"
#    keep-pick     a refused write leaves the pick on the label
#                  → "refused: the refused pick stayed"
#    no-reason     a refused write shows no reason → "refused: no reason shown"
#  (no-list-wait is gone with the code it broke: the Shell no longer writes
#  through Quickshell, so there is no Profiles list to wait for; busctl hands
#  any pick to rimed and rimed decides.)
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
mutant hyprctl-page run-settings-app-test.sh "Hyprland/monitor tools were called" \
    src/services/config_tab/pages/UpdatesPage.qml '/^CfgScroll \{$/a\    Process { running: true; command: ["hyprctl", "monitors", "-j"] }'
mutant no-fallback run-power-profile-service-test.sh "expected rimed|did not run rime tier" \
    src/services/system/PowerProfileService.qml 's/root\.backend = root\.ownerProc\.owned \? "ppd" : "rimed"/root.backend = "ppd"/'
mutant polling run-power-profile-service-test.sh "busctl calls|Tier was read" \
    src/services/system/PowerProfileService.qml 's/running: root\.refCount > 0 \&\& root\.backend === "rimed"/running: root.refCount > 0/'

mutant owner-by-name run-power-profile-service-test.sh "with another daemon owning the API, expected rimed" \
    src/services/system/PowerProfileService.qml 's#"org\.freedesktop\.UPower\.PowerProfiles", "/org/rimeos/Rimed1",#"org.freedesktop.DBus", "/org/freedesktop/DBus",#; s#"org\.freedesktop\.DBus\.Properties", "Get", "ss", "org\.rimeos\.Rimed1\.Power", "Tier"\]#"org.freedesktop.DBus", "NameHasOwner", "s", "org.freedesktop.UPower.PowerProfiles"]#; s#/\^v\\s\+s\\s\+"/#/^b\\s+true/#'

mutant no-queue run-power-profile-service-test.sh "the early set went to the rime CLI|the set went to the rime CLI" \
    src/services/system/PowerProfileService.qml 's/if \(root\.backend === ""\) \{/if (false) {/'
mutant no-kick run-power-profile-service-test.sh "no consumer: backend is" \
    src/services/system/PowerProfileService.qml 's/^( *)root\._checkOwner\(\) *\/\/ with no consumer.*$/\1\/\/ no kick/'
mutant quickshell-write run-power-profile-service-test.sh "refused: the refused pick stayed|refused: no reason shown" \
    src/services/system/PowerProfileService.qml 's/^( *)root\._ppdWrite\(id\)$/\1PowerProfiles.profile = (id === "performance" ? PowerProfile.Performance : id === "power-saver" ? PowerProfile.PowerSaver : PowerProfile.Balanced)/'
mutant keep-pick run-power-profile-service-test.sh "refused: the refused pick stayed" \
    src/services/system/PowerProfileService.qml '/\/\/ back on the profile in force$/d'
mutant no-reason run-power-profile-service-test.sh "refused: no reason shown" \
    src/services/system/PowerProfileService.qml '/ppdErr\.text/,/back on the profile in force/ s/root\.error = root\.explain\(text\)/root.error = ""/'

echo "mutate-settings-app: caught=$caught survived=$survived broken=$broken (logs: $logs)"
[ "$survived" -eq 0 ] && [ "$broken" -eq 0 ]
