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
