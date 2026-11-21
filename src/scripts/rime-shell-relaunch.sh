#!/bin/sh
# ─────────────────────────────────────────────────────────────────────────────
#  rime-shell-relaunch.sh <pid> <starttime> <argv...>
#
#  Started (detached) by services/system/LockKeeper.qml when a configuration
#  reload reaches a Shell that holds the session lock. On Quickshell 0.3.2 such
#  a reload cannot keep the lock in the same process: the new generation either
#  takes the old lock over and releases it (the bypass this exists to close) or,
#  wanting the lock as LockKeeper makes it, dies on a Wayland protocol error
#  (ext_session_lock_v1 error 3 duplicate_output after a soft reload, error 0
#  invalid_destroy after a hard one). The compositor keeps an abandoned lock
#  when its client dies, so the session stays locked, but with nothing to type a
#  password into. This waits for that process to end and starts the Shell again
#  with the same command line; the new Shell finds LockKeeper's record and locks
#  at once, which brings the password prompt back.
#
#  <pid> and <starttime> (field 22 of /proc/<pid>/stat) name the process, so a
#  recycled pid is never waited on. If it is still running after 10 s the reload
#  did not end it and nothing is started: there is never a second Shell.
#  Only ever STARTS a Shell. It cannot unlock anything.
# ─────────────────────────────────────────────────────────────────────────────
pid=$1
start=$2
shift 2 2>/dev/null || exit 2
[ "$#" -gt 0 ] || exit 2
case $pid in '' | *[!0-9]*) exit 2 ;; esac

# The process is still the one we were given, and has not exited.
running() {
    stat=$(cat "/proc/$pid/stat" 2>/dev/null) || return 1
    stat=${stat##*) }
    # shellcheck disable=SC2086 # the fields are space-separated on purpose
    set -- $stat
    case $1 in Z | X | x) return 1 ;; esac
    shift 19
    [ "$1" = "$start" ]
}

i=0
while running; do
    i=$((i + 1))
    [ "$i" -le 200 ] || exit 0
    sleep 0.05
done

echo "rime-shell-relaunch: the Shell (pid $pid) ended during a reload while the session was locked; starting it again" >&2
exec "$@"
