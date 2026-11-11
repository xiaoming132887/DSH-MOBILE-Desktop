'use strict'

const { app, BrowserWindow, shell, session, ipcMain, Menu, Tray, clipboard, globalShortcut } = require('electron')
const path = require('node:path')
const fs = require('node:fs')
const os = require('node:os')
const net = require('node:net')
const crypto = require('node:crypto')
const { spawn } = require('node:child_process')

const APP_ROOT = path.resolve(__dirname, '..')
const APP_TITLE = process.env.DSH_MOBILE_TITLE || 'DSH-MOBILE'
const DATA_ROOT = process.env.DSH_MOBILE_DATA || path.join(APP_ROOT, 'data')
const ELECTRON_DATA = process.env.DSH_MOBILE_ELECTRON_DIR || path.join(DATA_ROOT, 'electron')
const TARGET_URL = process.env.DSH_MOBILE_URL || 'http://127.0.0.1:49760'
const LOG_DIR = path.join(DATA_ROOT, 'logs')
const REMOTE_DIR = path.join(DATA_ROOT, 'remote')
const CLOUDFLARED = path.join(APP_ROOT, 'runtime', 'cloudflared.exe')
const IS_REMOTE_PHONE = process.env.DSH_MOBILE_ALLOW_MULTI === '1'

fs.mkdirSync(ELECTRON_DATA, { recursive: true })
fs.mkdirSync(LOG_DIR, { recursive: true })
fs.mkdirSync(REMOTE_DIR, { recursive: true })

app.setName(APP_TITLE)
app.setPath('userData', ELECTRON_DATA)
app.setPath('sessionData', path.join(ELECTRON_DATA, 'session'))
app.setAppUserModelId('app.dsh.mobile')

let mainWindow = null
let remoteWindow = null
let tray = null
let proxyChild = null
let proxyPort = 0
let proxyCode = ''
let proxyUrls = []
let proxyMode = 'lan'
let proxyLocalUrls = []
let tunnelChild = null
let publicUrl = ''

function log(line) {
  try {
    fs.appendFileSync(path.join(LOG_DIR, 'shell.log'), `[${new Date().toISOString()}] ${line}\n`)
  } catch {}
}

function showMainWindow() {
  if (!mainWindow) return
  if (mainWindow.isMinimized()) mainWindow.restore()
  mainWindow.show()
  mainWindow.focus()
}

// ------------------------------------------------------------------ remote LAN proxy
function enginePort() {
  try {
    const parsed = new URL(TARGET_URL)
    return Number(parsed.port || (parsed.protocol === 'https:' ? 443 : 80))
  } catch {
    return 0
  }
}

function lanUrls(port) {
  const urls = []
  const interfaces = os.networkInterfaces()
  for (const entries of Object.values(interfaces)) {
    for (const entry of entries || []) {
      if (!entry || entry.family !== 'IPv4' || entry.internal) continue
      if (entry.address.startsWith('169.254.')) continue
      urls.push(`http://${entry.address}:${port}`)
    }
  }
  return [...new Set(urls)]
}

function findFreePort(start) {
  return new Promise((resolve, reject) => {
    let candidate = start
    let attempts = 0
    const tryPort = () => {
      attempts += 1
      if (attempts > 40) return reject(new Error('no free LAN port found'))
      const server = net.createServer()
      server.once('error', () => {
        candidate += 1
        tryPort()
      })
      server.listen(candidate, '0.0.0.0', () => {
        const port = server.address().port
        server.close(() => resolve(port))
      })
    }
    tryPort()
  })
}

