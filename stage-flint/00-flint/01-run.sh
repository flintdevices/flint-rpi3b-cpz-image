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

# Install a first-boot service that reads wifi.txt and configures Wi-Fi via
# NetworkManager (nmcli) — see files/flint-wifi-setup.sh for why not
# wpa_supplicant/dhclient directly.
install -m 644 "${STAGE_DIR}/files/flint-wifi-setup.service" \
    "${ROOTFS_DIR}/etc/systemd/system/flint-wifi-setup.service"

install -m 755 "${STAGE_DIR}/files/flint-wifi-setup.sh" \
    "${ROOTFS_DIR}/usr/local/sbin/flint-wifi-setup.sh"

on_chroot << 'CHROOT'
systemctl enable flint-wifi-setup.service
CHROOT

# ── 5. APPLaunch autostart ────────────────────────────────────────────────────
# stage2/05-cardputerzero enables LaunchWizard.service (WantedBy=multi-user.target)
# to do first-boot setup, including presumably enabling APPLaunch for whichever
# user ends up being created. On this lite/CLI image LaunchWizard can't work at
# all: it (and APPLaunch itself) dynamically link libinput.so.10, which only
# desktop-stack images pull in — without it the exec fails outright (dynamic
# linker error, not a graceful skip), and LaunchWizard.service crash-loops
# forever (RestartSec=1, no StartLimitInterval) instead of ever reaching
# whatever it does to enable APPLaunch for the interactively-created user.
# Disable it and enable APPLaunch globally instead — `--global` applies to
# every current/future user without needing to know the interactive first-boot
# username at build time.
#
# A `--global`-enabled *user* unit only starts once a login session exists for
# that user — confirmed on real hardware: after a clean reboot with nobody
# logged in yet, `APPLaunch.service` simply never started (journalctl showed
# no "Started" line at all until the first SSH login), leaving the display
# black indefinitely. `loginctl enable-linger` is what makes systemd start the
# user's manager (and its enabled units) at boot regardless of login state —
# but `loginctl` itself talks to a running logind over D-Bus, which doesn't
# exist inside the pi-gen chroot. Linger is really just a marker file
# (`/var/lib/systemd/linger/<user>`) that logind checks at boot, so create it
# directly instead.
on_chroot << 'CHROOT'
systemctl disable LaunchWizard.service
systemctl --global enable APPLaunch.service
mkdir -p /var/lib/systemd/linger
touch "/var/lib/systemd/linger/${FIRST_USER_NAME}"
CHROOT

# ── 6. USB keyboard for APPLaunch ─────────────────────────────────────────────
# APPLaunch is hardcoded to the CardputerZero's TCA8418 I2C keyboard node, which
# this board lacks. A udev rule points that exact node at any attached USB
# keyboard as a real DEVLINK so libinput's path backend accepts it. See
# files/99-flint-usb-keyboard.rules for the full rationale and the hotplug caveat.
install -m 644 "${STAGE_DIR}/files/99-flint-usb-keyboard.rules" \
    "${ROOTFS_DIR}/etc/udev/rules.d/99-flint-usb-keyboard.rules"

# flint itself (launched by APPLaunch) auto-detects the TCA8418 keyboard and
# otherwise falls back to the wrong device; point it at the USB keyboard via a
# systemd user drop-in inherited by flint. See files/APPLaunch-flint-keyboard.conf.
install -m 644 -D "${STAGE_DIR}/files/APPLaunch-flint-keyboard.conf" \
    "${ROOTFS_DIR}/etc/systemd/user/APPLaunch.service.d/flint-keyboard.conf"

# APPLaunch defaults to /dev/fb0, which on this board is a boot-order race
# between vc4-kms-v3d (HDMI) and the ST7789 SPI panel — pin it to the stable
# /dev/fb_lcd symlink instead. See files/APPLaunch-framebuffer.conf.
install -m 644 -D "${STAGE_DIR}/files/APPLaunch-framebuffer.conf" \
    "${ROOTFS_DIR}/etc/systemd/user/APPLaunch.service.d/framebuffer.conf"
