#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-exclusive-focus.sh — a surface that holds the keyboard must also catch
#  the click outside itself.
#
#  Hyprland pins the POINTER to a layer surface holding exclusive keyboard
#  focus. A popup with a small window and exclusive focus therefore swallowed
#  every click outside itself, and the dismiss layer beneath it (PopupDismiss)
#  never saw one: the Wi-Fi, notification and audio panes, the power menu,
#  quick controls and the clipboard could not be closed by a click (Andre,
#  2026-09-27: "when i open anything from right notch like wifi and
#  notifications i cant close it"). labwc does not pin the pointer, which is
#  why every headless suite passed.
#
#  So, for every QML file whose layer surface asks for WlrKeyboardFocus.Exclusive
#  (discovered, not listed):
#
#   1. FULLSCREEN — the window is anchored to all four edges, so there is no
#      "outside" the compositor can pin the pointer away from. A kept window
#      (SurfaceLifecycle) lets go of three edges while parked, 1x1: that is
#      allowed only when its keyboard focus is gated on not being parked
#      (`… && !life.parked ?`, or on a property bound to `life.mapped`).
#   2. INPUT — its input region, while it holds the keyboard, is the whole
#      window: no mask at all, or a mask whose item fills the window. A
#      popup that masks its body at other times says which with `grabbing`:
#      `mask: Region { item: root.grabbing ? outside : <body> }`.
#   3. GRAB — a file that declares `grabbing` drives the keyboard with it
#      (`root.grabbing ? WlrKeyboardFocus.Exclusive`), and its `outside` catcher
#      is enabled by it and closes the popups on a click. One condition for
#      both, so the grab and the catcher cannot disagree.
#
#  Each rule is mutated on a copy to prove it can fail (a mutant that did not
#  apply is reported as such, never as caught).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }

check_tree() {   # check_tree <root> — one verdict line per finding: RULE PASS|FAIL detail
    python3 - "$1" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
def verdict(rule, good, detail=""): print(rule, "PASS" if good else "FAIL", detail)
def code(text):
    return "\n".join(l.split("//", 1)[0] for l in text.split("\n"))

def block_of(src, ident):
    """The text of the object declaring `id: ident`, from its opening brace."""
    m = re.search(r"\bid:\s*" + re.escape(ident) + r"\b", src)
    if not m: return ""
    start = src.rfind("{", 0, m.start())
    depth, i = 0, start
    while i < len(src):
        if src[i] == "{": depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0: return src[start:i + 1]
        i += 1
    return src[start:]

def fills(src, ident):
    return re.search(r"\banchors\.fill:\s*parent\b|\banchors\s*\{[^}]*\bfill:\s*parent", block_of(src, ident)) is not None

found = []
for f in sorted((root / "src").rglob("*.qml")):
    src = code(f.read_text(errors="replace"))
    kf = re.search(r"WlrLayershell\.keyboardFocus:\s*([^\n]*(?:\n\s+[?:][^\n]*)*)", src)
    if not kf or "WlrKeyboardFocus.Exclusive" not in kf.group(1): continue
    rel = str(f.relative_to(root)); found.append(rel)

    # Lifecycles the keyboard is never held while parked by.
    gated = set(re.findall(r"!\s*((?:\w+\.)*\w+)\.parked\b", kf.group(1)))
    for prop, ref in re.findall(r"readonly\s+property\s+bool\s+(\w+)\s*:\s*((?:\w+\.)*\w+)\.mapped\s*$", src, re.M):
        if re.search(r"\broot\." + prop + r"\b", kf.group(1)): gated.add(ref)
    def edge(e):
        m = re.search(r"\banchors\." + e + r":\s*(true\b|!\s*((?:\w+\.)*\w+)\.parked\b)", src)
        if m: return m.group(1) == "true" or m.group(2) in gated
        return re.search(r"\banchors\s*\{[^}]*\b" + e + r":\s*true", src) is not None
    edges = all(edge(e) for e in ("top", "bottom", "left", "right"))
    verdict("FULLSCREEN:" + rel, edges, "not anchored to all four edges: a click outside it goes nowhere on Hyprland")

    mask = re.search(r"\bmask:\s*Region\s*\{\s*item:\s*([^}\n]*)\}", src)
    grabbing = re.search(r"readonly\s+property\s+bool\s+grabbing\s*:", src) is not None
    if not mask:
        good, why = True, ""
    elif grabbing:
        # (a kept window's parked state, `life.parked ? null :`, takes no input)
        mg = re.match(r"\s*(?:(?:\w+\.)*parked\s*\?\s*null\s*:\s*)?root\.grabbing\s*\?\s*(\w+)\s*:", mask.group(1))
        good = bool(mg) and fills(src, mg.group(1))
        why = "while grabbing, the mask must be an item that fills the window (root.grabbing ? outside : …)"
    else:
        ids = [x for x in re.findall(r"\b[A-Za-z_]\w*\b", mask.group(1))
               if x != "root" and re.search(r"\bid:\s*" + x + r"\b", src)]
        good = len(ids) > 0 and all(fills(src, x) for x in ids)
        why = "its mask (%s) does not fill the window" % ", ".join(ids or ["?"])
    verdict("INPUT:" + rel, good, why)

    if grabbing:
        # (a kept window closing while another popup opens holds on until its
        # close ends: `(root.grabbing || life.closing && Popups.anyOpen)`)
        kfg = re.match(r"\s*(?:root\.grabbing|\(\s*root\.grabbing\s*\|\|\s*(?:\w+\.)*closing\s*&&\s*Popups\.anyOpen\s*\))"
                       r"\s*(?:&&\s*!\s*(?:\w+\.)*parked\s*)?\?\s*WlrKeyboardFocus\.Exclusive", kf.group(1)) is not None
        out = block_of(src, "outside")
        catcher = ("MouseArea" in src[max(0, src.find(out) - 40):src.find(out) + 1] if out else False) \
                  and re.search(r"\benabled:\s*root\.grabbing\b", out) is not None \
                  and re.search(r"\bonClicked:\s*Popups\.closeAll\(\)", out) is not None
        # A kept window must hold on: released at once, labwc can hand the keys
        # to a window before the opener's grab lands, and that closes the opener.
        if re.search(r"\bkeepWindow:\s*true\b", src) and "Popups.anyOpen" not in kf.group(1):
            kfg = False
        verdict("GRAB:" + rel, kfg and catcher,
                "grabbing must drive the keyboard, and `outside` must be a MouseArea enabled by it that closes the popups")

verdict("FOUND", len(found) >= 8, "only %d surfaces take the keyboard — this check would inspect little: %s" % (len(found), found))
PY
}

