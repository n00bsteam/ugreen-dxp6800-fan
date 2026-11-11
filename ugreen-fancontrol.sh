#!/usr/bin/env bash
#
# ugreen-fancontrol.sh — quiet case-fan control for UGREEN DXP6800 Pro
# on TrueNAS SCALE with the out-of-tree it87 driver.
#
#   pwm3 -> rear-right 92 mm case fan (Noctua NF-A9)
#   pwm4 -> rear-left  92 mm case fan (Noctua NF-A9)
#   pwm2 -> CPU fan: deliberately NOT touched, the chip's own auto curve
#           follows coretemp/PECI and does a good job on this board.
#
# The case zone is driven by the hottest SATA drive (drivetemp).  Measured on
# this box: pwm 128 (~50 %, ~1100 rpm) holds the drives at 54-55 C and the
# chassis at 45-47 C; pwm 255 (~2000 rpm) buys about 1 C more, so the curve
# stays near 50 % until the drives are genuinely hot.
#
# Failsafe: unreadable drive temperature -> 100 %, never a silent stop.
set -uo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

INTERVAL=20
PWM_MIN=80                 # ~31 %: below this the NF-A9 stops moving useful air
PWM_MAX=255
CASE_CHANNELS=(3 4)
INCLUDE_NVME=0             # on this box NVMe stays ~5 C cooler than the HDDs

# drive temp(C):pwm   (255 = 100 %, 128 = 50 %, 80 = 31 %)
# 55 C -> ~1360 rpm (barely audible), 57 C -> ~1500 rpm, 60 C -> ~1900 rpm.
CASE_CURVE=( "40:90" "46:110" "50:130" "55:160" "58:200" "61:235" "64:255" )

LOG="${FAN_LOG:-/var/log/ugreen-fancontrol.log}"
PIDFILE="${FAN_PIDFILE:-/var/run/ugreen-fancontrol.pid}"

# bash builtin only — this box has an intermittent exec() glitch where
# ordinary backgrounded binaries occasionally fail with ENOSYS.
log() { local ts; printf -v ts '%(%F %T)T' -1; printf '[%s] [fanctl] %s\n' "$ts" "$*"; }

read_sysfs() {
  local v=""
  IFS= read -r v < "$1" 2>/dev/null || return 1
  printf '%s' "${v//$'\r'/}"
}

find_hwmon() {
  local d
  for d in /sys/class/hwmon/hwmon*; do
    [ -r "$d/name" ] || continue
    [ "$(read_sysfs "$d/name")" = "it8613" ] && { printf '%s' "$d"; return 0; }
  done
  return 1
}

milli_to_c() {
  local m="${1//[^0-9]/}"
  [ -n "$m" ] || return 1
  printf '%s' $((10#$m / 1000))
}

read_drive_temp() {
  local d name raw t max=""
  for d in /sys/class/hwmon/hwmon*; do
    [ -r "$d/name" ] || continue
    name="$(read_sysfs "$d/name")"
    case "$name" in
      drivetemp) ;;
      nvme) [ "$INCLUDE_NVME" = "1" ] || continue ;;
      *) continue ;;
    esac
    [ -r "$d/temp1_input" ] || continue
    raw="$(read_sysfs "$d/temp1_input")" || continue
    t="$(milli_to_c "$raw" || true)"
    [ -n "${t:-}" ] || continue
    [ "$t" -lt 1 ] && continue
    [ "$t" -gt 90 ] && continue
    if [ -z "$max" ] || [ "$t" -gt "$max" ]; then max="$t"; fi
  done
  [ -n "$max" ] && { printf '%s' "$max"; return 0; }
  return 1
}

pwm_for_temp() {
  local temp="$1"; shift
  local -a curve=("$@")
  local first_t first_p last_t last_p pt t p prev_t="" prev_p=""
  first_t="${curve[0]%%:*}"; first_p="${curve[0]##*:}"
  last_t="${curve[-1]%%:*}"; last_p="${curve[-1]##*:}"
  if [ "$temp" -le "$first_t" ]; then printf '%s' "$first_p"; return; fi
  if [ "$temp" -ge "$last_t" ]; then printf '%s' "$last_p"; return; fi
  for pt in "${curve[@]}"; do
    t="${pt%%:*}"; p="${pt##*:}"
    if [ -n "$prev_t" ] && [ "$temp" -ge "$prev_t" ] && [ "$temp" -le "$t" ]; then
      printf '%s' $(( prev_p + (p - prev_p) * (temp - prev_t) / (t - prev_t) ))
      return
    fi
    prev_t="$t"; prev_p="$p"
  done
  printf '%s' "$last_p"
}

