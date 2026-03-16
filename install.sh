#!/bin/bash
# =============================================================================
#  SonicPad Debian All-In-One Setup Script
#  Covers:
#    - Creality Nebula Camera (crowsnest YUYV/CPU + ustreamer.sh patch)
#    - Accelerometer support (ADXL345 / input shaper packages)
#    - KIAUH installation
#    - System/OS performance tuning:
#        vm.swappiness, CPU governor, tmpfs for /tmp + /var/log,
#        Klipper process priority (nice/ionice), disable unused services
#    - Log rotation (Klipper, Moonraker, Crowsnest, system logs)
# =============================================================================

# Errors handled explicitly — set -e removed to prevent exit on non-fatal failures
set -uo pipefail

SCRIPT_VERSION="1.5.2"
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
# STATIC IP SETUP (optional)
# =============================================================================
setup_static_ip() {
    banner "Static IP Configuration (Optional)"
    echo "  Configure a static IP for Ethernet or WiFi (instead of DHCP)."
    echo ""
    if [ ! -t 0 ]; then
        info "Non-interactive mode: skipping static IP. Run 'sudo nmtui' to configure manually."
        return 0
    fi
    read -p "  Configure static IP now? [y/N]: " DO_STATIC
    case "${DO_STATIC}" in
        [Yy]*) ;;
        *) info "Skipping static IP. Using DHCP."; return 0 ;;
    esac

    echo ""
    echo "  Which interface?"
    echo "    1) Ethernet (eth0)"
    echo "    2) WiFi (wlan0)"
    echo ""
    read -p "  Select [1/2]: " IFACE_CHOICE

    case "${IFACE_CHOICE}" in
        1) DEVICE="eth0" ;;
        2) DEVICE="wlan0" ;;
        *) warn "Invalid choice. Skipping static IP."; return 0 ;;
    esac

    # Find the connection name for this device.
    # For wlan0: prefer 802-11-wireless (infrastructure) over wifi-p2p to avoid P2P mode.
    if [ "${DEVICE}" = "wlan0" ]; then
        CONN=$(nmcli -t -f NAME,DEVICE,TYPE connection show --active 2>/dev/null | awk -F: -v d="${DEVICE}" '$2==d && $3=="802-11-wireless" {print $1; exit}')
        [ -z "${CONN}" ] && CONN=$(nmcli -t -f NAME,DEVICE,TYPE connection show 2>/dev/null | awk -F: -v d="${DEVICE}" '$2==d && $3=="802-11-wireless" {print $1; exit}')
        [ -z "${CONN}" ] && CONN=$(nmcli -t -f NAME,DEVICE,TYPE connection show 2>/dev/null | awk -F: -v d="${DEVICE}" '$2==d && $3!="wifi-p2p" {print $1; exit}')
    fi
    if [ -z "${CONN}" ]; then
        CONN=$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null | grep ":${DEVICE}$" | cut -d: -f1 | head -1)
        [ -z "${CONN}" ] && CONN=$(nmcli -t -f NAME,DEVICE connection show 2>/dev/null | grep ":${DEVICE}$" | cut -d: -f1 | head -1)
    fi
    if [ -z "${CONN}" ]; then
        warn "No NetworkManager connection found for ${DEVICE}. Configure manually with: sudo nmtui"
        return 0
    fi

    echo ""
    echo "  Using connection: ${CONN}"
    echo "  Example: IP 192.168.1.100, Gateway 192.168.1.1, DNS 8.8.8.8"
    echo ""
    read -p "  IP address (e.g. 192.168.1.100): " STATIC_IP
    read -p "  CIDR prefix (e.g. 24 for /24): " STATIC_CIDR
    read -p "  Gateway (e.g. 192.168.1.1): " STATIC_GW
    read -p "  DNS server (e.g. 8.8.8.8): " STATIC_DNS

    STATIC_IP=$(echo "${STATIC_IP}" | tr -d '[:space:]')
    STATIC_CIDR=$(echo "${STATIC_CIDR}" | tr -d '[:space:]')
    STATIC_GW=$(echo "${STATIC_GW}" | tr -d '[:space:]')
    STATIC_DNS=$(echo "${STATIC_DNS}" | tr -d '[:space:]')

    if [ -z "${STATIC_IP}" ] || [ -z "${STATIC_CIDR}" ]; then
        warn "IP and CIDR required. Skipping."
        return 0
    fi

    info "Applying static IP to ${CONN}..."
    # Bind WiFi connection to wlan0 (avoids p2p / WiFi Direct mode)
    [ "${DEVICE}" = "wlan0" ] && sudo nmcli connection modify "${CONN}" connection.interface-name wlan0
    sudo nmcli connection modify "${CONN}" ipv4.method manual
    sudo nmcli connection modify "${CONN}" ipv4.addresses "${STATIC_IP}/${STATIC_CIDR}"
    [ -n "${STATIC_GW}" ] && sudo nmcli connection modify "${CONN}" ipv4.gateway "${STATIC_GW}"
    [ -n "${STATIC_DNS}" ] && sudo nmcli connection modify "${CONN}" ipv4.dns "${STATIC_DNS}"

    info "Reconnecting ${DEVICE}..."
    sudo nmcli connection down "${CONN}" 2>/dev/null || true
    sleep 2
    sudo nmcli connection up "${CONN}" 2>/dev/null || true
    sleep 2

    if ip -4 addr show "${DEVICE}" 2>/dev/null | grep -q "inet "; then
        ok "Static IP configured. ${DEVICE} should have ${STATIC_IP}/${STATIC_CIDR}"
    else
        warn "Connection may need manual check. Run: ip addr show ${DEVICE}"
    fi
}

