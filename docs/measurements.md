# Measurements

All numbers from one DXP6800 Pro: 6 × SATA HDD, 2 × Noctua NF-A9 replacing the
stock 92 mm fans, CPU fan stock, TrueNAS SCALE 25.10.8, kernel
`6.12.113-production+truenas`, Plex transcode running in the background
(load average ~0.6–1.2).

## PWM → RPM (Noctua NF-A9)

Measured with the daemon stopped, both channels in manual mode, 7 s per step
after the previous step had settled:

| pwm | % of 255 | rpm |
|---|---|---|
| 40 | 16 | 311 |
| 60 | 24 | 510 |
| 80 | 31 | 695 |
| 100 | 39 | 874 |
| 120 | 47 | 1040 |
| 140 | 55 | 1207 |
| 160 | 63 | 1360 |
| 180 | 71 | 1503 |
| 200 | 78 | 1646 |
| 220 | 86 | 1781 |
| 240 | 94 | 1906 |
| 255 | 100 | 2014 |

The curve is close to linear, ~8 rpm per PWM count. Below ~40 the fan stalls,
hence `PWM_MIN=80` in the daemon.

## Steady-state comparison

Each phase was held for 8 minutes; `hdd_max` is the hottest `drivetemp` sensor,
`chassis` is the IT8613E board sensor (`temp2`).

| Phase | pwm3/pwm4 | rpm | hdd_max | chassis | notes |
|---|---|---|---|---|---|
| stock, chip auto | 51 / 51 | ~1300–2030 | 54–59 °C | 47–51 °C | channels hunting independently |
| chip auto after driver load | 255 / 60 | 2033 / 1355 | 56 °C | 48 °C | one fan at 100 %, one at 23 % |
| max | 250 / 250 | ~2000 | 54 °C | 43–45 °C | 8 min |
| middle | 128 / 128 | ~1110 | 54–55 °C | 45–47 °C | 8 min |
| low | 80 / 80 | ~710 | 55 → 57 °C, rising | 47 → 51 °C | 9 min, did not settle |
| installed curve at 56 °C | 173 / 173 | ~1470 | 56 °C | 47 °C | |
| installed curve at 54 °C | 154 / 154 | ~1320 | 54 °C | 43 °C | |

Conclusion: the chassis fans are not the bottleneck. 50 % → 100 % buys about
1–2 °C on the drives, so the default curve sits at 55–70 % and only ramps above
58 °C.

## Why the timer is a FIFO

On this platform, backgrounded processes intermittently fail `execve()` on
ordinary binaries with `Function not implemented` — including `sleep`. A
daemon that calls `sleep` in its loop can therefore spin at 100 % CPU (observed:
one core pinned, package temperature 100 °C).

`ugreen-fancontrol.sh` avoids executing anything in its loop:

- the timer is a FIFO (`/var/run/ugreen-fancontrol.fifo`) opened read-write and
  waited on with the bash builtin `read -t`;
- timestamps use `printf '%(%F %T)T'`, not `date`;
- temperature reads use bash builtins and sysfs only;
- the PID file is truncated with a redirection, not `rm`.

If the FIFO cannot be created, the daemon exits and restores the chip's
automatic mode rather than risking a busy loop.
