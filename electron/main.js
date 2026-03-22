const { app, BrowserWindow, dialog, screen, Notification, ipcMain } = require('electron');
const { spawn } = require('child_process');
const http = require('http');
const path = require('path');
const fs = require('fs');
const crypto = require('crypto');

const PORT = 13100;
const BUILD_TAG = '2026-03-21-v8';

// Prevent renderer crashes on Windows VMs with virtual GPU
if (process.platform === 'win32') {
  app.disableHardwareAcceleration();
  app.commandLine.appendSwitch('disable-gpu');
  app.commandLine.appendSwitch('disable-gpu-compositing');
  app.commandLine.appendSwitch('disable-gpu-rasterization');
  app.commandLine.appendSwitch('disable-software-rasterizer');
  app.commandLine.appendSwitch('disable-features', 'CalculateNativeWinOcclusion,GpuProcessHighPriorityWin');
  app.commandLine.appendSwitch('use-gl', 'swiftshader');
  app.commandLine.appendSwitch('in-process-gpu');
}
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

// ── Clean stale data on update ──────────────────────────────

function cleanStaleDataOnUpdate() {
  const data = dataDir();
  const versionFile = path.join(data, '.app_version');
  const currentVersion = app.getVersion();

  // Check if version changed since last run
  let lastVersion = null;
  try { lastVersion = fs.readFileSync(versionFile, 'utf8').trim(); } catch {}

  if (lastVersion === currentVersion) return; // Same version, nothing to clean

  console.log(`[update] Version changed: ${lastVersion || 'fresh'} → ${currentVersion}`);

  // Clear tmp (cached gem specs, bootsnap cache, Bundler cache)
  const tmpDir = path.join(data, 'tmp');
  try {
    if (fs.existsSync(tmpDir)) {
      fs.rmSync(tmpDir, { recursive: true, force: true });
      console.log('[update] Cleared tmp directory');
    }
  } catch (e) {
    console.warn(`[update] Failed to clear tmp: ${e.message}`);
  }

  // Recreate required subdirectories
  ensureDirs(data);

  // Write current version
  try { fs.writeFileSync(versionFile, currentVersion); } catch {}
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

    const cmd = isWin ? process.env.COMSPEC || 'cmd.exe' : '/bin/sh';
    const args = isWin
      ? ['/c', launcherPath, 'db:prepare']
      : [launcherPath, 'db:prepare'];

    // On Windows, set Ruby env vars from JS since batch %~dp0 expansion
    // may not work correctly when spawned from Electron
    const rubyEnv = {};
    if (isWin) {
      const rubyBin = path.join(sidecarDir, 'ruby', 'bin');
      rubyEnv.PATH = `${rubyBin};${path.join(rubyBin, 'ruby_builtin_dlls')};${process.env.PATH || ''}`;
      // Don't set RUBYLIB — RubyInstaller uses --enable-load-relative to find its own stdlib.
      // Setting RUBYLIB causes double-loading of prism.rb and other stdlib files.
      rubyEnv.GEM_HOME = path.join(appDir, 'vendor', 'bundle', 'ruby', '3.4.0');
      rubyEnv.GEM_PATH = `${rubyEnv.GEM_HOME};${path.join(sidecarDir, 'ruby', 'lib', 'ruby', 'gems', '3.4.0')}`;
      rubyEnv.BUNDLE_GEMFILE = path.join(appDir, 'Gemfile');
      rubyEnv.BUNDLE_PATH = path.join(appDir, 'vendor', 'bundle');
    }

    const opts = {
      cwd: appDir,
      env: {
        ...process.env,
        ...rubyEnv,
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
        const stderr = Buffer.concat(stderrChunks).toString();
        // Write full error to file for debugging
        const fs = require('fs');
        const errFile = path.join(data, 'db_prepare_error.txt');
        fs.writeFileSync(errFile, stderr);
        reject(new Error(`db:prepare exited with code ${code}\n${stderr.slice(-2000)}`));
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

    cmd = isWin ? (process.env.COMSPEC || 'cmd.exe') : '/bin/sh';
    args = isWin
      ? ['/c', launcherPath, 'server']
      : [launcherPath, 'server'];

    const appDirServer = path.join(sidecarDir, 'app');
    const rubyEnvServer = {};
    if (isWin) {
      const rubyBin = path.join(sidecarDir, 'ruby', 'bin');
      rubyEnvServer.PATH = `${rubyBin};${path.join(rubyBin, 'ruby_builtin_dlls')};${process.env.PATH || ''}`;
      rubyEnvServer.GEM_HOME = path.join(appDirServer, 'vendor', 'bundle', 'ruby', '3.4.0');
      rubyEnvServer.GEM_PATH = `${rubyEnvServer.GEM_HOME};${path.join(sidecarDir, 'ruby', 'lib', 'ruby', 'gems', '3.4.0')}`;
      rubyEnvServer.BUNDLE_GEMFILE = path.join(appDirServer, 'Gemfile');
      rubyEnvServer.BUNDLE_PATH = path.join(appDirServer, 'vendor', 'bundle');
    }

    opts = {
      cwd: appDirServer,
      env: {
        ...process.env,
        ...rubyEnvServer,
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

  // Write all server output to a log file in the data directory for debugging
  const logFile = path.join(dataDir(), 'server.log');
  const logStream = fs.createWriteStream(logFile, { flags: 'w' });

  const serverLog = [];
  child.stdout.on('data', (chunk) => {
    process.stdout.write(`[rails] ${chunk}`);
    logStream.write(chunk);
    serverLog.push(chunk.toString());
  });

  child.stderr.on('data', (chunk) => {
    process.stderr.write(`[rails] ${chunk}`);
    logStream.write(chunk);
    serverLog.push(chunk.toString());
  });

  child.on('error', (err) => {
    console.error('Failed to start server:', err.message);
  });

  child._serverLog = serverLog;
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
      sandbox: false,
      preload: path.join(__dirname, 'preload.js'),
    },
  });

  mainWindow._lastBounds = mainWindow.getBounds();

  // Enable dev tools via Ctrl+Shift+I even in packaged app
  mainWindow.webContents.on('before-input-event', (event, input) => {
    if (input.control && input.shift && input.key === 'I') {
      mainWindow.webContents.toggleDevTools();
    }
  });

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

  // Clear Electron's HTTP cache to avoid stale assets after updates
  mainWindow.webContents.session.clearCache();

  const baseUrl = url || `http://127.0.0.1:${PORT}`;
  const lastPath = saved && saved.lastPath && saved.lastPath !== '/' ? saved.lastPath : '';
  mainWindow.loadURL(baseUrl + lastPath);

  // Debug: log renderer events
  mainWindow.webContents.on('did-fail-load', (event, errorCode, errorDescription, validatedURL) => {
    console.error(`[renderer] did-fail-load: ${errorCode} ${errorDescription} ${validatedURL}`);
    // Write to log file
    fs.appendFileSync(path.join(dataDir(), 'server.log'), `\n[renderer] did-fail-load: ${errorCode} ${errorDescription} ${validatedURL}\n`);
  });
  mainWindow.webContents.on('did-finish-load', () => {
    console.log('[renderer] did-finish-load: ' + mainWindow.webContents.getURL());
    fs.appendFileSync(path.join(dataDir(), 'server.log'), `\n[renderer] did-finish-load: ${mainWindow.webContents.getURL()}\n`);
  });
  mainWindow.webContents.on('console-message', (event, level, message) => {
    fs.appendFileSync(path.join(dataDir(), 'server.log'), `\n[renderer-console] ${message}\n`);
  });
  let crashCount = 0;
  mainWindow.webContents.on('render-process-gone', (event, details) => {
    crashCount++;
    fs.appendFileSync(path.join(dataDir(), 'server.log'), `\n[renderer] CRASHED #${crashCount}: ${JSON.stringify(details)}\n`);
    // Auto-recover up to 3 times, then give up
    if (crashCount <= 3 && mainWindow && !mainWindow.isDestroyed()) {
      setTimeout(() => mainWindow.loadURL(`http://127.0.0.1:${PORT}`), 2000);
    } else if (mainWindow && !mainWindow.isDestroyed()) {
      dialog.showErrorBox('Renderer Error', `The app renderer crashed ${crashCount} times. Try opening http://127.0.0.1:${PORT} in your browser instead.`);
    }
  });
  mainWindow.webContents.openDevTools({ mode: 'detach' });

  const showMainWindow = () => {
    if (splashWindow && !splashWindow.isDestroyed()) {
      splashWindow.close();
    }
    if (mainWindow && !mainWindow.isDestroyed() && !mainWindow.isVisible()) {
      mainWindow.show();
    }
  };

  mainWindow.once('ready-to-show', showMainWindow);

  // Fallback: show window after timeout even if page fails to load
  setTimeout(showMainWindow, 10000);

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
      // On Windows, cmd.exe /c start.bat spawns ruby.exe as a child process.
      // child.kill() only kills cmd.exe, not ruby.exe. Use taskkill /T to kill
      // the entire process tree.
      const { execSync } = require('child_process');
      try {
        execSync(`taskkill /pid ${child.pid} /T /F`, { stdio: 'ignore' });
      } catch {}
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
    // Write build tag to data dir so we can verify correct main.js is packaged
    const data = dataDir();
    ensureDirs(data);
    fs.writeFileSync(path.join(data, 'build_tag.txt'), BUILD_TAG);

    cleanStaleDataOnUpdate();

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
    const log = (serverProcess?._serverLog || []).join('').slice(-2000);
    const data = dataDir();
    try { fs.writeFileSync(path.join(data, 'server_error.txt'), (serverProcess?._serverLog || []).join('')); } catch {}
    dialog.showErrorBox(
      'Server Error',
      `Rails server failed to start within ${HEALTH_TIMEOUT / 1000} seconds.\n\n${log}`
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
