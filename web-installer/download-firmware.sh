#!/usr/bin/env bash
# Download the latest firmware from GitHub Actions CI and place it in
# web-installer/firmware/ so auto-flash.sh or serve-local.sh can use it.
#
# Usage:
#   ./download-firmware.sh                        # latest successful build (any branch)
#   ./download-firmware.sh main                   # latest from main
#   ./download-firmware.sh feature/ws2805-rgbcct  # latest from a feature branch
#   ./download-firmware.sh --run 30744368173       # specific run ID
#   ./download-firmware.sh --serve                 # download then start local server
#   ./download-firmware.sh --flash                 # download then auto-flash device
#
# Requires: gh (GitHub CLI) — brew install gh

set -euo pipefail

REPO="bertbijnens/TLED"
ARTIFACT="tled-firmware"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FIRMWARE_DIR="$SCRIPT_DIR/firmware"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info() { echo -e "${CYAN}[tled]${NC} $*"; }
ok()   { echo -e "${GREEN}[tled]${NC} $*"; }
die()  { echo -e "${RED}[tled]${NC} $*" >&2; exit 1; }

# ── argument parsing ─────────────────────────────────────────────────────────

BRANCH=""
RUN_ID=""
SERVE=false
FLASH=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --run)    shift; RUN_ID="$1" ;;
        --run=*)  RUN_ID="${1#--run=}" ;;
        --serve)  SERVE=true ;;
        --flash)  FLASH=true ;;
        -h|--help)
            grep '^#' "$0" | head -15 | sed 's/^# \?//'
            exit 0 ;;
        -*) die "Unknown flag: $1" ;;
        *)  BRANCH="$1" ;;
    esac
    shift
done

# ── checks ───────────────────────────────────────────────────────────────────

command -v gh &>/dev/null || die "GitHub CLI not found. Install with: brew install gh"
gh auth status &>/dev/null   || die "Not logged in to GitHub CLI. Run: gh auth login"

# ── find run ─────────────────────────────────────────────────────────────────

if [[ -z "$RUN_ID" ]]; then
    info "Looking for latest successful CI build..."

    FILTER=(--repo "$REPO" --workflow build-firmware.yml --status success --limit 1
             --json databaseId,headBranch,createdAt,headSha)
    [[ -n "$BRANCH" ]] && FILTER+=(--branch "$BRANCH")

    RUN_JSON=$(gh run list "${FILTER[@]}" --jq '.[0]')
    [[ "$RUN_JSON" == "null" || -z "$RUN_JSON" ]] && \
        die "No successful build found${BRANCH:+ for branch '$BRANCH'}."

    RUN_ID=$(echo  "$RUN_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['databaseId'])")
    RUN_BRANCH=$(echo "$RUN_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['headBranch'])")
    RUN_SHA=$(echo    "$RUN_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['headSha'][:8])")

    info "Run #${RUN_ID}  branch=${RUN_BRANCH}  commit=${RUN_SHA}"
fi

# ── download ─────────────────────────────────────────────────────────────────

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

info "Downloading artifact '${ARTIFACT}' from run #${RUN_ID}..."
gh run download "$RUN_ID" --repo "$REPO" --name "$ARTIFACT" --dir "$TMP_DIR"

# Artifact preserves the build/ directory structure; use find so we're not
# sensitive to any future layout changes.
find_bin() { find "$TMP_DIR" -name "$1" | head -1; }

TLED_BIN=$(find_bin "tled.bin")
BOOT_BIN=$(find_bin "bootloader.bin")
PART_BIN=$(find_bin "partition-table.bin")
OTA_BIN=$(find_bin  "ota_data_initial.bin")

[[ -z "$TLED_BIN" ]] && die "tled.bin not found in artifact."

mkdir -p "$FIRMWARE_DIR"
cp "$TLED_BIN" "$FIRMWARE_DIR/tled.bin"
cp "$BOOT_BIN" "$FIRMWARE_DIR/bootloader.bin"
cp "$PART_BIN" "$FIRMWARE_DIR/partition-table.bin"
cp "$OTA_BIN"  "$FIRMWARE_DIR/ota_data_initial.bin"

ok "Firmware written to $FIRMWARE_DIR/"
ls -lh "$FIRMWARE_DIR/"*.bin

# ── optional follow-up ───────────────────────────────────────────────────────

if [[ "$FLASH" == true ]]; then
    echo ""
    "$SCRIPT_DIR/auto-flash.sh"
elif [[ "$SERVE" == true ]]; then
    echo ""
    info "Starting local web installer at http://localhost:8080"
    info "(Web Serial requires HTTPS — use Caddy for actual flashing)"
    "$SCRIPT_DIR/serve-local.sh"
fi
