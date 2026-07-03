# Virtual Keyboard Over SSH Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user control APPLaunch/flint on the headless RPi 3B+ image entirely over
SSH, with no physical keyboard, by injecting evdev keystrokes through a `ydotoold`-backed
uinput virtual device that satisfies the existing USB-keyboard udev rule unchanged.

**Architecture:** A new pi-gen sub-stage (`stage-flint/00-flint/03-run.sh`) installs
`ydotool` (downloaded as a `.deb`, since it's not in Debian trixie's main repo), our own
system-level `ydotoold.service` (the packaged unit is user-scoped and starts too late),
and a `virtual-keyboard` curses-based CLI that forwards local SSH-terminal keystrokes to
`ydotool key`/`ydotool type` calls. All install logic lives in one idempotent shell
script (`install-virtual-keyboard.sh`) that both the pi-gen build and a manual live-SSH
patch of an already-flashed device can run unchanged.

**Tech Stack:** bash (pi-gen stage scripts), systemd unit files, udev rules, Python 3
stdlib `curses` (no new Python dependencies), `ydotool`/`ydotoold` 1.0.4 (Debian
trixie-backports `.deb`).

**Reference:** Design spec at
`docs/superpowers/specs/2026-07-03-virtual-keyboard-design.md` — read it first for the
full rationale (why each verified correction against the original proposal was needed).

There is no unit-test framework in this repo (per `CLAUDE.md`) — verification for shell
and systemd/udev files is syntax/lint checks (`bash -n`, `shellcheck` if available,
`systemd-analyze verify` if available); verification for the Python script is
`python3 -m py_compile`; final functional verification is a real pi-gen build followed by
real-hardware testing over SSH, plus a dry run of the live-patch path.

---

### Task 1: `ydotoold.service` unit file

**Files:**
- Create: `stage-flint/files/ydotoold.service`

- [ ] **Step 1: Write the unit file**

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

Socket path and permission flags (`--socket-path`, `--socket-perm`) verified against
`ydotool` v1.0.4's `Daemon/ydotoold.c` getopt table — see the design spec's "Socket path
pinned explicitly" note for why `--socket-path` must be set rather than left to the
default.

- [ ] **Step 2: Syntax-check the unit file**

Run: `systemd-analyze verify stage-flint/files/ydotoold.service 2>&1 || echo "systemd-analyze not available on this host — will be verified during the real build/boot instead"`

Expected: either no output (valid unit) or the fallback message if `systemd-analyze`
isn't installed on the dev machine. A real syntax error (e.g. `Failed to parse`) must be
fixed before continuing.

- [ ] **Step 3: Commit**

```bash
git add stage-flint/files/ydotoold.service
git commit -m "feat: add system-level ydotoold unit for virtual keyboard"
```

---

### Task 2: Make the keyboard event node world-readable

**Files:**
- Modify: `stage-flint/files/99-flint-usb-keyboard.rules`

- [ ] **Step 1: Add `MODE="0666"` to the existing rule**

Current content (line 20):
```
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEYBOARD}=="1", SYMLINK+="input/by-path/platform-3f804000.i2c-event", SYMLINK+="input/cardputerzero-kbd"
```

New content:
```
ACTION=="add|change", SUBSYSTEM=="input", KERNEL=="event*", ENV{ID_INPUT_KEYBOARD}=="1", SYMLINK+="input/by-path/platform-3f804000.i2c-event", SYMLINK+="input/cardputerzero-kbd", MODE="0666"
```

Also update the file's header comment (currently only explains the `SYMLINK+=` rationale)
to note the permission addition — append this paragraph after the existing comment block,
before the `ACTION==` line:

```
# MODE="0666": an SSH-logged-in user doesn't reliably get the console "uaccess" ACL
# that grants input-device read access to a locally logged-in seat user (that's a
# logind seat mechanism, not guaranteed for SSH sessions). Left world-readable rather
# than gated behind group membership — acceptable because SSH access to this box
# already implies full shell control, so this adds no new attack surface.
```

- [ ] **Step 2: Verify the file is still a single valid udev rule line plus comments**

