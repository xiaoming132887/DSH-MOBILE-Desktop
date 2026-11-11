# DSH-MOBILE

**DSH-MOBILE** 是一个第三方、便携、与官方 DeepSeek Harness 完全隔离的 DSH 客户端。
它使用官方 `@deepseek-ai/dsh` 引擎（当前 `0.2.2-rc.1`），但把**所有用户数据目录**换成了自己的一套，
因此可以和官方 DSH 同时安装、同时运行，互不影响。

> 这是**电脑端（Windows）源码仓库**；`runtime/` 下的 Node / Electron / dsh 引擎 /
> cloudflared 二进制不随仓库提交，首次运行前请按 [BUILD.md](BUILD.md) 准备。
> Android 端补丁见 [docs/ANDROID.md](docs/ANDROID.md)。

```
DSH-MOBILE\
├─ DSH-MOBILE.vbs          ← 双击启动（无控制台窗口）
├─ DSH-MOBILE.cmd          ← 调试启动（保留控制台，方便看报错）
├─ config\mobile.json      ← 端口、数据根、外壳类型
├─ data\                   ← 所有 DSH-MOBILE 数据（首次启动自动创建）
│  ├─ home\                ← DSH_HOME：会话、凭证、profiles、插件、缓存
│  ├─ agents\              ← DSH_AGENTS_HOME：AGENTS.md 等共享指令
│  ├─ electron\            ← Electron userData：Local Storage / IndexedDB / Cookie / GPUCache
│  ├─ appdata\             ← 子进程的 %APPDATA%
│  ├─ localappdata\        ← 子进程的 %LOCALAPPDATA%
│  ├─ temp\                ← 子进程的 TEMP / TMP
│  ├─ workspace\           ← 引擎默认工作目录
│  ├─ cache\  pnpm\        ← 工具链缓存
│  ├─ logs\                ← launcher.log / engine.log / engine.err.log / shell.log
│  └─ run\                 ← server.pid / shell.pid / port.txt
├─ runtime\
│  ├─ node.exe             ← 官方运行时 Node 24.21.0
│  ├─ engine\              ← 官方 dsh 0.2.2-rc.1 引擎（独立副本）
│  └─ electron\            ← Electron 外壳运行时
├─ shell\                  ← DSH-MOBILE 窗口外壳（标题固定为 DSH-MOBILE）
└─ scripts\                ← start / stop / status / doctor / shortcut / uninstall
```

## 1. 与官方 DSH 的隔离关系

| 数据 | 官方 DSH 默认 | DSH-MOBILE |
|---|---|---|
| DSH_HOME | `~/.dsh`（Windows：`C:\Users\<你>\.dsh`） | `DSH-MOBILE\data\home` |
| 共享指令根 | `~/.agents` | `DSH-MOBILE\data\agents` |
| Electron userData | `%APPDATA%\@deepseek-ai\dsh-desktop` | `DSH-MOBILE\data\electron` |
| Chromium session / cache | 跟随官方 userData | `DSH-MOBILE\data\electron\session` |
| TEMP / TMP | `%TEMP%` | `DSH-MOBILE\data\temp` |
| APPDATA / LOCALAPPDATA（子进程） | 当前用户 | `data\appdata` / `data\localappdata` |
| Web 端口 | 官方自动分配（当前机器为 49749） | 默认 `49760`，被占用时自动顺延 |
| 单实例锁 / 进程 | 官方自己的 userData | 自己的 `data\electron`，互不抢锁 |

- 官方和 DSH-MOBILE 的 `DSH_HOME`、`DSH_AGENTS_HOME`、Electron userData **没有任何交集**。
- 两个进程用不同的端口、不同的 userData，单实例锁不会互相触发。
- 官方升级/卸载不会动 `DSH-MOBILE\data`；删除 DSH-MOBILE 也不会动官方 `~/.dsh`。

### 自检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\doctor.ps1
```

输出 `RESULT: PASS` 表示所有数据根与官方默认路径都不重叠。

## 2. 启动

双击桌面快捷方式 **DSH-MOBILE**（由 `install-shortcut.ps1` 创建），或双击：

```
DSH-MOBILE.cmd
```

`DSH-MOBILE.vbs` 也可以无控制台启动，但部分 Windows 策略会禁用 `.vbs`；禁用时用 `.cmd` 或快捷方式。

首次启动会初始化独立 profile，通常需要 10–60 秒；之后是秒级。
窗口标题固定为 **DSH-MOBILE**，任务栏图标使用 DSH 图标。

> **首次使用**：DSH-MOBILE 不会读取官方 DSH 的登录态或 API Key（这正是隔离的要求）。
> 第一次打开后，在 DSH-MOBILE 自己的设置里登录 / 填 API Key、选择模型即可。
> 官方 DSH 的 `~/.dsh`、`%APPDATA%\@deepseek-ai\dsh-desktop` 完全不会被读写。

> **关闭窗口后**引擎默认继续在后台运行（这样重新打开是秒开）。
> 要彻底停止，双击 `DSH-MOBILE-stop.cmd`，或把 `config\mobile.json` 里的
> `keepEngineOnShellExit` 改为 `false`。

创建桌面快捷方式：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-shortcut.ps1
# 同时创建开始菜单项：加 -StartMenu
```

