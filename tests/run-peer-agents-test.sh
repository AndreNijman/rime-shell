#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-peer-agents-test.sh — agent sessions on this person's other Rime
#  computers (M4): the Agent Center's "Your computers" section and the agents
#  rows in Settings → Paired devices, in a real Quickshell, against a stub
#  `rime` that records every argv, a stub terminal (`xdg-terminal-exec`) that
#  records what it was asked to run and opens nothing, and a stub `wl-copy`.
#
#  What it proves, per phase:
#
#    centre    nothing runs before the Agent Center is shown; only the
#              computers that are active, trusted and claim view or control
#              are asked (`computers agents --json -- ID`, exact argv), never
#              one that claims off, an introduced one not allowed yet, or a
#              removed one; each shows its sessions, live first; a hostile
#              title/name/cwd (`$(touch PWNED)`, <b>, an escape sequence, a
#              newline, a line separator, a direction override) is drawn as
#              plain text on one line and runs nothing; an unreachable
#              computer and one whose claim is stale (it refuses) each show
#              one fixed quiet line, in the quiet colour; Peek runs
#              `computers peek --json -- ID N` and shows its text, plain, in
#              a read-only pane; Attach is offered only with control and only
#              for a live session, and opens the terminal with exactly
#              `rime remote computers attach -- ID N`; the service refuses an
#              attach for a view computer, a finished session or one it never
#              listed; the sweep repeats while shown and never starts sooner
#              than the computer list's own interval; hiding the Agent Center
#              kills the call in flight and runs nothing more.
#    settings  "Its agents on this computer" shows `agents` in words; "Turn
#              off" runs exactly `computers grant -- ID agents off` and the
#              row reads Off after; there is no control that raises it: each
#              higher level is shown as the exact terminal command (by id,
#              never the name) with Copy, which hands it to wl-copy as one
#              argument; nothing ever runs a grant other than off, or --yes;
#              an introduced computer may be turned off but is offered no
#              raise; "Your agents on it" shows the other computer's claim and
#              how long ago it was heard; a list without the fields (an older
#              rime-remoted) shows no agents rows.
#
#  After every phase: no file named PWNED exists anywhere the hostile text
#  could have made one.
#
#  Pictures: RIME_PA_SHOTS=<dir>. RIME_PA_ONLY="<phase> …" runs only those.
#
#  Headless: a private runtime dir, HOME and Wayland socket (tests/lib/
#  headless.sh). Nothing touches the live Shell, a real rime-remoted, another
#  computer, the real clipboard or a real terminal.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

. "$here/lib/headless.sh"

headless_require quickshell python3

W=""
staged="$root/.peer-agents-test.qml"
cleanup() {
    rm -f "$staged"
    rm -f "$root/PWNED"
    [[ -n "$W" ]] && rm -rf "$W"
    headless_cleanup
    return 0
}
trap cleanup EXIT INT TERM

headless_begin
W="$(mktemp -d)"
CALLS="$W/calls.log"
STATE="$W/computers.json"

# ── The stub rime ────────────────────────────────────────────────────────────
cat > "$HEADLESS_W/bin/rime" <<'STUB'
#!/usr/bin/env bash
line=""
for a in "$@"; do line+="[$a]"; done
printf '%s\n' "$line" >> "$RIME_PA_CALLS"

case "${1:-}" in
agent)
    # One local session, so "This machine" shows above "Your computers".
    [[ "${2:-}" == list ]] && echo '[{"id":1,"agent":"claude","program":"claude","args":[],"cwd":"/home/test/rime","project":null,"project_name":"rime","name":null,"title":"Local work","state":"working","detail":null,"paused":false,"started":1789150000,"last_activity":1789155000,"exit_code":null,"exit_signal":null,"attached":1,"cols":80,"rows":24}]'
    exit 0 ;;
request) echo '[]'; exit 0 ;;
host)    echo '[]'; exit 0 ;;
remote)
    [[ "${2:-}" == computers ]] || exit 0
    # rime asks about any grant but off at a terminal (remote.rs
    # computers_grant): no terminal on stdin, no grant.
    if [[ "${3:-}" == grant && " $* " != *" off "* && ! -t 0 ]]; then
        echo "rime: giving another computer view over your agent sessions is asked about at a terminal; run it in one (with --yes to skip typing the name)" >&2
        exit 1
    fi
    exec python3 "$RIME_PA_PY" "${@:3}"
    ;;
esac
exit 0
STUB
chmod +x "$HEADLESS_W/bin/rime"

cat > "$W/computers.py" <<'PY'
import json, os, sys, time
state_path = os.environ["RIME_PA_STATE"]
W = os.path.dirname(state_path)
calls = os.environ["RIME_PA_CALLS"]
args = [a for a in sys.argv[1:] if a not in ("--", "--json")]
verb, rest = args[0], args[1:]
state = json.load(open(state_path))
now = int(time.time() * 1000)

