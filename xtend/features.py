"""What each XTend feature adds to a caelestia shell (v2.5.0).

`files` are copied from this repo as-is (they're new to caelestia). `ops` are
anchored edits to caelestia's own files (see engine.py). Hidden features are
shared building blocks, pulled in by `requires` and removed with their last
dependent.
"""

from dataclasses import dataclass, field
from pathlib import Path

from .engine import Insert, Replace

BLOCKS = Path(__file__).resolve().parent / "blocks"


@dataclass
class Feature:
    name: str
    title: str
    summary: str
    files: list = field(default_factory=list)
    ops: list = field(default_factory=list)
    requires: list = field(default_factory=list)
    packages: list = field(default_factory=list)  # official repos
    aur: list = field(default_factory=list)
    default: bool = True
    hidden: bool = False
    notes: list = field(default_factory=list)


CW = "modules/drawers/ContentWindow.qml"
PANELS = "modules/drawers/Panels.qml"
REGIONS = "modules/drawers/Regions.qml"
STATE = "components/ScreenState.qml"
APPLIST = "modules/launcher/AppList.qml"
LAUNCHER = "modules/launcher/Content.qml"

# Upstream anchors shared by several features (each feature inserts its own lines)
A_STATE = "    property bool sidebar"
A_PANEL_IMPORTS = "import qs.modules.utilities.toasts as Toasts"
A_PANEL_ALIASES = "    readonly property alias sidebar: sidebar"
A_PANEL_ITEMS = "    Toasts.Toasts {"
A_REGIONS = "    component R: Region {"
A_GRAB = "            if (!conf.dashboard.showOnHover && s.dashboard && conf.dashboard.enabled)"
A_CLOSE = "            root.screenState.dashboard = false;"
A_STATE_FOR_TEXT = "    function stateForText(text: string): string {"
A_RESULTS_DEFAULT = "        default:\n            return Apps.search(text);"
A_LAST_STATE = "                root.delegate: variantItem\n            }\n        }"
A_COMPONENTS = "    Connections {\n        function onTextChanged() {"
A_ACCEPT = "                } else if (text.startsWith(GlobalConfig.launcher.actionPrefix)) {"
A_HINTS = "            // xtend:launcher-hints"


def region(name):
    return f"""    R {{
        panel: root.panels.{name}
        width: panel.width * (1 - root.panels.{name}.offsetScale)
        height: panel.height * (1 - root.panels.{name}.offsetScale)
    }}
"""


def grab(state):
    return f"""            if (s.{state})
                return true;"""


