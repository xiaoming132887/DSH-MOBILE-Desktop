#requires -Version 5.1
<#
  DSH-MOBILE 便携版 git 供应脚本（可重复执行）

  用途：让 DSH-MOBILE 能从 GitHub / 任意 git 仓库安装插件。DSH-MOBILE 自带
        node + engine，但没有 git；插件管理器探测 GitHub 连通性时会跑 `git ls-remote`，
        pnpm 安装 git 依赖时也要 `git`，缺少时日志里是
        `github-connection-*\git.log: 'git' 不是内部或外部命令`。

  做法：下载 GitHub 官方 MinGit（免安装、无注册表、无开始菜单），解包到
        <DSH-MOBILE>\runtime\git，并在 runtime\ 放 git.cmd / git.ps1 两个 shim。
        start.ps1 会把 runtime\ 前置到 PATH，所以引擎、pnpm 及其子进程都优先命中它。

  限制：MinGit 不含 OpenSSH，只支持 HTTPS 形式的仓库地址
        （https://github.com/owner/repo.git）；git@github.com: SSH 地址不可用。

  用法（放在 <DSH-MOBILE>\scripts\ 或任意位置，根目录自动推断）：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\provision-git.ps1
    可选：-Root D:\DSH-MOBILE  -GitVersion 2.56.1  -SkipVerify
  重新解压/升级 DSH-MOBILE 后重跑一次即可（已装好时秒过）。
#>
[CmdletBinding()]
param(
  [string]$Root = '',
  [string]$GitVersion = '2.56.1',
  [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# $Root 缺省时按脚本位置推断
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

$runtime = Join-Path $Root 'runtime'
$node = Join-Path $runtime 'node.exe'
$dest = Join-Path $runtime 'git'
$gitExe = Join-Path $dest 'cmd\git.exe'

if (-not (Test-Path -LiteralPath $node -PathType Leaf)) { throw "找不到 Node 运行时：$node" }

# ------------------------------------------------------- 已有安装则直接复用
$installed = $null
if (Test-Path -LiteralPath $gitExe -PathType Leaf) {
  try { $installed = (& $gitExe --version 2>$null | Select-Object -First 1) -replace '^git version\s+', '' } catch { $installed = $null }
}
if ($installed) {
  Write-Ok "git $installed 已装在 $dest，跳过下载"
} else {
  # ---------------------------------------------------------------- download
  $tmp = Join-Path $env:TEMP 'dsh-mobile-git'
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zip = Join-Path $tmp "MinGit-$GitVersion-64-bit.zip"
  $fetchScript = Join-Path $tmp 'fetch.cjs'
  @'
const fs = require("node:fs");
const [dst, version] = [process.argv[2], process.argv[3]];
const tag = `v${version}.windows.1`;
const name = `MinGit-${version}-64-bit.zip`;
const urls = [
  `https://registry.npmmirror.com/-/binary/git-for-windows/${tag}/${name}`,
  `https://github.com/git-for-windows/git/releases/download/${tag}/${name}`,
];
(async () => {
  for (const url of urls) {
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(600000) });
      if (!res.ok) { console.error("HTTP " + res.status + " " + url); continue; }
      const bytes = Buffer.from(await res.arrayBuffer());
      if (bytes.length < 5000000) { console.error("too small (" + bytes.length + ") from " + url); continue; }
      fs.writeFileSync(dst, bytes);
      console.log("downloaded " + url + " (" + Math.round(bytes.length / 1048576) + " MB)");
      process.exit(0);
    } catch (error) {
      console.error(url + " -> " + error.message);
    }
  }
  process.exit(1);
})();
'@ | Set-Content -LiteralPath $fetchScript -Encoding UTF8

  Write-Step "下载 MinGit $GitVersion（npmmirror 优先，失败回退 GitHub releases）"
  & $node $fetchScript $zip $GitVersion
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $zip)) { throw "MinGit 下载失败；请检查网络或代理后重试" }

  # ---------------------------------------------------------------- extract
  Write-Step "解包到 $dest"
  $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
  if (-not (Test-Path -LiteralPath $tar)) { throw "找不到 tar.exe：$tar" }
  # 保留已存在的运行时目录，先删后建保证干净
  $staging = Join-Path $tmp 'stage'
  if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $staging | Out-Null
  & $tar -xf $zip -C $staging
  if ($LASTEXITCODE -ne 0) { throw "解包失败（tar 退出码 $LASTEXITCODE）" }

  # 规范化：MinGit 的 zip 可能把内容放在单层目录里
  $source = $staging
  if (-not (Test-Path -LiteralPath (Join-Path $source 'cmd\git.exe'))) {
    $nested = Get-ChildItem -LiteralPath $staging -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'cmd\git.exe') } | Select-Object -First 1
    if ($nested) { $source = $nested.FullName }
  }
  if (-not (Test-Path -LiteralPath (Join-Path $source 'cmd\git.exe'))) {
    throw "解包结果里找不到 cmd\git.exe，压缩包结构可能已变化"
  }
  if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  Get-ChildItem -LiteralPath $source -Force | Move-Item -Destination $dest -Force
  Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $gitExe -PathType Leaf)) { throw "安装后找不到 $gitExe" }
  $installed = (& $gitExe --version) -replace '^git version\s+', ''
  Write-Ok "git $installed 已就位"
}