Run: `grep -c '^ACTION==' stage-flint/files/99-flint-usb-keyboard.rules`
Expected: `1`

- [ ] **Step 3: Commit**

```bash
git add stage-flint/files/99-flint-usb-keyboard.rules
git commit -m "fix: make keyboard event node world-readable for SSH sessions"
```

---

### Task 3: `virtual-keyboard` CLI script

**Files:**
- Create: `stage-flint/files/virtual-keyboard`

- [ ] **Step 1: Write the script**

```python
#!/usr/bin/env python3
"""Forward local keystrokes to the RPi's virtual keyboard via ydotool.

Run this after SSH-ing into the device. Every key you press is forwarded
to ydotoold's virtual keyboard, behaving exactly as if a USB keyboard were
plugged into the RPi. Press Ctrl+] to exit and return to the shell.
"""
import curses
import os
import subprocess
import sys

EXIT_KEY = "\x1d"  # Ctrl+]

# ydotoold (see stage-flint/files/ydotoold.service) is pinned to this socket
# path explicitly. The ydotool client falls back to $XDG_RUNTIME_DIR, which an
# SSH login session normally has set — pin it here too so client and daemon
# always agree regardless of the invoking session's environment.
YDOTOOL_ENV = {**os.environ, "YDOTOOL_SOCKET": "/tmp/.ydotool_socket"}

# Linux input-event-codes (linux/input-event-codes.h) for keys curses reports
# as KEY_* int constants rather than printable characters.
SPECIAL_KEYS = {
    curses.KEY_UP: 103,
    curses.KEY_DOWN: 108,
    curses.KEY_LEFT: 105,
    curses.KEY_RIGHT: 106,
    curses.KEY_HOME: 102,
    curses.KEY_END: 107,
    curses.KEY_PPAGE: 104,  # Page Up
    curses.KEY_NPAGE: 109,  # Page Down
    curses.KEY_DC: 111,     # Delete
    curses.KEY_BACKSPACE: 14,
    curses.KEY_ENTER: 28,
}

# Control characters curses reports as plain one-character strings rather
# than KEY_* constants.
CONTROL_KEYS = {
    "\n": 28,    # Enter
    "\r": 28,    # Enter
    "\x7f": 14,  # Backspace (many terminals send DEL for Backspace)
    "\x08": 14,  # Backspace (BS)
    "\t": 15,    # Tab
    "\x1b": 1,   # Esc
}


def send_key(code):
    subprocess.run(
        ["ydotool", "key", f"{code}:1", f"{code}:0"],
        env=YDOTOOL_ENV, check=True,
    )


def send_text(text):
    subprocess.run(["ydotool", "type", "--", text], env=YDOTOOL_ENV, check=True)


def check_ydotool_available():
    try:
        subprocess.run(
            ["ydotool", "key", "0:0"],
            env=YDOTOOL_ENV, capture_output=True, check=True,
        )
    except FileNotFoundError:
        sys.exit("virtual-keyboard: 'ydotool' is not installed.")
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.decode(errors="replace") if exc.stderr else ""
        sys.exit(
            "virtual-keyboard: ydotool could not reach ydotoold "
            f"(is the service running?). Details: {stderr.strip()}"
        )


def run(stdscr):
    curses.cbreak()
    curses.noecho()
    stdscr.keypad(True)
    stdscr.addstr(0, 0, "virtual-keyboard active. Press Ctrl+] to exit.")
    stdscr.refresh()

    while True:
        ch = stdscr.get_wch()

        if isinstance(ch, str) and ch == EXIT_KEY:
            break

        if isinstance(ch, int):
            code = SPECIAL_KEYS.get(ch)
            if code is not None:
                send_key(code)
            continue

        code = CONTROL_KEYS.get(ch)
        if code is not None:
            send_key(code)
        else:
            send_text(ch)


def main():
    check_ydotool_available()
    curses.wrapper(run)


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Verify it compiles**

Run: `python3 -m py_compile stage-flint/files/virtual-keyboard`
Expected: no output, exit code 0.

- [ ] **Step 3: Verify it fails fast without ydotool installed (dev machine sanity check)**

Run: `python3 stage-flint/files/virtual-keyboard; echo "exit code: $?"`

Expected: `virtual-keyboard: 'ydotool' is not installed.` (or the "could not reach
ydotoold" message if `ydotool` happens to be installed on your dev machine without a
running daemon) and a non-zero exit code — confirms the fail-fast check runs before
`curses.wrapper` ever puts the terminal into raw mode.

- [ ] **Step 4: Commit**

```bash
git add stage-flint/files/virtual-keyboard
git commit -m "feat: add virtual-keyboard SSH keystroke forwarding script"
```

---

### Task 4: `install-virtual-keyboard.sh` — single-source-of-truth installer

**Files:**
- Create: `stage-flint/files/install-virtual-keyboard.sh`

This script is copied into the chroot and run via `on_chroot` at build time (Task 5), and
is also meant to be copied directly onto an already-flashed device and run by hand over
SSH (`sudo bash install-virtual-keyboard.sh`) to patch a device that predates this
feature, without a full rebuild/reflash.

- [ ] **Step 1: Write the script**

```bash
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
# ydotoold.service, virtual-keyboard, and 99-flint-usb-keyboard.rules.

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

