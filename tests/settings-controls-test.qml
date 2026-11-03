import QtQuick
import QtTest
import "components/config"
import "components/config/settings-semantics.js" as Semantics

// ─────────────────────────────────────────────────────────────────────────────
//  settings-controls-test.qml — the shared settings controls, driven with real
//  input events (roadmap P0-024, criteria 1 and 2).
//
//  Run via tests/run-settings-controls-test.sh, which stages the real
//  src/components/config next to a Theme stub and hands this file to
//  qmltestrunner on the offscreen platform. Nothing here is a
//  reimplementation: every control under test is the shipped source.
//
//  ── Why this layer exists separately from the page suite ────────────────────
//
//  tests/run-settings-pages-test.sh builds the ten real pages under quickshell
//  and asks them what they are. It cannot press anything: quickshell offers no
//  way to post an input event. qmltestrunner does — QMouseEvent and QKeyEvent
//  through QQuickWindow's delivery agent, hit-tested by position, which is the
//  path a compositor's input takes once libinput has decoded it — but it cannot
//  load a page, because every page reaches a singleton that needs Quickshell.
//
//  So: pages there, controls here, geometry in nav-geometry-test.qml. Three
//  entry points because there are three layers, and the alternative is a suite
//  that skips whichever half of the question is inconvenient.
//
//  ── What it asserts ─────────────────────────────────────────────────────────
//
//  The half of P0-023 that is about pressing things:
//
//    * the apply bar (CfgApplyBar, showing a page's CfgCommit) is not there
//      when there is nothing staged
//    * each of its buttons emits its own act and no other
//    * a bar that is busy emits nothing at all, so a second Apply cannot land
//      on top of the first
//    * an error replaces the hint and does NOT touch the count — the user's
//      intent is still where they left it (criterion 4)
//    * a page that cannot Save has no Save button, rather than a disabled one
//    * the buttons carry the vocabulary's words, read off the live objects
//    * the lifecycle line renders the vocabulary's sentence, and renders
//      nothing at all for a state the vocabulary does not define
//    * a row that defers grows to fit the sentence saying so
//    * Ctrl+Enter does the bar's primary act and Ctrl+S saves, and neither
//      acts while the bar is busy or the page has the keys (a capture)
//    * a running confirmation asks its question with Keep and offers no Apply
//    * its buttons take Tab focus and say their names
//    * and the ordinary controls apply the input they are given: a click
//      toggles a switch, a click selects a segment, Enter accepts a field
//
//  The fixture is the root item and TestCase is a child of it, not the other
//  way round: TestCase sets `visible: false` on itself, so a fixture parented
//  to it is invisible, fails hit-testing, and receives no mouse event at all —
//  every "nothing happened" assertion would then pass for the wrong reason.
//  test_000_fixture exists to catch exactly that, the way the wheel suite's
//  does.
// ─────────────────────────────────────────────────────────────────────────────

