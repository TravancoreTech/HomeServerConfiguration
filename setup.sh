#!/usr/bin/env bash

# ==============================================================================
# HOMESERVER AUTO-INSTALLER & CONFIGURATOR (PORTABLE)
# ==============================================================================
# This script configures environment variables, passwords, and the network IP,
# then pulls the Docker images sequentially (one-by-one with retries) to prevent 
# network saturation/handshake timeouts, and finally launches the stack.
#
# Usage:
#   chmod +x setup.sh
#   sudo ./setup.sh
#   ./setup.sh --sync     # Synchronizes configurations from GitHub as non-git
# ==============================================================================

set -euo pipefail

# Text Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Restore ownership helper to reset permissions back to the original sudo user
restore_ownership() {
  if [ -n "${SUDO_USER:-}" ]; then
    chown "${SUDO_UID}:${SUDO_GID}" .env 2>/dev/null || true
    chown "${SUDO_UID}:${SUDO_GID}" setup.sh 2>/dev/null || true
    chown "${SUDO_UID}:${SUDO_GID}" configure_homepage.sh 2>/dev/null || true
    chown -R "${SUDO_UID}:${SUDO_GID}" immich nextcloud utility media dashboard storage 2>/dev/null || true
    if [ -d "appdata" ]; then
      chown -R "${SUDO_UID}:${SUDO_GID}" appdata 2>/dev/null || true
    fi
  fi
}