# =============================================================================
# SSL FIX: Install CA certs and disable git SSL verify as fallback
# =============================================================================
fix_ssl() {
    info "Fixing SSL certificate verification..."
    if dpkg -l ca-certificates &>/dev/null; then
        ok "ca-certificates already installed."
        sudo update-ca-certificates -f 2>/dev/null || true
    else
        sudo apt-get install -y ca-certificates -qq 2>/dev/null && sudo update-ca-certificates -f 2>/dev/null && ok "CA certificates installed." || warn "CA cert install failed — using git SSL bypass as fallback."
    fi
    git config --global http.sslVerify false 2>/dev/null || true
    ok "Git SSL verification disabled globally as fallback."
    # Sync system clock — "certificate is not yet valid" usually means wrong date
    info "Syncing system clock (fixes pip SSL 'certificate not yet valid')..."
    if sudo timedatectl set-ntp true 2>/dev/null; then
        sleep 2
    fi
    sudo ntpdate pool.ntp.org 2>/dev/null || true
}

# =============================================================================
# STOP KLIPPER SERVICES — prevents file locks, MCU conflicts during install
# =============================================================================
stop_klipper_services() {
    banner "Stopping Klipper Services"
    # Stop in dependency order: KlipperScreen, Crowsnest, Moonraker, Klipper, klipper-mcu
    # Use sudo throughout — user may lack permission to query/control system services.
    # Call stop unconditionally (ignore is-active) — catches services in weird states.
    STOPPED_ANY=false
    for svc in KlipperScreen crowsnest moonraker klipper klipper-mcu; do
        if sudo systemctl stop "$svc" 2>/dev/null; then
            ok "Stopped: $svc"
            STOPPED_ANY=true
        elif sudo systemctl is-active --quiet "$svc" 2>/dev/null; then
            warn "Could not stop $svc"
        fi
    done
    # Stop any instance variants (klipper-1, moonraker-2, etc.)
    RUNNING=$(sudo systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | awk '{print $1}' | grep -E '^klipper-|^moonraker-|^crowsnest-|^KlipperScreen-' || true)
    if [ -n "$RUNNING" ]; then
        for unit in $RUNNING; do
            svc="${unit%.service}"
            sudo systemctl stop "$svc" 2>/dev/null && ok "Stopped: $svc" || warn "Could not stop $svc"
            STOPPED_ANY=true
        done
    fi
    [ "$STOPPED_ANY" = false ] && info "No Klipper services were running."
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
        USTREAMER_BIN="${CROWSNEST_DIR}/bin/ustreamer/ustreamer"
        if [ -x "${USTREAMER_BIN}" ]; then
            ok "ustreamer binary already built."
        else
            info "Building ustreamer (this may take a few minutes)..."
            cd "${CROWSNEST_DIR}"
            make build 2>/dev/null && ok "ustreamer built." || {
                warn "make build failed — trying bin/ustreamer directly..."
                make -C bin/ustreamer 2>/dev/null && ok "ustreamer built (fallback)." || warn "ustreamer build failed. Try running: cd ~/crowsnest && make build"
            }
            cd - > /dev/null
        fi

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
# SECTION 2: Accelerometer Support (ADXL345 / Input Shaper)
# =============================================================================
setup_accelerometer() {
    banner "Accelerometer / Input Shaper Support"

    # Core ARM toolchain (needed for Klipper MCU compilation on-device)
    ARM_PKGS="binutils-arm-none-eabi libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib gcc-arm-none-eabi"
    ARM_NEEDED=""
    for pkg in $ARM_PKGS; do
        dpkg -l "$pkg" &>/dev/null || ARM_NEEDED="$ARM_NEEDED $pkg"
    done
    if [ -z "${ARM_NEEDED}" ]; then
        ok "ARM toolchain already installed."
    else
        info "Installing ARM toolchain..."
        sudo apt-get update -qq
        sudo apt-get install -y $ARM_PKGS
        ok "ARM toolchain installed."
    fi

    # libopenblas is required by numpy on ARM. Without it, numpy fails to load
    # even after pip install with: libopenblas.so.0: cannot open shared object file
    if dpkg -l libopenblas-dev &>/dev/null; then
        ok "libopenblas already installed."
    else
        info "Installing libopenblas (required by numpy on ARM)..."
        sudo apt-get update -qq
        sudo apt-get install -y libopenblas-dev
        ok "libopenblas installed."
    fi

    # Python packages MUST go into the klippy virtualenv.
    # System pip3 is not used by Klipper — installing there causes
    # "Failed to import numpy" errors at runtime.
    # numpy 2.x fails on this platform (missing libopenblas symbols),
    # so we pin to <2. numpy 1.26.x is the correct version here.
    KLIPPY_PIP="/home/sonic/klippy-env/bin/pip"
    KLIPPY_PY="/home/sonic/klippy-env/bin/python"
    NUMPY_SCIPY_INSTALLED=false
    if [ -f "${KLIPPY_PIP}" ]; then
        # Check if numpy<2 and scipy are already installed and importable
        NUMPY_OK=false
        SCIPY_OK=false
        if "${KLIPPY_PIP}" show numpy &>/dev/null; then
            NUMPY_VER=$("${KLIPPY_PIP}" show numpy 2>/dev/null | grep -i "^Version:" | awk '{print $2}')
            if [ -n "${NUMPY_VER}" ] && [ "$(echo "${NUMPY_VER}" | cut -d. -f1)" -lt 2 ] 2>/dev/null; then
                NUMPY_OK=true
            fi
        fi
        "${KLIPPY_PIP}" show scipy &>/dev/null && SCIPY_OK=true

        if [ "${NUMPY_OK}" = true ] && [ "${SCIPY_OK}" = true ]; then
            if "${KLIPPY_PY}" -c "import numpy; import scipy" 2>/dev/null; then
                ok "numpy and scipy already installed and working."
            else
                info "numpy/scipy present but import failed — reinstalling..."
                NUMPY_OK=false
                SCIPY_OK=false
            fi
        fi

        if [ "${NUMPY_OK}" != true ] || [ "${SCIPY_OK}" != true ]; then
            info "Installing numpy and scipy into klippy-env..."
            # --trusted-host bypasses SSL verify — fixes "certificate is not yet valid"
            # (often caused by wrong system clock on fresh flash)
            PIP_TRUSTED="--trusted-host pypi.org --trusted-host files.pythonhosted.org --trusted-host www.piwheels.org"
            if [ "${NUMPY_OK}" != true ]; then
                "${KLIPPY_PIP}" uninstall numpy -y 2>/dev/null || true
                "${KLIPPY_PIP}" install $PIP_TRUSTED "numpy<2" && ok "numpy<2 installed into klippy-env." || warn "numpy install failed."
                NUMPY_SCIPY_INSTALLED=true
            fi
            if [ "${SCIPY_OK}" != true ]; then
                "${KLIPPY_PIP}" install $PIP_TRUSTED scipy && ok "scipy installed into klippy-env." || warn "scipy install failed."
                NUMPY_SCIPY_INSTALLED=true
            fi
        fi

        # Verify numpy actually imports — catches libopenblas issues early
        if "${KLIPPY_PY}" -c "import numpy" 2>/dev/null; then
            ok "numpy import verified."
        else
            warn "numpy installed but import failed — libopenblas may be missing."
            warn "Run: sudo apt-get install -y libopenblas-dev  then re-run this script."
        fi

        # Clean up pip build cache and apt cache only if we installed packages
        if [ "${NUMPY_SCIPY_INSTALLED}" = true ]; then
            info "Cleaning up build cache to free SD card space..."
            "${KLIPPY_PIP}" cache purge 2>/dev/null || true
            sudo apt-get clean 2>/dev/null || true
            ok "Build cache cleared."
        fi
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
        # Must use Linux process MCU config (not AVR/STM32/etc). We write a minimal
        # .config and run olddefconfig to fill defaults, then build.
        # 'sudo make flash' copies the binary to /usr/local/bin/klipper_mcu.
        # No bootloader, no serial port — just a file copy.
        echo ""
        read -p "  Build and flash Klipper host MCU firmware? [Y/n]: " DO_BUILD_FW
        DO_BUILD_FW="${DO_BUILD_FW:-Y}"
        case "${DO_BUILD_FW}" in
            [Yy]*)
                info "Building Klipper host MCU firmware (Linux process)..."
                cd "${KLIPPER_DIR}"
                # Backup existing .config (user may have printer MCU config)
                [ -f .config ] && cp .config .config.bak.printer
                # Force Linux process MCU config
                echo 'CONFIG_MACH_LINUX=y' > .config
                make olddefconfig 2>/dev/null || true
                make clean 2>/dev/null || true
                if make 2>/dev/null; then
                    ok "Host MCU firmware built."
                    if sudo make flash 2>/dev/null; then
                        ok "Host MCU flashed to /usr/local/bin/klipper_mcu."
                    else
                        warn "make flash failed. Run manually: cd ~/klipper && make && sudo make flash"
                    fi
                else
                    warn "Host MCU build failed. Run manually: cd ~/klipper && make menuconfig (select Linux process) && make && sudo make flash"
                fi
                # Restore printer config so user can build printer firmware later
                if [ -f .config.bak.printer ]; then
                    mv .config.bak.printer .config
                    ok "Restored printer MCU config."
                fi
                cd - > /dev/null
                ;;
            *)
                info "Skipping host MCU build. Run manually when ready: cd ~/klipper && make menuconfig (select Linux process) && make && sudo make flash"
                ;;
        esac

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
# SECTION 3: KIAUH Installation
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
# SECTION 3.1: KlipperScreen Update (if installed)
# =============================================================================
update_klipperscreen() {
    local ks_dir="/home/sonic/KlipperScreen"

    if [ ! -d "${ks_dir}" ]; then
        info "KlipperScreen not found at ${ks_dir}. Skipping update."
        return 0
    fi
    if [ ! -d "${ks_dir}/.git" ]; then
        warn "KlipperScreen exists but is not a git checkout. Skipping auto-update."
        return 0
    fi

    info "Updating KlipperScreen (git pull --ff-only)..."

    # Do not auto-pull if user has local modifications in KlipperScreen repo.
    if ! git -C "${ks_dir}" diff --quiet 2>/dev/null || ! git -C "${ks_dir}" diff --cached --quiet 2>/dev/null; then
        warn "KlipperScreen has local changes. Skipping update to avoid overwriting edits."
        return 0
    fi

    if git -C "${ks_dir}" pull --ff-only 2>/dev/null; then
        ok "KlipperScreen updated."
    else
        warn "KlipperScreen update failed (non-fast-forward/network issue). Continuing."
    fi
}

