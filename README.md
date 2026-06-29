# 🏠 HomeServer Configuration Suite

A fully self-hosted homeserver stack built on Docker Compose, covering media streaming, personal cloud, photo backup, system utilities, and storage management — all manageable through a built-in web portal. No cloud dependency. No subscriptions. Everything on your own hardware.

[![License: MIT](https://img.shields.io/badge/License-MIT-indigo.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20Ubuntu%2020.04%2B-blue)](https://ubuntu.com/server)
[![Docker](https://img.shields.io/badge/Requires-Docker%20Engine-2496ED?logo=docker)](https://docs.docker.com/engine/install/)

---

## Table of Contents

- [What's Included](#whats-included)
- [Architecture Overview](#architecture-overview)
- [Quick Start (Fresh Server)](#quick-start-fresh-server)
- [Service Directory & Ports](#service-directory--ports)
- [Configuration Reference (.env)](#configuration-reference-env)
- [Management Portal (WebUI)](#management-portal-webui)
- [setup.sh CLI Reference](#setupsh-cli-reference)
- [Directory Structure](#directory-structure)
- [Hardware Recommendations](#hardware-recommendations)
- [Updating Services](#updating-services)
- [Backing Up](#backing-up)

---

## What's Included

The suite is organized into five independent Docker Compose stacks. Each runs in isolation and can be deployed or stopped individually.

| Suite | Purpose |
|---|---|
| 🎬 **Media** | Movie & TV automation, music server, streaming |
| ☁️ **Nextcloud** | Self-hosted cloud drive & calendar |
| 📸 **Immich** | Google Photos replacement with ML features |
| 🗄️ **Storage** | File browser, backup engines |
| 🛠️ **Utility** | Password manager, PDF tools, sync, monitoring |
| 📊 **Dashboard** | Landing portal with live service metrics |

---

## Architecture Overview

```
Your Laptop / Phone
        │
        │  (Local network or Tailscale VPN)
        ▼
┌─────────────────────────────────────────────────────┐
│                  Ubuntu Server                       │
│                                                      │
│  :80   Dashboard (Homepage)                         │
│  :8888 Management WebUI  ◄── You control everything │
│                               from here             │
│  ┌────────────┐  ┌────────────┐  ┌──────────────┐  │
│  │   Media    │  │   Cloud    │  │   Utility    │  │
│  │  Stack     │  │   Stack    │  │   Stack      │  │
│  └────────────┘  └────────────┘  └──────────────┘  │
│  ┌────────────┐  ┌────────────┐                     │
│  │  Storage   │  │ Dashboard  │                     │
│  │  Stack     │  │  Stack     │                     │
│  └────────────┘  └────────────┘                     │
│                                                      │
│  /mnt/hdd/media        (your media drives)          │
│  /mnt/hdd/photos       (photo backup location)      │
│  ./appdata/            (all service config data)    │
└─────────────────────────────────────────────────────┘
```

---

## Quick Start (Fresh Server)

> **Requirements:** Ubuntu 20.04+ or Debian 11+ server — headless is fine, no desktop needed. Run all commands over SSH from your laptop.


### Step 1 — Bootstrap (downloads the configuration suite)

This command downloads the suite directly to your current working directory and ensures basic tools (`curl`, `unzip`) are installed:

**Option A — Short URL**
```bash
curl -fsSL https://tinyurl.com/2aj7eauh | bash
```

**Option B — Full URL**
```bash
curl -fsSL https://raw.githubusercontent.com/TravancoreTech/HomeServerConfiguration/main/bootstrap.sh | bash
```

---

### Step 2 — Run the Interactive Setup CLI

Once bootstrapped, run the interactive installer to configure your environment, install Docker, and launch your desired containers:

```bash
sudo ./setup.sh
```

Follow the on-screen prompts to:
1. Automatically install Docker Engine and Docker Compose V2.
2. Select and configure storage mounts (SSD for databases, HDD for media).
3. Select which stacks to deploy (Media, Nextcloud, Immich, Storage, Utilities, Dashboards).
4. Auto-generate your local environment secrets (`.env`).

---

## Service Directory & Ports

### 🎬 Media & Streaming Suite
`media/docker-compose.yml`

| Service | Container | Port | Description |
|---|---|---|---|
| [Jellyfin](https://jellyfin.org) | `media_jellyfin` | `8096` | Media streaming server (movies, TV, music) |
| [qBittorrent](https://www.qbittorrent.org) | `media_qbittorrent` | `8085` | BitTorrent client with web UI |
| [Radarr](https://radarr.video) | `media_radarr` | `7878` | Automated movie download manager |
| [Sonarr](https://sonarr.tv) | `media_sonarr` | `8989` | Automated TV show download manager |
| [Prowlarr](https://prowlarr.com) | `media_prowlarr` | `9696` | Indexer manager for Radarr & Sonarr |
| [Flaresolverr](https://github.com/FlareSolverr/FlareSolverr) | `media_flaresolverr` | — | Cloudflare bypass proxy for indexers |
| [Jellyseerr](https://github.com/Fallenbagel/jellyseerr) | `media_jellyseerr` | `5055` | Content request portal for users |
| [Bazarr](https://www.bazarr.media) | `media_bazarr` | `6767` | Automatic subtitle downloader |
| [Navidrome](https://www.navidrome.org) | `media_navidrome` | `4533` | Self-hosted music server (Subsonic API) |
| [MeTube](https://github.com/alexta69/metube) | `media_metube` | `8087` | yt-dlp web UI for YouTube downloads |

> **Note:** Jellyfin is configured with Intel QuickSync / VAAPI hardware acceleration via `/dev/dri`. Disable the `devices` block if your server has no iGPU.

---

### ☁️ Personal Cloud & Backup Suite
`nextcloud/docker-compose.yml`

| Service | Container | Port | Description |
|---|---|---|---|
| [Nextcloud](https://nextcloud.com) | `nextcloud_app` | `8080` | Self-hosted cloud drive (Google Drive replacement) |
| Nextcloud Cron | `nextcloud_cron` | — | Background job scheduler for Nextcloud |
| [PostgreSQL 16](https://www.postgresql.org) | `nextcloud_postgres` | — | Database backend for Nextcloud |

> Nextcloud is connected to the shared Redis instance from the Utility stack to reduce memory overhead.

---

### 📸 Photo Backup Suite
`immich/docker-compose.yml`

| Service | Container | Port | Description |
|---|---|---|---|
| [Immich Server](https://immich.app) | `immich_server` | `2283` | Photo/video backup & management (Google Photos replacement) |
| Immich ML | `immich_machine_learning` | — | Face recognition, CLIP search, object classification |
| Valkey (Redis) | `immich_redis` | — | In-memory cache for Immich |
| PostgreSQL + pgvecto.rs | `immich_postgres` | — | Vector-capable database for Immich ML search |

> Immich is configured with Intel GPU hardware transcoding via `hwaccel.transcoding.yml`. Remove the `extends` block if not needed.

---

### 🗄️ Storage Suite
`storage/docker-compose.yml`

| Service | Container | Port | Description |
|---|---|---|---|
| [FileBrowser](https://filebrowser.org) | `storage_filebrowser` | `8082` | Web-based file manager for your media drives |
| [Kopia](https://kopia.io) | `storage_kopia` | `51515` | Fast, encrypted, deduplicated backup engine |
| [Backrest](https://github.com/garethgeorge/backrest) | `storage_backrest` | `9898` | Web UI and scheduler for Restic backups |

---

### 🛠️ Utility & Administration Suite
`utility/docker-compose.yml`

| Service | Container | Port | Description |
|---|---|---|---|
| [Vaultwarden](https://github.com/dani-garcia/vaultwarden) | `utility_vaultwarden` | `8086` | Bitwarden-compatible password manager |
| [Stirling-PDF](https://github.com/Stirling-Tools/Stirling-PDF) | `utility_stirling_pdf` | `8083` | PDF processing: split, merge, OCR, compress |
| [IT-Tools](https://it-tools.tech) | `utility_it_tools` | `8084` | Developer utilities: encoders, converters, regex |
| [Uptime Kuma](https://github.com/louislam/uptime-kuma) | `utility_uptime_kuma` | `3001` | Service monitoring & downtime alerts |
| [Syncthing](https://syncthing.net) | `utility_syncthing` | `8384` | Peer-to-peer file sync across devices |
| [Pairdrop](https://pairdrop.net) | `utility_pairdrop` | `3010` | LAN file sharing (AirDrop for any device) |
| [Paperless-ngx](https://docs.paperless-ngx.com) | `utility_paperless_web` | `8010` | Document scanning, OCR, and archiving |
| Paperless Redis | `utility_paperless_redis` | — | Shared Redis cache (also used by Nextcloud) |
| [Radicale](https://radicale.org) | `utility_radicale` | `5232` | CalDAV/CardDAV server (calendar & contacts sync) |
| [Baikal](https://sabre.io/baikal/) | `utility_baikal` | `8088` | Alternative CalDAV/CardDAV server |
| [Cronicle](https://github.com/jhuckaby/Cronicle) | `utility_cronicle` | `3012` | Cron job scheduler with web UI |
| [Ofelia](https://github.com/mcuadros/ofelia) | `utility_ofelia` | — | Docker-native job scheduler |

---

### 📊 Dashboard Suites
`homepage/docker-compose.yml` & `homarr/docker-compose.yml`

| Service | Container | Port | Description |
|---|---|---|---|
| [Homepage](https://gethomepage.dev) | `dashboard_homepage` | `80` | Live metrics dashboard (bound to root port) |
| [Homarr](https://homarr.dev) | `dashboard_homarr` | `8081` | Modern server landing dashboard portal |

> Homepage reads live container metrics via the Docker socket and is configured via `appdata/homepage/`.

---

## Configuration Reference (.env)

All stacks share a single `.env` file in the project root. It is auto-generated and managed by the WebUI — you rarely need to edit it manually.

| Variable | Default | Description |
|---|---|---|
| `TZ` | `Etc/UTC` | Timezone for all containers (e.g. `Asia/Kolkata`) |
| `PUID` | `1000` | User ID that owns media files |
| `PGID` | `1000` | Group ID that owns media files |
| `SERVER_IP` | — | Local IP of your server (e.g. `192.168.1.10`) |
| `SYSTEM_DATA_DIR` | `./appdata` | Where all service config data is stored |
| `MEDIA_DIR` | `/mnt/hdd/media` | Root path of your media drive |
| `UPLOAD_LOCATION` | `/mnt/hdd/immich/photos` | Immich photo upload destination |
| `NEXTCLOUD_DATA_LOCATION` | `/mnt/hdd/nextcloud/data` | Nextcloud user data directory |
| `DB_DATA_LOCATION` | `./appdata/immich/postgres` | Immich database storage path |
| `GITHUB_REPO` | — | Your GitHub repo for config backups |
| `GITHUB_TOKEN` | — | GitHub personal access token for git push/pull |
| `HOMEPAGE_VAR_QBITTORRENT_PASSWORD` | — | qBittorrent WebUI password (for Homepage metrics) |
| `HOMEPAGE_VAR_PAPERLESS_USERNAME` | — | Paperless username (for Homepage metrics) |
| `HOMEPAGE_VAR_PAPERLESS_PASSWORD` | — | Paperless password (for Homepage metrics) |
| `HOMEPAGE_VAR_IMMICH_API_KEY` | — | Immich API key (for Homepage metrics) |

> `.env` is listed in `.gitignore` and never committed to version control. Secrets stay on your machine.

---

## setup.sh CLI Reference

`setup.sh` is the core management utility of the Homeserver configuration suite. You run it directly from your terminal to install, configure, update, and manage all containers and host systems.

```bash
# First-time interactive setup
sudo ./setup.sh

# Non-interactive / scripted actions
sudo ./setup.sh --install-docker                  # Install Docker Engine & Compose V2
sudo ./setup.sh --update <services>                # Pull & redeploy selected services (e.g., 'all' or 'media_jellyfin')
sudo ./setup.sh --restart <services>              # Restart selected containers
sudo ./setup.sh --reconfigure <services>          # Recreate containers applying latest configuration
sudo ./setup.sh --nuke <services>                  # Tear down containers and wipe their local configurations
sudo ./setup.sh --prune                           # Prune unused Docker images, containers, networks, and volumes
sudo ./setup.sh --tailscale                       # Deploy and authenticate Tailscale VPN
sudo ./setup.sh --install-samba                   # Install Samba daemon and Cockpit administration GUI
sudo ./setup.sh --samba-info                      # Retrieve configured Samba shares and active users
sudo ./setup.sh --samba-add-user <user> <pass>    # Add a user to the Samba registry
sudo ./setup.sh --samba-remove-user <user>        # Delete a Samba user
sudo ./setup.sh --samba-add-share <name> <path>   # Register a new folder share in smb.conf
sudo ./setup.sh --samba-remove-share <name>       # Delete a share from smb.conf
sudo ./setup.sh --sys-maintenance                 # Run OS upgrades and clean package caches
sudo ./setup.sh --backup                          # Compress and archive .env and appdata/ configs
sudo ./setup.sh --git-push                        # Commit and push configs to GITHUB_REPO
sudo ./setup.sh --sync                            # Sync latest configs from GITHUB_REPO zipball
sudo ./setup.sh --check-updates                   # Check for newer tags of running Docker images
sudo ./setup.sh --set-static-ip <iface> <ip> <gw> <dns1> <dns2>  # Configure static IP via Netplan
sudo ./setup.sh --set-dhcp <iface>                # Revert interface to DHCP auto configuration
sudo ./setup.sh --schedule-power <shutdown_time> <shutdown_days> <wakeup_time> <wakeup_days> <enable_shutdown> <enable_wakeup> # Configure auto power scheduler
```

---

## Directory Structure

The project directory structure is modular and separates frontend assets, backend router, and compose suites:

```
HomeServerConfiguration/
│
├── bootstrap.sh              # One-command installer (downloads code and runs setup)
├── setup.sh                  # Core bash orchestrator (handles all system and docker actions)
├── configure_services.py     # Python config compiler
├── configure_homepage.sh     # Homepage dashboard config writer
├── docker-compose.yml        # Shared internal networks definition
├── .env                      # Global environment and secrets configuration (gitignored)
├── .gitignore
│
├── media/                    # 🎬 Media suite docker-compose
├── immich/                   # 📸 Photo backup suite docker-compose
├── nextcloud/                # ☁️ Cloud drive suite docker-compose
├── storage/                  # 🗄️ Storage management suite docker-compose
├── utility/                  # 🛠️ Utility & admin suite docker-compose
├── homepage/                 # 📊 Homepage landing dashboard docker-compose
├── homarr/                   # 📊 Homarr landing dashboard docker-compose
│
└── appdata/                  # Services configuration directories (gitignored)
    ├── homepage/             # Config files for the gethomepage dashboard (committed)
    └── ...                   # Application DBs, configuration files, and state data
```

---

## Hardware Recommendations

| Component | Minimum | Recommended |
|---|---|---|
| CPU | Intel Core i3 (8th gen+) | Intel Core i5/i7 with QuickSync iGPU |
| RAM | 8 GB | 16–32 GB |
| Boot drive | 120 GB SSD | 256 GB SSD |
| Media storage | 2 TB HDD | 4–8 TB HDD (or dedicated storage array) |
| OS | Ubuntu Server 22.04 LTS | Ubuntu Server 24.04 LTS |
| Network | 100 Mbps LAN | Gigabit LAN |

> **Hardware Accel Tip:** An Intel iGPU (8th gen+) enables hardware-accelerated transcoding in both Jellyfin and Immich via QuickSync/VAAPI with zero configuration.

---

## Updating Services

All container updates are managed through the WebUI under **Check & Pull Updates** or **Selective Update**. This pulls the latest image tag for each selected service, stops the old container, and restarts it with identical configurations.

To update everything at once from the terminal:

```bash
sudo ./setup.sh --update all
```

---

## Backing Up

The WebUI **Backup Configurations** action archives all `appdata/` config directories and the `.env` file. The **Push Configs to Git** action commits and pushes the project (excluding secrets) to your GitHub repository for version control.

To restore on a new machine: bootstrap ➔ git pull ➔ redeploy.

```bash
# Full restore workflow
curl -fsSL https://raw.githubusercontent.com/TravancoreTech/HomeServerConfiguration/main/bootstrap.sh | sudo bash
# Then in WebUI: Fetch Configs from Git -> Install (From scratch)
```

---

## Remote Access

[Tailscale](https://tailscale.com) is built into the stack. Once configured (via **Configure Tailscale VPN** in the WebUI), all your services are accessible from anywhere using your Tailscale IP — without opening any ports on your router.

---

*Built for personal use. Contributions and issues welcome.*
