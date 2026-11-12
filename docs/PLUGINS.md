# 插件安装：来源支持与工具链

DSH-MOBILE 的插件由引擎自带的 `dsh-plugin-manager` 安装：它把插件写进当前
profile 的 `package.json`，再用 **pnpm** 拉取、用 **git** 访问 git 来源，最后在
`.plugin-manager\logs\operation-*\` 里留下日志。

插件管理器启动 pnpm / git 时走 `scrubbedParentEnv()`：**所有 `DSH_*` 环境变量都会
被剥掉**，命令行只按 PATH 查找。所以插件能不能装，取决于 `pnpm` 和 `git` 能否在
PATH 上被正常解析——而不是取决于 DSH-MOBILE 有没有设置 `DSH_NODE`。

## 1. 支持的来源

| 来源 | 写法 | 依赖 |
|---|---|---|
| npm registry | `dsh-pet-custom-balance`、`@scope/plugin@1.2.3` | pnpm |
| GitHub 仓库 | `https://github.com/owner/repo`、简写 `owner/repo` | pnpm（走 codeload 压缩包，**不调 git**） |
| 任意 git 地址 | `git+https://example.com/owner/repo.git#main` | pnpm + git |
| 本地目录 / tarball | `file:../my-plugin`、`./plugin-1.0.0.tgz` | pnpm |

要点：`github:owner/repo` 这类写法 pnpm 会直接下载 GitHub 的源码 zip，
**不会调用 git**；但只要仓库里带 `git+https://` 形式的依赖、或插件自己在
`prepare` 里跑 git，git 就必须存在。曾经的失败点正是这两条路都不通。

## 2. 为什么之前装不上

| 症状 | 日志位置 | 真实原因 |
|---|---|---|
| `[pnpm] Node.js runtime not found` | `.plugin-manager\logs\operation-*\pnpm.log` | PATH 上的 `pnpm` 命中了官方桌面版残留 shim（`%LOCALAPPDATA%\deepseek-harness\bin\pnpm.cmd`），它写死指向已删除的 `D:\DeepSeekHarness\runtime\win32-x64\DSH Tauri.exe`，而 `DSH_NODE` 又被 `scrubbedParentEnv()` 剥掉，于是命中 `:no_node` |
| `'git' 不是内部或外部命令` | `.plugin-manager\logs\github-connection-*\git.log` | 系统里根本没有 git，插件管理器的 GitHub 连通性探测（`git ls-remote`）直接失败 |

## 3. 修复：把 pnpm 和 git 内置进 `runtime\`

两个脚本都**幂等**：已装好时秒过，重新解压 / 升级 DSH-MOBILE 后重跑一次即可恢复。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\provision-pnpm.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\provision-git.ps1
```

| 脚本 | 安装内容 | 位置 |
|---|---|---|
| `provision-pnpm.ps1` | pnpm 11.28.5（版本取自 `runtime\engine\desktop-runtime.json` 的 `release.pnpmVersion`）+ `pnpm.cmd` / `pnpm.ps1` shim | `runtime\pnpm\`、`runtime\pnpm.cmd` |
| `provision-git.ps1` | 官方 MinGit 2.56.1（免安装、不写注册表）+ `git.cmd` / `git.ps1` shim | `runtime\git\`、`runtime\git.cmd` |

两个 shim 都只用 `%~dp0` 相对路径、**不引用任何 `DSH_*` 变量**，正好绕开环境变量
被剥掉的问题。`scripts\start.ps1` 本来就把 `runtime\` 前置到 PATH，所以引擎、
pnpm、git 以及它们的所有子进程都会优先命中内置版本，不会再落到官方残留 shim 上。

可选参数：

```powershell
# 指定版本 / 指定根目录 / 跳过自检
.\scripts\provision-pnpm.ps1 -PnpmVersion 12.0.0 -Root D:\DSH-MOBILE
.\scripts\provision-git.ps1  -GitVersion 2.56.1  -SkipVerify
```

下载源：pnpm 走 `registry.npmmirror.com`（失败回退 npm 官方源）；MinGit 先试
npmmirror 镜像，失败回退 GitHub Releases。

## 4. 验证

`provision-*.ps1` 会自己复刻引擎的真实条件（先从环境里剥掉 `DSH_*`，再用 PATH
解析）跑一遍自检：`where pnpm` / `where git`、`pnpm --version`、`git ls-remote`
到 GitHub、真实浅克隆。`scripts\doctor.ps1` 也会额外输出一段插件工具链报告。

手工核对：

```powershell
.\runtime\pnpm.cmd --version          # 11.28.5
.\runtime\git.cmd --version           # git version 2.56.1.windows.1
Get-ChildItem data\home\profiles\*\logs -ErrorAction SilentlyContinue
```

## 5. 已知限制

1. **只支持 HTTPS**：MinGit 不含 OpenSSH，`git@github.com:owner/repo.git` 这种
   SSH 地址用不了。用 `https://github.com/owner/repo`。
2. **私有仓库**把 token 写在地址里：`https://<token>@github.com/owner/repo`。
   MinGit 不带 Git Credential Manager，不会弹窗登录。
3. **仓库带构建脚本时会被 pnpm 拦下**：`prepare` / `postinstall` 属于 pnpm 11 的
   默认安全策略，安装会返回 `pendingBuilds`；在插件界面点「允许这些脚本并重试」
   即可。GitHub 上需要编译前端的插件基本都会碰到这一步。
4. **首次安装较慢**：pnpm 要建 store、解析依赖；git 来源还要 clone 整个仓库。
5. **升级会覆盖 `runtime\`**：重新解压便携包后 `runtime\pnpm`、`runtime\git` 会丢失，
   重跑两个 provision 脚本即可，`data\` 下的插件和会话不受影响。

## 6. 排障速查

```powershell
# 1) PATH 上到底解析到谁
cmd /c where pnpm
cmd /c where git

# 2) 最近一次安装的原始日志
Get-ChildItem data\home\profiles\web\.plugin-manager\logs |
  Sort-Object LastWriteTime -Descending | Select-Object -First 5

# 3) 自检（含 pnpm / git 段）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1
```

- `where pnpm` 指到 `D:\DSH-MOBILE\runtime\pnpm.cmd`、`where git` 指到
  `D:\DSH-MOBILE\runtime\git.cmd` 就算正常。
- 若仍指到 `%LOCALAPPDATA%\deepseek-harness\bin\*`，说明那个窗口的 PATH 是旧的，
  关掉重开 DSH-MOBILE；也可以把官方残留目录从用户 PATH 里移除（只改用户变量）：

```powershell
$p = [Environment]::GetEnvironmentVariable('Path','User')
$new = ($p -split ';' | Where-Object { $_ -and $_ -notlike '*\deepseek-harness\bin*' }) -join ';'
[Environment]::SetEnvironmentVariable('Path', $new, 'User')
```

- 装插件不需要重启引擎（PATH 每次执行时解析），但改完 PATH 后**重开 DSH-MOBILE**
  最稳妥。
