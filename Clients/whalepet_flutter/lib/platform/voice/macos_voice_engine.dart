import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/voice/voice_engine.dart';
import '../../core/voice/voice_event_router.dart';

/// macOS 本地语音引擎（§7.4、§7.5、§10.2）。
///
/// 采集与识别都在原生层：`macos/Runner/VoiceEngine.swift` 用 AVAudioEngine 采集，
/// 交给系统 `SFSpeechRecognizer` **本机识别**（on-device），Dart 只收事件、发
/// 控制命令，PCM 不进 Dart（§7.4）。
///
/// 唤醒判定放在 [VoiceEventRouter]（core，纯 Dart）：系统识别没有「关键字语法」
/// 这类能力，只能用「常驻识别 + 唤醒词文本匹配」这种廉价替代，行为与 Android 版
/// 一致——耗电与延迟都不如真正的 KWS，所以默认关闭，由用户在设置里显式开启。
///
/// 将来换 sherpa-onnx（§7.9）：只要原生层实现同样的 start/stop + 事件回调，
/// 本文件和 core 里的路由都不用改。
class MacOSVoiceEngine implements VoiceEngineAdapter {
  MacOSVoiceEngine() {
    // 通道是单例的：这里挂一次，原生层的识别事件直接进 [_events]。
    _channel.setMethodCallHandler(_onNativeCall);
  }

  /// 与 `macos/Runner/AppDelegate.swift` 里的通道同名。
  static const MethodChannel _channel = MethodChannel('whalepet/voice');

  final StreamController<VoiceEngineEvent> _events =
      StreamController<VoiceEngineEvent>.broadcast();

  final VoiceEventRouter _router = VoiceEventRouter();

  bool _disposed = false;

  @override
  Stream<VoiceEngineEvent> get events => _events.stream;

  @override
  Future<void> initialize(VoiceEngineConfig config) async {
    if (_disposed) throw StateError('引擎已释放');
    if (!Platform.isMacOS) {
      throw UnsupportedError('MacOSVoiceEngine 只能在 macOS 上使用');
    }
    _router.setWakePhrases(config.wakePhrases);
    try {
      final Map<dynamic, dynamic>? info =
          await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'initialize',
        config.toJson(),
      );
      final String provider =
          (info?['provider'] ?? 'apple-speech').toString();
      final bool onDevice = info?['onDevice'] is bool
          ? info!['onDevice'] as bool
          : false;
      _emit(VoiceEngineReadyEvent(
        detail: onDevice
            ? '$provider（本机识别）'
            : '$provider（系统未提供本机识别，可能走 Apple 服务器）',
      ));
    } on PlatformException catch (error) {
      throw StateError(error.message ?? '语音引擎初始化失败');
    } on MissingPluginException {
      throw StateError('当前构建没有编译进语音通道（whalepet/voice）');
    }
  }

  @override
  Future<void> startWakeListening() async {
    if (_disposed) return;
    // 先切模式再通知原生：切模式期间到达的事件要按新模式判断，
    // 否则唤醒应答播报期间的残留事件会被当成新一轮指令。
    _router.setMode(VoiceEngineMode.wake);
    try {
      await _channel.invokeMethod<dynamic>('startWakeListening');
    } catch (_) {
      _router.setMode(VoiceEngineMode.idle);
      rethrow;
    }
  }

  @override
  Future<void> startManualListening() async {
    if (_disposed) return;
    _router.setMode(VoiceEngineMode.listen);
    try {
      await _channel.invokeMethod<dynamic>('startManualListening');
    } catch (_) {
      _router.setMode(VoiceEngineMode.idle);
      rethrow;
    }
  }

  @override
  Future<void> stopListening() async {
    _router.setMode(VoiceEngineMode.idle);
    try {
      await _channel.invokeMethod<dynamic>('stopListening');
    } catch (_) {
      // 已经停了就无所谓。
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _router.setMode(VoiceEngineMode.idle);
    try {
      await _channel.invokeMethod<dynamic>('dispose');
    } catch (_) {
      // 原生侧可能已经走了。
    }
    await _events.close();
  }

  // -- 原生事件 -------------------------------------------------------------

  Future<void> _onNativeCall(MethodCall call) async {
    if (_disposed) return;
    if (call.method != 'event') return;
    final Map<dynamic, dynamic> args =
        (call.arguments as Map<dynamic, dynamic>?) ?? const <dynamic, dynamic>{};
    final String type = (args['type'] ?? '').toString();
    final String mode = (args['mode'] ?? '').toString();

    // 模式守卫（§7.2 的 generation 守卫在平台层的对应物）：切模式之前
    // 迟到的旧事件直接丢掉，不能让上一轮的识别结果污染这一轮。
    if (!_modeMatches(mode)) return;

    final RawVoiceEvent? raw = _toRaw(type, args);
    if (raw == null) return;
    for (final VoiceEngineEvent event in _router.route(raw)) {
      _emit(event);
    }
  }

  bool _modeMatches(String nativeMode) {
    final VoiceEngineMode mode = _router.mode;
    if (mode == VoiceEngineMode.idle) return false;
    if (mode == VoiceEngineMode.wake) return nativeMode == 'wake';
    return nativeMode == 'listen';
  }

  RawVoiceEvent? _toRaw(String type, Map<dynamic, dynamic> args) {
    switch (type) {
      case 'partial':
        return RawPartialEvent(text: (args['text'] ?? '').toString());
      case 'final':
        return RawFinalEvent(
          text: (args['text'] ?? '').toString(),
          confidence: (args['confidence'] as num?)?.toDouble() ?? 0,
        );
      case 'error':
        return RawErrorEvent(
          code: (args['code'] ?? 'unknown').toString(),
          message: (args['message'] ?? '语音识别出错').toString(),
          retryable: args['retryable'] is bool
              ? args['retryable'] as bool
              : true,
        );
      default:
        return null;
    }
  }

  void _emit(VoiceEngineEvent event) {
    if (_disposed || _events.isClosed) return;
    _events.add(event);
  }
}