async function waitForProxy(port) {
  for (let i = 0; i < 50; i++) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/`)
      if (response.ok) return true
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  return false
}

function proxyState() {
  return {
    running: Boolean(proxyChild),
    mode: proxyMode,
    code: proxyCode,
    port: proxyPort,
    urls: proxyUrls,
    localUrls: proxyLocalUrls,
    publicUrl,
    enginePort: enginePort(),
    cloudflaredReady: fs.existsSync(CLOUDFLARED)
  }
}

function randomPassword(length) {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
  let value = ''
  for (let i = 0; i < length; i++) value += alphabet[crypto.randomInt(alphabet.length)]
  return value
}

function startCloudflared(port) {
  return new Promise((resolve, reject) => {
    if (!fs.existsSync(CLOUDFLARED)) {
      reject(new Error('cloudflared.exe is missing'))
      return
    }
    const logStream = fs.createWriteStream(path.join(LOG_DIR, 'cloudflared.log'), { flags: 'a' })
    const child = spawn(
      CLOUDFLARED,
      ['tunnel', '--url', `http://127.0.0.1:${port}`, '--no-autoupdate', '--loglevel', 'info'],
      { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] }
    )
    tunnelChild = child
    fs.writeFileSync(path.join(REMOTE_DIR, 'cloudflared.pid'), String(child.pid), 'ascii')
    let settled = false
    let buffer = ''
    let candidate = ''
    let probing = false
    const finish = (error, url) => {
      if (settled) return
      settled = true
      if (error) reject(error)
      else resolve(url)
    }
    const probe = (url) => {
      if (probing) return
      probing = true
      ;(async () => {
        for (let i = 0; i < 120 && !settled; i++) {
          try {
            const response = await fetch(url, { redirect: 'manual' })
            if (response.status < 500) { finish(null, url); return }
          } catch {}
          await new Promise((resolveWait) => setTimeout(resolveWait, 500))
        }
      })()
    }
    const scan = (chunk) => {
      const text = chunk.toString()
      buffer += text
      logStream.write(text)
      if (buffer.length > 30000) buffer = buffer.slice(-15000)
      const match = buffer.match(/https:\/\/[a-z0-9-]+\.trycloudflare\.com/i)
      if (match) {
        candidate = match[0]
        probe(candidate)
      }
      // The URL can appear before the connector is reachable; the probe above
      // is authoritative. This log check is only a fast path.
      if (candidate && /Registered tunnel connection/i.test(buffer)) finish(null, candidate)
    }
    child.stdout.on('data', scan)
    child.stderr.on('data', scan)
    child.on('error', (error) => finish(error))
    child.on('exit', (code) => {
      fs.rmSync(path.join(REMOTE_DIR, 'cloudflared.pid'), { force: true })
      if (!settled) finish(new Error(`cloudflared exited with code ${code}`))
    })
    setTimeout(() => {
      if (!settled) finish(new Error('timed out waiting for the Cloudflare tunnel to register'))
    }, 60000)
  })
}

