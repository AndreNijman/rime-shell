import QtQuick
import Quickshell
import Quickshell.Io
import "../../../"
import "../../"
import "../../../components"
import "../../../components/config"
import "../../liveupdate.js" as L

// Config → Updates
//
// What the OS's update machinery says about this computer: whether a newer
// release is published (the 6-hourly checker), and what the last
// `sudo rime update` did to the RUNNING system (the live update engine, which
// applies what it can without a restart and says what it could not).
//
// ── WHY IT ONLY READS ───────────────────────────────────────────────────────
//
// Updating needs root, and Rime has one updater: `sudo rime update`. The shell
// is image-owned, so it has no updater of its own and runs nothing privileged.
// The buttons open the user's terminal on fixed commands (liveupdate.js), and
// `sudo` asks for the password there.
//
// Both files are root's, world-readable, and absent most of the time. They are
// display data: every string is capped and drawn as plain text, and nothing
// in them is ever run. A missing file is the normal case, not an error.
CfgScroll {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    lifecycle: "live"

    // Set by SettingsHost (Nexus). The two files are re-read on a slow timer
    // while the page is looked at, and not at all when it is not.
    property bool onScreen: false

    readonly property string statusPath: Quickshell.env("RIME_LIVE_STATUS") || "/run/rime-live/status.json"
    readonly property string checkerPath: Quickshell.env("RIME_UPDATE_STATE") || "/run/rime-update/state"

    // The text last read, "" when the file is not there. Kept here rather than
    // read from the FileView, because a FileView whose file has gone keeps the
    // contents it had: a deleted status would go on being shown.
    property string _statusText: ""
    property string _checkerText: ""
    property string _releaseText: ""

    readonly property var status: L.parseStatus(root._statusText)
    readonly property var checker: L.parseChecker(root._checkerText)
    readonly property var heroView: L.hero(root.status, root.checker)
    readonly property var components: root.status.ok ? root.status.components : []

    readonly property string bootedRelease: {
        try {
            const r = JSON.parse(root._releaseText)
            const id = L.clean(r && r.id, 40)
            if (id !== "") return id
        } catch (e) {}
        return root.status.ok && root.status.booted ? root.status.booted.release : ""
    }
    readonly property string targetRelease:
        root.status.ok && root.status.target ? root.status.target.release : ""

    function toneColor(tone) {
        switch (tone) {
            case "ok":   return Theme.active
            case "warn": return Theme.attention
            case "bad":  return Theme.danger
            default:     return Theme.subtext
        }
    }

    // watchChanges cannot watch a file that does not exist yet, and an atomic
    // rename replaces the inode it was watching — so the timer is what notices
    // the engine's next write. Three small reads every few seconds, only while
    // somebody is looking.
    FileView {
        id: statusFile
        path: root.statusPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root._statusText = String(text())
        onLoadFailed: root._statusText = ""
    }
    FileView {
        id: checkerFile
        path: root.checkerPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root._checkerText = String(text())
        onLoadFailed: root._checkerText = ""
    }
    FileView {
        id: releaseFile
        path: ReleaseService.releasePath
        printErrors: false
        onLoaded: root._releaseText = String(text())
        onLoadFailed: root._releaseText = ""
    }
    Timer {
        interval: 4000
        repeat: true
        running: root.onScreen
        triggeredOnStart: true
        onTriggered: { statusFile.reload(); checkerFile.reload() }
    }

    // ── Where this computer is ───────────────────────────────────────────────
    CfgSection {
        title: "Rime updates"
        first: true

        StatusHero {
            id: hero
            glyph:  root.heroView.glyph
            tone:   root.toneColor(root.heroView.tone)
            title:  root.heroView.title
            detail: root.heroView.detail
            detailWraps: true
            titleItem.textFormat:  Text.PlainText
            detailItem.textFormat: Text.PlainText

            CfgButton {
                id: updateButton
                variant: "accent"
                label:   "Update now"
                icon:    "󰚰"
                onClicked: DesktopExec.runInTerminal(L.UPDATE_ARGV)
            }
        }

        CfgRow {
            id: recommendationRow
            plainText:        true
            hoverable:        false
            visible:          root.status.ok && root.status.recommendation !== ""
            label:            "Recommendation"
            description:      root.status.ok ? root.status.recommendation : ""
            descriptionLines: 0
        }

        CfgRow {
            id: bootedRow
            plainText: true
            hoverable: false
            label:     "Running"
            status:    root.bootedRelease !== "" ? "Rime " + root.bootedRelease : "not known"
        }

        CfgRow {
            id: targetRow
            plainText: true
            hoverable: false
            visible:   root.targetRelease !== ""
            label:     "Updating to"
            status:    "Rime " + root.targetRelease
        }
    }

    // ── What the last update did to the running system ──────────────────────
    CfgSection {
        title: "What changed"
        // No heading over nothing: an engine that touched nothing writes an
        // empty list, and most machines have no status at all.
        visible: root.components.length > 0

        Repeater {
            model: root.components.length
            delegate: CfgRow {
                id: compRow
                required property int index
                readonly property var comp: root.components[compRow.index] || null
                readonly property var compChip: L.chip(compRow.comp ? compRow.comp.state : "")
                plainText:        true
                hoverable:        false
                label:            compRow.comp ? compRow.comp.label : ""
                description:      L.componentLine(compRow.comp)
                descriptionLines: 3
                status:           compRow.compChip.text
                statusWarns:      compRow.compChip.tone === "warn" || compRow.compChip.tone === "bad"
            }
        }
    }

    // ── In a terminal ────────────────────────────────────────────────────────
    CfgSection {
        title: "In a terminal"

        CfgRow {
            plainText:   true
            label:       "Show the plan"
            description: "What an update would change, and what each part would need, without changing anything."
            CfgButton {
                id: planButton
                label: "Show plan"
                icon:  "󰈈"
                onClicked: DesktopExec.runInTerminal(L.PLAN_ARGV)
            }
        }

        CfgRow {
            plainText:   true
            label:       "Explain the last update"
            description: "Why each part was applied live, deferred, or left for a restart."
            CfgButton {
                id: explainButton
                label: "Explain"
                icon:  "󰋗"
                onClicked: DesktopExec.runInTerminal(L.EXPLAIN_ARGV)
            }
        }
    }
}
