#requires -Version 5.1
<#
  DSH-MOBILE isolation doctor.
  Proves that DSH-MOBILE's data roots are disjoint from every official
  DeepSeek Harness default, and that the bundled engine is runnable.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Config = Get-Content -LiteralPath (Join-Path $Root 'config\mobile.json') -Raw | ConvertFrom-Json
$Data = if ($env:DSH_MOBILE_DATA) { $env:DSH_MOBILE_DATA } elseif ([IO.Path]::IsPathRooted([string]$Config.dataDir)) { [string]$Config.dataDir } else { Join-Path $Root ([string]$Config.dataDir) }

$mobile = [ordered]@{
  DSH_HOME     = Join-Path $Data 'home'
  DSH_AGENTS   = Join-Path $Data 'agents'
  ElectronData = Join-Path $Data 'electron'
  Temp         = Join-Path $Data 'temp'
  AppData      = Join-Path $Data 'appdata'
  LocalAppData = Join-Path $Data 'localappdata'
  Logs         = Join-Path $Data 'logs'
  Workspace    = Join-Path $Data 'workspace'
}

function Get-Full([string]$Path) {
  try { [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') } catch { $Path }
}
function Test-Overlap([string]$A, [string]$B) {
  $a = Get-Full $A
  $b = Get-Full $B
  if ($a -eq $b) { return $true }
  return $a.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase) -or
         $b.StartsWith($a + '\', [StringComparison]::OrdinalIgnoreCase)
}
function Test-Inside([string]$Child, [string]$Parent) {
  if (-not $Child -or -not $Parent) { return $false }
  $c = Get-Full $Child
  $p = Get-Full $Parent
  return ($c -eq $p) -or $c.StartsWith($p + '\', [StringComparison]::OrdinalIgnoreCase)
}

# Official defaults. When this script runs *inside* DSH-MOBILE (agents do that a
# lot) the engine's own DSH_HOME / DSH_AGENTS_HOME / APPDATA already point into
# DSH-MOBILE, so they must not be mistaken for the official paths — otherwise
# every run false-fails as "overlaps official path: <itself>".
$userRoaming = if ($env:APPDATA -and -not (Test-Inside $env:APPDATA $Root)) {
  $env:APPDATA
} else {
  Join-Path $env:USERPROFILE 'AppData\Roaming'
}
$officialHome = if ($env:DSH_HOME -and -not (Test-Inside $env:DSH_HOME $Root)) {
  $env:DSH_HOME
} else {
  Join-Path $HOME '.dsh'
}
$officialAgents = if ($env:DSH_AGENTS_HOME -and -not (Test-Inside $env:DSH_AGENTS_HOME $Root)) {
  $env:DSH_AGENTS_HOME
} else {
  Join-Path $HOME '.agents'
}
$officialElectron = Join-Path $userRoaming '@deepseek-ai\dsh-desktop'
$official = [ordered]@{
  DSH_HOME     = $officialHome
  DSH_AGENTS   = $officialAgents
  ElectronData = $officialElectron
}

$problems = New-Object System.Collections.Generic.List[string]
$rows = New-Object System.Collections.Generic.List[object]

foreach ($key in $mobile.Keys) {
  $m = $mobile[$key]
  $o = if ($official.Contains($key)) { $official[$key] } else { $null }
  $overlap = if ($o) { Test-Overlap $m $o } else { $false }
  if ($overlap) { $problems.Add("$key overlaps official path: $m <-> $o") }
  $rows.Add([pscustomobject]@{
      Root     = $key
      Mobile   = $m
      Official = if ($o) { $o } else { '(n/a)' }
      Disjoint = if ($o) { -not $overlap } else { $true }
    })
}

$engine = Join-Path $Root 'runtime\engine\node_modules\@deepseek-ai\dsh\lib\bin.js'
$node = Join-Path $Root 'runtime\node.exe'
$version = $null
if ((Test-Path -LiteralPath $engine) -and (Test-Path -LiteralPath $node)) {
  $version = (& $node $engine --version 2>$null | Select-Object -First 1)
} else {
  $problems.Add("engine or node runtime missing: $engine")
}

Write-Output 'DSH-MOBILE isolation report'
Write-Output ('=' * 78)
$rows | Format-Table -AutoSize -Wrap | Out-String -Width 240 | Write-Output
Write-Output ("Engine: " + ($(if ($version) { "dsh $version" } else { 'NOT RUNNABLE' })))
Write-Output ("Root:   " + $Root)
Write-Output ("Data:   " + $Data)
Write-Output ''

# ---------------------------------------------------------- plugin toolchain
# The plugin manager strips every DSH_* variable before spawning pnpm / git, so
# these two have to be resolvable from PATH on their own. Missing ones are not
# an isolation failure, only a "plugin install will not work" hint.
$runtimeDir = Join-Path $Root 'runtime'
$pnpmCjs = Join-Path $runtimeDir 'pnpm\bin\pnpm.cjs'
$gitExe = Join-Path $runtimeDir 'git\cmd\git.exe'
$pnpmVersion = $null
$gitVersion = $null
if ((Test-Path -LiteralPath $pnpmCjs) -and (Test-Path -LiteralPath $node)) {
  try { $pnpmVersion = (& $node $pnpmCjs --version 2>$null | Select-Object -First 1) } catch { }
}
if (Test-Path -LiteralPath $gitExe) {
  try { $gitVersion = (& $gitExe --version 2>$null | Select-Object -First 1) -replace '^git version\s+', '' } catch { }
}

Write-Output 'Plugin toolchain'
Write-Output ('-' * 78)
Write-Output ("pnpm: " + ($(if ($pnpmVersion) { "$pnpmVersion  ($pnpmCjs)" } else { 'MISSING  -> .\scripts\provision-pnpm.ps1' })))
Write-Output ("git:  " + ($(if ($gitVersion) { "$gitVersion  ($gitExe)" } else { 'MISSING  -> .\scripts\provision-git.ps1' })))
if (-not $pnpmVersion -or -not $gitVersion) {
  Write-Output 'Note: plugin install needs both; npm-only sources still work without git.'
}
Write-Output ''

if ($problems.Count -eq 0) {
  Write-Output 'RESULT: PASS - DSH-MOBILE data roots are disjoint from official DSH defaults.'
  exit 0
}
Write-Output 'RESULT: FAIL'
$problems | ForEach-Object { Write-Output ("  - " + $_) }
exit 1
