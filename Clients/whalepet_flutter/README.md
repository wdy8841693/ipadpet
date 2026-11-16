# WhalePet Flutter 客户端（Android 全屏 + Windows / macOS 桌宠）

跨平台客户端工程：**同一份 `lib/core/`**，两套场景控制器（§6.3）。

| 部分 | 状态 | 说明 |
|---|---|---|
| `lib/core/`（宠物状态/数值/行为/存档/协议/语音状态机） | ✅ 双端共用 | 纯 Dart，`dart test` 直接可跑，不依赖 Flutter |
| `lib/ui/mobile_scene/`（Android 全屏场景） | ✅ 阶段 C 1~4 步 | 海底场景、立绘位移/拖拽/点击、状态条、操作栏、聊天/设置浮层 |
| `lib/platform/android/`、`speech_output/android_*`、`secure_storage/` | ✅ Android | MethodChannel + 系统 SpeechRecognizer / TextToSpeech / Keystore |
| 一句话带命令（§7.7，整段 ASR 路线） | ✅ 三端共用 | `core/voice/wake_matcher.dart`、`core/voice/spoken_command.dart` |
| 音频焦点 / 来电 / 前后台恢复（§10.1） | ✅ Android | `WhalePetBridge.kt` + `core/voice/voice_session_coordinator.dart` |
| `lib/platform/`（Win32 窗口、SAPI 离线 KWS/ASR、TTS） | ✅ Windows | `dart:ffi` + 系统 API，零第三方插件 |
| `lib/platform/tray/`、`lib/platform/autostart/` | ✅ Windows | 托盘图标（runner `Shell_NotifyIcon`）+ 开机自启（注册表 Run 项） |
| `lib/ui/desktop_pet/`（透明桌宠界面） | ✅ Windows / macOS | 气泡、立绘、聊天/设置面板、右键菜单 |
| `lib/platform/desktop_window/macos_window.dart`、`speech_output/macos_speech.dart`、`voice/macos_voice_engine.dart` | ✅ macOS | MethodChannel `whalepet/window` → 原生 AppKit；`AVSpeechSynthesizer` 播报；`SFSpeechRecognizer` 本机识别 |
| 本地语音（唤醒 → 识别 → 文本 → TTS） | ✅ 三端 | Android 用系统识别服务；Windows 用 SAPI 离线识别；macOS 用系统本机识别 |
| 一句话带命令（真 KWS 路线）、sherpa-onnx 本地模型、AEC/barge-in | ⏳ | 后续增强（sherpa 依赖脚本 `tool/fetch_sherpa_onnx_windows.py` 已就位） |

设计依据：[`docs/CROSS_PLATFORM.md`](../../../docs/CROSS_PLATFORM.md) §6（宠物核心）、§7（语音）、§8（`/api/agent`）、§10.3（Windows）、§11（存档与安全）、§12（测试）。

## 目录

```text
Clients/whalepet_flutter/
├── lib/
│   ├── main.dart                                   # 入口：装配适配层 → runtime → runApp
│   ├── core/                                       # 纯 Dart，禁止 import Flutter
│   │   ├── pet/                                    # 状态、数值、行为调度、台词
│   │   ├── storage/                                # 存档 schema v1 + 原子写
│   │   ├── agent/                                  # /api/agent 协议与 WebSocket 网关
│   │   ├── config/                                 # 设置、路径、DPAPI 令牌存储
│   │   ├── platform/                               # 窗口接口 + 位置几何
│   │   └── voice/                                  # 引擎/播报接口、唤醒词剥离、状态机、播报队列
│   ├── platform/
│   │   ├── android/native_bridge.dart              # MethodChannel/EventChannel 封装
│   │   ├── voice/android_system_voice_engine.dart  # 系统 SpeechRecognizer + 唤醒词文本匹配
│   │   ├── speech_output/android_system_tts.dart   # 系统 TextToSpeech
│   │   ├── secure_storage/keystore_token_store.dart# Android Keystore 加密令牌
│   │   ├── desktop_window/win32_window.dart        # Win32 FFI：透明/置顶/穿透/拖拽/DPI/工作区
│   │   ├── desktop_window/macos_window.dart        # macOS：MethodChannel → AppKit 窗口/穿透/拖拽
│   │   ├── speech_output/powershell_speech.dart    # 常驻子进程 + System.Speech 合成
│   │   ├── speech_output/macos_speech.dart         # AVSpeechSynthesizer（zh-CN）
│   │   └── voice/sapi_voice_engine.dart            # 常驻子进程 + 离线桌面识别（KWS/听写）
│   ├── ui/mobile_scene/                            # Android 全屏场景：runtime + shell
│   └── ui/desktop_pet/                             # runtime、宠物、气泡、聊天/设置面板、菜单
├── android/                                        # Flutter Android runner + 原生能力桥（Kotlin）
├── assets/pet/                                     # 立绘（与 iOS 工程同一套素材）
├── windows/                                        # Flutter Windows runner（桌宠窗口）
├── macos/                                          # Flutter macOS runner（AppKit 透明窗口 + 菜单栏项）
├── test/core/                                      # 纯 Dart 测试
└── tool/                                           # 开发/打包脚本
```

