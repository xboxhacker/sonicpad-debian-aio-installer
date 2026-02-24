# SonicPad Debian AIO Installer

An all-in-one setup script for Creality SonicPads running the [SonicPad-Debian](https://github.com/Jpe230/SonicPad-Debian) image (Debian 11 Bullseye, Allwinner R818).

Automates the four most common post-flash configuration tasks in a single run — no manual file editing required.

---

## What It Configures

| | What Gets Done |
|---|---|
| 🎥 **Nebula Camera** | Installs Crowsnest if missing, writes a working `crowsnest.conf` (YUYV/CPU, 1280x720 @ 15fps), and patches `ustreamer.sh` to stop MJPEG/HW auto-detection that conflicts with the SonicPad's EHCI USB controller |
| 📶 **WiFi Stability** | Disables XRadio power save (the #1 cause of long-print disconnections) and installs a systemd watchdog timer that auto-recovers `wlan0` every 2 minutes if connectivity drops |
| 📈 **Accelerometer** | Installs ARM toolchain and Python packages for ADXL345 input shaper calibration, builds the Klipper host MCU firmware if Klipper is present, and drops a ready-to-use `adxl345_sample.cfg` |
| 🛠️ **KIAUH** | Clones the [Klipper Installation And Update Helper](https://github.com/dw-0/kiauh) so you can install Klipper, Moonraker, Mainsail, Fluidd, KlipperScreen, and Crowsnest interactively |

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

The script will perform a pre-flight check to detect what's already installed, then walk through each section automatically.

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

**Watchdog log:**
```bash
tail -f /var/log/wifi-watchdog.log
```

**Accelerometer** — run in Mainsail/Fluidd console:
```
ACCELEROMETER_QUERY
SHAPER_CALIBRATE
SAVE_CONFIG
```

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Camera shows "No Signal" | Confirm `/dev/video0` exists: `ls /dev/video*`. If missing, the Nebula camera isn't being detected at USB level — check the cable. |
| `crowsnest.conf` not written | `~/printer_data/config` doesn't exist yet — install Moonraker via KIAUH first, then re-run the script. |
| `ustreamer.sh` patch failed | Manually edit `~/crowsnest/libs/ustreamer.sh` around line 58 — change `-m MJPEG --encoder=HW` to `-m YUYV --encoder=CPU` |
| WiFi still dropping | Check `dmesg \| grep "sunxi-mmc sdc1.*err"` — excessive SDIO errors may point to a hardware or power supply issue beyond software fixes. |
| ADXL readings all zero | Verify wiring or USB MCU serial path in `printer.cfg`, then run `ACCELEROMETER_QUERY` in the console for live debug output. |
| KIAUH won't launch | Make sure `~/kiauh/kiauh.sh` is executable: `chmod +x ~/kiauh/kiauh.sh` |

---

## Notes

**Nebula Camera:** The Creality Nebula camera does not work with MJPEG on SonicPad-Debian due to the Allwinner vendor kernel's EHCI bandwidth scheduling limitations. YUYV at 1280x720 with CPU encoding is the proven working configuration.

**WiFi:** The SonicPad uses an XRadio chip over SDIO. `sunxi-mmc sdc1` errors in `dmesg` are normal and the driver recovers automatically. Disabling power save eliminates the most common source of actual print-interrupting disconnects.

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
