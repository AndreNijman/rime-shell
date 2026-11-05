import Quickshell
import QtQuick
import "./src"
import "./src/services"
import "./src/services/config_tab/pages" as Pages

// ─────────────────────────────────────────────────────────────────────────────
// Settings → Misc → Default terminal, driven. Run via
// tests/run-terminal-settings-test.sh, which sets up the home and judges the
// "TERM {json}" lines this prints (one per step) and the list file it leaves.
//
//   step "start"   what the page shows before anything is chosen: both
//                  terminals installed (their entries were found, however late
//                  the scan), and the choice is what xdg-terminal-exec resolves
//                  from the OS list (Ghostty).
//   step "picked"  the PAGE's own control emits Alacritty; after the write the
//                  read-back resolves Alacritty, and nothing is "shadowed".
//   step "back"    TerminalService.setDefault("ghostty"): resolves Ghostty.
// With TERM_MODE=shadow the runner has put a desktop-specific list naming
// Alacritty in the way; choosing Ghostty must then SAY it is shadowed.
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 800
        implicitHeight: 600
        color: "black"

        readonly property string mode: Quickshell.env("TERM_MODE") || "normal"

        Pages.MiscPage { id: page; anchors.fill: parent; onScreen: true }

        function find(item, name) {
            if (!item) return null
            if (item.objectName === name) return item
            const kids = item.children || []
            for (let i = 0; i < kids.length; i++) {
                const p = find(kids[i], name)
                if (p) return p
            }
            if (item.contentItem && item.contentItem !== item) {
                const p = find(item.contentItem, name)
                if (p) return p
            }
            return null
        }

        function report(step) {
            const seg = find(page, "terminalChoice")
            const ghosttyEntry = DesktopEntries.heuristicLookup("com.mitchellh.ghostty")
            console.warn("TERM " + JSON.stringify({
                step: step, mode: win.mode,
                current: TerminalService.current, resolvedId: TerminalService.resolvedId,
                requested: TerminalService.requested, busy: TerminalService.busy,
                error: TerminalService.error, shadowed: TerminalService.shadowed,
                installed: { ghostty: TerminalService.installed("ghostty"),
                             alacritty: TerminalService.installed("alacritty") },
                segFound: !!seg,
                segValue: seg ? seg.value : null,
                segDimmed: seg ? seg.options.map(o => !!o.dimmed) : null,
                // The dock / overview find a running Ghostty's entry from its
                // Wayland app id (measured: com.mitchellh.ghostty).
                appIdEntry: ghosttyEntry ? ghosttyEntry.id : null
            }))
        }

        property var steps: win.mode === "shadow"
            ? [ function () { TerminalService.setDefault("ghostty") } ]
            : [ function () { const s = find(page, "terminalChoice"); if (s) s.selected("alacritty") },
                function () { TerminalService.setDefault("ghostty") } ]
        readonly property var names: win.mode === "shadow" ? ["shadow"] : ["picked", "back"]
        property int si: -1

        // Wait for a step to land: the write, then the read-back.
        Timer {
            id: waiter
            interval: 100
            repeat: true
            property int ticks: 0
            onTriggered: {
                ticks++
                if (TerminalService.busy && ticks < 50) return
                stop()
                win.report(win.si < 0 ? "start" : win.names[win.si])
                win.si++
                if (win.si >= win.steps.length) { console.warn("TERMDONE"); Qt.quit(); return }
                win.steps[win.si]()
                ticks = 0
                start()
            }
        }

        // The entries scan and the first --print-id are both asynchronous.
        Timer { running: true; interval: 2500; onTriggered: waiter.start() }
    }
}
