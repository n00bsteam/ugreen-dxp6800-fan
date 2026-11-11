#!/bin/bash
#
# rebuild.sh — rebuild it87.ko for the currently running TrueNAS kernel.
#
# Builds inside a Debian bookworm container (same gcc 12.2 the TrueNAS kernel
# was built with). The host rootfs is never modified: headers are copied to a
# temporary directory, the compiler lives in the container.
#
# Run after every TrueNAS SCALE update, then: fanctl restart
set -euo pipefail

DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
KV="$(uname -r)"
SRC="$DIR/src"
KDIR="$(readlink -f "/lib/modules/$KV/build" 2>/dev/null || true)"
IT87_REPO="${IT87_REPO:-https://github.com/IT-Kuny/UGREEN-DXP-FAN-NAS-Driver.git}"

[ -n "$KDIR" ] && [ -f "$KDIR/Makefile" ] || {
  echo "ERROR: no kernel build tree for $KV (looked at /lib/modules/$KV/build)" >&2
  exit 1
}

# Fetch the driver source on first run (GPL-2.0, not vendored here).
if [ ! -f "$SRC/it87.c" ]; then
  echo "== driver source not found, fetching $IT87_REPO =="
  command -v git >/dev/null 2>&1 || { echo "ERROR: git is required to fetch the driver source" >&2; exit 1; }
  rm -rf "$DIR/.driver-src"
  git clone --depth 1 --recurse-submodules "$IT87_REPO" "$DIR/.driver-src" >/dev/null 2>&1 || {
    echo "ERROR: cannot clone $IT87_REPO (set IT87_REPO to a mirror)" >&2
    exit 1
  }
  mkdir -p "$SRC"
  cp "$DIR/.driver-src/it87/it87.c" "$DIR/.driver-src/it87/Makefile" "$SRC/" || {
    echo "ERROR: cloned repository has no it87/it87.c" >&2
    exit 1
  }
  rm -rf "$DIR/.driver-src"
fi

[ -f "$SRC/it87.c" ] || { echo "ERROR: source missing at $SRC" >&2; exit 1; }

# NOTE: /tmp is mounted noexec on TrueNAS, and kbuild runs host binaries
# (objtool) from the header tree — so the work tree must live on the pool.
WORK="$DIR/.build"
rm -rf "$WORK"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

echo "== copying headers for $KV =="
cp -a "$KDIR" "$WORK/kheaders"
cp /sys/kernel/btf/vmlinux "$WORK/kheaders/vmlinux" 2>/dev/null || true

echo "== building in container =="
docker run --rm \
  -v "$WORK/kheaders:/usr/src/linux-headers-$KV" \
  -v "$SRC:/src" \
  -w /src debian:bookworm-slim \
  bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc make dwarves libelf-dev bc perl && make TARGET=$KV -j2 modules"

cp "$SRC/it87.ko" "$DIR/it87.ko"
echo "== built $DIR/it87.ko for $KV =="
modinfo "$DIR/it87.ko" 2>/dev/null | grep -E '^(vermagic|filename)' || true
echo "Now run: fanctl restart   (or reboot)"
