#!/usr/bin/env bash

# Detect wireless interface
WIFI_IFACE=$(ip -br link | grep -E '^(wl)' | awk '{print $1}' | head -n 1)

# Check if create_ap process is running
PID=$(pgrep -f "/usr/bin/create_ap" | head -n 1)

if [ -z "$PID" ]; then
    qs -c caelestia ipc call toaster info "Hotspot Status" "Hotspot is OFF" "wifi_off"
    exit 0
fi

# Query connected clients from create_ap
CLIENT_LIST=$(sudo create_ap --list-clients "$PID" 2>/dev/null | grep -E '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}')
COUNT=$(echo "$CLIENT_LIST" | grep -v '^$' | wc -l)
INTERNET_IFACE=$(ip route | grep '^default' | awk '{print $5}' | head -n 1)

if [ "$COUNT" -eq 0 ]; then
    qs -c caelestia ipc call toaster success "Hotspot Status: ON" "No connected devices · Sharing: ${INTERNET_IFACE:-$WIFI_IFACE}" "wifi_tethering"
else
    # Flatten the client MAC/IP list onto one line - toasts don't wrap/multiline
    FORMATTED_CLIENTS=$(echo "$CLIENT_LIST" | awk '{print $1" ("$2")"}' | paste -sd', ')
    qs -c caelestia ipc call toaster success "Hotspot Status: ON" "${COUNT} device(s) connected: ${FORMATTED_CLIENTS} · Sharing: ${INTERNET_IFACE:-$WIFI_IFACE}" "wifi_tethering"
fi