# Helper to write/update GitHub config in .env
save_github_config() {
  local repo="$1"
  local token="$2"
  local temp_env
  temp_env=$(mktemp)
  
  if [ -f .env ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" =~ ^GITHUB_REPO= ]]; then
        echo "GITHUB_REPO=${repo}" >> "$temp_env"
      elif [[ "$line" =~ ^GITHUB_TOKEN= ]]; then
        echo "GITHUB_TOKEN=${token}" >> "$temp_env"
      else
        echo "$line" >> "$temp_env"
      fi
    done < .env
    
    # If variables were not in .env, append them
    if ! grep -q "^GITHUB_REPO=" "$temp_env"; then
      echo "GITHUB_REPO=${repo}" >> "$temp_env"
    fi
    if ! grep -q "^GITHUB_TOKEN=" "$temp_env"; then
      echo "GITHUB_TOKEN=${token}" >> "$temp_env"
    fi
    mv "$temp_env" .env
  else
    cat << EOF > .env
# ==============================================================================
# GLOBAL HOMESERVER ENVIRONMENT CONFIGURATION (.ENV)
# ==============================================================================
GITHUB_REPO=${repo}
GITHUB_TOKEN=${token}
EOF
  fi
  restore_ownership
}

# Function to download and sync configurations from GitHub
sync_from_github() {
  echo -e "${BLUE}======================================================================${NC}"
  echo -e "${GREEN}          HOMESERVER CONFIGURATION SYNCHRONIZER (GITHUB BALL)${NC}"
  echo -e "${BLUE}======================================================================${NC}"

  # Load variables from .env if it exists
  if [ -f .env ]; then
    # Parse GITHUB_ variables safely
    eval "$(grep -E "^GITHUB_" .env | sed 's/^/export /' || true)"
  fi

  # Strip quotes from GITHUB_REPO and GITHUB_TOKEN if they exist
  GITHUB_REPO=$(echo "${GITHUB_REPO:-}" | sed 's/^"//;s/"$//')
  GITHUB_TOKEN=$(echo "${GITHUB_TOKEN:-}" | sed 's/^"//;s/"$//')

  if [ -z "${GITHUB_REPO:-}" ] || [ "$GITHUB_REPO" = "username/repo-name" ]; then
    read -rp "Enter GitHub repository (format: owner/repo) [default: arunkarshan/HomeServerConfiguration]: " USER_REPO
    GITHUB_REPO="${USER_REPO:-arunkarshan/HomeServerConfiguration}"
  fi

  if [ -z "${GITHUB_TOKEN:-}" ]; then
    read -s -rp "Enter GitHub Personal Access Token (optional, press Enter to skip for public repos): " USER_TOKEN
    echo ""
    GITHUB_TOKEN="${USER_TOKEN:-}"
  fi

  # Save configuration immediately to .env
  save_github_config "$GITHUB_REPO" "$GITHUB_TOKEN"

  # Validate system requirements for sync, installing automatically if running as root
  if ! command -v unzip &>/dev/null || ! command -v rsync &>/dev/null; then
    if [ "$EUID" -eq 0 ]; then
      echo -e "${YELLOW}Missing unzip/rsync utilities. Attempting automatic installation...${NC}"
      if command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y unzip rsync
      elif command -v dnf &>/dev/null; then
        dnf install -y unzip rsync
      elif command -v yum &>/dev/null; then
        yum install -y unzip rsync
      elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm unzip rsync
      else
        echo -e "${RED}Error: Package manager not found. Please install 'unzip' and 'rsync' manually.${NC}"
        exit 1
      fi
    else
      echo -e "${RED}Error: 'unzip' and 'rsync' utilities are required but not installed.${NC}"
      echo -e "Please install them manually, or run 'sudo ./setup.sh' to have them installed automatically.${NC}"
      exit 1
    fi
  fi

  echo -e "Fetching latest configuration from: ${YELLOW}https://github.com/${GITHUB_REPO}${NC}..."
  
  # Download archive ZIP
  HTTP_CODE=0
  SUCCESS=false
  
  for branch in "main" "master"; do
    echo -e "Checking branch: ${BLUE}$branch${NC}..."
    if [ -n "${GITHUB_TOKEN:-}" ]; then
      HTTP_CODE=$(curl -s -w "%{http_code}" -H "Authorization: token $GITHUB_TOKEN" -L "https://api.github.com/repos/$GITHUB_REPO/zipball/$branch" -o config_temp.zip)
    else
      HTTP_CODE=$(curl -s -w "%{http_code}" -L "https://api.github.com/repos/$GITHUB_REPO/zipball/$branch" -o config_temp.zip)
    fi
    
    if [ "$HTTP_CODE" -eq 200 ]; then
      SUCCESS=true
      break
    else
      rm -f config_temp.zip
    fi
  done

  if [ "$SUCCESS" = false ]; then
    echo -e "${RED}Error: Failed to download repository archive (HTTP status: $HTTP_CODE).${NC}"
    if [ -f config_temp.zip ]; then
      echo -e "${YELLOW}GitHub API Response:${NC}"
      cat config_temp.zip || true
      echo ""
      rm -f config_temp.zip
    fi
    echo -e "Suggestions:"
    echo -e "1. If the repository is private, verify your GITHUB_TOKEN has read access to the repo."
    echo -e "   (Note: GitHub returns 404 Not Found for unauthorized private repo requests to hide their existence)."
    echo -e "2. Check that the repository owner and name ($GITHUB_REPO) are spelled correctly."
    echo -e "3. Ensure the repository has a 'main' or 'master' branch."
    exit 1
  fi

  echo -e "Extracting configurations..."
  rm -rf temp_extract
  mkdir -p temp_extract
  unzip -q config_temp.zip -d temp_extract

  # Get the generated directory name in zip (e.g. username-reponame-hash)
  SOURCE_DIR=$(find temp_extract -maxdepth 1 -type d | grep -v "temp_extract$" | head -n 1)

  if [ -z "$SOURCE_DIR" ]; then
    echo -e "${RED}Error: Failed to locate extracted source directory.${NC}"
    rm -rf config_temp.zip temp_extract
    exit 1
  fi

  # Safely sync files to workspace root, avoiding database/media state and secrets overwrite
  echo -e "Deploying files to homeserver workspace..."
  rsync -av \
    --include='appdata/' \
    --include='appdata/homepage/***' \
    --exclude='appdata/*' \
    --exclude='.git*' \
    --exclude='.env*' \
    --exclude='*/*.env*' \
    --exclude='data/' \
    --exclude='temp_extract/' \
    --exclude='config_temp.zip' \
    "$SOURCE_DIR/" ./

  # Clean up temporary files
  rm -rf config_temp.zip temp_extract
  echo -e "${GREEN}✔ Configuration sync completed successfully!${NC}\n"
}

# ------------------------------------------------------------------------------
# 0. HYBRID SYNC OPTION (RUNS AS NON-ROOT)
# ------------------------------------------------------------------------------
if [[ "${1:-}" == "--sync" ]]; then
  sync_from_github
  exit 0
fi

# Load variables from .env if it exists to preserve current configuration early
if [ -f .env ]; then
  # Load env variables safely in shell
  set -a
  source .env
  set +a
fi

# Install Samba on the host machine using the native package manager
install_samba() {
  echo -e "\n${BLUE}Installing Samba on host...${NC}"
  if command -v apt-get &>/dev/null; then
    apt-get update && apt-get install -y samba
  elif command -v dnf &>/dev/null; then
    dnf install -y samba
  elif command -v yum &>/dev/null; then
    yum install -y samba
  elif command -v pacman &>/dev/null; then
    pacman -Sy --noconfirm samba
  else
    echo -e "${RED}Error: Package manager not found. Please install 'samba' manually.${NC}"
    return 1
  fi
}

# Configure host Samba share for Media directory
configure_samba() {
  local smb_conf="/etc/samba/smb.conf"
  if [ ! -f "$smb_conf" ]; then
    echo -e "${RED}Error: Samba configuration file not found at $smb_conf${NC}"
    return 1
  fi

  # Determine matching local user for PUID/SUDO_USER to prevent file permission issues
  local share_user="${SUDO_USER:-}"
  if [ -z "$share_user" ] || [ "$share_user" = "root" ]; then
    share_user=$(id -un "${PUID:-1000}" 2>/dev/null || echo "root")
  fi

  echo -e "\nConfiguring Samba share for: ${BLUE}/mnt${NC}"
  echo -e "Files will be forced to user: ${BLUE}${share_user}${NC}"

  # 1. Enable SMB1 (NT1) protocol and NTLM auth in [global] section for old NAS/RAID systems
  echo -e "Enabling SMB1 (NT1) and NTLM compatibility in Samba global config..."
  python3 -c "
import sys
import re
conf_path = '$smb_conf'
try:
    with open(conf_path, 'r') as f:
        content = f.read()
    
    if not re.search(r'\[global\]', content, re.IGNORECASE):
        print('Error: [global] section not found.')
        sys.exit(1)
        
    # Inject client/server min protocols and ntlm auth
    for opt, val in [('server min protocol', 'NT1'), ('client min protocol', 'NT1'), ('ntlm auth', 'yes')]:
        pattern = r'^\s*' + re.escape(opt) + r'\s*=.*$'
        if re.search(pattern, content, re.MULTILINE | re.IGNORECASE):
            content = re.sub(pattern, f'   {opt} = {val}', content, flags=re.MULTILINE | re.IGNORECASE)
        else:
            content = re.sub(r'(\[global\])', r'\1\n   ' + f'{opt} = {val}', content, flags=re.IGNORECASE, count=1)
            
    with open(conf_path, 'w') as f:
        f.write(content)
except Exception as e:
    print(f'Error updating global config: {e}')
    sys.exit(1)
" 2>/dev/null || true

  # 2. Define Samba block for /mnt
  local smb_block
  smb_block=$(cat <<EOF

# ==============================================================================
# HOMESERVER MOUNTS SHARE (AUTOMATICALLY GENERATED)
# ==============================================================================
[homeserver-mnt]
   comment = Homeserver Mounts (/mnt)
   path = /mnt
   browseable = yes
   read only = no
   guest ok = no
   create mask = 0775
   directory mask = 0775
   force user = ${share_user}
EOF
)

  # Remove old [homeserver-media] share if it exists
  python3 -c "
import sys
import re
conf_path = '$smb_conf'
try:
    with open(conf_path, 'r') as f:
        content = f.read()
    cleaned = re.sub(r'\[homeserver-media\].*?(?=\n\s*\[|\Z)', '', content, flags=re.DOTALL)
    with open(conf_path, 'w') as f:
        f.write(cleaned.strip() + '\n')
except Exception as e:
    sys.exit(1)
" 2>/dev/null || true

  # Check if [homeserver-mnt] block exists
  if grep -q "\[homeserver-mnt\]" "$smb_conf"; then
    echo -e "Samba share '[homeserver-mnt]' already exists in $smb_conf."
    read -rp "Would you like to overwrite it? (y/n) [default: n]: " OVERWRITE_SMB
    OVERWRITE_SMB="${OVERWRITE_SMB:-n}"
    if [[ "$OVERWRITE_SMB" =~ ^[Yy]$ ]]; then
      # Clean up existing block from config file
      python3 -c "
import sys
import re
conf_path = '$smb_conf'
try:
    with open(conf_path, 'r') as f:
        content = f.read()
    cleaned = re.sub(r'\[homeserver-mnt\].*?(?=\n\s*\[|\Z)', '', content, flags=re.DOTALL)
    with open(conf_path, 'w') as f:
        f.write(cleaned.strip() + '\n')
except Exception as e:
    sys.exit(1)
" 2>/dev/null || sed -i '/\[homeserver-mnt\]/,/^[[:space:]]*$/d' "$smb_conf"
      
      echo "$smb_block" >> "$smb_conf"
      echo -e "${GREEN}✔ Updated Samba configuration in $smb_conf.${NC}"
    else
      echo -e "Skipping update of existing Samba configuration."
      return 0
    fi
  else
    # Append new block
    echo "$smb_block" >> "$smb_conf"
    echo -e "${GREEN}✔ Added Samba configuration to $smb_conf.${NC}"
  fi

  # Restart Samba service
  echo -e "Restarting Samba service..."
  if command -v systemctl &>/dev/null; then
    if systemctl is-active --quiet smbd 2>/dev/null; then
      systemctl restart smbd
      echo -e "${GREEN}✔ Restarted smbd service.${NC}"
    elif systemctl is-active --quiet smb 2>/dev/null; then
      systemctl restart smb
      echo -e "${GREEN}✔ Restarted smb service.${NC}"
    else
      echo -e "${YELLOW}Warning: Samba service is not currently running. Starting it...${NC}"
      systemctl enable --now smbd 2>/dev/null || systemctl enable --now smb 2>/dev/null
    fi
  else
    echo -e "${YELLOW}Warning: systemctl not found. Please restart your Samba daemon manually.${NC}"
  fi
}

echo -e "${BLUE}======================================================================${NC}"
echo -e "${GREEN}          HOMESERVER ONE-CLICK DOCKER INSTALlATION & SETUP${NC}"
echo -e "${BLUE}======================================================================${NC}"

# Check if script is run as root (needed for automatic Docker installation)
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}Error: Please run this script with sudo or as root to handle installation and system checks.${NC}"
  echo -e "Usage: sudo ./setup.sh"
  exit 1
