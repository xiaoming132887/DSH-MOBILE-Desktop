# DSH-MOBILE 远程连接与会话同步

> 手机端补丁不在本仓库，见 [docs/ANDROID.md](docs/ANDROID.md) 与
> [Android PR #105](https://github.com/Soodok/Deepseek-Harness-Local-Android/pull/105)。

这套工具把 **Windows 上的 DSH-MOBILE** 和 **Android 上的 DSH Mobile**
（[Soodok/Deepseek-Harness-Local-Android](https://github.com/Soodok/Deepseek-Harness-Local-Android)）
连在同一个局域网里，做三件事：

1. **手机远程操控电脑**：手机浏览器打开 PC 的 DSH Web UI，使用电脑上的 Agent（文件、终端、工作区）。
2. **电脑远程操控手机**：电脑上的独立窗口打开手机 DSH Web UI，使用手机上的 Agent（屏幕、点按、通知等设备能力）。
3. **同步会话记录**：把两端的 `$DSH_HOME/sessions/*.jsonl` 双向镜像。

```
┌──────────────────────┐         LAN          ┌──────────────────────┐
│ Windows DSH-MOBILE   │  http://PC:3091      │ Android DSH Mobile   │
│ 127.0.0.1:49760      │ ◀──────────────────▶ │ 127.0.0.1:3080       │
│ remote/lan-proxy.mjs │  http://PHONE:3090   │ lan-web-proxy.mjs    │
│ data\home\sessions   │ ◀──── sync ────────▶ │ dsh-home/sessions    │
└──────────────────────┘                      └──────────────────────┘
```

## 手机端入口（Android 补丁）

Android 仓库需要先应用 `android/patch/` 里的补丁并重新构建，安装后：

**设置 → 双端互联**

- **连接电脑 DSH**：填电脑地址 + 密码，直接打开电脑 DSH；
- **同步会话**：双向 / 只拉取 / 只推送；
- **本机服务**：显示手机 LAN WebUI 地址、密码、远程访问配对地址。

手机端也可以主动连电脑的**公网 Cloudflare 地址**做同步，不需要手机装 Tailscale。

## 一、手机 → 电脑（手机控制电脑）

### 方式 A：在 DSH-MOBILE 里手动开启（推荐）

1. 打开 DSH-MOBILE 主窗口；
2. 点窗口右下角的 **「远程」** 悬浮按钮，或右键任务栏托盘图标 → **远程连接…**，
   也可以按 **Ctrl+Shift+Alt+R**；
3. 在弹出的「远程连接」面板里点 **「开启连接」**；
4. 面板会自动生成并显示：
   - **6 位连接密码**（大号字，可一键复制）
   - **手机访问地址**（本机所有局域网 IPv4，可逐个复制）
5. 手机浏览器打开地址、输入密码即可。点面板里的 **「关闭连接」** 停止。

连接由当前 DSH-MOBILE 进程管理：关闭 DSH-MOBILE 时会自动停止代理，密码每次开启都重新生成。

### 方式 B：公网（Cloudflare，手机零安装）

手机不在同一个 Wi-Fi、甚至用蜂窝网络时，用面板里的 **公网（Cloudflare）** 模式：

1. 打开「远程连接」面板 → 上方切到 **公网（Cloudflare）**；
2. 点 **「开启公网访问」**，确认提示；
3. 面板会自动：
   - 启动内置的 `cloudflared`（约 55 MB，已随 DSH-MOBILE 打包，无需单独安装）
   - 生成一个 `https://xxxx.trycloudflare.com` 临时 HTTPS 地址
   - 生成 **32 位连接密码**
4. 手机直接用浏览器打开这个 HTTPS 地址，输入 32 位密码即可。

注意：

- URL 和密码每次开启都会重新生成；关闭面板/退出 DSH-MOBILE 后隧道立即失效。
- 这是**公网可达**的地址，密码是唯一门槛；只临时使用，用完马上关。
- 该模式只暴露电脑端；手机端 3090 仍需要局域网/Tailscale 才能被电脑访问。
  会话同步在公网模式下不适用，请用局域网、Tailscale 或 Syncthing。

### 方式 C：命令行

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\DSH-MOBILE\remote\start-pc-lan.ps1
```

输出示例：

```
DSH-MOBILE remote access is ON
  6-digit code : 918680
  LAN URL(s)   :
    http://10.6.56.121:3091
```

手机连同一个 Wi-Fi，浏览器打开 `http://10.6.56.121:3091`，输入 6 位码即可。
进入后看到的就是电脑上的 DSH 界面，Agent 操作的是电脑的文件和终端。

- 如果手机打不开：Windows 防火墙放行 TCP 3091（第一次可加 `-OpenFirewall`，需要管理员）；
  确认手机和电脑在同一网段；不要做公网端口映射。
- 停止：`D:\DSH-MOBILE\remote\stop-pc-lan.ps1`
- 换验证码：重新运行 `start-pc-lan.ps1`（每次启动都会生成新码）。

## 二、电脑 → 手机（电脑控制手机）

先在手机上：

1. 打开 DSH Mobile → 设置 → 扩展 → **局域网访问 WebUI**；
2. 记下 6 位验证码和 `http://<手机IP>:3090`。

在电脑上：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File D:\DSH-MOBILE\remote\open-phone.ps1 `
  -PhoneUrl http://192.168.1.23:3090 -Code 123456
```

会弹出一个独立的 **DSH-MOBILE Remote Phone** 窗口，直接进入手机 DSH 界面。
手机端的屏幕、点按、通知、剪贴板等设备能力都在这个界面里由手机 Agent 调用。

也可以直接用浏览器打开 `http://<手机IP>:3090`。

## 三、同步会话记录

### 3.1 手机端补丁（必需）

手机现有 `lan-web-proxy.mjs` 只代理 WebUI，不暴露会话文件。仓库里已经准备好
补丁后的完整文件：

```
DSH-MOBILE\android\lan-web-proxy.mjs
```

覆盖到 Android 仓库：

```
app/src/main/assets/tools/lan-web-proxy.mjs
```

然后重新构建安装：

```bash
./gradlew :app:assembleDebug -Pabi=arm64-v8a -Ppackage=noruntime
```

细节见 `android\README.md`。补丁只增加 `/__dshm/sync/*` 端点，仍由同一个 6 位码保护，
且只能访问 `$DSH_HOME/sessions` 下的 `.jsonl`。

> 不重建 APK 时，手机 → 电脑、电脑 → 手机 的远程控制仍然可用；只有会话同步需要这个补丁。

### 3.2 电脑端同步

手机打开「局域网访问 WebUI」后，在电脑上：

```powershell
node D:\DSH-MOBILE\remote\sync-sessions.mjs `
  --url http://192.168.1.23:3090 `
  --code 123456
```

行为：

| 情况 | 处理 |
|---|---|
| 只有手机有 | 下载到 `D:\DSH-MOBILE\data\home\sessions` |
| 只有电脑有 | 上传到手机 `$DSH_HOME/sessions` |
| 两边相同（sha256） | 跳过 |
| 两边不同但一方是另一方的前缀（JSONL 追加） | 较长的一方覆盖较短的一方 |
| 两边真正分叉 | 本地副本备份到 `data\sync-conflicts\...`，按 mtime 新的一方为准 |

选项：

```powershell
# 只拉手机 -> 电脑
node ...\sync-sessions.mjs --url ... --code ... --direction pull

# 只推电脑 -> 手机
node ...\sync-sessions.mjs --url ... --code ... --direction push

# 只看差异，不写
node ...\sync-sessions.mjs --url ... --code ... --dry-run
```

同步日志在 `D:\DSH-MOBILE\data\logs\sync.log`。
同步完成后重启 DSH-MOBILE（或刷新会话列表）即可看到新会话。

**手机端直接同步（安装 Android 补丁后）**：手机 设置 → 双端互联 →
填电脑地址（局域网 `http://PC-IP:3091` 或公网 `https://xxx.trycloudflare.com`）
和密码 → 双向同步 / 只拉取 / 只推送。手机作为客户端时，电脑的公网模式即可用，
手机不需要装 Tailscale；电脑主动拉手机仍需电脑能访问手机 3090/3091。

> 同步范围只有 `sessions/**/*.jsonl` 会话记录；聊天里的图片附件、工作区文件、
> 凭证和插件配置**不会**被同步。附件仍由各自的 `$DSH_HOME` 保存。

### 3.3 冲突与并发

- DSH 会话是追加式 JSONL；正常“一台设备继续写”会走前缀快进，不会冲突。
- 两台设备同时写同一个会话才会真正分叉；此时保留两份，原文件按 mtime 新者为准，
  另一份在 `data\sync-conflicts` 下，可人工合并。
- 建议同步前退出正在运行的任务，避免边写边同步。

## 四、安全

- 两个代理都只应在**可信局域网**使用，验证码就是唯一门槛；不要开公网映射。
- 代理背后的 Agent 有完整文件/终端权限（手机端还有设备能力），验证码不要截图外传。
- 不使用时停止 PC 代理（`stop-pc-lan.ps1`）并在手机上关闭「局域网访问 WebUI」。
- 会话同步端点只读写 `sessions/*.jsonl`，不能读写凭证、插件或任意文件。

## 五、已验证 / 未验证

已在当前机器验证：

- PC 代理 `http://10.6.56.121:3091` 登录页、6 位码、DSH UI 200、页面标题 `DSH-MOBILE`。
- PC 端 `/__dshm/sync/ping`、manifest、上传/下载、前缀快进。
- `open-phone.ps1` 能打开独立 `DSH-MOBILE Remote Phone` 窗口。
- 主窗口的「远程」按钮 / 托盘「远程连接…」/ `Ctrl+Shift+Alt+R` 能打开面板；
  点「开启连接」会生成 6 位密码和局域网地址并启动代理。
- 公网模式：cloudflared 启动并生成 `https://*.trycloudflare.com` 地址，
  用 32 位密码访问返回 HTTP 200，页面标题 `DSH-MOBILE`；
  点「关闭连接」后 cloudflared 和代理进程都退出。

未在本机验证（因为没有 Android 构建环境/真机）：

- 打补丁后的手机 APK 实际运行；
- 手机 3090 与 PC 3091 之间的真实 Wi-Fi 往返。

手机端构建后按 `android\README.md` 的步骤跑一次即可确认。
