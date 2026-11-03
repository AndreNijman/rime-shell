import QtQuick
import Quickshell
import Quickshell.Io
import "./src"
import "./src/nexus"

// ─────────────────────────────────────────────────────────────────────────────
// Rime Settings — the settings app for sessions that run no Rime Shell (GNOME,
// KDE Plasma, COSMIC; rime-os docs/nixos/desktops.md §5, decision D9).
//
// It is the Shell's own settings body (SettingsHost and the PageRegistry pages)
// in an ordinary application window. Nexus cannot be used as it is: it is a
// wlr-layer-shell surface, and GNOME's compositor has no layer-shell. A
// FloatingWindow is an xdg_toplevel, which every desktop shows, lists in its
// window switcher and gives an icon to through the app id.
//
// It lives beside shell.qml because the pages import relatively ("../../../");
// a copy elsewhere would be a second set of pages. It runs as its own
// Quickshell instance, started by bin/rime-settings:
//
//     QS_APP_ID=org.rimeos.Settings quickshell -n -p <shellDir>/settings.qml
//
// QS_APP_ID is the xdg app id, so the window matches org.rimeos.Settings.desktop
// (StartupWMClass) and its icon; -n (--no-duplicate) refuses a second instance,
// and the launcher talks to the running one over IPC instead:
//
//     qs -p <shellDir>/settings.qml ipc call settings open <page>
//
// Shell-only pages (Appearance, Layout, Display, Input, Keybinds, Misc) are not
// listed here: PageRegistry.appMode filters them out of every reader of
// `pages`. They configure the Shell and Hyprland, neither of which runs in
// these sessions. The window is built only once appMode is set, so no
// Shell-only page is ever constructed, even for one frame.
// ─────────────────────────────────────────────────────────────────────────────
ShellRoot {
    id: app

    // The page shown. Set by the navigation, by `open` over IPC, and by the
    // launcher's argument.
    property string page: ""

    Component.onCompleted: {
        PageRegistry.appMode = true
        const want = Quickshell.env("RIME_SETTINGS_PAGE") || ""
        app.page = PageRegistry.has(want) ? want : PageRegistry.firstId
    }

    LazyLoader {
        id: loader
        active: PageRegistry.appMode

        FloatingWindow {
            id: win
            title: "Rime Settings"
            implicitWidth: 1080
            implicitHeight: 720
            minimumSize: Qt.size(760, 520)
            color: Theme.background

            SettingsHost {
                id: host
                anchors.fill: parent
                page: app.page
                live: win.visible
                onPageSelected: id => app.page = id
                onCloseRequested: Qt.quit()
            }

            Shortcut {
                sequences: [StandardKey.Close, "Escape"]
                onActivated: Qt.quit()
            }

            // For the IPC handler below: the page item SettingsHost built.
            function pageItem(id) { return host.pageItem(id) }
        }
    }

    IpcHandler {
        target: "settings"

        // Switch to a page; "" keeps the current one. A Shell-only page is
        // refused by name, as it is not part of this app.
        function open(page: string): string {
            if (page !== "" && !PageRegistry.has(page))
                return "unknown page: " + page + " (try: " + PageRegistry.pages.map(p => p.id).join(", ") + ")"
            if (page !== "")
                app.page = page
            return "settings open at " + app.page
        }

        function current(): string { return app.page }

        function pages(): string { return PageRegistry.pages.map(p => p.id).join(" ") }

        function close(): string { Qt.quit(); return "closing" }

        // Test hook: runs the Power page's own handler, the function its tier
        // control calls, so a test changes a real setting the way a click does.
        function power(tier: string): string {
            app.page = "power"
            const item = loader.item ? loader.item.pageItem("power") : null
            if (!item)
                return "power page not built"
            return item.chooseTier(tier)
        }
    }
}
