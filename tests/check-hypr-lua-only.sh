#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  check-hypr-lua-only.sh — the shell talks to Hyprland in Lua only, and says
#  so loudly when the config it needs is not the one running.
#
#  Hyprland's only config manager is Lua (0.55+): the .conf parser is gone and
#  the keyword request is refused. The shell used to keep a "conf" dialect,
#  chosen by a probe that read "conf" until it answered, so against a Lua
#  Hyprland every one of those writes was a silent no-op. This suite runs the
#  code the shell ships, not a copy of it:
#
#    LUASTR    HyprlandBackend._luaStr escapes a value into a Lua string the
#              way rime-os lua_str does (\\, \", \ddd for control bytes), and
#              luajit reads every vector back to the exact bytes;
#    SHADER    setScreenShader with a file name full of quotes, `$(...)` and a
#              newline: the expression hyprctl receives sets screen_shader to
#              exactly that name, and runs nothing;
#    WRITES    setGaps / setAccentBorder / setLayout go through `hyprctl eval`
#              only, and refuse a value that would be spliced in as code;
#    PROBE     HyprlandBackend's config probe maps each reply Hyprland can
#              give to the right state (ok, no-config, not-lua,
#              modules-missing, unknown);
#    INSTALL   install.sh and dots-extra/install-arch.sh refuse a home that
#              has only a hyprland.conf, name rime-hypr-migrate, and change
#              nothing;
#    COLOURS   matugen's Hyprland output is a Lua module Hyprland accepts
#              (verified with `Hyprland --verify-config` when installed);
#    NOKEYWORD nothing under src/ uses the keyword request or the old dialect
#              switch.
#    DISPATCH  every dispatch under src/ is an hl.dsp.* expression: under Lua
#              `hyprctl dispatch X` is `return hl.dispatch(X)`, so a hyprlang
#              word (`dispatch exit`) is refused. compositor.sh's logout and
#              dpms commands are evaluated with luajit against a stub hl.dsp
#              that has only the dispatchers 0.57 registers for them.
#
#  Then a self-test: each rule is run against a mutated copy of the tree and
#  must FAIL there.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${ROOT:-$(cd "$here/.." && pwd)}"
ONLY="${ONLY:-}"

pass=0; fail=0
ok()  { echo "  ok   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL $1"; fail=$((fail + 1)); }
want() { local label="$1"; shift; if "$@"; then ok "$label"; else bad "$label"; fi; }
run_rule() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

