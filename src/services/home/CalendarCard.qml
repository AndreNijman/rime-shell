import QtQuick
import "../../"
import "../../components"
import "../../components/controls"

// Calendar card — month grid with prev/next navigation.
// Self-contained: owns all calendar state.

StatCard {
    id: root
    padding: 0

    // ── State ─────────────────────────────────────────────────────────────────
    property int    _year:  0
    property int    _month: 0
    property int    _today: 0
    property int    _todayMonth: 0
    property int    _todayYear:  0
    property var    _days:  []
    property string _label: ""

    readonly property var _monthNames: [
        "January","February","March","April","May","June",
        "July","August","September","October","November","December"
    ]
    readonly property var _dowNames: ["Su","Mo","Tu","We","Th","Fr","Sa"]

    Component.onCompleted: {
        _syncToday(true)
    }

    // Re-read the wall clock. Called from a repeating timer and whenever the
    // card is shown, so a suspend (monotonic timers stop) or a clock change
    // can never leave "today" at the date the session started. Navigation is
    // only reset to the current month when the day actually changes.
    function _syncToday(force) {
        var now = new Date()
        var d = now.getDate(), m = now.getMonth(), y = now.getFullYear()
        if (!force && d === _today && m === _todayMonth && y === _todayYear)
            return
        _today = d; _todayMonth = m; _todayYear = y
        _year = y; _month = m
        _rebuild()
    }
    onVisibleChanged: if (visible) _syncToday(false)

    function _rebuild() {
        _label = _monthNames[_month].substring(0,3).toUpperCase() + "  " + _year
        var firstDow   = new Date(_year, _month, 1).getDay()
        var daysInMon  = new Date(_year, _month + 1, 0).getDate()
        var daysInPrev = new Date(_year, _month, 0).getDate()
        var days = []
        for (var p = firstDow - 1; p >= 0; p--)
            days.push({ n: daysInPrev - p, cur: false })
        for (var d = 1; d <= daysInMon; d++)
            days.push({ n: d, cur: true })
        var tail = 42 - days.length
        for (var t = 1; t <= tail; t++)
            days.push({ n: t, cur: false })
        _days = days
    }

    function _prev() {
        if (_month === 0) { _month = 11; _year-- } else _month--
        _rebuild()
    }
    function _next() {
        if (_month === 11) { _month = 0; _year++ } else _month++
        _rebuild()
    }

    Timer {
        interval: 30000
        running: true
        repeat: true
        onTriggered: root._syncToday(false)
    }

    // ── UI ────────────────────────────────────────────────────────────────────
    Item {
        anchors { fill: parent; margins: 12 }

        // Header
        Item {
            id: hdr
            anchors { left: parent.left; right: parent.right; top: parent.top }
            height: 22

            RimePressable {
                id: prevMonthBtn
                anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                width: 22; height: 22; radius: 6; hitMargin: 5
                Accessible.name: "Previous month"
                onActivated: root._prev()
                Text {
                    anchors.centerIn: parent
                    text: "‹"; font.pixelSize: theme.fs(15)
                    color: prevMonthBtn.hovered ? Theme.textPrimary : Theme.textTertiary
                    Behavior on color { MotionColor {} }
                }
                RimeFocusRing { target: prevMonthBtn }
            }
            Text {
                anchors.centerIn: parent
                text: root._label; font.pixelSize: theme.fs(10); font.weight: Font.Bold
                color: Theme.text
            }
            RimePressable {
                id: nextMonthBtn
                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                width: 22; height: 22; radius: 6; hitMargin: 5
                Accessible.name: "Next month"
                onActivated: root._next()
                Text {
                    anchors.centerIn: parent
                    text: "›"; font.pixelSize: theme.fs(15)
                    color: nextMonthBtn.hovered ? Theme.textPrimary : Theme.textTertiary
                    Behavior on color { MotionColor {} }
                }
                RimeFocusRing { target: nextMonthBtn }
            }
        }

        // DOW row
        Item {
            id: dow
            anchors { left: parent.left; right: parent.right; top: hdr.bottom; topMargin: 3 }
            height: 16
            Row {
                anchors.fill: parent
                Repeater {
                    model: root._dowNames
                    delegate: Text {
                        width: Math.floor(dow.width / 7)
                        horizontalAlignment: Text.AlignHCenter
                        text: modelData; font.pixelSize: theme.fs(8); font.weight: Font.Bold
                        color: Theme.textTertiary
                    }
                }
            }
        }

        // Day grid
        Grid {
            id: grid
            anchors { left: parent.left; right: parent.right; top: dow.bottom; topMargin: 2; bottom: parent.bottom }
            columns: 7; rows: 6

            readonly property real cW: width  / 7
            readonly property real cH: height / 6

            Repeater {
                model: root._days
                delegate: Item {
                    required property var modelData
                    required property int index
                    width: grid.cW; height: grid.cH

                    readonly property bool isToday:
                        modelData.cur && modelData.n === root._today &&
                        root._month === root._todayMonth &&
                        root._year  === root._todayYear

                    Rectangle {
                        anchors.centerIn: parent
                        width: Math.min(parent.width, parent.height) - 4
                        height: width; radius: width / 2
                        color: isToday ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b,0.15)
                               : dH.hovered && modelData.cur ? Qt.rgba(Theme.text.r, Theme.text.g, Theme.text.b, 0.07) : "transparent"
                        border.color: isToday ? Qt.rgba(Theme.active.r, Theme.active.g, Theme.active.b,0.3) : "transparent"
                        border.width: 1
                        Behavior on color { MotionColor { role: "state" } }
                        Text {
                            anchors.centerIn: parent; text: modelData.n
                            font.pixelSize: theme.fs(9); font.family: "JetBrains Mono"
                            font.weight: isToday ? Font.Bold : Font.Normal
                            color: isToday ? Theme.active
                                   : modelData.cur ? Theme.textSecondary
                                                   : Theme.textTertiary
                        }
                    }
                    HoverHandler { id: dH; enabled: modelData.cur; cursorShape: Qt.PointingHandCursor }
                }
            }
        }
    }
}
