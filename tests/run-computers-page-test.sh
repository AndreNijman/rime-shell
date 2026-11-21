#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-computers-page-test.sh — your other paired Rime computers, on the
#  Dashboard's Phone page and in Settings → Paired devices, in a real
#  Quickshell, against a stub `rime` that records every argv and every byte of
#  stdin, and keeps a list of computers that its own verbs change.
#
#  What it proves, per phase:
#
#    dash      nothing runs before the page is shown, and nothing asks the
#              phone while Computers is the section; the list parsed: online,
#              asleep, introduced, a removed one left out; a hostile name
#              (`$(touch …)`, backquotes, <b>, a newline, a direction
#              override) shown as plain text on one line; "Open link there"
#              with an https link on the clipboard sends it on STANDARD INPUT
#              and in no argv; the computer with the hostile name, not yet
#              allowed, offers neither "Open link there" nor "Send file…"
#              (only "Allow it in Settings") and the service refuses both;
#              once allowed it offers the link, and its "busy" answer names
#              it as plain text; with ftp://,
#              javascript: or text on the
#              clipboard it runs no `open` and asks for a link; a typed ftp
#              link is refused with nothing run; a typed link goes on stdin;
#              the other computer's "busy" answer is shown; "Send file…" runs
#              the file dialog, then `computers send -- ID PATH`; a list read
#              keeps the cards (a half-typed link survives it); the list is
#              read again while the page shows, and never after it closes.
#    alone     no phone paired: Computers is the whole page, with no tabs;
#              and a rime-remoted from before handoff cards (no `handoff` in
#              the list): no "Open link there", files still offered.
#    old       an older rime with no `computers` verb: no Computers tab, the
#              phone's page as before, no error shown.
#    settings  each of the four switches runs its exact command (the
#              clipboard's two switches as one word); a switch changed while
#              an older list read is running is shown as changed once that
#              read ends (read again, never left stale); a refused switch shows
#              the CLI's sentence and snaps back; an introduced computer's
#              switches are off with the reason and running them does nothing;
#              Allow; Remove needs a second click, shows a refusal in the
#              CLI's own words, and then removes; a list read keeps the rows.
#
#  After every phase: no file named PWNED/PWNED2 exists anywhere the hostile
#  name could have made one.
#
#  Every computer id here that can begin with "-" does: the Shell must pass it
#  after "--", never where the CLI's option parser would take it for a flag.
#
#  Pictures: RIME_CP_SHOTS=<dir> saves the Dashboard page and the Settings page.
#  RIME_CP_ONLY="<phase> …" runs only the phases named.
#
#  Headless: a private runtime dir, HOME and Wayland socket (tests/lib/
#  headless.sh). Nothing touches the live Shell, a real rime-remoted, the real
#  clipboard, another computer or a relay.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

. "$here/lib/headless.sh"

headless_require quickshell python3

W=""
staged="$root/.computers-page-test.qml"
cleanup() {
    rm -f "$staged"
    rm -f "$root/PWNED" "$root/PWNED2"
    [[ -n "$W" ]] && rm -rf "$W"
    headless_cleanup
    return 0
}
trap cleanup EXIT INT TERM

headless_begin
W="$(mktemp -d)"
CALLS="$W/calls.log"
STDIN_LOG="$W/stdin.log"
STATE="$W/computers.json"

# ── The stub rime ────────────────────────────────────────────────────────────
cat > "$HEADLESS_W/bin/rime" <<'STUB'
#!/usr/bin/env bash
# One line per run: the argv, each argument in [brackets] so a boundary shows.
line=""
for a in "$@"; do line+="[$a]"; done
printf '%s\n' "$line" >> "$RIME_CP_CALLS"

[[ "${1:-}" == "remote" ]] || exit 0
scene="${RIME_CP_SCENE:-dash}"
PHONE="-PhoneAQIDBAUGBwg"

case "${2:-}" in
devices)
    [[ "$scene" == alone ]] && { echo '[]'; exit 0; }
    cat <<JSON
[
  {"id":"$PHONE","name":"Pixel 8","public_key":"AAAA","paired_ms":1789000000000,
   "last_seen_ms":1789155000000,"revoked_ms":null,"requires_user_verification":true,
   "last_path":"lan","companion":false,
   "phone":{"battery":62,"charging":true,"can":["ring","receive","focus","messages"],
            "network":{"type":"wifi","signal":3},"reported_ms":1789155000000}}
]
JSON
    ;;
status)
    conns='[{"device_id":"'"$PHONE"'","device_name":"Pixel 8","path":"lan","rtt_ms":12,"since_ms":1789155000000,"quality":"good","disclosure":"full"}]'
    [[ "$scene" == alone ]] && conns='[]'
    cat <<JSON
{"version":1,"key":"AAAA","machine":"test","lan":[],"relay":null,"rendezvous":"r","paired":1,
 "offer_ms_left":null,"connections":$conns}
JSON
    ;;
messages)
    echo '{"device":"Pixel 8","threads":[],"changed_ms":1789154900000}'
    ;;
