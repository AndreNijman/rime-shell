pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.UPower
import "../"
import "players.js" as Players

// Single cava process shared by CenterContent and PlayerCard.
// 32 bars at 30fps, ON DEMAND — see below.
//
// ── WHY THIS IS GATED (it used to run 24/7) ─────────────────────────────────
// `running: true` was hardcoded and `isPlaying` was computed and then never
// read, so cava captured the audio monitor and emitted 30 frames/sec forever:
// while idle, while the visualiser was off-screen, and — the case that hurt —
// for the entire duration of a game.
//
// Games are the worst case because they always produce audio, so cava always
// had real signal. Every frame replaced `bars` with a NEW array, and both
// consumers used it directly as a Repeater model, which rebuilds all 32
// delegates. Two consumers x 32 delegates x 30 fps is ~1900 QML object
// create/destroys per second, each carrying a 50 ms height animation that could
// never finish because its object was destroyed after 33 ms. All of it
// repainting a layer-shell surface that the compositor then had to composite
// over the game.
//
// Now the process only runs when something both wants the bars AND there is a
// player producing them. A game is not an MPRIS player, so during gaming cava
// does not run at all: no process, no PipeWire capture stream, no repaints.
//
// NOTE the deliberate behaviour change: the visualiser now follows MPRIS rather
// than "any sound the machine makes". Anything with an MPRIS player (Firefox,
// mpv, Spotify, playerctl-visible players) still drives it; a bare `aplay` or a
// game no longer does.
//
// ── NEVER ON BATTERY ─────────────────────────────────────────────────────────
// On battery cava does not run at all, whatever is playing and whatever is on
// screen: no process, no PipeWire capture stream, no 30 fps repaints of the
// notch. Measured on the L16 at 0.3-1 W while music plays, out of a ~5 W floor.
// The bars lie flat (onWantedChanged) and come back the moment the charger is
// plugged in. UPower.onBattery is false on a desktop, so nothing changes there.

QtObject {
    id: root

    readonly property int barCount: 32

    // ── Demand, declared not counted ─────────────────────────────────────────
    // One flag per consumer, assigned declaratively. A single `subscribers++/--`
    // counter looks tidier and drifts in practice: it misses the initial value,
    // double-fires when an item is reparented or unmapped, and never decrements
    // on destruction. A drifted counter fails SILENTLY in both directions —
    // cava that never starts, or cava that never stops — which is precisely the
    // bug class being removed here.
    property bool centerWants: false
    property bool dashWants:   false

    readonly property bool onBattery: UPower.onBattery

    readonly property bool wanted: !root.onBattery && root.isPlaying && (root.centerWants || root.dashWants)

    property var bars: (function() {
        var a = []; for (var i = 0; i < 32; i++) a.push(0); return a
    })()

    // isPlaying is true if ANY of this computer's MPRIS players is playing.
    // This ensures bars flow regardless of which player index is active in PlayerCard.
    // A phone's player (Rime Remote) does not count: its sound comes out of the
    // phone, so cava would only capture silence here (players.js).
    readonly property bool isPlaying: Players.localPlaying(Mpris.players.values, MprisPlaybackState.Playing)

    // Flatten the bars when cava stops, so the visualiser does not freeze
    // mid-waveform on whatever frame happened to arrive last.
    onWantedChanged: {
        if (!root.wanted) {
            var z = []
            for (var i = 0; i < root.barCount; i++) z.push(0)
            root.bars = z
        }
    }

    property var _proc: Process {
        command: [
            "bash", "-c",
            "mkdir -p /tmp/rime_shell && " +
            "printf '[general]\\nbars = 32\\nframerate = 30\\nnoise_reduction = 77\\n\\n" +
            "[output]\\nmethod = raw\\nraw_target = /dev/stdout\\n" +
            "data_format = ascii\\nascii_max_range = 100\\n" +
            "bar_delimiter = 59\\nframe_delimiter = 10\\n' " +
            "> /tmp/rime_shell/cava_shared.ini && " +
            "exec cava -p /tmp/rime_shell/cava_shared.ini 2>/dev/null"
        ]
        running: root.wanted
        stdout: SplitParser {
            onRead: function(line) {
                var t = line.trim()
                if (t === "") return
                if (t.endsWith(";")) t = t.slice(0, -1)
                var parts = t.split(";")
                if (parts.length !== root.barCount) return
                var arr = []
                for (var i = 0; i < parts.length; i++)
                    arr.push(parseInt(parts[i]) || 0)
                root.bars = arr
            }
        }
    }
}