set_manual_pwm() {
  local hw="$1" ch="$2" val="$3" en pwm got
  en="$hw/pwm${ch}_enable"; pwm="$hw/pwm${ch}"
  [ -w "$en" ] && [ -w "$pwm" ] || return 1
  printf '1\n' > "$en" 2>/dev/null || return 1
  printf '%s\n' "$val" > "$pwm" 2>/dev/null || return 1
  got="$(read_sysfs "$pwm" || true)"
  [ "$got" = "$val" ] || { printf '%s\n' "$val" > "$pwm" 2>/dev/null || true; }
  got="$(read_sysfs "$pwm" || true)"
  [ "$got" = "$val" ]
}

restore_auto() {
  local hw ch
  hw="$(find_hwmon || true)"
  [ -n "$hw" ] || return 0
  for ch in "${CASE_CHANNELS[@]}"; do
    printf '2\n' > "$hw/pwm${ch}_enable" 2>/dev/null || true
  done
}

# --- single instance -------------------------------------------------------
if [ -f "$PIDFILE" ]; then
  other="$(read_sysfs "$PIDFILE" || true)"
  if [ -n "${other:-}" ] && [ "$other" != "$$" ] && kill -0 "$other" 2>/dev/null; then
    log "already running (pid $other), exiting"
    exit 0
  fi
fi
echo "$$" > "$PIDFILE"

if [ "$(id -u)" -ne 0 ]; then
  log "ERROR: must run as root"
  exit 1
fi

HWMON="$(find_hwmon)" || { log "ERROR: it8613 hwmon not found (is it87 loaded?)"; exit 1; }

for ch in "${CASE_CHANNELS[@]}"; do
  [ -w "$HWMON/pwm${ch}" ] && [ -w "$HWMON/pwm${ch}_enable" ] \
    || { log "ERROR: pwm${ch} not writable"; exit 1; }
done

trap 'restore_auto; : > "$PIDFILE"; exit 0' TERM INT
trap 'restore_auto' EXIT

# Enter manual control immediately at a safe mid speed, before any sensor read.
for ch in "${CASE_CHANNELS[@]}"; do
  set_manual_pwm "$HWMON" "$ch" 130 || log "WARN: pwm${ch} did not enter manual mode"
done

log "started pid=$$ hwmon=$HWMON channels=${CASE_CHANNELS[*]} interval=${INTERVAL}s"

# This box intermittently fails exec() on ordinary binaries ("Function not
# implemented"), and a backgrounded `sleep` hits it constantly.  So the timer
# is a FIFO opened read-write in this process: `read -t` is a bash builtin and
# blocks for the timeout without ever forking or exec'ing anything.
FIFO="${FAN_FIFO:-/var/run/ugreen-fancontrol.fifo}"
setup_timer() {
  local i
  [ -p "$FIFO" ] || {
    for i in 1 2 3 4 5; do mkfifo -m 600 "$FIFO" 2>/dev/null && break; done
  }
  [ -p "$FIFO" ] || return 1
  exec 3<>"$FIFO" 2>/dev/null || return 1
  return 0
}
nap() {
  local t="$1" start=$SECONDS
  read -r -t "$t" -u 3 _ 2>/dev/null
  [ $((SECONDS - start)) -ge $((t - 1)) ]
}

if ! setup_timer; then
  log "ERROR: cannot create timer fifo $FIFO"
  restore_auto
  exit 1
fi

last_pwm=""; last_t=""; iter=0
while :; do
  iter=$((iter + 1))
  T="$(read_drive_temp || true)"
  if [ -z "${T:-}" ]; then
    log "WARN: drive temp unreadable — fail-safe 100 %"
    T=999
  fi

  PWM="$(pwm_for_temp "$T" "${CASE_CURVE[@]}")"
  [ "$PWM" -lt "$PWM_MIN" ] && PWM="$PWM_MIN"
  [ "$PWM" -gt "$PWM_MAX" ] && PWM="$PWM_MAX"

  apply=0
  # Re-assert manual mode every 5 minutes even if nothing changed: the EC has
  # been seen to drop a channel back to auto on its own.
  if [ $((iter % 15)) -eq 0 ]; then apply=1; fi
  if [ -z "$last_pwm" ] || [ "$T" = "999" ]; then
    apply=1
  else
    dt=$(( T > last_t ? T - last_t : last_t - T ))
    dp=$(( PWM > last_pwm ? PWM - last_pwm : last_pwm - PWM ))
    if [ "$dt" -ge 2 ] || [ "$dp" -ge 24 ]; then apply=1; fi
  fi

  if [ "$apply" = 1 ]; then
    for ch in "${CASE_CHANNELS[@]}"; do
      set_manual_pwm "$HWMON" "$ch" "$PWM" || log "WARN: write pwm${ch}=${PWM} failed"
    done
    last_pwm="$PWM"; last_t="$T"
    log "drv=${T}C pwm=${PWM} ($(( PWM * 100 / PWM_MAX ))%) fan3=$(read_sysfs "$HWMON/fan3_input" 2>/dev/null || echo -) fan4=$(read_sysfs "$HWMON/fan4_input" 2>/dev/null || echo -)"
  fi

  nap "$INTERVAL" || { log "ERROR: timer stopped working"; restore_auto; exit 1; }
done
