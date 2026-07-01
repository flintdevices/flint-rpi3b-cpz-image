# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A `pi-gen`-based Raspberry Pi OS image builder — not an application. It produces a bootable
`.img.xz` for a **Raspberry Pi 3B+** that mimics a CardputerZero: it reuses the CardputerZero
fork's `pi-gen` stages (APPLaunch launcher, base OS) and layers the
[flint](https://flintdevices.dev) firmware on top via a custom pi-gen stage. There is no
application source code here, no test suite, and no linter — "development" means editing shell
scripts, a DTS overlay, and pi-gen stage config, then running a real image build to verify.

## Commands

```bash
# Local build (requires Docker; git submodule must be initialized)
git submodule update --init --recursive
./build.sh

# Override the flint .deb source
FLINT_DEB_URL=https://releases.flintdevices.dev/flint_0.0.42_arm64.deb ./build.sh
```

There is no unit-test runner. The only way to validate a change is an actual image build
(~30–45 min locally, up to 120 min in CI) followed by flashing/booting, or by reading the
generated rootfs artifacts under `pi-gen/work/` after a build. The `pi-gen` submodule ships
`tools/verify-image.sh <image.img>` and `tools/compare-images.sh <ours> <official>` for
inspecting a built image's partitions/boot files without a full flash — useful when checking
whether a stage change actually landed in the image.

CI (`.github/workflows/build.yml`) runs the equivalent build natively on an `ubuntu-24.04-arm`
runner (arm64, no qemu) on tag pushes (`v*`) or manual `workflow_dispatch`, and publishes a
GitHub Release for tag builds.

## Architecture: two build layers

**`pi-gen/` is a git submodule** (`CardputerZero/pi-gen`, `arm64` branch — see `.gitmodules`).
It contains the upstream stages that build the CardputerZero base OS:

- `stage0`–`stage2`: base Debian trixie rootfs, network, timezone.
- `stage2/05-cardputerzero`: installs APPLaunch (the app launcher UI) and CardputerZero's own
  device-tree/kernel-module customizations. Its `03-run.sh` pulls private CardputerZero apps
  (Recorder/CameraApp/FactoryTest/Compass) from repos this project can't reach (needs a token we
  don't have) — **both `build.sh` and the CI workflow disable it by `chmod -x`** before the pi-gen
  build runs. `02-run.sh` (APPLaunch itself) is left enabled; flint registers itself with
  APPLaunch via its `.deb` postinst, so no changes are needed there.
- `stage3`–`stage5` (desktop/LibreOffice) are skipped via `SKIP_STAGE3/4/5=1` in `config` — this
  is a lite/CLI image, not a desktop build.

**`stage-flint/` (this repo, top-level) is pi-gen's final stage**, appended to `STAGE_LIST` in
`config`. Since pi-gen only looks for stages inside its own directory, `build.sh`/CI **copy**
`stage-flint/` into `pi-gen/stage-flint/` at build time (a symlink won't survive being resolved
inside the Docker container, per the comment in `build.sh`). Its scripts:

- `00-packages`: apt packages needed by flint at runtime (pygame/SDL2, PIL, i2c-tools, etc).
- `01-run.sh`: installs the compiled `rpi3b-flint-overlay.dtbo`, rewrites `config.txt` (removes
  CardputerZero's M5IOE1-era dtparams, appends the RPi-3B+-specific block), enables SSH, drops a
  `wifi.txt` placeholder on the boot partition plus a first-boot systemd service
  (`flint-wifi-setup.service` / `.sh`) that reads it, writes `wpa_supplicant.conf`, brings up
  Wi-Fi once, then disables itself and scrubs the credentials from `wifi.txt`.
- `02-run.sh`: downloads flint's `.deb` (URL from `FLINT_DEB_URL`, default
  `releases.flintdevices.dev/flint_latest_arm64.deb`) and `dpkg -i`s it in the chroot; the deb's
  postinst is what wires flint into APPLaunch.
- `prerun.sh` / `EXPORT_IMAGE`: standard pi-gen plumbing (seed rootfs from the previous stage's
  output; export naming for `USE_QEMU`).

**Two independent copies of the pi-gen `config`** exist and must be kept in sync manually: the
top-level `config` file (used by `build.sh`) and an inline heredoc inside
`.github/workflows/build.yml`'s "Write pi-gen config" step (used by CI, which also injects a
dated `IMG_FILENAME`). If you change `STAGE_LIST`, `SKIP_STAGE*`, or similar in one, update the
other.