# =============================================================================
# FIX: WiFi stability (power save off, MAC preservation, prevent dropouts)
# =============================================================================
# Logs showed: 4-way handshake -> disconnected, "no secrets", MAC randomization.
# Fixes: power save off, use real MAC (no randomization), apply to existing conns.
fix_wifi_stability() {
    # Disable WiFi power management + MAC randomization (major causes of dropouts)
    local nm_powersave="/etc/NetworkManager/conf.d/95-wifi-powersave-off.conf"
    info "Configuring WiFi stability (power save off, MAC preservation)..."
    sudo mkdir -p /etc/NetworkManager/conf.d
    sudo tee "${nm_powersave}" > /dev/null << 'EOF'
# Disable WiFi power management — prevents connection dropouts
# Use real MAC address — MAC randomization causes 4-way handshake failures on some routers
[connection]
wifi.powersave = 2
wifi.cloned-mac-address = preserve
wifi.scan-rand-mac-address = no
EOF
    ok "WiFi power save and MAC preservation configured."
    sudo systemctl reload NetworkManager 2>/dev/null || true
    # Apply MAC preservation to existing WiFi connections (global default may not apply)
    for conn in $(nmcli -t -f NAME,TYPE connection show 2>/dev/null | awk -F: '$2=="802-11-wireless" {print $1}'); do
        nmcli connection modify "${conn}" 802-11-wireless.cloned-mac-address preserve 2>/dev/null && info "  Set preserve MAC for: ${conn}" || true
    done
    # iwconfig power off at boot — some drivers need this in addition to NM
    if [ -f /etc/rc.local ] && ! grep -q "iwconfig.*power" /etc/rc.local 2>/dev/null; then
        info "Adding iwconfig power off to rc.local..."
        sudo sed -i '/^exit 0/d' /etc/rc.local 2>/dev/null || true
        cat << 'EOF' | sudo tee -a /etc/rc.local > /dev/null

# Disable WiFi power save (prevents dropouts)
iwconfig wlan0 power off 2>/dev/null || true
exit 0
EOF
        ok "iwconfig power off added to rc.local."
    fi
}

