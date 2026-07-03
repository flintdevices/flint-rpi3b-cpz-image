#!/bin/bash
# Reads /boot/firmware/wifi.txt on first boot and configures Wi-Fi via
# NetworkManager. ConditionPathExists in the unit re-evaluates on every boot,
# so this keeps retrying on subsequent boots until it actually connects —
# only then does it scrub credentials and disable itself.

WIFI_FILE="/boot/firmware/wifi.txt"

if [ ! -f "${WIFI_FILE}" ]; then
    exit 0
fi

SSID=$(grep -E '^\s*WIFI_SSID=' "${WIFI_FILE}" | cut -d= -f2- | tr -d '[:space:]')
PASS=$(grep -E '^\s*WIFI_PASSWORD=' "${WIFI_FILE}" | cut -d= -f2- | tr -d '[:space:]')

if [ -z "${SSID}" ]; then
    exit 0
fi

# stage2/05-cardputerzero blocks all radios by default at the kernel level
# (rfkill default_state=0). NetworkManager also persists its own software
# radio toggle across reboots (separate from kernel rfkill) and can come up
# with Wi-Fi off if it observed the radio blocked during an earlier boot —
# unblocking rfkill alone isn't enough to get NetworkManager to use it.
rfkill unblock wifi || true
nmcli radio wifi on || true

# Right after unblocking, wlan0 can briefly report as unavailable while
# NetworkManager finishes bringing the device under management — wait for a
# manageable state before attempting to connect instead of racing it.
for _ in $(seq 1 15); do
    STATE=$(nmcli -t -f DEVICE,STATE device status 2>/dev/null | awk -F: '$1=="wlan0"{print $2}')
    case "${STATE}" in
        disconnected|disconnecting|connecting|connected) break ;;
    esac
    sleep 1
done

# NetworkManager is this image's actual network stack (not wpa_supplicant/
# dhclient directly) — nmcli handles associating and DHCP in one step, and
# stores the resulting connection profile so it reconnects on future boots
# without this script running again. Retry a few times: even once
# "manageable", the radio/device can take a moment to settle right after
# boot.
CONNECTED=0
for _ in $(seq 1 5); do
    if nmcli device wifi connect "${SSID}" password "${PASS}"; then
        CONNECTED=1
        break
    fi
    sleep 3
done

if [ "${CONNECTED}" -ne 1 ]; then
    logger -t flint-wifi-setup "failed to connect to ${SSID}; will retry on next boot"
    exit 1
fi

# Only scrub credentials and disable this service once the connection is
# confirmed — doing this unconditionally (as before) meant a transient
# failure (e.g. NetworkManager not ready yet) silently burned the one shot
# at using wifi.txt, with no way to retry.
sed -i '/^\s*WIFI_SSID=/d; /^\s*WIFI_PASSWORD=/d' "${WIFI_FILE}"
systemctl disable flint-wifi-setup.service
