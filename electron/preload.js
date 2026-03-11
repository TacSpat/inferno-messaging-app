const { contextBridge, ipcRenderer, webFrame } = require('electron');
webFrame.setZoomFactor(1);

contextBridge.exposeInMainWorld('electronAPI', {
  onStatusUpdate: (callback) => ipcRenderer.on('status-update', (_event, msg) => callback(msg)),
  showNotification: (opts) => ipcRenderer.send('show-notification', opts),
  setBadgeCount: (count) => ipcRenderer.send('set-badge-count', count),
  onNotificationClick: (callback) => ipcRenderer.on('notification-click', (_event, data) => callback(data)),
  onFocusChange: (callback) => ipcRenderer.on('window-focus', (_event, focused) => callback(focused)),
  platform: process.platform,
});
