import 'dart:convert';
import 'dart:io';

import 'atomic_file.dart';

/// 客户端设置（与宠物数值存档分开，§11.1）。
///
/// 只放「可以明文存」的东西：服务地址、开关、窗口位置。
/// Bearer 令牌走 DPAPI 单独加密（见 `TokenStore`），**不写进这个文件**。
class AppSettings {
  AppSettings({
    this.serverUrl = '',
    this.subscriptionsAnnouncements = true,
    this.speakResponses = true,
    this.alwaysOnTop = true,
    this.windowX,
    this.windowY,
    this.chatPanelOpen = false,
    this.voiceWakeEnabled = false,
    this.wakePhrase = '小鲸小鲸',
    this.wakeAliases = const <String>['小金小金'],
    this.wakeAck = '我在',
    this.autostartEnabled = false,
    this.oneShotCommandEnabled = false,
  });

  /// 设置文件格式版本。
  static const int kSchemaVersion = 1;

  /// 服务地址，例如 `http://192.168.1.10:8787`。
  final String serverUrl;

  /// 是否订阅其它 DSH 会话的全局通知（§8.7）。
  final bool subscriptionsAnnouncements;

  /// 回答是否用系统 TTS 播报。
  final bool speakResponses;

  /// 窗口是否置顶。
  final bool alwaysOnTop;

  /// 上次的窗口位置（逻辑像素）；null 表示还没手动拖过。
  final double? windowX;
  final double? windowY;

  /// 上次退出时聊天面板是否是打开的。
  final bool chatPanelOpen;

  /// 是否开启本地 KWS 常驻唤醒（默认关，接上麦克风再开）。
  final bool voiceWakeEnabled;

  /// 唤醒词、别名与应答（会写进 KWS 语法，§11.3）。
  final String wakePhrase;
  final List<String> wakeAliases;
  final String wakeAck;

  /// 是否开机自动启动桌宠（§10.3「开机启动」）。
  ///
  /// 这里只记「用户想要什么」；真正写进系统启动项由平台适配层执行
  /// （`lib/platform/autostart/`），写失败时以适配层返回的状态为准。
  final bool autostartEnabled;

  /// 是否支持「一句话带命令」（§7.7）。
  ///
  /// 打开后待机阶段用整段听写代替唤醒词小语法，「小鲸小鲸，帮我查天气」
  /// 一句话说完就执行；关掉则退回「唤醒 → 我在 → 说指令」的低功耗两段式。
  /// 只对「按键语法」引擎有区别（Windows SAPI），系统整段识别端恒定支持。
  ///
  /// **默认关闭**：SAPI 通用听写对自定义唤醒词识别很差（实测把「小鲸小鲸」
  /// 听成「孝敬孝敬」，置信度 0.22），默认开启会让最基本的唤醒都失效。
  /// 只在用户显式打开、且实测该机器能识别唤醒词时才启用。
  final bool oneShotCommandEnabled;

