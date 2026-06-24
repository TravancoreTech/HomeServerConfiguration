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
    echo -e "${YELLOW}Detected active homeserver containers running.${NC}"
    read -rp "Would you like to completely shut down the running containers first? (y/n) [default: n - in-place update]: " STOP_CONTAINERS_BEFORE
    if [[ "$STOP_CONTAINERS_BEFORE" =~ ^[Yy]$ ]]; then
      echo -e "${BLUE}Stopping running container stack...${NC}"
      docker compose $COMPOSE_ARGS down
      echo -e "${GREEN}✔ Container stack stopped successfully.${NC}"
    else
      echo -e "${GREEN}Proceeding with in-place update. Containers will be updated dynamically without full shutdown.${NC}"
    fi
  fi
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

# Update the .env file with the server IP
if [ -f .env ]; then
  sed -i.bak "s/^HOMEPAGE_VAR_SERVER_IP=.*/HOMEPAGE_VAR_SERVER_IP=${SERVER_IP}/" .env || \
  sed -i "" "s/^HOMEPAGE_VAR_SERVER_IP=.*/HOMEPAGE_VAR_SERVER_IP=${SERVER_IP}/" .env
  echo -e "${GREEN}✔ Updated HOMEPAGE_VAR_SERVER_IP in .env${NC}"
else
  echo -e "${RED}Warning: .env file not found in current directory.${NC}"
fi

# ------------------------------------------------------------------------------
# 3. PROMPT FOR APPLICATION CREDENTIALS & SECRETS
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}[3/4] Configuring credentials & secret keys...${NC}"

# Prompt for Immich Database Password
IMMICH_DB_PASS=""
while [ -z "$IMMICH_DB_PASS" ]; do
  read -s -rp "Enter database password for Immich (cannot be empty): " IMMICH_DB_PASS
  echo ""
done

# Prompt for Nextcloud Database Password
NEXTCLOUD_DB_PASS=""
while [ -z "$NEXTCLOUD_DB_PASS" ]; do
  read -s -rp "Enter database password for Nextcloud (cannot be empty): " NEXTCLOUD_DB_PASS
  echo ""
done

# Prompt for Paperless-ngx Secret Key
PAPERLESS_SECRET=""
while [ -z "$PAPERLESS_SECRET" ]; do
  read -s -rp "Enter secret key for Paperless-ngx (cannot be empty): " PAPERLESS_SECRET
  echo ""
done

# Replace passwords in sub-folder .env files
# Immich
if [ -f immich/.env ]; then
  sed -i.bak "s/DB_PASSWORD=.*/DB_PASSWORD=${IMMICH_DB_PASS}/" immich/.env || \
  sed -i "" "s/DB_PASSWORD=.*/DB_PASSWORD=${IMMICH_DB_PASS}/" immich/.env
  echo -e "${GREEN}✔ Configured database password for Immich.${NC}"
fi

# Nextcloud
if [ -f nextcloud/.env ]; then
  sed -i.bak "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${NEXTCLOUD_DB_PASS}/" nextcloud/.env || \
  sed -i "" "s/POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=${NEXTCLOUD_DB_PASS}/" nextcloud/.env
  echo -e "${GREEN}✔ Configured database password for Nextcloud.${NC}"
fi

# Paperless (in utility folder)
if [ -f utility/.env ]; then
  sed -i.bak "s/PAPERLESS_SECRET_KEY=.*/PAPERLESS_SECRET_KEY=${PAPERLESS_SECRET}/" utility/.env || \
  sed -i "" "s/PAPERLESS_SECRET_KEY=.*/PAPERLESS_SECRET_KEY=${PAPERLESS_SECRET}/" utility/.env
  echo -e "${GREEN}✔ Configured secret key for Paperless-ngx.${NC}"
fi

# Cleanup sed backup files
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

read -rp "Would you like to start the entire homeserver stack now? (y/n): " START_CONTAINERS

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
