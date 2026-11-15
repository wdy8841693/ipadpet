import 'pet_state.dart';

/// 宠物的三项数值：饱食、心情、精力。
///
/// 规则来源：docs/CROSS_PLATFORM.md §6.2（数值规则）。第一版沿用现有 iPad 实现的数值，
/// 跨平台重写时**不顺便调平衡**。
///
/// | 项目 | 规则 |
/// |---|---|
/// | 饱食 | 清醒和睡眠均按约 4 小时从 100 降至 0 |
/// | 心情 | 约 6 小时从 100 降至 0；饱食低于 25 时双倍衰减 |
/// | 精力 | 非睡眠约 5 小时耗尽；睡眠每秒恢复 1.2 |
/// | 离线结算 | 单次最多结算 6 小时 |
/// | 投喂 | 饱食 +22、心情 +6；睡眠时拒绝 |
/// | 摸头 | 默认心情 +10 |
/// | 玩耍 | 心情 +8、精力 -5；睡眠时拒绝 |
class PetVitals {
  /// 创建一组数值（自动钳到 0~100）。
  PetVitals({
    double satiety = 100.0,
    double mood = 100.0,
    double energy = 100.0,
  })  : satiety = _clamp(satiety),
        mood = _clamp(mood),
        energy = _clamp(energy);

  /// 数值上限。
  static const double maxValue = 100.0;

  /// 数值下限。
  static const double minValue = 0.0;

  /// 饱食衰减：约 4 小时从 100 降到 0（清醒与睡眠同速）。
  static const double kSatietyDecayPerSecond = 100.0 / (4.0 * 3600.0);

  /// 心情衰减：约 6 小时从 100 降到 0。
  static const double kMoodDecayPerSecond = 100.0 / (6.0 * 3600.0);

  /// 饱食低于该值时，心情衰减翻倍。
  static const double kHungryThreshold = 25.0;

  /// 精力衰减：非睡眠约 5 小时耗尽。
  static const double kEnergyDecayPerSecond = 100.0 / (5.0 * 3600.0);

  /// 睡眠时每秒恢复的精力。
  static const double kEnergyRecoverPerSecond = 1.2;

  /// 单帧 dt 上限（秒）：防止卡顿后一次扣掉太多。
  static const double kMaxFrameDeltaSeconds = 0.1;

  /// 单次离线结算最多结算的小时数。
  static const double kMaxOfflineSettleHours = 6.0;

  /// 饱食（0~100）。
  double satiety;

  /// 心情（0~100）。
  double mood;

  /// 精力（0~100）。
  double energy;

  /// 饱食是否低于阈值（心情会双倍衰减）。
  bool get isHungry => satiety < kHungryThreshold;

  /// 按帧推进数值。
  ///
  /// [dt] 会被钳到 [kMaxFrameDeltaSeconds]；饱食先衰减，再用**更新后的饱食值**
  /// 判断本帧心情是否双倍衰减。
  void tick(double dt, {required bool sleeping}) {
    _advance(_clampDelta(dt), sleeping: sleeping);
  }

  /// 离线结算：单次最多结算 [kMaxOfflineSettleHours] 小时。
  ///
  /// 离线时间不能靠逐帧补偿（会把几小时压进一帧），必须单独结算。
  void settleOffline(Duration elapsed) {
    final double seconds = elapsed.inMicroseconds / 1000000.0;
    final double maxSeconds = kMaxOfflineSettleHours * 3600.0;
    final double capped = seconds > maxSeconds ? maxSeconds : seconds;
    _advance(capped <= 0 ? 0.0 : capped, sleeping: false);
  }

  /// 投喂：饱食 +22、心情 +6。
  ///
  /// 睡眠中拒绝；饱食已满也拒绝。拒绝时**不改变任何数值**。
  bool feed({bool sleeping = false}) {
    if (sleeping) return false;
    if (satiety >= maxValue) return false;
    satiety = _clamp(satiety + 22.0);
    mood = _clamp(mood + 6.0);
    return true;
  }

  /// 摸头：心情 +10。
  bool petHead() {
    mood = _clamp(mood + 10.0);
    return true;
  }

  /// 玩耍：心情 +8、精力 -5。睡眠中拒绝。
  bool play({bool sleeping = false}) {
    if (sleeping) return false;
    mood = _clamp(mood + 8.0);
    energy = _clamp(energy - 5.0);
    return true;
  }

  /// 复制一份（用于存档或状态快照）。
  PetVitals copy() => PetVitals(satiety: satiety, mood: mood, energy: energy);

  /// 序列化为 JSON 片段。
  Map<String, dynamic> toJson() => <String, dynamic>{
        'satiety': satiety,
        'mood': mood,
        'energy': energy,
      };

  /// 从 JSON 片段还原（缺字段时用默认值）。
  factory PetVitals.fromJson(Map<String, dynamic> json) => PetVitals(
        satiety: _readDouble(json['satiety'], fallback: maxValue),
        mood: _readDouble(json['mood'], fallback: maxValue),
        energy: _readDouble(json['energy'], fallback: maxValue),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PetVitals &&
          other.satiety == satiety &&
          other.mood == mood &&
          other.energy == energy;

  @override
  int get hashCode => Object.hash(satiety, mood, energy);

  @override
  String toString() => 'PetVitals(satiety: $satiety, mood: $mood, energy: $energy)';

  // -- 内部 ---------------------------------------------------------------

  /// 真正推进数值（不做 dt 钳位，离线结算要用）。
  ///
  /// 心情衰减按**小步长**推进：每步先扣饱食，再用更新后的饱食值决定这一步是否双倍衰减。
  /// 否则一次结算几小时会用「结算前的饱食」算完整段心情，跨过饥饿阈值时结果不对。
  void _advance(double dt, {required bool sleeping}) {
    if (dt <= 0) return;
    const double stepSeconds = 1.0;
    double remaining = dt;
    while (remaining > 0) {
      final double step = remaining > stepSeconds ? stepSeconds : remaining;
      remaining -= step;

      satiety = _clamp(satiety - kSatietyDecayPerSecond * step);
      if (sleeping) {
        energy = _clamp(energy + kEnergyRecoverPerSecond * step);
      } else {
        energy = _clamp(energy - kEnergyDecayPerSecond * step);
      }
      // 阈值判断用更新后的饱食值。
      final double moodRate = kMoodDecayPerSecond * (isHungry ? 2.0 : 1.0);
      mood = _clamp(mood - moodRate * step);
    }
  }

  static double _clamp(double value) {
    if (value.isNaN) return minValue;
    if (value < minValue) return minValue;
    if (value > maxValue) return maxValue;
    return value;
  }

  static double _clampDelta(double dt) {
    if (dt.isNaN || dt <= 0) return 0.0;
    if (dt > kMaxFrameDeltaSeconds) return kMaxFrameDeltaSeconds;
    return dt;
  }

  static double _readDouble(Object? value, {required double fallback}) {
    if (value is num) return value.toDouble();
    return fallback;
  }
}

/// 睡眠状态判断的小工具：与 [PetState] 的关系由上层场景控制器决定。
bool isSleepingState(PetState state) => state == PetState.sleep;
