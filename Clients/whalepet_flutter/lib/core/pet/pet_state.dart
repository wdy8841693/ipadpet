/// 宠物状态集合。
///
/// 规则来源：docs/CROSS_PLATFORM.md §6.1（跨平台宠物核心设计）。
/// 约束：
///   - `drag` / `listening` / `thinking` / `speaking` 不被随机调度打断；
///   - 自主状态只在 `idle` / `walk` / `swim` / `sleep` 中选择；
///   - 语音状态由 `VoiceSessionCoordinator`（后续阶段）进入和退出。
enum PetState {
  idle,
  walk,
  swim,
  sleep,
  happy,
  eat,
  play,
  drag,
  listening,
  thinking,
  speaking;

  /// 自主状态：可被随机调度器选择。
  bool get isAutonomous =>
      const <PetState>{PetState.idle, PetState.walk, PetState.swim, PetState.sleep}.contains(this);

  /// 忙碌状态：正在被用户或语音流程占用，随机调度不得打断。
  bool get isBusy =>
      const <PetState>{PetState.drag, PetState.listening, PetState.thinking, PetState.speaking}.contains(this);
}

/// 自主状态列表（供调度器与测试使用）。
const List<PetState> kAutonomousStates = <PetState>[
  PetState.idle,
  PetState.walk,
  PetState.swim,
  PetState.sleep,
];
