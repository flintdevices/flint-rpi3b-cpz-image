# Replicating the CardputerZero environment on a Raspberry Pi 3B+

This guide sets up a Raspberry Pi 3B+ as a functional development and standalone target for flint,
using the same OS image and Device Tree configuration as the CardputerZero. A standard USB keyboard
replaces the onboard TCA8418 matrix.

---

## Hardware differences from CardputerZero

| Component | CardputerZero | RPi 3B+ setup |
|---|---|---|
| SoC | BCM2835 (CM0) | BCM2837 (RPi 3B+) — same BCM family |
| Display | ST7789V via SPI0, backlight via M5IOE1 PWM | ST7789V generic breakout via SPI0, backlight pulled high (always on) |
| Keyboard | TCA8418 5×10 matrix (I²C) | Standard USB keyboard |
| Audio | ES8389 I²S codec (proprietary) | Not configured — skip |
| M5IOE1 expander | Required for backlight, LCD RST, USB hub RST | **Not used** — LCD RST wired to a direct GPIO, backlight always on |
| Ethernet | SR9900A via internal USB hub | Onboard GbE (built-in to 3B+) |
| Wi-Fi / BT | CM0 built-in | Onboard (BCM43438) |
| Power | Internal battery + IP2316 charger | USB-C / micro-USB power supply |

---

## Required hardware

