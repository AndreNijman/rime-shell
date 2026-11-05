import QtQuick
import Quickshell
import Quickshell.Io
import "../../../"
import "../../../components"
import "../../../components/config"
// src/services: SystemStats is registered by that directory's qmldir (as in
// MiscPage).
import "../../"

// Config → About (Rime Settings, the app, only)
//
// In the Shell, About is the first section of Misc, beside the compositor and
// Shell rows that only mean something under Rime Shell; Misc is therefore
// Shell-only (PageRegistry `shellOnly`). GNOME, KDE Plasma and COSMIC users
// still need to know which Rime this is, so the app has this page of its own
// (`appOnly`): the mark, the release and the code revision, and the same
// SystemStats rows Misc shows (distro, kernel, desktop, uptime, packages).
CfgScroll {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    lifecycle: "live"

    // Set by SettingsHost: SystemStats costs a subprocess and runs only while
    // the page is genuinely on screen (PageRegistry needsScreen: true).
    property bool onScreen: false

    // The release (os-release IMAGE_VERSION, else VERSION_ID) and the Shell
    // tree's packaged commit. One read each, when the page is built.
    property string release: ""
    property string revision: ""

    FileView {
        path: "/etc/os-release"
        printErrors: false
        onLoaded: {
            const kv = {}
            for (const line of String(text()).split("\n")) {
                const m = line.match(/^([A-Z_]+)=("?)(.*)\2$/)
                if (m)
                    kv[m[1]] = m[3]
            }
            root.release = kv.IMAGE_VERSION || kv.VERSION || kv.VERSION_ID || ""
        }
    }
    FileView {
        path: Quickshell.shellDir + "/.rime-shell-commit"
        printErrors: false
        onLoaded: root.revision = String(text()).trim().slice(0, 12)
    }

    property var _openProc: Process { command: []; running: false }
    function openUrl(u) {
        _openProc.command = ["xdg-open", u]
        _openProc.running = false
        _openProc.running = true
    }

    CfgSection {
        title: "About"
        first: true

        Item {
            width: parent.width
            height: 60

            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12

                // The same mark as Settings → Misc → About: the spark's glyph on
                // the bootc image, the layered ridge on NixOS (Brand.ridge).
                Text {
                    visible: !Brand.ridge
                    text: "󰧑"
                    font.pixelSize: theme.fs(30)
                    color: Theme.active
                    anchors.verticalCenter: parent.verticalCenter
                }
                RimeMark {
                    visible: Brand.ridge
                    width: theme.px(44)
                    height: Math.round(width * 175 / 240)
                    accent: Theme.active
                    foreground: Theme.text
                    anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Text {
                        text: "Rime OS" + (root.release !== "" ? " " + root.release : "")
                        font.pixelSize: theme.fs(16)
                        font.weight: Font.Medium
                        color: Theme.text
                    }
                    Text {
                        text: "Rime Settings" + (root.revision !== "" ? "  ·  " + root.revision : "")
                        font.pixelSize: theme.typeCaption
                        color: Theme.textSecondary
                        font.family: Theme.fontMono
                    }
                }
            }
        }

        CfgRow {
            label: "Website"
            description: "rimeos.com"
            CfgButton {
                label: "Open"
                icon: "󰈺"
                onClicked: root.openUrl("https://rimeos.com")
            }
        }
    }

    CfgSection {
        title: "System"

        ServiceRef {
            service: sysStats
            active: root.onScreen
        }

        Item {
            width: parent.width
            height: sysStats.implicitHeight

            SystemStats {
                id: sysStats
                width: parent.width
            }
        }
    }
}
