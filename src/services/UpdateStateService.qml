pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import "liveupdate.js" as L

// ─── UpdateStateService ─────────────────────────────────────────────────────
// What the top bar's update icon shows (modules/Right/Updates.qml). One
// instance for every screen's bar, so two monitors read the files once.
//
// It reads the same two files as Settings → Updates, with the same overrides:
//   RIME_UPDATE_STATE   /run/rime-update/state       the 6-hourly checker
//   RIME_LIVE_STATUS    /run/rime-live/status.json   `sudo rime update`
// and liveupdate.js's indicator() decides what they mean; whatsNew() turns
// them, with the image's release.json (RIME_RELEASE_JSON, read once), into
// the "What's in this update" link.
//
// ── Cheap, because the bar is always mapped ─────────────────────────────────
// No process, no CLI, no poll while the files are there. A FileView with
// watchChanges watches the file's DIRECTORY (measured, Quickshell 0.3.2): it
// sees the file appear, be rewritten in place (the bootc checker), be
// replaced by a rename (the live engine, and the NixOS checker) and be
// deleted. What it cannot see is a directory that does not exist yet, or one
// removed and made again: /run/rime-live does not exist until the first
// `sudo rime update` of a boot, and /run/rime-update not until the first check.
// So while a file is absent, a slow timer re-arms its watch and reads it once;
// once it is there, the timer stops for it.
// ────────────────────────────────────────────────────────────────────────────
Singleton {
    id: root

    readonly property string statusPath: Quickshell.env("RIME_LIVE_STATUS") || "/run/rime-live/status.json"
    readonly property string checkerPath: Quickshell.env("RIME_UPDATE_STATE") || "/run/rime-update/state"
    // How often an ABSENT file is looked for again. Tests shorten it.
    readonly property int rearmInterval: parseInt(Quickshell.env("RIME_UPDATE_REARM_MS") || "30000", 10)

    // The text last read, "" when the file is not there. A FileView whose
    // file has gone keeps the contents it had, so this is what counts.
    property string _statusText: ""
    property string _checkerText: ""
    property bool _statusPresent: false
    property bool _checkerPresent: false

    readonly property var status: L.parseStatus(root._statusText)
    readonly property var checker: L.parseChecker(root._checkerText)
    readonly property var indicator: L.indicator(root.status, root.checker)
    // "What's in this update" (the bar's update menu, Settings → Updates):
    // { url, release, from } or null. liveupdate.js whatsNew().
    readonly property var whatsNew: L.whatsNew(root.status, root.checker, root.bootedRelease)

    // The release this machine booted, from the image's own release.json:
    // read once (the image cannot change under a running session), no watch.
    readonly property string releasePath: Quickshell.env("RIME_RELEASE_JSON") || "/usr/share/rime/release.json"
    property string _releaseText: ""
    readonly property string bootedRelease: {
        try {
            const r = JSON.parse(root._releaseText)
            return L.releaseId(r && r.id)
        } catch (e) {
            return ""
        }
    }
    // Whether the absent-file timer is running (tests: it must stop once both
    // files are there).
    readonly property bool rearming: rearmTimer.running

    FileView {
        id: statusFile
        path: root.statusPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: { root._statusText = String(text()); root._statusPresent = true }
        onLoadFailed: { root._statusText = ""; root._statusPresent = false }
    }
    FileView {
        id: checkerFile
        path: root.checkerPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: { root._checkerText = String(text()); root._checkerPresent = true }
        onLoadFailed: { root._checkerText = ""; root._checkerPresent = false }
    }

    FileView {
        path: root.releasePath
        printErrors: false
        onLoaded: root._releaseText = String(text())
        onLoadFailed: root._releaseText = ""
    }

    function _rearm(view) {
        view.watchChanges = false
        view.watchChanges = true
        view.reload()
    }

    Timer {
        id: rearmTimer
        interval: Math.max(250, root.rearmInterval)
        repeat: true
        running: !root._statusPresent || !root._checkerPresent
        onTriggered: {
            if (!root._statusPresent) root._rearm(statusFile)
            if (!root._checkerPresent) root._rearm(checkerFile)
        }
    }
}
