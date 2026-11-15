# WhalePet Flutter 客户端（Windows 桌宠）

跨平台客户端工程。当前交付：

| 部分 | 状态 | 说明 |
|---|---|---|
| `lib/core/`（宠物状态 / 数值 / 行为 / 存档 / 协议 / 播报队列） | ✅ 完成 | 纯 Dart，`dart test` 直接可跑，不依赖 Flutter |
| `lib/platform/`（Win32 窗口、系统 TTS） | ✅ Windows | 只用 `dart:ffi` + 系统 API，零第三方插件 |
| `lib/ui/desktop_pet/`（透明桌宠界面） | ✅ Windows | 气泡、立绘、面板、右键菜单 |
| 本地语音（KWS / VAD / ASR） | ⏳ 未做 | 第一阶段只做「文本指令 + 系统播报」 |

设计依据：[`docs/CROSS_PLATFORM.md`](../../../docs/CROSS_PLATFORM.md) §6（宠物核心）、§7（语音）、
§8（`/api/agent` 协议）、§10.3（Windows）、§11（存档与安全）、§12（测试）。

## 目录

```text
Clients/whalepet_flutter/
├── lib/
│   ├── main.dart                      # 入口：装配适配层 → 起 runtime → runApp
│   ├── core/                          # 纯 Dart，禁止 import Flutter
│   │   ├── pet/                       # 状态、数值、行为调度、台词
│   │   ├── storage/                   # 存档 schema v1 + 原子写
│   │   ├── agent/                     # /api/agent 协议与 WebSocket 网关
│   │   ├── config/                    # 设置、路径、DPAPI 令牌存储
│   │   ├── platform/                  # 窗口/播报的抽象接口 + 窗口位置几何
│   │   └── voice/                     # 播报接口与播报队列（去重/优先级）
│   ├── platform/
│   │   ├── desktop_window/win32_window.dart      # Win32 FFI：透明/置顶/穿透/拖拽/DPI
│   │   └── speech_output/powershell_speech.dart  # 常驻 PowerShell + System.Speech
│   └── ui/desktop_pet/                # runtime、宠物、气泡、聊天面板、设置面板、菜单
├── assets/pet/                        # 立绘（与 iOS 工程同一套素材）
├── windows/                           # Flutter Windows runner（已改造成桌宠窗口）
└── test/core/                         # 纯 Dart 测试
```

依赖规则（§5）：`UI → core 接口 → platform 实现`；`core` 不 import Flutter，`platform` 不改 widget。

## 构建 / 运行

前置：Flutter SDK（验证版本 3.50.0）+ Visual Studio 2022 生成工具的 **C++ 桌面开发**组件
（MSVC 工具集 + CMake + Windows SDK，缺一不可；`flutter doctor -v` 的 Visual Studio 项必须是 ✓）。

```bash
cd Clients/whalepet_flutter
flutter pub get
flutter run -d windows          # 调试运行
flutter build windows           # 产物：build/windows/x64/runner/Release/whalepet_flutter.exe
```

纯核心逻辑（不需要 Flutter、不需要图形环境）：

```bash
dart test
```

## 使用

启动后是一个 **380×560 的透明置顶窗口**，里面只有宠物和气泡：

| 操作 | 效果 |
|---|---|
| 单击宠物 | 摸头（心情 +10） |
| 双击宠物 | 打开聊天面板（输入指令，Enter 发送） |
| 右键宠物 | 菜单：摸头 / 投喂 / 玩 / 说点什么 / 设置 / 睡觉 / 重连 / 退出 |
| 按住拖动 | 系统级拖拽整窗移动，松手后自动夹回当前显示器工作区 |
| 鼠标移到透明区域 | 窗口变为 `WS_EX_TRANSPARENT`，不挡后面软件的点击 |

第一次使用先右键 →「设置」：

- **服务器地址**：`http://<运行 DSH 的机器 IP>:8787`（局域网 IP 或 ZeroTier IP）
- **访问令牌**：`~/.dsh/whalepet/ipad-token` 的内容（DPAPI 加密后存本地）

