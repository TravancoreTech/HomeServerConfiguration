#!/usr/bin/env python3
import sys
import os
import time
import urllib.request
import urllib.error
import json
import xml.etree.ElementTree as ET
import argparse

# Text Colors
GREEN = '\033[0;32m'
BLUE = '\033[0;34m'
YELLOW = '\033[1;33m'
RED = '\033[0;31m'
NC = '\033[0m'

def log(msg, color=NC):
    print(f"{color}{msg}{NC}")

def get_api_key(app_name):
    paths = [
        f"appdata/{app_name.lower()}/config.xml",
        f"appdata/{app_name.capitalize()}/config.xml"
    ]
    for path in paths:
        if os.path.exists(path):
            try:
                tree = ET.parse(path)
                root = tree.getroot()
                apikey_el = root.find("ApiKey")
                if apikey_el is not None and apikey_el.text:
                    return apikey_el.text
            except Exception as e:
                log(f"Error parsing {path}: {e}", RED)
    return None

def wait_for_service(name, url, timeout=90):
    log(f"Waiting for {name} to be ready at {url}...", BLUE)
    start_time = time.time()
    while time.time() - start_time < timeout:
        try:
            with urllib.request.urlopen(url, timeout=5) as response:
                return True
        except urllib.error.HTTPError as e:
            # HTTP Error means port is listening and responding (even if 401/403/etc)
            return True
        except Exception:
            time.sleep(2)
    log(f"Timeout waiting for {name} to start.", RED)
    return False

def make_api_request(url, method="GET", data=None, api_key=None):
    headers = {
        "Content-Type": "application/json"
    }
    if api_key:
        headers["X-Api-Key"] = api_key
    
    json_data = None
    if data is not None:
        json_data = json.dumps(data).encode('utf-8')
        
    req = urllib.request.Request(url, data=json_data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req) as res:
            res_data = res.read().decode('utf-8')
            return json.loads(res_data) if res_data else {}
    except urllib.error.HTTPError as e:
        err_msg = e.read().decode('utf-8')
        log(f"API Error {e.code} on {method} {url}: {err_msg}", RED)
        raise e
    except Exception as e:
        log(f"Error connecting to {url}: {e}", RED)
        raise e

def configure_auth(app_name, port, api_key, api_version="v3"):
    log(f"Configuring authentication for {app_name}...", BLUE)
    url = f"http://localhost:{port}/api/{api_version}/config/host"
    try:
        host_config = make_api_request(url, "GET", api_key=api_key)
        
        # Check if already configured
        if host_config.get("authenticationMethod") == "Forms" and host_config.get("username") == "admin":
            log(f"Authentication already configured for {app_name}.", GREEN)
            return True
            
        host_config["authenticationMethod"] = "Forms"
        host_config["username"] = "admin"
        host_config["password"] = "admin"
        
        make_api_request(url, "PUT", data=host_config, api_key=api_key)
        log(f"✔ Successfully set login for {app_name} to admin/admin.", GREEN)
        return True
    except Exception as e:
        log(f"Failed to configure auth for {app_name}: {e}", RED)
        return False

def configure_download_client(app_name, port, api_key):
    log(f"Configuring qBittorrent download client in {app_name}...", BLUE)
    url_list = f"http://localhost:{port}/api/v3/downloadclient"
    url_schema = f"http://localhost:{port}/api/v3/downloadclient/schema"
    try:
        clients = make_api_request(url_list, "GET", api_key=api_key)
        for client in clients:
            if client.get("name") == "qBittorrent":
                log(f"qBittorrent client already exists in {app_name}.", GREEN)
                return True
                
        schemas = make_api_request(url_schema, "GET", api_key=api_key)
        qb_schema = next((s for s in schemas if s.get("implementation") == "QBittorrent"), None)
        if not qb_schema:
            log(f"Could not find QBittorrent implementation in {app_name} download client schemas.", RED)
            return False
            
        for field in qb_schema.get("fields", []):
            name = field.get("name")
            if name == "host":
                field["value"] = "media_qbittorrent"
            elif name == "port":
                field["value"] = 8085
            elif name == "username":
                field["value"] = "admin"
            elif name == "password":
                field["value"] = "adminadmin"
            elif name == "category":
                field["value"] = app_name.lower()
                
        qb_schema["name"] = "qBittorrent"
        qb_schema["enable"] = True
        if "id" in qb_schema:
            del qb_schema["id"]
            
        make_api_request(url_list, "POST", data=qb_schema, api_key=api_key)
        log(f"✔ Successfully configured qBittorrent download client in {app_name}.", GREEN)
        return True
    except Exception as e:
        log(f"Failed to configure qBittorrent in {app_name}: {e}", RED)
        return False

