const { contextBridge, ipcRenderer, webUtils } = require('electron');
contextBridge.exposeInMainWorld('api', {
  sounds: (path, page) => ipcRenderer.invoke('sounds', { path, page }),
  profile: (soundPage) => ipcRenderer.invoke('profile', soundPage),
  instant: (soundPage) => ipcRenderer.invoke('instant', soundPage),
  open: (what) => ipcRenderer.invoke('open', what),
  favorite: (id) => ipcRenderer.invoke('favorite', id),
  unfavorite: (id) => ipcRenderer.invoke('unfavorite', id),
  deleteSound: (id) => ipcRenderer.invoke('delete-sound', id),
  authStatus: () => ipcRenderer.invoke('auth-status'),
  showSitePage: (path) => ipcRenderer.invoke('show-site-page', path),
  hideSitePage: () => ipcRenderer.invoke('hide-site-page'),
  submitUpload: (data) => ipcRenderer.invoke('submit-upload', data),
  // A <input type=file>'s File object never carries its real disk path to the renderer for security
  // reasons — webUtils.getPathForFile is Electron's own sanctioned way to recover it when the main
  // process genuinely needs to read that exact file (here: to attach it to the real upload POST).
  getPathForFile: (file) => webUtils.getPathForFile(file),
  // iPhone remote (remote.js): settings for the 📱 menu, and the commands the phone sends.
  remoteInfo: () => ipcRenderer.invoke('remote-info'),
  remoteEnable: (on) => ipcRenderer.invoke('remote-enable', on),
  remoteNewPin: () => ipcRenderer.invoke('remote-new-pin'),
  onRemote: (cb) => ipcRenderer.on('remote', (_e, msg) => cb(msg)),
  volumeChanged: (v) => ipcRenderer.send('volume-changed', v),
});
