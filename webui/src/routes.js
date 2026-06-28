const fs = require('fs');
const path = require('path');
const { spawnSetup, spawnSetupNoSudo, isMac, baseEnv, exec } = require('./runner');
const { parseEnv, writeEnv } = require('./config');

/**
 * Main HTTP request dispatcher.
 * Routes traffic to specific controllers adhering to Single Responsibility.
 * @param {http.IncomingMessage} req Incoming HTTP request
 * @param {http.ServerResponse} res Outgoing HTTP response
 */
function handleRequest(req, res) {
  // Setup standard headers
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (req.method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  // Router dispatcher
  if (req.method === 'GET') {
    handleGetRoute(req, res);
  } else if (req.method === 'POST') {
    handlePostRoute(req, res);
  } else {
    res.writeHead(405);
    res.end('Method Not Allowed');
  }
}

/**
 * Controller for all GET endpoints
 */
function handleGetRoute(req, res) {
  const parsedUrl = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
  const pathname = parsedUrl.pathname;

  // Static Assets Routes
  if (pathname === '/' || pathname === '/index.html') {
    serveStaticFile(path.join(__dirname, '../index.html'), 'text/html', res);
    return;
  }
  if (pathname === '/styles.css') {
    serveStaticFile(path.join(__dirname, '../public/styles.css'), 'text/css', res);
    return;
  }
  if (pathname === '/app.js') {
    serveStaticFile(path.join(__dirname, '../public/app.js'), 'application/javascript', res);
    return;
  }
  if (pathname.startsWith('/logos/') && pathname.endsWith('.png')) {
    const logoName = path.basename(pathname);
    const logoPath = path.join(__dirname, '../public/logos', logoName);
    serveStaticFile(logoPath, 'image/png', res);
    return;
  }

  // API Route: Get Status of Docker Containers
  if (pathname === '/api/status') {
    if (isMac) {
      // Mock docker status for local macOS development
      const containers = {
        media_jellyfin: 'running',
        media_qbittorrent: 'running',
        immich_server: 'running',
        nextcloud_app: 'running',
        utility_vaultwarden: 'running',
        media_radarr: 'running',
        media_sonarr: 'running',
        media_prowlarr: 'running',
        utility_tailscale: 'running'
      };
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ containers }, null, 2));
      return;
    }

    // Try executing without sudo first (failsafe for NoNewPrivileges sandboxes if in docker group)
    // If it fails, fallback to sudo.
    exec('docker ps -a --format "{{.Names}}:{{.State}}"', (err, stdout) => {
      if (!err) {
        sendDockerStatus(stdout, res);
      } else {
        exec('sudo docker ps -a --format "{{.Names}}:{{.State}}"', (sudoErr, sudoStdout) => {
          if (sudoErr) {
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: sudoErr.message }));
          } else {
            sendDockerStatus(sudoStdout, res);
          }
        });
      }
    });
    return;
  }

  // API Route: Get Current Environment Configurations
  if (pathname === '/api/config') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(parseEnv(), null, 2));
    return;
  }

  // API Route: Get Samba Details
  if (pathname === '/api/samba') {
    const child = spawnSetup(['--samba-info'], { cwd: path.join(__dirname, '../..') });
    pipeProcessOutput(child, res);
    return;
  }

  // API Route: Get Netplan Configuration Details
  if (pathname === '/api/netplan') {
    const child = spawnSetup(['--netplan-info'], { cwd: path.join(__dirname, '../..') });
    pipeProcessOutput(child, res);
    return;
  }

  // API Route: Start, Stop, or Restart Docker Containers
  if (pathname === '/api/container-action') {
    if (isMac) {
      // Mock success for development
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ success: true, mock: true }));
      return;
    }
    const service = parsedUrl.searchParams.get('container');
    const containerAction = parsedUrl.searchParams.get('action'); // start, stop, restart
    if (!service || !['start', 'stop', 'restart'].includes(containerAction)) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: 'Invalid parameters' }));
      return;
    }

    exec('docker ps > /dev/null 2>&1', (err) => {
      const cmd = err ? `sudo docker ${containerAction} ${service}` : `docker ${containerAction} ${service}`;
      exec(cmd, (execErr, stdout) => {
        if (execErr) {
          res.writeHead(500, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ error: execErr.message }));
        } else {
          res.writeHead(200, { 'Content-Type': 'application/json' });
          res.end(JSON.stringify({ success: true, output: stdout.trim() }));
        }
      });
    });
    return;
  }

  // API Route: Get detailed host system statistics (vitals, storage)
  if (pathname === '/api/system-stats') {
    if (isMac) {
      // Mock stats for macOS development
      const stats = {
        cpu: parseFloat((10 + Math.random() * 15).toFixed(1)),
        memory: {
          total: "16.0 GB",
          used: "8.4 GB",
          free: "7.6 GB",
          percent: 52.5
        },
        temp: parseFloat((40 + Math.random() * 8).toFixed(1)),
        uptime: "up 2 days, 14 hours, 5 minutes",
        os: "macOS Dev (Darwin)",
        net_rx: Math.floor(1024 * 1024 * 100 + Math.random() * 1024 * 1024 * 10),
        net_tx: Math.floor(1024 * 1024 * 50 + Math.random() * 1024 * 1024 * 5),
        samba_conns: 2,
        tailscale_ip: "100.80.90.100",
        tailscale_peers: 5,
        load_avg: "0.15 0.28 0.35",
        swap: { total: "4.0 GB", used: "1.2 GB" },
        disks: [
          { device: '/dev/disk1s1s1', fstype: 'apfs', size: '228.3 GiB', used: '162.1 GiB', avail: '66.2 GiB', percent: '71%', mount: '/' },
          { device: '/dev/disk3s1', fstype: 'apfs', size: '931.5 GiB', used: '452.0 GiB', avail: '479.5 GiB', percent: '49%', mount: '/Volumes/Storage' }
        ]
      };
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify(stats, null, 2));
      return;
    }

    // On Linux: execute native commands to fetch host metrics
    const statsCmd = `
      # 1. CPU Usage
      CPU_IDLE=\$(top -bn1 | grep -i "cpu(s)" | awk -F',' '{for(i=1;i<=NF;i++){if(\$i ~ /id/){print \$i}}}' | awk '{print \$1}')
      if [ -z "\$CPU_IDLE" ]; then CPU_IDLE=100; fi
      CPU_USAGE=\$(awk -v idle="\$CPU_IDLE" 'BEGIN {print 100 - idle}')
      if [ -z "\$CPU_USAGE" ]; then CPU_USAGE=0; fi

      # 2. Memory Usage (MB)
      MEM_TOTAL=\$(free -m | awk 'NR==2{print \$2}')
      MEM_USED=\$(free -m | awk 'NR==2{print \$3}')
      if [ -z "\$MEM_TOTAL" ] || [ "\$MEM_TOTAL" -eq 0 ]; then MEM_TOTAL=1; MEM_USED=0; fi
      MEM_PCT=\$(awk -v total="\$MEM_TOTAL" -v used="\$MEM_USED" 'BEGIN {printf "%.1f", (used*100)/total}')

      # 3. CPU Temperature
      CPU_TEMP=0
      if [ -f /sys/class/thermal/thermal_zone0/temp ]; then
        CPU_TEMP=\$(cat /sys/class/thermal/thermal_zone0/temp)
        CPU_TEMP=\$(awk -v temp="\$CPU_TEMP" 'BEGIN {printf "%.1f", temp/1000}')
      elif command -v sensors &>/dev/null; then
        CPU_TEMP=\$(sensors | grep -i "package id" | head -1 | awk '{print \$4}' | tr -d '+°C' || echo 0)
      fi
      if [ -z "\$CPU_TEMP" ]; then CPU_TEMP=0; fi

      # 4. Host Uptime
      UPTIME_VAL=\$(uptime -p 2>/dev/null || uptime | awk '{print "up", \$3, \$4}' | tr -d ',')
      if [ -z "\$UPTIME_VAL" ]; then UPTIME_VAL="up 0 hours"; fi

      # 5. OS version name
      OS_NAME="Linux"
      if [ -f /etc/os-release ]; then
        OS_NAME=\$(grep -E "^PRETTY_NAME=" /etc/os-release | cut -d'=' -f2 | tr -d '"')
      else
        OS_NAME=\$(uname -sr)
      fi

      # 6. Default network interface RX/TX bytes
      DEFAULT_IFACE=\$(ip route 2>/dev/null | grep default | awk '{print \$5}' | head -1)
      if [ -z "\$DEFAULT_IFACE" ]; then DEFAULT_IFACE=\$(ls /sys/class/net | grep -v lo | head -1); fi
      if [ -n "\$DEFAULT_IFACE" ]; then
        NET_RX=\$(cat /sys/class/net/\$DEFAULT_IFACE/statistics/rx_bytes 2>/dev/null || echo 0)
        NET_TX=\$(cat /sys/class/net/\$DEFAULT_IFACE/statistics/tx_bytes 2>/dev/null || echo 0)
      else
        NET_RX=0
        NET_TX=0
      fi

      # 7. Samba Connections Count
      SAMBA_CONNS=0
      if command -v smbstatus &>/dev/null; then
        SAMBA_CONNS=\$(smbstatus -p 2>/dev/null | grep -v "PID" | grep -v "\-\-\-\-" | grep -v "^$" | wc -l || echo 0)
      fi

      # 8. Tailscale details
      TS_IP="N/A"
      TS_PEERS=0
      if command -v tailscale &>/dev/null; then
        TS_IP=\$(tailscale ip -4 2>/dev/null || echo "N/A")
        TS_PEERS=\$(tailscale status 2>/dev/null | grep -v "Self" | grep -v "^$" | wc -l || echo 0)
      fi

      # 9. System Load Average (1m, 5m, 15m)
      LOAD_AVG=\$(cat /proc/loadavg 2>/dev/null | awk '{print \$1" "\$2" "\$3}' || echo "0.0 0.0 0.0")

      # 10. Swap usage
      SWAP_TOTAL=\$(free -m | awk 'NR==3{print \$2}' || echo 0)
      SWAP_USED=\$(free -m | awk 'NR==3{print \$3}' || echo 0)

      # Format output
      echo "\$CPU_USAGE|\$MEM_TOTAL|\$MEM_USED|\$MEM_PCT|\$CPU_TEMP|\$UPTIME_VAL|\$OS_NAME|\$NET_RX|\$NET_TX|\$SAMBA_CONNS|\$TS_IP|\$TS_PEERS|\$LOAD_AVG|\$SWAP_TOTAL|\$SWAP_USED"
    `;

    exec(statsCmd, (err, stdout) => {
      if (err) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: err.message }));
        return;
      }
      
      const parts = stdout.trim().split('|');
      if (parts.length < 15) {
        res.writeHead(500, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ error: 'Failed to parse full system metrics' }));
        return;
      }

      const cpu = parseFloat(parts[0]);
      const memTotalVal = parseInt(parts[1]);
      const memUsedVal = parseInt(parts[2]);
      const memPct = parseFloat(parts[3]);
      const temp = parseFloat(parts[4]);
      const uptime = parts[5];
      const osName = parts[6] || 'Linux Host';
      const netRx = parseInt(parts[7]);
      const netTx = parseInt(parts[8]);
      const sambaConns = parseInt(parts[9]);
      const tsIp = parts[10];
      const tsPeers = parseInt(parts[11]);
      const loadAvg = parts[12];
      const swapTotal = parseInt(parts[13]);
      const swapUsed = parseInt(parts[14]);

      // Fetch storage devices usage (df -hP)
      exec('df -hP', (dfErr, dfStdout) => {
        const disks = [];
        if (!dfErr) {
          dfStdout.split('\n').forEach(line => {
            const cols = line.trim().split(/\s+/);
            if (cols.length >= 6 && cols[0].startsWith('/dev/')) {
              disks.push({
                device: cols[0],
                fstype: 'ext4',
                size: cols[1],
                used: cols[2],
                avail: cols[3],
                percent: cols[4],
                mount: cols[5]
              });
            }
          });
        }

        const stats = {
          cpu,
          memory: {
            total: (memTotalVal / 1024).toFixed(1) + " GB",
            used: (memUsedVal / 1024).toFixed(1) + " GB",
            free: ((memTotalVal - memUsedVal) / 1024).toFixed(1) + " GB",
            percent: memPct
          },
          temp,
          uptime,
          os: osName,
          net_rx: netRx,
          net_tx: netTx,
          samba_conns: sambaConns,
          tailscale_ip: tsIp,
          tailscale_peers: tsPeers,
          load_avg: loadAvg,
          swap: {
            total: (swapTotal / 1024).toFixed(1) + " GB",
            used: (swapUsed / 1024).toFixed(1) + " GB"
          },
          disks
        };

        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify(stats, null, 2));
      });
    });
    return;
  }

  // API Route: Server-Sent Events (SSE) Live Container Logs
  if (pathname === '/api/logs') {
    const service = parsedUrl.searchParams.get('service');
    if (!service) {
      res.writeHead(400);
      res.end('Missing service parameter');
      return;
    }

    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive'
    });
    res.write(`data: [Streaming real-time logs for container: ${service}]\n\n`);

    // Probe if user can run docker without sudo, then spawn matching process
    exec('docker ps > /dev/null 2>&1', (err) => {
      const dockerBinary = err ? 'sudo' : 'docker';
      const dockerArgs = err ? ['docker', 'logs', '-f', '--tail', '200', service] : ['logs', '-f', '--tail', '200', service];
      const child = spawnSetup(err ? [] : [], { shell: false }); // Stub setup.sh spawn, run custom
      const logProcess = require('child_process').spawn(dockerBinary, dockerArgs, { env: baseEnv });

      logProcess.stdout.on('data', data => sendSseCleanLine(data, res));
      logProcess.stderr.on('data', data => sendSseCleanLine(data, res));
      logProcess.on('close', code => {
        res.write(`data: [Log stream finished with code ${code}]\n\n`);
        res.end();
      });
      req.on('close', () => logProcess.kill());
    });
    return;
  }

  // API Route: Server-Sent Events (SSE) Guided Setup Runner
  if (pathname === '/api/run') {
    const action = parsedUrl.searchParams.get('action');
    const services = parsedUrl.searchParams.get('services') || '';

    res.writeHead(200, {
      'Content-Type': 'text/event-stream',
      'Cache-Control': 'no-cache',
      'Connection': 'keep-alive'
    });
    res.write('data: Starting task...\n\n');

    let args = [];
    let env = { ...process.env, NON_INTERACTIVE: 'true' };

    switch (action) {
      case 'nuke': args = ['--nuke', services || 'all']; break;
      case 'update':
        args = ['--update', services || 'all'];
        if (parsedUrl.searchParams.get('only_pull') === 'true') {
          args.push('--only-pull');
        }
        break;
      case 'reconfigure': args = ['--reconfigure', services || 'all']; break;
      case 'restart': args = ['--restart', services || 'all']; break;
      case 'prune': args = ['--prune']; break;
      case 'homepage': args = ['--homepage']; break;
      case 'backup': args = ['--backup']; break;
      case 'tailscale': args = ['--tailscale']; break;
      case 'samba': args = ['--install-samba']; break;
      case 'maintenance': args = ['--sys-maintenance']; break;
      case 'install-docker': args = ['--install-docker']; break;
      case 'sync': args = ['--sync']; break;
      case 'check-updates': args = ['--check-updates']; break;
      case 'netplan-static':
        args = [
          '--set-static-ip',
          parsedUrl.searchParams.get('iface') || '',
          parsedUrl.searchParams.get('ip') || '',
          parsedUrl.searchParams.get('gw') || '',
          parsedUrl.searchParams.get('dns1') || '',
          parsedUrl.searchParams.get('dns2') || ''
        ];
        break;
      case 'netplan-dhcp':
        args = ['--set-dhcp', parsedUrl.searchParams.get('iface') || ''];
        break;
      case 'restart-network-webui':
        args = ['--restart-network-webui'];
        break;
      case 'host-reboot':
        args = ['--host-reboot'];
        break;
      case 'host-shutdown':
        args = ['--host-shutdown'];
        break;
      case 'schedule-power':
        args = [
          '--schedule-power',
          parsedUrl.searchParams.get('sh_time') || '',
          parsedUrl.searchParams.get('sh_days') || '',
          parsedUrl.searchParams.get('wake_time') || '',
          parsedUrl.searchParams.get('wake_days') || '',
          parsedUrl.searchParams.get('enable_sh') || '',
          parsedUrl.searchParams.get('enable_wake') || ''
        ];
        break;
      default:
        res.write('data: Unknown action.\n\n');
        res.end();
        return;
    }

    const spawnFn = (action === 'sync') ? spawnSetupNoSudo : spawnSetup;
    const child = spawnFn(args, { cwd: path.join(__dirname, '../..'), env });

    child.stdout.on('data', data => sendSseCleanLine(data, res));
    child.stderr.on('data', data => sendSseCleanLine(data, res, true));
    child.on('close', code => {
      res.write(`data: Task finished with exit code ${code}\n\n`);
      res.end();
    });
    req.on('close', () => child.kill());
    return;
  }

  // Not Found fallback
  res.writeHead(404);
  res.end('Not Found');
}