Item {
    id: fixture
    width:  520
    height: 520

    property int applies:  0
    property int saves:    0
    property int reverts:  0
    property int keeps:    0

    property int toggles:  0
    property var lastToggle: null
    property int selects:  0
    property var lastSelect: null
    property int accepts:  0
    property string lastAccept: ""

    function resetCounts() {
        fixture.applies = 0
        fixture.saves   = 0
        fixture.reverts = 0
        fixture.keeps   = 0
        fixture.toggles = 0
        fixture.selects = 0
        fixture.accepts = 0
    }

    // ── The bar under test ───────────────────────────────────────────────────
    // A page declares its draft (CfgCommit); the settings host shows it in its
    // one CfgApplyBar. Here the fixture is the host.
    CfgApplyBar {
        id: bar
        y: 0
        width: fixture.width
        height: implicitHeight

        model: CfgCommit {
            id: barModel
            count: 2
            noun:  "shortcut"
            canApply: true
            canSave:  true
            canKeep:  true

            onApplyRequested:  fixture.applies++
            onSaveRequested:   fixture.saves++
            onRevertRequested: fixture.reverts++
            onKeepRequested:   fixture.keeps++
        }
    }

    // A second bar, for the page shape that has one act. Kept as its own
    // instance rather than reconfiguring the first between tests, so a test
    // that forgets to put a property back cannot poison the next one. Its keys
    // are off: two bars in one window would make every shortcut ambiguous, and
    // the host never builds two.
    CfgApplyBar {
        id: oneAct
        y: 130
        width: fixture.width
        height: implicitHeight
        keysEnabled: false
        model: CfgCommit {
            count: 1
            noun: "change"
            canApply: true
            canSave:  false
        }
    }

    CfgLifecycle {
        id: live
        y: 240
        width: fixture.width
        lifecycle: "live"
    }

    CfgLifecycle {
        id: nonsense
        y: 290
        width: fixture.width
        lifecycle: "sideways"
    }

    // ── Ordinary controls, for the input-application half ────────────────────
    CfgRow {
        id: plainRow
        y: 340
        width: fixture.width
        label: "Plain"
        description: "A row with no deferred effect"
        CfgSwitch {
            id: sw
            checked: false
            onToggled: function (v) { fixture.toggles++; fixture.lastToggle = v }
        }
    }

    CfgRow {
        id: deferredRow
        y: 380
        width: fixture.width
        label: "Deferred"
        description: "A row that does not take effect where you change it"
        effect: "relogin"
        CfgSegmented {
            id: seg
            options: [{ value: "a", label: "Ay" }, { value: "b", label: "Bee" }]
            value: "a"
            onSelected: function (v) { fixture.selects++; fixture.lastSelect = v }
        }
    }

    CfgTextField {
        id: field
        y: 430
        text: "before"
        onAccepted: function (t) { fixture.accepts++; fixture.lastAccept = t }
    }

    TestCase {
        id: tc
        name: "SettingsControls"
        when: windowShown

        // ── finding a button by the word on it ───────────────────────────────
        // The label is an expression the engine evaluates, so the only honest
        // way to ask which button is which is to read what it is showing.
        function buttonsOf(item, out) {
            for (var i = 0; i < item.children.length; i++) {
                var c = item.children[i]
                if (c.variant !== undefined && c.label !== undefined)
                    out.push(c)
                buttonsOf(c, out)
            }
            return out
        }

        function buttonSaying(item, word) {
            var all = buttonsOf(item, [])
            for (var i = 0; i < all.length; i++)
                if (String(all[i].label) === word && all[i].visible)
                    return all[i]
            return null
        }

        function textsOf(item, out) {
            for (var i = 0; i < item.children.length; i++) {
                var c = item.children[i]
                if (c.text !== undefined && c.wrapMode !== undefined && c.visible
                    && String(c.text) !== "")
                    out.push(String(c.text))
                textsOf(c, out)
            }
            return out
        }

        function clickCentre(item) {
            mouseClick(item, item.width / 2, item.height / 2)
        }

        // ── 000: the fixture is real ─────────────────────────────────────────
        // Without this, every "nothing was emitted" assertion below could be
        // passing because the item was never hit-testable.
        function test_000_fixture() {
            verify(fixture.visible, "the fixture must be visible or no click lands")
            verify(bar.shown, "a bar holding two changes must be showing")
            // It slides up on its spring when it first shows; a click before it
            // lands would hit where it is going, not where it is.
            tryCompare(bar, "progress", 1, 2000)
            verify(bar.visible)
            verify(bar.height > 0, "the bar must have height")
            var apply = buttonSaying(bar, "Apply")
            verify(apply !== null, "the bar must have an Apply button to click")
            fixture.resetCounts()
            clickCentre(apply)
            compare(fixture.applies, 1, "a click on Apply must reach the fixture")
        }

        // ── the words ────────────────────────────────────────────────────────
        function test_010_buttons_carry_the_vocabulary() {
            compare(Semantics.verbLabel("apply"),  "Apply")
            compare(Semantics.verbLabel("save"),   "Save")
            compare(Semantics.verbLabel("revert"), "Revert")
            verify(buttonSaying(bar, Semantics.verbLabel("apply"))  !== null)
            verify(buttonSaying(bar, Semantics.verbLabel("save"))   !== null)
            verify(buttonSaying(bar, Semantics.verbLabel("revert")) !== null)
        }

        // ── one button, one act ──────────────────────────────────────────────
        function test_020_each_button_emits_only_its_own_act() {
            fixture.resetCounts()
            clickCentre(buttonSaying(bar, "Revert"))
            compare(fixture.reverts, 1, "Revert must emit revertRequested")
            compare(fixture.applies, 0, "Revert must not apply")
            compare(fixture.saves,   0, "Revert must not save")

            fixture.resetCounts()
            clickCentre(buttonSaying(bar, "Save"))
            compare(fixture.saves,   1, "Save must emit saveRequested")
            compare(fixture.applies, 0, "Save must not apply")
            compare(fixture.reverts, 0, "Save must not revert")
        }

        // ── nothing staged, nothing shown ────────────────────────────────────
        function test_030_no_bar_without_a_draft() {
            var was = barModel.count
            barModel.count = 0
            verify(!bar.shown, "a bar with nothing staged must not be showing")
            // It slides out on the surface springs, so it is gone a few frames
            // later. Waited for rather than asserted instantly, because "it is
            // still on its way down" and "it never left" read the same at once
            // and only one of them is a defect.
            tryCompare(bar, "visible", false, 2000)
            barModel.count = was
            verify(bar.shown, "and must come back when something is staged")
            tryCompare(bar, "progress", 1, 2000)
            verify(bar.visible)
        }

        // ── a busy bar is inert ──────────────────────────────────────────────
        // The second Apply is the one that lands while the first is still in
        // flight, and on the Display page that is a second transaction on top
        // of a countdown nobody has answered.
        function test_040_a_busy_bar_emits_nothing() {
            waitForRendering(fixture)
            var apply = buttonSaying(bar, "Apply")
            var revert = buttonSaying(bar, "Revert")
            verify(apply !== null && revert !== null,
                   "the bar must still have its buttons: " + textsOf(bar, []).join(" | "))
            fixture.resetCounts()
            barModel.busy = true
            clickCentre(apply)
            clickCentre(revert)
            compare(fixture.applies, 0, "a busy bar must not apply again")
            compare(fixture.reverts, 0, "a busy bar must not revert underneath itself")
            barModel.busy = false
            clickCentre(apply)
            compare(fixture.applies, 1, "and must work again once it is not busy")
        }

        // ── a refusal keeps the intent ───────────────────────────────────────
        function test_050_an_error_replaces_the_hint_and_keeps_the_count() {
            var before = barModel.count
            var hint = Semantics.stagedHint(barModel.canApply, barModel.canSave)
            waitForRendering(fixture)
            verify(textsOf(bar, []).indexOf(hint) >= 0,
                   "the bar must be showing the hint before anything fails; it "
                   + "shows: " + textsOf(bar, []).join(" | "))

            barModel.error = "Could not write /nowhere/keybinds.json (exit 1)."
            var shown = textsOf(bar, [])
            verify(shown.indexOf(barModel.error) >= 0, "the refusal must be on the bar")
            verify(shown.indexOf(hint) < 0, "and must replace the hint, not sit under it")
            compare(barModel.count, before, "a refusal must not change what is staged")
            verify(bar.visible, "and must not make the bar go away")

            var apply = buttonSaying(bar, "Apply")
            verify(apply !== null, "the user must still be able to try again")
            fixture.resetCounts()
            clickCentre(apply)
            compare(fixture.applies, 1, "and pressing it must still ask")

            barModel.error = ""
        }

        // ── one act, one button ──────────────────────────────────────────────
        function test_060_a_page_that_cannot_save_has_no_save_button() {
            verify(buttonSaying(oneAct, "Apply")  !== null, "Apply must be there")
            verify(buttonSaying(oneAct, "Revert") !== null, "Revert must be there")
            compare(buttonSaying(oneAct, "Save"), null,
                    "a page where Apply is also the save must not grow a Save button")
        }

        // ── the keys ─────────────────────────────────────────────────────────
        // Window shortcuts, so they reach the bar wherever focus is: the field
        // at the bottom of the fixture holds it here, the way a page's control
        // would.
        function test_062_ctrl_enter_applies_and_ctrl_s_saves() {
            waitForRendering(fixture)
            fixture.resetCounts()
            field.forceActiveFocus()
            keyClick(Qt.Key_Return, Qt.ControlModifier)
            compare(fixture.applies, 1, "Ctrl+Enter must apply")
            keyClick(Qt.Key_Enter, Qt.ControlModifier)
            compare(fixture.applies, 2, "Ctrl+Enter on the keypad too")
            keyClick(Qt.Key_S, Qt.ControlModifier)
            compare(fixture.saves, 1, "Ctrl+S must save where the page can")
            compare(fixture.reverts, 0, "no key reverts")
        }

        function test_064_keys_do_nothing_while_busy_or_captured() {
            fixture.resetCounts()
            field.forceActiveFocus()
            barModel.busy = true
            keyClick(Qt.Key_Return, Qt.ControlModifier)
            keyClick(Qt.Key_S, Qt.ControlModifier)
            barModel.busy = false
            compare(fixture.applies + fixture.saves, 0, "a busy bar must not act on a key")
            barModel.shortcutsEnabled = false
            keyClick(Qt.Key_Return, Qt.ControlModifier)
            keyClick(Qt.Key_S, Qt.ControlModifier)
            barModel.shortcutsEnabled = true
            compare(fixture.applies + fixture.saves, 0,
                    "a page that has the keys (a capture) must keep them")
            barModel.count = 0
            tryCompare(bar, "visible", false, 2000)
            keyClick(Qt.Key_Return, Qt.ControlModifier)
            compare(fixture.applies, 0, "a bar with nothing to apply must not apply")
            barModel.count = 2
            tryCompare(bar, "progress", 1, 2000)
        }

        // ── a confirmation ───────────────────────────────────────────────────
        function test_066_a_countdown_asks_with_keep_and_offers_no_apply() {
            fixture.resetCounts()
            barModel.countdownTitle = "Keep this layout?"
            barModel.countdownNote = "If you do nothing, it comes back in 5 seconds."
            barModel.countdown = 5
            waitForRendering(fixture)
            var shown = textsOf(bar, [])
            verify(shown.indexOf("Keep this layout?") >= 0, "the bar must ask: " + shown.join(" | "))
            verify(shown.indexOf(barModel.countdownNote) >= 0, "and say what doing nothing does")
            compare(buttonSaying(bar, "Apply"), null, "no Apply on top of an unanswered apply")
            compare(buttonSaying(bar, "Revert"), null, "the draft's Revert is not the answer")
            var keep = buttonSaying(bar, "Keep it")
            verify(keep !== null, "Keep it must be there")
            clickCentre(keep)
            compare(fixture.keeps, 1, "Keep it must answer")
            field.forceActiveFocus()
            keyClick(Qt.Key_Return, Qt.ControlModifier)
            compare(fixture.keeps, 2, "and Ctrl+Enter is Keep while the question is asked")
            compare(fixture.applies, 0, "never Apply")
            barModel.countdown = 0
            waitForRendering(fixture)
            verify(buttonSaying(bar, "Apply") !== null, "the draft's buttons come back after")
        }

        // ── reachable and named ──────────────────────────────────────────────
        function test_068_buttons_take_tab_and_say_their_names() {
            var revert = buttonSaying(bar, "Revert")
            var save = buttonSaying(bar, "Save")
            var apply = buttonSaying(bar, "Apply")
            verify(revert.activeFocusOnTab && save.activeFocusOnTab && apply.activeFocusOnTab,
                   "every button on the bar must be a Tab stop")
            revert.forceActiveFocus()
            keyClick(Qt.Key_Tab)
            verify(save.activeFocus, "Tab from Revert must reach Save")
            keyClick(Qt.Key_Tab)
            verify(apply.activeFocus, "and then Apply")
            compare(apply.Accessible.name, "Apply")
            compare(bar.surface.Accessible.role, Accessible.ToolBar)
            compare(bar.surface.Accessible.name, Semantics.stagedLine(2, "shortcut"),
                    "the bar must be named by what it holds")
            fixture.resetCounts()
            keyClick(Qt.Key_Space)
            compare(fixture.applies, 1, "Space on the focused Apply must apply")
        }

        // ── the lifecycle line ───────────────────────────────────────────────
        function test_070_lifecycle_says_the_vocabularys_sentence() {
            verify(live.visible, "a declared lifecycle must render")
            var shown = textsOf(live, [])
            verify(shown.indexOf(Semantics.stateBlurb("live")) >= 0,
                   "and must render the sentence the vocabulary defines")
            verify(shown.indexOf(Semantics.stateLabel("live")) >= 0,
                   "and name the state, so the reader learns the word")
        }

        function test_075_an_undefined_state_renders_nothing() {
            verify(!nonsense.visible,
                   "a state the vocabulary does not define must render nothing "
                   + "rather than an empty promise")
            compare(nonsense.height, 0)
        }

        function test_080_lifecycle_shows_a_failed_write_instead() {
            live.error = "Could not write settings.json (exit 1)."
            var shown = textsOf(live, [])
            verify(shown.indexOf(live.error) >= 0,
                   "a live page's failed write must be on its lifecycle line")
            verify(shown.indexOf(Semantics.stateBlurb("live")) < 0,
                   "and must replace the promise it is no longer keeping")
            live.error = ""
        }

        // ── the deferred caption ─────────────────────────────────────────────
        function test_090_a_deferred_row_grows_to_fit_its_sentence() {
            verify(deferredRow.height > plainRow.height,
                   "a row carrying an effect note must be taller than one that "
                   + "is not, or the sentence is drawn outside the row")
            verify(textsOf(deferredRow, []).indexOf(Semantics.effectNote("relogin")) >= 0,
                   "and must say the vocabulary's sentence, not its own")
            compare(textsOf(plainRow, []).indexOf(Semantics.effectNote("relogin")), -1,
                    "a row with no effect must say nothing about when it applies")
        }

        // ── input application ────────────────────────────────────────────────
        function test_100_a_click_toggles_a_switch() {
            fixture.resetCounts()
            clickCentre(sw)
            compare(fixture.toggles, 1, "a click must reach the switch")
            compare(fixture.lastToggle, true, "and must report the value it moved to")
        }

        function test_110_a_click_selects_a_segment() {
            fixture.resetCounts()
            var pills = []
            for (var i = 0; i < seg.children.length; i++)
                if (seg.children[i].width > 0 && seg.children[i].height > 0)
                    pills.push(seg.children[i])
            verify(pills.length >= 2, "the segmented control must have laid out its options")
            clickCentre(pills[1])
            compare(fixture.selects, 1, "a click must reach the segmented control")
            compare(fixture.lastSelect, "b", "and must report the option's value, not its label")
        }

        function test_120_enter_accepts_a_field() {
            fixture.resetCounts()
            mouseClick(field, field.width / 2, field.height / 2)
            keyClick(Qt.Key_X)
            keyClick(Qt.Key_Return)
            compare(fixture.accepts, 1, "Enter must accept the field")
            verify(fixture.lastAccept.length > 0, "and hand over what was typed")
        }
    }
}
