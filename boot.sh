#!/bin/bash
#
# boot.sh — Post Init entry point on TrueNAS SCALE, and periodic self-heal
# from a cron job.
#
# Idempotent: loads the out-of-tree it87 module if it is missing, then makes
# sure the daemon is running. Safe to call every few minutes.
#
# Exits 0 even on failure so a broken module never blocks the boot; the fans
# simply stay on the chip's own curve.
set -u
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

DIR="$(cd "$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")" && pwd)"
MOD="$DIR/it87.ko"
KV="$(uname -r)"

log() { logger -t ugreen-fan "$*" 2>/dev/null || true; }

modprobe hwmon-vid 2>/dev/null || modprobe hwmon_vid 2>/dev/null || true

# Already loaded: just make sure the daemon is alive (cron self-heal).
if grep -q '^it87 ' /proc/modules 2>/dev/null; then
  "$DIR/fanctl" start >/dev/null 2>&1 || log "fanctl start failed"
  exit 0
fi

[ -f "$MOD" ] || { log "it87.ko missing in $DIR"; exit 0; }

# After a TrueNAS update the kernel changes and the prebuilt module no longer
# matches. Warn once per boot instead of retrying every five minutes.
built_for="$(modinfo -F vermagic "$MOD" 2>/dev/null | awk '{print $1}')"
if [ -n "$built_for" ] && [ "$built_for" != "$KV" ]; then
  flag="/var/run/ugreen-fan-vermagic-warned"
  if [ ! -e "$flag" ]; then
    log "it87.ko built for $built_for, running $KV — run $DIR/rebuild.sh"
    : > "$flag" 2>/dev/null || true
  fi
  exit 0
fi

insmod "$MOD" 2>/dev/null || { log "insmod failed for $KV"; exit 0; }
"$DIR/fanctl" start >/dev/null 2>&1 || log "fanctl start failed"
exit 0