## 3. 常用命令

```powershell
# 查看状态（端口、PID、各数据目录大小）
.\scripts\status.ps1

# 停止引擎和窗口
.\scripts\stop.ps1

# 只看引擎 URL（不启动窗口，调试用）
.\scripts\start.ps1 -NoShell

# 卸载快捷方式（保留数据）
.\scripts\uninstall.ps1

# 卸载并删除 DSH-MOBILE 的全部数据
.\scripts\uninstall.ps1 -PurgeData
```

## 4. 数据备份 / 迁移

整个 `data\` 就是 DSH-MOBILE 的全部状态：

- 迁移到另一台机器：复制整个 `DSH-MOBILE` 文件夹即可（路径可以变，`config\mobile.json` 里的 `dataDir` 是相对路径）。
- 只备份会话：复制 `data\home\sessions\`。
- 只备份配置/凭证/插件：复制 `data\home\profiles\`（含 `.credentials.yaml`，注意保密）。
- 恢复：先退出 DSH-MOBILE，再把目录放回原位。

## 5. 引擎版本与升级

当前内置：官方 `@deepseek-ai/dsh@0.2.2-rc.1`（与官方桌面版 0.2.2-rc.1 同源）。

升级方式（手动、可控）：

1. 退出 DSH-MOBILE。
2. 用新版官方安装包中的 `resources\app.asar` 重新导出 `dsh` 树，替换 `runtime\engine\`；或
3. 在 `runtime\engine` 里用 pnpm 安装新版 `@deepseek-ai/dsh`，保持 `node_modules\@deepseek-ai\dsh\lib\bin.js` 入口不变。
4. 启动后看 `data\logs\engine.log` 的版本与 token URL。

DSH-MOBILE 不包含官方桌面版的自动更新器，升级由你自己控制，避免官方更新覆盖第三方副本。

## 6. 说明与限制

- 这是**第三方客户端**，不是 DeepSeek 官方发行版；引擎来自官方 MIT 许可的 `@deepseek-ai/dsh` 包。
- 外壳是 Electron 窗口加载 DSH Web UI。官方桌面壳独有的少数能力（托盘、原生更新、部分原生目录选择器）不在此外壳中；Web UI 的文件选择、下载、剪贴板、通知等由 Electron 提供。
- 引擎只监听 `127.0.0.1`，首次访问使用带 `?token=` 的一次性信任 URL；token 只写入本地 `data\logs\engine.log`。
- 不要把 `data\home\profiles\.credentials.yaml` 提交到 git 或发给别人。
- 如果 Windows 禁用了 `.vbs`，用 `DSH-MOBILE.cmd` 启动。

## 7. 远程连接手机 / 同步会话

见 **[README-REMOTE.md](README-REMOTE.md)**：

- **在 DSH-MOBILE 窗口点右下角「远程」按钮 → 开启连接**，面板会自动生成
  手机访问地址和 6 位密码；也可以右键托盘图标 →「远程连接…」，或按 `Ctrl+Shift+Alt+R`；
- 不在同一局域网时，面板切到 **公网（Cloudflare）** →「开启公网访问」，
  会自动生成 HTTPS 地址和 32 位密码，手机用浏览器即可；
- `remote\open-phone.ps1` 可在电脑上打开手机 DSH 的独立窗口；
- `remote\sync-sessions.mjs` 双向同步两端的 `sessions/*.jsonl`（手机端需安装
  `android\lan-web-proxy.mjs` 补丁）。
- Android 安装 `android\patch` 后：**设置 → 双端互联** 可直接连接电脑、
  双向/单向同步会话，并查看本机 LAN WebUI 地址与密码。

## 8. 目录速查

| 想看什么 | 去哪里 |
|---|---|
| 启动日志 | `data\logs\launcher.log` |
| 引擎输出 / 访问 token | `data\logs\engine.log` |
| 引擎错误 | `data\logs\engine.err.log` |
| 窗口日志 | `data\logs\shell.log` |
| 当前端口 | `data\run\port.txt` |
| 会话 | `data\home\sessions\` |
| 凭证 / 插件 / 模型配置 | `data\home\profiles\web\` |
| 工作区文件 | `data\workspace\`（可在 UI 中另选） |