computers)
    if [[ "$scene" == old ]]; then
        # clap's answer from a rime built before `computers` existed.
        echo "error: unrecognized subcommand 'computers'" >&2
        exit 2
    fi
    if [[ "${3:-}" == open ]]; then
        url="$(cat)"
        printf '%s\n<<END>>\n' "$url" >> "$RIME_CP_STDIN"
    fi
    exec python3 "$RIME_CP_PY" "${@:3}"
    ;;
esac
exit 0
STUB
chmod +x "$HEADLESS_W/bin/rime"

# The computers half: a list in a file, which the verbs change, answered in
# the shape `rime remote computers list --json` prints (a pretty JSON array of
# rime_remote_core::peer::Listed). Times are relative to now, so "online"
# (reached in the last twenty minutes) means the same on every run.
cat > "$W/computers.py" <<'PY'
import json, os, sys, time
state_path = os.environ["RIME_CP_STATE"]
W = os.path.dirname(state_path)
args = [a for a in sys.argv[1:] if a not in ("--", "--json")]
verb, rest = args[0], args[1:]
state = json.load(open(state_path))
now = int(time.time() * 1000)

def save():
    json.dump(state, open(state_path, "w"))
def find(cid):
    for c in state:
        if c["id"] == cid:
            return c
    print("rime: no paired computer is called %s" % cid, file=sys.stderr)
    sys.exit(1)
def refused(what):
    if os.path.exists(os.path.join(W, "refuse-" + what)):
        print("rime: a scheduled-job request cannot change a paired computer. "
              "Do it from a terminal or Rime Settings.", file=sys.stderr)
        sys.exit(1)

if verb == "list":
    # A slow read, while the test's flag file exists, answering with the list
    # as it was when the read began: the window in which an action finishes
    # while a read that predates it is still running.
    if os.path.exists(os.path.join(W, "slow-list")):
        time.sleep(1.2)
    out = []
    for c in state:
        row = {k: v for k, v in c.items() if not k.startswith("_")}
        if "_seen_ago" in c:
            row["last_seen_ms"] = now - c["_seen_ago"]
            if "presence" in c:
                row["presence_ms"] = now - c["_seen_ago"]
        trusted = not row.get("introduced_by") or row.get("allowed_ms")
        if not trusted or row.get("revoked_ms"):
            # effective switches: an untrusted computer gets nothing
            row["clipboard_send"] = row["clipboard_receive"] = row["files"] = False
            row["handoff"] = False
        if os.environ.get("RIME_CP_SCENE") == "alone":
            # a rime-remoted from before handoff cards lists no `handoff`
            row.pop("handoff", None)
        out.append(row)
    print(json.dumps(out, indent=2))
elif verb == "clipboard":
    refused("switch")
    c = find(rest[0]); word = rest[1]
    c["clipboard_send"] = word in ("on", "send")
    c["clipboard_receive"] = word in ("on", "receive")
    save()
    print("rime: %s: clipboard %s." % (c["name"], word), file=sys.stderr)
elif verb in ("files", "handoff"):
    refused("switch")
    c = find(rest[0])
    c[verb] = rest[1] == "on"
    save()
    print("rime: %s: %s %s." % (c["name"], verb, rest[1]), file=sys.stderr)
elif verb == "allow":
    c = find(rest[0])
    c["allowed_ms"] = now
    save()
    print("rime: %s is allowed: it is now as trusted as one you paired here." % c["name"], file=sys.stderr)
elif verb == "remove":
    if os.path.exists(os.path.join(W, "refuse-remove")):
        print("rime: a scheduled-job request cannot remove a paired computer. "
              "Remove it from a terminal or Rime Settings.", file=sys.stderr)
        sys.exit(1)
    c = find(rest[0])
    c["revoked_ms"] = now
    save()
    print("rime: %s is removed, here and there." % c["name"], file=sys.stderr)
elif verb == "send":
    c = find(rest[0])
    print("rime: %s has %s and saved it in its Downloads." % (c["name"], os.path.basename(rest[1])), file=sys.stderr)
elif verb == "open":
    # computers_open's --json answer: {id, name, shown, why}, exit 1 when not
    # shown. The desk shows it; the computer not allowed here does not take
    # links from us either; the laptop already has some waiting.
    c = find(rest[0])
    shown, why = True, None
    if not c["id"].startswith("-Desk"):
        shown = False
        why = "off" if c.get("introduced_by") and not c.get("allowed_ms") else "busy"
    print(json.dumps({"id": c["id"], "name": c["name"], "shown": shown, "why": why}))
    sys.exit(0 if shown else 1)
else:
    print("error: unrecognized subcommand '%s'" % verb, file=sys.stderr)
    sys.exit(2)
PY

# What a clipboard read gives: the text in $W/clip; the types say a password
# manager copied it when $W/clip-hint exists. `--watch` (the Shell's own
# clipboard watcher, if it starts) waits quietly.
cat > "$HEADLESS_W/bin/wl-paste" <<'STUB'
#!/usr/bin/env bash
W="$(dirname "$RIME_CP_STATE")"
printf '[wl-paste]' >> "$RIME_CP_CALLS"; printf '[%s]' "$@" >> "$RIME_CP_CALLS"; echo >> "$RIME_CP_CALLS"
for a in "$@"; do [[ "$a" == --watch ]] && { sleep 600; exit 0; }; done
for a in "$@"; do
    if [[ "$a" == --list-types ]]; then
        echo "text/plain;charset=utf-8"
        echo "text/plain"
        [[ -e "$W/clip-hint" ]] && echo "x-kde-passwordManagerHint"
        exit 0
    fi
