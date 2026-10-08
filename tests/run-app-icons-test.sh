#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  Run tests/app-icons-test.qml — IconService against fixture icons.
#
#  Apps Andre installed himself showed a broken icon: Helium in notifications
#  (an empty app_icon; the app is named only in the desktop-entry hint) and
#  Blanc everywhere (its only icon is in hicolor/1024x1024, a size directory
#  hicolor's index.theme does not list). Quickshell draws a placeholder for a
#  name its theme lacks and reports the Image Ready, so no surface's fallback
#  ever showed. This builds those shapes as fixtures and asks the shipped
#  service what each surface would draw.
#
#  No window is created, so it runs on the offscreen platform: nothing can
#  land on the developer's desktop. HOME, XDG_* and the session bus are
#  private; the only shared thing is /usr/share, read-only, so hicolor's real
#  index.theme defines the theme.
#
#  Skips cleanly (status 0) without quickshell.
#
#  Run from the repository root: ./tests/run-app-icons-test.sh
# ─────────────────────────────────────────────────────────────────────────────
. "$(dirname "${BASH_SOURCE[0]}")/lib/private-bus.sh"   # the session bus is ours, not the desktop's
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

command -v quickshell >/dev/null 2>&1 || { echo "SKIP: quickshell not installed"; exit 0; }
grep -q "^singleton IconService " "$root/src/services/qmldir" || {
    echo "FAIL: IconService is not registered in src/services/qmldir"; exit 1; }

W="$(mktemp -d)"
staged="$root/.app-icons-test.qml"
cleanup() { rm -f "$staged"; rm -rf "$W"; return 0; }
trap cleanup EXIT INT TERM
cp "$here/app-icons-test.qml" "$staged"

# A real PNG (1×1) and a real SVG, so an Image of them really loads.
png() { mkdir -p "$(dirname "$1")"; printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89\x00\x00\x00\rIDATx\x9cc\xf8\xcf\xc0\xf0\x1f\x00\x05\x00\x01\xff\x89\x99=\x1d\x00\x00\x00\x00IEND\xaeB`\x82' > "$1"; }
svg() { mkdir -p "$(dirname "$1")"; printf '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"/>\n' > "$1"; }
desk() { mkdir -p "$(dirname "$1")"; printf '[Desktop Entry]\nType=Application\nName=%s\nExec=true\nIcon=%s\n' "$2" "$3" > "$1"; }

export HOME="$W/home"
export XDG_DATA_HOME="$HOME/.local/share"
sys="$W/sys"
export XDG_DATA_DIRS="$sys:/usr/share"
export XDG_CONFIG_HOME="$W/config" XDG_CACHE_HOME="$W/cache" XDG_STATE_HOME="$W/state"
export XDG_RUNTIME_DIR="$W/run"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_STATE_HOME" "$XDG_RUNTIME_DIR"
chmod 0700 "$XDG_RUNTIME_DIR"
export ICON_FIXTURE_HOME="$XDG_DATA_HOME" ICON_FIXTURE_SYS="$sys"

png "$XDG_DATA_HOME/icons/hicolor/1024x1024/apps/fixblanc.png"    # Blanc's shape
png "$XDG_DATA_HOME/icons/hicolor/48x48/apps/fixhel.png"           # a theme icon
png "$sys/pixmaps/fixpix.png"
png "$XDG_DATA_HOME/icons/hicolor/1024x1024/apps/fixboth.png"
png "$sys/icons/hicolor/4096x4096/apps/fixboth.png"
svg "$sys/icons/hicolor/2048x2048/apps/fixsvg.svg"
png "$sys/icons/hicolor/4096x4096/apps/fixsvg.png"
desk "$XDG_DATA_HOME/applications/fixblanc.desktop" FixBlanc fixblanc
desk "$XDG_DATA_HOME/applications/fixhel.desktop" Fixhel fixhel

out="$(env -u WAYLAND_DISPLAY -u DISPLAY -u HYPRLAND_INSTANCE_SIGNATURE \
       QT_QPA_PLATFORM=offscreen QT_LOGGING_RULES="qml=true" \
       timeout 120 quickshell -p "$staged" 2>&1 \
       | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*DEBUG qml: //')"

printf '%s\n' "$out" | grep -E "^( *PASS| *FAIL|app-icons:)" || true

summary="$(printf '%s\n' "$out" | grep -o 'app-icons: passed=[0-9]* failed=[0-9]*' | tail -1)"
if [[ -z "$summary" ]]; then
    printf '%s\n' "$out" | tail -30
    echo "RESULT: the test did not run to completion"
    exit 1
fi
failed="${summary##*failed=}"
if [[ "$failed" -ne 0 ]]; then
    echo "RESULT: $failed assertion(s) failed"
    exit 1
fi
echo "RESULT: $summary"