async function startProxy(mode = 'lan') {
  if (proxyChild) {
    if (proxyMode === mode) return proxyState()
    await stopProxy()
  }
  const isPublic = mode === 'public'
  const port = await findFreePort(3091)
  const code = isPublic ? randomPassword(32) : String(crypto.randomInt(100000, 1000000))
  const childEnv = { ...process.env }
  delete childEnv.ELECTRON_RUN_AS_NODE
  childEnv.DSH_HOME = path.join(DATA_ROOT, 'home')
  childEnv.DSH_ENGINE_LOG = path.join(LOG_DIR, 'engine.log')
  childEnv.DSH_SYNC_ROOT = path.join(DATA_ROOT, 'home', 'sessions')
  childEnv.DSH_LAN_PW = code

  const out = fs.createWriteStream(path.join(LOG_DIR, 'pc-lan.log'), { flags: 'a' })
  const err = fs.createWriteStream(path.join(LOG_DIR, 'pc-lan.err.log'), { flags: 'a' })
  const child = spawn(
    path.join(APP_ROOT, 'runtime', 'node.exe'),
    [
      path.join(APP_ROOT, 'remote', 'lan-proxy.mjs'),
      '--port', String(port),
      '--pw', code,
      '--upstream', `127.0.0.1:${enginePort()}`
    ],
    {
      cwd: APP_ROOT,
      env: childEnv,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe']
    }
  )
  child.stdout.pipe(out)
  child.stderr.pipe(err)
  child.on('error', (error) => log(`remote proxy spawn error: ${error.message}`))
  child.on('exit', (codeValue, signal) => {
    log(`remote proxy exited: code=${codeValue} signal=${signal}`)
    if (proxyChild === child) {
      proxyChild = null
      proxyPort = 0
      proxyCode = ''
      proxyUrls = []
      proxyLocalUrls = []
      proxyMode = 'lan'
      publicUrl = ''
      fs.rmSync(path.join(REMOTE_DIR, 'pc-lan.pid'), { force: true })
    }
  })

  proxyChild = child
  proxyPort = port
  proxyCode = code
  proxyMode = mode
  proxyLocalUrls = lanUrls(port)
  proxyUrls = proxyLocalUrls
  fs.writeFileSync(path.join(REMOTE_DIR, 'pc-lan.pid'), String(child.pid), 'ascii')
  fs.writeFileSync(path.join(REMOTE_DIR, 'pc-code.txt'), code, 'ascii')

  const ready = await waitForProxy(port)
  if (!ready) {
    await stopProxy()
    throw new Error('LAN proxy did not become ready; see data\\logs\\pc-lan.err.log')
  }

  if (isPublic) {
    try {
      publicUrl = await startCloudflared(port)
      proxyUrls = [publicUrl]
    } catch (error) {
      await stopProxy()
      throw error
    }
  }

  fs.writeFileSync(path.join(REMOTE_DIR, 'pc-lan.json'), JSON.stringify({
    mode,
    code,
    port,
    enginePort: enginePort(),
    pid: child.pid,
    publicUrl,
    urls: proxyUrls,
    localUrls: proxyLocalUrls,
    updatedAt: new Date().toISOString()
  }, null, 2), 'utf8')
  log(`remote enabled: mode=${mode} port=${port} urls=${proxyUrls.join(',')}`)
  return proxyState()
}

async function stopProxy() {
  const child = proxyChild
  const tunnel = tunnelChild
  proxyChild = null
  tunnelChild = null
  proxyPort = 0
  proxyCode = ''
  proxyUrls = []
  proxyLocalUrls = []
  proxyMode = 'lan'
  publicUrl = ''
  if (tunnel) {
    try { tunnel.kill() } catch {}
    await new Promise((resolve) => setTimeout(resolve, 300))
    if (tunnel.exitCode === null) {
      try { spawn('taskkill', ['/PID', String(tunnel.pid), '/T', '/F'], { windowsHide: true }) } catch {}
    }
    fs.rmSync(path.join(REMOTE_DIR, 'cloudflared.pid'), { force: true })
  }
  if (child) {
    try { child.kill() } catch {}
    await new Promise((resolve) => setTimeout(resolve, 300))
    if (child.exitCode === null) {
      try { spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true }) } catch {}
    }
    log('remote disabled')
  }
  fs.rmSync(path.join(REMOTE_DIR, 'pc-lan.pid'), { force: true })
  fs.rmSync(path.join(REMOTE_DIR, 'pc-code.txt'), { force: true })
  fs.rmSync(path.join(REMOTE_DIR, 'pc-lan.json'), { force: true })
  return proxyState()
}

function killStaleProxy() {
  for (const name of ['pc-lan.pid', 'cloudflared.pid']) {
    const pidFile = path.join(REMOTE_DIR, name)
    if (!fs.existsSync(pidFile)) continue
    const pid = Number(fs.readFileSync(pidFile, 'utf8').trim())
    if (Number.isFinite(pid) && pid > 0) {
      try { process.kill(pid) } catch {}
    }
    fs.rmSync(pidFile, { force: true })
  }
  fs.rmSync(path.join(REMOTE_DIR, 'pc-code.txt'), { force: true })
  fs.rmSync(path.join(REMOTE_DIR, 'pc-lan.json'), { force: true })
}

