# flint-rpi3b-cpz-image

Raspberry Pi OS image builder that turns a **Raspberry Pi 3B+** into a CardputerZero-equivalent
flint device. The image ships with the [flint](https://flintdevices.dev) offensive security firmware
pre-installed and auto-started on a generic ST7789V 320×170 SPI display.

> **CardputerZero owners:** use the [official M5Stack image](https://github.com/CardputerZero/cardputer-zero-os) instead.
> This repo targets the RPi 3B+ as a development and standalone alternative only.

## What you get

This is a ready-to-flash `.img.xz` (Raspberry Pi OS Lite/trixie under the hood), not just a
config — flashing it gives you:

- **flint pre-installed and auto-started**, launched from the **APPLaunch** app launcher (the
  same launcher the real CardputerZero uses) on the wired ST7789V display.
- **A working login out of the box** — no interactive first-boot username/password wizard.
  Username `flint`, password `flint` (see [Security note](#security-note)).
- **SSH enabled by default**, reachable at `flint@flint.local` (or the device's IP) with the
  same `flint`/`flint` credentials.
- **Wi-Fi via a boot-partition text file** (`wifi.txt`) — fill it in before first boot and the
  device connects on its own; no keyboard/display interaction required.
- **A virtual on-screen-free keyboard over SSH**, for controlling APPLaunch/flint entirely from
  a terminal when no physical USB keyboard is attached (see [Controlling flint over SSH](#controlling-flint-over-ssh-no-keyboard)).

---

## Hardware required

| Component | Spec |
|---|---|
| SBC | Raspberry Pi 3B+ |
| Display | ST7789V 320×170 breakout (generic, 1.9") |
| Keyboard | Any standard USB keyboard |
| Storage | MicroSD card, 8 GB+ (16 GB recommended) |
| Power | 5V / 3A USB micro supply |

See the full [hardware and wiring guide](docs/rpi3bplus-dev-setup.md) for troubleshooting, custom DTS overlay, and HAL differences.

### Display wiring (SPI0)

| ST7789V pin | RPi GPIO | Header pin |
|---|---|---|
| VCC | 3.3V | Pin 1 |
| GND | GND | Pin 6 |
| SCL / SCK | GPIO11 | Pin 23 |
| SDA / MOSI | GPIO10 | Pin 19 |
| RES / RST | GPIO27 | Pin 13 |
| DC | GPIO25 | Pin 22 |
| CS | GPIO8 | Pin 24 |
| BLK / BL | 3.3V | Pin 17 |

Backlight is always on (tied to 3.3V). No PWM circuit required.

---

## Download a pre-built image

Download the latest `.img.xz` from [Releases](../../releases).

### Flash

**Option A — Raspberry Pi Imager (recommended):** open
[Raspberry Pi Imager](https://www.raspberrypi.com/software/), choose "Use custom", select the
downloaded `.img.xz` (no need to decompress it first), pick your SD card, and write. Skip the
Imager's own OS-customisation prompt (username/password/Wi-Fi) — this image already has that
baked in; see [First boot](#first-boot) below for how to still set Wi-Fi credentials.

**Option B — `dd`:**

```bash
xz -d flint-rpi3b-cpz-*.img.xz
sudo dd if=flint-rpi3b-cpz-*.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Replace `/dev/sdX` with your SD card's device (check with `lsblk` first — this overwrites the
whole device).

### First boot

1. **Wi-Fi (optional but recommended):** before ejecting the card, the FAT boot partition
   (`bootfs`, labelled `bootfs` or mounted as `/boot/firmware` once booted) will contain a
   `wifi.txt` placeholder. Uncomment and fill in the two lines:

   ```
   # bootfs/wifi.txt
   WIFI_SSID=YourNetwork
   WIFI_PASSWORD=YourPassword
   ```

   On first boot a one-shot service reads this file, connects via NetworkManager, and then
   erases the credentials from `wifi.txt` and disables itself — nothing to clean up manually,
   and no Wi-Fi setup screen to click through. If it can't connect (e.g. network not up yet),
   it retries automatically on the next boot without losing the credentials.

2. Insert the card, power on the Pi, and give it a minute to boot — **flint starts
   automatically** on the ST7789V display via APPLaunch, no login required at the display.

3. **SSH is enabled by default:** `ssh flint@flint.local` (password `flint`), or
   `ssh flint@<device-ip>` if `.local` mDNS resolution isn't available on your network.

4. **No USB keyboard?** See [Controlling flint over SSH](#controlling-flint-over-ssh-no-keyboard)
   below to drive APPLaunch/flint's on-screen input entirely from your SSH session.

### Security note

The image ships with a fixed `flint`/`flint` login and no first-boot password prompt, by design
(see [What you get](#what-you-get)) — the trade-off is convenience over securing a device with a
guessable default password. Standard practice for anything reachable on an untrusted network:
change the password after first login (`passwd`) or add your own SSH key and disable password
auth. Not needed for a device that stays on a trusted home/lab network only.

### Controlling flint over SSH (no keyboard)

If you don't have a USB keyboard wired up, the image ships a virtual keyboard so you can drive
APPLaunch and flint from your SSH terminal:

```bash
ssh flint@flint.local
virtual-keyboard
```

Every keystroke you type is forwarded to the device as if a real USB keyboard were plugged in;
press `Ctrl+]` to exit. The SSH login banner (MOTD) also mentions this command, so it's
discoverable even without reading this README first.

---

## Build the image locally

Requires Docker.

```bash
git clone --recurse-submodules https://github.com/your-org/flint-rpi3b-cpz-image.git
cd flint-rpi3b-cpz-image
./build.sh
# Output: deploy/flint-rpi3b-cpz-*.img.xz
```

The build takes ~30–45 minutes on native arm64 (e.g. the CI runner). On an x86_64 host, pi-gen
runs under QEMU user-mode emulation and it's significantly slower — expect **1–2+ hours** for a
first/fresh build; re-runs with `CONTINUE=1 ./build.sh` reuse the previous run's rootfs and are
much faster if you're only iterating on `stage-flint/`.

To override the flint `.deb` URL:

```bash
FLINT_DEB_URL=https://releases.flintdevices.dev/flint_0.0.42_arm64.deb ./build.sh
```

---

## Differences from the real CardputerZero

| Feature | CardputerZero | This image |
|---|---|---|
| Backlight control | M5IOE1 PWM (I²C) | Always on (3.3V) |
| Display RST | M5IOE1 GPIO | GPIO27 direct |
| Keyboard | TCA8418 5×10 matrix | USB HID |
| Audio | ES8389 I²S codec | Not available |
| Battery / charging | BQ27220 + IP2316 | Not available |
| Ethernet | SR9900A via USB hub | Onboard GbE |

HAL calls to `sys_backlight()` succeed silently (no-op). All other flint tools behave identically.

---

## Repository layout

```
config                      # pi-gen build variables
build.sh                    # local build entrypoint (wraps pi-gen + dtc)
Dockerfile                  # reproducible build environment
docs/
  rpi3bplus-dev-setup.md    # wiring guide, DTS overlay, HAL differences
overlays/
  rpi3b-flint-overlay.dts   # custom DTS: SPI display, GPIO27 RST, no M5IOE1
stage-flint/                # pi-gen stage: installs flint on top of the stage2 CPZero base
  00-flint/                 # pi-gen sub-stage (must be a subdir, not loose files at
                            #   stage-flint/ top level, or pi-gen's stage runner never executes it)
    00-packages             # apt package list
    01-run.sh               # RPi 3B+ display overlay, config.txt, SSH, Wi-Fi placeholder
    02-run.sh               # install flint .deb (its postinst registers flint with APPLaunch)
  prerun.sh / EXPORT_IMAGE  # seed rootfs from stage2; export the flint image
pi-gen/                     # submodule: CardputerZero/pi-gen (arm64 branch)
                            #   stage2/05-cardputerzero installs APPLaunch + HW overlays;
                            #   its private-app installer (03-run.sh) is skipped at build time
```
