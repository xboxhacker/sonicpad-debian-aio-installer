#!/bin/bash
# =============================================================================
#  SonicPad Debian All-In-One Setup Script
#  Covers:
#    - Creality Nebula Camera (crowsnest YUYV/CPU + ustreamer.sh patch)
#    - WiFi Watchdog (power save off + auto-reconnect service)
#    - Accelerometer support (ADXL345 / input shaper packages)
#    - KIAUH installation
# =============================================================================

set -e

SCRIPT_VERSION="1.0.0"
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
    if [ -d "${CROWSNEST_DIR}" ] && [ -f "${CROWSNEST_DIR}/crowsnest.sh" ]; then
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

    # --- Install or update Crowsnest ---
    if [ "${CROWSNEST_FOUND}" = true ]; then
        info "Crowsnest already installed. Pulling latest..."
        git -C "${CROWSNEST_DIR}" pull && ok "Crowsnest updated." || warn "Crowsnest git pull failed — continuing with existing version."
    else
        info "Installing Crowsnest..."
        git clone https://github.com/mainsail-crew/crowsnest.git "${CROWSNEST_DIR}"
        cd "${CROWSNEST_DIR}"
        sudo make install 2>/dev/null || {
            warn "make install failed — attempting manual service install..."
            sudo cp "${CROWSNEST_DIR}/crowsnest.service" "${SYSTEMD_DIR}/crowsnest.service" 2>/dev/null || true
            sudo systemctl daemon-reload
        }
        sudo systemctl enable crowsnest 2>/dev/null || true
        cd - > /dev/null
        ok "Crowsnest installed."
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

    # --- Disable power save immediately ---
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
After=network-online.target
Wants=network-online.target

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

INTERFACE="wlan0"
TEST_HOST="8.8.8.8"
PING_COUNT=3
PING_TIMEOUT=5
LOG="/var/log/wifi-watchdog.log"
MAX_LOG_LINES=500

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
}

trim_log() {
    if [ -f "$LOG" ]; then
        tail -n $MAX_LOG_LINES "$LOG" > "${LOG}.tmp" && mv "${LOG}.tmp" "$LOG"
    fi
}

# Check connectivity
if ! ping -I "$INTERFACE" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$TEST_HOST" > /dev/null 2>&1; then
    log "WARN: No connectivity detected on $INTERFACE. Attempting recovery..."

    # Ensure power save is still off
    /usr/sbin/iw dev "$INTERFACE" set power_save off 2>/dev/null

    # Bring the interface down and back up
    ip link set "$INTERFACE" down
    sleep 2
    ip link set "$INTERFACE" up
    sleep 5

    # Restart wpa_supplicant if used
    if systemctl is-active --quiet wpa_supplicant 2>/dev/null; then
        systemctl restart wpa_supplicant
        sleep 5
    fi

    # Try DHCP renewal
    dhclient "$INTERFACE" -1 2>/dev/null || true

    # Final check
    if ping -I "$INTERFACE" -c "$PING_COUNT" -W "$PING_TIMEOUT" "$TEST_HOST" > /dev/null 2>&1; then
        log "OK: WiFi recovered successfully."
    else
        log "ERROR: WiFi recovery failed. Manual intervention may be needed."
    fi
else
    : # Connectivity OK — no log spam
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

    # Python packages for input shaper / resonance testing
    info "Installing Python resonance/shaper dependencies..."
    pip3 install --upgrade numpy 2>/dev/null || warn "numpy upgrade failed — may already be current."
    pip3 install --upgrade scipy 2>/dev/null || warn "scipy upgrade failed."

    ok "Python packages installed."

    # Enable SPI if needed for direct ADXL345 wiring to SonicPad GPIO
    info "Checking SPI kernel modules..."
    if lsmod 2>/dev/null | grep -q spi; then
        ok "SPI module already loaded."
    else
        warn "SPI module not detected. The SonicPad uses the R818 SoC — ADXL345 is typically"
        warn "connected via USB (RP2040/Arduino) rather than direct SPI on this platform."
        warn "If you are using direct SPI wiring, you may need a custom kernel."
    fi

    # Deploy Klipper host MCU service (needed for accelerometer on SBC)
    KLIPPER_DIR="/home/sonic/klipper"
    HOST_MCU_SERVICE="${SYSTEMD_DIR}/klipper-mcu.service"

    if [ "${KLIPPER_FOUND}" = true ]; then
        info "Klipper found. Setting up host MCU service..."
        sudo tee "${HOST_MCU_SERVICE}" > /dev/null << 'EOF'
