pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.utils

// Secrets kept out of the shell source, in ~/.config/caelestia/.env (mode
// 600). The file is also sourced by assets/hotspot-toggle.sh, so values use
// bash double-quote escaping: KEY="value".
Singleton {
    id: root

    readonly property string envPath: `${Paths.config}/.env`

    property string hotspotSsid: ""
    property string hotspotPassword: ""
    property string exaApiKey: ""

    function escapeValue(s: string): string {
        return s.replace(/\\/g, "\\\\").replace(/"/g, "\\\"").replace(/\$/g, "\\$").replace(/`/g, "\\`");
    }

    function unescapeValue(s: string): string {
        return s.replace(/\\(.)/g, (_, c) => c);
    }

    function parse(content: string): void {
        const values = {};
        for (const line of content.split("\n")) {
            const match = line.match(/^([A-Z_][A-Z0-9_]*)="((?:[^"\\]|\\.)*)"\s*$/);
            if (match)
                values[match[1]] = root.unescapeValue(match[2]);
        }

        root.hotspotSsid = values.HOTSPOT_SSID ?? "";
        root.hotspotPassword = values.HOTSPOT_PASS ?? "";
        root.exaApiKey = values.EXA_API_KEY ?? "";
    }

    // Replaces the KEY="..." line in place, or appends one if it's missing.
    // Uses a function replacer so the escaped value's own backslashes/`$`
    // aren't reinterpreted as String.replace replacement patterns.
    function set(name: string, value: string): void {
        const line = `${name}="${root.escapeValue(value)}"`;
        const pattern = new RegExp(`^${name}="(?:[^"\\\\]|\\\\.)*"[ \\t]*$`, "m");
        const content = envFile.text();

        let updated;
        if (pattern.test(content))
            updated = content.replace(pattern, () => line);
        else
            updated = content + (content.length === 0 || content.endsWith("\n") ? "" : "\n") + line + "\n";

        envFile.setText(updated);
        // The file watcher doesn't fire for our own writes
        root.parse(updated);

        // setText() may recreate the file with default permissions
        chmodProc.running = true;
    }

    FileView {
        id: envFile

        path: root.envPath
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.parse(text())
        onLoadFailed: root.parse("")
    }

    Process {
        id: chmodProc

        command: ["chmod", "600", root.envPath]
    }
}
