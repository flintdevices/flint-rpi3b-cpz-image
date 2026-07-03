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

### Local builds on a non-arm64 host are much slower than "~30–45 min"

That estimate is native-speed (it's what CI gets on its arm64 runner). `build.sh` on an x86_64
host runs pi-gen inside Docker under QEMU user-mode emulation (`build-docker.sh`), which emulates
every instruction for `stage0`–`stage2` (debootstrap + all `apt-get install`s) — expect **1–2+
hours**, not 30–45 min. The final `stage-flint` + image export step runs at native speed (it's
mostly `rsync`/`parted`/`zerofree`/`xz` on the host, not inside the emulated chroot), so it doesn't
add much on top.

`build-docker.sh` names its container `pigen_work` and **refuses to start if one already exists**
unless `CONTINUE=1` is set — this determines whether a re-run repeats the full emulated bootstrap
or reuses it:

- **`docker rm -v pigen_work` then `./build.sh`** (fresh): forces a full re-bootstrap from
  `stage0`, ~1–2+ hours again. Needed when the pi-gen submodule itself was updated, `config`
  changed in a way that affects `stage0`–`stage2`, or the previous container's rootfs is suspect
  (e.g. it died mid-`dpkg` from the qemu bug below and may be in a half-configured state).
- **`CONTINUE=1 ./build.sh`** (resume): reuses the existing `pigen_work` container's volumes via
  `--volumes-from` — `stage0`–`stage2` rootfs and its installed packages are already there, so
  `apt-get`/`dpkg` mostly just confirm and skip. This is the one to use when iterating on
  `stage-flint/` only (overlay tweaks, `FLINT_DEB_URL`, `wifi.txt` service, etc.) after a build
  that got at least through `stage2` — turns a 1–2h rebuild into a few minutes.

### Known qemu-user-static bug on older hosts (e.g. Ubuntu 20.04 Focal)

If a fresh emulated build fails during `stage0` debootstrap with `dpkg: error processing package
systemd ... Failed to take /etc/passwd lock: Invalid argument`, it's not a bug in this repo — it's
`qemu-aarch64-static` being too old to correctly emulate the `fcntl`/OFD-lock syscall that modern
systemd's postinst relies on (e.g. Ubuntu 20.04 ships QEMU 4.2 from 2020, with no newer version in
its apt repos). Fix by registering a modern static QEMU build system-wide instead of relying on the
host's package:
```bash
docker run --rm --privileged multiarch/qemu-user-static --reset -p yes
```
This overwrites the kernel's `binfmt_misc` handlers with ones pinned (`F` flag) to the binaries
bundled in that image, independent of whatever `qemu-user-static` apt package is installed. Verify
with `cat /proc/sys/fs/binfmt_misc/qemu-aarch64` (should show `interpreter
/usr/bin/qemu-aarch64-static`). Then remove the container that died mid-bootstrap
(`docker rm -v pigen_work`) and start fresh — don't `CONTINUE=1` off a rootfs that failed inside
`dpkg`, it may be half-configured.

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
inside the Docker container, per the comment in `build.sh`).