fi

# ------------------------------------------------------------------------------
# 1. CHECK & INSTALL DOCKER DEPENDENCIES
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[1/4] Checking system dependencies...${NC}"

if ! command -v docker &> /dev/null; then
  echo -e "${YELLOW}Docker is not installed. Attempting automatic installation...${NC}"
  
  if [[ "$OSTYPE" == "darwin"* ]]; then
    echo -e "${RED}Error: Docker automatic installation is not supported on macOS via this script.${NC}"
    echo -e "Please download and install Docker Desktop: https://www.docker.com/products/docker-desktop/"
    exit 1
  fi

  # Attempt to install curl automatically if both curl and wget are missing
  if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
    echo -e "${YELLOW}Neither curl nor wget is found. Attempting to install curl automatically...${NC}"
    if command -v apt-get &> /dev/null; then
      apt-get update && apt-get install -y curl
    elif command -v dnf &> /dev/null; then
      dnf install -y curl
    elif command -v yum &> /dev/null; then
      yum install -y curl
    elif command -v pacman &> /dev/null; then
      pacman -Sy --noconfirm curl
    else
      echo -e "${RED}Error: No supported package manager found (apt, dnf, yum, pacman).${NC}"
      echo -e "Please install curl or wget manually on your system and run this script again."
      exit 1
    fi
  fi

  # Run the official Docker convenience installer
  if command -v curl &> /dev/null; then
    echo -e "Running the official Docker convenience installer script (curl)..."
    curl -fsSL https://get.docker.com | sh
  elif command -v wget &> /dev/null; then
    echo -e "Running the official Docker convenience installer script (wget)..."
    wget -qO- https://get.docker.com | sh
  else
    echo -e "${RED}Error: Could not install or locate curl/wget. Cannot download the Docker installer.${NC}"
    echo -e "Please install curl manually and run this script again.${NC}"
    exit 1
  fi
  
  # Verify installation
  if command -v docker &> /dev/null; then
    echo -e "${GREEN}✔ Docker installed successfully: $(docker --version)${NC}"
    # Start and enable docker service
    systemctl start docker || true
    systemctl enable docker || true
  else
    echo -e "${RED}Error: Automatic Docker installation failed.${NC}"
    echo -e "Please install Docker manually: https://docs.docker.com/engine/install/"
    exit 1
  fi
