#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-settings-app-test.sh — Rime Settings, the app for sessions without the
#  Shell (settings.qml + bin/rime-settings; rime-os docs/nixos/desktops.md §5).
#
#  A headless labwc (an ordinary xdg-shell desktop compositor, as GNOME and KDE
#  are to this app), the real launcher and the real pages. A second Quickshell
#  config (tests/toplevel-lister.qml) reads the compositor's toplevel list
#  through wlr-foreign-toplevel-management, so "which windows exist and with
#  which app id" is the compositor's answer, not the app's.
#
#    one window     `rime-settings` maps exactly one toplevel, app id
#                   org.rimeos.Settings (the .desktop file's StartupWMClass)
#    single         a second `rime-settings gaming` maps no second window and
#                   switches the running one to Gaming
#    pages          the Shell-only pages (appearance, layout, display, input,
#                   keybinds, misc) are not listed and cannot be opened; the
#                   new Power and Desktops pages are
#    no hyprland    hyprctl, wlr-randr and niri are logging stubs first on
#                   PATH; opening every page of the app calls none of them
#    in the Shell   with a Rime Shell instance answering `qs -c <shellDir>`,
#                   `rime-settings power` opens the Shell's Nexus at Power and
#                   starts no app window
#
#  Mutants (tests/mutate-settings-app.sh): QS_APP_ID dropped; --no-duplicate
#  and the IPC hand-over dropped (two windows); Display left in the app.
#  Skips (status 0) without quickshell or labwc.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$here/lib/headless.sh"
headless_require quickshell labwc

pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

pids=()
cleanup() { local p; for p in ${pids[@]+"${pids[@]}"}; do kill "$p" 2>/dev/null; done; headless_cleanup; }
trap cleanup EXIT INT TERM

headless_begin
HYPR_LOG="$HEADLESS_W/hypr-calls.log"; : > "$HYPR_LOG"
for n in hyprctl wlr-randr niri; do
    rm -f "$HEADLESS_W/bin/$n"   # a symlink to the shared _stub: never write through it
    cat > "$HEADLESS_W/bin/$n" <<STUB
#!/usr/bin/env bash
echo "$n \$*" >> "$HYPR_LOG"
case "\$*" in *-j*|*json*) echo "[]" ;; esac
exit 0
STUB
    chmod +x "$HEADLESS_W/bin/$n"
done
[ -e /dev/dri/renderD128 ] && export HEADLESS_WLR_RENDERER=gles2
headless_start labwc 1280x800 || exit 0

lister="$HEADLESS_W/lister/shell.qml"
mkdir -p "$(dirname "$lister")"
cp "$here/toplevel-lister.qml" "$lister"
quickshell -p "$lister" > "$HEADLESS_W/lister.log" 2>&1 &
pids+=($!)
toplevels() { quickshell -p "$lister" ipc call toplevels list 2>/dev/null; }
for _ in $(seq 1 60); do quickshell -p "$lister" ipc show >/dev/null 2>&1 && break; sleep 0.25; done

app="$root/settings.qml"
appipc() { quickshell -p "$app" ipc call settings "$@" 2>/dev/null; }
export RIME_SHELL_DIR="$root"
launcher="$root/bin/rime-settings"

count_app() { toplevels | grep -c '^org\.rimeos\.Settings|' || true; }
count_all() { toplevels | grep -c . || true; }

# ── one window, with the app id ──────────────────────────────────────────────
"$launcher" > "$HEADLESS_W/app.log" 2>&1 &
pids+=($!)
for _ in $(seq 1 80); do [ "$(count_all)" -ge 1 ] && break; sleep 0.25; done
sleep 1
echo "toplevels: $(toplevels | tr '\n' ' ')"
[ "$(count_app)" = 1 ] && ok "one toplevel with app id org.rimeos.Settings" \
    || bad "expected one org.rimeos.Settings toplevel, compositor lists: $(toplevels | tr '\n' ' ')"
toplevels | grep -qx 'org\.rimeos\.Settings|Rime Settings' && ok "titled Rime Settings" || bad "title"
[ "$(count_all)" = 1 ] && ok "no other window" || bad "$(count_all) toplevels"
grep -qx 'StartupWMClass=org.rimeos.Settings' "$root/dots-extra/settings-app/org.rimeos.Settings.desktop" \
    && ok "the .desktop file names the same app id" || bad ".desktop StartupWMClass"

