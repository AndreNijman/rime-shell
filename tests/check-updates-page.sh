#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-updates-page.sh — static invariants for Settings → Updates, the
#  `shell` IPC target, and the retirement of the shell's own git updater.
#
#  tests/liveupdate-test.js drives the decisions and
#  tests/run-updates-page-test.sh draws the page and calls the IPC from
#  outside. Neither can see what is NOT there: a Process slipped into the page,
#  a button that takes its argv from the status file, an unlock() added to the
#  shell target "for symmetry", a revision read at call time instead of at
#  startup, or the old updater coming back through a copied file. Each is one
#  edit from regressing with no visible symptom.
#
#  Same discipline as check-firewall-ui.sh: every check reads comment-stripped
#  code, every mutant is diffed against its source (one that did not apply is a
#  failure, not a catch), and a prose mutant naming every banned thing must
#  stay green.
#
# Run from anywhere: ./tests/check-updates-page.sh
#            or:     ./tests/check-updates-page.sh --self-test
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0
fail=0
quiet=0
ok()  { [ "$quiet" -eq 1 ] || echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { [ "$quiet" -eq 1 ] || echo "  FAIL  $1"; fail=$((fail + 1)); }
want() { local desc="$1"; shift; if "$@"; then ok "$desc"; else bad "$desc"; fi; }

code()       { grep -vE '^[[:space:]]*//' "$1" 2>/dev/null | sed -E 's#[[:space:]]+//[^"]*$##'; }
qmldircode() { grep -vE '^[[:space:]]*#'  "$1" 2>/dev/null; }
has()        { local _c; _c=$(code "$1");       grep -qE "$2" <<<"$_c"; }
lacks()      { local _c; _c=$(code "$1");     ! grep -qE "$2" <<<"$_c"; }
count()      { local _c; _c=$(code "$1"); grep -cE "$2" <<<"$_c"; }
qmldir_has() { local _c; _c=$(qmldircode "$1"); grep -qE "$2" <<<"$_c"; }

# The body of a block that opens on the first line matching $2, up to the
# closing brace at the same indent.
fn_body() {
    FN_PAT="$2" awk '
        !inside && $0 ~ ENVIRON["FN_PAT"] { inside = 1; indent = match($0, /[^ ]/); print; next }
        inside {
            print
            if ($0 ~ /^[ ]*\}/ && match($0, /[^ ]/) == indent) exit
        }
    ' "$1" 2>/dev/null | grep -vE '^[[:space:]]*//'
}
in_fn()     { local _b; _b=$(fn_body "$1" "$2");   grep -qE "$3" <<<"$_b"; }
not_in_fn() { local _b; _b=$(fn_body "$1" "$2"); ! grep -qE "$3" <<<"$_b"; }

