import 'dart:async';

/// 本地语音引擎的配置（§7.3、§7.6、§11.3）。
///
/// 这份配置从服务端 `voice_config` 下来时带 `revision`；revision 不变不重建语法，
/// 变化时在安全点（等待唤醒）重建，不能一边识别一边覆盖引擎。
class VoiceEngineConfig {
  const VoiceEngineConfig({
    this.culture = 'zh-CN',
    this.wakePhrase = '小鲸小鲸',
    this.wakeAliases = const <String>['小金小金'],
    this.wakeAck = '我在',
    this.listenTimeoutMs = 10000,
    this.maxCommandMs = 20000,
    this.endSilenceMs = 700,
    this.wakeConfidence = 0.45,
    this.dictationConfidence = 0.2,
    this.oneShotCommand = false,
    this.revision = 0,
  });

  /// 离线识别引擎的语言（Windows 上必须存在对应的 InstalledRecognizer）。
  final String culture;

  /// 主唤醒词。
  final String wakePhrase;

  /// 同音别名（KWS 语法里同等生效）。
  final List<String> wakeAliases;

  /// 唤醒应答（空串 = 不播「我在」，直接听指令）。
  final String wakeAck;

  /// 唤醒后最长聆听时间（§7.3 默认 10s）。
  final int listenTimeoutMs;

  /// 单条指令最长时长。
  final int maxCommandMs;

  /// 尾部静音判停。
  final int endSilenceMs;

  /// KWS / 听写的最低置信度。
  final double wakeConfidence;
  final double dictationConfidence;

  /// 是否支持「一句话带命令」（§7.7）。
  ///
  /// 打开后，待机阶段用**整段听写**代替「唤醒词小语法」：识别出整句后由
  /// [VoiceEventRouter] 在句首匹配唤醒词，并取出后面那一截当指令，
  /// 于是「小鲸小鲸，帮我查天气」可以一句话说完就执行。
  ///
  /// 代价是待机期一直在跑整段 ASR（比纯 KWS 费 CPU）。关掉它就退回
  /// 「唤醒 → 我在 → 说指令」的低功耗两段式。
  ///
  /// 只对「按键语法 + 整段 ASR」这类引擎有意义：Android/macOS 的系统识别
  /// 本来就是整段 ASR，恒定支持，不需要这个开关。
  ///
  /// **默认关闭**：Windows SAPI 的通用听写认不出自定义唤醒词（实测
  /// 「小鲸小鲸」→「孝敬孝敬」，置信度 0.22），默认开启等于关掉唤醒。
  final bool oneShotCommand;

  /// 服务端配置版本。
  final int revision;

  /// 所有唤醒词（主词 + 别名，去重）。
  List<String> get wakePhrases {
    final List<String> result = <String>[wakePhrase, ...wakeAliases];
    final Set<String> seen = <String>{};
    return result
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty && seen.add(value))
        .toList(growable: false);
  }

  VoiceEngineConfig copyWith({
    String? culture,
    String? wakePhrase,
    List<String>? wakeAliases,
    String? wakeAck,
    int? listenTimeoutMs,
    int? maxCommandMs,
    int? endSilenceMs,
    double? wakeConfidence,
    double? dictationConfidence,
    bool? oneShotCommand,
    int? revision,
  }) =>
      VoiceEngineConfig(
        culture: culture ?? this.culture,
        wakePhrase: wakePhrase ?? this.wakePhrase,
        wakeAliases: wakeAliases ?? this.wakeAliases,
        wakeAck: wakeAck ?? this.wakeAck,
        listenTimeoutMs: listenTimeoutMs ?? this.listenTimeoutMs,
        maxCommandMs: maxCommandMs ?? this.maxCommandMs,
        endSilenceMs: endSilenceMs ?? this.endSilenceMs,
        wakeConfidence: wakeConfidence ?? this.wakeConfidence,
        dictationConfidence: dictationConfidence ?? this.dictationConfidence,
        oneShotCommand: oneShotCommand ?? this.oneShotCommand,
        revision: revision ?? this.revision,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'culture': culture,
        'wake_phrases': wakePhrases,
        'wake_ack': wakeAck,
        'listen_timeout_ms': listenTimeoutMs,
        'max_command_ms': maxCommandMs,
        'end_silence_ms': endSilenceMs,
        'wake_confidence': wakeConfidence,
        'dictation_confidence': dictationConfidence,
        'one_shot_command': oneShotCommand,
        'revision': revision,
      };
}

/// 语音引擎事件基类（§7.5）。
sealed class VoiceEngineEvent {
  const VoiceEngineEvent({this.generation = 0});
  final int generation;
}

