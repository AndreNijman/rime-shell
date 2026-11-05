#!/usr/bin/env bash
# shellcheck disable=SC2016  # the $-words in single quotes are source text matched and mutated literally
# ─────────────────────────────────────────────────────────────────────────────
#  check-terminal-default.sh — does every terminal the shell opens follow the
#  user's default (Ghostty on Rime, or Alacritty if they chose it)?
#
#  1. No launch site names an emulator as the default: the context menu, the
#     Wi-Fi editor, the search verbs and the SUPER+T keybind all go through
#     xdg-terminal-exec (directly, or src/scripts/rime-terminal.sh).
#  2. rime-terminal.sh, RUN with stub terminals on PATH: xdg-terminal-exec
#     first and with argv intact; without it $TERMINAL, then Ghostty with
#     --gtk-single-instance=false before -e (Ghostty is single-instance on
#     Linux; a launch that hands off exits at once), then Alacritty -e; and
#     exit 127 with nothing at all.
#  3. SearchRun.sh's terminal verbs reach that launcher.
#  4. The Settings choice, read back by the REAL xdg-terminal-exec (the
#     system's, or $XTE): terminals.js withDefault() writes a list the tool
#     resolves to the chosen terminal, for both choices, with a desktop-
#     specific OS list in the way. Skipped (said so) when no real tool exists.
#  5. Mutants: each check above must fail on the bug it is for.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

pass=0; fail=0; skip=0
ok()  { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; fail=$((fail + 1)); }
skp() { printf '  SKIP %s (%s)\n' "$1" "$2"; skip=$((skip + 1)); }

W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

# Code lines only: a comment that explains why alacritty USED to be here is not
# a launch.
code() { grep -vE '^[[:space:]]*(//|#)' "$1"; }

