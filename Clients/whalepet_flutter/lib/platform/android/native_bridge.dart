import 'dart:async';

import 'package:flutter/services.dart';

/// Android 原生能力桥（§7.4：PCM 不穿越 MethodChannel，只传事件）。
///
/// 通道划分：
/// - `whalepet/native`：命令（TTS、ASR、Keystore、路径、权限）；
/// - `whalepet/native/events`：原生 → Dart 的事件（识别结果、播报进度）。
///
/// 对应原生实现：`android/app/src/main/kotlin/com/dywu/whalepet/WhalePetBridge.kt`。
class NativeBridge {
  const NativeBridge._();

  static const MethodChannel _methods = MethodChannel('whalepet/native');
  static const EventChannel _eventChannel = EventChannel('whalepet/native/events');

  static Stream<Map<String, Object?>>? _events;

  /// 原生事件流（广播、可多处订阅）。
  static Stream<Map<String, Object?>> get events {
    return _events ??= _eventChannel
        .receiveBroadcastStream()
        .map((Object? raw) => <String, Object?>{
              for (final MapEntry<Object?, Object?> entry
                  in (raw as Map<Object?, Object?>).entries)
                entry.key.toString(): entry.value,
            })
        .asBroadcastStream();
  }

  /// App 私有目录（Android 上 `getFilesDir()`），用作 AppPaths 的根。
  static Future<String> appRootDir() async =>
      await _methods.invokeMethod<String>('appRootDir') ?? '';

  static Future<bool> hasMicPermission() async =>
      await _methods.invokeMethod<bool>('hasMicPermission') ?? false;

  /// 弹系统权限框；返回用户是否授权。
  static Future<bool> requestMicPermission() async =>
      await _methods.invokeMethod<bool>('requestMicPermission') ?? false;

  static Future<void> openAppSettings() =>
      _methods.invokeMethod<void>('openAppSettings');

  // -- 安全存储（Android Keystore + AES-GCM） -------------------------------

  static Future<String?> secureRead(String key) =>
      _methods.invokeMethod<String>('secureRead', <String, Object?>{'key': key});

  static Future<void> secureWrite(String key, String value) =>
      _methods.invokeMethod<void>(
          'secureWrite', <String, Object?>{'key': key, 'value': value});

  // -- 系统 TTS -------------------------------------------------------------

  static Future<bool> ttsInit() async =>
      await _methods.invokeMethod<bool>('ttsInit') ?? false;

  static Future<void> ttsSpeak({
    required String id,
    required String text,
    double speechRate = 0.9,
  }) =>
      _methods.invokeMethod<void>('ttsSpeak', <String, Object?>{
        'id': id,
        'text': text,
        'rate': speechRate,
      });

  static Future<void> ttsStop() => _methods.invokeMethod<void>('ttsStop');

  // -- 系统语音识别 ---------------------------------------------------------

  static Future<bool> asrAvailable() async =>
      await _methods.invokeMethod<bool>('asrAvailable') ?? false;

  /// [wakeMode] = true 表示常驻唤醒（原生侧连续识别），false 表示听一条指令。
  static Future<void> asrStart({required bool wakeMode}) => _methods
      .invokeMethod<void>('asrStart', <String, Object?>{'wakeMode': wakeMode});

  /// 停止采集。
  ///
  /// [force] = true 表示**用户明确停止**（关语音 / 退后台 / 释放）：原生侧会
  /// 释放音频焦点并停掉来电轮询。打断期间的自动停采集不要传 true，否则
  /// 恢复监听会被一起清掉，来电结束后再也收不到恢复事件（§10.1）。
  static Future<void> asrStop({bool force = false}) =>
      _methods.invokeMethod<void>('asrStop', <String, Object?>{'force': force});
}