// ------------------------------------------------------------------ windows
function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1320,
    height: 900,
    minWidth: 960,
    minHeight: 620,
    title: APP_TITLE,
    icon: path.join(__dirname, 'icon.png'),
    backgroundColor: '#0f1115',
    autoHideMenuBar: true,
    show: false,
    webPreferences: {
      contextIsolation: true,
      sandbox: true,
      nodeIntegration: false,
      spellcheck: false,
      preload: path.join(__dirname, 'preload.js')
    }
  })

  mainWindow.setMenuBarVisibility(false)
  mainWindow.on('page-title-updated', (event) => {
    event.preventDefault()
    mainWindow.setTitle(APP_TITLE)
  })
  mainWindow.once('ready-to-show', () => {
    mainWindow.show()
    mainWindow.setTitle(APP_TITLE)
  })
  mainWindow.on('closed', () => {
    mainWindow = null
  })

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:/i.test(url)) shell.openExternal(url)
    return { action: 'deny' }
  })
  mainWindow.webContents.on('will-navigate', (event, url) => {
    if (!url.startsWith(TARGET_URL) && !url.startsWith('dsh-app:')) {
      event.preventDefault()
      if (/^https?:/i.test(url)) shell.openExternal(url)
    }
  })
  mainWindow.webContents.on('render-process-gone', (_event, details) => {
    log(`render-process-gone: ${JSON.stringify(details)}`)
  })
  mainWindow.webContents.on('did-finish-load', () => {
    log(`did-finish-load: ${mainWindow.webContents.getURL()}`)
    mainWindow.webContents.executeJavaScript(
      'document.title + " | " + ((document.body && document.body.innerText) || "").replace(/\\s+/g, " ").slice(0, 180)'
    ).then((text) => log(`page: ${text}`)).catch((error) => log(`page inspect failed: ${error && error.message}`))
    injectRemoteButton()
  })
  mainWindow.webContents.on('did-fail-load', (_event, code, description, url, isMainFrame) => {
    log(`did-fail-load: ${code} ${description} ${url} main=${isMainFrame}`)
  })

  mainWindow.loadURL(TARGET_URL).catch((error) => {
    log(`loadURL failed: ${error && error.message}`)
    mainWindow.loadFile(path.join(__dirname, 'offline.html')).catch(() => {})
  })
}

function injectRemoteButton() {
  if (IS_REMOTE_PHONE || !mainWindow) return
  const css = `
    #dshm-remote-fab {
      position: fixed; right: 16px; bottom: 88px; z-index: 2147483647;
      height: 32px; padding: 0 14px; border-radius: 16px;
      border: 1px solid rgba(255,255,255,.18);
      background: rgba(26,115,232,.92); color: #fff;
      font: 600 12px/30px "Segoe UI","Microsoft YaHei",sans-serif;
      letter-spacing: .04em; cursor: pointer;
      box-shadow: 0 4px 14px rgba(0,0,0,.35);
      backdrop-filter: blur(8px);
    }
    #dshm-remote-fab:hover { background: rgba(39,128,245,.98); }
    #dshm-remote-fab:active { transform: translateY(1px); }
  `
  mainWindow.webContents.insertCSS(css).catch(() => {})
  mainWindow.webContents.executeJavaScript(`(function () {
    var ID = 'dshm-remote-fab';
    function add() {
      if (document.getElementById(ID)) return;
      var b = document.createElement('button');
      b.id = ID;
      b.type = 'button';
      b.textContent = '远程';
      b.title = '开启 / 管理 DSH-MOBILE 远程连接 (Ctrl+Shift+Alt+R)';
      b.addEventListener('click', function () {
        if (window.dshMobile && window.dshMobile.openRemote) window.dshMobile.openRemote();
      });
      document.body.appendChild(b);
    }
    add();
    setInterval(add, 3000);
  })();`).then(() => log('remote button injected')).catch((error) => log(`remote button failed: ${error.message}`))
}

function openRemoteWindow() {
  log('open remote window requested')
  if (IS_REMOTE_PHONE) return
  if (remoteWindow) {
    if (remoteWindow.isMinimized()) remoteWindow.restore()
    remoteWindow.show()
    remoteWindow.focus()
    return
  }
  remoteWindow = new BrowserWindow({
    width: 640,
    height: 720,
    resizable: true,
    minimizable: true,
    maximizable: false,
    title: 'DSH-MOBILE 远程连接',
    icon: path.join(__dirname, 'icon.png'),
    backgroundColor: '#0f1115',
    autoHideMenuBar: true,
    parent: mainWindow || undefined,
    webPreferences: {
      contextIsolation: true,
      sandbox: false,
      nodeIntegration: false,
      preload: path.join(__dirname, 'remote-preload.js')
    }
  })
  remoteWindow.setMenuBarVisibility(false)
  remoteWindow.on('closed', () => { remoteWindow = null })
  remoteWindow.loadFile(path.join(__dirname, 'remote.html')).catch((error) => log(`remote window failed: ${error.message}`))
}