保存后自动重连，面板标题上的圆点显示连接状态。

## 数据落在哪

```text
%APPDATA%\WhalePet\
├── settings.json      # 服务地址、开关、窗口位置（明文，可读可改）
├── token.bin          # Bearer 令牌（DPAPI 密文，换账号/换机解不开）
├── client_id.txt      # 本机客户端 id，服务端据此把回答单播回来
└── save\pet_save.json # 数值存档（schema v1，原子写，坏档先备份再回落默认值）
```

## 与架构文档的对应

| 文档要求 | 落地 |
|---|---|
| §6.3 桌宠 = 移动窗口，不做全屏透明画布 | `Win32DesktopWindow.setPosition` + `PetRuntime._moveTick`（walk 水平、swim 起伏，约 30fps） |
| §6.3 位置限制在工作区 | `core/platform/window_placement.dart#clampToWorkArea`（有单测） |
| §6.3 穿透要有可恢复入口 | 透明区域自动穿透（可关；鼠标回到宠物身上自动恢复） |
| §8.1 兼容旧 `/api/audio` | 不碰旧通道，只新增 `/api/agent` 客户端 |
| §8.4 `request_id` 幂等 | `newRequestId()` 生成并在重试时复用，不产生新 id |
| §8.9 断线补发 / 去重 | `WebSocketAgentGateway` 按 `event_id` 去重，`hello` 上报 `last_received_event_id` |
| §8.10 重连策略 | 先 `/api/health`；1/2/4/8/16/30s 退避；401/403 不重试 |
| §7.8 不重复念「做完了」 | `SpeechQueue` 按 `requestId` 丢弃已回答的完成提醒（有单测） |
| §11.1 存档规则 | 15 秒节流 + 退出落盘；UTC ISO-8601；原子写（含 Windows rename 差异） |
| §11.2 令牌安全存储 | DPAPI（`CryptProtectData`）+ 应用附加熵 |

## 已知限制（第一版）

1. **没有本地语音唤醒 / 识别**：KWS、VAD、ASR（sherpa-onnx）留到下一阶段；现在靠右键菜单或聊天面板输入文字。
2. 播报走 `System.Speech`（SAPI 5），中文音色取决于系统装了哪些语音包；不支持播报中打断。
3. 窗口尺寸固定 380×560，聊天面板在窗口内，长回答需要滚动。
4. 其它 DSH 会话的全局通知默认开启，设置里可关。
5. 双击宠物会激活窗口（为了能打字），这是桌宠的固有取舍。
6. 暂不产出安装包，只有 `flutter build windows` 的便携目录。

## 验证记录（本机 Windows 11，2026-11-15）

```text
dart test                      → 66 个测试全绿（含阶段 B 原有 40 个）
flutter analyze                → 0 error / 0 warning
flutter build windows --debug  → 成功（VS 2022 生成工具 + Windows SDK 10.0.26100）
```

功能验证（真机截图逐一确认）：

| 项 | 结果 |
|---|---|
| 透明窗口 | 宠物浮在桌面壁纸之上，没有黑框/白框；窗口 `exstyle=0x800a8`（layered + topmost + toolwindow + transparent） |
| 单击宠物 | 立绘切到 happy，头顶气泡出随机台词，心情上升 |
| 双击宠物 | 打开聊天面板，输入框自动聚焦，直接可用键盘 |
| 右键宠物 | 7 项菜单：摸头 / 投喂 / 玩 / 说点什么 / 设置 / 睡觉 / 退出 |
| 设置面板 | 保存后写入 `%APPDATA%\WhalePet\settings.json` |
| 令牌存储 | `tool/write_token.dart` → DPAPI 加密写入并读回一致 |
| `/api/agent` 全链路 | 用本地模拟服务端跑通：`hello → ready → command → task(queued/started) → response → task(finished)`，回答上屏 + 气泡 + 立绘切到 speaking |
| 未配置时的降级 | 输入指令后保留在聊天记录里，并提示「还没连上 DSH：右键 → 设置」 |
