# Minimal image for compiling the DTS overlay without installing dtc locally.
# Used by build.sh when dtc is not available on the host.
#
# Usage (called by build.sh automatically if dtc is absent):
#   docker build -t flint-dtc . && \
#   docker run --rm -v $(pwd)/overlays:/overlays flint-dtc

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends device-tree-compiler && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /overlays

CMD ["dtc", "-@", "-I", "dts", "-O", "dtb", \
     "-o", "rpi3b-flint-overlay.dtbo", \
     "rpi3b-flint-overlay.dts"]
