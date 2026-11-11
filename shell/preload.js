'use strict'

const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('dshMobile', {
  openRemote: () => ipcRenderer.send('remote:open-window')
})
