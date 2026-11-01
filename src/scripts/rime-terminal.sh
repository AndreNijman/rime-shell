#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
#  rime-terminal.sh [COMMAND [ARG...]] — open the user's terminal, optionally
#  running COMMAND in it. The one terminal launcher behind the shell's context
#  menu, the Wi-Fi editor (nmtui) and the search verbs (SearchRun.sh), which
#  each used to carry their own list of emulators in their own order.
#
#  ORDER
#    1. xdg-terminal-exec — the system default, which is what Settings → Misc →
#       Default terminal writes (~/.config/xdg-terminals.list). Rime ships it
#       and points it at Ghostty. It is first so that choice is honoured
#       everywhere; $TERMINAL used to come first here, and the OS exports
#       TERMINAL=alacritty, so a user who picked Ghostty got Alacritty from a
#       search verb.
#    2. $TERMINAL, then Ghostty, then Alacritty, then the common rest — only
#       where xdg-terminal-exec is missing (a non-Rime host).
#
#  GHOSTTY AND THE PROCESS IT LEAVES
#  Ghostty is single-instance on Linux by default: a bare `ghostty` may hand
#  its window to a running instance and exit at once. `-e` forces it off
#  (measured on nixpkgs Ghostty 1.4.0), and the flag is passed explicitly
#  anyway so the PID this script execs into stays the terminal's for as long
#  as COMMAND runs. See src/services/terminals.js.
#
#  The command is passed through as argv, never re-joined into a string.
# ─────────────────────────────────────────────────────────────────────────────

have() { command -v "$1" >/dev/null 2>&1; }

if have xdg-terminal-exec; then
    exec xdg-terminal-exec "$@"
fi

# Run "$1" with its exec flag, or bare when there is no command.
# $1 = binary, $2 = the flag(s) before the command, as one word ("" = none).
launch() {
    bin="$1"; flag="$2"; shift 2
    if [ "$#" -eq 0 ]; then
        exec "$bin"
    fi
    case "$(basename "$bin")" in
        ghostty) exec "$bin" --gtk-single-instance=false -e "$@" ;;
    esac
    if [ -n "$flag" ]; then
        exec "$bin" "$flag" "$@"
    fi
    exec "$bin" "$@"
}

if [ -n "${TERMINAL:-}" ] && have "$TERMINAL"; then
    case "$(basename "$TERMINAL")" in
        foot) launch "$TERMINAL" "" "$@" ;;
        wezterm) launch "$TERMINAL" start "$@" ;;
        *) launch "$TERMINAL" -e "$@" ;;
    esac
fi

for entry in ghostty:-e alacritty:-e foot: kitty:-e wezterm:start xterm:-e; do
    name="${entry%%:*}"
    flag="${entry#*:}"
    have "$name" || continue
    launch "$name" "$flag" "$@"
done

# shellcheck disable=SC2016  # $TERMINAL is named, not expanded
printf 'rime-terminal: no terminal emulator found (install Ghostty, or set $TERMINAL)\n' >&2
if have notify-send; then
    # shellcheck disable=SC2016  # the same
    notify-send -a 'Rime Shell' 'No terminal found' \
        'Install a terminal emulator or set $TERMINAL.' 2>/dev/null
fi
exit 127
