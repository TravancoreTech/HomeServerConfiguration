#!/usr/bin/env bash
# ==============================================================================
# HOMEPAGE CONFIGURATION AUTO-CONFIGURATOR
# ==============================================================================
# Copies config files from the repo's appdata/homepage/ into wherever the
# running Homepage container actually mounts its /app/config directory.
# Detects the real mount path via `docker inspect` so it always lands in the
# right place regardless of how SYSTEM_DATA_DIR is configured.
# Also auto-extracts API keys from Radarr/Sonarr config.xml files.
# ==============================================================================

set -euo pipefail

# Text Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# 1. Determine target directory
#    Primary:  docker inspect the running container to find the real bind-mount
#    Fallback: SYSTEM_DATA_DIR from .env → ./appdata
# ------------------------------------------------------------------------------
TARGET_DIR=""

# Try to get the actual mount source from a running container
if command -v docker &>/dev/null; then
  CONTAINER_NAMES=("dashboard_homepage" "homepage")
  for cname in "${CONTAINER_NAMES[@]}"; do
    if docker inspect "$cname" &>/dev/null 2>&1; then
      DETECTED=$(docker inspect "$cname" \
        --format '{{range .Mounts}}{{if eq .Destination "/app/config"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null || true)
      if [ -n "$DETECTED" ]; then
        TARGET_DIR="$DETECTED"
        echo -e "${GREEN}✔ Detected Homepage config mount: $TARGET_DIR${NC}"
        break
      fi
    fi
  done
fi

# Fallback: derive from SYSTEM_DATA_DIR in .env
if [ -z "$TARGET_DIR" ]; then
  SYSTEM_DATA_DIR=""
  if [ -f ".env" ]; then
    SYSTEM_DATA_DIR=$(grep '^SYSTEM_DATA_DIR=' .env | cut -d= -f2- | sed 's/^"//;s/"$//' || true)
  fi
  TARGET_DIR="${SYSTEM_DATA_DIR:-./appdata}/homepage"
  echo -e "${YELLOW}Container not running or not found. Using fallback path: $TARGET_DIR${NC}"
fi

echo -e "${BLUE}Syncing Homepage config files to: $TARGET_DIR${NC}"
mkdir -p "$TARGET_DIR"

# ------------------------------------------------------------------------------
# 2. Copy config files from repo → target directory
#    services.yaml is always overwritten (it's the source of truth).
#    Other files are backed up first to preserve any manual edits.
# ------------------------------------------------------------------------------
SOURCE_DIR="appdata/homepage"

if [ ! -f "$SOURCE_DIR/services.yaml" ]; then
  echo -e "${RED}Error: Source file not found at $SOURCE_DIR/services.yaml${NC}"
  echo -e "${RED}Make sure you are running this script from the repo root directory.${NC}"
  exit 1
fi

# Always overwrite services.yaml — it is the canonical service list
cp "$SOURCE_DIR/services.yaml" "$TARGET_DIR/services.yaml"
echo -e "${GREEN}✔ services.yaml synced${NC}"

# Back up and overwrite remaining config files
for file in bookmarks.yaml settings.yaml widgets.yaml docker.yaml; do
  if [ -f "$SOURCE_DIR/$file" ]; then
    if [ -f "$TARGET_DIR/$file" ]; then
      cp "$TARGET_DIR/$file" "$TARGET_DIR/${file}.user.bak" || true
    fi
    cp "$SOURCE_DIR/$file" "$TARGET_DIR/$file"
    echo -e "${GREEN}✔ $file synced${NC}"
  fi
done

SERVICES_YAML="$TARGET_DIR/services.yaml"

# ------------------------------------------------------------------------------
# 3. Auto-inject Radarr API key
# ------------------------------------------------------------------------------
RADARR_CONFIG=""
for path in "appdata/radarr/config.xml" "appdata/Radarr/config.xml"; do
  [ -f "$path" ] && RADARR_CONFIG="$path" && break
done

if [ -n "$RADARR_CONFIG" ]; then
  RADARR_KEY=$(sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' "$RADARR_CONFIG" 2>/dev/null || true)
  if [ -n "$RADARR_KEY" ]; then
    echo -e "Found Radarr API Key: ${GREEN}${RADARR_KEY:0:4}...${NC}"
    sed -i.bak "s|key: YOUR_RADARR_API_KEY|key: $RADARR_KEY|g" "$SERVICES_YAML" \
      || sed -i "" "s|key: YOUR_RADARR_API_KEY|key: $RADARR_KEY|g" "$SERVICES_YAML"
  fi
fi

# ------------------------------------------------------------------------------
# 4. Auto-inject Sonarr API key
# ------------------------------------------------------------------------------
SONARR_CONFIG=""
for path in "appdata/sonarr/config.xml" "appdata/Sonarr/config.xml"; do
  [ -f "$path" ] && SONARR_CONFIG="$path" && break
done

if [ -n "$SONARR_CONFIG" ]; then
  SONARR_KEY=$(sed -n 's|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p' "$SONARR_CONFIG" 2>/dev/null || true)
  if [ -n "$SONARR_KEY" ]; then
    echo -e "Found Sonarr API Key: ${GREEN}${SONARR_KEY:0:4}...${NC}"
    sed -i.bak "s|key: YOUR_SONARR_API_KEY|key: $SONARR_KEY|g" "$SERVICES_YAML" \
      || sed -i "" "s|key: YOUR_SONARR_API_KEY|key: $SONARR_KEY|g" "$SERVICES_YAML"
  fi
fi

# Clean up sed backup files
rm -f "${SERVICES_YAML}.bak" 2>/dev/null || true

# ------------------------------------------------------------------------------
# 5. Restore file ownership to the invoking sudo user
# ------------------------------------------------------------------------------
if [ -n "${SUDO_USER:-}" ]; then
  chown "${SUDO_UID}:${SUDO_GID}" "$TARGET_DIR"/*.yaml 2>/dev/null || true
fi

echo -e "${GREEN}✔ Homepage configuration synced successfully to $TARGET_DIR${NC}"
