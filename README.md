# flint-rpi3b-cpz-image

Raspberry Pi OS image builder that turns a **Raspberry Pi 3B+** into a CardputerZero-equivalent
flint device. The image ships with the [flint](https://flintdevices.dev) offensive security firmware
pre-installed and auto-started on a generic ST7789V 320×170 SPI display.

> **CardputerZero owners:** use the [official M5Stack image](https://github.com/CardputerZero/cardputer-zero-os) instead.
> This repo targets the RPi 3B+ as a development and standalone alternative only.

---

## Hardware required

| Component | Spec |
|---|---|
| SBC | Raspberry Pi 3B+ |
| Display | ST7789V 320×170 breakout (generic, 1.9") |
| Keyboard | Any standard USB keyboard |
| Storage | MicroSD card, 8 GB+ (16 GB recommended) |
| Power | 5V / 3A USB micro supply |

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

Download the latest `.img.xz` from [Releases](../../releases) and flash with
[Raspberry Pi Imager](https://www.raspberrypi.com/software/) or `dd`:

```bash
xz -d flint-rpi3b-cpz-*.img.xz
sudo dd if=flint-rpi3b-cpz-*.img of=/dev/sdX bs=4M status=progress conv=fsync
```

### First boot

1. Before ejecting the SD card, mount the `bootfs` FAT partition and edit `wifi.txt`:

```
# bootfs/wifi.txt
WIFI_SSID=YourNetwork
WIFI_PASSWORD=YourPassword
```

2. SSH is enabled by default. Connect with `ssh flint@flint.local` (password: `flint`).
3. flint starts automatically on the display. Use a USB keyboard to navigate.

---

## Build the image locally

Requires Docker.

```bash
git clone --recurse-submodules https://github.com/your-org/flint-rpi3b-cpz-image.git
cd flint-rpi3b-cpz-image
./build.sh
# Output: deploy/flint-rpi3b-cpz-*.img.xz
```

The build takes ~30–45 minutes. Subsequent builds are faster due to Docker layer cache.

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
overlays/
  rpi3b-flint-overlay.dts   # custom DTS: SPI display, GPIO27 RST, no M5IOE1
stage-flint/                # pi-gen stage: installs flint on top of stage2 base
  00-packages               # apt package list
  01-run.sh                 # config.txt patches, SSH, Wi-Fi placeholder
  02-run.sh                 # install flint .deb from releases.flintdevices.dev
  03-run.sh                 # autostart: flint launches on boot like CPZero
pi-gen/                     # submodule: CardputerZero/pi-gen (arm64 branch)
```
