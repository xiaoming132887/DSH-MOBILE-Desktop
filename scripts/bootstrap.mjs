import { createRequire } from 'node:module'
import { pathToFileURL } from 'node:url'
import { realpathSync } from 'node:fs'

const anchor = process.argv[2]
if (!anchor) throw new Error('missing dsh package entry')
const require = createRequire(pathToFileURL(realpathSync.native(anchor)))
const bin = require.resolve('@deepseek-ai/dsh/lib/bin.js')
const { runCli } = await import(pathToFileURL(bin).href)
await runCli()