function createTray() {
  if (IS_REMOTE_PHONE) return
  try {
    tray = new Tray(path.join(__dirname, 'icon.ico'))
    tray.setToolTip('DSH-MOBILE')
    tray.setContextMenu(Menu.buildFromTemplate([
      { label: '打开 DSH-MOBILE', click: showMainWindow },
      { label: '远程连接…', click: openRemoteWindow },
      { type: 'separator' },
      { label: '退出', click: () => app.quit() }
    ]))
    tray.on('click', showMainWindow)
    log('tray created')
  } catch (error) {
    log(`tray failed: ${error.message}`)
  }
}

function createMenu() {
  if (IS_REMOTE_PHONE) return
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {
      label: 'DSH-MOBILE',
      submenu: [
        { label: '远程连接…', accelerator: 'CommandOrControl+Shift+Alt+R', click: openRemoteWindow },
        { type: 'separator' },
        { role: 'quit', label: '退出' }
      ]
    },
    {
      label: '视图',
      submenu: [
        { role: 'reload', label: '重新加载' },
        { role: 'toggleDevTools', label: '开发者工具' },
        { type: 'separator' },
        { role: 'togglefullscreen', label: '全屏' }
      ]
    }
  ]))
}

// ------------------------------------------------------------------ IPC
ipcMain.handle('remote:state', () => proxyState())
ipcMain.handle('remote:start', async (_event, mode) => {
  try {
    return { ok: true, state: await startProxy(mode === 'public' ? 'public' : 'lan') }
  } catch (error) {
    log(`remote start failed: ${error.message}`)
    return { ok: false, error: error.message, state: proxyState() }
  }
})
ipcMain.handle('remote:stop', async () => ({ ok: true, state: await stopProxy() }))
ipcMain.handle('remote:copy', (_event, text) => {
  clipboard.writeText(String(text ?? ''))
  return true
})
ipcMain.on('remote:open-window', () => openRemoteWindow())
ipcMain.on('remote:close-window', () => { if (remoteWindow) remoteWindow.close() })

// ------------------------------------------------------------------ lifecycle
const hasSingleInstance = IS_REMOTE_PHONE || app.requestSingleInstanceLock()
if (!hasSingleInstance) {
  app.quit()
} else {
  app.on('second-instance', () => showMainWindow())
  app.whenReady().then(() => {
    try { app.setAccessibilitySupportEnabled(true) } catch {}
    session.defaultSession.setPermissionRequestHandler((_webContents, permission, callback) => {
      const allowed = new Set(['clipboard-read', 'clipboard-sanitized-write', 'notifications', 'media', 'fullscreen'])
      callback(allowed.has(permission))
    })
    if (!IS_REMOTE_PHONE) {
      killStaleProxy()
      createMenu()
      createTray()
      const registered = globalShortcut.register('CommandOrControl+Shift+Alt+R', openRemoteWindow)
      log(`hotkey registered=${registered}`)
    }
    createWindow()
    if (process.argv.includes('--open-remote')) setTimeout(openRemoteWindow, 1200)
  })
}

app.on('will-quit', () => {
  globalShortcut.unregisterAll()
})
app.on('before-quit', () => {
  for (const child of [tunnelChild, proxyChild]) {
    if (!child) continue
    try { child.kill() } catch {}
    try { spawn('taskkill', ['/PID', String(child.pid), '/T', '/F'], { windowsHide: true }) } catch {}
  }
})
app.on('window-all-closed', () => {
  app.quit()
})
app.on('activate', () => {
  if (BrowserWindow.getAllWindows().length === 0) createWindow()
})
