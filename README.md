# Quiet, drive-aware fan control for the UGREEN DXP6800 Pro on TrueNAS SCALE

The DXP6800 Pro has two 92 mm chassis fans and one CPU fan, all behind an
ITE **IT8613E** Super I/O chip. On TrueNAS the stock firmware curve ignores the
drives completely: the chip only looks at its own CPU/PECI sensor, and on this
board it hunts — one case fan sat at 100 % while the other idled around 20 %,
with the HDDs at 54–59 °C.

This project replaces that with a stable, drive-temperature-driven zone for
**both chassis fans** and leaves the CPU fan alone. On the reference machine it
settles at 51–56 °C on the drives with the case fans around 1300–1470 rpm —
quieter than stock and a few degrees cooler.

It is deliberately small: a shell daemon reading sysfs, no `lm-sensors`, no
`fancontrol`, no systemd units (TrueNAS has a read-only root filesystem).

## How it works

| Channel | Fan | Controlled by |
|---|---|---|
| `pwm2` | CPU fan | **not touched** — the chip's own automatic curve follows PECI and works fine |
| `pwm3` | rear-right 92 mm case fan | this daemon |
| `pwm4` | rear-left 92 mm case fan | this daemon |
| `pwm5` | unpopulated header | not touched |

- The zone input is the hottest `drivetemp` sensor (SATA HDDs). NVMe can be
  folded in with `INCLUDE_NVME=1`, but on this chassis it is never the hottest.
- The curve is a list of `temp:pwm` points with linear interpolation, clamped
  to `PWM_MIN..255` (`PWM_MIN=80`, ≈31 %, because below that the NF-A9 stops
  moving useful air).
- A 2 °C / 24-count deadband stops the fans from hunting.
- Manual mode is re-asserted every 5 minutes even if nothing changed — the EC
  has been seen to drop a channel back to automatic on its own.
- Fail-safe: if the drive temperature cannot be read, the fans go to 100 %.
- On `fanctl stop` (or TERM) both channels are handed back to the chip (`auto`).

## Tested on

- UGREEN DXP6800 Pro, 6 × SATA HDD, 2 × Noctua NF-A9 (stock fans replaced)
- TrueNAS SCALE 25.10.8, kernel `6.12.113-production+truenas`
- IT8613E at `0xa30`, revision 12, exposed as `it8613`