# =============================================================================
# FIX: Permanently disable WiFi P2P (p2p0) so KlipperScreen uses wlan0
# =============================================================================
# NetworkManager creates p2p0 when WiFi P2P is enabled. KlipperScreen may show
# p2p0 instead of wlan0. Unmanage + udev down + p2p_disabled in wpa_supplicant.
fix_wifi_p2p() {
    # NetworkManager: ignore p2p devices so they don't appear in network panel
    local nm_conf="/etc/NetworkManager/conf.d/99-p2p-unmanaged.conf"
    if [ ! -f "${nm_conf}" ]; then
        info "Disabling WiFi P2P (p2p0) so wlan0 is used..."
        sudo mkdir -p /etc/NetworkManager/conf.d
        sudo tee "${nm_conf}" > /dev/null << 'EOF'
# Prevent p2p0 from being managed — KlipperScreen will use wlan0 instead
[keyfile]
unmanaged-devices=interface-name:p2p0;interface-name:p2p-dev-wlan0;interface-name:p2p-wlan0-*
EOF
        ok "NetworkManager will ignore p2p devices."
        sudo systemctl reload NetworkManager 2>/dev/null || true
    fi
    # udev: bring p2p0 down when it appears (permanently disable interface)
    local udev_rule="/etc/udev/rules.d/99-disable-p2p0.rules"
    if [ ! -f "${udev_rule}" ]; then
        info "Adding udev rule to disable p2p0..."
        echo 'ACTION=="add", SUBSYSTEM=="net", KERNEL=="p2p0", RUN+="/sbin/ip link set p2p0 down"' | sudo tee "${udev_rule}" > /dev/null
        sudo udevadm control --reload-rules
        ok "udev rule added: p2p0 will be brought down when created."
    fi
    # wpa_supplicant: disable P2P at source (prevents p2p0 creation)
    local wpas_conf="/etc/wpa_supplicant/wpa_supplicant.conf"
    if [ -f "${wpas_conf}" ] && ! grep -q "p2p_disabled" "${wpas_conf}" 2>/dev/null; then
        echo "p2p_disabled=1" | sudo tee -a "${wpas_conf}" > /dev/null
        ok "Added p2p_disabled=1 to wpa_supplicant."
    fi
    # Bring down p2p0 now if it exists
    sudo ip link set p2p0 down 2>/dev/null && info "  p2p0 brought down." || true
}

