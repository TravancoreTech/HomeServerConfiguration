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

# ------------------------------------------------------------------------------
# 0. HYBRID SYNC OPTION (RUNS AS NON-ROOT)
# ------------------------------------------------------------------------------
if [[ "${1:-}" == "--sync" ]]; then
  echo -e "${BLUE}======================================================================${NC}"
  echo -e "${GREEN}          HOMESERVER CONFIGURATION SYNCHRONIZER (GITHUB BALL)${NC}"
  echo -e "${BLUE}======================================================================${NC}"

  # Load variables from .env if it exists
  if [ -f .env ]; then
    # Parse GITHUB_ variables safely
    eval "$(grep -E "^GITHUB_" .env | sed 's/^/export /' || true)"
  fi

  if [ -z "${GITHUB_REPO:-}" ]; then
    echo -e "${RED}Error: GITHUB_REPO is not set in your root .env file.${NC}"
    echo -e "Please add 'GITHUB_REPO=username/repo-name' to your .env file."
    exit 1
  fi

  # Validate system requirements for sync
  if ! command -v unzip &>/dev/null; then
    echo -e "${RED}Error: 'unzip' utility is not installed. Please install it first.${NC}"
    exit 1
  fi
  if ! command -v rsync &>/dev/null; then
    echo -e "${RED}Error: 'rsync' utility is not installed. Please install it first.${NC}"
    exit 1
  fi

  echo -e "Fetching latest configuration from: ${YELLOW}https://github.com/${GITHUB_REPO}${NC}..."
  
  # Download archive ZIP
  HTTP_CODE=0
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    HTTP_CODE=$(curl -s -w "%{http_code}" -H "Authorization: token $GITHUB_TOKEN" -L "https://api.github.com/repos/$GITHUB_REPO/zipball/main" -o config_temp.zip)
  else
    HTTP_CODE=$(curl -s -w "%{http_code}" -L "https://api.github.com/repos/$GITHUB_REPO/zipball/main" -o config_temp.zip)
  fi

  if [ "$HTTP_CODE" -ne 200 ]; then
    echo -e "${RED}Error: Failed to download repository archive (HTTP status: $HTTP_CODE).${NC}"
    echo -e "If it is a private repository, please ensure GITHUB_TOKEN is configured correctly in .env."
    rm -f config_temp.zip
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
    --exclude='.git*' \
    --exclude='.env*' \
    --exclude='*/*.env*' \
    --exclude='appdata/' \
    --exclude='data/' \
    --exclude='temp_extract/' \
    --exclude='config_temp.zip' \
    "$SOURCE_DIR/" ./

  # Clean up temporary files
  rm -rf config_temp.zip temp_extract
  echo -e "${GREEN}✔ Configuration sync completed successfully!${NC}\n"
  exit 0
fi

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

# Build docker compose arguments dynamically for existing files
COMPOSE_ARGS=""
for file in "${COMPOSE_FILES[@]}"; do
  if [ -f "$file" ]; then
    COMPOSE_ARGS="$COMPOSE_ARGS -f $file"
  fi
done

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

# Check if appdata or configured data directories exist and ask if they want to nuke the setup
if [ -d "${SYSTEM_DATA_DIR:-./appdata}" ] || [ -d "${MEDIA_DIR:-/mnt/hdd/media}" ] || [ -d "${NEXTCLOUD_DATA_LOCATION:-/mnt/hdd/nextcloud/data}" ]; then
  echo -e "\n${YELLOW}Detected existing homeserver data and configurations.${NC}"
  read -rp "Would you like to NUKE/CLEAN the entire setup (deleting all databases and media) and start from scratch? (y/n) [default: n]: " NUKE_SETUP
  if [[ "$NUKE_SETUP" =~ ^[Yy]$ ]]; then
    read -rp "Are you absolutely sure you want to delete all databases, configurations, and media files? This CANNOT be undone! (type 'yes' to confirm): " CONFIRM_NUKE
    if [ "$CONFIRM_NUKE" = "yes" ]; then
      echo -e "${RED}Stopping containers (if any) and nuking existing directories...${NC}"
      if [ -n "$COMPOSE_ARGS" ]; then
        docker compose $COMPOSE_ARGS down -v --remove-orphans || true
      fi
      # Nuke active folders using variables or defaults
      rm -rf "${SYSTEM_DATA_DIR:-./appdata}"
      rm -rf "${MEDIA_DIR:-/mnt/hdd/media}" "${UPLOAD_LOCATION:-/mnt/hdd/immich/photos}" "${NEXTCLOUD_DATA_LOCATION:-/mnt/hdd/nextcloud/data}"
      rm -f .env immich/.env nextcloud/.env utility/.env media/.env
      CLEAN_START=true
      echo -e "${GREEN}✔ Cleaned up existing data. Ready for fresh setup.${NC}"
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

