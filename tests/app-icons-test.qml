import Quickshell
import Quickshell.Io
import QtQuick
import "./src/services"

// IconService, run for real against fixture icons (tests/run-app-icons-test.sh
// builds them in a private XDG_DATA_HOME / XDG_DATA_DIRS and stages this file
// at the repository root).
//
// What it proves:
//   * a name nobody has resolves to "" — not to image://icon/<name>, which
//     Quickshell answers with a placeholder that reports Ready, so the
//     caller's own fallback never showed (the "broken icon");
//   * an icon in a size directory hicolor's index.theme does not list
//     (Blanc's 1024x1024), and one in pixmaps/, are found by file;
//   * a notification with an empty app_icon gets its app's icon from the
//     desktop-entry hint (how Chromium browsers, Helium included, send them)
//     or from its app name (how Electron apps without the hint send them);
//   * an app installed while the shell runs is found without a restart.

ShellRoot {
    id: t

    property int pass: 0
    property int fail: 0
    readonly property string data: Quickshell.env("ICON_FIXTURE_HOME")
    readonly property string sys: Quickshell.env("ICON_FIXTURE_SYS")

    function check(what, cond, got) {
        if (cond) { console.log("  PASS  " + what); t.pass++ }
        else      { console.log("  FAIL  " + what + "  (got: " + JSON.stringify(got) + ")"); t.fail++ }
    }
    function eq(what, got, want) { t.check(what + " = " + JSON.stringify(want), got === want, got) }

    Image { id: missingImg; source: IconService.source("rime-test-no-such-icon") }
    Image { id: looseImg;   source: IconService.source("fixblanc") }
    Image { id: pixImg;     source: IconService.source("fixpix") }

    property int phase: 0

    Timer {
        id: tick
        interval: 100
        repeat: true
        running: true
        property int waited: 0
        onTriggered: {
            waited++
            if (t.phase === 0) {
                // Before the file index exists a miss is still "", never a placeholder.
                t.eq("empty name", IconService.source(""), "")
                t.eq("absolute path", IconService.source("/opt/x/icon.png"), "file:///opt/x/icon.png")
                t.eq("file:// url", IconService.source("file:///opt/x/icon.png"), "file:///opt/x/icon.png")
                t.eq("missing name before the index", IconService.source("rime-test-no-such-icon"), "")
                IconService.source("fixblanc")   // a miss: starts the index
                t.phase = 1; waited = 0
                return
            }
            if (t.phase === 1) {
                if (IconService.revision === 0 && waited < 100) return
                t.check("the file index landed", IconService.revision > 0, IconService.revision)
                t.eq("missing name", IconService.source("rime-test-no-such-icon"), "")
                t.eq("unlisted size dir (1024x1024)", IconService.source("fixblanc"),
                     "file://" + t.data + "/icons/hicolor/1024x1024/apps/fixblanc.png")
                t.eq("name with an extension", IconService.source("fixblanc.png"),
                     "file://" + t.data + "/icons/hicolor/1024x1024/apps/fixblanc.png")
                // Qt's own lookup already falls back to pixmaps/; either route is right.
                t.check("pixmaps/", ["image://icon/fixpix", "file://" + t.sys + "/pixmaps/fixpix.png"]
                        .indexOf(IconService.source("fixpix")) !== -1, IconService.source("fixpix"))
                t.check("an Image of the pixmaps/ icon is Ready", pixImg.status === Image.Ready, pixImg.status)
                t.eq("user dir beats system dir", IconService.source("fixboth"),
                     "file://" + t.data + "/icons/hicolor/1024x1024/apps/fixboth.png")
                t.eq("svg beats png", IconService.source("fixsvg"),
                     "file://" + t.sys + "/icons/hicolor/2048x2048/apps/fixsvg.svg")
                t.eq("themed name", IconService.source("fixhel"), "image://icon/fixhel")

                t.eq("entry", IconService.forEntry(DesktopEntries.byId("fixblanc")),
                     "file://" + t.data + "/icons/hicolor/1024x1024/apps/fixblanc.png")
                t.eq("null entry", IconService.forEntry(null), "")

                t.eq("notification: app_icon wins",
                     IconService.forNotification("fixblanc", "fixhel", "Fixhel"),
                     "file://" + t.data + "/icons/hicolor/1024x1024/apps/fixblanc.png")
                t.eq("notification: empty app_icon, desktop-entry hint (Chromium)",
                     IconService.forNotification("", "fixhel", "Fixhel"), "image://icon/fixhel")
                t.eq("notification: hint with .desktop",
                     IconService.forNotification("", "fixblanc.desktop", ""),
                     "file://" + t.data + "/icons/hicolor/1024x1024/apps/fixblanc.png")
                t.eq("notification: app name only (Electron, no hint)",
                     IconService.forNotification("", "", "FixBlanc"),
                     "file://" + t.data + "/icons/hicolor/1024x1024/apps/fixblanc.png")
                t.eq("notification: unknown app_icon falls through to the app",
                     IconService.forNotification("rime-test-no-such-icon", "fixhel", ""), "image://icon/fixhel")
                t.eq("notification: nothing known", IconService.forNotification("", "", "Nobody Here"), "")

                t.check("an Image of a missing icon is not Ready (the caller's fallback shows)",
                        missingImg.status !== Image.Ready, missingImg.status)
                t.check("an Image of the 1024 icon is Ready", looseImg.status === Image.Ready, looseImg.status)

                // Install an app while the shell runs: icon first, then its entry.
                t.before = IconService.revision
                installer.running = true
                t.phase = 2; waited = 0
                return
            }
            if (t.phase === 2) {
                if (IconService.revision === t.before && waited < 150) return
                t.eq("an app installed while running is found",
                     IconService.source("fixlate"),
                     "file://" + t.data + "/icons/hicolor/1024x1024/apps/fixlate.png")
                t.eq("…and its notifications by name",
                     IconService.forNotification("", "", "Fixlate"),
                     "file://" + t.data + "/icons/hicolor/1024x1024/apps/fixlate.png")
                console.log("app-icons: passed=" + t.pass + " failed=" + t.fail)
                Qt.quit()
            }
        }
    }
    property int before: 0

    Process {
        id: installer
        command: ["sh", "-c",
            "cp \"$1/icons/hicolor/1024x1024/apps/fixblanc.png\" \"$1/icons/hicolor/1024x1024/apps/fixlate.png\" && " +
            "printf '[Desktop Entry]\\nType=Application\\nName=Fixlate\\nExec=true\\nIcon=fixlate\\n' > \"$1/applications/fixlate.desktop\"",
            "sh", t.data]
    }
}
