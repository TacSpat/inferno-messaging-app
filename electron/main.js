const { app, BrowserWindow, dialog, screen, Notification, ipcMain } = require('electron');
const { spawn } = require('child_process');
const http = require('http');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');

const PORT = 13100;
const HEALTH_TIMEOUT = 30000;
const HEALTH_INTERVAL = 500;

let mainWindow = null;
let splashWindow = null;
let serverProcess = null;

// ── Data directory ──────────────────────────────────────────

function dataDir() {
  return path.join(app.getPath('userData'), 'inferno-data');
}

function ensureDirs(base) {
  for (const sub of ['storage/db', 'tmp/pids', 'tmp/cache', 'log']) {
    fs.mkdirSync(path.join(base, sub), { recursive: true });
  }
}

function getOrCreateSecret(base) {
  const secretPath = path.join(base, 'secret_key_base');
  try {
    const secret = fs.readFileSync(secretPath, 'utf8').trim();
    if (secret) return secret;
  } catch {}
  const secret = crypto.randomBytes(64).toString('hex'); // 128 hex chars
  fs.writeFileSync(secretPath, secret);
  return secret;
}

// ── Splash screen ───────────────────────────────────────────

function createSplashWindow() {
  splashWindow = new BrowserWindow({
    width: 400,
    height: 300,
    frame: false,
    resizable: false,
    alwaysOnTop: true,
    backgroundColor: '#0a0a09',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
    },
  });
  splashWindow.loadFile(path.join(__dirname, 'splash.html'));
}

function updateSplashStatus(message) {
  if (splashWindow && !splashWindow.isDestroyed()) {
    splashWindow.webContents.send('status-update', message);
  }
}

// ── Database preparation ────────────────────────────────────

function prepareDatabase() {
  return new Promise((resolve, reject) => {
    const sidecarDir = path.join(process.resourcesPath, 'sidecar');
    const isWin = process.platform === 'win32';
    const launcherName = isWin ? 'start.bat' : 'start.sh';
    const launcherPath = path.join(sidecarDir, launcherName);

    const data = dataDir();
    ensureDirs(data);
    const secret = getOrCreateSecret(data);

    // Verify sidecar files exist
    const appDir = path.join(sidecarDir, 'app');
    console.log(`[db:prepare] sidecarDir: ${sidecarDir}`);
    console.log(`[db:prepare] launcher: ${launcherPath} (exists: ${fs.existsSync(launcherPath)})`);
    console.log(`[db:prepare] appDir: ${appDir} (exists: ${fs.existsSync(appDir)})`);
    console.log(`[db:prepare] ruby: ${path.join(sidecarDir, 'ruby', 'bin', 'ruby')} (exists: ${fs.existsSync(path.join(sidecarDir, 'ruby', 'bin', 'ruby'))})`);
    console.log(`[db:prepare] bundle config: ${path.join(appDir, '.bundle', 'config')} (exists: ${fs.existsSync(path.join(appDir, '.bundle', 'config'))})`);

    const cmd = isWin ? launcherPath : '/bin/sh';
    const args = isWin
      ? ['db:prepare']
      : [launcherPath, 'db:prepare'];
    const opts = {
      cwd: appDir,
      env: {
        ...process.env,
        INFERNO_DATA_DIR: data,
        RAILS_ENV: 'production',
        SECRET_KEY_BASE: secret,
        RAILS_LOG_TO_STDOUT: '1',
      },
    };

    const stderrChunks = [];
    const child = spawn(cmd, args, { ...opts, stdio: ['ignore', 'pipe', 'pipe'] });

    child.stdout.on('data', (chunk) => {
      process.stdout.write(`[db:prepare] ${chunk}`);
    });

    child.stderr.on('data', (chunk) => {
      process.stderr.write(`[db:prepare] ${chunk}`);
      stderrChunks.push(chunk);
    });

    child.on('error', (err) => {
      reject(new Error(`db:prepare failed to start: ${err.message}`));
    });

    child.on('exit', (code) => {
      if (code === 0) {
        resolve();
      } else {
        const stderr = Buffer.concat(stderrChunks).toString().slice(-500);
        reject(new Error(`db:prepare exited with code ${code}\n${stderr}`));
      }
    });
  });
}

// ── Sidecar management ──────────────────────────────────────

