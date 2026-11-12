#requires -Version 5.1
<#
  DSH-MOBILE 便携版 pnpm 修复脚本（可重复执行）

  问题：DSH-MOBILE 的 GUI 插件安装在 profile 里调用 `pnpm`，但 DSH-MOBILE 自带的
        runtime 目录里没有 pnpm，于是命令行 PATH 命中了官方桌面版留下的残留 shim
        （%LOCALAPPDATA%\deepseek-harness\bin\pnpm.cmd）。该 shim 里写死的 Node
        运行时 `D:\DeepSeekHarness\runtime\win32-x64\DSH Tauri.exe` 已不存在，
        而插件管理器启动 pnpm 时用的是 scrubbedParentEnv()，会把所有 DSH_* 变量
        （含 DSH_NODE）剥掉，所以 shim 也拿不到 DSH-MOBILE 自己的 node.exe，
        最终报：`[pnpm] Node.js runtime not found`。

  修法：把与引擎配套的 pnpm（版本取自 runtime\engine\desktop-runtime.json 的
        release.pnpmVersion，默认 11.28.5）装进 DSH-MOBILE 自己的 runtime\ 目录，
        并在 runtime\ 放 pnpm.cmd / pnpm.ps1 两个 shim。start.ps1 会把
        runtime\ 前置到 PATH，于是引擎及其子进程（含插件安装）优先命中它，
        不再落到官方残留 shim 上。

  用法（放在 <DSH-MOBILE>\scripts\provision-pnpm.ps1 或任意位置都行，根目录会自动推断）：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\provision-pnpm.ps1
    可选：-Root D:\DSH-MOBILE  -PnpmVersion 11.28.5  -SkipVerify
  重新解压/升级 DSH-MOBILE 后，runtime\pnpm 会丢失，重跑一次即可（已装好时会秒过）。
#>
[CmdletBinding()]
param(
  [string]$Root = '',
  [string]$PnpmVersion = '',
  [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# $Root 缺省时按脚本位置推断（放在 <DSH-MOBILE>\scripts\ 或 <DSH-MOBILE>\ 下都能用）
if (-not $Root) {
  $candidates = @(
    (Join-Path (Split-Path -Parent $PSScriptRoot) ''),
    $PSScriptRoot,
    'D:\DSH-MOBILE'
  )
  foreach ($candidate in $candidates) {
    if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'runtime\node.exe') -PathType Leaf)) {
      $Root = (Resolve-Path -LiteralPath $candidate).Path
      break
    }
  }
  if (-not $Root) { throw "无法推断 DSH-MOBILE 根目录，请用 -Root 指定（例如 -Root D:\DSH-MOBILE）" }
}
$Root = $Root.TrimEnd('\')

function Write-Step([string]$Message) { Write-Host "[*] $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "[+] $Message" -ForegroundColor Green }
function Write-Warn2([string]$Message) { Write-Host "[!] $Message" -ForegroundColor Yellow }

# ------------------------------------------------------------------ paths
$runtime = Join-Path $Root 'runtime'
$node = Join-Path $runtime 'node.exe'
$dest = Join-Path $runtime 'pnpm'
$pnpmCjs = Join-Path $dest 'bin\pnpm.cjs'
$runtimeJson = Join-Path $runtime 'engine\desktop-runtime.json'

if (-not (Test-Path -LiteralPath $node -PathType Leaf)) { throw "找不到 Node 运行时：$node" }

# 版本：优先跟随引擎自带的 desktop-runtime.json
$enginePnpm = $null
if (Test-Path -LiteralPath $runtimeJson) {
  try {
    $rt = Get-Content -LiteralPath $runtimeJson -Raw | ConvertFrom-Json
    if ($rt.release.pnpmVersion) { $enginePnpm = [string]$rt.release.pnpmVersion }
  } catch { }
}
if (-not $PnpmVersion) { $PnpmVersion = if ($enginePnpm) { $enginePnpm } else { '11.28.5' } }
Write-Step "目标 pnpm 版本：$PnpmVersion（引擎声明：$(if ($enginePnpm) { $enginePnpm } else { '未读到，用默认值' })）"

$nodeVersion = (& $node -v).Trim()
Write-Step "本机 DSH-MOBILE Node：$nodeVersion"

# ------------------------------------------------------- 已有安装则直接复用
$installed = $null
if (Test-Path -LiteralPath $pnpmCjs -PathType Leaf) {
  try { $installed = (& $node $pnpmCjs --version 2>$null | Select-Object -First 1).Trim() } catch { $installed = $null }
}
if ($installed -eq $PnpmVersion) {
  Write-Ok "pnpm $installed 已装在 $dest，跳过下载"
} else {
  if ($installed) { Write-Warn2 "现有 pnpm $installed 与目标 $PnpmVersion 不一致，重新安装" }

  # ---------------------------------------------------------------- download
  $tmp = Join-Path $env:TEMP 'dsh-mobile-pnpm'
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $tgz = Join-Path $tmp "pnpm-$PnpmVersion.tgz"
  $fetchScript = Join-Path $tmp 'fetch.cjs'
  @'
const fs = require("node:fs");
const [dst, version] = [process.argv[2], process.argv[3]];
const urls = [
  `https://registry.npmmirror.com/pnpm/-/pnpm-${version}.tgz`,
  `https://registry.npmjs.org/pnpm/-/pnpm-${version}.tgz`,
];
(async () => {
  for (const url of urls) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(300000) });
      if (!res.ok) { console.error("HTTP " + res.status + " " + url); continue; }
      const bytes = Buffer.from(await res.arrayBuffer());
      if (bytes.length < 100000) { console.error("too small from " + url); continue; }
      fs.writeFileSync(dst, bytes);
      console.log("downloaded " + url + " (" + bytes.length + " bytes)");
      process.exit(0);
    } catch (error) {
      console.error(url + " -> " + error.message);
    }
  }
  process.exit(1);
})();
'@ | Set-Content -LiteralPath $fetchScript -Encoding UTF8

  Write-Step "下载 pnpm $PnpmVersion 发行包（npmmirror 优先，失败回退 npmjs）"
  & $node $fetchScript $tgz $PnpmVersion
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tgz)) { throw "pnpm 发行包下载失败；请检查网络或代理后重试" }
  Write-Ok ("已下载 " + [math]::Round((Get-Item -LiteralPath $tgz).Length / 1MB, 1) + " MB")

  # ---------------------------------------------------------------- extract
  Write-Step "解包到 $dest"
  if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
  if (-not (Test-Path -LiteralPath $tar)) { throw "找不到 tar.exe：$tar" }
  & $tar -xzf $tgz -C $dest --strip-components=1
  if ($LASTEXITCODE -ne 0) { throw "解包失败（tar 退出码 $LASTEXITCODE）" }
  if (-not (Test-Path -LiteralPath $pnpmCjs -PathType Leaf)) { throw "解包后找不到 $pnpmCjs" }
  Remove-Item -LiteralPath $tgz -Force -ErrorAction SilentlyContinue
  Write-Ok "pnpm 主体已就位"
}

