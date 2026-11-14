# 参考与致谢

本项目（鲸鱼娘 DSH 宠物）为**原创实现**：全部 Swift 代码与美术素材（程序化生成）均在本仓库内完成，未复制任何第三方项目的代码、贴图或音频。以下开源项目仅在**设计思路**层面提供参考：

## VPet-Simulator（虚拟桌宠模拟器）
- 仓库：https://github.com/LorisYounger/VPet
- 许可证：GPL-3.0
- 参考点：
  - 「状态机 + 数值（饱食/心情/体力）+ 互动触发」的桌宠三层架构；
  - 摸头/投喂/提起等互动与动画状态的映射关系；
  - 低状态时宠物"变蔫、求关注"的情感化反馈。
- 差异：VPet 面向 Windows/WPF 且支持创意工坊与 200+ 动画；本项目面向 iPadOS 15 单设备，用 SpriteKit 分层部件 + 程序化动画替代序列帧，规模刻意精简。

## Shijima / libshijima（Shimeji 系）
- 仓库：https://github.com/pixelomer/Shijima-Qt （及 Shijima-iOS / Shijima-Android / Shijima-Web）
- 许可证：GPL-3.0
- 参考点：Shimeji 行为脚本（走动/攀爬/拖拽/落下）的状态划分方式。
- 差异：Shijima-iOS 通过越狱插件把宠物注入系统桌面；iOS 沙箱不允许正规 App 这样做，因此本项目改为**全屏 App 内海底场景**，这是 iPadOS 15 上无需越狱的唯一合规形态。

## N.E.K.O
- 仓库：https://github.com/Project-N-E-K-O/N.E.K.O
- 参考点：桌宠主动搭话、按心情选台词的陪伴感设计。
- 差异：N.E.K.O 依赖 LLM 与 Live2D；本项目台词为本地静态语料库，零网络、零推理开销，适配 A8 老设备。

## 其他
- Apple SpriteKit / SKAction：系统框架，程序化动画的基础。
- Pillow：素材生成脚本使用的 Python 图像库（BSD 类许可）。

若未来引入上述任何项目的代码或素材，须遵守其 GPL-3.0 条款（整体开源并保留声明）；当前版本不存在此义务。