#requires -Version 5.1
<#
  Stop the PC LAN proxy started by start-pc-lan.ps1.
#>
$ErrorActionPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $PSScriptRoot
$Data = if ($env:DSH_MOBILE_DATA) { $env:DSH_MOBILE_DATA } else { Join-Path $Root 'data' }
$PidFile = Join-Path $Data 'remote\pc-lan.pid'
if (Test-Path -LiteralPath $PidFile) {
  $pidValue = [int](Get-Content -LiteralPath $PidFile -Raw)
  taskkill /PID $pidValue /T /F | Out-Null
  Remove-Item -LiteralPath $PidFile -Force
  Write-Output "stopped PC LAN proxy pid=$pidValue"
} else {
  Write-Output 'PC LAN proxy is not running.'
}
