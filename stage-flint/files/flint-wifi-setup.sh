#!/bin/bash
# Reads /boot/firmware/wifi.txt on first boot and configures Wi-Fi via
# NetworkManager. Runs once via systemd, then disables itself.

WIFI_FILE="/boot/firmware/wifi.txt"

if [ ! -f "${WIFI_FILE}" ]; then
    exit 0
fi

SSID=$(grep -E '^\s*WIFI_SSID=' "${WIFI_FILE}" | cut -d= -f2- | tr -d '[:space:]')
PASS=$(grep -E '^\s*WIFI_PASSWORD=' "${WIFI_FILE}" | cut -d= -f2- | tr -d '[:space:]')

if [ -z "${SSID}" ]; then
    exit 0
fi

# Remove credentials from the boot partition after applying
sed -i '/^WIFI_SSID=/d; /^WIFI_PASSWORD=/d' "${WIFI_FILE}"

# Disable this service so it never runs again
systemctl disable flint-wifi-setup.service

# stage2/05-cardputerzero blocks all radios by default at the kernel level
# (rfkill default_state=0). NetworkManager also persists its own software
# radio toggle across reboots (separate from kernel rfkill) and can come up
# with Wi-Fi off if it observed the radio blocked during an earlier boot —
# unblocking rfkill alone isn't enough to get NetworkManager to use it.
rfkill unblock wifi || true
nmcli radio wifi on || true

# NetworkManager is this image's actual network stack (not wpa_supplicant/
# dhclient directly) — nmcli handles associating and DHCP in one step, and
# stores the resulting connection profile so it reconnects on future boots
# without this script running again.
nmcli device wifi connect "${SSID}" password "${PASS}" || true