function spawnServer() {
  const isDev = !app.isPackaged;
  let cmd, args, opts;

  if (isDev) {
    const railsRoot = path.resolve(__dirname, '..');
    cmd = 'bundle';
    args = ['exec', 'rails', 'server', '-p', String(PORT), '-b', '127.0.0.1'];
    opts = { cwd: railsRoot, env: { ...process.env } };
  } else {
    const sidecarDir = path.join(process.resourcesPath, 'sidecar');
    const isWin = process.platform === 'win32';
    const launcherName = isWin ? 'start.bat' : 'start.sh';
    const launcherPath = path.join(sidecarDir, launcherName);

    const data = dataDir();
    ensureDirs(data);
    const secret = getOrCreateSecret(data);

    cmd = isWin ? launcherPath : '/bin/sh';
    args = isWin
      ? ['server']
      : [launcherPath, 'server'];
    opts = {
      cwd: path.join(sidecarDir, 'app'),
      env: {
        ...process.env,
        INFERNO_DATA_DIR: data,
        RAILS_ENV: 'production',
        PORT: String(PORT),
        PUMA_BIND: '127.0.0.1',
        SECRET_KEY_BASE: secret,
        SOLID_QUEUE_IN_PUMA: 'true',
        RAILS_LOG_TO_STDOUT: '1',
      },
    };
  }

  const child = spawn(cmd, args, { ...opts, stdio: ['ignore', 'pipe', 'pipe'] });

  child.stdout.on('data', (chunk) => {
    process.stdout.write(`[rails] ${chunk}`);
  });

  child.stderr.on('data', (chunk) => {
    process.stderr.write(`[rails] ${chunk}`);
  });

  child.on('error', (err) => {
    console.error('Failed to start server:', err.message);
  });

  return child;
}

// ── Health check ────────────────────────────────────────────

function waitForHealth() {
  return new Promise((resolve) => {
    const start = Date.now();

    const check = () => {
      const req = http.get(`http://127.0.0.1:${PORT}/up`, (res) => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(true);
        } else {
          retry();
        }
        res.resume();
      });

      req.on('error', retry);
      req.setTimeout(2000, () => {
        req.destroy();
        retry();
      });
    };

    const retry = () => {
      if (Date.now() - start >= HEALTH_TIMEOUT) {
        resolve(false);
      } else {
        setTimeout(check, HEALTH_INTERVAL);
      }
    };

    check();
  });
}

function waitForDevServer(url) {
  return new Promise((resolve) => {
    const start = Date.now();

    const check = () => {
      const req = http.get(`${url}/up`, (res) => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(true);
        } else {
          retry();
        }
        res.resume();
      });

      req.on('error', retry);
      req.setTimeout(2000, () => {
        req.destroy();
        retry();
      });
    };

    const retry = () => {
      if (Date.now() - start >= HEALTH_TIMEOUT) {
        resolve(false);
      } else {
        setTimeout(check, HEALTH_INTERVAL);
      }
    };

    check();
  });
}

// ── Window state persistence ────────────────────────────────

const windowStatePath = path.join(app.getPath('userData'), 'window-state.json');

function loadWindowState() {
  try {
    return JSON.parse(fs.readFileSync(windowStatePath, 'utf8'));
  } catch {
    return null;
  }
}

function saveWindowState() {
  if (!mainWindow) return;
  const isMaximized = mainWindow.isMaximized();
  const bounds = isMaximized ? mainWindow._lastBounds : mainWindow.getBounds();
  let lastPath = '/';
  try {
    const currentUrl = mainWindow.webContents.getURL();
    lastPath = new URL(currentUrl).pathname;
  } catch {}
  fs.writeFileSync(windowStatePath, JSON.stringify({ ...bounds, isMaximized, lastPath }));
}

function isStateOnScreen(state) {
  const displays = screen.getAllDisplays();
  return displays.some((d) => {
    const { x, y, width, height } = d.bounds;
    return state.x >= x && state.y >= y
      && state.x + state.width <= x + width
      && state.y + state.height <= y + height;
  });
}

// ── Main window ─────────────────────────────────────────────

