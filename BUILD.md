# Build / Runtime setup

This repository contains the **DSH-MOBILE Windows shell and launchers**, not the
official DSH engine binaries. The runtime is intentionally excluded from git
(large binaries + third-party licenses).

## Runtime layout

After setup the folder should look like:

```
DSH-MOBILE\
  runtime\
    node.exe
    cloudflared.exe
    engine\
      node_modules\@deepseek-ai\dsh\lib\bin.js
    electron\
      electron.exe
      ...
```

## Recommended: copy from an official DSH desktop install

Tested with official DSH desktop **0.2.2-rc.1**.

1. Install the official DeepSeek Harness desktop app (default `D:\DSH`).
2. Copy Node (24.21+):

```powershell
New-Item -ItemType Directory -Force .\runtime | Out-Null
Copy-Item "D:\DSH\resources\runtime\primary-runtime\dependencies\node\bin\node.exe" .\runtime\node.exe
```

3. Extract the `dsh` engine tree from the official `app.asar`:

```powershell
.\runtime\node.exe .\scripts\extract-asar-tree.js `
  "D:\DSH\resources\app.asar" "dsh" ".\runtime\engine" `
  "D:\DSH\resources\app.asar.unpacked"
```

4. Copy the Electron shell runtime:

```powershell
Copy-Item "D:\dsh tauri\electron\*" .\runtime\electron -Recurse -Force
```

5. Download `cloudflared` (only needed for the public mode):

```powershell
Invoke-WebRequest `
  -Uri "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" `
  -OutFile ".\runtime\cloudflared.exe"
```

## Run

```powershell
.\DSH-MOBILE.cmd
```

or double-click the desktop shortcut created by:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-shortcut.ps1
```

## Verify

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\status.ps1
```

`doctor.ps1` checks that `DSH_HOME`, `DSH_AGENTS_HOME`, Electron userData and
temp roots are disjoint from official DSH defaults.

## Notes

- The official engine is MIT-licensed; Electron, Node.js and cloudflared have
  their own licenses (see `THIRD_PARTY_NOTICES.md`).
- Do not commit `runtime/`, `data/`, credentials, or session logs.
- The Android client is a separate project:
  <https://github.com/Soodok/Deepseek-Harness-Local-Android>.