# ── 5. Enable, and on a live system also apply immediately ───────────────────
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
```

- [ ] **Step 2: Syntax-check**

Run: `bash -n stage-flint/files/install-virtual-keyboard.sh`
Expected: no output, exit code 0.

Run: `command -v shellcheck >/dev/null && shellcheck stage-flint/files/install-virtual-keyboard.sh || echo "shellcheck not installed, skipping"`
Expected: either no warnings, or the fallback message. If shellcheck reports real issues
(unquoted variables that can word-split, etc.), fix them before continuing.

- [ ] **Step 3: Commit**

```bash
git add stage-flint/files/install-virtual-keyboard.sh
git commit -m "feat: add idempotent virtual-keyboard installer for build and live-patch use"
```

---

### Task 5: pi-gen sub-stage wrapper

**Files:**
- Create: `stage-flint/00-flint/03-run.sh`

- [ ] **Step 1: Write the wrapper**

```bash
#!/bin/bash -e
# Install ydotoold + virtual-keyboard for SSH-driven input (no physical
# keyboard needed). All actual install logic lives in
# files/install-virtual-keyboard.sh, which is also meant to be run by hand
# on an already-flashed device to patch it without a rebuild — see that
# script's header comment.

install -m 755 "${STAGE_DIR}/files/install-virtual-keyboard.sh" \
    "${ROOTFS_DIR}/tmp/install-virtual-keyboard.sh"
install -m 644 "${STAGE_DIR}/files/ydotoold.service" \
    "${ROOTFS_DIR}/tmp/ydotoold.service"
install -m 644 "${STAGE_DIR}/files/virtual-keyboard" \
    "${ROOTFS_DIR}/tmp/virtual-keyboard"
install -m 644 "${STAGE_DIR}/files/99-flint-usb-keyboard.rules" \
    "${ROOTFS_DIR}/tmp/99-flint-usb-keyboard.rules"