# ---------------------------------------------------------------- shims
# 只依赖 %~dp0：git.exe 留在 MinGit 自己的目录布局里，靠相对位置定位它的
# mingw64\libexec 等部件；shim 只做转发，不设 GIT_EXEC_PATH 之类变量。
$cmdShim = @'
@echo off
rem DSH-MOBILE - portable git shim (generated by provision-git.ps1)
rem Forwards to the bundled MinGit in runtime\git; %* is handed over directly.
"%~dp0git\cmd\git.exe" %*
exit /b %ERRORLEVEL%
'@
$ps1Shim = @'
# DSH-MOBILE - portable git shim (generated by provision-git.ps1)
& "$PSScriptRoot\git\cmd\git.exe" @args
exit $LASTEXITCODE
'@
Set-Content -LiteralPath (Join-Path $runtime 'git.cmd') -Value $cmdShim -Encoding ASCII
Set-Content -LiteralPath (Join-Path $runtime 'git.ps1') -Value $ps1Shim -Encoding UTF8
Write-Ok "已写入 shim：$runtime\git.cmd、$runtime\git.ps1"

if ($SkipVerify) { Write-Ok '已跳过校验（-SkipVerify）'; return }

# ---------------------------------------------------------------- verify
# 复刻真实条件：剥掉 DSH_*，再用 PATH 找 git（插件管理器正是这样起子进程的）。
Write-Step '校验 1：模拟 scrubbedParentEnv()（剥掉 DSH_*）后的 git 解析'
Get-ChildItem Env: | Where-Object { $_.Name -like 'DSH_*' } | ForEach-Object {
  Remove-Item -LiteralPath ("Env:" + $_.Name) -ErrorAction SilentlyContinue
}
$env:PATH = $runtime + ';' + $env:PATH
$resolved = (& cmd /c where git 2>$null | Select-Object -First 1).Trim()
$version = (& cmd /c 'git --version' 2>&1 | Select-Object -Last 1).Trim()
if ($resolved -and ($version -match '^git version')) {
  Write-Ok "git 解析到：$resolved"
  Write-Ok "git --version -> $version"
} else {
  Write-Warn2 "git 解析异常：resolved='$resolved' version='$version'"
}

Write-Step '校验 2：git ls-remote 到 GitHub（插件管理器的连通性探测）'
$probe = (& cmd /c 'git ls-remote --heads https://github.com/git-for-windows/git main 2>&1' | Select-Object -Last 1)
if ($probe -match '[0-9a-f]{40}') { Write-Ok "ls-remote 正常：$($probe.Trim())" }
else { Write-Warn2 "ls-remote 未返回提交号：$($probe.Trim())" }

Write-Step '校验 3：真实浅克隆一个公共仓库'
$scratchRoot = Join-Path $env:TEMP 'git-selftest'
$scratch = Join-Path $scratchRoot 'Hello-World'
Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null
try {
  Push-Location $scratchRoot
  try {
    & cmd /c 'git clone --depth 1 --quiet https://github.com/octocat/Hello-World Hello-World 2>&1' | Out-Null
  } finally { Pop-Location }
  if (Test-Path -LiteralPath (Join-Path $scratch '.git')) {
    Write-Ok "clone 成功：$scratch"
  } else {
    Write-Warn2 'clone 未产生 .git 目录'
  }
} finally {
  Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Ok '修复完成。请重启 DSH-MOBILE（DSH-MOBILE-stop.cmd 后再启动），然后重试插件安装。'
