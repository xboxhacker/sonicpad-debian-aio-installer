# SonicPad Debian AIO Installer

An all-in-one setup script for Creality SonicPads running the [SonicPad-Debian](https://github.com/Jpe230/SonicPad-Debian) image (Debian 11 Bullseye, Allwinner R818).

Automates the most common post-flash configuration tasks in a single run — no manual file editing required.

---

## What It Configures

| | What Gets Done |
|---|---|
| 🎥 **Nebula Camera** | Installs Crowsnest if missing, writes a working `crowsnest.conf` (YUYV/CPU, 1280x720 @ 15fps), and patches `ustreamer.sh` to stop MJPEG/HW auto-detection that conflicts with the SonicPad's EHCI USB controller |
| 📶 **WiFi Stability** | Disables XRadio power save (the #1 cause of long-print disconnections) and installs a systemd watchdog timer that auto-recovers `wlan0` every 2 minutes if connectivity drops |
| 📈 **Accelerometer** | Installs ARM toolchain and Python packages for ADXL345 input shaper calibration, builds the Klipper host MCU firmware if Klipper is present, and drops a ready-to-use `adxl345_sample.cfg` |
| 🛠️ **KIAUH** | Clones the [Klipper Installation And Update Helper](https://github.com/dw-0/kiauh) so you can install Klipper, Moonraker, Mainsail, Fluidd, KlipperScreen, and Crowsnest interactively |
| ⚡ **OS Performance Tuning** | `vm.swappiness=10` to keep Klipper in RAM, CPU governor forced to `performance` for step timing stability, `tmpfs` on `/tmp` and `/var/log` to reduce SD card writes, `noatime` on root filesystem, Klipper process priority boosted (`nice=-10`), and unused system services disabled |
| 🗂️ **Log Rotation** | `logrotate` configs for Klipper, Moonraker, Crowsnest, and the WiFi watchdog (daily, 5-day retention, gzip compressed), plus systemd journal capped at 64MB to protect SD card longevity |

---

## Requirements

- SonicPad flashed with [SonicPad-Debian](https://github.com/Jpe230/SonicPad-Debian) (Bullseye)
- SSH access to the pad
- Default credentials: user `sonic` / password `pad`
- Active internet connection on the pad

---

## Install

SSH into your SonicPad, then run:

```bash
cd ~ && git clone https://github.com/xboxhacker/sonicpad-debian-aio-installer.git
cd sonicpad-debian-aio-installer
chmod +x install.sh
./install.sh
```

The script performs a pre-flight check to detect what's already installed (Klipper, Crowsnest, printer_data), then walks through each section automatically with clear status output.

---

## After the Script

**Step 1 — Install the Klipper ecosystem via KIAUH**

```bash
~/kiauh/kiauh.sh
```

Install in this order for best results: **Klipper → Moonraker → Mainsail** (or Fluidd) **→ KlipperScreen → Crowsnest**

**Step 2 — Re-run the installer after Klipper is installed**

The accelerometer section needs Klipper present to build the host MCU firmware. If Klipper wasn't found on the first run, do this after KIAUH finishes:

```bash
cd ~/sonicpad-debian-aio-installer && ./install.sh
```

**Step 3 — Add accelerometer config to printer.cfg**

```bash
cat ~/printer_data/config/adxl345_sample.cfg
```

Copy the relevant section into your `printer.cfg`. Option A is for direct SPI wiring; Option B is for a USB MCU (RP2040, Arduino, etc.) which is the recommended approach for the R818.

**Step 4 — Reboot**

```bash
sudo reboot
```

---

## Verify Everything Works

**Camera stream:**
```bash
curl http://localhost:8080/state
```
Look for `"online": true` and `captured_fps` close to 30 with `queued_fps` at 15.

**WiFi watchdog:**
```bash
systemctl status wifi-watchdog.timer
/usr/sbin/iw dev wlan0 get power_save   # should say: Power save: off
```

**WiFi watchdog log:**
```bash
tail -f /var/log/wifi-watchdog.log
```

**CPU governor:**
```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   # should say: performance
```

**Swappiness:**
```bash
cat /proc/sys/vm/swappiness   # should say: 10
```

**tmpfs mounts:**
```bash
mount | grep tmpfs   # should show /tmp and /var/log
```

**Accelerometer** — run in Mainsail/Fluidd console:
```
ACCELEROMETER_QUERY
SHAPER_CALIBRATE
SAVE_CONFIG
```

---

## What the OS Tuning Does

| Tweak | Default | After | Why |
|---|---|---|---|
| `vm.swappiness` | 60 | 10 | Keeps Klipper's Python process in RAM, reduces latency spikes from swap activity during long prints |
| CPU governor | `ondemand` | `performance` | Prevents clock scaling micro-stutters in Klipper step generation |
| `/tmp` | SD card | tmpfs (64MB RAM) | Removes high-churn temp writes from SD card |
| `/var/log` | SD card | tmpfs (32MB RAM) | Keeps log writes in RAM, dramatically extends SD card life |
| `noatime` | enabled | disabled | Stops the kernel writing access timestamps on every file read — big reduction in SD card wear |
| Klipper priority | default | `nice=-10`, `ionice` RT | Klipper wins CPU/IO contention against background tasks like apt and logging |
| Disabled services | running | stopped/disabled | `bluetooth`, `avahi-daemon`, `ModemManager`, `apt-daily` timers — frees RAM and eliminates mid-print apt runs |
| systemd journal | unbounded | 64MB cap | Prevents journal from slowly consuming the entire SD card on a R/W filesystem |

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Camera shows "No Signal" | Confirm `/dev/video0` exists: `ls /dev/video*`. If missing, the Nebula camera isn't detected at USB level — check the cable. |
| `crowsnest.conf` not written | `~/printer_data/config` doesn't exist yet — install Moonraker via KIAUH first, then re-run the script. |
| `ustreamer.sh` patch failed | Manually edit `~/crowsnest/libs/ustreamer.sh` around line 58 — change `-m MJPEG --encoder=HW` to `-m YUYV --encoder=CPU` |
| WiFi still dropping | Check `dmesg \| grep "sunxi-mmc sdc1.*err"` — excessive SDIO errors may point to a hardware or power supply issue beyond software fixes. |
| ADXL readings all zero | Verify wiring or USB MCU serial path in `printer.cfg`, then run `ACCELEROMETER_QUERY` in the console for live debug output. |
| KIAUH won't launch | Make sure `~/kiauh/kiauh.sh` is executable: `chmod +x ~/kiauh/kiauh.sh` |
| CPU governor not persisting | Check `/etc/rc.local` exists and is executable: `ls -la /etc/rc.local` |
| `/var/log` tmpfs not mounted | It mounts on reboot. To mount now: `sudo mount -t tmpfs -o size=32m tmpfs /var/log` |

---

## Notes

**Nebula Camera:** The Creality Nebula camera does not work with MJPEG on SonicPad-Debian due to the Allwinner vendor kernel's EHCI bandwidth scheduling limitations. YUYV at 1280x720 with CPU encoding is the proven working configuration.

**WiFi:** The SonicPad uses an XRadio chip over SDIO. `sunxi-mmc sdc1` errors in `dmesg` are normal and the driver recovers automatically. Disabling power save eliminates the most common source of actual print-interrupting disconnects.

**tmpfs and logs:** Because `/var/log` moves to RAM, log files do not persist across reboots by default. The logrotate configs compress and retain up to 5 days of rotated logs on the SD card. If you need persistent real-time logs, remove the `/var/log` tmpfs entry from `/etc/fstab`.

**Accelerometer on R818:** Most users connect the ADXL345 via a small USB MCU (RP2040 running Klipper firmware) rather than direct SPI GPIO, which is the more reliable path on this platform.

**KIAUH is interactive:** The script clones it but does not run it automatically — Klipper installation requires you to choose your printer's MCU, board type, etc.

---

## Credits

- [Jpe230/SonicPad-Debian](https://github.com/Jpe230/SonicPad-Debian) — the Debian port that makes all of this possible
- [dw-0/kiauh](https://github.com/dw-0/kiauh) — Klipper Installation And Update Helper
- [mainsail-crew/crowsnest](https://github.com/mainsail-crew/crowsnest) — camera streaming manager
- [pikvm/ustreamer](https://github.com/pikvm/ustreamer) — the underlying camera streamer

---

## License

GPL-3.0 — see [LICENSE](LICENSE) for details.