check_tree() {
    local r="$1"
    local js="$r/src/services/liveupdate.js"
    local page="$r/src/services/config_tab/pages/UpdatesPage.qml"
    local reg="$r/src/nexus/PageRegistry.qml"
    local qmldir="$r/src/services/qmldir"
    local ipc="$r/src/state/IpcManager.qml"
    local exec="$r/src/services/DesktopExec.qml"
    local misc="$r/src/services/config_tab/pages/MiscPage.qml"

    local f
    for f in "$js" "$page" "$reg" "$qmldir" "$ipc" "$exec" "$misc"; do
        want "$(basename "$f") exists and is non-empty" test -s "$f"
    done

    # ── 1. the page can be opened, and polls only while looked at ────────────
    want "UpdatesPage is reachable through the qmldir" \
        qmldir_has "$qmldir" '^UpdatesPage \./config_tab/pages/UpdatesPage\.qml$'
    want "the page is in the registry" has "$reg" '"id": "updates"'
    want "the registry names a component for it" has "$reg" 'UpdatesPage \{\}'
    want "the registry says this page must be told when it is on screen" \
        test "$(FN_PAT='"id": "updates"' awk '
            $0 ~ ENVIRON["FN_PAT"] { inside = 1 }
            inside && /needsScreen/ { print; exit }' "$reg" | grep -c 'true')" = 1
    want "the re-read timer runs only while the page is on screen" \
        has "$page" '^[[:space:]]+running: root\.onScreen$'
    want "Misc points at the page instead of an updater" has "$misc" 'NexusState\.page = "updates"'

    # ── 2. the page runs nothing but three constants ─────────────────────────
    want "the page has no Process and no command of its own" \
        lacks "$page" '(Process[[:space:]]*\{|(^|[^a-zA-Z.])command[[:space:]]*[:=]|execDetached|Qt\.openUrlExternally)'
    want "every terminal the page opens is one of the three constants" \
        test "$(code "$page" | grep -E 'runInTerminal' | grep -vcE 'DesktopExec\.runInTerminal\(L\.(UPDATE|PLAN|EXPLAIN)_ARGV\)$')" = 0
    want "and there are exactly three" test "$(count "$page" 'DesktopExec\.runInTerminal\(')" = 3
    want "Update now opens sudo rime update" \
        has "$js" '^var UPDATE_ARGV  = \["sh", "-c", HOLD, "sh", "sudo", "rime", "update"\]$'
    want "Show plan opens sudo rime update --plan" \
        has "$js" '^var PLAN_ARGV    = \["sh", "-c", HOLD, "sh", "sudo", "rime", "update", "--plan"\]$'
    want "Explain opens rime live explain" \
        has "$js" '^var EXPLAIN_ARGV = \["sh", "-c", HOLD, "sh", "rime", "live", "explain"\]$'
    want "the hold wrapper only runs its arguments" \
        has "$js" "^var HOLD = \"\\\\\"\\\$@\\\\\"; printf '\\\\\\\\nPress Enter to close this window. '; read -r _\"$"
    want "nothing evaluates text" lacks "$js" '\beval[[:space:]]*\(|new[[:space:]]+Function\b|Qt\.include'
    want "nor does the page" lacks "$page" '\beval[[:space:]]*\(|new[[:space:]]+Function\b|Qt\.include|createQmlObject'
    want "the terminal helper runs the argv it is given, through xdg-terminal-exec" \
        in_fn "$exec" 'function runInTerminal' 'const cmd = \[root\.terminalHelper\]'

    # ── 3. what the files say is drawn as text ───────────────────────────────
    want "every CfgRow on the page draws plain text" \
        test "$(count "$page" '(^|[[:space:]])CfgRow[[:space:]]*\{')" = "$(count "$page" 'plainText:[[:space:]]+true')"
    want "the hero's title is plain text" has "$page" 'titleItem\.textFormat:[[:space:]]+Text\.PlainText'
    want "the hero's detail is plain text" has "$page" 'detailItem\.textFormat:[[:space:]]+Text\.PlainText'
    want "CfgRow honours plainText on its label" \
        test "$(count "$r/src/components/config/CfgRow.qml" 'textFormat:[[:space:]]+root\.plainText \? Text\.PlainText')" = 3
    want "a status file that disappears stops being shown" \
        has "$page" 'onLoadFailed: root\._statusText = ""'
    want "so does a checker file" has "$page" 'onLoadFailed: root\._checkerText = ""'

    # ── 4. the shell IPC target answers and does nothing ─────────────────────
    want "there is a shell target" has "$ipc" 'target: "shell"'
    local fns
    fns=$(fn_body "$ipc" 'property var shellInfo: IpcHandler' | grep -oE 'function [A-Za-z_]+' | awk '{print $2}' | sort | tr '\n' ' ')
    want "it has exactly revision() and state() (has: $fns)" test "$fns" = "revision state "
    want "it touches no lock state" \
        not_in_fn "$ipc" 'property var shellInfo: IpcHandler' 'LockState\.[A-Za-z]+[[:space:]]*=[^=]|LockState\.lock\(|unlock'
    want "revision() returns what was read at startup" \
        in_fn "$ipc" 'function revision\(\)' 'return root\.shellRevision$'
    want "the revision is read once, at startup" \
        in_fn "$ipc" 'Component\.onCompleted' 'root\._commitFile\.text\(\)'
    want "and the file is not watched for changes" \
        not_in_fn "$ipc" 'property FileView _commitFile' 'watchChanges: true'
    want "a lock being released still counts as locked" \
        in_fn "$ipc" 'function shellLockState' 'LockState\.unlocking !== false'
    want "a lock waiting for its picture still counts as locked" \
        in_fn "$ipc" 'function shellLockState' 'LockState\.capturing !== false'
    want "an engaged compositor lock counts as locked" \
        in_fn "$ipc" 'function shellLockState' '\|\| secure$'
    want "only an explicit false is unlocked" \
        in_fn "$ipc" 'function shellLockState' 'LockState\.locked !== false'
    want "a state that cannot be read is locked" \
        in_fn "$ipc" 'function shellLockState' '"locked": true, "lockSecure": false'
    want "state() reports the pid" in_fn "$ipc" 'property var shellInfo: IpcHandler' 'Quickshell\.processId'

    # ── 5. the git updater is gone and stays gone ────────────────────────────
    local hits
    hits=$(grep -rlE 'UpdateService|UpdatePopup|update_prefs|stashAndUpdate' \
               "$r/src" "$r/shell.qml" "$r/.github" "$r/tests" "$r/.gitignore" 2>/dev/null \
           | grep -v '/tests/check-updates-page\.sh$' || true)
    want "nothing names the git updater (${hits//$'\n'/ })" test -z "$hits"
    want "no service in src fetches or pulls the shell's own repo" \
        test -z "$(grep -rlE '"git",[[:space:]]*"-C",[^]]*"(fetch|pull)"|git (fetch|pull|stash)' "$r/src" --include='*.qml' 2>/dev/null || true)"
}

