import 'dart:convert';

import '../pet/pet_vitals.dart';

/// 存档格式错误（解析失败、版本不认识等）。
class PetSaveFormatException implements Exception {
  /// 构造一条格式错误。
  const PetSaveFormatException(this.message);

  /// 错误说明。
  final String message;

  @override
  String toString() => 'PetSaveFormatException: $message';
}

/// 宠物本地存档（schema v1）。
///
/// 规则来源：docs/CROSS_PLATFORM.md §11.1：
///   - 时间统一用 UTC ISO-8601 字符串，不依赖各语言默认的 Date JSON 编码；
///   - 原子写入由 [PetSaveStore] 负责；
///   - 损坏存档先备份再回落到默认值；
///   - 桌面窗口位置、语音设置放独立设置文件，不混进数值存档。
class PetSave {
  /// 创建一份存档。
  PetSave({
    required this.vitals,
    required this.lastTickUtc,
    required this.petName,
    required this.totalFeeds,
    required this.totalPets,
    required this.bornAtUtc,
    this.schemaVersion = kPetSaveSchemaVersion,
  });

  /// 当前支持的存档版本。
  static const int kPetSaveSchemaVersion = 1;

  /// 存档格式版本。
  final int schemaVersion;

  /// 数值状态。
  final PetVitals vitals;

  /// 最后一次推进数值的时刻（UTC）。
  final DateTime lastTickUtc;

  /// 宠物名字。
  final String petName;

  /// 累计投喂次数。
  final int totalFeeds;

  /// 累计摸头次数。
  final int totalPets;

  /// 出生时刻（UTC）。
  final DateTime bornAtUtc;

  /// 默认存档：满数值、零计数。
  factory PetSave.defaults({String petName = '小鲸', DateTime? now}) {
    final DateTime stamp = (now ?? DateTime.now()).toUtc();
    return PetSave(
      vitals: PetVitals(),
      lastTickUtc: stamp,
      petName: petName,
      totalFeeds: 0,
      totalPets: 0,
      bornAtUtc: stamp,
    );
  }

  /// 序列化成 JSON 文本（缩进两格，便于人工查看与排障）。
  String encode() {
    final Map<String, dynamic> payload = <String, dynamic>{
      'schema_version': schemaVersion,
      'vitals': vitals.toJson(),
      'last_tick_utc': lastTickUtc.toUtc().toIso8601String(),
      'pet_name': petName,
      'total_feeds': totalFeeds,
      'total_pets': totalPets,
      'born_at_utc': bornAtUtc.toUtc().toIso8601String(),
    };
    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  /// 解析 JSON 文本；格式不对时抛 [PetSaveFormatException]。
  static PetSave decode(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (error) {
      throw PetSaveFormatException('存档不是合法 JSON：$error');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const PetSaveFormatException('存档根节点必须是 JSON 对象');
    }

    final int version = _readInt(decoded['schema_version'], fallback: kPetSaveSchemaVersion);
    if (version > kPetSaveSchemaVersion) {
      throw PetSaveFormatException('存档版本 $version 比当前支持的 $kPetSaveSchemaVersion 新');
    }

    final Object? rawVitals = decoded['vitals'];
    if (rawVitals is! Map<String, dynamic>) {
      throw const PetSaveFormatException('存档缺少 vitals 字段');
    }

    final Object? rawName = decoded['pet_name'];
    final DateTime stamp = _readDate(decoded['last_tick_utc'], field: 'last_tick_utc');

    final PetSave save = PetSave(
      schemaVersion: version,
      vitals: PetVitals.fromJson(rawVitals),
      lastTickUtc: stamp,
      petName: rawName is String && rawName.isNotEmpty ? rawName : '小鲸',
      totalFeeds: _readInt(decoded['total_feeds'], fallback: 0),
      totalPets: _readInt(decoded['total_pets'], fallback: 0),
      bornAtUtc: _readDate(decoded['born_at_utc'], field: 'born_at_utc'),
    );
    return save.migrate();
  }

  /// 把旧版本存档升级到当前版本。
  ///
  /// 目前只有 v1，故是恒等映射；将来新增版本时在这里补迁移规则。
  PetSave migrate() {
    if (schemaVersion == kPetSaveSchemaVersion) return this;
    throw PetSaveFormatException('没有从 schema $schemaVersion 升级到 $kPetSaveSchemaVersion 的迁移规则');
  }

  /// 复制一份并替换部分字段。
  PetSave copyWith({
    PetVitals? vitals,
    DateTime? lastTickUtc,
    String? petName,
    int? totalFeeds,
    int? totalPets,
  }) =>
      PetSave(
        schemaVersion: schemaVersion,
        vitals: vitals ?? this.vitals,
        lastTickUtc: lastTickUtc ?? this.lastTickUtc,
        petName: petName ?? this.petName,
        totalFeeds: totalFeeds ?? this.totalFeeds,
        totalPets: totalPets ?? this.totalPets,
        bornAtUtc: bornAtUtc,
      );

  // -- 内部 ---------------------------------------------------------------

  static int _readInt(Object? value, {required int fallback}) {
    if (value is int) return value;
    if (value is double) return value.round();
    if (value is num) return value.toInt();
    return fallback;
  }

  static DateTime _readDate(Object? value, {required String field}) {
    if (value is! String || value.isEmpty) {
      throw PetSaveFormatException('存档缺少 $field 字段');
    }
    final DateTime? parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw PetSaveFormatException('$field 不是合法的 ISO-8601 时间：$value');
    }
    return parsed.toUtc();
  }
}
