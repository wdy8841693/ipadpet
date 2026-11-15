import 'package:test/test.dart';
import 'package:whalepet_flutter/core/pet/pet_vitals.dart';

void main() {
  group('PetVitals 数值规则', () {
    test('tick 的 dt 钳到 0.1 秒', () {
      final PetVitals vitals = PetVitals();
      final double before = vitals.satiety;
      vitals.tick(5.0, sleeping: false);
      expect(before - vitals.satiety,
          closeTo(PetVitals.kSatietyDecayPerSecond * 0.1, 1e-9));
    });

    test('饱食约 4 小时从 100 降到 0（清醒与睡眠同速）', () {
      final PetVitals awake = PetVitals();
      awake.settleOffline(const Duration(hours: 4));
      expect(awake.satiety, closeTo(0.0, 1e-6));

      // 睡眠只影响精力：饱食与清醒同速（4 小时 = 144000 个 0.1 秒帧）。
      final PetVitals asleep = PetVitals();
      for (int i = 0; i < 144000; i += 1) {
        asleep.tick(0.1, sleeping: true);
      }
      expect(asleep.satiety, closeTo(0.0, 1e-3));
      // 睡眠时精力不降反升。
      expect(asleep.energy, greaterThan(100.0 - 0.001));
    });

    test('心情约 6 小时从 100 降到 0', () {
      expect(PetVitals.kMoodDecayPerSecond * 6 * 3600, closeTo(100.0, 1e-6));
    });

    test('精力：非睡眠约 5 小时耗尽，睡眠每秒恢复 1.2', () {
      expect(PetVitals.kEnergyDecayPerSecond * 5 * 3600, closeTo(100.0, 1e-6));

      // 从半满开始睡：dt 被钳到 0.1 秒 → 每帧 +0.12。
      final PetVitals vitals = PetVitals(energy: 50.0);
      vitals.tick(10.0, sleeping: true);
      expect(vitals.energy, closeTo(50.0 + 0.12, 1e-9));

      // 清醒时同样一帧要扣精力。
      final PetVitals awake = PetVitals(energy: 50.0);
      awake.tick(10.0, sleeping: false);
      expect(awake.energy, lessThan(50.0));
    });

    test('饱食低于 25 时心情双倍衰减（用更新后的饱食判断）', () {
      final PetVitals hungry = PetVitals(satiety: 24.0, mood: 100.0);
      final PetVitals full = PetVitals(satiety: 90.0, mood: 100.0);
      hungry.tick(1.0, sleeping: false);
      full.tick(1.0, sleeping: false);
      final double hungryDrop = 100.0 - hungry.mood;
      final double fullDrop = 100.0 - full.mood;
      expect(hungryDrop, closeTo(PetVitals.kMoodDecayPerSecond * 2 * 0.1, 1e-9));
      expect(fullDrop, closeTo(PetVitals.kMoodDecayPerSecond * 0.1, 1e-9));
      expect(hungryDrop, greaterThan(fullDrop));
    });

    test('数值永远在 0~100 之间', () {
      final PetVitals vitals = PetVitals();
      vitals.settleOffline(const Duration(days: 30));
      expect(vitals.satiety, greaterThanOrEqualTo(0.0));
      expect(vitals.mood, greaterThanOrEqualTo(0.0));
      expect(vitals.energy, greaterThanOrEqualTo(0.0));
      expect(vitals.satiety, lessThanOrEqualTo(100.0));
      expect(vitals.mood, lessThanOrEqualTo(100.0));
      expect(vitals.energy, lessThanOrEqualTo(100.0));
    });

    test('离线结算单次最多 6 小时', () {
      final PetVitals sixHours = PetVitals();
      final PetVitals oneDay = PetVitals();
      sixHours.settleOffline(const Duration(hours: 6));
      oneDay.settleOffline(const Duration(days: 1));
      // 超过 6 小时按 6 小时算：两者结果必须完全一致。
      expect(oneDay.satiety, sixHours.satiety);
      expect(oneDay.mood, sixHours.mood);
      expect(oneDay.energy, sixHours.energy);

      // 未触底的区间可以精确核对：1 小时扣掉 1/4 的饱食。
      final PetVitals oneHour = PetVitals();
      oneHour.settleOffline(const Duration(hours: 1));
      expect(oneHour.satiety, closeTo(75.0, 1e-6));
      // 6 小时会把饱食扣穿，钳到 0。
      expect(sixHours.satiety, 0.0);
    });

    test('离线结算跨过饥饿阈值时，心情按分段速率衰减', () {
      // 饱食从 30 开始：约 0.2 小时后跌破 25，之后心情双倍衰减。
      final PetVitals vitals = PetVitals(satiety: 30.0, mood: 100.0);
      vitals.settleOffline(const Duration(hours: 1));

      const double satietyRate = PetVitals.kSatietyDecayPerSecond;
      const double moodRate = PetVitals.kMoodDecayPerSecond;
      // 跌破阈值所需秒数（按 1 秒步长推进，取整）。
      final int secondsToHungry = ((30.0 - PetVitals.kHungryThreshold) / satietyRate).ceil();
      final double expectedMood =
          100.0 - moodRate * secondsToHungry - moodRate * 2 * (3600 - secondsToHungry);
      expect(vitals.mood, closeTo(expectedMood.clamp(0.0, 100.0), 0.05));
      // 若错误地全程用单倍速率，心情会明显偏高。
      expect(vitals.mood, lessThan(100.0 - moodRate * 3600));
    });

    test('投喂：饱食 +22、心情 +6；睡眠时拒绝且不改数值', () {
      final PetVitals vitals = PetVitals(satiety: 50.0, mood: 50.0);
      expect(vitals.feed(), isTrue);
      expect(vitals.satiety, closeTo(72.0, 1e-9));
      expect(vitals.mood, closeTo(56.0, 1e-9));

      final PetVitals sleeping = PetVitals(satiety: 50.0, mood: 50.0);
      expect(sleeping.feed(sleeping: true), isFalse);
      expect(sleeping.satiety, closeTo(50.0, 1e-9));
      expect(sleeping.mood, closeTo(50.0, 1e-9));
    });

    test('饱食已满时投喂被拒绝', () {
      final PetVitals vitals = PetVitals(satiety: 100.0, mood: 50.0);
      expect(vitals.feed(), isFalse);
      expect(vitals.satiety, closeTo(100.0, 1e-9));
      expect(vitals.mood, closeTo(50.0, 1e-9));
    });

    test('摸头：心情 +10', () {
      final PetVitals vitals = PetVitals(mood: 50.0);
      expect(vitals.petHead(), isTrue);
      expect(vitals.mood, closeTo(60.0, 1e-9));
    });

    test('玩耍：心情 +8、精力 -5；睡眠时拒绝', () {
      final PetVitals vitals = PetVitals(mood: 50.0, energy: 50.0);
      expect(vitals.play(), isTrue);
      expect(vitals.mood, closeTo(58.0, 1e-9));
      expect(vitals.energy, closeTo(45.0, 1e-9));

      final PetVitals sleeping = PetVitals(mood: 50.0, energy: 50.0);
      expect(sleeping.play(sleeping: true), isFalse);
      expect(sleeping.mood, closeTo(50.0, 1e-9));
      expect(sleeping.energy, closeTo(50.0, 1e-9));
    });

    test('copy 与 JSON 往返保持一致', () {
      final PetVitals vitals = PetVitals(satiety: 12.5, mood: 33.0, energy: 66.5);
      expect(vitals.copy(), vitals);
      final PetVitals restored = PetVitals.fromJson(vitals.toJson());
      expect(restored, vitals);
    });
  });
}