else
  echo -e "${GREEN}✔ Docker is installed: $(docker --version)${NC}"
fi

# Ensure Docker Compose V2 is available
if ! docker compose version &> /dev/null; then
  echo -e "${YELLOW}Docker Compose V2 is not found. Attempting to install compose plugin...${NC}"
  if command -v apt-get &> /dev/null; then
    apt-get update && apt-get install -y docker-compose-plugin || true
  elif command -v dnf &> /dev/null; then
    dnf install -y docker-compose-plugin || true
  elif command -v yum &> /dev/null; then
    yum install -y docker-compose-plugin || true
  fi
  
  # Double check
  if ! docker compose version &> /dev/null; then
    echo -e "${RED}Error: Docker Compose V2 is required but could not be installed automatically.${NC}"
    echo -e "Please install the 'docker-compose-plugin' manually.${NC}"
    exit 1
  fi
fi

echo -e "${GREEN}✔ Docker Compose is installed: $(docker compose version)${NC}"

# Define stack files in strict dependency order (Utility starts Redis for Nextcloud)
COMPOSE_FILES=(
  "utility/docker-compose.yml"
  "nextcloud/docker-compose.yml"
  "immich/docker-compose.yml"
  "media/docker-compose.yml"
  "storage/docker-compose.yml"
  "dashboard/docker-compose.yml"
)

# ------------------------------------------------------------------------------
# 1. AUTO-SYNC & DEPENDENCIES RESOLUTION
# ------------------------------------------------------------------------------
# Determine default GITHUB_REPO in case .env is missing
if [ -z "${GITHUB_REPO:-}" ] || [ "$GITHUB_REPO" = "username/repo-name" ]; then
  GITHUB_REPO="arunkarshan/HomeServerConfiguration"
fi

# Check if configuration files exist
FOUND_FILES=0
for file in "${COMPOSE_FILES[@]}"; do
  if [ -f "$file" ]; then
    FOUND_FILES=$((FOUND_FILES + 1))
  fi
done

if [ "$FOUND_FILES" -eq 0 ]; then
  echo -e "${YELLOW}No Docker Compose configuration files were found in the current directory.${NC}"
  echo -e "Automatically downloading latest configurations from GitHub..."
  sync_from_github
else
  # Prompt to sync latest configurations
  read -rp "Would you like to pull/update the latest configurations from GitHub first? (y/n) [default: n]: " SYNC_LATEST
  if [[ "$SYNC_LATEST" =~ ^[Yy]$ ]]; then
    sync_from_github
  fi
fi

# Build docker compose arguments dynamically for existing files
# Set project directory to the root directory (.) so that the global .env file is loaded correctly
COMPOSE_ARGS="--project-directory ."
FOUND_FILES=0
for file in "${COMPOSE_FILES[@]}"; do
  if [ -f "$file" ]; then
    COMPOSE_ARGS="$COMPOSE_ARGS -f $file"
    FOUND_FILES=$((FOUND_FILES + 1))
  fi
done

if [ "$FOUND_FILES" -eq 0 ]; then
  echo -e "${RED}Error: No Docker Compose configuration files found after syncing.${NC}"
  echo -e "Please check your repository content and structure.${NC}"
  exit 1
fi

# Check if any containers are currently running before setting up
if [ -n "$COMPOSE_ARGS" ]; then
  RUNNING_SERVICES=$(docker compose $COMPOSE_ARGS ps --services --filter "status=running" 2>/dev/null || true)
  if [ -n "$RUNNING_SERVICES" ]; then
    echo -e "${YELLOW}Detected active container stack running. Automatically shutting down containers to apply updates safely...${NC}"
    docker compose $COMPOSE_ARGS down
    echo -e "${GREEN}✔ Container stack stopped successfully.${NC}"
  fi
fi

# Source the root .env file if it exists to preserve current configuration
CLEAN_START=false
if [ -f .env ]; then
  # Load env variables safely in shell
  set -a
  source .env
  set +a
fi

if [ -d "${SYSTEM_DATA_DIR:-./appdata}" ] || [ -f .env ]; then
  echo -e "\n${YELLOW}Detected existing homeserver database or configurations.${NC}"
  read -rp "Would you like to NUKE/CLEAN all configurations and databases (retaining your HDD media/photos)? (y/n) [default: n]: " NUKE_SETUP
  if [[ "$NUKE_SETUP" =~ ^[Yy]$ ]]; then
    read -rp "Are you absolutely sure you want to delete all databases and application configurations? Media files will NOT be touched. (type 'yes' to confirm): " CONFIRM_NUKE
    if [ "$CONFIRM_NUKE" = "yes" ]; then
      echo -e "${RED}Stopping containers (if any) and cleaning configurations/databases...${NC}"
      if [ -n "$COMPOSE_ARGS" ]; then
        docker compose $COMPOSE_ARGS down -v --remove-orphans || true
      fi
      # Clear appdata configuration folder (databases, configs, caches) and environment files
      rm -rf "${SYSTEM_DATA_DIR:-./appdata}"
      rm -f .env immich/.env nextcloud/.env utility/.env media/.env
      CLEAN_START=true
      echo -e "${GREEN}✔ Cleaned up configuration directories. Ready for fresh configuration.${NC}"
    else
      echo -e "${GREEN}Cleanup cancelled. Proceeding in update mode.${NC}"
    fi
  fi
fi

