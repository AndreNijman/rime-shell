import QtQuick
import Quickshell
import "title.js" as Title
import "clients.js" as Clients
import Quickshell.Io
import Quickshell.Hyprland
import "../../"
import "boxes.js" as Boxes
import "../kblayout.js" as KB
import "hyprMotion.js" as HyprMotion
import "../../shapes/fluid/geometry.js" as Geo

// ─── HyprlandBackend ──────────────────────────────────────────────────────────
// CompositorService's Hyprland adapter. Loaded by URL and only on Hyprland, so
// `import Quickshell.Hyprland` above never resolves anywhere else — which is the
// whole reason the consumers no longer need `target: isHyprland ? Hyprland : null`
// scattered through them. Resolving that singleton is what constructs it, and
// constructing it off Hyprland logs.
//
// ── One dialect: Lua ─────────────────────────────────────────────────────────
// Hyprland 0.55+ reads hyprland.lua and nothing else: the old .conf parser is
// gone, the old keyword request is refused ("keyword can't work with
// non-legacy parsers. Use eval."), and a dispatch takes one Lua expression. So every
// write in this file is `hyprctl eval` and every dispatch is an `hl.dsp.*`
// expression; there is no second path to drift. A home that still has only a
// hyprland.conf is not run "in compatibility": checkHyprConfig() below
// says so loudly and names rime-hypr-migrate.
//
// ── What costs something ─────────────────────────────────────────────────────
// Workspaces and the focused monitor are pushed by the Quickshell.Hyprland
// singleton and cost nothing. Window enumeration and the focused window title
// need `hyprctl`, so both are refcounted: CompositorService pushes windowsWanted
// and titleWanted in, and nothing spawns while nobody is looking.
// ──────────────────────────────────────────────────────────────────────────────

