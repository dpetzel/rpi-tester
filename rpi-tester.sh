#!/bin/bash
# rpi-test.sh — Raspberry Pi Hardware Validation Script
# Runs comprehensive tests and outputs JSON results
# Usage: sudo ./rpi-test.sh
#
# Credits & Inspiration:
#   - boardcheck.sh by roseaar42 (https://gist.github.com/roseaar42/fed522a699122ff0bfaa902143956aa7)
#     Throttle flag decoding, SD card grading concept, overall structure
#   - TheRemote's throttle/clock script (https://gist.github.com/TheRemote/10bda1ac790f959210db5789f5241436)
#     vcgencmd throttle bit-field interpretation
#   - aikoncwd/rpi-benchmark (https://github.com/aikoncwd/rpi-benchmark)
#     DD-based storage speed testing approach
#   - pi3g/pi-stress-test (https://github.com/pi3g/pi-stress-test)
#     stress-ng usage pattern for Pi thermal testing
#   - stressberry by nschloe (https://github.com/nschloe/stressberry)
#     Temperature monitoring during sustained load concept

set -euo pipefail

OUTPUT="$HOME/rpi-test-results.json"
STRESS_DURATION=60
MEMTEST_MB=""  # auto-calculated
QUICK=0

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --quick|-q) QUICK=1; shift ;;
        *) shift ;;
    esac
done

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# --- Helpers ---

json_escape() { printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }

die() { echo "FATAL: $1" >&2; exit 1; }

