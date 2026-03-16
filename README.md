# SonicPad Debian AIO Installer

An all-in-one setup script for Creality SonicPads running the [SonicPad-Debian](https://github.com/Jpe230/SonicPad-Debian) image (Debian 11 Bullseye, Allwinner R818).

Automates the most common post-flash configuration tasks in a single run — no manual file editing required.

---

## What It Configures

| | What Gets Done |
|---|---|
| 🎥 **Nebula Camera** | Installs Crowsnest if missing, writes a working `crowsnest.conf` (YUYV/CPU, 1280x720 @ 15fps), and patches `ustreamer.sh` to stop MJPEG/HW auto-detection that conflicts with the SonicPad's EHCI USB controller |
| 📈 **Accelerometer** | Installs `libopenblas-dev` (required by numpy on ARM), installs `numpy<2` and `scipy` into the klippy virtualenv, optionally builds and flashes the Linux process MCU (y/n prompt), creates `klipper-mcu.service`, sets permanent `spidev2.0` permissions via udev, and drops a ready-to-use `adxl345_sample.cfg` |
| 🛠️ **KIAUH** | Clones the [Klipper Installation And Update Helper](https://github.com/dw-0/kiauh) so you can install Klipper, Moonraker, Mainsail, Fluidd, KlipperScreen, and Crowsnest interactively |
| 🖥️ **KlipperScreen Update** | If `~/KlipperScreen` exists as a clean git checkout, script runs `git pull --ff-only` automatically before applying KlipperScreen compatibility patches |
| ⚡ **OS Performance Tuning** | `vm.swappiness=10` to keep Klipper in RAM, CPU governor forced to `performance` for step timing stability, `tmpfs` on `/tmp` (with `mode=1777` for Xorg compatibility), `noatime` on root filesystem, Klipper process priority boosted (`nice=-10`), and unused system services disabled |
| 🗂️ **Log Rotation** | `logrotate` configs for Klipper, Moonraker, Crowsnest (daily, 5-day retention, gzip compressed), plus systemd journal capped at 64MB to protect SD card longevity |
| 🌐 **Static IP** | Optional. Prompts to configure static IP for Ethernet or WiFi via NetworkManager (prefers 802-11-wireless over p2p for WiFi) |
| 📶 **WiFi Stability** | Disables power save, preserves real MAC (no randomization), applies to existing connections. Reduces dropouts. |
| 📶 **WiFi P2P Disabled** | Unmanages p2p0, udev rule brings it down, `p2p_disabled` in wpa_supplicant. KlipperScreen uses wlan0. |
| 🔧 **Config Fixes** | KlipperScreen `screen_blanking` inline comments (incl. #~# section), KlipperScreen WiFi UI p2p0 filtering/IP label fixes, moonraker.conf `/home/biqu/` → `/home/sonic/` |

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
sudo apt-get install -y ca-certificates && sudo update-ca-certificates -f
git -c http.sslVerify=false clone https://github.com/xboxhacker/sonicpad-debian-aio-installer.git
cd sonicpad-debian-aio-installer
chmod +x install.sh
./install.sh
```

> **Note:** The `ca-certificates` line fixes SSL verification failures that are common on fresh SonicPad-Debian images. The script handles this automatically on subsequent runs.

The script performs a pre-flight check to detect what's already installed (Klipper, Crowsnest, printer_data), then walks through each section automatically with clear status output.

---

## Updating the Script

To pull the latest version and re-run:

```bash
cd ~/sonicpad-debian-aio-installer
git fetch --all
git reset --hard origin/main
chmod +x install.sh
./install.sh
```

The script is safe to re-run on an already-configured pad — it detects existing installs and skips steps that are already done.

> **Why `git reset --hard`?** A regular `git pull` can fail if the local copy has diverged. `reset --hard` forces the local copy to exactly match the remote, which is always what you want here.

---

## After the Script

**Step 1 — Install the Klipper ecosystem via KIAUH**

```bash
~/kiauh/kiauh.sh
```

Install in this order for best results: **Klipper → Moonraker → Mainsail** (or Fluidd) **→ KlipperScreen → Crowsnest**

**Step 2 — Re-run the installer after Klipper is installed**

The accelerometer section needs Klipper and the klippy virtualenv present to install numpy/scipy and build the host MCU. Re-run after KIAUH finishes:

```bash
cd ~/sonicpad-debian-aio-installer && ./install.sh
```

**Step 3 — Add accelerometer config to printer.cfg**

```bash
cat ~/printer_data/config/adxl345_sample.cfg
```

Merge the contents into your `printer.cfg`. The config uses the proven working settings for the SonicPad:

```ini
[mcu rpi]
serial: /tmp/klipper_host_mcu

[adxl345]
cs_pin: rpi:None
spi_speed: 2000000
spi_bus: spidev2.0

[resonance_tester]
accel_chip: adxl345
accel_per_hz: 70
probe_points:
    117.5, 117.5, 10
```

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

**klipper-mcu service:**
```bash
sudo systemctl status klipper-mcu
ls -la /tmp/klipper_host_mcu   # socket must exist before Klipper starts
```

**numpy import:**
```bash
~/klippy-env/bin/python -c "import numpy; print(numpy.__version__)"
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

## Accelerometer Notes

The accelerometer setup on the SonicPad has several non-obvious requirements that this script handles automatically:

- **libopenblas-dev** must be installed via apt before pip — numpy on ARM requires it and will fail to import without it even after a successful pip install
- **numpy must be pinned to `<2`** — numpy 2.x fails on this platform with missing libopenblas symbols. Version 1.26.x is the correct target
- **numpy must be installed into `~/klippy-env/`** — system pip3 is not used by Klipper. Installing there results in "Failed to import numpy" at runtime
- **`/dev/spidev2.0` is root-only by default** — a udev rule (`/etc/udev/rules.d/99-spidev.rules`) is installed to make it permanently accessible to the `sonic` user
- **`klipper-mcu.service`** must be running and `/tmp/klipper_host_mcu` must exist before Klipper starts — the service is configured to start `Before=klipper.service`
- **The host MCU binary is `klipper_mcu`** (underscore) at `/usr/local/bin/klipper_mcu` — this is where `sudo make flash` puts it in Klipper's Linux process MCU build

---

## Troubleshooting

| Problem | Fix |
|---|---|
| Camera shows "No Signal" | Confirm `/dev/video0` exists: `ls /dev/video*`. If missing, the Nebula camera isn't detected at USB level — check the cable. |
| `crowsnest.conf` not written | `~/printer_data/config` doesn't exist yet — install Moonraker via KIAUH first, then re-run the script. |
| `ustreamer.sh` patch failed | Manually edit `~/crowsnest/libs/ustreamer.sh` around line 58 — change `-m MJPEG --encoder=HW` to `-m YUYV --encoder=CPU` |
| `mcu rpi: Unable to open port` | `klipper-mcu` service isn't running. Check: `sudo systemctl status klipper-mcu` and `ls /tmp/klipper_host_mcu`. Build firmware: `cd ~/klipper && make menuconfig` (select Linux process), then `make && sudo make flash` |
| Moonraker "can't connect to Klipper" | `klippy_uds_address` may point to `/home/biqu/`. Fix: `sed -i 's|/home/biqu/|/home/sonic/|g' ~/printer_data/config/moonraker.conf` then `sudo systemctl restart moonraker` |
| KlipperScreen blank/crash | Check `screen_blanking` in KlipperScreen.conf — no inline comments. Fix: `sed -i 's/^\(screen_blanking:\s*\)\([0-9]*\).*/\1\2/' ~/printer_data/config/KlipperScreen.conf` and fix #~# section too |
| WiFi drops constantly | Power save + MAC randomization cause this. Script fixes it. If still dropping: `nmcli connection modify "YourSSID" wifi-sec.key-mgmt wpa-psk` (disables FT-PSK) |
| `Unable to open spi device` | spidev permissions not set. Run: `sudo chmod 666 /dev/spidev2.0` and verify udev rule exists at `/etc/udev/rules.d/99-spidev.rules` |
| `Failed to import numpy` | numpy not in klippy-env or wrong version. Run: `sudo apt-get install -y libopenblas-dev && ~/klippy-env/bin/pip uninstall numpy -y && ~/klippy-env/bin/pip install "numpy<2"` |
| numpy imports but SHAPER_CALIBRATE fails | scipy missing from klippy-env. Run: `~/klippy-env/bin/pip install scipy` |
| CPU governor not persisting | Check `/etc/rc.local` exists and is executable: `ls -la /etc/rc.local` |
| `/var/log` tmpfs not mounted | Mounts on reboot. To mount now: `sudo mount -t tmpfs -o size=32m tmpfs /var/log` |

---

## Changelog

### v1.5.2
- Added: `update_klipperscreen` — auto-updates `~/KlipperScreen` via `git pull --ff-only` when installed as a clean git checkout; safely skips on local changes/non-git checkout.

### v1.5.1
- Added: `fix_klipperscreen_wifi_p2p_ui` — patches KlipperScreen post-update to ignore `p2p*` interfaces in Network panel, suppress unmanaged `p2p` popup noise, and show IP label with the active interface.

### v1.5.0
- Added: Optional firmware build (y/n) — skip host MCU build if desired
- Added: Linux process MCU config for firmware build — backs up printer config, sets CONFIG_MACH_LINUX, restores after flash
- Added: WiFi stability — power save off, MAC preservation (no randomization), apply to existing connections
- Added: WiFi P2P disabled — unmanage p2p0, udev rule brings it down, p2p_disabled in wpa_supplicant
- Added: Static IP prefers 802-11-wireless over p2p, binds WiFi to wlan0
- Added: fix_moonraker_biqu_path — corrects /home/biqu/ → /home/sonic/ in moonraker.conf
- Added: fix_klipperscreen_config — strips inline comments from screen_blanking in [main] and #~# sections
- Added: fix_sonic_path_env — adds /usr/sbin to PATH (rfkill, etc.)
- Added: apt install usbutils, python3-serial, rfkill at script start

### v1.4.1
- Added: Optional static IP configuration. Script prompts after hostname setup to configure static IP for Ethernet or WiFi via NetworkManager.

### v1.4.0
- Removed: All WiFi-related setup (unique MAC, power save, watchdog, udev, NetworkManager configs). Configure WiFi manually via nmtui, KlipperScreen, or wpa_supplicant. Hostname setup retained.

### v1.3.7
- Fixed: WiFi watchdog no longer disrupts when wlan0 has IP but ping fails (e.g. no internet, local network). Only runs recovery when wlan0 has no IP (actually disconnected). Added 15-min backoff after failed recovery to stop the on/off loop.

### v1.3.6
- Fixed: WiFi now works out of the box. Removed aggressive boot-time WiFi changes (xradio-station-mode.service, fix-mac-at-boot.timer, cron @reboot) that stopped wpa_supplicant and reloaded the driver repeatedly — WiFi never had a chance to connect. Now uses only: udev (set MAC when wlan0 appears), set-unique-mac.service (gentle ip link down/address/up at 30s), power save off, watchdog for recovery. xradio-station-mode.sh kept for watchdog hard recovery when already offline.

### v1.3.5
- Added: U-Boot `fw_setenv wifi_mac` — tries to set MAC in boot env (SonicPad firmware passes `wifi_mac` to kernel). If it works, MAC is applied at kernel boot. Falls back to userspace (udev, xradio-station-mode, cron) if fw_setenv fails or offset is wrong.

### v1.3.4
- Added: `--skip-wifi` / `--safe-mode` flag to skip all WiFi/MAC changes. Use on fresh flash to avoid connectivity issues; re-run without the flag later to enable.
- Added: Troubleshooting entry for WiFi broken / lost SSH with recovery steps.

### v1.3.3
- Fixed: multi-pad IP conflict — SonicPads often ship with identical hardware MACs, causing DHCP to assign the same IP to all. Script now derives a unique, stable MAC from `/etc/machine-id` per device so each pad gets its own IP on any network. Run the script on each pad; reboot to apply.
- Fixed: unique MAC now set directly on wlan0 in `xradio-station-mode.sh` (SonicPad uses wpa_supplicant, not NetworkManager, so the NM config alone was ignored). WiFi watchdog also restores the unique MAC after module reload during recovery.

### v1.2.2
- Fixed: script would silently exit on any failed command due to `set -e` — replaced with explicit per-command error handling
- Fixed: `fix_ssl()` now runs before preflight and all git operations, preventing SSL failures on fresh images
- Fixed: fstab corruption where tmpfs line was appended directly onto rootfs line with no newline, causing root filesystem to mount read-only on next boot
- Fixed: removed `/var/log` tmpfs — was wiping Xorg/KlipperScreen log directories on boot, causing blank screen
- Fixed: `/tmp` tmpfs now uses `mode=1777` so Xorg lock files work correctly
- Fixed: fstab auto-repair detects and fixes corrupted joined lines from previous script versions
- Added: `mount --fake -a` fstab validation before reboot
- Added: git clone now uses `-c http.sslVerify=false` as fallback on all clone operations
- Added: hostname configuration step with conflict warning for multi-pad networks

### v1.2.1 *(superseded by v1.2.2)*
- Added SSL certificate fix (`ca-certificates` install + `update-ca-certificates`) at script start
- Added `git config --global http.sslVerify false` as session-wide fallback

### v1.2.0 *(superseded by v1.2.2)*
- fstab safety improvements (partial — had newline issue)
- Removed `/var/log` tmpfs

### v1.1.0
- Accelerometer: added `libopenblas-dev` apt install (fixes numpy ARM import failure)
- Accelerometer: pinned numpy to `<2` (numpy 2.x incompatible with this platform)
- Accelerometer: numpy/scipy now installed into `klippy-env` virtualenv (not system pip)
- Accelerometer: added post-install numpy import verification
- Accelerometer: fixed `klipper-mcu` service `ExecStart` to use correct binary name `klipper_mcu` (underscore)
- Accelerometer: added `klipper-mcu.service` enable on install
- Accelerometer: added udev rule for permanent `spidev2.0` permissions
- Accelerometer: updated sample config to match proven working SonicPad macro
- General: improved spidev presence check

### v1.0.0
- Initial release

---

## Credits

- [Jpe230/SonicPad-Debian](https://github.com/Jpe230/SonicPad-Debian) — the Debian port that makes all of this possible
- [dw-0/kiauh](https://github.com/dw-0/kiauh) — Klipper Installation And Update Helper
- [mainsail-crew/crowsnest](https://github.com/mainsail-crew/crowsnest) — camera streaming manager
- [pikvm/ustreamer](https://github.com/pikvm/ustreamer) — the underlying camera streamer

---

## License

GPL-3.0 — see [LICENSE](LICENSE) for details.
