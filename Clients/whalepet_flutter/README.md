# WhalePet Flutter 客户端（Windows / macOS 桌宠）

跨平台客户端工程。**Windows（阶段 E）第一版已完成**：透明桌宠 + 本地离线语音闭环 + 文本 Agent 通道；
**macOS（阶段 D）v1 已完成**：透明桌宠 + 文本 Agent 通道 + 系统 TTS（本地唤醒词暂未接）。

| 部分 | 状态 | 说明 |
|---|---|---|
| `lib/core/`（宠物状态/数值/行为/存档/协议/语音状态机） | ✅ | 纯 Dart，`dart test` 直接可跑，不依赖 Flutter |
| `lib/platform/` Win32 窗口、SAPI 播报、离线 KWS/ASR | ✅ Windows | `dart:ffi` + 系统 API，零第三方插件 |
| `lib/platform/` AppKit 窗口、AVSpeechSynthesizer | ✅ macOS | MethodChannel + 原生 Swift（`macos/Runner`） |
| `lib/ui/desktop_pet/`（透明桌宠界面） | ✅ 双端 | 气泡、立绘、聊天/设置面板、右键菜单 |
| 本地语音（KWS → VAD → ASR → 文本 → TTS） | ✅ Windows / ⏳ macOS | macOS v1 只有系统 TTS，唤醒/识别待接 |
| 一句话带命令（§7.7）、AEC/barge-in、Android | ⏳ | 后续增强 |

设计依据：[`docs/CROSS_PLATFORM.md`](../../../docs/CROSS_PLATFORM.md) §6（宠物核心）、§7（语音）、§8（`/api/agent`）、§10.2（macOS）、§10.3（Windows）、§11（存档与安全）、§12（测试）。

## 目录

```text
Clients/whalepet_flutter/
├── lib/
│   ├── main.dart                                   # 入口：按平台装配适配层 → runtime → runApp
│   ├── core/                                       # 纯 Dart，禁止 import Flutter
│   │   ├── pet/                                    # 状态、数值、行为调度、台词
│   │   ├── storage/                                # 存档 schema v1 + 原子写
│   │   ├── agent/                                  # /api/agent 协议与 WebSocket 网关
│   │   ├── config/                                 # 设置、路径、DPAPI 令牌存储
│   │   ├── platform/                               # 窗口接口 + 位置几何
│   │   └── voice/                                  # 引擎/播报接口、唤醒词剥离、状态机、播报队列
│   ├── platform/
│   │   ├── desktop_window/win32_window.dart        # Win32 FFI：透明/置顶/穿透/拖拽/DPI/工作区
│   │   ├── desktop_window/macos_window.dart        # MethodChannel + CoreGraphics 光标（左上原点坐标）
│   │   ├── speech_output/powershell_speech.dart    # 常驻子进程 + System.Speech 合成
│   │   ├── speech_output/macos_speech.dart         # AVSpeechSynthesizer 通道
│   │   └── voice/sapi_voice_engine.dart            # 常驻子进程 + 离线桌面识别（KWS/听写，仅 Windows）
│   └── ui/desktop_pet/                             # runtime、宠物、气泡、聊天/设置面板、菜单
├── assets/pet/                                     # 立绘（与 iOS 工程同一套素材）
├── windows/                                        # Flutter Windows runner（桌宠窗口）
├── macos/                                          # Flutter macOS runner（透明 NSPanel 式窗口 + 菜单栏状态项）
├── test/core/                                      # 纯 Dart 测试
└── tool/                                           # 开发/打包脚本
```

依赖规则（§5）：`UI → core 接口 → platform 实现`；`core` 不 import Flutter，`platform` 不改 widget。

## 构建 / 运行

### macOS（阶段 D）

前置：Xcode（验证版本 26.3）+ Flutter SDK（验证版本 3.50.0，Intel Mac 可用但官方已提示后续弃用）。

```bash
cd Clients/whalepet_flutter
flutter pub get
flutter run -d macos                     # 调试
flutter build macos --release            # 产物：build/macos/Build/Products/Release/
python3 tool/package_release_macos.py    # 打包成 dist/whalepet-macos-<ver>.zip
```

