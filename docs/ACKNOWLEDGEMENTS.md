# 参考与致谢

## 直接使用的开源素材

**[dsh-whale-musume](https://github.com/Sutera-Diffusus/dsh-whale-musume)**（MIT，Copyright (c) 2026 Sutera-Diffusus）：
本 App 的鲸鱼娘角色立绘（10 张状态图 + AppIcon）直接来自该项目 npm 包 v2.5.3 的
`assets/generated/` 目录，仅做尺寸归一化与 webp→PNG 转换；同一套 PNG 供 iPad 与
Flutter 三端客户端（Android / Windows / macOS）共用。
完整映射表与许可文本见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) 与
[LICENSE-dsh-whale-musume.txt](LICENSE-dsh-whale-musume.txt)。

## 直接使用的第三方库

- **[OkHttp](https://github.com/square/okhttp) 3.12.13 + [Okio](https://github.com/square/okio) 1.17.6**（Apache-2.0）：
  仅 Android 原生 Java 原型（`Android/libs/` 两个 jar）的 WebSocket 实现；jar 内自带许可声明，未修改。
- **[sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) v2.0.1**（Apache-2.0）+
  **[ONNX Runtime](https://github.com/microsoft/onnxruntime)**（MIT）：
  macOS 客户端的本地唤醒词检测（KWS）。载荷不入库，由
  `Clients/whalepet_flutter/tool/fetch_sherpa_onnx.sh` 在出包时拉取官方产物，
  装进 App 包的 `Contents/Resources/kws/`；二进制与模型均未修改。
- **[Flutter / Dart](https://github.com/flutter/flutter)**（BSD-3-Clause）与
  **[ffi](https://github.com/dart-lang/native/tree/main/pkgs/ffi)**（BSD-3-Clause）：
  跨平台客户端的框架与 FFI 辅助库，由使用者本机安装/pub 拉取，不随仓库分发源码。

## 设计思路参考（未复制代码/素材）

全部 Swift / Dart / Java / 插件 JS 代码与背景/特效素材为本仓库原创。以下开源项目仅在**设计思路**层面提供参考：

### VPet-Simulator（虚拟桌宠模拟器）
- 仓库：https://github.com/LorisYounger/VPet
- 许可证：Apache-2.0（默认动画素材版权归 VUP-Simulator 团队，另有授权条款）
- 参考点：
  - 「状态机 + 数值（饱食/心情/体力）+ 互动触发」的桌宠三层架构；
  - 摸头/投喂/提起等互动与动画状态的映射关系；
  - 低状态时宠物"变蔫、求关注"的情感化反馈。
- 差异：VPet 面向 Windows/WPF 且支持创意工坊与 200+ 动画；本项目面向 iPadOS 15 单设备，用 SpriteKit 分层部件 + 程序化动画替代序列帧，规模刻意精简。

### Shijima / libshijima（Shimeji 系）
- 仓库：https://github.com/pixelomer/Shijima-Qt （及 Shijima-iOS / Shijima-Android / Shijima-Web）
- 许可证：GPL-3.0
- 参考点：Shimeji 行为脚本（走动/攀爬/拖拽/落下）的状态划分方式。
- 差异：Shijima-iOS 通过越狱插件把宠物注入系统桌面；iOS 沙箱不允许正规 App 这样做，因此本项目改为**全屏 App 内海底场景**，这是 iPadOS 15 上无需越狱的唯一合规形态。

### N.E.K.O
- 仓库：https://github.com/Project-N-E-K-O/N.E.K.O
- 许可证：Apache-2.0
- 参考点：桌宠主动搭话、按心情选台词的陪伴感设计。
- 差异：N.E.K.O 依赖 LLM 与 Live2D；本项目台词为本地静态语料库，零网络、零推理开销，适配 A8 老设备。

### 运行平台与系统框架
- **[DeepSeek Harness（DSH）](https://github.com/deepseek-ai/deepseek-harness)**（MIT）：本项目的宿主平台。
  DSH 插件按官方 Host API / bundle 契约编写（调研笔记见 [refs/](refs/)），语音识别复用其
  `speech-to-text` 服务（SenseVoice 本地模型），会话复用其官方 sessionController——本项目未复制 DSH 源码，
  仅作为插件调用其公开接口。
- **Apple SpriteKit / AVFoundation / UIKit / AppKit**：系统框架，程序化动画、音频采集与 TTS 的基础。
- **Windows SAPI / Android 系统语音服务**：操作系统自带的识别与合成能力（FFI 直连，无第三方运行时）。
- **[Pillow](https://github.com/python-pillow/Pillow)**（MIT-CMU）：素材导入/生成脚本使用的 Python 图像库（开发期工具，不随 App 分发）。

注意：VPet 默认动画版权归 VUP-Simulator 团队（另有授权条款），Shijima 为 GPL-3.0——
本项目**未使用**它们的任何代码与素材，仅参考思路，不触发其许可义务。
实际使用的 dsh-whale-musume 为 MIT，义务仅为保留版权声明（已满足，见
[LICENSE-dsh-whale-musume.txt](LICENSE-dsh-whale-musume.txt)）。