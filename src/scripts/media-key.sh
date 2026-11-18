#!/usr/bin/env bash
# The Shell's media keys (KeybindService: Play / Pause, Next Track, Previous Track).
#
# Rime OS ships /usr/libexec/rime-media-key, which sends the key to the computer's own players
# and reaches a paired phone's player only when the computer has none. The Shell is a checkout
# that updates apart from the OS image, so on an image without that helper this falls back to
# plain playerctl, which is what these keys ran before.
set -u
case "${1-}" in
    play-pause|next|previous) ;;
    *) echo "usage: media-key.sh play-pause|next|previous" >&2; exit 2 ;;
esac
helper=${RIME_MEDIA_KEY_HELPER:-/usr/libexec/rime-media-key}
if [ -x "$helper" ]; then
    exec "$helper" "$1"
fi
exec playerctl "$1"
