#!/usr/bin/env bash

# ==============================================================================
# HOMESERVER SUITE — BOOTSTRAP INSTALLER
# ==============================================================================
# Downloads the homeserver suite as a zip (no git required) and starts the
# WebUI management portal as a systemd service.
#
# The WebUI then handles everything else: Docker installation, stack
# configuration, and service deployment via its guided interface.
#
# Usage (on a fresh Ubuntu/Debian server, run as root or with sudo):
#   curl -fsSL https://raw.githubusercontent.com/<YOU>/homeserver/main/bootstrap.sh | sudo bash
#
# Requirements: Ubuntu 20.04+ / Debian 11+ (any architecture)
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Configuration — update REPO_ZIP to your GitHub archive URL
# ------------------------------------------------------------------------------
REPO_ZIP="https://github.com/TravancoreTech/HomeServerConfiguration/archive/refs/heads/main.zip"
INSTALL_DIR="/opt/homeserver"
SERVICE_NAME="homeserver-webui"
WEBUI_PORT=8888

# ------------------------------------------------------------------------------
# Colors
# ------------------------------------------------------------------------------
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
DIM='\033[2m'
NC='\033[0m'

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
info()    { echo -e "${BLUE}  ▸${NC} $*"; }
ok()      { echo -e "${GREEN}  ✔${NC} $*"; }
warn()    { echo -e "${YELLOW}  ⚠${NC} $*"; }
die()     { echo -e "${RED}  ✘ ERROR:${NC} $*" >&2; exit 1; }
section() { echo -e "\n${BLUE}[$1/5]${NC} $2"; }

# ------------------------------------------------------------------------------
# Must be run as root (needed for apt, systemd, and /opt install)
# ------------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
  die "Please run with sudo:\n\n  sudo bash bootstrap.sh\n  # or via curl:\n  curl -fsSL <url> | sudo bash"
fi

# Detect the real user behind sudo (we'll run the service as them, not root)
REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
  # Running directly as root — service will run as root
  REAL_USER="root"
  REAL_HOME="/root"
else
  REAL_HOME=$(eval echo "~${REAL_USER}")
fi

# ------------------------------------------------------------------------------
# Header
# ------------------------------------------------------------------------------
echo ""
echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║${NC}      ${GREEN}Homeserver Suite — Bootstrap${NC}           ${BLUE}║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${DIM}  Install dir : ${INSTALL_DIR}${NC}"
echo -e "${DIM}  WebUI port  : ${WEBUI_PORT}${NC}"
echo -e "${DIM}  Service user: ${REAL_USER}${NC}"
echo ""

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
  die "No supported package manager found (apt, dnf, yum). Cannot continue."
fi

$UPDATE_CMD

# curl — almost always present, but install if missing
if ! command -v curl &>/dev/null; then
  info "Installing curl..."
  $INSTALL_CMD curl
  ok "curl installed"
else
  ok "curl already available: $(curl --version | head -1)"
fi

# unzip — needed to extract the GitHub archive
if ! command -v unzip &>/dev/null; then
  info "Installing unzip..."
  $INSTALL_CMD unzip
  ok "unzip installed"
else
  ok "unzip already available"
fi

# ==============================================================================
# STEP 2 — Install Node.js LTS
# ==============================================================================
section 2 "Installing Node.js LTS..."

if command -v node &>/dev/null; then
  NODE_VER=$(node --version)
  ok "Node.js already installed: ${NODE_VER}"
else
  info "Fetching NodeSource LTS setup script..."

  if [ "$PKG_MGR" = "apt-get" ]; then
    # NodeSource — Ubuntu/Debian
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1
    $INSTALL_CMD nodejs
  elif [ "$PKG_MGR" = "dnf" ] || [ "$PKG_MGR" = "yum" ]; then
    # NodeSource — Fedora/RHEL/CentOS
    curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash - >/dev/null 2>&1
    $INSTALL_CMD nodejs
  fi

  ok "Node.js installed: $(node --version)"
fi

# ==============================================================================
# STEP 3 — Download and extract the homeserver suite zip
# ==============================================================================
section 3 "Downloading Homeserver Suite..."

