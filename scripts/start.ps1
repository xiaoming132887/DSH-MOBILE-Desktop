#requires -Version 5.1
<#
  DSH-MOBILE launcher.
  Starts an isolated dsh web engine and an Electron shell, with every
  user-data location redirected under <root>\data.
#>
[CmdletBinding()]
param(
  [int]$Port = 0,
  [switch]$NoShell,
  [switch]$Wait,
  [switch]$Remote
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$ConfigPath = Join-Path $Root 'config\mobile.json'
$Config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$Data = if ($env:DSH_MOBILE_DATA) {
  $env:DSH_MOBILE_DATA
} elseif ([IO.Path]::IsPathRooted([string]$Config.dataDir)) {
  [string]$Config.dataDir
} else {
  Join-Path $Root ([string]$Config.dataDir)
}

$Dirs = @{
  Home         = Join-Path $Data 'home'
  Agents       = Join-Path $Data 'agents'
  Electron     = Join-Path $Data 'electron'
  AppData      = Join-Path $Data 'appdata'
  LocalAppData = Join-Path $Data 'localappdata'
  Temp         = Join-Path $Data 'temp'
  Logs         = Join-Path $Data 'logs'
  Run          = Join-Path $Data 'run'
  Cache        = Join-Path $Data 'cache'
  Pnpm         = Join-Path $Data 'pnpm'
  Workspace    = Join-Path $Data 'workspace'
  Browser      = Join-Path $Data 'browser'
}
foreach ($dir in $Dirs.Values) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

$EngineLog = Join-Path $Dirs.Logs 'engine.log'
$EngineErr = Join-Path $Dirs.Logs 'engine.err.log'
$LauncherLog = Join-Path $Dirs.Logs 'launcher.log'
$ServerPidFile = Join-Path $Dirs.Run 'server.pid'
$ShellPidFile = Join-Path $Dirs.Run 'shell.pid'
$PortFile = Join-Path $Dirs.Run 'port.txt'

function Write-LauncherLog([string]$Message) {
  $line = ('[{0}] {1}' -f (Get-Date).ToString('s'), $Message)
  Add-Content -LiteralPath $LauncherLog -Value $line -Encoding UTF8
}

function Test-PortFree([int]$Candidate) {
  $listener = $null
  try {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $Candidate)
    $listener.Start()
    return $true
  } catch {
    return $false
  } finally {
    if ($listener) { $listener.Stop() }
  }
}

function Wait-HttpReady([int]$Candidate, [int]$TimeoutSeconds = 90) {
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  $url = "http://127.0.0.1:$Candidate/"
  while ((Get-Date) -lt $deadline) {
    try {
      $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3
      if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500) { return $true }
    } catch {
      # Engine still starting; a 404 is also acceptable once the port is open.
      if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -lt 500) { return $true }
    }
    Start-Sleep -Milliseconds 500
  }
  return $false
}

Write-LauncherLog "launcher start; root=$Root data=$Data"

# ---------------------------------------------------------------- environment
# Everything dsh or its children could treat as a per-user data location is
# redirected into this app's own data root. The official app and a normal
# `dsh` install keep using ~/.dsh, ~/.agents and %APPDATA%.
# Drop any inherited official-DSH runtime context. Without this, launching
# DSH-MOBILE from a terminal opened inside the official app would inherit
# DSH_PROFILE=desktop / DSH_PROFILE_DIR / DSH_WEB_URL and point the new engine
# back at the official profile or port.
foreach ($name in @(
    'DSH_PROFILE', 'DSH_PROFILE_DIR', 'DSH_SESSION_ID', 'DSH_SHELL',
    'DSH_WEB_URL', 'DSH_APP_VERSION', 'DSH_CLIENT_VERSION',
    'DSH_CLIENT_COMMIT_HASH', 'DSH_CLIENT_BUILD_PROFILE', 'DSH_CLIENT_TITLE',
    'DSH_DEPLOYMENT_REGION', 'DSH_REGION', 'DSH_RANK',
    'DSH_PLATFORM_ORIGIN', 'DSH_PLATFORM_COOKIE', 'DSH_TRANSPORT__',
    'DSH_HOST_PATHS__', 'DSH_BOOT__', 'DSH_BOOT_READY__'
  )) {
  Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
}

