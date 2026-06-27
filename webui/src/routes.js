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
      case 'update': args = ['--update', services || 'all']; break;
      case 'reconfigure': args = ['--reconfigure', services || 'all']; break;
      case 'restart': args = ['--restart', services || 'all']; break;
      case 'prune': args = ['--prune']; break;
      case 'homepage': args = ['--homepage']; break;
      case 'backup': args = ['--backup']; break;
      case 'tailscale': args = ['--tailscale']; break;
      case 'samba': args = ['--install-samba']; break;
      case 'maintenance': args = ['--sys-maintenance']; break;
      case 'git-push': args = ['--git-push']; break;
      case 'sync': args = ['--sync']; break;
      case 'install-docker': args = ['--install-docker']; break;
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
      default:
        res.write('data: Unknown action.\n\n');
        res.end();
        return;
    }

    const spawnFn = (action === 'sync' || action === 'git-push') ? spawnSetupNoSudo : spawnSetup;
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