依赖规则（§5）：`UI → core 接口 → platform 实现`；`core` 不 import Flutter，`platform` 不改 widget。

## 构建 / 运行（Android）

前置：Flutter SDK 3.50.0 + Android SDK（platform 36 / build-tools 36 / platform-tools）+ JDK 17。

```bash
cd Clients/whalepet_flutter
export ANDROID_HOME=<Android SDK 路径>
bash tool/build_android.sh      # 拷到本地目录构建，产物复制回 dist/
# 或直接：flutter build apk --release
adb install -r dist/whalepet-android-<ver>.apk
```

> 工程放在网络盘（UNC）时必须在本地目录构建：`cmd.exe` 不能以 UNC 路径为工作目录，
> `flutter`/`gradle` 的 `.bat` 会直接失败。`tool/build_android.sh` 已经处理了这件事。

首次启动：允许麦克风 → 点底部「设置」填服务器地址与令牌 → 「说话」按钮开始一轮聆听；
想要「小鲸小鲸」常驻唤醒，在设置里打开「语音唤醒常驻侦听」（走系统识别，比较耗电）。

Windows 上还可以额外打开**一句话带命令**：「小鲸小鲸，帮我查一下明天的安排」会被当成
一条指令直接执行，不先播「我在」。这个开关**默认关闭**——SAPI 通用听写经常把自定义
唤醒词听成别的词（实测「小鲸小鲸」→「孝敬孝敬」，置信度 0.22），默认开启反而连基本
唤醒都会失效（见下面「Windows 平台能力」）。

## 构建 / 运行（Windows）

前置：Flutter SDK（验证版本 3.50.0）+ Visual Studio 2022 生成工具的 **C++ 桌面开发**组件
（MSVC + CMake + Windows SDK，`flutter doctor -v` 的 Visual Studio 项必须是 ✓）。

```bash
cd Clients/whalepet_flutter
flutter pub get
flutter run -d windows          # 调试
flutter build windows           # 产物：build/windows/x64/runner/Release/
python tool/package_release.py  # 打包成 dist/whalepet-windows-x64-<ver>.zip
```

> **便携包必须自带 VC 运行库。** `flutter build` 的 Release 目录里只有
> `whalepet_flutter.exe`、`flutter_windows.dll`、`data/`，而主程序是动态链接 MSVC
> 运行库的（导入表点名 `VCRUNTIME140.dll`、`MSVCP140.dll`），干净的 Windows 上双击会报
> 「找不到 VCRUNTIME140.dll」。`tool/package_release.py` 因此会把本机的
> `vcruntime140*.dll` / `msvcp140.dll`（外加 `d3dcompiler_47.dll`）以微软支持的
> app-local 方式一起打进包；找不到就地报错，不会产出残包（可用 `WHALEPET_DLL_DIR`
> 指向含这些 DLL 的目录）。

> **网络盘上多人并行构建会互相踩。** `flutter build` 要解析
> `.dart_tool/package_graph.json`，别的会话正在 `pub get` 时它会被写成半截，
> 报 `FormatException: Unexpected end of input`；`build/` 目录也会互相覆盖
> （debug 产物会混进 Release 目录）。并行时建议错开构建，打包脚本现在会剔除
> 调试残留并校验 AOT 快照。

纯核心逻辑（不需要 Flutter、不需要图形环境）：

```bash
dart test
dart analyze
```

## 构建 / 运行（macOS）

前置：Xcode（验证版本 26.3）+ Flutter SDK（验证版本 3.50.0；Intel Mac 可用，但官方已提示后续弃用）。

```bash
cd Clients/whalepet_flutter
flutter pub get
flutter run -d macos                     # 调试
flutter build macos --release            # 产物：build/macos/Build/Products/Release/
python3 tool/package_release_macos.py    # 打包成 dist/whalepet-macos-<ver>.zip
```

工程默认关闭 Swift Package Manager（零插件用不上，开着会让 `xcodebuild` 卡在依赖解析）；
需要时 `flutter config --enable-swift-package-manager` 后重建 `macos/`。

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
- 语音：勾「开启唤醒词常驻侦听」，可改唤醒词、别名（逗号分隔）、唤醒应答（Windows / macOS 都支持唤醒与听写；Android 是系统识别服务）

## Windows 平台能力（阶段 E 收尾）

