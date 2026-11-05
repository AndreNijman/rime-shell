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
//   "ppd"    rimed serves the power-profiles-daemon API and maps it 1:1 onto
//            its tiers (rime-os docs/nixos/desktops.md §7). That is every Rime
//            system with a current rimed: NixOS ships no power-profiles-daemon,
//            and since rime-os #139 the bootc image masks it and rimed owns its
//            names there too. The Shell reads through Quickshell's own
//            PowerProfiles object, which follows PropertiesChanged: event-driven,
//            no process, no timer. GNOME's power menu, KDE's battery applet and
//            COSMIC's applet talk to the same object, so a change made in any of
//            them, in `rime tier`, or by an AC change shows here at once. It
//            writes with ONE `busctl set-property … ActiveProfile` per press (see
//            WHY A CHANGE DID NOT HAPPEN).
//   "rimed"  the name is not rimed's: nobody owns it (a rimed that predates the
//            API, or one started with RIMED_POWER_PROFILES=0), or another
//            daemon does (a system that runs power-profiles-daemon on purpose;
//            writing to it would bypass rimed's tiers). The old path stays:
//            `rime tier <id>` sets (rimed SetTier over D-Bus, polkit-authorized
//            for the active local user without a prompt), and the Tier property
//            is re-read with busctl every 4 s while something displays it.
//
// The owner is asked once each time the first consumer arrives (refCount 0 → 1),
// with ONE busctl call sent to the power-profiles NAME for rimed's own object
// (Properties.Get org.rimeos.Rimed1.Power Tier at /org/rimeos/Rimed1). Only a
// connection that is rimed answers it: power-profiles-daemon has no such object
// and nobody answers an unowned name. So "ppd" means "the power-profiles name
// is rimed's", not merely "the name has an owner". That call is the only READ
// the "ppd" path ever starts (a press starts one write): the polling mutant in
// tests/run-power-profile-service-test.sh counts the busctl reads and fails on
// a second one.
//
// WHY A CHANGE DID NOT HAPPEN (`error`, `errorDetail`). On the "rimed" path a
// refused `rime tier` is put into words (explain()) and shown for 8 s by the
// Dashboard's power panel; it used to be thrown away, so the optimistic label
// snapped back and the switch looked like it did nothing. The "ppd" path says
// why too. It does not write through Quickshell's PowerProfiles: Quickshell
// 0.3.2 sets its own value first and only logs a refused write
// (DBusPropertyGroup::pushPropertyUpdate), so the label kept the refused pick
// and nobody learnt why. Instead the press shows the pick at once (`_optimistic`,
// no wait for the daemon) and runs one `busctl set-property` whose exit says
// whether rimed took it: on success the PropertiesChanged rimed sent before its
// reply has already moved PowerProfiles, and the pick gives way to it; on a
// refusal the pick goes (the label is back on what PowerProfiles reads, which
// Quickshell never changed) and the reply's text is put into words. Chosen
// over a rimed "last refusal" property (a per-caller answer broadcast to every
// client of a standard API, racing GNOME's and KDE's writes) and over a
// Quickshell patch (bootc's Shell runs an unpatched Quickshell). One process
// per press, none at rest; rimed's API is unchanged.
//
// The three tier IDs are exactly rimed's AND power-profiles-daemon's
// (performance, balanced, power-saver). Rime has no other tier: `ultra-max` and
// `ultra` were removed from rimed (rimed-core/src/tier.rs; tests/tier_plan.rs
// asserts neither parses) and must not come back here. `check-tier-parity` in
// rime-os fails CI if this list and rimed's `Tier` disagree, in either direction.
// This list is the Shell's own order (high→low); it never reads the D-Bus
// `Profiles` list, whose order (lowest first, as power-profiles-daemon) is for
// other clients.
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
    // shows as the held tier, which is what the machine is running; a pick
    // whose write is on its way shows at once (`_optimistic`).
    readonly property string current: root.usesPowerProfiles
        ? (root._optimistic !== "" ? root._optimistic : root._idOf(PowerProfiles.profile)) : root._rimedTier

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

    // Why the last change did not happen, in words for the person who pressed
    // the button; "" when it did (see the header). `errorDetail` keeps rime's
    // own line for anyone who needs it.
    property string error: ""
    property string errorDetail: ""

    function _idOf(e) {
        switch (e) {
            case PowerProfile.Performance: return "performance"
            case PowerProfile.PowerSaver:  return "power-saver"
            default:                       return "balanced"
        }
    }

    // A set asked for before the owner check answered (the IPC hook can call
    // setProfile while no page holds the service): kept here, the latest one
    // wins, and applied on the backend the check finds. Sent straight away it
    // would take the `rime tier` path, which is the wrong writer when rimed
    // owns the power-profiles name. (rimed itself says whether `performance`
    // exists, so a queued performance no longer waits for Quickshell to read
    // the Profiles list, which its own setProfile needed.)
    property string _pendingSet: ""

    function _flushPending() {
        if (root._pendingSet === "" || root.backend === "")
            return
        const id = root._pendingSet
        root._pendingSet = ""
        root.setProfile(id)
    }

    // ── the power-profiles write ────────────────────────────────────────────
    // The pick on its way to rimed, shown as `current` until rimed's answer:
    // "" when nothing is on its way.
    property string _optimistic: ""
    // A pick made while a write is still on its way: sent when that one
    // answers (latest wins; a running write is never killed, its exit would
    // read as a refusal).
    property string _ppdNext: ""

    function _ppdWrite(id) {
        root._optimistic = id
        if (root.ppdSetProc.running) {
            root._ppdNext = id
            return
        }
        root._ppdStart(id)
    }
    function _ppdStart(id) {
        root.ppdSetProc.target = id
        root.ppdSetProc.command = ["busctl", "--system", "set-property", "org.freedesktop.UPower.PowerProfiles",
                                   "/org/freedesktop/UPower/PowerProfiles", "org.freedesktop.UPower.PowerProfiles",
                                   "ActiveProfile", "s", id]
        root.ppdSetProc.running = true
    }
    readonly property Process ppdSetProc: Process {
        property string target: ""
        command: []
        running: false
        stderr: StdioCollector { id: ppdErr }
        onExited: function (code, status) {
            if (root._ppdNext !== "") {             // a later pick decides; this answer is old
                const next = root._ppdNext
                root._ppdNext = ""
                root._ppdStart(next)
                return
            }
            if (code === 0) {
                root.error = ""
                root.errorDetail = ""
                // rimed sends PropertiesChanged before its reply, so PowerProfiles
                // normally reads the pick already. If not (game mode keeps its own
                // tier and only re-announces it), give the signal one moment.
                if (root._idOf(PowerProfiles.profile) === root.ppdSetProc.target)
                    root._optimistic = ""
                else
                    root._settle.restart()
            } else {
                const text = (ppdErr.text || "").trim()
                root.errorDetail = text.split("\n")[0] || ("busctl exited " + code)
                root.error = root.explain(text)
                root._optimistic = ""               // back on the profile in force
            }
        }
    }
    // One-shot, only after an accepted write PowerProfiles has not shown yet.
    readonly property Timer _settle: Timer {
        interval: 1000
        onTriggered: if (!root.ppdSetProc.running) root._optimistic = ""
    }
    readonly property Connections _profileFollow: Connections {
        target: root.usesPowerProfiles ? PowerProfiles : null
        function onProfileChanged() {
            if (!root.ppdSetProc.running) {
                root._settle.stop()
                root._optimistic = ""
            }
        }
    }

    function setProfile(id) {
        root.error = ""                             // the next press clears the message at once
        root.errorDetail = ""
        if (root.backend === "") {
            root._pendingSet = id
            root._checkOwner()                      // with no consumer nothing has asked yet
            return
        }
        if (root.usesPowerProfiles) {
            root._ppdWrite(id)
            return
        }
        root.getProc.running = false                // a read already on its way holds the OLD tier
        root._rimedTier = id                        // optimistic; the daemon confirms
        root.setProc.command = ["rime", "tier", id]
        root.setProc.running = false
        root.setProc.running = true
    }

    // rime's refusal → a sentence. polkit allows the person signed in at this
    // computer (the active local session) and nobody else, without a prompt.
    function explain(detail) {
        // busctl prints an AccessDenied reply as "Access denied" (sd-bus hides
        // the daemon's text for it); `rime tier` passes rimed's own words.
        if (/not authori[sz]ed|AccessDenied|Access denied/i.test(detail))
            return "Not allowed: only the person signed in at this computer can change the power profile."
        if (/rimed not running|cannot reach rimed|ServiceUnknown|NameHasNoOwner|not provided by any \.service files/i.test(detail))
            return "The power service is not running, so the profile was not changed."
        return "The power profile was not changed."
    }

    // An error stays up long enough to read, then goes; the next press clears
    // it at once.
    readonly property Timer errorTimer: Timer {
        interval: 8000
        running: root.error !== ""
        onTriggered: {
            root.error = ""
            root.errorDetail = ""
        }
    }

    // ── which backend ───────────────────────────────────────────────────────
    readonly property Process ownerProc: Process {
        // Addressed to the power-profiles name, asking for rimed's object: answered
        // (`v s "<tier>"`, exit 0) only when rimed owns that name (see the header).
        command: ["busctl", "--system", "call", "org.freedesktop.UPower.PowerProfiles", "/org/rimeos/Rimed1",
                  "org.freedesktop.DBus.Properties", "Get", "ss", "org.rimeos.Rimed1.Power", "Tier"]
        running: false
        property bool owned: false
        stdout: SplitParser {
            onRead: function (line) {
                if (/^v\s+s\s+"/.test(line.trim()))
                    root.ownerProc.owned = true
            }
        }
        onExited: function (code) {
            if (code !== 0)
                root.ownerProc.owned = false
            root.backend = root.ownerProc.owned ? "ppd" : "rimed"
            if (root._pendingSet !== "") {
                root._flushPending()                // the set's own exit reads the tier back
                return
            }
            // The fallback's first read. Not while a set is in flight (see poll).
            if (root.backend === "rimed" && root.refCount > 0 && !root.setProc.running)
                root._refresh()
        }
    }
    function _checkOwner() {
        // One in flight answers for everyone. Restarting it would end it early,
        // and that exit (code != 0) would read as "rimed" and send a queued set
        // down the wrong path.
        if (root.ownerProc.running)
            return
        root.ownerProc.owned = false
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
        stderr: StdioCollector { id: setErr }
        onExited: function (code, status) {
            if (code === 0) {
                root.error = ""
                root.errorDetail = ""
            } else {
                const text = (setErr.text || "").trim()
                root.errorDetail = text.split("\n")[0] || ("rime tier exited " + code)
                root.error = root.explain(text)
            }
            root._refresh()
        }
    }

    // read: busctl get-property prints `s "balanced"`; pull the quoted value.
    readonly property Process getProc: Process {
        command: ["busctl", "--system", "get-property", "org.rimeos.Rimed1", "/org/rimeos/Rimed1", "org.rimeos.Rimed1.Power", "Tier"]
        running: false
        stdout: SplitParser {
            onRead: function (line) {
                const m = line.match(/"([^"]+)"/)
                // A read that lands while a set is in flight is the old tier
                // (it started before the set); the set's own exit reads again.
                if (m && m[1] !== "" && !root.setProc.running)
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
        // Not while a set is in flight: the daemon still holds the OLD tier,
        // and reading it would flip the label back under the user's finger.
        // The set's own exit reads the real value.
        onTriggered: if (!root.setProc.running) root._refresh()
    }
}