$env:DSH_HOME = $Dirs.Home
$env:DSH_AGENTS_HOME = $Dirs.Agents
$env:DSH_TELEMETRY_DISABLED = if ($Config.telemetryDisabled -eq $false) { '0' } else { '1' }
$env:DSH_MOBILE = '1'
$env:APPDATA = $Dirs.AppData
$env:LOCALAPPDATA = $Dirs.LocalAppData
$env:TEMP = $Dirs.Temp
$env:TMP = $Dirs.Temp
$env:TMPDIR = $Dirs.Temp
$env:XDG_CACHE_HOME = Join-Path $Dirs.Cache 'xdg'
$env:XDG_CONFIG_HOME = Join-Path $Dirs.Cache 'xdg-config'
$env:XDG_DATA_HOME = Join-Path $Dirs.Cache 'xdg-data'
$env:PNPM_HOME = $Dirs.Pnpm
$env:npm_config_cache = Join-Path $Dirs.Cache 'npm'
$env:DSH_MOBILE_DATA = $Data
$env:DSH_MOBILE_ELECTRON_DIR = $Dirs.Electron
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue

# ---------------------------------------------------------------- engine paths
$Node = Join-Path $Root 'runtime\node.exe'
$Bin = Join-Path $Root 'runtime\engine\node_modules\@deepseek-ai\dsh\lib\bin.js'
if (-not (Test-Path -LiteralPath $Node)) { throw "missing Node runtime: $Node" }
if (-not (Test-Path -LiteralPath $Bin)) { throw "missing dsh engine: $Bin (run scripts\install-engine.ps1)" }
$env:DSH_NODE = $Node
$env:PATH = (Join-Path $Root 'runtime') + ';' + $env:PATH

# ---------------------------------------------------------------- existing run
$existingServer = $null
if (Test-Path -LiteralPath $ServerPidFile) {
  $existingPid = [int](Get-Content -LiteralPath $ServerPidFile -Raw)
  $existingServer = Get-Process -Id $existingPid -ErrorAction SilentlyContinue
}
if ($existingServer) {
  $existingPort = if (Test-Path -LiteralPath $PortFile) { [int](Get-Content -LiteralPath $PortFile -Raw) } else { 0 }
  if ($existingPort -gt 0 -and (Wait-HttpReady -Candidate $existingPort -TimeoutSeconds 5)) {
    $Port = $existingPort
    Write-LauncherLog "reusing engine pid=$($existingServer.Id) port=$Port"
  } else {
    taskkill /PID $existingServer.Id /T /F | Out-Null
    $existingServer = $null
  }
}

