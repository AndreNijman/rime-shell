import QtQuick
import "../../"
import "../../components/controls"

// ── A phone is this computer's touchpad (rime-os contract §2.16) ────────────
//
// The island's item while TouchpadService.live: a dot, the phone's name and
// "· touchpad", and a Stop button. CenterContent puts it in the carousel with
// the recorder and push-to-talk, the other "something is using this computer"
// items, and scrolls to it when it appears.
//
// The notch is 300-360 px, so the whole sentence ("Pixel 8 is using this
// computer as a touchpad and keyboard") does not fit beside a button. Only the
// name elides; "· touchpad" always shows. The sentence is the screen reader's
// name for the item and the notification's body.
//
// The name is the phone's choice: shown as PLAIN text only (Text.PlainText,
// set explicitly: the default AutoText would draw "<b>" as bold), already
// cleaned of control, zero-width and direction characters by the service, and
// in a Text of its own, so a right-to-left name cannot reorder the rest.
//
// The bar is under the lock screen's surface while the session is locked, so
// none of this, name or Stop, can be seen or pressed there.
Item {
    id: root
    objectName: "touchpadNotice"
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForSize(Screen.width, Screen.height) }   // P1-040: this output's sizes

    readonly property bool failed: TouchpadService.stopFailed
    readonly property bool stopping: TouchpadService.stopping
    // For tests: the two texts and the button, by name rather than by walking.
    readonly property alias nameItem: nameText
    readonly property alias suffixItem: suffixText
    readonly property alias stopItem: stopBtn

    Accessible.role: Accessible.StaticText
    Accessible.name: root.failed ? qsTr("The touchpad could not be stopped")
                                 : TouchpadService.sentence

    Row {
        id: info
        anchors {
            left: parent.left
            leftMargin: 10
            right: stopBtn.left
            rightMargin: 8
            verticalCenter: parent.verticalCenter
        }
        spacing: 7

        // Live, like the recorder's and push-to-talk's tally lights; it holds
        // still under Reduce Motion (Motion.ambient), and while stopping.
        Rectangle {
            id: dot
            anchors.verticalCenter: parent.verticalCenter
            width: 8; height: 8; radius: 4
            color: root.failed ? Theme.danger : Theme.active
            SequentialAnimation on opacity {
                running: TouchpadService.live && !root.stopping && Motion.ambient
                // Finish the current beat when gated off, so it rests at its
                // end value instead of freezing mid-fade (Reduce Motion mid-pulse).
                alwaysRunToEnd: true
                loops: Animation.Infinite
                NumberAnimation { to: 0.25; duration: Motion.pulseHalf; easing.type: Easing.InOutSine }
                NumberAnimation { to: 1.0;  duration: Motion.pulseHalf; easing.type: Easing.InOutSine }
            }
        }

        Row {
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            Text {
                id: nameText
                anchors.verticalCenter: parent.verticalCenter
                text: TouchpadService.name
                textFormat: Text.PlainText
                font.pixelSize: theme.fs(12); font.weight: Font.Medium
                color: Theme.text
                elide: Text.ElideRight
                maximumLineCount: 1
                width: Math.max(0, Math.min(implicitWidth,
                                            info.width - dot.width - info.spacing - suffixText.implicitWidth - parent.spacing))
            }

            Text {
                id: suffixText
                anchors.verticalCenter: parent.verticalCenter
                text: root.failed ? qsTr("· couldn't stop")
                    : root.stopping ? qsTr("· stopping…")
                    : qsTr("· touchpad")
                textFormat: Text.PlainText
                font.pixelSize: theme.fs(12)
                color: root.failed ? Theme.danger : Theme.subtext
            }
        }
    }

    // Stop. It never names the phone: TouchpadService runs
    // `rime remote devices touchpad stop`, and the file turning live:false is
    // what makes this item go.
    RimePressable {
        id: stopBtn
        objectName: "touchpadStop"
        anchors {
            right: parent.right
            rightMargin: 10
            verticalCenter: parent.verticalCenter
        }
        width: stopLabel.implicitWidth + 20
        height: 22
        radius: height / 2
        hitMargin: 4
        interactive: !root.stopping
        // The bar never takes the keyboard from the window being typed in.
        focusOnPress: false
        Accessible.name: root.failed ? qsTr("Try to stop the touchpad again") : qsTr("Stop the touchpad")
        onActivated: TouchpadService.stop()

        Rectangle {
            anchors.fill: parent
            radius: stopBtn.radius
            color: stopBtn.tint(Theme.surfaceRaised)
            border.width: 1
            border.color: Theme.outlineSoft
            Behavior on color { MotionColor {} }
        }
        Text {
            id: stopLabel
            anchors.centerIn: parent
            text: root.failed ? qsTr("Retry") : qsTr("Stop")
            textFormat: Text.PlainText
            font.pixelSize: theme.fs(11); font.weight: Font.Medium
            color: Theme.text
        }
        RimeFocusRing { target: stopBtn }
    }
}
