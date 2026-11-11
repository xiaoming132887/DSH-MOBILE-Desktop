#!/usr/bin/env node
/**
 * DSH-MOBILE session sync (protocol v1).
 *
 * Talks to the DSH-MOBILE LAN proxy on the phone (port 3090) or on the PC
 * (port 3091) and mirrors $DSH_HOME/sessions/*.jsonl.
 *
 *   node sync-sessions.mjs --url http://192.168.1.23:3090 --code 123456
 *   node sync-sessions.mjs --url http://192.168.1.23:3090 --code 123456 --direction pull
 *   node sync-sessions.mjs --url http://192.168.1.23:3090 --code 123456 --dry-run
 *
 * The remote proxy must expose the /__dshm/sync/* endpoints (patched
 * lan-web-proxy.mjs shipped in ../android/).
 */
import fs from 'node:fs'
import path from 'node:path'
import crypto from 'node:crypto'
import { fileURLToPath } from 'node:url'

const HERE = path.dirname(fileURLToPath(import.meta.url))
const APP_ROOT = path.resolve(HERE, '..')
const argv = process.argv.slice(2)
const arg = (name, fallback) => {
  const i = argv.indexOf('--' + name)
  return i >= 0 && argv[i + 1] ? argv[i + 1] : fallback
}
const has = (name) => argv.includes('--' + name)

const REMOTE = (arg('url', process.env.DSH_SYNC_URL || '')).replace(/\/+$/, '')
const CODE = arg('code', process.env.DSH_SYNC_CODE || '')
const DIRECTION = arg('direction', 'both') // both | pull | push
const DATA = path.resolve(arg('data', process.env.DSH_MOBILE_DATA || path.join(APP_ROOT, 'data')))
const LOCAL_ROOT = path.resolve(arg('local', path.join(DATA, 'home', 'sessions')))
const BACKUP_ROOT = path.resolve(arg('backup', path.join(DATA, 'sync-conflicts')))
const MAX_BYTES = 64 * 1024 * 1024
const DRY = has('dry-run')

if (!REMOTE || !CODE) {
  console.error('usage: node sync-sessions.mjs --url http://<host>:3090 --code <6-digit> [--direction both|pull|push] [--dry-run]')
  process.exit(2)
}

const headers = { 'x-dshm-sync': CODE }
const logLines = []
function log(line) {
  const text = `[${new Date().toISOString()}] ${line}`
  console.log(text)
  logLines.push(text)
}

function sha256(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex')
}

async function remoteJson(pathname) {
  const res = await fetch(REMOTE + pathname, { headers })
  if (!res.ok) throw new Error(`${pathname}: HTTP ${res.status} ${await res.text()}`)
  return res.json()
}

async function remoteBytes(rel) {
  const res = await fetch(`${REMOTE}/__dshm/sync/file?path=${encodeURIComponent(rel)}`, { headers })
  if (!res.ok) throw new Error(`GET ${rel}: HTTP ${res.status}`)
  const buf = Buffer.from(await res.arrayBuffer())
  if (buf.length > MAX_BYTES) throw new Error(`GET ${rel}: too large (${buf.length})`)
  return buf
}

async function putRemote(rel, buf) {
  if (DRY) { log(`[dry] upload ${rel} (${buf.length} B)`); return }
  const res = await fetch(`${REMOTE}/__dshm/sync/file?path=${encodeURIComponent(rel)}`, {
    method: 'PUT',
    headers: { ...headers, 'content-type': 'application/x-ndjson' },
    body: buf,
  })
  if (!res.ok) throw new Error(`PUT ${rel}: HTTP ${res.status} ${await res.text()}`)
  log(`upload ${rel} (${buf.length} B)`)
}

async function localManifest() {
  const files = []
  async function walk(dir) {
    let entries
    try { entries = await fs.promises.readdir(dir, { withFileTypes: true }) } catch { return }
    for (const entry of entries) {
      if (entry.name.startsWith('.') || entry.name.endsWith('.tmp')) continue
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) { await walk(full); continue }
      if (!entry.isFile() || !entry.name.endsWith('.jsonl')) continue
      const buf = await fs.promises.readFile(full)
      const stat = await fs.promises.stat(full)
      files.push({
        path: path.relative(LOCAL_ROOT, full).split(path.sep).join('/'),
        size: stat.size,
        mtimeMs: Math.round(stat.mtimeMs),
        sha256: sha256(buf),
      })
    }
  }
  await walk(LOCAL_ROOT)
  files.sort((a, b) => a.path.localeCompare(b.path))
  return files
}