echo "── exclusive keyboard focus catches the click outside ──"
verdicts="$(check_tree .)"
while read -r rule verdict detail; do
    [ -n "$rule" ] || continue
    if [ "$verdict" = PASS ]; then ok "$rule"; else bad "$rule — $detail"; fi
done <<<"$verdicts"
grep -q "^GRAB:src/popups/RightPanel.qml PASS" <<<"$verdicts" \
    && ok "the right-notch panel is checked as a grabbing popup" \
    || bad "the right-notch panel was not checked as a grabbing popup"

echo "── self-test: can these checks fail? ──"
MW="$(mktemp -d)"; trap 'rm -rf "$MW"' EXIT INT TERM
mutant() {   # mutant <label> <file> <old> <new> <rule that must FAIL, with its file>
    rm -rf "$MW/t"; mkdir -p "$MW/t"; cp -r src "$MW/t/src"
    if ! python3 - "$MW/t/$2" "$3" "$4" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if old not in s: sys.exit(3)
open(p, "w").write(s.replace(old, new, 1))
PY
    then bad "self-test $1: the mutation did not apply"; return; fi
    if check_tree "$MW/t" | grep -q "^$5 FAIL"; then ok "self-test $1: caught"
    else bad "self-test $1: SURVIVED"; fi
}
mutant "the right panel back in its corner" src/popups/RightPanel.qml \
       "    anchors.left:   !root.life.parked
    anchors.bottom: !root.life.parked
" "" FULLSCREEN:src/popups/RightPanel.qml
mutant "a parked Dashboard that can still hold the keyboard" src/popups/Dashboard.qml \
       "(wantsFocus || life.closing && Popups.anyOpen) && !life.parked ?" "(wantsFocus || life.closing && Popups.anyOpen) ?" FULLSCREEN:src/popups/Dashboard.qml
mutant "the power menu masking only its body" src/popups/ArchMenu.qml \
       "mask: Region { item: life.parked ? null : root.grabbing ? outside : hit }" "mask: Region { item: hit }" \
       INPUT:src/popups/ArchMenu.qml
mutant "quick controls grabbing without the catcher's condition" src/popups/QuickControl.qml \
       "WlrLayershell.keyboardFocus: (root.grabbing || life.closing && Popups.anyOpen) && !life.parked ? WlrKeyboardFocus.Exclusive" \
       "WlrLayershell.keyboardFocus: (Popups.quickOpen || life.closing && Popups.anyOpen) && !life.parked ? WlrKeyboardFocus.Exclusive" \
       GRAB:src/popups/QuickControl.qml
mutant "a kept power menu that lets go of the keys at once" src/popups/ArchMenu.qml \
       "(root.grabbing || life.closing && Popups.anyOpen) && !life.parked ?" "root.grabbing && !life.parked ?" \
       GRAB:src/popups/ArchMenu.qml
mutant "a catcher that closes nothing" src/popups/ClipboardPopup.qml \
       "        onClicked: Popups.closeAll()
    }

    mask:" "    }

    mask:" GRAB:src/popups/ClipboardPopup.qml

echo
echo "check-exclusive-focus: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
