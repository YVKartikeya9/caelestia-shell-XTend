pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services

Item {
    id: root

    required property ScreenState screenState

    property bool loading: true
    property bool failed: false
    property int qrGeneration: 0

    implicitWidth: 420
    implicitHeight: 520

    function regenerate(): void {
        root.loading = true;
        root.failed = false;
        Hotspot.generateQr(result => {
            root.loading = false;
            if (result.success)
                root.qrGeneration++;
            else
                root.failed = true;
        });
    }

    Component.onCompleted: root.regenerate()

    StyledRect {
        anchors.fill: parent

        color: Colours.tPalette.m3surfaceContainer
        border.color: Colours.palette.m3outlineVariant
        border.width: 1
        radius: Tokens.rounding.extraLarge

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: Tokens.spacing.large

            RowLayout {
                Layout.fillWidth: true

                StyledText {
                    text: Tr.tr("Scan to connect")
                    font: Tokens.font.title.builders.medium.weight(Font.Medium).build()
                }

                Item {
                    Layout.fillWidth: true
                }

                Item {
                    implicitWidth: implicitHeight
                    implicitHeight: closeIcon.implicitHeight + Tokens.padding.extraSmall

                    StateLayer {
                        radius: Tokens.rounding.full
                        onClicked: root.screenState.hotspotQr = false
                    }

                    MaterialIcon {
                        id: closeIcon

                        anchors.centerIn: parent
                        text: "close"
                        color: Colours.palette.m3onSurfaceVariant
                    }
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                StyledRect {
                    anchors.centerIn: parent
                    width: Math.min(parent.width, parent.height)
                    height: width
                    radius: Tokens.rounding.large
                    color: "white"
                    visible: !root.loading && !root.failed

                    Image {
                        anchors.fill: parent
                        anchors.margins: Tokens.padding.large
                        source: root.qrGeneration > 0 ? `file://${Hotspot.qrPath}?t=${root.qrGeneration}` : ""
                        cache: false
                        fillMode: Image.PreserveAspectFit
                        smooth: false
                    }
                }

                StyledText {
                    anchors.centerIn: parent
                    visible: root.loading
                    text: Tr.tr("Generating…")
                    color: Colours.palette.m3onSurfaceVariant
                }

                StyledText {
                    anchors.centerIn: parent
                    visible: root.failed
                    text: Tr.tr("Couldn't generate QR code")
                    color: Colours.palette.m3error
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.small / 2

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    text: Hotspot.ssid
                    font: Tokens.font.body.builders.medium.weight(Font.Medium).build()
                }

                StyledText {
                    Layout.alignment: Qt.AlignHCenter
                    visible: Hotspot.password.length > 0
                    text: Hotspot.password
                    font: Tokens.font.mono.small
                    color: Colours.palette.m3onSurfaceVariant
                }
            }
        }
    }
}
