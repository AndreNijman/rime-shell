#!/usr/bin/env bash
# shellcheck disable=SC2015  # ok and bad always return 0, so `cond && ok || bad` is if/else here
# ─────────────────────────────────────────────────────────────────────────────
#  check-ghostty-theme.sh — Rime's Ghostty theme is rendered where Ghostty
#  looks, and renders over rime-os's seeded fallback.
#
#  Ghostty is Rime's terminal on NixOS. Every user's config.ghostty says
#  `theme = rime-os` (rime-os's rime-terminal-migrate writes it), so the
#  shell's matugen template is the whole theme:
#
#   OUTPUT  matugen.toml.in renders ghostty-colors.template to
#           ~/.config/ghostty/themes/rime-os
#   STATIC  the template keeps Alacritty's stock look (font, size, padding,
#           cursor, accent palette) between rime-static markers; rime-os
#           compares that block with its fallback copy at build time
#   STALE   WallpaperService.rethemeIfStale() re-renders when an output is
#           missing OR is rime-os's seeded fallback (first line
#           "# rime-os fallback"), and leaves a rendered theme alone
#
#  STALE runs the real command WallpaperService builds (extracted from the QML)
#  against a fixture HOME with a stub matugen. Each rule is mutated to prove it
#  can fail.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

TOML=src/config/matugen.toml.in
TMPL=src/config/ghostty-colors.template
WALL=src/services/WallpaperService.qml
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The bash program rethemeIfStale() passes to `bash -c`: the JS string pieces
# between `"bash", "-c",` and the argument list, unescaped.
extract_cmd() {
    python3 - "$1" <<'PY'
import json, re, sys
src = open(sys.argv[1]).read()
body = src.split("function rethemeIfStale()", 1)[1].split('"--", root.currentWall', 1)[0]
body = body.split('"bash", "-c",', 1)[1]
parts = re.findall(r'^\s*("(?:[^"\\]|\\.)*")\s*\+?\s*,?\s*$', body, re.M)
sys.stdout.write("".join(json.loads(p) for p in parts))
PY
}

# One fixture HOME; prints "ran" when the stub matugen was called.
stale_case() {
    local wall="$1" theme="$2" h="$WORK/home-$RANDOM" cmd
    mkdir -p "$h/.config/ghostty/themes" "$WORK/bin" "$WORK/shell/src/config"
    printf '#!/bin/sh\necho ran\n' > "$WORK/bin/matugen"; chmod +x "$WORK/bin/matugen"
    printf "[templates.ghostty]\noutput_path = '@HOME@/.config/ghostty/themes/rime-os'\n" \
        > "$WORK/shell/src/config/matugen.toml.in"
    : > "$WORK/wall.jpg"
    case "$theme" in
        missing) ;;
        *) printf '%s\n' "$theme" > "$h/.config/ghostty/themes/rime-os" ;;
    esac
    cmd="$(extract_cmd "$wall")"
    HOME="$h" PATH="$WORK/bin:$PATH" bash -c "$cmd" -- "$WORK/wall.jpg" "$WORK/shell" tonal-spot dark \
        2>/dev/null | grep -x ran >/dev/null && echo ran
}

check_all() {
    local toml="$1" tmpl="$2" wall="$3" label="$4" before=$fail
    grep -F "output_path = '@HOME@/.config/ghostty/themes/rime-os'" "$toml" >/dev/null \
        && ok "OUTPUT the template renders to ~/.config/ghostty/themes/rime-os$label" \
        || bad "OUTPUT the template renders to ~/.config/ghostty/themes/rime-os$label"
    local block
    block="$(sed -n '/^# rime-static-begin$/,/^# rime-static-end$/p' "$tmpl")"
    { printf '%s\n' "$block" | grep -x 'font-family = monospace' >/dev/null \
        && printf '%s\n' "$block" | grep -x 'font-size = 11.25' >/dev/null \
        && printf '%s\n' "$block" | grep -x 'palette = 1=#ac4242' >/dev/null \
        && ! printf '%s\n' "$block" | grep '{{' >/dev/null; } \
        && ok "STATIC Alacritty's stock look sits between the markers, no matugen colour in it$label" \
        || bad "STATIC Alacritty's stock look sits between the markers, no matugen colour in it$label"
    head -n1 "$tmpl" | grep '^# rime-os fallback' >/dev/null \
        && bad "STATIC the rendered theme does not carry the fallback mark (it would re-render forever)$label" \
        || ok "STATIC the rendered theme does not carry the fallback mark (it would re-render forever)$label"
    [ "$(stale_case "$wall" missing)" = ran ] \
        && ok "STALE a missing theme is rendered$label" || bad "STALE a missing theme is rendered$label"
    [ "$(stale_case "$wall" '# rime-os fallback: seeded')" = ran ] \
        && ok "STALE the seeded fallback is rendered over$label" \
        || bad "STALE the seeded fallback is rendered over$label"
    [ -z "$(stale_case "$wall" '# Rime rendered theme')" ] \
        && ok "STALE a rendered theme is left alone$label" || bad "STALE a rendered theme is left alone$label"
    [ "$fail" -gt "$before" ]
}

echo "check-ghostty-theme: the shipped files"
check_all "$TOML" "$TMPL" "$WALL" ""

echo "check-ghostty-theme: mutants (each must fail at least one rule)"
mutant() {
    local name="$1" file="$2" from="$3" to="$4" m="$WORK/mut" saved_pass=$pass saved_fail=$fail
    mkdir -p "$m"; cp "$TOML" "$m/toml"; cp "$TMPL" "$m/tmpl"; cp "$WALL" "$m/wall"
    python3 - "$m/$file" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1:]
s = open(p).read()
assert s.count(a) == 1, f"mutant text not found once: {a!r}"
open(p, "w").write(s.replace(a, b))
PY
    if check_all "$m/toml" "$m/tmpl" "$m/wall" " [mutant: $name]" >/dev/null; then
        pass=$saved_pass; fail=$saved_fail; ok "mutant killed: $name"
    else
        pass=$saved_pass; fail=$saved_fail; bad "mutant SURVIVED: $name"
    fi
}
mutant "old output path" toml "/.config/ghostty/themes/rime-os'" "/.config/ghostty/rime-shell-colors'"
mutant "fallback not stale" wall "'# rime-os fallback'*) first=fallback" "'# never'*) first=fallback"
# shellcheck disable=SC2016  # the QML's own text, $first included, matched literally
mutant "everything stale" wall '[ \"$first\" != fallback ]' 'false'
mutant "matugen colour in static block" tmpl "font-size = 11.25" "font-size = {{colors.x}}"
mutant "template marked as fallback" tmpl "# Rime's Ghostty theme, rendered" "# rime-os fallback, rendered"

echo "check-ghostty-theme: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
