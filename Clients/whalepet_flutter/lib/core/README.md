# WhalePet 跨平台核心（阶段 B）

本目录是 Android / macOS / Windows 三端共享的**纯 Dart** 宠物核心。
规则出处：[`docs/CROSS_PLATFORM.md`](../../../../docs/CROSS_PLATFORM.md) §6（宠物核心）、§11.1（本地存档）、§12.1（测试）。

## 边界

```text
UI → core 接口 → platform 实现
core 不得 import Flutter SDK 或原生窗口代码
platform 不得反向修改 UI widget
```

因此本包 `pubspec.yaml` **不依赖 flutter**，只依赖 `dart:*`；这样核心逻辑可以在任何装了 Dart SDK
的机器上直接跑单测，不必先装 Flutter、也不必起模拟器。

## 文件职责

| 文件 | 职责 |
|---|---|
| [`pet/pet_state.dart`](pet/pet_state.dart) | 状态枚举与分类：自主状态（idle/walk/swim/sleep）、忙碌状态（drag/listening/thinking/speaking） |
| [`pet/pet_vitals.dart`](pet/pet_vitals.dart) | 饱食/心情/精力的衰减、钳位、离线结算与互动（投喂/摸头/玩耍） |
| [`pet/pet_behavior.dart`](pet/pet_behavior.dart) | 自主行为调度器；随机源必须注入，保证同 seed 可重放 |
| [`storage/pet_save.dart`](storage/pet_save.dart) | 存档 schema v1 的编解码与版本校验（时间统一 UTC ISO-8601） |
| [`storage/pet_save_store.dart`](storage/pet_save_store.dart) | 文件持久化：原子写、损坏备份后回落默认值 |

## 数值规则（照抄现有 iPad 实现，不在重写时调平衡）

| 项目 | 规则 |
|---|---|
| 饱食 | 清醒和睡眠均按约 4 小时从 100 降至 0 |
| 心情 | 约 6 小时从 100 降至 0；饱食低于 25 时双倍衰减 |
| 精力 | 非睡眠约 5 小时耗尽；睡眠每秒恢复 1.2 |
| 离线结算 | 单次最多结算 6 小时 |
| 投喂 | 饱食 +22、心情 +6；睡眠时拒绝，饱食已满也拒绝 |
| 摸头 | 心情 +10 |
| 玩耍 | 心情 +8、精力 -5；睡眠时拒绝 |

两个容易写错的细节，本实现已处理：

1. **帧 dt 钳到 0.1 秒**（`tick`），但**离线时间不能靠逐帧补偿**，必须走 `settleOffline()`。
2. **心情双倍衰减按小步长分段计算**：每步先扣饱食，再用更新后的饱食值判断是否饥饿。
   若一次结算几小时却用「结算前的饱食」算完整段心情，跨过 25 阈值时结果会偏高。

## 存档格式（schema v1）

```json
{
  "schema_version": 1,
  "vitals": { "satiety": 80.0, "mood": 80.0, "energy": 90.0 },
  "last_tick_utc": "2026-11-15T12:00:00.000Z",
  "pet_name": "小鲸",
  "total_feeds": 0,
  "total_pets": 0,
  "born_at_utc": "2026-11-15T08:00:00.000Z"
}
```

- 时间一律 UTC ISO-8601，不用各语言默认的 Date JSON 编码；
- 写入走 `.tmp` + `rename` 原子替换；
- 解析失败先把坏文件改名成 `pet_save.json.corrupt-<毫秒时间戳>`，再回落默认值；
- 高于当前支持的 `schema_version` 直接报错，不静默丢数据；
- 桌面窗口位置、语音设置属于**另一个设置文件**，不混进数值存档。

## 如何验证

```bash
cd Clients/whalepet_flutter
dart pub get
dart test
```

覆盖的行为（对应架构文档 §12.1）：

- 数值衰减、上下限、dt 钳位、6 小时离线结算上限；
- 饥饿阈值分段衰减；
- 睡眠时不能投喂和玩耍、饱食满时不能投喂；
- 拖拽与语音状态不被随机调度覆盖；
- 固定随机源时状态序列可重放；
- 存档往返、UTC 规范化、损坏恢复与备份、原子写不残留临时文件。

## 当前状态与已知风险

> **本机没有安装 Dart / Flutter SDK，这批 Dart 代码尚未执行过 `dart test`。**

已做的替代验证：

- 用脚本核对了全部文件的括号配平，并确认 `core/` 下没有任何 `package:flutter/` 依赖；
- 用 Python 复刻了 `PetVitals` 的衰减算法，逐条复算了测试里的期望值
  （过程中发现并修正了一处错误的离线结算断言）。

仍需在装有 Dart SDK 的机器上确认的点：

- 语法与类型检查（`dart analyze`）；
- `dart test` 全绿，特别是浮点容差（`closeTo`）在 Dart double 下的实际表现；
- `PetSaveStore` 在 Windows 上的 `rename` 覆盖语义（POSIX 已按原子替换设计，
  Windows 上目标文件存在时 `rename` 可能失败，需要改用先删后移或 `File.copy` + `delete`）。

## 下一步（阶段 C 起）

本包目前只有核心，没有 UI、没有网络、没有语音。后续按架构文档推进：

1. `core/agent/`：`AgentGateway` + `/api/agent` 协议客户端（服务端已实现，见插件 0.4.0）；
2. `core/voice/`：`VoiceSessionCoordinator` 状态机 + `SpeechQueue`（纯 Dart，可用假适配器测试）；
3. `platform/`：各端音频采集、KWS/ASR（sherpa-onnx）、系统 TTS、透明窗口、安全存储；
4. `ui/`：Android 全屏场景与桌面桌宠场景控制器。