done
cat "$W/clip" 2>/dev/null
exit 0
STUB
chmod +x "$HEADLESS_W/bin/wl-paste"

# The file dialog: the path in $W/pick, or nothing (cancelled).
cat > "$HEADLESS_W/bin/zenity" <<'STUB'
#!/usr/bin/env bash
W="$(dirname "$RIME_CP_STATE")"
line="[zenity]"; for a in "$@"; do line+="[$a]"; done
printf '%s\n' "$line" >> "$RIME_CP_CALLS"
cat "$W/pick" 2>/dev/null
exit 0
STUB
chmod +x "$HEADLESS_W/bin/zenity"

cp "$here/computers-page-test.qml" "$staged"

headless_start || exit 0

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

# The list every phase starts from.
seed() {
    python3 - "$STATE" <<'PY'
import json, sys
hostile = "<b>Bold</b> $(touch PWNED) `touch PWNED2`\nline two\u202egnp.exe"
state = [
    {"id": "-DeskAQIDBAUGBwg", "name": "Desk", "public_key": "-DeskAQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRo",
     "paired_ms": 1789000000000, "_seen_ago": 120000, "revoked_ms": None,
     "requires_user_verification": False, "last_path": "lan", "addresses": ["192.168.1.20:47321"],
     "presence": {"name": "Desk", "battery": {"percent": 80, "charging": True}, "on_ac": True,
                  "power_mode": "balanced", "locked": False, "network": "wifi", "uptime_s": 7200},
     "clipboard_send": False, "clipboard_receive": False, "files": True, "handoff": False},
    {"id": "LaptAQIDBAUGBwgJ", "name": "Laptop", "public_key": "x", "paired_ms": 1789000000000,
     "_seen_ago": 3600000, "revoked_ms": None, "requires_user_verification": False,
     "last_path": "relay", "clipboard_send": True, "clipboard_receive": True, "files": False, "handoff": True},
    {"id": "IntrAQIDBAUGBwgJ", "name": hostile, "public_key": "y", "paired_ms": 1789000000000,
     "last_seen_ms": None, "revoked_ms": None, "requires_user_verification": False,
     "introduced_by": {"id": "-PhoneAQIDBAUGBwg", "name": "Pixel 8"},
     "clipboard_send": True, "clipboard_receive": True, "files": True, "handoff": True},
    {"id": "GoneAQIDBAUGBwgJ", "name": "Old desk", "public_key": "z", "paired_ms": 1, "last_seen_ms": 2,
     "revoked_ms": 3, "requires_user_verification": False, "handoff": True},
]
json.dump(state, open(sys.argv[1], "w"))
PY
}

no_pwned() {
    local name="$1" d hit=""
    for d in "$root" "$W" "$HOME" "$XDG_RUNTIME_DIR" "$HEADLESS_W" "/tmp"; do
        [[ -e "$d/PWNED" || -e "$d/PWNED2" ]] && hit+=" $d"
    done
    if [[ -z "$hit" ]]; then
        ok "$name: the hostile name executed nothing (no PWNED, PWNED2)"
    else
        bad "$name: the hostile name ran a command: PWNED in$hit"
    fi
}

phase() {
    local name="$1" want="$2"
    # RIME_CP_ONLY="dash settings" runs only those phases (for mutation runs).
    [[ -n "${RIME_CP_ONLY:-}" && " $RIME_CP_ONLY " != *" $name "* ]] && return 0
    local log="$W/$name.log"
    : > "$CALLS"
    : > "$STDIN_LOG"
    rm -f "$W/clip" "$W/clip-hint" "$W/pick" "$W/refuse-switch" "$W/refuse-remove" "$W/slow-list"
    seed

    echo
    echo "── $name ────────────────────────────────────────────────"

    ( cd "$root" && env \
        RIME_CP_SCENE="$name" \
        RIME_CP_CALLS="$CALLS" \
        RIME_CP_STDIN="$STDIN_LOG" \
        RIME_CP_STATE="$STATE" \
        RIME_CP_PY="$W/computers.py" \
        RIME_CP_W="$W" \
        RIME_CP_SHOTS="${RIME_CP_SHOTS:-}" \
        RIME_COMPUTERS_POLL_MS=700 \
        RIME_PHONE_POLL_MS=700 \
        QT_LOGGING_RULES="qml=true" \
        timeout 180 quickshell -p "$staged" ) > "$log" 2>&1

    sed -i -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*\(DEBUG\|WARN\) qml: //' "$log"
    [[ -n "${RIME_CP_KEEP:-}" ]] && cp "$log" "$RIME_CP_KEEP/"
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

phase dash     39
phase alone     6
phase old       6
phase settings 36

echo
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
