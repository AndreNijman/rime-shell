import QtQuick
import "../../../"
import "../../"
import "../../../components"
import "../../../components/config"

// Config → Paired devices  (roadmap P1-051, criteria 3 and 5)
//
//   3. "Lost devices can be revoked from Rime Settings."
//   5. "Paired-device list shows name, last seen, permissions, and revocation
//       state."
//
// ── A revoked device stays on the list ──────────────────────────────────────
//
// The daemon keeps the record after revocation so the listing can still show
// that it WAS revoked and when, and this page shows it. A row that vanished
// would leave the person unable to tell "I revoked that phone" from "that
// phone was never here" — and the second reading is the one that sends
// somebody hunting for a device they already dealt with.
//
// ── The biometric flag is a claim, and is not a column ──────────────────────
//
// Criterion 5 says "permissions", and the field behind it is
// `requires_user_verification`. It records that the DEVICE said its key is
// held behind a biometric or device lock. This desktop cannot see a
// fingerprint and cannot check it, which rime-remote-core says at length:
// "recorded as a requirement the owner set and not as a fact about the
// device".
//
// So it is one sentence under the list, exactly as `rime remote devices`
// prints it, and deliberately NOT a tick in each row — "a tick in a table
// would read as a fact this machine had verified". remotepairing.js exposes it
// only as that sentence, and tests/remote-pairing-test.js asserts the absence
// of anything a row could render per device.
//
// ── State colours are not decided here ──────────────────────────────────────
//
// The token and the weight come from remotepairing.js, looked up on Theme by
// name. That is the rule tests/check-color-tokens.sh states after "Rime agents
// display only in white": a row does not decide what a state looks like, and a
// three-branch ternary made of theme tokens is still the bug.
CfgScroll {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForSize(Screen.width, Screen.height) }   // P1-040: this output's sizes


    lifecycle: "live"

    property bool onScreen: false

    ServiceRef {
        service: RemotePairingService
        active: root.onScreen
    }
    ServiceRef {
        service: ComputersService
        active: root.onScreen
    }

    // The computer whose Remove was pressed once: a second press within
    // 2.5 s removes it (MiscPage's two-click confirm). A removal ends the
    // pair on both computers, and pairing again needs a person at each.
    property string _removeArmed: ""
    Timer { id: removeTimer; interval: 2500; onTriggered: root._removeArmed = "" }
    // The computer a path is being typed for, where no file dialog exists.
    property string _pathFor: ""

    // ── The devices ──────────────────────────────────────────────────────────
    CfgSection {
        title: "Paired devices"
        first: true

        CfgRow {
            label: "Nothing paired yet"
            description: "Open 'Pair a device' and scan the code with Rime Remote."
            // Only once a read has actually come back. "No devices" and "not
            // asked yet" look identical and mean opposite things.
            visible: RemotePairingService.devicesChecked
                     && RemotePairingService.summary === "No devices paired."
        }

        CfgRow {
            label: "Could not read the device list"
            description: RemotePairingService.devicesError
            visible: RemotePairingService.devicesError !== ""
        }

        Repeater {
            model: RemotePairingService.devices

            Rectangle {
                id: deviceRow

                // What the headless suite finds rows by. A marker property
                // rather than a position in the tree, so the assertion still
                // points at the right object after somebody reflows the page.
                property string deviceId: modelData.id
                readonly property string deviceState: RemotePairingService.deviceState(modelData)
                // The token is a NAME on Theme, looked up rather than switched
                // on, so remotepairing.js stays the only file deciding it.
                readonly property color tone: Theme[RemotePairingService.stateToken(deviceRow.deviceState)]
                readonly property string weight: RemotePairingService.stateWeight(deviceRow.deviceState)

                readonly property string phoneLine: RemotePairingService.phoneLine(modelData)
                readonly property bool canBeRung: modelData.phone !== null
                    && RemotePairingService.deviceState(modelData) !== "revoked"
                readonly property bool canReceive: deviceRow.canBeRung && modelData.phone.canReceive
                readonly property bool ringShown: RemotePairingService.actFor === modelData.id
                    && RemotePairingService.actText !== ""

                width: parent.width
                height: theme.px(deviceRow.phoneLine !== "" || deviceRow.ringShown ? 80 : 62)
                radius: theme.px(8)
                color: deviceRow.weight === "tint"
                    ? Qt.rgba(deviceRow.tone.r, deviceRow.tone.g, deviceRow.tone.b, 0.08)
                    : "transparent"
                border.color: deviceRow.weight === "outline" || deviceRow.weight === "solid"
                    ? deviceRow.tone : Theme.border
                border.width: Math.max(1, theme.px(1))

                Column {
                    anchors.left: parent.left
                    anchors.leftMargin: theme.px(12)
                    anchors.right: sendBtn.visible ? sendBtn.left : ringBtn.visible ? ringBtn.left : revokeBtn.left
                    anchors.rightMargin: theme.px(10)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: theme.px(3)

                    Text {
                        text: modelData.name
                        textFormat: Text.PlainText
                        font.pixelSize: theme.fs(13)
                        font.weight: Font.Medium
                        color: Theme.text
                        elide: Text.ElideRight
                        width: parent.width
                    }

                    Row {
                        spacing: theme.px(8)

                        // The state word, in the state's own tone. The word is
                        // the redundant channel that survives when the hue
                        // does not carry -- see remotepairing.js on why every
                        // state also has a weight.
                        Text {
                            text: RemotePairingService.stateLabel(deviceRow.deviceState)
                            font.pixelSize: theme.typeCaption
                            color: deviceRow.tone
                        }
                        Text {
                            text: "·  last seen " + RemotePairingService.lastSeen(modelData)
                                + (modelData.lastPath ? "  over " + modelData.lastPath : "")
                            font.pixelSize: theme.typeCaption
                            color: Theme.subtext
                            elide: Text.ElideRight
                        }
                    }

                    // The phone's own report (battery, charging), or what the
                    // last ring did. One line: the ring result wins while it
                    // is fresh, because it answers the button just pressed.
                    Text {
                        text: deviceRow.ringShown ? RemotePairingService.actText : deviceRow.phoneLine
                        visible: text !== ""
                        font.pixelSize: theme.typeCaption
                        color: Theme[RemotePairingService.actToken(deviceRow.ringShown)]
                        elide: Text.ElideRight
                        width: parent.width
                    }
                }

                // `rime remote send --clipboard`: this computer's clipboard,
                // as text, onto the phone's. Only on a phone that said it can
                // receive (an app with notifications allowed). The CLI reads
                // the clipboard, so the Shell never holds it.
                CfgButton {
                    id: sendBtn
                    anchors.right: ringBtn.visible ? ringBtn.left : revokeBtn.left
                    anchors.rightMargin: theme.px(6)
                    anchors.verticalCenter: parent.verticalCenter
                    label: RemotePairingService.sending === modelData.id ? "Sending…" : "Send clipboard"
                    icon: "󰅇"
                    visible: deviceRow.canReceive
                    enabled: RemotePairingService.sending === ""
                    onClicked: RemotePairingService.sendClipboard(modelData.id)
                }

                // Find the phone: `rime remote ring`. Only on a device that has
                // reported itself, which means an app new enough to ring; an
                // older one would only ever answer with a refusal.
                CfgButton {
                    id: ringBtn
                    anchors.right: revokeBtn.left
                    anchors.rightMargin: theme.px(6)
                    anchors.verticalCenter: parent.verticalCenter
                    label: RemotePairingService.ringing === modelData.id ? "Ringing…" : "Ring"
                    icon: "󰂞"
                    visible: deviceRow.canBeRung
                    enabled: RemotePairingService.ringing === ""
                    onClicked: RemotePairingService.ring(modelData.id)
                }

                CfgButton {
                    id: revokeBtn
                    anchors.right: parent.right
                    anchors.rightMargin: theme.px(8)
                    anchors.verticalCenter: parent.verticalCenter
                    label: RemotePairingService.revoking === modelData.id ? "Revoking…" : "Revoke"
                    icon: "󰅙"
                    // A revoked device has nothing left to take away. The
                    // button goes rather than greying, so the row reads as
                    // finished business instead of a disabled action somebody
                    // tries to work out how to enable.
                    visible: RemotePairingService.deviceState(modelData) !== "revoked"
                    enabled: RemotePairingService.revoking === ""
                    onClicked: RemotePairingService.revoke(modelData.id)
                }
            }
        }

        CfgRow {
            label: "Could not revoke"
            description: RemotePairingService.revokeError
            visible: RemotePairingService.revokeError !== ""
        }
    }

    // ── Your other Rime computers ────────────────────────────────────────────
    //
    // `rime remote computers list --json`, through ComputersService. Hidden
    // while none was ever paired, or when this rime has no `computers` verb.
    // A removed computer stays listed, as a revoked phone does. Each switch
    // is this computer's half (rime-os docs/remote.md, "Your clipboard and
    // files between computers"); the daemon refuses any of them for a
    // computer that is not allowed yet, so they are off and say why.
    //
    // Names come from the other computer: plain text, one line, elided.
    CfgSection {
        title: "Computers"
        visible: ComputersService.computers.length > 0

        Repeater {
            // The ids, so a list read updates a row rather than rebuilding it
            // (a half-typed path, or a Remove waiting for its second click,
            // would go with a rebuilt row).
            model: ComputersService.computerIds

            Column {
                id: comp
                required property var modelData
                readonly property string computerId: comp.modelData
                readonly property var c: ComputersService.row(comp.computerId)
                readonly property var st: ComputersService.stateOf(comp.c)
                readonly property color tone: Theme[comp.st.token]
                readonly property bool live: comp.c.active
                readonly property bool busy: ComputersService.busyFor === comp.computerId
                readonly property string note: ComputersService.sendingFor === comp.computerId
                    ? "Sending " + ComputersService.sendingName + "…" : ComputersService.noteOf(comp.computerId)

                objectName: "computerSettings"
                width: parent.width
                spacing: theme.px(2)

                Rectangle {
                    width: parent.width
                    height: info.implicitHeight + theme.px(20)
                    radius: theme.px(8)
                    color: comp.st.weight === "tint" ? Qt.rgba(comp.tone.r, comp.tone.g, comp.tone.b, 0.08) : "transparent"
                    border.color: comp.st.weight === "outline" || comp.st.weight === "solid" ? comp.tone : Theme.border
                    border.width: Math.max(1, theme.px(1))

                    Column {
                        id: info
                        anchors.left: parent.left
                        anchors.leftMargin: theme.px(12)
                        anchors.right: buttons.left
                        anchors.rightMargin: theme.px(10)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: theme.px(3)

                        Text {
                            objectName: "computerName"
                            text: comp.c.name
                            textFormat: Text.PlainText
                            maximumLineCount: 1
                            font.pixelSize: theme.fs(13)
                            font.weight: Font.Medium
                            color: Theme.text
                            elide: Text.ElideRight
                            width: parent.width
                        }
                        Row {
                            spacing: theme.px(8)
                            width: parent.width
                            Text {
                                id: stateWord
                                text: comp.st.word
                                textFormat: Text.PlainText
                                font.pixelSize: theme.typeCaption
                                color: comp.tone
                            }
                            Text {
                                width: parent.width - stateWord.width - theme.px(8)
                                visible: text !== ""
                                // "Reached 2m ago" → "·  reached 2m ago"; only the
                                // first letter, so "Rime Remote" keeps its capitals.
                                readonly property string line: ComputersService.reachedLine(comp.c)
                                text: line !== "" ? "·  " + line.charAt(0).toLowerCase() + line.slice(1) : ""
                                textFormat: Text.PlainText
                                font.pixelSize: theme.typeCaption
                                color: Theme.subtext
                                elide: Text.ElideRight
                            }
                        }
                        Text {
                            objectName: "computerPresence"
                            width: parent.width
                            visible: text !== ""
                            text: comp.live ? ComputersService.presenceLine(comp.c) : ""
                            textFormat: Text.PlainText
                            maximumLineCount: 1
                            font.pixelSize: theme.typeCaption
                            color: Theme.subtext
                            elide: Text.ElideRight
                        }
                        Text {
                            objectName: "computerIntroduced"
                            width: parent.width
                            visible: text !== ""
                            text: ComputersService.introducedLine(comp.c)
                            textFormat: Text.PlainText
                            maximumLineCount: 1
                            font.pixelSize: theme.typeCaption
                            color: comp.c.needsAllow ? Theme.warning : Theme.subtext
                            elide: Text.ElideRight
                        }
                    }

                    Row {
                        id: buttons
                        anchors.right: parent.right
                        anchors.rightMargin: theme.px(8)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: theme.px(6)

                        // An introduced computer stays less trusted until a
                        // person here says otherwise: `computers allow`.
                        CfgButton {
                            objectName: "computerAllow"
                            visible: comp.c.needsAllow
                            label: comp.busy && ComputersService.busyKind === "allow" ? "Allowing…" : "Allow"
                            variant: "accent"
                            enabled: ComputersService.busyFor === ""
                            onClicked: ComputersService.allow(comp.computerId)
                        }
                        CfgButton {
                            objectName: "computerSendFile"
                            // Not before it is allowed: the sender refuses one
                            // that is not (remote-live-contract §2.15).
                            visible: comp.live && comp.c.trusted
                            label: "Send file…"
                            icon: "󰈔"
                            enabled: ComputersService.sendingFor === "" && ComputersService.pickingFor === ""
                            onClicked: {
                                if (ComputersService.canPick) ComputersService.pickAndSend(comp.computerId)
                                else root._pathFor = root._pathFor === comp.computerId ? "" : comp.computerId
                            }
                        }
                        CfgButton {
                            objectName: "computerRemove"
                            visible: comp.live
                            variant: "danger"
                            icon: "󰅙"
                            label: comp.busy && ComputersService.busyKind === "remove" ? "Removing…"
                                 : root._removeArmed === comp.computerId ? "Click to confirm" : "Remove"
                            enabled: ComputersService.busyFor === ""
                            onClicked: {
                                if (root._removeArmed !== comp.computerId) {
                                    root._removeArmed = comp.computerId
                                    removeTimer.restart()
                                } else {
                                    root._removeArmed = ""
                                    removeTimer.stop()
                                    ComputersService.remove(comp.computerId)
                                }
                            }
                        }
                    }
                }

                // No file dialog on this machine: the whole path, typed.
                Row {
                    visible: comp.live && root._pathFor === comp.computerId
                    spacing: theme.px(8)
                    topPadding: theme.px(4)
                    CfgTextField {
                        id: pathField
                        objectName: "computerPathField"
                        fieldWidth: theme.px(320)
                        placeholder: "/home/you/Documents/file.pdf"
                        Accessible.name: "Path of the file to send to " + comp.c.name
                        onAccepted: pathSend.press()
                    }
                    CfgButton {
                        id: pathSend
                        label: "Send"
                        variant: "accent"
                        enabled: ComputersService.sendingFor === "" && pathField.text.trim() !== ""
                        onClicked: if (ComputersService.sendPath(comp.computerId, pathField.text)) {
                            pathField.text = ""
                            root._pathFor = ""
                        }
                    }
                }

                Text {
                    objectName: "computerNote"
                    width: parent.width
                    visible: text !== ""
                    topPadding: theme.px(4)
                    text: comp.note
                    textFormat: Text.PlainText
                    wrapMode: Text.WordWrap
                    maximumLineCount: 3
                    elide: Text.ElideRight
                    font.pixelSize: theme.typeCaption
                    color: ComputersService.sendingFor !== comp.computerId && !ComputersService.noteOk ? Theme.danger : Theme.subtext
                }

                Item { width: 1; height: theme.px(2); visible: comp.live }

                CfgRow {
                    objectName: "computerSwitch_clipboard_send"
                    visible: comp.live
                    plainText: true
                    label: "Send my clipboard to it"
                    disabledReason: comp.c.trusted ? "" : "Allow this computer first."
                    description: SettingsService.phoneClipboard
                        ? "Text you copy here goes to it when it takes this computer's clipboard too."
                        : "Nothing is sent while \"Send my clipboard to my phone\" is off, under Clipboard below."
                    CfgSwitch {
                        checked: comp.c.clipboardSend
                        enabled: ComputersService.busyFor === ""
                        onToggled: function(v) { ComputersService.setSwitch(comp.computerId, "clipboard_send", v) }
                    }
                }
                CfgRow {
                    objectName: "computerSwitch_clipboard_receive"
                    visible: comp.live
                    plainText: true
                    label: "Take its clipboard"
                    disabledReason: comp.c.trusted ? "" : "Allow this computer first."
                    description: "Text copied there lands on this clipboard when it sends it. Never while this screen is locked."
                    CfgSwitch {
                        checked: comp.c.clipboardReceive
                        enabled: ComputersService.busyFor === ""
                        onToggled: function(v) { ComputersService.setSwitch(comp.computerId, "clipboard_receive", v) }
                    }
                }
                CfgRow {
                    objectName: "computerSwitch_files"
                    visible: comp.live
                    plainText: true
                    label: "Take its files"
                    disabledReason: comp.c.trusted ? "" : "Allow this computer first."
                    description: "Files it sends are saved in Downloads. Nothing is opened."
                    CfgSwitch {
                        checked: comp.c.files
                        enabled: ComputersService.busyFor === ""
                        onToggled: function(v) { ComputersService.setSwitch(comp.computerId, "files", v) }
                    }
                }
                CfgRow {
                    objectName: "computerSwitch_handoff"
                    // A rime-remoted without handoff cards lists no `handoff`.
                    visible: comp.live && comp.c.handoff !== null
                    plainText: true
                    label: "Take its links"
                    disabledReason: comp.c.trusted ? "" : "Allow this computer first."
                    description: "A link it sends shows here as a notification. Nothing opens until you press Open."
                    CfgSwitch {
                        checked: comp.c.handoff === true
                        enabled: ComputersService.busyFor === ""
                        onToggled: function(v) { ComputersService.setSwitch(comp.computerId, "handoff", v) }
                    }
                }

                // ── Agent sessions across computers (M4) ─────────────────────
                // `agents`: what that computer may do with the agent sessions
                // HERE. The Shell only lowers it, to off; every other level is
                // asked about at a terminal, so the command is shown to copy.
                CfgRow {
                    objectName: "computerAgents"
                    visible: comp.live && comp.c.agents !== null
                    plainText: true
                    label: "Its agents on this computer"
                    status: ComputersService.agentWord(comp.c.agents)
                    description: comp.c.agents === "control"
                        ? "It can watch the agent sessions here, attach to them and type into them."
                        : comp.c.agents === "view"
                        ? "It can see the agent sessions here and what they show. It cannot type into them."
                        : "It cannot see the agent sessions here."
                    descriptionLines: 2
                    CfgButton {
                        objectName: "computerAgentsOff"
                        visible: comp.c.agents === "view" || comp.c.agents === "control"
                        label: comp.busy && ComputersService.busyKind === "agents" ? "Turning off…" : "Turn off"
                        variant: "danger"
                        enabled: ComputersService.busyFor === ""
                        onClicked: ComputersService.agentsOff(comp.computerId)
                    }
                }
                Column {
                    id: raise
                    objectName: "computerAgentsRaise"
                    readonly property var lines: ComputersService.agentsLines(comp.c)
                    visible: comp.live && comp.c.agents !== null
                    width: parent.width
                    leftPadding: theme.px(12)
                    rightPadding: theme.px(12)
                    spacing: theme.px(4)

                    Text {
                        width: raise.width - raise.leftPadding - raise.rightPadding
                        text: raise.lines.length > 0
                            ? "Any level but Off is set from a terminal here: run the line, and rime asks you to type its name first."
                            : "Allow this computer first to let it see your agent sessions."
                        textFormat: Text.PlainText
                        wrapMode: Text.WordWrap
                        color: Theme.textSecondary
                        font.pixelSize: theme.typeCaption
                    }
                    Repeater {
                        model: raise.lines.length
                        delegate: Row {
                            required property int index
                            readonly property var l: raise.lines[index] || ({ word: "", line: "" })
                            spacing: theme.px(8)
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: theme.px(110)
                                text: l.word
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                color: Theme.textSecondary
                                font.pixelSize: theme.typeCaption
                            }
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.min(cmd.implicitWidth + theme.px(16),
                                                raise.width - raise.leftPadding - raise.rightPadding - theme.px(230))
                                height: cmd.implicitHeight + theme.px(8)
                                radius: theme.radiusXS
                                color: Theme.surfaceHigh
                                clip: true
                                TextEdit {
                                    id: cmd
                                    objectName: "computerAgentsCommand"
                                    anchors.left: parent.left
                                    anchors.leftMargin: theme.px(8)
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: l.line
                                    textFormat: TextEdit.PlainText
                                    readOnly: true
                                    selectByMouse: true
                                    color: Theme.text
                                    font.family: Theme.fontMono
                                    font.pixelSize: theme.typeMono
                                    // Drawn as typed: no ligature turns "--" into one dash.
                                    font.features: { "calt": 0, "liga": 0 }
                                }
                            }
                            CfgButton {
                                objectName: "computerAgentsCopy"
                                anchors.verticalCenter: parent.verticalCenter
                                label: "Copy"
                                icon: "󰆏"
                                onClicked: ComputersService.copyText(l.line)
                            }
                        }
                    }
                }
                CfgRow {
                    objectName: "computerCanAgents"
                    visible: comp.live && comp.c.canAgents !== null
                    plainText: true
                    label: "Your agents on it"
                    status: ComputersService.agentWord(comp.c.canAgents)
                    description: (comp.c.canAgents === "control"
                        ? "It says this computer can watch its agent sessions and work in them."
                        : comp.c.canAgents === "view"
                        ? "It says this computer can watch its agent sessions."
                        : "It says this computer cannot see its agent sessions.")
                        + (comp.c.canAgentsMs !== null ? " Last heard " + ComputersService.agoText(comp.c.canAgentsMs) + "." : "")
                        + " Only someone at it can change this."
                }

                Item { width: 1; height: theme.px(10) }
            }
        }

        CfgRow {
            label: "Both computers decide"
            description: "A copy, a file or a link goes from one computer to the other only when the other takes it, so turn each on at both. Removing a computer removes this one there too."
        }
    }

    // ── The device's own claim ───────────────────────────────────────────────
    CfgSection {
        title: "Device locks"
        visible: RemotePairingService.verificationNote !== ""

        CfgRow {
            label: "What the device says"
            // One sentence, naming the devices, phrased as a claim. Not a
            // column and not a tick: this machine cannot verify it, and a
            // tick would read as though it had.
            description: RemotePairingService.verificationNote
        }
    }

    // ── Do Not Disturb on both ───────────────────────────────────────────────
    CfgSection {
        title: "Focus"

        CfgRow {
            label: "Do Not Disturb follows your phone"
            // Off by default: with it off the Shell reads nothing from the
            // phone and tells the phone nothing. PhoneFocusService.
            description: "When Do Not Disturb changes on a phone with Focus turned on in Rime Remote, it changes here too, and turning it on or off here does the same on the phone."
            CfgSwitch {
                checked: SettingsService.phoneFocus
                onToggled: function(v) { SettingsService.set("phoneFocus", v) }
            }
        }
    }

    // ── This computer's clipboard on the phones ──────────────────────────────
    CfgSection {
        title: "Clipboard"

        CfgRow {
            label: "Send my clipboard to my phone"
            // Off by default: with it off nothing watches the clipboard.
            // PhoneClipboardService; rime-os contract §2.10.
            description: "Text you copy here goes to each connected phone with \"Get the computer's clipboard\" turned on in Rime Remote, and to each computer under Computers that you send your clipboard to. A password manager's copy, images and text over 64 KB are not sent."
            CfgSwitch {
                checked: SettingsService.phoneClipboard
                onToggled: function(v) { SettingsService.set("phoneClipboard", v) }
            }
        }
    }

    // ── What revoking does ───────────────────────────────────────────────────
    CfgSection {
        title: "About revoking"

        CfgRow {
            label: "It takes effect immediately"
            description: "A connection the device is already holding is dropped, not merely refused next time. The record is kept, so the device stays on this list marked revoked rather than disappearing."
        }

        CfgRow {
            label: "Pairing again is a new decision"
            description: "A revoked device cannot come back on its own. It has to scan a fresh pairing code, which means somebody has to be at this machine to show one."
        }
    }
}