# ── a second launch: no second window, the page switches ────────────────────
# In the background, so a launcher that wrongly starts a second app (and so
# never returns) is still running while the windows are counted.
"$launcher" gaming > "$HEADLESS_W/second.log" 2>&1 &
second=$!
for _ in $(seq 1 40); do kill -0 "$second" 2>/dev/null || break; sleep 0.25; done
sleep 2
n_app="$(count_app)"
if kill -0 "$second" 2>/dev/null; then
    bad "a second launch did not return: $(head -3 "$HEADLESS_W/second.log" | tr '\n' ' ')"
    kill "$second" 2>/dev/null; wait "$second" 2>/dev/null
else
    wait "$second"; rc=$?
    [ "$rc" = 0 ] && ok "a second launch returns (rc 0)" || bad "second launch rc=$rc: $(cat "$HEADLESS_W/second.log")"
fi
[ "$n_app" = 1 ] && ok "still one window after a second launch" || bad "$n_app Rime Settings windows after a second launch"
[ "$(appipc current)" = gaming ] && ok "the second launch switched to gaming" || bad "page is '$(appipc current)'"

# ── pages ────────────────────────────────────────────────────────────────────
pages="$(appipc pages)"
echo "pages: $pages"
for p in appearance layout display input keybinds misc; do
    case " $pages " in *" $p "*) bad "Shell-only page $p is listed" ;; *) ok "Shell-only page $p is not listed" ;; esac
    case "$(appipc open "$p")" in "unknown page"*) ok "$p cannot be opened" ;; *) bad "$p opened in the app" ;; esac
done
for p in power desktops updates gaming about; do
    case " $pages " in *" $p "*) ok "$p is listed" ;; *) bad "$p is not listed" ;; esac
done

# ── every page, no Hyprland ──────────────────────────────────────────────────
: > "$HYPR_LOG"
for p in $pages; do
    appipc open "$p" >/dev/null
    for _ in $(seq 1 20); do [ "$(appipc current)" = "$p" ] && break; sleep 0.1; done
    sleep 1.5
done
if [ -s "$HYPR_LOG" ]; then
    bad "Hyprland/monitor tools were called while the pages were open: $(sort "$HYPR_LOG" | uniq -c | tr '\n' ';')"
else
    ok "every page opened ($(echo $pages | wc -w)), no hyprctl, wlr-randr or niri call"
fi
grep -E 'ERROR' "$HEADLESS_W/app.log" | grep -v 'FileView' | head -5
appipc close >/dev/null
for _ in $(seq 1 40); do [ "$(count_app)" = 0 ] && break; sleep 0.25; done
[ "$(count_app)" = 0 ] && ok "close quits the app" || bad "the window stayed after close"

# ── inside a Rime session: the Shell's Nexus, not the app ───────────────────
fake="$HEADLESS_W/fakeshell"; mkdir -p "$fake"
NEXUS_LOG="$HEADLESS_W/nexus.log"; : > "$NEXUS_LOG"
cat > "$fake/shell.qml" <<QML
import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
    IpcHandler {
        target: "nexus"
        function open(page: string): string { console.warn("NEXUS-OPEN " + page); return "nexus open at " + page }
    }
}
QML
quickshell -c "$fake" > "$NEXUS_LOG" 2>&1 &
pids+=($!)
for _ in $(seq 1 60); do quickshell -c "$fake" ipc show >/dev/null 2>&1 && break; sleep 0.25; done
RIME_SHELL_DIR="$fake" timeout 20 "$launcher" power > "$HEADLESS_W/inshell.log" 2>&1
sleep 1
grep -q 'NEXUS-OPEN power' "$NEXUS_LOG" && ok "in a Rime session it opens Nexus at power" \
    || bad "Nexus was not asked: $(cat "$HEADLESS_W/inshell.log")"
[ "$(count_app)" = 0 ] && ok "and starts no app window" || bad "an app window appeared inside a Rime session"

echo "RESULT: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