on_chroot << 'CHROOT'
bash /tmp/install-virtual-keyboard.sh /tmp
rm -f /tmp/install-virtual-keyboard.sh /tmp/ydotoold.service /tmp/virtual-keyboard /tmp/99-flint-usb-keyboard.rules
CHROOT
```

`YDOTOOL_DEB_URL`, if exported before the pi-gen build runs (Task 6), is inherited by the
`on_chroot` subshell the same way `FLINT_DEB_URL` already is.

- [ ] **Step 2: Make it executable**

Run: `chmod +x stage-flint/00-flint/03-run.sh`

This matches `01-run.sh`/`02-run.sh` (both `100755` in git) — pi-gen's `run_stage` silently
skips non-executable scripts, so this bit is load-bearing, not cosmetic (see `CLAUDE.md`'s
"Critical structural rule" section for the exact failure mode if this is missed).

- [ ] **Step 3: Verify the executable bit and syntax**

Run: `git status --short stage-flint/00-flint/03-run.sh && bash -n stage-flint/00-flint/03-run.sh`
Expected: `git status` shows the new file (mode 100755 once staged); `bash -n` produces no
output.

- [ ] **Step 4: Commit**

```bash
git add stage-flint/00-flint/03-run.sh
git commit -m "feat: wire virtual-keyboard installer into pi-gen stage-flint"
```

---

### Task 6: Wire `YDOTOOL_DEB_URL` through `build.sh`

**Files:**
- Modify: `build.sh:71-72`

- [ ] **Step 1: Add the export next to the existing `FLINT_DEB_URL` export**

Current (`build.sh:71-72`):
```bash
# Export FLINT_DEB_URL so it's available inside the pi-gen Docker container
export FLINT_DEB_URL="${FLINT_DEB_URL:-https://releases.flintdevices.dev/flint_latest_arm64.deb}"
```

New:
```bash
# Export FLINT_DEB_URL so it's available inside the pi-gen Docker container
export FLINT_DEB_URL="${FLINT_DEB_URL:-https://releases.flintdevices.dev/flint_latest_arm64.deb}"

# Same reasoning for YDOTOOL_DEB_URL (see stage-flint/files/install-virtual-keyboard.sh) —
# ydotool isn't in Debian trixie's main repo, only trixie-backports.
export YDOTOOL_DEB_URL="${YDOTOOL_DEB_URL:-http://deb.debian.org/debian/pool/main/y/ydotool/ydotool_1.0.4-2~bpo13+1_arm64.deb}"
```

- [ ] **Step 2: Verify syntax**

Run: `bash -n build.sh`
Expected: no output, exit code 0.

- [ ] **Step 3: Commit**

```bash
git add build.sh
git commit -m "feat: export YDOTOOL_DEB_URL override point in build.sh"
```

---

### Task 7: Wire `YDOTOOL_DEB_URL` through CI

**Files:**
- Modify: `.github/workflows/build.yml:106-111`

**Why:** `CLAUDE.md` explicitly flags that `build.sh` and this workflow's env wiring can
drift out of sync — do this in the same task as Task 6, not later.

- [ ] **Step 1: Add the env var to the "Build image" step**

Current (`.github/workflows/build.yml:106-111`):
```yaml
      - name: Build image
        run: |
          cd pi-gen
          sudo XZ_DEFAULTS="-T0" ./build.sh
        env:
          FLINT_DEB_URL: ${{ steps.deb_url.outputs.url }}
```

New:
```yaml
      - name: Build image
        run: |
          cd pi-gen
          sudo XZ_DEFAULTS="-T0" ./build.sh
        env:
          FLINT_DEB_URL: ${{ steps.deb_url.outputs.url }}
          YDOTOOL_DEB_URL: http://deb.debian.org/debian/pool/main/y/ydotool/ydotool_1.0.4-2~bpo13+1_arm64.deb
```

- [ ] **Step 2: Verify YAML syntax**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/build.yml'))" && echo "valid YAML"`
Expected: `valid YAML`. (If `pyyaml` isn't installed, run
`ruby -ryaml -e "YAML.load_file('.github/workflows/build.yml')" && echo "valid YAML"` as a
fallback, or visually diff the change since it's a two-line addition.)

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build.yml
git commit -m "ci: wire YDOTOOL_DEB_URL through the build workflow"
```

---

### Task 8: Document the feature in `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md` (append a new subsection after the existing "Wi-Fi comes up
  soft-blocked by design" section, before "Backlight is hardwired to 3.3V")

**Why:** This repo's `CLAUDE.md` documents every non-obvious hardware/boot constraint in
detail (see the existing U-Boot, libinput, Wi-Fi sections) — a future reader debugging
"why doesn't my keypress reach flint over SSH" needs the same kind of trail the USB
keyboard fix already left.

- [ ] **Step 1: Append the section**

Insert after the paragraph ending "...check `nmcli radio wifi` and `nmcli device status`
before assuming it's an rfkill or credentials problem." and before "Backlight is
hardwired to 3.3V...":

```markdown
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
from the SSH terminal to the device; Ctrl+] exits. The `ydotool` client resolves its
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
```

- [ ] **Step 2: Verify the insertion location**

Run: `grep -n "SSH-only control\|Backlight is hardwired" CLAUDE.md`
Expected: the new section's heading line number is lower than "Backlight is hardwired"'s
line number, confirming correct placement.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document the SSH virtual-keyboard feature in CLAUDE.md"
```