command -v node >/dev/null || { echo "check-hypr-lua-only: SKIP (no node)"; exit 0; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

HB="$ROOT/src/services/compositor/HyprlandBackend.qml"

# A harness that lifts named functions out of HyprlandBackend.qml and runs
# them with a recording `root`. QML function bodies are plain JS; the ones
# used here only reach root.*, console and template literals.
cat > "$tmp/harness.js" <<'JS'
const fs = require("fs")
const src = fs.readFileSync(process.argv[2], "utf8")
function lift(name) {
    const re = new RegExp("\\n    function " + name + "\\s*\\(([^)]*)\\)\\s*\\{")
    const m = re.exec(src)
    if (!m) throw new Error("no function " + name)
    const start = m.index + m[0].length
    const end = src.indexOf("\n    }\n", start)
    const params = m[1].split(",").map(s => s.trim()).filter(Boolean)
    return new Function("root", "console", ...params, src.slice(start, end))
}
const calls = []
const warnings = []
const root = {
    _accentHex: "", _pacingLog: false, layouts: ["dwindle", "master"], layoutName: "",
    screenShader: "",
    _accentProc: "accent", _gapsWriteProc: "gaps", _layoutWriteProc: "layout",
    _shaderApplyProc: "shader", _submapProc: "submap", _layerRulesProc: "rules",
    _start(proc, argv) { calls.push({ proc, argv }) },
}
const quiet = { warn: m => warnings.push(String(m)), info() {}, log() {}, error: m => warnings.push(String(m)) }
for (const n of ["_luaStr", "_shaderName", "setScreenShader", "setGaps",
                 "setAccentBorder", "_pushAccent", "setLayout"]) {
    const f = lift(n)
    root[n] = (...a) => f(root, quiet, ...a)
}
const op = process.argv[3]
const args = JSON.parse(process.argv[4] || "[]")
if (op === "luaStr") {
    process.stdout.write(JSON.stringify(args.map(v => root._luaStr(v))))
} else {
    root[op](...args)
    process.stdout.write(JSON.stringify({ calls, warnings }))
}
JS

hb() { node "$tmp/harness.js" "$HB" "$@"; }

# ── LUASTR ───────────────────────────────────────────────────────────────────
if run_rule LUASTR; then
    # The expected literals are rime-os lua_str's output for the same inputs
    # (files/system/libexec/rime-display-apply, between its lua_str markers).
    vec='["plain", "a\"b", "back\\\\slash", "line\nbreak", "tab\there", "del\u007f", "]] [[ x", "it'"'"'s", "nul\u0000x"]'
    got="$(hb luaStr "$vec" 2>&1)"
    exp='["\"plain\"","\"a\\\"b\"","\"back\\\\\\\\slash\"","\"line\\010break\"","\"tab\\009here\"","\"del\\127\"","\"]] [[ x\"","\"it'"'"'s\"","\"nul\\000x\""]'
    want "LUASTR _luaStr escapes like rime-os lua_str" test "$got" = "$exp"
    [ "$got" = "$exp" ] || { echo "        got $got"; echo "        exp $exp"; }
    if command -v luajit >/dev/null; then
        # Read each literal back through Lua: the bytes must survive exactly.
        rt_ok=1
        while IFS=$'\t' read -r hex lit; do
            back="$(luajit -e "io.write((($lit):gsub('.', function(c) return string.format('%02x', c:byte()) end)))" 2>&1)"
            [ "$back" = "$hex" ] || { echo "        $lit -> $back, want $hex"; rt_ok=0; }
        done < <(node -e '
            const v = JSON.parse(process.argv[1]), l = JSON.parse(process.argv[2])
            v.forEach((x, i) => console.log(Buffer.from(x, "utf8").toString("hex") + "\t" + l[i]))' "$vec" "$got")
        want "LUASTR luajit reads every literal back to the same bytes" test "$rt_ok" -eq 1
    else
        echo "  skip LUASTR round trip (no luajit)"
    fi
fi

# ── SHADER ───────────────────────────────────────────────────────────────────
if run_rule SHADER; then
    evil=$'/tmp/x\'] os.execute("touch PWNED") --"$(touch PWNED2).glsl'
    out="$(hb setScreenShader "$(node -e 'console.log(JSON.stringify([process.argv[1]]))' "$evil")")"
    mkdir -p "$tmp/shader/bin"
    cat > "$tmp/shader/bin/hyprctl" <<'SH'
#!/bin/bash
# Record argv one per NUL-terminated field.
printf '%s\0' "$@" >> "$REC"
echo ok
SH
    chmod +x "$tmp/shader/bin/hyprctl"
    : > "$tmp/shader/rec"
    argv_json="$(node -e 'const r = JSON.parse(process.argv[1]); console.log(JSON.stringify(r.calls[0].argv))' "$out")"
    # Run the exact argv the shell would, in a directory where a stray
    # command substitution would leave a file behind.
    ( cd "$tmp/shader" && PATH="$tmp/shader/bin:$PATH" REC="$tmp/shader/rec" \
        node -e 'const a = JSON.parse(process.argv[1]); require("child_process").execFileSync(a[0], a.slice(1), { stdio: "ignore" })' "$argv_json" )
    want "SHADER the file name ran nothing in the shell" test ! -e "$tmp/shader/PWNED2"
    expr="$(tr '\0' '\n' < "$tmp/shader/rec" | awk 'prev == "eval" { print; exit } { prev = $0 }')"
    want "SHADER the write is one hyprctl eval" test -n "$expr"
    if command -v luajit >/dev/null && [ -n "$expr" ]; then
        printf '%s' "$expr" > "$tmp/shader/expr.lua"
        got="$(cd "$tmp/shader" && luajit -e '
            hl = { config = function(t) io.write(t.decoration.screen_shader) end }
            os.execute = function() io.write("EXECUTED") end
            dofile("expr.lua")' 2>&1)"
        want "SHADER Lua sets screen_shader to exactly the file name" test "$got" = "$evil"
        want "SHADER Lua ran nothing from the file name" test ! -e "$tmp/shader/PWNED"
    fi
    off="$(hb setScreenShader '[""]')"
    want "SHADER off is screen_shader = \"\"" grep -qF 'screen_shader = \"\" }' <<<"$off"
fi

# ── WRITES ───────────────────────────────────────────────────────────────────
if run_rule WRITES; then
    g="$(hb setGaps '[4, 12]')"
    want "WRITES setGaps is one hyprctl eval with both gaps" \
        grep -qF '"argv":["hyprctl","eval","hl.config({ general = { gaps_in = 4, gaps_out = 12 } })"]' <<<"$g"
    g="$(hb setGaps '["1 } }) os.exit(1) --", 3]')"
    want "WRITES setGaps refuses a value that is not a number" grep -qF '"calls":[]' <<<"$g"
    a="$(hb setAccentBorder '["#a1b2c3"]')"
    want "WRITES setAccentBorder is one hyprctl eval on col.active_border" \
        grep -qF '"argv":["hyprctl","eval","hl.config({ general = { col = { active_border = { colors = { \"rgb(a1b2c3)\" } } } } })"]' <<<"$a"
    a="$(hb setAccentBorder '["a1b2c3\") } } } }) os.exit(1) --"]')"
    want "WRITES setAccentBorder refuses a value that is not a colour" grep -qF '"calls":[]' <<<"$a"
    l="$(hb setLayout '["master"]')"
    want "WRITES setLayout is one hyprctl eval" \
        grep -qF '"argv":["hyprctl","eval","hl.config({ general = { layout = \"master\" } })"]' <<<"$l"
