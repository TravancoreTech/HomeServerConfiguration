#!/usr/bin/env bash

# ==============================================================================
# HOMESERVER SUITE — BOOTSTRAP INSTALLER
# ==============================================================================
# Downloads the homeserver suite to the current directory (no git required)
# and starts the interactive setup script.
# ==============================================================================

set -euo pipefail

# Configuration
REPO_ZIP="https://github.com/TravancoreTech/HomeServerConfiguration/archive/refs/heads/main.zip"
INSTALL_DIR=$(pwd)
SERVICE_NAME="homeserver-webui"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

info()    { echo -e "${BLUE}  ▸${NC} $*"; }
ok()      { echo -e "${GREEN}  ✔${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()     { echo -e "${RED}  ✘ ERROR:${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BLUE}[$1/3]${NC} $2"; }

# Header
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}      ${GREEN}Homeserver Suite — Bootstrap${NC}           ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${DIM}  Target dir  : ${INSTALL_DIR}${NC}"
echo ""

# Cleanup existing WebUI systemd service if it exists (requires sudo/root)
if systemctl is-active --quiet "$SERVICE_NAME" || systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null || [ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]; then
  section 0 "Removing existing WebUI system service..."
  if [ "$EUID" -ne 0 ]; then
    info "Sudo privileges are required to remove the systemd service. Please authorize."
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || true
    sudo systemctl daemon-reload 2>/dev/null || true
  else
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service" 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
  fi
  ok "WebUI service stopped and removed successfully."
fi

# ==============================================================================
# STEP 1 — Ensure curl and unzip are available
# ==============================================================================
section 1 "Installing prerequisites (curl, unzip)..."

# Detect package manager
if command -v apt-get &>/dev/null; then
  PKG_MGR="apt-get"
  INSTALL_CMD="apt-get install -y -qq"
  UPDATE_CMD="apt-get update -qq"
elif command -v dnf &>/dev/null; then
  PKG_MGR="dnf"
  INSTALL_CMD="dnf install -y -q"
  UPDATE_CMD="dnf check-update -q || true"
elif command -v yum &>/dev/null; then
  PKG_MGR="yum"
  INSTALL_CMD="yum install -y -q"
  UPDATE_CMD="true"
else
  PKG_MGR=""
fi

install_dep() {
  local dep="$1"
  if ! command -v "$dep" &>/dev/null; then
    info "Installing $dep..."
    if [ -n "$PKG_MGR" ]; then
      if [ "$EUID" -ne 0 ]; then
        sudo $UPDATE_CMD
        sudo $INSTALL_CMD "$dep"
      else
        $UPDATE_CMD
        $INSTALL_CMD "$dep"
      fi
      ok "$dep installed"
    else
      die "$dep is missing and no supported package manager (apt, dnf, yum) was found. Please install it manually."
    fi
  else
    ok "$dep already available"
  fi
}

install_dep curl
install_dep unzip

# ==============================================================================
# STEP 2 — Download and extract the homeserver suite zip
# ==============================================================================
section 2 "Downloading and deploying Homeserver Suite..."

TMP_ZIP=$(mktemp /tmp/homeserver-XXXXXX.zip)
TMP_DIR=$(mktemp -d /tmp/homeserver-extract-XXXXXX)

info "Downloading zip from GitHub..."
if ! curl -fsSL --progress-bar "$REPO_ZIP" -o "$TMP_ZIP"; then
  rm -f "$TMP_ZIP"
  die "Failed to download the suite. Check your internet connection and REPO_ZIP URL."
fi

ok "Download complete ($(du -sh "$TMP_ZIP" | cut -f1))"

info "Extracting..."
unzip -q -o "$TMP_ZIP" -d "$TMP_DIR"

# GitHub archives extract into a subdirectory like repo-main/
EXTRACTED_SUBDIR=$(find "$TMP_DIR" -maxdepth 1 -mindepth 1 -type d | head -1)
if [ -z "$EXTRACTED_SUBDIR" ]; then
  die "Could not find extracted content inside zip. Archive may be malformed."
fi

# Copy all files directly to the current working directory
cp -r "${EXTRACTED_SUBDIR}/." "$INSTALL_DIR/"

# Cleanup temp files
rm -rf "$TMP_ZIP" "$TMP_DIR"

# Fix ownership if run via sudo
if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
  REAL_USER="$SUDO_USER"
  REAL_GID=$(id -g "$REAL_USER" 2>/dev/null || echo "$REAL_USER")
  chown -R "${REAL_USER}:${REAL_GID}" "$INSTALL_DIR" 2>/dev/null || true
fi

# Make the setup script executable
chmod +x "$INSTALL_DIR/setup.sh" "$INSTALL_DIR/configure_homepage.sh" 2>/dev/null || true

ok "Files successfully deployed to: ${INSTALL_DIR}"

# ==============================================================================
# STEP 3 — Run/Prompt setup script
# ==============================================================================
section 3 "Done!"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}     Homeserver Suite bootstrap complete!    ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  To start the interactive installation, run:"
echo ""
echo -e "  ${YELLOW}sudo ./setup.sh${NC}"
echo ""
