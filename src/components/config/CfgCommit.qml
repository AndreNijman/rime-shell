import QtQuick

// What a page is holding that the machine has not seen, and the acts it can
// perform on it (roadmap P0-023, criteria 2, 3 and 4). A DECLARATION: it draws
// nothing. The one bar that shows it is CfgApplyBar, which the settings host
// (src/nexus/SettingsHost.qml) floats over the bottom of whichever page is
// current, so a page with a draft has its Apply in view however far it is
// scrolled.
//
// A page declares it as a property rather than as a child:
//
//     CfgScroll {
//         commit: CfgCommit {
//             count: Service.stagedCount
//             canApply: true
//             onApplyRequested: Service.apply()
//             onRevertRequested: Service.revert()
//         }
//         …
//     }
//
// ── One bar, because three pages had three ways out ─────────────────────────
//
// Display offered Apply / Save / a button labelled Revert on a row labelled
// Discard. Blueprint offered Save / a button labelled Revert on a row labelled
// Discard, with Apply somewhere further down the page. Keybinds offered a
// button labelled Save that wrote the file AND reloaded the compositor, next to
// one labelled Discard. Three pages, three orders, two words for putting the
// draft back and two meanings for Save.
//
// So the words, the order and the sentence come from the bar, and the page
// supplies only what is true about itself: how many changes it holds, what it
// calls them, which of the acts it can actually perform, and one sentence of
// its own if the general one is not enough.
//
// ── Why the bar floats instead of ending the page ───────────────────────────
//
// It used to be the last child of the page's column, so on a long page the
// button that makes a change real was below the fold, and on the Keybinds page
// it was above a seventy-row list that scrolled away from it. A draft the user
// cannot see the way out of is a draft they leave behind. The page's content
// gets the bar's height as bottom padding (CfgScroll.bottomInset), so the bar
// never covers the last control.
//
// ── Why a failed act does not clear the bar ─────────────────────────────────
//
// `error` renders in place of the hint and the staged count stays exactly as it
// was. That is criterion 4: a refused write must leave the user's intent where
// they can press the button again, and the bar is where they can see that it
// is still there. A page that clears its draft and then reports a failure has
// told the user about work it already destroyed.
QtObject {
    id: root

    // How many changes are held, and what this page calls one of them.
    property int    count: 0
    property string noun:  "change"

    // Which acts this page can honestly perform. A page where persisting and
    // taking effect are the same write offers Apply alone — see
    // settings-semantics.js's APPLY_IS_ALSO_SAVE — and says so through
    // `note` rather than by growing a second button for one act.
    property bool canApply:  false
    property bool canSave:   false
    property bool canRevert: true

    // True while an act is in flight. Every button goes inert; the one that is
    // working says so.
    property bool busy: false

    // Non-empty when the last act was refused. Replaces the hint.
    property string error: ""

    // One page-specific sentence, shown under the hint. For what only this page
    // knows: which files a Save writes, how long a countdown runs.
    property string note: ""

    // The act is destructive and the page has already said why. The button
    // keeps its word — a second word for Save is how the vocabulary stops
    // meaning anything — and takes the danger weight, so the change of meaning
    // is visible without being renamed (criterion 5).
    property bool dangerous: false

    // ── A confirmation that is running ──────────────────────────────────────
    // Seconds left before an applied change puts itself back (the Display
    // page's keep-or-revert). While it is above zero the bar asks the
    // question instead of offering Apply, and `canKeep` adds the button that
    // answers it. What happens on no answer is the page's own sentence,
    // `countdownNote`; the bar adds nothing it cannot know.
    property int    countdown: 0
    property string countdownTitle: ""
    property string countdownNote: ""
    property bool   canKeep: false

    // False while the page itself needs the keys a shortcut would take — the
    // Keybinds page capturing a combination, where Ctrl+S may be the very
    // combination being bound.
    property bool shortcutsEnabled: true

    signal applyRequested()
    signal saveRequested()
    signal revertRequested()
    signal keepRequested()

    readonly property bool held: root.count > 0
    // What the bar shows for: a draft, or a confirmation still running.
    readonly property bool shown: root.held || root.countdown > 0
}
