#requires -Version 5.1
<#
  Open the phone's DSH Mobile Web UI in a dedicated DSH-MOBILE window.
  Requires the phone's "局域网访问 WebUI" to be enabled.
#>
[CmdletBinding()]
param(
  [string]$PhoneUrl = '',
  [string]$Code = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Data = if ($env:DSH_MOBILE_DATA) { $env:DSH_MOBILE_DATA } else { Join-Path $Root 'data' }
$RemoteDir = Join-Path $Data 'remote'
New-Item -ItemType Directory -Force -Path $RemoteDir | Out-Null
$ConfigPath = Join-Path $RemoteDir 'phone.json'

if (-not $PhoneUrl -and (Test-Path -LiteralPath $ConfigPath)) {
  $saved = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
  $PhoneUrl = [string]$saved.url
  if (-not $Code) { $Code = [string]$saved.code }
}
if (-not $PhoneUrl) {
  $PhoneUrl = Read-Host 'Phone LAN WebUI URL (for example http://192.168.1.23:3090)'
}
if (-not $PhoneUrl) { throw 'phone URL is required' }
$PhoneUrl = $PhoneUrl.TrimEnd('/')

[pscustomobject]@{ url = $PhoneUrl; code = $Code; updatedAt = (Get-Date).ToString('o') } |
  ConvertTo-Json | Set-Content -LiteralPath $ConfigPath -Encoding UTF8

$target = if ($Code) {
  "$PhoneUrl/__lan_auth?pw=$([Uri]::EscapeDataString($Code))"
} else {
  "$PhoneUrl/"
}

$electron = Join-Path $Root 'runtime\electron\electron.exe'
$shell = Join-Path $Root 'shell'
$env:DSH_MOBILE_DATA = Join-Path $Data 'remote-phone'
$env:DSH_MOBILE_ELECTRON_DIR = Join-Path $Data 'remote-phone\electron'
$env:DSH_MOBILE_URL = $target
$env:DSH_MOBILE_TITLE = 'DSH-MOBILE Remote Phone'
$env:DSH_MOBILE_ALLOW_MULTI = '1'
Remove-Item Env:ELECTRON_RUN_AS_NODE -ErrorAction SilentlyContinue

try {
  Start-Process -FilePath $electron -ArgumentList @($shell, '--no-sandbox') `
    -WorkingDirectory $shell -ErrorAction Stop | Out-Null
  Write-Output "opened phone UI: $PhoneUrl"
} catch {
  Write-Output "Electron window failed ($($_.Exception.Message)); opening the default browser"
  Start-Process $target
}
