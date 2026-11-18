#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
#  run-phone-page-test.sh — the Dashboard's Phone page, in a real Quickshell,
#  against a stub `rime` that records every argv and every byte of stdin.
#
#  What it proves, per phase:
#
#    full      nothing runs before the page is shown; the conversation list,
#              one conversation, an older page; a failed send that keeps the
#              draft and says why; a reply whose text goes in on
#              standard input and is in NO argv (including a newline and a
#              leading "--"); no reply box for a group; calls list, the call
#              now, dial (and a refused number that runs nothing), hang up;
#              the photo grid newest first with the partial-access note, and
#              save with the saved path; the poll runs while open, and after
#              the page closes nothing more runs and what it showed is gone.
#    off       a connected phone without the words: each section says which
#              switch to turn on, and asks the phone nothing.
#    offline   a paired phone that is not connected says so; no section runs.
#    none      nothing paired says so.
#    error     a command's refusal is shown in its own words.
#
#  Every device id here begins with "-": a base64url id can, and the page must
#  pass it as one `--device=ID` argument, never as a separate one the CLI's
#  option parser would take for a flag.
#
#  Headless: a private runtime dir, HOME and Wayland socket (tests/lib/
#  headless.sh). Nothing touches the live Shell, a real rime-remoted, the real
#  runtime folder, a phone or a relay.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"

. "$here/lib/headless.sh"

headless_require quickshell python3

W=""
staged="$root/.phone-page-test.qml"
cleanup() {
    rm -f "$staged"
    [[ -n "$W" ]] && rm -rf "$W"
    headless_cleanup
    return 0
}
trap cleanup EXIT INT TERM

headless_begin
W="$(mktemp -d)"
CALLS="$W/calls.log"
STDIN_LOG="$W/stdin.log"

# Two small real PNGs for the grid's previews, where the daemon would put them.
THUMBS="$XDG_RUNTIME_DIR/rime-remote/photos/-PhoneAQIDBAUGBwg"
mkdir -p "$THUMBS"
python3 - "$THUMBS" <<'PY'
import struct, sys, zlib
def png(path, rgb):
    raw = b"".join(b"\x00" + bytes(rgb) * 8 for _ in range(8))
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
    data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", 8, 8, 8, 2, 0, 0, 0)) \
        + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    open(path, "wb").write(data)
png(sys.argv[1] + "/5.png", (200, 40, 40))
png(sys.argv[1] + "/6.png", (40, 200, 40))
PY

cat > "$HEADLESS_W/bin/rime" <<'STUB'
#!/usr/bin/env bash
# One line per run: the argv, each argument in [brackets] so a boundary is
# visible ("--device=-x" is one argument; "--device" "-x" would be two).
line=""
for a in "$@"; do line+="[$a]"; done
printf '%s\n' "$line" >> "$RIME_PH_CALLS"

[[ "${1:-}" == "remote" ]] || exit 0
scene="${RIME_PH_SCENE:-full}"
ID="-PhoneAQIDBAUGBwg"
has() { local w; for w in "${@:2}"; do [[ "$w" == "$1" ]] && return 0; done; return 1; }

case "${2:-}" in
devices)
    case "$scene" in
    none) echo '[]' ;;
    off)  CAN='["ring","receive","focus"]' ;;
    *)    CAN='["ring","receive","focus","messages","calls","calls_history","calls_answer","calls_dial","photos"]' ;;
    esac
    [[ "$scene" == none ]] && exit 0
    cat <<JSON
[
  {"id":"$ID","name":"Pixel 8","public_key":"AAAA","paired_ms":1789000000000,
   "last_seen_ms":1789155000000,"revoked_ms":null,"requires_user_verification":true,
   "last_path":"lan","companion":false,
   "phone":{"battery":62,"charging":true,"can":$CAN,"network":{"type":"wifi","signal":3},
            "reported_ms":1789155000000}}
]
JSON
    ;;
status)
    conns='[{"device_id":"'"$ID"'","device_name":"Pixel 8","path":"lan","rtt_ms":12,"since_ms":1789155000000,"quality":"good","disclosure":"full"}]'
    [[ "$scene" == offline || "$scene" == none ]] && conns='[]'
    cat <<JSON
{"version":1,"key":"AAAA","machine":"test","lan":[],"relay":null,"rendezvous":"r","paired":1,
 "offer_ms_left":null,"connections":$conns}
JSON
    ;;
messages)
    if has send "$@"; then
        text="$(cat)"
        printf '%s\n<<END>>\n' "$text" >> "$RIME_PH_STDIN"
        sleep 0.4
        if [[ "$text" == *NOSIGNAL* ]]; then
            echo '{"error":"Pixel 8 could not send it: no mobile signal."}'
            echo "rime: Pixel 8 could not send it: no mobile signal." >&2
            exit 1
        fi
        echo '{"sent":true,"device":"Pixel 8"}'
        exit 0
    fi
    # A slow read, while the test's flag file exists: the window in which a
    # send queues behind a read.
    [[ -e "$RIME_PH_CALLS.slow" ]] && sleep 1.5
    if [[ "$scene" == error ]]; then
        echo '{"error":"Pixel 8 did not answer in time. Is Rime Remote open on it?"}'
        echo "rime: Pixel 8 did not answer in time. Is Rime Remote open on it?" >&2
        exit 1
    fi
    python3 - "$@" <<'PY'
