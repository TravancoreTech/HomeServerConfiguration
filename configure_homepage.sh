#!/usr/bin/env bash
# ==============================================================================
# HOMEPAGE CONFIGURATION AUTO-CONFIGURATOR
# ==============================================================================
# This script runs after a delay to extract API keys from running service
# configurations (Radarr, Sonarr, etc.) and updates homepage's services.yaml.
# ==============================================================================

set -euo pipefail

# Text Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Load environment variables from .env to get SYSTEM_DATA_DIR
SYSTEM_DATA_DIR=""
if [ -f ".env" ]; then
  # Safely parse SYSTEM_DATA_DIR
  SYSTEM_DATA_DIR=$(grep '^SYSTEM_DATA_DIR=' .env | cut -d= -f2- | sed 's/^"//;s/"$//' || true)
fi

TARGET_DIR="${SYSTEM_DATA_DIR:-./appdata}/homepage"
echo -e "${BLUE}Target directory for Homepage: $TARGET_DIR${NC}"

# Pre-create folder
mkdir -p "$TARGET_DIR"

# Always sync services.yaml to target directory to ensure it has the latest service listing
if [ -f "appdata/homepage/services.yaml" ]; then
  cp "appdata/homepage/services.yaml" "$TARGET_DIR/services.yaml"
else
  echo -e "${RED}Error: Template services.yaml not found at appdata/homepage/services.yaml${NC}"
  exit 1
fi

# Copy other configuration templates only if they do not exist in the target directory
for file in bookmarks.yaml settings.yaml widgets.yaml docker.yaml; do
  if [ -f "appdata/homepage/$file" ] && [ ! -f "$TARGET_DIR/$file" ]; then
    echo "Initializing default $file in $TARGET_DIR..."
    cp "appdata/homepage/$file" "$TARGET_DIR/$file"
  fi
done

SERVICES_YAML="$TARGET_DIR/services.yaml"
echo -e "${BLUE}Configuring Homepage services.yaml at $SERVICES_YAML...${NC}"

# 1. Parse Radarr API Key
# Radarr stores config in appdata/radarr/config.xml or appdata/Radarr/config.xml
# Checking both lowercase and uppercase paths
RADARR_CONFIG=""
if [ -f "appdata/radarr/config.xml" ]; then
  RADARR_CONFIG="appdata/radarr/config.xml"
elif [ -f "appdata/Radarr/config.xml" ]; then
  RADARR_CONFIG="appdata/Radarr/config.xml"
fi

if [ -n "$RADARR_CONFIG" ]; then
  RADARR_KEY=$(sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' "$RADARR_CONFIG" 2>/dev/null || true)
  if [ -n "$RADARR_KEY" ]; then
    echo -e "Found Radarr API Key: ${GREEN}${RADARR_KEY:0:4}...${NC}"
    # Replace key in services.yaml
    sed -i.bak "s|key: YOUR_RADARR_API_KEY|key: $RADARR_KEY|g" "$SERVICES_YAML" || sed -i "" "s|key: YOUR_RADARR_API_KEY|key: $RADARR_KEY|g" "$SERVICES_YAML"
  fi
fi

# 2. Parse Sonarr API Key
SONARR_CONFIG=""
if [ -f "appdata/sonarr/config.xml" ]; then
  SONARR_CONFIG="appdata/sonarr/config.xml"
elif [ -f "appdata/Sonarr/config.xml" ]; then
  SONARR_CONFIG="appdata/Sonarr/config.xml"
fi

if [ -n "$SONARR_CONFIG" ]; then
  SONARR_KEY=$(sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' "$SONARR_CONFIG" 2>/dev/null || true)
  if [ -n "$SONARR_KEY" ]; then
    echo -e "Found Sonarr API Key: ${GREEN}${SONARR_KEY:0:4}...${NC}"
    # Replace key in services.yaml
    sed -i.bak "s|key: YOUR_SONARR_API_KEY|key: $SONARR_KEY|g" "$SERVICES_YAML" || sed -i "" "s|key: YOUR_SONARR_API_KEY|key: $SONARR_KEY|g" "$SERVICES_YAML"
  fi
fi

# Clean up any backup files created by sed
rm -f "${SERVICES_YAML}.bak" 2>/dev/null || true

# Restore file ownership to the original sudo user
if [ -n "${SUDO_USER:-}" ]; then
  chown "${SUDO_UID}:${SUDO_GID}" "$SERVICES_YAML" 2>/dev/null || true
fi

echo -e "${GREEN}✔ Homepage configuration updated successfully!${NC}"
