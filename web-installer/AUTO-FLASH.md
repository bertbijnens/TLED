# TLED Auto-Flash

Detects a plugged-in ESP32-C6, reads the installed firmware version directly
from flash, and updates it automatically if the version differs.

## Requirements

```bash
pip3 install esptool
```

## Usage

```bash
# Flash the device currently plugged in
./auto-flash.sh

# Keep watching — auto-flash whenever a device is plugged in
./auto-flash.sh --watch

# Force-flash even if the version already matches
./auto-flash.sh --force

# Full install — erases NVS and Matter commissioning data (asks for confirmation)
./auto-flash.sh --full

# Specify port explicitly
./auto-flash.sh --port /dev/tty.usbmodem1
```

## How it works

1. **Detects the device** by polling for a USB serial port:
   - macOS native USB: `/dev/tty.usbmodem*`
   - macOS USB-serial adapter: `/dev/tty.usbserial-*`
   - Linux native USB: `/dev/ttyACM*`
   - Linux USB-serial adapter: `/dev/ttyUSB*`

2. **Reads the installed version** from flash without modifying anything.
   `esptool` resets the chip into ROM download mode, reads 256 bytes from
   the app partition (`0x20000`), and locates the `esp_app_desc_t` structure
   by its magic word (`0xABCD5AA5`). The version string sits 16 bytes into
   that structure. The chip then reboots and resumes normal operation.
   This takes about 3 seconds.

3. **Compares** the installed version against the version in `manifest.json`.

4. **Flashes** if the versions differ (or if `--force` is given).

## Flash modes

| Mode | What gets flashed | NVS / commissioning |
|------|-------------------|---------------------|
| Default (update) | `tled.bin` only at `0x20000` | **Preserved** |
| `--full` | bootloader + partition table + otadata + app | **Erased** — re-pair required |

Use the default mode for routine firmware updates. Use `--full` only when
setting up a brand-new device or recovering from a corrupted flash.

## Flash offsets (from partitions.csv / manifest.json)

| File | Offset |
|------|--------|
| `bootloader.bin` | `0x0000` |
| `partition-table.bin` | `0xC000` |
| `ota_data_initial.bin` | `0x1D000` |
| `tled.bin` (app) | `0x20000` |
