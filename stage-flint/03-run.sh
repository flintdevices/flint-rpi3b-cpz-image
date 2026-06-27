#!/bin/bash -e
# Configure flint to autostart on the framebuffer display, mimicking the
# CPZero image behaviour (app launcher on boot, no login prompt on the display).

# ── 1. flint autostart service ────────────────────────────────────────────────
install -m 644 "${STAGE_DIR}/files/flint-autostart.service" \
    "${ROOTFS_DIR}/etc/systemd/system/flint-autostart.service"

# ── 2. Enable the service and set the default target to multi-user ────────────
on_chroot << 'CHROOT'
systemctl enable flint-autostart.service
systemctl set-default multi-user.target
CHROOT

# ── 3. Disable getty on tty1 so flint owns the console ───────────────────────
on_chroot << 'CHROOT'
systemctl disable getty@tty1.service || true
CHROOT