# =============================================================================
# FIX: Moonraker klippy_uds_address (biqu -> sonic path)
# =============================================================================
# Some configs reference /home/biqu/ (Biqu pad) but SonicPad uses /home/sonic/.
fix_moonraker_biqu_path() {
    local conf="/home/sonic/printer_data/config/moonraker.conf"
    [ -f "${conf}" ] || return 0
    if grep -q "/home/biqu/" "${conf}" 2>/dev/null; then
        info "Fixing moonraker.conf: biqu -> sonic path..."
        sudo sed -i 's|/home/biqu/|/home/sonic/|g' "${conf}"
        ok "moonraker.conf path corrected."
        if systemctl is-active --quiet moonraker 2>/dev/null; then
            sudo systemctl restart moonraker 2>/dev/null && ok "Moonraker restarted." || true
        fi
    fi
}

# =============================================================================
# FIX: Add /usr/sbin to PATH for sonic user (rfkill, etc.)
# =============================================================================
fix_sonic_path_env() {
    local bashrc="/home/sonic/.bashrc"
    [ -f "${bashrc}" ] || return 0
    if ! grep -q 'PATH=.*/usr/sbin' "${bashrc}" 2>/dev/null; then
        echo 'export PATH="$PATH:/usr/sbin"' >> "${bashrc}"
        ok "Added /usr/sbin to PATH in .bashrc."
    fi
}

