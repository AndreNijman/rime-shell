import Quickshell
import QtQuick
import "./src/services"
import "./src/popups"
import "./src"

// Inline reply in the notification centre and the toast, driven through the
// shipped components (tests/run-inline-reply-test.sh stages this file at the
// repository root, runs it offscreen on a private session bus, posts the
// notifications with gdbus and watches the bus with dbus-monitor).
//
// The runner posts, in order:
//   A  actions ["inline-reply", "Reply"]       summary "reply-a"
//   B  actions ["open", "Open"]                summary "plain-b"
//   C  actions ["inline-reply", "Antworten"]   summary "reply-c"
//
// What it proves, here (the bus side is the runner's):
//   * a card shows a Reply button exactly when its notification takes an
//     inline reply, labelled with the app's own label; the plain card, whose
//     actions row is on screen for its own action, has none (the same lookup
//     that finds A's is the one that finds nothing on B);
//   * the toast's Reply opens the centre with that card's field open and
//     focused, and the toast steps aside;
//   * an empty or blank field sends nothing; Escape's path closes the field,
//     clears it and takes its focus (the list, a focus scope, used to hand the
//     keys straight back to the hidden field), and a closed field never sends;
//     the real send closes the notification and leaves no reply state behind;
//   * a plain notification cannot be put into reply mode.
// It prints REPLY_ID=<A's id> and REPLY_TEXT for the runner, which asserts
// that the bus carried exactly one NotificationReplied, A's, with that text.