## Hardware layer: DTS overlay

`overlays/rpi3b-flint-overlay.dts` replaces the fork's `cardputerzero-overlay`: it wires the
ST7789V display directly to GPIO25 (DC) / GPIO27 (RST) / SPI0 CS0, with no dependency on the
M5IOE1 I/O expander used by the real CardputerZero (no expander is present on a plain RPi 3B+).
`build.sh` compiles this `.dts` → `.dtbo` locally with `dtc` (falling back to the `Dockerfile` in
this repo, a throwaway Debian image with `device-tree-compiler`, if `dtc` isn't installed); CI
always compiles with `dtc` directly since the runner is native arm64. `stage-flint/01-run.sh`
copies the compiled `.dtbo` into the image and points `config.txt` at it.

Backlight is hardwired to 3.3V (always on) — there is no PWM circuit, so HAL calls like
`sys_backlight()` in flint are expected to no-op on this hardware rather than fail. See the
"Differences from the real CardputerZero" and "Differences in HAL behavior" tables in
[README.md](README.md) and [docs/rpi3bplus-dev-setup.md](docs/rpi3bplus-dev-setup.md) before
assuming a HAL call should behave identically to the real device.

## Key constraints when modifying stages

- pi-gen skips any stage script that isn't executable — this is the mechanism used to disable
  the fork's private-app installer; don't "fix" it by deleting the script (keeps diffs against
  the upstream submodule minimal) or by trying to patch the private-repo URLs.
- Scripts run via `on_chroot` execute inside the target rootfs; anything referencing host paths
  (like `${STAGE_DIR}/../overlays/...` in `01-run.sh`, which copies from *outside* the chroot)
  must happen before/outside the `on_chroot` block.
- `FLINT_DEB_URL` is the one supported override point for pointing a build at a different flint
  build; it must be exported before invoking pi-gen (both `build.sh` and the CI workflow do this)
  since pi-gen stage scripts only see explicitly exported env vars inside the Docker/chroot build.
- **`stage-flint/01-run.sh` reads the compiled overlay via `${STAGE_DIR}/../overlays/...`**,
  which resolves to `pi-gen/overlays/` once `stage-flint` is copied inside `pi-gen` (see below).
  `build.sh` and the CI workflow must copy the freshly-compiled `.dtbo` into `pi-gen/overlays/`
  *every run* (dtc recompiles it each time) — **both currently do this** via an explicit
  `mkdir -p pi-gen/overlays && cp overlays/rpi3b-flint-overlay.dtbo pi-gen/overlays/` step placed
  right after "copy stage-flint into pi-gen". This was missing for the entire lifetime of this
  repo until it was added — without it, `01-run.sh`'s `cp` fails and, because the script runs
  under `set -e`, the *whole* stage-flint stage aborts silently-ish, meaning `config.txt` patching
  SSH-enable, and `wifi.txt` generation (all later in the same script) never run, and pi-gen never
  gets to `02-run.sh` (flint `.deb` install) either. A build that stops here still produces a
  `.img.xz` (from a different, already-exported stage2 artifact) that looks plausible but has no
  flint on it — see the README "Troubleshooting" section. If you ever touch this copy step, keep
  `build.sh` and `.github/workflows/build.yml` in sync, same as the `config` duplication above.