  /// 服务地址解析结果；空或非法返回 null。
  Uri? get parsedServerUri {
    final String raw = serverUrl.trim();
    if (raw.isEmpty) return null;
    final String withScheme = raw.contains('://') ? raw : 'http://$raw';
    final Uri? uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) return null;
    return uri;
  }

  /// 是否已经配置好可以连的服务器。
  bool get isConfigured => parsedServerUri != null;

  AppSettings copyWith({
    String? serverUrl,
    bool? subscriptionsAnnouncements,
    bool? speakResponses,
    bool? alwaysOnTop,
    double? windowX,
    double? windowY,
    bool? chatPanelOpen,
    bool? voiceWakeEnabled,
    String? wakePhrase,
    List<String>? wakeAliases,
    String? wakeAck,
    bool? autostartEnabled,
    bool? oneShotCommandEnabled,
  }) {
    return AppSettings(
      serverUrl: serverUrl ?? this.serverUrl,
      subscriptionsAnnouncements:
          subscriptionsAnnouncements ?? this.subscriptionsAnnouncements,
      speakResponses: speakResponses ?? this.speakResponses,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      windowX: windowX ?? this.windowX,
      windowY: windowY ?? this.windowY,
      chatPanelOpen: chatPanelOpen ?? this.chatPanelOpen,
      voiceWakeEnabled: voiceWakeEnabled ?? this.voiceWakeEnabled,
      wakePhrase: wakePhrase ?? this.wakePhrase,
      wakeAliases: wakeAliases ?? this.wakeAliases,
      wakeAck: wakeAck ?? this.wakeAck,
      autostartEnabled: autostartEnabled ?? this.autostartEnabled,
      oneShotCommandEnabled:
          oneShotCommandEnabled ?? this.oneShotCommandEnabled,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema_version': kSchemaVersion,
        'server_url': serverUrl,
        'subscriptions_announcements': subscriptionsAnnouncements,
        'speak_responses': speakResponses,
        'always_on_top': alwaysOnTop,
        'window_x': windowX,
        'window_y': windowY,
        'chat_panel_open': chatPanelOpen,
        'voice_wake_enabled': voiceWakeEnabled,
        'wake_phrase': wakePhrase,
        'wake_aliases': wakeAliases,
        'wake_ack': wakeAck,
        'autostart_enabled': autostartEnabled,
        'one_shot_command_enabled': oneShotCommandEnabled,
      };

  static AppSettings fromJson(Map<String, dynamic> json) {
    final int version = json['schema_version'] is num
        ? (json['schema_version'] as num).toInt()
        : kSchemaVersion;
    if (version > kSchemaVersion) {
      throw FormatException('设置文件版本 $version 比当前支持的 $kSchemaVersion 新');
    }
    return AppSettings(
      serverUrl: _string(json['server_url']) ?? '',
      subscriptionsAnnouncements: _bool(json['subscriptions_announcements'], true),
      speakResponses: _bool(json['speak_responses'], true),
      alwaysOnTop: _bool(json['always_on_top'], true),
      // 旧版本配置里可能残留 click_through_where_transparent 键：
      // 穿透现在是恒定行为，该键被忽略（fromJson 只读取上面这些已知字段）。
      windowX: _double(json['window_x']),
      windowY: _double(json['window_y']),
      chatPanelOpen: _bool(json['chat_panel_open'], false),
      voiceWakeEnabled: _bool(json['voice_wake_enabled'], false),
      wakePhrase: _string(json['wake_phrase']) ?? '小鲸小鲸',
      wakeAliases: _stringList(json['wake_aliases'], const <String>['小金小金']),
      wakeAck: _string(json['wake_ack']) ?? '我在',
      autostartEnabled: _bool(json['autostart_enabled'], false),
      oneShotCommandEnabled: _bool(json['one_shot_command_enabled'], false),
    );
  }

  static String? _string(Object? value) => value is String ? value : null;

  static bool _bool(Object? value, bool fallback) =>
      value is bool ? value : fallback;

  static double? _double(Object? value) =>
      value is num ? value.toDouble() : null;

  static List<String> _stringList(Object? value, List<String> fallback) {
    if (value is! List) return fallback;
    return value.whereType<String>().toList(growable: false);
  }
}

/// 设置的读写：文件不存在 / 损坏都回落到默认值（不让客户端起不来）。
class SettingsStore {
  SettingsStore({required this.file});

  final File file;

  Future<AppSettings> load() async {
    try {
      if (!await file.exists()) return AppSettings();
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, dynamic>) return AppSettings();
      return AppSettings.fromJson(decoded);
    } catch (_) {
      return AppSettings();
    }
  }

  Future<void> save(AppSettings settings) async {
    await writeFileAtomically(
      file,
      const JsonEncoder.withIndent('  ').convert(settings.toJson()),
    );
  }
}
