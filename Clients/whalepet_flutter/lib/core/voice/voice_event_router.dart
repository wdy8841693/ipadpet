import 'voice_engine.dart';
import 'wake_matcher.dart';

/// 本地语音引擎的工作模式（§7.2）。
///
/// 与原生层一一对应：原生侧只知道自己处于哪种采集/识别模式，
/// 「这句话算不算唤醒」「这句话算不算指令」由 Dart 侧判断。
enum VoiceEngineMode {
  /// 不采集、不识别。
  idle,

  /// 常驻待机：只关心有没有命中唤醒词。
  wake,

  /// 正在聆听指令。
  listen,
}

/// 原生语音层给的原始事件（还没有产品语义）。
sealed class RawVoiceEvent {
  const RawVoiceEvent();
}

/// 中间识别结果（这句话还没说完）。
class RawPartialEvent extends RawVoiceEvent {
  const RawPartialEvent({required this.text});

  final String text;
}

/// 最终识别结果（引擎认为这句话说完了）。
class RawFinalEvent extends RawVoiceEvent {
  const RawFinalEvent({required this.text, required this.confidence});

  final String text;
  final double confidence;
}

/// 原生层报错。
class RawErrorEvent extends RawVoiceEvent {
  const RawErrorEvent({
    required this.code,
    required this.message,
    this.retryable = true,
  });

  final String code;
  final String message;
  final bool retryable;
}

/// 致命错误代码：这些不是「没听清」，重试也没用，只能报错并退回待唤醒。
///
/// 原生层必须用这几个代码上报，跨平台行为才一致（§7.5）。
const Set<String> kFatalVoiceErrorCodes = <String>{
  'permission_denied',
  'not_available',
  'mic_unavailable',
  'engine_stalled',
};

/// 把「原生识别事件」翻译成「语义事件」的唯一地方（§7.2、§7.5）。
///
/// 为什么单独抽一层：
///
///   - 原生层只负责采集与识别，不认识「唤醒词」「指令」这些产品概念；
///   - 唤醒判定要复用 [WakeMatcher]（别名、宽松匹配、句首剥离），这是纯
///     Dart 逻辑，放在 core 里才能被 `dart test` 直接覆盖；
///   - 各平台（Android 系统识别 / macOS 系统识别 / 将来的 sherpa-onnx）
///     共用同一套路由，行为一致，出问题时好对照。
///
/// 状态机的两条硬规则（§7.2 的 generation 守卫在平台层，这里守的是语义）：
///
///   - 待机模式命中唤醒词后，本轮不再产生任何事件（避免「我在」播报期间
///     反复触发唤醒）；
///   - 聆听模式只认一个结果：出了 final 之后原生层补的收尾错误一律丢弃
///     （否则会出现「指令已经发出去了，界面又报一次没听清」）。
class VoiceEventRouter {
  VoiceEventRouter({List<String> wakePhrases = const <String>[]})
      : _wakePhrases = List<String>.unmodifiable(wakePhrases);

  List<String> _wakePhrases;

  VoiceEngineMode _mode = VoiceEngineMode.idle;

  /// 待机模式本轮是否已经命中过唤醒词。
  bool _wakeFired = false;

  /// 聆听模式本轮是否已经出结果（出结果 = 这一轮结束）。
  bool _listenClosed = false;

  /// 唤醒词表（主词 + 别名）。
  List<String> get wakePhrases => _wakePhrases;

  VoiceEngineMode get mode => _mode;

  /// 换唤醒词（服务端 `voice_config` 下来后调用，§11.3）。
  void setWakePhrases(List<String> phrases) {
    _wakePhrases = List<String>.unmodifiable(phrases);
  }

  /// 切换模式。进入待机/聆听时清掉上一轮的标记。
  void setMode(VoiceEngineMode mode) {
    _mode = mode;
    if (mode == VoiceEngineMode.wake) {
      _wakeFired = false;
    } else if (mode == VoiceEngineMode.listen) {
      _listenClosed = false;
    }
  }

  /// 路由一个原始事件，返回要交给协调器的语义事件（可能为空列表）。
  List<VoiceEngineEvent> route(RawVoiceEvent event) {
    if (_mode == VoiceEngineMode.idle) return const <VoiceEngineEvent>[];
    if (_mode == VoiceEngineMode.wake) return _routeWake(event);
    return _routeListen(event);
  }

  // -- 待机 -----------------------------------------------------------------

  List<VoiceEngineEvent> _routeWake(RawVoiceEvent event) {
    // 已经唤醒过了：这一轮剩下的内容全部忽略。
    if (_wakeFired) return const <VoiceEngineEvent>[];
    if (event is RawPartialEvent) return _matchWake(event.text);
    if (event is RawFinalEvent) return _matchWake(event.text);
    if (event is RawErrorEvent) {
      // 待机阶段的「没说话」「没听清」是常态（引擎自己会续上），
      // 不上报错误，也不该拿它去重启引擎。
      if (_isFatal(event.code)) {
        return <VoiceEngineEvent>[
          VoiceCaptureErrorEvent(code: event.code, message: event.message),
        ];
      }
      return const <VoiceEngineEvent>[];
    }
    return const <VoiceEngineEvent>[];
  }

  List<VoiceEngineEvent> _matchWake(String rawText) {
    final String text = rawText.trim();
    if (text.isEmpty) return const <VoiceEngineEvent>[];
    final String? keyword = WakeMatcher(_wakePhrases).match(text);
    if (keyword == null) return const <VoiceEngineEvent>[];
    _wakeFired = true;
    return <VoiceEngineEvent>[
      VoiceWakeDetectedEvent(
        keyword: keyword,
        // 系统识别不区分「唤醒词置信度」，给一个固定的中等值方便上层观察。
        confidence: 0.6,
      ),
    ];
  }

  // -- 聆听 -----------------------------------------------------------------

  List<VoiceEngineEvent> _routeListen(RawVoiceEvent event) {
    // 一轮聆听只认一个结果：final 之后原生层还会补一条收尾错误，
    // 这里直接丢弃，避免把已经发出去的指令又变成一次错误提示。
    if (_listenClosed) return const <VoiceEngineEvent>[];
    if (event is RawPartialEvent) {
      final String text = event.text.trim();
      if (text.isEmpty) return const <VoiceEngineEvent>[];
      return <VoiceEngineEvent>[VoicePartialTranscriptEvent(text: text)];
    }
    if (event is RawFinalEvent) {
      _listenClosed = true;
      final String text = event.text.trim();
      if (text.isEmpty) {
        return <VoiceEngineEvent>[
          VoiceRecognitionErrorEvent(
            code: 'empty_result',
            message: '没听清',
            retryable: true,
          ),
        ];
      }
      return <VoiceEngineEvent>[
        VoiceFinalTranscriptEvent(text: text, confidence: event.confidence),
      ];
    }
    if (event is RawErrorEvent) {
      if (_isFatal(event.code)) {
        _listenClosed = true;
        return <VoiceEngineEvent>[
          VoiceCaptureErrorEvent(code: event.code, message: event.message),
        ];
      }
      // 可恢复错误（「没听清」）：这一轮还没结束，原生层会续上识别，
      // 用户可以接着说，所以不关闭聆听。
      return <VoiceEngineEvent>[
        VoiceRecognitionErrorEvent(
          code: event.code,
          message: event.message,
          retryable: event.retryable,
        ),
      ];
    }
    return const <VoiceEngineEvent>[];
  }

  static bool _isFatal(String code) => kFatalVoiceErrorCodes.contains(code);
}