架构文档 §10.3 里 Windows 原本缺的三块，这轮补齐了。

### 托盘图标

桌宠窗口是 `WS_EX_TOOLWINDOW`（不在任务栏、不进 Alt+Tab），一旦隐藏就没法找回来，
所以托盘是唯一的「找回入口」：

- 图标本体在 runner（`windows/runner/tray_icon.cpp`，`Shell_NotifyIcon`），
  右键弹菜单、左键双击切换显示/隐藏；
- 菜单项：显示/隐藏宠物、语音唤醒（带勾选）、设置…、退出；
- Explorer 重启会掉图标，runner 监听 `WM_TASKBARCREATED` 自动补回；
- 菜单动作通过 `whalepet/desktop` MethodChannel 交给 Dart，
  与右键菜单共用同一套行为（`PetRuntime._onTrayAction`）。

### 开机自启

设置面板里勾「开机自动启动」，写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
（不需要管理员权限）。实现走 `dart:ffi` 直连 advapi32（`lib/platform/autostart/win32_autostart.dart`），
不起 `reg.exe` 子进程，路径带引号，兼容带空格的目录。

便携包换目录后，下次启动会自动把启动项里的旧路径刷新成新路径。

### 多显示器与 DPI

- runner 监听 `WM_DISPLAYCHANGE` / `WM_SETTINGCHANGE` / `WM_DPICHANGED`，
  通过 `whalepet/desktop` 通道通知 Dart；
- `Win32DesktopWindow` 收到通知后**先刷新缓存的 DPI 比例**
  （窗口被拖到不同缩放的显示器上时，旧比例会让逻辑像素↔物理像素整体偏移），
  再抛 `displayChanges`，由 `PetRuntime._refreshWorkArea()` 把窗口夹回可见范围。

### 一句话带命令（§7.7）

Windows 侧之前只有「唤醒 → 我在 → 说指令」两段式。这轮让 SAPI 引擎支持**整段听写**待机策略：

| 待机策略 | 引擎行为 | 代价 |
|---|---|---|
| 一句话带命令（默认关，需手动开） | 待机跑整段听写语法，Dart 侧用 `WakeMatcher.matchWithRest` 匹配句首唤醒词并取出后面那一截 | 待机期一直跑整段 ASR，CPU 比纯关键词语法高；自定义唤醒词可能被听成别的词 |
| 低功耗唤醒（默认） | 待机只跑「唤醒词小语法」，命中即唤醒 | 一句话带命令不支持 |

设置面板里可以切换（改了会重建引擎）。两条路都用同一套 core 语义
（`WakeMatcher` + 协调器），与 Android/macOS 对齐。

## sherpa-onnx 本地模型（§7.9）：依赖已备好，Provider 待接

```bash
python tool/fetch_sherpa_onnx_windows.py            # 运行时 + ASR 模型
python tool/fetch_sherpa_onnx_windows.py --with-kws # 额外拉 KWS 模型（GitHub 源，国内常被挡）
```

产物落在 `windows/.sherpa/`（gitignore）：`lib/` 里是 `sherpa-onnx-c-api.dll`、
`onnxruntime.dll` 等运行时，`model/` 里是模型。

运行时走 npm 官方包 `sherpa-onnx-win-x64`（与 GitHub Releases 同源产物，
但 npm registry 在国内可达）；模型走 HuggingFace 镜像 `hf-mirror.com`。

> **还差什么**：官方 `c-api.h` 头文件只在 GitHub Releases 里（jsDelivr / 各镜像站
> 在当前网络下均不可达），没有它就没法编译原生 Provider 或写 FFI 绑定。
> 拿到头文件后，按 `lib/core/voice/voice_engine.dart` 的 `VoiceEngineAdapter`
> 接口新增一个 `SherpaVoiceEngine` 即可，core 与 UI 不用动。

## macOS 平台差异

窗口同样是 **380×560 透明置顶小窗**，但能力落在原生 AppKit（`macos/Runner/AppDelegate.swift`）：

