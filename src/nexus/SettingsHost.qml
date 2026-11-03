import QtQuick
import "../"
import "../components"
import "../components/controls"
import "../components/config"

// ─────────────────────────────────────────────────────────────────────────────
// SettingsHost — the settings app's body: the navigation, the page header and
// the page stack, one LazyPage per PageRegistry page (UI/UX roadmap v3 Phase
// 19). Nexus is the window and the sheet around it; this is what is inside.
//
// It was inline in Nexus while the Dashboard's Config tab (ShellConfig) was a
// SECOND host of every page — two instances of each page, two sets of staged
// state (KeybindService's two `_pending` maps), and a settings app inside the
// operational Dashboard, which the IA rules say it is not. Phase 19 removed
// that tab; this Item is the one host left, and being an Item rather than a
// window, it is also what the offscreen suites (settings-staged, nav-geometry)
// lay out instead of a stand-in.
//
// The host window binds `page` and `live` and answers the two signals:
//     SettingsHost {
//         page: NexusState.page;  live: <window on screen and live>
//         onPageSelected: id => NexusState.page = id
//         onCloseRequested: NexusState.close()
//     }
//
// It also hosts the ONE apply bar (CfgApplyBar). A page that holds a draft
// declares it as a `commit: CfgCommit { … }`; the bar floats over the bottom
// of the page area while the current page's commit has something to show, and
// the page is given the bar's height as bottom padding. A window that hosts
// this Item — Nexus, or a standalone settings app built from the same pages —
// gets the bar, its keys (Ctrl+Enter, Ctrl+S) and the padding with it.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: host

    // The host window's own sizes (P1-040) — Nexus passes its screen's set.
    property ThemeSet theme: ThemeSet { scale: Theme.factorForSize(Screen.width, Screen.height) }

    property string page: PageRegistry.pages.length > 0 ? PageRegistry.pages[0].id : ""
    // True while a person can see the pages: gates the refcounted telemetry
    // (a page's onScreen), so a poller started here stops when the window goes.
    property bool live: true
    // 0..1, how far the host window has brought its content in (Nexus: the
    // lifecycle's content fade). The navigation and the title arrive first,
    // the page a beat after, so what arrives reads as an order rather than
    // one flash; leaving, the page goes first and is gone by the time the
    // fade is two thirds done. 1 when nothing drives it.
    property real reveal: 1
    function _part(a, b) {
        const t = Math.max(0, Math.min(1, (host.reveal - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // The apply bar, for a window that wants to know whether a draft is
    // showing (and for the suites, which measure it).
    readonly property alias applyBar: applyBar

    signal pageSelected(string id)
    signal closeRequested()

    // Pages move in the direction of the nav order (Phase 7): they bind to
    // `shownPage`, set only after `pageDir` is.
    property int    pageDir: 1
    property int    _pageIdx: 0
    property string shownPage: host.page
    function _indexOf(id) {
        const list = PageRegistry.pages
        for (let i = 0; i < list.length; i++) if (list[i].id === id) return i
        return 0
    }
    onPageChanged: {
        const i = host._indexOf(host.page)
        host.pageDir = i >= host._pageIdx ? 1 : -1
        host._pageIdx = i
        host.shownPage = host.page
    }
    Component.onCompleted: host._pageIdx = host._indexOf(host.page)

    // The page item built for `id`, or null when it has not been visited yet
    // (pages are built on first visit). Rime Settings' IPC test hook calls a
    // page's own handler through this.
    function pageItem(id) {
        for (let i = 0; i < pagesRep.count; i++) {
            const l = pagesRep.itemAt(i)
            if (l && l.modelData && l.modelData.id === id)
                return l.item
        }
        return null
    }

    // ── Left: navigation ────────────────────────────────────────────
    NavPane {
        id: nav
        anchors {
            left: parent.left
            top: parent.top
            bottom: parent.bottom
        }
        currentPage: host.page
        opacity: host._part(0.05, 0.65)
        onPageSelected: function (id) { host.pageSelected(id) }
    }

    Rectangle {
        anchors {
            left: nav.right
            top: parent.top
            bottom: parent.bottom
            topMargin: theme.px(10)
            bottomMargin: theme.px(10)
        }
        width: 1
        color: Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07)
        opacity: host._part(0.05, 0.65)   // with the navigation it divides
    }

    // ── Right: header + page ────────────────────────────────────────
    Item {
        id: pane

        anchors {
            left: nav.right
            right: parent.right
            top: parent.top
            bottom: parent.bottom
            leftMargin: theme.px(1)
        }

        readonly property var current: PageRegistry.pageFor(host.page)

        Item {
            id: header
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
            }
            height: theme.px(58)
            opacity: host._part(0.05, 0.65)

            Text {
                id: title
                anchors {
                    left: parent.left
                    leftMargin: theme.px(18)
                    top: parent.top
                    topMargin: theme.px(12)
                }
                text: pane.current ? pane.current.title : ""
                color: Theme.textPrimary
                font.pixelSize: theme.typePageTitle
                font.weight: Font.DemiBold
            }

            Text {
                anchors {
                    left: parent.left
                    leftMargin: theme.px(18)
                    top: title.bottom
                    topMargin: theme.px(2)
                    right: closeBtn.left
                    rightMargin: theme.px(8)
                }
                text: pane.current ? pane.current.subtitle : ""
                color: Theme.textSecondary
                font.pixelSize: theme.typeCaption
                elide: Text.ElideRight
            }

            RimeIconButton {
                id: closeBtn
                anchors {
                    right: parent.right
                    rightMargin: theme.px(12)
                    top: parent.top
                    topMargin: theme.px(12)
                }
                glyph: "󰅖"
                label: "Close settings"
                radius: height / 2
                onActivated: host.closeRequested()
            }
        }

        // One LazyPage per registered page: built on first visit, kept
        // afterwards so scroll position and sub-page state survive
        // switching away and back. The stagger is on this wrapper: each
        // LazyPage owns its own opacity for page switches.
        Item {
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                bottom: parent.bottom
            }
            opacity: host._part(0.35, 1)

            Repeater {
                id: pagesRep
                model: PageRegistry.pages

                delegate: LazyPage {
                    required property var modelData

                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        bottom: parent.bottom
                        topMargin: header.height
                        leftMargin: theme.px(8)
                        rightMargin: theme.px(8)
                        bottomMargin: theme.px(8)
                    }

                    shown: host.shownPage === modelData.id
                    direction: host.pageDir
                    sourceComponent: modelData.component

                    // Pages that consume refcounted telemetry need to know
                    // whether a user can actually see them; without this a
                    // poller started here would run until logout.
                    onLoaded: {
                        const p = item
                        if (!p) return
                        if (modelData.needsScreen)
                            p.onScreen = Qt.binding(() => host.live
                                                          && host.page === modelData.id
                                                          && !LockState.locked)
                        // Room under the last control while the apply bar
                        // shows for this page's draft, so the bar never sits
                        // on it.
                        if (p.bottomInset !== undefined)
                            p.bottomInset = Qt.binding(() => p.commit && p.commit.shown
                                                             ? applyBar.reserve : 0)
                    }
                }
            }
        }

        // ── The apply bar ───────────────────────────────────────────────
        // One, for whichever page is current, over the bottom of the same
        // area the pages fill. Clipped to that area, so it comes up from the
        // page's own bottom edge rather than from the window's frame.
        readonly property Item currentPage: {
            pagesRep.count   // re-read once the Repeater has built its pages
            const lp = pagesRep.itemAt(host._indexOf(host.page))
            return lp && lp.item ? lp.item : null
        }

        Item {
            anchors {
                left: parent.left
                right: parent.right
                top: parent.top
                bottom: parent.bottom
                topMargin: header.height
                leftMargin: theme.px(8)
                rightMargin: theme.px(8)
                bottomMargin: theme.px(8)
            }
            clip: true
            opacity: host._part(0.35, 1)

            CfgApplyBar {
                id: applyBar
                anchors {
                    left: parent.left
                    right: parent.right
                    bottom: parent.bottom
                    leftMargin: theme.px(8)
                    rightMargin: theme.px(8)
                }
                height: implicitHeight
                theme: host.theme
                model: pane.currentPage && pane.currentPage.commit !== undefined
                       ? pane.currentPage.commit : null
                keysEnabled: host.live
            }
        }
    }
}
