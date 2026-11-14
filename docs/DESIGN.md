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
│  └─ PetScene (SpriteKit)                   │
│      ├─ PetBrain   ← 纯逻辑状态机(可单测)   │
│      ├─ PetVitals  ← 数值模型(可单测)       │
│      ├─ PetStore   ← JSON 原子持久化        │
│      ├─ PetNode    ← 分层部件 + SKAction    │
│      ├─ HUDNode / SpeechBubbleNode (纯 SK) │
│      └─ Dialogue   ← 本地台词库             │
└────────────────────────────────────────────┘
```

- **逻辑与渲染分离**：PetBrain/PetVitals/PetStore 不 import UIKit/SpriteKit，
  13 个 XCTest 用例直接覆盖衰减曲线、离线结算上限、状态超时、拖拽优先级、存档往返。
- **随机源泛型化**：`tick<R: RandomNumberGenerator>` 避免 existential 开销，
  也兼容 Xcode 14（Swift 5.7）——iPadOS 15 时代的主流工具链。

## 状态机

自主状态：idle / walk / swim / sleep（加权随机，精力低时睡眠权重 8→60）。
事件状态：happy(摸头) / eat(投喂) / play(玩球) / drag(拖拽)。
drag 永不超时，只能由 touchesEnded/Cancelled 结束；事件状态结束后回到自主调度。

## 数值曲线（刻意放缓，陪伴不是负担）

| 数值 | 衰减速率 | 恢复 |
|---|---|---|
| 饱食 | 100 → 0 约 4h | 投喂 +22 |
| 心情 | 100 → 0 约 6h（饥饿时×2） | 摸头 +10 / 玩耍 +8 |
| 精力 | 清醒 100 → 0 约 5h | 睡眠 +1.2/s |

离线结算封顶 6h：长期不打开也不会出现"全 0 惨状"，回来先待机打招呼。

## 渲染与动画

- 部件分层（尾/鳍/身/鳍冠/四套表情/腮红/喷水），zPosition 固定排序，
  `ignoresSiblingOrder = true` 减少每帧排序。
- 全部动画为 SKAction 组合：漂浮(bob)、尾摆、鳍拍、眨眼(压扁脸部)、咀嚼、喷水。
  **零序列帧** → 显存只有十几张小 PNG。
- 漂浮/摇晃作用于内部 `rig` 容器，根节点位置只由场景控制，
  避免 SKAction 与拖拽/寻路互相覆盖坐标。
- 朝向翻转用根节点 xScale 符号；`baseScale.didSet` 保留符号。

## A8 性能要点清单

1. 30fps 上限；2. 无物理引擎；3. 无 SKEmitterNode（12 个复用 ShapeNode 气泡）；
4. HUD 进度条路径按整数量化缓存，不每帧重建 CGPath；
5. 背景为预渲染渐变 PNG，不用 SKEffectNode 实时模糊；
6. 台词气泡 DispatchWorkItem 定时隐藏，新台词取消旧任务；
7. 存档 15s 节流 + 退后台立即写。

## 已知限制 / 后续路线

- 台词为静态语料；如需 LLM 聊天，建议走局域网 API 而非设备端推理（A8 跑不动）。
- 未做 iCloud 同步（单机存档已够用；扩展点：PetStore 换 NSUbiquitousKeyValueStore）。
- 未做音效（鲸歌/泡泡声），扩展点：SKAction.playSoundFileNamed，注意包体与内存。
- Live2D 风格升级需 Cubism SDK（arm64 支持 iOS 12+），但会显著增加包体与 CPU，
  在 mini 4 上不推荐；当前分层部件方案是性能/表现力的平衡点。