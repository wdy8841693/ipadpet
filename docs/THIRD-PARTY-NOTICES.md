# 第三方素材与代码声明

本仓库包含来自第三方开源项目的素材，按各自许可使用。

## 1. dsh-whale-musume（鲸鱼娘立绘）

- 来源：https://github.com/Sutera-Diffusus/dsh-whale-musume
- 获取方式：npm 官方源 `npm pack dsh-whale-musume`（v2.5.3），
  取 `assets/generated/dsh-whale-state-*.webp`
- 许可：**MIT**（包内 `LICENSE`：Copyright (c) 2026 Sutera-Diffusus）
- 用途：iPad App「鲸鱼娘 DSH 宠物」的角色立绘

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

## 2. 设计思路参考（未使用其代码/素材）

- [VPet-Simulator](https://github.com/LorisYounger/VPet)（Apache-2.0；默认动画另有 VUP 团队版权条款）：状态机+数值+互动架构思路。
- [Shijima / libshijima](https://github.com/pixelomer/Shijima-Qt)（GPL-3.0）：Shimeji 行为划分思路。
- [N.E.K.O](https://github.com/Project-N-E-K-O/N.E.K.O)：主动陪伴交互启发。

## 3. 本仓库原创部分

- 全部 Swift 代码（状态机/数值/持久化/场景/HUD/台词）
- 背景渐变 `bg_gradient`、特效 `fx_heart` / `fx_fish`（`Tools/art/generate_assets.py` 程序化绘制）

以上原创部分按仓库根 `LICENSE`（MIT）授权。