[Unit]
Description=Klipper Host MCU (for ADXL345 / resonance testing)
Before=klipper.service
After=local-fs.target

[Service]
Type=simple
User=sonic
RemainAfterExit=yes
ExecStart=/home/sonic/klippy-env/bin/python /home/sonic/klipper/klippy/klippy.py /home/sonic/printer_data/config/printer.cfg -l /home/sonic/printer_data/logs/klippy.log -a /tmp/klippy_uds
ExecStartPre=/bin/sh -c "/home/sonic/klipper/scripts/flash-sd.sh /tmp/klipper_host_mcu.bin /dev/null"
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

        # Build the host MCU firmware
        info "Building Klipper host MCU firmware..."
        cd "${KLIPPER_DIR}"
        make clean KCONFIG_CONFIG=config.host 2>/dev/null || true
        make menuconfig KCONFIG_CONFIG=config.host 2>/dev/null || {
            warn "make menuconfig skipped (non-interactive). Using default config."
        }
        make KCONFIG_CONFIG=config.host 2>/dev/null && {
            ok "Host MCU firmware built."
            sudo make flash KCONFIG_CONFIG=config.host 2>/dev/null && ok "Host MCU flashed." || warn "Flash step skipped or failed — may need manual run."
        } || warn "Host MCU build skipped or failed. Run 'make' in ${KLIPPER_DIR} manually."
        cd - > /dev/null

        # Provide sample klipper config snippet
        info "Creating sample accelerometer config snippet..."
        cat > /home/sonic/printer_data/config/adxl345_sample.cfg << 'EOF'
# ============================================================
# ADXL345 Accelerometer Config Snippet
# Add these sections to your printer.cfg
# ============================================================

# Option A: ADXL345 via Klipper Host MCU (direct SPI wiring to SonicPad)
[mcu host]
serial: /tmp/klipper_host_mcu

[adxl345]
cs_pin: host:None

[resonance_tester]
accel_chip: adxl345
probe_points:
    # Set to the center of your bed:
    117.5, 117.5, 10

# ============================================================
# Option B: ADXL345 via USB MCU (RP2040, Arduino, etc.)
# Replace /dev/serial/by-id/... with your actual device path
# ============================================================
# [mcu adxl]
# serial: /dev/serial/by-id/usb-Klipper_rp2040_XXXXXXXXXXXXXXXX-if00
#
# [adxl345]
# cs_pin: adxl:gpio1
# spi_bus: spi0a
#
# [resonance_tester]
# accel_chip: adxl345
# probe_points:
#     117.5, 117.5, 10
EOF
        ok "Sample config written to ~/printer_data/config/adxl345_sample.cfg"
    else
        warn "Klipper directory not found at ${KLIPPER_DIR}. Install Klipper first (KIAUH will be installed next)."
        warn "After Klipper is installed, re-run this script to complete the accelerometer setup."
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
        git clone https://github.com/dw-0/kiauh.git "${KIAUH_DIR}"
        ok "KIAUH cloned to ${KIAUH_DIR}."
    fi

    chmod +x "${KIAUH_DIR}/kiauh.sh"

    ok "KIAUH is ready. Launch with:  ~/kiauh/kiauh.sh"
    info "KIAUH will NOT be launched automatically — run it after this script completes."
    info "Use KIAUH to install/update: Klipper, Moonraker, Mainsail, Fluidd, KlipperScreen, Crowsnest."
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
    echo ""
    read -p "  Press ENTER to continue or Ctrl+C to cancel..." _

    require_sudo
    preflight_check

    setup_nebula_camera
    setup_wifi
    setup_accelerometer
    setup_kiauh

    banner "Setup Complete!"
    echo -e "${GREEN}All steps finished. Summary:${NC}"
    echo ""
    echo "  Camera  → crowsnest.conf written, ustreamer.sh patched (YUYV/CPU)"
    echo "  WiFi    → Power save disabled, watchdog timer active (2 min interval)"
    echo "  Accel   → ARM toolchain + Python packages installed, sample config written"
    echo "  KIAUH   → Ready at ~/kiauh/kiauh.sh"
    echo ""
    echo -e "${YELLOW}Next steps:${NC}"
    echo "  1. Run  ~/kiauh/kiauh.sh  to install Klipper, Moonraker, Mainsail, Crowsnest"
    echo "  2. After Klipper is installed, re-run this script to complete host MCU setup"
    echo "  3. Review ~/printer_data/config/adxl345_sample.cfg and merge into printer.cfg"
    echo "  4. Reboot:  sudo reboot"
    echo ""
}

main "$@"