if [ "${1:-}" = "--self-test" ]; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    quiet=1; check_tree "$repo"; quiet=0
    echo "baseline: $pass passed, $fail failed"
    [ "$fail" -eq 0 ] || { echo "the baseline itself fails; fix that first"; exit 1; }

    mutants=(
      "page|s/running: root\.onScreen/running: true/|the page re-reads files whether or not anyone looks"
      "page|s/DesktopExec\.runInTerminal(L\.PLAN_ARGV)/DesktopExec.runInTerminal([\"sh\", \"-c\", root.status.summary])/|a button runs text from the status file"
      "page|s/onClicked: DesktopExec\.runInTerminal(L\.EXPLAIN_ARGV)/onClicked: Quickshell.execDetached([\"rime\", \"live\", \"explain\"])/|the page spawns on its own"
      "js|s/\"sh\", \"sudo\", \"rime\", \"update\"\]/\"sh\", \"sudo\", \"rime\", \"update\", \"--yes\"]/|Update now passes another argument"
      "js|s/\"sudo\", \"rime\", \"update\", \"--plan\"\]/\"rime\", \"update\", \"--plan\"]/|Show plan runs without root and cannot download the release"
      "page|0,/plainText:        true/s//plainText:        false/|a row draws the file as markup"
      "page|s/titleItem\.textFormat:  Text\.PlainText/titleItem.textFormat:  Text.AutoText/|the hero draws the summary as markup"
      "page|s/onLoadFailed: root\._statusText = \"\"/onLoadFailed: {}/|a deleted status keeps being shown"
      "qmldir|/^UpdatesPage /d|the page is missing from the qmldir"
      "reg|s/\"id\": \"updates\"/\"id\": \"update\"/|the page is not in the registry under its id"
      "ipc|s/        function state(): string {/        function unlock(): string { return \"\" }\n        function state(): string {/|the shell target grows an unlock"
      "ipc|s/            return root\.shellRevision$/            return String(root._commitFile.text()).trim()/|revision() re-reads the file at call time"
      "ipc|s/ || LockState\.unlocking !== false//|a lock being released reads as unlocked"
      "ipc|s/                           || LockState\.capturing !== false || secure/                           || secure/|a lock waiting for its picture reads as unlocked"
      "ipc|s/return { \"locked\": true, \"lockSecure\": false }/return { \"locked\": false, \"lockSecure\": false }/|an unreadable lock state reads as unlocked"
      "ipc|s/LockState\.locked !== false/LockState.locked === true/|an undefined lock flag reads as unlocked"
      "misc|s/NexusState\.page = \"updates\"/UpdateService.check()/|Misc calls the old updater again"
    )
    caught=0; missed=0
    for m in "${mutants[@]}"; do
        which="${m%%|*}"; rest="${m#*|}"
        expr="${rest%|*}"; label="${rest##*|}"
        rm -rf "$tmp/t"; mkdir -p "$tmp/t"
        cp -r "$repo/src" "$repo/shell.qml" "$repo/tests" "$repo/.gitignore" "$tmp/t/"
        cp -r "$repo/.github" "$tmp/t/" 2>/dev/null
        case "$which" in
            js)     target="$tmp/t/src/services/liveupdate.js" ;;
            page)   target="$tmp/t/src/services/config_tab/pages/UpdatesPage.qml" ;;
            qmldir) target="$tmp/t/src/services/qmldir" ;;
            reg)    target="$tmp/t/src/nexus/PageRegistry.qml" ;;
            ipc)    target="$tmp/t/src/state/IpcManager.qml" ;;
            misc)   target="$tmp/t/src/services/config_tab/pages/MiscPage.qml" ;;
        esac
        cp "$target" "$tmp/orig"
        sed -i "$expr" "$target"
        if cmp -s "$tmp/orig" "$target"; then
            echo "  MUTANT DID NOT APPLY: $label"; echo "    $expr"
            missed=$((missed + 1)); continue
        fi
        pass=0; fail=0; quiet=1; check_tree "$tmp/t"; quiet=0
        if [ "$fail" -gt 0 ]; then
            printf '  caught  %-62s (%d failed)\n' "$label" "$fail"; caught=$((caught + 1))
        else
            printf '  MISSED  %-62s\n' "$label"; missed=$((missed + 1))
        fi
    done

    # The old updater put back as a file nothing imports must still be caught.
    rm -rf "$tmp/t"; mkdir -p "$tmp/t"
    cp -r "$repo/src" "$repo/shell.qml" "$repo/tests" "$repo/.gitignore" "$tmp/t/"
    git -C "$repo" show eda0581:src/services/UpdateService.qml > "$tmp/t/src/services/UpdateService.qml" 2>/dev/null \
        || printf 'QtObject { // UpdateService\n property var p: ["git", "-C", d, "fetch"]\n}\n' > "$tmp/t/src/services/UpdateService.qml"
    pass=0; fail=0; quiet=1; check_tree "$tmp/t"; quiet=0
    if [ "$fail" -gt 0 ]; then echo "  caught  the old UpdateService.qml put back"; caught=$((caught + 1))
    else echo "  MISSED  the old UpdateService.qml put back"; missed=$((missed + 1)); fi

    # The green mutant: prose naming every banned thing changes nothing.
    rm -rf "$tmp/t"; mkdir -p "$tmp/t"
    cp -r "$repo/src" "$repo/shell.qml" "$repo/tests" "$repo/.gitignore" "$tmp/t/"
    cat >> "$tmp/t/src/services/config_tab/pages/UpdatesPage.qml" <<'PROSE'
// Prose mutant. None of this is code: the page never builds a Process, never
// sets command: ["sudo", "rime", "update"], never calls execDetached or
// Qt.openUrlExternally, never eval()s a field, and never runs
// DesktopExec.runInTerminal(status.summary).
PROSE
    cat >> "$tmp/t/src/state/IpcManager.qml" <<'PROSE'
// Prose mutant: the shell target has no function unlock() and never sets
// LockState.locked = false.
PROSE
    pass=0; fail=0; quiet=1; check_tree "$tmp/t"; quiet=0
    if [ "$fail" -eq 0 ]; then echo "  caught  prose naming every banned thing stays green"; caught=$((caught + 1))
    else echo "  MISSED  prose naming every banned thing reddened $fail checks"; missed=$((missed + 1)); fi

    echo
    echo "self-test: $caught/$((caught + missed)) mutants behaved, $missed did not"
    [ "$missed" -eq 0 ]
    exit $?
fi

echo "== updates page, shell IPC, no git updater =="
check_tree "$repo"
echo
echo "updates-page: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
