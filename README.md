# 鲸鱼娘 DSH 宠物 🐋‍♀️

一位住在 iPad 全屏海底世界里的**鲸鱼娘**——蓝发女仆裙 Q 版少女，鲸尾 + 鳍耳，立绘来自开源项目 [dsh-whale-musume](https://github.com/Sutera-Diffusus/dsh-whale-musume)（MIT）。为 **iPad mini 4（A8 / 2GB RAM / iPadOS 15.8.x）** 量身打造：SpriteKit 整图切换 + 程序化运动动画，30fps 低功耗运行，无内购、无第三方运行时依赖。

**v1.2.0 新增：语音唤醒 + DeepSeek Harness 对话。** 通过内网自部署的桥接服务器（`Server/`），对着 iPad 说 **"小鲸小鲸"** 即可唤醒她，随后语音下达指令，服务器完成唤醒词检测与中文语音识别，交给 DeepSeek Harness（DSH）处理，回答由 iPad 本地 TTS 播报，宠物同步切换"聆听/思考/播报"动画。语音仅在 App 前台工作，音频只走局域网。部署方式见 [Server/README.md](Server/README.md)。

![预览](docs/preview.png)

> DSH = **D**eep **S**ea **H**ug（深海抱抱）。10 张状态立绘（待机/散步/巡游/摸头/投喂/睡觉/拖拽/玩耍/委屈/挥手）+ 漂浮、摇摆、Q 弹、点头等程序化运动。被摸头会脸红冒爱心，被拎起来会晃荡喊晕船。

## 功能

| 交互 | 效果 |
|---|---|
| 轻点鲸鱼娘 | 摸头：Q 弹挤压 + 举手欢呼 + 爱心 + 心情↑ |
| 按住拖动 | 拎起来到处放（拖拽态四肢乱晃） |
| 🐟 投喂 | 小鱼干飞进嘴里，饱食↑ |
| 🫧 玩耍 | 泡泡球弹跳，心情↑ 精力↓ |
| 🌙 睡觉 | 入睡恢复精力，再点唤醒 |
| 🎙️ 说话 | 开启语音 / 手动触发一次指令（免唤醒词） |
| ⚙️ 设置 | 填写桥接服务器地址与访问令牌，保存即测试连通 |
| ✏️ 改名 | 自定义名字（≤12 字符），台词随名字变化 |

- **语音对话**：前台待唤醒 → 说"小鲸小鲸"（支持一句话带指令）→ DSH 生成回答 → 本地 TTS 播报，播报期间自动闭麦防自触发；也可点 🎙️ 手动开始。
- **数值系统**：饱食 / 心情 / 精力三条状态槽，随时间缓慢衰减；离线最多结算 6 小时，不会"一觉醒来饿死"。
- **自主行为**：加权随机状态机（待机/散步/巡游/睡觉），又饿又累时会变蔫、主动求关注。
- **台词气泡**：按场景与数值状态选句，避免连续重复；语音过程有专属气泡与状态。
- **持久化**：JSON 原子写入 Application Support，杀进程不丢档；服务器地址存 UserDefaults，令牌存 Keychain。
- **全方向旋转**：横竖屏自适应，`UIRequiresFullScreen` 全屏独占（老设备省内存）。

## 设备与性能预算（iPad mini 4）

| 项 | 取值 | 说明 |
|---|---|---|
| 最低系统 | iPadOS 15.0 | mini 4 最高 15.8.x，不支持 16 |
| 帧率 | 30 fps | `preferredFramesPerSecond = 30`，省电防发热 |
| 渲染 | SpriteKit 整图切换 + SKAction 运动 | 无序列帧、无物理引擎、无 SKEffectNode |
| 纹理显存 | ≈ 9.7 MB（运行时） | 10 张 420pt 立绘 + 背景 + 特效；磁盘含图标 ≈ 14 MB |
| 粒子 | 12 个复用 SKShapeNode 气泡 | 不用 SKEmitterNode |
| 存档 | 每 15s + 退后台时 | 原子写，掉电安全 |

## 构建（需要一台 Mac）

本仓库在 Linux 上开发并通过静态自检；**编译与真机安装必须在 macOS + Xcode 上完成**（Apple 工具链限制）。

```bash
# 1. 安装 XcodeGen（一次性）
brew install xcodegen

# 2. 生成 Xcode 工程（project.yml 是唯一事实源，.xcodeproj 不入库）
xcodegen generate

# 3. 打开工程
open WhalePet.xcodeproj
```

在 Xcode 中：
1. 选中 WhalePet target → Signing & Capabilities → 勾选 *Automatically manage signing*，选择你的 Team（**免费 Apple ID 即可**，7 天有效期，到期重签）。
2. 连接 iPad mini 4，顶部设备选择它，⌘R 运行。
3. 首次在设备上信任开发者：设置 → 通用 → VPN与设备管理。

命令行构建（可选）：

```bash
xcodebuild -project WhalePet.xcodeproj -scheme WhalePet \
  -destination 'platform=iOS,name=你的iPad' \
  -allowProvisioningUpdates build
```

跑单元测试（任意 iPad 模拟器）：

```bash
xcodebuild test -project WhalePet.xcodeproj -scheme WhalePet \
  -destination 'platform=iOS Simulator,name=iPad (10th generation)'
```

> 注意：Xcode 15+ 默认不带 iOS 15 模拟器运行时，可在 Settings → Platforms 下载；
> 或直接真机跑测试。部署目标 15.0 用 Xcode 14/15/16 均可编译。

## 素材来源与再生成

**角色立绘**来自开源项目 [dsh-whale-musume](https://github.com/Sutera-Diffusus/dsh-whale-musume)（MIT，Copyright (c) 2026 Sutera-Diffusus），已随仓库入库，无需联网即可构建。详见 [THIRD-PARTY-NOTICES.md](docs/THIRD-PARTY-NOTICES.md)。

如需更新到上游新版立绘：

```bash
cd /tmp && npm pack dsh-whale-musume --registry=https://registry.npmjs.org
tar xzf dsh-whale-musume-*.tgz
python3 Tools/art/import_upstream.py --src /tmp/package/assets/generated
```

**背景与特效**（深海渐变/爱心/小鱼干）为原创程序化绘制：

```bash
python3 Tools/art/generate_assets.py
```

## Linux 侧自检（无需 Mac）

```bash
python3 Tools/scripts/check.py
```

校验：Swift 括号配平、工程配置（iOS 15 / 仅 iPad / 全屏）、纹理引用一致性、显存预算、测试覆盖、语音权限声明、桥接服务器语法与纯逻辑测试。

## v2：作为 DSH 插件接入你的工作 DSH（推荐）

`Plugin/whalepet-dsh-bridge/` 是一个 **DSH Host 插件**，把 iPad 的语音/文本直接接进**本机正在运行的 DSH**：
音频走 DSH 自带的 SenseVoice（`ctx.speechToText`），会话走官方 `ctx.sessionController`（create → prompt →
wait），宠物会话是完整的 Agent（工具、检索、文件、多步执行），并出现在 DSH 会话列表里。

```
iPad App ──HTTP/WS(16kHz PCM)──▶ whalepet-bridge 插件（0.0.0.0:8787）
                                   ├─ ctx.speechToText   SenseVoice（本地 CPU）
                                   ├─ 唤醒词 + 会话状态机
                                   └─ ctx.sessionController = 完整 Agent
```

- 协议与 `Server/` 的 Python 桥接**完全一致**，iPad 端不用改代码，只改设置里的地址/令牌。
- 宠物会话默认 `workspace-write`：能读写 `~/.dsh/whalepet/workspace`、跑命令、联网检索；
  插件在它自己的 scope 里加一段"鲸鱼娘"人格，回复去掉 Markdown 后交给 iPad 的 TTS。
- 安装/配置/安全说明见 [Plugin/whalepet-dsh-bridge/README.md](Plugin/whalepet-dsh-bridge/README.md)；
  DSH Host API 与 bundle 打包契约调研见 [Plugin/docs/](Plugin/docs/)。

**会话不用管**：宠物只有一个长期会话，空闲自动归档（列表里看不见），每 24 小时自动换新会话，
说话前自动恢复——没有"新建会话/清理会话"这回事。

> PM2 部署（可选）：`Tools/deploy/dsh-web.sh` 是直连本地安装的 dsh 入口（不再每次 npx 解析 registry），
> `Tools/deploy/pm2-switch.sh` 是一次性切换脚本（带失败回退）。见脚本头部注释。

> 旧的 `Server/` Python 桥接仍保留：它自带 faster-whisper + 独立 DSH runtime，适合"隔离宠物"的部署形态；
> 接工作 DSH 时用插件版。

## 语音对话部署速览

1. 服务器（内网 Linux/macOS，Python 3.10+）：

```bash
cd Server
python -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env   # 填 WHALEPET_TOKEN / DSH_HOME / WHALEPET_WORKSPACE / DEEPSEEK_API_KEY
python run.py
```

2. iPad：⚙️ 设置 → 填 `http://服务器IP:8787` 和令牌 → 保存并测试 → 说"小鲸小鲸"。

细节（权限模型、TLS、systemd）见 [Server/README.md](Server/README.md)。
注意：DSH 处于开发者预览期，默认会话权限为 **read-only**；语音唤醒仅 App 前台有效。

## 目录结构

```
├── project.yml                  # XcodeGen 工程描述（唯一事实源）
├── Server/                      # 内网桥接服务器（aiohttp + faster-whisper + DSH SDK）
│   ├── whalepet_bridge/         # 服务主体（文本/唤醒逻辑可单测）
│   ├── tests/                   # 27 个纯逻辑单元测试
│   ├── requirements.txt / .env.example / run.py
│   └── README.md                # 部署与协议文档
├── WhalePet/
│   ├── Pet/                     # 纯逻辑 + 渲染节点
│   │   ├── PetState.swift       # 状态枚举（含语音三态）+ 数值模型（可单测）
│   │   ├── PetBrain.swift       # 行为调度状态机（可单测）
│   │   ├── PetStore.swift       # JSON 持久化（可单测）
│   │   ├── Dialogue.swift       # 台词库
│   │   └── PetNode.swift        # 状态立绘切换 + SKAction 运动动画
│   ├── Scenes/PetScene.swift    # 主场景：交互/移动/特效/帧循环/语音状态
│   ├── Networking/DSHClient.swift  # HTTP 健康检查/聊天 + WebSocket 音频通道
│   ├── Voice/VoiceController.swift # 麦克风采集/16k 转码/本地 TTS/状态机
│   ├── UI/                      # SpeechBubbleNode / HUDNode（纯 SK）
│   ├── Support/                 # AppDelegate / ViewController / ServerSettings / Info.plist
│   └── Resources.xcassets       # 程序化生成的全部素材
├── WhalePetTests/               # 23 个纯逻辑单元测试（宠物状态机 + 服务器设置）
├── Tools/art/import_upstream.py # 上游立绘导入（dsh-whale-musume, MIT）
├── Tools/art/generate_assets.py # 背景/特效生成器（原创）
├── Tools/scripts/check.py       # Linux 静态自检
└── docs/                        # 预览图 / 设计说明 / 第三方声明
```

## 参考与致谢

- **角色立绘**：[dsh-whale-musume](https://github.com/Sutera-Diffusus/dsh-whale-musume)（MIT）——直接使用了其 10 张状态立绘，声明见 [THIRD-PARTY-NOTICES.md](docs/THIRD-PARTY-NOTICES.md)。
- **设计思路**（未复制代码/素材）：[VPet-Simulator](https://github.com/LorisYounger/VPet) 的状态+数值架构、[Shijima](https://github.com/pixelomer/Shijima-Qt) 的 Shimeji 行为划分、[N.E.K.O](https://github.com/Project-N-E-K-O/N.E.K.O) 的主动陪伴交互。

详见 [docs/ACKNOWLEDGEMENTS.md](docs/ACKNOWLEDGEMENTS.md)。

## License

代码与原创素材：MIT（见 [LICENSE](LICENSE)）。
第三方立绘：MIT（dsh-whale-musume，见 [docs/LICENSE-dsh-whale-musume.txt](docs/LICENSE-dsh-whale-musume.txt)）。