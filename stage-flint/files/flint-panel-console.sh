#!/bin/bash
# Route a text console onto the ST7789 SPI panel as early in boot as possible.
#
# Why: APPLaunch (what normally draws to the panel) is a *lingered user*
# service — it only starts once systemd-logind has brought up user@UID at the
# tail end of boot, so the panel stays black from power-on until then (~a
# minute on a cold boot). This paints boot/login console output onto the panel
# within a couple of seconds of the fbtft driver probing, giving immediate
# "the device is on and booting" feedback. When APPLaunch later opens the same
# framebuffer it simply paints over this console — no conflict.
#
# stage2/05-cardputerzero ships a udev rule (99-cardputer-zero-lcd.rules) that
# creates a stable /dev/fb_lcd symlink to whichever /dev/fbN is the ST7789
# (matched by driver name, not by probe order). We resolve that to its numeric
# index and hand it to con2fbmap, which maps a virtual terminal to an fb by
# number.

set -u

FB_SYMLINK="/dev/fb_lcd"

# The SPI panel is probed by the fbtft driver during kernel/module init, which
# can land slightly after this unit starts — wait a bounded time for it.
for _ in $(seq 1 20); do
    [ -e "${FB_SYMLINK}" ] && break
    sleep 0.5
done

if [ ! -e "${FB_SYMLINK}" ]; then
    logger -t flint-panel-console "${FB_SYMLINK} never appeared; skipping panel console"
    exit 0
fi

# /dev/fb_lcd -> /dev/fbN ; extract N for con2fbmap.
FBDEV=$(readlink -f "${FB_SYMLINK}")
FBIDX=${FBDEV##*/dev/fb}

case "${FBIDX}" in
    ''|*[!0-9]*)
        logger -t flint-panel-console "could not resolve fb index from ${FBDEV}; skipping"
        exit 0
        ;;
esac

# Map tty1 (the active VT that carries console output) to the panel's fb.
if con2fbmap 1 "${FBIDX}"; then
    # Give the user something to see immediately rather than a bare cursor.
    printf '\n  flint booting...\n' > /dev/tty1 2>/dev/null || true
    logger -t flint-panel-console "mapped tty1 -> fb${FBIDX} (${FB_SYMLINK})"
else
    logger -t flint-panel-console "con2fbmap failed for fb${FBIDX}"
fi

exit 0