---

### Task 9: Real build and hardware verification

**Files:** none (verification only — this repo has no unit-test runner; per `CLAUDE.md`,
an actual image build plus real-hardware testing is the only way to validate pi-gen stage
changes).

- [ ] **Step 1: Run a local build**

Run: `./build.sh`

Expected: build completes and produces `pi-gen/deploy/*.img.xz`. Watch the build log for
`Begin /pi-gen/stage-flint/00-flint/03-run.sh` — its absence would mean the sub-stage
didn't run at all (the exact silent-skip failure mode documented in `CLAUDE.md`'s
"Critical structural rule" section).

If iterating after a build that already reached `stage2`, use `CONTINUE=1 ./build.sh`
instead to skip re-bootstrapping — see `CLAUDE.md`'s "Local builds on a non-arm64 host"
section.

- [ ] **Step 2: Inspect the built image without flashing**

Run: `pi-gen/tools/verify-image.sh pi-gen/deploy/*.img` (or the `.img.xz`, decompressed
first if the tool requires it — check `--help`)

Expected: confirms `ydotool`/`ydotoold`, `/usr/local/bin/virtual-keyboard`,
`/etc/systemd/system/ydotoold.service`, and the updated
`/etc/udev/rules.d/99-flint-usb-keyboard.rules` are present in the rootfs, and that
`ydotoold.service` is enabled (symlinked under `multi-user.target.wants/`).

- [ ] **Step 3: Flash and boot on real hardware**

Flash the image, boot the RPi 3B+, complete the one-time physical-keyboard first-boot
wizard (documented limitation, unchanged by this feature — see the design spec's "Out of
scope" section), then:

```bash
ssh <user>@<device-ip-or-hostname>.local
systemctl status ydotoold.service   # should already be active, no login needed to start it
udevadm info /dev/input/cardputerzero-kbd | grep ID_INPUT_KEYBOARD  # confirms the
                                                                     # uinput device is
                                                                     # classified the same
                                                                     # way a physical
                                                                     # keyboard would be —
                                                                     # this was an
                                                                     # unverified
                                                                     # assumption in the
                                                                     # design, confirm it
                                                                     # here
virtual-keyboard
```

Expected: typing after `virtual-keyboard` starts navigates APPLaunch's menu and/or
controls a running flint tool, observed on the device's physical SPI screen. Ctrl+] exits
cleanly back to the SSH shell prompt.

- [ ] **Step 4: Verify the live-patch path on the same device**

Since the device above was already flashed with this feature, live-patch verification
needs a *previous* image (or `git stash`/checkout the pre-feature commit, rebuild, reflash
a spare card, then patch it live) — if a spare card isn't available, at minimum confirm
the idempotent-rerun behavior on the already-patched device:

```bash
scp stage-flint/files/install-virtual-keyboard.sh stage-flint/files/ydotoold.service \
    stage-flint/files/virtual-keyboard stage-flint/files/99-flint-usb-keyboard.rules \
    <user>@<device>.local:/tmp/
ssh <user>@<device>.local 'sudo bash /tmp/install-virtual-keyboard.sh /tmp'
```

Expected: script prints "ydotool already installed, skipping download", reinstalls the
other files without error, prints "Applied live. Run 'virtual-keyboard' over SSH to
test.", and `virtual-keyboard` continues to work immediately without a reboot.

- [ ] **Step 5: Note results**

No commit for this task — it's verification, not a code change. If any step fails, return
to the relevant earlier task, fix, and re-run this task from Step 1.