HOSTILE = "$(touch PWNED) <b>bold</b> \u001b[31mred\u001b[0m\nline two\u2028three\u202eevil"

def find(cid):
    for c in state:
        if c["id"] == cid:
            return c
    print(json.dumps({"error": "no paired computer is called %s" % cid}))
    print("rime: no paired computer is called %s" % cid, file=sys.stderr)
    sys.exit(1)

def session(i, state_, title=None, name=None, cwd="/home/a/rime", project_name=None, exited=False, started=100, last=200):
    return {"id": i, "agent": "claude", "program": "claude", "args": [HOSTILE], "cwd": cwd, "project": None,
            "project_name": project_name, "name": name, "title": title, "state": state_, "detail": None,
            "paused": False, "started": int(time.time()) - started, "last_activity": int(time.time()) - last,
            "exit_code": 0 if exited else None, "exit_signal": None, "attached": 0, "cols": 80, "rows": 24,
            "request_origin": "local_terminal", "actor": None, "children": []}

SESSIONS = {
    "-DeskAQIDBAUGBwg": [
        session(2, "complete", title="Old build", exited=True, started=9000, last=8000),
        session(3, "working", title="Fixing the tests", project_name="rime", started=600, last=5),
        session(7, "waiting_for_user", title="t", name=HOSTILE, cwd="/home/a/" + HOSTILE, project_name=HOSTILE,
                started=300, last=60),
    ],
    "LaptAQIDBAUGBwgJ": [session(5, "working", title="Writing the docs", started=1200, last=20)],
}

if verb == "list":
    out = []
    for c in state:
        row = {k: v for k, v in c.items() if not k.startswith("_")}
        if "_claim_ago" in c:
            row["can_agents_ms"] = now - c["_claim_ago"]
        out.append(row)
    print(json.dumps(out, indent=2))
elif verb == "agents":
    cid = rest[0]
    c = find(cid)
    with open(os.path.join(W, "times.log"), "a") as f:
        f.write("%s %d\n" % (cid, now))
    if cid.startswith("-Desk") and os.path.exists(os.path.join(W, "slow-agents")):
        with open(calls, "a") as f:
            f.write("[slow-start]\n")
        time.sleep(3)
        with open(calls, "a") as f:
            f.write("[slow-done]\n")
    if cid.startswith("Away"):
        print(json.dumps({"error": "could not reach 'Away': no route to it (it may be asleep or off)"}))
        print("rime: could not reach 'Away'", file=sys.stderr)
        sys.exit(1)
    if cid.startswith("Stale"):
        msg = ("'Stale' does not let this computer see its agent sessions. A person there can allow it with "
               "`rime remote computers grant <this computer> agents view`")
        print(json.dumps({"error": msg}))
        print("rime: " + msg, file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"id": cid, "name": c["name"], "sessions": SESSIONS.get(cid, []),
                      "truncated": False, "unreadable": 0}))
elif verb == "peek":
    cid, n = rest[0], int(rest[1])
    c = find(cid)
    # The CLI has already taken escapes out (remote.rs peek_text); a stray
    # control character and the hostile text still come through as text.
    text = "$ cargo test\nrunning 12 tests\n" + HOSTILE.replace("\u001b", "") + "\ntest result: ok\n\n"
    print(json.dumps({"id": cid, "name": c["name"], "session": n, "text": text, "cols": 80, "rows": 24,
                      "state": "waiting_for_user"}))
elif verb == "grant":
    cid, what, level = rest[0], rest[1], rest[2]
    c = find(cid)
    c["agents"] = level
    json.dump(state, open(state_path, "w"))
    print("rime: %s (%s) may not reach your agent sessions here." % (c["name"], cid), file=sys.stderr)
else:
    print("error: unrecognized subcommand '%s'" % verb, file=sys.stderr)
    sys.exit(2)
PY

# The terminal: records what it was asked to run, opens nothing.
cat > "$HEADLESS_W/bin/xdg-terminal-exec" <<'STUB'
#!/usr/bin/env bash
line="[xdg-terminal-exec]"; for a in "$@"; do line+="[$a]"; done
printf '%s\n' "$line" >> "$RIME_PA_CALLS"
exit 0
STUB
chmod +x "$HEADLESS_W/bin/xdg-terminal-exec"

cat > "$HEADLESS_W/bin/wl-copy" <<'STUB'
#!/usr/bin/env bash
line="[wl-copy]"; for a in "$@"; do line+="[$a]"; done
printf '%s\n' "$line" >> "$RIME_PA_CALLS"
exit 0
STUB
chmod +x "$HEADLESS_W/bin/wl-copy"

cp "$here/peer-agents-test.qml" "$staged"

headless_start || exit 0

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

