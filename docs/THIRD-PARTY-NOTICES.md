# 第三方素材与代码声明

本仓库包含来自第三方开源项目的素材，按各自许可使用。

## 1. dsh-whale-musume（鲸鱼娘立绘）

- 来源：https://github.com/Sutera-Diffusus/dsh-whale-musume
- 获取方式：npm 官方源 `npm pack dsh-whale-musume`（v2.5.3），
  取 `assets/generated/dsh-whale-state-*.webp`
- 许可：**MIT**（包内 `LICENSE`：Copyright (c) 2026 Sutera-Diffusus）
- 用途：iPad App「鲸鱼娘 DSH 宠物」的角色立绘；同一套 PNG 也复制到
  `Clients/whalepet_flutter/assets/pet/`（Android / Windows / macOS 客户端共用，字节一致）

### 被本仓库使用的部分

| 本仓库 imageset | 上游文件 | 处理 |
|---|---|---|
| `pet_idle` | `dsh-whale-state-idle-cute.webp` | 裁透明边 + 等比缩放至 420pt 高 + 统一画布，转 PNG |
| `pet_walk` | `dsh-whale-state-tail-swing.webp` | 同上 |
| `pet_swim` | `dsh-whale-state-daily-stretch.webp` | 同上 |
| `pet_happy` | `dsh-whale-state-react-head.webp` | 同上 |
| `pet_eat` | `dsh-whale-state-eat.webp` | 同上 |
| `pet_sleep` | `dsh-whale-state-sleep.webp` | 同上 |
| `pet_drag` | `dsh-whale-state-pick-up.webp` | 同上 |
| `pet_play` | `dsh-whale-state-celebrate.webp` | 同上 |
| `pet_sad` | `dsh-whale-state-failure.webp` | 同上 |
| `pet_greet` | `dsh-whale-state-greet.webp` | 同上 |
| `AppIcon` 全套 | `dsh-whale-state-idle-cute.webp` | 合成到深蓝圆角底 |

导入脚本：`Tools/art/import_upstream.py`（可重复执行，幂等）。
立绘版权归原作者所有；本仓库仅做尺寸归一化与格式转换，未修改角色形象本身。
MIT 许可全文见上游包 `LICENSE`，要点：保留版权声明与许可文本即可自由使用、修改、分发。

### 移除方式

若原作者有不同意见，删除上述 imageset 并回退到 git 历史中的程序化素材版本
（`git log -- Tools/art/generate_assets.py`）即可，App 逻辑不受影响。

## 2. 随仓库分发的第三方二进制（Android 原生原型）

`Android/libs/` 内含两个 jar，供 `Android/build-apk.sh` 脚本构建使用（Apache-2.0）：

| 文件 | 项目 | 许可证 |
|---|---|---|
| `okhttp-3.12.13.jar` | [Square OkHttp](https://github.com/square/okhttp) | Apache-2.0 |
| `okio-1.17.6.jar` | [Square Okio](https://github.com/square/okio) | Apache-2.0 |

仅用于早期原生 Java 原型（`Android/`）的 WebSocket；Flutter 客户端与 iPad App 不依赖它们。
Apache-2.0 要求保留版权与许可声明：jar 内已含各自 `META-INF/LICENSE`/`NOTICE`，未做修改。

### Windows 便携包内的微软可再发行组件

`release/whalepet-windows-x64-*.zip` 按 app-local 方式附带以下微软 DLL（未修改）：

| 文件 | 来源 | 分发依据 |
|---|---|---|
| `vcruntime140.dll` / `vcruntime140_1.dll` / `msvcp140.dll` | Visual C++ 2015-2022 Redistributable | [微软 VC Redist 可再发行条款](https://learn.microsoft.com/cpp/windows/redistributing-visual-cpp-files)（Distributable Code） |
| `d3dcompiler_47.dll` | Windows SDK | 同上（DirectX 组件随 VS 生成工具再发行） |

这些是微软专有二进制，**不在本仓库 MIT 许可范围内**，仅按微软再发行条款随便携包分发；
源码不随仓库提供。Flutter 引擎 `flutter_windows.dll` 为 BSD-3-Clause（Flutter 项目）。

## 3. 运行时框架与库依赖（不随仓库分发源码）

- **[Flutter / Dart SDK](https://github.com/flutter/flutter)**（BSD-3-Clause）：跨平台客户端
  （`Clients/whalepet_flutter/`）的 UI 框架与语言运行时，由使用者本机安装。
- **[dart-lang/ffi](https://github.com/dart-lang/native/tree/main/pkgs/ffi)**（BSD-3-Clause）：
  pubspec 依赖，FFI 内存分配辅助，纯 Dart。
- **系统语音 API**：Windows SAPI（`ISpRecognizer`/`ISpVoice`）、macOS AVSpeechSynthesizer、
  Android/iOS 系统识别与 TTS——操作系统自带能力，非第三方代码。
- 开发期工具：`test`（BSD-3-Clause）、`flutter_lints`（BSD-3-Clause），仅测试/静态检查用。

## 4. 设计思路参考（未使用其代码/素材）

- [VPet-Simulator](https://github.com/LorisYounger/VPet)（Apache-2.0；默认动画另有 VUP 团队版权条款）：状态机+数值+互动架构思路。
- [Shijima / libshijima](https://github.com/pixelomer/Shijima-Qt)（GPL-3.0）：Shimeji 行为划分思路。
- [N.E.K.O](https://github.com/Project-N-E-K-O/N.E.K.O)（Apache-2.0）：主动陪伴交互启发。
- [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（MIT）：宿主平台，插件仅调用其公开 Host API，未复制源码。

## 5. 本仓库原创部分

- 全部 Swift 代码（状态机/数值/持久化/场景/HUD/台词）
- 全部 Dart 代码（`lib/core/` 宠物核心 + 三端 platform 适配层）与插件 JS 代码
- Android 原生 Java 原型代码（`Android/app/`，第三方 jar 除外）
- 背景渐变 `bg_gradient`、特效 `fx_heart` / `fx_fish`（`Tools/art/generate_assets.py` 程序化绘制）

以上原创部分按仓库根 `LICENSE`（MIT）授权。