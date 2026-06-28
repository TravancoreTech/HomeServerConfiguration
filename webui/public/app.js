    const SERVICES_LIST = [
      "jellyfin", "qbittorrent", "radarr", "sonarr", "prowlarr", "flaresolverr", 
      "jellyseerr", "bazarr", "navidrome", "metube", "media-local-tracker", "torrent-generator",
      "nextcloud-app", "nextcloud-cron", "nextcloud-db",
      "immich-server", "immich-machine-learning", "redis", "database",
      "vaultwarden", "stirling-pdf", "it-tools", "uptime-kuma", "syncthing", "pairdrop",
      "paperless-redis", "paperless-web", "radicale", "baikal", "cronicle", "ofelia", "tailscale"
    ].sort();

    const SUITE_GROUPS = {
      media: ["jellyfin", "qbittorrent", "radarr", "sonarr", "prowlarr", "flaresolverr", "jellyseerr", "bazarr", "navidrome", "metube", "media-local-tracker", "torrent-generator"],
      cloud: ["nextcloud-app", "nextcloud-cron", "nextcloud-db", "immich-server", "immich-machine-learning", "redis", "database"],
      utility: ["vaultwarden", "stirling-pdf", "it-tools", "uptime-kuma", "syncthing", "pairdrop", "paperless-redis", "paperless-web", "radicale", "baikal", "cronicle", "ofelia", "tailscale"]
    };

    let cachedConfig = {};
    let activeSSE = null;
    let logsSSE = null;
    let logsPaused = false;
    let currentLogContainer = '';

    // Move shared config flow to active tab
    function moveSharedConfig(targetPaneId) {
      const sharedConfig = document.getElementById('shared-config-flow');
      const targetContainer = document.getElementById(`${targetPaneId}-config-container`);
      if (sharedConfig && targetContainer) {
        targetContainer.appendChild(sharedConfig);
        sharedConfig.style.display = 'block';
      }
    }

    // Dynamic visibility of contextual config panels based on checkbox state
    function updateContextualConfigVisibility(prefix) {
      const hasImmich = [
        "immich-server", "immich-machine-learning", "redis", "database"
      ].some(svc => {
        const cb = document.getElementById(`cb-${prefix}-${svc}`);
        return cb && cb.checked;
      });

      const hasNextcloud = [
        "nextcloud-app", "nextcloud-cron", "nextcloud-db"
      ].some(svc => {
        const cb = document.getElementById(`cb-${prefix}-${svc}`);
        return cb && cb.checked;
      });

      const tailscaleCb = document.getElementById(`cb-${prefix}-tailscale`);
      const hasTailscale = tailscaleCb && tailscaleCb.checked;

      const immichCard = document.getElementById('context-immich-card');
      const nextcloudCard = document.getElementById('context-nextcloud-card');
      const tailscaleCard = document.getElementById('context-tailscale-card');

      if (immichCard) immichCard.style.display = hasImmich ? 'block' : 'none';
      if (nextcloudCard) nextcloudCard.style.display = hasNextcloud ? 'block' : 'none';
      if (tailscaleCard) tailscaleCard.style.display = hasTailscale ? 'block' : 'none';
    }

    // Switch between guided task panels
    function triggerJourney(paneId) {
      // Deactivate active menu highlights
      document.querySelectorAll('.menu-item').forEach(btn => btn.classList.remove('active'));
      // Hide active panes
      document.querySelectorAll('.journey-pane').forEach(pane => pane.classList.remove('active'));

      // Highlight target menu button
      const targetBtn = document.getElementById('btn-' + paneId);
      if (targetBtn) targetBtn.classList.add('active');

      // Show target panel
      const targetPane = document.getElementById('journey-' + paneId);
      if (targetPane) targetPane.classList.add('active');

      // Hide terminal if transitioning back to Dashboard Overview
      if (paneId === 'dashboard') {
        document.getElementById('terminal-pane').style.display = 'none';
      }

      // If switching away from logs, close log stream
      if (paneId !== 'logs' && logsSSE) {
        logsSSE.close();
        logsSSE = null;
      }

      // Move shared config flow container
      const sharedConfig = document.getElementById('shared-config-flow');
      if (sharedConfig) {
        if (paneId === 'update' || paneId === 'install') {
          moveSharedConfig(paneId);
          updateContextualConfigVisibility(paneId);
        } else {
          const hiddenHolder = document.getElementById('hidden-config-holder');
          if (hiddenHolder) hiddenHolder.appendChild(sharedConfig);
          sharedConfig.style.display = 'none';
        }
      }

      // Load Samba State if needed
      if (paneId === 'samba') {
        loadSambaState();
      }

      // Load Netplan State if needed
      if (paneId === 'netplan') {
        loadNetplanState();
      }

      // Load App Configuration State if needed
      if (paneId === 'app-config') {
        loadAppConfigState();
      }

      // Load Docker containers list if needed
      if (paneId === 'docker') {
        fetchStatus();
      }

      // Load Consolidated System state if needed
      if (paneId === 'system') {
        switchSystemTab('vitals');
        fetchSystemStats();
        loadNetplanState();
        loadPowerScheduleState();
      }

      // Reset docker-install console state on re-entry
      if (paneId === 'docker-install') {
        const statusEl = document.getElementById('docker-install-status');
        if (statusEl) statusEl.textContent = '';
      }
    }

    // Toggle forms accordion sections
    function toggleFormSection(header) {
      const body = header.nextElementSibling;
      const arrow = header.querySelector('span:last-child');
      if (body.style.display === 'none') {
        body.style.display = 'grid';
        arrow.textContent = '▾';
      } else {
        body.style.display = 'none';
        arrow.textContent = '▸';
      }
    }

    // Toggle mount fields visibility
    function toggleMountFields(checked) {
      document.querySelectorAll('.mount-field').forEach(el => {
        el.style.display = checked ? 'grid' : 'none';
      });
    }

    // Toggle dashboard config
    function toggleDashboardWidgetConfig() {
      const el = document.getElementById('dashboard-widget-config');
      el.style.display = el.style.display === 'none' ? 'block' : 'none';
    }

    function toggleVolumeSettingsConfig() {
      const el = document.getElementById('dashboard-volumes-config');
      el.style.display = el.style.display === 'none' ? 'block' : 'none';
    }

    async function applyCustomVolumeSettings() {
      const jellyfinExtra = document.getElementById('volume_JELLYFIN_EXTRA_DIR').value.trim();
      const photoBackup = document.getElementById('volume_PHOTO_BACKUP_LOCATION').value.trim();
      const uploadLoc = document.getElementById('volume_UPLOAD_LOCATION').value.trim();
      const nextcloudLoc = document.getElementById('volume_NEXTCLOUD_DATA_LOCATION').value.trim();

      const config = {
        JELLYFIN_EXTRA_DIR: jellyfinExtra,
        PHOTO_BACKUP_LOCATION: photoBackup,
        UPLOAD_LOCATION: uploadLoc,
        NEXTCLOUD_DATA_LOCATION: nextcloudLoc
      };

      const servicesToRecreate = [];
      if (jellyfinExtra !== (cachedConfig.JELLYFIN_EXTRA_DIR || '')) {
        servicesToRecreate.push('jellyfin');
      }
      if (photoBackup !== (cachedConfig.PHOTO_BACKUP_LOCATION || '') || uploadLoc !== (cachedConfig.UPLOAD_LOCATION || '')) {
        servicesToRecreate.push('immich-server');
      }
      if (nextcloudLoc !== (cachedConfig.NEXTCLOUD_DATA_LOCATION || '')) {
        servicesToRecreate.push('nextcloud-app');
      }

      if (servicesToRecreate.length > 0) {
        const confirmMsg = `The following services need to be reconfigured and restarted for paths to take effect: ${servicesToRecreate.join(', ')}. Proceed?`;
        if (!confirm(confirmMsg)) return;
      }

      try {
        const res = await fetch('/api/config', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(config)
        });
        const data = await res.json();
        if (data.success) {
          cachedConfig = { ...cachedConfig, ...config };
          if (servicesToRecreate.length > 0) {
            toggleVolumeSettingsConfig();
            triggerJourney('dashboard');
            initConsoleLogs(`Reconfiguring services: ${servicesToRecreate.join(', ')}`, `/api/run?action=reconfigure&services=${servicesToRecreate.join(',')}`);
          } else {
            alert('Volume settings saved successfully. No container restarts needed.');
            toggleVolumeSettingsConfig();
            loadConfig();
          }
        } else {
          alert('Failed to save settings: ' + data.error);
        }
      } catch (err) {
        alert('Error communicating with backend: ' + err.message);
      }
    }

    // Checkbox selections helpers
    function checkAll(val, prefix) {
      document.querySelectorAll(`.cb-${prefix}`).forEach(cb => cb.checked = val);
      // Sync group check boxes
      Object.keys(SUITE_GROUPS).forEach(suiteKey => {
        const groupCb = document.getElementById(`group-cb-${prefix}-${suiteKey}`);
        if (groupCb) {
          groupCb.checked = val;
          groupCb.indeterminate = false;
        }
      });
      if (prefix === 'update' || prefix === 'install') {
        updateContextualConfigVisibility(prefix);
      }
    }

    // Checkbox suite selection helpers
    function checkSuite(suiteName, prefix) {
      checkAll(false, prefix);
      const list = SUITE_GROUPS[suiteName] || [];
      list.forEach(svc => {
        const cb = document.getElementById(`cb-${prefix}-${svc}`);
        if (cb) cb.checked = true;
      });
      // Sync group check boxes
      Object.keys(SUITE_GROUPS).forEach(suiteKey => {
        syncGroupCheckboxState(prefix, suiteKey);
      });
      if (prefix === 'update' || prefix === 'install') {
        updateContextualConfigVisibility(prefix);
      }
    }

    function toggleGroupCheckBoxes(groupCb, suiteKey, prefix) {
      const isChecked = groupCb.checked;
      const services = SUITE_GROUPS[suiteKey] || [];
      services.forEach(svc => {
        const cb = document.getElementById(`cb-${prefix}-${svc}`);
        if (cb) {
          cb.checked = isChecked;
        }
      });
      if (prefix === 'update' || prefix === 'install') {
        updateContextualConfigVisibility(prefix);
      }
    }

    function syncGroupCheckboxState(prefix, suiteKey) {
      const services = SUITE_GROUPS[suiteKey] || [];
      const cbs = services.map(svc => document.getElementById(`cb-${prefix}-${svc}`)).filter(Boolean);
      const groupCb = document.getElementById(`group-cb-${prefix}-${suiteKey}`);
      if (groupCb && cbs.length > 0) {
        const allChecked = cbs.every(cb => cb.checked);
        const someChecked = cbs.some(cb => cb.checked);
        groupCb.checked = allChecked;
        groupCb.indeterminate = someChecked && !allChecked;
      }
    }

    function findSuiteKey(serviceName) {
      for (const [suiteKey, list] of Object.entries(SUITE_GROUPS)) {
        if (list.includes(serviceName)) return suiteKey;
      }
      return null;
    }

    // Populate the checkbox grids in the UI dynamically with grouping
    function populateChecklists() {
      const prefixes = ['update', 'restart', 'install'];
      const suiteDisplayNames = {
        media: "🎬 Media Stack Services",
        cloud: "☁️ Cloud & Backup Services",
        utility: "🛠️ System Utility Services"
      };

      prefixes.forEach(prefix => {
        const target = document.getElementById(`${prefix}-checklist-target`);
        if (!target) return;
        target.innerHTML = '';

        for (const [suiteKey, services] of Object.entries(SUITE_GROUPS)) {
          // Create group container
          const groupDiv = document.createElement('div');
          groupDiv.className = 'checklist-group';
          groupDiv.style.marginBottom = '1.25rem';

          // Create group header
          const header = document.createElement('div');
          header.className = 'checklist-group-header';
          header.style.display = 'flex';
          header.style.alignItems = 'center';
          header.style.justifyContent = 'space-between';
          header.style.borderBottom = '1px solid rgba(255,255,255,0.06)';
          header.style.paddingBottom = '0.35rem';
          header.style.marginBottom = '0.65rem';
          header.style.marginTop = '0.5rem';

          const titleWrapper = document.createElement('div');
          titleWrapper.style.display = 'flex';
          titleWrapper.style.alignItems = 'center';
          titleWrapper.style.gap = '0.5rem';

          const groupCb = document.createElement('input');
          groupCb.type = 'checkbox';
          groupCb.id = `group-cb-${prefix}-${suiteKey}`;
          groupCb.className = `group-cb-${prefix}`;
          groupCb.style.width = '15px';
          groupCb.style.height = '15px';
          groupCb.style.accentColor = 'var(--accent-indigo)';
          groupCb.style.cursor = 'pointer';
          groupCb.addEventListener('change', () => {
            toggleGroupCheckBoxes(groupCb, suiteKey, prefix);
          });

          const label = document.createElement('label');
          label.htmlFor = `group-cb-${prefix}-${suiteKey}`;
          label.textContent = suiteDisplayNames[suiteKey] || `${suiteKey} Suite`;
          label.style.fontSize = '0.85rem';
          label.style.fontWeight = '700';
          label.style.color = 'var(--text-highlight)';
          label.style.cursor = 'pointer';

          titleWrapper.appendChild(groupCb);
          titleWrapper.appendChild(label);

          const countBadge = document.createElement('span');
          countBadge.textContent = `${services.length} items`;
          countBadge.style.fontSize = '0.7rem';
          countBadge.style.color = 'var(--text-muted)';
          countBadge.style.background = 'rgba(255,255,255,0.04)';
          countBadge.style.padding = '0.1rem 0.4rem';
          countBadge.style.borderRadius = '10px';

          header.appendChild(titleWrapper);
          header.appendChild(countBadge);
          groupDiv.appendChild(header);

          // Create service grid
          const grid = document.createElement('div');
          grid.className = 'checklist-grid';

          services.forEach(svc => {
            const item = document.createElement('div');
            item.className = 'check-item';
            item.innerHTML = `
              <input type="checkbox" id="cb-${prefix}-${svc}" value="${svc}" class="cb-${prefix}">
              <label for="cb-${prefix}-${svc}">${svc}</label>
            `;

            const input = item.querySelector('input');
            input.addEventListener('change', () => {
              syncGroupCheckboxState(prefix, suiteKey);
              if (prefix === 'update' || prefix === 'install') {
                updateContextualConfigVisibility(prefix);
              }
            });

            grid.appendChild(item);
          });

          groupDiv.appendChild(grid);
          target.appendChild(groupDiv);
        }
      });
    }

    // Helper to get normalized service name for logo images
    function getLogoKey(name) {
      return name.toLowerCase()
        .replace(/^media[-_]/i, '')
        .replace(/^utility[-_]/i, '')
        .replace(/^cloud[-_]/i, '')
        .replace(/^storage[-_]/i, '')
        .replace(/^dashboard[-_]/i, '')
        .replace(/[-_]/g, '_');
    }

    // Classify a container by Broad Type and Actual Group (SOLID/SRP layout)
    function classifyContainer(name) {
      const lower = name.toLowerCase();
      
      // Determine Broad Type
      let broadType = 'General';
      if (lower.startsWith('media_') || lower.startsWith('media-') || SUITE_GROUPS.media.some(k => lower.includes(k))) {
        broadType = 'Media';
      } else if (lower.startsWith('storage_') || lower.startsWith('storage-') || lower.startsWith('nextcloud') || lower.startsWith('immich') || SUITE_GROUPS.cloud.some(k => lower.includes(k))) {
        broadType = 'Storage';
      } else if (lower.startsWith('utility_') || lower.startsWith('utility-') || SUITE_GROUPS.utility.some(k => lower.includes(k))) {
        broadType = 'Utility';
      } else if (lower.startsWith('dashboard_') || lower.startsWith('dashboard-')) {
        broadType = 'Dashboard';
      }

      // Determine Sub Group
      let group = 'General';
      
      if (broadType === 'Media') {
        // Jellyfin / Arr group
        const isArr = ['jellyfin', 'qbittorrent', 'radarr', 'sonarr', 'prowlarr', 'flaresolverr', 'jellyseerr', 'bazarr'].some(k => lower.includes(k));
        if (isArr) {
          group = 'Jellyfin / Arr Group';
        } else {
          group = 'Other Media';
        }
      } else if (broadType === 'Storage') {
        if (lower.includes('immich')) {
          group = 'Immich Group';
        } else if (lower.includes('nextcloud')) {
          group = 'Nextcloud Group';
        } else if (lower.includes('filebrowser') || lower.includes('kopia') || lower.includes('backrest')) {
          group = 'Backup & File Manager';
        }
      } else if (broadType === 'Utility') {
        if (lower.includes('paperless')) {
          group = 'Paperless Group';
        } else if (lower.includes('radicale') || lower.includes('baikal')) {
          group = 'Calendar & Contacts';
        } else if (lower.includes('syncthing') || lower.includes('pairdrop')) {
          group = 'File Sync & Sharing';
        } else if (lower.includes('vaultwarden') || lower.includes('tailscale')) {
          group = 'Security & VPN';
        } else if (['stirling', 'it-tools', 'uptime', 'cronicle', 'ofelia'].some(k => lower.includes(k))) {
          group = 'System & Monitoring';
        }
      } else if (broadType === 'Dashboard') {
        group = 'Dashboard Overview';
      }

      return { broadType, group };
    }

    // Fetch container status and render statuses in sidebar & dashboard
    async function fetchStatus() {
      try {
        const res = await fetch('/api/status');

        // If the server returned an error (e.g. Docker socket permission denied),
        // treat it as daemon-offline — never show the first-time banner.
        if (!res.ok) {
          updateStatusOffline();
          return;
        }

        const data = await res.json();
        const dockerPageGrid = document.getElementById('docker-page-containers-target');
        const firstTimeBanner = document.getElementById('first-time-setup-banner');

        if (dockerPageGrid) dockerPageGrid.innerHTML = '';
        
        // Update Daemon online tags
        const daemonBadge = document.getElementById('docker-page-daemon-badge');
        if (daemonBadge) {
          daemonBadge.className = 'container-status-badge badge-up';
          daemonBadge.textContent = 'Daemon Online';
        }
        document.getElementById('stats-daemon-status').textContent = 'Online';
        document.getElementById('stats-daemon-desc').textContent = 'Daemon running';

        if (!data.containers || Object.keys(data.containers).length === 0) {
          if (dockerPageGrid) dockerPageGrid.innerHTML = '<div style="text-align: center; color: var(--text-muted); font-size: 0.85rem; padding: 1.5rem;">No containers found.</div>';
          document.getElementById('widget-total-count').textContent = '0';
          document.getElementById('widget-running-count').textContent = '0';
          document.getElementById('widget-stopped-count').textContent = '0';
          document.getElementById('widget-error-count').textContent = '0';
          document.getElementById('bulletin-content').innerHTML = 'No service containers deployed yet.';
          updateSidebarStatus('All Good', '0/0 running', 'up');
          if (firstTimeBanner) firstTimeBanner.style.display = 'block';
          return;
        }

        let total = 0;
        let running = 0;
        let stopped = 0;
        let errors = 0;
        let vpnState = 'Offline';
        const stoppedList = [];
        const errorList = [];

        // Build nested group structure: grouped[broadType][group] = []
        const grouped = {};

        Object.entries(data.containers).forEach(([name, status]) => {
          total++;
          const statusLower = status.toLowerCase();
          const isUp = statusLower.includes('up') || statusLower.includes('running');
          
          let isError = false;
          if (statusLower.includes('unhealthy') || statusLower.includes('dead') || (statusLower.includes('exited') && !statusLower.includes('exited (0)'))) {
            isError = true;
          }

          if (isUp) {
            running++;
            if (name.includes('tailscale')) vpnState = 'Active';
          } else if (isError) {
            errors++;
            errorList.push(name);
          } else {
            stopped++;
            stoppedList.push(name);
          }

          const details = getServiceDetails(name);
          const { broadType, group } = classifyContainer(name);

          if (!grouped[broadType]) {
            grouped[broadType] = {};
          }
          if (!grouped[broadType][group]) {
            grouped[broadType][group] = [];
          }
          grouped[broadType][group].push({ name, status, isUp, isError, details });
        });

        // Render in Docker Containers Detailed Page Grid (hierarchical grouping)
        if (dockerPageGrid) {
          const broadTypeOrder = ['Media', 'Storage', 'Utility', 'Dashboard', 'General'];
          const broadTypeIcons = {
            'Media': '🎬',
            'Storage': '🗄️',
            'Utility': '🛠️',
            'Dashboard': '📊',
            'General': '📦'
          };

          const presentBroadTypes = Object.keys(grouped).sort((a, b) => {
            let idxA = broadTypeOrder.indexOf(a);
            let idxB = broadTypeOrder.indexOf(b);
            if (idxA === -1) idxA = 999;
            if (idxB === -1) idxB = 999;
            return idxA - idxB;
          });

          presentBroadTypes.forEach(broadType => {
            // Broad Type Section
            const broadSection = document.createElement('div');
            broadSection.className = 'broad-type-section';
            broadSection.style.cssText = 'margin-bottom: 2rem; padding: 1.25rem; border: 1px solid var(--border-color); border-radius: 12px; background: rgba(255, 255, 255, 0.015);';

            const broadIcon = broadTypeIcons[broadType] || '📦';
            const broadTitle = document.createElement('h3');
            broadTitle.className = 'broad-type-title';
            broadTitle.style.cssText = 'font-family: var(--font-sans); font-size: 1.15rem; font-weight: 700; color: var(--text-primary); margin-top: 0; margin-bottom: 1.25rem; padding-bottom: 0.5rem; border-bottom: 1px solid var(--border-color); display: flex; align-items: center; gap: 0.5rem;';
            broadTitle.innerHTML = `<span>${broadIcon}</span> ${broadType}`;
            broadSection.appendChild(broadTitle);

            // Group sorting
            const groupOrder = ['Jellyfin / Arr Group', 'Immich Group', 'Nextcloud Group', 'Backup & File Manager', 'Paperless Group', 'Calendar & Contacts', 'File Sync & Sharing', 'Security & VPN', 'System & Monitoring', 'Dashboard Overview', 'General'];
            const presentGroups = Object.keys(grouped[broadType]).sort((a, b) => {
              let idxA = groupOrder.indexOf(a);
              let idxB = groupOrder.indexOf(b);
              if (idxA === -1) idxA = 999;
              if (idxB === -1) idxB = 999;
              return idxA - idxB;
            });

            presentGroups.forEach(groupName => {
              const groupSection = document.createElement('div');
              groupSection.className = 'group-section';
              groupSection.style.cssText = 'margin-bottom: 1.25rem;';

              const containers = grouped[broadType][groupName];
              
              const groupTitle = document.createElement('h4');
              groupTitle.className = 'group-title';
              groupTitle.style.cssText = 'font-family: var(--font-sans); font-size: 0.88rem; font-weight: 600; color: var(--text-secondary); margin-top: 0; margin-bottom: 0.65rem; display: flex; align-items: center; gap: 0.35rem;';
              groupTitle.innerHTML = `• ${groupName} <span style="font-size: 0.75rem; color: var(--text-muted); font-weight: normal; margin-left: 0.25rem;">(${containers.length})</span>`;
              groupSection.appendChild(groupTitle);

              const grid = document.createElement('div');
              grid.className = 'dashboard-containers-grid';

              // Sort containers in this group alphabetically
              containers.sort((a, b) => a.name.localeCompare(b.name)).forEach(({ name, status, isUp, isError, details }) => {
                const dbCard = document.createElement('div');
                dbCard.className = 'dashboard-container-card';
                dbCard.style.cssText = 'display: flex; flex-direction: row; align-items: flex-start; padding: 1.25rem; gap: 1rem; border-radius: 12px; min-height: auto; cursor: pointer;';
                dbCard.onclick = (e) => {
                  if (e.target.tagName.toLowerCase() !== 'a') {
                    showContainerDetails(name, status, isUp, details);
                  }
                };
                dbCard.innerHTML = `
                  <div class="service-card-icon" style="font-size: 1.85rem; padding: 0.5rem; background: rgba(255,255,255,0.03); border: 1px solid var(--border-color); border-radius: 10px; display: flex; align-items: center; justify-content: center; width: 46px; height: 46px; flex-shrink: 0; user-select: none; position: relative;">
                    <span class="fallback-emoji" style="display: block;">${details.icon}</span>
                    <img src="/logos/logo_${getLogoKey(name)}.png" onload="this.previousElementSibling.style.display='none'; this.style.display='block';" onerror="this.style.display='none';" style="display: none; width: 100%; height: 100%; object-fit: contain;" />
                  </div>
                  <div style="display: flex; flex-direction: column; flex-grow: 1; min-width: 0;">
                    <div style="display: flex; align-items: center; justify-content: space-between; gap: 0.5rem;">
                      <span class="dashboard-container-name" style="font-weight: 700; color: var(--text-primary); font-size: 0.95rem; white-space: nowrap; overflow: hidden; text-overflow: ellipsis;">${details.name}</span>
                      <span class="status-dot ${isUp ? 'up' : (isError ? 'down' : 'down')}" style="background-color: ${isUp ? 'var(--accent-green)' : (isError ? 'var(--accent-red)' : 'var(--accent-orange)')}; box-shadow: 0 0 6px ${isUp ? 'var(--accent-green)' : (isError ? 'var(--accent-red)' : 'var(--accent-orange)')}; flex-shrink: 0;"></span>
                    </div>
                    <span style="color: var(--text-muted); font-size: 0.75rem; font-family: var(--font-mono); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; margin-top: 0.15rem; margin-bottom: 0.5rem;" title="${name}">${name}</span>
                    <div style="display: flex; align-items: center; justify-content: space-between; font-size: 0.78rem;">
                      <span style="font-weight: 600; color: ${isUp ? 'var(--accent-green)' : (isError ? 'var(--accent-red)' : 'var(--accent-orange)')};">${isUp ? 'Running' : (isError ? 'Error' : 'Stopped')}</span>
                      <a href="javascript:void(0)" onclick="triggerLogs('${name}')" style="color: var(--accent-indigo-text); text-decoration: none; font-weight: 600; display: inline-flex; align-items: center; gap: 0.25rem;">
                        View Log ↗
                      </a>
                    </div>
                  </div>
                `;
                grid.appendChild(dbCard);
              });

              groupSection.appendChild(grid);
              broadSection.appendChild(groupSection);
            });

            dockerPageGrid.appendChild(broadSection);
          });
        }

        // Update home metrics
        document.getElementById('widget-total-count').textContent = total;
        document.getElementById('widget-running-count').textContent = running;
        document.getElementById('widget-stopped-count').textContent = stopped;
        document.getElementById('widget-error-count').textContent = errors;
        document.getElementById('stats-vpn').textContent = vpnState;

        const vpnStatsText = document.getElementById('stats-vpn');
        if (vpnStatsText) {
          vpnStatsText.style.color = (vpnState === 'Active') ? 'var(--accent-green)' : 'var(--accent-red)';
        }

        // Update notice board / bulletin
        const bulletinContent = document.getElementById('bulletin-content');
        const bulletinHeader = document.getElementById('bulletin-header');
        const bulletinCard = document.getElementById('dashboard-notices-bulletin');
        
        if (errors > 0) {
          bulletinCard.style.borderColor = 'rgba(239, 68, 68, 0.2)';
          bulletinCard.style.background = 'rgba(239, 68, 68, 0.02)';
          bulletinHeader.style.color = 'var(--accent-red)';
          bulletinHeader.innerHTML = '⚠️ System Error Alert';
          bulletinContent.innerHTML = `Critical services are in error state! Fix immediately:<br><strong style="color: var(--accent-red);">${errorList.join(', ')}</strong>`;
          updateSidebarStatus('Error', `${errors} failing`, 'down');
        } else if (stopped > 0) {
          bulletinCard.style.borderColor = 'rgba(245, 158, 11, 0.2)';
          bulletinCard.style.background = 'rgba(245, 158, 11, 0.02)';
          bulletinHeader.style.color = 'var(--accent-orange)';
          bulletinHeader.innerHTML = '⚠️ Service Notices';
          bulletinContent.innerHTML = `Some services are currently stopped:<br><strong style="color: var(--accent-orange);">${stoppedList.join(', ')}</strong>`;
          updateSidebarStatus('Warning', `${stopped} stopped`, 'down'); // yellow class fallback
          document.getElementById('sidebar-status-dot').style.backgroundColor = 'var(--accent-orange)';
          document.getElementById('sidebar-status-dot').style.boxShadow = '0 0 6px var(--accent-orange)';
        } else {
          bulletinCard.style.borderColor = 'var(--border-color)';
          bulletinCard.style.background = 'rgba(255,255,255,0.01)';
          bulletinHeader.style.color = 'var(--text-primary)';
          bulletinHeader.innerHTML = '📰 System Status';
          bulletinContent.innerHTML = 'All deployed services are running smoothly. System healthy!';
          updateSidebarStatus('All Good', `${running}/${total} running`, 'up');
        }

        if (firstTimeBanner) firstTimeBanner.style.display = 'none';

      } catch (err) {
        console.error('Failed to query stack status:', err);
        updateStatusOffline();
      } finally {
        fetchSystemStats();
      }
    }

    function updateStatusOffline() {
      const firstTimeBanner = document.getElementById('first-time-setup-banner');
      if (firstTimeBanner) firstTimeBanner.style.display = 'none';
      
      const daemonBadge = document.getElementById('docker-page-daemon-badge');
      if (daemonBadge) {
        daemonBadge.className = 'container-status-badge badge-down';
        daemonBadge.textContent = 'Daemon Offline';
      }

      document.getElementById('stats-daemon-status').textContent = 'Offline';
      document.getElementById('stats-daemon-desc').textContent = 'Daemon unreachable';
      document.getElementById('widget-total-count').textContent = '-';
      document.getElementById('widget-running-count').textContent = '-';
      document.getElementById('widget-stopped-count').textContent = '-';
      document.getElementById('widget-error-count').textContent = '-';
      
      const bulletinContent = document.getElementById('bulletin-content');
      if (bulletinContent) {
        bulletinContent.innerHTML = '<span style="color: var(--accent-red);">⚠️ Docker daemon is offline or unreachable. Check your systemd docker socket.</span>';
      }
      updateSidebarStatus('Error', 'Daemon offline', 'down');
    }

    function updateSidebarStatus(title, desc, stateClass) {
      const dot = document.getElementById('sidebar-status-dot');
      const titleEl = document.getElementById('sidebar-status-title');
      const descEl = document.getElementById('sidebar-status-desc');
      
      if (dot && titleEl && descEl) {
        dot.className = `status-dot ${stateClass}`;
        // reset custom colors from warning check
        dot.style.backgroundColor = '';
        dot.style.boxShadow = '';
        titleEl.textContent = title;
        descEl.textContent = desc;
      }
    }


    // Container Logs Streaming Functions
    function triggerLogs(containerName) {
      triggerJourney('logs');
      initContainerLogs(containerName);
    }

    function initContainerLogs(containerName) {
      const terminal = document.getElementById('logs-terminal-body');
      const titleEl = document.getElementById('logs-header-title');
      
      titleEl.textContent = `Logs: ${containerName}`;
      terminal.innerHTML = `[Connecting to logs stream for ${containerName}...]\n\n`;
      terminal.scrollTop = terminal.scrollHeight;
      logsPaused = false;
      document.getElementById('btn-pause-logs').textContent = 'Pause';

      if (logsSSE) {
        logsSSE.close();
      }

      logsSSE = new EventSource(`/api/logs?service=${containerName}`);

      logsSSE.onmessage = function(e) {
        if (logsPaused) return;
        const line = e.data;
        const span = document.createElement('span');
        span.textContent = line + '\n';
        terminal.appendChild(span);
        terminal.scrollTop = terminal.scrollHeight;
      };

      logsSSE.onerror = function() {
        const span = document.createElement('span');
        span.style.color = 'var(--text-muted)';
        span.textContent = '\n[Log stream disconnected]\n';
        terminal.appendChild(span);
        terminal.scrollTop = terminal.scrollHeight;
        logsSSE.close();
        logsSSE = null;
      };
    }

    function pauseLogs() {
      logsPaused = !logsPaused;
      document.getElementById('btn-pause-logs').textContent = logsPaused ? 'Resume' : 'Pause';
    }

    function clearLogs() {
      document.getElementById('logs-terminal-body').innerHTML = '[Logs console cleared]\n';
    }

    // Samba Sharing Operations Functions
    async function loadSambaState() {
      try {
        const res = await fetch('/api/samba');
        const data = await res.json();
        
        const badge = document.getElementById('samba-status-badge');
        const uninstalledView = document.getElementById('samba-uninstalled-view');
        const installedView = document.getElementById('samba-installed-view');

        if (data.installed) {
          badge.innerHTML = '<span class="container-status-badge badge-up">Installed & Active</span>';
          uninstalledView.style.display = 'none';
          installedView.style.display = 'block';

          // Render users list
          const usersTarget = document.getElementById('samba-users-list-target');
          usersTarget.innerHTML = '';
          if (!data.users || data.users.length === 0) {
            usersTarget.innerHTML = '<tr><td colspan="2" style="text-align: center; color: var(--text-muted); padding: 1.5rem;">No Samba users configured.</td></tr>';
          } else {
            data.users.forEach(username => {
              const tr = document.createElement('tr');
              tr.innerHTML = `
                <td style="font-weight: 500;">${username}</td>
                <td style="text-align: right;">
                  <button class="badge-btn" style="background: rgba(244,63,94,0.1); color: var(--warning-banner-text); border-color: rgba(244,63,94,0.2);" onclick="deleteSambaUser('${username}')">Delete</button>
                </td>
              `;
              usersTarget.appendChild(tr);
            });
          }

          // Render shares list
          const sharesTarget = document.getElementById('samba-shares-list-target');
          sharesTarget.innerHTML = '';
          if (!data.shares || data.shares.length === 0) {
            sharesTarget.innerHTML = '<tr><td colspan="6" style="text-align: center; color: var(--text-muted); padding: 1.5rem;">No shares configured.</td></tr>';
          } else {
            data.shares.forEach(share => {
              const tr = document.createElement('tr');
              tr.innerHTML = `
                <td style="font-weight: 600; color: var(--accent-indigo-text);">[${share.name}]</td>
                <td style="font-family: var(--font-mono); font-size: 0.8rem;">${share.path}</td>
                <td>${share.valid_users || '<span style="color: var(--text-muted);">All Users</span>'}</td>
                <td>${share.guest_ok === 'yes' ? 'Allowed' : 'Denied'}</td>
                <td>${share.read_only === 'yes' ? 'Read-Only' : 'Read/Write'}</td>
                <td style="text-align: right;">
                  <button class="badge-btn" style="background: rgba(244,63,94,0.1); color: var(--warning-banner-text); border-color: rgba(244,63,94,0.2);" onclick="deleteSambaShare('${share.name}')">Delete</button>
                </td>
              `;
              sharesTarget.appendChild(tr);
            });
          }
        } else {
          badge.innerHTML = '<span class="container-status-badge badge-down">Not Installed</span>';
          uninstalledView.style.display = 'block';
          installedView.style.display = 'none';
        }
      } catch (err) {
        console.error('Failed to load Samba state:', err);
      }
    }

    function toggleAddSambaUserForm() {
      const el = document.getElementById('samba-add-user-form');
      el.style.display = el.style.display === 'none' ? 'block' : 'none';
    }

    function toggleAddSambaShareForm() {
      const el = document.getElementById('samba-add-share-form');
      el.style.display = el.style.display === 'none' ? 'block' : 'none';
    }

    async function submitAddSambaUser() {
      const username = document.getElementById('smb_username').value.trim();
      const password = document.getElementById('smb_password').value.trim();
      if (!username || !password) {
        alert('Username and password are required.');
        return;
      }
      try {
        const res = await fetch('/api/samba/action', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action: 'add-user', username, password })
        });
        const data = await res.json();
        if (data.success) {
          alert('Samba user added successfully.');
          document.getElementById('smb_username').value = '';
          document.getElementById('smb_password').value = '';
          toggleAddSambaUserForm();
          loadSambaState();
        } else {
          alert('Failed to add Samba user: ' + data.error);
        }
      } catch (err) {
        alert('Error communicating with backend.');
      }
    }

    async function deleteSambaUser(username) {
      if (!confirm(`Are you sure you want to delete Samba user '${username}'?`)) return;
      try {
        const res = await fetch('/api/samba/action', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action: 'remove-user', username })
        });
        const data = await res.json();
        if (data.success) {
          loadSambaState();
        } else {
          alert('Failed to delete user: ' + data.error);
        }
      } catch (err) {
        alert('Error communicating with backend.');
      }
    }

    async function submitAddSambaShare() {
      const share_name = document.getElementById('smb_share_name').value.trim();
      const share_path = document.getElementById('smb_share_path').value.trim();
      const valid_users = document.getElementById('smb_valid_users').value.trim();
      const read_only = document.getElementById('smb_read_only').value;
      const guest_ok = document.getElementById('smb_guest_ok').value;

      if (!share_name || !share_path) {
        alert('Share name and server path are required.');
        return;
      }
      try {
        const res = await fetch('/api/samba/action', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action: 'add-share', share_name, share_path, valid_users, guest_ok, read_only })
        });
        const data = await res.json();
        if (data.success) {
          alert('Shared folder created successfully.');
          document.getElementById('smb_share_name').value = '';
          document.getElementById('smb_share_path').value = '';
          document.getElementById('smb_valid_users').value = '';
          toggleAddSambaShareForm();
          loadSambaState();
        } else {
          alert('Failed to create share: ' + data.error);
        }
      } catch (err) {
        alert('Error communicating with backend.');
      }
    }

    async function deleteSambaShare(share_name) {
      if (!confirm(`Are you sure you want to delete Samba share '${share_name}'?`)) return;
      try {
        const res = await fetch('/api/samba/action', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action: 'remove-share', share_name })
        });
        const data = await res.json();
        if (data.success) {
          loadSambaState();
        } else {
          alert('Failed to delete share: ' + data.error);
        }
      } catch (err) {
        alert('Error communicating with backend.');
      }
    }

    function installSamba() {
      triggerJourney('dashboard');
      initConsoleLogs('Installing Samba Share Service', '/api/run?action=samba');
    }

    // Netplan Network Configuration functions
    async function loadNetplanState() {
      try {
        const res = await fetch('/api/netplan');
        const data = await res.json();

        // Check if netplan is installed
        const unsupportedBanner = document.getElementById('netplan-unsupported-banner');
        if (unsupportedBanner) {
          unsupportedBanner.style.display = data.installed ? 'none' : 'block';
        }

        // Populating current settings display
        const cur = data.current || {};
        const lblIface = document.getElementById('lbl-netplan-iface');
        const lblMode = document.getElementById('lbl-netplan-mode');
        const lblAddress = document.getElementById('lbl-netplan-address');
        const lblGateway = document.getElementById('lbl-netplan-gateway');
        const lblDns = document.getElementById('lbl-netplan-dns');

        if (lblIface) lblIface.textContent = cur.interface || '-';
        if (lblMode) lblMode.textContent = cur.interface ? (cur.dhcp ? 'Dynamic (DHCP)' : 'Static IP') : '-';
        if (lblAddress) lblAddress.textContent = cur.address || '-';
        if (lblGateway) lblGateway.textContent = cur.gateway || '-';
        if (lblDns) lblDns.textContent = (cur.dns && cur.dns.length > 0) ? cur.dns.join(', ') : '-';

        // Populate interface dropdown selector
        const select = document.getElementById('netplan_iface_select');
        const noIfaceBanner = document.getElementById('netplan-no-iface-banner');
        const applyBtn = document.getElementById('netplan-apply-btn');
        if (select) {
          select.innerHTML = '';
          if (data.interfaces && data.interfaces.length > 0) {
            // Hide error banner, enable apply button
            if (noIfaceBanner) noIfaceBanner.style.display = 'none';
            if (applyBtn) applyBtn.disabled = false;
            let hasMatch = false;
            data.interfaces.forEach(iface => {
              const opt = document.createElement('option');
              opt.value = iface;
              opt.textContent = iface;
              if (cur.interface === iface) {
                opt.selected = true;
                hasMatch = true;
              }
              select.appendChild(opt);
            });
            // Auto-select first interface if none matches current config
            if (!hasMatch && select.options.length > 0) {
              select.options[0].selected = true;
            }
          } else {
            // No interfaces: show error banner and disable apply button
            const opt = document.createElement('option');
            opt.value = '';
            opt.textContent = 'No interfaces detected';
            select.appendChild(opt);
            if (noIfaceBanner) noIfaceBanner.style.display = 'flex';
            if (applyBtn) applyBtn.disabled = true;
          }
        }

        // Populate form inputs with current config or sensible defaults
        const txtIp = document.getElementById('netplan_ip_cidr');
        const txtGw = document.getElementById('netplan_gateway');
        const txtDns1 = document.getElementById('netplan_dns1');
        const txtDns2 = document.getElementById('netplan_dns2');

        if (txtIp) txtIp.value = cur.address || '';
        if (txtGw) txtGw.value = cur.gateway || '';
        if (txtDns1) txtDns1.value = (cur.dns && cur.dns[0]) ? cur.dns[0] : '1.1.1.1';
        if (txtDns2) txtDns2.value = (cur.dns && cur.dns[1]) ? cur.dns[1] : '8.8.8.8';

        if (cur.interface) {
          if (!cur.dhcp) {
            // Check Static Radio
            const radStatic = document.querySelector('input[name="netplan_mode"][value="static"]');
            if (radStatic) {
              radStatic.checked = true;
              toggleNetplanFields('static');
            }
          } else {
            // Check DHCP Radio
            const radDhcp = document.querySelector('input[name="netplan_mode"][value="dhcp"]');
            if (radDhcp) {
              radDhcp.checked = true;
              toggleNetplanFields('dhcp');
            }
          }
        }
      } catch (err) {
        console.error('Failed to load Netplan state:', err);
        // Populate the dropdown with an error state so the user knows it failed to load
        const select = document.getElementById('netplan_iface_select');
        if (select && select.options.length === 0) {
          const opt = document.createElement('option');
          opt.value = '';
          opt.textContent = 'Failed to load interfaces — refresh to retry';
          select.appendChild(opt);
        }
      }
    }

    function toggleNetplanFields(mode) {
      const staticFields = document.getElementById('netplan-static-fields');
      if (staticFields) {
        staticFields.style.display = (mode === 'static') ? 'flex' : 'none';
      }
    }

    function applyNetplanConfig() {
      const radChecked = document.querySelector('input[name="netplan_mode"]:checked');
      const mode = radChecked ? radChecked.value : 'dhcp';
      const ifaceSelect = document.getElementById('netplan_iface_select');
      const interface_name = ifaceSelect ? ifaceSelect.value : '';

      // Check if the dropdown is empty or only has the placeholder "No interfaces found" option
      if (!interface_name || (ifaceSelect && ifaceSelect.options.length === 1 && ifaceSelect.options[0].value === '')) {
        alert('No network interfaces were detected. Please ensure the server has a network interface available and refresh the page.');
        return;
      }

      let queryUrl = '';
      if (mode === 'dhcp') {
        queryUrl = `/api/run?action=netplan-dhcp&iface=${encodeURIComponent(interface_name)}`;
      } else {
        let ip_cidr = document.getElementById('netplan_ip_cidr').value.trim();
        const gateway = document.getElementById('netplan_gateway').value.trim();
        let dns1 = document.getElementById('netplan_dns1').value.trim();
        let dns2 = document.getElementById('netplan_dns2').value.trim();

        if (!dns1) dns1 = '1.1.1.1';
        if (!dns2) dns2 = '8.8.8.8';

        if (!ip_cidr || !gateway) {
          alert('IP Address and Gateway are required for static IP configuration.');
          return;
        }

        if (!ip_cidr.includes('/')) {
          ip_cidr = ip_cidr + '/24';
        }

        queryUrl = `/api/run?action=netplan-static&iface=${encodeURIComponent(interface_name)}&ip=${encodeURIComponent(ip_cidr)}&gw=${encodeURIComponent(gateway)}&dns1=${encodeURIComponent(dns1)}&dns2=${encodeURIComponent(dns2)}`;
      }

      const confirmMsg = mode === 'static' 
        ? "Warning: Applying a static IP can temporarily disconnect the server and close your session. You will need to access the WebUI using the new IP address if it changes. Proceed?"
        : "Warning: Applying DHCP will reload interfaces. Proceed?";
      
      if (!confirm(confirmMsg)) return;

      streamPaneConsole(queryUrl, 'sys-terminal-body');
    // Local Terminal Helpers for independent pages
    function copyPaneConsole(id) {
      const text = document.getElementById(id).innerText;
      navigator.clipboard.writeText(text).then(() => {
        alert('Console output copied to clipboard.');
      }).catch(err => {
        alert('Failed to copy console logs.');
      });
    }}

    function clearPaneConsole(id) {
      document.getElementById(id).innerHTML = '[Console cleared]\n';
    }

    function streamPaneConsole(queryUrl, terminalId) {
      if (activeSSE) {
        activeSSE.close();
      }
      const terminal = document.getElementById(terminalId);
      if (terminal) {
        terminal.innerHTML = `[Task Initiated]\nConnecting to server execution stream...\n\n`;
        terminal.scrollTop = terminal.scrollHeight;
      }

      activeSSE = new EventSource(queryUrl);

      activeSSE.onmessage = function(e) {
        let line = e.data;
        
        let lineClass = '';
        if (line.includes('[ERROR]') || line.includes('Failed') || line.includes('Error')) {
          lineClass = 'term-err';
        } else if (line.includes('✔') || line.includes('successfully') || line.includes('Success')) {
          lineClass = 'term-ok';
        } else if (line.includes('Warning') || line.includes('⚠️')) {
          lineClass = 'term-warn';
        }

        const span = document.createElement('span');
        if (lineClass) span.className = lineClass;
        span.textContent = line + '\n';
        
        if (terminal) {
          terminal.appendChild(span);
          terminal.scrollTop = terminal.scrollHeight;
        }
      };

      activeSSE.onerror = function() {
        if (terminal) {
          const span = document.createElement('span');
          span.style.color = 'var(--text-muted)';
          span.textContent = '\n[Execution finished. Log stream closed]\n';
          terminal.appendChild(span);
          terminal.scrollTop = terminal.scrollHeight;
        }
        
        activeSSE.close();
        activeSSE = null;
        fetchStatus();
      };
    }

    // Consolidated execution endpoints
    function runPruneGarbage() {
      streamPaneConsole('/api/run?action=prune', 'sys-terminal-body');
    }

    function runSystemUpdate() {
      streamPaneConsole('/api/run?action=maintenance', 'sys-terminal-body');
    }

    // App Configuration Portal functions
    let activeAppConfigTab = 'jellyfin';
    const appFolders = { jellyfin: [], immich: [], nextcloud: [] };
    const appEnvVars = { jellyfin: [], immich: [], nextcloud: [], qbittorrent: [], vaultwarden: [] };

    function switchAppConfigTab(appName) {
      activeAppConfigTab = appName;
      // Deactivate all buttons in the tab list
      document.querySelectorAll('#journey-app-config .checklist-header-actions .badge-btn').forEach(btn => {
        btn.classList.remove('active');
      });
      // Hide all panes
      document.querySelectorAll('.app-config-tab-pane').forEach(pane => {
        pane.style.display = 'none';
      });

      // Activate target button
      const targetBtn = document.getElementById(`btn-tab-config-${appName}`);
      if (targetBtn) targetBtn.classList.add('active');

      // Show target pane
      const targetPane = document.getElementById(`tab-pane-${appName}`);
      if (targetPane) targetPane.style.display = 'block';
    }

    function markAppConfigDirty(app) {
      const notice = document.getElementById(`notice-restart-${app}`);
      if (notice) notice.style.display = 'flex';
      const btn = document.getElementById(`btn-restart-${app}`);
      if (btn) btn.style.display = 'inline-block';
    }

    function addAppFolder(app, path = '') {
      appFolders[app].push(path);
      renderAppFolders(app);
      markAppConfigDirty(app);
    }

    function removeAppFolder(app, index) {
      appFolders[app].splice(index, 1);
      renderAppFolders(app);
      markAppConfigDirty(app);
    }

    function renderAppFolders(app) {
      const list = document.getElementById(`${app}-folders-list`);
      if (!list) return;
      list.innerHTML = '';
      
      appFolders[app].forEach((folderPath, index) => {
        const row = document.createElement('div');
        row.style.display = 'flex';
        row.style.gap = '0.5rem';
        row.style.alignItems = 'center';
        row.style.marginBottom = '0.25rem';
        
        const input = document.createElement('input');
        input.type = 'text';
        input.value = folderPath;
        input.placeholder = `Folder Path #${index + 1}`;
        input.style.flex = '1';
        input.addEventListener('input', (e) => {
          appFolders[app][index] = e.target.value;
          markAppConfigDirty(app);
        });
        
        const deleteBtn = document.createElement('button');
        deleteBtn.type = 'button';
        deleteBtn.className = 'badge-btn';
        deleteBtn.style.background = 'rgba(244, 63, 94, 0.1)';
        deleteBtn.style.color = 'var(--warning-banner-text)';
        deleteBtn.style.borderColor = 'rgba(244, 63, 94, 0.2)';
        deleteBtn.innerHTML = '🗑️';
        deleteBtn.addEventListener('click', () => removeAppFolder(app, index));
        
        row.appendChild(input);
        row.appendChild(deleteBtn);
        list.appendChild(row);
      });
    }

    function addAppEnvVar(app, key = '', val = '') {
      appEnvVars[app].push({ key, val });
      renderAppEnvVars(app);
      markAppConfigDirty(app);
    }

    function removeAppEnvVar(app, index) {
      appEnvVars[app].splice(index, 1);
      renderAppEnvVars(app);
      markAppConfigDirty(app);
    }

    function renderAppEnvVars(app) {
      const list = document.getElementById(`${app}-env-list`);
      if (!list) return;
      list.innerHTML = '';
      
      appEnvVars[app].forEach((pair, index) => {
        const row = document.createElement('div');
        row.style.display = 'flex';
        row.style.gap = '0.5rem';
        row.style.alignItems = 'center';
        row.style.marginBottom = '0.25rem';
        
        const keyInput = document.createElement('input');
        keyInput.type = 'text';
        keyInput.value = pair.key;
        keyInput.placeholder = 'VARIABLE_NAME';
        keyInput.style.flex = '1';
        keyInput.style.fontFamily = 'monospace';
        keyInput.addEventListener('input', (e) => {
          appEnvVars[app][index].key = e.target.value.trim().toUpperCase();
          markAppConfigDirty(app);
        });
        
        const valInput = document.createElement('input');
        valInput.type = 'text';
        valInput.value = pair.val;
        valInput.placeholder = 'value';
        valInput.style.flex = '1.5';
        valInput.addEventListener('input', (e) => {
          appEnvVars[app][index].val = e.target.value;
          markAppConfigDirty(app);
        });
        
        const deleteBtn = document.createElement('button');
        deleteBtn.type = 'button';
        deleteBtn.className = 'badge-btn';
        deleteBtn.style.background = 'rgba(244, 63, 94, 0.1)';
        deleteBtn.style.color = 'var(--warning-banner-text)';
        deleteBtn.style.borderColor = 'rgba(244, 63, 94, 0.2)';
        deleteBtn.innerHTML = '🗑️';
        deleteBtn.addEventListener('click', () => removeAppEnvVar(app, index));
        
        row.appendChild(keyInput);
        row.appendChild(valInput);
        row.appendChild(deleteBtn);
        list.appendChild(row);
      });
    }

    async function loadAppConfigState() {
      try {
        const res = await fetch('/api/config');
        if (!res.ok) throw new Error('Failed to fetch config');
        const config = await res.json();

        // Clear builders
        Object.keys(appFolders).forEach(k => appFolders[k] = []);
        Object.keys(appEnvVars).forEach(k => appEnvVars[k] = []);

        // Parse folders
        if (config.MEDIA_DIR) appFolders.jellyfin.push(config.MEDIA_DIR);
        if (config.JELLYFIN_EXTRA_MEDIA_DIRS) {
          config.JELLYFIN_EXTRA_MEDIA_DIRS.split(',').forEach(p => { if (p) appFolders.jellyfin.push(p); });
        }
        
        if (config.PHOTO_BACKUP_LOCATION) appFolders.immich.push(config.PHOTO_BACKUP_LOCATION);
        if (config.IMMICH_EXTRA_BACKUP_DIRS) {
          config.IMMICH_EXTRA_BACKUP_DIRS.split(',').forEach(p => { if (p) appFolders.immich.push(p); });
        }
        
        if (config.NEXTCLOUD_DATA_LOCATION) appFolders.nextcloud.push(config.NEXTCLOUD_DATA_LOCATION);
        if (config.NEXTCLOUD_EXTRA_DATA_DIRS) {
          config.NEXTCLOUD_EXTRA_DATA_DIRS.split(',').forEach(p => { if (p) appFolders.nextcloud.push(p); });
        }

        // Standard keys list to exclude from custom env vars
        const standardKeys = new Set([
          'TZ', 'PUID', 'PGID', 'SYSTEM_DATA_DIR', 'DB_DATA_LOCATION', 'NEXTCLOUD_DB_LOCATION',
          'GITHUB_REPO', 'GITHUB_TOKEN', 'HOMEPAGE_VAR_QBITTORRENT_PASSWORD', 'HOMEPAGE_VAR_PAPERLESS_USERNAME',
          'HOMEPAGE_VAR_PAPERLESS_PASSWORD', 'HOMEPAGE_VAR_IMMICH_API_KEY',
          'MEDIA_DIR', 'JELLYFIN_PORT', 'JELLYFIN_EXTRA_MEDIA_DIRS',
          'UPLOAD_LOCATION', 'PHOTO_BACKUP_LOCATION', 'IMMICH_PORT', 'IMMICH_EXTRA_BACKUP_DIRS',
          'NEXTCLOUD_DATA_LOCATION', 'NEXTCLOUD_PORT', 'NEXTCLOUD_EXTRA_DATA_DIRS',
          'QBITTORRENT_PORT', 'QBITTORRENT_INCOMING_PORT',
          'VAULTWARDEN_PORT', 'SIGNUPS_ALLOWED'
        ]);

        // Map custom variables
        Object.entries(config).forEach(([key, val]) => {
          if (standardKeys.has(key)) return;
          
          if (key.startsWith('JELLYFIN_')) {
            appEnvVars.jellyfin.push({ key, val });
          } else if (key.startsWith('IMMICH_')) {
            appEnvVars.immich.push({ key, val });
          } else if (key.startsWith('NEXTCLOUD_')) {
            appEnvVars.nextcloud.push({ key, val });
          } else if (key.startsWith('QBITTORRENT_')) {
            appEnvVars.qbittorrent.push({ key, val });
          } else if (key.startsWith('VAULTWARDEN_')) {
            appEnvVars.vaultwarden.push({ key, val });
          }
        });

        // Populate port and static inputs
        document.getElementById('input-jellyfin-port').value = config.JELLYFIN_PORT || '';
        document.getElementById('input-immich-upload-location').value = config.UPLOAD_LOCATION || '';
        document.getElementById('input-immich-port').value = config.IMMICH_PORT || '';
        document.getElementById('input-nextcloud-port').value = config.NEXTCLOUD_PORT || '';
        document.getElementById('input-qbittorrent-port').value = config.QBITTORRENT_PORT || '';
        document.getElementById('input-qbittorrent-incoming-port').value = config.QBITTORRENT_INCOMING_PORT || '';
        document.getElementById('input-vaultwarden-port').value = config.VAULTWARDEN_PORT || '';
        document.getElementById('input-vaultwarden-signup-allowed').value = config.SIGNUPS_ALLOWED !== undefined ? String(config.SIGNUPS_ALLOWED) : 'true';

        // Render builders
        Object.keys(appFolders).forEach(renderAppFolders);
        Object.keys(appEnvVars).forEach(renderAppEnvVars);

        // Fetch container statuses
        const statusRes = await fetch('/api/status');
        if (!statusRes.ok) throw new Error('Failed to fetch status');
        const statusData = await statusRes.json();
        const containers = statusData.containers || {};

        const appContainers = {
          jellyfin: 'media_jellyfin',
          immich: 'immich_server',
          nextcloud: 'nextcloud_app',
          qbittorrent: 'media_qbittorrent',
          vaultwarden: 'utility_vaultwarden'
        };

        for (const [app, containerName] of Object.entries(appContainers)) {
          const badge = document.getElementById(`badge-status-${app}`);
          if (badge) {
            const state = containers[containerName];
            if (state === 'running') {
              badge.className = 'container-status-badge badge-up';
              badge.textContent = 'Running';
            } else {
              badge.className = 'container-status-badge badge-down';
              badge.textContent = state ? state.charAt(0).toUpperCase() + state.slice(1) : 'Stopped';
            }
          }
        }
      } catch (err) {
        console.error('Error loading app config state:', err);
      }
    }

    async function saveAppConfigOnly(app) {
      const payload = {};

      if (app === 'jellyfin') {
        const folders = appFolders.jellyfin;
        payload.MEDIA_DIR = folders.length > 0 ? folders[0] : '';
        payload.JELLYFIN_EXTRA_MEDIA_DIRS = folders.length > 1 ? folders.slice(1).join(',') : '';
        payload.JELLYFIN_PORT = document.getElementById('input-jellyfin-port').value.trim();
        
        appEnvVars.jellyfin.forEach(pair => {
          if (pair.key) payload[pair.key] = pair.val;
        });
      } else if (app === 'immich') {
        const folders = appFolders.immich;
        payload.PHOTO_BACKUP_LOCATION = folders.length > 0 ? folders[0] : '';
        payload.IMMICH_EXTRA_BACKUP_DIRS = folders.length > 1 ? folders.slice(1).join(',') : '';
        payload.UPLOAD_LOCATION = document.getElementById('input-immich-upload-location').value.trim();
        payload.IMMICH_PORT = document.getElementById('input-immich-port').value.trim();
        
        appEnvVars.immich.forEach(pair => {
          if (pair.key) payload[pair.key] = pair.val;
        });
      } else if (app === 'nextcloud') {
        const folders = appFolders.nextcloud;
        payload.NEXTCLOUD_DATA_LOCATION = folders.length > 0 ? folders[0] : '';
        payload.NEXTCLOUD_EXTRA_DATA_DIRS = folders.length > 1 ? folders.slice(1).join(',') : '';
        payload.NEXTCLOUD_PORT = document.getElementById('input-nextcloud-port').value.trim();
        
        appEnvVars.nextcloud.forEach(pair => {
          if (pair.key) payload[pair.key] = pair.val;
        });
      } else if (app === 'qbittorrent') {
        payload.QBITTORRENT_PORT = document.getElementById('input-qbittorrent-port').value.trim();
        payload.QBITTORRENT_INCOMING_PORT = document.getElementById('input-qbittorrent-incoming-port').value.trim();
        
        appEnvVars.qbittorrent.forEach(pair => {
          if (pair.key) payload[pair.key] = pair.val;
        });
      } else if (app === 'vaultwarden') {
        payload.VAULTWARDEN_PORT = document.getElementById('input-vaultwarden-port').value.trim();
        payload.SIGNUPS_ALLOWED = document.getElementById('input-vaultwarden-signup-allowed').value;
        
        appEnvVars.vaultwarden.forEach(pair => {
          if (pair.key) payload[pair.key] = pair.val;
        });
      }

      try {
        const saveRes = await fetch('/api/config', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(payload)
        });

        if (!saveRes.ok) throw new Error('Failed to save configuration.');
        const saveResult = await saveRes.json();
        if (!saveResult.success) throw new Error('Save configuration returned success=false.');

        alert('Configuration saved to .env successfully! Please click the red "Restart Service" button to apply these changes on the host.');
      } catch (err) {
        alert('Error saving config: ' + err.message);
      }
    }

    function restartAppService(app) {
      let serviceToRestart = '';
      let displayTitle = '';

      if (app === 'jellyfin') {
        serviceToRestart = 'jellyfin';
        displayTitle = 'Restarting Jellyfin Player';
      } else if (app === 'immich') {
        serviceToRestart = 'immich_suite';
        displayTitle = 'Restarting Immich Photos Stack';
      } else if (app === 'nextcloud') {
        serviceToRestart = 'nextcloud_suite';
        displayTitle = 'Restarting Nextcloud Cloud Stack';
      } else if (app === 'qbittorrent') {
        serviceToRestart = 'qbittorrent';
        displayTitle = 'Restarting qBittorrent Downloader';
      } else if (app === 'vaultwarden') {
        serviceToRestart = 'vaultwarden';
        displayTitle = 'Restarting Vaultwarden Password Vault';
      }

      if (!serviceToRestart) return;

      // Hide restart warnings
      const notice = document.getElementById(`notice-restart-${app}`);
      if (notice) notice.style.display = 'none';
      const btn = document.getElementById(`btn-restart-${app}`);
      if (btn) btn.style.display = 'none';

      triggerJourney('dashboard');
      initConsoleLogs(displayTitle, `/api/run?action=restart&services=${serviceToRestart}`);
    }

    // App Setups & Usage Manual Tab Switching
    function showUsageTab(tabName) {
      document.querySelectorAll('.usage-tab-pane').forEach(el => el.style.display = 'none');
      document.querySelectorAll('#journey-usage .checklist-header-actions .badge-btn').forEach(btn => btn.classList.remove('active'));

      const targetPane = document.getElementById(`usage-tab-${tabName}`);
      if (targetPane) targetPane.style.display = 'block';

      const targetBtn = document.getElementById(`btn-tab-${tabName}`);
      if (targetBtn) targetBtn.classList.add('active');
    }

    // Docker Engine Installation
    let dockerInstallSSE = null;
    function runDockerInstall() {
      const btn = document.getElementById('btn-run-docker-install');
      const statusEl = document.getElementById('docker-install-status');
      const consoleWrap = document.getElementById('docker-install-console');
      const output = document.getElementById('docker-install-output');

      if (dockerInstallSSE) {
        dockerInstallSSE.close();
        dockerInstallSSE = null;
      }

      btn.disabled = true;
      statusEl.textContent = 'Installing…';
      consoleWrap.style.display = 'block';
      output.textContent = '';

      dockerInstallSSE = new EventSource('/api/run?action=install-docker');

      dockerInstallSSE.onmessage = function(e) {
        const line = e.data;
        output.textContent += line + '\n';
        output.scrollTop = output.scrollHeight;

        if (line.includes('✔') || line.includes('successfully') || line.includes('Success')) {
          statusEl.style.color = 'var(--accent-green)';
          statusEl.textContent = '✔ Docker installed successfully';
        } else if (line.includes('[ERROR]') || line.includes('Error') || line.includes('Failed')) {
          statusEl.style.color = 'var(--accent-red)';
          statusEl.textContent = '✗ Error encountered — see output';
        }
      };

      dockerInstallSSE.onerror = function() {
        btn.disabled = false;
        if (!statusEl.textContent.startsWith('✔') && !statusEl.textContent.startsWith('✗')) {
          statusEl.style.color = 'var(--text-muted)';
          statusEl.textContent = 'Stream closed.';
        }
        dockerInstallSSE.close();
        dockerInstallSSE = null;
      };
    }

    // Load configs and populate form fields
    async function loadConfig() {
      try {
        const res = await fetch('/api/config');
        const data = await res.json();
        cachedConfig = data;

        // Populate shared wizard elements
        Object.entries(data).forEach(([key, val]) => {
          const input = document.getElementById(key);
          if (input) {
            if (input.type === 'checkbox') {
              input.checked = val === 'true';
            } else {
              input.value = val;
            }
          }
        });

        // Handle auto mount initial toggles
        const isAutoMount = data.CONFIGURE_DRIVE_MOUNTS === 'true';
        document.getElementById('chk-auto-mount').checked = isAutoMount;
        toggleMountFields(isAutoMount);

        // Render mounting stat on dashboard
        document.getElementById('stats-mount').textContent = isAutoMount ? 'Host Mounts' : 'Portable';
        
        // Populate specific page elements
        if (data.TS_AUTHKEY) {
          document.getElementById('tailscale_TS_AUTHKEY').value = data.TS_AUTHKEY;
          document.getElementById('ts-authkey-display').value = '••••••••••••••••';
        } else {
          document.getElementById('ts-authkey-display').value = 'Not configured';
        }

        if (data.HOMEPAGE_VAR_QBITTORRENT_PASSWORD) {
          document.getElementById('homepage_QBITTORRENT_PASSWORD').value = data.HOMEPAGE_VAR_QBITTORRENT_PASSWORD;
        }
        if (data.HOMEPAGE_VAR_PAPERLESS_USERNAME) {
          document.getElementById('homepage_PAPERLESS_USERNAME').value = data.HOMEPAGE_VAR_PAPERLESS_USERNAME;
        }
        if (data.HOMEPAGE_VAR_PAPERLESS_PASSWORD) {
          document.getElementById('homepage_PAPERLESS_PASSWORD').value = data.HOMEPAGE_VAR_PAPERLESS_PASSWORD;
        }
        if (data.HOMEPAGE_VAR_IMMICH_API_KEY) {
          document.getElementById('homepage_IMMICH_API_KEY').value = data.HOMEPAGE_VAR_IMMICH_API_KEY;
        }

        const repoVal = data.GITHUB_REPO || localStorage.getItem('GITHUB_REPO') || 'arunkarshan/HomeServerConfiguration';
        document.getElementById('git_push_REPO').value = repoVal;
        document.getElementById('git_sync_REPO').value = repoVal;

        // Populate volume config settings
        if (data.JELLYFIN_EXTRA_DIR) {
          document.getElementById('volume_JELLYFIN_EXTRA_DIR').value = data.JELLYFIN_EXTRA_DIR;
        }
        if (data.PHOTO_BACKUP_LOCATION) {
          document.getElementById('volume_PHOTO_BACKUP_LOCATION').value = data.PHOTO_BACKUP_LOCATION;
        }
        if (data.UPLOAD_LOCATION) {
          document.getElementById('volume_UPLOAD_LOCATION').value = data.UPLOAD_LOCATION;
        }
        if (data.NEXTCLOUD_DATA_LOCATION) {
          document.getElementById('volume_NEXTCLOUD_DATA_LOCATION').value = data.NEXTCLOUD_DATA_LOCATION;
        }
      } catch (err) {
        console.error('Failed to load configurations:', err);
      }
    }

    // Save wizard configuration changes dynamically based on active journey pane
    async function saveConfigForJourney(journeyId) {
      const config = {};
      
      if (journeyId === 'update' || journeyId === 'install') {
        config['SERVER_IP'] = document.getElementById('SERVER_IP').value;
        config['TZ'] = document.getElementById('TZ').value;
        config['PUID'] = document.getElementById('PUID').value;
        config['PGID'] = document.getElementById('PGID').value;
        config['SYSTEM_DATA_DIR'] = document.getElementById('SYSTEM_DATA_DIR').value;
        config['MEDIA_DIR'] = document.getElementById('MEDIA_DIR').value;
        config['CONFIGURE_DRIVE_MOUNTS'] = document.getElementById('chk-auto-mount').checked ? 'true' : 'false';
        config['DRIVE_MOUNT_POINTS'] = document.getElementById('DRIVE_MOUNT_POINTS').value;
        config['DRIVE_SIZES'] = document.getElementById('DRIVE_SIZES').value;
        config['UPLOAD_LOCATION'] = document.getElementById('UPLOAD_LOCATION').value;
        config['PHOTO_BACKUP_LOCATION'] = document.getElementById('PHOTO_BACKUP_LOCATION').value;
        config['NEXTCLOUD_DATA_LOCATION'] = document.getElementById('NEXTCLOUD_DATA_LOCATION').value;
        config['TS_AUTHKEY'] = document.getElementById('TS_AUTHKEY').value;
      } else if (journeyId === 'tailscale') {
        config['TS_AUTHKEY'] = document.getElementById('tailscale_TS_AUTHKEY').value;
      } else if (journeyId === 'homepage') {
        config['HOMEPAGE_VAR_QBITTORRENT_PASSWORD'] = document.getElementById('homepage_QBITTORRENT_PASSWORD').value;
        config['HOMEPAGE_VAR_PAPERLESS_USERNAME'] = document.getElementById('homepage_PAPERLESS_USERNAME').value;
        config['HOMEPAGE_VAR_PAPERLESS_PASSWORD'] = document.getElementById('homepage_PAPERLESS_PASSWORD').value;
        config['HOMEPAGE_VAR_IMMICH_API_KEY'] = document.getElementById('homepage_IMMICH_API_KEY').value;
      } else if (journeyId === 'git-push') {
        config['GITHUB_REPO'] = document.getElementById('git_push_REPO').value;
      } else if (journeyId === 'git-sync') {
        config['GITHUB_REPO'] = document.getElementById('git_sync_REPO').value;
      }

      try {
        const res = await fetch('/api/config', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(config)
        });
        const data = await res.json();
        if (data.success) {
          loadConfig();
          return true;
        }
        return false;
      } catch (err) {
        console.error('Error saving configs:', err);
        return false;
      }
    }

    // Trigger selective checklist actions (Update, Restart, Install/Nuke)
    async function runSelectiveAction(action) {
      const selected = [];
      const prefix = action === 'nuke' || action === 'install' ? 'install' : action;
      document.querySelectorAll(`.cb-${prefix}:checked`).forEach(cb => {
        selected.push(cb.value);
      });

      if (selected.length === 0) {
        alert('Please check at least one service to perform this action.');
        return;
      }

      if (action === 'install') {
        const confirmMsg = '⚠️ WARNING: Proceeding will erase all databases and configurations for the checked services. This action CANNOT be undone.\n\nAre you sure you want to proceed?';
        if (!confirm(confirmMsg)) return;
      }

      // Auto-save the config first
      const saved = await saveConfigForJourney(prefix);
      if (!saved) {
        alert('Failed to save configuration settings. Aborting task execution.');
        return;
      }

      // Transition and launch SSE logs
      const title = `${action === 'install' ? 'Install' : action.charAt(0).toUpperCase() + action.slice(1)} Task Running`;
      const sseAction = action === 'install' ? 'nuke' : action;
      initConsoleLogs(title, `/api/run?action=${sseAction}&services=${selected.join(',')}`);
    }

    // Trigger configured single-command tasks (tailscale, homepage, git-push, sync)
    async function runConfiguredAction(action, title) {
      let journeyId = action;
      if (action === 'git-push') journeyId = 'git-push';
      if (action === 'sync') journeyId = 'git-sync';
      
      const saved = await saveConfigForJourney(journeyId);
      if (!saved) {
        alert('Failed to save configuration settings. Aborting task execution.');
        return;
      }

      initConsoleLogs(title || `${action} running`, `/api/run?action=${action}`);
    }

    // Trigger direct single-command tasks (backup, prune, maintenance, etc.)
    function runDirectAction(action, title) {
      initConsoleLogs(title || `${action} running`, `/api/run?action=${action}`);
    }

    // Initialize Log Console Stream (SSE)
    function initConsoleLogs(title, queryUrl) {
      document.getElementById('terminal-pane').style.display = 'block';
      const terminal = document.getElementById('terminal-body');
      const titleEl = document.getElementById('terminal-title-text');
      
      titleEl.textContent = title;
      terminal.innerHTML = `[Task Initiated: ${title.toUpperCase()}]\nConnecting to server execution stream...\n\n`;
      terminal.scrollTop = terminal.scrollHeight;

      if (activeSSE) {
        activeSSE.close();
      }

      activeSSE = new EventSource(queryUrl);

      activeSSE.onmessage = function(e) {
        let line = e.data;
        
        let lineClass = '';
        if (line.includes('[ERROR]') || line.includes('Failed') || line.includes('Error')) {
          lineClass = 'term-err';
        } else if (line.includes('✔') || line.includes('successfully') || line.includes('Success')) {
          lineClass = 'term-ok';
        } else if (line.includes('Warning') || line.includes('⚠️')) {
          lineClass = 'term-warn';
        }

        const span = document.createElement('span');
        if (lineClass) span.className = lineClass;
        span.textContent = line + '\n';
        
        terminal.appendChild(span);
        terminal.scrollTop = terminal.scrollHeight;
      };

      activeSSE.onerror = function() {
        const span = document.createElement('span');
        span.style.color = 'var(--text-muted)';
        span.textContent = '\n[Execution finished. Log stream closed]\n';
        terminal.appendChild(span);
        terminal.scrollTop = terminal.scrollHeight;
        
        activeSSE.close();
        activeSSE = null;
        fetchStatus();
      };
    }

    // Terminal helper actions
    function clearConsoleOutput() {
      document.getElementById('terminal-body').innerHTML = '[Console cleared]\n';
    }

    // Copy Console logs to clipboard
    function copyConsoleOutput() {
      const text = document.getElementById('terminal-body').innerText;
      navigator.clipboard.writeText(text).then(() => {
        alert('Console output copied to clipboard.');
      }).catch(err => {
        alert('Failed to copy console logs.');
      });
    }

    // Light & Dark Theme Controller
    function initTheme() {
      const savedTheme = localStorage.getItem('theme') || 'auto';
      applyTheme(savedTheme);
      
      // Listen to system theme changes in auto mode
      window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', () => {
        const curr = localStorage.getItem('theme') || 'auto';
        if (curr === 'auto') {
          applyTheme('auto');
        }
      });
    }

    function applyTheme(theme) {
      const root = document.documentElement;
      const btn = document.getElementById('theme-toggle-btn');
      
      root.classList.remove('theme-light', 'theme-dark');

      if (theme === 'auto') {
        const systemDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
        root.classList.add(systemDark ? 'theme-dark' : 'theme-light');
        if (btn) {
          btn.textContent = '🌓';
          btn.title = 'Theme: Auto (System)';
        }
      } else if (theme === 'dark') {
        root.classList.add('theme-dark');
        if (btn) {
          btn.textContent = '🌙';
          btn.title = 'Theme: Dark';
        }
      } else {
        root.classList.add('theme-light');
        if (btn) {
          btn.textContent = '☀️';
          btn.title = 'Theme: Light';
        }
      }
    }

    function toggleTheme() {
      const currentTheme = localStorage.getItem('theme') || 'auto';
      let nextTheme = 'auto';

      if (currentTheme === 'auto') {
        nextTheme = 'dark';
      } else if (currentTheme === 'dark') {
        nextTheme = 'light';
      } else {
        nextTheme = 'auto';
      }

      localStorage.setItem('theme', nextTheme);
      applyTheme(nextTheme);
    }

    // Initialize Page
    initTheme();
    populateChecklists();
    fetchStatus();
    loadConfig();

    // Sync and cache Git configurations in localStorage
    const setupGitSyncListeners = () => {
      const syncRepo = document.getElementById('git_sync_REPO');
      const pushRepo = document.getElementById('git_push_REPO');

      if (syncRepo && pushRepo) {
        syncRepo.addEventListener('input', (e) => {
          localStorage.setItem('GITHUB_REPO', e.target.value);
          pushRepo.value = e.target.value;
        });
        pushRepo.addEventListener('input', (e) => {
          localStorage.setItem('GITHUB_REPO', e.target.value);
          syncRepo.value = e.target.value;
        });
      }
    };
    setupGitSyncListeners();
    
    // Poll containers status updates
    setInterval(fetchStatus, 15000);

    // ---- Restart Portal Server ----
    async function restartPortalServer() {
      const confirmed = confirm(
        '⚠️  Restart the Portal WebUI server?\n\nThe page will go offline briefly and reconnect automatically once the server is back up.'
      );
      if (!confirmed) return;

      const overlay = document.getElementById('restart-overlay');
      const statusText = document.getElementById('restart-status-text');
      const btn = document.getElementById('btn-restart-server');

      // Show overlay
      overlay.style.display = 'flex';
      if (btn) btn.disabled = true;
      statusText.textContent = 'Sending restart signal…';

      try {
        await fetch('/api/restart-server', { method: 'POST' });
      } catch (_) {
        // The server may close the connection before a response; that's fine.
      }

      statusText.textContent = 'Server is restarting — waiting for it to come back online…';

      // Poll /api/status until the server responds again, then reload.
      let attempts = 0;
      const maxAttempts = 60; // 60 × 2s = 2 min timeout
      const poll = setInterval(async () => {
        attempts++;
        try {
          const r = await fetch('/api/status', { cache: 'no-store' });
          if (r.ok) {
            clearInterval(poll);
            statusText.textContent = 'Server is back! Reloading…';
            setTimeout(() => window.location.reload(), 800);
          }
        } catch (_) {
          // Server still down — keep polling
          statusText.textContent = `Waiting for server… (${attempts * 2}s elapsed)`;
        }
        if (attempts >= maxAttempts) {
          clearInterval(poll);
          statusText.textContent = 'Server did not respond in time. Please refresh manually.';
          const spinner = document.getElementById('restart-spinner');
          if (spinner) spinner.style.borderTopColor = '#facc15';
          if (btn) btn.disabled = false;
        }
      }, 2000);
    }

    // Toggle collapsible container card display in dashboard
    let containersCollapsed = false;
    function toggleContainersCollapsible() {
      const wrapper = document.getElementById('dashboard-containers-collapse-wrapper');
      const arrow = document.getElementById('containers-toggle-arrow');
      containersCollapsed = !containersCollapsed;
      if (containersCollapsed) {
        wrapper.style.maxHeight = '0px';
        wrapper.style.overflow = 'hidden';
        arrow.style.transform = 'rotate(-90deg)';
      } else {
        wrapper.style.maxHeight = '420px';
        wrapper.style.overflowY = 'auto';
        arrow.style.transform = 'rotate(0deg)';
      }
    }

    // Maps system container name to user-friendly service details (SRP mapping)
    function getServiceDetails(name) {
      const lower = name.toLowerCase();
      
      const mapping = [
        { keys: ['jellyfin'], name: 'Jellyfin Media Server', icon: '🎬' },
        { keys: ['qbittorrent'], name: 'qBittorrent Client', icon: '📥' },
        { keys: ['radarr'], name: 'Radarr Movies', icon: '🎥' },
        { keys: ['sonarr'], name: 'Sonarr TV Shows', icon: '📺' },
        { keys: ['prowlarr'], name: 'Prowlarr Indexers', icon: '🔍' },
        { keys: ['flaresolverr'], name: 'FlareSolverr Bypass', icon: '🕵️' },
        { keys: ['jellyseerr'], name: 'Jellyseerr Requests', icon: '🎫' },
        { keys: ['bazarr'], name: 'Bazarr Subtitles', icon: '✍️' },
        { keys: ['navidrome'], name: 'Navidrome Music', icon: '🎵' },
        { keys: ['metube'], name: 'MeTube Downloader', icon: '🎥' },
        { keys: ['nextcloud-app', 'nextcloud_app'], name: 'Nextcloud Cloud Hub', icon: '☁️' },
        { keys: ['nextcloud-cron', 'nextcloud_cron'], name: 'Nextcloud Cron', icon: '⏱️' },
        { keys: ['nextcloud-db', 'nextcloud_db'], name: 'Nextcloud Database', icon: '🗄️' },
        { keys: ['immich-server', 'immich_server'], name: 'Immich Photos', icon: '📸' },
        { keys: ['immich-machine-learning', 'immich_machine_learning'], name: 'Immich Machine Learning', icon: '🤖' },
        { keys: ['vaultwarden'], name: 'Vaultwarden Key Pass', icon: '🔑' },
        { keys: ['tailscale'], name: 'Tailscale VPN', icon: '🛡️' },
        { keys: ['stirling-pdf', 'stirling_pdf'], name: 'Stirling PDF', icon: '📄' },
        { keys: ['it-tools'], name: 'IT Tools', icon: '🛠️' },
        { keys: ['uptime-kuma'], name: 'Uptime Kuma', icon: '📈' },
        { keys: ['syncthing'], name: 'Syncthing Sync', icon: '🔄' },
        { keys: ['pairdrop'], name: 'PairDrop File Share', icon: '🎈' },
        { keys: ['radicale'], name: 'Radicale CalDAV', icon: '📅' },
        { keys: ['baikal'], name: 'Baikal Contacts', icon: '📅' },
        { keys: ['cronicle'], name: 'Cronicle Jobs', icon: '⏱️' },
        { keys: ['ofelia'], name: 'Ofelia Tasks', icon: '⏱️' },
        { keys: ['paperless-web', 'paperless_web'], name: 'Paperless Documents', icon: '📝' },
        { keys: ['paperless-redis'], name: 'Paperless Redis', icon: '⚡' },
        { keys: ['redis'], name: 'Redis Cache', icon: '⚡' },
        { keys: ['postgres', 'database'], name: 'System Database', icon: '🗄️' }
      ];

      for (const item of mapping) {
        if (item.keys.some(k => lower.includes(k))) {
          return item;
        }
      }

      // Default fallback formatting
      const cleanName = name
        .replace(/^media[-_]/i, '')
        .replace(/^utility[-_]/i, '')
        .replace(/^cloud[-_]/i, '')
        .replace(/[-_]/g, ' ')
        .split(' ')
        .map(w => w.charAt(0).toUpperCase() + w.slice(1))
        .join(' ');
      return { name: cleanName, icon: '📦' };
    }

    // Detailed metadata maps for geek-appealing container inspection (SOLID/SRP layout)
    const CONTAINER_METADATA_MAP = {
      jellyfin: {
        image: 'jellyfin/jellyfin:latest',
        group: 'Media Suite',
        mounts: [
          { host: 'MEDIA_DIR', container: '/media', desc: 'Primary movies, series, and music directory' },
          { host: 'SYSTEM_DATA_DIR/jellyfin/config', container: '/config', desc: 'Configuration and plugins' },
          { host: 'SYSTEM_DATA_DIR/jellyfin/cache', container: '/cache', desc: 'Transcoding and cover art cache' }
        ],
        links: ['media_qbittorrent', 'media_radarr', 'media_sonarr'],
        compose: `jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: media_jellyfin
    user: "\${PUID}:\${PGID}"
    network_mode: host
    volumes:
      - \${SYSTEM_DATA_DIR}/jellyfin/config:/config
      - \${SYSTEM_DATA_DIR}/jellyfin/cache:/cache
      - \${MEDIA_DIR}:/media
    restart: unless-stopped`
      },
      qbittorrent: {
        image: 'lscr.io/linuxserver/qbittorrent:latest',
        group: 'Media Suite',
        mounts: [
          { host: 'MEDIA_DIR/downloads', container: '/downloads', desc: 'Active torrent downloads directory' },
          { host: 'SYSTEM_DATA_DIR/qbittorrent', container: '/config', desc: 'Application settings and state' }
        ],
        links: ['media_prowlarr', 'media_radarr', 'media_sonarr'],
        compose: `qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    container_name: media_qbittorrent
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
      - TZ=\${TZ}
    volumes:
      - \${SYSTEM_DATA_DIR}/qbittorrent:/config
      - \${MEDIA_DIR}/downloads:/downloads
    ports:
      - 8080:8080
      - 6881:6881
      - 6881:6881/udp
    restart: unless-stopped`
      },
      nextcloud: {
        image: 'nextcloud:apache',
        group: 'Cloud Hub Suite',
        mounts: [
          { host: 'NEXTCLOUD_DATA_LOCATION', container: '/var/www/html/data', desc: 'Primary cloud uploads repository' },
          { host: 'SYSTEM_DATA_DIR/nextcloud/config', container: '/var/www/html/config', desc: 'System environment overrides' }
        ],
        links: ['nextcloud_db', 'nextcloud_cron', 'redis'],
        compose: `nextcloud-app:
    image: nextcloud:apache
    container_name: nextcloud_app
    restart: always
    ports:
      - 8080:80
    volumes:
      - \${SYSTEM_DATA_DIR}/nextcloud/config:/var/www/html/config
      - \${NEXTCLOUD_DATA_LOCATION}:/var/www/html/data
    environment:
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=\${NEXTCLOUD_DB_PASSWORD}
      - MYSQL_HOST=nextcloud_db
    depends_on:
      - nextcloud_db`
      },
      immich: {
        image: 'ghcr.io/immich-app/immich-server:release',
        group: 'Cloud Hub Suite',
        mounts: [
          { host: 'UPLOAD_LOCATION', container: '/usr/src/app/upload', desc: 'Photos and videos library uploads' },
          { host: 'PHOTO_BACKUP_LOCATION', container: '/mnt/PhotoBackup', desc: 'External reference photobacks (read-only)' }
        ],
        links: ['immich_machine_learning', 'redis', 'database'],
        compose: `immich-server:
    image: ghcr.io/immich-app/immich-server:release
    container_name: immich_server
    volumes:
      - \${UPLOAD_LOCATION}:/usr/src/app/upload
      - \${PHOTO_BACKUP_LOCATION}:/mnt/PhotoBackup:ro
    ports:
      - 2283:2283
    environment:
      - DB_HOSTNAME=database
      - DB_USERNAME=postgres
      - DB_PASSWORD=\${POSTGRES_DB_PASSWORD}
      - REDIS_HOSTNAME=redis
    restart: always
    depends_on:
      - database
      - redis`
      },
      vaultwarden: {
        image: 'vaultwarden/server:latest',
        group: 'Utility Suite',
        mounts: [
          { host: 'SYSTEM_DATA_DIR/vaultwarden', container: '/data', desc: 'Vault credential files and logs' }
        ],
        links: [],
        compose: `vaultwarden:
    image: vaultwarden/server:latest
    container_name: utility_vaultwarden
    volumes:
      - \${SYSTEM_DATA_DIR}/vaultwarden:/data
    ports:
      - 8081:80
    restart: unless-stopped`
      },
      tailscale: {
        image: 'tailscale/tailscale:latest',
        group: 'Utility Suite',
        mounts: [
          { host: '/dev/net/tun', container: '/dev/net/tun', desc: 'Tunnel network kernel driver' },
          { host: 'SYSTEM_DATA_DIR/tailscale', container: '/var/lib/tailscale', desc: 'VPN auth states and keys' }
        ],
        links: [],
        compose: `tailscale:
    image: tailscale/tailscale:latest
    container_name: utility_tailscale
    network_mode: host
    capabilities:
      - NET_ADMIN
    volumes:
      - /dev/net/tun:/dev/net/tun
      - \${SYSTEM_DATA_DIR}/tailscale:/var/lib/tailscale
    environment:
      - TS_AUTHKEY=\${TS_AUTHKEY}
    restart: unless-stopped`
      }
    };

    let currentDetailCompose = '';

    function showContainerDetails(name, status, isUp, details) {
      triggerJourney('docker-detail');
      
      let key = '';
      const lower = name.toLowerCase();
      if (lower.includes('jellyfin')) key = 'jellyfin';
      else if (lower.includes('qbittorrent')) key = 'qbittorrent';
      else if (lower.includes('nextcloud')) key = 'nextcloud';
      else if (lower.includes('immich')) key = 'immich';
      else if (lower.includes('vaultwarden')) key = 'vaultwarden';
      else if (lower.includes('tailscale')) key = 'tailscale';

      let meta = CONTAINER_METADATA_MAP[key];
      if (!meta) {
        let groupName = 'System Service';
        if (SUITE_GROUPS.media.some(k => lower.includes(k))) groupName = 'Media Suite';
        else if (SUITE_GROUPS.cloud.some(k => lower.includes(k))) groupName = 'Cloud Hub Suite';
        else if (SUITE_GROUPS.utility.some(k => lower.includes(k))) groupName = 'Utility Suite';

        meta = {
          image: `lscr.io/linuxserver/${key || name.replace(/^(media_|utility_|cloud_)/, '')}:latest`,
          group: groupName,
          mounts: [
            { host: `SYSTEM_DATA_DIR/${name}`, container: '/config', desc: 'Application configurations state' }
          ],
          links: [],
          compose: `${name.replace(/^(media_|utility_|cloud_)/, '')}:
    image: lscr.io/linuxserver/${key || name.replace(/^(media_|utility_|cloud_)/, '')}:latest
    container_name: ${name}
    environment:
      - PUID=\${PUID}
      - PGID=\${PGID}
    volumes:
      - \${SYSTEM_DATA_DIR}/${name}:/config
    restart: unless-stopped`
        };
      }

      // Populate layout
      document.getElementById('detail-icon').textContent = details.icon;
      document.getElementById('detail-icon').style.display = 'block';
      const detailLogo = document.getElementById('detail-logo');
      if (detailLogo) {
        detailLogo.style.display = 'none';
        detailLogo.src = `/logos/logo_${getLogoKey(name)}.png`;
      }
      document.getElementById('detail-service-name').textContent = details.name;
      document.getElementById('detail-container-name').textContent = name;
      
      const badge = document.getElementById('detail-status-badge');
      const dot = document.getElementById('detail-status-dot');
      const statusLower = status.toLowerCase();
      const isError = statusLower.includes('unhealthy') || statusLower.includes('dead') || (statusLower.includes('exited') && !statusLower.includes('exited (0)'));
      
      badge.textContent = isUp ? 'Running' : (isError ? 'Error' : 'Stopped');
      badge.className = `container-status-badge ${isUp ? 'badge-up' : (isError ? 'badge-down' : 'badge-down')}`;
      if (isUp) {
        badge.style.background = 'rgba(16, 185, 129, 0.1)';
        badge.style.color = 'var(--accent-green)';
        dot.className = 'status-dot up';
        dot.style.backgroundColor = 'var(--accent-green)';
        dot.style.boxShadow = '0 0 6px var(--accent-green)';
      } else if (isError) {
        badge.style.background = 'rgba(239, 68, 68, 0.1)';
        badge.style.color = 'var(--accent-red)';
        dot.className = 'status-dot down';
        dot.style.backgroundColor = 'var(--accent-red)';
        dot.style.boxShadow = '0 0 6px var(--accent-red)';
      } else {
        badge.style.background = 'rgba(245, 158, 11, 0.1)';
        badge.style.color = 'var(--accent-orange)';
        dot.className = 'status-dot down';
        dot.style.backgroundColor = 'var(--accent-orange)';
        dot.style.boxShadow = '0 0 6px var(--accent-orange)';
      }

      document.getElementById('detail-group').textContent = meta.group;
      document.getElementById('detail-image').textContent = meta.image;

      // Populate Mounts
      const mountsList = document.getElementById('detail-mounts-list');
      mountsList.innerHTML = '';
      if (meta.mounts.length === 0) {
        mountsList.innerHTML = '<span style="color: var(--text-muted);">No volume mounts configured.</span>';
      } else {
        meta.mounts.forEach(m => {
          const div = document.createElement('div');
          div.style.cssText = 'padding: 0.5rem; border-radius: 6px; background: rgba(255,255,255,0.02); border: 1px solid rgba(255,255,255,0.03);';
          div.innerHTML = `
            <div style="font-family: var(--font-mono); font-weight: 600; color: var(--text-primary);">${m.host} <span style="color: var(--accent-blue);">→</span> ${m.container}</div>
            <div style="font-size: 0.72rem; color: var(--text-muted); margin-top: 0.15rem;">${m.desc}</div>
          `;
          mountsList.appendChild(div);
        });
      }

      // Populate Links
      const linksList = document.getElementById('detail-links-list');
      linksList.innerHTML = '';
      if (meta.links.length === 0) {
        linksList.innerHTML = '<span style="color: var(--text-muted);">No linked containers.</span>';
      } else {
        meta.links.forEach(l => {
          const div = document.createElement('div');
          div.style.cssText = 'padding: 0.4rem 0.6rem; border-radius: 6px; background: rgba(168,85,247,0.04); border: 1px solid rgba(168,85,247,0.15); display: inline-block; font-family: var(--font-mono); font-size: 0.75rem; color: var(--accent-indigo-text); margin-right: 0.5rem; margin-bottom: 0.5rem;';
          div.textContent = l;
          linksList.appendChild(div);
        });
      }

      // Populate Compose code block
      currentDetailCompose = meta.compose;
      document.getElementById('detail-compose-code').textContent = meta.compose;
    }

    function copyDetailCompose() {
      navigator.clipboard.writeText(currentDetailCompose);
      alert('Docker Compose code block copied to clipboard!');
    }

    // Consolidated System Administration tab switching
    function switchSystemTab(tabName) {
      document.querySelectorAll('.sys-tab-pane').forEach(p => p.style.display = 'none');
      document.querySelectorAll('.sys-tab-btn').forEach(b => b.classList.remove('active'));
      
      const pane = document.getElementById('sys-tab-content-' + tabName);
      const btn = document.getElementById('sys-tab-btn-' + tabName);
      if (pane) pane.style.display = 'block';
      if (btn) btn.classList.add('active');

      // Re-query metrics contextually
      if (tabName === 'vitals') {
        fetchSystemStats();
      } else if (tabName === 'network') {
        loadNetplanState();
      } else if (tabName === 'power') {
        loadPowerScheduleState();
      }
    }

    // Query and render host statistics (vitals/temperature/memory/disks list)
    async function fetchSystemStats() {
      try {
        const res = await fetch('/api/system-stats');
        if (!res.ok) return;
        const stats = await res.json();

        // 1. Update Homepage Vitals Card
        const vitalsCpu = document.getElementById('vitals-cpu-val');
        const vitalsRam = document.getElementById('vitals-ram-val');
        const vitalsTemp = document.getElementById('vitals-temp-val');
        if (vitalsCpu) vitalsCpu.textContent = `${stats.cpu}%`;
        if (vitalsRam) vitalsRam.textContent = `${stats.memory.percent}%`;
        if (vitalsTemp) vitalsTemp.textContent = `${stats.temp}°C`;

        // 2. Update System Page Detailed Vitals
        const sysCpuVal = document.getElementById('sys-cpu-val');
        const sysCpuBar = document.getElementById('sys-cpu-bar');
        const sysRamVal = document.getElementById('sys-ram-val');
        const sysRamBar = document.getElementById('sys-ram-bar');
        const sysRamDetail = document.getElementById('sys-ram-detail');
        const sysTempVal = document.getElementById('sys-temp-val');
        const sysTempBar = document.getElementById('sys-temp-bar');

        if (sysCpuVal) sysCpuVal.textContent = `${stats.cpu}%`;
        if (sysCpuBar) sysCpuBar.style.width = `${stats.cpu}%`;
        if (sysRamVal) sysRamVal.textContent = `${stats.memory.percent}%`;
        if (sysRamBar) sysRamBar.style.width = `${stats.memory.percent}%`;
        if (sysRamDetail) sysRamDetail.textContent = `${stats.memory.used} of ${stats.memory.total} allocated`;
        if (sysTempVal) sysTempVal.textContent = `${stats.temp}°C`;
        if (sysTempBar) {
          // color mapping based on danger thresholds
          sysTempBar.style.width = `${Math.min(stats.temp, 100)}%`;
          if (stats.temp > 70) {
            sysTempBar.style.background = 'var(--accent-red)';
          } else if (stats.temp > 55) {
            sysTempBar.style.background = 'var(--accent-orange)';
          } else {
            sysTempBar.style.background = 'var(--accent-green)';
          }
        }

        // 3. Render Disk Drives list
        const disksTarget = document.getElementById('system-disks-target');
        if (disksTarget) {
          disksTarget.innerHTML = '';
          if (!stats.disks || stats.disks.length === 0) {
            disksTarget.innerHTML = `<tr><td colspan="6" style="padding: 1.5rem; text-align: center; color: var(--text-muted);">No physical storage dev mounts found.</td></tr>`;
          } else {
            stats.disks.forEach(d => {
              const row = document.createElement('tr');
              row.style.borderBottom = '1px solid rgba(255,255,255,0.03)';
              
              const pctVal = parseInt(d.percent.replace('%', ''));
              let barColor = 'var(--accent-green)';
              if (pctVal > 85) {
                barColor = 'var(--accent-red)';
              } else if (pctVal > 70) {
                barColor = 'var(--accent-orange)';
              }

              row.innerHTML = `
                <td style="padding: 0.75rem 1rem; font-family: var(--font-mono); color: var(--text-primary); font-weight: 500;">${d.device}</td>
                <td style="padding: 0.75rem 1rem; color: var(--text-highlight);">${d.mount}</td>
                <td style="padding: 0.75rem 1rem; color: var(--text-secondary);">${d.size}</td>
                <td style="padding: 0.75rem 1rem; color: var(--accent-red);">${d.used}</td>
                <td style="padding: 0.75rem 1rem; color: var(--accent-green);">${d.avail}</td>
                <td style="padding: 0.75rem 1rem; vertical-align: middle;">
                  <div style="display: flex; align-items: center; gap: 0.5rem;">
                    <span style="font-size: 0.75rem; color: var(--text-secondary); font-weight: 600; width: 30px; text-align: right;">${d.percent}</span>
                    <div style="flex-grow: 1; height: 6px; background: rgba(255,255,255,0.05); border-radius: 3px; overflow: hidden; width: 80px;">
                      <div style="height: 100%; width: ${pctVal}%; background: ${barColor};"></div>
                    </div>
                  </div>
                </td>
              `;
              disksTarget.appendChild(row);
            });
          }
        }
      } catch (err) {
        console.error('Failed to query system stats:', err);
      }
    }

    // Power management Scheduler state handling
    async function loadPowerScheduleState() {
      try {
        const res = await fetch('/api/config');
        const config = await res.json();

        const chkSh = document.getElementById('power_enable_shutdown');
        const chkWake = document.getElementById('power_enable_wakeup');
        const txtShTime = document.getElementById('power_shutdown_time');
        const selectShDays = document.getElementById('power_shutdown_days');
        const txtWakeTime = document.getElementById('power_wakeup_time');
        const selectWakeDays = document.getElementById('power_wakeup_days');

        if (chkSh) chkSh.checked = (config.AUTO_SHUTDOWN_ENABLED === 'true');
        if (chkWake) chkWake.checked = (config.AUTO_WAKEUP_ENABLED === 'true');
        if (txtShTime) txtShTime.value = config.AUTO_SHUTDOWN_TIME || '23:00';
        if (selectShDays) selectShDays.value = config.AUTO_SHUTDOWN_DAYS || 'everyday';
        if (txtWakeTime) txtWakeTime.value = config.AUTO_WAKEUP_TIME || '07:00';
        if (selectWakeDays) selectWakeDays.value = config.AUTO_WAKEUP_DAYS || 'everyday';

        togglePowerFields();
      } catch (err) {
        console.error('Failed to load power configurations:', err);
      }
    }

    function togglePowerFields() {
      const enableSh = document.getElementById('power_enable_shutdown').checked;
      const enableWake = document.getElementById('power_enable_wakeup').checked;

      document.getElementById('power_shutdown_time').disabled = !enableSh;
      document.getElementById('power_shutdown_days').disabled = !enableSh;
      document.getElementById('power_wakeup_time').disabled = !enableWake;
      document.getElementById('power_wakeup_days').disabled = !enableWake;
    }

    async function applyPowerSchedule() {
      const enableSh = document.getElementById('power_enable_shutdown').checked;
      const enableWake = document.getElementById('power_enable_wakeup').checked;
      const shTime = document.getElementById('power_shutdown_time').value;
      const shDays = document.getElementById('power_shutdown_days').value;
      const wakeTime = document.getElementById('power_wakeup_time').value;
      const wakeDays = document.getElementById('power_wakeup_days').value;

      // 1. Save settings to .env first
      const updates = {
        AUTO_SHUTDOWN_ENABLED: enableSh ? 'true' : 'false',
        AUTO_SHUTDOWN_TIME: shTime,
        AUTO_SHUTDOWN_DAYS: shDays,
        AUTO_WAKEUP_ENABLED: enableWake ? 'true' : 'false',
        AUTO_WAKEUP_TIME: wakeTime,
        AUTO_WAKEUP_DAYS: wakeDays
      };

      try {
        const saveRes = await fetch('/api/config', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify(updates)
        });

        if (!saveRes.ok) {
          alert('Failed to save power schedule variables to .env config file.');
          return;
        }

        // 2. Run system cron task runner
        const queryUrl = `/api/run?action=schedule-power&sh_time=${encodeURIComponent(shTime)}&sh_days=${encodeURIComponent(shDays)}&wake_time=${encodeURIComponent(wakeTime)}&wake_days=${encodeURIComponent(wakeDays)}&enable_sh=${enableSh}&enable_wake=${enableWake}`;
        
        // Scroll terminal view into sight
        const terminalHeader = document.getElementById('sys-terminal-header');
        if (terminalHeader) terminalHeader.scrollIntoView({ behavior: 'smooth' });

        streamPaneConsole(queryUrl, 'sys-terminal-body');
      } catch (err) {
        console.error('Power schedule task setup failure:', err);
        alert('Setup failure: check server error log console.');
      }
    }