FEATURES = [
    Feature(
        name="secrets",
        title="Secrets",
        summary="Reads settings and keys from ~/.config/caelestia/.env",
        files=["services/Secrets.qml"],
        hidden=True,
    ),
    Feature(
        name="launcher-hints",
        title="Launcher hints",
        summary="Lets features add their prefixes to the launcher's placeholder text",
        hidden=True,
        ops=[
            Replace(
                LAUNCHER,
                '        placeholderText: Tr.tr("Type \\"%1\\" for commands").arg(GlobalConfig.launcher.actionPrefix)',
                '        placeholderText: {\n'
                '            const hints = [Tr.tr("Type \\"%1\\" for commands").arg(GlobalConfig.launcher.actionPrefix)];\n'
                '            // xtend:launcher-hints\n'
                '            return hints.join(", ");\n'
                '        }',
                marker="            // xtend:launcher-hints\n",
            ),
        ],
    ),
    Feature(
        name="hotspot",
        title="Wi-Fi hotspot + QR code",
        summary="Hotspot toggle, connected devices and a QR code in the network popout",
        requires=["secrets"],
        files=[
            "services/Hotspot.qml",
            "modules/hotspotqr/Content.qml",
            "modules/hotspotqr/Wrapper.qml",
            "assets/hotspot-toggle.sh",
            "assets/hotspot-status.sh",
        ],
        # create_ap needs dnsmasq and iptables to share the connection
        packages=["qrencode", "dnsmasq", "iptables"],
        aur=["create_ap"],
        default=False,
        notes=[
            "Starting a hotspot runs create_ap, ip and iw as root via sudo. XTend doesn't "
            "set that up for you; see the README before turning the hotspot on.",
        ],
        ops=[
            Insert(STATE, A_STATE, "    property bool hotspotQr"),
            # Services load at startup from ServiceLoader.qml (2.5.0) or shell.qml (newer)
            Insert(("modules/ServiceLoader.qml", "shell.qml"), "        Brightness;", "        Hotspot;"),
            Insert(PANELS, A_PANEL_IMPORTS, "import qs.modules.hotspotqr as HotspotQr"),
            Insert(PANELS, A_PANEL_ALIASES, "    readonly property alias hotspotQr: hotspotQr"),
            Insert(PANELS, A_PANEL_ITEMS, """    HotspotQr.Wrapper {
        id: hotspotQr

        screenState: root.screenState

        anchors.centerIn: parent

        z: 100
    }
""", where="before"),
            Insert(REGIONS, A_REGIONS, region("hotspotQr"), where="before"),
            Insert(CW, A_GRAB, grab("hotspotQr"), where="before"),
            Insert(CW, A_CLOSE, "            root.screenState.hotspotQr = false;"),
            Insert("modules/bar/popouts/Network.qml", "import Caelestia.Config", "import Quickshell.Services.Pam", where="before"),
            Insert("modules/bar/popouts/Network.qml", "    property bool showPasswordDialog: false", """
    // "" | "auth" | "edit" - editing the hotspot password is gated behind
    // re-entering your own login password via the same PAM service the lock
    // screen uses, not just a plain click
    property string hotspotEditStage: ""
    property bool hotspotAuthFailed: false
    property bool hotspotPasswordFailed: false

    Component.onCompleted: Hotspot.refreshStatus(() => {})"""),
            Insert("modules/bar/popouts/Network.qml", "    Connections {\n        function onActiveChanged(): void {",
                   (BLOCKS / "hotspot" / "network-section.qml").read_text(), where="before"),
        ],
    ),
    Feature(
        name="cheatsheet",
        title="Keybind cheatsheet",
        summary="Searchable list of your Hyprland keybinds (Super + /)",
        files=[
            "modules/cheatsheet/Content.qml",
            "modules/cheatsheet/Wrapper.qml",
            "scripts/describe-keybinds.py",
            "scripts/keybind-descriptions.json",
        ],
        ops=[
            Insert(STATE, A_STATE, "    property bool cheatsheet"),
            # modules/Shortcuts.qml (2.5.0) moved to daemons/Shortcuts.qml upstream
            Insert(("modules/Shortcuts.qml", "daemons/Shortcuts.qml"), "    IpcHandler {\n        function toggle(drawer: string): void {", """    // qmllint disable unresolved-type
    CustomShortcut {
        // qmllint enable unresolved-type
        name: "cheatsheet"
        description: "Toggle cheatsheet"
        onPressed: {
            if (root.hasFullscreen)
                return;
            const screenState = ShellState.forActive();
            screenState.cheatsheet = !screenState.cheatsheet;
        }
    }
""", where="before"),
            Insert(PANELS, A_PANEL_IMPORTS, "import qs.modules.cheatsheet as Cheatsheet"),
            Insert(PANELS, A_PANEL_ALIASES, "    readonly property alias cheatsheet: cheatsheet"),
            Insert(PANELS, A_PANEL_ITEMS, """    Cheatsheet.Wrapper {
        id: cheatsheet

        screenState: root.screenState

        anchors.centerIn: parent
    }
""", where="before"),
            Insert(REGIONS, A_REGIONS, region("cheatsheet"), where="before"),
            Replace(CW, "screenState.launcher || screenState.session ? WlrKeyboardFocus.OnDemand",
                    "screenState.launcher || screenState.session || screenState.cheatsheet /* xtend:cheatsheet */ ? WlrKeyboardFocus.OnDemand"),
            Insert(CW, A_GRAB, grab("cheatsheet"), where="before"),
            Insert(CW, A_CLOSE, "            root.screenState.cheatsheet = false;"),
        ],
    ),
    Feature(
        name="filesearch",
        title="Launcher file search",
        summary='Find files and folders in your home folder by typing "<" in the launcher',
        requires=["launcher-hints"],
        files=["modules/launcher/services/Files.qml"],
        packages=["plocate", "fd"],
        ops=[
            Insert(APPLIST, "import Caelestia.Config", "import Caelestia.I18n"),
            Insert(APPLIST, A_STATE_FOR_TEXT, """        if (text.startsWith("<"))
            return "find";
"""),
            Insert(APPLIST, A_RESULTS_DEFAULT, """        case "find":
            Files.search(text.slice(1));
            if (Files.searching && Files.results.length === 0)
                return [{ icon: "search", name: Tr.tr("Searching…"), desc: "", onClicked: () => {} }];
            return Files.results;""", where="before"),
            Replace(APPLIST, "        values: root.resultsForText(root.displayText)\n",
                    "        values: {\n            void Files.results; // xtend:filesearch - re-evaluate as async results arrive\n"
                    "            return root.resultsForText(root.displayText);\n        }\n"),
            Insert(APPLIST, "            Schemes.reload();", """        if (state !== "find")
            Files.reset();"""),
            Insert(APPLIST, A_LAST_STATE, """        State {
            name: "find"

            PropertyChanges {
                root.delegate: findItem
            }
        }""", inline=True, prefix=","),
            Insert(APPLIST, A_COMPONENTS, """    Component {
        id: findItem

        ActionItem {
            list: root
        }
    }
""", where="before"),
            Insert(LAUNCHER, A_HINTS, '            hints.push(Tr.tr("\\"<\\" to find files"));'),
            Insert(LAUNCHER, A_ACCEPT, """                } else if (text.startsWith("<")) {
                    currentItem.modelData.onClicked(list.currentList);""", where="before"),
            # Result rows: highlight the match and add an "open folder" button
            Insert("modules/launcher/items/ActionItem.qml", "    required property var list", """
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

        const lower = text.toLowerCase();
        const q = query.toLowerCase();
        const idx = lower.indexOf(q);
        if (idx === -1) {
            // Fuzzy (in-order) match: bold each matched character
            let out = "";
            let qi = 0;
            for (let i = 0; i < text.length; i++) {
                const ch = root.escapeHtml(text[i]);
                if (qi < q.length && lower[i] === q[qi]) {
                    out += `<b>${ch}</b>`;
                    qi++;
                } else {
                    out += ch;
                }
            }
            return qi === q.length ? out : root.escapeHtml(text);
        }

        const pre = root.escapeHtml(text.slice(0, idx));
        const match = root.escapeHtml(text.slice(idx, idx + query.length));
        const post = root.escapeHtml(text.slice(idx + query.length));
        return `${pre}<b>${match}</b>${post}`;
    }"""),
            Replace("modules/launcher/items/ActionItem.qml",
                    "            implicitWidth: parent.width - icon.width\n",
                    "            implicitWidth: parent.width - icon.width - (root.hasSecondary ? secondaryButton.width + Tokens.spacing.medium : 0) // xtend:filesearch\n"),
            Replace("modules/launcher/items/ActionItem.qml",
                    '                text: root.modelData?.name ?? ""\n                font: Tokens.font.body.medium\n',
                    '                // xtend:filesearch\n'
                    '                textFormat: root.modelData?.query ? Text.StyledText : Text.PlainText\n'
                    '                text: root.modelData?.query ? root.highlighted(root.modelData?.name ?? "", root.modelData.query) : (root.modelData?.name ?? "")\n'
                    '                font: Tokens.font.body.medium\n\n'
                    '                elide: Text.ElideRight\n'
                    '                width: parent.width\n'
                    '                // xtend:filesearch end\n'),
            Replace("modules/launcher/items/ActionItem.qml",
                    "                elide: Text.ElideRight\n                width: root.width - icon.width - Tokens.rounding.extraLargeIncreased\n",
                    "                elide: Text.ElideMiddle // xtend:filesearch\n                width: parent.width // xtend:filesearch\n"),
            Insert("modules/launcher/items/ActionItem.qml", "                anchors.top: name.bottom\n            }\n        }", """
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
        }"""),
        ],
    ),
    Feature(
        name="google",
        title="Google search + Exa AI preview",
        summary='Search Google by typing "?" in the launcher; optional AI answer preview with an Exa API key',
        requires=["secrets", "launcher-hints"],
        files=["modules/launcher/items/GoogleItem.qml", "modules/launcher/services/ExaCache.qml"],
        notes=[
            "The AI preview only runs if EXA_API_KEY is set in ~/.config/caelestia/.env. "
            "When it is, what you type after \"?\" is sent to api.exa.ai.",
        ],
        ops=[
            Insert(APPLIST, A_STATE_FOR_TEXT, """        if (text.startsWith("?"))
            return "google";
"""),
            Insert(APPLIST, A_RESULTS_DEFAULT, """        case "google":
            return [0]; // single delegate; GoogleItem reads the query itself""", where="before"),
            Replace(APPLIST,
                    "    implicitHeight: (Tokens.sizes.launcher.itemHeight + spacing) * Math.min(Config.launcher.maxShown, count) - spacing\n",
                    "    // xtend:google - GoogleItem grows to fit its preview, so size from the current item\n"
                    "    implicitHeight: ((currentItem?.implicitHeight ?? Tokens.sizes.launcher.itemHeight) + spacing) * Math.min(Config.launcher.maxShown, count) - spacing\n"),
            Insert(APPLIST, A_LAST_STATE, """        State {
            name: "google"

            PropertyChanges {
                root.delegate: googleItem
            }
        }""", inline=True, prefix=","),
            Insert(APPLIST, A_COMPONENTS, """    Component {
        id: googleItem

        GoogleItem {
            list: root
        }
    }
""", where="before"),
            Insert(LAUNCHER, A_HINTS, '            hints.push(Tr.tr("\\"?\\" to search"));'),
            Insert(LAUNCHER, A_ACCEPT, """                } else if (text.startsWith("?")) {
                    currentItem.onClicked();""", where="before"),
        ],
    ),
]

BY_NAME = {f.name: f for f in FEATURES}


def resolve(names):
    """Selected features plus everything they require, in definition order."""
    want = set()

    def add(n):
        if n not in want:
            want.add(n)
            for r in BY_NAME[n].requires:
                add(r)

    for n in names:
        add(n)
    return [f for f in FEATURES if f.name in want]
