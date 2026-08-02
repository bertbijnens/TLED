#!/usr/bin/env bash
# TLED Auto-Flash
#
# Detects a plugged-in ESP32-C6, reads the installed firmware version from
# flash, and flashes the local firmware if the version differs.
#
# Usage:
#   ./auto-flash.sh              # flash the device currently on USB
#   ./auto-flash.sh --watch      # keep watching; flash whenever a device is plugged in
#   ./auto-flash.sh --force      # flash even if versions match
#   ./auto-flash.sh --full       # full install (erases NVS/commissioning data)
#   ./auto-flash.sh --port /dev/tty.usbmodem1 [flags]
#
# Requirements:
#   pip3 install esptool          (or: python3 -m pip install esptool)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIRMWARE_DIR="$SCRIPT_DIR/firmware"
MANIFEST="$SCRIPT_DIR/manifest.json"

# Flash offsets (from manifest.json / partitions.csv)
OFFSET_BOOTLOADER="0x0"
OFFSET_PARTITIONS="0xC000"
OFFSET_OTADATA="0x1D000"
OFFSET_APP="0x20000"

# esptool settings
CHIP="esp32c6"
BAUD="460800"

# ── colours ─────────────────────────────────────────────────────────────────
CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[tled]${NC} $*"; }
ok()    { echo -e "${GREEN}[tled]${NC} $*"; }
warn()  { echo -e "${YELLOW}[tled]${NC} $*"; }
die()   { echo -e "${RED}[tled]${NC} $*" >&2; exit 1; }

# ── helpers ──────────────────────────────────────────────────────────────────

check_deps() {
    if ! python3 -c "import esptool" 2>/dev/null; then
        die "esptool not found. Install it with: pip3 install esptool"
    fi
    if ! command -v python3 &>/dev/null; then
        die "python3 not found."
    fi
}

local_version() {
    python3 -c "import json; print(json.load(open('$MANIFEST'))['version'])"
}

# Returns first ESP32 serial port found, or empty string.
find_port() {
    local p=""
    # macOS — native USB-CDC (ESP32-C6 built-in USB)
    p=$(ls /dev/tty.usbmodem* 2>/dev/null | head -1 || true)
    # macOS — CP2102 / CH340 USB-serial adapter
    [[ -z "$p" ]] && p=$(ls /dev/tty.usbserial-* 2>/dev/null | head -1 || true)
    # Linux — ACM (native USB)
    [[ -z "$p" ]] && p=$(ls /dev/ttyACM* 2>/dev/null | head -1 || true)
    # Linux — USB-serial adapter
    [[ -z "$p" ]] && p=$(ls /dev/ttyUSB* 2>/dev/null | head -1 || true)
    echo "$p"
}

# Read the installed firmware version from flash by locating the
# esp_app_desc_t magic word (0xABCD5AA5) at the app partition start.
# esptool resets the chip to ROM download mode to do the read, then lets
# the firmware restart — this takes ~3 seconds.
device_version() {
    local port="$1"
    python3 - "$port" "$OFFSET_APP" "$BAUD" "$CHIP" <<'PYEOF'
import sys, struct, subprocess, tempfile, os

port, offset_str, baud, chip = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
offset = int(offset_str, 16) if offset_str.startswith('0x') else int(offset_str)

tmp = tempfile.NamedTemporaryFile(suffix='.bin', delete=False)
tmp.close()

try:
    r = subprocess.run(
        ['python3', '-m', 'esptool',
         '--port', port, '--baud', baud, '--chip', chip,
         'read_flash', hex(offset), '256', tmp.name],
        capture_output=True, text=True, timeout=20
    )
    if r.returncode != 0:
        sys.stderr.write(r.stderr)
        sys.exit(1)

    data = open(tmp.name, 'rb').read()

    # Locate esp_app_desc_t by magic word
    MAGIC = 0xABCD5AA5
    for i in range(0, len(data) - 48, 4):
        if struct.unpack_from('<I', data, i)[0] == MAGIC:
            raw = data[i + 16 : i + 48]
            version = raw.rstrip(b'\x00').decode('utf-8', errors='replace').strip()
            print(version)
            sys.exit(0)

    sys.stderr.write("Magic word not found — possibly blank or incompatible firmware\n")
    sys.exit(1)
finally:
    os.unlink(tmp.name)
PYEOF
}