function isPrefix(short, long) {
  return short.length <= long.length && short.equals(long.subarray(0, short.length))
}

async function main() {
  await fs.promises.mkdir(LOCAL_ROOT, { recursive: true })
  await fs.promises.mkdir(BACKUP_ROOT, { recursive: true })

  const ping = await remoteJson('/__dshm/sync/ping')
  if (ping.version !== 1) throw new Error(`unsupported sync protocol: ${JSON.stringify(ping)}`)
  log(`remote ${REMOTE} protocol v${ping.version}`)

  const remoteManifest = await remoteJson('/__dshm/sync/manifest')
  const local = await localManifest()
  const localByPath = new Map(local.map((f) => [f.path, f]))
  const remoteByPath = new Map(remoteManifest.files.map((f) => [f.path, f]))
  const all = [...new Set([...localByPath.keys(), ...remoteByPath.keys()])].sort()

  let downloaded = 0
  let uploaded = 0
  let conflicts = 0
  let skipped = 0

  for (const rel of all) {
    const l = localByPath.get(rel)
    const r = remoteByPath.get(rel)
    if (l && r && l.sha256 === r.sha256) { skipped++; continue }

    if (DIRECTION !== 'push' && r && !l) {
      const buf = await remoteBytes(rel)
      if (DRY) log(`[dry] download ${rel} (${buf.length} B)`)
      else {
        const dest = path.join(LOCAL_ROOT, ...rel.split('/'))
        await fs.promises.mkdir(path.dirname(dest), { recursive: true })
        await fs.promises.writeFile(dest, buf)
        log(`download ${rel} (${buf.length} B)`)
      }
      downloaded++
      continue
    }

    if (DIRECTION !== 'pull' && l && !r) {
      const buf = await fs.promises.readFile(path.join(LOCAL_ROOT, ...rel.split('/')))
      await putRemote(rel, buf)
      uploaded++
      continue
    }

    // Both sides have the file and hashes differ. JSONL sessions are
    // append-only, so a strict prefix means the longer side continued it.
    if (l && r) {
      const localBuf = await fs.promises.readFile(path.join(LOCAL_ROOT, ...rel.split('/')))
      const remoteBuf = await remoteBytes(rel)
      if (DIRECTION !== 'push' && isPrefix(localBuf, remoteBuf)) {
        if (DRY) log(`[dry] fast-forward download ${rel} (${remoteBuf.length} B)`)
        else {
          await fs.promises.writeFile(path.join(LOCAL_ROOT, ...rel.split('/')), remoteBuf)
          log(`fast-forward download ${rel} (${remoteBuf.length} B)`)
        }
        downloaded++
        continue
      }
      if (DIRECTION !== 'pull' && isPrefix(remoteBuf, localBuf)) {
        await putRemote(rel, localBuf)
        uploaded++
        continue
      }
      // True divergence: keep both, remote wins if newer.
      conflicts++
      const stamp = new Date().toISOString().replace(/[:.]/g, '-')
      const backup = path.join(BACKUP_ROOT, ...rel.split('/')) + `.${stamp}.local.jsonl`
      if (!DRY) {
        await fs.promises.mkdir(path.dirname(backup), { recursive: true })
        await fs.promises.writeFile(backup, localBuf)
      }
      if (DIRECTION !== 'pull' && r.mtimeMs > l.mtimeMs) {
        if (!DRY) await fs.promises.writeFile(path.join(LOCAL_ROOT, ...rel.split('/')), remoteBuf)
        log(`conflict ${rel}: remote newer -> downloaded; local backup ${backup}`)
        downloaded++
      } else if (DIRECTION !== 'pull') {
        await putRemote(rel, localBuf)
        log(`conflict ${rel}: local newer -> uploaded; local backup ${backup}`)
        uploaded++
      } else {
        log(`conflict ${rel}: kept local; backup ${backup}`)
      }
    }
  }

  const summary = `done: downloaded=${downloaded} uploaded=${uploaded} conflicts=${conflicts} skipped=${skipped} remoteFiles=${remoteManifest.count} localFiles=${local.length}`
  log(summary)
  const logFile = path.join(DATA, 'logs', 'sync.log')
  await fs.promises.mkdir(path.dirname(logFile), { recursive: true })
  await fs.promises.appendFile(logFile, logLines.join('\n') + '\n')
  if (downloaded || uploaded || conflicts) {
    log('restart DSH-MOBILE (or wait for the session list to refresh) to see synced sessions.')
  }
}

main().catch((error) => {
  console.error('sync failed:', error.message)
  process.exit(1)
})