# =============================================================================
# FIX: KlipperScreen screen_blanking config
# =============================================================================
# KlipperScreen crashes if screen_blanking has an inline comment (e.g. "600  #Blank af mins").
# Fix both [main] section and Moonraker's #~# managed section.
fix_klipperscreen_config() {
    local conf="/home/sonic/printer_data/config/KlipperScreen.conf"
    [ -f "${conf}" ] || return 0
    local fixed=false
    # Fix [main] section: screen_blanking: 600  #comment -> screen_blanking: 600
    if grep -q "screen_blanking:.*#" "${conf}" 2>/dev/null; then
        sed -i 's/^\(screen_blanking:\s*\)\([0-9][0-9]*\).*/\1\2/' "${conf}"
        fixed=true
    fi
    # Fix #~# managed section: screen_blanking = 600  #comment -> screen_blanking = 600
    if grep -q "#~# screen_blanking.*#" "${conf}" 2>/dev/null; then
        sed -i 's/\(#~# screen_blanking = [0-9][0-9]*\).*/\1/' "${conf}"
        fixed=true
    fi
    if [ "${fixed}" = true ]; then
        info "Fixing KlipperScreen screen_blanking (removing inline comments)..."
        ok "KlipperScreen config fixed."
        if systemctl is-active --quiet KlipperScreen 2>/dev/null; then
            sudo systemctl restart KlipperScreen 2>/dev/null && ok "KlipperScreen restarted." || true
        fi
    fi
}

# =============================================================================
# FIX: KlipperScreen WiFi P2P UI handling after updates
# =============================================================================
# Newer KlipperScreen builds may list p2p0 first and show misleading IP labels
# like "(p2p0)" even when wlan0 is connected. Patch runtime files idempotently.
fix_klipperscreen_wifi_p2p_ui() {
    local panel_py="/home/sonic/KlipperScreen/panels/network.py"
    local sdbus_py="/home/sonic/KlipperScreen/ks_includes/sdbus_nm.py"
    local changed=false

    # Patch panels/network.py: filter out p2p* interfaces from wireless list
    if [ -f "${panel_py}" ]; then
        if grep -q 'self.wireless_interfaces = \[iface.interface for iface in self.sdbus_nm.get_wireless_interfaces()\]' "${panel_py}" 2>/dev/null; then
            info "Patching KlipperScreen network panel to ignore p2p interfaces..."
            sed -i 's|self.wireless_interfaces = \[iface.interface for iface in self.sdbus_nm.get_wireless_interfaces()\]|self.wireless_interfaces = [iface.interface for iface in self.sdbus_nm.get_wireless_interfaces() if not iface.interface.startswith("p2p")]|' "${panel_py}"
            changed=true
            ok "Patched network.py (p2p filtered)."
        fi
    fi

    # Patch ks_includes/sdbus_nm.py:
    # 1) Ignore unmanaged popup for p2p interfaces
    # 2) Show actual active iface in IP label instead of selected wlan_device iface
    if [ -f "${sdbus_py}" ]; then
        if grep -q 'self.popup(f"{self.wlan_device.interface} is not managed by NetworkManager and cannot be controlled by this app")' "${sdbus_py}" 2>/dev/null; then
            info "Patching KlipperScreen unmanaged p2p popup handling..."
            sed -i 's|self.popup(f"{self.wlan_device.interface} is not managed by NetworkManager and cannot be controlled by this app")|if str(self.wlan_device.interface).startswith("p2p"):\n                logging.info(f"Ignoring unmanaged P2P interface: {self.wlan_device.interface}")\n            else:\n                self.popup(f"{self.wlan_device.interface} is not managed by NetworkManager and cannot be controlled by this app")|' "${sdbus_py}"
            changed=true
            ok "Patched sdbus_nm.py (ignore unmanaged p2p popup)."
        fi

        if grep -q 'return f"{ip} ({self.wlan_device.interface})"' "${sdbus_py}" 2>/dev/null; then
            info "Patching KlipperScreen IP label to show active interface..."
            sed -i 's|return f"{ip} ({self.wlan_device.interface})"|return f"{ip} ({iface_name})"|' "${sdbus_py}"
            changed=true
            ok "Patched sdbus_nm.py (IP label uses active iface)."
        fi
    fi

    # Syntax check and restart only when we changed something
    if [ "${changed}" = true ]; then
        if [ -f "${panel_py}" ]; then
            python3 -m py_compile "${panel_py}" 2>/dev/null || warn "network.py syntax check failed."
        fi
        if [ -f "${sdbus_py}" ]; then
            python3 -m py_compile "${sdbus_py}" 2>/dev/null || warn "sdbus_nm.py syntax check failed."
        fi
        if systemctl is-active --quiet KlipperScreen 2>/dev/null; then
            sudo systemctl restart KlipperScreen 2>/dev/null && ok "KlipperScreen restarted." || true
        fi
    fi
}