# Load variables again if clean start cleared them
if [ "$CLEAN_START" = true ]; then
  TZ=""
  PUID=""
  PGID=""
  SYSTEM_DATA_DIR=""
  DB_DATA_LOCATION=""
  NEXTCLOUD_DB_LOCATION=""
  MEDIA_DIR=""
  UPLOAD_LOCATION=""
  NEXTCLOUD_DATA_LOCATION=""
  DB_USERNAME=""
  DB_DATABASE_NAME=""
  IMMICH_VERSION=""
  POSTGRES_DB=""
  POSTGRES_USER=""
  NEXTCLOUD_VERSION=""
  PAPERLESS_PORT=""
  PAPERLESS_TIME_ZONE=""
fi

# ------------------------------------------------------------------------------
# 2. DETERMINE SERVER IP & CONFIGURE HOMEPAGE
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[2/4] Configuring Server IP address...${NC}"

# Try to auto-detect the local IP address
DETECTED_IP=""
if command -v ip &> /dev/null; then
  DETECTED_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || true)
fi
if [ -z "$DETECTED_IP" ] && command -v hostname &> /dev/null; then
  DETECTED_IP=$(hostname -I | awk '{print $1}' || true)
fi

# Fallback to local default if detection fails
if [ -z "$DETECTED_IP" ]; then
  DETECTED_IP="192.168.1.100"
fi

echo -e "Auto-detected server local IP: ${YELLOW}${DETECTED_IP}${NC}"
read -rp "Press Enter to use this IP, or type your server's local IP/domain: " USER_IP

SERVER_IP="${USER_IP:-$DETECTED_IP}"
echo -e "Configuring homepage links to point to: ${GREEN}${SERVER_IP}${NC}"

# Apply sensible defaults for path and system variables if not already defined, prompting if missing or empty
# ------------------------------------------------------------------------------
# 3. PROMPT FOR APPLICATION PATHS & CREDENTIALS
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[3/4] Configuring paths, credentials & secret keys...${NC}"

