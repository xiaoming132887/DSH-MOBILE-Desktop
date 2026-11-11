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

$officialHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
$officialAgents = if ($env:DSH_AGENTS_HOME) { $env:DSH_AGENTS_HOME } else { Join-Path $HOME '.agents' }
$officialElectron = Join-Path $env:APPDATA '@deepseek-ai\dsh-desktop'
$official = [ordered]@{
  DSH_HOME     = $officialHome
  DSH_AGENTS   = $officialAgents
  ElectronData = $officialElectron
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
if ($problems.Count -eq 0) {
  Write-Output 'RESULT: PASS - DSH-MOBILE data roots are disjoint from official DSH defaults.'
  exit 0
}
Write-Output 'RESULT: FAIL'
$problems | ForEach-Object { Write-Output ("  - " + $_) }
exit 1
