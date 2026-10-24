import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.modules.launcher.services

Item {
    id: root

    required property var list
    readonly property string query: list.search.text.slice(1)

    // idle | loading | done | error
    property string previewState: "idle"
    property string previewText: ""
    property string plainAnswerText: ""

    function onClicked(): void {
        if (root.query.length === 0)
            return;

        Quickshell.execDetached(["xdg-open", `https://www.google.com/search?q=${encodeURIComponent(root.query)}`]);
        root.list.screenState.launcher = false;
    }

    function copyAnswer(): void {
        if (root.plainAnswerText.length === 0)
            return;
        Quickshell.execDetached(["wl-copy", root.plainAnswerText]);
    }

    function escapeHtml(text: string): string {
        return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
    }

    function escapeAttr(text: string): string {
        return root.escapeHtml(text).replace(/"/g, "&quot;");
    }

    // Turns Exa's "...fact [1]..." citation markers into real links to the
    // matching citation URL, instead of stripping them out
    function formatAnswer(answer: string, citations: var): string {
        // textFormat is Text.StyledText (rich text), which ignores raw
        // newlines - without converting them to <br>, Exa's line-separated
        // structure (bullet points, numbered lists) collapses into one
        // run-on paragraph.
        const escaped = root.escapeHtml(answer).replace(/\n/g, "<br>");
        return escaped.replace(/\[(\d+)\]/g, (match, n) => {
            const citation = citations[Number(n) - 1];
            if (!citation?.url)
                return "";
            return ` <a href="${root.escapeAttr(citation.url)}">[${n}]</a>`;
        });
    }

    function applyAnswer(query: string, answer: string, citations: var): void {
        if (query !== root.query)
            return; // stale - a newer query has since replaced this one

        root.plainAnswerText = answer;
        root.previewText = root.formatAnswer(answer, citations);
        root.previewState = "done";
        ExaCache.set(query, answer, citations);
    }

    function fetchPreview(): void {
        const query = root.query;

        if (query.length === 0) {
            root.previewState = "idle";
            root.previewText = "";
            return;
        }

        // No key in ~/.config/caelestia/.env - skip the preview entirely
        if (Secrets.exaApiKey.length === 0) {
            root.previewState = "idle";
            root.previewText = "";
            return;
        }

        const cached = ExaCache.get(query);
        if (cached) {
            root.applyAnswer(query, cached.answer, cached.citations);
            return;
        }

        root.previewState = "loading";

        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return;

            // A newer query has since taken over - this response is stale
            if (query !== root.query)
                return;

            if (xhr.status === 200) {
                try {
                    const data = JSON.parse(xhr.responseText);
                    root.applyAnswer(query, data.answer || "", data.citations || []);
                } catch (e) {
                    root.previewState = "error";
                }
            } else {
                root.previewState = "error";
            }
        };
        xhr.open("POST", "https://api.exa.ai/answer");
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.setRequestHeader("x-api-key", Secrets.exaApiKey);
        xhr.send(JSON.stringify({ query, text: false }));
    }

    Timer {
        id: debounce
        interval: 1500
        onTriggered: root.fetchPreview()
    }

    onQueryChanged: debounce.restart()

    implicitHeight: content.implicitHeight + Tokens.padding.medium * 2

    anchors.left: parent?.left
    anchors.right: parent?.right

    StateLayer {
        radius: Tokens.rounding.large
        onClicked: root.onClicked()
    }

    ColumnLayout {
        id: content

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Tokens.padding.medium

        spacing: Tokens.spacing.small

        RowLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.medium

            MaterialIcon {
                text: "travel_explore"
                fontStyle: Tokens.font.icon.extraLarge
                Layout.alignment: Qt.AlignVCenter
            }

            StyledText {
                color: root.query.length > 0 ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant
                text: root.query.length > 0 ? Tr.tr("Search Google for “%1”").arg(root.query) : Tr.tr("Type a search query")
                elide: Text.ElideRight

                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
            }

            Item {
                visible: root.previewState === "done" && root.plainAnswerText.length > 0

                implicitWidth: Tokens.sizes.launcher.itemHeight * 0.5
                implicitHeight: implicitWidth

                Layout.alignment: Qt.AlignVCenter

                StateLayer {
                    radius: Tokens.rounding.large
                    onClicked: root.copyAnswer()
                }

                MaterialIcon {
                    anchors.centerIn: parent
                    text: "content_copy"
                    color: Colours.palette.m3onSurfaceVariant
                    fontStyle: Tokens.font.icon.large
                }
            }
        }

        StyledText {
            visible: root.previewState === "loading"
            text: Tr.tr("Loading preview…")
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.medium

            Layout.fillWidth: true
            Layout.leftMargin: Tokens.padding.large + Tokens.spacing.medium
        }

        StyledText {
            visible: root.previewState === "error"
            text: Tr.tr("Couldn't load preview")
            color: Colours.palette.m3error
            font: Tokens.font.body.medium

            Layout.fillWidth: true
            Layout.leftMargin: Tokens.padding.large + Tokens.spacing.medium
        }

        StyledText {
            visible: root.previewState === "done" && root.previewText.length > 0
            text: root.previewText
            textFormat: Text.StyledText
            linkColor: Colours.palette.m3primary
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.medium
            wrapMode: Text.Wrap

            // Citation URLs come from the remote response - only open web links
            onLinkActivated: link => {
                if (/^https?:\/\//i.test(link))
                    Quickshell.execDetached(["xdg-open", link]);
            }

            Layout.fillWidth: true
            Layout.leftMargin: Tokens.padding.large + Tokens.spacing.medium
        }
    }
}