seed() {
    python3 - "$STATE" "$1" <<'PY'
import json, sys
path, scene = sys.argv[1], sys.argv[2]
HOSTILE = "$(touch PWNED) <b>bold</b>\nname"
base = {"public_key": "k", "paired_ms": 1789000000000, "last_seen_ms": None, "revoked_ms": None,
        "requires_user_verification": False, "clipboard_send": False, "clipboard_receive": False,
        "files": False, "handoff": False}
def comp(**kw):
    d = dict(base); d.update(kw); return d
if scene == "centre":
    state = [
        comp(id="-DeskAQIDBAUGBwg", name="Desk", agents="off", can_agents="control", _claim_ago=60000),
        comp(id="LaptAQIDBAUGBwgJ", name="Laptop", agents="view", can_agents="view", _claim_ago=60000),
        comp(id="SpareAQIDBAUGBwg", name="Spare", agents="control", can_agents="off"),
        comp(id="IntrAQIDBAUGBwgJ", name="Intro", introduced_by={"id": "p", "name": "Pixel 8"},
             agents="off", can_agents="control"),
        comp(id="GoneAQIDBAUGBwgJ", name="Old desk", revoked_ms=3, agents="off", can_agents="control"),
        comp(id="AwayAQIDBAUGBwgJ", name="Away", agents="off", can_agents="view"),
        comp(id="StaleAQIDBAUGBwg", name="Stale", agents="off", can_agents="control"),
    ]
else:
    state = [
        comp(id="-DeskAQIDBAUGBwg", name="Desk", agents="control", can_agents="view", _claim_ago=120000),
        comp(id="LaptAQIDBAUGBwgJ", name="Laptop", agents="off", can_agents="control", _claim_ago=60000),
        comp(id="IntrAQIDBAUGBwgJ", name=HOSTILE, introduced_by={"id": "p", "name": "Pixel 8"},
             agents="view", can_agents="control"),
        comp(id="OlderAQIDBAUGBwg", name="Older"),
    ]
json.dump(state, open(path, "w"))
PY
}

no_pwned() {
    local name="$1" d hit=""
    for d in "$root" "$W" "$HOME" "$XDG_RUNTIME_DIR" "$HEADLESS_W" "/tmp"; do
        [[ -e "$d/PWNED" ]] && hit+=" $d"
    done
    if [[ -z "$hit" ]]; then
        ok "$name: the hostile text executed nothing (no PWNED)"
    else
        bad "$name: the hostile text ran a command: PWNED in$hit"
    fi
}

phase() {
    local name="$1" want="$2"
    [[ -n "${RIME_PA_ONLY:-}" && " $RIME_PA_ONLY " != *" $name "* ]] && return 0
    local log="$W/$name.log"
    : > "$CALLS"
    rm -f "$W/slow-agents" "$W/times.log"
    seed "$name"

    echo
    echo "── $name ────────────────────────────────────────────────"

    ( cd "$root" && env \
        RIME_PA_SCENE="$name" \
        RIME_PA_CALLS="$CALLS" \
        RIME_PA_STATE="$STATE" \
        RIME_PA_PY="$W/computers.py" \
        RIME_PA_W="$W" \
        RIME_PA_SHOTS="${RIME_PA_SHOTS:-}" \
        RIME_COMPUTERS_POLL_MS=1500 \
        QT_LOGGING_RULES="qml=true" \
        timeout 180 quickshell -p "$staged" ) > "$log" 2>&1

    sed -i -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*\(DEBUG\|WARN\) qml: //' "$log"
    [[ -n "${RIME_PA_KEEP:-}" ]] && cp "$log" "$RIME_PA_KEEP/"
    grep -E "^(  PASS|  FAIL|  picture)" "$log" || true

    if grep -qE "is not a type|Cannot assign|Unable to assign|Failed to load configuration|ReferenceError|TypeError" "$log"; then
        bad "the $name page built and ran without QML errors"
        grep -E "is not a type|Cannot assign|Unable to assign|Failed to load configuration|ReferenceError|TypeError" "$log" \
            | head -5 | sed 's/^/          /'
    else
        ok "the $name page built and ran without QML errors"
    fi

    no_pwned "$name"

    local summary got_pass got_fail
    summary="$(grep -o 'passed=[0-9]* failed=[0-9]*' "$log" | tail -1)"
    if [[ -z "$summary" ]]; then
        bad "$name reported a result at all"
        tail -20 "$log" | sed 's/^/          /'
        return
    fi
    got_pass="${summary#passed=}"; got_pass="${got_pass%% *}"
    got_fail="${summary##*failed=}"

    if [[ "$got_fail" -eq 0 ]]; then
        ok "$name: no assertion failed"
    else
        bad "$name: $got_fail assertion(s) failed"
    fi
    if [[ "$got_pass" -eq "$want" ]]; then
        ok "$name made all $want of its assertions"
    else
        bad "$name made $got_pass assertions, expected exactly $want"
    fi
}

phase centre   32
phase settings 14

echo
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