# ---------------------------------------------------------------- start engine
if (-not $Port -or $Port -le 0) {
  $Port = if ($Config.port) { [int]$Config.port } else { 49760 }
}
if (-not $existingServer) {
  $tries = 0
  while (-not (Test-PortFree -Candidate $Port)) {
    $Port++
    $tries++
    if ($tries -gt 200) { throw 'no free loopback port found' }
  }
  Write-LauncherLog "starting engine: $Node $Bin web --port $Port"
  if (Test-Path -LiteralPath $EngineLog) { Move-Item -LiteralPath $EngineLog -Destination "$EngineLog.prev" -Force }
  if (Test-Path -LiteralPath $EngineErr) { Move-Item -LiteralPath $EngineErr -Destination "$EngineErr.prev" -Force }
  $server = Start-Process -FilePath $Node -ArgumentList @($Bin, 'web', '--port', "$Port", '--no-open') `
    -WorkingDirectory $Dirs.Workspace -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $EngineLog -RedirectStandardError $EngineErr
  Set-Content -LiteralPath $ServerPidFile -Value $server.Id -Encoding ASCII
  Set-Content -LiteralPath $PortFile -Value $Port -Encoding ASCII
  Write-LauncherLog "engine pid=$($server.Id) port=$Port"
} else {
  $server = $existingServer
}

if (-not (Wait-HttpReady -Candidate $Port -TimeoutSeconds 120)) {
  Write-LauncherLog "engine did not become ready; see $EngineLog / $EngineErr"
  throw "DSH engine did not become ready on http://127.0.0.1:$Port/ — see $EngineLog"
}

# The web server prints a one-time browser-trust URL containing ?token=...
# Use that exact URL for the shell; the bare origin answers 401 until the
# browser session has been granted.
$Url = "http://127.0.0.1:$Port/"
$tokenLine = $null
for ($i = 0; $i -lt 60; $i++) {
  $tokenLine = Get-Content -LiteralPath $EngineLog -ErrorAction SilentlyContinue |
    Where-Object { $_ -match 'dsh web:\s+(http://\S+)' } | Select-Object -Last 1
  if ($tokenLine -and $tokenLine -match '(http://\S+)') { $Url = $Matches[1]; break }
  Start-Sleep -Milliseconds 250
}
if (-not $tokenLine) {
  Write-LauncherLog 'warning: engine token URL not found; using bare origin'
}
Set-Content -LiteralPath (Join-Path $Dirs.Run 'url.txt') -Value $Url -Encoding UTF8
Write-LauncherLog ("engine ready at http://127.0.0.1:$Port/ (token " + $(if ($tokenLine) { 'captured' } else { 'missing' }) + ")")

# ---------------------------------------------------------------- start shell
if ($NoShell) {
  Write-Output $Url
  return
}

$shellKind = if ($env:DSH_MOBILE_SHELL) { $env:DSH_MOBILE_SHELL } else { [string]$Config.shell }
Write-LauncherLog "shell kind=$shellKind"
$shell = $null
if ($shellKind -eq 'electron') {
  $electron = Join-Path $Root 'runtime\electron\electron.exe'
  if (Test-Path -LiteralPath $electron) {
    try {
      $env:DSH_MOBILE_URL = $Url
      $electronArgs = @((Join-Path $Root 'shell'), '--no-sandbox')
      if ($Remote) { $electronArgs += '--open-remote' }
      Write-LauncherLog "starting electron shell remotePanel=$([bool]$Remote)"
      $shell = Start-Process -FilePath $electron -ArgumentList $electronArgs `
        -WorkingDirectory (Join-Path $Root 'shell') -PassThru -ErrorAction Stop
      Write-LauncherLog "electron shell pid=$($shell.Id)"
    } catch {
      Write-LauncherLog "electron shell failed: $($_.Exception.Message); falling back to Edge"
      $shell = $null
    }
  } else {
    Write-LauncherLog "electron runtime missing; falling back to Edge"
  }
}

if (-not $shell -or $shell.HasExited) {
  if ($shell -and $shell.HasExited) {
    Write-LauncherLog "browser app window exited immediately (pid=$($shell.Id)); trying default browser"
    $shell = $null
  }
  $edgeCandidates = @(
    "$env:ProgramFiles (x86)\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles (x86)\Google\Chrome\Application\chrome.exe"
  )
  $browser = $edgeCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  if ($browser) {
    Write-LauncherLog "starting browser app window: $browser"
    $shell = Start-Process -FilePath $browser -ArgumentList @(
      "--app=$Url",
      "--user-data-dir=$($Dirs.Browser)",
      '--no-first-run',
      '--no-default-browser-check',
      '--window-size=1280,900',
      '--disable-features=msEdgeSidebarV2'
    ) -PassThru
    Start-Sleep -Seconds 3
    if ($shell.HasExited) {
      Write-LauncherLog "browser app window exited immediately (pid=$($shell.Id)); trying default browser"
      $shell = $null
    }
  }
}

if (-not $shell) {
  Write-LauncherLog "opening default browser at $Url (engine keeps running; use stop.ps1 to stop it)"
  Start-Process $Url
}

if ($shell) {
  Start-Sleep -Seconds 2
  if ($shell.HasExited) {
    Write-LauncherLog "shell handed off to the existing window (pid=$($shell.Id) exited)"
    $shell = $null
  }
}
if ($shell) {
  Set-Content -LiteralPath $ShellPidFile -Value $shell.Id -Encoding ASCII
  Write-LauncherLog "shell pid=$($shell.Id)"
  if ($Wait -or $Config.keepEngineOnShellExit -eq $false) {
    Wait-Process -Id $shell.Id -ErrorAction SilentlyContinue
    Write-LauncherLog 'shell exited; stopping engine'
    taskkill /PID $server.Id /T /F | Out-Null
    Remove-Item -LiteralPath $ServerPidFile, $ShellPidFile -Force -ErrorAction SilentlyContinue
  }
}
