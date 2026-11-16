import 'dart:async';

import '../../core/voice/voice_engine.dart';
import '../../core/voice/wake_matcher.dart';
import '../android/native_bridge.dart';

/// Android 上的语音引擎适配层（§7.5、§10.1）。
///
/// 第一版刻意用**系统语音识别**（`android.speech.SpeechRecognizer`）而不是 sherpa-onnx：
///
/// - 采集、VAD、识别都在系统语音服务里完成，PCM 完全不进 Dart，符合 §7.4；
/// - 不用往安装包里塞模型，先打通「点麦说话 → DSH 执行 → 本地播报」这条垂直闭环（阶段 C 第 1~2 步）；
/// - 唤醒靠「常驻识别 + [WakeMatcher] 文本匹配」实现，属于**廉价替代**：
///   耗电与延迟都不如真正的 KWS，所以默认关闭，由用户在设置里显式开启。
///
/// 后续接 sherpa-onnx 时，只要新写一个 `VoiceEngineAdapter` 实现替换本类即可，
/// 协调器与 UI 不用改（这正是这层接口存在的理由）。
class AndroidSystemVoiceEngine implements VoiceEngineAdapter {
  AndroidSystemVoiceEngine();

  final StreamController<VoiceEngineEvent> _events =
      StreamController<VoiceEngineEvent>.broadcast();

  StreamSubscription<Map<String, Object?>>? _nativeSubscription;
  VoiceEngineConfig _config = const VoiceEngineConfig();
  WakeMatcher _matcher = const WakeMatcher(<String>['小鲸小鲸']);

  int _generation = 0;
  bool _wakeMode = false;
  bool _listening = false;
  bool _disposed = false;
  String? _lastWakeText;

  @override
  Stream<VoiceEngineEvent> get events => _events.stream;

  @override
  Future<void> initialize(VoiceEngineConfig config) async {
    if (_disposed) return;
    _config = config;
    _matcher = WakeMatcher(config.wakePhrases);

    final bool available = await NativeBridge.asrAvailable();
    if (!available) {
      throw StateError('没有可用的系统语音识别服务（部分精简 ROM 需要先装「语音服务」）');
    }
    bool granted = await NativeBridge.hasMicPermission();
    if (!granted) {
      granted = await NativeBridge.requestMicPermission();
    }
    if (!granted) {
      throw StateError('麦克风权限被拒绝，可到系统设置里打开');
    }

    _nativeSubscription ??= NativeBridge.events.listen(_onNativeEvent);
    _emit(VoiceEngineReadyEvent(
      generation: _generation,
      detail: 'Android SpeechRecognizer (zh-CN)',
    ));
  }

  @override
  Future<void> startWakeListening() async {
    if (_disposed) return;
    _generation++;
    _wakeMode = true;
    _listening = true;
    _lastWakeText = null;
    await NativeBridge.asrStart(wakeMode: true);
  }

  @override
  Future<void> startManualListening() async {
    if (_disposed) return;
    _generation++;
    _wakeMode = false;
    _listening = true;
    await NativeBridge.asrStart(wakeMode: false);
  }

  @override
  Future<void> stopListening() async {
    _generation++;
    _listening = false;
    _wakeMode = false;
    try {
      await NativeBridge.asrStop();
    } catch (_) {
      // 已经停了就无所谓
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _listening = false;
    try {
      await NativeBridge.asrStop();
    } catch (_) {}
    await _nativeSubscription?.cancel();
    _nativeSubscription = null;
    await _events.close();
  }

  // -- 原生事件 -------------------------------------------------------------

  void _onNativeEvent(Map<String, Object?> event) {
    if (_disposed) return;
    final String type = (event['type'] ?? '').toString();
    switch (type) {
      case 'partial':
        if (!_listening || _wakeMode) return;
        final String text = (event['text'] ?? '').toString().trim();
        if (text.isEmpty) return;
        _emit(VoicePartialTranscriptEvent(text: text, generation: _generation));
      case 'final':
        _onFinalTranscript(event);
      case 'error':
        _onNativeError(event);
      default:
        break;
    }
  }

  void _onFinalTranscript(Map<String, Object?> event) {
    final String text = (event['text'] ?? '').toString().trim();
    final double confidence = (event['confidence'] as num?)?.toDouble() ?? 0;

    if (text.isEmpty) {
      if (_listening && !_wakeMode) {
        _emit(VoiceRecognitionErrorEvent(
          generation: _generation,
          code: 'empty_result',
          message: '没听清',
          retryable: true,
        ));
      }
      return;
    }

    if (_wakeMode) {
      // 常驻唤醒阶段：只有命中唤醒词才算数，其余句子直接丢掉（这是常态，不上报错误）。
      if (!_matcher.contains(text)) return;
      if (text == _lastWakeText) return;
      _lastWakeText = text;
      _wakeMode = false;
      _listening = false;
      unawaited(_stopNative());
      _emit(VoiceWakeDetectedEvent(
        generation: _generation,
        keyword: _config.wakePhrase,
        // 系统识别不区分「唤醒词置信度」，这里给一个固定的中等值，方便上层日志观察
        confidence: confidence == 0 ? 0.6 : confidence,
      ));
      return;
    }

    _listening = false;
    unawaited(_stopNative());
    _emit(VoiceFinalTranscriptEvent(
      generation: _generation,
      text: text,
      confidence: confidence,
    ));
  }

  void _onNativeError(Map<String, Object?> event) {
    final String code = (event['code'] ?? 'unknown').toString();
    final String message = (event['message'] ?? '语音识别出错').toString();

    // 待唤醒阶段的「没听清/无匹配」是常态（原生侧会自己续听），不打扰用户。
    if (_wakeMode) {
      if (code == 'insufficient_permissions' || code == 'not_available') {
        _listening = false;
        _wakeMode = false;
        _emit(VoiceCaptureErrorEvent(
          generation: _generation,
          code: code,
          message: message,
        ));
      }
      return;
    }

    if (!_listening) return;
    final bool fatal = code == 'insufficient_permissions' || code == 'not_available';
    _listening = false;
    if (fatal) {
      _emit(VoiceCaptureErrorEvent(
        generation: _generation,
        code: code,
        message: message,
      ));
      return;
    }
    _emit(VoiceRecognitionErrorEvent(
      generation: _generation,
      code: code,
      message: message,
      retryable: true,
    ));
  }

  Future<void> _stopNative() async {
    try {
      await NativeBridge.asrStop();
    } catch (_) {}
  }

  void _emit(VoiceEngineEvent event) {
    if (_disposed || _events.isClosed) return;
    _events.add(event);
  }
}
