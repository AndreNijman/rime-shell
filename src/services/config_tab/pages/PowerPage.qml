import QtQuick
import Quickshell
import Quickshell.Io
import "../../../"
import "../../"
import "../../system"
import "../../../components"
import "../../../components/config"

// Config → Power
//
// Rime's power tiers, whether rimed moves between them on its own when the
// charger comes and goes, and the battery charge limit. All three are rimed's
// (org.rimeos.Rimed1.Power and .Battery on the system bus); this page owns
// nothing and stages nothing. rimed authorizes each write through polkit,
// passwordless for the active local session, so there is no prompt.
//
// It is in the Shell's Nexus and in Rime Settings, the app GNOME, KDE Plasma
// and COSMIC users open. In those desktops the desktop's own power menu also
// drives the same tiers (rimed serves the power-profiles-daemon API), so a tier
// picked there shows here and the other way round: the tier comes from
// PowerProfileService, which follows rimed's PropertiesChanged.
//
// `chooseTier` is the one handler the tier control calls. Rime Settings' IPC
// test hook (`settings power <tier>`) calls it too, so a test changes the tier
// exactly the way a click does.
CfgScroll {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForHeight(Screen.height) }   // P1-040: this output's sizes

    lifecycle: "live"

    // Set by SettingsHost: the page is on screen. The auto-switch and battery
    // reads run when it arrives and after each write, never on a timer.
    property bool onScreen: false

    ServiceRef {
        service: PowerProfileService
        active: root.onScreen
    }

    function chooseTier(id) {
        for (const p of PowerProfileService.profiles)
            if (p.id === id) {
                PowerProfileService.setProfile(id)
                return "power tier " + id
            }
        return "unknown tier: " + id
    }

    // What the tier row shows right now: the selected tier and the reason
    // line (empty when hidden). Rime Settings' IPC (`settings powerState`)
    // returns it, so a test reads the page, not the service behind it.
    function tierState() {
        return JSON.stringify({ tier: tierControl.value, reason: tierReason.visible ? tierReason.status : "" })
    }

    // ── rimed reads (busctl --system; one shot each) ─────────────────────────
    property bool autoSwitch: true
    property bool batterySupported: false
    property int  chargeStart: 0
    property int  chargeEnd: 100
    property string writeError: ""

    function _value(line) {
        // busctl get-property prints `b true`, `y 80`.
        const parts = line.trim().split(/\s+/)
        return parts.length >= 2 ? parts[1] : ""
    }

    readonly property Process readProc: Process {
        command: ["busctl", "--system", "get-property", "org.rimeos.Rimed1", "/org/rimeos/Rimed1",
                  "org.rimeos.Rimed1.Power", "AutoSwitch"]
        running: false
        stdout: SplitParser {
            onRead: line => root.autoSwitch = root._value(line) === "true"
        }
        onExited: root.batteryProc.running = true
    }
    readonly property Process batteryProc: Process {
        command: ["busctl", "--system", "get-property", "org.rimeos.Rimed1", "/org/rimeos/Rimed1",
                  "org.rimeos.Rimed1.Battery", "Supported", "ChargeStart", "ChargeEnd"]
        running: false
        property int _n: 0
        onStarted: _n = 0
        stdout: SplitParser {
            onRead: function (line) {
                const v = root._value(line)
                switch (root.batteryProc._n++) {
                    case 0: root.batterySupported = v === "true"; break
                    case 1: root.chargeStart = parseInt(v) || 0; break
                    case 2: root.chargeEnd = parseInt(v) || 100; break
                }
            }
        }
    }
    readonly property Process writeProc: Process {
        command: []
        running: false
        stderr: StdioCollector {
            onStreamFinished: root.writeError = this.text.trim()
        }
        onExited: root.refresh()
    }

    function refresh() {
        root.readProc.running = false
        root.readProc.running = true
    }
    function _write(args) {
        root.writeError = ""
        root.writeProc.command = ["busctl", "--system", "call", "org.rimeos.Rimed1", "/org/rimeos/Rimed1"].concat(args)
        root.writeProc.running = false
        root.writeProc.running = true
    }
    function setAutoSwitch(on) {
        root.autoSwitch = on
        root._write(["org.rimeos.Rimed1.Power", "SetAutoSwitch", "b", on ? "true" : "false"])
    }
    function setChargeEnd(end) {
        // Keep the start below the end: rimed refuses start >= end.
        const start = Math.min(root.chargeStart, Math.max(0, end - 5))
        root.chargeEnd = end
        root._write(["org.rimeos.Rimed1.Battery", "SetChargeThresholds", "yy", String(start), String(end)])
    }

    property int _pendingEnd: 100
    Timer {
        id: chargeDebounce
        interval: 400
        onTriggered: root.setChargeEnd(root._pendingEnd)
    }

    onOnScreenChanged: if (onScreen) root.refresh()

    // ── Tier ─────────────────────────────────────────────────────────────────
    CfgSection {
        title: "Power profile"
        first: true

        CfgRow {
            label: "Tier"
            description: PowerProfileService.usesPowerProfiles
                ? "The same setting as your desktop's own power menu: both talk to rimed."
                : "Applied by rimed: CPU policy, energy preference and the firmware profile."
            CfgSegmented {
                id: tierControl
                options: PowerProfileService.profiles.map(p => ({ value: p.id, label: p.label }))
                value: PowerProfileService.current
                onSelected: function (v) { root.chooseTier(v) }
            }
        }

        // Why a press did not change the tier (rimed refused it, rimed not
        // running). Without it the tier snapped back and said nothing.
        CfgRow {
            id: tierReason
            visible: PowerProfileService.error !== ""
            label: "Not changed"
            hoverable: false
            statusWarns: true
            status: PowerProfileService.error
        }

        CfgRow {
            visible: PowerProfileService.holds.length > 0
            label: "Held"
            hoverable: false
            description: PowerProfileService.holds.map(h => (h.reason || h.applicationId) + " holds " + h.profile).join("; ")
                + ". Your choice applies again when the hold ends."
        }

        CfgRow {
            visible: PowerProfileService.degradation !== ""
            label: "Performance is limited"
            hoverable: false
            statusWarns: true
            status: PowerProfileService.degradation
        }

        CfgRow {
            label: "Switch with the charger"
            description: "rimed picks Balanced on battery and your tier again on AC."
            CfgSwitch {
                checked: root.autoSwitch
                onToggled: function (v) { root.setAutoSwitch(v) }
            }
        }
    }

    // ── Battery ──────────────────────────────────────────────────────────────
    CfgSection {
        title: "Battery"
        visible: root.batterySupported

        CfgRow {
            label: "Stop charging at"
            description: "A battery kept below full lasts more years. Charging resumes below " + root.chargeStart + " %."
            CfgSlider {
                value: root.chargeEnd
                from: 50
                to: 100
                step: 5
                suffix: " %"
                // One write when the slider settles, not one per step dragged.
                onMoved: function (v) { root._pendingEnd = Math.round(v); chargeDebounce.restart() }
            }
        }
    }

    CfgSection {
        title: ""
        visible: root.writeError !== ""
        Text {
            width: parent.width
            text: "rimed refused the change: " + root.writeError
            wrapMode: Text.WordWrap
            font.pixelSize: theme.typeCaption
            color: Theme.danger
        }
    }
}
