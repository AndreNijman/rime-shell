pragma Singleton
import QtQuick
import "../services/config_tab"
import "../services/config_tab/pages"

// ─────────────────────────────────────────────────────────────────────────────
// PageRegistry — the single definition of the shell's settings pages.
//
// Settings are presented in one place: Nexus, through SettingsHost (UI/UX
// Phase 19). There used to be two — the dashboard's Config tab as well — and
// before this registry the dashboard tab hardcoded its own tab list AND its own
// five Loaders, so adding a page meant editing two lists. A page is declared
// once — id, title, icon, and the Component that renders it — and the host and
// the suites (settings-staged, nav-geometry) all read it from here.
//
// `group` is the navigation's section (UI/UX Phase 19b): the pages are listed
// in group order, and NavPane draws a section label above the first page of
// each group. Seventeen pages in one flat column read as a pile; five groups — what
// it looks like, how you drive it, who may reach what, the devices paired to it,
// and the machine itself — read as a map.
//
// `needsScreen` marks pages that consume refcounted telemetry services and must
// therefore be told whether they are genuinely on screen (see ServiceRef). Data
// & Storage and Misc do; getting it wrong on a new page means a poller that
// never stops, so it is declared rather than inferred.
//
// `shellOnly` marks pages that configure Rime Shell or Hyprland themselves (the
// bar, the layout, monitors through Hyprland, keybinds, the compositor). They
// are listed in the Shell's Nexus and left out of Rime Settings, the standalone
// app (settings.qml) that GNOME, KDE Plasma and COSMIC users open: there is no
// Shell and no Hyprland to configure there (rime-os docs/nixos/desktops.md §5).
// settings.qml sets `appMode`, and `pages` is then the list without them; every
// reader (SettingsHost, NavPane, IpcManager, search) reads `pages`, so a
// Shell-only page cannot be reached in the app by any path.
// ─────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    // True in Rime Settings (settings.qml), false in the Shell.
    property bool appMode: false

    // `appOnly` is the other direction: About, which the Shell keeps inside
    // Misc (with the compositor and Shell rows), is a page of its own in the app.
    readonly property var pages: root.allPages.filter(p => root.appMode ? !p.shellOnly : !p.appOnly)

    readonly property var allPages: [
        {
            "id": "appearance",
            "shellOnly": true,
            "group": "Look & feel",
            "title": "Appearance",
            "subtitle": "Palette, wallpaper, lock screen, shape",
            "icon": "󰏘",
            "needsScreen": false,
            "component": appearanceComp
        },
        {
            "id": "layout",
            "shellOnly": true,
            "group": "Look & feel",
            "title": "Layout & Behavior",
            "subtitle": "Scaling, bar, motion, spacing, dimensions",
            "icon": "󰕰",
            "needsScreen": false,
            "component": layoutComp
        },
        {
            "id": "display",
            "shellOnly": true,
            "group": "Look & feel",
            "title": "Display",
            "subtitle": "Resolution, refresh, scale, rotation, arrangement",
            "icon": "󰍹",
            "needsScreen": false,
            "component": displayComp
        },
        {
            "id": "input",
            "shellOnly": true,
            "group": "Input",
            "title": "Input",
            "subtitle": "Touchpad, mouse, keyboard repeat",
            "icon": "󰟸",
            "needsScreen": false,
            "component": inputComp
        },
        {
            "id": "keybinds",
            "shellOnly": true,
            "group": "Input",
            "title": "Keybinds",
            "subtitle": "Shortcuts for every popup",
            "icon": "󰌌",
            "needsScreen": false,
            "component": keybindsComp
        },
        {
            "id": "privacy",
            "shellOnly": false,
            "group": "Privacy & agents",
            "title": "Privacy & Permissions",
            "subtitle": "Camera, microphone, capture, files, and who enforces each",
            "icon": "󰒃",
            // PermissionsService runs one `rime permissions list --json` per
            // sweep, and that command runs a `flatpak info` per installed
            // application. Getting this wrong means a burst of Flatpak
            // processes every 30 seconds until logout.
            "needsScreen": true,
            "component": privacyComp
        },
        {
            "id": "firewall",
            "shellOnly": false,
            "group": "Privacy & agents",
            "title": "Firewall",
            "subtitle": "What is reachable from the network, and what you opened",
            "icon": "󰕥",
            // FirewallService runs three reads on a slow sweep while this page
            // is looked at, and nothing at all when it is not.
            "needsScreen": true,
            "component": firewallComp
        },
        {
            "id": "agents",
            "shellOnly": false,
            "group": "Privacy & agents",
            "title": "Agents",
            "subtitle": "The sandbox new agent sessions start in",
            "icon": "󰚩",
            // AgentService forks `rime agent list` on a timer and is
            // refcounted on it. The page lists what is running so it can show
            // each session's own mode, so it holds a ref and has to be told
            // whether anyone is looking.
            "needsScreen": true,
            "component": agentsComp
        },
        {
            "id": "remote-pair",
            "shellOnly": false,
            "group": "Devices",
            "title": "Pair a device",
            "subtitle": "Show a code for Rime Remote on your phone to scan",
            "icon": "",
            // Stronger than elsewhere: `rime remote pair` MINTS a one-time
            // token, so this page must not be built for somebody who never
            // opened it.
            "needsScreen": true,
            "component": remotePairComp
        },
        {
            "id": "remote-devices",
            "shellOnly": false,
            "group": "Devices",
            "title": "Paired devices",
            "subtitle": "Every phone that can reach this machine, and how to revoke one",
            "icon": "",
            "needsScreen": true,
            "component": remoteDevicesComp
        },
        {
            "id": "data",
            "shellOnly": false,
            "group": "System",
            "title": "Data & Storage",
            "subtitle": "Disks, memory, clipboard, notifications",
            "icon": "󰋊",
            "needsScreen": true,
            "component": dataComp
        },
        {
            "id": "lid",
            "shellOnly": false,
            "group": "System",
            "title": "Closing the Lid",
            "subtitle": "What a shut lid does while work is running, and what it cost last time",
            "icon": "󰶐",
            // LidService runs `rime lid status --json` and `rime lid report
            // --json` one after the other on a sweep timer while this page is
            // looked at, and nothing at all when it is not. Getting this wrong
            // means two `rime` processes every 15 seconds until logout.
            "needsScreen": true,
            "component": lidComp
        },
        {
            "id": "gaming",
            "shellOnly": false,
            "group": "System",
            "title": "Gaming",
            "subtitle": "Gaming Mode, what it needs, and the performance policy",
            "icon": "󰊴",
            // GamingService runs `rime gaming` and `rime mode status` when the
            // page is opened and when the user presses Refresh, and nothing on
            // a timer — `rime mode set --auto` is one-shot by design, so a
            // poller here would be the shell inventing a daemon the OS declined
            // to ship. Nothing to refcount, so nothing to tell about the screen.
            "needsScreen": false,
            "component": gamingComp
        },
        {
            "id": "power",
            "shellOnly": false,
            "group": "System",
            "title": "Power",
            "subtitle": "Power tier, switching with the charger, battery charge limit",
            "icon": "󰂄",
            // Reads rimed's AutoSwitch and battery thresholds when it arrives
            // on screen, and holds PowerProfileService (whose rimed fallback
            // polls) only while it is looked at.
            "needsScreen": true,
            "component": powerComp
        },
        {
            "id": "desktops",
            "shellOnly": false,
            "group": "System",
            "title": "Desktops",
            "subtitle": "GNOME, KDE Plasma and COSMIC beside Rime's own sessions",
            "icon": "󰍺",
            "needsScreen": false,
            "component": desktopsComp
        },
        {
            "id": "updates",
            "shellOnly": false,
            "group": "System",
            "title": "Updates",
            "subtitle": "Whether a newer Rime is out, and what the last update changed live",
            "icon": "󰚰",
            // Re-reads /run/rime-live/status.json and /run/rime-update/state on
            // a slow timer while the page is looked at, and nothing at all when
            // it is not.
            "needsScreen": true,
            "component": updatesComp
        },
        {
            "id": "recovery",
            "shellOnly": false,
            "group": "System",
            "title": "Recovery",
            "subtitle": "Health, rollback, repair, ways back in",
            "icon": "󰑙",
            // RecoveryService runs `rime recover status --json` and
            // `rime doctor --json` on a sweep timer while this page is looked
            // at, and nothing at all when it is not. Getting this wrong means
            // two `rime` processes every 20 seconds until logout.
            "needsScreen": true,
            "component": recoveryComp
        },
        {
            "id": "blueprint",
            "shellOnly": false,
            "group": "System",
            "title": "Blueprint",
            "subtitle": "What this machine should be, and what differs",
            "icon": "󰦑",
            "needsScreen": false,
            "component": blueprintComp
        },
        {
            "id": "misc",
            "shellOnly": true,
            "group": "System",
            "title": "Misc",
            "subtitle": "Compositor, release notes, about",
            "icon": "󰒓",
            // SystemStats lives in the About area and shells out to collect
            // distro/kernel/uptime/packages, so this page has to be told
            // whether anyone is looking.
            "needsScreen": true,
            "component": miscComp
        },
        {
            "id": "about",
            "shellOnly": false,
            "appOnly": true,
            "group": "System",
            "title": "About",
            "subtitle": "Rime OS, this machine, and where the code lives",
            "icon": "󰋽",
            // SystemStats again: one subprocess, only while looked at.
            "needsScreen": true,
            "component": aboutComp
        }
    ]

    function pageFor(id) {
        for (const p of root.pages)
            if (p.id === id)
                return p
        return null
    }

    function has(id) {
        return root.pageFor(id) !== null
    }

    readonly property string firstId: root.pages.length > 0 ? root.pages[0].id : ""

    // The components live here rather than inline in the list so the list stays
    // readable and each page is named once.
    readonly property Component appearanceComp: Component {
        AppearancePage {}
    }
    readonly property Component layoutComp: Component {
        LayoutPage {}
    }
    readonly property Component dataComp: Component {
        DataPage {}
    }
    readonly property Component inputComp: Component {
        InputPage {}
    }
    readonly property Component displayComp: Component {
        DisplayPage {}
    }
    readonly property Component blueprintComp: Component {
        BlueprintPage {}
    }
    readonly property Component gamingComp: Component {
        GamingPage {}
    }
    readonly property Component updatesComp: Component {
        UpdatesPage {}
    }
    readonly property Component recoveryComp: Component {
        RecoveryPage {}
    }
    readonly property Component privacyComp: Component {
        PrivacyPage {}
    }
    readonly property Component agentsComp: Component {
        AgentsPage {}
    }
    readonly property Component lidComp: Component {
        LidPage {}
    }
    readonly property Component firewallComp: Component {
        FirewallPage {}
    }
    readonly property Component remotePairComp: Component {
        RemotePairPage {}
    }
    readonly property Component remoteDevicesComp: Component {
        RemoteDevicesPage {}
    }
    readonly property Component keybindsComp: Component {
        KeybindsPage {}
    }
    readonly property Component powerComp: Component {
        PowerPage {}
    }
    readonly property Component desktopsComp: Component {
        DesktopsPage {}
    }
    readonly property Component miscComp: Component {
        MiscPage {}
    }
    readonly property Component aboutComp: Component {
        AboutPage {}
    }
}