QtObject {
    id: root

    // Frame-pacing logs, as theme/Motion.qml reads them; APEX_PACING_LOG is the
    // variable's name before the rename, which a developer's own unit may set.
    readonly property bool _pacingLog: (Quickshell.env("RIME_PACING_LOG") || Quickshell.env("APEX_PACING_LOG")) === "1"  // rime-rename: keep (the variable's pre-rename name)

    readonly property bool ready: true

    readonly property string displayName: "Hyprland"

    // `hyprctl version` prints "Hyprland 0.56.2 built from branch …"; the
    // facade takes the first x.y.z off stdout. Nothing else in this file needs
    // to know how it is spelled, and no consumer does.
    readonly property var versionCommand: ["hyprctl", "version"]

    signal focusMoved()

    // ── What counts as "the user is now looking somewhere else" ───────────────
    // The raw events that mean focus actually moved. `activewindow` is
    // deliberately absent: Hyprland fires it for title changes too, so a
    // browser switching tabs would count as the user looking elsewhere.
    //
    // `focusedmon` IS included, and that is a decision rather than an
    // oversight, because it has a visible cost. Hyprland's `follow_mouse` is on
    // by default, so on a multi-monitor session merely moving the cursor across
    // a monitor boundary now fires this and PopupDismiss closes every open
    // popup. It did not before. Single-monitor sessions — this shell's usual
    // case — are unaffected, because the event never fires there.
    //
    // It is kept because CompositorService defines focusMoved as "a different
    // workspace, a different window, a different monitor", and the other two
    // backends already honour the monitor half: niri fires on
    // focusedWorkspaceId (which changes when monitor focus does, since each
    // output shows its own workspace) and labwc on activeToplevelChanged.
    // Dropping it here would make Hyprland the one backend that silently
    // narrows the contract it is implementing, and `Popups.closeAll()` is
    // global — the popup sits on the monitor the user just left.
    //
    // `activemonitor` used to be in this list and was never an event. Hyprland's
    // IPC event names are compiled into the binary; `focusedmon` and
    // `focusedmonv2` are there, and the only occurrence of "activemonitor"
    // anywhere in it is `workspace.activemonitor`, a Lua hook name — checked
    // with `strings /usr/bin/Hyprland`. So it matched nothing and the monitor
    // half of the contract was in fact unimplemented until `focusedmon` landed.
    readonly property var _FOCUS_EVENTS: [
        "workspace", "activespecial", "openwindow", "focusedmon"
    ]

    readonly property var capabilities: ({
        workspaces:           true,
        workspaceSwitch:      true,
        specialWorkspace:     true,
        windows:              true,
        windowGeometry:       true,
        outputGeometry:       true,
        windowFocus:          true,
        windowMove:           true,
        windowClose:          true,
        // Hyprland has no built-in overview dispatch — hyprexpo is a plugin and
        // Rime does not ship it. Declared false rather than dispatching into a
        // plugin that is probably not loaded.
        windowPreview:        true,
        overview:             false,
        accentBorder:         true,
        gaps:                 true,
        tilingLayout:         true,
        keyboardInterception: true,
        screenShader:         true,
        nightLight:           true,
        keyboardLayouts:     true,
        motion:               true
    })

    property bool windowsWanted: false
    property bool titleWanted:   false
    property bool layoutWanted:  false

    // ── What the refcounts actually buy ───────────────────────────────────────
    // True because enumerating windows and reading the focused title each cost
    // a `hyprctl` here: nothing runs while nobody holds a ref, and the list and
    // title fall back to empty/"Desktop" the moment the last ref is handed
    // back. On the wlroots backends the same data arrives over a protocol the
    // compositor pushes, so it is live whether anyone asked or not.
    //
    // Declared rather than left as prose because the two are behaviourally
    // different and the facade suite has to know which contract to assert. See
    // the note in check-compositor-backends.sh on why this is not a capability.
    readonly property bool windowsPolled: true
    readonly property bool titlePolled:   true

    // ── One Process per concern, deliberately not one shared Process ──────────
    // `running = false; running = true` on a Process TERMINATES whatever it is
    // currently running. Consolidating the four commands below onto one shared
    // Process — which is what the first draft of this file did — made them able
    // to kill each other, and they could not before: they used to live in four
    // separate files with four separate Process objects.
    //
    // Verified against a live Quickshell: start `bash -c "sleep 1; echo FIRST"`,
    // reassign and restart 200 ms later with `echo SECOND`, and only SECOND
    // runs.
    //
    // The one that makes this severe rather than untidy is the submap. If a
    // concurrent border retint or layout change kills `hyprctl dispatch submap
    // reset`, Hyprland stays in RimeShell_clean and EVERY KEY falls through to
    // the shell until Hyprland is restarted. A wallpaper apply landing while
    // focus mode is mid-write is the mundane version: gaps half-applied.
    property Process _accentProc: Process { command: []; running: false }
    property Process _gapsWriteProc: Process {
        command: []; running: false
        // New gaps move the band between a window and the frame: keep the
        // window's corner concentric with the fillet (syncWindowCorners).
        onRunningChanged: if (!running) root.syncWindowCorners()
    }
    property Process _submapProc:  Process { command: []; running: false }
    property Process _shaderApplyProc: Process {
        command: []
        running: false
        // The apply is an eval write plus a damage cycle; re-read afterwards
        // so the tile reflects what Hyprland actually ended up with rather than
        // what was asked for.
        onRunningChanged: if (!running) root.refreshScreenShader()
    }

    function _start(proc, argv) {
        proc.command = argv
        proc.running = false
        proc.running = true
    }

    // A Lua string literal for a value that came from outside the shell (a
    // file name, a workspace name): backslash, quote and every control byte
    // escaped, the same rule as rime-os rime-display-apply / rime-input-apply
    // lua_str, so the value is data inside the expression and never code.
    function _luaStr(value) {
        const v = String(value)
        let out = ""
        for (let i = 0; i < v.length; i++) {
            const ch = v.charAt(i)
            const c = v.charCodeAt(i)
            if (ch === "\\")      out += "\\\\"
            else if (ch === '"')   out += '\\"'
            else if (c < 0x20 || c === 0x7f) out += "\\" + ("00" + c).slice(-3)
            else                   out += ch
        }
        return '"' + out + '"'
    }

    // ── Workspaces ────────────────────────────────────────────────────────────
    // Hyprland pushes these; no polling. `id` is the identity a caller passes
    // back to focusWorkspace().
    readonly property var workspaces: {
        const out = []
        const src = Hyprland.workspaces ? Hyprland.workspaces.values : []
        const focusedId = Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1
        for (let i = 0; i < src.length; i++) {
            const w = src[i]
            out.push({
                id:        w.id,
                idx:       w.id,
                ref:       w.id,          // focusWorkspace() takes the id here
                name:      w.name || String(w.id),
                output:    w.monitor ? w.monitor.name : "",
                isActive:  w.active === true || w.id === focusedId,
                isFocused: w.id === focusedId,
                isUrgent:  w.urgent === true,
                occupied:  true           // it is in the list because it exists
            })
        }
        out.sort(function (a, b) { return a.id - b.id })
        return out
    }

    readonly property int focusedWorkspaceId:
        Hyprland.focusedWorkspace ? Hyprland.focusedWorkspace.id : -1

    // Hyprland presents a fixed 1..10 grid; a workspace that holds nothing is
    // still a place you can switch to, and the bar has always shown it as an
    // empty dot.
    readonly property int workspaceSlots: 10

    // The scratchpad. `activespecial` carries "workspaceName,monitorName" and an
    // empty name means it just closed.
    property bool specialWorkspaceOpen: false

    readonly property string focusedOutput:
        Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""

    // ── Focused window title ──────────────────────────────────────────────────
    // `hyprctl activewindow -j` on every raw event, but only while somebody
    // holds a title ref. Hyprland emits a raw event for essentially every state
    // change, so this is push-driven rather than polled.
    property string focusedTitle:   "Desktop"

    // Hyprland's `initialTitle` is the title the window had when it was mapped,
    // which for almost every toolkit is the bare application name — "kitty",
    // "Mozilla Firefox". That is what the notch wants, and it is what this shell
    // has always displayed there, so the mapping is preserved rather than
    // "improved" into `class`.
    property string focusedAppName: "Desktop"

    property Process _titleProc: Process {
        command: ["hyprctl", "activewindow", "-j"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                // Same race as the window list: a title landing after the ref
                // was released would overwrite the placeholder.
                if (!root.titleWanted) return

                // The decision lives in title.js so tests/title-test.js can
                // drive the file the shell loads rather than a copy. null
                // means the read never completed — a killed or truncated
                // `hyprctl`, which _refreshTitle() causes by design on every
                // raw event — and the last known-good title must stand.
                // Writing "Desktop" there is what made the notch flash.
                const r = Title.readActiveWindow(this.text)
                if (r === null) return
                root.focusedTitle   = r.title
                root.focusedAppName = r.appName
            }
        }
    }

    function _refreshTitle() {
        if (!root.titleWanted) return
        root._titleProc.running = false
        root._titleProc.running = true
    }

    onTitleWantedChanged: {
        if (root.titleWanted) {
            root._refreshTitle()
        } else {
            root.focusedTitle   = "Desktop"
            root.focusedAppName = "Desktop"
        }
    }

    // ── Window list ───────────────────────────────────────────────────────────
    property var windows: []

    property Process _clientsProc: Process {
        command: ["hyprctl", "-j", "clients"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                // The ref can be handed back while this query is still in
                // flight, in which case onWindowsWantedChanged has already
                // cleared the list and this result would refill it — a poller
                // that "stopped" but left stale data behind. Discard it.
                if (!root.windowsWanted) return

                // The decision lives in clients.js so tests/clients-test.js can
                // drive the file the shell loads rather than a copy. null means
                // the read never completed — a killed or truncated `hyprctl`,
                // which _refreshWindows() causes by design on every raw event —
                // and the last known-good list must stand. Assigning [] there
                // is what made the launcher's lower rows flash: every window
                // row vanished and the next poll put them all back.
                //
                // `[]` that PARSED is a different thing and does clear the
                // list: it is Hyprland's answer for "no windows are open".
                const r = Clients.readClients(this.text)
                if (r === null) return
                root.windows = r
            }
        }
    }

    function _refreshWindows() {
        if (!root.windowsWanted) return
        root._clientsProc.running = false
        root._clientsProc.running = true
    }

    onWindowsWantedChanged: {
        if (root.windowsWanted) root._refreshWindows()
        else                    root.windows = []
    }

    // One listener for both. Hyprland's raw event stream fires on window and
    // workspace changes alike; each refresh is a no-op unless its ref is held.
    property Connections _events: Connections {
        target: Hyprland
        function onRawEvent(event) {
            root._refreshTitle()
            root._refreshWindows()
            root._refreshLayout()
            if (event.name === "activelayout" || event.name === "configreloaded")
                root._refreshKeyboardLayouts()
            if (root._FOCUS_EVENTS.indexOf(event.name) !== -1) root.focusMoved()

            if (event.name === "activespecial" || event.name === "activespecialv2")
                root.specialWorkspaceOpen = String(event.data).split(",")[0] !== ""
            else if (event.name === "destroyworkspace")
                root.specialWorkspaceOpen = false
            // A reload restores the config's own motion and layout and drops
            // every rule declared at runtime: read the motion again, re-declare
            // the rules, put the chosen layout back.
            else if (event.name === "configreloaded") {
                root._motionReread()
                root._pushLayerRules()
                root.syncWindowCorners()
                root._applyPreferredLayout()
                root._pushAccent()
                // A reload is also the moment a broken or half-migrated
                // config shows itself: look again.
                root.checkHyprConfig()
            }
        }
    }

    Component.onCompleted: {
        root._refreshTitle()
        root._refreshWindows()
        root._pushLayerRules()
        root.syncWindowCorners()
        root._applyPreferredLayout()

        // One one-shot probe at startup, `hyprctl getoption`. It used to run
        // from QuickSettings.Component.onCompleted instead, so the fork
        // happened on first dashboard open. Same count per session, moved
        // earlier, and the property is now honest from the start rather than
        // reading false until somebody looks. This is a one-shot, not one of
        // the refcounted pollers: nothing repeats. The night light's own adopt
        // probe is the facade's, for every compositor at once.
        root.refreshScreenShader()
    }

    // ── Is Hyprland running Rime's Lua config? ────────────────────────────────
    // ShellState holds the answer and raises the notice (ShellState.hyprConfig);
    // the probe lives here because only this adapter spawns hyprctl.
    //
    // `hyprctl eval` replies exactly "ok" when the chunk ran, the error text
    // when it raised, and "eval is only supported with the lua config manager"
    // otherwise (Hyprland src/ipc/s1/Commands.cpp evalRequest). rime.keybindings
    // is the module the shell's own shell-keybinds module builds on, so its
    // presence in package.loaded is the proof Rime's tree loaded.
    property int _hyprConfigRetries: 0
    function checkHyprConfig() {
        root._hyprConfigProbe.running = false
        root._hyprConfigProbe.running = true
    }
    property Process _hyprConfigProbe: Process {
        running: false
        command: ["bash", "-c",
            "f=\"$HOME/.config/hypr/hyprland.lua\"; "
            + "[ -f \"$f\" ] || { echo no-config; exit 0; }; "
            + "r=\"$(hyprctl eval 'if package.loaded[\"rime.keybindings\"] == nil then "
            + "error(\"rime-modules-missing\", 0) end' 2>&1)\"; "
            + "case \"$r\" in "
            + "ok) echo ok ;; "
            + "*rime-modules-missing*) echo modules-missing ;; "
            + "*'only supported with the lua'*) printf 'not-lua %s\\n' \"$r\" ;; "
            + "*) printf 'unknown %s\\n' \"$r\" ;; "
            + "esac"]
        stdout: StdioCollector {
            onStreamFinished: {
                const line = this.text.trim()
                const sp = line.indexOf(" ")
                const state = sp < 0 ? line : line.slice(0, sp)
                const detail = sp < 0 ? "" : line.slice(sp + 1)
                if (state === "unknown" || state === "") {
                    // hyprctl could not reach the instance (no signature in
                    // this environment yet): not a config verdict. Ask again.
                    console.warn("Rime Shell: could not ask Hyprland about its config: " + detail)
                    ShellState.reportHyprConfig("unknown", detail)
                    if (root._hyprConfigRetries++ < 12) root._hyprConfigRetry.restart()
                    return
                }
                root._hyprConfigRetries = 0
                ShellState.reportHyprConfig(state, detail)
            }
        }
    }
    property Timer _hyprConfigRetry: Timer {
        interval: 5000
        onTriggered: root.checkHyprConfig()
    }
    // Started a few seconds in rather than at construction: the notification
    // server is this shell, and a notice posted before it is listening is lost.
    // rime-shell-firstrun also replaces a stock config and reloads Hyprland at
    // login, so it is asked again on every configreloaded.
    property Timer _hyprConfigFirst: Timer {
        interval: 3000
        running: true
        onTriggered: root.checkHyprConfig()
    }

    // ── Motion (UI/UX roadmap v3 Phase 21) ────────────────────────────────────
    // The shell's speed and Reduce Motion, applied to Hyprland's animations. The
    // numbers are Hyprland's own (hyprMotion.js reads them back and scales
    // them), so rime-os appearance.lua stays the one place they are written.
    //
    // A shell restart finds its own previous push in Hyprland and must not
    // scale it again: what was pushed, and from what base, is kept per Hyprland
    // instance in $XDG_RUNTIME_DIR, and trusted only while the live table is
    // still exactly that push.
    property real _mScale:   1
    property bool _mReduced: false
    property bool _mWanted:  false
    property var  _mBase:    null
    readonly property string _mSig: Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") || ""

    function syncMotion(scale, reduced) {
        root._mScale = scale
        root._mReduced = reduced
        root._mWanted = true
        if (root._mBase === null) root._motionReread()
        else                      root._motionPush()
    }

    // ── Window corners follow the frame ───────────────────────────────────────
    // A window's outer corner (its rounding + its border) is kept concentric
    // with the frame's inner fillet across the band between them (Andre,
    // 2026-09-27: "is the hyprland window corner radii consistent with the
    // actual corner frame fillets … make it exactly"): Geo.windowRounding.
    // rime-os appearance.lua's rounding was a free number (10), so a window's
    // corner ran a pixel inside the fillet's curve, and changing the shell's
    // corner radius moved the frame and not the windows. Read gaps_out and
    // border_size live (either can change under it), then write the rounding
    // — at start, after every config reload (which drops runtime values), after
    // the gaps slider, and when the corner radius or strip width changes.
    function syncWindowCorners() { root._cornersDebounce.restart() }
    property Timer _cornersDebounce: Timer {
        interval: 150
        onTriggered: root._start(root._cornersReadProc, ["bash", "-c",
            "hyprctl -j getoption general:gaps_out; hyprctl -j getoption general:border_size"])
    }
    // The first number of an option's answer, whichever form Hyprland gives it
    // in: `int`, or `css` / `custom` for a gap ("10 10 10 10").
    function _optionNumber(o) {
        if (!o) return NaN
        if (o.int !== undefined) return parseInt(o.int)
        const g = o.css !== undefined ? o.css : o.custom
        if (g !== undefined && g !== "") return parseInt(String(g).trim().split(/\s+/)[0])
        return NaN
    }
    function _cornersRead(text) {
        const nums = []
        const parts = String(text).split("}")
        for (let i = 0; i < parts.length; i++) {
            let v = NaN
            try { v = root._optionNumber(JSON.parse((parts[i] + "}").trim())) } catch (e) { v = NaN }
            if (!isNaN(v)) nums.push(v)
        }
        if (nums.length < 2) return            // unreadable: leave Hyprland's own
        const t = root._cornersTheme
        const r = Geo.windowRounding(t.cornerRadius, t.borderWidth, nums[0], nums[1])
        if (root._pacingLog)
            console.info("Rime window corners: gaps_out=" + nums[0] + " border=" + nums[1] + " -> rounding " + r)
        root._start(root._cornersWriteProc,
            ["hyprctl", "eval", "hl.config({ decoration = { rounding = " + r + " } })"])
    }
    property Process _cornersReadProc: Process {
        stdout: StdioCollector { onStreamFinished: root._cornersRead(String(this.text)) }
    }
    property Process _cornersWriteProc: Process {}
    // The frame's sizes are each output's own (P1-040); Hyprland's rounding is
    // one value, so it follows the output being worked on — the focused one,
    // else the first.
    readonly property var _cornersScreen: {
        const want = Hyprland.focusedMonitor ? Hyprland.focusedMonitor.name : ""
        const list = Quickshell.screens
        for (let i = 0; i < list.length; i++) if (list[i].name === want) return list[i]
        return list.length > 0 ? list[0] : null
    }
    on_CornersScreenChanged: root.syncWindowCorners()
    property ThemeSet _cornersTheme: ThemeSet { scale: Theme.factorForScreen(root._cornersScreen) }
    property Connections _cornersThemeChanges: Connections {
        target: root._cornersTheme
        function onCornerRadiusChanged() { root.syncWindowCorners() }
        function onBorderWidthChanged()  { root.syncWindowCorners() }
    }

    // ── The shell's own layers are not the compositor's to animate ──────────
    // Every shell surface animates itself — a bloom out of the notch, a pour,
    // a spill, a toast — through SurfaceLifecycle, and at progress 0 each one
    // coincides exactly with the bar it grows from, so mapping it is invisible.
    // Hyprland does not know that: on the stock tree every layer that maps is
    // run through `fadeLayersIn` (inherits `fade`, 400 ms) and its unmap through
    // `fadeLayersOut`. Measured in a nested 0.56.2 (UI/UX Phase 20): 66–90 % of
    // the network panel was a translucent blend 240–345 ms into its open — the
    // body "pops in" half-transparent instead of growing out of the notch, and
    // keeps fading after it has stopped. On Andre's L16 today the tree is stock
    // (`hyprctl -j animations`: fade 4 ds `ease`), so every open looked like it.
    //
    // rime-os carries the same rule in appearance.lua (feat/hypr-motion) for
    // the next image; the shell declares it too, at start and after every
    // config reload (which drops runtime rules), so it holds on any Hyprland
    // the shell runs under, whatever that config is. Named, so a user can find
    // it (`require` cannot reach it, but `hyprctl eval` of a rule with the same
    // name and no_anim = false turns it off).
    readonly property string _layerRulesLua:
        'hl.layer_rule({ name = "rime-shell-self-animated", match = { namespace = "^quickshell$" }, no_anim = true })'
    function _pushLayerRules() {
        if (root._pacingLog) console.info("Rime layer rules: push")
        root._start(root._layerRulesProc, ["hyprctl", "eval", root._layerRulesLua])
    }
    property Process _layerRulesProc: Process {
        stdout: StdioCollector { onStreamFinished: if (root._pacingLog) console.info("Rime layer rules: " + String(this.text).trim()) }
        stderr: StdioCollector { onStreamFinished: if (String(this.text).trim() !== "") console.warn("Rime layer rules: " + String(this.text).trim()) }
    }

    function _motionReread() {
        root._mBase = null
        if (root._mWanted) root._start(root._motionReadProc, ["bash", "-c",
            'hyprctl -j animations; printf "\\n\\x1e\\n"; cat "${XDG_RUNTIME_DIR:-/tmp}/rime-shell/hypr-motion.json" 2>/dev/null'])
    }

    function _motionRead(text) {
        const cut = text.indexOf("\n\x1e\n")
        const live = cut < 0 ? text : text.slice(0, cut)
        let state = null
        try { state = cut < 0 ? null : JSON.parse(text.slice(cut + 3)) } catch (e) { state = null }
        const base = HyprMotion.chooseBase(live, state, root._mSig)
        if (!base) return          // unreadable: leave Hyprland as its config has it
        root._mBase = base
        root._motionPush()
    }

    function _motionPush() {
        const lua = HyprMotion.plan(root._mBase, root._mScale, root._mReduced)
        const state = JSON.stringify({ signature: root._mSig, base: root._mBase,
                                       pushed: HyprMotion.expected(root._mBase, root._mScale, root._mReduced) })
        // The eval and the record in one shell, argv-positional like every other
        // write in the shell: the Lua and the JSON are data, never script.
        root._start(root._motionPushProc, ["bash", "-c",
            'hyprctl eval "$1" >/dev/null && d="${XDG_RUNTIME_DIR:-/tmp}/rime-shell" && mkdir -p "$d" && printf "%s" "$2" > "$d/hypr-motion.json"',
            "--", lua, state])
    }

    property Process _motionReadProc: Process {
        stdout: StdioCollector { onStreamFinished: root._motionRead(String(this.text)) }
    }
    property Process _motionPushProc: Process {}

    // ── Tiling layout ─────────────────────────────────────────────────────────
    // `hyprctl -j activeworkspace` reports the workspace's layout and window
    // count. Refreshed on raw events, with a slow safety timer for the one case
    // events do not cover: changing the layout on an empty workspace, where
    // nothing else happens afterwards to trigger a read.
    //
    // Both are refcounted now. The old indicator ran its 4-second timer for the
    // entire session whether or not the bar was on screen.
    property string layoutName:        ""
    property int    layoutWindowCount: 0

    readonly property var layouts: ["dwindle", "master", "monocle", "scrolling"]

    // ── Window previews ───────────────────────────────────────────────────────
    // Every window's wayland handle, keyed by this backend's own window handle.
    // hyprctl's addresses are "0x…"; a HyprlandToplevel's `address` is the same
    // hex WITHOUT the prefix (measured), and its `wayland` can arrive after the
    // object does, so a toplevel is listed once it has one. Event-driven: no poll.
    readonly property var previewSources: {
        const out = {}
        const src = Hyprland.toplevels ? Hyprland.toplevels.values : []
        for (let i = 0; i < src.length; i++) {
            const t = src[i]
            if (t && t.wayland) out["0x" + t.address] = t.wayland
        }
        return out
    }

    // ── Keyboard layouts ──────────────────────────────────────────────────────
    // One `hyprctl devices` read at start and on the compositor's own
    // `activelayout` / `configreloaded` events — a keybind, another client or a
    // config reload — never on a timer. The active layout comes back as its xkb
    // description, matched to a configured slot through evdev.lst (kblayout.js).
    property var keyboardLayouts: ({ labels: [], names: [], index: 0 })
    property var _kbLst: null

    function switchKeyboardLayout(dir) {
        root._start(root._kbActProc, ["hyprctl", "switchxkblayout", "all", dir === "prev" ? "prev" : "next"])
    }
    function _refreshKeyboardLayouts() {
        if (!root._kbReadProc.running) root._kbReadProc.running = true
    }
    property Process _kbActProc: Process { command: []; running: false; onExited: root._refreshKeyboardLayouts() }
    property Process _kbLstProc: Process {
        command: ["cat", "/usr/share/X11/xkb/rules/evdev.lst"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: { root._kbLst = KB.parseLst(this.text); root._refreshKeyboardLayouts() }
        }
        onExited: if (root._kbLst === null) root._refreshKeyboardLayouts()
    }
    property Process _kbReadProc: Process {
        command: ["hyprctl", "-j", "devices"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                let m = null
                try { m = KB.fromHypr(JSON.parse(this.text), root._kbLst) } catch (e) { m = null }
                if (!m) { root.keyboardLayouts = ({ labels: [], names: [], index: 0 }); return }
                const names = m.codes.map(function (c, i) {
                    return (root._kbLst && root._kbLst.layouts[c]) || m.labels[i]
                })
                root.keyboardLayouts = ({ labels: m.labels, names: names, index: m.index })
            }
        }
    }

    property Process _layoutProc: Process {
        command: ["hyprctl", "-j", "activeworkspace"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(this.text)
                    if (d && d.tiledLayout) {
                        root.layoutName        = String(d.tiledLayout).toLowerCase()
                        root.layoutWindowCount = d.windows > 0 ? d.windows : 0
                    }
                } catch (e) {
                    // Malformed JSON: keep the last known layout rather than
                    // flashing the indicator to "Unknown".
                }
            }
        }
    }

    function _refreshLayout() {
        if (!root.layoutWanted) return
        if (!root._layoutProc.running) root._layoutProc.running = true
    }

    onLayoutWantedChanged: if (root.layoutWanted) root._refreshLayout()

    property Timer _layoutSafety: Timer {
        interval: 4000
        repeat:   true
        running:  root.layoutWanted
        onTriggered: root._refreshLayout()
    }

    // Its own Process, not _accentProc: the kept layout is put back at start
    // and after a reload, the same moments the accent border is written, and a
    // shared Process kills whichever write started first (see above).
    property Process _layoutWriteProc: Process {
        command: []; running: false
        // Read back what Hyprland ended up with, not what was asked for.
        onRunningChanged: if (!running) root._refreshLayout()
    }

    function setLayout(name) {
        if (root.layouts.indexOf(name) < 0) return
        root._start(root._layoutWriteProc,
            ["hyprctl", "eval", `hl.config({ general = { layout = ${root._luaStr(name)} } })`])
        // Optimistic, so the indicator changes under the cursor rather than on
        // the next poll.
        root.layoutName = name
    }

    // The layout chosen from the bar (SettingsService.windowLayout, pushed in
    // by the facade). "" = never chosen, and the config's own layout stands.
    // A reload puts the config's back and so does a login, so it is re-applied
    // then (configreloaded), when it arrives (the settings file is read after
    // this backend is built), and at start.
    property string preferredLayout: ""
    // A choice from the menu has already been written (the facade writes,
    // then keeps it): only a kept layout arriving from the file is news.
    onPreferredLayoutChanged: if (root.preferredLayout !== root.layoutName) root._applyPreferredLayout()
    function _applyPreferredLayout() {
        if (root.preferredLayout !== "") root.setLayout(root.preferredLayout)
    }

    // ── Screenshot picker boxes ───────────────────────────────────────────────
    readonly property string windowBoxScript: Boxes.HYPR_WINDOWS
    readonly property string outputBoxScript: Boxes.HYPR_OUTPUTS

    // ── Actions ───────────────────────────────────────────────────────────────
    function focusWorkspace(ref) {
        Hyprland.dispatch(`hl.dsp.focus({ workspace = ${root._luaStr(ref)} })`)
    }

    function toggleSpecialWorkspace(name) {
        Hyprland.dispatch(`hl.dsp.workspace.toggle_special(${root._luaStr(name)})`)
    }

    function focusWindow(handle) {
        Hyprland.dispatch(`hl.dsp.focus({ window = ${root._luaStr("address:" + handle)} })`)
    }

    // Both Lua forms were names Hyprland 0.56.2 does not have — `hl.dsp.close`
    // and `hl.dsp.window.move_to_workspace` — so on the Lua config each call was
    // "attempt to call a nil value": the launcher's close-window row closed
    // nothing, and no window could be moved (measured in a nested 0.56.2; the
    // forms below are the ones it takes). `follow = false` keeps the view where
    // it is, as `movetoworkspacesilent` does.
    function closeWindow(handle) {
        Hyprland.dispatch(`hl.dsp.window.close({ window = ${root._luaStr("address:" + handle)} })`)
    }

    function moveWindowToWorkspace(handle, ws) {
        Hyprland.dispatch(`hl.dsp.window.move({ workspace = ${root._luaStr(ws)}, follow = false, window = ${root._luaStr("address:" + handle)} })`)
    }

    function toggleOverview() { /* unreachable: capabilities.overview is false */ }

    // The accent is a runtime value: a config reload puts the config's own
    // border back (colors.lua, written by matugen, when it exists), so the
    // last one asked for is kept and pushed again on configreloaded.
    property string _accentHex: ""
    function setAccentBorder(hex) {
        const h = String(hex).replace(/^#/, "")
        if (!/^[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/.test(h)) {
            console.warn("Rime accent border: not a colour, ignored: " + hex)
            return
        }
        root._accentHex = h
        root._pushAccent()
    }
    function _pushAccent() {
        if (root._accentHex === "") return
        root._start(root._accentProc, ["hyprctl", "eval",
            `hl.config({ general = { col = { active_border = { colors = { "rgb(${root._accentHex})" } } } } })`])
    }

    function setGaps(inner, outer) {
        // Both gaps in ONE hl.config, so the two cannot be seen half-applied:
        // a single call rather than two that happen to be chained. Numbers
        // only: anything else would be spliced into the expression as code.
        const i = Math.round(Number(inner)), o = Math.round(Number(outer))
        if (!isFinite(i) || !isFinite(o)) {
            console.warn("Rime gaps: not numbers, ignored: " + inner + ", " + outer)
            return
        }
        root._start(root._gapsWriteProc, ["hyprctl", "eval",
            `hl.config({ general = { gaps_in = ${i}, gaps_out = ${o} } })`])
    }

    // Both gaps in one call. This used to be two chained Processes in
    // QuickSettings, each with its own python one-liner, sequenced by
    // onRunningChanged — three subprocesses to read two integers, and no way to
    // tell "the read failed" from "the gaps really are zero".
    property var _gapsCallback: null

    property Process _gapsProc: Process {
        command: ["bash", "-c",
            "hyprctl -j getoption general:gaps_in; hyprctl -j getoption general:gaps_out"]
        running: false
        onRunningChanged: if (!running) root._gapsSettle.restart()
        stdout: StdioCollector {
            onStreamFinished: {
                const cb = root._gapsCallback
                root._gapsCallback = null
                if (!cb) return

                // Two JSON objects back to back. A CSS-style gap comes as
                // "5 5 5 5" under `css` (0.56; `custom` before it), a plain one
                // as `int`; take the first number of whichever is present.
                // (Reading only `custom` and `int`, 0.56's gaps were unreadable.)
                const nums = []
                const parts = this.text.split("}")
                for (let i = 0; i < parts.length; i++) {
                    const chunk = parts[i] + "}"
                    let v = NaN
                    try { v = root._optionNumber(JSON.parse(chunk.trim())) } catch (e) { v = NaN }
                    if (!isNaN(v)) nums.push(v)
                }

                if (nums.length >= 2) cb(true, { inner: nums[0], outer: nums[1] })
                else                  cb(false, null)
            }
        }
    }

    // A binary that cannot be executed emits NEITHER streamFinished NOR exited —
    // only runningChanged. Without this, one failed exec leaves _gapsCallback
    // non-null and every later readGaps is refused for the life of the session,
    // and focus mode never flips because its callback never runs.
    //
    // The facade carries the same guard for outputState/inputState; it was
    // identified there and not applied here.
    property Timer _gapsSettle: Timer {
        interval: 150
        repeat: false
        onTriggered: {
            const cb = root._gapsCallback
            if (!cb) return
            root._gapsCallback = null
            cb(false, null)
        }
    }

    function readGaps(callback) {
        // A second read while one is in flight would drop the first caller's
        // callback on the floor. Refuse instead — the caller gets an answer.
        if (root._gapsCallback !== null) { callback(false, null); return }
        root._gapsCallback = callback
        root._gapsProc.running = false
        root._gapsProc.running = true
    }

    // ── Screen shader ─────────────────────────────────────────────────────────
    // `decoration:screen_shader` is a fullscreen fragment shader Hyprland runs
    // over the composited output — the Filter tile's night-vision, protanopia
    // and so on. Nothing else Rime ships has an equivalent: niri and labwc have
    // no shader hook at all, which is why this is a capability rather than
    // something every backend pretends to.
    //
    // The whole implementation used to live in QuickSettings, including the
    // .conf/lua dialect split, which meant the tile was the only consumer left
    // in the shell that knew what hyprctl was.
    //
    // Reported as a basename without its extension — "protanopia", not
    // "/usr/share/hyprshade/shaders/protanopia.glsl" — because that is what the
    // picker lists and what the tile shows. "" means no shader.
    property string screenShader: ""

    property Process _shaderReadProc: Process {
        command: ["hyprctl", "getoption", "decoration:screen_shader", "-j"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                // Parsed here rather than through the `python3 -c` one-liner
                // this replaced: same JSON, one fewer interpreter per read.
                let s = ""
                try {
                    const d = JSON.parse(this.text)
                    s = (d && d.str) ? String(d.str).trim() : ""
                } catch (e) { s = "" }
                // `[[EMPTY]]` is how Hyprland's .conf dialect spells "unset".
                root.screenShader = (s === "" || s === "[[EMPTY]]")
                    ? "" : root._shaderName(s)
            }
        }
    }

    function _shaderName(path) {
        return String(path).replace(/^.*\//, "").replace(/\.[^.]*$/, "")
    }

    // No settle timer here, unlike readGaps: this is a property refresh and not
    // a callback, so a hyprctl that cannot exec leaves the value stale rather
    // than leaving a caller waiting on a reply that can never come.
    function refreshScreenShader() {
        root._shaderReadProc.running = false
        root._shaderReadProc.running = true
    }

    // path is absolute, or "" to turn the shader off. Resolving a picker entry
    // to a file is the caller's job — this backend does not search the disk.
    function setScreenShader(path) {
        const off = String(path) === ""

        // ── The DPMS damage cycle ────────────────────────────────────────────
        // Hyprland only re-runs the shader where it has damage, so applying one
        // to an otherwise idle screen does nothing visible until something else
        // happens to redraw. Cycling DPMS off and on forces a full redraw of
        // every output.
        //
        // Carried over verbatim from QuickSettings, where it was written and
        // proven on hardware. It is not obvious and it is not decorative; do
        // not "simplify" it into a single dispatch.
        const damage = ` && hyprctl dispatch 'hl.dsp.dpms({ action = "disable" })'`
                     + ` && hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'`

        // The path comes off the user's disk and may contain anything a file
        // name may contain. It is escaped as a Lua string here (_luaStr) and
        // the whole expression goes to bash as a positional argument, so it is
        // neither shell nor Lua code. It used to sit inside '$1' in the Lua
        // source: a name with a ' in it ended the string.
        const expr = `hl.config({ decoration = { screen_shader = ${root._luaStr(off ? "" : path)} } })`

        root._start(root._shaderApplyProc,
                    ["bash", "-c", `hyprctl eval "$1"` + damage, "--", expr])

        // Optimistic, so the tile changes under the cursor rather than after
        // the re-read lands. _shaderApplyProc corrects it either way.
        root.screenShader = off ? "" : root._shaderName(path)
    }

    // ── Night light ───────────────────────────────────────────────────────────
    // hyprsunset. Hyprland 0.56.2 advertises `zwlr_gamma_control_manager_v1`
    // as well — measured, nested — so gammastep would also work here and the
    // shell could run one tool everywhere. It deliberately does not:
    //
    //   hyprsunset shifts the colour temperature through
    //   `hyprland-ctm-control-v1`, a colour TRANSFORM MATRIX applied during
    //   composition. gammastep rewrites the output's GAMMA LUT. A per-display
    //   ICC calibration curve is loaded into that same LUT, so on the wlroots
    //   compositors night light and a calibration curve are the same slot and
    //   the second one to write wins. On Hyprland they are two slots and both
    //   survive — which is the case a creator machine cares about.
    //
    // So the mechanism is per compositor and the reason is colour management,
    // not the absence of an alternative.
    readonly property string nightLightProcess: "hyprsunset"
    function nightLightArgv(kelvin) {
        return ["hyprsunset", "-t", String(kelvin)]
    }

    // Hyprland submaps: a named mode with no binds in it, so every key falls
    // through to the focused surface. That surface is the shell while it is
    // capturing a keybind.
    function setKeyboardInterception(on) {
        const target = on ? "RimeShell_clean" : "reset"
        root._start(root._submapProc,
            ["hyprctl", "dispatch", `hl.dsp.submap("${target}")`])
    }
}
