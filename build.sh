#!/bin/bash -e
# Local build entrypoint for flint-rpi3b-cpz-image.
# Compiles the DTS overlay then delegates to pi-gen via Docker.
#
# Usage:
#   ./build.sh
#   FLINT_DEB_URL=https://releases.flintdevices.dev/flint_0.0.42_arm64.deb ./build.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PIGEN_DIR="${SCRIPT_DIR}/pi-gen"
STAGE_FLINT_DIR="${SCRIPT_DIR}/stage-flint"
OVERLAYS_SRC="${SCRIPT_DIR}/overlays"

# ── 1. Compile DTS → DTBO ────────────────────────────────────────────────────
echo "==> Compiling rpi3b-flint-overlay.dts"
if command -v dtc &>/dev/null; then
    dtc -@ -I dts -O dtb \
        -o "${OVERLAYS_SRC}/rpi3b-flint-overlay.dtbo" \
        "${OVERLAYS_SRC}/rpi3b-flint-overlay.dts"
elif command -v docker &>/dev/null; then
    echo "    dtc not found — using Docker fallback"
    docker build -t flint-dtc "${SCRIPT_DIR}" -q
    docker run --rm \
        -v "${OVERLAYS_SRC}:/overlays" \
        flint-dtc
else
    echo "ERROR: neither dtc nor docker found. Install one of:"
    echo "  sudo apt install device-tree-compiler"
    echo "  https://docs.docker.com/get-docker/"
    exit 1
fi

echo "    -> overlays/rpi3b-flint-overlay.dtbo"

# ── 2. Check pi-gen submodule ────────────────────────────────────────────────
if [ ! -f "${PIGEN_DIR}/build.sh" ]; then
    echo "ERROR: pi-gen submodule not initialised. Run:"
    echo "  git submodule update --init --recursive"
    exit 1
fi

# ── 3. Copy custom stage into pi-gen ────────────────────────────────────────
# realpath inside pi-gen/build.sh resolves symlinks to their source path,
# which doesn't exist inside the Docker container — must copy, not symlink.
if [ ! -d "${PIGEN_DIR}/stage-flint" ]; then
    cp -r "${STAGE_FLINT_DIR}" "${PIGEN_DIR}/stage-flint"
    echo "==> Copied stage-flint into pi-gen"
fi

# Skip the fork's private CPZero app installers (Recorder/CameraApp/etc.) —
# private repos we can't reach; flint replaces them. pi-gen skips non-executable
# run scripts. APPLaunch (02-run.sh) stays; flint self-registers via deb postinst.
if [ -f "${PIGEN_DIR}/stage2/05-cardputerzero/03-run.sh" ]; then
    chmod -x "${PIGEN_DIR}/stage2/05-cardputerzero/03-run.sh"
    echo "==> Disabled fork's private CPZero app installer"
fi

# ── 4. Run pi-gen build (Docker) ─────────────────────────────────────────────
echo "==> Starting pi-gen build (this takes ~30–45 minutes)"
cd "${PIGEN_DIR}"

# Export FLINT_DEB_URL so it's available inside the pi-gen Docker container
export FLINT_DEB_URL="${FLINT_DEB_URL:-https://releases.flintdevices.dev/flint_latest_arm64.deb}"

# pi-gen reads config from the directory it's called from; point it at ours
CONFIG_FILE="${SCRIPT_DIR}/config"

./build-docker.sh -c "${CONFIG_FILE}"

echo ""
echo "==> Build complete. Image:"
ls -lh "${PIGEN_DIR}/deploy/"*.img.xz 2>/dev/null || ls -lh "${PIGEN_DIR}/deploy/"*.img
