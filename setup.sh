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

# ------------------------------------------------------------------------------
# GIT FETCH TIMESTAMP HELPERS
# ------------------------------------------------------------------------------
save_fetch_timestamp() {
  TZ="Asia/Kolkata" date "+%Y-%m-%d %H:%M:%S IST" > .last_fetch_timestamp 2>/dev/null || true
  if [ -n "${SUDO_UID:-}" ]; then
    chown "${SUDO_UID}:${SUDO_GID}" .last_fetch_timestamp 2>/dev/null || true
  fi
}

show_last_fetch_timestamp() {
  if [ -f .last_fetch_timestamp ]; then
    local last_ts
    last_ts=$(cat .last_fetch_timestamp)
    echo -e "Last Git Fetch: ${YELLOW}${last_ts}${NC}"
  else
    echo -e "Last Git Fetch: ${YELLOW}Never / Unknown${NC}"
  fi
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
  save_fetch_timestamp
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

# Configure host Samba share with detailed prompts (user addition, path creation, authentication etc.)
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

  echo -e "\n${BLUE}======================================================================${NC}"
  echo -e "${GREEN}                  SAMBA FILE SHARING CONFIGURATION WIZARD${NC}"
  echo -e "${BLUE}======================================================================${NC}"

  # 1. Share Path Selection
  local share_path=""
  while [ -z "$share_path" ]; do
    read -rp "Enter the directory path you want to share [default: /mnt]: " share_path
    share_path="${share_path:-/mnt}"
  done

  # Verify or create the sharing directory
  if [ ! -d "$share_path" ]; then
    read -rp "Directory '$share_path' does not exist. Create it now? (y/n) [default: y]: " create_dir
    create_dir="${create_dir:-y}"
    if [[ "$create_dir" =~ ^[Yy]$ ]]; then
      echo -e "Creating directory '$share_path'..."
      mkdir -p "$share_path"
      if [ "$share_user" != "root" ]; then
        chown "$share_user":"$(id -gn "$share_user")" "$share_path" 2>/dev/null || true
      fi
      chmod 775 "$share_path"
      echo -e "${GREEN}✔ Directory created and permissions configured (775).${NC}"
    else
      echo -e "${RED}Error: Shared directory must exist to configure Samba share.${NC}"
      return 1
    fi
  fi

  # 2. Share Name Selection
  local share_name=""
  while [ -z "$share_name" ]; do
    read -rp "Enter the Samba share name [default: homeserver-mnt]: " share_name
    share_name="${share_name:-homeserver-mnt}"
    # Strip brackets to prevent configuration syntax errors
    share_name=$(echo "$share_name" | tr -d '[]')
  done

  # 3. Authentication Configuration
  local guest_ok="no"
  local valid_users_line=""
  local added_users=()
  
  while true; do
    read -rp "Configure authenticated sharing (requires password)? (y/n) [default: y]: " auth_choice
    auth_choice="${auth_choice:-y}"
    if [[ "$auth_choice" =~ ^[Yy]$ ]]; then
      while true; do
        local samba_user=""
        read -rp "Enter Samba username [default: $share_user]: " samba_user
        samba_user="${samba_user:-$share_user}"
        
        # Ensure system user exists
        if ! id "$samba_user" &>/dev/null; then
          echo -e "${YELLOW}System user '$samba_user' does not exist.${NC}"
          read -rp "Create system user '$samba_user' (without login shell)? (y/n) [default: y]: " create_user
          create_user="${create_user:-y}"
          if [[ "$create_user" =~ ^[Yy]$ ]]; then
            echo -e "Creating system user '$samba_user'..."
            useradd -M -s /usr/sbin/nologin "$samba_user" || useradd -M -s /sbin/nologin "$samba_user" || adduser -D -H -s /sbin/nologin "$samba_user"
            echo -e "${GREEN}✔ System user created.${NC}"
          else
            echo -e "${RED}Error: Authenticated sharing requires a system user. Please enter an existing user or allow creation.${NC}"
            continue
          fi
        fi

        # Samba Password Setup
        local samba_password=""
        local samba_password_confirm=""
        while true; do
          read -s -rp "Enter Samba password for '$samba_user': " samba_password
          echo ""
          read -s -rp "Confirm Samba password: " samba_password_confirm
          echo ""
          if [ -z "$samba_password" ]; then
            echo -e "${RED}Password cannot be empty. Please try again.${NC}"
          elif [ "$samba_password" != "$samba_password_confirm" ]; then
            echo -e "${RED}Passwords do not match. Please try again.${NC}"
          else
            break
          fi
        done

        # Set the Samba user password
        echo -e "Configuring Samba password for user '$samba_user'..."
        printf "%s\n%s\n" "$samba_password" "$samba_password" | smbpasswd -a -s "$samba_user"
        
        added_users+=("$samba_user")
        
        read -rp "Would you like to configure another Samba user for this share? (y/n) [default: n]: " add_another
        add_another="${add_another:-n}"
        if [[ ! "$add_another" =~ ^[Yy]$ ]]; then
          break
        fi
      done
      
      guest_ok="no"
      valid_users_line="   valid users = ${added_users[*]}"
      break
    elif [[ "$auth_choice" =~ ^[Nn]$ ]]; then
      read -rp "WARNING: Guest sharing allows anonymous read-write access. Confirm? (y/n) [default: n]: " guest_confirm
      guest_confirm="${guest_confirm:-n}"
      if [[ "$guest_confirm" =~ ^[Yy]$ ]]; then
        guest_ok="yes"
        valid_users_line=""
        break
      fi
    else
      echo -e "${RED}Invalid option. Please enter 'y' or 'n'.${NC}"
    fi
  done

  # 4. Enable SMB1 (NT1) protocol and NTLM auth in [global] section for old NAS/RAID systems
  echo -e "\nEnabling SMB1 (NT1) and NTLM compatibility in Samba global config..."
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

  # 5. Define Samba block dynamically
  local smb_block
  smb_block=$(cat <<EOF

# ==============================================================================
# HOMESERVER MOUNTS SHARE (AUTOMATICALLY GENERATED)
# ==============================================================================
[${share_name}]
   comment = Homeserver Mounts (${share_path})
   path = ${share_path}
   browseable = yes
   read only = no
   guest ok = ${guest_ok}
$( [ -n "$valid_users_line" ] && echo "$valid_users_line" || true )
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

  # Check if the share block already exists in smb.conf
  if grep -q "\[${share_name}\]" "$smb_conf"; then
    echo -e "Samba share '[${share_name}]' already exists in $smb_conf."
    read -rp "Would you like to overwrite it? (y/n) [default: n]: " OVERWRITE_SMB
    OVERWRITE_SMB="${OVERWRITE_SMB:-n}"
    if [[ "$OVERWRITE_SMB" =~ ^[Yy]$ ]]; then
      # Clean up existing block from config file
      python3 -c "
import sys
import re
conf_path = '$smb_conf'
share_name = '$share_name'
try:
    with open(conf_path, 'r') as f:
        content = f.read()
    cleaned = re.sub(r'\[' + re.escape(share_name) + r'\].*?(?=\n\s*\[|\Z)', '', content, flags=re.DOTALL)
    with open(conf_path, 'w') as f:
        f.write(cleaned.strip() + '\n')
except Exception as e:
    sys.exit(1)
" 2>/dev/null || sed -i "/\[${share_name}\]/,/^[[:space:]]*$/d" "$smb_conf"
      
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

  # Restart Samba service and enable it on startup
  echo -e "Enabling and restarting Samba service..."
  if command -v systemctl &>/dev/null; then
    if systemctl show smbd.service 2>/dev/null | grep -q "LoadState=loaded"; then
      systemctl enable smbd
      systemctl restart smbd
      echo -e "${GREEN}✔ Enabled and restarted smbd service on startup.${NC}"
    elif systemctl show smb.service 2>/dev/null | grep -q "LoadState=loaded"; then
      systemctl enable smb
      systemctl restart smb
      echo -e "${GREEN}✔ Enabled and restarted smb service on startup.${NC}"
    else
      echo -e "${YELLOW}Warning: Neither smbd nor smb service was found in systemd. Please enable manually.${NC}"
    fi
  else
    echo -e "${YELLOW}Warning: systemctl not found. Please enable and restart your Samba daemon manually.${NC}"
  fi
}

# ------------------------------------------------------------------------------
# DEPENDENCY CHECK & AUTOMATIC INSTALLATION
# ------------------------------------------------------------------------------
check_dependencies() {
  echo -e "\n${BLUE}Checking system dependencies...${NC}"

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
}

if [ $# -eq 0 ]; then
  echo -e "${BLUE}======================================================================${NC}"
  echo -e "${GREEN}          HOMESERVER ONE-CLICK DOCKER INSTALlATION & SETUP${NC}"
  echo -e "${BLUE}======================================================================${NC}"

  # Check if script is run as root (needed for automatic Docker installation)
  if [ "$EUID" -ne 0 ] && [ "$(uname)" != "Darwin" ]; then
    echo -e "${RED}Error: Please run this script with sudo or as root to handle installation and system checks.${NC}"
    echo -e "Usage: sudo ./setup.sh"
    exit 1
  fi

  # ------------------------------------------------------------------------------
  # 1. CHECK & INSTALL DOCKER DEPENDENCIES
  # ------------------------------------------------------------------------------
  echo -e "\n${BLUE}[1/4] Checking system dependencies...${NC}"
  check_dependencies
fi

# Define stack files in strict dependency order (Utility starts Redis for Nextcloud)
COMPOSE_FILES=(
  "utility/docker-compose.yml"
  "nextcloud/docker-compose.yml"
  "immich/docker-compose.yml"
  "media/docker-compose.yml"
  "storage/docker-compose.yml"
  "dashboard/docker-compose.yml"
)

# Restore file ownership to the non-root user
restore_ownership

# ------------------------------------------------------------------------------
# DOCKER COMPOSE CONFIGURATION RESOLUTION
# ------------------------------------------------------------------------------
generate_compose_overrides() {
  # 1. Jellyfin overrides
  local jellyfin_override="media/docker-compose.override.yml"
  rm -f "$jellyfin_override"
  if [ -n "${JELLYFIN_EXTRA_MEDIA_DIRS:-}" ]; then
    echo "services:" > "$jellyfin_override"
    echo "  jellyfin:" >> "$jellyfin_override"
    echo "    volumes:" >> "$jellyfin_override"
    local idx=1
    IFS=',' read -ra DIRS <<< "$JELLYFIN_EXTRA_MEDIA_DIRS"
    for dir in "${DIRS[@]}"; do
      dir=$(echo "$dir" | xargs)
      if [ -n "$dir" ]; then
        echo "      - \"${dir}:/media_extra_${idx}\"" >> "$jellyfin_override"
        idx=$((idx + 1))
      fi
    done
  fi

  # 2. Immich overrides
  local immich_override="immich/docker-compose.override.yml"
  rm -f "$immich_override"
  if [ -n "${IMMICH_EXTRA_BACKUP_DIRS:-}" ]; then
    echo "services:" > "$immich_override"
    echo "  immich-server:" >> "$immich_override"
    echo "    volumes:" >> "$immich_override"
    local idx=1
    IFS=',' read -ra DIRS <<< "$IMMICH_EXTRA_BACKUP_DIRS"
    for dir in "${DIRS[@]}"; do
      dir=$(echo "$dir" | xargs)
      if [ -n "$dir" ]; then
        echo "      - \"${dir}:/mnt/PhotoBackup_extra_${idx}:ro\"" >> "$immich_override"
        idx=$((idx + 1))
      fi
    done
  fi

  # 3. Nextcloud overrides
  local nextcloud_override="nextcloud/docker-compose.override.yml"
  rm -f "$nextcloud_override"
  if [ -n "${NEXTCLOUD_EXTRA_DATA_DIRS:-}" ]; then
    echo "services:" > "$nextcloud_override"
    echo "  nextcloud-app:" >> "$nextcloud_override"
    echo "    volumes:" >> "$nextcloud_override"
    local idx=1
    IFS=',' read -ra DIRS <<< "$NEXTCLOUD_EXTRA_DATA_DIRS"
    for dir in "${DIRS[@]}"; do
      dir=$(echo "$dir" | xargs)
      if [ -n "$dir" ]; then
        echo "      - \"${dir}:/var/www/html/data/extra_${idx}\"" >> "$nextcloud_override"
        idx=$((idx + 1))
      fi
    done
  fi
}

build_compose_args() {
  if [ -f .env ]; then
    set -a
    source .env
    set +a
  fi

  generate_compose_overrides

  COMPOSE_ARGS="--project-directory ."
  local found_files=0
  for file in "${COMPOSE_FILES[@]}"; do
    if [ -f "$file" ]; then
      COMPOSE_ARGS="$COMPOSE_ARGS -f $file"
      found_files=$((found_files + 1))
      
      local override_file="${file%.yml}.override.yml"
      if [ -f "$override_file" ]; then
        COMPOSE_ARGS="$COMPOSE_ARGS -f $override_file"
      fi
    fi
  done
  if [ "$found_files" -eq 0 ]; then
    return 1
  fi
  return 0
}

# ------------------------------------------------------------------------------
# CONFIGURATION WIZARD & ENV FILE GENERATION
# ------------------------------------------------------------------------------
prompt_and_generate_configs() {
  # Try to auto-detect the local IP address
  local detected_ip=""
  if command -v ip &> /dev/null; then
    detected_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || true)
  fi
  if [ -z "$detected_ip" ] && command -v hostname &> /dev/null; then
    detected_ip=$(hostname -I | awk '{print $1}' || true)
  fi
  if [ -z "$detected_ip" ]; then
    detected_ip="192.168.1.100"
  fi

  if [ -n "${SERVER_IP:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing SERVER_IP: ${SERVER_IP}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      SERVER_IP="$detected_ip"
    else
      echo -e "\nAuto-detected server local IP: ${YELLOW}${detected_ip}${NC}"
      read -rp "Press Enter to use this IP, or type your server's local IP/domain: " USER_IP
      SERVER_IP="${USER_IP:-$detected_ip}"
    fi
  fi

  # Timezone Prompt
  if [ -n "${TZ:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing Timezone: ${TZ}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      TZ="Asia/Kolkata"
    else
      read -rp "Enter system timezone [default: Asia/Kolkata]: " USER_TZ
      TZ="${USER_TZ:-Asia/Kolkata}"
    fi
  fi

  # PUID Prompt
  if [ -n "${PUID:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing PUID: ${PUID}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      PUID="1000"
    else
      read -rp "Enter system PUID [default: 1000]: " USER_PUID
      PUID="${USER_PUID:-1000}"
    fi
  fi

  # PGID Prompt
  if [ -n "${PGID:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing PGID: ${PGID}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      PGID="1000"
    else
      read -rp "Enter system PGID [default: 1000]: " USER_PGID
      PGID="${USER_PGID:-1000}"
    fi
  fi

  # Appdata Directory
  if [ -n "${SYSTEM_DATA_DIR:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing Appdata directory: ${SYSTEM_DATA_DIR}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      SYSTEM_DATA_DIR="./appdata"
    else
      read -rp "Enter Appdata directory (SSD/fast storage) [default: ./appdata]: " USER_SYS_DIR
      SYSTEM_DATA_DIR="${USER_SYS_DIR:-./appdata}"
    fi
  fi

  # Media Directory
  if [ -n "${MEDIA_DIR:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing media directory: ${MEDIA_DIR}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      MEDIA_DIR="./data/media"
    else
      read -rp "Enter Media directory (HDD/mass storage) [default: ./data/media]: " USER_MEDIA_DIR
      MEDIA_DIR="${USER_MEDIA_DIR:-./data/media}"
    fi
  fi

  # Immich photos directory
  if [ -n "${UPLOAD_LOCATION:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing Immich photos directory: ${UPLOAD_LOCATION}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      UPLOAD_LOCATION="./data/immich/photos"
    else
      read -rp "Enter Immich photos directory (HDD/mass storage) [default: ./data/immich/photos]: " USER_UPLOAD
      UPLOAD_LOCATION="${USER_UPLOAD:-./data/immich/photos}"
    fi
  fi

  # Immich photo backup mount
  if [ -n "${PHOTO_BACKUP_LOCATION:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing Immich photo backup path: ${PHOTO_BACKUP_LOCATION}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      PHOTO_BACKUP_LOCATION="./data/PhotoBackup"
    else
      read -rp "Enter Immich photo backup path (HDD/mass storage) [default: ./data/PhotoBackup]: " USER_PHOTO_BACKUP
      PHOTO_BACKUP_LOCATION="${USER_PHOTO_BACKUP:-./data/PhotoBackup}"
    fi
  fi

  # Immich DB directory
  if [ -n "${DB_DATA_LOCATION:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing Immich DB directory: ${DB_DATA_LOCATION}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      DB_DATA_LOCATION="./appdata/immich/postgres"
    else
      read -rp "Enter Immich database directory (SSD/fast storage) [default: ./appdata/immich/postgres]: " USER_DB_LOC
      DB_DATA_LOCATION="${USER_DB_LOC:-./appdata/immich/postgres}"
    fi
  fi

  # Immich DB user
  if [ -n "${DB_USERNAME:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing Immich DB user: ${DB_USERNAME}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      DB_USERNAME="postgres"
    else
      read -rp "Enter Immich database username [default: postgres]: " USER_DB_USER
      DB_USERNAME="${USER_DB_USER:-postgres}"
    fi
  fi

  # Immich DB name
  if [ -n "${DB_DATABASE_NAME:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing Immich DB name: ${DB_DATABASE_NAME}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      DB_DATABASE_NAME="immich"
    else
      read -rp "Enter Immich database name [default: immich]: " USER_DB_NAME
      DB_DATABASE_NAME="${USER_DB_NAME:-immich}"
    fi
  fi

  # Nextcloud data directory
  if [ -n "${NEXTCLOUD_DATA_LOCATION:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing Nextcloud data directory: ${NEXTCLOUD_DATA_LOCATION}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      NEXTCLOUD_DATA_LOCATION="./data/nextcloud/data"
    else
      read -rp "Enter Nextcloud data directory (HDD/mass storage) [default: ./data/nextcloud/data]: " USER_NC_DATA
      NEXTCLOUD_DATA_LOCATION="${USER_NC_DATA:-./data/nextcloud/data}"
    fi
  fi

  # Nextcloud DB directory
  if [ -n "${NEXTCLOUD_DB_LOCATION:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing Nextcloud DB directory: ${NEXTCLOUD_DB_LOCATION}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      NEXTCLOUD_DB_LOCATION="./appdata/nextcloud/postgres"
    else
      read -rp "Enter Nextcloud database directory (SSD/fast storage) [default: ./appdata/nextcloud/postgres]: " USER_NC_DB
      NEXTCLOUD_DB_LOCATION="${USER_NC_DB:-./appdata/nextcloud/postgres}"
    fi
  fi

  # Nextcloud DB name
  if [ -n "${POSTGRES_DB:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing Nextcloud DB name: ${POSTGRES_DB}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      POSTGRES_DB="nextcloud"
    else
      read -rp "Enter Nextcloud database name [default: nextcloud]: " USER_NC_POSTGRES_DB
      POSTGRES_DB="${USER_NC_POSTGRES_DB:-nextcloud}"
    fi
  fi

  # Nextcloud DB user
  if [ -n "${POSTGRES_USER:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing Nextcloud DB user: ${POSTGRES_USER}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      POSTGRES_USER="nextcloud"
    else
      read -rp "Enter Nextcloud database username [default: nextcloud]: " USER_NC_POSTGRES_USER
      POSTGRES_USER="${USER_NC_POSTGRES_USER:-nextcloud}"
    fi
  fi

  # Immich Password Prompt
  if [ -n "${DB_PASSWORD:-}" ] && [ "$DB_PASSWORD" != "changeme_immich_db_password" ]; then
    echo -e "${GREEN}✔ Reusing existing database password for Immich.${NC}"
    IMMICH_DB_PASS="$DB_PASSWORD"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      IMMICH_DB_PASS=$(openssl rand -hex 16 2>/dev/null || echo "immich_pass_123")
    else
      IMMICH_DB_PASS=""
      while [ -z "$IMMICH_DB_PASS" ]; do
        read -s -rp "Enter database password for Immich (cannot be empty): " IMMICH_DB_PASS
        echo ""
      done
    fi
  fi

  # Nextcloud Password Prompt
  if [ -n "${POSTGRES_PASSWORD:-}" ] && [ "$POSTGRES_PASSWORD" != "changeme_nextcloud_db_password" ]; then
    echo -e "${GREEN}✔ Reusing existing database password for Nextcloud.${NC}"
    NEXTCLOUD_DB_PASS="$POSTGRES_PASSWORD"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      NEXTCLOUD_DB_PASS=$(openssl rand -hex 16 2>/dev/null || echo "nextcloud_pass_123")
    else
      NEXTCLOUD_DB_PASS=""
      while [ -z "$NEXTCLOUD_DB_PASS" ]; do
        read -s -rp "Enter database password for Nextcloud (cannot be empty): " NEXTCLOUD_DB_PASS
        echo ""
      done
    fi
  fi
  POSTGRES_PASSWORD="$NEXTCLOUD_DB_PASS"

  # Paperless Secret Prompt
  if [ -n "${PAPERLESS_SECRET_KEY:-}" ] && [ "$PAPERLESS_SECRET_KEY" != "change_this_to_a_random_string_for_security_123!" ] && [ "$PAPERLESS_SECRET_KEY" != "change_this_secret_key_123" ]; then
    echo -e "${GREEN}✔ Reusing existing secret key for Paperless-ngx.${NC}"
    PAPERLESS_SECRET="$PAPERLESS_SECRET_KEY"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      PAPERLESS_SECRET=$(openssl rand -hex 32 2>/dev/null || echo "paperless_secret_123_random_chars")
    else
      PAPERLESS_SECRET=""
      while [ -z "$PAPERLESS_SECRET" ]; do
        read -s -rp "Enter secret key for Paperless-ngx (cannot be empty): " PAPERLESS_SECRET
        echo ""
      done
    fi
  fi

  # GitHub repo prompt
  if [ -n "${GITHUB_REPO:-}" ] && [ "$GITHUB_REPO" != "username/repo-name" ]; then
    echo -e "${GREEN}✔ Reusing existing GitHub repository: ${GITHUB_REPO}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      GITHUB_REPO="arunkarshan/HomeServerConfiguration"
    else
      read -rp "Enter GitHub repository (format: owner/repo) [default: arunkarshan/HomeServerConfiguration]: " USER_REPO
      GITHUB_REPO="${USER_REPO:-arunkarshan/HomeServerConfiguration}"
    fi
  fi

  # GitHub token prompt
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing GitHub token.${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      GITHUB_TOKEN=""
    else
      read -s -rp "Enter GitHub Personal Access Token (optional, press Enter to skip for public repos): " USER_TOKEN
      echo ""
      GITHUB_TOKEN="${USER_TOKEN:-}"
    fi
  fi

  # Tailscale Auth Key prompt
  if [ -n "${TS_AUTHKEY:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing Tailscale Auth Key.${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      TS_AUTHKEY=""
    else
      read -rp "Enter Tailscale Auth Key (optional, e.g. tskey-auth-...): " USER_TS_KEY
      TS_AUTHKEY="${USER_TS_KEY:-}"
    fi
  fi

  # Storage Drive Mounting prompt
  if [ -n "${CONFIGURE_DRIVE_MOUNTS:-}" ]; then
    echo -e "${GREEN}✔ Reusing existing Storage Mounts configuration: ${CONFIGURE_DRIVE_MOUNTS}${NC}"
  else
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      CONFIGURE_DRIVE_MOUNTS="false"
      DRIVE_MOUNT_POINTS=""
      DRIVE_SIZES=""
    else
      read -rp "Do you want to configure auto-mounting of external storage drives in /etc/fstab? (y/n) [default: n]: " USER_MOUNT_CONF
      if [[ "$USER_MOUNT_CONF" =~ ^[Yy]$ ]]; then
        CONFIGURE_DRIVE_MOUNTS="true"
        read -rp "Enter drive mount paths (space-separated, e.g. /mnt/hdd /mnt/hdd6t): " USER_MOUNT_PATHS
        DRIVE_MOUNT_POINTS="${USER_MOUNT_PATHS:-/mnt/hdd /mnt/hdd6t}"
        read -rp "Enter drive sizes/identifiers matching df (space-separated, e.g. 465.8G 5.5T): " USER_DRIVE_SIZES
        DRIVE_SIZES="${USER_DRIVE_SIZES:-465.8G 5.5T}"
      else
        CONFIGURE_DRIVE_MOUNTS="false"
        DRIVE_MOUNT_POINTS=""
        DRIVE_SIZES=""
      fi
    fi
  fi

  # Versions and Ports defaults
  IMMICH_VERSION="${IMMICH_VERSION:-release}"
  NEXTCLOUD_VERSION="${NEXTCLOUD_VERSION:-latest}"
  PAPERLESS_PORT="${PAPERLESS_PORT:-8010}"
  PAPERLESS_TIME_ZONE="${PAPERLESS_TIME_ZONE:-$TZ}"

  # Check and load existing Kopia admin password
  local generated_kopia_pass=false
  KOPIA_ADMIN_PASS="${KOPIA_ADMIN_PASSWORD:-}"
  if [ -z "$KOPIA_ADMIN_PASS" ]; then
    KOPIA_ADMIN_PASS=$(openssl rand -hex 16 2>/dev/null || echo "admin_kopia_pass_123")
    generated_kopia_pass=true
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
PHOTO_BACKUP_LOCATION=${PHOTO_BACKUP_LOCATION}
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

# Kopia Configuration
KOPIA_ADMIN_PASSWORD=${KOPIA_ADMIN_PASS}

# GitHub Sync Configuration
GITHUB_REPO=${GITHUB_REPO}
GITHUB_TOKEN=${GITHUB_TOKEN:-}
HOMEPAGE_VAR_SERVER_IP=${SERVER_IP}

# Homepage Widget Credentials
HOMEPAGE_VAR_QBITTORRENT_PASSWORD=${HOMEPAGE_VAR_QBITTORRENT_PASSWORD:-YOUR_QBITTORRENT_PASSWORD}
HOMEPAGE_VAR_PAPERLESS_USERNAME=${HOMEPAGE_VAR_PAPERLESS_USERNAME:-YOUR_PAPERLESS_USERNAME}
HOMEPAGE_VAR_PAPERLESS_PASSWORD=${HOMEPAGE_VAR_PAPERLESS_PASSWORD:-YOUR_PAPERLESS_PASSWORD}
HOMEPAGE_VAR_IMMICH_API_KEY=${HOMEPAGE_VAR_IMMICH_API_KEY:-YOUR_IMMICH_API_KEY}

# Tailscale VPN Settings
TS_AUTHKEY=${TS_AUTHKEY}

# Storage Drive Mounting
CONFIGURE_DRIVE_MOUNTS=${CONFIGURE_DRIVE_MOUNTS}
DRIVE_MOUNT_POINTS="${DRIVE_MOUNT_POINTS}"
DRIVE_SIZES="${DRIVE_SIZES}"
EOF
  echo -e "${GREEN}✔ Configured root global .env file.${NC}"

  # 2. Generate immich/.env
  mkdir -p immich
  cat << EOF > immich/.env
IMMICH_VERSION=${IMMICH_VERSION}
UPLOAD_LOCATION=${UPLOAD_LOCATION}
PHOTO_BACKUP_LOCATION=${PHOTO_BACKUP_LOCATION}
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
TS_AUTHKEY=${TS_AUTHKEY}
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

  # 6. Generate storage/.env
  mkdir -p storage
  cat << EOF > storage/.env
PUID=${PUID}
PGID=${PGID}
TZ=${TZ}
MEDIA_DIR=${MEDIA_DIR}
SYSTEM_DATA_DIR=../appdata
KOPIA_ADMIN_PASSWORD=${KOPIA_ADMIN_PASS}
EOF
  echo -e "${GREEN}✔ Configured storage/.env file.${NC}"

  # Pre-create appdata directories for services to ensure correct ownership and permissions
  local app_dir="${SYSTEM_DATA_DIR:-./appdata}"
  mkdir -p "$app_dir/radicale"
  mkdir -p "$app_dir/baikal/config"
  mkdir -p "$app_dir/baikal/Specific"
  mkdir -p "$app_dir/kopia/config" "$app_dir/kopia/cache" "$app_dir/kopia/logs"
  mkdir -p "$app_dir/backrest/data" "$app_dir/backrest/config" "$app_dir/backrest/cache" "$app_dir/backrest/tmp"
  mkdir -p "$app_dir/cronicle/data" "$app_dir/cronicle/logs" "$app_dir/cronicle/plugins"
  mkdir -p "$app_dir/torrent-generator"

  if [ -n "${SUDO_UID:-}" ]; then
    chown -R "${SUDO_UID}:${SUDO_GID}" \
      "$app_dir/radicale" \
      "$app_dir/baikal" \
      "$app_dir/kopia" \
      "$app_dir/backrest" \
      "$app_dir/cronicle" \
      "$app_dir/torrent-generator" 2>/dev/null || true
  fi
  # Allow the container services to write (especially Baikal/Kopia/Cronicle which run as special UIDs)
  chmod -R 777 \
    "$app_dir/radicale" \
    "$app_dir/baikal" \
    "$app_dir/kopia" \
    "$app_dir/backrest" \
    "$app_dir/cronicle" 2>/dev/null || true

  if [ "$generated_kopia_pass" = true ]; then
    echo -e "\n${YELLOW}🔑 A random Kopia Admin Password has been generated: ${GREEN}${KOPIA_ADMIN_PASS}${NC}"
    echo -e "${YELLOW}   This password has been saved to your root .env and storage/.env files.${NC}\n"
  fi

  find . -name "*.bak" -type f -delete || true
  restore_ownership
}

# ------------------------------------------------------------------------------
# SILENT GITHUB SYNCHRONIZER
# ------------------------------------------------------------------------------
sync_from_github_silent() {
  local repo="${GITHUB_REPO:-arunkarshan/HomeServerConfiguration}"
  local token="${GITHUB_TOKEN:-}"

  echo -e "Silently syncing configurations from: ${YELLOW}https://github.com/${repo}${NC}..."
  
  if ! command -v unzip &>/dev/null || ! command -v rsync &>/dev/null; then
    if [ "$EUID" -eq 0 ]; then
      if command -v apt-get &>/dev/null; then
        apt-get update && apt-get install -y unzip rsync
      elif command -v dnf &>/dev/null; then
        dnf install -y unzip rsync
      elif command -v yum &>/dev/null; then
        yum install -y unzip rsync
      elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm unzip rsync
      fi
    fi
  fi

  local success=false
  for branch in "main" "master"; do
    local http_code=0
    if [ -n "$token" ]; then
      http_code=$(curl -s -w "%{http_code}" -H "Authorization: token $token" -L "https://api.github.com/repos/$repo/zipball/$branch" -o config_temp.zip)
    else
      http_code=$(curl -s -w "%{http_code}" -L "https://api.github.com/repos/$repo/zipball/$branch" -o config_temp.zip)
    fi
    
    if [ "$http_code" -eq 200 ]; then
      success=true
      break
    else
      rm -f config_temp.zip
    fi
  done

  if [ "$success" = true ]; then
    mkdir -p config_temp_dir
    unzip -q config_temp.zip -d config_temp_dir
    local top_dir
    top_dir=$(find config_temp_dir -mindepth 1 -maxdepth 1 -type d | head -n 1)
    rsync -a --exclude='.git' --exclude='.env*' --exclude='*/*.env*' "${top_dir}/" ./
    rm -rf config_temp_dir config_temp.zip
    save_fetch_timestamp
    echo -e "${GREEN}✔ Repository synchronized successfully.${NC}"
  else
    echo -e "${RED}Error: Failed to silently download repository archive. Sync skipped.${NC}"
  fi
  restore_ownership
}

# ------------------------------------------------------------------------------
# HELPER TO PRINT APPLICATION ACCESS URLS
# ------------------------------------------------------------------------------
print_successful_urls() {
  local SERVER_IP="${SERVER_IP:-${HOMEPAGE_VAR_SERVER_IP:-localhost}}"
  echo -e "\n${GREEN}======================================================================${NC}"
  echo -e "${GREEN}✔ Active services are accessible at the URLs below:${NC}"
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
  echo -e "  - Radicale CalDAV:      http://${SERVER_IP}:5232"
  echo -e "  - Baïkal CalDAV:        http://${SERVER_IP}:8088"
  echo -e "  - Local Tracker:        http://${SERVER_IP}:8000/announce"
  echo -e "  - Torrent Generator UI: http://${SERVER_IP}:8089"
  echo -e "======================================================================${NC}"
}

# Interactive service selection helper (supporting individual services and grouped suites)
# Returns a space-separated list of selected services in stdout.
select_services_prompt() {
  local prompt_text="$1"  # Custom prompt text
  
  # Fetch raw services
  local raw_services=($(docker compose $COMPOSE_ARGS config --services | sort))
  local num_raw=${#raw_services[@]}
  
  # Define suites
  local suites=("immich_suite" "nextcloud_suite" "jellyfin_suite" "util_suite")
  local num_suites=${#suites[@]}
  
  # Print choices
  echo -e "\n${BLUE}Available services & suites:${NC}" >&2
  # Print individual services
  for ((i=0; i<num_raw; i++)); do
    printf "  %2d) %s\n" $((i+1)) "${raw_services[i]}" >&2
  done
  # Print groups/suites
  echo -e "${BLUE}  --- Service Groups (Suites) ---${NC}" >&2
  for ((i=0; i<num_suites; i++)); do
    printf "  %2d) %s (Group)\n" $((num_raw + i + 1)) "${suites[i]}" >&2
  done
  
  local total_options=$((num_raw + num_suites))
  
  read -rp "$prompt_text" USER_CHOICE
  
  local selected=()
  if [ -z "$USER_CHOICE" ]; then
    # Return all raw services
    echo "${raw_services[*]}"
    return 0
  fi
  
  IFS=',' read -ra ADDR <<< "$USER_CHOICE"
  for idx in "${ADDR[@]}"; do
    idx=$(echo "$idx" | xargs)
    if [[ "$idx" =~ ^[0-9]+$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "$total_options" ]; then
      if [ "$idx" -le "$num_raw" ]; then
        # Individual service
        selected+=("${raw_services[$((idx-1))]}")
      else
        # Group/suite selected
        local suite_idx=$((idx - num_raw - 1))
        local suite_name="${suites[suite_idx]}"
        if [ "$suite_name" = "immich_suite" ]; then
          selected+=("immich-server" "immich-machine-learning" "redis" "database")
        elif [ "$suite_name" = "nextcloud_suite" ]; then
          selected+=("nextcloud-app" "nextcloud-cron" "nextcloud-db")
        elif [ "$suite_name" = "jellyfin_suite" ]; then
          selected+=("jellyfin" "qbittorrent" "radarr" "sonarr" "prowlarr" "flaresolverr" "jellyseerr" "bazarr" "navidrome" "metube" "media-local-tracker" "torrent-generator")
        elif [ "$suite_name" = "util_suite" ]; then
          selected+=("vaultwarden" "stirling-pdf" "it-tools" "uptime-kuma" "syncthing" "pairdrop" "paperless-redis" "paperless-web" "radicale" "baikal" "cronicle" "ofelia")
        fi
      fi
    else
      if [ -n "$idx" ]; then
        echo -e "${RED}Warning: Ignoring invalid option '$idx'.${NC}" >&2
      fi
    fi
  done
  
  # Deduplicate selected services in case they overlap
  local uniq_selected=()
  if [ ${#selected[@]} -gt 0 ]; then
    uniq_selected=($(echo "${selected[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
  fi
  
  echo "${uniq_selected[*]}"
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 1: UPDATE CONFIG & DEPLOY SELECTIVE SERVICES
# ------------------------------------------------------------------------------
action_update_config() {
  echo -e "\nUpdating configuration from Git repository..."
  sync_from_github
  build_compose_args
  
  if [ -f .env ]; then
    set -a; source .env; set +a
  fi

  local selected_list
  selected_list=$(select_services_prompt "Enter the numbers of the services/groups you want to update (comma-separated, e.g. 1,4,22) [default: ALL]: ")
  local selected_services=($selected_list)

  if [ ${#selected_services[@]} -eq 0 ]; then
    echo -e "${RED}Error: No valid services selected. Returning to main menu.${NC}"
    return 1
  fi

  echo -e "\nSelected services to update: ${GREEN}${selected_services[*]}${NC}"

  # Stop selected services first
  echo -e "${BLUE}Stopping selected services...${NC}"
  docker compose $COMPOSE_ARGS stop "${selected_services[@]}"

  # Sequential Pull
  echo -e "${GREEN}Starting sequential image pull to prevent network saturation and timeouts...${NC}"
  for service in "${selected_services[@]}"; do
    echo -e "Pulling image for: ${BLUE}$service${NC}..."
    local retry=0
    local success=false
    while [ $retry -lt 3 ] && [ "$success" = false ]; do
      if docker compose $COMPOSE_ARGS pull "$service"; then
        success=true
      else
        retry=$((retry + 1))
        echo -e "${YELLOW}Warning: Pull failed for '$service'. Retrying ($retry/3) in 5 seconds...${NC}"
        sleep 5
      fi
    done
    if [ "$success" = false ]; then
      echo -e "${RED}Error: Failed to pull image for '$service'. Returning to main menu.${NC}"
      return 1
    fi
  done

  # Restart
  echo -e "${BLUE}Bringing selected services up...${NC}"
  docker compose $COMPOSE_ARGS up -d "${selected_services[@]}"

  # Configure Homepage widgets
  echo -e "\n${BLUE}Configuring Homepage widgets...${NC}"
  if [ -f "./configure_homepage.sh" ]; then
    chmod +x ./configure_homepage.sh
    ./configure_homepage.sh || true
  fi

  print_successful_urls
  restore_ownership
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 2: RESTART SELECTIVE SERVICES (STOP & START)
# ------------------------------------------------------------------------------
action_restart_services() {
  local selected_list
  selected_list=$(select_services_prompt "Enter the numbers of the services/groups you want to restart (comma-separated, e.g. 1,4,22) [default: ALL]: ")
  local selected_services=($selected_list)

  if [ ${#selected_services[@]} -eq 0 ]; then
    echo -e "${RED}Error: No valid services selected. Returning to main menu.${NC}"
    return 1
  fi

  echo -e "\nRestarting services: ${GREEN}${selected_services[*]}${NC}"

  # Stop selected services
  echo -e "${BLUE}Stopping selected services...${NC}"
  docker compose $COMPOSE_ARGS stop "${selected_services[@]}"

  # Start selected services
  echo -e "${BLUE}Starting selected services...${NC}"
  docker compose $COMPOSE_ARGS up -d "${selected_services[@]}"

  echo -e "${GREEN}✔ Services restarted successfully!${NC}"
  restore_ownership
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 3: NUKE EVERYTHING AND FRESH START (⚠️ DANGER ⚠️)
# ------------------------------------------------------------------------------
action_nuke_everything() {
  echo -e "\n${RED}⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️${NC}"
  echo -e "${RED}⚠️ DANGER: THIS WILL NUKE AND ERASE ALL DATABASES AND CONFIGURATIONS! ⚠️${NC}"
  echo -e "${RED}⚠️ This permanently deletes nextcloud DB, immich DB, paperless configs, etc.${NC}"
  echo -e "${RED}⚠️ Your raw media/photos inside external mounts (/mnt/hdd etc.) will NOT be touched. ⚠️${NC}"
  echo -e "${RED}⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️${NC}"
  read -rp "Are you absolutely sure you want to proceed? (type 'yes' to confirm): " CONFIRM_NUKE
  if [ "$CONFIRM_NUKE" != "yes" ]; then
    echo -e "${YELLOW}Nuke operation cancelled. Returning to main menu.${NC}"
    return
  fi

  echo -e "${RED}Shutting down all running containers...${NC}"
  docker compose $COMPOSE_ARGS down -v --remove-orphans || true

  echo -e "${RED}Deleting appdata configuration directories and local .env files...${NC}"
  rm -rf "${SYSTEM_DATA_DIR:-./appdata}"
  rm -f .env immich/.env nextcloud/.env utility/.env media/.env

  # Reset parameters in environment for prompt
  PUID=""
  PGID=""
  TZ=""
  SYSTEM_DATA_DIR=""
  MEDIA_DIR=""
  UPLOAD_LOCATION=""
  DB_USERNAME=""
  DB_DATABASE_NAME=""
  IMMICH_VERSION=""
  POSTGRES_DB=""
  POSTGRES_USER=""
  NEXTCLOUD_VERSION=""
  PAPERLESS_PORT=""
  PAPERLESS_TIME_ZONE=""

  echo -e "\n${BLUE}Syncing latest configuration from Git...${NC}"
  sync_from_github_silent
  
  echo -e "\n${BLUE}Starting configuration wizard...${NC}"
  prompt_and_generate_configs
  
  build_compose_args

  echo -e "${GREEN}Deploying fresh container stack...${NC}"
  local selected_services=()

  echo -e "\nWould you like to deploy all services or select a subset to deploy?"
  read -rp "Enter 'all' or 'select' [default: all]: " deploy_choice
  deploy_choice="${deploy_choice:-all}"

  if [[ "$deploy_choice" =~ ^[Ss]elect$ ]]; then
    local selected_list
    selected_list=$(select_services_prompt "Enter the numbers of the services/groups you want to deploy (comma-separated, e.g. 1,4,22): ")
    selected_services=($selected_list)
  fi

  # Fallback to ALL services if choice was 'all' or selection was empty/invalid
  if [ ${#selected_services[@]} -eq 0 ]; then
    selected_services=($(docker compose $COMPOSE_ARGS config --services | sort))
  fi

  echo -e "\nSelected services to deploy: ${GREEN}${selected_services[*]}${NC}"

  for service in "${selected_services[@]}"; do
    echo -e "Pulling image for: ${BLUE}$service${NC}..."
    local retry=0
    local success=false
    while [ $retry -lt 3 ] && [ "$success" = false ]; do
      if docker compose $COMPOSE_ARGS pull "$service"; then
        success=true
      else
        retry=$((retry + 1))
        echo -e "${YELLOW}Warning: Pull failed for '$service'. Retrying ($retry/3) in 5 seconds...${NC}"
        sleep 5
      fi
    done
  done

  docker compose $COMPOSE_ARGS up -d "${selected_services[@]}"

  echo -e "\n${BLUE}Waiting 5 seconds for services to initialize...${NC}"
  sleep 5
  if [ -f "./configure_homepage.sh" ]; then
    chmod +x ./configure_homepage.sh
    ./configure_homepage.sh || true
  fi

  print_successful_urls
  restore_ownership
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 4: UPDATE HOMEPAGE WIDGETS AND CONTAINER (SILENT SYNC)
# ------------------------------------------------------------------------------
action_update_homepage() {
  echo -e "\n${BLUE}Updating configurations from Git...${NC}"
  sync_from_github_silent
  build_compose_args
  
  echo -e "${BLUE}Restarting and pulling latest image for Homepage container...${NC}"
  docker compose $COMPOSE_ARGS stop homepage
  docker compose $COMPOSE_ARGS pull homepage || true
  docker compose $COMPOSE_ARGS up -d homepage
  
  if [ -f "./configure_homepage.sh" ]; then
    chmod +x ./configure_homepage.sh
    ./configure_homepage.sh || true
  fi
  echo -e "${GREEN}✔ Homepage dashboard updated and restarted successfully!${NC}"
  restore_ownership
}

# Install Cockpit and 45Drives Samba GUI sharing plugin
install_cockpit_samba_gui() {
  echo -e "\n${BLUE}======================================================================${NC}"
  echo -e "${GREEN}          INSTALLING COCKPIT & 45DRIVES FILE SHARING GUI PANEL${NC}"
  echo -e "${BLUE}======================================================================${NC}"
  
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: This operation requires root/sudo privileges.${NC}"
    return 1
  fi
  
  # 1. Install Cockpit
  echo -e "Installing Cockpit web service..."
  if command -v apt-get &>/dev/null; then
    apt-get update && apt-get install -y cockpit
  elif command -v dnf &>/dev/null; then
    dnf install -y cockpit
  elif command -v yum &>/dev/null; then
    yum install -y cockpit
  elif command -v pacman &>/dev/null; then
    pacman -Sy --noconfirm cockpit
  else
    echo -e "${RED}Error: Package manager not found. Please install Cockpit manually.${NC}"
    return 1
  fi
  
  # 2. Enable and Start Cockpit Service
  if command -v systemctl &>/dev/null; then
    systemctl enable --now cockpit.socket
    echo -e "${GREEN}✔ Cockpit socket service enabled and started.${NC}"
  fi
  
  # 3. Add 45Drives Repository and Install cockpit-file-sharing
  echo -e "Adding 45Drives package repository for File Sharing plugin..."
  if command -v apt-get &>/dev/null; then
    # For Debian/Ubuntu
    curl -sSL https://repo.45drives.com/setup | bash
    apt-get update
    apt-get install -y cockpit-file-sharing
    echo -e "${GREEN}✔ 45Drives Cockpit File Sharing plugin installed successfully!${NC}"
  elif [ -d /etc/yum.repos.d/ ] || command -v dnf &>/dev/null; then
    # For CentOS/RHEL/Fedora
    curl -sSL https://repo.45drives.com/setup | bash
    dnf install -y cockpit-file-sharing || yum install -y cockpit-file-sharing
    echo -e "${GREEN}✔ 45Drives Cockpit File Sharing plugin installed successfully!${NC}"
  else
    echo -e "${YELLOW}Warning: Automatic repository setup not supported for this distro.${NC}"
    echo -e "Please install the cockpit-file-sharing plugin manually from: https://github.com/45Drives/cockpit-file-sharing"
  fi
  
  # Get Server IP
  local detected_ip=""
  if command -v ip &> /dev/null; then
    detected_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}' || true)
  fi
  if [ -z "$detected_ip" ] && command -v hostname &> /dev/null; then
    detected_ip=$(hostname -I | awk '{print $1}' || true)
  fi
  detected_ip="${detected_ip:-localhost}"
  
  echo -e "\n${GREEN}======================================================================${NC}"
  echo -e "${GREEN}✔ COCKPIT SAMBA MANAGER DEPLOYED SUCCESSFULLY!${NC}"
  echo -e "  You can access the Samba File Sharing UI at:"
  echo -e "  URL:      ${YELLOW}https://${detected_ip}:9090${NC}"
  echo -e "  User:     Log in using your host server system credentials"
  echo -e "  Features: Manage Samba & NFS shares, configure users, and permissions"
  echo -e "${GREEN}======================================================================${NC}"
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 5: INSTALL/CONFIGURE HOST SAMBA
# ------------------------------------------------------------------------------
action_install_samba() {
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

  # Prompt for Cockpit File Sharing Web GUI
  echo -e ""
  read -rp "Would you like to install Cockpit Web Console + 45Drives File Sharing GUI? (y/n) [default: y]: " INSTALL_COCKPIT
  INSTALL_COCKPIT="${INSTALL_COCKPIT:-y}"
  if [[ "$INSTALL_COCKPIT" =~ ^[Yy]$ ]]; then
    install_cockpit_samba_gui || true
  fi
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 6: SHOW SYSTEM STATUS & VITALS
# ------------------------------------------------------------------------------
action_show_status() {
  echo -e "\n${BLUE}=== Docker Container Status ===${NC}"
  docker compose $COMPOSE_ARGS ps
  
  echo -e "\n${BLUE}=== Storage Disk Usage (/mnt/*) ===${NC}"
  df -h /mnt/* 2>/dev/null || df -h
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 7: BACKUP SERVER CONFIGURATIONS
# ------------------------------------------------------------------------------
action_backup_configs() {
  local backup_name="homeserver_config_backup_$(date +%F_%H-%M-%S).tar.gz"
  echo -e "\n${BLUE}Creating backup of configuration files into $backup_name...${NC}"
  tar -czf "$backup_name" .env */.env setup.sh configure_homepage.sh */docker-compose.yml appdata/homepage/*.yaml 2>/dev/null || true
  echo -e "${GREEN}✔ Backup saved successfully to: $backup_name${NC}"
  restore_ownership
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 8: VIEW CONTAINER LOGS
# ------------------------------------------------------------------------------
action_view_logs() {
  echo -e "\n${BLUE}=== View Container Logs ===${NC}"
  build_compose_args
  local services
  services=($(docker compose $COMPOSE_ARGS config --services 2>/dev/null || echo ""))
  if [ ${#services[@]} -eq 0 ]; then
    echo -e "${RED}No services found in docker compose files.${NC}"
    return 1
  fi

  echo -e "Select a service to view its logs:"
  local i=1
  for svc in "${services[@]}"; do
    echo -e "  $i) $svc"
    i=$((i + 1))
  done
  echo -e "  $i) Return to main menu"

  local choice
  read -rp "Enter choice (1-$i): " choice
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$i" ]; then
    echo -e "${RED}Invalid selection.${NC}"
    return 1
  fi

  if [ "$choice" -eq "$i" ]; then
    return 0
  fi

  local selected_svc="${services[$((choice - 1))]}"
  echo -e "\n${BLUE}Streaming logs for $selected_svc (press Ctrl+C to exit)...${NC}"
  
  # Save original trap, and catch SIGINT to prevent setup.sh from exiting
  local orig_trap
  orig_trap=$(trap -p SIGINT)
  trap 'echo -e "\nReturning to menu..."' SIGINT
  
  # Temporarily disable exit-on-error as logging can be interrupted
  set +e
  docker compose $COMPOSE_ARGS logs -f --tail=100 "$selected_svc"
  set -e
  
  # Restore original trap or clear it
  if [ -n "$orig_trap" ]; then
    eval "$orig_trap"
  else
    trap - SIGINT
  fi
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 9: CHECK AND PULL IMAGE UPDATES (WITHOUT RESTART)
# ------------------------------------------------------------------------------
action_check_updates() {
  echo -e "\n${BLUE}=== Check and Pull Container Updates ===${NC}"
  build_compose_args
  echo -e "Pulling latest images from registries..."
  echo -e "${YELLOW}Note: This will download new images if available, but will NOT restart your running services.${NC}"
  echo -e "${YELLOW}New versions will take effect next time services are restarted or redeployed.${NC}\n"
  
  docker compose $COMPOSE_ARGS pull || true
  
  echo -e "\n${GREEN}✔ Check and pull completed successfully!${NC}"
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 10: DOCKER GARBAGE COLLECTION (PRUNE)
# ------------------------------------------------------------------------------
action_docker_prune() {
  echo -e "\n${RED}=== Docker Garbage Collection ===${NC}"
  echo -e "${YELLOW}This operation will reclaim disk space by deleting:${NC}"
  echo -e "  - All stopped containers"
  echo -e "  - All networks not used by at least one container"
  echo -e "  - All dangling and unused images"
  echo -e "  - All unused build caches"
  echo -e "  - All unused volumes (only volumes not used by any container)"
  echo ""
  local PRUNE_CONFIRM
  if [ "${NON_INTERACTIVE:-}" = "true" ]; then
    PRUNE_CONFIRM="y"
    echo -e "Non-interactive mode: Automatically confirming garbage collection."
  else
    read -rp "Are you sure you want to run garbage collection? (y/n) [default: n]: " PRUNE_CONFIRM
    PRUNE_CONFIRM="${PRUNE_CONFIRM:-n}"
  fi
  if [[ ! "$PRUNE_CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "Aborted."
    return 0
  fi
  
  echo -e "\n${BLUE}Running docker system prune...${NC}"
  docker system prune -af --volumes
  echo -e "\n${GREEN}✔ Garbage collection completed successfully!${NC}"
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 11: PUSH CONFIGURATIONS TO GITHUB
# ------------------------------------------------------------------------------
action_git_push() {
  echo -e "\n${BLUE}=== Push Local Configurations to GitHub ===${NC}"
  if [ ! -d ".git" ]; then
    echo -e "${RED}Error: This directory is not a Git repository. Cannot push to GitHub.${NC}"
    return 1
  fi

  # Show status
  echo -e "${BLUE}Current repository status:${NC}"
  git status -s

  # Check if there are changes
  if [ -z "$(git status --porcelain)" ]; then
    echo -e "\n${GREEN}No local changes detected to push.${NC}"
    return 0
  fi

  echo ""
  read -rp "Do you want to commit and push all local changes? (y/n) [default: y]: " GIT_CONFIRM
  GIT_CONFIRM="${GIT_CONFIRM:-y}"
  if [[ ! "$GIT_CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "Aborted."
    return 0
  fi

  read -rp "Enter commit message [default: Update homeserver configurations]: " COMMIT_MSG
  COMMIT_MSG="${COMMIT_MSG:-Update homeserver configurations}"

  # Stage all tracked/untracked files (respecting .gitignore)
  git add -A

  # Commit changes
  git commit -m "$COMMIT_MSG"

  # Load github configs from .env
  local repo=""
  local token=""
  if [ -f .env ]; then
    repo=$(grep -E "^GITHUB_REPO=" .env | cut -d'=' -f2- | sed 's/^"//;s/"$//' || true)
    token=$(grep -E "^GITHUB_TOKEN=" .env | cut -d'=' -f2- | sed 's/^"//;s/"$//' || true)
  fi

  # Fallback to defaults or git credentials if not in .env
  repo="${repo:-arunkarshan/HomeServerConfiguration}"

  echo -e "\n${BLUE}Pushing to GitHub repo: $repo...${NC}"
  
  # Temporarily disable exit-on-error to handle push failures gracefully
  set +e
  if [ -n "$token" ] && [ "$token" != "YOUR_GITHUB_TOKEN" ]; then
    # Authenticated push using token
    local remote_url="https://x-access-token:${token}@github.com/${repo}.git"
    git push "$remote_url" main
  else
    # Standard push (using SSH keys or Credential Helper)
    git push origin main
  fi
  local push_status=$?
  set -e

  if [ $push_status -eq 0 ]; then
    echo -e "\n${GREEN}✔ Successfully pushed configurations to GitHub!${NC}"
  else
    echo -e "\n${RED}Failed to push configurations to GitHub.${NC}"
    echo -e "If this is a private repository, please check your GITHUB_TOKEN permissions."
  fi
  restore_ownership
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 12: TAILSCALE VPN CONFIGURATION
# ------------------------------------------------------------------------------
action_setup_tailscale() {
  echo -e "\n${BLUE}=== Configure Secure Remote Access (Tailscale VPN) ===${NC}"
  
  if command -v tailscale &>/dev/null; then
    echo -e "${GREEN}Tailscale is already installed on this system!${NC}"
    echo -e "Current Status:"
    tailscale status || true
    echo ""
    read -rp "Would you like to run 'tailscale up' to log in or refresh your connection? (y/n) [default: y]: " TS_UP
    TS_UP="${TS_UP:-y}"
    if [[ ! "$TS_UP" =~ ^[Yy]$ ]]; then
      return 0
    fi
  else
    echo -e "${YELLOW}Tailscale is not installed on this server.${NC}"
    read -rp "Would you like to install and configure Tailscale? (y/n) [default: y]: " TS_INSTALL
    TS_INSTALL="${TS_INSTALL:-y}"
    if [[ ! "$TS_INSTALL" =~ ^[Yy]$ ]]; then
      return 0
    fi

    echo -e "\n${BLUE}Installing Tailscale via official installer script...${NC}"
    if ! curl -fsSL https://tailscale.com/install.sh | sh; then
      echo -e "${RED}Failed to install Tailscale.${NC}"
      return 1
    fi
  fi

  echo -e "\n${BLUE}Starting Tailscale authentication...${NC}"
  echo -e "${YELLOW}Follow the link printed below to authorize this server in your Tailscale admin console:${NC}"
  
  # Run tailscale up. This prints a login URL.
  # We disable exit-on-error temporarily just in case tailscale up exits non-zero on interruption or cancel
  set +e
  tailscale up
  set -e

  echo -e "\n${GREEN}Checking Tailscale connection IP...${NC}"
  local ts_ip
  ts_ip=$(tailscale ip -4 2>/dev/null || echo "")
  if [ -n "$ts_ip" ]; then
    echo -e "${GREEN}✔ Tailscale is connected! Server IP address: ${BLUE}$ts_ip${NC}"
  else
    echo -e "${YELLOW}Tailscale IP not found. You may need to finish logging in via the printed link.${NC}"
  fi
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 13: SYSTEM MAINTENANCE (UPDATES & REBOOT)
# ------------------------------------------------------------------------------
action_system_maintenance() {
  echo -e "\n${BLUE}=== System Updates and Maintenance ===${NC}"
  echo -e "Checking host package manager..."
  
  local pkg_manager=""
  if command -v apt-get &>/dev/null; then
    pkg_manager="apt"
  elif command -v dnf &>/dev/null; then
    pkg_manager="dnf"
  elif command -v yum &>/dev/null; then
    pkg_manager="yum"
  elif command -v pacman &>/dev/null; then
    pkg_manager="pacman"
  fi

  if [ -z "$pkg_manager" ]; then
    echo -e "${RED}Error: Supported package manager (apt, dnf, yum, pacman) not found. Maintenance skipped.${NC}"
    return 1
  fi

  local UPDATE_CONFIRM
  if [ "${NON_INTERACTIVE:-}" = "true" ]; then
    UPDATE_CONFIRM="y"
    echo -e "Non-interactive mode: Automatically confirming system package updates."
  else
    read -rp "Start updating host system packages? (y/n) [default: y]: " UPDATE_CONFIRM
    UPDATE_CONFIRM="${UPDATE_CONFIRM:-y}"
  fi
  if [[ ! "$UPDATE_CONFIRM" =~ ^[Yy]$ ]]; then
    echo -e "Aborted package updates."
  else
    echo -e "\n${BLUE}Running host system updates via $pkg_manager...${NC}"
    set +e
    case "$pkg_manager" in
      apt)
        apt-get update && apt-get upgrade -y
        ;;
      dnf)
        dnf upgrade -y
        ;;
      yum)
        yum update -y
        ;;
      pacman)
        pacman -Syu --noconfirm
        ;;
    esac
    local update_status=$?
    set -e
    if [ $update_status -eq 0 ]; then
      echo -e "${GREEN}✔ System packages updated successfully!${NC}"
    else
      echo -e "${RED}System updates encountered errors. Please inspect output.${NC}"
    fi
  fi

  # Reboot requirement checks
  local reboot_needed=false
  echo -e "\n${BLUE}Checking if a system reboot is required...${NC}"
  if [ -f /var/run/reboot-required ]; then
    reboot_needed=true
    echo -e "${YELLOW}⚠️ A system reboot is REQUIRED (pending updates need reboot).${NC}"
  elif command -v needs-restarting &>/dev/null; then
    if needs-restarting -r &>/dev/null; then
      reboot_needed=false
    else
      reboot_needed=true
      echo -e "${YELLOW}⚠️ A system reboot is REQUIRED (pending kernel/library updates).${NC}"
    fi
  else
    echo -e "No reboot indicators found. The system appears stable."
  fi

  # Ask to reboot
  local default_reboot="n"
  if [ "$reboot_needed" = true ]; then
    default_reboot="y"
  fi

  if [ "${NON_INTERACTIVE:-}" = "true" ]; then
    echo -e "Reboot check completed. Reboot needed: $reboot_needed. Skipping reboot in non-interactive mode."
  else
    read -rp "Would you like to reboot the host machine now? (y/n) [default: $default_reboot]: " REBOOT_CHOICE
    REBOOT_CHOICE="${REBOOT_CHOICE:-$default_reboot}"
    if [[ "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
      echo -e "${RED}Rebooting the host system now... Goodbye!${NC}"
      sleep 2
      reboot
    else
      echo -e "Reboot skipped. Returning to main menu."
    fi
  fi
}

# PORTAL ACTION 0: FETCH LATEST CONFIGURATIONS FROM GITHUB
action_sync_latest() {
  echo -e "\n${BLUE}Syncing latest configurations from Git repository...${NC}"
  sync_from_github
}

# Find device name in lsblk by matching size (part/disk)
find_dev_by_size() {
  local target_size="$1" # e.g. "465.8G" or "5.5T"
  lsblk -r -p -o NAME,SIZE,TYPE 2>/dev/null | grep -E " (part|disk)$" | grep -w "$target_size" | awk '{print $1}' | head -n 1
}

# Automatically configure auto-mounting in /etc/fstab for a drive by its size
configure_mount_fstab() {
  local mp="$1"          # e.g., "/mnt/hdd"
  local size_label="$2"  # e.g., "465.8G"

  # Find the disk/partition by its size using lsblk
  local dev_path
  dev_path=$(find_dev_by_size "$size_label")
  if [ -z "$dev_path" ]; then
    echo -e "${RED}Warning: Could not find drive of size $size_label in lsblk to auto-mount at $mp.${NC}"
    return 1
  fi

  echo -e "Discovered device ${BLUE}${dev_path}${NC} (${size_label}) for ${BLUE}${mp}${NC}."

  # Resolve partition UUID and filesystem type using blkid
  local uuid
  uuid=$(blkid -o value -s UUID "$dev_path" 2>/dev/null || echo "")
  local fs_type
  fs_type=$(blkid -o value -s TYPE "$dev_path" 2>/dev/null || echo "ext4")

  # Construct the fstab entry with defaults,nofail option so the OS still boots if drive is unplugged
  local fstab_entry=""
  if [ -n "$uuid" ]; then
    fstab_entry="UUID=${uuid} ${mp} ${fs_type} defaults,nofail 0 2"
    echo -e "UUID resolved: ${BLUE}${uuid}${NC} (FS: ${fs_type})."
  else
    fstab_entry="${dev_path} ${mp} ${fs_type} defaults,nofail 0 2"
    echo -e "UUID not found. Falling back to device path: ${BLUE}${dev_path}${NC}."
  fi

  # Ensure the mount point directory exists on the host
  mkdir -p "$mp"

  # Append mount entry to fstab
  echo -e "\n# Added by Homeserver Configuration Portal for auto-mount on $(date)" >> /etc/fstab
  echo "$fstab_entry" >> /etc/fstab
  echo -e "${GREEN}✔ Configured auto-mount for ${mp} in /etc/fstab.${NC}"
}

# Ensure required storage drives are mounted and configured to auto-mount on startup
ensure_mounts() {
  if [ "${CONFIGURE_DRIVE_MOUNTS:-false}" = "true" ] && [ "$EUID" -eq 0 ]; then
    # Parse space-separated mount points and sizes
    local mps=($DRIVE_MOUNT_POINTS)
    local sizes=($DRIVE_SIZES)
    local count=${#mps[@]}
    
    for ((i=0; i<count; i++)); do
      local mp="${mps[i]}"
      local size="${sizes[i]:-}"
      
      # 1. Verify and configure auto-mount in /etc/fstab if missing
      if ! grep -v "^#" /etc/fstab 2>/dev/null | grep -E -q "[[:space:]]${mp}([[:space:]]|$)"; then
        if [ -n "$size" ]; then
          configure_mount_fstab "$mp" "$size" || true
        fi
      fi
      
      # 2. Verify active mounting and mount immediately if offline
      if ! grep -qs " ${mp} " /proc/mounts; then
        echo -e "${YELLOW}Warning: ${mp} is not mounted. Attempting to mount...${NC}"
        mount "$mp" &>/dev/null || true
      fi
    done
  fi
}

print_mount_vitals() {
  if [ "${CONFIGURE_DRIVE_MOUNTS:-false}" = "true" ]; then
    echo -e "  Storage Mounts:"
    local mps=($DRIVE_MOUNT_POINTS)
    local count=${#mps[@]}
    
    for ((i=0; i<count; i++)); do
      local mp="${mps[i]}"
      local mounted="${RED}Not Mounted${NC}"
      local auto_cfg="${RED}No Auto-mount${NC}"
      
      if grep -qs " ${mp} " /proc/mounts; then
        mounted="${GREEN}Mounted${NC}"
      fi
      if grep -v "^#" /etc/fstab 2>/dev/null | grep -E -q "[[:space:]]${mp}([[:space:]]|$)"; then
        if ! grep -v "^#" /etc/fstab 2>/dev/null | grep -E "[[:space:]]${mp}([[:space:]]|$)" | grep -q "noauto"; then
          auto_cfg="${GREEN}Auto-mount Configured${NC}"
        fi
      fi
      echo -e "    - ${mp}: [${mounted}] [${auto_cfg}]"
    done
  else
    echo -e "  Storage Mounts: ${YELLOW}Auto-mounting not configured (Portable Mode)${NC}"
  fi
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 16.5: NON-INTERACTIVE RESTART SERVICES
# ------------------------------------------------------------------------------
action_restart_services_noninteractive() {
  local target_services_arg="$1"
  local selected_services=()
  if [ "$target_services_arg" = "all" ] || [ -z "$target_services_arg" ]; then
    selected_services=($(docker compose $COMPOSE_ARGS config --services | sort))
  else
    IFS=',' read -ra ADDR <<< "$target_services_arg"
    for svc in "${ADDR[@]}"; do
      svc=$(echo "$svc" | xargs)
      # Expand suites if needed
      if [ "$svc" = "immich_suite" ]; then
        selected_services+=("immich-server" "immich-machine-learning" "redis" "database")
      elif [ "$svc" = "nextcloud_suite" ]; then
        selected_services+=("nextcloud-app" "nextcloud-cron" "nextcloud-db")
      elif [ "$svc" = "jellyfin_suite" ]; then
        selected_services+=("jellyfin" "qbittorrent" "radarr" "sonarr" "prowlarr" "flaresolverr" "jellyseerr" "bazarr" "navidrome" "metube" "media-local-tracker" "torrent-generator")
      elif [ "$svc" = "util_suite" ]; then
        selected_services+=("vaultwarden" "stirling-pdf" "it-tools" "uptime-kuma" "syncthing" "pairdrop" "paperless-redis" "paperless-web" "radicale" "baikal" "cronicle" "ofelia" "tailscale")
      else
        selected_services+=("$svc")
      fi
    done
  fi

  echo -e "\nRestarting services: ${GREEN}${selected_services[*]}${NC}"
  docker compose $COMPOSE_ARGS stop "${selected_services[@]}"
  docker compose $COMPOSE_ARGS up -d "${selected_services[@]}"
  echo -e "${GREEN}✔ Services restarted successfully!${NC}"
  restore_ownership
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 16: NUKE SELECTED SERVICES
# ------------------------------------------------------------------------------
action_nuke_selected() {
  local target_services_arg="$1"
  echo -e "\n${RED}⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️${NC}"
  echo -e "${RED}⚠️ DANGER: THIS WILL NUKE AND ERASE SELECTED DATABASES AND CONFIGURATIONS! ⚠️${NC}"
  echo -e "${RED}⚠️ This permanently deletes configurations/databases for: ${target_services_arg}${NC}"
  echo -e "${RED}⚠️ Your raw media/photos inside external mounts will NOT be touched. ⚠️${NC}"
  echo -e "${RED}⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️ ⚠️⚠️⚠️${NC}"

  local CONFIRM_NUKE=""
  if [ "${NON_INTERACTIVE:-}" = "true" ]; then
    CONFIRM_NUKE="yes"
  else
    read -rp "Are you absolutely sure you want to proceed? (type 'yes' to confirm): " CONFIRM_NUKE
  fi

  if [ "$CONFIRM_NUKE" != "yes" ]; then
    echo -e "${YELLOW}Nuke operation cancelled.${NC}"
    return
  fi

  # Determine which services to nuke
  local selected_services=()
  if [ "$target_services_arg" = "all" ] || [ -z "$target_services_arg" ]; then
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      selected_services=($(docker compose $COMPOSE_ARGS config --services | sort))
    else
      echo -e "\nWould you like to nuke all services or select specific services?"
      read -rp "Enter 'all' or 'select' [default: all]: " nuke_choice
      nuke_choice="${nuke_choice:-all}"
      if [[ "$nuke_choice" =~ ^[Ss]elect$ ]]; then
        local selected_list
        selected_list=$(select_services_prompt "Enter the numbers of the services/groups you want to nuke (comma-separated): ")
        selected_services=($selected_list)
      else
        selected_services=($(docker compose $COMPOSE_ARGS config --services | sort))
      fi
    fi
  else
    # Parse comma separated services
    IFS=',' read -ra ADDR <<< "$target_services_arg"
    for svc in "${ADDR[@]}"; do
      svc=$(echo "$svc" | xargs)
      # If it's a suite group name, expand it
      if [ "$svc" = "immich_suite" ]; then
        selected_services+=("immich-server" "immich-machine-learning" "redis" "database")
      elif [ "$svc" = "nextcloud_suite" ]; then
        selected_services+=("nextcloud-app" "nextcloud-cron" "nextcloud-db")
      elif [ "$svc" = "jellyfin_suite" ]; then
        selected_services+=("jellyfin" "qbittorrent" "radarr" "sonarr" "prowlarr" "flaresolverr" "jellyseerr" "bazarr" "navidrome" "metube" "media-local-tracker" "torrent-generator")
      elif [ "$svc" = "util_suite" ]; then
        selected_services+=("vaultwarden" "stirling-pdf" "it-tools" "uptime-kuma" "syncthing" "pairdrop" "paperless-redis" "paperless-web" "radicale" "baikal" "cronicle" "ofelia" "tailscale")
      else
        selected_services+=("$svc")
      fi
    done
  fi

  if [ ${#selected_services[@]} -eq 0 ]; then
    echo -e "${RED}No valid services selected for nuking.${NC}"
    return 1
  fi

  echo -e "${RED}Stopping selected containers and removing volumes...${NC}"
  docker compose $COMPOSE_ARGS rm -f -s -v "${selected_services[@]}" || true

  echo -e "${RED}Deleting appdata configuration directories for selected services...${NC}"
  for service in "${selected_services[@]}"; do
    case "$service" in
      heimdall) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/heimdall" ;;
      homepage) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/homepage" ;;
      jellyfin) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/jellyfin" ;;
      qbittorrent) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/qbittorrent" ;;
      radarr) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/radarr" ;;
      sonarr) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/sonarr" ;;
      prowlarr) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/prowlarr" ;;
      jellyseerr) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/jellyseerr" ;;
      bazarr) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/bazarr" ;;
      navidrome) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/navidrome" ;;
      metube) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/metube" ;;
      torrent-generator) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/torrent-generator" ;;
      nextcloud-app|nextcloud-cron|nextcloud-db)
        rm -rf "${NEXTCLOUD_DB_LOCATION:-./appdata/nextcloud/postgres}"
        if [ "$service" = "nextcloud-app" ]; then
          rm -rf "${NEXTCLOUD_DATA_LOCATION:-./data/nextcloud}"
        fi
        ;;
      immich-server|immich-machine-learning|redis|database)
        rm -rf "${DB_DATA_LOCATION:-./appdata/immich/postgres}"
        ;;
      vaultwarden) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/vaultwarden" ;;
      stirling-pdf) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/stirling-pdf" ;;
      uptime-kuma) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/uptime-kuma" ;;
      syncthing) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/syncthing" ;;
      paperless-redis|paperless-web)
        rm -rf "${SYSTEM_DATA_DIR:-./appdata}/paperless"
        ;;
      radicale) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/radicale" ;;
      baikal) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/baikal" ;;
      cronicle) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/cronicle" ;;
      tailscale) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/tailscale" ;;
      filebrowser) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/filebrowser" ;;
      kopia) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/kopia" ;;
      backrest) rm -rf "${SYSTEM_DATA_DIR:-./appdata}/backrest" ;;
    esac
  done

  # If we nuked everything, we can also delete the env files
  local total_services=($(docker compose $COMPOSE_ARGS config --services | sort))
  if [ ${#selected_services[@]} -eq ${#total_services[@]} ]; then
    echo -e "${RED}All services nuked. Removing env configurations...${NC}"
    if [ "${NON_INTERACTIVE:-}" = "true" ]; then
      rm -f immich/.env nextcloud/.env utility/.env media/.env storage/.env
    else
      rm -f .env immich/.env nextcloud/.env utility/.env media/.env storage/.env
    fi
  fi

  echo -e "\n${BLUE}Syncing latest configurations...${NC}"
  sync_from_github_silent

  # Re-run config wizard only if running interactively and we nuked all,
  # or if env files were deleted and don't exist.
  if [ ! -f .env ]; then
    echo -e "\n${BLUE}Starting configuration wizard...${NC}"
    prompt_and_generate_configs
  fi

  build_compose_args

  # Re-deploy selected services
  echo -e "${GREEN}Deploying fresh instances of nuked services...${NC}"
  for service in "${selected_services[@]}"; do
    echo -e "Pulling image for: ${BLUE}$service${NC}..."
    local retry=0
    local success=false
    while [ $retry -lt 3 ] && [ "$success" = false ]; do
      if docker compose $COMPOSE_ARGS pull "$service"; then
        success=true
      else
        retry=$((retry + 1))
        echo -e "${YELLOW}Pull failed. Retrying in 5 seconds... ($retry/3)${NC}"
        sleep 5
      fi
    done
  done

  echo -e "${GREEN}Starting nuked services...${NC}"
  docker compose $COMPOSE_ARGS up -d "${selected_services[@]}"

  # Run post-install configuration if these services were recreated
  if [[ " ${selected_services[*]} " =~ " sonarr " || " ${selected_services[*]} " =~ " radarr " || " ${selected_services[*]} " =~ " prowlarr " ]]; then
    if [ -f "./configure_services.py" ]; then
      echo -e "\nRunning API setups..."
      python3 ./configure_services.py --services "$(echo "${selected_services[*]}" | tr ' ' ',')" || true
    fi
  fi

  echo -e "${GREEN}✔ Selected services nuked and reinstalled successfully!${NC}"
  restore_ownership
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 17: NON-INTERACTIVE UPDATE CONFIG & DEPLOY SELECTIVE SERVICES
# ------------------------------------------------------------------------------
action_update_config_noninteractive() {
  local target_services_arg="$1"
  echo -e "\nUpdating configuration from Git repository..."
  sync_from_github_silent
  build_compose_args

  if [ -f .env ]; then
    set -a
    source .env
    set +a
  fi

  local selected_services=()
  if [ "$target_services_arg" = "all" ] || [ -z "$target_services_arg" ]; then
    selected_services=($(docker compose $COMPOSE_ARGS config --services | sort))
  else
    # Parse comma separated list
    IFS=',' read -ra ADDR <<< "$target_services_arg"
    for svc in "${ADDR[@]}"; do
      svc=$(echo "$svc" | xargs)
      # Expand suite if name matches
      if [ "$svc" = "immich_suite" ]; then
        selected_services+=("immich-server" "immich-machine-learning" "redis" "database")
      elif [ "$svc" = "nextcloud_suite" ]; then
        selected_services+=("nextcloud-app" "nextcloud-cron" "nextcloud-db")
      elif [ "$svc" = "jellyfin_suite" ]; then
        selected_services+=("jellyfin" "qbittorrent" "radarr" "sonarr" "prowlarr" "flaresolverr" "jellyseerr" "bazarr" "navidrome" "metube" "media-local-tracker" "torrent-generator")
      elif [ "$svc" = "util_suite" ]; then
        selected_services+=("vaultwarden" "stirling-pdf" "it-tools" "uptime-kuma" "syncthing" "pairdrop" "paperless-redis" "paperless-web" "radicale" "baikal" "cronicle" "ofelia" "tailscale")
      else
        selected_services+=("$svc")
      fi
    done
  fi

  echo -e "Updating services: ${GREEN}${selected_services[*]}${NC}"

  # Pull and start
  for service in "${selected_services[@]}"; do
    echo -e "Pulling image for: ${BLUE}$service${NC}..."
    docker compose $COMPOSE_ARGS pull "$service" || true
  done

  echo -e "${BLUE}Bringing services up...${NC}"
  docker compose $COMPOSE_ARGS up -d "${selected_services[@]}"

  # Configure Homepage widgets
  if [ -f "./configure_homepage.sh" ]; then
    chmod +x ./configure_homepage.sh
    ./configure_homepage.sh || true
  fi

  # Auto-reconfigure media if they are in the list
  if [[ " ${selected_services[*]} " =~ " sonarr " || " ${selected_services[*]} " =~ " radarr " || " ${selected_services[*]} " =~ " prowlarr " ]]; then
    if [ -f "./configure_services.py" ]; then
      chmod +x ./configure_services.py
      python3 ./configure_services.py --services "$(echo "${selected_services[*]}" | tr ' ' ',')" || true
    fi
  fi

  restore_ownership
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 18: NON-INTERACTIVE FORCE RECONFIGURE
# ------------------------------------------------------------------------------
action_reconfigure_noninteractive() {
  local target_services_arg="$1"
  echo -e "\nReconfiguring media services..."

  local selected_list=()
  if [ "$target_services_arg" = "all" ] || [ -z "$target_services_arg" ]; then
    selected_list=("prowlarr" "sonarr" "radarr")
  else
    IFS=',' read -ra ADDR <<< "$target_services_arg"
    for choice in "${ADDR[@]}"; do
      choice=$(echo "$choice" | xargs)
      if [[ "$choice" == "prowlarr" || "$choice" == "sonarr" || "$choice" == "radarr" ]]; then
        selected_list+=("$choice")
      fi
    done
  fi

  local joined_selected
  joined_selected=$(local IFS=,; echo "${selected_list[*]}")

  if [ -z "$joined_selected" ]; then
    echo -e "${RED}No valid media services selected for reconfiguration.${NC}"
    return 1
  fi

  echo -e "Triggering reconfiguration for: ${GREEN}${joined_selected}${NC}"

  if [ -f "./configure_services.py" ]; then
    chmod +x ./configure_services.py
    python3 ./configure_services.py --services "$joined_selected" || true
  else
    echo -e "${RED}Error: configure_services.py not found!${NC}"
  fi
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 19: NON-INTERACTIVE TAILSCALE DEPLOY
# ------------------------------------------------------------------------------
action_setup_tailscale_noninteractive() {
  echo -e "\n${BLUE}=== Configure Secure Remote Access (Tailscale VPN) ===${NC}"
  if [ -z "${TS_AUTHKEY:-}" ]; then
    echo -e "${YELLOW}Warning: TS_AUTHKEY is not set in your environment configuration.${NC}"
    echo -e "If you want containerized Tailscale to auto-connect, please configure TS_AUTHKEY."
  else
    echo -e "${GREEN}TS_AUTHKEY is set. Starting containerized Tailscale VPN...${NC}"
  fi

  docker compose $COMPOSE_ARGS up -d tailscale
  echo -e "${GREEN}Tailscale container started!${NC}"
  echo -e "Checking container status..."
  sleep 3
  docker exec utility_tailscale tailscale status || true
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 20: SAMBA MANAGEMENT OPTIONS
# ------------------------------------------------------------------------------
action_samba_info() {
  local installed="false"
  if command -v smbd &>/dev/null; then
    installed="true"
  fi
  local active="false"
  if pgrep smbd &>/dev/null || systemctl is-active smbd &>/dev/null; then
    active="true"
  fi
  
  local users_json="[]"
  if [ "$installed" = "true" ]; then
    local users=()
    while IFS=: read -r username _; do
      if [ -n "$username" ]; then
        users+=("\"$username\"")
      fi
    done < <(pdbedit -L 2>/dev/null)
    
    if [ ${#users[@]} -gt 0 ]; then
      local IFS=","
      users_json="[${users[*]}]"
    fi
  fi

  local shares_json="[]"
  if [ "$installed" = "true" ] && [ -f /etc/samba/smb.conf ]; then
    shares_json=$(python3 -c "
import sys, json
shares = []
current = None
try:
    with open('/etc/samba/smb.conf', 'r') as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#') or line.startswith(';'):
                continue
            if line.startswith('[') and line.endswith(']'):
                name = line[1:-1].strip()
                if name not in ['global', 'homes', 'printers', 'print$']:
                    current = {
                        'name': name,
                        'path': '',
                        'valid_users': '',
                        'guest_ok': 'no',
                        'read_only': 'no'
                    }
                    shares.append(current)
                else:
                    current = None
            elif current:
                if '=' in line:
                    parts = line.split('=', 1)
                    k = parts[0].strip().lower()
                    v = parts[1].strip()
                    if k == 'path':
                        current['path'] = v
                    elif k in ['valid users', 'valid_users']:
                        current['valid_users'] = v
                    elif k in ['guest ok', 'guest_ok', 'public']:
                        current['guest_ok'] = v
                    elif k in ['read only', 'read_only', 'writable', 'writeable']:
                        if k in ['writable', 'writeable']:
                            current['read_only'] = 'no' if v.lower() in ['yes', 'true', '1'] else 'yes'
                        else:
                            current['read_only'] = v
except Exception as e:
    pass
print(json.dumps(shares))
" 2>/dev/null || echo "[]")
  fi

  cat <<EOF
{
  "installed": $installed,
  "active": $active,
  "users": $users_json,
  "shares": $shares_json
}
EOF
}

action_samba_add_user() {
  local username="$1"
  local password="$2"
  if [ -z "$username" ] || [ -z "$password" ]; then
    echo -e "${RED}Error: Username and password are required.${NC}"
    return 1
  fi
  
  if ! id "$username" &>/dev/null; then
    echo -e "Creating system user '$username'..."
    useradd -M -s /usr/sbin/nologin "$username"
  fi
  
  echo -e "Setting Samba password for '$username'..."
  printf "%s\n%s\n" "$password" "$password" | smbpasswd -a -s "$username"
  echo -e "${GREEN}✔ User '$username' added successfully to Samba!${NC}"
}

action_samba_remove_user() {
  local username="$1"
  if [ -z "$username" ]; then
    echo -e "${RED}Error: Username is required.${NC}"
    return 1
  fi
  
  echo -e "Removing Samba credentials for '$username'..."
  smbpasswd -x "$username"
  
  if id "$username" &>/dev/null; then
    echo -e "Deleting system user '$username'..."
    userdel "$username" 2>/dev/null || true
  fi
  echo -e "${GREEN}✔ User '$username' removed successfully!${NC}"
}

action_samba_add_share() {
  local name="$1"
  local path="$2"
  local valid_users="$3"
  local guest_ok="${4:-no}"
  local read_only="${5:-no}"
  
  if [ -z "$name" ] || [ -z "$path" ]; then
    echo -e "${RED}Error: Share name and path are required.${NC}"
    return 1
  fi
  
  name=$(echo "$name" | tr -d '[]')
  
  if [ ! -d "$path" ]; then
    echo -e "Creating shared folder: $path..."
    mkdir -p "$path"
    chmod 775 "$path"
  fi
  
  action_samba_remove_share "$name" &>/dev/null
  
  echo -e "Appending share '$name' config to smb.conf..."
  cat <<EOF >> /etc/samba/smb.conf

[$name]
   path = $path
   browseable = yes
   read only = $read_only
   guest ok = $guest_ok
   valid users = $valid_users
EOF
  
  echo -e "Restarting Samba daemon..."
  systemctl restart smbd || service smbd restart || rc-service smbd restart || true
  echo -e "${GREEN}✔ Share '$name' added successfully!${NC}"
}

action_samba_remove_share() {
  local name="$1"
  if [ -z "$name" ]; then
    echo -e "${RED}Error: Share name is required.${NC}"
    return 1
  fi
  
  echo -e "Removing share '$name' config from smb.conf..."
  python3 -c "
import sys
name = sys.argv[1]
lines = []
inside_target = False
try:
    with open('/etc/samba/smb.conf', 'r') as f:
        for line in f:
            stripped = line.strip()
            if stripped.startswith('[') and stripped.endswith(']'):
                sec = stripped[1:-1].strip()
                if sec == name:
                    inside_target = True
                    continue
                else:
                    inside_target = False
            if inside_target:
                continue
            lines.append(line)
    with open('/etc/samba/smb.conf', 'w') as f:
        f.writelines(lines)
    print('Success')
except Exception as e:
    print(f'Error: {e}')
" "$name"
  
  echo -e "Restarting Samba daemon..."
  systemctl restart smbd || service smbd restart || rc-service smbd restart || true
  echo -e "${GREEN}✔ Share '$name' removed successfully!${NC}"
}

# ------------------------------------------------------------------------------
# PORTAL ACTION 21: NETPLAN STATIC IP & DHCP CONFIGURATION
# ------------------------------------------------------------------------------
action_netplan_info() {
  local installed="false"
  # Check via PATH first, then fall back to known absolute locations.
  # /usr/sbin/netplan may be absent from PATH when the server is launched via
  # systemd or another service manager that provides a restricted environment.
  if command -v netplan &>/dev/null || \
     [ -x /usr/sbin/netplan ] || \
     [ -x /sbin/netplan ] || \
     [ -x /usr/bin/netplan ]; then
    installed="true"
  fi

  local interfaces_json="[]"
  local interfaces=()
  if [ -d /sys/class/net ]; then
    for dev in /sys/class/net/*; do
      [ -e "$dev" ] || continue
      name=$(basename "$dev")
      if [[ "$name" != "lo" && "$name" != docker* && "$name" != veth* && "$name" != br-* && "$name" != tailscale* ]]; then
        interfaces+=("\"$name\"")
      fi
    done
  else
    # Mock fallback for non-Linux hosts (e.g. Darwin macOS development)
    interfaces+=("\"eth0\"")
    interfaces+=("\"enp3s0\"")
  fi

  if [ ${#interfaces[@]} -gt 0 ]; then
    local IFS=","
    interfaces_json="[${interfaces[*]}]"
  fi

  local current_config="null"
  if [ -d /etc/netplan ]; then
    current_config=$(python3 -c "
import sys, json, glob
config = {
    'interface': '',
    'dhcp': True,
    'address': '',
    'gateway': '',
    'dns': []
}
files = glob.glob('/etc/netplan/*.yaml') + glob.glob('/etc/netplan/*.yml')
if files:
    try:
        with open(files[0], 'r') as f:
            lines = f.readlines()
            current_iface = ''
            in_ethernets = False
            in_nameservers = False
            for line in lines:
                stripped = line.strip()
                if not stripped or stripped.startswith('#'):
                    continue
                indent = len(line) - len(line.lstrip())
                if stripped.startswith('ethernets:'):
                    in_ethernets = True
                    continue
                if in_ethernets:
                    if indent == 0 and not stripped.startswith('ethernets:'):
                        in_ethernets = False
                        continue
                    if indent == 4 or (indent == 2 and not stripped.endswith(':') and ':' in stripped):
                        if stripped.endswith(':'):
                            current_iface = stripped[:-1].strip()
                            config['interface'] = current_iface
                            continue
                    if current_iface and indent >= 6:
                        if stripped.startswith('dhcp4:'):
                            val = stripped.split(':', 1)[1].strip().lower()
                            config['dhcp'] = val in ['true', 'yes', '1']
                        elif stripped.startswith('addresses:'):
                            parts = stripped.split(':', 1)[1].strip()
                            if parts.startswith('[') and parts.endswith(']'):
                                addr = parts[1:-1].strip().split(',')[0].strip()
                                config['address'] = addr
                        elif stripped.startswith('-') and len(lines) > 0:
                            config['address'] = stripped[1:].strip()
                        elif stripped.startswith('gateway4:'):
                            config['gateway'] = stripped.split(':', 1)[1].strip()
                        elif stripped.startswith('via:'):
                            config['gateway'] = stripped.split(':', 1)[1].strip()
                        elif stripped.startswith('nameservers:'):
                            in_nameservers = True
                        elif in_nameservers:
                            if indent < 8:
                                in_nameservers = False
                            elif stripped.startswith('addresses:'):
                                parts = stripped.split(':', 1)[1].strip()
                                if parts.startswith('[') and parts.endswith(']'):
                                    config['dns'] = [x.strip() for x in parts[1:-1].split(',')]
    except Exception as e:
        pass
print(json.dumps(config))
" 2>/dev/null || echo "null")
  else
    # Mock fallback for non-Linux hosts
    current_config="{\"interface\": \"eth0\", \"dhcp\": true, \"address\": \"192.168.1.150/24\", \"gateway\": \"192.168.1.1\", \"dns\": [\"8.8.8.8\", \"1.1.1.1\"]}"
  fi

  cat <<EOF
{
  "installed": $installed,
  "interfaces": $interfaces_json,
  "current": $current_config
}
EOF
}

action_set_static_ip() {
  local interface="$1"
  local ip_cidr="$2"
  local gateway="$3"
  local dns1="$4"
  local dns2="$5"

  if [ -z "$interface" ] || [ -z "$ip_cidr" ] || [ -z "$gateway" ] || [ -z "$dns1" ]; then
    echo -e "${RED}Error: Interface, IP/CIDR, Gateway, and Primary DNS are required.${NC}"
    return 1
  fi

  if ! command -v netplan &>/dev/null; then
    echo -e "${YELLOW}Warning: netplan utility not found on the host system.${NC}"
    if [ "$(uname)" = "Darwin" ]; then
      echo -e "[DEV MODE] Writing simulated Netplan configuration for $interface..."
      echo -e "IP Address: $ip_cidr"
      echo -e "Gateway: $gateway"
      echo -e "DNS: $dns1, $dns2"
      echo -e "${GREEN}✔ Simulated Static IP set successfully!${NC}"
      return 0
    else
      echo -e "${RED}Error: netplan is not installed. Static IP configuration requires Netplan on Ubuntu/Debian.${NC}"
      return 1
    fi
  fi

  echo -e "Backing up existing Netplan configurations..."
  mkdir -p /etc/netplan/backup/
  cp -f /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null || true
  cp -f /etc/netplan/*.yml /etc/netplan/backup/ 2>/dev/null || true

  rm -f /etc/netplan/*.yaml /etc/netplan/*.yml

  local netplan_file="/etc/netplan/01-netcfg.yaml"
  echo -e "Writing static IP configuration to $netplan_file..."
  cat <<EOF > "$netplan_file"
network:
  version: 2
  renderer: networkd
  ethernets:
    $interface:
      dhcp4: no
      addresses:
        - $ip_cidr
      routes:
        - to: default
          via: $gateway
      nameservers:
        addresses:
          - $dns1
EOF

  if [ -n "$dns2" ]; then
    cat <<EOF >> "$netplan_file"
          - $dns2
EOF
  fi

  chmod 600 "$netplan_file"

  echo -e "Applying netplan configuration..."
  if netplan apply; then
    echo -e "${GREEN}✔ Static IP configured successfully!${NC}"
    return 0
  else
    echo -e "${RED}Error: Failed to apply Netplan configuration.${NC}"
    echo -e "Restoring backup configurations..."
    cp -f /etc/netplan/backup/* /etc/netplan/ 2>/dev/null || true
    netplan apply
    return 1
  fi
}

action_set_dhcp() {
  local interface="$1"
  if [ -z "$interface" ]; then
    echo -e "${RED}Error: Interface is required.${NC}"
    return 1
  fi

  if ! command -v netplan &>/dev/null; then
    echo -e "${YELLOW}Warning: netplan utility not found on the host system.${NC}"
    if [ "$(uname)" = "Darwin" ]; then
      echo -e "[DEV MODE] Writing simulated Netplan DHCP configuration for $interface..."
      echo -e "${GREEN}✔ Simulated DHCP set successfully!${NC}"
      return 0
    else
      echo -e "${RED}Error: netplan is not installed. DHCP configuration requires Netplan on Ubuntu/Debian.${NC}"
      return 1
    fi
  fi

  echo -e "Backing up existing Netplan configurations..."
  mkdir -p /etc/netplan/backup/
  cp -f /etc/netplan/*.yaml /etc/netplan/backup/ 2>/dev/null || true
  cp -f /etc/netplan/*.yml /etc/netplan/backup/ 2>/dev/null || true

  rm -f /etc/netplan/*.yaml /etc/netplan/*.yml

  local netplan_file="/etc/netplan/01-netcfg.yaml"
  echo -e "Writing DHCP configuration to $netplan_file..."
  cat <<EOF > "$netplan_file"
network:
  version: 2
  renderer: networkd
  ethernets:
    $interface:
      dhcp4: yes
EOF

  chmod 600 "$netplan_file"

  echo -e "Applying netplan configuration..."
  if netplan apply; then
    echo -e "${GREEN}✔ DHCP configured successfully!${NC}"
    return 0
  else
    echo -e "${RED}Error: Failed to apply Netplan configuration.${NC}"
    echo -e "Restoring backup configurations..."
    cp -f /etc/netplan/backup/* /etc/netplan/ 2>/dev/null || true
    netplan apply
    return 1
  fi
}

# ------------------------------------------------------------------------------
# PORTAL INTERACTIVE MAIN MENU LOOP
# ------------------------------------------------------------------------------
main_menu() {
  if ! docker network inspect homeserver_network &>/dev/null; then
    echo -e "Creating shared global bridge network: ${BLUE}homeserver_network${NC}..."
    docker network create homeserver_network
  fi

  while true; do
    ensure_mounts

    echo -e "\n${BLUE}======================================================================${NC}"
    echo -e "${GREEN}                 HOMESERVER SYSTEM MANAGEMENT PORTAL${NC}"
    echo -ne "  " && show_last_fetch_timestamp
    print_mount_vitals
    echo -e "${BLUE}======================================================================${NC}"
    echo -e "  1) Fetch latest configurations from Git repository"
    echo -e "  2) NUKE everything and deploy from scratch (⚠️ DANGER ⚠️)"
    echo -e "  3) Update configuration from Git & update specific services"
    echo -e "  4) Restart specific services (Stop & Start)"
    echo -e "  5) View real-time logs of a container"
    echo -e "  6) Check/Pull latest Docker image updates (without restarting)"
    echo -e "  7) Run Docker garbage collection (prune unused files/caches)"
    echo -e "  8) Push local configurations to GitHub (Git commit & push)"
    echo -e "  9) Update Homepage Dashboard (Pull configs, update container)"
    echo -e " 10) Install/Configure host Samba (SMB) file sharing"
    echo -e " 11) Configure secure remote access (Tailscale VPN)"
    echo -e " 12) Run system updates and maintenance (OS upgrade & reboot check)"
    echo -e " 13) Show container status and disk usage (System Vitals)"
    echo -e " 14) Backup server configurations (.env and app configs)"
    echo -e "  0) Exit"
    echo -e "${BLUE}======================================================================${NC}"
    read -rp "Please enter your choice (0-14): " MENU_CHOICE

    case "$MENU_CHOICE" in
      1) action_sync_latest ;;
      2) action_nuke_everything ;;
      3) action_update_config ;;
      4) action_restart_services ;;
      5) action_view_logs ;;
      6) action_check_updates ;;
      7) action_docker_prune ;;
      8) action_git_push ;;
      9) action_update_homepage ;;
      10) action_install_samba ;;
      11) action_setup_tailscale ;;
      12) action_system_maintenance ;;
      13) action_show_status ;;
      14) action_backup_configs ;;
      0) echo -e "${GREEN}Exiting management portal. Goodbye!${NC}"; exit 0 ;;
      *) echo -e "${RED}Invalid option. Please try again.${NC}" ;;
    esac
  done
}

# ==============================================================================
# MAIN SCRIPT ENTRY POINT
# ==============================================================================

if [ "$(uname)" != "Darwin" ]; then
  if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Error: Please run this script with sudo or as root to handle installation and system checks.${NC}"
    echo -e "Usage: sudo ./setup.sh"
    exit 1
  fi
  check_dependencies
fi

if [ -f .env ]; then
  set -a
  source .env
  set +a
fi

if ! build_compose_args; then
  echo -e "${YELLOW}No Docker Compose configuration files found in the current directory.${NC}"
  echo -e "Automatically downloading latest configurations from GitHub first..."
  sync_from_github
  build_compose_args
fi

if [ ! -f .env ]; then
  echo -e "${YELLOW}No environment config found. Initializing configuration wizard...${NC}"
  prompt_and_generate_configs
fi

# Check if CLI arguments were passed
if [ $# -gt 0 ]; then
  export NON_INTERACTIVE="true"
  case "$1" in
    --sync)
      action_sync_latest
      ;;
    --nuke)
      action_nuke_selected "$2"
      ;;
    --update)
      action_update_config_noninteractive "$2"
      ;;
    --reconfigure)
      action_reconfigure_noninteractive "$2"
      ;;
    --restart)
      action_restart_services_noninteractive "$2"
      ;;
    --prune)
      action_docker_prune
      ;;
    --homepage)
      action_update_homepage
      ;;
    --backup)
      action_backup_configs
      ;;
    --tailscale)
      action_setup_tailscale_noninteractive
      ;;
    --install-samba)
      action_install_samba
      ;;
    --sys-maintenance)
      action_system_maintenance
      ;;
    --git-push)
      action_git_push
      ;;
    --check-updates)
      action_check_updates
      ;;
    --samba-info)
      action_samba_info
      ;;
    --samba-add-user)
      action_samba_add_user "$2" "$3"
      ;;
    --samba-remove-user)
      action_samba_remove_user "$2"
      ;;
    --samba-add-share)
      action_samba_add_share "$2" "$3" "$4" "$5" "$6"
      ;;
    --samba-remove-share)
      action_samba_remove_share "$2"
      ;;
    --netplan-info)
      action_netplan_info
      ;;
    --set-static-ip)
      action_set_static_ip "$2" "$3" "$4" "$5" "$6"
      ;;
    --set-dhcp)
      action_set_dhcp "$2"
      ;;
    --install-docker)
      check_dependencies
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
  exit 0
fi

main_menu

