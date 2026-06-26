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

### Step 1 — Bootstrap (gets the Management WebUI running)

This single command installs Node.js, downloads the suite, and starts the WebUI as a system service. It does **not** install Docker or launch any containers — that's done through the WebUI.

**Option A — Short URL (quick)**

```bash
curl -fsSL https://tinyurl.com/22qdg5nm | sudo bash
```

**Option B — Full GitHub URL (recommended if you want to verify the source)**

```bash
# Inspect the script first (always good practice before piping to bash)
curl -fsSL https://raw.githubusercontent.com/arunkarshan/HomeServerConfiguration/main/bootstrap.sh | less

# Then run it once you're satisfied
curl -fsSL https://raw.githubusercontent.com/arunkarshan/HomeServerConfiguration/main/bootstrap.sh | sudo bash
```

> Both URLs point to the exact same script. Option A redirects to Option B via TinyURL.
> If you are security-conscious (and you should be), use Option B so you can see exactly
> what you're running before it executes. The script source is fully readable
> at [bootstrap.sh](bootstrap.sh) in this repository.

What it does:
- Installs `curl`, `unzip`, and **Node.js LTS** via NodeSource
- Downloads the suite as a zip from GitHub (no `git` required)
- Extracts to `/opt/homeserver`
- Creates and enables a **systemd service** (`homeserver-webui`) that survives reboots
- Prints the URL to open in your browser

When it finishes, you'll see:

```
✔ WebUI is live and running!

  Open this in your browser (from your laptop):
  http://192.168.1.x:8888

```

### Step 2 — Open the WebUI

On **your laptop's browser**, navigate to the URL printed above. From here, everything else is managed through the portal — no more terminal needed.

### Step 3 — Install Docker (via WebUI)

In the sidebar, go to **Documentation & Guides → Install Docker Engine**. Click **Install Docker Engine**. The portal runs the official Docker convenience installer and streams live output.

### Step 4 — Configure & Deploy (via WebUI)

Go to **Deploy & Setup → Install (From scratch)**. Fill in your server IP, timezone, user IDs, and storage paths. Select the suites you want and click deploy.

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

### 📊 Dashboard Suite
`dashboard/docker-compose.yml`

