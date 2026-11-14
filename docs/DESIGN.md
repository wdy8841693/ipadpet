# 设计说明

## 为什么是"全屏 App"而不是"系统桌面宠物"

iOS/iPadOS 沙箱不允许 App 在其他应用之上绘制（无 Android `SYSTEM_ALERT_WINDOW` 等价物）。
Shijima-iOS 那类"真桌宠"依赖越狱注入 SpringBoard。iPad mini 4 虽可越狱（palera1n 等），
但本项目选择**免越狱、可签名分发**的正规路线：全屏海底场景 + 全屏独占
（`UIRequiresFullScreen = true`，顺带禁掉 Split View 以降低老设备内存压力）。

## 架构

```
┌────────────────────────────────────────────┐
│ PetViewController (UIKit, 30fps SKView)    │
│  ├─ VoiceController ← 采集/TTS/状态机       │
│  │   └─ DSHClient  ← HTTP + WebSocket      │
│  │       └─ ServerSettings ← URL/Keychain   │
│  └─ PetScene (SpriteKit)                   │
│      ├─ PetBrain   ← 纯逻辑状态机(可单测)   │
│      ├─ PetVitals  ← 数值模型(可单测)       │
│      ├─ PetStore   ← JSON 原子持久化        │
│      ├─ PetNode    ← 分层部件 + SKAction    │
│      ├─ HUDNode / SpeechBubbleNode (纯 SK) │
│      └─ Dialogue   ← 本地台词库             │
└────────────────────────────────────────────┘
```

- **逻辑与渲染分离**：PetBrain/PetVitals/PetStore/ServerSettings 不 import
  UIKit/SpriteKit（除必要框架），23 个 XCTest 用例直接覆盖衰减曲线、离线结算上限、
  状态超时、拖拽优先级、存档往返、语音状态机与服务器 URL 校验。
- **随机源泛型化**：`tick<R: RandomNumberGenerator>` 避免 existential 开销，
  也兼容 Xcode 14（Swift 5.7）——iPadOS 15 时代的主流工具链。

## 状态机

自主状态：idle / walk / swim / sleep（加权随机，精力低时睡眠权重 8→60）。
事件状态：happy(摸头) / eat(投喂) / play(玩球) / drag(拖拽)。
语音状态：listening(聆听) / thinking(思考) / speaking(播报)——由 VoiceController
事件驱动进出，不参与随机调度。
drag 与语音状态永不超时，只能由外部事件结束；事件状态结束后回到自主调度。

## 数值曲线（刻意放缓，陪伴不是负担）

| 数值 | 衰减速率 | 恢复 |
|---|---|---|
| 饱食 | 100 → 0 约 4h | 投喂 +22 |
| 心情 | 100 → 0 约 6h（饥饿时×2） | 摸头 +10 / 玩耍 +8 |
| 精力 | 清醒 100 → 0 约 5h | 睡眠 +1.2/s |

离线结算封顶 6h：长期不打开也不会出现"全 0 惨状"，回来先待机打招呼。

## 角色素材：直接用开源成品立绘