| 项 | Windows | macOS |
|---|---|---|
| 窗口能力 | `dart:ffi` 直调 user32 | MethodChannel `whalepet/window` → 原生 AppKit |
| 透明/无边框 | `WS_EX_LAYERED` + `SetLayeredWindowAttributes` | `isOpaque=false` + 背景 clear + 去掉 `.titled` |
| 置顶 | `HWND_TOPMOST` | `window.level = .floating`（+ 常驻所有空间） |
| 不进任务栏/Dock | `WS_EX_TOOLWINDOW` | `LSUIElement` + `setActivationPolicy(.accessory)` |
| 托盘/菜单栏 | 托盘图标（显示/隐藏、语音开关、设置、退出） | 菜单栏 🐳 状态项：显示 / 退出 |
| 鼠标穿透 | `WS_EX_TRANSPARENT` | `window.ignoresMouseEvents` |
| 原生拖拽 | `WM_NCLBUTTONDOWN` + `HTCAPTION` | `performDrag(with:)` |
| 工作区 | `MonitorFromWindow` + `SPI_GETWORKAREA` | `screen.visibleFrame`（自动避开刘海/菜单栏/Dock） |
| 显示器变化 | 启动时约束一次 | `NSApplication.didChangeScreenParameters` → 原生回调 `screensChanged` → Dart 重读工作区并把窗口夹回可见范围（§10.2） |
| 全局光标 | `GetCursorPos` | CoreGraphics `CGEventCreate` + `CGEventGetLocation`（FFI，同步） |
| 系统 TTS | SAPI5（`System.Speech`） | `AVSpeechSynthesizer`（zh-CN） |
| 令牌存储 | DPAPI 密文 | `~/.whalepet/token.bin` 明文 + 0600（待换 Keychain） |
| 本地唤醒/识别 | SAPI5 离线识别器（唤醒词小语法 + 听写语法） | **唤醒**：sherpa-onnx 本地 KWS（离线模型）<br>**识别**：系统 `SFSpeechRecognizer` 本机识别（on-device） |

**macOS 本地语音（阶段 D 文字版 → 阶段 E 语音版 → 真 KWS）**

macOS 端现在也有完整的「唤醒 → 识别 → 文本 → DSH → 播报」闭环，
其中**唤醒用本地关键词模型（真 KWS）**，指令识别用系统本机识别：

```text
[待机] 麦克风 → AVAudioEngine → 重采样 16kHz 单声道
        → 常驻子进程 whalepet-kws（sherpa-onnx KWS，拼音建模）
        → 命中唤醒词 → {"type":"wake"} → MethodChannel whalepet/voice
        → VoiceEventRouter（core，纯 Dart）复核唤醒词
[聆听] 麦克风 → AVAudioEngine → SFSpeechAudioBufferRecognitionRequest
        → SFSpeechRecognizer（requiresOnDeviceRecognition = true）
        → 事件（partial/final/error）→ MethodChannel whalepet/voice
        → /api/agent 只发文本
        → 回答上屏 + SpeechQueue 去重/优先级
        → AVSpeechSynthesizer 播报（期间闭麦）
```

| 项 | 说明 |
|---|---|
| 唤醒（真 KWS） | 常驻子进程 `tool/whalepet_kws.cpp`（sherpa-onnx，中文拼音建模）；采集与重采样在 `macos/Runner/VoiceEngine.swift`，PCM 不进 Dart（§7.4） |
| 唤醒词表 | 模型只认拼音 token，映射表在 `macos/Runner/WhalePetWakeKeywords.swift`；表里没有的词自动退回文本匹配 |
| 识别 | 指令识别用系统 `SFSpeechRecognizer`；`supportsOnDeviceRecognition` 为真时强制 `requiresOnDeviceRecognition = true`，为假时仍可用，但会在引擎信息里标明「可能走 Apple 服务器」 |
| 载荷 | 运行时动态库 + KWS 模型约 40MB，**不入库**；`tool/fetch_sherpa_onnx.sh` 拉取，Xcode「Copy KWS Payload」阶段拷进 App 包 `Resources/kws/`，出包时随包内置（离线可用） |
| 降级 | 没有载荷 / 唤醒词不在拼音表 / 子进程起不来 → 自动退回「系统识别 + 唤醒词文本匹配」，功能不丢，只是待机期更费电 |
| 触发阈值 | 默认 0.08（按 TTS 合成音频标定的初值），真机复验时按实际误触发率再调 |
| 权限 | 首次开启语音时申请「麦克风」+「语音识别」；`Info.plist` 已写用途说明 |
| 模式守卫 | 原生事件带 `mode`（wake/listen），切模式前迟到的旧事件直接丢弃（对应 §7.2 的 generation 守卫） |
| 待机续接 | 识别任务被系统结束（静音/时限）时自动续上；连续快速重启超过 3 次判定引擎卡死并报错 |
| 已知限制 | 一句话带命令（§7.7）与播报中打断（barge-in）仍待做 |

```bash
# 第一次构建前拉一次本地唤醒词载荷（约 40MB，不入库）
tool/fetch_sherpa_onnx.sh

# 排障：打印原生引擎的初始化与事件
WHALEPET_VOICE_DEBUG=1 ./build/macos/Build/Products/Release/whalepet_flutter.app/Contents/MacOS/whalepet_flutter
```

**为什么令牌先明文**：同机 `~/.dsh/whalepet/ipad-token` 本来就是 0600 明文，威胁模型一致；
后续换 Keychain（`SecItemAdd`）后再打开 App Sandbox。

