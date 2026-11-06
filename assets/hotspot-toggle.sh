#!/usr/bin/env bash
# Toggles the Wi-Fi hotspot. Everything that needs root (create_ap, hostapd,
# cleanup) is done by /usr/local/bin/caelestia-hotspot, the only command the
# hotspot may run with sudo (start|stop, see /etc/sudoers.d/caelestia-hotspot,
# both set up by caelestia-XTend's install.py).

HELPER=/usr/local/bin/caelestia-hotspot
LOG=/run/caelestia-hotspot/create_ap.log

# SSID and password live in ~/.config/caelestia/.env (HOTSPOT_SSID="...",
# HOTSPOT_PASS="..."), kept out of this script so they aren't in the shell source
ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/caelestia/.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
HOTSPOT_SSID="${HOTSPOT_SSID:-caelestia}"

toast() {
    qs -c caelestia ipc call toaster "$@" >/dev/null 2>&1
}

if [ ! -x "$HELPER" ]; then
    toast error "Hotspot Error" "Helper not installed; run caelestia-XTend's ./install.py --features hotspot" "wifi_off"
    exit 1
fi

# If already running -> STOP IT
if pgrep -x hostapd >/dev/null || pgrep -f '^(/usr/bin/)?bash /usr/bin/create_ap( |$)' >/dev/null; then
    sudo -n "$HELPER" stop
    toast info "Hotspot" "Wi-Fi Hotspot Stopped" "wifi_tethering_off"
    exit 0
fi

if [ -z "$HOTSPOT_PASS" ]; then
    toast error "Hotspot Error" "No HOTSPOT_PASS in ${ENV_FILE}" "wifi_off"
    exit 1
fi

toast info "Hotspot" "Starting Hotspot..." "wifi_tethering"

# The name and password go in on stdin, so they never show up in ps
ERR="${XDG_RUNTIME_DIR:-/tmp}/caelestia-hotspot.err"
if ! INTERNET_IFACE=$(printf '%s\n%s\n' "$HOTSPOT_SSID" "$HOTSPOT_PASS" | sudo -n "$HELPER" start 2>"$ERR"); then
    toast error "Hotspot Error" "$(head -c 200 "$ERR")" "wifi_off"
    exit 1
fi

# Verify startup - poll, since the full NetworkManager/iw/hostapd bring-up
# can take a few seconds
STARTED=0
for i in $(seq 1 16); do
    sleep 0.5
    if pgrep -x hostapd >/dev/null; then
        STARTED=1
        break
    fi
done

if [ "$STARTED" -eq 1 ]; then
    toast success "Hotspot Active" "SSID: ${HOTSPOT_SSID} · Sharing: ${INTERNET_IFACE}" "wifi_tethering"
else
    toast error "Hotspot Error" "Failed to start. Check ${LOG}" "error"
fi