/**
 * Controller for all POST endpoints
 */
function handlePostRoute(req, res) {
  const pathname = req.url;

  // API Route: Save Configuration
  if (pathname === '/api/config') {
    readBody(req, (err, body) => {
      if (err) return sendJsonError(res, 'Invalid request body');
      try {
        const config = JSON.parse(body);
        const existing = parseEnv();
        writeEnv({ ...existing, ...config });
        res.writeHead(200, { 'Content-Type': 'application/json' });
        res.end(JSON.stringify({ success: true }));
      } catch (e) {
        sendJsonError(res, 'Invalid JSON payload');
      }
    });
    return;
  }

  // API Route: Samba Actions (install, add/remove user, add/remove share)
  if (pathname === '/api/samba/action') {
    readBody(req, (err, body) => {
      if (err) return sendJsonError(res, 'Invalid request body');
      try {
        const payload = JSON.parse(body);
        const { action, username, password, share_name, share_path, valid_users, guest_ok, read_only } = payload;
        
        let args = [];
        if (action === 'install') args = ['--install-samba'];
        else if (action === 'add-user') args = ['--samba-add-user', username, password];
        else if (action === 'remove-user') args = ['--samba-remove-user', username];
        else if (action === 'add-share') args = ['--samba-add-share', share_name, share_path, valid_users, guest_ok, read_only];
        else if (action === 'remove-share') args = ['--samba-remove-share', share_name];
        else return sendJsonError(res, 'Invalid Samba action', 400);

        const child = spawnSetup(args, { cwd: path.join(__dirname, '../..') });
        let stdout = '';
        let stderr = '';
        child.stdout.on('data', data => stdout += data.toString());
        child.stderr.on('data', data => stderr += data.toString());
        child.on('close', code => {
          if (code === 0) {
            res.writeHead(200, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ success: true, output: stdout }));
          } else {
            res.writeHead(500, { 'Content-Type': 'application/json' });
            res.end(JSON.stringify({ error: stderr || `Exited with code ${code}` }));
          }
        });
      } catch (e) {
        sendJsonError(res, 'Invalid JSON payload');
      }
    });
    return;
  }

  // API Route: Restart Portal Server Process
  if (pathname === '/api/restart-server') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ ok: true, message: 'Restarting server...' }));

    setTimeout(() => {
      // Elegant restart strategy that respects NoNewPrivileges sandbox constraints:
      // 1. If running as a systemd service, systemctl is-active will be successful. We can exit with code 1.
      //    The process supervisor (systemd) automatically triggers Restart=on-failure to restart it.
      // 2. If running standalone (macOS / dev), spawn a detached background shell to kill and restart.
      if (isMac) {
        process.exit(0);
        return;
      }

      exec('systemctl is-active --quiet homeserver-webui', (err) => {
        if (!err) {
          console.log('[restart] Active systemd service detected. Exiting to trigger systemd supervisor restart.');
          process.exit(1);
        } else {
          console.log('[restart] Standalone mode. Initiating detached shell reboot.');
          const scriptPath = path.join(__dirname, '../server.js');
          const restartCmd = `sleep 1 && kill -9 ${process.pid} ; sleep 1 && node ${scriptPath} &`;
          const shell = require('child_process').spawn('bash', ['-c', restartCmd], {
            detached: true,
            stdio: 'ignore',
            env: baseEnv
          });
          shell.unref();
          process.exit(0);
        }
      });
    }, 500);
    return;
  }

  res.writeHead(404);
  res.end('Not Found');
}

