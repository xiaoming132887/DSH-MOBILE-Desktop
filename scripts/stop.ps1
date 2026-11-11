#requires -Version 5.1
<#
  Stop the DSH-MOBILE engine and shell. Data is kept.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'
$Root = Split-Path -Parent $PSScriptRoot
$Data = if ($env:DSH_MOBILE_DATA) { $env:DSH_MOBILE_DATA } else { Join-Path $Root 'data' }
$Run = Join-Path $Data 'run'
$ServerPidFile = Join-Path $Run 'server.pid'
$ShellPidFile = Join-Path $Run 'shell.pid'

if (Test-Path -LiteralPath $ServerPidFile) {
  $serverPid = [int](Get-Content -LiteralPath $ServerPidFile -Raw)
  taskkill /PID $serverPid /T /F | Out-Null
  Write-Output "stopped engine pid=$serverPid"
}

if (Test-Path -LiteralPath $ShellPidFile) {
  $shellPid = [int](Get-Content -LiteralPath $ShellPidFile -Raw)
  taskkill /PID $shellPid /T /F | Out-Null
  Write-Output "stopped shell pid=$shellPid"
}

Get-Process electron -ErrorAction SilentlyContinue |
  Where-Object { $_.Path -and $_.Path -like (Join-Path $Root 'runtime\electron\electron.exe') } |
  ForEach-Object {
    Stop-Process -Id $_.Id -Force
    Write-Output "stopped electron pid=$($_.Id)"
  }

Remove-Item -LiteralPath $ServerPidFile, $ShellPidFile -Force -ErrorAction SilentlyContinue
Write-Output 'DSH-MOBILE stopped.'