角色立绘来自 [dsh-whale-musume](https://github.com/Sutera-Diffusus/dsh-whale-musume)（MIT）：
蓝发女仆裙 Q 版鲸鱼娘（鲸尾+鳍耳），完成度远高于程序化绘制。
每个状态一张 512×512 RGBA webp，导入脚本裁透明边、统一缩放到 420pt 高、
底部对齐放入 420×420 画布转 PNG（`Tools/art/import_upstream.py`）。

状态映射：idle→idle-cute / walk→tail-swing / swim→daily-stretch /
happy→react-head / eat→eat / sleep→sleep / drag→pick-up / play→celebrate /
低落覆盖→failure / 心情极好随机→greet。

## 渲染与动画

- **整图切换 + 运动动画**：每状态一张立绘，SKAction 负责漂浮(bob)、
  走路摇摆(waddle)、游动 sway、庆祝弹跳+Q弹、进食点头、睡觉呼吸、拖拽晃荡。
  不做序列帧（上游是静态立绘），运动变换足以表达"活着的"感觉。
- 单 sprite + `rig` 运动容器：根节点位置只由场景控制，
  避免 SKAction 与拖拽/寻路互相覆盖坐标。
- 锚点底边中心：`position` 即脚底，`floorStandY()` 直接踩沙地。
- 朝向翻转用根节点 xScale 符号；`baseScale.didSet` 保留符号。
- 显存：10 张 420×420 RGBA ≈ 7MB + 背景 3MB ≈ 9.7MB，A8 预算内。
- `ignoresSiblingOrder = true` 减少每帧排序。

## A8 性能要点清单

1. 30fps 上限；2. 无物理引擎；3. 无 SKEmitterNode（12 个复用 ShapeNode 气泡）；
4. HUD 进度条路径按整数量化缓存，不每帧重建 CGPath；
5. 背景为预渲染渐变 PNG，不用 SKEffectNode 实时模糊；
6. 台词气泡 DispatchWorkItem 定时隐藏，新台词取消旧任务；
7. 存档 15s 节流 + 退后台立即写；
8. 立绘统一 420pt 画布（@2x 设备上 840px < 源 512px 的 2 倍放大可接受，
   且 mini 4 为非 Retina 级 1024×768@2x=2048×1536，实际渲染尺寸约 520px，接近源分辨率）；
9. 语音采集/转码在音频线程，WS 发送带背压上限（约 47s 音频）防弱网内存堆积；
   ASR 与 LLM 全在服务器，A8 只承担 16kHz 重采样与 TTS 播报。

## 语音与 DSH 架构（v1.2.0）

```
iPad (前台)                          内网无头服务器 (Server/)
┌────────────────────────┐          ┌─────────────────────────────────┐
│ AVAudioEngine 采集      │  16kHz   │ webrtcvad 20ms 帧切句（pre-roll） │
│ AVAudioConverter 转码   │──PCM──▶  │ faster-whisper 中文 ASR          │
│ URLSessionWebSocketTask │  (WS)    │ 唤醒词匹配（小鲸小鲸+同音别名）     │
│ AVSpeechSynthesizer 播报│◀─JSON──  │ DeepSeekHarness.run() (官方 SDK) │
└────────────────────────┘  事件     │  - 独立 DSH_HOME / 受限工作目录   │
      播报时 playback_start/end      │  - 新会话默认 /permission read-only│
      → 服务器闭麦防自触发            └─────────────────────────────────┘
```

- **为什么唤醒词在服务器**：Apple 的 SFSpeechRecognizer 有约 1 分钟的识别
  时长限制和配额，不适合常驻轮询；Porcupine 等商用唤醒引擎当前 iOS SDK
  要求 iOS 16+，mini 4（iPadOS 15）装不了。服务器 VAD+ASR 方案零专用模型、
  可自定义唤醒词，代价是前台才可用——这本来就是 iOS 沙箱的边界。
- **宠物状态机扩展**：listening / thinking / speaking 三个语音态，
  `baseDuration = nil`（不超时、由 VoiceController 事件结束），
  复用现有立绘（happy/swim/greet）+ 轻量运动动画，不新增纹理。
- **隐私**：音频只走局域网；令牌存 Keychain；ATS 仅放行本地网络
  （`NSAllowsLocalNetworking`，未开 `NSAllowsArbitraryLoads`）。
- **会话连续性**：每台 iPad 固定 session_id（`pet-xxxxxxxx`），
  DSH 会话日志持久化在服务器 DSH_HOME，可跨启动恢复上下文。

## 已知限制 / 后续路线

- 语音唤醒仅 App 前台有效；退后台自动闭麦（iOS 不允许第三方后台常听）。
- 服务器 ASR 默认 small/int8 CPU 模型；追求更低延迟可换 SenseVoice-ONNX
  或 GPU float16（改环境变量即可）。
- DSH 处于开发者预览期（官方警告会有破坏性变更）：桥接层把 DSH 调用隔离在
  `Server/whalepet_bridge/dsh.py` 单文件，升级 SDK 只需改这一处。
- 台词语料仍是静态的；接 DSH 后气泡已可显示动态回复，后续可做性格化提示词。
- 未做 iCloud 同步（单机存档已够用；扩展点：PetStore 换 NSUbiquitousKeyValueStore）。
- 未做音效（鲸歌/泡泡声），扩展点：SKAction.playSoundFileNamed，注意包体与内存。
- Live2D 风格升级需 Cubism SDK（arm64 支持 iOS 12+），但会显著增加包体与 CPU，
  在 mini 4 上不推荐；当前分层部件方案是性能/表现力的平衡点。