# WhalePet Flutter 客户端（Android 全屏 + Windows 桌宠）

跨平台客户端工程：**同一份 `lib/core/`**，两套场景控制器（§6.3）。

| 部分 | 状态 | 说明 |
|---|---|---|
| `lib/core/`（宠物状态/数值/行为/存档/协议/语音状态机） | ✅ 双端共用 | 纯 Dart，`dart test` 直接可跑，不依赖 Flutter |
| `lib/ui/mobile_scene/`（Android 全屏场景） | ✅ 阶段 C 1~2 步 | 海底场景、立绘位移/拖拽/点击、状态条、操作栏、聊天/设置浮层 |
| `lib/platform/android/`、`speech_output/android_*`、`secure_storage/` | ✅ Android | MethodChannel + 系统 SpeechRecognizer / TextToSpeech / Keystore |
| `lib/platform/`（Win32 窗口、SAPI 离线 KWS/ASR、TTS） | ✅ Windows | `dart:ffi` + 系统 API，零第三方插件 |
| `lib/ui/desktop_pet/`（透明桌宠界面） | ✅ Windows | 气泡、立绘、聊天/设置面板、右键菜单 |
| 本地语音（唤醒 → 识别 → 文本 → TTS） | ✅ 双端 | Android 用系统识别服务；Windows 用 SAPI 离线识别 |
| 一句话带命令（§7.7）、sherpa-onnx 本地模型、AEC/barge-in、macOS | ⏳ | 后续增强 |

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
│   │   ├── speech_output/powershell_speech.dart    # 常驻子进程 + System.Speech 合成
│   │   └── voice/sapi_voice_engine.dart            # 常驻子进程 + 离线桌面识别（KWS/听写）
│   ├── ui/mobile_scene/                            # Android 全屏场景：runtime + shell
│   └── ui/desktop_pet/                             # runtime、宠物、气泡、聊天/设置面板、菜单
├── android/                                        # Flutter Android runner + 原生能力桥（Kotlin）
├── assets/pet/                                     # 立绘（与 iOS 工程同一套素材）
├── windows/                                        # Flutter Windows runner（桌宠窗口）
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
- 语音：勾「开启唤醒词常驻侦听」，可改唤醒词、别名（逗号分隔）、唤醒应答

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
%APPDATA%\WhalePet\
├── settings.json      # 服务地址、语音配置、开关、窗口位置（明文）
├── token.bin          # Bearer 令牌（DPAPI 密文，换账号/换机解不开）
├── client_id.txt      # 本机客户端 id，服务端据此单播回答
└── save\pet_save.json # 数值存档（schema v1，原子写，坏档先备份再回落默认值）
```

## 与架构文档的对应

| 文档要求 | 落地 |
|---|---|
| §6.3 桌宠 = 移动窗口 | `Win32DesktopWindow.setPosition` + 30fps 帧循环 |
| §6.3 位置限制在工作区 | `clampToWorkArea`（有单测） |
| §7.2 语音状态机与 generation | `VoiceSessionCoordinator`：8 态、generation 守卫、resumeAfterSpeech、10s 聆听超时 |
| §7.4 PCM 不穿过 Dart | 采集/KWS/ASR 全在常驻子进程，Dart 只收事件 |
| §7.6 待机只跑 KWS | 两套语法按模式互斥启用，待机仅唤醒词小语法 |
| §7.8 闭麦与播报队列 | 播报前 `stopListening`，`SpeechQueue` 去重/优先级/「回答后不念做完了」 |
| §8 全部协议字段 | `core/agent/`，含 `event_id` 去重、补发、退避、401/403 不重试 |
| §11.2 令牌安全存储 | DPAPI（`CryptProtectData` + 应用附加熵） |
| §11.3 voice_config 版本 | revision 变化在「等待唤醒」安全点重建 KWS 语法 |

## 与文档原设计的偏差

| 原设计 | 实际做法 | 原因 |
|---|---|---|
| §5 允许用 `window_manager` 等插件 | 全部 `dart:ffi` 直连 Win32 | 零第三方依赖、行为可控 |
| §10.3 托盘图标 | 右键菜单（含退出/重连/设置） | 自绘托盘要额外消息窗口，收益低 |
| §10.3 sherpa-onnx 原生库 | SAPI5 离线识别作为第一 Provider | 本机自带中文识别器，无需下模型；接口已解耦 |
| §7.5 系统 TTS | SAPI5（`System.Speech`） | 无额外依赖，中文音色系统自带 |
| 窗口随面板缩放 | 固定 380×560 + 透明区域自动穿透 | 尺寸稳定、命中测试简单 |
| §7.9 Android 用 sherpa-onnx 本地 KWS/ASR | 先用系统 `SpeechRecognizer`（阶段 C 第 2 步） | 不塞模型先打通「说话→执行→播报」；`VoiceEngineAdapter` 已留好替换位 |
| §7.6 KWS 是低功耗守门器 | 常驻模式用「连续识别 + 唤醒词文本匹配」（默认关） | 系统识别没有关键字语法；耗电/延迟不如真 KWS，故做成可选开关 |
| §10.1 令牌用 Keystore | 已实现（AES-GCM + Android Keystore） | 与文档一致 |

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
