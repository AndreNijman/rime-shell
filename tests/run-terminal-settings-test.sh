#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-terminal-settings-test.sh — Settings → Misc → Default terminal, end to
#  end: the real page, the real TerminalService, the REAL xdg-terminal-exec.
#
#  In a private headless compositor (tests/lib/headless.sh) with a private home
#  that holds what a Rime install has: Ghostty's and Alacritty's desktop
#  entries (the binaries are stubs that are never run: --print-id only checks
#  they exist) and an OS list naming Ghostty first. tests/terminal-settings-
#  test.qml then drives the page; this judges what it printed and the
#  ~/.config/xdg-terminals.list it left behind:
#    - both terminals show as installed, and the page starts on Ghostty;
#    - choosing Alacritty on the page writes the list and reads back Alacritty;
#    - choosing Ghostty again reads back Ghostty, and the list keeps one line
#      per terminal (no growth);
#    - a running Ghostty's Wayland app id finds its desktop entry;
#    - with a desktop-specific list in the way, the page SAYS the choice is
#      shadowed instead of showing a choice that does nothing.
#  Then the read-back after a write is taken out of the staged tree, and the
#  run must FAIL.
#
#  Needs xdg-terminal-exec (the system's, or XTE=/path); SKIPs without it.
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"

headless_require quickshell
command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not installed"; exit 0; }
XTE="${XTE:-$(command -v xdg-terminal-exec || true)}"
[[ -n "$XTE" ]] || { echo "SKIP: no xdg-terminal-exec (set XTE=)"; exit 0; }

headless_begin
trap '[[ -n "${KEEP_TERM_OUT:-}" ]] && cp "$HEADLESS_W"/log-* "$KEEP_TERM_OUT"/ 2>/dev/null; headless_cleanup' EXIT INT TERM
headless_start || exit 0

# The real helper, first on PATH, ahead of anything the host has.
printf '#!/bin/sh\nexec sh %q "$@"\n' "$XTE" > "$HEADLESS_W/bin/xdg-terminal-exec"
chmod +x "$HEADLESS_W/bin/xdg-terminal-exec"
for t in ghostty alacritty; do
    printf '#!/bin/sh\ntouch %q\nexit 99\n' "$HEADLESS_W/launched-$t" > "$HEADLESS_W/bin/$t"
    chmod +x "$HEADLESS_W/bin/$t"
done
share="$HEADLESS_W/share"; etc="$HEADLESS_W/etc"
mkdir -p "$share" "$etc" "$HOME/.local/share/applications"
printf '[Desktop Entry]\nType=Application\nName=Ghostty\nTryExec=ghostty\nExec=ghostty --gtk-single-instance=true\nCategories=System;TerminalEmulator;\nStartupWMClass=com.mitchellh.ghostty\nX-TerminalArgExec=-e\n' \
    > "$HOME/.local/share/applications/com.mitchellh.ghostty.desktop"
printf '[Desktop Entry]\nType=Application\nName=Alacritty\nTryExec=alacritty\nExec=alacritty\nCategories=System;TerminalEmulator;\nStartupWMClass=Alacritty\n' \
    > "$HOME/.local/share/applications/Alacritty.desktop"
printf 'com.mitchellh.ghostty.desktop\n' > "$etc/xdg-terminals.list"
export XDG_DATA_DIRS="$share" XDG_CONFIG_DIRS="$etc" XDG_CURRENT_DESKTOP=Hyprland XTE_CACHE_ENABLED=0

tree="$HEADLESS_W/tree"
mkdir -p "$tree"
cp -r "$root/src" "$tree/src"
cp "$here/terminal-settings-test.qml" "$tree/shell.qml"

list="$HOME/.config/xdg-terminals.list"

# run <label> <mode> → judged lines; exit status = verdict.
run() {
    local log="$HEADLESS_W/log-$1"
    rm -f "$list" "$HOME/.config/hyprland-xdg-terminals.list"
    if [[ "$2" = shadow ]]; then
        printf 'Alacritty.desktop\n' > "$HOME/.config/hyprland-xdg-terminals.list"
    fi
    TERM_MODE="$2" timeout 90 quickshell -p "$tree/shell.qml" >"$log" 2>&1
    grep 'TERMDONE' "$log" >/dev/null || {
        echo "  FAIL the test shell stopped early ($1)"; grep -iE 'error|is not a type' "$log" | head -20; return 2; }
    if compgen -G "$HEADLESS_W/launched-*" >/dev/null; then
        echo "  FAIL a terminal was LAUNCHED by the settings page ($1)"; return 1
    fi
    sed -n 's/.*TERM \({.*}\)$/\1/p' "$log" | python3 -I "$here/lib/terminal-settings-check.py" "$2" "$list"
}

rc=0
echo "── a fresh home, the OS list naming Ghostty ──"
run normal normal || rc=1
echo "── a desktop-specific list naming Alacritty in the way ──"
run shadow shadow || rc=1
[[ $rc -eq 0 ]] || { echo "RESULT: the Default terminal setting does not do what it shows"; exit 1; }

# ── Can it fail? No read-back after the write. ──────────────────────────────
python3 -I - "$tree/src/services/TerminalService.qml" <<'PY' || { echo "RESULT: the self-test mutation did not apply"; exit 1; }
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "root._writePending = false\n            root.refresh()"
if old not in s: sys.exit(3)
open(p, "w", encoding="utf-8").write(s.replace(old, "root._writePending = false\n            root.busy = false", 1))
PY
if run noreadback normal >/dev/null; then
    echo "  FAIL self-test: a page that never reads back SURVIVED"
    exit 1
fi
echo "  ok   self-test: a page that never reads back is caught"
echo "RESULT: Settings → Default terminal writes the user's list and shows what xdg-terminal-exec then resolves"
