import 'dart:async';

import '../../core/voice/speech_output.dart';
import '../android/native_bridge.dart';

/// Android 系统 TTS 适配层（§10.1：等 utterance 完成回调再恢复唤醒）。
///
/// 原生侧用 `TextToSpeech` + `UtteranceProgressListener`，把 started / finished / failed
/// 以 `{type: 'tts', kind: ..., id: ...}` 的形式回抛。
///
/// 注意 [speak] 的完成语义：**必须等到这条 utterance 真的念完**才 resolve。
/// 协调器既看这个 Future 也看事件流（两者幂等）来判断「播报结束、该恢复采集了」；
/// 如果像普通 native 调用那样立刻返回，麦克风会在宠物还在说话时就打开，自己把自己唤醒。
class AndroidSystemTts implements SpeechOutputAdapter {
  AndroidSystemTts();

  final StreamController<SpeechOutputEvent> _events =
      StreamController<SpeechOutputEvent>.broadcast();
  final Map<String, Completer<void>> _pending = <String, Completer<void>>{};

  StreamSubscription<Map<String, Object?>>? _nativeSubscription;
  bool _initialized = false;
  bool _disposed = false;

  @override
  Stream<SpeechOutputEvent> get events => _events.stream;

  @override
  Future<void> initialize() async {
    if (_disposed) return;
    if (_initialized) return;
    _nativeSubscription ??= NativeBridge.events.listen((Map<String, Object?> event) {
      if ((event['type'] ?? '') != 'tts') return;
      final String? id = event['id']?.toString();
      if (id == null || id.isEmpty) return;
      final String kind = (event['kind'] ?? '').toString();
      switch (kind) {
        case 'started':
          _emit(SpeechOutputEvent(
            kind: SpeechOutputEventKind.started,
            utteranceId: id,
          ));
        case 'finished':
          _emit(SpeechOutputEvent(
            kind: SpeechOutputEventKind.finished,
            utteranceId: id,
          ));
          _complete(id);
        case 'failed':
          _emit(SpeechOutputEvent(
            kind: SpeechOutputEventKind.failed,
            utteranceId: id,
            message: (event['message'] ?? '播报失败').toString(),
          ));
          _complete(id);
        default:
          break;
      }
    });

    final bool ok = await NativeBridge.ttsInit();
    if (!ok) {
      throw StateError('系统 TTS 初始化失败（可能没装中文语音包）');
    }
    _initialized = true;
  }

  @override
  Future<void> speak(String utteranceId, String text) async {
    if (_disposed) return;
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;

    final Completer<void> completer = Completer<void>();
    _pending[utteranceId] = completer;
    try {
      await NativeBridge.ttsSpeak(id: utteranceId, text: trimmed);
    } catch (error) {
      _pending.remove(utteranceId);
      rethrow;
    }
    try {
      // 兜底：系统播报服务卡死时也不能把状态机永远挂住
      await completer.future.timeout(const Duration(minutes: 2));
    } on TimeoutException {
      _pending.remove(utteranceId);
    }
  }

  @override
  Future<void> stop() async {
    if (_disposed) return;
    try {
      await NativeBridge.ttsStop();
    } catch (_) {}
    _completeAll();
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    try {
      await NativeBridge.ttsStop();
    } catch (_) {}
    _completeAll();
    await _nativeSubscription?.cancel();
    _nativeSubscription = null;
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

  void _emit(SpeechOutputEvent event) {
    if (_disposed || _events.isClosed) return;
    _events.add(event);
  }
}
