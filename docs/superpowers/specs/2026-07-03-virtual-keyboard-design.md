# Virtual keyboard over SSH — design

## Problem

The RPi 3B+ flint image has no physical keyboard. APPLaunch and flint both require an
evdev keyboard device to receive any input — with none attached, the device is
uncontrollable except via SSH shell (which already works: `stage-flint` sets up
NetworkManager Wi-Fi + SSH). This design adds a way to drive APPLaunch/flint themselves
(not just a shell) over that same SSH connection, with no new hardware.

## Existing infrastructure this reuses (verified against current code, not assumed)

- `stage-flint/files/99-flint-usb-keyboard.rules`: a udev rule that symlinks *any* evdev
  node with `ID_INPUT_KEYBOARD=1` to `/dev/input/by-path/platform-3f804000.i2c-event`
  (APPLaunch's hardcoded path) and to `/dev/input/cardputerzero-kbd`. It does not filter
  on USB — any device with that udev property qualifies, physical or virtual.
- `stage-flint/files/APPLaunch-flint-keyboard.conf`: sets
  `FLINT_KEYBOARD_DEVICE=/dev/input/cardputerzero-kbd` in APPLaunch's user-unit
  environment, inherited by flint (APPLaunch's child process).
- Known caveat (already documented in `01-run.sh`): libinput's path backend does not
  hotplug. The devlink must exist **before** APPLaunch starts, or a manual restart/relogin
  is needed.

A uinput-backed virtual keyboard that shows up with `ID_INPUT_KEYBOARD=1` satisfies this
rule with zero changes to it. The problem reduces to: (1) create that virtual device
early enough, and (2) get keystrokes from an SSH client into it.

## Verified corrections to the original proposal

- **`ydotool` is not in Debian trixie's main repo**, only `trixie-backports`
  (`1.0.4-2~bpo13+1`) and `sid`. Confirmed via packages.debian.org — plan accordingly,
  don't just add `ydotool` to `00-packages`.
- **The Debian package ships a systemd *user* unit** (`/usr/lib/systemd/user/ydotool.service`),
  not a system unit. A user unit only starts at login — the same moment APPLaunch's user
  unit starts — which races the "must exist before APPLaunch starts" requirement. We
  write our own system-level unit instead of using the packaged one.
- **`/dev/uinput` is `GROUP="input", MODE="0660"`** (upstream udev rule) — whoever runs
  `ydotoold` needs to be root or in `input`. Separately, the *output* evdev node's
  readability by an SSH-logged-in user is not guaranteed either: the `uaccess` ACL that
  normally grants console users access to input devices is a logind seat mechanism, and
  SSH sessions don't reliably get seat-assigned the same way. Both are addressed by
  making the relevant device nodes/sockets world-accessible (see Permissions below) —
  acceptable because SSH access to this box already implies full shell control, so this
  adds no new attack surface.

## Architecture

```
SSH client                              RPi 3B+
┌────────────────┐                      ┌───────────────────────────────┐
│ ssh pi@rpi       │                     │ ydotoold.service (system unit,  │
│ $ virtual-keyboard│──stdin (raw mode)─▶│  our own, root, starts at boot) │
└────────────────┘   curses capture      │   → creates uinput virtual dev  │
                      → ydotool key/type │        │ ID_INPUT_KEYBOARD=1     │
                      subprocess calls   │        ▼                        │
                                         │ existing udev rule (99-flint-   │
                                         │ usb-keyboard.rules, +MODE=0666) │
                                         │        │                        │
                                         │        ▼                        │
                                         │ /dev/input/cardputerzero-kbd    │
                                         │        │                        │
                                         │        ▼                        │
                                         │ APPLaunch / flint (evdev read)  │
                                         └───────────────────────────────┘
```

No existing behavior changes for a real physical USB keyboard — it satisfies the same
udev rule the same way and continues to work if one is ever plugged in.

## Components

### 1. `stage-flint/files/install-virtual-keyboard.sh` (single source of truth)

One idempotent shell script containing all the install logic, written so it can run in
two contexts unchanged:

- **Build time**: invoked via `on_chroot` from the new `stage-flint/00-flint/03-run.sh`
  sub-stage script, targeting the image's rootfs during the pi-gen build.
- **Live-patch time**: copied to an already-flashed, already-booted device and run
  directly via `sudo bash install-virtual-keyboard.sh` over the existing SSH shell
  access — no rebuild/reflash required to fix a device that's already in the field.

Logic:
1. Download `ydotool_1.0.4-2~bpo13+1_arm64.deb` — default URL
   `http://deb.debian.org/debian/pool/main/y/ydotool/ydotool_1.0.4-2~bpo13+1_arm64.deb`,
   overridable via `YDOTOOL_DEB_URL` env var, mirroring the existing `FLINT_DEB_URL`
   pattern — then `dpkg -i` + `apt-get install -f -y` to pull in any missing dependency.
   Skip re-download if `ydotoold` is already installed (idempotent for live-patch reruns).
2. Install `ydotoold.service` (our own system unit, below) to
   `/etc/systemd/system/ydotoold.service`.
3. Install `/usr/local/bin/virtual-keyboard` (mode 755).
4. Write/overwrite `/etc/udev/rules.d/99-flint-usb-keyboard.rules` with the `MODE="0666"`
   addition (see below).
5. `systemctl enable ydotoold.service` always. Additionally, only if running on a live
   system with systemd actually active as PID 1 (test: `[ -d /run/systemd/system ]` —
   false inside a pi-gen chroot, true on a booted device) — `udevadm control --reload-rules
   && udevadm trigger`, `systemctl daemon-reload`, and `systemctl start
   ydotoold.service`, so a live-patched device doesn't need a reboot to pick this up.

### 2. `stage-flint/00-flint/03-run.sh` (new pi-gen sub-stage script)

Thin wrapper: copies `install-virtual-keyboard.sh` into the chroot and runs it via
`on_chroot`. Keeps `01-run.sh`/`02-run.sh` untouched.

### 3. `stage-flint/files/ydotoold.service` (new, our own unit — not the packaged one)

```ini
[Unit]
Description=ydotoold virtual input daemon
After=local-fs.target

[Service]
ExecStart=/usr/bin/ydotoold --socket-path /tmp/.ydotool_socket --socket-perm 0666
Restart=always

[Install]
WantedBy=multi-user.target
```

System-level so it starts at boot, before any login — satisfies the no-hotplug
constraint on APPLaunch's side.

**Socket path pinned explicitly, verified against `ydotool` v1.0.4 source
(`Client/ydotool.c`, `Daemon/ydotoold.c`) rather than assumed:** the client resolves the
socket path as `$YDOTOOL_SOCKET` → else `$XDG_RUNTIME_DIR/.ydotool_socket` → else
`/tmp/.ydotool_socket`. Our daemon runs as a root system service (no `XDG_RUNTIME_DIR`),
so it lands on `/tmp/.ydotool_socket` by default — but an SSH-logged-in user's shell
normally *does* have `XDG_RUNTIME_DIR=/run/user/<uid>` set by logind, which would make the
`ydotool` client look in the wrong place and silently fail to connect. Fixed by pinning
`--socket-path /tmp/.ydotool_socket` on the daemon and `YDOTOOL_SOCKET=/tmp/.ydotool_socket`
in `virtual-keyboard`'s own environment, so neither side depends on `XDG_RUNTIME_DIR`
being absent/present.

### 4. Edit to `stage-flint/files/99-flint-usb-keyboard.rules`

Add `MODE="0666"` to the existing `ACTION=="add|change", ...` line. Applies equally to a
future physical USB keyboard; not ydotool-specific.

### 5. `stage-flint/files/virtual-keyboard` (new, Python 3 + stdlib `curses`)

Run manually by the user over SSH after logging in. Behavior:

- Enters `curses` raw mode (`cbreak`, `noecho`, `keypad(True)` — the keypad flag makes
  curses decode arrow/function-key ANSI escape sequences into single key constants,
  avoiding a hand-rolled escape parser).
- Printable characters are buffered and flushed via `ydotool type "<buffer>"` — delegates
  character-to-keycode mapping to ydotool itself.
- Special keys (Enter, Backspace, Tab, Esc, arrows, Delete, Home/End, Page Up/Down) map
  through a fixed table of Linux input-event-codes to `ydotool key <code>:1 <code>:0`.
- **Ctrl+]** (byte `0x1D`) exits the mode and restores the terminal (via
  `curses.wrapper`'s built-in teardown) without forwarding that keystroke — chosen as the
  classic telnet/ssh escape character, unlikely to collide with anything the user
  actually wants to send.
- If the `ydotool`/`ydotoold` socket isn't reachable, fails fast with a clear error
  instead of silently dropping keystrokes.

## Permissions (explicit decision)

Everything on the input path — `ydotoold`'s control socket (`--socket-perm 0666`) and the
udev-created event node (`MODE="0666"`) — is left world-accessible rather than gated
behind group membership. This is a deliberate simplification for a single-user personal
device where SSH access already equals full root-equivalent shell control; adding group
gymnastics (and the associated "which user gets created at first boot" problem already
documented elsewhere in this repo for APPLaunch) would add complexity without adding real
security.

## Out of scope (unchanged from the original ask)

- The interactive first-boot username/password wizard still requires a physical keyboard
  once, before `virtual-keyboard` can be used (SSH isn't up yet at that point either).
- No visual feedback loop — the user still needs to look at the device's physical SPI
  screen to see the effect of forwarded keystrokes. Streaming the framebuffer (VNC/fbcat)
  is a separate, unaddressed feature.

## Verification plan (no unit tests in this repo — real build + real hardware, per CLAUDE.md)

- `udevadm info /dev/input/eventN` on the ydotoold-created device shows
  `ID_INPUT_KEYBOARD=1` and both expected `SYMLINK`s — confirms the untouched udev rule
  actually classifies a uinput device the same way it classifies a physical one (this was
  an assumption, not verified against real hardware/kernel behavior, going into this
  design).
- `systemctl status ydotoold` is active *before* any SSH login on a fresh boot.
- End-to-end: SSH in, run `virtual-keyboard`, confirm keystrokes reach APPLaunch (menu
  navigation) and flint (a running tool), using the physical screen to observe.
- Live-patch path: run `install-virtual-keyboard.sh` by hand over SSH on the
  already-flashed test device, confirm `ydotoold` comes up without a reboot and
  `virtual-keyboard` works immediately.
