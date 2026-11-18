import QtQuick
import QtQuick.Controls
import "../"
import "../../"
import "../../components"
import "../../components/config"
import "../../components/controls"
import "../phone.js" as P

// ─── PhonePhotos ─────────────────────────────────────────────────────────────
// The phone's newest photos and screenshots as a grid, from the previews the
// daemon keeps under the runtime folder while the phone is connected. Pick
// one and Save fetches the whole photo into Pictures, Rime Remote, and says
// where it went.
//
// When Android gave Rime Remote only the photos the person picked, the page
// says so: an empty-looking grid is not "no photos".
// ─────────────────────────────────────────────────────────────────────────────
Item {
    id: root
    readonly property ThemeSet theme: ThemeSet { scale: Theme.factorForSize(Screen.width, Screen.height) }   // P1-040: this output's sizes

    readonly property bool featureOn: PhoneService.offers("photos")
    // The picked photo, or null.
    property var picked: null
    readonly property var _photoIds: PhoneService.photos.map(function (p) { return p.id })
    // A refreshed grid without the picked photo lets go of it.
    on_PhotoIdsChanged: if (root.picked && root._photoIds.indexOf(root.picked.id) < 0) root.picked = null

    EmptyState {
        objectName: "phonePhotosOff"
        anchors.centerIn: parent
        width: parent.width * 0.8
        visible: !root.featureOn
        plain: true
        glyph: "󰉏"
        title: PhoneService.offMessage("photos").title
        hint: PhoneService.offMessage("photos").hint
    }

    Column {
        id: head
        visible: root.featureOn
        anchors { left: parent.left; right: parent.right; top: parent.top }
        spacing: theme.px(4)

        Text {
            objectName: "phonePhotosPartial"
            width: parent.width
            visible: PhoneService.photosPartial
            text: "Only the photos you picked on the phone are shown. To show all of them, allow Rime Remote all photos in the phone's settings."
            wrapMode: Text.WordWrap
            color: Theme.textSecondary
            font.pixelSize: theme.typeCaption
        }
        Text {
            objectName: "phonePhotosNote"
            width: parent.width
            visible: text !== ""
            text: PhoneService.photosError !== "" ? PhoneService.photosError
                : !PhoneService.photosLoaded ? "Asking the phone for its photos"
                : PhoneService.photos.length === 0 ? "No photos on the phone" : ""
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: PhoneService.photosError !== "" ? Theme.danger : Theme.textSecondary
            font.pixelSize: theme.typeCaption
        }
    }

    GridView {
        id: grid
        objectName: "phonePhotoGrid"
        visible: root.featureOn
        anchors { left: parent.left; right: parent.right; top: head.bottom; bottom: saveBar.top
                  topMargin: theme.px(6); bottomMargin: theme.px(6) }
        clip: true
        readonly property int columns: Math.max(3, Math.floor(width / theme.px(130)))
        cellWidth: Math.floor(width / columns)
        cellHeight: cellWidth
        model: PhoneService.photos
        boundsBehavior: Flickable.StopAtBounds
        Accessible.role: Accessible.List
        Accessible.name: "Photos"
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        footer: Item {
            width: grid.width
            height: PhoneService.morePhotos ? theme.px(44) : 0
            visible: PhoneService.morePhotos
            CfgButton {
                objectName: "phoneMorePhotos"
                anchors.centerIn: parent
                label: PhoneService.loadingMorePhotos ? "Loading" : "More photos"
                enabled: !PhoneService.loadingMorePhotos
                onClicked: PhoneService.readPhotos(true)
            }
        }

        delegate: Item {
            id: cell
            required property var modelData
            width: grid.cellWidth
            height: grid.cellHeight

            RimePressable {
                id: tile
                objectName: "phonePhoto_" + cell.modelData.id
                readonly property bool isPicked: root.picked !== null && root.picked.id === cell.modelData.id
                anchors.fill: parent
                anchors.margins: theme.px(3)
                radius: theme.radiusS
                Accessible.role: Accessible.Button
                Accessible.name: cell.modelData.name || "Photo"
                onActivated: root.picked = tile.isPicked ? null : cell.modelData

                Rectangle {
                    anchors.fill: parent
                    radius: theme.radiusS
                    color: tile.tint(Theme.surfaceHigh)
                    border.width: tile.isPicked ? theme.px(2) : 0
                    border.color: Theme.accentText
                }
                Image {
                    objectName: "phonePhotoThumb"
                    anchors.fill: parent
                    anchors.margins: tile.isPicked ? theme.px(3) : 0
                    visible: source !== ""
                    source: P.fileUrl(cell.modelData.thumb)
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: false
                    sourceSize.width: grid.cellWidth
                    sourceSize.height: grid.cellHeight
                }
                Text {
                    anchors.centerIn: parent
                    width: parent.width - theme.px(8)
                    visible: cell.modelData.thumb === ""
                    horizontalAlignment: Text.AlignHCenter
                    text: cell.modelData.name
                    textFormat: Text.PlainText
                    elide: Text.ElideMiddle
                    color: Theme.textSecondary
                    font.pixelSize: theme.typeCaption
                }
            }
        }
    }

    // ── Save ─────────────────────────────────────────────────────────────────

    Column {
        id: saveBar
        visible: root.featureOn
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        spacing: theme.px(4)

        Row {
            width: parent.width
            spacing: theme.px(10)
            visible: root.picked !== null

            Text {
                objectName: "phonePickedName"
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - saveButton.width - parent.spacing
                text: root.picked ? root.picked.name + " · " + P.bytes(root.picked.size)
                                    + (root.picked.width ? " · " + root.picked.width + " × " + root.picked.height : "") : ""
                textFormat: Text.PlainText
                elide: Text.ElideMiddle
                color: Theme.textPrimary
                font.pixelSize: theme.typeBody
            }
            CfgButton {
                id: saveButton
                objectName: "phoneSave"
                label: PhoneService.savingId >= 0 ? "Saving" : "Save"
                variant: "accent"
                enabled: PhoneService.savingId < 0
                onClicked: if (root.picked) PhoneService.save(root.picked.id)
            }
        }
        Text {
            objectName: "phoneSaveNote"
            width: parent.width
            visible: text !== ""
            text: PhoneService.saveError !== "" ? PhoneService.saveError
                : PhoneService.savedPath !== "" ? "Saved to " + PhoneService.savedPath : ""
            textFormat: Text.PlainText
            wrapMode: Text.WrapAnywhere
            color: PhoneService.saveError !== "" ? Theme.danger : Theme.textSecondary
            font.pixelSize: theme.typeCaption
        }
    }
}
