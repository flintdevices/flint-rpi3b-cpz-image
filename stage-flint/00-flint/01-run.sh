#!/bin/bash -e
# Patch config.txt and set up SSH + Wi-Fi placeholder for RPi 3B+ flint image.

CONFIG="${ROOTFS_DIR}/boot/firmware/config.txt"
CMDLINE="${ROOTFS_DIR}/boot/firmware/cmdline.txt"
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

# stage2/05-cardputerzero installs a U-Boot built for the real CardputerZero's
# Compute Module (BCM2835/CM0) and points config.txt at it via `kernel=`. That
# chain-loads on a Compute Module; on a plain RPi 3B+ (BCM2837) it's the wrong
# SoC entirely — the board resets before Linux (or any video output) ever
# starts. Strip the directive and the U-Boot binaries so the firmware falls
# back to its normal kernel8.img/auto-detected arm64 kernel boot path.
sed -i '/^kernel=u-boot/d' "${CONFIG}"
rm -f "${ROOTFS_DIR}/boot/firmware/u-boot.bin" \
      "${ROOTFS_DIR}/boot/firmware/u-boot-nolog.bin"

# Same source also adds overlays for CardputerZero-v3 hardware this board
# doesn't have (battery gauge, speaker, IMU, camera, IR); loading them here
# is at best a no-op, at worst a GPIO/bus conflict with our own overlay.
sed -i '/^dtoverlay=bq27220_v3/d'                 "${CONFIG}"
sed -i '/^dtoverlay=spk-gpio24-high-overlay/d'    "${CONFIG}"
sed -i '/^dtoverlay=bmi270_overlay/d'             "${CONFIG}"
sed -i '/^dtoverlay=camera-gpio16-high-overlay/d' "${CONFIG}"
sed -i '/^dtoverlay=gpio-ir,/d'                   "${CONFIG}"
sed -i '/^dtoverlay=gpio-ir-tx,/d'                "${CONFIG}"

# `fbcon=map:off` (added by the same stage2 script) blanks the kernel text
# console on every framebuffer, including HDMI — drop it so HDMI shows the
# normal boot/login console. Also drop `quiet` so a real display shows what's
# happening instead of a blank screen during boot.
sed -i 's/ fbcon=map:off//; s/ quiet//' "${CMDLINE}"

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