# ── 1. static ────────────────────────────────────────────────────────────────
static_checks() {   # static_checks <tree> — prints one FAIL line per finding
    local r="$1" f
    for f in src/popups/ContextMenu.qml src/popups/WifiTab.qml src/scripts/SearchRun.sh \
             src/services/config_tab/KeybindService.qml src/services/DesktopExec.qml; do
        [ -s "$r/$f" ] || { echo "missing $f"; continue; }
        if code "$r/$f" | grep -nE '"(alacritty|ghostty)"|\$\{TERMINAL:-|exec "\$name"' >/dev/null; then
            echo "$f names an emulator (or \$TERMINAL) as the default: $(code "$r/$f" | grep -nE '"(alacritty|ghostty)"|\$\{TERMINAL:-|exec "\$name"' | head -1)"
        fi
    done
    code "$r/src/services/config_tab/KeybindService.qml" | grep -F '.replace("$terminal",    "xdg-terminal-exec")' >/dev/null \
        || echo "the Hyprland keybind generator does not resolve \$terminal to xdg-terminal-exec"
    code "$r/src/services/config_tab/KeybindService.qml" | grep -F '"$terminal":    "xdg-terminal-exec"' >/dev/null \
        || echo "the niri keybind generator does not resolve \$terminal to xdg-terminal-exec"
    code "$r/src/popups/ContextMenu.qml" | grep -F '/src/scripts/rime-terminal.sh"' >/dev/null \
        || echo "the desktop menu's Terminal does not use rime-terminal.sh"
    code "$r/src/popups/WifiTab.qml" | grep -F '/src/scripts/rime-terminal.sh", "nmtui"' >/dev/null \
        || echo "the Wi-Fi editor does not open nmtui through rime-terminal.sh"
    code "$r/src/scripts/SearchRun.sh" | grep -F 'rime-terminal.sh' >/dev/null \
        || echo "SearchRun.sh does not open its terminal through rime-terminal.sh"
    code "$r/src/services/DesktopExec.qml" | grep -F 'readonly property string terminalHelper: "xdg-terminal-exec"' >/dev/null \
        || echo "DesktopExec no longer launches terminal apps through xdg-terminal-exec"
    # A direct Ghostty launch anywhere in the shell must turn single-instance off.
    local hit
    hit="$(grep -rnE '(^|[^-.a-z])ghostty"?[[:space:]]+(-e|"-e")' "$r/src" --include='*.sh' --include='*.qml' --include='*.js' 2>/dev/null \
           | grep -vE ':[0-9]+:[[:space:]]*(#|//)' | grep -v 'gtk-single-instance=false' | head -1)"
    [ -z "$hit" ] || echo "a direct ghostty -e launch keeps single-instance mode: ${hit#"$r"/}"
}

# ── 2. the launcher, run ─────────────────────────────────────────────────────
# Every script under test runs with env -i and a PATH of stubs plus the few
# real tools named here: no display, no real terminal, no sudo can be reached.
tools() {   # tools <dir> <name...> — link the real binaries into <dir>
    local d="$1" t p; shift
    for t in "$@"; do
        p="$(type -P "$t")" || continue
        [ -e "$d/$t" ] || ln -s "$p" "$d/$t"
    done
}

mkstub() {   # mkstub <dir> <name> — a terminal that records its argv
    cat > "$1/$2" <<STUB
#!/bin/sh
printf '%s' "$2" > "\$RT_LOG"
for a in "\$@"; do printf ' [%s]' "\$a" >> "\$RT_LOG"; done
STUB
    chmod +x "$1/$2"
}

# run_launcher <tree> <stubs...> -- <args...> — prints what was exec'd, or rc=N
run_launcher() {
    local r="$1"; shift
    local bin="$W/bin.$RANDOM$RANDOM"; mkdir -p "$bin"
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do mkstub "$bin" "$1"; shift; done
    [ "${1:-}" = "--" ] && shift
    # The basics the script itself needs, and nothing that could be a terminal.
    tools "$bin" sh basename dirname
    local log="$W/log.$RANDOM"; : > "$log"
    env -i PATH="$bin" HOME="$W" RT_LOG="$log" ${RT_TERMINAL:+TERMINAL="$RT_TERMINAL"} \
        "$(command -v sh)" "$r/src/scripts/rime-terminal.sh" "$@" >/dev/null 2>&1
    local rc=$?
    if [ -s "$log" ]; then cat "$log"; else printf 'rc=%s' "$rc"; fi
}

launcher_checks() {   # launcher_checks <tree>
    local r="$1" got
    got="$(run_launcher "$r" xdg-terminal-exec ghostty alacritty -- bash -c 'echo a  b')"
    [ "$got" = "xdg-terminal-exec [bash] [-c] [echo a  b]" ] \
        || echo "with xdg-terminal-exec present it is not used first, argv intact: got '$got'"
    got="$(RT_TERMINAL=alacritty run_launcher "$r" xdg-terminal-exec ghostty alacritty -- nmtui)"
    [ "$got" = "xdg-terminal-exec [nmtui]" ] \
        || echo "\$TERMINAL outranks the user's default (xdg-terminal-exec): got '$got'"
    got="$(run_launcher "$r" xdg-terminal-exec --)"
    [ "$got" = "xdg-terminal-exec" ] || echo "a bare launch does not open the default terminal: got '$got'"
    got="$(run_launcher "$r" ghostty alacritty -- nmtui)"
    [ "$got" = "ghostty [--gtk-single-instance=false] [-e] [nmtui]" ] \
        || echo "without xdg-terminal-exec Ghostty is not next, with single-instance off: got '$got'"
    got="$(run_launcher "$r" alacritty -- nmtui)"
    [ "$got" = "alacritty [-e] [nmtui]" ] || echo "Alacritty is not the fallback after Ghostty: got '$got'"
    got="$(RT_TERMINAL=alacritty run_launcher "$r" ghostty alacritty -- nmtui)"
    [ "$got" = "alacritty [-e] [nmtui]" ] || echo "\$TERMINAL is not honoured when xdg-terminal-exec is missing: got '$got'"
    got="$(run_launcher "$r" --  nmtui)"
    [ "$got" = "rc=127" ] || echo "with no terminal at all it does not fail with 127: got '$got'"
}

# ── 3. SearchRun's verbs reach the launcher ──────────────────────────────────
searchrun_checks() {   # searchrun_checks <tree>
    local r="$1" bin="$W/sr.$RANDOM" log="$W/srlog.$RANDOM"
    mkdir -p "$bin"; : > "$log"
    mkstub "$bin" xdg-terminal-exec
    printf '#!/bin/sh\nexit 0\n' > "$bin/rime"; chmod +x "$bin/rime"
    # A PATH holding nothing that can open a window: a mutant that names a
    # real emulator must fail here, never start one on the desktop.
    tools "$bin" bash sh basename dirname cat
    env -i PATH="$bin" HOME="$W" RT_LOG="$log" RIME_BIN="$bin/rime" TERMINAL=alacritty \
        "$(type -P bash)" "$r/src/scripts/SearchRun.sh" os-update >/dev/null 2>&1
    case "$(cat "$log")" in
        "xdg-terminal-exec [bash] [-c] [sudo $bin/rime update; "*) : ;;
        *) echo "SearchRun os-update did not open the default terminal: got '$(cat "$log")'" ;;
    esac
}