# Apply sensible defaults for path and system variables if not already defined
TZ="${TZ:-Etc/UTC}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
SYSTEM_DATA_DIR="${SYSTEM_DATA_DIR:-./appdata}"
DB_DATA_LOCATION="${DB_DATA_LOCATION:-./appdata/immich/postgres}"
NEXTCLOUD_DB_LOCATION="${NEXTCLOUD_DB_LOCATION:-./appdata/nextcloud/postgres}"

MEDIA_DIR="${MEDIA_DIR:-/mnt/hdd/media}"
UPLOAD_LOCATION="${UPLOAD_LOCATION:-/mnt/hdd/immich/photos}"
NEXTCLOUD_DATA_LOCATION="${NEXTCLOUD_DATA_LOCATION:-/mnt/hdd/nextcloud/data}"

DB_USERNAME="${DB_USERNAME:-postgres}"
DB_DATABASE_NAME="${DB_DATABASE_NAME:-immich}"
IMMICH_VERSION="${IMMICH_VERSION:-release}"

POSTGRES_DB="${POSTGRES_DB:-nextcloud}"
POSTGRES_USER="${POSTGRES_USER:-nextcloud}"
NEXTCLOUD_VERSION="${NEXTCLOUD_VERSION:-latest}"

PAPERLESS_PORT="${PAPERLESS_PORT:-8010}"
PAPERLESS_TIME_ZONE="${PAPERLESS_TIME_ZONE:-Etc/UTC}"

# ------------------------------------------------------------------------------
# 3. PROMPT FOR APPLICATION CREDENTIALS & SECRETS
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[3/4] Configuring credentials & secret keys...${NC}"

# Immich Password Prompt (Reuses value from sourced shell variables)
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
GITHUB_REPO=${GITHUB_REPO:-"username/repo-name"}
GITHUB_TOKEN=${GITHUB_TOKEN:-""}
HOMEPAGE_VAR_SERVER_IP=${SERVER_IP}
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

# ------------------------------------------------------------------------------
# 4. START HOMESERVER CONTAINER STACK
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[4/4] Launching docker stacks...${NC}"

# Ensure shared bridge network exists
if ! docker network inspect homeserver_network &>/dev/null; then
  echo -e "Creating shared global bridge network: ${BLUE}homeserver_network${NC}..."
  docker network create homeserver_network
fi

read -rp "Would you like to start the entire homeserver stack now? (y/n) [default: y]: " START_CONTAINERS
START_CONTAINERS="${START_CONTAINERS:-y}"

if [[ "$START_CONTAINERS" =~ ^[Yy]$ ]]; then
  echo -e "${GREEN}Starting sequential image pull to prevent network saturation and timeouts...${NC}"
  
  # Fetch list of services across the active configuration
  SERVICES=$(docker compose $COMPOSE_ARGS config --services)
  
  for service in $SERVICES; do
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
  
  echo -e "\n${GREEN}✔ All images successfully pulled. Launching container stack...${NC}"
  docker compose $COMPOSE_ARGS up -d
  
  echo -e "\n${GREEN}======================================================================${NC}"
  echo -e "${GREEN}✔ Stack deployed successfully! You can access the apps below:${NC}"
  echo -e "  - Homepage Dashboard:   http://${SERVER_IP}"
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
