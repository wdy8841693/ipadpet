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
    this.clickThroughWhereTransparent = true,
    this.windowX,
    this.windowY,
    this.chatPanelOpen = false,
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

  /// 是否在「透明区域」自动鼠标穿透（鼠标离开宠物身上时不吃点击）。
  final bool clickThroughWhereTransparent;

  /// 上次的窗口位置（逻辑像素）；null 表示还没手动拖过。
  final double? windowX;
  final double? windowY;

  /// 上次退出时聊天面板是否是打开的。
  final bool chatPanelOpen;

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
    bool? clickThroughWhereTransparent,
    double? windowX,
    double? windowY,
    bool? chatPanelOpen,
  }) {
    return AppSettings(
      serverUrl: serverUrl ?? this.serverUrl,
      subscriptionsAnnouncements:
          subscriptionsAnnouncements ?? this.subscriptionsAnnouncements,
      speakResponses: speakResponses ?? this.speakResponses,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      clickThroughWhereTransparent:
          clickThroughWhereTransparent ?? this.clickThroughWhereTransparent,
      windowX: windowX ?? this.windowX,
      windowY: windowY ?? this.windowY,
      chatPanelOpen: chatPanelOpen ?? this.chatPanelOpen,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'schema_version': kSchemaVersion,
        'server_url': serverUrl,
        'subscriptions_announcements': subscriptionsAnnouncements,
        'speak_responses': speakResponses,
        'always_on_top': alwaysOnTop,
        'click_through_where_transparent': clickThroughWhereTransparent,
        'window_x': windowX,
        'window_y': windowY,
        'chat_panel_open': chatPanelOpen,
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
      clickThroughWhereTransparent:
          _bool(json['click_through_where_transparent'], true),
      windowX: _double(json['window_x']),
      windowY: _double(json['window_y']),
      chatPanelOpen: _bool(json['chat_panel_open'], false),
    );
  }

  static String? _string(Object? value) => value is String ? value : null;

  static bool _bool(Object? value, bool fallback) =>
      value is bool ? value : fallback;

  static double? _double(Object? value) =>
      value is num ? value.toDouble() : null;
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