# ── 4. the real xdg-terminal-exec reads what the Settings choice writes ─────
XTE="${XTE:-$(command -v xdg-terminal-exec || true)}"
xte_checks() {   # xte_checks <tree>
    local r="$1" key want id home
    home="$W/xte.$RANDOM"
    mkdir -p "$home/config" "$home/data/applications" "$home/etc" "$home/bin"
    # Both terminals "installed": desktop entries the tool will accept, TryExec
    # pointing at stubs, and the OS default list as Rime ships it (Ghostty),
    # plus a desktop-specific system list that must NOT outrank the user's.
    mkstub "$home/bin" ghostty; mkstub "$home/bin" alacritty
    mkdir -p "$home/tools"
    tools "$home/tools" sh awk cat sed grep tr head tail mkdir rm mv find basename dirname readlink realpath env printf stat
    printf '[Desktop Entry]\nType=Application\nName=Ghostty\nTryExec=ghostty\nExec=ghostty --gtk-single-instance=true\nCategories=System;TerminalEmulator;\nX-TerminalArgExec=-e\n' \
        > "$home/data/applications/com.mitchellh.ghostty.desktop"
    printf '[Desktop Entry]\nType=Application\nName=Alacritty\nTryExec=alacritty\nExec=alacritty\nCategories=System;TerminalEmulator;\n' \
        > "$home/data/applications/Alacritty.desktop"
    printf 'com.mitchellh.ghostty.desktop\n' > "$home/etc/xdg-terminals.list"
    printf 'com.mitchellh.ghostty.desktop\n' > "$home/etc/hyprland-xdg-terminals.list"
    for key in alacritty ghostty alacritty; do
        node -e '
            const T = require(process.argv[1]); const fs = require("fs");
            const p = process.argv[2]; let t = ""; try { t = fs.readFileSync(p, "utf8") } catch (e) {}
            fs.writeFileSync(p, T.withDefault(t, process.argv[3]));' \
            "$r/src/services/terminals.js" "$home/config/xdg-terminals.list" "$key" || { echo "the writer failed for $key"; continue; }
        want="$(node -e 'console.log(require(process.argv[1]).byKey(process.argv[2]).desktopId)' "$r/src/services/terminals.js" "$key")"
        id="$(env -i PATH="$home/bin:$home/tools" HOME="$home" XDG_CONFIG_HOME="$home/config" \
                 XDG_CONFIG_DIRS="$home/etc" XDG_DATA_HOME="$home/data" XDG_DATA_DIRS="$home/data" \
                 XDG_CURRENT_DESKTOP=Hyprland XTE_CACHE_ENABLED=0 XDG_CACHE_HOME="$home/cache" \
                 sh "$XTE" --print-id 2>/dev/null)"
        [ "$id" = "$want" ] || echo "after choosing $key, xdg-terminal-exec resolves '$id', not '$want'"
    done
}