// Helper: Serve a static file with appropriate Content-Type
function serveStaticFile(filePath, contentType, res) {
  if (fs.existsSync(filePath)) {
    res.writeHead(200, { 'Content-Type': contentType });
    res.end(fs.readFileSync(filePath));
  } else {
    res.writeHead(404);
    res.end(`${path.basename(filePath)} not found`);
  }
}

// Helper: Read complete request body buffer
function readBody(req, callback) {
  let body = '';
  req.on('data', chunk => body += chunk);
  req.on('end', () => callback(null, body));
  req.on('error', err => callback(err));
}

// Helper: Standardized JSON error response
function sendJsonError(res, message, status = 400) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: message }));
}

// Helper: Format docker ps output and return JSON
function sendDockerStatus(stdout, res) {
  const containers = {};
  stdout.split('\n').forEach(line => {
    const parts = line.trim().split(':');
    if (parts.length === 2) {
      containers[parts[0]] = parts[1];
    }
  });
  res.writeHead(200, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ containers }, null, 2));
}

// Helper: Pipe output streams directly to response
function pipeProcessOutput(child, res) {
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', data => stdout += data.toString());
  child.stderr.on('data', data => stderr += data.toString());
  child.on('close', code => {
    if (code === 0) {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(stdout);
    } else {
      res.writeHead(500, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ error: stderr || `Process exited with code ${code}` }));
    }
  });
}

// Helper: Clear ansi colors and send clean line to SSE client
function sendSseCleanLine(data, res, isError = false) {
  const lines = data.toString().split('\n');
  lines.forEach(line => {
    if (line.trim()) {
      const cleaned = line.replace(/[\u001b\u009b][[()#;?]*(?:[0-9]{1,4}(?:;[0-9]{0,4})*)?[0-9A-ORZcf-nqry=><]/g, '');
      res.write(`data: ${isError ? '[ERROR] ' : ''}${cleaned}\n\n`);
    }
  });
}

module.exports = {
  handleRequest
};
