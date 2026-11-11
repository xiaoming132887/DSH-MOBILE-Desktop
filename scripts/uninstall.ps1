#requires -Version 5.1
<#
  Remove DSH-MOBILE shortcuts and optionally its data.
#>
[CmdletBinding()]
param(
  [switch]$PurgeData
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Data = if ($env:DSH_MOBILE_DATA) { $env:DSH_MOBILE_DATA } else { Join-Path $Root 'data' }

& (Join-Path $PSScriptRoot 'stop.ps1')

$shortcuts = @(
  (Join-Path ([Environment]::GetFolderPath('Desktop')) 'DSH-MOBILE.lnk'),
  (Join-Path ([Environment]::GetFolderPath('Programs')) 'DSH-MOBILE.lnk')
)
foreach ($shortcut in $shortcuts) {
  if (Test-Path -LiteralPath $shortcut) {
    Remove-Item -LiteralPath $shortcut -Force
    Write-Output "removed $shortcut"
  }
}

if ($PurgeData) {
  $resolved = [IO.Path]::GetFullPath($Data)
  $expected = [IO.Path]::GetFullPath((Join-Path $Root 'data'))
  if ($resolved -ne $expected) {
    throw "refusing to purge unexpected data path: $resolved"
  }
  Remove-Item -LiteralPath $resolved -Recurse -Force
  Write-Output "purged $resolved"
} else {
  Write-Output "data kept at $Data (pass -PurgeData to delete it)"
}
