#requires -Version 5.1
<#
  Start the PC side of DSH-MOBILE remote access.
  Exposes the local DSH-MOBILE Web UI on the LAN (default port 3091) behind
  a 6-digit code, so a phone browser can control this computer's DSH agent.
#>
[CmdletBinding()]
param(
  [int]$LanPort = 3091,
  [string]$Code = '',
  [switch]$OpenFirewall
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Data = if ($env:DSH_MOBILE_DATA) { $env:DSH_MOBILE_DATA } else { Join-Path $Root 'data' }
$Run = Join-Path $Data 'run'
$RemoteDir = Join-Path $Data 'remote'
New-Item -ItemType Directory -Force -Path $RemoteDir | Out-Null

if (-not $Code) {
  $Code = -join (1..6 | ForEach-Object { Get-Random -Minimum 0 -Maximum 10 })
}

# Ensure the engine is up and get its loopback port. Start it in a detached
# process: start.ps1 owns the engine child, so calling it in-process can make
# this launcher wait on the child's inherited handles.
$portFile = Join-Path $Run 'port.txt'
$engineUp = $false
if (Test-Path -LiteralPath $portFile) {
  $candidate = [int](Get-Content -LiteralPath $portFile -Raw)
  try {
    Invoke-WebRequest "http://127.0.0.1:$candidate/" -UseBasicParsing -TimeoutSec 3 | Out-Null
    $engineUp = $true
  } catch {
    if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { $engineUp = $true }
  }
}
if (-not $engineUp) {
  Start-Process powershell.exe -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
    '-File', (Join-Path $Root 'scripts\start.ps1'), '-NoShell'
  ) -WindowStyle Hidden | Out-Null
  for ($i = 0; $i -lt 90; $i++) {
    if (Test-Path -LiteralPath $portFile) {
      $candidate = [int](Get-Content -LiteralPath $portFile -Raw)
      try {
        Invoke-WebRequest "http://127.0.0.1:$candidate/" -UseBasicParsing -TimeoutSec 2 | Out-Null
        $engineUp = $true; break
      } catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 401) { $engineUp = $true; break }
      }
    }
    Start-Sleep -Seconds 1
  }
}
if (-not $engineUp) { throw 'DSH-MOBILE engine did not start' }
$EnginePort = [int](Get-Content -LiteralPath $portFile -Raw)

$Proxy = Join-Path $Root 'remote\lan-proxy.mjs'
$Node = Join-Path $Root 'runtime\node.exe'
$PidFile = Join-Path $RemoteDir 'pc-lan.pid'
$Log = Join-Path $Data 'logs\pc-lan.log'
$Err = Join-Path $Data 'logs\pc-lan.err.log'

if (Test-Path -LiteralPath $PidFile) {
  $oldPid = [int](Get-Content -LiteralPath $PidFile -Raw)
  taskkill /PID $oldPid /T /F | Out-Null
  Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

$env:DSH_HOME = Join-Path $Data 'home'
$env:DSH_ENGINE_LOG = Join-Path $Data 'logs\engine.log'
$env:DSH_SYNC_ROOT = Join-Path $Data 'home\sessions'

$proc = Start-Process -FilePath $Node -ArgumentList @(
  $Proxy, '--port', "$LanPort", '--pw', $Code, '--upstream', "127.0.0.1:$EnginePort"
) -WorkingDirectory $Root -WindowStyle Hidden -PassThru -RedirectStandardOutput $Log -RedirectStandardError $Err
Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding ASCII
Start-Sleep -Seconds 2

try {
  $check = Invoke-WebRequest "http://127.0.0.1:$LanPort/" -UseBasicParsing -TimeoutSec 5
  if ($check.StatusCode -ne 200) { throw "proxy returned HTTP $($check.StatusCode)" }
} catch {
  throw "LAN proxy did not start: $($_.Exception.Message) — see $Err"
}

$ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Where-Object { $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.0\.0\.0)' } |
  Sort-Object @{ Expression = { if ($_.InterfaceAlias -match 'WLAN|Wi-Fi|无线') { 0 } else { 1 } } } |
  Select-Object -ExpandProperty IPAddress -Unique

$urls = @($ips | ForEach-Object { "http://${_}:$LanPort" })
$record = [pscustomobject]@{
  code = $Code
  port = $LanPort
  enginePort = $EnginePort
  pid = $proc.Id
  urls = $urls
  updatedAt = (Get-Date).ToString('o')
}
$record | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $RemoteDir 'pc-lan.json') -Encoding UTF8
Set-Content -LiteralPath (Join-Path $RemoteDir 'pc-code.txt') -Value $Code -Encoding ASCII

if ($OpenFirewall) {
  try {
    New-NetFirewallRule -DisplayName 'DSH-MOBILE LAN 3091' -Direction Inbound -Protocol TCP `
      -LocalPort $LanPort -Action Allow -Profile Private -ErrorAction Stop | Out-Null
    Write-Output 'firewall rule created for private networks'
  } catch {
    Write-Output "firewall rule not created: $($_.Exception.Message)"
  }
}

Write-Output ''
Write-Output 'DSH-MOBILE remote access is ON'
Write-Output "  6-digit code : $Code"
Write-Output "  engine       : 127.0.0.1:$EnginePort"
Write-Output "  LAN URL(s)   :"
if ($urls.Count -eq 0) { Write-Output "    (no LAN IPv4 found; check Wi-Fi/Ethernet)" }
foreach ($url in $urls) { Write-Output "    $url" }
Write-Output ''
Write-Output 'On the phone, open one of the LAN URLs and enter the code.'
Write-Output 'Stop with: powershell -File .\remote\stop-pc-lan.ps1'