工程默认关闭 Swift Package Manager（零插件用不上，开着会让 `xcodebuild` 卡在依赖解析）。
若要用 SPM：`flutter config --enable-swift-package-manager` 后重建 `macos/`。

### Windows（阶段 E）

前置：Visual Studio 2022 生成工具的 **C++ 桌面开发**组件
（MSVC + CMake + Windows SDK，`flutter doctor -v` 的 Visual Studio 项必须是 ✓）。

```bash
cd Clients/whalepet_flutter
flutter pub get
flutter run -d windows          # 调试
flutter build windows           # 产物：build/windows/x64/runner/Release/
python tool/package_release.py  # 打包成 dist/whalepet-windows-x64-<ver>.zip
```

纯核心逻辑（不需要 Flutter、不需要图形环境）：

```bash
dart test
dart analyze
```

## 使用

启动后是一个 **380×560 的透明置顶窗口**，里面只有宠物和气泡：

| 操作 | 效果 |
|---|---|
| 单击宠物 | 摸头（心情 +10） |
| 双击宠物 | 打开聊天面板（文本指令，Enter 发送） |
| 右键宠物 | 摸头 / 投喂 / 玩 / **开启或关闭语音唤醒** / **点击说话** / 说点什么 / 设置 / 睡觉 / 退出 |
| 按住拖动 | 系统级拖拽整窗移动，松手自动夹回当前显示器工作区 |
| 鼠标移到透明区域 | 窗口变 `WS_EX_TRANSPARENT`，不挡后面软件 |

第一次用先右键 →「设置」：

- 服务器地址：`http://<运行 DSH 的机器 IP>:8787`
- 访问令牌：`~/.dsh/whalepet/ipad-token` 的内容
- 语音：勾「开启唤醒词常驻侦听」，可改唤醒词、别名（逗号分隔）、唤醒应答（Windows 专用，macOS v1 无本地识别）

## macOS 平台差异

窗口同样是 **380×560 透明置顶小窗**，但能力落在原生 AppKit（`macos/Runner/AppDelegate.swift`）：

| 项 | Windows | macOS |
|---|---|---|
| 窗口能力 | `dart:ffi` 直调 user32 | MethodChannel `whalepet/window` → 原生 AppKit |
| 透明/无边框 | `WS_EX_LAYERED` + `SetLayeredWindowAttributes` | `isOpaque=false` + 背景 clear + 去掉 `.titled` |
| 置顶 | `HWND_TOPMOST` | `window.level = .floating`（+ 常驻所有空间） |
| 不进任务栏/Dock | `WS_EX_TOOLWINDOW` | `LSUIElement` + `setActivationPolicy(.accessory)` |
| 托盘/菜单栏 | 右键菜单（无托盘图标） | 菜单栏 🐳 状态项：显示 / 退出 |
| 鼠标穿透 | `WS_EX_TRANSPARENT` | `window.ignoresMouseEvents` |
| 原生拖拽 | `WM_NCLBUTTONDOWN` + `HTCAPTION` | `performDrag(with:)` |
| 工作区 | `MonitorFromWindow` + `SPI_GETWORKAREA` | `screen.visibleFrame`（自动避开刘海/菜单栏/Dock） |
| 全局光标 | `GetCursorPos` | CoreGraphics `CGEventCreate` + `CGEventGetLocation`（FFI，同步） |
| 系统 TTS | SAPI5（`System.Speech`） | `AVSpeechSynthesizer`（zh-CN） |
| 令牌存储 | DPAPI 密文 | `~/.whalepet/token.bin` 明文 + 0600（待换 Keychain） |
| 本地唤醒/识别 | SAPI5 离线识别器 | ⏳ 未接（v1 只支持文字对话） |

**为什么令牌先明文**：同机 `~/.dsh/whalepet/ipad-token` 本来就是 0600 明文，威胁模型一致；
后续换 Keychain（`SecItemAdd`）后再打开 App Sandbox。