# Flash only the app binary (preserves NVS / Matter commissioning data).
flash_update() {
    local port="$1"
    info "Flashing app binary only (NVS preserved)..."
    python3 -m esptool \
        --port "$port" --baud "$BAUD" --chip "$CHIP" \
        --before default_reset --after hard_reset \
        write_flash "$OFFSET_APP" "$FIRMWARE_DIR/tled.bin"
}

# Full install: erase chip and write all parts (loses commissioning data).
flash_full() {
    local port="$1"
    warn "Full install — this erases NVS and Matter commissioning data."
    warn "You will need to re-pair the device in your smart home app."
    read -r -p "Continue? [y/N] " confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { info "Aborted."; return; }

    python3 -m esptool \
        --port "$port" --baud "$BAUD" --chip "$CHIP" \
        --before default_reset --after hard_reset \
        write_flash \
            "$OFFSET_BOOTLOADER" "$FIRMWARE_DIR/bootloader.bin" \
            "$OFFSET_PARTITIONS" "$FIRMWARE_DIR/partition-table.bin" \
            "$OFFSET_OTADATA"    "$FIRMWARE_DIR/ota_data_initial.bin" \
            "$OFFSET_APP"        "$FIRMWARE_DIR/tled.bin"
}

# ── per-device logic ─────────────────────────────────────────────────────────

handle_device() {
    local port="$1"
    local lv dv

    lv=$(local_version)
    echo ""
    info "Device found: ${BOLD}$port${NC}"
    info "Local firmware version:  ${BOLD}$lv${NC}"

    info "Reading installed version from flash (~3s)..."
    if dv=$(device_version "$port" 2>/tmp/tled-esptool-err); then
        info "Installed firmware version: ${BOLD}$dv${NC}"
    else
        warn "Could not read version: $(cat /tmp/tled-esptool-err | tail -1)"
        dv="UNKNOWN"
    fi

    if [[ "$dv" == "$lv" ]] && [[ "$FORCE" == false ]]; then
        ok "Already up to date ($lv). Use --force to flash anyway."
        return
    fi

    if [[ "$dv" != "UNKNOWN" && "$dv" != "$lv" ]]; then
        info "Version differs ($dv → $lv). Flashing..."
    fi

    if [[ "$FULL" == true ]]; then
        flash_full "$port"
    else
        flash_update "$port"
    fi

    ok "Done. Device is running $lv."
}

# ── argument parsing ─────────────────────────────────────────────────────────

WATCH=false
FORCE=false
FULL=false
PORT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --watch)  WATCH=true ;;
        --force)  FORCE=true ;;
        --full)   FULL=true ;;
        --port)   shift; PORT="$1" ;;
        --port=*) PORT="${1#--port=}" ;;
        -h|--help)
            grep '^#' "$0" | head -20 | sed 's/^# \?//'
            exit 0 ;;
        *) die "Unknown argument: $1. Use --help for usage." ;;
    esac
    shift
done

# ── main ─────────────────────────────────────────────────────────────────────

check_deps

if [[ -n "$PORT" ]]; then
    handle_device "$PORT"
elif [[ "$WATCH" == true ]]; then
    info "Watching for ESP32-C6 device... (Ctrl-C to stop)"
    last_port=""
    while true; do
        port=$(find_port)
        if [[ -n "$port" && "$port" != "$last_port" ]]; then
            sleep 1  # let USB enumerate fully
            handle_device "$port" || warn "Flash failed — check the connection and try again."
            last_port="$port"
        elif [[ -z "$port" && -n "$last_port" ]]; then
            info "Device disconnected."
            last_port=""
        fi
        sleep 2
    done
else
    port=$(find_port)
    [[ -z "$port" ]] && die "No ESP32 device found. Plug one in, or use --watch to wait."
    handle_device "$port"
fi