The `it87` driver that ships with that kernel does **not** know the IT8613E at
all (its chip table has no entry for it), so an out-of-tree module is required.
`rebuild.sh` builds it from the
[IT-Kuny/UGREEN-DXP-FAN-NAS-Driver](https://github.com/IT-Kuny/UGREEN-DXP-FAN-NAS-Driver)
sources inside a container — nothing is installed into the TrueNAS rootfs.

## Measured behaviour

PWM → RPM on the Noctua NF-A9 (both case fans, linear enough to tune by hand):

| PWM | 40 | 60 | 80 | 100 | 120 | 140 | 160 | 180 | 200 | 220 | 240 | 255 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| rpm | 311 | 510 | 695 | 874 | 1040 | 1207 | 1360 | 1503 | 1646 | 1781 | 1906 | 2014 |

Temperature at steady state (same 6 drives, same room):

| Case PWM | rpm | HDD max | chassis |
|---|---|---|---|
| 20 % (stock chip auto) | ~1300–2030, hunting | 54–59 °C | 47–51 °C |
| 31 % | ~710 | 56–57 °C, still climbing | 47–51 °C |
| 50 % | ~1100 | 54–55 °C | 45–47 °C |
| 67 % | ~1470 | 56 °C | 47 °C |
| 98 % | ~2000 | 54 °C | 43–45 °C |

Going from 50 % to 100 % buys only 1–2 °C, so the default curve stays near
55–70 % and ramps only when the drives are genuinely hot. The real win over
stock is stability and noise, not a huge temperature drop.

Raw measurements: [`docs/measurements.md`](docs/measurements.md).

## Requirements

- TrueNAS SCALE 25.10.x with the `production+truenas` kernel (the build script
  uses the headers TrueNAS already ships)
- Docker (used only to compile the module; no host packages are installed)
- root access
- the fan wiring above (i.e. a DXP6800 Pro, or a similar board you have mapped)

## Installation

```bash
FAN_DIR=/mnt/<pool>/scripts/ugreen-fan          # any dataset, NOT the boot pool
sudo mkdir -p /mnt/<pool>/scripts
sudo git clone <this-repo-url> "$FAN_DIR"
cd "$FAN_DIR"

sudo ./rebuild.sh        # builds it87.ko for the running kernel (needs Docker)
sudo ./fanctl start
sudo ./fanctl status
```

`fanctl status` should show `it8613`, both `pwm3`/`pwm4` in `manual` with a
sane value, and both fans spinning. Then make it survive reboots and upgrades.

### Post Init script

System → Advanced → Init/Shutdown Scripts → Add:

| Field | Value |
|---|---|
| Type | Command |
| Command | `/mnt/<pool>/scripts/ugreen-fan/boot.sh` |
| When | Post Init |
| Timeout | 30 |
| Enabled | yes |

### Cron Job (self-healing)

System → Advanced → Cron Jobs (called Tasks → Cron Jobs on older releases):

| Field | Value |
|---|---|
| Command | `/mnt/<pool>/scripts/ugreen-fan/boot.sh` |
| Run As | root |
| Schedule | every 5 minutes (`*/5 * * * *`) |
| Enabled | yes |

`boot.sh` is idempotent: it loads the module if it is missing and restarts the
daemon if it died. Running it every five minutes costs nothing and heals a
crashed daemon or a module that was unloaded.

## Tuning the curve

The whole curve is one array near the top of `ugreen-fancontrol.sh`:

```bash
CASE_CURVE=( "40:90" "46:110" "50:130" "55:160" "58:200" "61:235" "64:255" )
```

Each entry is `drive-temp-C:pwm`, `pwm` is 0–255. Values between points are
interpolated linearly; below the first point the first PWM is used, above the
last point the last one. `PWM_MIN=80` clamps everything below ≈31 %.

To pick your own points:

1. Look at your normal drive temperatures: `sudo ./fanctl temps`.
2. Find your noise floor. Run the daemon manually at a few duties:

   ```bash
   sudo ./fanctl stop          # hand fans back to the chip
   sudo ./fanctl set 140       # 55 %, ~1200 rpm; listen
   sudo ./fanctl set 180       # 71 %, ~1500 rpm
   ```

   `fanctl set` refuses values below 80 on purpose.
3. Put the highest duty you find acceptable at your normal temperature, and
   steepen the curve above it. Example presets:

   ```bash
   # quieter: accept a warmer chassis
   CASE_CURVE=( "40:80" "46:95" "50:110" "55:135" "58:170" "61:215" "64:255" )

   # default: balanced
   CASE_CURVE=( "40:90" "46:110" "50:130" "55:160" "58:200" "61:235" "64:255" )

   # cooler: more noise
   CASE_CURVE=( "40:110" "46:130" "50:150" "55:180" "58:220" "61:245" "64:255" )
   ```

4. Apply: `sudo ./fanctl restart`, then check `fanctl status` and `fanctl log`.

The deadband (2 °C or 24 PWM counts) is in the main loop; do not make it
smaller than 1 °C or the fans will audibly oscillate.

## Persistence on TrueNAS

Everything lives on a pool and is registered in the TrueNAS configuration
database, because `/` and `/usr` are read-only and are replaced on every
update:

| Layer | Location | Reboot | SCALE update |
|---|---|---|---|
| scripts, `it87.ko`, `src/` | pool dataset | yes | yes |
| module load + daemon start | Init/Shutdown Script | yes | yes |
| crash recovery | Cron Job → `boot.sh` | yes | yes |
| manual-mode re-assert | inside the daemon | yes | yes |

The same pattern is used by
[miskcoo/ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller)
on TrueNAS — binaries on a pool, execution through the middleware, periodic
re-apply. The difference is that the LED controller talks to its MCU over i2c
from userspace and needs no kernel module, while fan control has to go through
the IT8613E driver.

## After a TrueNAS SCALE update

The kernel changes and the old `it87.ko` no longer matches. `boot.sh` notices
this (vermagic mismatch), logs one line and leaves the fans on the chip's
automatic curve instead of retrying every five minutes. To restore control:

```bash
sudo /mnt/<pool>/scripts/ugreen-fan/rebuild.sh
sudo /mnt/<pool>/scripts/ugreen-fan/fanctl restart
```

`rebuild.sh` needs no host packages: it copies the kernel headers to a work
directory on the pool (not `/tmp`, which is mounted `noexec` on TrueNAS),
compiles inside a `debian:bookworm-slim` container with the same gcc 12.2 the
kernel was built with, and drops the new `it87.ko` next to the scripts.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `fanctl status`: `it8613: not found` | module not loaded — `sudo ./fanctl diagnose`, `dmesg \| grep -i it87` |
| `insmod: Invalid module format` | module built for another kernel — run `rebuild.sh` |
| `it87: Unknown symbol vid_from_reg` | `hwmon-vid` not loaded; `boot.sh` does `modprobe hwmon-vid` first |
| `pwm3/4` fall back to `auto` | EC reset the channel; the daemon re-asserts within 5 minutes |
| Fans don't change at all | something else is writing (`fancontrol`), or the chip is not in manual mode |
| `Function not implemented` in the log | known transient `execve()` failure on this platform for backgrounded binaries. The daemon avoids external binaries in its loop and uses a FIFO + `read -t` as its timer |
| `rebuild.sh`: `objtool: Permission denied` | work dir ended up on a `noexec` mount; the script uses `<dir>/.build` on the pool for this reason |

## Uninstall

```bash
sudo ./fanctl stop       # hands both channels back to the chip
sudo rmmod it87
```

Then delete the Init/Shutdown Script and the Cron Job in the UI. Nothing else
on the system was modified (the driver lives only on the pool).

## Credits

- [IT-Kuny/UGREEN-DXP-FAN-NAS-Driver](https://github.com/IT-Kuny/UGREEN-DXP-FAN-NAS-Driver) —
  out-of-tree `it87` with UGREEN board support (GPL-2.0), itself based on the
  lm-sensors `it87` driver.
- The community DXP4800 Pro run sheet this project started from.
- [miskcoo/ugreen_leds_controller](https://github.com/miskcoo/ugreen_leds_controller) —
  the TrueNAS persistence pattern (pool + middleware + periodic re-apply).
- Fan→channel mapping and the DXP6800 specifics were confirmed on real hardware;
  see [IT-Kuny issue #6](https://github.com/IT-Kuny/UGREEN-DXP-FAN-NAS-Driver/issues/6).

Not affiliated with UGREEN. Fan control can cook hardware if misconfigured:
keep `PWM_MIN` at a speed where the fans actually spin, and watch temperatures
after any change.

## License

MIT for the scripts in this repository — see [LICENSE](LICENSE). The kernel
module is built from GPL-2.0 sources and is not vendored here.
