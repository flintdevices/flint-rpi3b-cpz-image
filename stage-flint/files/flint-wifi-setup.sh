#!/bin/bash
# Reads /boot/firmware/wifi.txt on first boot and configures Wi-Fi via
# NetworkManager. ConditionPathExists in the unit re-evaluates on every boot,
# so this keeps retrying on subsequent boots until it actually connects —
# only then does it scrub credentials and disable itself.

WIFI_FILE="/boot/firmware/wifi.txt"

if [ ! -f "${WIFI_FILE}" ]; then
    exit 0
fi

# Trim only leading/trailing whitespace and a trailing \r (in case wifi.txt
# was edited on Windows) — SSIDs/passwords may legitimately contain internal
# spaces, which `tr -d '[:space:]'` used to silently strip out.
trim() { sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/\r$//'; }
SSID=$(grep -E '^\s*WIFI_SSID=' "${WIFI_FILE}" | cut -d= -f2- | trim)
PASS=$(grep -E '^\s*WIFI_PASSWORD=' "${WIFI_FILE}" | cut -d= -f2- | trim)

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

# wlan0 being "manageable" doesn't mean it can scan yet: NetworkManager's own
# D-Bus activation of wpa_supplicant can itself take several "re-acquiring
# supplicant interface" retries this early in boot (observed up to ~20s across
# 3 retries on real hardware). Attempting to connect before that settles
# always fails with "No network with SSID ... found" even when the network is
# right there, because the scan cache is still empty — not a bad password.
# Poll for the target SSID to actually show up in a (forced) rescan instead of
# guessing a fixed timeout.
FOUND=0
for _ in $(seq 1 20); do
    if nmcli -t -f SSID device wifi list ifname wlan0 --rescan yes 2>/dev/null | grep -qxF "${SSID}"; then
        FOUND=1
        break
    fi
    sleep 2
done
if [ "${FOUND}" -ne 1 ]; then
    logger -t flint-wifi-setup "${SSID} never appeared in a scan; will retry on next boot"
    exit 1
fi

# If a saved connection profile for this SSID already exists (e.g. from a
# previous successful run of this script, or a manual connect), NetworkManager
# auto-activates it on its own well before this service runs. Calling
# `nmcli device wifi connect` again while it's already active reliably fails
# with "802-11-wireless-security.key-mgmt: property is missing" (reproduced on
# real hardware) — nmcli mishandles re-adding a `password` to an
# already-active profile instead of just recognizing it's already connected.
# Without this check the script would fail on *every* subsequent boot forever
# and never reach the scrub-credentials step below.
ACTIVE_SSID=$(nmcli -t -f GENERAL.CONNECTION device show wlan0 2>/dev/null | cut -d: -f2-)

CONNECTED=0
if [ "${ACTIVE_SSID}" = "${SSID}" ]; then
    CONNECTED=1
else
    # NetworkManager is this image's actual network stack (not wpa_supplicant/
    # dhclient directly) — nmcli handles associating and DHCP in one step, and
    # stores the resulting connection profile so it reconnects on future boots
    # without this script running again. Retry a few times: even once the SSID
    # is visible, association/DHCP can still transiently fail.
    for _ in $(seq 1 5); do
        if nmcli device wifi connect "${SSID}" password "${PASS}"; then
            CONNECTED=1
            break
        fi
        sleep 3
    done
fi

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