# ---------------------------------------------------------------- shims
# 只依赖 %~dp0 相对路径：不引用 DSH_* 环境变量，也不引用已失效的官方路径。
$cmdShim = @'
@echo off
rem DSH-MOBILE - portable pnpm shim (generated by dsh-mobile-pnpm-fix.ps1)
rem Runs DSH-MOBILE's own node.exe on the bundled pnpm; never falls back to any
rem official-desktop shim. %* is handed to node directly (no extra `call` layer),
rem so caret/%/& in package specs stay byte-identical.
"%~dp0node.exe" "%~dp0pnpm\bin\pnpm.cjs" %*
exit /b %ERRORLEVEL%
'@
$ps1Shim = @'
# DSH-MOBILE - portable pnpm shim (generated by dsh-mobile-pnpm-fix.ps1)
& "$PSScriptRoot\node.exe" "$PSScriptRoot\pnpm\bin\pnpm.cjs" @args
exit $LASTEXITCODE
'@
Set-Content -LiteralPath (Join-Path $runtime 'pnpm.cmd') -Value $cmdShim -Encoding ASCII
Set-Content -LiteralPath (Join-Path $runtime 'pnpm.ps1') -Value $ps1Shim -Encoding UTF8
Write-Ok "已写入 shim：$runtime\pnpm.cmd、$runtime\pnpm.ps1"

if ($SkipVerify) { Write-Ok '已跳过校验（-SkipVerify）'; return }

# ---------------------------------------------------------------- verify
# 复刻引擎安装插件的真实条件：把 DSH_* 从环境里剥掉，再在 PATH 上找 `pnpm`。
Write-Step '校验 1：模拟 scrubbedParentEnv()（剥掉 DSH_*）后的 pnpm 解析'
Get-ChildItem Env: | Where-Object { $_.Name -like 'DSH_*' } | ForEach-Object {
  Remove-Item -LiteralPath ("Env:" + $_.Name) -ErrorAction SilentlyContinue
}
$env:PATH = $runtime + ';' + $env:PATH
$resolved = (& cmd /c where pnpm 2>$null | Select-Object -First 1).Trim()
$version = (& cmd /c "pnpm --version" 2>&1 | Select-Object -Last 1).Trim()
if ($resolved -and ($version -match '^\d+\.')) {
  Write-Ok "pnpm 解析到：$resolved"
  Write-Ok "pnpm --version -> $version"
} else {
  Write-Warn2 "pnpm 解析异常：resolved='$resolved' version='$version'"
}

$profileDir = Join-Path $Root 'data\home\profiles\web'
if (Test-Path -LiteralPath $profileDir) {
  Write-Step '校验 2：在 profile 目录里跑 pnpm view（插件市场/安装的同一路径）'
  Push-Location $profileDir
  try {
    $view = (& cmd /c 'pnpm view @deepseek-ai/dsh version 2>&1' | Select-Object -Last 3) -join ' '
    if ($view -match '\d+\.\d+\.\d+') { Write-Ok "pnpm view 默认 registry：$($view.Trim())" }
    else { Write-Warn2 "pnpm view 默认 registry 未返回版本：$($view.Trim())" }
  } finally { Pop-Location }
}

Write-Host ''
Write-Ok '修复完成。请重启 DSH-MOBILE（DSH-MOBILE-stop.cmd 后再启动），然后重试插件安装。'