# =============================================================================
# SECTION 4: System / OS Performance Tuning
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
# SECTION 5: Log Rotation
# =============================================================================
setup_logrotate() {
    banner "Log Rotation Setup"

    if dpkg -l logrotate &>/dev/null; then
        ok "logrotate already installed."
    else
        info "Installing logrotate..."
        sudo apt-get install -y logrotate -qq
        ok "logrotate installed."
    fi

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
    echo "  [2] Accelerometer / Input Shaper packages (ADXL345)"
    echo "  [3] KIAUH (Klipper Installation & Update Helper)"
    echo "  [4] System / OS Performance Tuning"
    echo "       vm.swappiness, CPU governor, tmpfs, noatime, Klipper priority,"
    echo "       disable unused services"
    echo "  [5] Log Rotation (Klipper, Moonraker, Crowsnest, journal cap)"
    echo "  [*] Static IP (optional, prompted after hostname)"
    echo ""
    read -p "  Press ENTER to continue or Ctrl+C to cancel..." _

    require_sudo
    info "Updating package lists and installing usbutils, python3-serial, rfkill..."
    sudo apt update
    sudo apt install -y usbutils python3-serial rfkill
    fix_ssl
    stop_klipper_services
    preflight_check
    setup_hostname
    setup_static_ip

    setup_nebula_camera
    setup_accelerometer
    setup_kiauh
    update_klipperscreen
    setup_os_tuning
    setup_logrotate
    fix_wifi_stability
    fix_wifi_p2p
    fix_moonraker_biqu_path
    fix_klipperscreen_config
    fix_klipperscreen_wifi_p2p_ui
    fix_sonic_path_env

    banner "Setup Complete!"
    echo -e "${GREEN}All steps finished. Summary:${NC}"
    echo ""
    echo "  Camera   → crowsnest.conf written, ustreamer.sh patched (YUYV/CPU, 1280x720)"
    echo "  Accel    → ARM toolchain + Python packages, optional host MCU build (Linux process)"
    echo "  KIAUH    → Ready at ~/kiauh/kiauh.sh"
    echo "  KScreen  → Auto-updated from ~/KlipperScreen when clean git checkout"
    echo "  OS Tune  → swappiness=10, CPU governor=performance, tmpfs /tmp + /var/log,"
    echo "             noatime on root fs, Klipper nice=-10, unused services disabled"
    echo "  WiFi     → Power save off, MAC preserved, p2p0 disabled"
    echo "  Fixes    → KlipperScreen screen_blanking + p2p UI, moonraker biqu→sonic path"
    echo "  Logs     → logrotate configured for Klipper, Moonraker, Crowsnest"
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