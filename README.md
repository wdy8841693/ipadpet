# 鲸鱼娘 DSH 宠物 🐋

一位住在 iPad 全屏海底世界里的**鲸鱼娘**——蓝发女仆裙 Q 版少女，鲸尾 + 鳍耳，立绘来自开源项目
[dsh-whale-musume](https://github.com/Sutera-Diffusus/dsh-whale-musume)（MIT）。

为 **iPad mini 4（A8 / 2GB RAM / iPadOS 15.8.x）** 量身打造：SpriteKit 整图切换 + 程序化运动动画，
30fps 低功耗；再通过一个 **DSH Host 插件**把语音接进你本机正在运行的 DeepSeek Harness——
宠物会话就是完整的 DSH Agent：能查资料、跑命令、改文件，任务开始/完成/需要授权会主动提醒，
**会话不用你管**。

| 部分 | 版本 | 说明 |
|---|---|---|
| iPad App（`WhalePet/`） | **v1.2.6** | SpriteKit 宠物 + 语音采集/TTS + 网关客户端 |
| Flutter 客户端（`Clients/whalepet_flutter/`） | **v0.3.2** | Android 全屏 + Windows / macOS 桌宠，共用 `lib/core/`，走 `/api/agent` 文本协议 |
| 原生 Java 原型（`Android/`） | v1.3.0-android.1 | 用 SurfaceView + Canvas 手写的第一版 Android App，保留作参考/对比 |
| DSH 插件（`Plugin/whalepet-dsh-bridge/`） | **0.4.1** | 局域网网关：旧音频通道 + 新 `/api/agent` 文本通道，共用一个 Agent 服务 |

![预览](docs/preview.png)

## 项目结构

```
ipadpet/
├── WhalePet/                 # iPad App 源码（SwiftUI 之外的纯 UIKit + SpriteKit）
│   ├── Pet/                  #   状态机、数值、存档、台词
│   ├── Scenes/  UI/          #   SpriteKit 场景、气泡、HUD
│   ├── Voice/                #   AVAudioEngine 采集、AVAudioConverter 16k、TTS
│   ├── Networking/           #   DSHClient（HTTP + WebSocket，iOS 15 兼容）
│   ├── Support/              #   AppDelegate / ViewController / 服务器设置（Keychain）
│   └── Resources.xcassets/   #   立绘与图标（来自上游 MIT 素材）
├── WhalePetTests/            # 纯逻辑 XCTest（状态机/数值/存档/配置校验）
├── Clients/whalepet_flutter/ # 跨平台客户端（Flutter）：Android 全屏 + Windows / macOS 桌宠
│   ├── lib/core/             #   纯 Dart 共享核心：宠物/存档/协议/语音状态机
│   ├── lib/ui/mobile_scene/  #   Android 场景（海底背景、立绘、操作栏、面板）
│   ├── lib/ui/desktop_pet/   #   桌面透明桌宠场景（Windows / macOS）
│   ├── lib/platform/         #   平台适配层（Android 通道 / Win32 FFI / AppKit 通道 / 系统 TTS）
│   ├── android/              #   Android runner + Kotlin 原生桥（识别/TTS/Keystore）
│   ├── windows/              #   Windows runner（无边框 + 分层 + 置顶）
│   ├── macos/                #   macOS runner（AppKit 透明窗口 + 菜单栏状态项）
│   └── tool/                 #   打包/验证脚本（Android、Windows、macOS 各一套）
├── Android/                  # 原生 Java 原型（不依赖 Flutter，保留参考）
│   ├── app/src/main/java/    #   MainActivity + pet/net/voice/ui 四个包
│   └── build-apk.sh          #   aapt2 + javac + d8 + apksigner 手工打包
├── Plugin/
│   └── whalepet-dsh-bridge/  # DSH 插件（Host 网关 + 浏览器设置页，零第三方依赖）
│       ├── index.js          #   插件入口：会话/人格/权限/任务提醒
│       ├── client.js         #   设置页（DSH 设置 → 鲸鱼娘）
│       ├── src/settings*.js  #   运行时设置存储 + 设置接口
│       ├── src/              #   传输层（server/ws）、VAD、唤醒词、WAV
│       ├── test/             #   node:test：纯逻辑 + 真 HTTP/WS + 假 ctx 集成
│       ├── cordis.patch.yml  #   bundle 配置（端口/权限预设/会话轮换）
│       └── README.md         #   插件安装、协议、配置、排障
├── Tools/
│   ├── art/                  # 素材导入/生成脚本
│   ├── scripts/check.py      # Linux 侧静态自检（Swift/资产/权限/插件测试）
│   └── deploy/               # PM2 部署：dsh-web.sh（直连本地 dsh）、pm2-switch.sh
├── docs/
│   ├── ARCHITECTURE.md       # 整体架构、协议、会话策略、排障
│   ├── DESIGN.md             # 设计取舍与 A8 性能预算
│   ├── refs/                 # DSH Host API / bundle 打包契约调研
│   ├── preview.png
│   ├── ACKNOWLEDGEMENTS.md   # 开源参考致谢
│   └── THIRD-PARTY-NOTICES.md
├── project.yml               # XcodeGen 工程唯一事实源（.xcodeproj 不入库）
├── LICENSE
└── README.md
```

## 架构

```
iPad App ──HTTP/WS(16kHz PCM)──▶ 插件 whalepet-bridge :8787 ──▶ 工作 DSH
                                    ├─ ctx.speechToText   SenseVoice（本地 CPU）
                                    ├─ 唤醒词 / VAD / 状态机
                                    └─ ctx.sessionController → 完整 Agent 会话
```

细节（协议、事件、会话轮换、安全边界）见 **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**。

## 能力

| 能力 | 说明 |
|---|---|
| 语音唤醒 | 说「**小鲸小鲸**」唤醒，宠物答一句「我在」，接着说指令；也支持一句话带命令 |
| 设置界面 | DSH 设置 → 「鲸鱼娘」：改人设、唤醒词/应答、其它会话播报、完成播报字数，附 iPad 连接地址与令牌 |
| 跨平台通道 | 新增 `/api/agent` 纯文本通道（protocol v2：幂等 request_id、断线补发、多客户端隔离），旧 `/api/audio` 保持不变 |
| 跨平台客户端 | Flutter 三端共用 `lib/core/`：Android 全屏场景（系统识别/TTS）、Windows 桌宠（SAPI 离线唤醒+听写）、macOS 桌宠（文字版 + AVSpeechSynthesizer） |
| 真 Agent | 宠物会话是完整的 DSH Agent：联网检索、读文件、跑命令、多步执行（默认权限 `workspace-write`） |
| 设置页 | DSH「设置 → 鲸鱼娘」可改人设/唤醒词/播报；保存立即生效（写 `~/.dsh/whalepet/settings.json`）；页面里直接给出 iPad 连接地址与令牌 |
| 任务提醒 | 前台时宠物用**语音播报**：宠物自己的任务（开始/授权/断线恢复/失败）**以及其它 DSH 会话的任务**（开始/完成/授权）都会报一句；断线期间完成的任务重连后补播 |
| 不用管会话 | **永久同一个会话**（不换新），空闲自动归档（列表不可见）；上下文由 `compaction-basic` 自动压缩兜底 |
| 本地播报 | 回复经口语化清洗后用 AVSpeechSynthesizer 播放；播报期间自动闭麦防自触发 |
| 离线宠物 | 不连服务器也能摸头/投喂/玩耍/睡觉，数值与存档都在本地 |
| 设备适配 | iPadOS 15 部署目标、A8 省电预算、四方向自适应、全屏独占 |

## 快速开始

### 1. DSH 侧（一次性）

前置：当前 profile 已启用语音输入 bundle（`speech-to-text` 行、`defaultProvider: sensevoice-local`）
与 Web 会话控制器；插件只 `inject` 这些服务，不重复插入。

```bash
# 在 DSH 里安装插件（target 填本仓库 Plugin/whalepet-dsh-bridge 的绝对路径；
# 安装会写入 profile 的 package.json 与 bundle 列表）
plugin_manager { action: "install_bundle",
                 target: "<你的克隆路径>/ipadpet/Plugin/whalepet-dsh-bridge" }
```

- 令牌：首次启动自动生成在 **`~/.dsh/whalepet/ipad-token`**（0600，重启不变）；
- 配置（端口、权限预设、会话轮换、人名/唤醒词等）在
  [Plugin/whalepet-dsh-bridge/cordis.patch.yml](Plugin/whalepet-dsh-bridge/cordis.patch.yml)，
  也可在 profile 的 patch 里按 id `whalepet-bridge` 覆盖；
- 运行数据都在 `~/.dsh/whalepet/`：`ipad-token`、`access.log`、`sessions` 元数据、宠物工作目录 `workspace/`。

### 2. iPad 侧（需要一台 Mac）

```bash
# 1）生成工程（project.yml 是唯一事实源）
brew install xcodegen
xcodegen generate

# 2）打开并真机运行
open WhalePet.xcodeproj
```

Xcode 里选 WhalePet target → Signing 选免费 Apple ID（7 天有效期）→ 连 iPad mini 4 → ⌘R。
首次运行允许「本地网络」与「麦克风」权限。

在 App 里点 **⚙️ → 语音服务器**，填：

- 服务器地址：`http://<运行 DSH 的机器 IP>:8787`（同一 WiFi 填局域网 IP；走 ZeroTier 填 ZeroTier IP）
- 访问令牌：`~/.dsh/whalepet/ipad-token` 的内容

点「保存并测试」，提示「连接成功」即可说「小鲸小鲸」。

### 3. Android 侧（Flutter 客户端，推荐）

```bash
cd Clients/whalepet_flutter
export ANDROID_HOME=<Android SDK>
bash tool/build_android.sh      # → dist/whalepet-android-<版本>-release.apk（版本取自 pubspec）
adb install -r dist/whalepet-android-*-release.apk
```

需要 Flutter 3.50 + Android SDK platform 36 / build-tools 36 + JDK 17。
装好后点底部 **⚙️ 设置** 填服务器地址与令牌；点 **🎙️ 说话** 说指令，回答由系统 TTS 播报。
立绘、状态机、台词、`/api/agent` 协议与桌面端完全共用 `lib/core/`。

> 工程在网络盘上时必须用上面的脚本（会先复制到本地再构建）——
> Windows 版 `flutter`/`gradle` 的 `.bat` 不接受 UNC 路径作为工作目录。

细节见 [Clients/whalepet_flutter/README.md](Clients/whalepet_flutter/README.md)。
另有早期手写的原生 Java 版（`Android/`，不依赖 Flutter），构建方式见 [Android/README.md](Android/README.md)。

### 4. Windows 桌宠（`Clients/whalepet_flutter/`）

前置：Windows 10/11 x64 + Flutter SDK + Visual Studio 2022 生成工具的 **C++ 桌面开发**组件
（MSVC + CMake + Windows SDK，缺一个都会 `flutter doctor` 报 incomplete）。

```bash
cd Clients/whalepet_flutter
flutter pub get
flutter run -d windows                       # 调试
flutter build windows --release              # Release
python tool/package_release.py --no-build    # dist/whalepet-windows-x64-<version>.zip
```

便携包自带 VC 运行库（`vcruntime140*` / `msvcp140`，app-local），目标机不用装
VC++ Redistributable；整目录一起拷贝，别只拿 exe。

启动后是一个 380×560 的**透明置顶窗口**，里面只有宠物和气泡：单击摸头、双击聊天、
右键菜单（摸头/投喂/玩/语音开关/点击说话/设置/睡觉/重连/退出）、按住拖动整窗移动；
鼠标移到透明区域自动穿透，不挡后面软件的点击。第一次用先右键 →「设置」，
填服务器地址（`http://<DSH 机器 IP>:8787`）与 `~/.dsh/whalepet/ipad-token` 的内容。

本地语音（全离线，零模型下载）：待机只用 SAPI5 中文桌面识别器跑「唤醒词小语法」，
说「小鲸小鲸」后播「我在」并切到听写语法，识别成文本后上行；播报期间自动闭麦。
没有麦克风也可以用 `WHALEPET_VOICE_WAV=<wav>` 注入音频跑通全链路。
数据在 `%APPDATA%\WhalePet\`：设置明文、令牌 DPAPI 加密、宠物存档原子写。

### 5. macOS 桌宠（`Clients/whalepet_flutter/`）

前置：macOS 13+（Intel / Apple Silicon 均可）+ Xcode + Flutter SDK。

```bash
cd Clients/whalepet_flutter
flutter pub get
flutter run -d macos                              # 调试
flutter build macos --release                     # Release
python3 tool/package_release_macos.py --no-build  # dist/whalepet-macos-<version>.zip
```

同样是 380×560 的**透明置顶小窗**，窗口能力交给原生 AppKit（`macos/Runner`）：

- 不进 Dock、不抢菜单栏，菜单栏常驻 🐳 状态项（显示 / 退出），退出前自动落盘；
- 常驻所有空间（含全屏应用之上）；走路/游泳时窗口跟着宠物移动，自动夹在显示器工作区内；
- 鼠标移到透明区域自动穿透（`ignoresMouseEvents`）；
- 交互与 Windows 完全一致：单击摸头、双击聊天、右键菜单、按住拖动。

**v1 能力边界**：文字对话（`/api/agent`）+ 系统 TTS（AVSpeechSynthesizer zh-CN）已通；
本地唤醒词与语音识别未接（设置里语音入口显示「语音关闭」），留待下一阶段。
令牌暂存 `~/.whalepet/token.bin` 明文 0600（同机 `ipad-token` 也是 0600 明文，
威胁模型一致），Keychain 与公证待补。出包后首次运行需「右键 → 打开」绕过 Gatekeeper。

细节见 [Clients/whalepet_flutter/README.md](Clients/whalepet_flutter/README.md)。

## 配置（插件）

见 [Plugin/whalepet-dsh-bridge/README.md](Plugin/whalepet-dsh-bridge/README.md)，常用项：

| 键 | 默认 | 说明 |
|---|---|---|
| `host` / `port` | `0.0.0.0` / `8787` | 监听地址；iPad 连接的端口 |
| `wakePhrase` / `wakeAliases` | `小鲸小鲸` + 同音别名 | 唤醒词表 |
| `permissionPreset` | `workspace-write` | 宠物会话权限预设（沙箱 + 审批组合） |
| `rotateAfterHours` | `0`（本机） | `0` = 永久同一个会话（Super Agent 式）；`>0` = 每 N 小时换新、旧的归档 |
| `archiveWhenIdle` | `true` | 空闲归档（DSH 列表不可见），说话前自动恢复 |
| `requestTimeoutMs` / `maxWaitMs` | `300000` / `600000` | 单次等待 / 单轮最长等待 |
| `voicePersona` | 内置鲸鱼娘人格 | 自定义宠物人格（仅作用于宠物会话） |

## 测试与自检

```bash
# Linux 侧全量静态自检（Swift 括号、工程配置、纹理引用、显存预算、权限声明、插件测试）
python3 Tools/scripts/check.py

# 插件单元/集成测试（89 个）
cd Plugin/whalepet-dsh-bridge && node --test test/*.test.js
```

Swift 编译与真机验证必须在 macOS + Xcode 上做，Linux 侧只能做静态哨兵。

## 部署（PM2，可选）

`dsh web` 默认只监听 `127.0.0.1:3080`；若用 nginx/ZeroTier 暴露浏览器界面，建议用直连入口托管：

```bash
# 首次：把 PM2 里的 dsh 从 npx 切到本地安装（带失败回退，日志 Tools/deploy/pm2-switch.log）
pm2 start Tools/deploy/pm2-switch.sh --name dsh-switch --interpreter bash --no-autorestart
```

`Tools/deploy/dsh-web.sh` 会按「npx 缓存 → npm 全局 → npx 兜底」直连已安装的 dsh，避免
`npx @latest` 在 registry 抽风时静默崩溃、PM2 重启循环。

## 文档

- [架构与协议](docs/ARCHITECTURE.md)
- [设计说明（含 A8 性能预算）](docs/DESIGN.md)
- [插件 README（安装/协议/配置/排障）](Plugin/whalepet-dsh-bridge/README.md)
- [DSH Host API 调研](docs/refs/dsh-host-api.md) · [bundle 打包契约](docs/refs/dsh-bundle-packaging.md)
- [开源参考致谢](docs/ACKNOWLEDGEMENTS.md) · [第三方素材许可](docs/THIRD-PARTY-NOTICES.md)

## 参考与借用（开源致谢）

本项目站在这些开源项目的肩膀上，**素材借用 / 思路参考 / 平台依赖**三类分开列清楚：

| 项目 | 许可证 | 与本项目的关系 |
|---|---|---|
| [dsh-whale-musume](https://github.com/Sutera-Diffusus/dsh-whale-musume) | MIT | **直接借用素材**：鲸鱼娘全部角色立绘（10 张状态图 + AppIcon）来自其 npm 包 v2.5.3，仅做尺寸归一化与 webp→PNG 转换，iPad 与 Flutter 三端共用；已保留上游版权声明 |
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) | MIT | **运行平台**：DSH 插件按官方 Host API 编写，语音识别（SenseVoice）与 Agent 会话复用 DSH 服务；未复制其源码 |
| [OkHttp](https://github.com/square/okhttp) / [Okio](https://github.com/square/okio) | Apache-2.0 | **直接借用二进制**：仅 Android 原生原型（`Android/libs/`）的 WebSocket jar，未修改 |
| [Flutter / Dart](https://github.com/flutter/flutter) · [ffi](https://github.com/dart-lang/native/tree/main/pkgs/ffi) | BSD-3-Clause | **框架依赖**：跨平台客户端的 UI 框架与 FFI 辅助库，本机安装/pub 拉取，不随仓库分发 |
| [VPet-Simulator](https://github.com/LorisYounger/VPet) | Apache-2.0 | **仅思路参考**：「状态机 + 数值 + 互动」桌宠三层架构、低状态求关注的情感化反馈；未使用任何代码/素材 |
| [Shijima / libshijima](https://github.com/pixelomer/Shijima-Qt) | GPL-3.0 | **仅思路参考**：Shimeji 行为状态划分；因 iOS 沙箱限制改为全屏 App 内场景；未使用任何代码/素材 |
| [N.E.K.O](https://github.com/Project-N-E-K-O/N.E.K.O) | Apache-2.0 | **仅思路参考**：主动搭话的陪伴感设计；本项目台词为本地静态语料，无 LLM/Live2D 依赖 |
| [Pillow](https://github.com/python-pillow/Pillow) | MIT-CMU | 开发期工具：素材导入/生成脚本用的 Python 图像库，不随 App 分发 |

全部 Swift / Dart / Java / 插件 JS 代码、背景/特效素材为本仓库原创（MIT）。
逐文件映射与许可全文见 **[docs/THIRD-PARTY-NOTICES.md](docs/THIRD-PARTY-NOTICES.md)** 与
**[docs/ACKNOWLEDGEMENTS.md](docs/ACKNOWLEDGEMENTS.md)**。

## 已知限制

- 语音只在 App 前台工作（iOS 不允许后台常驻麦克风）；后台时任务仍在服务器继续，回来可看会话；
- 语音识别是**整段非流式**（SenseVoice 限制），按句切分后整句送识别；
- VAD 是轻量能量检测（无原生依赖），安静室内够用，嘈杂环境可调 `vadFloorDbfs` / `vadMarginDb`；
- 8787 是明文 HTTP + Bearer，仅用于内网/ZeroTier，**不要暴露公网**；
- macOS 客户端 v1 只支持文字对话（本地唤醒/识别未接），令牌暂为 0600 明文，未做公证。

## 版本历史

| 版本 | 内容 |
|---|---|
| v1.3.2 | 一句话带命令、音频中断与恢复、Windows 托盘/自启、macOS 本地语音与真 KWS；重出 Android 0.3.2 安装包；详见 [docs/releases/v1.3.2.md](docs/releases/v1.3.2.md) |
| v1.3.1 | 三端编译产物入库（Android APK / Windows 便携包 / macOS 桌宠包 + SHA256）；修复 device_kind 跟随平台、Windows 便携包附带 VC 运行库；详见 [docs/releases/v1.3.1.md](docs/releases/v1.3.1.md) |
| v1.3.0 | 跨平台版：Flutter 三端客户端（Android 全屏 / Windows SAPI 离线语音桌宠 / macOS 文字版桌宠）合入主线，插件 0.4.x 新增 `/api/agent` 文本通道 |
| v1.3.0-android.1 | 新增 Android 版（`Android/`）：SurfaceView + Canvas 渲染、AudioRecord 16k 采集、系统 TTS、OkHttp WebSocket，行为/数值/台词/协议与 iPad 版一致 |
| v1.2.6 | 前台任务提醒全部改为语音播报（开始/需要授权/断线恢复/失败；完成由回答本身播报） |
| v1.2.5 | 重连放弃阈值（连续 10 次≈3 分钟后转错误态，点麦克风可重试） |
| v1.2.4 | 断线期间完成的任务在重连后补播；新增 `task interrupted` 态 |
| v1.2.3 | 断线自动重连（1/2/4/8/16/30s 退避，401 不重试）；重连时补启采集 |
| v1.2.2 | 任务开始/完成/需要授权提醒；`task` 事件 |
| v1.2.1 | 修复 `VoiceController.start()` 重复建连（双 WebSocket / 双音频引擎） |
| v1.2.0 | 语音唤醒 + 接入 DSH（当时用独立 Python 桥接 `Server/`） |
| v1.1.0 | 改用开源成品立绘 |
| v1.0.0 | 首个可运行版本 |

> 早期 Python 桥接（`Server/`，自带 faster-whisper + 独立 DSH runtime）已在 v2 重构中移除，
> 需要时可在 git 历史里找回：`git show v1.2.0:Server/README.md`、`git checkout v1.2.0 -- Server`。