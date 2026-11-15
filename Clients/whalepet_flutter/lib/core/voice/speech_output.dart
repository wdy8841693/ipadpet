/// 播报（TTS）适配层的事件与接口（§7.1、§7.5）。
///
/// 与宠物状态机的唯一接口：语音状态由 `VoiceSessionCoordinator` 驱动，
/// 播报层只负责「开口 / 说完 / 出错」，不决定宠物进入什么状态。

/// 播报事件类型。
enum SpeechOutputEventKind { started, finished, failed }

/// 一条播报事件。所有异步回调都必须带 [utteranceId]，
/// 便于丢弃「上一轮迟到」的回调（§7.2 generation 规则）。
class SpeechOutputEvent {
  const SpeechOutputEvent({
    required this.kind,
    required this.utteranceId,
    this.message,
  });

  final SpeechOutputEventKind kind;
  final String utteranceId;
  final String? message;

  @override
  String toString() =>
      'SpeechOutputEvent(${kind.name}, $utteranceId${message == null ? '' : ', $message'})';
}

/// 系统 TTS 适配层。
abstract interface class SpeechOutputAdapter {
  /// 播报事件流。
  Stream<SpeechOutputEvent> get events;

  /// 初始化引擎（失败时抛出，由上层决定是否降级为「只上屏不播报」）。
  Future<void> initialize();

  /// 播报一条文本；[utteranceId] 用于事件去重与迟到回调丢弃。
  Future<void> speak(String utteranceId, String text);

  /// 停止当前播报。
  Future<void> stop();

  /// 释放进程/引擎。
  Future<void> dispose();
}

/// 不支持播报的平台用的空实现。
class NoopSpeechOutput implements SpeechOutputAdapter {
  const NoopSpeechOutput();

  @override
  Stream<SpeechOutputEvent> get events => const Stream<SpeechOutputEvent>.empty();

  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String utteranceId, String text) async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}