fi

# ── PROBE ────────────────────────────────────────────────────────────────────
if run_rule PROBE; then
    node -e '
        const s = require("fs").readFileSync(process.argv[1], "utf8")
        const i = s.indexOf("property Process _hyprConfigProbe: Process {")
        if (i < 0) process.exit(2)
        const a = s.indexOf("command: [", i) + "command: ".length
        const b = s.indexOf("]\n", a) + 1
        const argv = new Function("return " + s.slice(a, b))()
        process.stdout.write(argv[2])' "$HB" > "$tmp/probe.sh" 2>/dev/null
    want "PROBE the probe lives in HyprlandBackend" test -s "$tmp/probe.sh"
    mkdir -p "$tmp/probe/bin" "$tmp/probe/home/.config/hypr"
    cat > "$tmp/probe/bin/hyprctl" <<'SH'
#!/bin/bash
[ "$1" = eval ] || exit 3
printf '%s\n' "$REPLY_TEXT"
SH
    chmod +x "$tmp/probe/bin/hyprctl"
    probe() {   # probe <has lua file 0|1> <hyprctl reply>
        rm -f "$tmp/probe/home/.config/hypr/hyprland.lua"
        [ "$1" = 1 ] && echo '-- x' > "$tmp/probe/home/.config/hypr/hyprland.lua"
        HOME="$tmp/probe/home" PATH="$tmp/probe/bin:$PATH" REPLY_TEXT="$2" bash -c "$(cat "$tmp/probe.sh")"
    }
    want "PROBE no hyprland.lua -> no-config" test "$(probe 0 ok)" = "no-config"
    want "PROBE eval ok -> ok" test "$(probe 1 ok)" = "ok"
    want "PROBE modules not loaded -> modules-missing" \
        test "$(probe 1 '[string "if package.loaded"]: rime-modules-missing')" = "modules-missing"
    r="$(probe 1 'eval is only supported with the lua config manager')"
    want "PROBE not a Lua config -> not-lua, with Hyprland's words" \
        test "$r" = "not-lua eval is only supported with the lua config manager"
    r="$(probe 1 'HYPRLAND_INSTANCE_SIGNATURE was not set')"
    want "PROBE an unreachable Hyprland -> unknown (asked again, not a verdict)" \
        test "${r%% *}" = "unknown"
