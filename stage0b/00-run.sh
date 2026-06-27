#!/bin/bash -e
# Pin cloud-init and rpi-cloud-init-mods to prevent installation.
# These packages have a broken dependency chain in the Raspberry Pi trixie repo
# (python3-jsonpatch / python3-json-pointer circular configure ordering).
# Neither is needed on a headless RPi 3B+ with a fixed SD card image.

cat > "${ROOTFS_DIR}/etc/apt/preferences.d/no-cloud-init" << 'EOF'
Package: cloud-init rpi-cloud-init-mods
Pin: release *
Pin-Priority: -1
EOF

# Also purge if already installed from stage0 dist-upgrade
on_chroot << 'CHROOT'
apt-get remove --purge -y cloud-init rpi-cloud-init-mods 2>/dev/null || true
apt-get autoremove -y || true
CHROOT