**Critical structural rule, learned the hard way**: pi-gen's `run_stage` only executes numbered
scripts (`00-packages`, `01-run.sh`, etc.) that live inside a **sub-stage subdirectory** of the
stage — it globs `"${STAGE_DIR}"/*` and only recurses into entries that are directories (see
`pi-gen/build.sh`'s `run_stage`/`run_sub_stage`). Every upstream stage follows this
(`stage2/01-sys-tweaks/00-packages`, `stage2/05-cardputerzero/01-run.sh`, etc. — the numbered
files always sit one level inside a named subdirectory, never loose at the stage's own top level).
`stage-flint/00-flint/` is that sub-stage directory here — **do not** put `00-packages`/`NN-run.sh`
directly under `stage-flint/`. `prerun.sh` and `EXPORT_IMAGE` *do* belong at the stage top level
(that matches every upstream stage too).

This bit the project for a while: the scripts originally sat directly under `stage-flint/`
(`stage-flint/00-packages`, `stage-flint/01-run.sh`, `stage-flint/02-run.sh`). pi-gen's stage
runner silently skipped all of them — no error, no log line, `run_stage` just found no
subdirectories to recurse into (only `stage-flint/files/`, which has no numbered scripts of its
own) and moved on. The build still completed and produced a `.img.xz` that looked entirely
plausible (right size, right filename), but it was byte-for-byte whatever `stage2` exported: no
overlay, no `config.txt` patch, no SSH sentinel, no `wifi.txt`, no flint `.deb` — i.e. every
previous theory about this being an overlay-copy or download problem was only partially right;
the scripts responsible were never invoked in the first place. Confirmed by grepping a full build
log for `stage-flint/00-packages`/`01-run.sh`/`02-run.sh` and finding zero hits, and by the
resulting image's `dpkg -l` having `applaunch` (installed in `stage2`) but no `flint` package at
all. If you ever restructure `stage-flint/`, verify with a build log that
`Begin /pi-gen/stage-flint/00-flint/01-run.sh` (or equivalent) actually appears — `Begin
/pi-gen/stage-flint` followed immediately by `Begin/End .../files` with nothing in between means
the scripts aren't being picked up.

- `00-flint/00-packages`: apt packages needed by flint at runtime (pygame/SDL2, PIL, i2c-tools, etc).
- `00-flint/01-run.sh`: installs the compiled `rpi3b-flint-overlay.dtbo`, rewrites `config.txt`
  (removes CardputerZero's M5IOE1-era dtparams, strips the CM0 U-Boot chainload and its
  hardware-specific overlays — see below — appends the RPi-3B+-specific block), cleans
  `cmdline.txt`, enables SSH, drops a `wifi.txt` placeholder on the boot partition plus a
  first-boot systemd service (`flint-wifi-setup.service` / `.sh`) that reads it, brings up Wi-Fi
  via NetworkManager (`nmcli`) once, then disables itself and scrubs the credentials from
  `wifi.txt`.
- `00-flint/02-run.sh`: downloads flint's `.deb` (URL from `FLINT_DEB_URL`, default
  `releases.flintdevices.dev/flint_latest_arm64.deb`) and `dpkg -i`s it in the chroot; the deb's
  postinst is what wires flint into APPLaunch.
- `prerun.sh` / `EXPORT_IMAGE` (at `stage-flint/` top level): standard pi-gen plumbing (seed
  rootfs from the previous stage's output; export naming for `USE_QEMU`).
- Scripts inside `00-flint/` still reference `${STAGE_DIR}` (e.g. `${STAGE_DIR}/../overlays/...`,
  `${STAGE_DIR}/files/...`) rather than a path relative to their own subdirectory — this works
  because pi-gen's `run_sub_stage` only `pushd`s into the sub-stage directory, it does not
  reassign the `STAGE_DIR` env var, which keeps pointing at `stage-flint` itself regardless of
  which sub-stage subdirectory the currently-executing script lives in.

**`stage2/05-cardputerzero/02-run.sh` installs a U-Boot built for the wrong SoC — must be
stripped, not just left alongside our overlay.** That script downloads U-Boot firmware from
`CardputerZero/u-boot` releases (`uboot-firmware-m5stack.tar.gz`) and inserts `kernel=u-boot.bin`
as the *first line* of `config.txt`, so the RPi firmware chain-loads U-Boot instead of booting
Linux directly. That U-Boot is built for the real CardputerZero's Compute Module (`strings
u-boot.bin` shows `raspberrypi,0-compute-module`, i.e. BCM2835/CM0) — on a plain RPi 3B+
(BCM2837) it's the wrong SoC, and the board resets before Linux (or any video output, HDMI
included) ever starts. This shipped in the first image actually built after the sub-stage fix
above and produced exactly that symptom on real hardware: no HDMI video, apparent boot loop. Fix
(now in `00-flint/01-run.sh`): `sed -i '/^kernel=u-boot/d' config.txt` and delete
`u-boot.bin`/`u-boot-nolog.bin` from the boot partition so firmware falls back to its normal
`kernel8.img` auto-detect path. The same upstream script also adds `dtoverlay=` lines for
CardputerZero-v3 hardware this board lacks (`bq27220_v3` battery gauge, `spk-gpio24-high-overlay`
speaker, `bmi270_overlay` IMU, `camera-gpio16-high-overlay`, `gpio-ir`/`gpio-ir-tx`) — strip these
too, since even if they don't hard-fail boot they claim GPIOs/buses that may collide with
`rpi3b-flint-overlay`. It also appends `fbcon=map:off` and `quiet` to `cmdline.txt`, which blanks
the kernel text console on every framebuffer (including HDMI) — strip both so HDMI shows a normal
boot/login console, which is also your best debugging tool if a future image doesn't boot: **it
will show U-Boot's `raspberrypi,0-compute-module` banner or a reset loop directly, instead of a
dark screen that looks identical to "no signal."** Don't assume upstream's `05-cardputerzero`
script is safe to leave unexamined just because it isn't the private-app installer that's already
disabled — audit anything it writes to `config.txt`/`cmdline.txt` against what actual RPi 3B+
hardware has.

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
always compiles with `dtc` directly since the runner is native arm64. `stage-flint/00-flint/01-run.sh`
copies the compiled `.dtbo` into the image and points `config.txt` at it.

The `st7789v@0` node **must set `buswidth = <8>;`** — without it, the `fb_st7789v_m5stack`
fbtft-based driver (cloned/built from `github.com/m5stack/m5stack-linux-dtoverlays` by
`stage2/05-cardputerzero/01-run.sh`) fails to probe with `error -EINVAL: buswidth is not set`, so
`/dev/fb0` never appears — flint/APPLaunch then fail with "cannot open framebuffer device" even
though the overlay otherwise loads and the SPI wiring is correct. This can't be caught by mounting
a built image (it's a runtime kernel probe failure, not a missing file) — it only showed up
testing on real hardware. If you touch the overlay again, boot it for real and check `dmesg | grep
st7789` for the `graphics fb0: ... frame buffer` success line, not just that the `.dtbo` exists.

**APPLaunch (and the `LaunchWizard` service meant to bootstrap it) hard-depend on
`libinput.so.10`, which this lite/CLI image doesn't otherwise install.** Without
`libinput10` in `stage-flint/00-flint/00-packages`, both binaries fail at the dynamic-linker
level (`ldd` shows `libinput.so.10 => not found`) — systemd reports this as a bare `status=127`/
`203/EXEC` with no application-level error message, so it looks like a missing binary or a
generic crash rather than a missing shared library. `LaunchWizard.service` additionally has no
`StartLimitInterval` set, so once it can't exec, it restarts every second forever — treat a
service stuck in `activating (auto-restart)` with an `EXEC`/`127` exit as "missing shared library,
check `ldd`" before assuming anything else.

`LaunchWizard.service` itself is not just broken by the missing library — it's fundamentally
built for the real CardputerZero's graphical first-boot flow (autologin into an `rpd-labwc`
Wayland session per the fork's own design notes in `pi-gen/docs/CARDPUTERZERO-IMAGE-DESIGN.md`),
which this lite/no-desktop image (`SKIP_STAGE3/4/5=1`) never installs the rest of regardless of
`libinput10`. Its real job — presumably enabling `APPLaunch.service` for whichever user gets
created by the interactive first-boot username/password prompt — never happens, since it
crash-loops before getting there. `01-run.sh` now disables `LaunchWizard.service` outright and
runs `systemctl --global enable APPLaunch.service` instead: `--global` enables the unit for every
current *and future* user without needing to know the interactive first-boot username at build
time — this used to not be knowable at build time, because pi-gen's `export-image/01-user-rename`
stage runs an interactive first-boot `rename-user -f -s` wizard by default, which overrides
`config`'s `FIRST_USER_NAME=flint`/`FIRST_USER_PASS=flint` with whatever the person at the console
types in (observed as `pi` in one real test even though `config` set `flint`). `config` and the CI
workflow's heredoc now both set `DISABLE_FIRST_BOOT_USER_RENAME=1`, which skips that wizard
(`export-image/01-user-rename/01-run.sh` just removes `piwiz.desktop` instead of running
`rename-user`) so the build-time `flint`/`flint` account is what's actually on the image — the
`--global enable APPLaunch.service` approach above still works fine with a known username, it just
no longer has to. A global-enabled user unit starts on that user's first login (console *or* SSH)
without needing `loginctl enable-linger` — only add linger if the goal becomes "APPLaunch starts
with no login at all."

**Wi-Fi comes up soft-blocked by design, not by bug.** `stage2/05-cardputerzero/01-run.sh` sets
`options rfkill default_state=0` in `/etc/modprobe.d/rfkill_default.conf`, so `wlan0` (and `bt`)
enumerate but sit `rfkill`-blocked (`soft=1` in `/sys/class/rfkill/*/soft`) and `state DOWN` in `ip
link` until something unblocks them. `stage-flint/files/flint-wifi-setup.sh` only tries to bring
Wi-Fi up if `wifi.txt` has a real `WIFI_SSID` filled in — on the placeholder file it exits before
touching rfkill at all. Seeing `wlan0` present-but-down with the placeholder `wifi.txt` still in
place is expected, not a regression; only chase this further if `wifi.txt` has real credentials
and Wi-Fi *still* doesn't come up.

**This image's real network stack is NetworkManager, not wpa_supplicant/dhclient directly —
`flint-wifi-setup.sh` originally assumed the latter and silently failed on real hardware.**
`dhclient` doesn't exist on this Debian trixie build at all (`command not found`); manually
starting a second `wpa_supplicant -i wlan0 -c ...` process alongside NetworkManager's own
(`/usr/sbin/wpa_supplicant -u -s ...`, already running for `NetworkManager[…]`) even reached
`wpa_state=COMPLETED` in isolation, but NetworkManager still reported `wlan0` as `unavailable`
(`managed-type: 'external'`, `journalctl -u NetworkManager`) because the interface was fighting
two supplicant instances. Separately, and *independently* of kernel rfkill — even after `rfkill
unblock wifi` — NetworkManager has its **own** persisted software radio toggle
(`nmcli radio wifi`, stored in `/var/lib/NetworkManager/NetworkManager.state`) that can come up
`disabled` if NM observed the radio rfkill-blocked at an earlier boot, and unblocking rfkill later
doesn't flip it back. Fixed `flint-wifi-setup.sh` to do both `rfkill unblock wifi` *and* `nmcli
radio wifi on` before handing the actual connect to `nmcli device wifi connect "$SSID" password
"$PASS"` — nmcli's connect handles associate+DHCP in one step using NM's real stack, and persists
a connection profile so it reconnects on later boots without this script running again. If Wi-Fi
still won't come up after a build change here, check `nmcli radio wifi` and `nmcli device status`
before assuming it's an rfkill or credentials problem.

**That fix still wasn't enough for automatic first-boot connection: every `nmcli`/`rfkill` call
in the script was suffixed `|| true`, and it unconditionally scrubbed `WIFI_SSID`/`WIFI_PASSWORD`
from `wifi.txt` and disabled `flint-wifi-setup.service` regardless of whether the connect actually
succeeded.** `flint-wifi-setup.service` also had no ordering dependency on `NetworkManager.service`
— only `After=network-pre.target`, `Before=network.target wpa_supplicant.service` — so on a fresh
boot it could run its `nmcli` calls before NetworkManager was even up, fail every one of them
silently, and still burn its one shot at `wifi.txt` (credentials wiped, service disabled) with no
way to retry. Fixed by adding `After=NetworkManager.service`/`Wants=NetworkManager.service` to the
unit, having the script poll `nmcli -t -f DEVICE,STATE device status` for `wlan0` to leave
`unavailable` before attempting to connect, retrying `nmcli device wifi connect` a few times, and
only scrubbing credentials / disabling the service once a connect attempt actually returns success
— on failure it `exit 1`s and leaves both the service enabled and the credentials in `wifi.txt`, so
`ConditionPathExists=/boot/firmware/wifi.txt` lets it retry on the next boot instead of only ever
getting one (possibly-too-early) attempt.

**SSH-only control (no physical keyboard) works via a virtual keyboard, not a special
case in APPLaunch/flint.** `stage-flint/00-flint/03-run.sh` installs `ydotool`/`ydotoold`
(downloaded as a `.deb` — not in Debian trixie's main repo, only `trixie-backports`) with
our own system-level `ydotoold.service` (the packaged unit is user-scoped and only starts
at login, too late to satisfy libinput's no-hotplug requirement — see the "APPLaunch...
hard-depend on libinput.so.10" section above for that constraint). The daemon's uinput
virtual device gets `ID_INPUT_KEYBOARD=1` from the kernel/udev the same way a physical USB
keyboard does, so it's picked up by the *existing* `99-flint-usb-keyboard.rules` unchanged
— no APPLaunch/flint-specific code exists for this. Run `virtual-keyboard` after SSH-ing in
(`/usr/local/bin/virtual-keyboard`, installed by the same stage) to forward every keystroke
from the SSH terminal to the device; Ctrl+] exits. A dynamic-MOTD script
(`/etc/update-motd.d/99-flint-virtual-keyboard-motd`) mentions the command on every SSH
login so a user without a keyboard isn't left guessing. The `ydotool` client resolves its
control socket via `$YDOTOOL_SOCKET` → `$XDG_RUNTIME_DIR/.ydotool_socket` →
`/tmp/.ydotool_socket`, and an SSH login session normally has `XDG_RUNTIME_DIR` set by
logind — both the daemon (`--socket-path`) and `virtual-keyboard` pin
`/tmp/.ydotool_socket` explicitly so this never depends on which env vars happen to be
set. All install logic lives in one idempotent script,
`stage-flint/files/install-virtual-keyboard.sh`, so an already-flashed device can be
patched by copying it over and running `sudo bash install-virtual-keyboard.sh` without a
full rebuild/reflash — it detects a live system via `/run/systemd/system` and applies
immediately instead of only enabling for next boot. Full design rationale, including
verified corrections against the original proposal, is in
`docs/superpowers/specs/2026-07-03-virtual-keyboard-design.md`.

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
- **`stage-flint/00-flint/01-run.sh` reads the compiled overlay via `${STAGE_DIR}/../overlays/...`**,
  which resolves to `pi-gen/overlays/` once `stage-flint` is copied inside `pi-gen` (see the
  "Critical structural rule" note above — this bug was independent of, and masked by, the missing
  sub-stage directory: the `cp` here was never even reached until that was fixed, since pi-gen
  wasn't invoking `01-run.sh` at all). `build.sh` and the CI workflow copy the freshly-compiled
  `.dtbo` into `pi-gen/overlays/` *every run* (dtc recompiles it each time) via an explicit
  `mkdir -p pi-gen/overlays && cp overlays/rpi3b-flint-overlay.dtbo pi-gen/overlays/` step placed
  right after "copy stage-flint into pi-gen". Without it, `01-run.sh`'s `cp` fails and, because the
  script runs under `set -e`, the *whole* stage-flint sub-stage aborts partway through, meaning
  whatever runs after that `cp` in the same script (`config.txt` patching, SSH-enable, `wifi.txt`
  generation) never executes, and pi-gen never gets to `02-run.sh` (flint `.deb` install) either.
  If you ever touch this copy step, keep
  `build.sh` and `.github/workflows/build.yml` in sync, same as the `config` duplication above.