# Check the URL is configured
if [[ "$REPO_ZIP" == *"<YOU>"* ]]; then
  die "REPO_ZIP is not configured. Edit bootstrap.sh and set the correct GitHub archive URL."
fi

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

# Install to /opt/homeserver
mkdir -p "$INSTALL_DIR"
cp -r "${EXTRACTED_SUBDIR}/." "$INSTALL_DIR/"

# Cleanup temp files
rm -rf "$TMP_ZIP" "$TMP_DIR"

# Fix ownership so the real user owns the files
chown -R "${REAL_USER}:${REAL_USER}" "$INSTALL_DIR" 2>/dev/null || true

ok "Suite installed to ${INSTALL_DIR}"

# ==============================================================================
# STEP 4 — Create and enable systemd service
# ==============================================================================
section 4 "Setting up WebUI as a system service..."

# Ensure the real user belongs to the 'docker' group to communicate with Docker socket without sudo.
# Uses /dev/tty redirection to support piped curl installations.
if [ "$REAL_USER" != "root" ]; then
  if ! id -nG "$REAL_USER" | grep -qw docker; then
    echo -e -n "${YELLOW}  ▸ Add user $REAL_USER to 'docker' group to run without sudo? [Y/n]: ${NC}"
    if read -r RESPONSE < /dev/tty; then
      RESPONSE=${RESPONSE:-Y}
      if [[ "$RESPONSE" =~ ^[Yy] ]]; then
        if ! getent group docker >/dev/null; then
          groupadd -f docker
        fi
        usermod -aG docker "$REAL_USER"
        ok "Added user $REAL_USER to docker group"
      else
        warn "Skipping docker group assignment. WebUI status queries may show offline."
      fi
    else
      # Fallback for non-interactive scripts: default to Yes
      if ! getent group docker >/dev/null; then
        groupadd -f docker
      fi
      usermod -aG docker "$REAL_USER"
      ok "Non-interactive default: Added user $REAL_USER to docker group"
    fi
  fi
fi

SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

cat > "$SERVICE_FILE" << EOF
[Unit]
Description=Homeserver Suite Management WebUI
Documentation=https://github.com/TravancoreTech/HomeServerConfiguration
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}/webui
ExecStart=/usr/bin/node ${INSTALL_DIR}/webui/server.js
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

# Security hardening
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" --quiet
systemctl restart "$SERVICE_NAME"

# Give it 2 seconds to start, then check
sleep 2
if systemctl is-active --quiet "$SERVICE_NAME"; then
  ok "Service is running (${SERVICE_NAME})"
else
  warn "Service may have failed to start. Check logs:"
  echo -e "     ${YELLOW}journalctl -u ${SERVICE_NAME} -n 30${NC}"
fi

# ==============================================================================
# STEP 5 — Print access info
# ==============================================================================
section 5 "Done!"

# Detect server IP (prefer the primary non-loopback IPv4)
SERVER_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
# Fallback to hostname -I
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
# Final fallback
if [ -z "$SERVER_IP" ]; then
  SERVER_IP="<your-server-ip>"
fi

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║${NC}         WebUI is live and running!           ${GREEN}║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Open this in your browser (from your laptop):"
echo ""
echo -e "  ${YELLOW}http://${SERVER_IP}:${WEBUI_PORT}${NC}"
echo ""
echo -e "${DIM}  ─────────────────────────────────────────────${NC}"
echo -e "${DIM}  Useful service commands:${NC}"
echo -e "${DIM}  systemctl status ${SERVICE_NAME}${NC}"
echo -e "${DIM}  systemctl restart ${SERVICE_NAME}${NC}"
echo -e "${DIM}  journalctl -u ${SERVICE_NAME} -f${NC}"
echo -e "${DIM}  ─────────────────────────────────────────────${NC}"
echo -e "${DIM}  Files installed to: ${INSTALL_DIR}${NC}"
echo ""
echo -e "  ${DIM}Next: use the WebUI to install Docker and deploy your stack.${NC}"
echo ""