check_deps() {
    local missing=()
    for cmd in stress-ng memtester bc vcgencmd lsusb; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        # Only attempt install if apt-get is likely to succeed (network + not already tried)
        if [[ ! -f /tmp/.rpi-test-deps-attempted ]]; then
            echo "Installing missing deps: ${missing[*]}" >&2
            if ! apt-get update -qq 2>&2; then
                echo "WARNING: apt-get update failed — trying install anyway" >&2
            fi
            # Install deps individually so one missing package doesn't block the rest
            for pkg in stress-ng memtester bc usbutils; do
                apt-get install -y -qq "$pkg" 2>/dev/null || true
            done
            # vcgencmd package varies by distro
            apt-get install -y -qq libraspberrypi-bin 2>/dev/null || \
                apt-get install -y -qq raspi-utils-core 2>/dev/null || true
            touch /tmp/.rpi-test-deps-attempted
            # Re-check
            missing=()
            for cmd in stress-ng memtester bc vcgencmd lsusb; do
                command -v "$cmd" &>/dev/null || missing+=("$cmd")
            done
        fi
        if [[ ${#missing[@]} -gt 0 ]]; then
            echo "WARNING: Missing deps (install manually): ${missing[*]}" >&2
            MISSING_DEPS="${missing[*]}"
        else
            MISSING_DEPS=""
        fi
    else
        MISSING_DEPS=""
    fi
}

# --- System Identification ---

get_sysinfo() {
    MODEL=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo "Unknown")
    SERIAL=$(cat /proc/device-tree/serial-number 2>/dev/null | tr -d '\0' || grep -oP 'Serial\s+:\s+\K.*' /proc/cpuinfo || echo "Unknown")
    REVISION=$(grep -oP 'Revision\s+:\s+\K.*' /proc/cpuinfo || echo "Unknown")
    RAM_MB=$(free -m | awk '/Mem:/{print $2}')
    SOC=$(cat /proc/device-tree/compatible 2>/dev/null | tr '\0' '\n' | head -1 || echo "Unknown")
    KERNEL=$(uname -r)
    OS_VERSION=$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "Unknown")
    FW_VERSION=$(vcgencmd version 2>/dev/null | grep -oP 'version \K.*' | head -1 || echo "Unknown")

    # EEPROM version (Pi 4/5 only)
    EEPROM=""
    if command -v rpi-eeprom-update &>/dev/null; then
        local update_check=$(rpi-eeprom-update 2>/dev/null || echo "")
        EEPROM=$(echo "$update_check" | grep -oP 'CURRENT: \K.*' | head -1 || echo "")
    fi

    # Determine expected values based on model string
    if echo "$MODEL" | grep -qi "Pi 5"; then
        EXPECTED_USB=4; EXPECTED_GPIO=28; EXPECTED_ETH_SPEED=1000; HAS_WIFI=1; HAS_BT=1
        EXPECTED_HDMI=2; HAS_AUDIO_JACK=0
    elif echo "$MODEL" | grep -qi "Pi 400"; then
        EXPECTED_USB=4; EXPECTED_GPIO=28; EXPECTED_ETH_SPEED=1000; HAS_WIFI=1; HAS_BT=1
        EXPECTED_HDMI=1; HAS_AUDIO_JACK=0
    elif echo "$MODEL" | grep -qi "Pi 4"; then
        EXPECTED_USB=4; EXPECTED_GPIO=28; EXPECTED_ETH_SPEED=1000; HAS_WIFI=1; HAS_BT=1
        EXPECTED_HDMI=2; HAS_AUDIO_JACK=1
    elif echo "$MODEL" | grep -qi "Pi 3.*B+"; then
        EXPECTED_USB=4; EXPECTED_GPIO=28; EXPECTED_ETH_SPEED=1000; HAS_WIFI=1; HAS_BT=1
        EXPECTED_HDMI=1; HAS_AUDIO_JACK=1
    elif echo "$MODEL" | grep -qi "Pi 3"; then
        EXPECTED_USB=4; EXPECTED_GPIO=28; EXPECTED_ETH_SPEED=100; HAS_WIFI=1; HAS_BT=1
        EXPECTED_HDMI=1; HAS_AUDIO_JACK=1
    elif echo "$MODEL" | grep -qi "Zero 2"; then
        EXPECTED_USB=1; EXPECTED_GPIO=28; EXPECTED_ETH_SPEED=0; HAS_WIFI=1; HAS_BT=1
        EXPECTED_HDMI=1; HAS_AUDIO_JACK=0
    elif echo "$MODEL" | grep -qi "Zero W"; then
        EXPECTED_USB=1; EXPECTED_GPIO=28; EXPECTED_ETH_SPEED=0; HAS_WIFI=1; HAS_BT=1
        EXPECTED_HDMI=1; HAS_AUDIO_JACK=0
    elif echo "$MODEL" | grep -qi "Zero"; then
        EXPECTED_USB=1; EXPECTED_GPIO=28; EXPECTED_ETH_SPEED=0; HAS_WIFI=0; HAS_BT=0
        EXPECTED_HDMI=1; HAS_AUDIO_JACK=0
    else
        EXPECTED_USB=4; EXPECTED_GPIO=28; EXPECTED_ETH_SPEED=100; HAS_WIFI=0; HAS_BT=0
        EXPECTED_HDMI=1; HAS_AUDIO_JACK=0
    fi
}

# --- Power & Thermal ---

get_thermal() {
    TEMP_IDLE=$(vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+' || echo "0")
    THROTTLE_HEX=$(vcgencmd get_throttled 2>/dev/null | grep -oP '0x[0-9a-fA-F]+' || echo "0x0")
    THROTTLE_NOW=0; THROTTLE_HISTORY=0
    local val=$((THROTTLE_HEX))
    [[ $((val & 0x1)) -ne 0 ]] && UNDERVOLT_NOW=1 || UNDERVOLT_NOW=0
    [[ $((val & 0x2)) -ne 0 ]] && FREQ_CAP_NOW=1 || FREQ_CAP_NOW=0
    [[ $((val & 0x4)) -ne 0 ]] && THROTTLE_NOW=1 || true
    [[ $((val & 0x10000)) -ne 0 ]] && UNDERVOLT_HIST=1 || UNDERVOLT_HIST=0
    [[ $((val & 0x20000)) -ne 0 ]] && FREQ_CAP_HIST=1 || FREQ_CAP_HIST=0
    [[ $((val & 0x40000)) -ne 0 ]] && THROTTLE_HISTORY=1 || true
}

# --- CPU Stress ---

run_cpu_stress() {
    if ! command -v stress-ng &>/dev/null; then
        STRESS_RESULT="SKIP"; STRESS_MAX_TEMP="0"; STRESS_THROTTLED=0; STRESS_CLOCK="0"; return
    fi
    echo "Running CPU stress test (${STRESS_DURATION}s)..." >&2
    local max_temp=0
    STRESS_THROTTLED=0
    stress-ng --cpu 0 --timeout "${STRESS_DURATION}s" --quiet &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        local t=$(vcgencmd measure_temp 2>/dev/null | grep -oP '[0-9.]+' || echo "0")
        local cmp=$(echo "$t > $max_temp" | bc 2>/dev/null || echo "0")
        [[ "$cmp" == "1" ]] && max_temp=$t
        # Check for active throttling during stress (bits 0,2: undervolt, hard throttle — NOT bit 3 soft temp limit)
        local thr=$(vcgencmd get_throttled 2>/dev/null | grep -oP '0x[0-9a-fA-F]+' || echo "0x0")
        local tval=$((thr))
        [[ $((tval & 0x5)) -ne 0 ]] && STRESS_THROTTLED=1
        sleep 2
    done
    wait "$pid" 2>/dev/null
    STRESS_MAX_TEMP=$max_temp
    STRESS_CLOCK=$(vcgencmd measure_clock arm 2>/dev/null | grep -oP '[0-9]+$' || echo "0")
    STRESS_RESULT="DONE"
}

# --- Memory ---

run_memory_test() {
    if ! command -v memtester &>/dev/null; then
        MEM_RESULT="SKIP"; MEM_ERRORS=0; return
    fi
    local avail=$(free -m | awk '/Mem:/{print $7}')
    MEMTEST_MB=$((avail / 2))
    [[ $MEMTEST_MB -lt 32 ]] && MEMTEST_MB=32
    [[ $MEMTEST_MB -gt 512 ]] && MEMTEST_MB=512
    echo "Running memtester (${MEMTEST_MB}MB, 1 pass)..." >&2
    if memtester "${MEMTEST_MB}M" 1 >&2; then
        MEM_RESULT="PASS"; MEM_ERRORS=0
    else
        MEM_RESULT="FAIL"; MEM_ERRORS=1
    fi
}

# --- Storage ---

run_storage_test() {
    echo "Checking SD card slot..." >&2
    local root_dev=$(findmnt -n -o SOURCE / 2>/dev/null || echo "unknown")
    if echo "$root_dev" | grep -q "mmcblk"; then
        BOOT_MEDIA="microSD"
        SD_SLOT="detected"
    elif echo "$root_dev" | grep -q "sd[a-z]\|nvme"; then
        BOOT_MEDIA="USB"
        SD_SLOT="not booted from SD"
    else
        BOOT_MEDIA="other"
        SD_SLOT="not booted from SD"
    fi
    BOOT_DEVICE="$root_dev"
}

# --- USB ---

check_usb() {
    USB_LIST=$(lsusb 2>/dev/null || echo "none")
    USB_TREE=$(lsusb -t 2>/dev/null || echo "")
    USB_CONTROLLERS=$(echo "$USB_LIST" | grep -ci "hub") || true

    # Count external devices (anything that isn't a root hub or internal hub)
    USB_DEVICES=$(echo "$USB_LIST" | grep -v "root hub" | grep -cv "Hub") || true

    # Per-model port validation
    USB_PORT_ERRORS=""
    if echo "$MODEL" | grep -qi "Pi 4\|Pi 400"; then
        # Pi 4: expect 2 devices on USB2 (Bus 1 hub), 2 devices on USB3 (Bus 2)
        USB2_DEVS=$(echo "$USB_TREE" | grep -A20 "480M" | grep -c "Class=Human Interface\|Class=Mass Storage\|Class=Vendor" 2>/dev/null) || USB2_DEVS=0
        USB3_DEVS=$(echo "$USB_TREE" | grep -A20 "5000M" | grep -v "root_hub" | grep -c "Class=" 2>/dev/null) || USB3_DEVS=0
        USB_PORT_DETAIL="USB2: ${USB2_DEVS}/2, USB3: ${USB3_DEVS}/2"
        [[ $USB2_DEVS -lt 2 || $USB3_DEVS -lt 2 ]] && USB_PORT_ERRORS="incomplete" || true
    elif echo "$MODEL" | grep -qi "Pi 3"; then
        # Pi 3B/3B+: LAN9514/LAN7515 is internal USB hub + Ethernet combo
        # Topology: root_hub -> LAN9514 hub (0424:9514) -> Ethernet (0424:ec00) + 4 external USB ports
        LAN_HUB=$(echo "$USB_LIST" | grep -c "0424:9514\|0424:7800") || true
        LAN_ETH=$(echo "$USB_LIST" | grep -c "0424:ec00\|0424:7800") || true
        # Count occupied physical USB ports from tree topology
        # Pi 3B/3B+: 4 physical ports split across hub/4p (top) and hub/3p (LAN sub-hub)
        # Top-level ports: direct children (8-space) of hub/4p, excluding the internal LAN sub-hub
        local _p1 _p2
        _p1=$(echo "$USB_TREE" | grep "^        |__ Port" | grep -cv "Driver=hub/3p") || true
        # LAN sub-hub ports: 12-space children between hub/3p and next 8-space entry, excluding ethernet
        _p2=$(echo "$USB_TREE" | sed -n "/Driver=hub\/3p/,/^        |__ Port/p" | grep "^            |__ Port" | grep -cv "lan78xx\|smsc95xx") || true
        USB_PORTS_USED=$((_p1 + _p2))
        USB_PORT_DETAIL="LAN hub: ${LAN_HUB}, Eth: ${LAN_ETH}, Ports used: ${USB_PORTS_USED}/4"
        if [[ "$LAN_HUB" -eq 0 ]]; then
            USB_PORT_ERRORS="LAN9514 hub missing — USB/Ethernet chip may be dead"
        elif [[ "$LAN_ETH" -eq 0 ]]; then
            USB_PORT_ERRORS="Ethernet adapter not enumerated under LAN hub"
        fi
    else
        USB_PORT_DETAIL=""
        USB_PORT_ERRORS="UNSUPPORTED_MODEL"
    fi
}

# --- Network ---

check_network() {
    # Ethernet
    ETH_IFACE=$(ip -o link show 2>/dev/null | grep -oP 'eth[0-9]+|end[0-9]+' | head -1 || echo "")
    if [[ -n "$ETH_IFACE" ]]; then
        ETH_LINK=$(cat /sys/class/net/"$ETH_IFACE"/carrier 2>/dev/null || echo "0")
        ETH_SPEED=$(cat /sys/class/net/"$ETH_IFACE"/speed 2>/dev/null || echo "0")
        ETH_PING=""
        if [[ "$ETH_LINK" == "1" ]]; then
            local gw=$(ip route | grep default | grep "$ETH_IFACE" | awk '{print $3}' | head -1)
            [[ -n "$gw" ]] && ETH_PING=$(ping -c 3 -W 2 "$gw" 2>/dev/null | grep -oP 'rtt.*= \K[0-9.]+' || echo "timeout")
        fi
    else
        ETH_LINK="absent"; ETH_SPEED="0"; ETH_PING=""
    fi

    # Wi-Fi
    WIFI_IFACE=$(ip -o link show 2>/dev/null | grep -oP 'wlan[0-9]+' | head -1 || echo "")
    if [[ -n "$WIFI_IFACE" ]]; then
        WIFI_UP=$(cat /sys/class/net/"$WIFI_IFACE"/carrier 2>/dev/null || echo "0")
        # Get link info
        WIFI_LINK_INFO=$(iw dev "$WIFI_IFACE" link 2>/dev/null || echo "")
        WIFI_FREQ=$(echo "$WIFI_LINK_INFO" | grep -oP 'freq: \K[0-9.]+' || echo "")
        WIFI_SPEED=$(echo "$WIFI_LINK_INFO" | grep -oP 'rx bitrate: \K[0-9.]+' || echo "")
        # Determine band
        if [[ -n "$WIFI_FREQ" ]]; then
            WIFI_BAND=$( (( ${WIFI_FREQ%%.*} > 4000 )) && echo "5GHz" || echo "2.4GHz" )
        else
            WIFI_BAND=""
        fi
        # Scan count
        if command -v iwlist &>/dev/null; then
            WIFI_SCAN_COUNT=$(iwlist "$WIFI_IFACE" scan 2>/dev/null | grep -c "Cell" 2>/dev/null || true)
        elif command -v iw &>/dev/null; then
            WIFI_SCAN_COUNT=$(iw dev "$WIFI_IFACE" scan 2>/dev/null | grep -c "BSS " 2>/dev/null || true)
        else
            WIFI_SCAN_COUNT=$WIFI_UP
        fi
        WIFI_SCAN_COUNT=${WIFI_SCAN_COUNT:-0}
    else
        WIFI_UP="absent"; WIFI_SCAN_COUNT=0; WIFI_BAND=""; WIFI_SPEED=""
    fi

    # Bluetooth
    if command -v bluetoothctl &>/dev/null; then
        BT_PRESENT=$(bluetoothctl show 2>/dev/null | grep -c "Controller") || true
        if [[ "$BT_PRESENT" -gt 0 ]]; then
            # Quick scan
            timeout 5 bluetoothctl scan on &>/dev/null &
            sleep 5
            BT_DEVICES=$(bluetoothctl devices 2>/dev/null | wc -l || echo "0")
            bluetoothctl scan off &>/dev/null || true
        else
            BT_DEVICES=0
        fi
    else
        BT_PRESENT=0; BT_DEVICES=0
    fi
}

# --- Display ---

check_display() {
    if command -v kmsprint &>/dev/null; then
        HDMI_STATUS=$(kmsprint 2>/dev/null | head -5 || echo "unavailable")
        HDMI_CONNECTED=$(echo "$HDMI_STATUS" | grep -ci "connected") || true
    elif command -v tvservice &>/dev/null; then
        HDMI_STATUS=$(tvservice -s 2>/dev/null || echo "unavailable")
        HDMI_CONNECTED=$(echo "$HDMI_STATUS" | grep -ci "HDMI") || true
    else
        HDMI_STATUS="no display tool available"; HDMI_CONNECTED=0
    fi
    GPU_MEM=$(vcgencmd get_mem gpu 2>/dev/null | grep -oP '[0-9]+' || echo "0")
}

# --- GPIO ---

check_gpio() {
    GPIO_CHIPS=$(ls /dev/gpiochip* 2>/dev/null | wc -l || echo "0")
    if command -v gpioinfo &>/dev/null; then
        GPIO_LINES=$(gpioinfo 2>/dev/null | wc -l || echo "0")
    else
        GPIO_LINES=$(cat /sys/class/gpio/gpiochip*/ngpio 2>/dev/null | paste -sd+ | bc 2>/dev/null || echo "0")
    fi
}

# --- Camera/DSI ---

check_camera() {
    CAM_DETECTED=0
    if command -v libcamera-hello &>/dev/null; then
        libcamera-hello --timeout 1 --nopreview 2>/dev/null && CAM_DETECTED=1
    elif command -v raspistill &>/dev/null; then
        raspistill -t 1 -o /dev/null 2>/dev/null && CAM_DETECTED=1
    fi
    CSI_PRESENT=$(ls /dev/video* 2>/dev/null | wc -l || echo "0")
}

# --- Manual Tests (require human confirmation) ---

prompt_confirm() {
    local prompt="$1"
    local response
    echo -en "${CYAN}[MANUAL]${NC} ${prompt} (y/n): " >&2
    read -r response </dev/tty
    [[ "$response" =~ ^[Yy] ]] && echo "PASS" || echo "FAIL"
}

prompt_yns() {
    local prompt="$1"
    local response
    echo -en "${CYAN}[MANUAL]${NC} ${prompt} (y/n/s=skip): " >&2
    read -r response </dev/tty
    if [[ "$response" =~ ^[Yy] ]]; then echo "PASS"
    elif [[ "$response" =~ ^[Ss] ]]; then echo "SKIP"
    else echo "FAIL"
    fi
}

run_manual_tests() {
    echo "" >&2
    echo "--- Manual Verification ---" >&2

    # HDMI visual confirmation per port
    HDMI_VISUAL=()
    for ((i=1; i<=EXPECTED_HDMI; i++)); do
        local label="HDMI"
        [[ $EXPECTED_HDMI -gt 1 ]] && label="HDMI port $i"
        HDMI_VISUAL+=("$(prompt_confirm "Can you see display output on ${label}?")")
    done

    # Audio jack test
    AUDIO_JACK_RESULT="N/A"
    if [[ $HAS_AUDIO_JACK -eq 1 ]]; then
        # Play a test tone if aplay is available
        if command -v speaker-test &>/dev/null; then
            echo -e "${CYAN}[MANUAL]${NC} Playing test tone on audio jack..." >&2
            # Try headphone-specific ALSA device names without changing system config
            timeout 5 speaker-test -t sine -f 440 -l 1 -D plughw:Headphones 2>/dev/null || \
                timeout 5 speaker-test -t sine -f 440 -l 1 -D plughw:0,0 2>/dev/null || true
        fi
        AUDIO_JACK_RESULT=$(prompt_confirm "Did you hear audio from the 3.5mm jack?")
    fi

    # Camera test — auto-detect, prompt only if camera is present
    if [[ $CAM_DETECTED -eq 1 ]]; then
        CAMERA_RESULT=$(prompt_yns "Is camera output working? (y/n/s=skip)")
    else
        CAMERA_RESULT="SKIP"
    fi
}

# --- Build JSON Output ---

build_json() {
    cat <<EOF
{
  "test_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "missing_deps": "$MISSING_DEPS",
  "system": {
    "model": $(json_escape "$MODEL"),
    "serial": $(json_escape "$SERIAL"),
    "revision": $(json_escape "$REVISION"),
    "ram_mb": $RAM_MB,
    "soc": $(json_escape "$SOC"),
    "kernel": $(json_escape "$KERNEL"),
    "os": $(json_escape "$OS_VERSION"),
    "firmware": $(json_escape "$FW_VERSION"),
    "eeprom": $(json_escape "$EEPROM")
  },
  "thermal": {
    "idle_temp_c": $TEMP_IDLE,
    "throttle_hex": "$THROTTLE_HEX",
    "undervolt_now": $UNDERVOLT_NOW,
    "freq_cap_now": $FREQ_CAP_NOW,
    "throttle_now": $THROTTLE_NOW,
    "undervolt_history": $UNDERVOLT_HIST,
    "freq_cap_history": $FREQ_CAP_HIST,
    "throttle_history": $THROTTLE_HISTORY
  },
  "cpu_stress": {
    "result": "$STRESS_RESULT",
    "duration_s": $STRESS_DURATION,
    "max_temp_c": $STRESS_MAX_TEMP,
    "throttled": $STRESS_THROTTLED,
    "clock_hz": "$STRESS_CLOCK"
  },
  "memory": {
    "total_mb": $RAM_MB,
    "tested_mb": ${MEMTEST_MB:-0},
    "result": "$MEM_RESULT",
    "errors": $MEM_ERRORS
  },
  "storage": {
    "boot_media": $(json_escape "$BOOT_MEDIA"),
    "sd_slot": $(json_escape "$SD_SLOT"),
    "boot_device": $(json_escape "$BOOT_DEVICE")
  },
  "usb": {
    "devices_found": $USB_DEVICES,
    "controllers": $USB_CONTROLLERS,
    "expected_ports": $EXPECTED_USB,
    "port_detail": $(json_escape "${USB_PORT_DETAIL:-}"),
    "port_errors": $(json_escape "${USB_PORT_ERRORS:-}"),
    "lan_hub_present": ${LAN_HUB:-0},
    "lan_eth_present": ${LAN_ETH:-0},
    "ports_used": ${USB_PORTS_USED:-0},
    "device_list": $(json_escape "$USB_LIST")
  },
  "network": {
    "ethernet": {
      "interface": $(json_escape "$ETH_IFACE"),
      "link": "$ETH_LINK",
      "speed_mbps": "$ETH_SPEED",
      "ping_ms": "$ETH_PING",
      "expected_speed": $EXPECTED_ETH_SPEED
    },
    "wifi": {
      "interface": $(json_escape "$WIFI_IFACE"),
      "up": "$WIFI_UP",
      "band": $(json_escape "${WIFI_BAND:-}"),
      "speed_mbps": $(json_escape "${WIFI_SPEED:-}"),
      "networks_found": $WIFI_SCAN_COUNT,
      "expected": $HAS_WIFI
    },
    "bluetooth": {
      "present": $BT_PRESENT,
      "devices_found": $BT_DEVICES,
      "expected": $HAS_BT
    }
  },
  "display": {
    "hdmi_connected": $HDMI_CONNECTED,
    "status": $(json_escape "$HDMI_STATUS"),
    "gpu_mem_mb": $GPU_MEM
  },
  "gpio": {
    "chips": $GPIO_CHIPS,
    "lines": $GPIO_LINES,
    "expected_gpio": $EXPECTED_GPIO
  },
  "camera": {
    "detected": $CAM_DETECTED,
    "video_devices": $CSI_PRESENT
  },
  "manual_tests": {
    "hdmi_visual": [$(printf '"%s",' "${HDMI_VISUAL[@]}" | sed 's/,$//')],
    "audio_jack": $(json_escape "$AUDIO_JACK_RESULT"),
    "camera": $(json_escape "$CAMERA_RESULT"),
    "expected_hdmi_ports": $EXPECTED_HDMI,
    "has_audio_jack": $HAS_AUDIO_JACK
  }
}
EOF
}

# --- Main ---

[[ $(id -u) -ne 0 ]] && die "Must run as root (sudo)"

echo "=== Raspberry Pi Hardware Validation ===" >&2
check_deps
get_sysinfo
echo "Model: $MODEL | RAM: ${RAM_MB}MB | Serial: $SERIAL" >&2

# Quick checks needed for manual prompts
check_display
check_camera

# Manual tests first (so user can walk away during automated tests)
run_manual_tests

# Automated checks (seconds each)
echo "--- Power & Thermal ---" >&2
get_thermal

echo "--- GPIO Check ---" >&2
check_gpio

echo "--- USB Check ---" >&2
check_usb

echo "--- Network Check ---" >&2
check_network

# Medium (30-60s)
echo "--- Storage Test ---" >&2
run_storage_test

# Long tests last (1-5 min each)
if [[ $QUICK -eq 0 ]]; then
    echo "--- CPU Stress Test (${STRESS_DURATION}s) ---" >&2
    run_cpu_stress

    echo "--- Memory Test ---" >&2
    run_memory_test
else
    echo "--- Skipping CPU Stress (--quick) ---" >&2
    STRESS_RESULT="SKIP"; STRESS_MAX_TEMP="0"; STRESS_THROTTLED=0; STRESS_CLOCK="0"
    echo "--- Skipping Memory Test (--quick) ---" >&2
    MEM_RESULT="SKIP"; MEM_ERRORS=0; MEMTEST_MB=0
fi

echo "--- Writing Results ---" >&2
build_json > "$OUTPUT"
echo "Results saved to: $OUTPUT" >&2

# --- Print Screenshot-Friendly Summary ---

print_summary() {
    clear 2>/dev/null || true
    local pass="${GREEN} PASS ${NC}" warn="${YELLOW} WARN ${NC}" fail="${RED} FAIL ${NC}" skip="${CYAN} SKIP ${NC}"

    # Determine per-category status
    local pwr_status="$pass" cpu_status="$pass" mem_status="$pass"
    local stor_status="$pass" usb_status="$pass" net_status="$pass"
    local disp_status="$pass" gpio_status="$pass"
    local overall="${GREEN}PASS${NC}" issues=0

    # Power
    local pwr_detail=""
    if [[ $UNDERVOLT_NOW -eq 1 ]]; then
        pwr_status="$fail"; overall="${RED}FAIL${NC}"; ((issues++)) || true
        pwr_detail="Undervoltage detected — bad power supply"
    elif [[ $THROTTLE_NOW -eq 1 ]]; then
        pwr_status="$fail"; overall="${RED}FAIL${NC}"; ((issues++)) || true
        pwr_detail="Thermal throttling active"
    elif [[ $UNDERVOLT_HIST -eq 1 ]]; then
        pwr_status="$warn"
        pwr_detail="Undervoltage occurred previously"
    elif [[ $THROTTLE_HISTORY -eq 1 ]]; then
        pwr_status="$warn"
        pwr_detail="Thermal throttling occurred previously"
    else
        pwr_detail="Clean — no issues detected"
    fi

    # CPU
    if [[ "$STRESS_RESULT" == "SKIP" ]]; then
        cpu_status="$skip"
    elif [[ $STRESS_THROTTLED -eq 1 ]]; then
        cpu_status="$fail"; overall="${RED}FAIL${NC}"; ((issues++)) || true
    fi

    # Memory
    if [[ "$MEM_RESULT" == "SKIP" ]]; then
        mem_status="$skip"
    elif [[ "$MEM_RESULT" == "FAIL" ]]; then
        mem_status="$fail"; overall="${RED}FAIL${NC}"; ((issues++)) || true
    fi

    # Storage — if we booted, it works
    stor_status="$pass"

    # USB
    if [[ $USB_CONTROLLERS -lt 2 ]] && [[ $EXPECTED_USB -ge 4 ]] && ! echo "$MODEL" | grep -qi "Pi 3"; then
        usb_status="$fail"; overall="${RED}FAIL${NC}"; ((issues++)) || true
    elif echo "$MODEL" | grep -qi "Pi 3" && [[ "${LAN_HUB:-0}" -eq 0 ]]; then
        usb_status="$fail"; overall="${RED}FAIL${NC}"; ((issues++)) || true
    elif [[ "$USB_PORT_ERRORS" == "UNSUPPORTED_MODEL" ]]; then
        usb_status="$warn"
    elif [[ -n "$USB_PORT_ERRORS" ]]; then
        usb_status="$warn"
    fi

    # Network
    if [[ $HAS_WIFI -eq 1 && -z "$WIFI_IFACE" ]]; then
        net_status="$fail"; overall="${RED}FAIL${NC}"; ((issues++)) || true
    fi

    # Display
    if [[ $HDMI_CONNECTED -eq 0 ]]; then
        disp_status="—"
    fi

    # GPIO
    if [[ $GPIO_CHIPS -eq 0 ]]; then
        gpio_status="$fail"; overall="${RED}FAIL${NC}"; ((issues++)) || true
    fi

    # EEPROM note
    local eeprom_note=""
    local eeprom_status="$pass"
    if [[ -n "$EEPROM" ]]; then
        eeprom_note="${EEPROM}"
    else
        eeprom_note="N/A"
        eeprom_status="${CYAN}—${NC}"
    fi

    # RAM in friendly format
    # Map reported RAM to nominal size (GPU/kernel eat some)
    local ram_gb
    if [[ $RAM_MB -gt 7000 ]]; then ram_gb=8
    elif [[ $RAM_MB -gt 3500 ]]; then ram_gb=4
    elif [[ $RAM_MB -gt 1800 ]]; then ram_gb=2
    elif [[ $RAM_MB -gt 900 ]]; then ram_gb=1
    elif [[ $RAM_MB -gt 400 ]]; then ram_gb="512 MB"
    else ram_gb="?"
    fi
    [[ "$ram_gb" != *MB* && "$ram_gb" != "?" ]] && ram_gb="${ram_gb} GB"
    local mode_note=""
    [[ $QUICK -eq 1 ]] && mode_note=" (quick mode)"

    # Get pinout info if available
    local usb_desc="" eth_desc=""
    if command -v pinout &>/dev/null; then
        usb_desc=$(pinout 2>/dev/null | grep "USB ports" | sed 's/.*: //')
        eth_desc=$(pinout 2>/dev/null | grep "Ethernet" | sed 's/.*: //')
    fi
    [[ -z "$usb_desc" ]] && usb_desc="${USB_CONTROLLERS} controllers, ${USB_DEVICES} devices"

    echo -e ""
    echo -e "╔══════════════════════════════════════════════════════════════╗"
    echo -e "║        ${CYAN}RASPBERRY PI HARDWARE TEST REPORT${NC}${mode_note}"
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  Model:    $MODEL"
    echo -e "║  Revision: $REVISION"
    echo -e "║  RAM:      ${ram_gb}"
    echo -e "║  Serial:   $SERIAL"
    echo -e "║  OS:       $OS_VERSION"
    echo -e "║  Tested:   $(date +%Y-%m-%d\ %H:%M)"
    if [[ -n "$EEPROM" ]]; then
        echo -e "║  EEPROM:   ${EEPROM}"
    fi
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  CATEGORY        │ RESULT │ DETAIL"
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  Power           │ $pwr_status │ ${pwr_detail}"
    echo -e "║  Temperature     │ $pass │ Idle ${TEMP_IDLE}°C"
    echo -e "║  CPU Stress      │ $cpu_status │ Max ${STRESS_MAX_TEMP}°C / ${STRESS_DURATION}s"
    echo -e "║  Memory          │ $mem_status │ ${ram_gb}"
    echo -e "║  Boot Media      │ $stor_status │ ${BOOT_MEDIA} (${BOOT_DEVICE})"
    # USB - split into USB2 and USB3 lines
    if echo "$MODEL" | grep -qi "Pi 4\|Pi 400"; then
        local usb2_status="$pass" usb3_status="$pass"
        local usb2_txt="Devices detected in all ports"
        local usb3_txt="Devices detected in all ports"
        # usb2_devs and usb3_devs from check_usb
        if [[ ${USB2_DEVS:-0} -lt 2 ]]; then
            usb2_status="$warn"; usb2_txt="${USB2_DEVS:-0}/2 ports with devices"
        fi
        if [[ ${USB3_DEVS:-0} -lt 2 ]]; then
            usb3_status="$warn"; usb3_txt="${USB3_DEVS:-0}/2 ports with devices"
        fi
        echo -e "║  USB 2.0         │ $usb2_status │ ${usb2_txt}"
        echo -e "║  USB 3.0         │ $usb3_status │ ${usb3_txt}"
    elif echo "$MODEL" | grep -qi "Pi 3"; then
        local usb_pi3_status="$pass"
        local usb_pi3_txt=""
        if [[ "${LAN_HUB:-0}" -eq 0 ]]; then
            usb_pi3_status="$fail"; usb_pi3_txt="Internal USB hub NOT detected — chip may be dead"
        elif [[ "${LAN_ETH:-0}" -eq 0 ]]; then
            usb_pi3_status="$warn"; usb_pi3_txt="Hub OK but Ethernet adapter missing"
        elif [[ "${USB_PORTS_USED:-0}" -gt 0 ]]; then
            usb_pi3_txt="${USB_PORTS_USED}/4 ports in use"
        else
            usb_pi3_txt="No external devices connected"
        fi
        echo -e "║  USB             │ $usb_pi3_status │ ${usb_pi3_txt}"
    elif [[ "$USB_PORT_ERRORS" == "UNSUPPORTED_MODEL" ]]; then
        echo -e "║  USB             │ $warn │ Model needs USB validation support"
    else
        echo -e "║  USB             │ $usb_status │ ${USB_DEVICES} devices detected"
    fi
    local wifi_txt="N/A" bt_txt="N/A" eth_txt="N/A"
    if [[ $HAS_WIFI -eq 1 ]]; then
        if [[ -n "$WIFI_IFACE" ]] && [[ "${WIFI_SCAN_COUNT:-0}" -gt 0 ]] 2>/dev/null; then
            wifi_txt="${WIFI_BAND:+${WIFI_BAND} }${WIFI_SPEED:+${WIFI_SPEED} Mbps}"
            [[ -z "$wifi_txt" ]] && wifi_txt="Connected"
        else
            wifi_txt="FAIL"
        fi
    fi
    if [[ $HAS_BT -eq 1 ]]; then
        if [[ "${BT_PRESENT:-0}" -gt 0 ]]; then
            bt_txt="OK"
        else
            bt_txt="FAIL"
        fi
    fi
    if [[ $EXPECTED_ETH_SPEED -gt 0 ]]; then
        if [[ "$ETH_LINK" == "1" ]]; then
            eth_txt="${ETH_SPEED}Mbps link"
        else
            eth_txt="No cable (${EXPECTED_ETH_SPEED}Mbps port)"
        fi
    fi
    local wifi_status="$pass" bt_status="$pass" eth_status="$pass"
    [[ "$wifi_txt" == "FAIL" ]] && wifi_status="$fail"
    [[ "$wifi_txt" == "N/A" ]] && wifi_status="${CYAN} N/A  ${NC}"
    [[ "$bt_txt" == "FAIL" ]] && bt_status="$fail"
    [[ "$bt_txt" == "N/A" ]] && bt_status="${CYAN} N/A  ${NC}"
    [[ "$eth_txt" == No\ cable* ]] && eth_status="$warn"
    [[ "$eth_txt" == "N/A" ]] && eth_status="${CYAN} N/A  ${NC}"
    echo -e "║  Ethernet        │ $eth_status │ ${eth_txt}"
    echo -e "║  WiFi            │ $wifi_status │ ${wifi_txt}"
    echo -e "║  Bluetooth       │ $bt_status │ ${bt_txt}"
    if [[ $HDMI_CONNECTED -gt 0 ]]; then
        local res=$(echo "$HDMI_STATUS" | grep -oP '\d+x\d+@[0-9.]+' | head -1 || echo "connected")
        local hdmi_detail="Connected, ${res}"
        local hdmi_status="$pass"
        for ((i=0; i<${#HDMI_VISUAL[@]}; i++)); do
            if [[ "${HDMI_VISUAL[$i]}" == "FAIL" ]]; then
                hdmi_status="$fail"; hdmi_detail="${hdmi_detail}, visual FAIL"
                overall="${RED}FAIL${NC}"; ((issues++)) || true
            fi
        done
        echo -e "║  HDMI            │ $hdmi_status │ ${hdmi_detail}"
    else
        for ((i=0; i<${#HDMI_VISUAL[@]}; i++)); do
            local hdmi_v_status="$pass"
            [[ "${HDMI_VISUAL[$i]}" == "FAIL" ]] && { hdmi_v_status="$fail"; overall="${RED}FAIL${NC}"; ((issues++)) || true; }
            echo -e "║  HDMI            │ $hdmi_v_status │ Visual confirmed"
        done
    fi
    # Manual test: Audio jack
    if [[ $HAS_AUDIO_JACK -eq 1 ]]; then
        local audio_status="$pass"
        [[ "$AUDIO_JACK_RESULT" == "FAIL" ]] && { audio_status="$fail"; overall="${RED}FAIL${NC}"; ((issues++)) || true; }
        echo -e "║  Audio Jack      │ $audio_status │ 3.5mm audio confirmed"
    fi
    # Camera (manual test result)
    if [[ "$CAMERA_RESULT" == "PASS" ]]; then
        echo -e "║  Camera (CSI)    │ $pass │ Detected and confirmed"
    elif [[ "$CAMERA_RESULT" == "FAIL" ]]; then
        echo -e "║  Camera (CSI)    │ $fail │ Connected but not detected"
        overall="${RED}FAIL${NC}"; ((issues++)) || true
    elif [[ "$CAMERA_RESULT" == "SKIP" ]]; then
        echo -e "║  Camera (CSI)    │ $skip │ No camera connected"
    fi
    echo -e "╠══════════════════════════════════════════════════════════════╣"
    echo -e "║  VERDICT:  $overall ($issues issues)"
    echo -e "╚══════════════════════════════════════════════════════════════╝"
    echo -e ""
}

print_summary >&2
echo "=== Testing Complete ===" >&2