fi

# ── INSTALL ──────────────────────────────────────────────────────────────────
if run_rule INSTALL; then
    # install.sh refuses a non-Arch host before it gets here, so its config
    # block is run on its own, with its own log helpers.
    sed -n '/^log_info()/,/^die()/p' "$ROOT/install.sh" > "$tmp/inst.sh"
    sed -n '/^HYPR_DIR="\$HOME\/.config\/hypr"$/,/^# STEP 2/p' "$ROOT/install.sh" >> "$tmp/inst.sh"
    echo 'echo "TARGET=$HYPRLAND_CONF"' >> "$tmp/inst.sh"
    h="$tmp/inst-conf"; mkdir -p "$h/.config/hypr"; echo 'exec-once = x' > "$h/.config/hypr/hyprland.conf"
    out="$(HOME="$h" bash "$tmp/inst.sh" 2>&1)"; rc=$?
    want "INSTALL install.sh refuses a home with only hyprland.conf" test "$rc" -ne 0
    want "INSTALL  ... and names rime-hypr-migrate" grep -q 'rime-hypr-migrate' <<<"$out"
    want "INSTALL  ... and leaves hyprland.conf as it was" \
        test "$(cat "$h/.config/hypr/hyprland.conf")" = 'exec-once = x'
    h="$tmp/inst-lua"; mkdir -p "$h/.config/hypr"; echo '-- x' > "$h/.config/hypr/hyprland.lua"
    out="$(HOME="$h" bash "$tmp/inst.sh" 2>&1)"; rc=$?
    want "INSTALL install.sh targets hyprland.lua" \
        test "$rc" -eq 0 -a "$(grep '^TARGET=' <<<"$out")" = "TARGET=$h/.config/hypr/hyprland.lua"

    h="$tmp/arch"; mkdir -p "$h/.config/hypr"; echo 'exec-once = x' > "$h/.config/hypr/hyprland.conf"
    out="$(HOME="$h" bash "$ROOT/dots-extra/install-arch.sh" "$h/.config/hypr/hyprland.conf" "$h/backup" conf 2>&1)"; rc=$?
    want "INSTALL install-arch.sh refuses a hyprland.conf" test "$rc" -ne 0
    want "INSTALL  ... before it writes anything" \
        test "$(cd "$h" && find . -type f | sort | tr '\n' ' ')" = "./.config/hypr/hyprland.conf "
    want "INSTALL  ... and names rime-hypr-migrate" grep -q 'rime-hypr-migrate' <<<"$out"
    want "INSTALL install-arch.sh writes no config_Provider.json" \
        bash -c '! grep -qE "data\\[.configProvider.\\]" "$1"' _ "$ROOT/dots-extra/install-arch.sh"
fi

# ── COLOURS ──────────────────────────────────────────────────────────────────
if run_rule COLOURS; then
    toml="$ROOT/src/config/matugen.toml.in"
    block="$(awk '/^\[templates.hyprland_colors\]/{f=1;next} /^\[/{f=0} f' "$toml")"
    want "COLOURS matugen writes ~/.config/hypr/rime/colors.lua" \
        grep -qF "output_path = '@HOME@/.config/hypr/rime/colors.lua'" <<<"$block"
    tpl_rel="$(sed -n "s|^input_path = '@SRCDIR@/\(.*\)'|\1|p" <<<"$block")"
    tpl="$ROOT/$tpl_rel"
    want "COLOURS its template exists" test -s "$tpl"
    mkdir -p "$tmp/colours/rime"
    sed 's/{{colors\.primary\.default\.hex_stripped}}/a1b2c3/g' "$tpl" > "$tmp/colours/rime/colors.lua" 2>/dev/null
    want "COLOURS the rendered module has no template tag left" \
        bash -c '! grep -q "{{" "$1"' _ "$tmp/colours/rime/colors.lua"
    if command -v luajit >/dev/null; then
        got="$(cd "$tmp/colours" && luajit -e '
            hl = { config = function(t) io.write(t.general.col.active_border.colors[1]) end }
            dofile("rime/colors.lua")' 2>&1)"
        want "COLOURS the module sets the active border to the accent" test "$got" = "rgb(a1b2c3)"
    fi
    if command -v Hyprland >/dev/null && [ "$(id -u)" -ne 0 ]; then
        echo 'require("rime.colors")' > "$tmp/colours/hyprland.lua"
        v="$(XDG_RUNTIME_DIR="$tmp/colours" timeout 60 Hyprland --i-am-really-stupid --verify-config \
                --config "$tmp/colours/hyprland.lua" 2>&1)"
        want "COLOURS Hyprland --verify-config accepts it" grep -q 'config ok' <<<"$v"
    else
        echo "  skip COLOURS Hyprland --verify-config (no Hyprland, or root)"
    fi