**一个 macOS 独有的坑**：`FlutterAppDelegate` 的 `applicationDidFinishLaunching`
只在协议里声明，Swift 重写**不会**挂到 `applicationDidFinishLaunching:` 这个 ObjC 入口上
（实测：通知照发、方法不被调用，`MissingPluginException` 由此而来）。
初始化必须放在 `applicationWillFinishLaunching`，此时 nib 已加载完、窗口与引擎都已就绪。

## 本地语音链路

```text
麦克风 → SAPI5 离线桌面识别器（zh-CN）
   ├─ 待机：只启用「唤醒词小语法」，低功耗
   └─ 唤醒：切成听写语法，partial/final 文本
→ WakeMatcher 剥掉句首唤醒词
→ VoiceSessionCoordinator（会话 generation 守卫、10s 聆听超时、迟到回调丢弃）
→ /api/agent 只发文本
→ 回答上屏 + SpeechQueue 去重/优先级
→ System.Speech 播报（期间闭麦）
→ 延迟 250ms → 回待唤醒
```

为什么第一版用 SAPI5 而不是 sherpa-onnx：本机自带 `MS-2052-80-DESK / zh-CN` 离线识别器和
`Microsoft Huihui Desktop / zh-CN` 音色，零模型下载即可跑通全链路。代码全部收在
`VoiceEngineAdapter` 后面，将来换 sherpa-onnx 只需替换 `sapi_voice_engine.dart`。

**已知精度限制**：SAPI 中文听写准确率一般（实测「帮我查一下明天的安排」→「当我查一下明天的安排」），
适合短指令，长句/口音/噪声场景应切 sherpa-onnx。播报中打断（barge-in）暂不支持。

### 没有麦克风也能验证

`SapiVoiceEngine(audioFile: ...)` 会用 `SetInputToWaveFile` 代替麦克风。正式入口读环境变量
`WHALEPET_VOICE_WAV`，两个开发脚本可直接跑：

```bash
dart run tool/verify_voice.dart wake   <wav>   # 验证唤醒语法
dart run tool/verify_voice.dart listen <wav>   # 验证听写 + 最终文本
dart run tool/verify_tts.dart                  # 验证连续两条播报
```

设置 `WHALEPET_VOICE_DEBUG=1` 会打印引擎的原始 stdout 与发送的命令。

## 数据落在哪

```text
%APPDATA%\WhalePet\            # Windows
~/.whalepet/                   # macOS
├── settings.json      # 服务地址、语音配置、开关、窗口位置（明文）
├── token.bin          # Bearer 令牌（Windows: DPAPI 密文；macOS: 明文 0600）
├── client_id.txt      # 本机客户端 id（Windows: windows-xxx，macOS: macos-xxx）
└── save/pet_save.json # 数值存档（schema v1，原子写，坏档先备份再回落默认值）
```

## 开发自检钩子（无需点界面）

```bash
# Windows
WHALEPET_VOICE_WAV=<wav>  ./build/.../whalepet_flutter.exe   # 用 WAV 代替麦克风跑语音闭环

# macOS
WHALEPET_SPEAK_TEST=1     ./build/macos/Build/Products/Release/whalepet_flutter.app/Contents/MacOS/whalepet_flutter
WHALEPET_CHAT_TEST="帮我看看今天的安排"  ...同上...   # 启动 3 秒后自动发一条文本命令

# 后端联调用一个最小 mock（protocol v2）：health + hello→ready + command→task/response
node tool/mock_agent_server.js   # 需要 npm i ws；端口 8799，令牌 mock-token
```

## 与架构文档的对应

