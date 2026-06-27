const { spawn, exec } = require('child_process');
const path = require('path');

const isMac = process.platform === 'darwin';

// Augment PATH to include system binary directories (/usr/sbin, /sbin etc.)
// ensuring systemd or custom service environments can discover netplan/iptables.
const baseEnv = {
  ...process.env,
  PATH: [process.env.PATH, '/usr/sbin', '/usr/bin', '/sbin', '/bin'].filter(Boolean).join(':')
};

/**
 * Spawns setup.sh as root (using sudo on Linux) for privileged system alterations.
 * Bypasses sudo automatically on macOS to facilitate dev environments.
 * @param {Array<string>} args CLI arguments to pass to setup.sh
 * @param {Object} options Additional child_process spawn options
 */
function spawnSetup(args, options = {}) {
  const scriptPath = path.join(__dirname, '../../setup.sh');
  const isRoot = process.getuid && process.getuid() === 0;
  const cmd = (isMac || isRoot) ? 'bash' : 'sudo';
  const spawnArgs = (isMac || isRoot) ? [scriptPath, ...args] : ['bash', scriptPath, ...args];
  const mergedEnv = options.env ? { ...baseEnv, ...options.env } : baseEnv;
  return spawn(cmd, spawnArgs, { ...options, env: mergedEnv });
}

/**
 * Spawns setup.sh as the current unprivileged user.
 * Essential for operations like git sync and push that run in systemd
 * environments where NoNewPrivileges prohibits sudo elevation.
 * @param {Array<string>} args CLI arguments to pass to setup.sh
 * @param {Object} options Additional child_process spawn options
 */
function spawnSetupNoSudo(args, options = {}) {
  const scriptPath = path.join(__dirname, '../../setup.sh');
  const mergedEnv = options.env ? { ...baseEnv, ...options.env } : baseEnv;
  return spawn('bash', [scriptPath, ...args], { ...options, env: mergedEnv });
}

module.exports = {
  spawnSetup,
  spawnSetupNoSudo,
  isMac,
  baseEnv,
  exec
};