fi

# ── NOKEYWORD ────────────────────────────────────────────────────────────────
if run_rule NOKEYWORD; then
    hits="$(grep -rnE "hyprctl[\"', ]+keyword" "$ROOT/src" 2>/dev/null)"
    want "NOKEYWORD nothing under src/ uses the keyword request" test -z "$hits"
    [ -z "$hits" ] || sed 's/^/        /' <<<"$hits"
    hits="$(grep -rnE 'configProvider|root\._lua\b' "$ROOT/src" 2>/dev/null)"
    want "NOKEYWORD nothing under src/ branches on the old dialect switch" test -z "$hits"
    [ -z "$hits" ] || sed 's/^/        /' <<<"$hits"
fi

# ── DISPATCH ─────────────────────────────────────────────────────────────────
if run_rule DISPATCH; then
    # The word after `dispatch` must open an hl.* expression or be a variable.
    hits="$(grep -rnE "hyprctl[\"', ]+dispatch[\"'\`, ]+" "$ROOT/src" 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|#)' \
        | grep -vE "hyprctl[\"', ]+dispatch[\"'\`, ]+(hl\.|\\\$)" )"
    want "DISPATCH every hyprctl dispatch under src/ is an hl.dsp expression" test -z "$hits"
    [ -z "$hits" ] || sed 's/^/        /' <<<"$hits"
    hits="$(grep -rnE 'Hyprland\.dispatch\(' "$ROOT/src" 2>/dev/null \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' | grep -v 'hl\.dsp\.')"
    want "DISPATCH every Hyprland.dispatch() under src/ is an hl.dsp expression" test -z "$hits"
    [ -z "$hits" ] || sed 's/^/        /' <<<"$hits"
    if command -v luajit >/dev/null 2>&1; then
        lua_dispatch_ok() {   # <verb args...>: the hyprland command parses and names a real dispatcher
            local expr
            expr="$(bash -c '. "$1/src/scripts/compositor.sh"; shift; "$@" || exit 1
                [ "${RIME_CMD[0]}" = hyprctl ] && [ "${RIME_CMD[1]}" = dispatch ] || exit 1
                printf %s "${RIME_CMD[2]}"' _ "$ROOT" "$@")" || return 1
            EXPR="$expr" luajit -e '
                local called = {}
                hl = { dsp = setmetatable({
                    exit = function() called.exit = true; return true end,
                    dpms = function(t)
                        assert(type(t) == "table" and (t.action == "enable" or t.action == "disable"),
                               "dpms wants { action = enable|disable }")
                        called.dpms = t.action; return true
                    end,
                }, { __index = function(_, k) error("no hl.dsp." .. k .. " in 0.57") end }) }
                local f = assert(loadstring("return " .. os.getenv("EXPR")))
                assert(f())' >/dev/null 2>&1
        }
        want "DISPATCH logout on Hyprland is a dispatcher 0.57 has" lua_dispatch_ok rime_logout_command hyprland
        want "DISPATCH screen-on on Hyprland is a dispatcher 0.57 has" lua_dispatch_ok rime_dpms_command hyprland on
        want "DISPATCH screen-off on Hyprland is a dispatcher 0.57 has" lua_dispatch_ok rime_dpms_command hyprland off
    else
        echo "  SKIP DISPATCH luajit evaluation (no luajit)"
    fi
