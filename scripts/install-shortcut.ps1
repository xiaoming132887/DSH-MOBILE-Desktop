#requires -Version 5.1
<#
  Create Desktop / Start Menu shortcuts for DSH-MOBILE.
#>
[CmdletBinding()]
param(
  [switch]$StartMenu,
  [string]$Icon = ''
)

$Root = Split-Path -Parent $PSScriptRoot
$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$Launcher = Join-Path $Root 'scripts\start.ps1'
if (-not $Icon) { $Icon = Join-Path $Root 'shell\icon.ico' }
if (-not (Test-Path -LiteralPath $Icon)) { $Icon = Join-Path $Root 'shell\icon.png' }

$shell = New-Object -ComObject WScript.Shell
$targets = @()
$targets += (Join-Path ([Environment]::GetFolderPath('Desktop')) 'DSH-MOBILE.lnk')
if ($StartMenu) {
  $targets += (Join-Path ([Environment]::GetFolderPath('Programs')) 'DSH-MOBILE.lnk')
}

foreach ($target in $targets) {
  $shortcut = $shell.CreateShortcut($target)
  $shortcut.TargetPath = $PowerShell
  $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Launcher`""
  $shortcut.WorkingDirectory = $Root
  $shortcut.IconLocation = $Icon
  $shortcut.Description = 'DSH-MOBILE — isolated DeepSeek Harness client'
  $shortcut.Save()
  Write-Output "created $target"
}
