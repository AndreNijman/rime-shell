import QtQuick
import Quickshell
import Quickshell.Io
import "../../../"
import "../../"
import "../../../components"
import "../../../components/config"

// Config → Desktops
//
// GNOME, KDE Plasma and COSMIC beside Rime's own sessions (rime-os
// docs/nixos/desktops.md). A desktop is a prebuilt system feature of the
// running release: installing one switches it on and activates the same
// release's variant that carries it, live, without a reboot, and it is offered
// at the login screen from the next time the greeter starts. Rime adds one
// other desktop at a time.
//
// What the page lists comes from /etc/rime/catalogue.json, the catalogue the
// running system was built with: its `features` whose `group` is "desktop",
// with `in_system` (this system carries it) and `switch` (the file that selects
// it). The disk each choice needs is the published floor of the variant it
// would select (catalogue `floors`), and what it adds is that floor's store
// size minus this system's. Nothing is hard-coded except the ids to
// look for when a catalogue predates the `group` field.
//
// Installing and removing need root. The page runs
//     pkexec /usr/bin/rime install <id>      (and `remove`)
// and the desktop's own polkit agent asks for the password (polkit action
// org.rimeos.rime.system, auth_admin_keep). On a system without the catalogue
// (bootc) the page says other desktops are not offered.
CfgScroll {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    lifecycle: "live"

    property bool onScreen: false

    readonly property string cataloguePath: Quickshell.env("RIME_CATALOGUE") || "/etc/rime/catalogue.json"
    readonly property var knownIds: ["gnome", "kde", "cosmic"]

    property var catalogue: null
    property bool catalogueRead: false

    FileView {
        id: catFile
        path: root.cataloguePath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try {
                root.catalogue = JSON.parse(String(text()))
            } catch (e) {
                root.catalogue = null
            }
            root.catalogueRead = true
        }
        onLoadFailed: { root.catalogue = null; root.catalogueRead = true }
    }

    // [{id, title, summary, inSystem, switchPath, group}]
    readonly property var desktops: {
        const c = root.catalogue
        if (!c || !c.features)
            return []
        const out = []
        // Rime's order first (GNOME, KDE Plasma, COSMIC), then any other.
        const rank = id => { const i = root.knownIds.indexOf(id); return i < 0 ? 99 : i }
        const ids = Object.keys(c.features).sort((a, b) => rank(a) - rank(b) || (a < b ? -1 : a > b ? 1 : 0))
        for (const id of ids) {
            const f = c.features[id]
            const isDesktop = f.group === "desktop" || (f.group === undefined && root.knownIds.indexOf(id) >= 0)
            if (!isDesktop || f.offered === false)
                continue
            out.push({ "id": id, "title": f.title || id, "summary": f.summary || "",
                       "inSystem": f.in_system === true, "switchPath": f.switch || "" })
        }
        return out
    }
    readonly property var installed: root.desktops.filter(d => d.inSystem)

    // The variant a choice selects: "plain", then every other feature this
    // system carries, plus the desktop, sorted and joined by "-" (as the
    // release names them: nix/release/variants.nix).
    function variantWith(id) {
        const c = root.catalogue
        const names = []
        for (const k of Object.keys((c && c.features) || {})) {
            const f = c.features[k]
            const isDesktop = f.group === "desktop" || (f.group === undefined && root.knownIds.indexOf(k) >= 0)
            if (!isDesktop && f.in_system === true)
                names.push(k)
        }
        if (id !== "")
            names.push(id)
        names.sort()
        return ["plain"].concat(names).join("-")
    }
    function floorText(id) {
        const c = root.catalogue
        const fl = c && c.floors ? c.floors[root.variantWith(id)] : null
        return fl && fl.disk_gb ? "Needs a disk of at least " + fl.disk_gb + " GB" : ""
    }
    // What the desktop adds on disk: the floor store size of the variant it
    // selects minus that of the variant this machine runs (catalogue `floors`,
    // nix/release/floors.nix: measured base + the desktop's measured closure).
    function sizeText(id) {
        const c = root.catalogue
        const fl = c && c.floors ? c.floors : null
        const want = fl ? fl[root.variantWith(id)] : null
        const have = fl ? fl[root.variantWith("")] : null
        if (!want || !have || !want.store_bytes || !have.store_bytes)
            return ""
        const add = want.store_bytes - have.store_bytes
        return add > 0 ? "adds about " + (add / 1e9).toFixed(1) + " GB on disk" : ""
    }

    // ── install / remove ─────────────────────────────────────────────────────
    property string busyId: ""
    property string busyVerb: ""
    property string lastResult: ""
    property bool lastFailed: false

    readonly property Process act: Process {
        command: []
        running: false
        property string _out: ""
        stdout: StdioCollector { onStreamFinished: root.act._out = this.text }
        stderr: StdioCollector { onStreamFinished: if (this.text.trim() !== "") root.act._out += "\n" + this.text }
        onExited: function (code) {
            const lines = root.act._out.trim().split("\n").filter(l => l.trim() !== "")
            root.lastFailed = code !== 0
            root.lastResult = code === 126 || code === 127
                ? "Not authorized."
                : (lines.length > 0 ? lines[lines.length - 1] : (code === 0 ? "Done." : "Failed (" + code + ")."))
            root.busyId = ""
            root.busyVerb = ""
            catFile.reload()
        }
    }

    function run(verb, id) {
        if (root.busyId !== "")
            return "busy"
        root.busyId = id
        root.busyVerb = verb
        root.lastResult = ""
        root.act._out = ""
        root.act.command = ["pkexec", "/usr/bin/rime", verb, id]
        root.act.running = true
        return verb + " " + id
    }

    // ── what is on this machine ──────────────────────────────────────────────
    CfgSection {
        title: "Other desktops"
        first: true

        Text {
            width: parent.width
            visible: root.catalogueRead && root.desktops.length === 0
            text: "This system does not offer other desktops."
            wrapMode: Text.WordWrap
            font.pixelSize: theme.fs(11)
            color: Theme.subtext
        }

        Text {
            width: parent.width
            visible: root.desktops.length > 0
            text: "Rime's own sessions stay. A desktop you add appears at the login screen the next time you log out; nothing restarts. Rime adds one other desktop at a time."
            wrapMode: Text.WordWrap
            font.pixelSize: theme.typeCaption
            color: Theme.subtext
        }

        Repeater {
            model: root.desktops
            delegate: CfgRow {
                id: row
                required property var modelData
                readonly property bool busy: root.busyId === modelData.id
                readonly property var blocker: root.installed.find(d => d.id !== modelData.id)
                label: modelData.title
                status: busy ? (root.busyVerb === "install" ? "Installing…" : "Removing…")
                        : modelData.inSystem ? "Installed" : ""
                description: [modelData.summary, root.sizeText(modelData.id),
                              modelData.inSystem ? "" : root.floorText(modelData.id)]
                             .filter(s => s !== "").join(". ")
                disabledReason: !modelData.inSystem && blocker
                    ? blocker.title + " is installed: remove it first" : ""

                CfgButton {
                    label: row.modelData.inSystem ? "Remove" : "Install"
                    icon: row.modelData.inSystem ? "󰆴" : "󰇚"
                    variant: row.modelData.inSystem ? "danger" : "default"
                    enabled: root.busyId === "" && !row.unavailable
                    onClicked: root.run(row.modelData.inSystem ? "remove" : "install", row.modelData.id)
                }
            }
        }

        Text {
            width: parent.width
            visible: root.lastResult !== ""
            text: root.lastResult
            wrapMode: Text.WordWrap
            font.pixelSize: theme.typeCaption
            color: root.lastFailed ? Theme.danger : Theme.subtext
        }
    }
}