def configure_prowlarr_apps(prowlarr_key, sonarr_key, radarr_key):
    log("Configuring Sonarr and Radarr connections in Prowlarr...", BLUE)
    url_list = "http://localhost:9696/api/v1/applications"
    url_schema = "http://localhost:9696/api/v1/applications/schema"
    try:
        apps = make_api_request(url_list, "GET", api_key=prowlarr_key)
        existing_names = [a.get("name") for a in apps]
        
        schemas = make_api_request(url_schema, "GET", api_key=prowlarr_key)
        
        # 1. Add Sonarr
        if "Sonarr" in existing_names:
            log("Sonarr application already exists in Prowlarr.", GREEN)
        elif sonarr_key:
            sonarr_schema = next((s for s in schemas if s.get("implementation") == "Sonarr"), None)
            if sonarr_schema:
                for field in sonarr_schema.get("fields", []):
                    name = field.get("name")
                    if name == "baseUrl":
                        field["value"] = "http://media_sonarr:8989"
                    elif name == "apiKey":
                        field["value"] = sonarr_key
                    elif name == "prowlarrUrl":
                        field["value"] = "http://media_prowlarr:9696"
                    elif name == "syncLevel":
                        field["value"] = "full"
                sonarr_schema["name"] = "Sonarr"
                sonarr_schema["enable"] = True
                if "id" in sonarr_schema:
                    del sonarr_schema["id"]
                make_api_request(url_list, "POST", data=sonarr_schema, api_key=prowlarr_key)
                log("✔ Successfully linked Sonarr in Prowlarr.", GREEN)
                
        # 2. Add Radarr
        if "Radarr" in existing_names:
            log("Radarr application already exists in Prowlarr.", GREEN)
        elif radarr_key:
            radarr_schema = next((s for s in schemas if s.get("implementation") == "Radarr"), None)
            if radarr_schema:
                for field in radarr_schema.get("fields", []):
                    name = field.get("name")
                    if name == "baseUrl":
                        field["value"] = "http://media_radarr:7878"
                    elif name == "apiKey":
                        field["value"] = radarr_key
                    elif name == "prowlarrUrl":
                        field["value"] = "http://media_prowlarr:9696"
                    elif name == "syncLevel":
                        field["value"] = "full"
                radarr_schema["name"] = "Radarr"
                radarr_schema["enable"] = True
                if "id" in radarr_schema:
                    del radarr_schema["id"]
                make_api_request(url_list, "POST", data=radarr_schema, api_key=prowlarr_key)
                log("✔ Successfully linked Radarr in Prowlarr.", GREEN)
    except Exception as e:
        log(f"Failed to configure Prowlarr applications: {e}", RED)

