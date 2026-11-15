import 'dart:math';

import 'pet_state.dart';

/// 自主行为调度器：决定宠物在没有用户输入时做什么。
///
/// 规则来源：docs/CROSS_PLATFORM.md §6.1：
///   - `drag` / `listening` / `thinking` / `speaking` 不被随机调度打断；
///   - 自主状态只在 `idle` / `walk` / `swim` / `sleep` 中选择；
///   - **随机源必须注入**，不得在枚举属性里直接调用全局随机数，
///     这样同一 seed 的序列可以重放（便于测试与录像复盘）。
class PetBehavior {
  /// 创建调度器。[random] 必须是外部注入的（通常是 `Random(seed)`）。
  PetBehavior({required Random random, this.idleToAutonomousChance = 0.02})
      : _random = random;

  final Random _random;

  /// 从待机切到其它自主状态的概率（每帧）。
  final double idleToAutonomousChance;

  /// 推进一帧，返回下一个状态。
  ///
  /// - [isDragging]：用户正拖着宠物，随机调度不得打断；
  /// - [isBusy]：语音流程占用中（listening / thinking / speaking），不得打断；
  /// - [dt]：帧间隔（秒），本调度器只用作调用方的时间参考，不参与概率计算。
  PetState nextAutonomousState(
    PetState current, {
    required bool isDragging,
    required bool isBusy,
    double dt = 0.0,
  }) {
    // 拖拽与语音状态优先：原样返回，不做任何随机决定。
    if (isDragging || isBusy) return current;
    // 非自主状态（例如 happy / eat / play 的收尾）由场景控制器负责，这里不接管。
    if (!kAutonomousStates.contains(current)) return current;

    if (current == PetState.idle) {
      if (_random.nextDouble() >= idleToAutonomousChance) return PetState.idle;
      return _pickOtherThan(PetState.idle);
    }

    // 在自主状态之间切换时，同样有概率先回到待机。
    if (_random.nextDouble() < idleToAutonomousChance) return PetState.idle;
    return _pickOtherThan(current);
  }

  /// 从自主状态里挑一个（排除 [exclude]）。
  PetState _pickOtherThan(PetState exclude) {
    final List<PetState> candidates =
        kAutonomousStates.where((PetState state) => state != exclude).toList();
    return candidates[_random.nextInt(candidates.length)];
  }
}
