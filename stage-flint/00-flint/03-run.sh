#!/bin/bash -e
# Install ydotoold + virtual-keyboard for SSH-driven input (no physical
# keyboard needed). All actual install logic lives in
# files/install-virtual-keyboard.sh, which is also meant to be run by hand
# on an already-flashed device to patch it without a rebuild — see that
# script's header comment.

install -m 755 "${STAGE_DIR}/files/install-virtual-keyboard.sh" \
    "${ROOTFS_DIR}/tmp/install-virtual-keyboard.sh"
install -m 644 "${STAGE_DIR}/files/ydotoold.service" \
    "${ROOTFS_DIR}/tmp/ydotoold.service"
install -m 644 "${STAGE_DIR}/files/virtual-keyboard" \
    "${ROOTFS_DIR}/tmp/virtual-keyboard"
install -m 644 "${STAGE_DIR}/files/99-flint-usb-keyboard.rules" \
    "${ROOTFS_DIR}/tmp/99-flint-usb-keyboard.rules"
install -m 644 "${STAGE_DIR}/files/99-flint-virtual-keyboard-motd" \
    "${ROOTFS_DIR}/tmp/99-flint-virtual-keyboard-motd"

on_chroot << 'CHROOT'
bash /tmp/install-virtual-keyboard.sh /tmp
rm -f /tmp/install-virtual-keyboard.sh /tmp/ydotoold.service /tmp/virtual-keyboard /tmp/99-flint-usb-keyboard.rules /tmp/99-flint-virtual-keyboard-motd
CHROOT
