#!/bin/bash
# =============================================================================
#  SonicPad Debian All-In-One Setup Script
#  Covers:
#    - Creality Nebula Camera (crowsnest YUYV/CPU + ustreamer.sh patch)
#    - WiFi Watchdog (power save off + auto-reconnect service)
#    - Accelerometer support (ADXL345 / input shaper packages)
#    - KIAUH installation
#    - System/OS performance tuning:
#        vm.swappiness, CPU governor, tmpfs for /tmp + /var/log,
#        Klipper process priority (nice/ionice), disable unused services
#    - Log rotation (Klipper, Moonraker, Crowsnest, system logs)
# =============================================================================

# Errors handled explicitly — set -e removed to prevent exit on non-fatal failures
set -uo pipefail

SCRIPT_VERSION="1.3.2"
CROWSNEST_DIR="/home/sonic/crowsnest"
PRINTER_DATA="/home/sonic/printer_data"
SYSTEMD_DIR="/etc/systemd/system"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; }

banner() {
    echo ""
    echo -e "${CYAN}============================================================${NC}"
    echo -e "${CYAN}  $1${NC}"
    echo -e "${CYAN}============================================================${NC}"
    echo ""
}

require_sudo() {
    if [ "$EUID" -eq 0 ]; then
        err "Do not run this script as root. Run as the 'sonic' user."
        exit 1
    fi
    info "Checking sudo access..."
    sudo -v || { err "sudo access required."; exit 1; }
}

# =============================================================================
# HOSTNAME SETUP
# =============================================================================
setup_hostname() {
    banner "Hostname Configuration"

    CURRENT_HOSTNAME=$(hostname)
    info "Current hostname: ${CURRENT_HOSTNAME}"
    echo ""
    echo "  If you are running multiple SonicPads on the same network, each"
    echo "  needs a unique hostname to avoid mDNS (.local) conflicts."
    echo ""
    echo "  Examples: SonicPad, SonicPad2, PrinterLeft, TronXY, IR3"
    echo ""
    read -p "  Enter new hostname [default: ${CURRENT_HOSTNAME}]: " NEW_HOSTNAME
    NEW_HOSTNAME="${NEW_HOSTNAME:-${CURRENT_HOSTNAME}}"

    # Strip whitespace
    NEW_HOSTNAME=$(echo "${NEW_HOSTNAME}" | tr -d '[:space:]')

    if [ "${NEW_HOSTNAME}" = "${CURRENT_HOSTNAME}" ]; then
        ok "Hostname unchanged: ${CURRENT_HOSTNAME}"
    else
        info "Setting hostname to '${NEW_HOSTNAME}'..."
        sudo hostnamectl set-hostname "${NEW_HOSTNAME}"
        # Update /etc/hosts — replace old hostname and ensure 127.0.1.1 entry exists
        sudo sed -i "s/${CURRENT_HOSTNAME}/${NEW_HOSTNAME}/g" /etc/hosts
        # Ensure 127.0.1.1 maps to new hostname (prevents "sudo: unable to resolve host" warnings)
        if grep -q "^127.0.1.1" /etc/hosts; then
            sudo sed -i "s/^127.0.1.1.*/127.0.1.1 ${NEW_HOSTNAME}/" /etc/hosts
        else
            echo "127.0.1.1 ${NEW_HOSTNAME}" | sudo tee -a /etc/hosts > /dev/null
        fi
        ok "Hostname set to '${NEW_HOSTNAME}'."
        info "Pad will be reachable at ${NEW_HOSTNAME}.local after reboot."
    fi
}

# =============================================================================
# SSL FIX: Install CA certs and disable git SSL verify as fallback
# =============================================================================
fix_ssl() {
    info "Fixing SSL certificate verification..."
    sudo apt-get install -y ca-certificates -qq 2>/dev/null &&         sudo update-ca-certificates -f 2>/dev/null &&         ok "CA certificates updated." ||         warn "CA cert update failed — using git SSL bypass as fallback."
    git config --global http.sslVerify false 2>/dev/null || true
    ok "Git SSL verification disabled globally as fallback."
}

# =============================================================================
# PRE-FLIGHT: Detect existing installs
# =============================================================================
KLIPPER_FOUND=false
CROWSNEST_FOUND=false

preflight_check() {
    banner "Pre-Flight Check"

    # --- Klipper ---
    if [ -d "/home/sonic/klipper" ] && [ -f "/home/sonic/klipper/klippy/klippy.py" ]; then
        KLIPPER_FOUND=true
        ok "Klipper detected at ~/klipper"
    else
        warn "Klipper NOT found. KIAUH will be installed — run it after this script to install Klipper."
        warn "Re-run this script after Klipper is installed to complete accelerometer/host MCU setup."
    fi

    # --- Crowsnest ---
    if [ -d "${CROWSNEST_DIR}" ] && [ -n "$(ls -A ${CROWSNEST_DIR} 2>/dev/null)" ]; then
        CROWSNEST_FOUND=true
        ok "Crowsnest detected at ${CROWSNEST_DIR}"
    else
        warn "Crowsnest NOT found. It will be cloned and installed during camera setup."
    fi

    # --- printer_data ---
    if [ -d "${PRINTER_DATA}/config" ]; then
        ok "printer_data/config directory found."
    else
        warn "printer_data/config NOT found. Some config writes will be skipped until Moonraker creates it."
    fi

    echo ""
    info "Pre-flight complete. Proceeding with setup..."
    sleep 1
}

