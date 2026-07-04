#!/bin/bash -e
# Idempotent installer for the SSH virtual-keyboard feature. Runs unchanged:
#   - at pi-gen build time, invoked via on_chroot from 00-flint/03-run.sh
#     (files/ live at the script's own directory, /boot etc. resolve inside
#     the chroot being built)
#   - on an already-flashed, already-booted device, run directly as root
#     over an existing SSH session to patch a device without a full rebuild
#
# Usage: sudo bash install-virtual-keyboard.sh [path-to-stage-flint-files-dir]
# If no path is given, assumes this script's own directory also contains
# ydotoold.service, virtual-keyboard, 99-flint-usb-keyboard.rules, and
# 99-flint-virtual-keyboard-motd.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FILES_DIR="${1:-${SCRIPT_DIR}}"

YDOTOOL_DEB_URL="${YDOTOOL_DEB_URL:-http://deb.debian.org/debian/pool/main/y/ydotool/ydotool_1.0.4-2~bpo13+1_arm64.deb}"

# ── 1. Install ydotool (not in Debian trixie's main repo, only backports) ────
if ! command -v ydotoold >/dev/null 2>&1; then
    echo "Downloading ydotool from ${YDOTOOL_DEB_URL}"
    curl -fsSL --retry 3 -o /tmp/ydotool.deb "${YDOTOOL_DEB_URL}"
    dpkg -i /tmp/ydotool.deb || apt-get install -f -y
    rm -f /tmp/ydotool.deb
else
    echo "ydotool already installed, skipping download"
fi

# ── 2. Install our own system-level ydotoold unit ────────────────────────────
# (Not the packaged /usr/lib/systemd/user/ydotool.service — that's a user unit
# and only starts at login, racing APPLaunch's own login-time start. Ours
# starts at boot, before any login, satisfying libinput's no-hotplug
# requirement.)
install -m 644 "${FILES_DIR}/ydotoold.service" /etc/systemd/system/ydotoold.service

# The .deb's postinst globally enables its own /usr/lib/systemd/user/ydotool.service
# (WantedBy=default.target). This was assumed harmless because a user unit "only
# starts at login" — true, but linger (enabled for the first user so APPLaunch
# starts without a login, see 01-run.sh) makes systemd start that user's default
# target at boot too, with no login required. That starts a *second* ydotoold
# (default socket, default uinput device) racing ours for the keyboard udev
# symlink — confirmed on real hardware as the cause of virtual-keyboard working
# once and then not, since which daemon's uinput device wins the symlink is a
# boot-order race. Mask the packaged unit so only ours ever runs.
systemctl --global disable ydotool.service 2>/dev/null || true
systemctl --global mask ydotool.service

# ── 3. Install the virtual-keyboard CLI ──────────────────────────────────────
install -m 755 "${FILES_DIR}/virtual-keyboard" /usr/local/bin/virtual-keyboard

# ── 4. Refresh the keyboard udev rule (MODE=0666 addition) ───────────────────
# stage-flint/00-flint/01-run.sh (unmodified by this feature) already installs
# this same file at build time, so this write is a harmless no-op duplicate
# during a fresh pi-gen build (identical content, same destination). It is
# NOT redundant for the live-patch use case: an already-flashed device's copy
# predates the MODE=0666 fix and 01-run.sh never re-runs on a live system, so
# this script must carry its own copy to stay self-contained.
install -m 644 "${FILES_DIR}/99-flint-usb-keyboard.rules" \
    /etc/udev/rules.d/99-flint-usb-keyboard.rules

# ── 5. SSH login MOTD notice ──────────────────────────────────────────────────
install -m 755 "${FILES_DIR}/99-flint-virtual-keyboard-motd" \
    /etc/update-motd.d/99-flint-virtual-keyboard-motd

# ── 6. Enable, and on a live system also apply immediately ───────────────────
systemctl enable ydotoold.service

# /run/systemd/system only exists when systemd is actually running as PID 1 —
# true on a live booted device, false inside a pi-gen chroot during build.
# On a live system, apply everything now instead of requiring a reboot.
if [ -d /run/systemd/system ]; then
    udevadm control --reload-rules
    udevadm trigger
    systemctl daemon-reload
    systemctl restart ydotoold.service
    echo "Applied live. Run 'virtual-keyboard' over SSH to test."
else
    echo "Installed for next boot (build-time chroot — not starting services now)."
fi
