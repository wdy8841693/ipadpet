import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/voice/speech_output.dart';

/// macOS 系统 TTS 适配层：原生侧用 `AVSpeechSynthesizer`（zh-CN 声音）。
///
/// 事件回传走 MethodChannel `whalepet/speech` 的 `event` 回调，
/// `utteranceId` 由 Dart 侧生成并随 speak 下发，原生原样带回。
///
/// [speak] 的完成语义与 Android/Windows 一致：**必须等真实 utterance
/// 结束事件**才 resolve。原生 `speak` 方法只是提交朗读并立即返回，
/// 不能拿 MethodChannel 的回包当播报完成——否则协调器会提前恢复麦克风，
/// 造成自触发或下一条播报抢跑。
class MacOSSpeechOutput implements SpeechOutputAdapter {
  MacOSSpeechOutput();

  static const MethodChannel _channel = MethodChannel('whalepet/speech');

  final StreamController<SpeechOutputEvent> _events =
      StreamController<SpeechOutputEvent>.broadcast();
  final Map<String, Completer<void>> _pending = <String, Completer<void>>{};

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
          _complete(id);
        case 'cancelled':
          // core 的事件枚举没有 cancelled；协调器把 finished/failed 都视为
          // 「这条播报已结束」，取消映射为 failed（不重试、不再等）。
          _events.add(SpeechOutputEvent(
            kind: SpeechOutputEventKind.failed,
            utteranceId: id,
            message: 'cancelled',
          ));
          _complete(id);
        case 'failed':
          _events.add(SpeechOutputEvent(
            kind: SpeechOutputEventKind.failed,
            utteranceId: id,
            message: args['message'] == null ? null : '${args['message']}',
          ));
          _complete(id);
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
    final Completer<void> completer = Completer<void>();
    _pending[utteranceId] = completer;
    try {
      await _channel.invokeMethod<dynamic>(
        'speak',
        <String, String>{'utteranceId': utteranceId, 'text': text},
      );
    } catch (error) {
      _pending.remove(utteranceId);
      rethrow;
    }
    try {
      // 系统播报卡死时也不能让协调器永远等下去。
      await completer.future.timeout(const Duration(minutes: 2));
    } on TimeoutException {
      _pending.remove(utteranceId);
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _channel.invokeMethod<dynamic>('stop');
    } finally {
      _completeAll();
    }
  }

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
    _completeAll();
    await _events.close();
  }

  void _complete(String id) {
    final Completer<void>? completer = _pending.remove(id);
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void _completeAll() {
    for (final Completer<void> completer in _pending.values) {
      if (!completer.isCompleted) completer.complete();
    }
    _pending.clear();
  }
}
