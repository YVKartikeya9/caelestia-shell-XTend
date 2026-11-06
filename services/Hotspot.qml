pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.I18n

// A thin wrapper around assets/hotspot-toggle.sh (bundled with the shell
// config rather than living in ~/.local/bin, so the config has no external
// script dependency) - it already handles interface/channel detection and
// create_ap cleanup; the root part goes through the root-owned helper
// /usr/local/bin/caelestia-hotspot, whose start/stop are the only commands
// allowed without a password (/etc/sudoers.d/caelestia-hotspot). This singleton
// just gives the popout toggle and the Hyprland keybind (which points at
// this same bundled script) a single source of truth: status is read via
// an unprivileged `pgrep -x hostapd`, so it reflects reality regardless of
// which one last started or stopped it.
Singleton {
    id: root

    readonly property string toggleScript: Quickshell.shellPath("assets/hotspot-toggle.sh")

    property bool active: false
    // SSID and password live in ~/.config/caelestia/.env (HOTSPOT_SSID,
    // HOTSPOT_PASS), which the toggle script also sources
    readonly property string ssid: Secrets.hotspotSsid || "caelestia"
    readonly property string password: Secrets.hotspotPassword
    property bool busy: false
    property list<var> clients: []
    readonly property int clientCount: clients.length

    readonly property string qrPath: `${Quickshell.env("XDG_RUNTIME_DIR") || "/tmp"}/caelestia-hotspot-qr.png`

    // Auto-disable after no devices have been connected for this long
    readonly property int idleTimeoutMs: 10 * 60 * 1000
    // 0 means "not currently idle" - set the moment clientCount drops to 0,
    // cleared the moment it goes back above 0
    property real idleSince: 0

    // Keeps active/clients fresh in the background (e.g. for the idle
    // check below) even while nobody has the network popout open - this
    // singleton is eagerly loaded from ServiceLoader.qml specifically so
    // this timer is always running whenever the hotspot actually is.
    Timer {
        id: idleCheckTimer

        interval: 30000
        repeat: true
        triggeredOnStart: true
        running: root.active

        onTriggered: root.refreshStatus(() => root.checkIdle())
    }

    function checkIdle(): void {
        if (!root.active || root.clientCount > 0) {
            root.idleSince = 0;
            return;
        }

        if (root.idleSince === 0) {
            root.idleSince = Date.now();
            return;
        }

        if (Date.now() - root.idleSince >= root.idleTimeoutMs) {
            root.idleSince = 0;
            Quickshell.execDetached(["notify-send", "-u", "normal", "-i", "network-wireless-disabled", "Hotspot", "Turned off automatically - no devices connected for 10 minutes"]);
            root.toggle(() => {});
        }
    }

    function refreshStatus(callback: var): void {
        if (statusProc.running)
            return;
        statusProc.callback = callback;
        statusProc.running = true;
    }

    function toggle(callback: var): void {
        if (toggleProc.running)
            return;
        root.busy = true;
        toggleProc.wasActive = root.active;
        toggleProc.callback = callback;
        toggleProc.running = true;
    }

    // Escaping for the WIFI: QR code format (ZXing convention): backslash,
    // semicolon, comma, double-quote and colon are all field separators or
    // otherwise significant, and need a literal backslash in front of them.
    function escapeWifiQr(s: string): string {
        return s.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/"/g, "\\\"").replace(/:/g, "\\:");
    }

    function generateQr(callback: var): void {
        if (!root.ssid) {
            if (callback)
                callback({
                    success: false,
                    error: Tr.tr("No SSID available")
                });
            return;
        }

        // Field order (S, T, P, H) matches Android's own "share Wi-Fi via QR"
        // generator - some phone camera parsers are strict about this order
        // and silently fall back to plain text/"create a QR from this" if it
        // doesn't match, rather than offering to join the network.
        const security = root.password.length > 0 ? "WPA" : "nopass";
        const escSsid = root.escapeWifiQr(root.ssid);
        const qrString = root.password.length > 0 ? `WIFI:S:${escSsid};T:${security};P:${root.escapeWifiQr(root.password)};H:false;;` : `WIFI:S:${escSsid};T:nopass;H:false;;`;

        qrProc.callback = callback;
        qrProc.command = ["qrencode", "-o", root.qrPath, "-s", "8", "-m", "2", qrString];
        qrProc.running = true;
    }

    // The password lives in ~/.config/caelestia/.env, which the script
    // sources at startup - so the keybind and this toggle still share one
    // source of truth without the secret sitting in the shell source.
    function setPassword(newPassword: string, callback: var): void {
        if (newPassword.length < 8 || newPassword.length > 63) {
            if (callback)
                callback({
                    success: false,
                    error: Tr.tr("Password must be 8-63 characters")
                });
            return;
        }

        Secrets.set("HOTSPOT_PASS", newPassword);

        if (callback)
            callback({
                success: true
            });
    }

    Process {
        id: qrProc

        property var callback: null

        stderr: StdioCollector {
            id: qrErr
        }

        onExited: code => { // qmllint disable signal-handler-parameters
            if (qrProc.callback)
                qrProc.callback({
                    success: code === 0,
                    path: root.qrPath,
                    error: qrErr.text.trim()
                });
        }
    }

    Component.onCompleted: root.refreshStatus(() => {})

    // hostapd is the actual ground truth for "is a hotspot broadcasting" -
    // create_ap's own supervisor process can die independently (observed:
    // orphaned hostapd left running with no create_ap process at all), so
    // checking for create_ap itself can report "off" while it's still on
    Process {
        id: statusProc

        property var callback: null

        command: ["pgrep", "-x", "hostapd"]

        onExited: code => { // qmllint disable signal-handler-parameters
            root.active = code === 0;

            if (!root.active) {
                root.clients = [];
                if (statusProc.callback)
                    statusProc.callback(false);
                return;
            }

            apIfaceProc.callback = statusProc.callback;
            apIfaceProc.running = true;
        }
    }

    // Reading client info no longer goes through `create_ap --list-clients`
    // at all - that needs create_ap's own pid, which (observed twice now)
    // can disappear on its own while hostapd keeps running fine as an
    // orphan, silently losing the client list. Instead this reads the same
    // ground truth create_ap itself reads: the kernel's station table
    // (unprivileged) and dnsmasq's lease file, matched by MAC - neither
    // depends on create_ap's own process still being alive.

    // Find the virtual AP interface(s) create_ap created (named ap0, ap1,
    // ... by convention - the same one hotspot-toggle's own cleanup already
    // greps for)
    Process {
        id: apIfaceProc

        property var callback: null

        command: ["ip", "-br", "link"]

        stdout: StdioCollector {
            id: apIfaceOut
        }

        onExited: code => { // qmllint disable signal-handler-parameters
            const ifaces = code === 0 ? apIfaceOut.text.split("\n").map(line => line.trim().split(/\s+/)[0]).filter(name => /^ap[0-9]+$/.test(name ?? "")) : [];

            if (ifaces.length === 0) {
                root.clients = [];
                if (apIfaceProc.callback)
                    apIfaceProc.callback(true);
                return;
            }

            stationDumpProc.callback = apIfaceProc.callback;
            stationDumpProc.command = ["iw", "dev", ifaces[0], "station", "dump"];
            stationDumpProc.running = true;
        }
    }

    Process {
        id: stationDumpProc

        property var callback: null

        stdout: StdioCollector {
            id: stationOut
        }

        onExited: code => { // qmllint disable signal-handler-parameters
            // Walk line-by-line rather than a lazy multiline regex - this
            // engine has already shown it doesn't support some standard JS
            // regex/String features (matchAll), so favour the simplest thing
            // that works. rx/tx bytes are cumulative totals since the device
            // associated - "how much data has it used", not a live rate.
            const stations = [];
            if (code === 0) {
                let current = null;
                for (const line of stationOut.text.split("\n")) {
                    const stationMatch = line.match(/^Station ([0-9a-fA-F:]{17})/);
                    if (stationMatch) {
                        current = {
                            mac: stationMatch[1].toLowerCase(),
                            rxBytes: 0,
                            txBytes: 0
                        };
                        stations.push(current);
                        continue;
                    }
                    if (!current)
                        continue;

                    const rxMatch = line.match(/rx bytes:\s*(\d+)/);
                    if (rxMatch)
                        current.rxBytes = parseInt(rxMatch[1], 10);

                    const txMatch = line.match(/tx bytes:\s*(\d+)/);
                    if (txMatch)
                        current.txBytes = parseInt(txMatch[1], 10);
                }
            }

            if (stations.length === 0) {
                root.clients = [];
                if (stationDumpProc.callback)
                    stationDumpProc.callback(true);
                return;
            }

            leasesProc.callback = stationDumpProc.callback;
            leasesProc.stations = stations;
            leasesProc.running = true;
        }
    }

    // dnsmasq.leases lines: "<timestamp> <mac> <ip> <hostname> <clientid>" -
    // hostname is "*" when the client didn't send one. Needs a shell only
    // for the glob (the confdir name is randomised per run).
    Process {
        id: leasesProc

        property var callback: null
        property var stations: []

        command: ["sh", "-c", "cat /tmp/create_ap.*/dnsmasq.leases 2>/dev/null"]

        stdout: StdioCollector {
            id: leasesOut
        }

        onExited: code => { // qmllint disable signal-handler-parameters
            const byMac = {};
            for (const line of leasesOut.text.split("\n")) {
                const parts = line.trim().split(/\s+/);
                if (parts.length < 4)
                    continue;
                const mac = parts[1]?.toLowerCase();
                if (!mac)
                    continue;
                byMac[mac] = {
                    ip: parts[2] ?? "",
                    hostname: parts[3] ?? ""
                };
            }

            root.clients = leasesProc.stations.map(station => {
                const info = byMac[station.mac] ?? {
                    ip: "",
                    hostname: ""
                };
                return {
                    ip: info.ip,
                    hostname: info.hostname && info.hostname !== "*" ? info.hostname : "",
                    rxBytes: station.rxBytes,
                    txBytes: station.txBytes
                };
            });

            if (leasesProc.callback)
                leasesProc.callback(true);
        }
    }

    Process {
        id: toggleProc

        property bool wasActive: false
        property var callback: null

        command: [root.toggleScript]

        onExited: code => { // qmllint disable signal-handler-parameters
            root.refreshStatus(() => {
                // The stop path signals the running instance and returns
                // before teardown actually finishes (killing hostapd/dnsmasq,
                // removing the virtual interface) - if status still hasn't
                // budged, give it one short beat to settle before trusting it
                if (root.active === toggleProc.wasActive) {
                    settleTimer.exitCode = code;
                    settleTimer.callback = toggleProc.callback;
                    settleTimer.restart();
                    return;
                }

                root.busy = false;
                if (toggleProc.callback)
                    toggleProc.callback({
                        success: code === 0
                    });
            });
        }
    }

    Timer {
        id: settleTimer

        property int exitCode: 0
        property var callback: null

        interval: 700

        onTriggered: root.refreshStatus(() => {
            root.busy = false;
            if (settleTimer.callback)
                settleTimer.callback({
                    success: settleTimer.exitCode === 0
                });
        })
    }
}