- Raspberry Pi 3B+
- ST7789V breakout module (320×170, 1.9") — generic modules from AliExpress/Amazon
  - Look for modules that expose: `VCC`, `GND`, `SCL`/`SCK`, `SDA`/`MOSI`, `RES`/`RST`, `DC`, `CS`, `BLK`/`BL`
- 8× female-to-female jumper wires
- Standard USB keyboard
- MicroSD card (16 GB+)
- Power supply for RPi 3B+ (5V / 3A recommended)

---

## Wiring — ST7789V breakout to RPi 3B+ GPIO header

The CardputerZero SPI0 pin assignments map directly to the RPi 3B+ 40-pin header.

| ST7789V pin | RPi GPIO | RPi header pin | Notes |
|---|---|---|---|
| VCC | 3.3V | Pin 1 | Do **not** use 5V — display is 3.3V logic |
| GND | GND | Pin 6 | |
| SCL / SCK | GPIO11 | Pin 23 | SPI0 CLK |
| SDA / MOSI | GPIO10 | Pin 19 | SPI0 MOSI |
| RES / RST | GPIO27 | Pin 13 | Manual RST (replaces PYG5/M5IOE1) |
| DC | GPIO25 | Pin 22 | Data/Command select — same as CPZero |
| CS | GPIO8 | Pin 24 | SPI0 CS0 — same as CPZero |
| BLK / BL | 3.3V | Pin 17 | Backlight always on (tied to 3V3) |

> **RST pin:** On the CardputerZero, display reset is driven by the M5IOE1 expander (PYG5). Here
> we wire RST directly to GPIO27. The overlay below is adjusted accordingly.

> **BLK / BL pin:** Wire directly to 3.3V on the RPi header (pin 1 or 17). No PWM, no transistor —
> backlight stays at full brightness.

---

## OS image

> **Recommended:** use the pre-built image from
> [flint-rpi3b-cpz-image](https://github.com/flintdevices/flint-rpi3b-cpz-image/releases).
> It ships with flint pre-installed, the overlay pre-compiled, SSH enabled, and a
> `wifi.txt` placeholder on the boot partition. Skip to [Install and run flint](#install-and-run-flint)
> if you use it.

For a manual setup, use the official CardputerZero Debian image. It ships with all required kernel
drivers (`st7789v_m5stack`, `m5stack,pwm-backlight`, `tca8418c`, etc.) pre-built as modules.

Download and flash the image using the [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
or `dd`:

```bash
# Replace /dev/sdX with your MicroSD card device
sudo dd if=cardputerzero-debian.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Mount the `bootfs` partition (first FAT partition) before first boot to edit `config.txt`.

---

## Boot configuration — `config.txt`

The file is at `/boot/firmware/config.txt` on the running system, or on the `bootfs` FAT partition
of the MicroSD card when mounted on another machine.

Replace the stock CardputerZero `config.txt` with the following:

```ini
# Core interfaces
dtparam=i2c_arm=on
dtparam=i2s=on
dtparam=spi=on

# Display: ST7789V 320×170 via fbtft (SPI0, CS0)
# Legacy fbtft path — kept as fallback
dtoverlay=fbtft,spi0-0,st7789v,width=170,height=320,speed=40000000,fps=30,dc_pin=25,rotate=90

# GPU / DRM
dtoverlay=vc4-kms-v3d
max_framebuffers=2
disable_fw_kms_setup=1

# System
arm_64bit=1
disable_overscan=1

# No cardputerzero-overlay — we use a custom overlay below
[all]
dtoverlay=rpi3b-flint-overlay
```

> `arm_boost=1` is omitted — it applies only to CM0. On BCM2837 it has no effect.  
> `camera_auto_detect=0` and `dtoverlay=imx219` are omitted — no camera in this setup.  
> `dtoverlay=cardputerzero-overlay` is replaced by `rpi3b-flint-overlay` (see next section).

---

## Custom Device Tree overlay — `rpi3b-flint-overlay.dts`

The stock `cardputerzero-overlay` references the M5IOE1 expander for backlight and display RST.
This custom overlay removes that dependency and wires RST to GPIO27 directly.

Save the following as `rpi3b-flint-overlay.dts`:

```dts
/dts-v1/;
/plugin/;

/ {
    compatible = "brcm,bcm2837";

    /* fragment@0 — GPIO pin assignments */
    fragment@0 {
        target = <&gpio>;
        __overlay__ {
            st7789v_pins: st7789v_pins {
                brcm,pins = <25 27>;        /* DC=GPIO25, RST=GPIO27 */
                brcm,function = <1>;        /* output */
            };
        };
    };

    /* fragment@1 — SPI0: ST7789V display on CS0 */
    fragment@1 {
        target = <&spi0>;
        __overlay__ {
            #address-cells = <1>;
            #size-cells = <0>;

            /* disable default spidev on CS0 */
            spidev@0 {
                status = "disabled";
            };

            st7789v: st7789v@0 {
                compatible = "sitronix,st7789v_m5stack";
                reg = <0>;                  /* CS0 */
                spi-max-frequency = <50000000>;
                dc-gpios = <&gpio 25 0>;
                reset-gpios = <&gpio 27 1>; /* active-low RST on GPIO27 */
                width = <170>;
                height = <320>;
                x-offset = <0>;
                y-offset = <35>;
                rotation = <90>;
                fps = <60>;
            };
        };
    };
};
```

### Compile and deploy the overlay

```bash
# Install the device tree compiler if not present
sudo apt install device-tree-compiler

# Compile
dtc -@ -I dts -O dtb -o rpi3b-flint-overlay.dtbo rpi3b-flint-overlay.dts

# Deploy to the overlays directory
sudo cp rpi3b-flint-overlay.dtbo /boot/firmware/overlays/

sudo reboot
```

---

## Verify the display after boot

```bash
# fbtft driver loaded
ls /dev/fb*
# Expected: /dev/fb0 or /dev/fb1

# DRM node present (if vc4-kms-v3d is active)
ls /dev/dri/
# Expected: card0, renderD128

# Quick framebuffer test — fills screen with a solid color
cat /dev/urandom > /dev/fb0
```

If `/dev/fb0` does not appear, check `dmesg` for SPI or fbtft errors:

```bash
dmesg | grep -E 'spi|fbtft|st7789'
```

---

## Keyboard — USB

Plug any standard USB keyboard into one of the RPi 3B+ USB-A ports. No configuration is needed —
the kernel HID driver handles it automatically.

flint maps physical keys to its internal key events. On a full USB keyboard the relevant bindings are:

| flint key | USB keyboard key |
|---|---|
| `UP` | Arrow Up |
| `DOWN` | Arrow Down |
| `LEFT` | Arrow Left |
| `RIGHT` | Arrow Right |
| `OK` | Enter |
| `BACK` | Escape |
| `KEY1` – `KEY5` | F1 – F5 |

These bindings are defined in [flint/input/](../../flint/input/) and apply to the pygame input
backend used in emulator mode. On the real device with evdev, the same logical keys are produced by
the TCA8418 keymap; a USB keyboard produces identical events through the kernel HID layer.

---

## Install and run flint

```bash
# Clone the repository
git clone https://github.com/flintdevices/flint.git
cd flint

# Create venv and install dependencies
make setup

# Run in emulator mode (pygame window — no hardware HAL needed)
make run

# Run with real HAL targeting the RPi display
FLINT_TARGET=cardputer make run-real
```

> On first run with a real display, set `FLINT_HEADLESS=0` and ensure `SDL_FBDEV=/dev/fb0` (or
> the correct framebuffer node) is exported if pygame does not find the display automatically.

---

## Differences in HAL behavior vs. the real CardputerZero

| HAL feature | CardputerZero | RPi 3B+ setup |
|---|---|---|
| `sys_backlight(level)` | PY32/M5IOE1 PWM → kernel sysfs | No-op — backlight always on |
| `sys_display_reset()` | PYG5 via M5IOE1 | GPIO27 direct (handled by display driver) |
| Keyboard input | TCA8418 evdev (`/dev/input/eventX`) | USB HID evdev (same interface, different device path) |
| Battery / charging | BQ27220 + IP2316 via I²C | Not available |
| Audio | ES8389 + AW8737A | Not available |
| Wi-Fi / BT | CM0 built-in (same BCM stack) | BCM43438 — same Linux driver (`brcmfmac`) |

Tools that call `ctx.hal.sys_backlight()` will silently succeed (mock behavior) — no crash, no
brightness change. All other tools behave identically on both targets.

---

## Troubleshooting

### No HDMI video at all / board appears to boot-loop

Mount the boot partition (`bootfs`) on another machine and check `config.txt` for a `kernel=`
line (it should not be there). Older builds of this image could ship `kernel=u-boot.bin`, left
over from `pi-gen`'s upstream CardputerZero stage — that U-Boot binary is built for the real
CardputerZero's Compute Module (BCM2835/CM0), not this board's BCM2837, and the board resets
before Linux (or any video output) ever starts. If you see this, you have a stale image built
before this was fixed — rebuild from a current checkout (`stage-flint/00-flint/01-run.sh` strips
`kernel=u-boot.bin` and the matching `u-boot*.bin` files). A monitor on HDMI is the fastest way to
tell this apart from a display-wiring problem: with the bad `kernel=` line you'll see either
nothing at all or a U-Boot banner mentioning `raspberrypi,0-compute-module`/reset messages; with
it fixed, HDMI shows the normal kernel boot/login console (useful for debugging even after this
fix, if the SPI panel itself isn't showing anything).

### Display shows nothing after boot

1. Double-check wiring against the table above, especially DC (GPIO25) and CS (GPIO8).
2. Confirm `rpi3b-flint-overlay.dtbo` is in `/boot/firmware/overlays/` and the `config.txt`
   `dtoverlay=` line matches the filename exactly (no `.dtbo` extension in the config).
3. Run `dmesg | grep -i spi` — look for the driver binding message.
4. If using a 240×240 or 240×280 module instead of 320×170, adjust `width`/`height`/`y-offset`
   in the overlay and the `fbtft` line in `config.txt`.

### pygame cannot open display

```bash
export SDL_VIDEODRIVER=fbcon
export SDL_FBDEV=/dev/fb0
python3 -m flint
```

### USB keyboard not detected

```bash
lsusb          # verify the keyboard appears
ls /dev/input/ # find the event device
evtest /dev/input/event0  # confirm key events
```