| Service | Container | Port | Description |
|---|---|---|---|
| [Homepage](https://gethomepage.dev) | `dashboard_homepage` | `80` | Live metrics dashboard (bound to root port) |
| [Heimdall](https://heimdall.site) | `dashboard_heimdall` | `8081` | Visual app launcher portal |

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

## Management Portal (WebUI)

The WebUI runs at `http://<your-server-ip>:8888`. It is started automatically on boot via systemd.

```
systemctl status homeserver-webui    # check status
systemctl restart homeserver-webui   # restart portal
journalctl -u homeserver-webui -f    # live logs
```

### Sidebar actions

| Section | Action |
|---|---|
| **Deploy & Setup** | Overview Dashboard, First-Time Install, Selective Update, Selective Restart, Check & Pull Updates |
| **Services & VPN** | Configure Tailscale VPN, Configure Samba Share, Configure Static IP, Configure Apps |
| **System & Storage** | Backup Configurations, Push/Fetch Configs to/from Git, Prune Docker Garbage, OS Update |
| **Documentation & Guides** | Install Docker Engine, Suite Reference Guide, App Setup Manuals |

---

## setup.sh CLI Reference

`setup.sh` is the backend engine. The WebUI calls it internally, but it can also be run directly from the terminal for scripting or advanced use.

```bash
# First-time interactive setup
sudo ./setup.sh

# Non-interactive flags (used by WebUI)
sudo ./setup.sh --install-docker          # Install Docker Engine + Compose V2
sudo ./setup.sh --update    <services>    # Pull & redeploy selected services
sudo ./setup.sh --restart   <services>    # Restart selected services
sudo ./setup.sh --reconfigure <services>  # Recreate containers with new config
sudo ./setup.sh --nuke      <services>    # Tear down and wipe selected services
sudo ./setup.sh --prune                   # Remove unused Docker images & volumes
sudo ./setup.sh --tailscale               # Configure & start Tailscale VPN
sudo ./setup.sh --install-samba           # Install and configure Samba shares
sudo ./setup.sh --sys-maintenance         # Run OS update & maintenance
sudo ./setup.sh --backup                  # Backup all config files
sudo ./setup.sh --git-push                # Push configs to GitHub
sudo ./setup.sh --sync                    # Pull latest configs from GitHub
sudo ./setup.sh --check-updates           # Check for new Docker image versions
sudo ./setup.sh --set-static-ip <iface> <ip> <gw> <dns1> <dns2>
sudo ./setup.sh --set-dhcp <iface>
```

---

## Directory Structure

```
HomeServerConfiguration/
│
├── bootstrap.sh              # One-command installer (starts WebUI only)
├── setup.sh                  # Main orchestrator (3000+ lines, all operations)
├── configure_services.py     # Service configuration generator
├── configure_homepage.sh     # Homepage dashboard config writer
├── docker-compose.yml        # Root-level shared network definition
├── .env                      # Active configuration (gitignored)
├── .gitignore
│
├── webui/                    # Management portal (Node.js)
│   ├── index.html            # Single-page application
│   └── server.js             # Express-style HTTP + SSE server
│
├── media/                    # 🎬 Media suite
│   └── docker-compose.yml
│
├── immich/                   # 📸 Photo backup suite
│   ├── docker-compose.yml
│   └── hwaccel.transcoding.yml
│
├── nextcloud/                # ☁️ Cloud drive suite
│   └── docker-compose.yml
│
├── storage/                  # 🗄️ Storage management suite
│   └── docker-compose.yml
│
├── utility/                  # 🛠️ Utility & admin suite
│   └── docker-compose.yml
│
├── dashboard/                # 📊 Dashboard suite
│   └── docker-compose.yml
│
└── appdata/                  # Runtime config data (gitignored, except homepage)
    ├── homepage/             # Homepage dashboard YAML configs (committed)
    └── ...                   # All other service configs (local only)
```

---

## Hardware Recommendations

| Component | Minimum | Recommended |
|---|---|---|
| CPU | Intel Core i3 (8th gen+) | Intel Core i5/i7 with QuickSync iGPU |
| RAM | 8 GB | 16–32 GB |
| Boot drive | 120 GB SSD | 256 GB SSD |
| Media storage | 2 TB HDD | 4–8 TB HDD (or NAS) |
| OS | Ubuntu Server 22.04 LTS | Ubuntu Server 24.04 LTS |
| Network | 100 Mbps LAN | Gigabit LAN |

> An Intel iGPU (8th gen+) enables hardware-accelerated transcoding in both Jellyfin and Immich via VAAPI/QuickSync with zero additional setup.

---

## Updating Services

All container updates are managed through the WebUI under **Check & Pull Updates** or **Selective Update**. This pulls the latest image for each selected service, stops the old container, and restarts it.

To update everything at once from the terminal:

```bash
sudo ./setup.sh --update all
```

---

## Backing Up

The WebUI **Backup Configurations** action archives all `appdata/` config directories and the `.env` file. The **Push Configs to Git** action commits and pushes the project (excluding secrets) to your GitHub repository for version control.

To restore on a new machine: bootstrap → git pull → redeploy.

```bash
# Full restore workflow
curl -fsSL https://raw.githubusercontent.com/arunkarshan/HomeServerConfiguration/main/bootstrap.sh | sudo bash
# Then in WebUI: Fetch Configs from Git → Install (From scratch)
```

---

## Remote Access

[Tailscale](https://tailscale.com) is built into the stack. Once configured (via **Configure Tailscale VPN** in the WebUI), all your services are accessible from anywhere using your Tailscale IP — without opening any ports on your router.

---

*Built for personal use. Contributions and issues welcome.*