def configure_prowlarr_indexer(prowlarr_key, server_ip):
    log("Configuring TrackerSync Torznab indexer in Prowlarr...", BLUE)
    url_list = "http://localhost:9696/api/v1/indexer"
    url_schema = "http://localhost:9696/api/v1/indexer/schema"
    try:
        indexers = make_api_request(url_list, "GET", api_key=prowlarr_key)
        for indexer in indexers:
            if indexer.get("name") == "TrackerSync":
                log("TrackerSync indexer already exists in Prowlarr.", GREEN)
                return True
                
        schemas = make_api_request(url_schema, "GET", api_key=prowlarr_key)
        torznab_schema = next((s for s in schemas if s.get("implementation") == "Torznab"), None)
        if not torznab_schema:
            log("Could not find Torznab implementation in Prowlarr indexer schemas.", RED)
            return False
            
        for field in torznab_schema.get("fields", []):
            name = field.get("name")
            if name == "baseUrl":
                field["value"] = f"http://{server_ip}:3000/torznab"
            elif name == "apiKey":
                field["value"] = "none"
                
        torznab_schema["name"] = "TrackerSync"
        torznab_schema["enable"] = True
        if "id" in torznab_schema:
            del torznab_schema["id"]
            
        make_api_request(url_list, "POST", data=torznab_schema, api_key=prowlarr_key)
        log("✔ Successfully configured TrackerSync Torznab indexer in Prowlarr.", GREEN)
        return True
    except Exception as e:
        log(f"Failed to configure TrackerSync indexer in Prowlarr: {e}", RED)
        return False

def load_server_ip():
    ip = os.environ.get("SERVER_IP")
    if ip:
        return ip
        
    if os.path.exists(".env"):
        with open(".env", "r") as f:
            for line in f:
                if line.startswith("HOMEPAGE_VAR_SERVER_IP="):
                    return line.split("=")[1].strip()
                elif line.startswith("SERVER_IP="):
                    return line.split("=")[1].strip()
    return "127.0.0.1"

def main():
    parser = argparse.ArgumentParser(description="Configure Media Stack Services")
    parser.add_argument("--services", type=str, help="Comma-separated list of services to configure (prowlarr,sonarr,radarr)")
    args = parser.parse_args()
    
    target_services = None
    if args.services:
        target_services = [s.strip().lower() for s in args.services.split(",")]
        
    server_ip = load_server_ip()
    log(f"Loaded SERVER_IP: {server_ip}", BLUE)
    
    # 1. Wait for services to be ready
    services_to_wait = []
    if not target_services or "prowlarr" in target_services:
        services_to_wait.append(("Prowlarr", "http://localhost:9696"))
    if not target_services or "sonarr" in target_services:
        services_to_wait.append(("Sonarr", "http://localhost:8989"))
    if not target_services or "radarr" in target_services:
        services_to_wait.append(("Radarr", "http://localhost:7878"))
        
    for name, url in services_to_wait:
        if not wait_for_service(name, url):
            log(f"Error: {name} is not responding. Skipping its configuration.", RED)
            # Remove it from targets so we don't try to query it
            if target_services:
                if name.lower() in target_services:
                    target_services.remove(name.lower())
            
    # 2. Extract API keys
    prowlarr_key = get_api_key("prowlarr")
    sonarr_key = get_api_key("sonarr")
    radarr_key = get_api_key("radarr")
    
    log(f"Extracted API Keys: Prowlarr={bool(prowlarr_key)}, Sonarr={bool(sonarr_key)}, Radarr={bool(radarr_key)}", BLUE)
    
    # 3. Perform configurations
    # Prowlarr
    if (not target_services or "prowlarr" in target_services) and prowlarr_key:
        configure_auth("Prowlarr", 9696, prowlarr_key, "v1")
        configure_prowlarr_indexer(prowlarr_key, server_ip)
        configure_prowlarr_apps(prowlarr_key, sonarr_key, radarr_key)
        
    # Sonarr
    if (not target_services or "sonarr" in target_services) and sonarr_key:
        configure_auth("Sonarr", 8989, sonarr_key, "v3")
        configure_download_client("Sonarr", 8989, sonarr_key)
        
    # Radarr
    if (not target_services or "radarr" in target_services) and radarr_key:
        configure_auth("Radarr", 7878, radarr_key, "v3")
        configure_download_client("Radarr", 7878, radarr_key)

if __name__ == "__main__":
    main()