| 文档要求 | 落地 |
|---|---|
| §6.3 桌宠 = 移动窗口 | `Win32DesktopWindow` / `MacOSDesktopWindow` 的 `setPosition` + 30fps 帧循环 |
| §6.3 位置限制在工作区 | `clampToWorkArea`（有单测） |
| §10.2 macOS 原生窗口适配 | `macos/Runner`：透明无边框置顶、全空间、菜单栏状态项、`visibleFrame` 工作区 |
| §7.2 语音状态机与 generation | `VoiceSessionCoordinator`：8 态、generation 守卫、resumeAfterSpeech、10s 聆听超时 |
| §7.4 PCM 不穿过 Dart | 采集/KWS/ASR 全在常驻子进程（Windows）；macOS v1 不采集音频 |
| §7.6 待机只跑 KWS | 两套语法按模式互斥启用，待机仅唤醒词小语法（Windows） |
| §7.8 闭麦与播报队列 | 播报前 `stopListening`，`SpeechQueue` 去重/优先级/「回答后不念做完了」 |
| §8 全部协议字段 | `core/agent/`，含 `event_id` 去重、补发、退避、401/403 不重试 |
| §11.2 令牌安全存储 | Windows DPAPI（`CryptProtectData` + 应用附加熵）；macOS 明文 0600（待 Keychain） |
| §11.3 voice_config 版本 | revision 变化在「等待唤醒」安全点重建 KWS 语法 |

## 与文档原设计的偏差

| 原设计 | 实际做法 | 原因 |
|---|---|---|
| §5 允许用 `window_manager` 等插件 | Windows 全部 `dart:ffi` 直连 Win32；macOS 走 MethodChannel + 原生 AppKit | 前者零依赖可控，后者是官方推荐路径（窗口层级/全空间/Dock 策略都在 AppKit 侧） |
| §10.3 托盘图标 | Windows 用右键菜单；macOS 用菜单栏状态项 | Windows 自绘托盘要额外消息窗口，收益低；macOS 没有状态项就没法退出（不在 Dock） |
| §10.3 sherpa-onnx 原生库 | Windows 用 SAPI5 离线识别作为第一 Provider；macOS v1 不接本地语音 | 前者系统自带中文识别器；后者先做文字闭环，语音下一阶段 |
| §7.5 系统 TTS | Windows SAPI5（`System.Speech`）；macOS AVSpeechSynthesizer | 均为系统自带，无额外依赖 |
| 窗口随面板缩放 | 固定 380×560 + 透明区域自动穿透 | 尺寸稳定、命中测试简单 |
| §11.2 令牌必须安全存储 | Windows DPAPI；macOS 暂为明文 0600 | macOS 同机 `~/.dsh/whalepet/ipad-token` 本就是 0600 明文，威胁模型一致；换 Keychain 后再开沙箱 |

## Windows 子进程通信的一个坑

实测：在 Windows 上向常驻 PowerShell 子进程的 **stdin 写第二行及以后，`[Console]::In.ReadLine()` 永远读不到**
（最小复现见提交记录）。所以播报与语音引擎都不用 stdin 控制，改为**编号命令文件队列**：
Dart 写 `cmd-000001.json.tmp` → 原子 rename → 脚本每 100ms 按序号取走执行。中文一律走 UTF-8 文件，
脚本 stdout 设 UTF-8；`.ps1` 写 CRLF（PowerShell 5.1 对纯 LF 的事件 Action 块解析有坑）。

## 语音闭环真机踩过的三个坑（已修）

跑通「唤醒 → 应答 → 聆听 → 指令 → 回答 → 播报 → 回待唤醒」之后，这三处都留了回归用例：

1. **引擎编号 ≠ 会话 generation。** 引擎事件的 `generation` 是「第几条控制命令」（唤醒 1、闭麦 2、聆听 3…），
   协调器的是「本次会话第几代」（enable 才 +1）。早期代码拿两者互相比较，唤醒后的 FINAL 全被当迟到事件丢掉，
   现象是「能唤醒、能看到识别文本，但指令永远发不出去」。现在引擎自己按 mode/gen 过滤过期事件，协调器只按状态兜底。
2. **唤醒应答的播报 id 不能只按 generation 拼。** 同一轮会话里 generation 不变，`ack-<gen>` 第二轮就被播报队列
   当重复项吞掉，现象是「第一次唤醒有『我在』，之后每次唤醒都静默地直接进聆听」。改成自增序号。