**一个 macOS 独有的坑**：`FlutterAppDelegate` 的 `applicationDidFinishLaunching`
只在协议里声明，Swift 重写**不会**挂到 `applicationDidFinishLaunching:` 这个 ObjC 入口上
（实测：通知照发、方法不被调用，`MissingPluginException` 由此而来）。
初始化必须放在 `applicationWillFinishLaunching`，此时 nib 已加载完、窗口与引擎都已就绪。

## 本地语音链路（Windows）

> macOS 端的链路见上面的「macOS 平台差异 → macOS 本地语音」；Android 端走系统
> `SpeechRecognizer`，三端共用同一套 `VoiceSessionCoordinator` 状态机。

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

## Android 本地语音与中断处理（阶段 C 第 3~4 步）

```text
麦克风 → 系统 SpeechRecognizer（整段识别，非流式）
   ├─ 待机：连续识别，命中唤醒词才算数
   └─ 聆听：听一条指令，partial/final 文本
→ WakeMatcher.matchWithRest()：唤醒词 + 后面那一截
→ hasEffectiveContent()：后面那截算不算有效指令
→ VoiceSessionCoordinator（generation 守卫、10s 聆听超时、迟到回调丢弃）
→ /api/agent 只发文本
→ 回答上屏 + SpeechQueue 去重/优先级
→ 系统 TTS 播报（期间闭麦）
→ 延迟 250ms → 回待唤醒
```

### 一句话带命令（§7.7）

系统识别是**整段**识别，「小鲸小鲸，帮我查一下明天的安排」会整句返回。Android 端现在会：

| 识别到的内容 | 行为 |
|---|---|
| 「小鲸小鲸帮我查天气」 | 直接把「帮我查天气」发给 DSH，**不播「我在」** |
| 「小鲸小鲸」 | 播「我在」→ 进入 10 秒聆听（第一阶段流程） |
| 「小鲸小鲸嗯」 | 后面只有语气词 → 当作没听到 → 播「我在」→ 聆听 |

判定逻辑放在纯 Dart 的 `core/voice/spoken_command.dart`：
「嗯 / 啊 / 请 / 帮我」这类语气词只用于**判定**（剥掉后还剩不剩实义字），
不会从发给 DSH 的命令里删掉——「帮我查一下明天的安排」原样发过去，语义更完整。

> 真 KWS 引擎（Windows SAPI 关键字语法）拿不到「后面那一截」，
> 仍然走「唤醒 → 应答 → 聆听」；sherpa-onnx 到位后，KWS 命中就把
> pre-roll 音频交给 ASR，那才是完整的 §7.7。

### 音频焦点 / 来电 / 前后台（§10.1）

| 场景 | 处理 |
|---|---|
| 主动聆听时 | 申请 `AUDIOFOCUS_GAIN_TRANSIENT`（用户在跟宠物说话，让别的应用暂时让路） |
| 待机唤醒时 | **不申请**焦点——低功耗守门器不该打断用户正在听的音乐；麦克风被占由识别器自己的 `ERROR_RECOGNIZER_BUSY` 兜底 |
| 别的应用抢走音频 | `AUDIOFOCUS_LOSS` → 引擎发 `VoiceInterruptionEvent` → 宠物提示「稍后会自动恢复，文字对话仍然可用」 |
| 来电 / 通话 | 轮询 `AudioManager.mode`（`in_call`/`ringtone`/`in_communication`），不用 `READ_PHONE_STATE` 权限 |
| 焦点回来 / 挂断 | 引擎发 `VoiceEngineRecoveredEvent` → 协调器重新初始化引擎 → 回待唤醒 |
| 退后台 | `coordinator.suspend()`：停采集、停播报，但**保留语音开关**；不再冒「语音关掉啦」 |
| 回前台 | `coordinator.resume()`：按退后台前的状态恢复 |

中断是**可恢复**的：出错时只把语音这一轮作废，文本对话照常可用。

## 开发自检钩子（无需点界面）

```bash
# Windows：用 WAV 代替麦克风跑完整语音闭环
WHALEPET_VOICE_WAV=<wav> WHALEPET_VOICE_DEBUG=1 ./build/windows/x64/runner/Release/whalepet_flutter.exe

# macOS：验证播报通道 / 自动发一条文本命令
WHALEPET_SPEAK_TEST=1 ./build/macos/Build/Products/Release/whalepet_flutter.app/Contents/MacOS/whalepet_flutter
WHALEPET_CHAT_TEST="帮我看看今天的安排"  # 同上，启动 3 秒后自动发一条文本命令

# 桌面端通用：启动 3 秒后自动发一条文本命令
WHALEPET_CHAT_TEST="查一下明天的安排" ./build/windows/x64/runner/Release/whalepet_flutter.exe

# 后端联调用最小 mock（protocol v2）：health + hello→ready + command→task/response
node tool/mock_agent_server.js   # 需要 npm i ws；端口 8799，令牌 mock-token
```

