import 'dart:convert';

import 'package:test/test.dart';
import 'package:whalepet_flutter/core/pet/pet_vitals.dart';
import 'package:whalepet_flutter/core/storage/pet_save.dart';

void main() {
  final DateTime stamp = DateTime.utc(2026, 11, 15, 12, 0, 0);

  group('PetSave 编解码', () {
    test('默认存档：满数值、零计数', () {
      final PetSave save = PetSave.defaults(now: stamp);
      expect(save.schemaVersion, PetSave.kPetSaveSchemaVersion);
      expect(save.vitals.satiety, 100.0);
      expect(save.vitals.mood, 100.0);
      expect(save.vitals.energy, 100.0);
      expect(save.totalFeeds, 0);
      expect(save.totalPets, 0);
      expect(save.petName, '小鲸');
      expect(save.lastTickUtc.isUtc, isTrue);
      expect(save.bornAtUtc.isUtc, isTrue);
    });

    test('JSON 键名与 schema 固定一致，时间是 UTC ISO-8601', () {
      final PetSave save = PetSave.defaults(now: stamp).copyWith(
        vitals: PetVitals(satiety: 80.0, mood: 70.0, energy: 90.0),
        totalFeeds: 3,
        totalPets: 5,
      );
      final Map<String, dynamic> json = jsonDecode(save.encode()) as Map<String, dynamic>;
      expect(json.keys.toSet(), <String>{
        'schema_version',
        'vitals',
        'last_tick_utc',
        'pet_name',
        'total_feeds',
        'total_pets',
        'born_at_utc',
      });
      expect(json['schema_version'], 1);
      expect(json['last_tick_utc'], '2026-11-15T12:00:00.000Z');
      expect(json['born_at_utc'], '2026-11-15T12:00:00.000Z');
      expect((json['vitals'] as Map<String, dynamic>).keys.toSet(),
          <String>{'satiety', 'mood', 'energy'});
    });

    test('本地时间会被规范化成 UTC', () {
      // 东八区的 20:00 == UTC 12:00。
      final DateTime local = DateTime.utc(2026, 11, 15, 12).toLocal();
      final PetSave save = PetSave.defaults(now: local);
      final Map<String, dynamic> json = jsonDecode(save.encode()) as Map<String, dynamic>;
      expect(json['last_tick_utc'], endsWith('Z'));
      expect(DateTime.parse(json['last_tick_utc'] as String).isUtc, isTrue);
    });

    test('往返保持一致', () {
      final PetSave original = PetSave.defaults(now: stamp).copyWith(
        vitals: PetVitals(satiety: 12.5, mood: 33.25, energy: 66.5),
        petName: '小鲸二号',
        totalFeeds: 7,
        totalPets: 11,
      );
      final PetSave restored = PetSave.decode(original.encode());
      expect(restored.schemaVersion, original.schemaVersion);
      expect(restored.vitals, original.vitals);
      expect(restored.petName, original.petName);
      expect(restored.totalFeeds, original.totalFeeds);
      expect(restored.totalPets, original.totalPets);
      expect(restored.lastTickUtc, original.lastTickUtc);
      expect(restored.bornAtUtc, original.bornAtUtc);
    });

    test('非法 JSON 抛 PetSaveFormatException', () {
      expect(() => PetSave.decode('{不是 JSON'), throwsA(isA<PetSaveFormatException>()));
      expect(() => PetSave.decode('[]'), throwsA(isA<PetSaveFormatException>()));
    });

    test('缺字段 / 坏时间抛 PetSaveFormatException', () {
      expect(() => PetSave.decode('{}'), throwsA(isA<PetSaveFormatException>()));
      final Map<String, dynamic> broken = <String, dynamic>{
        'schema_version': 1,
        'vitals': <String, dynamic>{'satiety': 1, 'mood': 2, 'energy': 3},
        'last_tick_utc': '昨天下午',
        'pet_name': '小鲸',
        'total_feeds': 0,
        'total_pets': 0,
        'born_at_utc': '2026-11-15T12:00:00.000Z',
      };
      expect(() => PetSave.decode(jsonEncode(broken)), throwsA(isA<PetSaveFormatException>()));
    });

    test('更高版本的存档被拒绝（不静默丢数据）', () {
      final Map<String, dynamic> future = <String, dynamic>{
        'schema_version': 99,
        'vitals': <String, dynamic>{'satiety': 1, 'mood': 2, 'energy': 3},
        'last_tick_utc': '2026-11-15T12:00:00.000Z',
        'pet_name': '小鲸',
        'total_feeds': 0,
        'total_pets': 0,
        'born_at_utc': '2026-11-15T12:00:00.000Z',
      };
      expect(() => PetSave.decode(jsonEncode(future)), throwsA(isA<PetSaveFormatException>()));
    });

    test('数值越界的存档会被钳回 0~100', () {
      final Map<String, dynamic> odd = <String, dynamic>{
        'schema_version': 1,
        'vitals': <String, dynamic>{'satiety': 500, 'mood': -20, 'energy': 42},
        'last_tick_utc': '2026-11-15T12:00:00.000Z',
        'pet_name': '小鲸',
        'total_feeds': 0,
        'total_pets': 0,
        'born_at_utc': '2026-11-15T12:00:00.000Z',
      };
      final PetSave save = PetSave.decode(jsonEncode(odd));
      expect(save.vitals.satiety, 100.0);
      expect(save.vitals.mood, 0.0);
      expect(save.vitals.energy, 42.0);
    });

    test('migrate：当前版本是恒等映射', () {
      final PetSave save = PetSave.defaults(now: stamp);
      expect(save.migrate(), same(save));
    });
  });
}