# =============================================================================
# SECTION 1: Nebula Camera Setup
# =============================================================================
setup_nebula_camera() {
    banner "Nebula Camera Setup"

    # Ensure sonic user is in the video group — required to access /dev/video0.
    # Without this crowsnest fails with "No usable Devices Found" even though
    # the camera is physically present and detected by the kernel.
    info "Adding sonic user to video group..."
    if groups sonic | grep -q "video"; then
        ok "sonic already in video group."
    else
        sudo usermod -a -G video sonic
        ok "sonic added to video group (takes effect on next login/reboot)."
    fi

    # --- Install or update Crowsnest ---
    # We clone and build crowsnest manually rather than using 'make install'
    # because crowsnest's installer is interactive (prompts for user input)
    # and will hang a non-interactive script.
    # KIAUH handles the full crowsnest service install interactively if needed.
    if [ "${CROWSNEST_FOUND}" = true ]; then
        info "Crowsnest already installed. Pulling latest..."
        git -C "${CROWSNEST_DIR}" pull && ok "Crowsnest updated." || warn "Crowsnest git pull failed — continuing with existing version."
    else
        info "Cloning Crowsnest..."
        git -c http.sslVerify=false clone https://github.com/mainsail-crew/crowsnest.git "${CROWSNEST_DIR}" || { err "Crowsnest clone failed. Check network and SSL certs."; return; }

        # Build ustreamer binary only — non-interactive, no sudo make install
        info "Building ustreamer (this may take a few minutes)..."
        cd "${CROWSNEST_DIR}"
        make build 2>/dev/null && ok "ustreamer built." || {
            warn "make build failed — trying bin/ustreamer directly..."
            make -C bin/ustreamer 2>/dev/null && ok "ustreamer built (fallback)." ||                 warn "ustreamer build failed. Try running: cd ~/crowsnest && make build"
        }
        cd - > /dev/null

        # Install crowsnest as a service non-interactively
        # crowsnest ships a pre-built .service file we can copy directly
        if [ -f "${CROWSNEST_DIR}/crowsnest.service" ]; then
            sudo cp "${CROWSNEST_DIR}/crowsnest.service" "${SYSTEMD_DIR}/crowsnest.service"
            sudo systemctl daemon-reload
            sudo systemctl enable crowsnest 2>/dev/null || true
            ok "crowsnest.service installed and enabled."
        else
            warn "crowsnest.service file not found — skipping service install."
            warn "Use KIAUH to install Crowsnest as a service after this script."
        fi

        ok "Crowsnest cloned and built."
    fi

    # --- crowsnest.conf ---
    CROWSNEST_CONF="${PRINTER_DATA}/config/crowsnest.conf"

    if [ ! -d "${PRINTER_DATA}/config" ]; then
        warn "printer_data/config directory not found. Skipping crowsnest.conf write."
    else
        info "Writing crowsnest.conf..."
        sudo tee "${CROWSNEST_CONF}" > /dev/null << 'EOF'
[crowsnest]
log_path: /home/sonic/printer_data/logs/crowsnest.log
log_level: verbose
delete_log: false

[cam nebula]
mode: ustreamer
device: /dev/video0
resolution: 1280x720
max_fps: 15
port: 8080
custom_flags: --host=0.0.0.0 --encoder=CPU --format=YUYV
EOF
        ok "crowsnest.conf written."
    fi

    # --- Patch ustreamer.sh to stop MJPEG auto-detection override ---
    USTREAMER_SH="${CROWSNEST_DIR}/libs/ustreamer.sh"

    if [ ! -f "${USTREAMER_SH}" ]; then
        warn "ustreamer.sh not found at ${USTREAMER_SH}. Is crowsnest installed?"
        warn "Skipping ustreamer.sh patch. Run this script again after installing crowsnest."
    else
        info "Patching ustreamer.sh to use YUYV/CPU instead of MJPEG/HW auto-detection..."

        # Check if already patched
        if grep -q "YUYV --encoder=CPU" "${USTREAMER_SH}"; then
            ok "ustreamer.sh already patched. Skipping."
        else
            # Patch: replace the MJPEG/HW line with YUYV/CPU
            sed -i 's/start_param+=( -m MJPEG --encoder=HW )/start_param+=( -m  YUYV --encoder=CPU )/' "${USTREAMER_SH}"

            # Verify the patch worked
            if grep -q "YUYV --encoder=CPU" "${USTREAMER_SH}"; then
                ok "ustreamer.sh patched successfully."
            else
                warn "sed patch may not have matched. Checking for alternate formatting..."
                # Try with varying whitespace
                sed -i 's/start_param+=(.*-m MJPEG.*--encoder=HW.*)/start_param+=( -m  YUYV --encoder=CPU )/' "${USTREAMER_SH}"
                if grep -q "YUYV --encoder=CPU" "${USTREAMER_SH}"; then
                    ok "ustreamer.sh patched (alternate match)."
                else
                    err "Could not auto-patch ustreamer.sh. Please manually change the MJPEG/HW line to YUYV/CPU near line 58 in ${USTREAMER_SH}"
                fi
            fi
        fi
    fi

    # Restart crowsnest if running
    if systemctl is-active --quiet crowsnest 2>/dev/null; then
        info "Restarting crowsnest..."
        sudo systemctl restart crowsnest
        ok "crowsnest restarted."
    fi
}