ShellRoot {
    id: t

    property int pass: 0
    property int fail: 0
    function check(what, cond, got) {
        if (cond) { console.warn("  PASS  " + what); t.pass++ }
        else      { console.warn("  FAIL  " + what + "  (got: " + JSON.stringify(got) + ")"); t.fail++ }
    }

    readonly property string replyText: "On my way, 10 min (café)"

    // One window, as the centre and the toast share RightPanel's surface (and
    // the offscreen platform makes only one window active: the focus asserted
    // below is the window's real activeFocus, not just the scope's).
    FloatingWindow {
        implicitWidth: 860
        implicitHeight: 720
        color: "black"
        NotificationList { id: list; width: 380 }
        NotificationToast {
            id: toast
            x: 420
            // As RightPanel binds it.
            blocked: Popups.networkOpen || Popups.notificationsOpen
        }
    }

    function noteBy(summary) {
        for (const n of NotificationService.list) if (n && n.summary === summary) return n
        return null
    }
    // Every visible descendant whose accessible name or role matches.
    function find(item, pred, out) {
        out = out || []
        if (!item) return out
        if (item.visible && pred(item)) out.push(item)
        const kids = item.children || []
        for (let i = 0; i < kids.length; i++) t.find(kids[i], pred, out)
        return out
    }
    function named(item, name) { return t.find(item, function (x) { return x.Accessible.name === name && x.Accessible.role === Accessible.Button }) }
    function field(item) { return t.find(item, function (x) { return x.Accessible.role === Accessible.EditableText })[0] || null }

    property var a: null
    property var b: null
    property var c: null
    property int aId: 0
    property int phase: 0
    property int waited: 0

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            t.waited++
            if (t.waited > 300) { t.check("phase " + t.phase + " finished in time", false, t.phase); t.finish(); return }
            switch (t.phase) {
            case 0: {
                t.a = t.noteBy("reply-a"); t.b = t.noteBy("plain-b"); t.c = t.noteBy("reply-c")
                if (!t.a || !t.b || !t.c || !list._cardFor(t.c.id) || !toast.showing) return
                t.aId = t.a.id
                console.warn("REPLY_ID=" + t.aId)
                t.check("A arrives with hasInlineReply", t.a.hasInlineReply === true, t.a.hasInlineReply)
                t.check("A's inline-reply is not among its actions", t.a.actions.length === 0, t.a.actions.length)
                t.check("B arrives without it", t.b.hasInlineReply === false, t.b.hasInlineReply)

                const ca = list._cardFor(t.a.id), cb = list._cardFor(t.b.id), cc = list._cardFor(t.c.id)
                t.check("card A shows one Reply button", t.named(ca, "Reply").length === 1, t.named(ca, "Reply").length)
                t.check("card B shows its own action", t.named(cb, "Open").length === 1, t.named(cb, "Open").length)
                t.check("... but no Reply button", t.named(cb, "Reply").length === 0, t.named(cb, "Reply").length)
                t.check("card C's button carries the app's label", t.named(cc, "Antworten").length === 1, t.named(cc, "Antworten").length)
                t.check("no card has a field open yet", !t.field(ca) && !t.field(cb) && !t.field(cc), "field")
                t.check("B cannot be put into reply mode", list._openReply(t.b.id) === false && list._replyId === null, list._replyId)

                t.check("the toast shows A", toast.current === t.a, toast.current ? toast.current.summary : null)
                t.check("the toast shows a Reply button for A", t.named(toast, "Reply").length === 1, t.named(toast, "Reply").length)
                toast.reply()
                t.check("the toast's Reply opens the centre", Popups.notificationsOpen === true, Popups.notificationsOpen)
                t.check("... asking for A's reply", Popups.notificationReplyId === t.aId, Popups.notificationReplyId)
                t.check("... and the toast steps aside", toast.showing === false, toast.showing)
                t.check("... without dismissing A", t.a.tracked === true && NotificationService.list.indexOf(t.a) >= 0, t.a.tracked)
                t.check("card A is replying", ca.replying === true && list._replyId === t.aId, list._replyId)
                t.check("card C is not", cc.replying === false, cc.replying)
                t.phase = 1; t.waited = 0
                return
            }
            case 1: {
                const ca = list._cardFor(t.aId)
                const f = t.field(ca)
                if (!f || !f.activeFocus) { if (t.waited < 30) return }
                t.check("A's field is shown and has the keys", !!f && f.activeFocus, f ? f.activeFocus : "no field")
                t.check("the field is named for a reader", !!f && f.Accessible.name === "Reply", f ? f.Accessible.name : null)
                t.check("the highlight is on A", list._curId === t.aId, list._curId)

                f.text = ""
                t.check("an empty field does not send", ca.sendReply() === false, "sent")
                f.text = "  \t  "
                t.check("a blank field does not send", ca.sendReply() === false, "sent")
                t.check("... and A is still there, still replying", t.a.tracked && ca.replying, ca.replying)

                list._cancelReply()
                t.check("Escape's path closes the field", ca.replying === false && !t.field(ca), ca.replying)
                t.check("... takes the keys from it", !!f && !f.activeFocus && !f.focus, f ? f.activeFocus : null)
                t.check("... and the highlight stays on A", list._curId === t.aId, list._curId)
                f.text = "typed at a closed field"
                t.check("a closed field never sends", ca.sendReply() === false, "sent")
                ca.openReply()
                t.phase = 2; t.waited = 0
                return
            }
            case 2: {
                const ca = list._cardFor(t.aId)
                const f = t.field(ca)
                if (!f || !f.activeFocus) { if (t.waited < 30) return }
                t.check("reopened by the card's own Reply, focused", !!f && f.activeFocus, f ? f.activeFocus : "no field")
                t.check("... and empty (a cancel clears it)", !!f && f.text === "", f ? f.text : null)
                f.text = t.replyText
                console.warn("REPLY_TEXT=" + t.replyText)
                t.check("a real reply sends", ca.sendReply() === true, "not sent")
                t.check("no reply state is left", list._replyId === null, list._replyId)
                t.check("the highlight moves to the next card", list._curId !== t.aId && list._curId !== null, list._curId)
                t.phase = 3; t.waited = 0
                return
            }
            case 3: {
                if (NotificationService.list.some(function (n) { return n && n.id === t.aId }) && t.waited < 30) return
                t.check("A closes after the reply", !NotificationService.list.some(function (n) { return n && n.id === t.aId }), "still listed")
                t.check("B and C are untouched", t.b.tracked && t.c.tracked, "gone")
                t.check("C is not replying", list._cardFor(t.c.id) && list._cardFor(t.c.id).replying === false, "replying")
                Popups.replyToNotification(t.c.id)
                t.check("a second ask opens C", list._replyId === t.c.id, list._replyId)
                Popups.closeAll()
                t.check("closing the centre drops the ask and the field", Popups.notificationReplyId === null && list._replyId === null, list._replyId)
                t.finish()
                return
            }
            }
        }
    }

    function finish() {
        console.warn("inline-reply: passed=" + t.pass + " failed=" + t.fail)
        Qt.quit()
    }
}