run_all() {   # run_all <tree> — prints findings; empty = clean
    static_checks "$1"
    launcher_checks "$1"
    searchrun_checks "$1"
    if [ -n "$XTE" ]; then xte_checks "$1"; fi
}

report() {   # report <label> <findings>
    if [ -z "$2" ]; then ok "$1"; else while IFS= read -r l; do bad "$l"; done <<<"$2"; fi
}

echo "── the shipped tree ──"
report "every launch site follows the default terminal (static)" "$(static_checks "$root")"
report "rime-terminal.sh: xdg-terminal-exec, then \$TERMINAL, Ghostty (single-instance off), Alacritty, 127" \
    "$(launcher_checks "$root")"
report "SearchRun's terminal verbs open the default terminal" "$(searchrun_checks "$root")"
if [ -n "$XTE" ]; then
    report "the real xdg-terminal-exec ($XTE) resolves each Settings choice, over a desktop-specific OS list" \
        "$(xte_checks "$root")"
else
    skp "the real xdg-terminal-exec resolves each Settings choice" "no xdg-terminal-exec here; set XTE="
fi

# ── 5. mutants ──────────────────────────────────────────────────────────────
echo "── mutants (each must be caught) ──"
mutant() {   # mutant <name> <file> <python-replace-old> <new>
    local name="$1" file="$2" old="$3" new="$4" m="$W/m.$RANDOM"
    mkdir -p "$m"; cp -r "$root/src" "$m/src"
    python3 -I - "$m/$file" "$old" "$new" <<'PY' || { bad "mutant did not apply: $name"; return; }
import sys
p, old, new = sys.argv[1:4]
s = open(p, encoding="utf-8").read()
if old not in s: sys.exit(3)
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
    if [ -n "$(run_all "$m")" ]; then ok "caught: $name"; else bad "NOT caught: $name"; fi
}
mutant "\$TERMINAL tried before xdg-terminal-exec" src/scripts/rime-terminal.sh \
    'if have xdg-terminal-exec; then' 'if [ -n "${TERMINAL:-}" ] && have "$TERMINAL"; then exec "$TERMINAL" -e "$@"; fi
if have xdg-terminal-exec; then'
mutant "Ghostty launched -e without --gtk-single-instance=false" src/scripts/rime-terminal.sh \
    'ghostty) exec "$bin" --gtk-single-instance=false -e "$@" ;;' 'ghostty) exec "$bin" -e "$@" ;;'
mutant "SUPER+T hardcoded to alacritty again (Hyprland)" src/services/config_tab/KeybindService.qml \
    '.replace("$terminal",    "xdg-terminal-exec")' '.replace("$terminal",    "alacritty")'
mutant "the desktop menu back to \${TERMINAL:-alacritty}" src/popups/ContextMenu.qml \
    'proc.exec(["sh", Quickshell.shellDir + "/src/scripts/rime-terminal.sh"])' 'proc.exec(["sh", "-c", "${TERMINAL:-alacritty}"])'
mutant "SearchRun keeps its own emulator list" src/scripts/SearchRun.sh \
    'exec sh "$launcher" bash -c "$script"' 'exec alacritty -e bash -c "$script"'
if [ -n "$XTE" ]; then
    mutant "the Settings writer names a desktop id the tool cannot find" src/services/terminals.js \
        'desktopId: "com.mitchellh.ghostty.desktop",' 'desktopId: "ghostty.desktop",'
else
    skp "mutant: wrong desktop id" "needs a real xdg-terminal-exec"
fi

echo
echo "check-terminal-default: passed=$pass failed=$fail skipped=$skip"
[ "$fail" -eq 0 ]