## 数据落在哪

```text
%APPDATA%\WhalePet\
├── settings.json      # 服务地址、语音配置、开关、窗口位置（明文）
├── token.bin          # Bearer 令牌（DPAPI 密文，换账号/换机解不开）
├── client_id.txt      # 本机客户端 id，服务端据此单播回答
└── save\pet_save.json # 数值存档（schema v1，原子写，坏档先备份再回落默认值）
```

macOS 同构，根目录是 `~/.whalepet/`；令牌先明文 0600（见上「macOS 平台差异」）。

## 与架构文档的对应

| 文档要求 | 落地 |
|---|---|
| §6.3 桌宠 = 移动窗口 | `Win32DesktopWindow.setPosition` + 30fps 帧循环 |
| §6.3 位置限制在工作区 | `clampToWorkArea`（有单测） |
| §7.2 语音状态机与 generation | `VoiceSessionCoordinator`：8 态、generation 守卫、resumeAfterSpeech、10s 聆听超时 |
| §7.4 PCM 不穿过 Dart | 采集/KWS/ASR 全在常驻子进程，Dart 只收事件 |
| §7.6 待机只跑 KWS | 两套语法按模式互斥启用，待机仅唤醒词小语法 |
| §7.8 闭麦与播报队列 | 播报前 `stopListening`，`SpeechQueue` 去重/优先级/「回答后不念做完了」 |
| §7.7 一句话带命令 | `WakeMatcher.matchWithRest()` 取唤醒词后面那一截 + `hasEffectiveContent()` 判定有效性；协调器有有效指令就跳过「我在」 |
| §10.1 Android 音频焦点 | `WhalePetBridge.kt`：只在主动聆听时申请 `GAIN_TRANSIENT`；焦点丢失 → `VoiceInterruptionEvent` |
| §10.1 Android 来电检测 | 轮询 `AudioManager.mode`，不用 `READ_PHONE_STATE` 权限 |
| §10.1 前后台 | `coordinator.suspend()` / `resume()`：退后台停采集但保留语音开关，回前台按设置恢复 |
| §8 全部协议字段 | `core/agent/`，含 `event_id` 去重、补发、退避、401/403 不重试 |
| §11.2 令牌安全存储 | DPAPI（`CryptProtectData` + 应用附加熵） |
| §11.3 voice_config 版本 | revision 变化在「等待唤醒」安全点重建 KWS 语法 |
| §6.3 macOS「窗口即宠物」 | `MacOSDesktopWindow` + `macos/Runner/AppDelegate.swift`（AppKit 透明置顶） |
| §10.3 macOS 系统 TTS | `MacOSSpeechOutput`（`AVSpeechSynthesizer`，zh-CN） |
| §7.4 macOS PCM 不穿过 Dart | `macos/Runner/VoiceEngine.swift`：采集 + 识别全在原生层，Dart 只收事件 |
| §7.5 macOS Provider | `MacOSVoiceEngine`（MethodChannel `whalepet/voice`）+ `VoiceEventRouter`（core，纯 Dart） |
| §10.2 macOS 本机识别 | `SFSpeechRecognizer` + `requiresOnDeviceRecognition`；不支持时在引擎信息里标明 |
| §11.3 唤醒词变更 | `VoiceEventRouter.setWakePhrases` 换词表；服务端 revision 变化走协调器重建引擎 |
| §10.2 macOS 多显示器变化后重新约束窗口 | 原生 `didChangeScreenParameters` → `screensChanged` → `PetRuntime._refreshWorkArea`（`clampToWorkArea`） |

## 与文档原设计的偏差

