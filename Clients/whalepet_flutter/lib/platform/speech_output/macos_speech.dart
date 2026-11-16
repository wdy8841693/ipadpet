import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/voice/speech_output.dart';

/// macOS 系统 TTS 适配层：原生侧用 `AVSpeechSynthesizer`（zh-CN 声音）。
///
/// 事件回传走 MethodChannel `whalepet/speech` 的 `event` 回调，
/// `utteranceId` 由 Dart 侧生成并随 speak 下发，原生原样带回，
/// 迟到的回调由 `SpeechQueue` 按 id 去重（§7.8）。
class MacOSSpeechOutput implements SpeechOutputAdapter {
  MacOSSpeechOutput();

  static const MethodChannel _channel = MethodChannel('whalepet/speech');

  final StreamController<SpeechOutputEvent> _events =
      StreamController<SpeechOutputEvent>.broadcast();

  bool _initialized = false;
  bool _handlerBound = false;

  @override
  Stream<SpeechOutputEvent> get events => _events.stream;

  void _bindHandler() {
    if (_handlerBound) return;
    _handlerBound = true;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method != 'event') return null;
      final Map<dynamic, dynamic> args =
          call.arguments as Map<dynamic, dynamic>? ?? const <dynamic, dynamic>{};
      final String id = '${args['utteranceId']}';
      switch ('${args['kind']}') {
        case 'started':
          _events.add(SpeechOutputEvent(
            kind: SpeechOutputEventKind.started,
            utteranceId: id,
          ));
        case 'finished':
          _events.add(SpeechOutputEvent(
            kind: SpeechOutputEventKind.finished,
            utteranceId: id,
          ));
        case 'cancelled':
          // core 的事件枚举没有 cancelled；协调器把 finished/failed 都视为
          // 「这条播报已结束」，取消映射为 failed（不重试、不再等）。
          _events.add(SpeechOutputEvent(
            kind: SpeechOutputEventKind.failed,
            utteranceId: id,
            message: 'cancelled',
          ));
        case 'failed':
          _events.add(SpeechOutputEvent(
            kind: SpeechOutputEventKind.failed,
            utteranceId: id,
            message: args['message'] == null ? null : '${args['message']}',
          ));
      }
      return null;
    });
  }

  @override
  Future<void> initialize() async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('MacOSSpeechOutput 只能在 macOS 上使用');
    }
    _bindHandler();
    await _channel.invokeMethod<dynamic>('initialize');
    _initialized = true;
  }

  @override
  Future<void> speak(String utteranceId, String text) async {
    if (!_initialized) return;
    await _channel.invokeMethod<dynamic>(
      'speak',
      <String, String>{'utteranceId': utteranceId, 'text': text},
    );
  }

  @override
  Future<void> stop() => _channel.invokeMethod<dynamic>('stop');

  @override
  Future<void> dispose() async {
    if (_initialized) {
      try {
        await _channel.invokeMethod<dynamic>('dispose');
      } on PlatformException {
        // 退出时的清理失败可以忽略。
      }
    }
    _initialized = false;
    await _events.close();
  }
}
