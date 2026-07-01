#!/bin/bash -e
# Download and install the flint .deb from releases.flintdevices.dev.

# Default to latest known release; override with FLINT_DEB_URL env var at build time.
FLINT_DEB_URL="${FLINT_DEB_URL:-https://releases.flintdevices.dev/flint_latest_arm64.deb}"
DEB_PATH="/tmp/flint.deb"

echo "Downloading flint from ${FLINT_DEB_URL}"
curl -fsSL --retry 3 -o "${ROOTFS_DIR}${DEB_PATH}" "${FLINT_DEB_URL}"

on_chroot << CHROOT
dpkg -i "${DEB_PATH}" || apt-get install -f -y
rm -f "${DEB_PATH}"
CHROOT
