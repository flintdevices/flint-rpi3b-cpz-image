#!/bin/bash
# Reads /boot/firmware/wifi.txt on first boot and writes wpa_supplicant.conf.
# Runs once via systemd, then disables itself.

WIFI_FILE="/boot/firmware/wifi.txt"
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant.conf"

if [ ! -f "${WIFI_FILE}" ]; then
    exit 0
fi

SSID=$(grep -E '^\s*WIFI_SSID=' "${WIFI_FILE}" | cut -d= -f2- | tr -d '[:space:]')
PASS=$(grep -E '^\s*WIFI_PASSWORD=' "${WIFI_FILE}" | cut -d= -f2- | tr -d '[:space:]')

if [ -z "${SSID}" ]; then
    exit 0
fi

cat > "${WPA_CONF}" << EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=GB

network={
    ssid="${SSID}"
    psk="${PASS}"
    key_mgmt=WPA-PSK
}
EOF

chmod 600 "${WPA_CONF}"

# Remove credentials from the boot partition after applying
sed -i '/^WIFI_SSID=/d; /^WIFI_PASSWORD=/d' "${WIFI_FILE}"

# Disable this service so it never runs again
systemctl disable flint-wifi-setup.service

rfkill unblock wifi || true
wpa_supplicant -B -i wlan0 -c "${WPA_CONF}" || true
dhclient wlan0 || true