| 原设计 | 实际做法 | 原因 |
|---|---|---|
| §5 允许用 `window_manager` 等插件 | 全部 `dart:ffi` 直连 Win32 | 零第三方依赖、行为可控 |
| §10.3 托盘图标 | **已实现**：runner `Shell_NotifyIcon` + 右键菜单（显示/隐藏、语音开关、设置、退出） | 桌宠窗口不在任务栏，隐藏后没有别的入口能找回来 |
| §10.3 sherpa-onnx 原生库 | SAPI5 离线识别作为第一 Provider；sherpa 运行时/模型依赖脚本已就位 | 本机自带中文识别器，无需下模型；接口已解耦，`c-api.h` 当前网络不可达 |
| §7.5 系统 TTS | SAPI5（`System.Speech`） | 无额外依赖，中文音色系统自带 |
| 窗口随面板缩放 | 固定 380×560 + 透明区域自动穿透 | 尺寸稳定、命中测试简单 |
| §7.9 Android 用 sherpa-onnx 本地 KWS/ASR | 先用系统 `SpeechRecognizer`（阶段 C 第 2 步） | 不塞模型先打通「说话→执行→播报」；`VoiceEngineAdapter` 已留好替换位 |
| §7.6 KWS 是低功耗守门器 | 常驻模式用「连续识别 + 唤醒词文本匹配」（默认关） | 系统识别没有关键字语法；耗电/延迟不如真 KWS，故做成可选开关 |
| §7.7 一句话带命令 | 走「整段 ASR」路线：唤醒词后面那一截直接当指令 | 真 KWS 路线（pre-roll 交给 ASR）要等 sherpa-onnx；整段路线已经能一句带命令 |
| §7.4 Android PCM 不进 Dart | 采集与识别全在系统语音服务里，Dart 只收文本事件 | 与 §7.4 一致，且零额外依赖 |
| §10.1 Android 音频焦点 | 待机唤醒不申请焦点，只在主动聆听时申请 `GAIN_TRANSIENT` | 守门器不该打断用户正在听的音乐；待机时麦克风被占由识别器报错兜底 |
| §10.2 macOS 用 sherpa-onnx 本地 KWS/ASR | 先用系统 `SFSpeechRecognizer` 本机识别（on-device） | 不塞模型先打通「唤醒→执行→播报」；`VoiceEngineAdapter` 已留好替换位 |
| §10.1 令牌用 Keystore | 已实现（AES-GCM + Android Keystore） | 与文档一致 |
| §5 macOS 允许用插件 | 窗口/语音走一条自建 MethodChannel + 系统框架 | 只依赖 AppKit/AVFoundation，不引第三方插件 |
| §11.2 macOS 令牌加密 | 先 0600 明文落盘，后续换 Keychain | 与同机 `~/.dsh` 令牌的威胁模型一致，先跑通再收紧 |

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

### 阶段 E 收尾验证（2026-11-16）

```text
flutter analyze                → 无 error/warning（22 条 info，均为既有 material.dart 弃用提示）
flutter test                   → 146 个测试全绿
                                 （另有 3 个 macOS 唤醒用例由并行会话在改，不在本轮范围）
flutter build windows --release→ 成功（105s），产物 build/windows/x64/runner/Release/
python tool/package_release.py → dist/whalepet-windows-x64-0.3.1+2.zip（15.5 MiB）
```

本轮新增能力的状态：

| 能力 | 验证到什么程度 |
|---|---|
| 托盘图标 | C++ 编译链接通过；已确认托盘菜单文案与 `whalepet/desktop` 通道名进入二进制（静态核对）。**真机点验未做**：本机从网络盘直接运行 exe 被 Windows 策略拒绝（`Access is denied`），需拷到本地目录后点图标验证 |
| 开机自启 | 注册表读写路径实现完成；开关接进设置面板。写入/删除的真机点验同上 |
| 多显示器 / DPI | 消息链路实现完成（runner → 通道 → Dart 刷新 DPI → 重新约束）；插拔显示器的真机点验同上 |
| 一句话带命令（Windows） | core 侧 146 个用例全绿（含 §7.7 的 6 个）；**SAPI 引擎侧的真机 WAV 验证未做**（本机无麦克风，且 exe 不能从网络盘启动），需本地跑 `tool/verify_voice.dart listen` 复核 |

> 本轮的一个打包缺陷修复：`build/` 目录被并行会话的 debug 构建污染时，
> Release 里会残留 43MB 的 `kernel_blob.bin`（JIT 内核），打出来的包会翻倍。
> `tool/package_release.py` 现在会剔除调试残留，并在缺少 AOT 快照（`data/app.so`）时直接报错。

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

### 发布包复验（2026-11-16，提交 `c08fd97` = GitHub `main` = tag `v1.3.0`）

```text
flutter build windows --release           → 成功（在该提交上重建，不是旧产物）
python tool/package_release.py --no-build → dist/whalepet-windows-x64-0.3.1+2.zip（15.5 MiB）
解压到空目录重新启动 + mock /api/agent    → hello → 连续 6 轮 command，语音闭环正常
```

复验时发现的分发缺陷：Release 目录里没有 VC 运行库，`whalepet_flutter.exe` 的导入表却点名
`MSVCP140.dll` / `VCRUNTIME140.dll`，干净 Windows 上双击会直接报「找不到 VCRUNTIME140.dll」。
`tool/package_release.py` 已改为把 `vcruntime140*.dll` / `msvcp140.dll` / `d3dcompiler_47.dll`
一起打进包（app-local），缺 DLL 时直接失败而不是产出残包。

## 验证记录（macOS 15.8.3 / Intel，2026-11-16）

