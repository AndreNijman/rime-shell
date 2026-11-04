pragma Singleton
import Quickshell
import QtQuick
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import "../."
import "hyprConfig.js" as HyprConfig

// Global shell state.
//
// WiFi              — owned by QuickSettings (nmcli)
// Night Light       — owned by QuickSettings (hyprsunset)
// Caffeine          — logind `idle` block inhibitor AND a Wayland surface
//                     inhibitor, both unconditionally; see below for why both
//                     and why neither is keyed on the compositor
// Hotspot           — owned by QuickSettings (nmcli hotspot)
// Airplane Mode     — owned by QuickSettings (rfkill)
// Focus Mode        — owned by FocusMode (state/FocusMode.qml); TopBar reacts to hide + zero gaps
// DND               — read by NotificationService to suppress incoming notifications
// VPN               — action state from VPNTab plus an idle-state system probe

QtObject {
    id: root

    // The three notch widths used to live here, one field each, written by
    // every TopBar and read by PopupDismiss. They are gone (P1-040): a bar per
    // output all binding into one field is last-writer-wins, and it only looked
    // correct while every bar computed the same number. shell.qml hands each
    // PopupDismiss the bar from its own per-screen Scope instead.

    property bool focusMode:    false
    property bool dnd:          false
    property bool screenRecord: false
    property bool hotspot:      false
    property bool airplane:     false

    // Caffeine — while true, nothing may dim, lock, blank or suspend the
    // machine. Two independent inhibitors enforce that; see below.
    property bool caffeine:     false

    // ── Caffeine's logind inhibitor ───────────────────────────────────────────
    // This is the one that actually works, and it is held on EVERY compositor.
    //
    // ── What this replaced, and why it was wrong ──────────────────────────────
    // This Process used to be gated `root.caffeine && Compositor.isLabwc`, on
    // the belief that the Wayland surface inhibitor in each TopBar covered
    // Hyprland and niri and only labwc needed a logind lock. That was the last
    // place in the shell where real behaviour was keyed on a compositor NAME,
    // and it turned out to be keyed on it backwards.
    //
    // Measured by tests/measure-idle-inhibit.sh — one arm per fresh nested
    // compositor, each treated arm paired with a control that had to fire
    // before it counted, verdict taken from a marker file the idle rule itself
    // creates rather than from a grep of the daemon's log:
    //
    //   Hyprland 0.56.2 + hypridle 0.1.8
    //     Wayland inhibitor on a LAYER SURFACE  -> idle FIRED. No effect.
    //     Wayland inhibitor on a toplevel       -> suppressed.
    //     logind --what=idle --mode=block       -> suppressed.
    //   labwc 0.9.6 + hypridle 0.1.8
    //     Wayland inhibitor on a layer surface  -> suppressed.
    //     logind --what=idle --mode=block       -> suppressed.
    //
    // Hyprland ignores idle inhibitors on layer-shell surfaces, and the bar IS
    // a layer surface. So Caffeine did nothing at all on the primary
    // compositor: the tile lit up and the screen locked anyway. The labwc
    // branch was aiming the one mechanism that works at the one compositor that
    // did not need it.
    //
    // ── Why there is no capability for this ───────────────────────────────────
    // Because nothing here varies by compositor. A logind `idle` block
    // inhibitor is not a compositor feature; it is a logind lock that hypridle
    // consults (measured: held -> no listener fires, released -> they fire).
    // An `idleInhibit` capability would therefore be declared true by all four
    // backends and would select the same mechanism in every one — a key
    // carrying no information, whose only real effect would be to offer a
    // future backend author somewhere to write `false` and silently kill a
    // feature Andre uses. The §17 debt here is discharged by DELETING the
    // compositor branch, not by abstracting it: there was never a compositor
    // question to ask.
    readonly property Process caffeineInhibitor: Process {
        command: [
            "setpriv", "--pdeathsig", "TERM",
            "systemd-inhibit",
            "--what=idle",
            "--who=Rime Shell",
            "--why=Caffeine is enabled",
            "--mode=block",
            // systemd-inhibit forks the payload. Give that process the same
            // parent-death guarantee so neither side survives a shell crash.
            "setpriv", "--pdeathsig", "TERM", "sleep", "infinity"
        ]
        // Caffeine and nothing else. No compositor name, no capability: a
        // second condition here is a way for the feature to be dead on some
        // session nobody tested, which is exactly what happened last time.
        running: root.caffeine
    }

    // VPN state must be alive with the bar, not owned by VPNTab: that tab is
    // lazy-loaded, so a connection established before opening it otherwise has
    // no indicator. VPNTab writes changes immediately; this low-frequency probe
    // catches connections made externally without leaving a monitor process
    // behind across Quickshell reloads.
    readonly property Process vpnRefresh: Process {
        // Resolve NetworkManager and sing-box in one process so an older
        // fallback result cannot overwrite a newer NetworkManager result.
        command: ["sh", "-c",
            "name=$(nmcli -t -f TYPE,NAME con show --active 2>/dev/null" +
            " | awk -F: '$1==\"wireguard\" || $1==\"vpn\" {sub(/^[^:]*:/, \"\"); print; exit}'); " +
            "if [ -z \"$name\" ] && systemctl is-active --quiet sing-box.service 2>/dev/null; then name=sing-box; fi; " +
            "printf '%s' \"$name\""]
        running: false
        stdout: StdioCollector {
            onStreamFinished: root.applyVpnProbeResult(
                text.trim(), root._vpnProbeGeneration)
        }
    }

    readonly property Timer vpnRefreshTimer: Timer {
        interval: 30000
        repeat: true
        running: true
        triggeredOnStart: true
        onTriggered: {
            if (root.vpnRefresh.running || root.vpnConnecting)
                return
            root._vpnProbeGeneration = root._vpnGeneration
            root.vpnRefresh.running = true
        }
    }

    // ── Fullscreen window tracking (bar + borders unmap for it) ──────────────
    // The bar and the three border strips are layer-shell surfaces on layer
    // `top`, which the compositor draws ABOVE a fullscreen window. So a game
    // paid for compositing four extra surfaces on every single frame, forever,
    // and anything that repainted one of them (the cava visualiser, a clock
    // tick) forced a recomposite between the game's own frames.
    //
    // Setting `visible: false` on a Quickshell PanelWindow genuinely UNMAPS the
    // layer surface — verified on hardware by watching `hyprctl layers` while
    // toggling a popup (4 -> 5 -> 4) — so there is nothing left for the
    // compositor to draw.
    //
    // ToplevelManager is wlr-foreign-toplevel-management, NOT a Hyprland
    // interface: this has to keep working under niri, which the base ships as a
    // selectable session.
    //
    // Exposed as the toplevel itself rather than a bool so each bar can check
    // whether the fullscreen window is on ITS screen; a fullscreen game on one
    // monitor should not blank the bar on another.
    readonly property var activeFullscreenToplevel: {
        var t = ToplevelManager.activeToplevel
        return (t && t.fullscreen) ? t : null
    }

    /// Whether the bar on `screenName` should unmap. Popups are separate windows
    /// anchored to the bar, so never unmap it while one is open — that would
    /// leave a popup parented to a surface that no longer exists.
    function fullscreenCovers(screenName) {
        var t = root.activeFullscreenToplevel
        if (!t)             return false
        if (Popups.anyOpen) return false
        var ss = t.screens
        // An empty/unknown screen list means the compositor did not tell us; the
        // safe reading is "it covers this output", because the alternative is
        // leaving the bar over a fullscreen game.
        if (!ss || ss.length === 0) return true
        for (var i = 0; i < ss.length; i++)
            if (ss[i] && ss[i].name === screenName) return true
        return false
    }

    // WiFi — false when radio is off OR hotspot is using the interface
    property bool wifiOn:       false

    // VPN — set by VPNTab and the low-frequency state probe, read by Network.qml
    property bool   vpnActive:     false
    property bool   vpnConnecting: false
    property string vpnName:       ""
    property int    _vpnGeneration: 0
    property int    _vpnProbeGeneration: -1

    // VPNTab is the owner of action transitions. Every update invalidates a
    // periodic probe that may still be carrying the pre-action system state.
    function updateVpnState(active, connecting, name) {
        root._vpnGeneration++
        root.vpnActive = active
        root.vpnConnecting = connecting
        root.vpnName = name
    }

    function applyVpnProbeResult(name, generation) {
        // Discard any result that predates a VPNTab state transition. Checking
        // vpnConnecting alone is insufficient: an old probe can return just
        // after the action has completed.
        if (root.vpnConnecting || generation !== root._vpnGeneration)
            return false
        root.vpnActive = name !== ""
        root.vpnName = name
        return true
    }

    // ── Hardware Detection ──────────────────────────────────────────
    property bool hasBattery: false
    
    function _checkBattery() {
        if (UPower.displayDevice && UPower.displayDevice.ready) {
            hasBattery = UPower.displayDevice.isLaptopBattery
        }
    }
    
    Component.onCompleted: {
        _checkBattery()
    }
    
    property var _batConn: Connections {
        target: UPower.displayDevice
        function onReadyChanged() {
            _checkBattery()
        }
    }

    // ── Keybind interception ──────────────────────────────────────────────────
    //
    // While the user is recording a new shortcut, every key has to reach the
    // shell rather than firing whatever it is currently bound to. On Hyprland
    // that is a submap with no binds in it; nothing else Rime ships has an
    // equivalent, so the adapter reports no capability and refuses — which is
    // what the `!Compositor.isHyprland` early return here did by hand, along
    // with the two-dialect hyprctl split that now lives in HyprlandBackend.
    property Connections keybindListener: Connections {
        target: KeybindService

        function onIsCapturingChanged() {
            CompositorService.setKeyboardInterception(KeybindService.isCapturing)
        }
    }
    
    // ── Is Hyprland running Rime's Lua config? ────────────────────────────────
    //
    // Hyprland 0.57 has one config manager, Lua: there is no hyprlang parser
    // and no keyword request left, so everything the shell changes at runtime
    // goes through `hyprctl eval`, and everything it persists is a module that
    // ~/.config/hypr/hyprland.lua requires. The shell used to carry a "conf"
    // dialect for a hyprland.conf, chosen by a probe that defaulted to it — and
    // against 0.57 every one of those writes was a silent no-op.
    //
    // What can still go wrong is the CONFIG, and it must never be quiet:
    //
    //   no-config        there is no ~/.config/hypr/hyprland.lua at all;
    //   not-lua          eval answers that Lua is not the running manager (a
    //                    Hyprland older than this shell expects);
    //   modules-missing  Hyprland is running a hyprland.lua that never loaded
    //                    Rime's modules — Hyprland's own autogenerated example
    //                    won the race with the seeder, a hand-written file has
    //                    no require lines, or the keybindings module errored.
    //
    // Each is logged and posted once as a notification that names the fix.
    // The probe (HyprlandBackend.checkHyprConfig) asks the running instance,
    // not the file: a file that exists proves nothing about what Hyprland
    // loaded.
    //
    //   "unknown" until the first answer (and on a non-Hyprland session), then
    //   "ok" or one of the three above.
    property string hyprConfig: "unknown"
    property string hyprConfigDetail: ""
    property string _hyprConfigNotified: ""
    property int _hyprConfigRetries: 0

    // The fix, as a user can run it. /usr/libexec is rewritten to the system
    // profile by the NixOS package.
    readonly property string hyprConfigFix:
        "Run /usr/libexec/rime-hypr-migrate to convert an old hyprland.conf, "
        + "or log out and back in so Rime can seed ~/.config/hypr/hyprland.lua."

    function _hyprConfigMessage(state) {
        if (state === "no-config")
            return "There is no ~/.config/hypr/hyprland.lua, so keybinds, display "
                 + "and input settings have nothing to load them."
        if (state === "not-lua")
            return "Hyprland is not running a Lua config, so the shell cannot "
                 + "change it (" + root.hyprConfigDetail + ")."
        if (state === "modules-missing")
            return "Hyprland's config did not load Rime's modules, so keybinds, "
                 + "display and input settings are not applied."
        return ""
    }

    // Called by HyprlandBackend, which owns the probe: only the adapter
    // spawns hyprctl (tests/check-compositor-backends.sh). This side keeps the
    // answer and makes sure a bad one is never quiet.
    //
    // What an answer changes is decided in hyprConfig.js (tests/hypr-config-
    // test.js): "unknown" changes nothing, "loaded again" is logged only when a
    // problem clears, and a problem's critical notice is posted once.
    function reportHyprConfig(state, detail) {
        const v = HyprConfig.step(root.hyprConfig, root._hyprConfigNotified, state)
        if (!v.verdict) return
        root.hyprConfigDetail = detail || ""
        root.hyprConfig = v.state
        root._hyprConfigNotified = v.notified
        if (v.loadedAgain)
            console.info("Rime Shell: Hyprland's Lua config is loaded again")
        if (!v.problem) return
        const msg = root._hyprConfigMessage(state)
        console.error("Rime Shell: Hyprland config problem (" + state + "): " + msg
                      + " " + root.hyprConfigFix)
        if (!v.notify) return
        hyprConfigNotice.command = ["notify-send", "-a", "Rime Shell", "-i", "dialog-warning",
                                    "-u", "critical", "Hyprland config not loaded",
                                    msg + " " + root.hyprConfigFix]
        hyprConfigNotice.running = true
    }

    property var _hyprConfigNoticeProc: Process {
        id: hyprConfigNotice
        running: false
    }
}
