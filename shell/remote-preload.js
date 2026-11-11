'use strict'

const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('dshRemote', {
  state: () => ipcRenderer.invoke('remote:state'),
  start: (mode) => ipcRenderer.invoke('remote:start', mode),
  stop: () => ipcRenderer.invoke('remote:stop'),
  copy: (text) => ipcRenderer.invoke('remote:copy', text),
  close: () => ipcRenderer.send('remote:close-window')
})
