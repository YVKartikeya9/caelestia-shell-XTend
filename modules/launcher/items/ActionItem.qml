import QtQuick
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root

    required property var modelData
    required property var list

    readonly property bool hasSecondary:
        Boolean(root.modelData?.secondaryIcon && root.modelData?.onSecondaryClicked)

    function escapeHtml(text: string): string {
        return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    // Bolds the portion of text that matched the search query, if the model
    // provided one (only file search results do this right now)
    function highlighted(text: string, query: string): string {
        if (!query)
            return root.escapeHtml(text);

        const idx = text.toLowerCase().indexOf(query.toLowerCase());
        if (idx === -1)
            return root.escapeHtml(text);

        const pre = root.escapeHtml(text.slice(0, idx));
        const match = root.escapeHtml(text.slice(idx, idx + query.length));
        const post = root.escapeHtml(text.slice(idx + query.length));
        return `${pre}<b>${match}</b>${post}`;
    }

    implicitHeight: Tokens.sizes.launcher.itemHeight

    anchors.left: parent?.left
    anchors.right: parent?.right

    StateLayer {
        radius: Tokens.rounding.large
        onClicked: root.modelData?.onClicked(root.list)
    }

    Item {
        anchors.fill: parent
        anchors.leftMargin: Tokens.padding.medium
        anchors.rightMargin: Tokens.padding.medium
        anchors.margins: Tokens.padding.small

        MaterialIcon {
            id: icon

            anchors.verticalCenter: parent.verticalCenter
            text: root.modelData?.icon ?? ""
            color: Colours.palette.m3onSurfaceVariant
            fontStyle: Tokens.font.icon.builders.large.scale(1.3).build()
        }

        Item {
            anchors.left: icon.right
            anchors.leftMargin: Tokens.spacing.medium
            anchors.verticalCenter: icon.verticalCenter

            implicitWidth: parent.width - icon.width - (root.hasSecondary ? secondaryButton.width + Tokens.spacing.medium : 0)
            implicitHeight: name.implicitHeight + desc.implicitHeight

            StyledText {
                id: name

                textFormat: root.modelData?.query ? Text.StyledText : Text.PlainText
                text: root.modelData?.query ? root.highlighted(root.modelData?.name ?? "", root.modelData.query) : (root.modelData?.name ?? "")
                font: Tokens.font.body.medium

                elide: Text.ElideRight
                width: parent.width
            }

            StyledText {
                id: desc

                text: root.modelData?.desc ?? ""
                font: Tokens.font.body.small
                color: Colours.palette.m3outline

                elide: Text.ElideMiddle
                width: parent.width

                anchors.top: name.bottom
            }
        }

        Item {
            id: secondaryButton

            visible: root.hasSecondary
            width: visible ? Tokens.sizes.launcher.itemHeight * 0.6 : 0
            height: width

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            StateLayer {
                radius: Tokens.rounding.large
                onClicked: root.modelData?.onSecondaryClicked(root.list)
            }

            MaterialIcon {
                anchors.centerIn: parent
                text: root.modelData?.secondaryIcon ?? ""
                color: Colours.palette.m3onSurfaceVariant
                fontStyle: Tokens.font.icon.builders.large.scale(1.3).build()
            }
        }
    }
}
