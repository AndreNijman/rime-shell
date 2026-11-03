pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower

// ─────────────────────────────────────────────────────────────────────────────
// PowerProfileService — Rime Shell front-end for Rime's power tiers.
//
// TWO BACKENDS, chosen by who owns org.freedesktop.UPower.PowerProfiles:
//
//   "ppd"    rimed serves the power-profiles-daemon API (rime-os
//            docs/nixos/desktops.md §7: power-profiles-daemon is not run, rimed
//            owns its names and maps them 1:1 onto its tiers). The Shell then
//            reads and writes through Quickshell's own PowerProfiles object,
//            which follows PropertiesChanged: event-driven, no process, no
//            timer. GNOME's power menu, KDE's battery applet and COSMIC's
//            applet talk to the same object, so a change made in any of them,
//            in `rime tier`, or by an AC change shows here at once.
//   "rimed"  the name has no owner: a machine on a rimed that predates the API
//            (bootc today). The old path stays: `rime tier <id>` sets (rimed
//            SetTier over D-Bus, polkit-authorized), and the Tier property is
//            re-read with busctl every 4 s while something displays it.
//
// The owner is asked once each time the first consumer arrives (refCount 0 → 1),
// with one `busctl NameHasOwner` call. That is the only process the "ppd" path
// ever starts: the polling mutant in tests/run-power-profile-service-test.sh
// counts the busctl calls and fails on a second one.
//
// The three tier IDs are exactly rimed's AND power-profiles-daemon's
// (performance, balanced, power-saver). Rime has no other tier: `ultra-max` and
// `ultra` were removed from rimed (rimed-core/src/tier.rs; tests/tier_plan.rs
// asserts neither parses) and must not come back here. `check-tier-parity` in
// rime-os fails CI if this list and rimed's `Tier` disagree, in either direction.
// ─────────────────────────────────────────────────────────────────────────────

Singleton {
    id: root

    property int refCount: 0

    property int interval: 4000

    // High→low, matching rimed's tier ladder and the historical picker order.
    readonly property var profiles: [
        {
            "id": "performance",
            "label": "Performance"
        },
        {
            "id": "balanced",
            "label": "Balanced"
        },
        {
            "id": "power-saver",
            "label": "Power Saver"
        }
    ]

    // "" until the first owner check answers, then "ppd" or "rimed".
    property string backend: ""
    readonly property bool usesPowerProfiles: root.backend === "ppd"

    // The rimed fallback's last read (or optimistic) value.
    property string _rimedTier: "balanced"

    // The effective tier. Under "ppd" a hold (Gaming Mode holds performance)
    // shows as the held tier, which is what the machine is running.
    readonly property string current: root.usesPowerProfiles ? root._idOf(PowerProfiles.profile) : root._rimedTier

    readonly property bool hasPerformance: root.usesPowerProfiles ? PowerProfiles.hasPerformanceProfile : true
    // "" or the reason performance is capped (lap detected, temperature).
    readonly property string degradation: root.usesPowerProfiles
        && PowerProfiles.degradationReason !== PerformanceDegradationReason.None
        ? PerformanceDegradationReason.toString(PowerProfiles.degradationReason) : ""
    // [{profile, applicationId, reason}] — who is holding a tier, e.g. Gaming Mode.
    readonly property var holds: {
        if (!root.usesPowerProfiles)
            return []
        const out = []
        for (const h of PowerProfiles.holds)
            out.push({ "profile": root._idOf(h.profile), "applicationId": h.applicationId, "reason": h.reason })
        return out
    }

    function _idOf(e) {
        switch (e) {
            case PowerProfile.Performance: return "performance"
            case PowerProfile.PowerSaver:  return "power-saver"
            default:                       return "balanced"
        }
    }
    function _enumOf(id) {
        switch (id) {
            case "performance": return PowerProfile.Performance
            case "power-saver": return PowerProfile.PowerSaver
            default:            return PowerProfile.Balanced
        }
    }

    function setProfile(id) {
        if (root.usesPowerProfiles) {
            // Writes ActiveProfile; rimed answers with PropertiesChanged.
            PowerProfiles.profile = root._enumOf(id)
            return
        }
        root._rimedTier = id                        // optimistic; the daemon confirms
        root.setProc.command = ["rime", "tier", id]
        root.setProc.running = false
        root.setProc.running = true
    }

    // ── which backend ───────────────────────────────────────────────────────
    readonly property Process ownerProc: Process {
        command: ["busctl", "--system", "call", "org.freedesktop.DBus", "/org/freedesktop/DBus",
                  "org.freedesktop.DBus", "NameHasOwner", "s", "org.freedesktop.UPower.PowerProfiles"]
        running: false
        property bool owned: false
        stdout: SplitParser {
            onRead: function (line) {
                if (/^b\s+true/.test(line.trim()))
                    root.ownerProc.owned = true
            }
        }
        onExited: {
            root.backend = root.ownerProc.owned ? "ppd" : "rimed"
            if (root.backend === "rimed" && root.refCount > 0)
                root._refresh()
        }
    }
    function _checkOwner() {
        root.ownerProc.owned = false
        root.ownerProc.running = false
        root.ownerProc.running = true
    }
    property int _lastRefs: 0
    onRefCountChanged: {
        if (root._lastRefs === 0 && root.refCount > 0)
            root._checkOwner()
        root._lastRefs = root.refCount
    }

    // ── the rimed fallback ──────────────────────────────────────────────────
    // set: `rime tier <id>` → rimed SetTier (D-Bus, polkit-authorized). Refresh
    // from the daemon once the call returns so the UI settles on the real value.
    readonly property Process setProc: Process {
        command: []
        running: false
        onExited: root._refresh()
    }

    // read: busctl get-property prints `s "balanced"`; pull the quoted value.
    readonly property Process getProc: Process {
        command: ["busctl", "--system", "get-property", "org.rimeos.Rimed1", "/org/rimeos/Rimed1", "org.rimeos.Rimed1.Power", "Tier"]
        running: false
        stdout: SplitParser {
            onRead: function (line) {
                const m = line.match(/"([^"]+)"/)
                if (m && m[1] !== "")
                    root._rimedTier = m[1]
            }
        }
    }

    function _refresh() {
        root.getProc.running = false
        root.getProc.running = true
    }

    readonly property Timer poll: Timer {
        interval: root.interval
        running: root.refCount > 0 && root.backend === "rimed"
        repeat: true
        onTriggered: root._refresh()
    }
}
