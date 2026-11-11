#requires -Version 5.1
<#
  Show DSH-MOBILE process, port and data-directory status.
#>
[CmdletBinding()]
param()

$Root = Split-Path -Parent $PSScriptRoot
$Data = if ($env:DSH_MOBILE_DATA) { $env:DSH_MOBILE_DATA } else { Join-Path $Root 'data' }
$Run = Join-Path $Data 'run'

$port = 0
$serverPid = 0
$url = ''
if (Test-Path -LiteralPath (Join-Path $Run 'port.txt')) {
  $port = [int](Get-Content -LiteralPath (Join-Path $Run 'port.txt') -Raw)
}
if (Test-Path -LiteralPath (Join-Path $Run 'server.pid')) {
  $serverPid = [int](Get-Content -LiteralPath (Join-Path $Run 'server.pid') -Raw)
}
$server = if ($serverPid) { Get-Process -Id $serverPid -ErrorAction SilentlyContinue } else { $null }
if ($port) { $url = "http://127.0.0.1:$port/" }
$urlFile = Join-Path $Run 'url.txt'
if (Test-Path -LiteralPath $urlFile) {
  $tokenUrl = (Get-Content -LiteralPath $urlFile -Raw).Trim()
  if ($tokenUrl) { $url = $tokenUrl }
}

[pscustomobject]@{
  App          = 'DSH-MOBILE'
  Root         = $Root
  DataRoot     = $Data
  DSH_HOME     = Join-Path $Data 'home'
  DSH_AGENTS   = Join-Path $Data 'agents'
  ElectronData = Join-Path $Data 'electron'
  EnginePid    = if ($server) { $server.Id } else { $null }
  EngineUp     = [bool]$server
  Port         = if ($port) { $port } else { $null }
  URL          = if ($url -match 'token=') { "http://127.0.0.1:$port/ (token hidden; see data\run\url.txt)" } else { $url }
} | Format-List

if ($port) {
  try {
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 3
    Write-Output "HTTP $($response.StatusCode), $($response.Content.Length) bytes"
  } catch {
    Write-Output "HTTP check: $($_.Exception.Message)"
  }
}

Write-Output ''
Write-Output 'Data directories:'
Get-ChildItem -LiteralPath $Data -Force -ErrorAction SilentlyContinue |
  Select-Object Mode, Name, @{n = 'SizeMiB'; e = {
      if ($_.PSIsContainer) {
        [math]::Round(((Get-ChildItem -LiteralPath $_.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1MB), 1)
      } else { [math]::Round($_.Length / 1MB, 2) }
    } } | Format-Table -AutoSize
