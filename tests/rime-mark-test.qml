import Quickshell
import QtQuick
import "./src"
import "./src/services"
import "./src/components"
import "./src/modules/Left" as Left
import "./src/services/config_tab/pages" as Pages

// ─────────────────────────────────────────────────────────────────────────────
// The Rime mark, drawn. Run via tests/run-rime-mark-test.sh, which reads the
// pictures this writes (tests/lib/rime-mark-check.py).
//
// What can only be seen in pixels:
//   - plane 3 is the accent and planes 1, 2, 4 the ink, on a light and on a
//     dark surface, at every size from the brand pack's 16 px minimum up;
//   - an accent that changes while the mark is on screen is redrawn (the
//     wallpaper palette moves under a running shell);
//   - the bar's mark (Left/ControlPanel) and the About mark (Settings → Misc)
//     are the REAL modules, bound to the live Theme: their accent is
//     Theme.active and their ink Theme.text, read back from the drawn items.
// Every picture is written to MARK_OUT; every record is one "MARK {json}" line.
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    FloatingWindow {
        id: win
        implicitWidth: 1280
        implicitHeight: 900
        color: "#808080"

        readonly property string out: Quickshell.env("MARK_OUT") || ""
        readonly property string scheme: Quickshell.env("MARK_SCHEME") || "dark"

        // Brand surfaces: charcoal / off-white, ink the other one.
        readonly property var surfaces: ({
            dark:  { bg: "#212224", ink: "#FAFAFA" },
            light: { bg: "#FAFAFA", ink: "#212224" }
        })
        readonly property var sizes: [16, 24, 32, 48, 120, 240]
        readonly property color testAccent: "#91C2DC"
        readonly property color changedAccent: "#E0457B"

        Flow {
            id: flow
            width: parent.width
            spacing: 4

            Repeater {
                model: ["dark", "light"]
                delegate: Repeater {
                    id: perSurface
                    property string surface: modelData
                    model: win.sizes
                    delegate: Rectangle {
                        property string cellName: "mark-" + perSurface.surface + "-" + modelData
                        property string kind: "plain"
                        width: modelData + 16; height: Math.round(modelData * 175 / 240) + 16
                        color: win.surfaces[perSurface.surface].bg
                        RimeMark {
                            objectName: "mark"
                            anchors.centerIn: parent
                            width: modelData
                            height: Math.round(modelData * 175 / 240)
                            accent: win.testAccent
                            foreground: win.surfaces[perSurface.surface].ink
                        }
                    }
                }
            }

            // The shipped light palette's own accent on its own ink (dE 9.9).
            Rectangle {
                property string cellName: "mark-collapse"
                property string kind: "collapse"
                width: 136; height: 104; color: "#faf9fb"
                RimeMark {
                    objectName: "mark"
                    anchors.centerIn: parent
                    width: 120; height: 88
                    accent: "#000613"
                    foreground: "#1b1c1e"
                }
            }

            // The bar's mark, the real module, on the bar's own colour.
            Rectangle {
                property string cellName: "bar-controlpanel-" + win.scheme
                property string kind: "bar"
                width: 64; height: 44; color: Theme.background
                Left.ControlPanel { anchors.centerIn: parent }
            }

            // Settings → Misc, the real page; the About block is at its top.
            Rectangle {
                property string cellName: "settings-misc-" + win.scheme
                property string kind: "about"
                width: 640; height: 420; color: Theme.background
                clip: true
                Pages.MiscPage { anchors.fill: parent; onScreen: true }
            }
        }

        function find(item, name) {
            if (!item) return null
            if (item.objectName === name) return item
            const kids = item.children || []
            for (let i = 0; i < kids.length; i++) {
                const p = find(kids[i], name)
                if (p) return p
            }
            // CfgScroll keeps its content under contentItem
            if (item.contentItem && item.contentItem !== item) {
                const p = find(item.contentItem, name)
                if (p) return p
            }
            return null
        }

        function hex(c) {
            const h = v => ("0" + Math.round(v * 255).toString(16)).slice(-2)
            return "#" + h(c.r) + h(c.g) + h(c.b)
        }

        property var queue: []
        property int pass: 0     // 0: as built; 1: after the accent changed

        function record(cell, mark, file) {
            const r = {
                pass: win.pass, scheme: win.scheme, name: cell.cellName, kind: cell.kind, file: file,
                dpr: win.devicePixelRatio === undefined ? 1 : win.devicePixelRatio,
                missing: !mark
            }
            if (mark) {
                const o = mark.mapToItem(cell, 0, 0)
                r.x = o.x; r.y = o.y; r.w = mark.width; r.h = mark.height
                r.small = mark.small
                r.accent = hex(mark.accent); r.foreground = hex(mark.foreground)
                r.planes = [hex(mark.planeColor(0)), hex(mark.planeColor(1)),
                            hex(mark.planeColor(2)), hex(mark.planeColor(3))]
                r.themeActive = hex(Theme.active); r.themeText = hex(Theme.text)
                r.accessibleName = mark.Accessible.name
            }
            return r
        }

        function begin() {
            win.queue = []
            for (let i = 0; i < flow.children.length; i++)
                if (flow.children[i].cellName !== undefined) win.queue.push(flow.children[i])
            grabNext()
        }

        function grabNext() {
            if (queue.length === 0) {
                if (win.pass === 0) {
                    // The accent moves under a running mark.
                    win.pass = 1
                    for (let i = 0; i < flow.children.length; i++) {
                        const c = flow.children[i]
                        if (c.kind === "plain") { const m = find(c, "mark"); if (m) m.accent = win.changedAccent }
                    }
                    settle.restart()
                    return
                }
                console.warn("MARKDONE")
                Qt.quit()
                return
            }
            const cell = queue.shift()
            if (win.pass === 1 && cell.kind !== "plain") { grabNext(); return }
            const name = (cell.kind === "plain" || cell.kind === "collapse") ? "mark"
                       : (cell.kind === "bar" ? "rimeMark" : "aboutRimeMark")
            const mark = find(cell, name)
            const file = out + "/" + win.pass + "-" + cell.cellName + ".png"
            const rec = record(cell, mark, file)
            cell.grabToImage(function (res) {
                res.saveToFile(file)
                console.warn("MARK " + JSON.stringify(rec))
                win.grabNext()
            })
        }

        Timer { id: settle; interval: 600; onTriggered: win.begin() }
        Timer { running: true; interval: 2000; onTriggered: win.begin() }
    }
}