import json, sys
args = sys.argv[1:]
def opt(name):
    return args[args.index(name) + 1] if name in args else None
thread = opt("--thread")
before = opt("--before")
if thread is None:
    print(json.dumps({"device": "Pixel 8", "threads": [
        {"id": 7, "addresses": ["+15555215556"], "name": "Test Name", "snippet": "see you at 6", "date_ms": 1789154900000, "unread": 2, "count": 40},
        {"id": 8, "addresses": ["+15555215557"], "snippet": "ok", "date_ms": 1789150000000, "unread": 0, "count": 1},
        {"id": 9, "addresses": ["+15555215558", "+15555215559"], "snippet": "group", "date_ms": 1789140000000, "unread": 0, "count": 3},
    ], "changed_ms": 1789154900000}, indent=2))
elif before is None:
    msgs = [{"id": 100 + i, "date_ms": 1789154000000 + i * 1000, "from_me": i % 2 == 0,
             "body": "message %d" % i, "status": "sent" if i % 2 == 0 else "received"} for i in range(30)]
    msgs.reverse()
    print(json.dumps({"device": "Pixel 8", "thread": int(thread), "messages": msgs}, indent=2))
else:
    msgs = [{"id": 50 + i, "date_ms": 1789150000000 + i * 1000, "from_me": False,
             "body": "older %d" % i, "status": "received"} for i in range(5)]
    msgs.reverse()
    print(json.dumps({"device": "Pixel 8", "thread": int(thread), "messages": msgs}, indent=2))
PY
    ;;
calls)
    if has dial "$@" || has hangup "$@"; then
        action=dial; has hangup "$@" && action=hangup
        echo '{"done":true,"device":"Pixel 8","action":"'"$action"'"}'
        exit 0
    fi
    cat <<'JSON'
{"device":"Pixel 8",
 "current":{"state":"ringing","number":"+15555215556","name":"Test Name","since_ms":1789154990000},
 "calls":[{"number":"+15555215556","name":"Test Name","type":"missed","date_ms":1789154000000,"duration_s":0},
          {"number":"+15555215557","type":"outgoing","date_ms":1789150000000,"duration_s":75}]}
JSON
    ;;
photos)
    if has save "$@"; then
        echo '{"saved":true,"device":"Pixel 8","photo":'"$4"',"path":"'"$HOME"'/Pictures/Rime Remote/IMG_0005.jpg","len":2500000}'
        exit 0
    fi
    T="$XDG_RUNTIME_DIR/rime-remote/photos/$ID"
    cat <<JSON
{"device":"Pixel 8","partial":true,"photos":[
  {"id":5,"name":"IMG_0005.jpg","date_ms":1789150000000,"width":4000,"height":3000,"size":2500000,"mime":"image/jpeg","thumb":"$T/5.png"},
  {"id":6,"name":"Screenshot_0006.png","date_ms":1789154000000,"width":1080,"height":2400,"size":640000,"mime":"image/png","thumb":"$T/6.png"}]}
JSON
    ;;
esac
exit 0
STUB
chmod +x "$HEADLESS_W/bin/rime"

cp "$here/phone-page-test.qml" "$staged"

headless_start || exit 0

pass=0
fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1"; fail=$((fail + 1)); }

phase() {
    local name="$1" want="$2"
    local log="$W/$name.log"
    : > "$CALLS"
    : > "$STDIN_LOG"

    echo
    echo "── $name ────────────────────────────────────────────────"

    ( cd "$root" && env \
        RIME_PH_SCENE="$name" \
        RIME_PH_CALLS="$CALLS" \
        RIME_PH_STDIN="$STDIN_LOG" \
        RIME_PHONE_POLL_MS=700 \
        QT_LOGGING_RULES="qml=true" \
        timeout 180 quickshell -p "$staged" ) > "$log" 2>&1

    sed -i -e 's/\x1b\[[0-9;]*m//g' -e 's/^[[:space:]]*\(DEBUG\|WARN\) qml: //' "$log"
    [[ -n "${RIME_PH_KEEP:-}" ]] && cp "$log" "$RIME_PH_KEEP/"
    grep -E "^(  PASS|  FAIL)" "$log" || true

    if grep -qE "is not a type|Cannot assign|Unable to assign|Failed to load configuration|ReferenceError|TypeError" "$log"; then
        bad "the $name page built and ran without QML errors"
        grep -E "is not a type|Cannot assign|Unable to assign|Failed to load configuration|ReferenceError|TypeError" "$log" \
            | head -5 | sed 's/^/          /'
    else
        ok "the $name page built and ran without QML errors"
    fi

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

phase full    51
phase off      5
phase offline  5
phase none     3
phase error    3

echo
echo "passed=$pass failed=$fail"
[[ "$fail" -eq 0 ]]
