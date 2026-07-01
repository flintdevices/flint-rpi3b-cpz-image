#!/bin/bash -e
# Patch config.txt and set up SSH + Wi-Fi placeholder for RPi 3B+ flint image.

CONFIG="${ROOTFS_DIR}/boot/firmware/config.txt"
OVERLAYS_DST="${ROOTFS_DIR}/boot/firmware/overlays"

# ── 1. Install the custom DTS overlay ────────────────────────────────────────
install -d "${OVERLAYS_DST}"
cp "${STAGE_DIR}/../overlays/rpi3b-flint-overlay.dtbo" "${OVERLAYS_DST}/"

# ── 2. Patch config.txt ───────────────────────────────────────────────────────
# Remove lines we're replacing so we can append a clean block.
sed -i '/^dtparam=i2c_arm/d'         "${CONFIG}"
sed -i '/^dtparam=i2s/d'             "${CONFIG}"
sed -i '/^dtparam=spi/d'             "${CONFIG}"
sed -i '/^dtparam=audio/d'           "${CONFIG}"
sed -i '/^dtoverlay=cardputerzero/d' "${CONFIG}"
sed -i '/^arm_boost/d'               "${CONFIG}"
sed -i '/^camera_auto_detect/d'      "${CONFIG}"
sed -i '/^dtoverlay=imx219/d'        "${CONFIG}"

# Append RPi 3B+ flint block
cat >> "${CONFIG}" << 'EOF'

# ── flint RPi 3B+ configuration ──────────────────────────────────────────────
dtparam=i2c_arm=on
dtparam=i2s=on
dtparam=spi=on

# ST7789V 320×170 via SPI0 — custom overlay (GPIO27=RST, GPIO25=DC, GPIO8=CS)
dtoverlay=rpi3b-flint-overlay

# GPU / DRM
dtoverlay=vc4-kms-v3d
max_framebuffers=2
disable_fw_kms_setup=1

# System
arm_64bit=1
disable_overscan=1
EOF

# ── 3. SSH ────────────────────────────────────────────────────────────────────
# pi-gen honours ENABLE_SSH in config, but we set the sentinel file explicitly
# so it survives any stage ordering differences.
touch "${ROOTFS_DIR}/boot/firmware/ssh"

# ── 4. Wi-Fi placeholder file (editable before first boot) ───────────────────
cat > "${ROOTFS_DIR}/boot/firmware/wifi.txt" << 'EOF'
# Edit this file before first boot to configure Wi-Fi.
# Remove the leading # from the lines below and fill in your credentials.
#
# WIFI_SSID=YourNetworkName
# WIFI_PASSWORD=YourPassword
EOF

# Install a first-boot service that reads wifi.txt and writes wpa_supplicant
install -m 644 "${STAGE_DIR}/files/flint-wifi-setup.service" \
    "${ROOTFS_DIR}/etc/systemd/system/flint-wifi-setup.service"

install -m 755 "${STAGE_DIR}/files/flint-wifi-setup.sh" \
    "${ROOTFS_DIR}/usr/local/sbin/flint-wifi-setup.sh"

on_chroot << 'CHROOT'
systemctl enable flint-wifi-setup.service
CHROOT
