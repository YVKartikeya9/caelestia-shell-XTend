pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Pam // xtend:hotspot
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.utils

ColumnLayout {
    id: root

    required property PopoutState popouts

    property string connectingToSsid: ""
    property string view: "wireless" // "wireless" or "ethernet"
    property var passwordNetwork: null
    property bool showPasswordDialog: false
    // xtend:hotspot

    // "" | "auth" | "edit" - editing the hotspot password is gated behind
    // re-entering your own login password via the same PAM service the lock
    // screen uses, not just a plain click
    property string hotspotEditStage: ""
    property bool hotspotAuthFailed: false
    property bool hotspotPasswordFailed: false

    Component.onCompleted: Hotspot.refreshStatus(() => {})
    // xtend:hotspot end

    spacing: Tokens.spacing.small
    width: Tokens.sizes.bar.networkWidth

    // Wireless section
    StyledText {
        visible: root.view === "wireless"
        Layout.preferredHeight: visible ? implicitHeight : 0
        Layout.topMargin: visible ? Tokens.padding.medium : 0
        Layout.rightMargin: Tokens.padding.extraSmall
        text: Tr.tr("Wireless")
        font: Tokens.font.body.builders.medium.weight(Font.Medium).build()
    }

    Toggle {
        visible: root.view === "wireless"
        Layout.preferredHeight: visible ? implicitHeight : 0
        label: Tr.trCtx("Enabled", "toggle label")
        checked: Nmcli.wifiEnabled
        toggle.onToggled: Nmcli.enableWifi(checked)
    }

    StyledText {
        visible: root.view === "wireless"
        Layout.preferredHeight: visible ? implicitHeight : 0
        Layout.topMargin: visible ? Tokens.spacing.small : 0
        Layout.rightMargin: Tokens.padding.extraSmall
        text: Tr.trN("%n network available", "%n networks available", Nmcli.networks.length) // qmllint disable missing-property
        color: Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.small
    }

    Repeater {
        visible: root.view === "wireless"
        model: ScriptModel {
            values: [...Nmcli.networks].sort((a, b) => {
                if (a.active !== b.active)
                    return b.active - a.active;
                return b.strength - a.strength;
            }).slice(0, 8)
        }

        RowLayout {
            id: networkItem

            required property Nmcli.AccessPoint modelData
            readonly property bool isConnecting: root.connectingToSsid === modelData.ssid
            readonly property bool loading: networkItem.isConnecting

            visible: root.view === "wireless"
            Layout.preferredHeight: visible ? implicitHeight : 0
            Layout.fillWidth: true
            Layout.rightMargin: Tokens.padding.extraSmall
            spacing: Tokens.spacing.small

            opacity: 0
            scale: 0.7

            Component.onCompleted: {
                opacity = 1;
                scale = 1;
            }

            Behavior on opacity {
                Anim {
                    type: Anim.DefaultEffects
                }
            }

            Behavior on scale {
                Anim {}
            }

            MaterialIcon {
                text: Icons.getNetworkIcon(networkItem.modelData.strength)
                color: networkItem.modelData.active ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
            }

            MaterialIcon {
                visible: networkItem.modelData.isSecure
                text: "lock"
                fontStyle: Tokens.font.icon.small
            }

            StyledText {
                Layout.leftMargin: Tokens.spacing.extraSmall
                Layout.rightMargin: Tokens.spacing.extraSmall
                Layout.fillWidth: true
                text: networkItem.modelData.ssid
                elide: Text.ElideRight
                font: Tokens.font.body.builders.medium.weight(networkItem.modelData.active ? Font.Medium : Font.Normal).build()
                color: networkItem.modelData.active ? Colours.palette.m3primary : Colours.palette.m3onSurface
            }

            StyledRect {
                implicitWidth: implicitHeight
                implicitHeight: wirelessConnectIcon.implicitHeight + Tokens.padding.extraSmall

                radius: Tokens.rounding.full
                color: Qt.alpha(Colours.palette.m3primary, networkItem.modelData.active ? 1 : 0)

                CircularIndicator {
                    anchors.fill: parent
                    running: networkItem.loading
                }

                StateLayer {
                    color: networkItem.modelData.active ? Colours.palette.m3onPrimary : Colours.palette.m3onSurface
                    disabled: networkItem.loading || !Nmcli.wifiEnabled

                    onClicked: {
                        if (networkItem.modelData.active) {
                            Nmcli.disconnectFromNetwork();
                        } else {
                            root.connectingToSsid = networkItem.modelData.ssid;
                            NetworkConnection.handleConnect(networkItem.modelData, null, network => {
                                // Password is required - show password dialog
                                root.passwordNetwork = network;
                                root.showPasswordDialog = true;
                                root.popouts.currentName = "wirelesspassword";
                            });

                            // Clear connecting state if connection succeeds immediately (saved profile)
                            // This is handled by the onActiveChanged connection below
                        }
                    }
                }

                MaterialIcon {
                    id: wirelessConnectIcon

                    anchors.centerIn: parent
                    animate: true
                    text: networkItem.modelData.active ? "link_off" : "link"
                    color: networkItem.modelData.active ? Colours.palette.m3onPrimary : Colours.palette.m3onSurface

                    opacity: networkItem.loading ? 0 : 1

                    Behavior on opacity {
                        Anim {
                            type: Anim.DefaultEffects
                        }
                    }
                }
            }
        }
    }

    StyledRect {
        visible: root.view === "wireless"
        Layout.preferredHeight: visible ? implicitHeight : 0
        Layout.topMargin: visible ? Tokens.spacing.small : 0
        Layout.fillWidth: true
        implicitHeight: rescanBtn.implicitHeight + Tokens.padding.small

        radius: Tokens.rounding.full
        color: Colours.palette.m3primaryContainer

        StateLayer {
            color: Colours.palette.m3onPrimaryContainer
            disabled: Nmcli.scanning || !Nmcli.wifiEnabled
            onClicked: Nmcli.rescanWifi()
        }

        RowLayout {
            id: rescanBtn

            anchors.centerIn: parent
            spacing: Tokens.spacing.small
            opacity: Nmcli.scanning ? 0 : 1

            MaterialIcon {
                id: scanIcon

                Layout.topMargin: Math.round(fontInfo.pointSize * 0.0575)
                animate: true
                text: "wifi_find"
                color: Colours.palette.m3onPrimaryContainer
            }

            StyledText {
                Layout.topMargin: -Math.round(scanIcon.fontInfo.pointSize * 0.0575)
                text: Tr.tr("Rescan networks")
                color: Colours.palette.m3onPrimaryContainer
            }

            Behavior on opacity {
                Anim {
                    type: Anim.DefaultEffects
                }
            }
        }

        CircularIndicator {
            anchors.centerIn: parent
            strokeWidth: Tokens.padding.extraSmall / 2
            bgColour: "transparent"
            implicitSize: parent.implicitHeight - Tokens.padding.large
            running: Nmcli.scanning
        }
    }

    // Ethernet section
    StyledText {
        visible: root.view === "ethernet"
        Layout.preferredHeight: visible ? implicitHeight : 0
        Layout.topMargin: visible ? Tokens.padding.medium : 0
        Layout.rightMargin: Tokens.padding.extraSmall
        text: Tr.tr("Ethernet")
        font: Tokens.font.body.builders.medium.weight(Font.Medium).build()
    }

    StyledText {
        visible: root.view === "ethernet"
        Layout.preferredHeight: visible ? implicitHeight : 0
        Layout.topMargin: visible ? Tokens.spacing.small : 0
        Layout.rightMargin: Tokens.padding.extraSmall
        text: Tr.trN("%n device available", "%n devices available", Nmcli.ethernetDevices.length)
        color: Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.small
    }

    Repeater {
        visible: root.view === "ethernet"
        model: ScriptModel {
            values: [...Nmcli.ethernetDevices].sort((a, b) => {
                if (a.connected !== b.connected)
                    return b.connected - a.connected;
                return (a.iface || "").localeCompare(b.iface || "");
            }).slice(0, 8)
        }

        RowLayout {
            id: ethernetItem

            required property var modelData
            readonly property bool loading: false

            visible: root.view === "ethernet"
            Layout.preferredHeight: visible ? implicitHeight : 0
            Layout.fillWidth: true
            Layout.rightMargin: Tokens.padding.extraSmall
            spacing: Tokens.spacing.small

            opacity: 0
            scale: 0.7

            Component.onCompleted: {
                opacity = 1;
                scale = 1;
            }

            Behavior on opacity {
                Anim {
                    type: Anim.DefaultEffects
                }
            }

            Behavior on scale {
                Anim {}
            }

            MaterialIcon {
                text: "cable"
                color: ethernetItem.modelData.connected ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
            }

            StyledText {
                Layout.leftMargin: Tokens.spacing.extraSmall
                Layout.rightMargin: Tokens.spacing.extraSmall
                Layout.fillWidth: true
                text: ethernetItem.modelData.iface || Tr.trCtx("Unknown", "unknown network interface")
                elide: Text.ElideRight
                font: Tokens.font.body.builders.medium.weight(ethernetItem.modelData.connected ? Font.Medium : Font.Normal).build()
                color: ethernetItem.modelData.connected ? Colours.palette.m3primary : Colours.palette.m3onSurface
            }

            StyledRect {
                implicitWidth: implicitHeight
                implicitHeight: connectIcon.implicitHeight + Tokens.padding.extraSmall

                radius: Tokens.rounding.full
                color: Qt.alpha(Colours.palette.m3primary, ethernetItem.modelData.connected ? 1 : 0)

                CircularIndicator {
                    anchors.fill: parent
                    running: ethernetItem.loading
                }

                StateLayer {
                    color: ethernetItem.modelData.connected ? Colours.palette.m3onPrimary : Colours.palette.m3onSurface
                    disabled: ethernetItem.loading

                    onClicked: {
                        if (ethernetItem.modelData.connected && ethernetItem.modelData.connection) {
                            Nmcli.disconnectEthernet(ethernetItem.modelData.connection, () => {});
                        } else {
                            Nmcli.connectEthernet(ethernetItem.modelData.connection || "", ethernetItem.modelData.iface || "", () => {});
                        }
                    }
                }

                MaterialIcon {
                    id: connectIcon

                    anchors.centerIn: parent
                    animate: true
                    text: ethernetItem.modelData.connected ? "link_off" : "link"
                    color: ethernetItem.modelData.connected ? Colours.palette.m3onPrimary : Colours.palette.m3onSurface

                    opacity: ethernetItem.loading ? 0 : 1

                    Behavior on opacity {
                        Anim {
                            type: Anim.DefaultEffects
                        }
                    }
                }
            }
        }
    }

    // xtend:hotspot
    // Hotspot section - a plain interactive toggle over the same
    // assets/hotspot-toggle.sh script the keybind already runs, so both
    // stay in sync and drive identical create_ap logic. Shown regardless of
    // view - the hotspot broadcasts over the wifi radio
    // no matter which connection is currently providing your internet.
    StyledText {
        Layout.preferredHeight: implicitHeight
        Layout.topMargin: Tokens.padding.medium
        Layout.rightMargin: Tokens.padding.extraSmall
        text: Tr.tr("Hotspot")
        font: Tokens.font.body.builders.medium.weight(Font.Medium).build()
    }

    RowLayout {
        Layout.preferredHeight: implicitHeight
        Layout.topMargin: Tokens.spacing.small
        Layout.fillWidth: true
        Layout.rightMargin: Tokens.padding.extraSmall
        spacing: Tokens.spacing.medium

        MaterialIcon {
            text: "wifi_tethering"
            color: Hotspot.active ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
        }

        StyledText {
            Layout.fillWidth: true
            text: Hotspot.active ? (Hotspot.ssid || Tr.tr("Hotspot active")) : Tr.tr("Off")
            elide: Text.ElideRight
            font: Tokens.font.body.builders.medium.weight(Hotspot.active ? Font.Medium : Font.Normal).build()
            color: Hotspot.active ? Colours.palette.m3primary : Colours.palette.m3onSurface
        }

        Item {
            visible: Hotspot.active
            implicitWidth: visible ? implicitHeight : 0
            implicitHeight: qrIcon.implicitHeight + Tokens.padding.extraSmall

            StateLayer {
                radius: Tokens.rounding.full
                onClicked: {
                    const s = ShellState.forActive();
                    if (s)
                        s.hotspotQr = true;
                }
            }

            MaterialIcon {
                id: qrIcon

                anchors.centerIn: parent
                text: "qr_code"
                color: Colours.palette.m3onSurfaceVariant
                fontStyle: Tokens.font.icon.medium
            }
        }

        Item {
            implicitWidth: implicitHeight
            implicitHeight: editIcon.implicitHeight + Tokens.padding.extraSmall

            StateLayer {
                radius: Tokens.rounding.full
                onClicked: {
                    if (root.hotspotEditStage) {
                        hotspotAuth.abort();
                        root.hotspotEditStage = "";
                    } else {
                        root.hotspotAuthFailed = false;
                        root.hotspotEditStage = "auth";
                    }
                }
            }

            MaterialIcon {
                id: editIcon

                anchors.centerIn: parent
                text: "key"
                color: Colours.palette.m3onSurfaceVariant
                fontStyle: Tokens.font.icon.medium
            }
        }

        StyledSwitch {
            id: hotspotSwitch

            checked: Hotspot.active
            enabled: !Hotspot.busy

            // Clicking a switch breaks the declarative `checked` binding and
            // assigns a literal - re-apply the real value on every change
            // instead of it. (Qt.binding() from inside an async callback
            // throws in this QML engine, so a Connections re-sync is used
            // instead of the usual rebind-on-click trick.)
            onToggled: Hotspot.toggle(() => {})

            Connections {
                target: Hotspot
                function onActiveChanged() {
                    hotspotSwitch.checked = Hotspot.active;
                }
            }
        }
    }

    PamContext {
        id: hotspotAuth

        config: "passwd"
        configDirectory: Quickshell.shellPath("assets/pam.d")

        onResponseRequiredChanged: {
            if (!responseRequired)
                return;
            respond(hotspotAuthField.text);
        }

        onCompleted: res => { // qmllint disable signal-handler-parameters
            if (res === PamResult.Success) {
                root.hotspotAuthFailed = false;
                root.hotspotEditStage = "edit";
                hotspotAuthField.text = "";
            } else {
                root.hotspotAuthFailed = true;
                hotspotAuthField.isError = true;
                hotspotAuthField.text = "";
            }
        }
    }

    Item {
        id: hotspotAuthForm

        Layout.fillWidth: true
        Layout.rightMargin: Tokens.padding.extraSmall
        Layout.topMargin: root.hotspotEditStage === "auth" ? Tokens.spacing.small : 0
        implicitHeight: root.hotspotEditStage === "auth" ? hotspotAuthFormContent.implicitHeight : 0
        clip: true
        opacity: root.hotspotEditStage === "auth" ? 1 : 0

        Behavior on Layout.topMargin {
            Anim {
                type: Anim.DefaultEffects
            }
        }

        Behavior on implicitHeight {
            Anim {
                type: Anim.DefaultEffects
            }
        }

        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }

        ColumnLayout {
            id: hotspotAuthFormContent

            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Tokens.spacing.small

            StyledTextField {
                id: hotspotAuthField

                Layout.fillWidth: true
                enabled: root.hotspotEditStage === "auth"
                placeholderText: Tr.tr("Confirm your password")
                leadingIcon: "lock"
                echoMode: TextInput.Password
                errorText: Tr.tr("Wrong password")

                onAccepted: hotspotAuthBtn.clicked()
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: Tokens.spacing.small

                TextButton {
                    isRound: true
                    horizontalPadding: Tokens.padding.large
                    type: TextButton.Tonal
                    text: Tr.tr("Cancel")
                    onClicked: {
                        hotspotAuth.abort();
                        root.hotspotEditStage = "";
                        root.hotspotAuthFailed = false;
                        hotspotAuthField.text = "";
                    }
                }

                ButtonBase {
                    id: hotspotAuthBtn

                    isRound: true
                    inactiveColour: Colours.palette.m3primary
                    inactiveOnColour: Colours.palette.m3onPrimary
                    stateLayer.disabled: hotspotAuth.active || hotspotAuthField.text.length === 0

                    implicitWidth: hotspotAuthText.implicitWidth + Tokens.padding.extraLarge * 2
                    implicitHeight: hotspotAuthText.implicitHeight + Tokens.padding.medium * 2

                    onClicked: {
                        root.hotspotAuthFailed = false;
                        hotspotAuthField.isError = false;
                        hotspotAuth.start();
                    }

                    StyledText {
                        id: hotspotAuthText

                        anchors.centerIn: parent
                        text: Tr.tr("Confirm")
                        font: hotspotAuthBtn.font
                        color: hotspotAuthBtn.onColour
                    }
                }
            }
        }
    }

    Item {
        id: hotspotPasswordForm

        Layout.fillWidth: true
        Layout.rightMargin: Tokens.padding.extraSmall
        Layout.topMargin: root.hotspotEditStage === "edit" ? Tokens.spacing.small : 0
        implicitHeight: root.hotspotEditStage === "edit" ? hotspotPasswordFormContent.implicitHeight : 0
        clip: true
        opacity: root.hotspotEditStage === "edit" ? 1 : 0

        Behavior on Layout.topMargin {
            Anim {
                type: Anim.DefaultEffects
            }
        }

        Behavior on implicitHeight {
            Anim {
                type: Anim.DefaultEffects
            }
        }

        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }

        ColumnLayout {
            id: hotspotPasswordFormContent

            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Tokens.spacing.small

            StyledTextField {
                id: hotspotPasswordField

                Layout.fillWidth: true
                enabled: root.hotspotEditStage === "edit"
                placeholderText: Tr.tr("New hotspot password")
                leadingIcon: "key"
                echoMode: TextInput.Password
                supportingText: Tr.tr("8-63 characters")
                errorText: root.hotspotPasswordFailed ? Tr.tr("Couldn't save password") : Tr.tr("Password must be 8-63 characters")

                onAccepted: hotspotPasswordSaveBtn.clicked()
            }

            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: Tokens.spacing.small

                TextButton {
                    isRound: true
                    horizontalPadding: Tokens.padding.large
                    type: TextButton.Tonal
                    text: Tr.tr("Cancel")
                    onClicked: {
                        root.hotspotEditStage = "";
                        root.hotspotPasswordFailed = false;
                        hotspotPasswordField.text = "";
                    }
                }

                ButtonBase {
                    id: hotspotPasswordSaveBtn

                    isRound: true
                    inactiveColour: Colours.palette.m3primary
                    inactiveOnColour: Colours.palette.m3onPrimary
                    stateLayer.disabled: hotspotPasswordField.text.length < 8

                    implicitWidth: hotspotPasswordSaveText.implicitWidth + Tokens.padding.extraLarge * 2
                    implicitHeight: hotspotPasswordSaveText.implicitHeight + Tokens.padding.medium * 2

                    onClicked: {
                        const password = hotspotPasswordField.text;
                        if (password.length < 8 || password.length > 63) {
                            hotspotPasswordField.isError = true;
                            hotspotPasswordField.forceActiveFocus();
                            return;
                        }

                        root.hotspotPasswordFailed = false;
                        Hotspot.setPassword(password, result => {
                            if (result.success) {
                                root.hotspotEditStage = "";
                                hotspotPasswordField.text = "";
                            } else {
                                root.hotspotPasswordFailed = true;
                                hotspotPasswordField.isError = true;
                            }
                        });
                    }

                    StyledText {
                        id: hotspotPasswordSaveText

                        anchors.centerIn: parent
                        text: Tr.tr("Save")
                        font: hotspotPasswordSaveBtn.font
                        color: hotspotPasswordSaveBtn.onColour
                    }
                }
            }
        }
    }

    StyledText {
        visible: Hotspot.active
        Layout.preferredHeight: visible ? implicitHeight : 0
        Layout.topMargin: visible ? Tokens.spacing.small : 0
        Layout.rightMargin: Tokens.padding.extraSmall
        text: Hotspot.clientCount === 0 ? Tr.tr("No devices connected") : Tr.trN("%n device connected", "%n devices connected", Hotspot.clientCount)
        color: Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.small
    }

    Repeater {
        visible: Hotspot.active
        model: Hotspot.clients

        RowLayout {
            id: clientItem

            required property var modelData

            Layout.preferredHeight: implicitHeight
            Layout.fillWidth: true
            Layout.rightMargin: Tokens.padding.extraSmall
            spacing: Tokens.spacing.small

            MaterialIcon {
                text: "devices"
                fontStyle: Tokens.font.icon.small
                color: Colours.palette.m3onSurfaceVariant
            }

            StyledText {
                Layout.fillWidth: true
                text: clientItem.modelData.hostname || Tr.tr("Unnamed device (%1)").arg(clientItem.modelData.ip)
                elide: Text.ElideRight
                font: Tokens.font.body.small
                color: Colours.palette.m3onSurfaceVariant
            }

            StyledText {
                text: Tr.tr("↓%1 ↑%2").arg(Units.formatBytes(clientItem.modelData.rxBytes, false)).arg(Units.formatBytes(clientItem.modelData.txBytes, false))
                font: Tokens.font.body.small
                color: Colours.palette.m3onSurfaceVariant
            }
        }
    }
    // xtend:hotspot end
    Connections {
        function onActiveChanged(): void {
            if (Nmcli.active && root.connectingToSsid === Nmcli.active.ssid) {
                root.connectingToSsid = "";
                // Close password dialog if we successfully connected
                if (root.showPasswordDialog && root.passwordNetwork && Nmcli.active.ssid === root.passwordNetwork.ssid) {
                    root.showPasswordDialog = false;
                    root.passwordNetwork = null;
                    if (root.popouts.currentName === "wirelesspassword") {
                        root.popouts.currentName = "network";
                    }
                }
            }
        }

        function onScanningChanged(): void {
            if (!Nmcli.scanning)
                scanIcon.rotation = 0;
        }

        target: Nmcli
    }

    Connections {
        function onCurrentNameChanged(): void {
            // Clear password network when leaving password dialog
            if (root.popouts.currentName !== "wirelesspassword" && root.showPasswordDialog) {
                root.showPasswordDialog = false;
                root.passwordNetwork = null;
            }
        }

        target: root.popouts
    }

    component Toggle: RowLayout {
        required property string label
        property alias checked: toggle.checked
        property alias toggle: toggle

        Layout.fillWidth: true
        Layout.rightMargin: Tokens.padding.extraSmall
        spacing: Tokens.spacing.medium

        StyledText {
            Layout.fillWidth: true
            text: parent.label
        }

        StyledSwitch {
            id: toggle
        }
    }
}
