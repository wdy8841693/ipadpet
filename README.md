# 鲸鱼娘 DSH 宠物 🐋

一只住在 iPad 全屏海底世界里的 Q 版蓝鲸娘桌宠。为 **iPad mini 4（A8 / 2GB RAM / iPadOS 15.8.x）** 量身打造：SpriteKit 分层部件 + 程序化动画，30fps 低功耗运行，无网络、无内购、无第三方运行时依赖。

![预览](docs/preview.png)

> DSH = **D**eep **S**ea **H**ug（深海抱抱）。她会散步、巡游、睡觉、吃小鱼干，被摸头会冒爱心，被拎起来会晕船。

## 功能

| 交互 | 效果 |
|---|---|
| 轻点鲸鱼娘 | 摸头：Q 弹挤压 + 爱心 + 心情↑ |
| 按住拖动 | 拎起来到处放（拖拽态四肢摊开） |
| 🐟 投喂 | 小鱼干飞进嘴里，饱食↑ |
| 🫧 玩耍 | 泡泡球弹跳，心情↑ 精力↓ |
| 🌙 睡觉 | 入睡恢复精力，再点唤醒 |
| ✏️ 改名 | 自定义名字（≤12 字符），台词随名字变化 |

- **数值系统**：饱食 / 心情 / 精力三条状态槽，随时间缓慢衰减；离线最多结算 6 小时，不会"一觉醒来饿死"。
- **自主行为**：加权随机状态机（待机/散步/巡游/睡觉），又饿又累时会变蔫、主动求关注。
- **台词气泡**：按场景与数值状态选句，避免连续重复。
- **持久化**：JSON 原子写入 Application Support，杀进程不丢档。
- **全方向旋转**：横竖屏自适应，`UIRequiresFullScreen` 全屏独占（老设备省内存）。

## 设备与性能预算（iPad mini 4）

| 项 | 取值 | 说明 |
|---|---|---|
| 最低系统 | iPadOS 15.0 | mini 4 最高 15.8.x，不支持 16 |
| 帧率 | 30 fps | `preferredFramesPerSecond = 30`，省电防发热 |
| 渲染 | SpriteKit 分层 PNG + SKAction | 无序列帧、无物理引擎、无 SKEffectNode |
| 纹理显存 | < 10 MB（运行时） | 全部素材含图标 ≈ 8 MB 磁盘 |
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

## 重新生成素材

所有美术均为**原创程序化绘制**（Pillow 矢量脚本），无第三方版权素材：

```bash
python3 Tools/art/generate_assets.py     # 输出到 WhalePet/Resources.xcassets
```

想换配色/造型，改 `Tools/art/generate_assets.py` 顶部的调色板与几何函数即可。

## Linux 侧自检（无需 Mac）

```bash
python3 Tools/scripts/check.py
```

校验：Swift 括号配平、工程配置（iOS 15 / 仅 iPad / 全屏）、纹理引用一致性、显存预算、测试覆盖。

## 目录结构

```
├── project.yml                  # XcodeGen 工程描述（唯一事实源）
├── WhalePet/
│   ├── Pet/                     # 纯逻辑 + 渲染节点
│   │   ├── PetState.swift       # 状态枚举 + 数值模型（可单测）
│   │   ├── PetBrain.swift       # 行为调度状态机（可单测）
│   │   ├── PetStore.swift       # JSON 持久化（可单测）
│   │   ├── Dialogue.swift       # 台词库
│   │   └── PetNode.swift        # 分层部件 + SKAction 动画
│   ├── Scenes/PetScene.swift    # 主场景：交互/移动/特效/帧循环
│   ├── UI/                      # SpeechBubbleNode / HUDNode（纯 SK）
│   ├── Support/                 # AppDelegate / ViewController / Info.plist
│   └── Resources.xcassets       # 程序化生成的全部素材
├── WhalePetTests/               # 13 个纯逻辑单元测试
├── Tools/art/generate_assets.py # 素材生成器
├── Tools/scripts/check.py       # Linux 静态自检
└── docs/                        # 预览图 / 设计说明 / 致谢
```

## 参考与致谢

本项目为原创实现，设计上参考了以下开源桌宠项目的**思路**（未复制其代码或素材）：

- [VPet-Simulator](https://github.com/LorisYounger/VPet)（GPL-3.0）：状态驱动的桌宠行为/数值/互动分层设计。
- [Shijima-iOS / libshijima](https://github.com/pixelomer/Shijima-Qt)（GPL-3.0）：Shimeji 系桌宠在 iOS 上的行为模拟思路（其 iOS 版依赖越狱注入，本项目走正规 App 路线，不适用其实现）。
- [N.E.K.O](https://github.com/Project-N-E-K-O/N.E.K.O)：桌宠"主动求关注"的情感化交互启发。

详见 [docs/ACKNOWLEDGEMENTS.md](docs/ACKNOWLEDGEMENTS.md)。

## License

MIT（见 [LICENSE](LICENSE)）。素材为本仓库脚本原创生成，可自由修改分发。