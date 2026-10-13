import Quickshell
import QtQuick
import "./src"
import "./src/services"
import "./src/components"
import "./src/modules/Right" as Right
import "./src/modules/Left" as Left

// ─────────────────────────────────────────────────────────────────────────────
// The bar's open pill, held to the glyph it sits under. Run via
// tests/run-open-pill-centre-test.sh, which reads the pixels this writes.
//
// "The selector on the wifi button is off centre" is a statement about where
// the font engine put a glyph's ink and where the scene graph put a circle, and
// neither is in the source: a 15 px glyph whose advance is odd lands on a whole
// pixel inside a 20 px box (anchors round a centred item), and its ink need not
// fill that advance or sit in the middle of the line box. So this builds the
// REAL bar modules and every glyph they can show, at every factor the shell
// scales to, shows each one's pill, and for each writes out:
//   - the pill's centre, from its laid-out geometry, and
//   - a picture of the cell with the pill hidden, so only the glyph is drawn.
// The runner finds the glyph's ink in that picture and compares.
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 1100
        implicitHeight: 700
        color: "black"

        readonly property string out: Quickshell.env("PILL_OUT") || ""
        readonly property var factors: [0.85, 1.0, 1.2, 1.35, 1.5]

        // Every glyph the IconBtn hosts can show (Network.qml, Notifications.qml).
        readonly property var iconGlyphs: [
            0xf0928, 0xf0925, 0xf0922, 0xf091f, 0xf092d,   // wifi by strength, none
            0xeb01,                                        // wifi, limited
            0xef44, 0xf0162,                               // ethernet, limited
            0xf099d, 0xf00b1, 0xf0002,                     // VPN, Bluetooth, hotspot
            0xf009a, 0xf009b, 0xf009c                      // notifications
        ]
        // Audio.qml's glyphs, in its own Text (the pill is a child of the Text).
        readonly property var audioGlyphs: [0xf057e, 0xf0580, 0xf057f, 0xf075f]

        Flow {
            id: flow
            width: parent.width
            spacing: 2

            Repeater {
                model: win.iconGlyphs
                delegate: Rectangle {
                    property string cellName: "iconbtn-" + modelData.toString(16)
                    width: 52; height: 44; color: "black"
                    IconBtn {
                        anchors.centerIn: parent
                        text: String.fromCodePoint(modelData)
                        textColor: "white"
                        OpenPill { shown: true }
                    }
                }
            }
            Repeater {
                model: win.audioGlyphs
                delegate: Rectangle {
                    property string cellName: "audio-text-" + modelData.toString(16)
                    width: 52; height: 44; color: "black"
                    // Audio.qml's own arrangement, glyph for glyph: its sink is
                    // whatever this machine has, so the real module can show
                    // only one of these.
                    Text {
                        anchors.centerIn: parent
                        text: String.fromCodePoint(modelData)
                        color: "white"
                        font.pixelSize: aTheme.typeIcon
                        font.family: Theme.fontIcon
                        readonly property ThemeSet aTheme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }
                        OpenPill { shown: true }
                    }
                }
            }
            Rectangle {
                property string cellName: "module-network"
                width: 120; height: 44; color: "black"
                Right.Network { anchors.centerIn: parent }
            }
            Rectangle {
                property string cellName: "module-notifications"
                width: 52; height: 44; color: "black"
                Right.Notifications { anchors.centerIn: parent }
            }
            Rectangle {
                property string cellName: "module-audio"
                width: 120; height: 44; color: "black"
                Right.Audio { anchors.centerIn: parent }
            }
            Rectangle {
                property string cellName: "module-systray"
                width: 120; height: 44; color: "black"
                // No tray items on a private bus, and the module hides itself
                // without any: shown anyway, and unfolded (its open state), so
                // the toggle's glyph is alone with its pill.
                Right.SysTray {
                    anchors.centerIn: parent
                    Component.onCompleted: { visible = true; win.findProp(this, "isOpen").isOpen = true }
                }
            }
            Rectangle {
                property string cellName: "module-controlpanel"
                width: 52; height: 44; color: "black"
                Left.ControlPanel { anchors.centerIn: parent }
            }
            Repeater {
                // labwc has no tiling layouts, and the indicator hides itself
                // where there are none: shown anyway, each glyph set by hand.
                model: ["dwindle", "master", "monocle", "scrolling"]
                delegate: Rectangle {
                    property string cellName: "module-layout-" + modelData
                    width: 60; height: 44; color: "black"
                    Left.LayoutDisplayer {
                        anchors.centerIn: parent
                        screenName: "test"
                        Component.onCompleted: { visible = true; win.findProp(this, "tileRadius").layout = modelData }
                    }
                }
            }
        }

        function findProp(item, name) {
            if (!item) return null
            if (item[name] !== undefined) return item
            for (let i = 0; i < item.children.length; i++) {
                const p = findProp(item.children[i], name)
                if (p) return p
            }
            return null
        }

        function findPill(item) {
            if (!item) return null
            if (item.shown !== undefined && item.size !== undefined && item.z === -1 && item.radius !== undefined)
                return item
            for (let i = 0; i < item.children.length; i++) {
                const p = findPill(item.children[i])
                if (p) return p
            }
            return null
        }

        property int fi: -1
        property var queue: []

        function nextFactor() {
            fi++
            if (fi >= factors.length) {
                console.warn("PILLDONE")
                Qt.quit()
                return
            }
            SettingsService.scaleMode = "manual"
            SettingsService.scaleManual = factors[fi]
            settle.restart()
        }

        Timer {
            id: settle
            interval: 700     // springs (the pill's scale, the tray's fold) at rest
            onTriggered: {
                win.queue = []
                for (let i = 0; i < flow.children.length; i++)
                    if (flow.children[i].cellName !== undefined) win.queue.push(flow.children[i])
                win.grabNext()
            }
        }

        function grabNext() {
            if (queue.length === 0) { nextFactor(); return }
            const cell = queue.shift()
            const pill = findPill(cell)
            if (!pill) {
                console.warn("PILL " + JSON.stringify({ f: factors[fi], name: cell.cellName, missing: true }))
                grabNext()
                return
            }
            // A pill set up to be shown: the open state forced on, then drawn
            // out of the picture so only the glyph is left in it.
            pill.shown = true
            const c = pill.mapToItem(cell, pill.width / 2, pill.height / 2)
            pill.visible = false
            const file = out + "/" + factors[fi].toFixed(2) + "-" + cell.cellName + ".png"
            const rec = { f: factors[fi], name: cell.cellName, cx: c.x, cy: c.y,
                          pw: pill.width, ph: pill.height, file: file,
                          dpr: win.devicePixelRatio === undefined ? 1 : win.devicePixelRatio }
            cell.grabToImage(function (r) {
                r.saveToFile(file)
                pill.visible = true
                console.warn("PILL " + JSON.stringify(rec))
                win.grabNext()
            })
        }

        Timer { running: true; interval: 1500; onTriggered: win.nextFactor() }
    }
}