fi

# ── Self-test: each rule fails on a tree that breaks it ──────────────────────
if [ -z "$ONLY" ]; then
    echo "── self-test: can these checks fail? ──"
    mutant() {   # mutant <label> <file> <old> <new> <rule>
        local label="$1" file="$2" old="$3" new="$4" rule="$5" m="$tmp/mut"
        rm -rf "$m"; mkdir -p "$m"
        cp -r "$ROOT/src" "$ROOT/install.sh" "$ROOT/dots-extra" "$m/"
        if ! python3 - "$m/$file" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if old not in s: sys.exit(1)
open(p, "w").write(s.replace(old, new, 1))
PY
        then bad "self-test $label: the mutation did not apply"; return; fi
        if ROOT="$m" ONLY="$rule" bash "$0" >/dev/null 2>&1; then
            bad "self-test $label: NOT caught by $rule"
        else
            ok "self-test $label: caught"
        fi
    }
    mutant "a quote left unescaped" src/services/compositor/HyprlandBackend.qml \
        "else if (ch === '\"')   out += '\\\\\"'" "else if (false)   out += ''" LUASTR
    mutant "the shader name spliced into the Lua source" src/services/compositor/HyprlandBackend.qml \
        'screen_shader = ${root._luaStr(off ? "" : path)}' "screen_shader = '\${off ? \"\" : path}'" SHADER
    mutant "gaps written without the number check" src/services/compositor/HyprlandBackend.qml \
        'if (!isFinite(i) || !isFinite(o)) {' 'if (false) {' WRITES
    mutant "the keyword request back in setGaps" src/services/compositor/HyprlandBackend.qml \
        'root._start(root._gapsWriteProc, ["hyprctl", "eval",' 'root._start(root._gapsWriteProc, ["hyprctl", "keyword",' WRITES
    mutant "a probe that never looks for the file" src/services/compositor/HyprlandBackend.qml \
        '+ "[ -f \"$f\" ] || { echo no-config; exit 0; }; "' '+ ""' PROBE
    mutant "install.sh appending to a hyprland.conf again" install.sh \
        'die "No hyprland.lua in $HYPR_DIR. Nothing was changed."' 'HYPRLAND_CONF="$HYPR_DIR/hyprland.conf"' INSTALL
    mutant "matugen writing the orphan .conf again" src/config/matugen.toml.in \
        "output_path = '@HOME@/.config/hypr/rime/colors.lua'" "output_path = '@HOME@/.config/hypr/rime-shell-colors.conf'" COLOURS
    mutant "a hyprlang colour template" src/config/hypr-colors.lua.template \
        'hl.config({ general = { col = { active_border = { colors = { "rgb({{colors.primary.default.hex_stripped}})" } } } } })' \
        '$primary = {{colors.primary.default.hex_stripped}}' COLOURS
    mutant "a keyword write in a script" src/scripts/compositor.sh \
        'RIME_CMD=()' 'RIME_CMD=(hyprctl keyword general:gaps_in 0)' NOKEYWORD
    mutant "a hyprlang logout dispatch" src/scripts/compositor.sh \
        "RIME_CMD=(hyprctl dispatch 'hl.dsp.exit()')" 'RIME_CMD=(hyprctl dispatch exit)' DISPATCH
    mutant "a hyprlang dpms dispatch" src/scripts/compositor.sh \
        "RIME_CMD=(hyprctl dispatch 'hl.dsp.dpms({ action = \"disable\" })')" 'RIME_CMD=(hyprctl dispatch dpms off)' DISPATCH
    mutant "a dispatcher 0.57 does not have" src/scripts/compositor.sh \
        "RIME_CMD=(hyprctl dispatch 'hl.dsp.exit()')" "RIME_CMD=(hyprctl dispatch 'hl.dsp.quit()')" DISPATCH
    mutant "dpms with a hyprlang action word" src/scripts/compositor.sh \
        'hl.dsp.dpms({ action = "enable" })' 'hl.dsp.dpms({ action = "on" })' DISPATCH
fi

echo
echo "check-hypr-lua-only: passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