3. **一轮结束时重建 KWS 会把状态机卡死。** `_rebuildEngine` 原来只在 `waitingWake` 才干活，而收尾的 `_resumeWake`
   在播报态把重建甩给它，结果引擎没重建、状态也没回待唤醒，宠物永远停在「播报中」，之后再不响应唤醒。
   现在重建可以在任意状态调用（自己停识别、初始化、回待唤醒），并且「引擎建好」就清掉脏标记，避免启动时
   白重建一次。

另外：待唤醒阶段只开着唤醒小语法，说别的句子必然被 SAPI 拒识——这属于常态，不能当错误弹提示，
更不能拿它重启引擎（否则会自我循环重启）。

## 验证记录（本机 Windows 11，2026-11-15）

```text
dart test                      → 89 个测试全绿
dart analyze lib               → 无 error/warning；只剩 Flutter 3.50 对
                                 package:flutter/material.dart 的 info 级弃用提示
flutter build windows --debug  → 成功
flutter build windows --release→ 成功
python tool/package_release.py → dist/whalepet-windows-x64-0.2.0.zip（13.2 MiB）
tool/verify_voice.dart wake    → WAKE 1 0.988 小金小金（别名命中）
tool/verify_voice.dart listen  → PARTIAL×9 → FINAL 0.608「当我查一下明天的安排」
tool/verify_tts.dart           → 两条播报均 started/finished
```

### 应用内 WAV 全链路（不打字、不开麦）

mock `/api/agent` + `WHALEPET_VOICE_WAV=full.wav` 跑通，并连续跑到第 3 轮以上：

```text
WAKE 1 → stop 2（闭麦播「我在」）→ listen 3
FINAL 3 「孝敬孝敬帮我查一下明天的安排」→ stop 4 → 服务端 command
response → stop 5（闭麦播回答）→ wake 6 → WAKE 6 → stop 7 → listen 8 → …
```

服务端侧每次都能收到 `command`，气泡显示「收到啦，你说的…」，回答播完自动回待唤醒。
（WAV 模式每次切模式都会从头播放，所以会自己循环；真实麦克风不会。）

UI 真机确认：透明窗浮于壁纸（无黑框）、单击摸头、双击聊天、右键菜单、设置保存、
令牌 DPAPI 往返、模拟 `/api/agent` 跑通 `hello→ready→command→task→response→finished`。

开发环境注意：本机**没有默认录音设备**，所以麦克风实时链路用 WAV 输入验证；接上麦克风后
在设置里打开唤醒即可用。引擎实例退出时会注销事件订阅，避免遗留宿主进程。

## 验证记录（macOS 15.8.3 / Intel，2026-11-16）

```text
dart test                         → 89 个测试全绿
flutter analyze                   → 0 error / 0 warning（仅 tool/ 脚本的 info 级提示）
flutter build macos --debug       → 成功
flutter build macos --release     → 成功（45.3 MB .app）
python3 tool/package_release_macos.py → dist/whalepet-macos-0.2.0.zip（18.8 MiB）
```

真机确认（逐项截图核对）：

| 项 | 结果 |
|---|---|
| 透明悬浮 | 立绘浮在桌面上，周围像素完全透明，无黑底、无边框、无阴影 |
| 不进 Dock / 不抢菜单栏 | 菜单栏归前台应用所有；`LSUIElement` + `.accessory` 生效 |
| 菜单栏状态项 | 🐳 出现，菜单含「显示鲸鱼娘 / 退出鲸鱼娘…」 |
| 桌宠移动 | 自主行为触发后窗口跟着走：`window_x` 530 → 1060、`window_y` 261 → 207（走 + 游） |
| 握手 | mock 侧收到 `hello macos-mltidp`（客户端 id 前缀随平台为 `macos-`） |
| 文本对话 | `command 帮我看看今天的安排` → `response` → 气泡「收到你的话：帮我看看今天的安排」 |
| TTS | `WHALEPET_SPEAK_TEST=1`：`started` → `finished`（AVSpeechSynthesizer zh-CN） |
| 存档 | `~/.whalepet/{settings.json,save/pet_save.json,client_id.txt}` 正常读写；退出前补写 |

待手动确认（同一通道，逻辑共用，未做点击自动化）：单击摸头、双击聊天面板、右键菜单、
按住拖拽、透明区域自动穿透。
