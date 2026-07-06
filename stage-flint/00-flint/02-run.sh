#!/bin/bash -e
# Download and install the flint .deb from releases.flintdevices.dev.

# Default to latest known release; override with FLINT_DEB_URL env var at build time.
FLINT_DEB_URL="${FLINT_DEB_URL:-https://releases.flintdevices.dev/flint_latest_arm64.deb}"
DEB_PATH="/tmp/flint.deb"

echo "Downloading flint from ${FLINT_DEB_URL}"
curl -fsSL --retry 3 -o "${ROOTFS_DIR}${DEB_PATH}" "${FLINT_DEB_URL}"

on_chroot << CHROOT
# Install via apt (not dpkg -i) so the .deb's Recommends — iw, aircrack-ng,
# tcpdump, hostapd, dnsmasq, nmap, arp-scan, ... — are pulled in. dpkg -i
# installs none of them and 'apt-get install -f' only satisfies hard Depends,
# which would leave the Wi-Fi tooling absent and every monitor-mode/scan tool
# non-functional on the device.
apt-get install -y "${DEB_PATH}"
rm -f "${DEB_PATH}"
CHROOT