# =============================================================================
# SECTION 2: WiFi Watchdog
# =============================================================================
setup_wifi() {
    banner "WiFi Stability Setup"

    # --- Force station mode at boot ---
    # The XRadio chip (wlan0) on the SonicPad sometimes initializes in P2P mode
    # instead of managed/station mode. When this happens the interface appears
    # connected but has no network access and can take forever to switch over,
    # or never does. Forcing station mode before wpa_supplicant starts fixes this.
    info "Installing xradio-station-mode.service (fixes P2P boot issue)..."
    sudo tee "${SYSTEMD_DIR}/xradio-station-mode.service" > /dev/null << 'EOF'
[Unit]
Description=Force XRadio wlan0 into station mode before wpa_supplicant
Before=wpa_supplicant.service network.target
After=sys-subsystem-net-devices-wlan0.device
Wants=sys-subsystem-net-devices-wlan0.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/xradio-station-mode.sh

[Install]
WantedBy=multi-user.target
EOF

    # Write the station mode script — detects correct module name at runtime
    sudo tee /usr/local/bin/xradio-station-mode.sh > /dev/null << 'STATIONMODE'
#!/bin/bash
# Force XRadio WiFi chip into station (managed) mode
# Handles both xr819_wlan and xradio_wlan module names

IFACE="wlan0"

# Detect which module name is in use
if lsmod | grep -q "xr819_wlan"; then
    MOD="xr819_wlan"
elif lsmod | grep -q "xradio_wlan"; then
    MOD="xradio_wlan"
else
    MOD="xradio"
fi

# Bring interface down, reload module, force station mode, bring back up
ip link set "$IFACE" down 2>/dev/null || true
rmmod "$MOD" 2>/dev/null || true
sleep 2
modprobe "$MOD" 2>/dev/null || true
sleep 3
ip link set "$IFACE" down 2>/dev/null || true
iw dev "$IFACE" set type station 2>/dev/null || true
ip link set "$IFACE" up 2>/dev/null || true
iw dev "$IFACE" set power_save off 2>/dev/null || true
STATIONMODE
    sudo chmod +x /usr/local/bin/xradio-station-mode.sh
    sudo systemctl daemon-reload
    sudo systemctl enable xradio-station-mode.service
    sudo systemctl start xradio-station-mode.service 2>/dev/null || true
    ok "xradio-station-mode.service enabled."

    # --- Disable power save immediately ---
    # Tell NetworkManager to ignore p2p0 — prevents it from grabbing p2p0
    # at boot instead of wlan0 (root cause of "boots to P2P" issue)
    info "Configuring NetworkManager to ignore p2p0 interface..."
    sudo mkdir -p /etc/NetworkManager/conf.d
    sudo tee /etc/NetworkManager/conf.d/99-ignore-p2p.conf > /dev/null << 'NMCONF'
[keyfile]
unmanaged-devices=interface-name:p2p0
NMCONF
    ok "NetworkManager will ignore p2p0 at boot."

    # Disable MAC address randomization — random MACs cause DHCP conflicts
    # when multiple pads are on the same network (both get same IP)
    info "Disabling WiFi MAC address randomization..."
    sudo tee /etc/NetworkManager/conf.d/99-no-mac-randomize.conf > /dev/null << 'NMRAND'
[device]
wifi.scan-rand-mac-address=no

[connection]
wifi.cloned-mac-address=permanent
NMRAND
    ok "MAC randomization disabled — permanent hardware MAC will be used."

    info "Disabling WiFi power save..."
    if /usr/sbin/iw dev wlan0 get power_save 2>/dev/null | grep -q "off"; then
        ok "WiFi power save already off."
    else
        sudo /usr/sbin/iw dev wlan0 set power_save off 2>/dev/null && ok "WiFi power save disabled." || warn "Could not disable power save via iw (interface may not be up yet — service will handle it at boot)."
    fi

    # --- Systemd service to keep power save off across reboots ---
    info "Installing wifi-powersave-off.service..."
    sudo tee "${SYSTEMD_DIR}/wifi-powersave-off.service" > /dev/null << 'EOF'
[Unit]
Description=Disable WiFi Power Save on wlan0
After=xradio-station-mode.service
Wants=xradio-station-mode.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/iw dev wlan0 set power_save off
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable wifi-powersave-off.service
    sudo systemctl start wifi-powersave-off.service 2>/dev/null || true
    ok "wifi-powersave-off.service enabled."

    # --- WiFi Watchdog Script ---
    info "Installing WiFi watchdog script..."
    sudo tee /usr/local/bin/wifi-watchdog.sh > /dev/null << 'WATCHDOG'
#!/bin/bash
# WiFi Watchdog for SonicPad (XRadio SDIO chip)
# Detects loss of network connectivity and recovers wlan0
# Uses escalating recovery: soft bounce -> station mode force -> module reload

INTERFACE="wlan0"
TEST_HOST="8.8.8.8"
PING_COUNT=3
PING_TIMEOUT=5
LOG="/var/log/wifi-watchdog.log"
MAX_LOG_LINES=500
FAIL_COUNT_FILE="/tmp/wifi-watchdog-fails"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

trim_log() {
    if [ -f "$LOG" ]; then
        tail -n $MAX_LOG_LINES "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
    fi
}

check_ping() {
    ping -I "$INTERFACE" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$TEST_HOST" > /dev/null 2>&1
}

force_station_mode() {
    ip link set "$INTERFACE" down 2>/dev/null
    sleep 1
    iw dev "$INTERFACE" set type station 2>/dev/null || true
    ip link set "$INTERFACE" up 2>/dev/null
    /usr/sbin/iw dev "$INTERFACE" set power_save off 2>/dev/null || true
}

reload_xradio_module() {
    # Nuclear option — unload and reload the XRadio kernel module.
    # This fully resets the chip out of P2P mode when soft methods fail.
    # Module name varies by SonicPad kernel: xr819_wlan or xradio_wlan
    log "INFO: Reloading xradio kernel module to force reset..."
    systemctl stop wpa_supplicant 2>/dev/null || true
    ip link set "$INTERFACE" down 2>/dev/null || true
    rmmod xr819_wlan 2>/dev/null || rmmod xradio_wlan 2>/dev/null || rmmod xradio 2>/dev/null || true
    sleep 3
    modprobe xr819_wlan 2>/dev/null || modprobe xradio_wlan 2>/dev/null || modprobe xradio 2>/dev/null || true
    sleep 5
    force_station_mode
    sleep 2
    systemctl start wpa_supplicant 2>/dev/null || true
    sleep 8
    dhclient "$INTERFACE" -1 2>/dev/null || true
}

# Read consecutive fail count
FAILS=0
if [ -f "$FAIL_COUNT_FILE" ]; then
    FAILS=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
fi

if ! check_ping; then
    FAILS=$((FAILS + 1))
    echo "$FAILS" > "$FAIL_COUNT_FILE"
    log "WARN: No connectivity on $INTERFACE (consecutive fails: $FAILS). Attempting recovery..."

    if [ "$FAILS" -le 3 ]; then
        # Soft recovery: force station mode and restart wpa_supplicant
        force_station_mode
        sleep 5
        if systemctl is-active --quiet wpa_supplicant 2>/dev/null; then
            systemctl restart wpa_supplicant
            sleep 8
        fi
        dhclient "$INTERFACE" -1 2>/dev/null || true

    else
        # Hard recovery: reload the XRadio module entirely
        log "WARN: Soft recovery failed $FAILS times — escalating to module reload."
        reload_xradio_module
    fi

    # Final check
    if check_ping; then
        log "OK: WiFi recovered successfully (after $FAILS attempts)."
        echo "0" > "$FAIL_COUNT_FILE"
    else
        log "ERROR: WiFi recovery failed (attempt $FAILS)."
    fi
else
    # Connectivity OK — reset fail counter
    if [ "$FAILS" -gt 0 ]; then
        log "OK: Connectivity restored. Resetting fail counter."
        echo "0" > "$FAIL_COUNT_FILE"
    fi
fi

trim_log
WATCHDOG
    sudo chmod +x /usr/local/bin/wifi-watchdog.sh

    # --- Watchdog as a systemd timer (every 2 minutes) ---
    info "Installing wifi-watchdog timer..."
    sudo tee "${SYSTEMD_DIR}/wifi-watchdog.service" > /dev/null << 'EOF'
[Unit]
Description=WiFi Watchdog - Reconnect wlan0 if offline

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wifi-watchdog.sh
EOF

    sudo tee "${SYSTEMD_DIR}/wifi-watchdog.timer" > /dev/null << 'EOF'
[Unit]
Description=Run WiFi Watchdog every 2 minutes

[Timer]
OnBootSec=60
OnUnitActiveSec=2min
Unit=wifi-watchdog.service

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable wifi-watchdog.timer
    sudo systemctl start wifi-watchdog.timer
    ok "WiFi watchdog timer enabled (runs every 2 minutes)."
}