function createMainWindow(url) {
  const saved = loadWindowState();
  const useSaved = saved && isStateOnScreen(saved);

  let windowOpts;
  if (useSaved) {
    windowOpts = { x: saved.x, y: saved.y, width: saved.width, height: saved.height };
  } else {
    const cursor = screen.getCursorScreenPoint();
    const display = screen.getDisplayNearestPoint(cursor);
    const { x, y, width, height } = display.workArea;
    const w = 1280, h = 800;
    windowOpts = { x: x + Math.round((width - w) / 2), y: y + Math.round((height - h) / 2), width: w, height: h };
  }

  mainWindow = new BrowserWindow({
    ...windowOpts,
    minWidth: 800,
    minHeight: 500,
    show: false,
    title: 'Inferno',
    autoHideMenuBar: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  mainWindow._lastBounds = mainWindow.getBounds();

  if (useSaved && saved.isMaximized) {
    mainWindow.maximize();
  }

  mainWindow.on('resize', () => {
    if (!mainWindow.isMaximized()) mainWindow._lastBounds = mainWindow.getBounds();
  });
  mainWindow.on('move', () => {
    if (!mainWindow.isMaximized()) mainWindow._lastBounds = mainWindow.getBounds();
  });
  mainWindow.on('close', saveWindowState);

  mainWindow.setMenuBarVisibility(false);

  const baseUrl = url || `http://127.0.0.1:${PORT}`;
  const lastPath = saved && saved.lastPath && saved.lastPath !== '/' ? saved.lastPath : '';
  mainWindow.loadURL(baseUrl + lastPath);

  mainWindow.once('ready-to-show', () => {
    if (splashWindow && !splashWindow.isDestroyed()) {
      splashWindow.close();
    }
    mainWindow.show();
  });

  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

// ── Graceful shutdown ───────────────────────────────────────

function killServer() {
  if (!serverProcess) return;

  return new Promise((resolve) => {
    const child = serverProcess;
    serverProcess = null;

    if (process.platform !== 'win32') {
      child.kill('SIGTERM');

      const timeout = setTimeout(() => {
        child.kill('SIGKILL');
        resolve();
      }, 5000);

      child.on('exit', () => {
        clearTimeout(timeout);
        resolve();
      });
    } else {
      child.kill();
      resolve();
    }
  });
}

// ── IPC: notifications & badge ───────────────────────────────

function setupIPC() {
  ipcMain.on('show-notification', (_event, opts) => {
    if (!Notification.isSupported()) return;
    const notif = new Notification({ title: opts.title || 'Inferno', body: opts.body || '', silent: true });
    notif.on('click', () => {
      if (mainWindow) {
        if (mainWindow.isMinimized()) mainWindow.restore();
        mainWindow.focus();
        mainWindow.webContents.send('notification-click', { navigateTo: opts.navigateTo });
      }
    });
    notif.show();
  });

  ipcMain.on('set-badge-count', (_event, count) => {
    if (process.platform === 'win32') {
      if (mainWindow) mainWindow.flashFrame(count > 0);
    } else {
      app.setBadgeCount(count);
    }
  });
}

function setupWindowFocusForwarding() {
  if (!mainWindow) return;
  mainWindow.on('focus', () => {
    mainWindow.webContents.send('window-focus', true);
  });
  mainWindow.on('blur', () => {
    mainWindow.webContents.send('window-focus', false);
  });
}

// ── Auto-updater ────────────────────────────────────────────

function setupAutoUpdater() {
  const { autoUpdater } = require('electron-updater');
  autoUpdater.autoDownload = false;

  autoUpdater.on('update-available', (info) => {
    dialog.showMessageBox(mainWindow, {
      type: 'info',
      title: 'Update Available',
      message: `Version ${info.version} is available. Download now?`,
      buttons: ['Download', 'Later'],
    }).then((result) => {
      if (result.response === 0) {
        autoUpdater.downloadUpdate();
      }
    });
  });

  autoUpdater.on('update-downloaded', () => {
    dialog.showMessageBox(mainWindow, {
      type: 'info',
      title: 'Update Ready',
      message: 'Update downloaded. The app will restart to install it.',
      buttons: ['Restart Now', 'Later'],
    }).then((result) => {
      if (result.response === 0) {
        autoUpdater.quitAndInstall();
      }
    });
  });

  autoUpdater.checkForUpdates().catch(() => {});
}

// ── App lifecycle ───────────────────────────────────────────

const devUrl = process.env.ELECTRON_DEV_URL;

app.whenReady().then(async () => {
  setupIPC();

  if (devUrl) {
    createSplashWindow();
    updateSplashStatus('Connecting to dev server...');

    const healthy = await waitForDevServer(devUrl);
    if (!healthy) {
      dialog.showErrorBox('Dev Server Error', `Could not connect to ${devUrl}. Is your Rails server running?`);
      app.quit();
      return;
    }

    createMainWindow(devUrl);
    setupWindowFocusForwarding();
    return;
  }

  const isDev = !app.isPackaged;

  createSplashWindow();

  if (!isDev) {
    updateSplashStatus('Preparing database...');
    try {
      await prepareDatabase();
    } catch (err) {
      dialog.showErrorBox('Database Error', `Failed to prepare database: ${err.message}`);
      app.quit();
      return;
    }
  }

  updateSplashStatus('Starting server...');
  serverProcess = spawnServer();

  updateSplashStatus('Waiting for server...');
  const healthy = await waitForHealth();

  if (!healthy) {
    dialog.showErrorBox(
      'Server Error',
      `Rails server failed to start within ${HEALTH_TIMEOUT / 1000} seconds.`
    );
    await killServer();
    app.quit();
    return;
  }

  updateSplashStatus('Loading app...');
  createMainWindow();
  setupWindowFocusForwarding();

  if (!isDev) {
    setupAutoUpdater();
  }
});

app.on('window-all-closed', async () => {
  if (!devUrl) {
    await killServer();
  }
  app.quit();
});

app.on('before-quit', async (event) => {
  if (serverProcess) {
    event.preventDefault();
    await killServer();
    app.quit();
  }
});