# Timezone Prompt
if [ -n "${TZ:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing Timezone: ${TZ}${NC}"
else
  read -rp "Enter system timezone [default: Asia/Kolkata]: " USER_TZ
  TZ="${USER_TZ:-Asia/Kolkata}"
fi

# PUID Prompt
if [ -n "${PUID:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing PUID: ${PUID}${NC}"
else
  read -rp "Enter system PUID [default: 1000]: " USER_PUID
  PUID="${USER_PUID:-1000}"
fi

# PGID Prompt
if [ -n "${PGID:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing PGID: ${PGID}${NC}"
else
  read -rp "Enter system PGID [default: 1000]: " USER_PGID
  PGID="${USER_PGID:-1000}"
fi

# Appdata Directory (SSD/fast storage)
if [ -n "${SYSTEM_DATA_DIR:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing Appdata directory: ${SYSTEM_DATA_DIR}${NC}"
else
  read -rp "Enter Appdata directory (SSD/fast storage) [default: ./appdata]: " USER_SYS_DIR
  SYSTEM_DATA_DIR="${USER_SYS_DIR:-./appdata}"
fi

# Media Directory (HDD/mass storage)
if [ -n "${MEDIA_DIR:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing media directory: ${MEDIA_DIR}${NC}"
else
  read -rp "Enter Media directory (HDD/mass storage) [default: /mnt/hdd6t/media]: " USER_MEDIA_DIR
  MEDIA_DIR="${USER_MEDIA_DIR:-/mnt/hdd6t/media}"
fi

# Immich photos directory (HDD/mass storage)
if [ -n "${UPLOAD_LOCATION:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing Immich photos directory: ${UPLOAD_LOCATION}${NC}"
else
  read -rp "Enter Immich photos directory (HDD/mass storage) [default: /mnt/hdd/immich/photos]: " USER_UPLOAD
  UPLOAD_LOCATION="${USER_UPLOAD:-/mnt/hdd/immich/photos}"
fi

# Immich database directory (SSD/fast storage)
if [ -n "${DB_DATA_LOCATION:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing Immich DB directory: ${DB_DATA_LOCATION}${NC}"
else
  read -rp "Enter Immich database directory (SSD/fast storage) [default: ./appdata/immich/postgres]: " USER_DB_LOC
  DB_DATA_LOCATION="${USER_DB_LOC:-./appdata/immich/postgres}"
fi

# Immich database user
if [ -n "${DB_USERNAME:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing Immich DB user: ${DB_USERNAME}${NC}"
else
  read -rp "Enter Immich database username [default: postgres]: " USER_DB_USER
  DB_USERNAME="${USER_DB_USER:-postgres}"
fi

# Immich database name
if [ -n "${DB_DATABASE_NAME:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing Immich DB name: ${DB_DATABASE_NAME}${NC}"
else
  read -rp "Enter Immich database name [default: immich]: " USER_DB_NAME
  DB_DATABASE_NAME="${USER_DB_NAME:-immich}"
fi

# Nextcloud data directory (HDD/mass storage)
if [ -n "${NEXTCLOUD_DATA_LOCATION:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing Nextcloud data directory: ${NEXTCLOUD_DATA_LOCATION}${NC}"
else
  read -rp "Enter Nextcloud data directory (HDD/mass storage) [default: /mnt/hdd/nextcloud/data]: " USER_NC_DATA
  NEXTCLOUD_DATA_LOCATION="${USER_NC_DATA:-/mnt/hdd/nextcloud/data}"
fi

# Nextcloud database directory (SSD/fast storage)
if [ -n "${NEXTCLOUD_DB_LOCATION:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing Nextcloud DB directory: ${NEXTCLOUD_DB_LOCATION}${NC}"
else
  read -rp "Enter Nextcloud database directory (SSD/fast storage) [default: ./appdata/nextcloud/postgres]: " USER_NC_DB
  NEXTCLOUD_DB_LOCATION="${USER_NC_DB:-./appdata/nextcloud/postgres}"
fi

# Nextcloud database name
if [ -n "${POSTGRES_DB:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing Nextcloud DB name: ${POSTGRES_DB}${NC}"
else
  read -rp "Enter Nextcloud database name [default: nextcloud]: " USER_NC_POSTGRES_DB
  POSTGRES_DB="${USER_NC_POSTGRES_DB:-nextcloud}"
fi

# Nextcloud database user
if [ -n "${POSTGRES_USER:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing Nextcloud DB user: ${POSTGRES_USER}${NC}"
else
  read -rp "Enter Nextcloud database username [default: nextcloud]: " USER_NC_POSTGRES_USER
  POSTGRES_USER="${USER_NC_POSTGRES_USER:-nextcloud}"
fi

# Immich Password Prompt
if [ -n "${DB_PASSWORD:-}" ] && [ "$DB_PASSWORD" != "changeme_immich_db_password" ]; then
  echo -e "${GREEN}✔ Reusing existing database password for Immich.${NC}"
  IMMICH_DB_PASS="$DB_PASSWORD"
else
  IMMICH_DB_PASS=""
  while [ -z "$IMMICH_DB_PASS" ]; do
    read -s -rp "Enter database password for Immich (cannot be empty): " IMMICH_DB_PASS
    echo ""
  done
fi

# Nextcloud Password Prompt
if [ -n "${POSTGRES_PASSWORD:-}" ] && [ "$POSTGRES_PASSWORD" != "changeme_nextcloud_db_password" ]; then
  echo -e "${GREEN}✔ Reusing existing database password for Nextcloud.${NC}"
  NEXTCLOUD_DB_PASS="$POSTGRES_PASSWORD"
else
  NEXTCLOUD_DB_PASS=""
  while [ -z "$NEXTCLOUD_DB_PASS" ]; do
    read -s -rp "Enter database password for Nextcloud (cannot be empty): " NEXTCLOUD_DB_PASS
    echo ""
  done
fi
POSTGRES_PASSWORD="$NEXTCLOUD_DB_PASS"

# Paperless Secret Prompt
if [ -n "${PAPERLESS_SECRET_KEY:-}" ] && [ "$PAPERLESS_SECRET_KEY" != "change_this_to_a_random_string_for_security_123!" ] && [ "$PAPERLESS_SECRET_KEY" != "change_this_secret_key_123" ]; then
  echo -e "${GREEN}✔ Reusing existing secret key for Paperless-ngx.${NC}"
  PAPERLESS_SECRET="$PAPERLESS_SECRET_KEY"
else
  PAPERLESS_SECRET=""
  while [ -z "$PAPERLESS_SECRET" ]; do
    read -s -rp "Enter secret key for Paperless-ngx (cannot be empty): " PAPERLESS_SECRET
    echo ""
  done
fi

# GitHub Configuration Prompt
GITHUB_REPO=$(echo "${GITHUB_REPO:-}" | sed 's/^"//;s/"$//')
GITHUB_TOKEN=$(echo "${GITHUB_TOKEN:-}" | sed 's/^"//;s/"$//')

if [ -n "${GITHUB_REPO:-}" ] && [ "$GITHUB_REPO" != "username/repo-name" ]; then
  echo -e "${GREEN}✔ Reusing existing GitHub repository: ${GITHUB_REPO}${NC}"
else
  read -rp "Enter GitHub repository (format: owner/repo) [default: arunkarshan/HomeServerConfiguration]: " USER_REPO
  GITHUB_REPO="${USER_REPO:-arunkarshan/HomeServerConfiguration}"
fi

if [ -n "${GITHUB_TOKEN:-}" ]; then
  echo -e "${GREEN}✔ Reusing existing GitHub token.${NC}"
else
  read -s -rp "Enter GitHub Personal Access Token (optional, press Enter to skip for public repos): " USER_TOKEN
  echo ""
  GITHUB_TOKEN="${USER_TOKEN:-}"
fi

# Versions and Ports defaults
IMMICH_VERSION="${IMMICH_VERSION:-release}"
NEXTCLOUD_VERSION="${NEXTCLOUD_VERSION:-latest}"
PAPERLESS_PORT="${PAPERLESS_PORT:-8010}"
PAPERLESS_TIME_ZONE="${PAPERLESS_TIME_ZONE:-$TZ}"

echo -e "Writing and unifying environment configuration files..."

# 1. Generate Global root .env
cat << EOF > .env
# ==============================================================================
# GLOBAL HOMESERVER ENVIRONMENT CONFIGURATION (.ENV)
# ==============================================================================

# Timezone and User Identifiers
TZ=${TZ}
PUID=${PUID}
PGID=${PGID}

# Fast Storage (SSD) - Configs, Databases, and Metadata Cache
SYSTEM_DATA_DIR=${SYSTEM_DATA_DIR}
DB_DATA_LOCATION=${DB_DATA_LOCATION}
NEXTCLOUD_DB_LOCATION=${NEXTCLOUD_DB_LOCATION}

# Mass Storage (HDD) - Media, Downloads, Photos, and Cloud Files
MEDIA_DIR=${MEDIA_DIR}
UPLOAD_LOCATION=${UPLOAD_LOCATION}
NEXTCLOUD_DATA_LOCATION=${NEXTCLOUD_DATA_LOCATION}

# Immich Configuration
IMMICH_VERSION=${IMMICH_VERSION}
DB_USERNAME=${DB_USERNAME}
DB_DATABASE_NAME=${DB_DATABASE_NAME}
DB_PASSWORD=${IMMICH_DB_PASS}

# Nextcloud Configuration
NEXTCLOUD_VERSION=${NEXTCLOUD_VERSION}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${NEXTCLOUD_DB_PASS}

# Paperless Configuration
PAPERLESS_PORT=${PAPERLESS_PORT}
PAPERLESS_SECRET_KEY=${PAPERLESS_SECRET}
PAPERLESS_TIME_ZONE=${PAPERLESS_TIME_ZONE}

# GitHub Sync Configuration
GITHUB_REPO=${GITHUB_REPO}
GITHUB_TOKEN=${GITHUB_TOKEN:-}
HOMEPAGE_VAR_SERVER_IP=${SERVER_IP}

# Homepage Widget Credentials
HOMEPAGE_VAR_QBITTORRENT_PASSWORD=${HOMEPAGE_VAR_QBITTORRENT_PASSWORD:-YOUR_QBITTORRENT_PASSWORD}
HOMEPAGE_VAR_PAPERLESS_USERNAME=${HOMEPAGE_VAR_PAPERLESS_USERNAME:-YOUR_PAPERLESS_USERNAME}
HOMEPAGE_VAR_PAPERLESS_PASSWORD=${HOMEPAGE_VAR_PAPERLESS_PASSWORD:-YOUR_PAPERLESS_PASSWORD}
HOMEPAGE_VAR_IMMICH_API_KEY=${HOMEPAGE_VAR_IMMICH_API_KEY:-YOUR_IMMICH_API_KEY}
EOF
echo -e "${GREEN}✔ Configured root global .env file.${NC}"

# 2. Generate immich/.env
mkdir -p immich
cat << EOF > immich/.env
IMMICH_VERSION=${IMMICH_VERSION}
UPLOAD_LOCATION=${UPLOAD_LOCATION}
DB_DATA_LOCATION=../appdata/immich/postgres
DB_PASSWORD=${IMMICH_DB_PASS}
DB_USERNAME=${DB_USERNAME}
DB_DATABASE_NAME=${DB_DATABASE_NAME}
EOF
echo -e "${GREEN}✔ Configured immich/.env file.${NC}"

# 3. Generate nextcloud/.env
mkdir -p nextcloud
cat << EOF > nextcloud/.env
NEXTCLOUD_VERSION=${NEXTCLOUD_VERSION}
POSTGRES_DB=${POSTGRES_DB}
POSTGRES_USER=${POSTGRES_USER}
POSTGRES_PASSWORD=${NEXTCLOUD_DB_PASS}
NEXTCLOUD_DATA_LOCATION=${NEXTCLOUD_DATA_LOCATION}
NEXTCLOUD_DB_LOCATION=../appdata/nextcloud/postgres
EOF
echo -e "${GREEN}✔ Configured nextcloud/.env file.${NC}"

# 4. Generate utility/.env
mkdir -p utility
cat << EOF > utility/.env
PUID=${PUID}
PGID=${PGID}
TZ=${TZ}
SYSTEM_DATA_DIR=../appdata
MEDIA_DIR=${MEDIA_DIR}
PAPERLESS_PORT=${PAPERLESS_PORT}
PAPERLESS_SECRET_KEY=${PAPERLESS_SECRET}
PAPERLESS_TIME_ZONE=${PAPERLESS_TIME_ZONE}
EOF
echo -e "${GREEN}✔ Configured utility/.env file.${NC}"

# 5. Generate media/.env
mkdir -p media
cat << EOF > media/.env
PUID=${PUID}
PGID=${PGID}
TZ=${TZ}
MEDIA_DIR=${MEDIA_DIR}
SYSTEM_DATA_DIR=../appdata
EOF
echo -e "${GREEN}✔ Configured media/.env file.${NC}"

# Cleanup backup files
find . -name "*.bak" -type f -delete || true

# Restore file ownership to the non-root user
restore_ownership

# ------------------------------------------------------------------------------
# 4. START HOMESERVER CONTAINER STACK
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[4/4] Launching docker stacks...${NC}"

# Ensure shared bridge network exists
if ! docker network inspect homeserver_network &>/dev/null; then
  echo -e "Creating shared global bridge network: ${BLUE}homeserver_network${NC}..."
  docker network create homeserver_network
fi

# Clean up conflicting containers from older setups (belonging to other project names or created manually)
CONFLICT_CONTAINERS=(
  "homepage" "heimdall" "jellyfin" "radarr" "sonarr" "prowlarr" "qbittorrent" 
  "navidrome" "metube" "jellyseerr" "immich_server" "immich_machine_learning" 
  "immich_redis" "immich_postgres" "nextcloud" "nextcloud_postgres" "nextcloud_redis"
  "filebrowser" "vaultwarden" "paperless-ngx" "utility_paperless_redis" "uptime-kuma" "syncthing"
)

echo -e "Checking for conflicting containers from older configurations..."
for container in "${CONFLICT_CONTAINERS[@]}"; do
  if docker ps -a --format '{{.Names}}' | grep -Eq "^${container}\$"; then
    PROJ=$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "$container" 2>/dev/null || true)
    if [ "$PROJ" != "homeserver" ]; then
      echo -e "${YELLOW}Removing conflicting container '$container' (project: '${PROJ:-none}')...${NC}"
      docker rm -f "$container" &>/dev/null || true
    fi
  fi
done

read -rp "Would you like to start/update homeserver services now? (y/n) [default: y]: " START_CONTAINERS
START_CONTAINERS="${START_CONTAINERS:-y}"

if [[ "$START_CONTAINERS" =~ ^[Yy]$ ]]; then
  # Fetch list of services across the active configuration
  ALL_SERVICES=($(docker compose $COMPOSE_ARGS config --services | sort))
  NUM_SERVICES=${#ALL_SERVICES[@]}

  echo -e "\n${BLUE}Available services:${NC}"
  for ((i=0; i<NUM_SERVICES; i++)); do
    printf "  %2d) %s\n" $((i+1)) "${ALL_SERVICES[i]}"
  done
  echo ""

  read -rp "Enter the numbers of the services you want to update (separated by commas, e.g. 1,4,5) [default: ALL]: " USER_CHOICE

  SELECTED_SERVICES=()
  if [ -z "$USER_CHOICE" ]; then
    # Default: ALL
    SELECTED_SERVICES=("${ALL_SERVICES[@]}")
  else
    # Parse comma-separated input
    IFS=',' read -ra ADDR <<< "$USER_CHOICE"
    for part in "${ADDR[@]}"; do
      # Strip all whitespace
      idx=$(echo "$part" | tr -d '[:space:]')
      # Validate index is a number within 1..NUM_SERVICES
      if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "$NUM_SERVICES" ]; then
        SELECTED_SERVICES+=("${ALL_SERVICES[$((idx-1))]}")
      else
        echo -e "${RED}Warning: Ignoring invalid service number '$idx'.${NC}"
      fi
    done
  fi

  if [ ${#SELECTED_SERVICES[@]} -eq 0 ]; then
    echo -e "${RED}Error: No valid services selected. Exiting.${NC}"
    exit 1
  fi

  echo -e "\nSelected services to update: ${GREEN}${SELECTED_SERVICES[*]}${NC}"

  # Stop selected services first
  echo -e "${BLUE}Stopping selected services...${NC}"
  docker compose $COMPOSE_ARGS stop "${SELECTED_SERVICES[@]}"

  echo -e "${GREEN}Starting sequential image pull to prevent network saturation and timeouts...${NC}"
  
  for service in "${SELECTED_SERVICES[@]}"; do
    echo -e "Pulling image for: ${BLUE}$service${NC}..."
    RETRY=0
    SUCCESS=false
    
    while [ $RETRY -lt 3 ] && [ "$SUCCESS" = false ]; do
      if docker compose $COMPOSE_ARGS pull "$service"; then
        SUCCESS=true
      else
        RETRY=$((RETRY + 1))
        echo -e "${YELLOW}Warning: Pull failed for '$service'. Retrying ($RETRY/3) in 5 seconds...${NC}"
        sleep 5
      fi
    done
    
    if [ "$SUCCESS" = false ]; then
      echo -e "${RED}Error: Failed to pull image for '$service' after 3 attempts.${NC}"
      echo -e "Check your internet connection and run this script again."
      exit 1
    fi
  done
  
  docker compose $COMPOSE_ARGS up -d "${SELECTED_SERVICES[@]}"
  
  # Wait for services to initialize config files and configure Homepage
  echo -e "\n${BLUE}Waiting 5 seconds for services to initialize config files...${NC}"
  sleep 5
  if [ -f "./configure_homepage.sh" ]; then
    chmod +x ./configure_homepage.sh
    ./configure_homepage.sh || true
  fi
  
  # Check if Samba is installed on the host and prompt to install or update it
  if command -v smbd &>/dev/null; then
    echo -e "\n${BLUE}Samba detected on the system.${NC}"
    read -rp "Would you like to configure/update your host Samba mounts share? (y/n) [default: y]: " CONFIGURE_SAMBA
    CONFIGURE_SAMBA="${CONFIGURE_SAMBA:-y}"
    if [[ "$CONFIGURE_SAMBA" =~ ^[Yy]$ ]]; then
      configure_samba || true
    fi
  else
    echo -e "\n${YELLOW}Samba is not installed on this system.${NC}"
    read -rp "Would you like to install and configure Samba to share your /mnt directory? (y/n) [default: y]: " INSTALL_SAMBA_CHOICE
    INSTALL_SAMBA_CHOICE="${INSTALL_SAMBA_CHOICE:-y}"
    if [[ "$INSTALL_SAMBA_CHOICE" =~ ^[Yy]$ ]]; then
      install_samba && configure_samba || true
    fi
  fi
  
  echo -e "\n${GREEN}======================================================================${NC}"
  echo -e "${GREEN}✔ Selected services deployed successfully! You can access the apps below:${NC}"
  echo -e "  - Homepage Dashboard:   http://${SERVER_IP}"
  echo -e "  - Heimdall Dashboard:   http://${SERVER_IP}:8081"
  echo -e "  - Nextcloud:            http://${SERVER_IP}:8080"
  echo -e "  - Jellyfin:             http://${SERVER_IP}:8096"
  echo -e "  - Immich Photos:        http://${SERVER_IP}:2283"
  echo -e "  - File Browser:         http://${SERVER_IP}:8082"
  echo -e "  - Uptime Kuma:          http://${SERVER_IP}:3001"
  echo -e "  - MeTube YT Downloader: http://${SERVER_IP}:8087"
  echo -e "  - Navidrome Music:      http://${SERVER_IP}:4533"
  echo -e "  - Paperless-ngx:        http://${SERVER_IP}:8010"
  echo -e "  - Stirling-PDF tools:   http://${SERVER_IP}:8083"
  echo -e "  - IT-Tools:             http://${SERVER_IP}:8084"
  echo -e "  - Vaultwarden (SSL req):http://${SERVER_IP}:8086"
  echo -e "======================================================================${NC}"
  echo -e "Note: Docker will automatically create local relative folders ('./appdata' and './data')"
  echo -e "to store configs and downloads. If you mount external hard drives,"
  echo -e "simply update the paths in the global '.env' file and restart the stack."
else
  echo -e "${YELLOW}Setup complete! Run 'docker compose $COMPOSE_ARGS up -d' manually to start.${NC}"
fi

# Ensure all files are owned by the original user
restore_ownership