# =============================================================================
# SECTION 3: Accelerometer Support (ADXL345 / Input Shaper)
# =============================================================================
setup_accelerometer() {
    banner "Accelerometer / Input Shaper Support"

    info "Installing required packages for ADXL345 and resonance measurement..."
    sudo apt-get update -qq

    # Core ARM toolchain (needed for Klipper MCU compilation on-device)
    sudo apt-get install -y \
        binutils-arm-none-eabi \
        libnewlib-arm-none-eabi \
        libstdc++-arm-none-eabi-newlib \
        gcc-arm-none-eabi

    ok "ARM toolchain installed."

    # libopenblas is required by numpy on ARM. Without it, numpy fails to load
    # even after pip install with: libopenblas.so.0: cannot open shared object file
    info "Installing libopenblas (required by numpy on ARM)..."
    sudo apt-get install -y libopenblas-dev
    ok "libopenblas installed."

    # Python packages MUST go into the klippy virtualenv.
    # System pip3 is not used by Klipper — installing there causes
    # "Failed to import numpy" errors at runtime.
    # numpy 2.x fails on this platform (missing libopenblas symbols),
    # so we pin to <2. numpy 1.26.x is the correct version here.
    info "Installing numpy and scipy into klippy-env..."
    KLIPPY_PIP="/home/sonic/klippy-env/bin/pip"
    if [ -f "${KLIPPY_PIP}" ]; then
        "${KLIPPY_PIP}" uninstall numpy -y 2>/dev/null || true
        "${KLIPPY_PIP}" install "numpy<2" && ok "numpy<2 installed into klippy-env." || warn "numpy install failed."
        "${KLIPPY_PIP}" install scipy && ok "scipy installed into klippy-env." || warn "scipy install failed."
        # Verify numpy actually imports — catches libopenblas issues early
        if /home/sonic/klippy-env/bin/python -c "import numpy" 2>/dev/null; then
            ok "numpy import verified."
        else
            warn "numpy installed but import failed — libopenblas may be missing."
            warn "Run: sudo apt-get install -y libopenblas-dev  then re-run this script."
        fi

        # Clean up pip build cache and apt cache — numpy/scipy leave large
        # build artifacts that can fill the SD card (seen: Errno 28 No space left)
        info "Cleaning up build cache to free SD card space..."
        "${KLIPPY_PIP}" cache purge 2>/dev/null || true
        sudo apt-get clean 2>/dev/null || true
        ok "Build cache cleared."
    else
        warn "klippy-env not found — install Klipper via KIAUH first, then re-run this script."
        warn "After Klipper is installed, run:"
        warn "  sudo apt-get install -y libopenblas-dev"
        warn "  ~/klippy-env/bin/pip install 'numpy<2' scipy"
    fi

    # Confirm spidev2.0 is present
    info "Checking SPI device..."
    if [ -e "/dev/spidev2.0" ]; then
        ok "/dev/spidev2.0 found."
    else
        warn "/dev/spidev2.0 not found — ADXL345 SPI may not work."
    fi


    # Deploy Klipper host MCU service (needed for accelerometer on SBC)
    KLIPPER_DIR="/home/sonic/klipper"
    HOST_MCU_SERVICE="${SYSTEMD_DIR}/klipper-mcu.service"

    if [ "${KLIPPER_FOUND}" = true ]; then
        info "Klipper found. Setting up host MCU service..."

        # klipper-mcu service runs the Linux process MCU binary installed to
        # /usr/local/bin/klipper-mcu by 'sudo make flash'.
        # Must start BEFORE klipper.service so /tmp/klipper_host_mcu socket
        # exists when Klipper connects to [mcu rpi].
        sudo tee "${HOST_MCU_SERVICE}" > /dev/null << 'EOF'
[Unit]
Description=Klipper Linux Process MCU
Before=klipper.service
After=local-fs.target

[Service]
Type=simple
User=sonic
ExecStart=/usr/local/bin/klipper_mcu
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable klipper-mcu.service
        ok "klipper-mcu.service installed and enabled."

        # Build and flash the host MCU.
        # 'make' compiles using the existing .config (Linux process MCU).
        # 'sudo make flash' copies the binary to /usr/local/bin/klipper-mcu.
        # No bootloader, no serial port — just a file copy.
        info "Building Klipper host MCU firmware..."
        cd "${KLIPPER_DIR}"
        make clean 2>/dev/null || true
        if make 2>/dev/null; then
            ok "Host MCU firmware built."
            if sudo make flash 2>/dev/null; then
                ok "Host MCU flashed to /usr/local/bin/klipper-mcu."
            else
                warn "make flash failed. Run manually: cd ~/klipper && make && sudo make flash"
            fi
        else
            warn "Host MCU build failed. Run manually: cd ~/klipper && make && sudo make flash"
        fi
        cd - > /dev/null

        # Fix spidev permissions — /dev/spidev2.0 is root-only by default,
        # which prevents the sonic user from accessing the ADXL345.
        # udev rule makes this permanent across reboots.
        info "Setting spidev permissions..."
        echo 'SUBSYSTEM=="spidev", MODE="0666"' | sudo tee /etc/udev/rules.d/99-spidev.rules > /dev/null
        sudo udevadm control --reload-rules
        sudo chmod 666 /dev/spidev2.0 2>/dev/null || true
        ok "spidev permissions set (persistent via udev)."

        # Start the service now if Klipper is already running
        if systemctl is-active --quiet klipper 2>/dev/null; then
            sudo systemctl restart klipper-mcu.service 2>/dev/null &&                 ok "klipper-mcu service started." ||                 warn "klipper-mcu start failed — try: sudo systemctl start klipper-mcu"
        fi

        # Write sample config matching the proven working SonicPad macro
        info "Creating sample accelerometer config snippet..."
        cat > /home/sonic/printer_data/config/adxl345_sample.cfg << 'EOF'
# ============================================================
# ADXL345 Accelerometer Config — SonicPad (Linux host MCU)
# Merge these sections into your printer.cfg
# ============================================================

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
EOF
        ok "Sample config written to ~/printer_data/config/adxl345_sample.cfg"
    else
        warn "Klipper not found. Install Klipper via KIAUH first, then re-run this script."
    fi
}

