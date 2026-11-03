import QtQuick
import "../../"
import "settings-semantics.js" as Semantics

// ─────────────────────────────────────────────────────────────────────────────
// CfgApplyBar — the bar a settings page's draft is applied from. ONE of them,
// hosted by src/nexus/SettingsHost.qml over the bottom of the page area and
// pointed at the current page's CfgCommit. Pages never draw it themselves;
// they declare what they hold (CfgCommit) and the host shows it.
//
// It floats rather than ending the page's column: a long page put Apply below
// the fold, and the Keybinds page put it above a seventy-row list that
// scrolled away from it. It stays in view whatever the scroll position, and
// the host gives the page `reserve` px of bottom padding (CfgScroll's
// bottomInset) while it shows, so the bar never sits on the last control.
//
// It comes up from under the page's bottom edge on the Shell's surface springs
// (surfaceOpen / surfaceClose) and fades with them; under Reduce Motion the
// springs' response is 0 and it simply appears and goes. While it leaves it
// keeps the words it had, so a bar sliding out after a successful Apply does
// not read "Nothing staged" on its way down.
//
// Keys, wherever focus is in the window: Ctrl+Enter does the primary act (Apply,
// or Save on a page that has no Apply, or Keep during a confirmation), Ctrl+S
// saves (Apply on a page where Apply is also the save). Escape is the window's,
// as it always was: the drafts live in their services, not in the window, so
// closing Settings throws nothing away and the bar is back when it reopens.
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root

    // The host's per-output sizes when it passes them; this output's otherwise.
    property ThemeSet theme: ThemeSet { scale: Theme.factorForSize(Screen.width, Screen.height) }

    // The current page's declaration. Null on a page that stages nothing.
    property CfgCommit model: null

    // False when the window is not on screen: a shortcut in a hidden window
    // must not act on a draft nobody is looking at.
    property bool keysEnabled: true

    // From the bar's bottom edge to the bottom of the area it floats in.
    property real gap: theme.px(12)

    readonly property bool shown: root.model !== null && root.model.shown

    // How much of the area the bar covers, measured from the area's bottom —
    // the padding a page needs so its last control can scroll clear of it.
    readonly property real reserve: card.height + root.gap + theme.px(8)

    // The drawn surface, for whoever needs its rectangle (the suites).
    readonly property Item surface: card

    // 0 = tucked under the page's bottom edge, 1 = at rest.
    readonly property real progress: slide.value
    readonly property bool moving: slide.running

    SpringFollower {
        id: slide
        role: root.shown ? "surfaceOpen" : "surfaceClose"
        target: root.shown ? 1 : 0
    }

    visible: root.shown || slide.value > 0.001
    implicitHeight: root.reserve

    LayoutMirroring.enabled: Qt.application.layoutDirection === Qt.RightToLeft
    LayoutMirroring.childrenInherit: true

    // ── What the bar says, frozen while it leaves ────────────────────────────
    readonly property var _live: {
        const m = root.model
        if (!m) return null
        const confirming = m.countdown > 0
        return {
            confirming: confirming,
            line: confirming ? (m.countdownTitle !== "" ? m.countdownTitle : "Waiting for you")
                             : Semantics.stagedLine(m.count, m.noun),
            error: m.error,
            hint: confirming ? m.countdownNote : Semantics.stagedHint(m.canApply, m.canSave),
            note: confirming ? "" : m.note,
            canApply: !confirming && m.canApply,
            canSave: !confirming && m.canSave,
            canRevert: !confirming && m.canRevert,
            canKeep: confirming && m.canKeep,
            busy: m.busy,
            dangerous: m.dangerous
        }
    }
    property var _s: ({ confirming: false, line: "", error: "", hint: "", note: "",
                        canApply: false, canSave: false, canRevert: false,
                        canKeep: false, busy: false, dangerous: false })
    Binding {
        target: root
        property: "_s"
        value: root._live
        when: root.shown && root._live !== null
        restoreMode: Binding.RestoreNone
    }

    // ── The acts, for the buttons and the keys ───────────────────────────────
    // Each one checks the live declaration rather than the frozen words: a bar
    // on its way out acts on nothing.
    function _can(what) {
        const m = root.model
        if (!m || !m.shown || m.busy) return false
        const confirming = m.countdown > 0
        if (what === "keep") return confirming && m.canKeep
        if (confirming) return false
        if (what === "apply")  return m.canApply
        if (what === "save")   return m.canSave
        if (what === "revert") return m.canRevert
        return false
    }
    function apply()  { if (root._can("apply"))  root.model.applyRequested() }
    function save()   { if (root._can("save"))   root.model.saveRequested() }
    function revert() { if (root._can("revert")) root.model.revertRequested() }
    function keep()   { if (root._can("keep"))   root.model.keepRequested() }

    // Ctrl+Enter: the act the bar is for.
    function primary() {
        if (root._can("keep")) root.keep()
        else if (root._can("apply")) root.apply()
        else if (root._can("save")) root.save()
    }
    // Ctrl+S: save, where saving is its own act; otherwise the act that saves.
    function saveKey() {
        if (root._can("save")) root.save()
        else if (root._can("apply")) root.apply()
    }

    readonly property bool _keys: root.keysEnabled && root.shown
                                  && root.model.shortcutsEnabled && !root.model.busy
    Shortcut {
        sequences: ["Ctrl+Return", "Ctrl+Enter"]
        context: Qt.WindowShortcut
        enabled: root._keys
        onActivated: root.primary()
    }
    Shortcut {
        sequences: ["Ctrl+S"]
        context: Qt.WindowShortcut
        enabled: root._keys
        onActivated: root.saveKey()
    }

    // ── The surface ──────────────────────────────────────────────────────────
    readonly property color _tone: root._s.error !== "" ? Theme.danger : Theme.warning

    Rectangle {
        id: card
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.bottomMargin: root.gap
        height: Math.max(theme.px(52), lines.implicitHeight + theme.px(20),
                         buttons.implicitHeight + theme.px(20))
        radius: theme.radiusL
        color: Theme.surfaceRaised
        border.color: Theme.outlineSoft
        border.width: 1
        opacity: Math.min(1, root.progress * 1.5)
        transform: Translate { y: (1 - root.progress) * (card.height + root.gap + theme.px(8)) }

        Accessible.role: Accessible.ToolBar
        Accessible.name: root._s.line
        Accessible.description: root._s.error !== "" ? root._s.error : root._s.hint
        Accessible.ignored: !root.shown

        // The staged tone, over the surface: the same warning (or, after a
        // refusal, danger) wash the old in-page bar had, so a draft still reads
        // as a draft and a refusal as a refusal.
        Rectangle {
            anchors.fill: parent
            radius: parent.radius
            color: Qt.rgba(root._tone.r, root._tone.g, root._tone.b, 0.08)
            Behavior on color { MotionColor { role: "state" } }
        }

        Column {
            id: lines
            anchors {
                left: parent.left
                right: buttons.left
                verticalCenter: parent.verticalCenter
                leftMargin: theme.px(14)
                rightMargin: theme.px(12)
            }
            spacing: theme.px(2)

            Text {
                width: parent.width
                text: root._s.line
                font.pixelSize: theme.fs(11)
                font.weight: Font.Medium
                color: root._tone
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                visible: text !== ""
                text: root._s.error !== "" ? root._s.error : root._s.hint
                font.pixelSize: theme.fs(10)
                color: root._s.error !== "" ? Theme.danger : Theme.textSecondary
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                visible: root._s.note !== "" && root._s.error === ""
                text: root._s.note
                font.pixelSize: theme.fs(10)
                color: Theme.textSecondary
                wrapMode: Text.WordWrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
        }

        // Revert at the far end from Apply: the rightmost button is the one a
        // hand reaches for without looking, so it is the one that does what the
        // user came here to do, and throwing the draft away is furthest from it.
        Row {
            id: buttons
            anchors {
                right: parent.right
                verticalCenter: parent.verticalCenter
                rightMargin: theme.px(10)
            }
            spacing: theme.px(6)

            CfgButton {
                id: revertBtn
                visible: root._s.canRevert
                label:   Semantics.verbLabel("revert")
                enabled: !root._s.busy && root.shown
                onClicked: root.revert()
            }
            CfgButton {
                id: saveBtn
                visible: root._s.canSave
                variant: root._s.dangerous ? "danger" : "default"
                // Only one button says it is working, and it is the one that
                // is: where a page offers both, `busy` belongs to Apply.
                label:   (root._s.busy && !root._s.canApply) ? "Saving…" : Semantics.verbLabel("save")
                enabled: !root._s.busy && root.shown
                onClicked: root.save()
            }
            CfgButton {
                id: applyBtn
                visible: root._s.canApply
                variant: "accent"
                label:   root._s.busy ? "Applying…" : Semantics.verbLabel("apply")
                enabled: !root._s.busy && root.shown
                onClicked: root.apply()
            }
            CfgButton {
                id: keepBtn
                visible: root._s.canKeep
                variant: "accent"
                label:   "Keep it"
                enabled: !root._s.busy && root.shown
                onClicked: root.keep()
            }
        }
    }
}