/// 初始化完成，可以开始待唤醒。
class VoiceEngineReadyEvent extends VoiceEngineEvent {
  const VoiceEngineReadyEvent({super.generation, this.detail = ''});

  /// 引擎信息（例如 recognizer id）。
  final String detail;
}

/// 本地唤醒命中。
class VoiceWakeDetectedEvent extends VoiceEngineEvent {
  const VoiceWakeDetectedEvent({
    super.generation,
    required this.keyword,
    required this.confidence,
    this.trailingText = '',
  });

  final String keyword;
  final double confidence;

  /// 唤醒词后面紧跟着的话（§7.7）。
  ///
  /// 整段 ASR（Android / macOS 的系统识别）会把「小鲸小鲸帮我查天气」整句返回，
  /// 这里给出唤醒词之后的那一截。非空就说明用户是「一句话带命令」，
  /// 此时不必先播「我在」，可以直接把这句话发给 DSH。
  ///
  /// 真正的 KWS 引擎（Windows SAPI 关键字语法）拿不到这一截，保持空串，
  /// 走「唤醒 → 应答 → 聆听」的第一阶段流程。
  final String trailingText;
}

/// 中间识别文本（只上屏，不发指令）。
class VoicePartialTranscriptEvent extends VoiceEngineEvent {
  const VoicePartialTranscriptEvent({super.generation, required this.text});
  final String text;
}

/// 最终识别文本（判停后）。
class VoiceFinalTranscriptEvent extends VoiceEngineEvent {
  const VoiceFinalTranscriptEvent({
    super.generation,
    required this.text,
    required this.confidence,
  });

  final String text;
  final double confidence;
}

/// 识别失败（可重试 / 不可重试）。
class VoiceRecognitionErrorEvent extends VoiceEngineEvent {
  const VoiceRecognitionErrorEvent({
    super.generation,
    required this.code,
    required this.message,
    required this.retryable,
  });

  final String code;
  final String message;
  final bool retryable;
}

/// 采集层错误：没有麦克风、设备被占用、引擎不可用等。
class VoiceCaptureErrorEvent extends VoiceEngineEvent {
  const VoiceCaptureErrorEvent({
    super.generation,
    required this.code,
    required this.message,
  });

  final String code;
  final String message;
}

/// 采集被外部打断：来电、其它应用抢走音频、麦克风被占用（§10.1）。
///
/// 与 [VoiceCaptureErrorEvent] 的区别：这是**可恢复**的中断，
/// 引擎恢复后还会发 [VoiceEngineRecoveredEvent]。
class VoiceInterruptionEvent extends VoiceEngineEvent {
  const VoiceInterruptionEvent({
    super.generation,
    required this.reason,
    required this.message,
  });

  /// 中断原因：`audio_focus` / `phone_call` / `background`。
  final String reason;

  /// 给用户看的一句话。
  final String message;
}

/// 打断结束，麦克风又可以用了，引擎可以重新开始采集。
class VoiceEngineRecoveredEvent extends VoiceEngineEvent {
  const VoiceEngineRecoveredEvent({super.generation, this.detail = ''});

  /// 补充说明（例如「音频焦点回来了」）。
  final String detail;
}

/// 语音引擎适配层（§7.5）。
///
/// PCM 不穿过 Dart：采集、重采样、KWS、VAD、ASR 全在原生层，
/// Dart 只收事件、发控制命令。
abstract interface class VoiceEngineAdapter {
  /// 引擎事件流。
  Stream<VoiceEngineEvent> get events;

  /// 初始化引擎（可能要几百毫秒到几秒）。失败时抛出，由协调器给出可恢复原因。
  Future<void> initialize(VoiceEngineConfig config);

  /// 低功耗常驻唤醒。
  Future<void> startWakeListening();

  /// 手动/唤醒后聆听（跳过 KWS）。
  Future<void> startManualListening();

  /// 停止采集与识别。
  Future<void> stopListening();

  /// 释放。
  Future<void> dispose();
}

/// 不支持语音的平台 / 单元测试用的空实现。
class NoopVoiceEngine implements VoiceEngineAdapter {
  const NoopVoiceEngine();

  @override
  Stream<VoiceEngineEvent> get events => const Stream<VoiceEngineEvent>.empty();

  @override
  Future<void> initialize(VoiceEngineConfig config) async {}

  @override
  Future<void> startWakeListening() async {}

  @override
  Future<void> startManualListening() async {}

  @override
  Future<void> stopListening() async {}

  @override
  Future<void> dispose() async {}
}