# =============================================================================
# SECTION 4: KIAUH Installation
# =============================================================================
setup_kiauh() {
    banner "KIAUH Installation"

    KIAUH_DIR="/home/sonic/kiauh"

    if [ -d "${KIAUH_DIR}" ]; then
        info "KIAUH already exists at ${KIAUH_DIR}. Pulling latest..."
        git -C "${KIAUH_DIR}" pull && ok "KIAUH updated." || warn "KIAUH git pull failed."
    else
        info "Cloning KIAUH..."
        git -c http.sslVerify=false clone https://github.com/dw-0/kiauh.git "${KIAUH_DIR}" || { err "KIAUH clone failed. Check network and SSL certs."; return; }
        ok "KIAUH cloned to ${KIAUH_DIR}."
    fi

    chmod +x "${KIAUH_DIR}/kiauh.sh"

    ok "KIAUH is ready. Launch with:  ~/kiauh/kiauh.sh"
    info "KIAUH will NOT be launched automatically — run it after this script completes."
    info "Use KIAUH to install/update: Klipper, Moonraker, Mainsail, Fluidd, KlipperScreen, Crowsnest."
}

# =============================================================================
# SECTION 5: System / OS Performance Tuning
# =============================================================================
setup_os_tuning() {
    banner "System / OS Performance Tuning"

    # --- vm.swappiness ---
    # Default is 60 — way too aggressive for a dedicated printer host.
    # Setting to 10 keeps Klipper's Python process in RAM and reduces
    # latency spikes caused by swapping during long prints.
    info "Setting vm.swappiness=10..."
    if grep -q "^vm.swappiness" /etc/sysctl.conf 2>/dev/null; then
        sudo sed -i 's/^vm.swappiness.*/vm.swappiness=10/' /etc/sysctl.conf
    else
        echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf > /dev/null
    fi
    sudo sysctl -w vm.swappiness=10 > /dev/null
    ok "vm.swappiness set to 10."

    # --- CPU Governor: performance ---
    # The R818 vendor kernel locks scaling_governor to root writes only and may
    # not expose it as writable even with sudo via sysfs. We try both methods
    # but treat failure as non-fatal — the rc.local entry below ensures it
    # is applied at every boot when the kernel is more permissive.
    info "Setting CPU governor to 'performance'..."
    GOVERNOR_SET=false
    for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [ -f "$cpu" ] || continue
        echo performance | sudo tee "$cpu" > /dev/null 2>&1 && GOVERNOR_SET=true || true
    done
    if [ "$GOVERNOR_SET" = true ]; then
        ok "CPU governor set to performance."
    else
        info "scaling_governor not writable now (R818 vendor kernel limitation)."
        info "Governor will be set to performance at next reboot via rc.local."
    fi

    # Make governor persistent across reboots via rc.local
    if [ ! -f /etc/rc.local ]; then
        sudo tee /etc/rc.local > /dev/null << 'EOF'
#!/bin/bash
# rc.local — runs at boot
EOF
        sudo chmod +x /etc/rc.local
    fi
    if ! grep -q "scaling_governor" /etc/rc.local; then
        sudo sed -i '/^exit 0/d' /etc/rc.local 2>/dev/null || true
        cat << 'EOF' | sudo tee -a /etc/rc.local > /dev/null
# Set CPU governor to performance for Klipper step timing stability
for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$cpu" 2>/dev/null || true
done
exit 0
EOF
        ok "CPU governor persistence written to /etc/rc.local."
    else
        ok "CPU governor already in rc.local. Skipping."
    fi

    # --- tmpfs for /tmp only ---
    # Moves /tmp to RAM to reduce SD card write cycles.
    # NOTE: /var/log is intentionally NOT put on tmpfs. KlipperScreen, Xorg,
    # and the display manager rely on persistent subdirectories under /var/log
    # that are created at install time. A tmpfs wipes them on every boot,
    # causing a blank screen with only the Debian logo visible.
    info "Configuring tmpfs for /tmp..."

    FSTAB=/etc/fstab

    # --- fstab safety: ensure file ends with a newline ---
    # If the last line has no trailing newline, tee -a appends directly onto
    # the last line, corrupting the entry (e.g. "0 0tmpfs /tmp ..."). This
    # causes the root filesystem to mount read-only on next boot.
    if [ -f "$FSTAB" ]; then
        if [ "$(sudo tail -c 1 "$FSTAB" | wc -l)" -eq 0 ]; then
            printf "\n" | sudo tee -a "$FSTAB" > /dev/null
            info "Added missing newline to end of fstab."
        fi
    fi

    # --- fstab safety: detect and repair corrupted joined lines ---
    if sudo grep -qP "\d 0tmpfs|\d 0PARTLABEL|\d 0/" "$FSTAB" 2>/dev/null; then
        warn "Detected corrupted fstab entries — repairing..."
        sudo sed -i 's/0 0tmpfs/0 0\ntmpfs/g' "$FSTAB"
        sudo sed -i 's/0 0PARTLABEL/0 0\nPARTLABEL/g' "$FSTAB"
        ok "fstab corruption repaired."
    fi

    # --- Remove /var/log tmpfs if added by a previous version of this script ---
    if sudo grep -q "tmpfs.*/var/log" "$FSTAB"; then
        sudo sed -i '/tmpfs.*\/var\/log/d' "$FSTAB"
        warn "Removed /var/log tmpfs from fstab (was causing blank screen on boot)."
    fi

    # --- Add /tmp tmpfs with mode=1777 (required for Xorg lock files) ---
    if ! sudo grep -q "tmpfs.*/tmp" "$FSTAB"; then
        printf "\n" | sudo tee -a "$FSTAB" > /dev/null
        echo "tmpfs   /tmp        tmpfs   defaults,noatime,nosuid,mode=1777,size=256m    0 0" | sudo tee -a "$FSTAB" > /dev/null
        ok "tmpfs /tmp added to fstab."
    else
        if ! sudo grep "tmpfs.*/tmp" "$FSTAB" | grep -q "mode=1777"; then
            sudo sed -i '/tmpfs.*\/tmp/ s/nosuid/nosuid,mode=1777/' "$FSTAB"
            ok "Added mode=1777 to existing /tmp tmpfs entry."
        else
            ok "tmpfs /tmp already in fstab. Skipping."
        fi
    fi

    # --- Final fstab sanity check ---
    info "Verifying fstab integrity..."
    if sudo mount --fake -a 2>/dev/null; then
        ok "fstab syntax verified OK."
    else
        warn "fstab may have issues — check /etc/fstab before rebooting:"
        sudo cat "$FSTAB"
    fi

    # --- noatime on root filesystem ---
    # Prevents the kernel from writing access timestamps on every file read.
    # Significantly reduces SD card wear, especially during long prints where
    # Klipper, Moonraker, and Crowsnest are constantly reading config/module files.
    info "Setting noatime on root filesystem..."
    if grep -q "noatime" "$FSTAB"; then
        ok "noatime already set in fstab. Skipping."
    else
        # Add noatime to the root mount options
        sudo sed -i 's/\(.*\s\/\s.*defaults\)/\1,noatime/' "$FSTAB" 2>/dev/null || \
        sudo sed -i '/^\s*[^#].*\s\/\s/ s/defaults/defaults,noatime/' "$FSTAB" 2>/dev/null || \
            warn "Could not auto-set noatime in fstab — add it manually to the root / entry."
        # Apply immediately without remounting (avoids disruption)
        sudo mount -o remount,noatime / 2>/dev/null && ok "noatime applied to root fs." || \
            warn "noatime remount skipped — will apply on next reboot."
    fi

    # --- nice / ionice priority for Klipper ---
    # Gives Klipper's klippy.py process a higher CPU and I/O scheduling priority
    # so it wins contention against background tasks (apt, logging, etc).
    # Applied via a systemd drop-in so it survives service restarts.
    info "Boosting Klipper process priority (nice=-10, ionice=realtime)..."
    KLIPPER_SERVICE_DIR="${SYSTEMD_DIR}/klipper.service.d"
    sudo mkdir -p "${KLIPPER_SERVICE_DIR}"
    sudo tee "${KLIPPER_SERVICE_DIR}/priority.conf" > /dev/null << 'EOF'
[Service]
# Raise CPU priority — negative nice = higher priority (range: -20 to 19)
Nice=-10
# Set I/O scheduler to best-effort class 2, priority 0 (highest in class)
IOSchedulingClass=2
IOSchedulingPriority=0
EOF
    sudo systemctl daemon-reload
    ok "Klipper priority drop-in written."

    # Reload Klipper if it's running to pick up new priority
    if systemctl is-active --quiet klipper 2>/dev/null; then
        sudo systemctl restart klipper
        ok "Klipper restarted with new priority settings."
    fi

    # --- Disable unused services ---
    # These ship with Debian but serve no purpose on a dedicated printer host.
    # Disabling frees RAM and reduces background scheduling noise.
    info "Disabling unused system services..."
    SERVICES_TO_DISABLE=(
        "bluetooth.service"       # No BT hardware on SonicPad
        "avahi-daemon.service"    # mDNS — not needed, saves ~4MB RAM
        "ModemManager.service"    # Modem management — irrelevant here
        "apt-daily.service"       # Unattended apt runs during prints = bad
        "apt-daily-upgrade.service"
        "apt-daily.timer"
        "apt-daily-upgrade.timer"
    )

    for svc in "${SERVICES_TO_DISABLE[@]}"; do
        if systemctl list-unit-files "${svc}" &>/dev/null && \
           systemctl is-enabled "${svc}" 2>/dev/null | grep -q "enabled"; then
            sudo systemctl disable --now "${svc}" 2>/dev/null && \
                ok "Disabled: ${svc}" || \
                warn "Could not disable ${svc} — may not be present."
        else
            info "Already disabled or not found: ${svc}"
        fi
    done
}

