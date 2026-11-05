pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "terminals.js" as Terms

// ─────────────────────────────────────────────────────────────────────────────
// TerminalService — Settings → Misc → Default terminal (Ghostty / Alacritty).
//
// ── WHERE THE CHOICE LIVES ───────────────────────────────────────────────────
// In the user's own ~/.config/xdg-terminals.list, the file the freedesktop
// terminal helper reads before the OS's /etc/xdg one. Not in the shell's
// settings JSON: every launch the shell makes goes through xdg-terminal-exec
// (DesktopExec, the context menu, SUPER+T, rime-terminal.sh), and so does
// every other program that follows the spec, so one line there moves all of
// them and nothing has to be regenerated or restarted.
//
// The write keeps every line of the user's list that is about neither known
// terminal (terminals.js withDefault), so a hand-edited list survives.
//
// ── WHAT THE PAGE SHOWS IS A READ-BACK ───────────────────────────────────────
// `current` is what `xdg-terminal-exec --print-id` resolves after the write,
// not what was asked for. Those differ when a desktop-specific list
// (~/.config/hyprland-xdg-terminals.list) outranks the plain one, or when the
// chosen terminal is not installed; `shadowed` says so in a sentence instead
// of showing a choice that does nothing.
// ─────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    readonly property var options: Terms.KNOWN

    // The key xdg-terminal-exec resolves to now ("ghostty", "alacritty"), or
    // "" when it resolves to something else or to nothing.
    property string current: ""
    // The desktop id it resolved to, as printed ("" before the first read).
    property string resolvedId: ""
    // The key the user last asked for in this session.
    property string requested: ""
    property bool busy: false
    property string error: ""

    readonly property string shadowed:
        (root.requested !== "" && !root.busy && root.current !== root.requested)
            ? (root.resolvedId !== ""
                ? ("Your choice is saved, but " + root.resolvedId + " still opens: a "
                   + "desktop-specific xdg-terminals.list outranks it, or "
                   + Terms.byKey(root.requested).name + " is not installed.")
                : ("Your choice is saved, but no terminal resolves. Is "
                   + Terms.byKey(root.requested).name + " installed?"))
            : ""

    // Installed means a desktop entry exists: that is exactly what
    // xdg-terminal-exec needs, and it costs no process to ask.
    // byId() notifies nothing, and the entries are scanned AFTER the shell
    // starts: a binding that asked once would keep the first answer (measured:
    // the Settings row showed an installed Alacritty as not installed). Every
    // binding that calls installed() reads _entriesRev, which moves whenever
    // the set of entries does.
    function installed(key) {
        const t = Terms.byKey(key)
        if (!t || root._entriesRev < 0) return false
        return DesktopEntries.byId(t.desktopId.replace(/\.desktop$/, "")) !== null
    }

    property int _entriesRev: 0
    Connections {
        target: DesktopEntries.applications
        function onValuesChanged() {
            root._entriesRev++
            // A terminal installed or removed changes what resolves.
            if (!root.busy) root.refresh()
        }
    }

    readonly property string _configHome: {
        const x = Quickshell.env("XDG_CONFIG_HOME") || ""
        return x !== "" ? x : (Quickshell.env("HOME") + "/.config")
    }
    readonly property string listPath: root._configHome + "/xdg-terminals.list"

    // xdg-terminal-exec's own cache. It is keyed on `ls -l` of the list files
    // (size and mtime to the MINUTE), and choosing a terminal only reorders
    // the same two lines, so the list keeps its size. Measured (0.14.3 and
    // nixpkgs 0.14.4): Alacritty chosen, a terminal opened (the cache saved),
    // Ghostty chosen within the minute: every launch, and --print-id, still
    // gave Alacritty. So a write drops the cache; the next launch rebuilds it.
    readonly property string cachePath: {
        const x = Quickshell.env("XDG_CACHE_HOME") || ""
        return (x !== "" ? x : (Quickshell.env("HOME") + "/.cache")) + "/xdg-terminal-exec"
    }

    function refresh() {
        root._probe.running = false
        root._probe.running = true
    }

    function setDefault(key) {
        if (root.busy || !Terms.byKey(key)) return
        root.error = ""
        root.requested = key
        root.busy = true
        // Read the list as it is NOW (another program may have edited it since
        // the shell started), then write. FileView's text() is the last load,
        // so reload synchronously first.
        root._file.reload()
        root._file.waitForJob()
        const next = Terms.withDefault(root._file.text() || "", key)
        root._writePending = true
        root._file.setText(next)
    }

    property bool _writePending: false

    property FileView _file: FileView {
        path: root.listPath
        printErrors: false           // no list yet is the normal first-run state
        atomicWrites: true
        blockWrites: true
        onSaved: {
            if (!root._writePending) return
            root._writePending = false
            // Drop the stale cache, then read back (see cachePath).
            root._dropCache.running = true
        }
        onSaveFailed: function(err) {
            root._writePending = false
            root.busy = false
            root.error = "Could not write " + root.listPath + " (" + err + ")."
        }
    }

    property Process _dropCache: Process {
        command: ["rm", "-f", "--", root.cachePath]
        running: false
        onExited: root.refresh()
    }

    property Process _probe: Process {
        command: ["xdg-terminal-exec", "--print-id"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const id = String(this.text || "").trim().split("\n")[0] || ""
                root.resolvedId = id
                root.current = Terms.keyForDesktopId(id)
                root.busy = false
            }
        }
        onExited: function(code) {
            if (code !== 0) root.busy = false
        }
    }

    Component.onCompleted: refresh()
}
