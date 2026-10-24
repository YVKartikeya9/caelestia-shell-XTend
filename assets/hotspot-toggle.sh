#!/usr/bin/env bash

# SSID and password live in ~/.config/caelestia/.env (HOTSPOT_SSID="...",
# HOTSPOT_PASS="..."), kept out of this script so they aren't in the shell source
ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/caelestia/.env"
[ -f "$ENV_FILE" ] && source "$ENV_FILE"
HOTSPOT_SSID="${HOTSPOT_SSID:-caelestia}"

# 1. Detect Wi-Fi interface
WIFI_IFACE=$(ip -br link | grep -E '^(wl)' | awk '{print $1}' | head -n 1)

if [ -z "$WIFI_IFACE" ]; then
    qs -c caelestia ipc call toaster error "Hotspot Error" "No wireless interface found!" "wifi_off"
    exit 1
fi

# 2. Cleanup helper function
cleanup_hotspot() {
    sudo create_ap --stop "$WIFI_IFACE" >/dev/null 2>&1
    sudo killall -9 hostapd create_ap dnsmasq 2>/dev/null
    for iface in $(ip -br link | grep -E '^ap[0-9]' | awk '{print $1}'); do
        sudo iw dev "$iface" del 2>/dev/null || sudo ip link delete "$iface" 2>/dev/null
    done
    rm -f /tmp/create_ap.*.pid 2>/dev/null
}

# 3. If already running -> STOP IT
if pgrep hostapd > /dev/null || pgrep -f "create_ap" > /dev/null; then
    cleanup_hotspot
    qs -c caelestia ipc call toaster info "Hotspot" "Wi-Fi Hotspot Stopped" "wifi_tethering_off"
    exit 0
fi

if [ -z "$HOTSPOT_PASS" ]; then
    qs -c caelestia ipc call toaster error "Hotspot Error" "No HOTSPOT_PASS in ${ENV_FILE}" "wifi_off"
    exit 1
fi

# Ensure clean slate before launch
cleanup_hotspot

# 4. Detect upstream internet interface
INTERNET_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n 1)
[ -z "$INTERNET_IFACE" ] && INTERNET_IFACE="$WIFI_IFACE"

# 5. Determine channel and band
EXTRA_ARGS=()
if [ "$INTERNET_IFACE" = "$WIFI_IFACE" ]; then
    CURRENT_CHAN=$(iw dev "$WIFI_IFACE" info 2>/dev/null | awk '/channel/ {print $2}')
    if [ -n "$CURRENT_CHAN" ]; then
        EXTRA_ARGS+=("-c" "$CURRENT_CHAN")
        if [ "$CURRENT_CHAN" -gt 14 ]; then
            EXTRA_ARGS+=("--freq-band" "5")
        else
            EXTRA_ARGS+=("--freq-band" "2.4")
        fi
    fi
fi

qs -c caelestia ipc call toaster info "Hotspot" "Starting Hotspot (Sharing: ${INTERNET_IFACE})..." "wifi_tethering"

# 6. Launch create_ap
nohup sudo create_ap "${EXTRA_ARGS[@]}" "$WIFI_IFACE" "$INTERNET_IFACE" "$HOTSPOT_SSID" "$HOTSPOT_PASS" > /tmp/create_ap.log 2>&1 &

# 7. Verify startup - poll instead of a single fixed-delay check, since the
# full NetworkManager/iw/hostapd bring-up can take longer than a flat 3s
STARTED=0
for i in $(seq 1 16); do
    sleep 0.5
    if pgrep hostapd > /dev/null; then
        STARTED=1
        break
    fi
done

if [ "$STARTED" -eq 1 ]; then
    qs -c caelestia ipc call toaster success "Hotspot Active" "SSID: ${HOTSPOT_SSID} · Sharing: ${INTERNET_IFACE}" "wifi_tethering"
else
    qs -c caelestia ipc call toaster error "Hotspot Error" "Failed to start. Check /tmp/create_ap.log" "error"
fi