```text
dart test                            → 89 个测试全绿
flutter analyze                      → 0 error / 0 warning（仅 tool/ 脚本的 info 级提示）
flutter build macos --debug          → 成功
flutter build macos --release        → 成功（45.3 MB .app）
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

### macOS 本地语音（新增，待真机复验）

macOS 端补上本地语音引擎后（`VoiceEngine.swift` + `MacOSVoiceEngine` +
`VoiceEventRouter`），本机（Linux，无 Xcode）能验证的部分：

```text
dart test                        → 105 个测试全绿（新增 16 个：路由 14 + 协调器回归 1 + 多屏回归 1）
dart analyze lib/core lib/platform test → 0 error / 0 warning（flutter_lints 全套）
flutter analyze                  → 22 个 info（全是既有的 material.dart 弃用与 tool/ 脚本提示）
pbxproj 结构自检                → 对象引用全部可解析、括号配平、新文件三处就位
Info.plist 解析                  → NSMicrophoneUsageDescription / NSSpeechRecognitionUsageDescription 已写
```

**尚未在 macOS 真机验证**（需要一台装了 Xcode 的 Mac）：

1. `flutter build macos` 能否编译通过（`VoiceEngine.swift` 是新加的源文件）；
2. 首次开启语音时「麦克风」「语音识别」两个系统授权弹窗是否正常出现；
3. 唤醒 → 识别 → 播报的实际闭环与识别准确率；
4. `requiresOnDeviceRecognition` 在目标机型上是否真的走本机识别
   （引擎 ready 事件里会打印 `onDevice`）；
5. 插拔外接显示器后桌宠是否被拉回可见屏幕。

复验命令：

```bash
cd Clients/whalepet_flutter
flutter build macos --release
WHALEPET_VOICE_DEBUG=1 ./build/macos/Build/Products/Release/whalepet_flutter.app/Contents/MacOS/whalepet_flutter
```

## 验证记录（Android 阶段 C 第 3~4 步，2026-11-16）

本机（Windows，无 Android SDK / 无真机）能验证的部分：

```text
flutter test                            → 141 个测试全绿（新增 36 个）
  ├─ spoken_command_test.dart          →  7 个：语气词判定
  ├─ wake_matcher_test.dart            → +7 个：matchWithRest 唤醒词后面那一截
  ├─ voice_event_router_test.dart      → 改：待机只认 final（§7.7.4）
  ├─ voice_session_coordinator_test.dart→ +11 个：一句话带命令 / 中断恢复 / 前后台
  └─ android_system_voice_engine_test  → 10 个：Android 引擎（模拟 MethodChannel/EventChannel）
dart analyze lib test                   → 0 error / 0 warning（仅既有 info 级提示）
flutter build bundle --debug            → 成功（kernel_blob.bin，整包 Dart 编译通过）
```

> 测试命令从 `dart test` 改用 `flutter test`：`test/core/pet_runtime_display_test.dart`
> 依赖 `dart:ui`，`android_system_voice_engine_test.dart` 依赖 Flutter 的二进制消息器。
> 为此在 `pubspec.yaml` 的 `dev_dependencies` 里补了 `flutter_test`（SDK 包，不引入网络依赖）。

**修掉一个阻断编译的预存错误**：`lib/ui/desktop_pet/pet_runtime.dart` 的
`_toggleWindowVisible()` 原来写成

```dart
final DesktopWindowAdapter adapter = window;
if (adapter is! WindowVisibilityAware) return;
final WindowVisibilityAware visibility = adapter;   // ← 编译不过
```

`WindowVisibilityAware` 与 `DesktopWindowAdapter` 是**两个无关的接口**，Dart 的类型提升
要求「被提升的类型是声明类型的子类型」，所以 `is` 检查后无法提升；分析器没报，
但真编译（CFE）会失败——`main.dart` 导入了这个文件，**Android / Windows / macOS 三个构建
都会挂**。改成按 `Object` 声明即可正常提升。之前 `flutter test` 之所以是绿的，
是因为命中了旧的构建缓存；`flutter pub get` 让缓存失效后才暴露出来。

### 待真机复验（需要一台 Android 手机）

1. `flutter build apk --release` 能否编译通过（本轮改动了 `WhalePetBridge.kt`）；
2. 说「小鲸小鲸，帮我查一下明天的安排」是否**不播「我在」**、直接执行；
3. 只说「小鲸小鲸」是否照旧播「我在」并进入聆听；
4. 锁屏 / 切后台再回来，语音是否按原设置恢复，且不再冒「语音关掉啦」；
5. 来电时是否提示「检测到来电/通话」，挂断后是否自动回到待唤醒；
6. 播报期间放音乐是否会被误判为「麦克风被占用」。