# =============================================================================
# SECTION 6: Log Rotation
# =============================================================================
setup_logrotate() {
    banner "Log Rotation Setup"

    info "Installing logrotate if not present..."
    sudo apt-get install -y logrotate -qq
    ok "logrotate ready."

    # --- Klipper logs ---
    info "Writing logrotate config for Klipper..."
    sudo tee /etc/logrotate.d/klipper > /dev/null << 'EOF'
/home/sonic/printer_data/logs/klippy.log {
    daily
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su sonic sonic
}
EOF
    ok "Klipper logrotate configured."

    # --- Moonraker logs ---
    info "Writing logrotate config for Moonraker..."
    sudo tee /etc/logrotate.d/moonraker > /dev/null << 'EOF'
/home/sonic/printer_data/logs/moonraker.log {
    daily
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su sonic sonic
}
EOF
    ok "Moonraker logrotate configured."

    # --- Crowsnest logs ---
    info "Writing logrotate config for Crowsnest..."
    sudo tee /etc/logrotate.d/crowsnest > /dev/null << 'EOF'
/home/sonic/printer_data/logs/crowsnest.log {
    daily
    rotate 5
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su sonic sonic
}
EOF
    ok "Crowsnest logrotate configured."

    # --- WiFi watchdog log ---
    info "Writing logrotate config for wifi-watchdog..."
    sudo tee /etc/logrotate.d/wifi-watchdog > /dev/null << 'EOF'
/var/log/wifi-watchdog.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
    ok "WiFi watchdog logrotate configured."

    # --- System journal size cap ---
    # journald can grow unbounded on a R/W filesystem — cap it at 64MB.
    info "Capping systemd journal size to 64MB..."
    sudo mkdir -p /etc/systemd/journald.conf.d
    sudo tee /etc/systemd/journald.conf.d/size.conf > /dev/null << 'EOF'
[Journal]
SystemMaxUse=64M
RuntimeMaxUse=32M
EOF
    sudo systemctl restart systemd-journald 2>/dev/null || true
    ok "systemd journal capped at 64MB."

    # Run logrotate once now to verify configs are valid
    info "Running logrotate dry-run to verify configs..."
    sudo logrotate --debug /etc/logrotate.conf 2>&1 | grep -E "error|warn" || true
    ok "Logrotate configs verified."
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    clear
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║       SonicPad Debian All-In-One Setup v${SCRIPT_VERSION}         ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  This script will configure:"
    echo "  [1] Creality Nebula Camera (YUYV/CPU via crowsnest)"
    echo "  [2] WiFi Power Save OFF + Auto-Reconnect Watchdog"
    echo "  [3] Accelerometer / Input Shaper packages (ADXL345)"
    echo "  [4] KIAUH (Klipper Installation & Update Helper)"
    echo "  [5] System / OS Performance Tuning"
    echo "       vm.swappiness, CPU governor, tmpfs, noatime, Klipper priority,"
    echo "       disable unused services"
    echo "  [6] Log Rotation (Klipper, Moonraker, Crowsnest, journal cap)"
    echo ""
    read -p "  Press ENTER to continue or Ctrl+C to cancel..." _

    require_sudo
    fix_ssl
    preflight_check
    setup_hostname

    setup_nebula_camera
    setup_wifi
    setup_accelerometer
    setup_kiauh
    setup_os_tuning
    setup_logrotate

    banner "Setup Complete!"
    echo -e "${GREEN}All steps finished. Summary:${NC}"
    echo ""
    echo "  Camera   → crowsnest.conf written, ustreamer.sh patched (YUYV/CPU, 1280x720)"
    echo "  WiFi     → Power save disabled, watchdog timer active (2 min interval)"
    echo "  Accel    → ARM toolchain + Python packages installed, sample config written"
    echo "  KIAUH    → Ready at ~/kiauh/kiauh.sh"
    echo "  OS Tune  → swappiness=10, CPU governor=performance, tmpfs /tmp + /var/log,"
    echo "             noatime on root fs, Klipper nice=-10, unused services disabled"
    echo "  Logs     → logrotate configured for Klipper, Moonraker, Crowsnest, watchdog"
    echo "             systemd journal capped at 64MB"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Launch KIAUH to install Klipper, Moonraker, Mainsail, Crowsnest"
    echo "     (use the option below to launch with TMPDIR fix for OctoEverywhere)"
    echo "  2. After Klipper is installed, re-run this script to complete host MCU setup"
    echo "  3. Review ~/printer_data/config/adxl345_sample.cfg and merge into printer.cfg"
    echo "  4. Reboot:  sudo reboot"
    echo ""
    echo -e "${YELLOW}TIP:${NC} When installing OctoEverywhere via KIAUH Extensions,"
    echo "     launch KIAUH with TMPDIR set to avoid 'No space left on device' errors."
    echo "     pip uses /tmp for builds which is limited to 256MB on tmpfs."
    echo ""

    # --- Offer to launch KIAUH with TMPDIR fix ---
    read -p "  Launch KIAUH now (with TMPDIR fix for OctoEverywhere)? [Y/n]: " LAUNCH_KIAUH
    LAUNCH_KIAUH="${LAUNCH_KIAUH:-Y}"
    case "${LAUNCH_KIAUH}" in
        [Yy]*)
            info "Launching KIAUH with TMPDIR=/home/sonic/tmp ..."
            mkdir -p ~/tmp
            export TMPDIR=~/tmp
            ~/kiauh/kiauh.sh
            ;;
        *)
            echo ""
            ok "Skipping KIAUH launch. To launch manually with the TMPDIR fix:"
            echo "     mkdir -p ~/tmp && export TMPDIR=~/tmp && ~/kiauh/kiauh.sh"
            echo ""
            ;;
    esac
}

main "$@"
# __INJECT_PLACEHOLDER__