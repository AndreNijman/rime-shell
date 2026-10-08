pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// ─────────────────────────────────────────────────────────────────────────────
// IconService — the one place an application icon name becomes an image URL.
//
// ── The defect this exists for ──────────────────────────────────────────────
//
// Every surface used to build `"image://icon/" + name` itself and show its own
// fallback (the app's initial, the dock's glyph) when the Image was not Ready.
// That fallback never appeared: Quickshell's icon provider answers a name the
// theme does not have with a placeholder pixmap, and the Image reports Ready
// (measured on Quickshell 0.3.1: status 1, 100×100, for a name that exists
// nowhere). So a missing icon was drawn as a broken one, everywhere.
//
// Two ordinary apps hit it on Andre's machine (2026-10-08):
//
//   * Helium (a Chromium browser, `rime install`ed) sends notifications with
//     an EMPTY app_icon and names itself only in the `desktop-entry` hint. The
//     notification surfaces read appIcon alone. The launcher, which reads the
//     .desktop file, was fine.
//   * Blanc (an AppImage) installed its icon only at
//     ~/.local/share/icons/hicolor/1024x1024/apps/blanc.png. hicolor's
//     index.theme lists no 1024x1024 directory, so a spec-following theme
//     lookup never looks there: broken in the launcher AND in notifications.
//     Apps that drop a loose file in pixmaps/ or an unlisted size are common.
//
// ── What this does instead ──────────────────────────────────────────────────
//
// source(name) returns a URL only for an icon that is really there, else "":
//   1. an absolute path or file:// URL is used as given;
//   2. a name the icon theme has goes through image://icon/ (checked with
//      Quickshell.iconPath(name, true), which returns "" on a miss);
//   3. otherwise the name is looked up in an index of every icon FILE under
//      the XDG data dirs' icons/*/*/apps/ and pixmaps/, whatever size
//      directory it is in;
//   4. otherwise "" — and the caller's own fallback shows, as it always meant to.
//
// forNotification() walks appIcon, then the desktop-entry hint, then the
// app's name, through the desktop entries, so a notification shows the same
// icon the launcher does.
//
// The file index is built on the first miss (most lookups never need it) and
// rebuilt when the set of desktop entries changes, which is what installing
// an app does. `revision` moves when it lands, so bindings that called
// source() re-evaluate.
// ─────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    // Bumped whenever the file index changes. source() reads it, so every
    // binding that called source() depends on it.
    property int revision: 0

    // name (no extension) → absolute path of the best file for it.
    property var _files: ({})
    property bool _indexed: false

    // The directories searched, highest priority first: the user's own data
    // dir, then XDG_DATA_DIRS in order (flatpak exports, /usr/local, /usr),
    // each with icons/ and pixmaps/. ~/.icons is the legacy user location.
    readonly property var _roots: {
        const home = Quickshell.env("HOME") || ""
        const dataHome = Quickshell.env("XDG_DATA_HOME") || (home + "/.local/share")
        const dataDirs = (Quickshell.env("XDG_DATA_DIRS") || "/usr/local/share:/usr/share")
            .split(":").filter(d => d !== "")
        const out = []
        if (home !== "")
            out.push(home + "/.icons")
        for (const d of [dataHome].concat(dataDirs)) {
            out.push(d + "/icons")
            out.push(d + "/pixmaps")
        }
        return out
    }

    // ── public ───────────────────────────────────────────────────────────────

    function source(name) {
        root.revision   // dependency: re-evaluate when the file index lands
        let s = (name ?? "").toString().trim()
        if (s === "")
            return ""
        if (s.startsWith("file://"))
            s = decodeURIComponent(s.slice(7))
        if (s.startsWith("/"))
            return "file://" + s
        if (s.startsWith("image://"))
            return s

        const themed = Quickshell.iconPath(s, true)
        if (themed !== "")
            return themed

        // "foo.png" is not an icon name, but desktop files say it anyway.
        const bare = s.replace(/\.(png|svg|xpm)$/i, "")
        if (bare !== s) {
            const t = Quickshell.iconPath(bare, true)
            if (t !== "")
                return t
        }

        if (!root._indexed) {
            root._requestIndex()
            return ""
        }
        const f = root._files[bare]
        return f ? "file://" + f : ""
    }

    // A desktop entry (or null) → its icon's URL, or "".
    function forEntry(entry) {
        return entry && entry.icon ? root.source(entry.icon) : ""
    }

    // What a notification should show as its app's icon: what it sent, else
    // the icon of the app it says it is (desktop-entry hint), else the icon of
    // the app whose name it carries. The arguments are plain strings so a
    // card's snapshot of a notification that has closed resolves the same way.
    function forNotification(appIcon, desktopEntry, appName) {
        const direct = root.source(appIcon)
        if (direct !== "")
            return direct
        for (const key of [desktopEntry, appName]) {
            const k = (key ?? "").toString().trim().replace(/\.desktop$/, "")
            if (k === "")
                continue
            const entry = DesktopEntries.byId(k) ?? DesktopEntries.heuristicLookup(k)
            const viaEntry = root.forEntry(entry)
            if (viaEntry !== "")
                return viaEntry
            // A desktop-entry hint is also, usually, the icon's name.
            const viaName = root.source(k)
            if (viaName !== "")
                return viaName
        }
        return ""
    }

    // ── the file index ───────────────────────────────────────────────────────

    // Lower is better. The root's position wins (a user's own icon overrides
    // the system's), then svg over raster, then the larger raster.
    function _rank(path) {
        let rootIdx = root._roots.length
        for (let i = 0; i < root._roots.length; i++) {
            if (path.startsWith(root._roots[i] + "/")) { rootIdx = i; break }
        }
        let quality = 0
        if (/\.svg$/i.test(path) || path.indexOf("/scalable/") !== -1)
            quality = 100000
        else {
            const m = path.match(/\/(\d+)x\d+(@\d+)?\//)
            quality = m ? parseInt(m[1]) : (/\.xpm$/i.test(path) ? 1 : 48)
        }
        return rootIdx * 1000000 - quality
    }

    function _parse(text) {
        const best = ({})
        const files = ({})
        for (const line of text.split("\n")) {
            const p = line.trim()
            if (p === "")
                continue
            const base = p.slice(p.lastIndexOf("/") + 1).replace(/\.(png|svg|xpm)$/i, "")
            if (base === "")
                continue
            const r = root._rank(p)
            if (best[base] === undefined || r < best[base]) {
                best[base] = r
                files[base] = p
            }
        }
        return files
    }

    function _requestIndex() {
        if (!scan.running)
            scan.running = true
    }

    Process {
        id: scan
        // icons/<theme>/<size>/apps/<file> is depth 4 from icons/; pixmaps/<file>
        // is depth 1. -L because flatpak exports and /usr/local are symlink farms.
        command: ["find", "-L"].concat(root._roots).concat([
            "-maxdepth", "4",
            "(", "-path", "*/apps/*", "-o", "-path", "*/pixmaps/*", ")",
            "-type", "f",
            "(", "-name", "*.png", "-o", "-name", "*.svg", "-o", "-name", "*.xpm", ")"
        ])
        stdout: StdioCollector {
            onStreamFinished: {
                root._files = root._parse(this.text)
                root._indexed = true
                root.revision++
            }
        }
    }

    // Installing or removing an app changes the desktop entries; its icon
    // files arrived with it. Debounced: a package set lands as a burst.
    Timer {
        id: reindex
        interval: 1500
        onTriggered: if (root._indexed) root._requestIndex()
    }
    Connections {
        target: DesktopEntries.applications
        function onValuesChanged() { reindex.restart() }
    }
}
