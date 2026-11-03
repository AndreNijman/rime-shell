#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# run-power-profile-test.sh — the Dashboard's Power profile pills
# (src/services/system/PowerProfileService.qml + src/modules/Center/PowerPanel.qml).
#
#     ./tests/run-power-profile-test.sh
#
# The REAL service and panel in the private headless compositor
# (tests/lib/headless.sh), with the two things they reach outside themselves
# replaced on PATH:
#   rime    `rime tier <id>`: per $STUB_DIR/mode, writes the tier (ok, after a
#           0.8 s delay), refuses the way rimed's polkit check does (refuse),
#           or finds rimed down (down) — with rime's real messages and exit 1
#   busctl  prints the tier file the way `busctl get-property` prints Tier
# A refused `rime tier` used to be thrown away, so the pill snapped back and
# the switch looked like it did nothing. Skips (0) without quickshell or a
# compositor, as the other headless suites do.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
. "$root/tests/lib/headless.sh"
headless_require quickshell
headless_begin
staged="$root/.power-profile-test.qml"
cleanup() { rm -f "$staged"; headless_cleanup; }
trap cleanup EXIT INT TERM
headless_start labwc 1280x800 || exit 0
cp "$here/power-profile-test.qml" "$staged"

W="$HEADLESS_W/power"; mkdir -p "$W"
B="$HEADLESS_W/bin"   # first on PATH; its stubs are symlinks to one _stub
rm -f "$B/rime" "$B/busctl"
echo balanced > "$W/tier"
echo ok > "$W/mode"
cat > "$B/rime" <<STUB
#!/bin/sh
[ "\$1" = tier ] && [ -n "\${2:-}" ] || exit 0
case "\$(cat "$W/mode")" in
    ok)     sleep 0.8; echo "\$2" > "$W/tier"; echo "rime: tier -> \$2" ;;
    refuse) echo "rime: SetTier failed: org.freedesktop.DBus.Error.AccessDenied: not authorized for org.rimeos.rimed.manage-power" >&2
            exit 1 ;;
    down)   echo "rime: rimed not running — cannot apply '\$2'. Dry-run plan:" >&2
            echo "  - governor -> powersave" >&2
            exit 1 ;;
esac
STUB
cat > "$B/busctl" <<STUB
#!/bin/sh
printf 's "%s"\n' "\$(cat "$W/tier")"
STUB
chmod +x "$B/rime" "$B/busctl"

out="$(STUB_DIR="$W" QT_LOGGING_RULES="qml=true" timeout 90 quickshell -p "$staged" 2>&1 || true)"
echo "$out" | grep -E "PASS|FAIL|passed=" || true
if grep -q "Failed to load configuration" <<<"$out"; then
    echo "$out" | tail -20
    echo "RESULT: the test config failed to load"
    exit 1
fi
summary="$(echo "$out" | grep -o 'passed=[0-9]* failed=[0-9]*' | tail -1)"
if [[ -z "$summary" ]]; then
    echo "$out" | tail -20
    echo "RESULT: test did not run to completion"
    exit 1
fi
echo "RESULT: $summary"
[[ "${summary##*failed=}" -eq 0 ]]
