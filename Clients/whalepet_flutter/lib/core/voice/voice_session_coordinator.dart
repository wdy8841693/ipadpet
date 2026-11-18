import 'dart:async';

import '../agent/agent_protocol.dart';
import '../pet/pet_state.dart';
import 'speech_output.dart';
import 'speech_queue.dart';
import 'spoken_command.dart';
import 'voice_engine.dart';
import 'wake_matcher.dart';

/// 语音会话状态（§7.2）。
///
/// 按文档两阶段实现里的「第一阶段」与「第二阶段」并行：
/// - 第一阶段：`等待唤醒 →（说「我在」）→ 聆听指令 → Agent 执行 → 播报 → 回到等待唤醒`；
/// - 第二阶段（§7.7）：唤醒词后面直接跟了指令时，跳过「我在」，直接发命令。
enum VoiceSessionState {
  disabled,
  preparing,
  waitingWake,
  listening,
  recognizing,
  thinking,
  speaking,
  error,
}

/// 协调器给 UI 的事件（UI 只读，不反向改状态机）。
sealed class CoordinatorEvent {
  const CoordinatorEvent({this.generation = 0});
  final int generation;
}

/// 头顶气泡。
class CoordinatorBubbleEvent extends CoordinatorEvent {
  const CoordinatorBubbleEvent({
    required this.text,
    this.seconds = 5,
    super.generation,
  });

  final String text;
  final double seconds;
}

/// 中间识别文本（只上屏，不发指令）。
class CoordinatorTranscriptEvent extends CoordinatorEvent {
  const CoordinatorTranscriptEvent({required this.text, super.generation});
  final String text;
}

/// 聊天面板一行。
class CoordinatorChatEvent extends CoordinatorEvent {
  const CoordinatorChatEvent({
    required this.fromUser,
    required this.text,
    super.generation,
  });

  final bool fromUser;
  final String text;
}

/// 宠物立绘状态。
class CoordinatorPetStateEvent extends CoordinatorEvent {
  const CoordinatorPetStateEvent({required this.state, super.generation});
  final PetState state;
}

/// 可恢复/不可恢复的错误。
class CoordinatorErrorEvent extends CoordinatorEvent {
  const CoordinatorErrorEvent({required this.message, super.generation});
  final String message;
}

/// 一条 Agent 命令在客户端的生命周期。
///
/// 不能只靠 [_activeRequestId]：断线/音频中断时它会清空，而服务端任务仍在跑；
/// cancel 后它也会清空，而迟到 response 必须被丢弃。请求账本负责区分这两种情况。
enum _AgentRequestState { active, completed, cancelled }

/// 客户端语音状态机的**唯一所有者**（§7.1）。
///
/// 职责：唤醒、聆听、识别、发命令、等回答、排队播报、闭麦与恢复、取消。
/// 服务端不再维护新客户端的 waiting/listening 状态。
///
/// 所有异步回调都带 `generation`：停止/取消/重连后迟到的识别、TTS、Agent 事件
/// 一律丢弃（对应 iOS 端已经踩过的「双 WebSocket、双音频引擎」坑，§7.2）。
class VoiceSessionCoordinator {
  VoiceSessionCoordinator({
    required this.engine,
    required this.speech,
    required this.queue,
    required VoiceEngineConfig config,
    required bool Function() speakEnabled,
    required Future<void> Function({
      required String requestId,
      required String text,
      required String source,
    }) sendCommand,
    required Future<void> Function(String requestId) cancelCommand,
    this.speechResumeDelay = const Duration(milliseconds: 250),
  })  : _config = config,
        _speakEnabled = speakEnabled,
        _sendCommand = sendCommand,
        _cancelCommand = cancelCommand {
    _engineSubscription = engine.events.listen(_onEngineEvent);
    _speechSubscription = speech.events.listen(_onSpeechEvent);
  }

  final VoiceEngineAdapter engine;
  final SpeechOutputAdapter speech;
  final SpeechQueue queue;
  final bool Function() _speakEnabled;
  final Future<void> Function({
    required String requestId,
    required String text,
    required String source,
  }) _sendCommand;
  final Future<void> Function(String requestId) _cancelCommand;
  final Duration speechResumeDelay;

  VoiceEngineConfig _config;
  VoiceEngineConfig get config => _config;

  final StreamController<CoordinatorEvent> _events =
      StreamController<CoordinatorEvent>.broadcast();
  final StreamController<VoiceSessionState> _states =
      StreamController<VoiceSessionState>.broadcast();

  Stream<CoordinatorEvent> get events => _events.stream;
  Stream<VoiceSessionState> get states => _states.stream;

  VoiceSessionState _state = VoiceSessionState.disabled;
  VoiceSessionState get state => _state;

  /// 语音开关与宠物状态是两件事：关掉语音后，文本对话仍要走同一套回答/播报队列。
  bool _enabled = false;
  bool get enabled => _enabled;
  bool get isSpeaking => _speaking;

  int _generation = 0;
  int get generation => _generation;
  bool _disposed = false;
  bool _engineReady = false;
  bool _speaking = false;
  String? _speakingId;
  VoiceSessionState _resumeAfterSpeech = VoiceSessionState.waitingWake;
  int _speechGeneration = 0;

  /// 引擎当前实际生效的配置版本；与服务端/设置里的 revision 不一致就要重建语法。
  int _engineRevision = -1;

  /// 退到后台时置位：采集已停，但语音开关本身没被用户关掉（§10.1）。
  bool _suspended = false;
  bool get suspended => _suspended;

  String? _activeRequestId;
  int _activeGeneration = 0;

  /// 请求账本：只接受仍为 active 的 response/error；
  /// cancelled 的迟到结果直接丢弃，completed 防止重复播报。
  final Map<String, _AgentRequestState> _agentRequests =
      <String, _AgentRequestState>{};

  /// 本地语音自己的播报序号。唤醒应答每轮都要重新播，不能只靠 session
  /// generation 拼 id：同一轮会话里 generation 不变，队列会把它当重复项吞掉
  /// （真机现象：第一次唤醒有「我在」，之后每次唤醒都静默地直接进入聆听）。
  int _utteranceSeq = 0;
  Timer? _listenTimer;

  StreamSubscription<VoiceEngineEvent>? _engineSubscription;
  StreamSubscription<SpeechOutputEvent>? _speechSubscription;

  // -- 生命周期 -------------------------------------------------------------

  /// 开启语音：初始化引擎 → 常驻 KWS。
  Future<void> enable() async {
    if (_disposed) return;
    final int gen = ++_generation;
    _suspended = false;
    await _startEngine(gen);
  }

  /// 初始化引擎并进入待唤醒。
  ///
  /// [enable] / 回到前台 [resume] / 中断恢复都走这一条路径，
  /// 避免三处各写一份「初始化 → 起 KWS → 回待唤醒」而走出三种行为。
  Future<void> _startEngine(int gen, {bool announce = true}) async {
    if (_disposed || gen != _generation) return;
    final VoiceEngineConfig snapshot = config;
    _setState(VoiceSessionState.preparing);
    try {
      await engine.initialize(snapshot);
      if (_disposed || gen != _generation) return;
      _engineReady = true;
      _enabled = true;
      // 引擎已经按这份配置建好语法，标记为「干净」：
      // 否则启动时 setConfig（revision 0 → 1）留下的脏标记会让第一轮回答
      // 结束后白重建一次引擎，而重建路径又会把状态机卡在 speaking。
      _engineRevision = snapshot.revision;
      await engine.startWakeListening();
      if (_disposed || gen != _generation) return;
      _setState(VoiceSessionState.waitingWake);
      if (announce) {
        _emit(CoordinatorBubbleEvent(
          text: '语音就绪，说「${config.wakePhrase}」叫我～',
          seconds: 5,
          generation: gen,
        ));
      }
      _emit(CoordinatorPetStateEvent(state: PetState.idle, generation: gen));
    } catch (error) {
      if (_disposed || gen != _generation) return;
      _engineReady = false;
      _setState(VoiceSessionState.error);
      _emit(CoordinatorErrorEvent(message: '语音引擎起不来：$error', generation: gen));
    }
  }

  /// 退到后台：停采集、停播报，但**保留语音开关**（§10.1）。
  ///
  /// 与 [disable] 的区别：用户主动关语音和「切到后台」是两件事，
  /// 后者回到前台应该按原设置恢复（§10.1「回来按用户设置恢复」），
  /// 顺便也避免每次切后台都冒一句「语音关掉啦」。
  Future<void> suspend() async {
    if (_disposed || _suspended) return;
    _suspended = true;
    final int gen = ++_generation;
    _listenTimer?.cancel();
    queue.clear();
    _speaking = false;
    _speakingId = null;
    _activeRequestId = null;
    await speech.stop();
    await engine.stopListening();
    if (gen != _generation) return;
    _setState(VoiceSessionState.disabled);
    _emit(CoordinatorPetStateEvent(state: PetState.idle, generation: gen));
  }

  /// 回到前台：恢复退后台前的语音状态（§10.1）。
  Future<void> resume() async {
    if (_disposed || !_suspended) return;
    _suspended = false;
    if (!_enabled) {
      _setState(VoiceSessionState.disabled);
      return;
    }
    final int gen = ++_generation;
    await _startEngine(gen, announce: false);
  }

  /// 关闭语音：停止采集、识别与播报，宠物回到普通离线状态。
  Future<void> disable() async {
    if (_disposed) return;
    final int gen = ++_generation;
    _enabled = false;
    _suspended = false;
    _engineRevision = -1;
    _listenTimer?.cancel();
    queue.clear();
    _speaking = false;
    _speakingId = null;
    _activeRequestId = null;
    await speech.stop();
    await engine.stopListening();
    _setState(VoiceSessionState.disabled);
    _emit(CoordinatorPetStateEvent(state: PetState.idle, generation: gen));
    _emit(CoordinatorBubbleEvent(text: '语音关掉啦，想说话随时开～', generation: gen));
  }

  /// 手动点击麦克风：跳过 KWS，直接聆听。
  Future<void> manualListen() async {
    if (_disposed) return;
    _suspended = false;
    if (!_engineReady) {
      await enable();
      if (!_engineReady) return;
    }
    final int gen = ++_generation;
    queue.clear();
    await engine.startManualListening();
    if (gen != _generation) return;
    _setState(VoiceSessionState.listening);
    _emit(CoordinatorPetStateEvent(state: PetState.listening, generation: gen));
    _emit(CoordinatorBubbleEvent(text: '我在听～', seconds: 4, generation: gen));
    _armListenTimeout(gen);
  }

  /// 取消当前这一轮：停本地等待/TTS，向服务端发 cancel（不谎称远程任务已终止）。
  Future<void> cancel() async {
    if (_disposed) return;
    final int gen = ++_generation;
    _listenTimer?.cancel();
    queue.clear();
    _speaking = false;
    _speakingId = null;
    final String? requestId = _activeRequestId;
    _activeRequestId = null;
    // 标记取消后，服务端即使还在后台执行并在稍后返回 response，也不能上屏或播报。
    if (requestId != null) {
      _agentRequests[requestId] = _AgentRequestState.cancelled;
    }
    await speech.stop();
    await engine.stopListening();
    if (requestId != null) {
      await _cancelCommand(requestId);
    }
    if (gen != _generation) return;
    if (enabled) {
      await _resumeWake(gen);
    }
    _emit(CoordinatorBubbleEvent(text: '好，先不说了', seconds: 3, generation: gen));
  }

  /// 服务端下发的语音配置（§11.3）：revision 变化要在安全点重建 KWS 语法。
  void setConfig(VoiceEngineConfig next) {
    if (_sameVoice(next, _config)) return;
    _config = next;
    if (_enabled && _state == VoiceSessionState.waitingWake) {
      unawaited(_rebuildEngine());
    }
    // 其它状态（聆听/播报/一轮未结束）不在这里动手：重建会和识别交叉，
    // 留到本轮收尾的 _resumeWake 再统一重建。
  }

  static bool _sameVoice(VoiceEngineConfig a, VoiceEngineConfig b) {
    if (a.revision != b.revision ||
        a.wakePhrase != b.wakePhrase ||
        a.wakeAck != b.wakeAck ||
        a.listenTimeoutMs != b.listenTimeoutMs ||
        a.wakeAliases.length != b.wakeAliases.length) {
      return false;
    }
    for (int i = 0; i < a.wakeAliases.length; i++) {
      if (a.wakeAliases[i] != b.wakeAliases[i]) return false;
    }
    return true;
  }

  /// 配置（唤醒词/应答/revision）变了才需要重建；引擎建好即视为干净。
  bool get _configDirty => _engineRevision != _config.revision;

  /// 重建引擎。可以在任意状态调用：会先停识别、再初始化、最后回到待唤醒。
  Future<void> _rebuildEngine() async {
    if (_disposed || !_enabled) return;
    final int gen = ++_generation;
    final VoiceEngineConfig snapshot = config;
    _setState(VoiceSessionState.preparing);
    try {
      await engine.stopListening();
      await engine.initialize(snapshot);
      if (_disposed || gen != _generation) return;
      _engineReady = true;
      _engineRevision = snapshot.revision;
      await engine.startWakeListening();
      if (_disposed || gen != _generation) return;
      _setState(VoiceSessionState.waitingWake);
      _emit(CoordinatorPetStateEvent(state: PetState.idle, generation: gen));
    } catch (error) {
      if (_disposed) return;
      _engineReady = false;
      _setState(VoiceSessionState.error);
      _emit(CoordinatorErrorEvent(message: '唤醒词更新失败：$error', generation: gen));
    }
  }

  /// 聊天面板 / 其它入口提交文本命令。
  Future<void> submitText(String raw) async {
    final String? text = normalizeCommandText(raw);
    if (text == null) return;
    final int gen = ++_generation;
    _listenTimer?.cancel();
    _emit(CoordinatorChatEvent(fromUser: true, text: text, generation: gen));
    await _dispatchCommand(text, gen);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    _listenTimer?.cancel();
    queue.clear();
    _agentRequests.clear();
    await _engineSubscription?.cancel();
    await _speechSubscription?.cancel();
    await speech.stop();
    await engine.stopListening();
    await engine.dispose();
    await _events.close();
    await _states.close();
  }

  // -- 语音引擎事件 ---------------------------------------------------------

  void _onEngineEvent(VoiceEngineEvent event) {
    if (_disposed || !enabled) return;
    // 注意：`event.generation` 是**引擎自己的命令编号**（每 start/stop 一次 +1），
    // 和协调器这边的会话 generation 不是同一个计数器，绝不能互相比较。
    // 早先这里写成 `if (event.generation != _generation) return;`，结果
    // 「唤醒(引擎 1) → 闭麦(2) → 聆听(3)」之后引擎带着 3 报上来的 FINAL
    // 全被当成迟到事件丢掉，表现就是「能唤醒、能出识别文本，但指令永远发不出去」。
    // 过期结果的过滤由引擎自己做（mode/gen 双重校验），这里只按状态兜底。
    final int gen = _generation;

    switch (event) {
      case VoiceEngineReadyEvent():
        _engineReady = true;
      case VoiceWakeDetectedEvent():
        if (_state == VoiceSessionState.waitingWake) {
          _onWake(event, gen);
        }
      case VoicePartialTranscriptEvent():
        if (_state == VoiceSessionState.listening) {
          _emit(CoordinatorTranscriptEvent(text: event.text, generation: gen));
        }
      case VoiceFinalTranscriptEvent():
        if (_state == VoiceSessionState.listening ||
            _state == VoiceSessionState.recognizing) {
          _onFinalTranscript(event, gen);
        }
      case VoiceRecognitionErrorEvent():
        _onRecognitionError(event, gen);
      case VoiceCaptureErrorEvent():
        _onCaptureError(event, gen);
      case VoiceInterruptionEvent():
        _onInterruption(event, gen);
      case VoiceEngineRecoveredEvent():
        _onEngineRecovered(event, gen);
    }
  }

  void _onWake(VoiceWakeDetectedEvent event, int gen) {
    _listenTimer?.cancel();
    // §7.7 一句话带命令：整段 ASR 会把「小鲸小鲸，帮我查天气」整句返回，
    // 唤醒词后面已经跟着有效指令时，不必先播「我在」，直接发出去。
    final String? command = _effectiveCommand(event.trailingText);
    if (command != null) {
      _emit(CoordinatorChatEvent(fromUser: true, text: command, generation: gen));
      _emit(CoordinatorTranscriptEvent(text: '', generation: gen));
      unawaited(_dispatchCommand(command, gen, source: 'voice'));
      return;
    }
    _emit(CoordinatorBubbleEvent(
      text: '在呢，听着～',
      seconds: 3,
      generation: gen,
    ));
    if (config.wakeAck.trim().isEmpty) {
      _beginListening(gen);
      return;
    }
    // 先播「我在」，播完再进入聆听：speaking 必须携带 resumeAfterSpeech。
    _resumeAfterSpeech = VoiceSessionState.listening;
    queue.enqueue(SpeechItem(
      id: 'ack-${++_utteranceSeq}',
      text: config.wakeAck.trim(),
      priority: SpeechPriority.response,
    ));
    _pumpSpeech(gen);
  }

  /// 唤醒词后面那句话算不算一条有效指令；有效返回清理后的文本，否则 null。
  ///
  /// 引擎通常已经把唤醒词剥掉了，这里再剥一次是**幂等**的：
  /// 剥完还是原样（因为已经不在句首了），所以不会把指令削掉。
  String? _effectiveCommand(String raw) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    final String stripped = WakeMatcher(config.wakePhrases).strip(trimmed);
    if (!hasEffectiveContent(stripped)) return null;
    return stripped;
  }

  void _onFinalTranscript(VoiceFinalTranscriptEvent event, int gen) {
    _setState(VoiceSessionState.recognizing);
    final WakeMatcher matcher = WakeMatcher(config.wakePhrases);
    final String command = matcher.strip(event.text);
    // 空识别、或者只说了「嗯 / 帮我」这种语气词：都算「没听清」。
    if (!hasEffectiveContent(command)) {
      // 没超时就允许重说，超时回待唤醒。
      if (_state == VoiceSessionState.recognizing) {
        _emit(CoordinatorBubbleEvent(
          text: '没听清，再说一遍？',
          seconds: 4,
          generation: gen,
        ));
        // 只把状态改成 listening 不够：真实引擎的这一轮已经结束，
        // VoiceEventRouter 也可能关闭了本轮，必须真正重启采集/识别。
        unawaited(_beginListening(gen));
        return;
      }
      unawaited(_resumeWake(gen));
      return;
    }
    _emit(CoordinatorChatEvent(fromUser: true, text: command, generation: gen));
    _emit(CoordinatorTranscriptEvent(text: '', generation: gen));
    unawaited(_dispatchCommand(command, gen, source: 'voice'));
  }

  void _onRecognitionError(VoiceRecognitionErrorEvent event, int gen) {
    // 待唤醒阶段只开着唤醒小语法，说别的句子必然被拒——这是常态，不是错误，
    // 更不该拿它重启引擎（早期版本会在这里自我循环重启）。
    if (_state == VoiceSessionState.waitingWake) return;
    if (event.retryable && _state == VoiceSessionState.listening) {
      _emit(CoordinatorBubbleEvent(
        text: '刚刚没听清，再说一次～',
        seconds: 4,
        generation: gen,
      ));
      return;
    }
    _emit(CoordinatorErrorEvent(message: event.message, generation: gen));
    unawaited(_resumeWake(gen));
  }

  void _onCaptureError(VoiceCaptureErrorEvent event, int gen) {
    _engineReady = false;
    _setState(VoiceSessionState.error);
    _emit(CoordinatorErrorEvent(
      message: '麦克风不可用：${event.message}（文字对话仍然可用）',
      generation: gen,
    ));
    _emit(CoordinatorPetStateEvent(state: PetState.idle, generation: gen));
  }

  /// 采集被外部打断（来电、其它应用抢走音频）：这一轮作废，等引擎恢复。
  ///
  /// 不把它当成致命错误：引擎恢复后会发 [VoiceEngineRecoveredEvent]，
  /// 那时再重新初始化引擎回到待唤醒（§10.1）。
  void _onInterruption(VoiceInterruptionEvent event, int gen) {
    if (_state == VoiceSessionState.disabled) return;
    _listenTimer?.cancel();
    queue.clear();
    _speaking = false;
    _speakingId = null;
    _activeRequestId = null;
    _engineReady = false;
    // 不要在这里补 engine.stopListening()：打断事件本身就意味着引擎已经
    // 停了采集，原生侧还留着音频焦点/来电轮询等恢复信号。再 stop 一次会把
    // 恢复监听一起清掉，来电结束后永远等不到 VoiceEngineRecoveredEvent（§10.1）。
    _setState(VoiceSessionState.error);
    _emit(CoordinatorErrorEvent(
      message: '${event.message}（稍后会自动恢复，文字对话仍然可用）',
      generation: gen,
    ));
    _emit(CoordinatorPetStateEvent(state: PetState.idle, generation: gen));
  }

  /// 中断结束：重新初始化引擎，回到待唤醒。
  void _onEngineRecovered(VoiceEngineRecoveredEvent event, int gen) {
    if (_state != VoiceSessionState.error) return;
    if (!_enabled || _suspended || _disposed) return;
    final int next = ++_generation;
    unawaited(_startEngine(next, announce: false));
  }

  // -- 命令 ----------------------------------------------------------------

  Future<void> _dispatchCommand(
    String text,
    int gen, {
    String source = 'text',
  }) async {
    _listenTimer?.cancel();
    await engine.stopListening();
    if (gen != _generation) return;
    if (_enabled) _setState(VoiceSessionState.thinking);
    _emit(CoordinatorPetStateEvent(state: PetState.thinking, generation: gen));
    _emit(CoordinatorBubbleEvent(
      text: '收到，我这就去办～',
      seconds: 3,
      generation: gen,
    ));
    final String requestId = newRequestId();
    _activeRequestId = requestId;
    _activeGeneration = gen;
    _agentRequests[requestId] = _AgentRequestState.active;
    try {
      await _sendCommand(requestId: requestId, text: text, source: source);
    } catch (error) {
      if (gen != _generation) return;
      _activeRequestId = null;
      _agentRequests[requestId] = _AgentRequestState.completed;
      _emit(CoordinatorErrorEvent(message: '发送失败：$error', generation: gen));
      _settle(gen);
    }
  }

  /// 所有服务端事件都转发到这里（由 PetRuntime 统一订阅后调用）。
  void onAgentEvent(AgentServerEvent event) {
    if (_disposed) return;
    switch (event) {
      case AgentReadyEvent():
        break;
      case AgentVoiceConfigEvent():
        setConfig(config.copyWith(
          wakePhrase:
              event.wakePhrase.isEmpty ? config.wakePhrase : event.wakePhrase,
          wakeAliases: event.wakeAliases.isEmpty
              ? config.wakeAliases
              : event.wakeAliases,
          wakeAck: event.wakeAck,
          listenTimeoutMs: event.listenTimeoutMs,
          revision: event.revision,
        ));
      case AgentTaskEvent():
        _onTask(event);
      case AgentResponseEvent():
        _onResponse(event);
      case AgentAnnouncementEvent():
        _onAnnouncement(event);
      case AgentErrorEvent():
        _onAgentError(event);
      case AgentUnknownServerEvent():
        break;
    }
  }

  void _onTask(AgentTaskEvent event) {
    // 断线/音频中断会清空 _activeRequestId，但请求账本仍是 active；
    // cancel/completed 的请求则不能继续改变 UI 或播报状态。
    if (_agentRequests[event.requestId] != _AgentRequestState.active) return;
    final int gen = event.requestId == _activeRequestId
        ? _activeGeneration
        : _generation;
    switch (event.state) {
      case 'queued':
        _emit(CoordinatorBubbleEvent(
          text: event.text ?? '正在排队…',
          seconds: 4,
          generation: gen,
        ));
      case 'started':
        _setState(VoiceSessionState.thinking);
      case 'progress':
        // 长任务心跳：只刷新气泡告诉用户"还在跑"，不进播报队列——
        // 否则每隔几十秒就打断一次 TTS，反而吵。
        _emit(CoordinatorBubbleEvent(
          text: event.text ?? '还在处理中…',
          seconds: 5,
          generation: gen,
        ));
      case 'approval':
        queue.enqueue(SpeechItem(
          id: event.eventId ?? 'approval-${event.requestId}',
          text: event.text ?? '需要你确认一下',
          priority: SpeechPriority.completion,
          requestId: event.requestId,
        ));
        _pumpSpeech(gen);
      case 'finished':
        _activeRequestId = null;
        // 「做完了」由队列按 requestId 去重：正式回答念过就不再重复。
        queue.enqueue(SpeechItem(
          id: event.eventId ?? 'finish-${event.requestId}',
          text: event.text ?? '做完了',
          priority: SpeechPriority.completion,
          requestId: event.requestId,
        ));
        _pumpSpeech(gen, resume: VoiceSessionState.waitingWake);
      case 'failed':
        _activeRequestId = null;
        _agentRequests[event.requestId] = _AgentRequestState.completed;
        _emit(CoordinatorBubbleEvent(
          text: event.text ?? '出错了',
          seconds: 6,
          generation: gen,
        ));
        if (!_speaking) _settle(gen);
      case 'interrupted':
        // 服务端任务仍在后台继续：保留账本 active，稍后的 response 必须能上屏。
        _activeRequestId = null;
        _emit(CoordinatorBubbleEvent(
          text: event.text ?? '任务中断了',
          seconds: 6,
          generation: gen,
        ));
        if (!_speaking) _settle(gen);
      default:
        break;
    }
  }

  void _onResponse(AgentResponseEvent event) {
    // 取消、失败或已经播过的请求不再接受迟到结果。
    if (_agentRequests[event.requestId] != _AgentRequestState.active) return;
    _agentRequests[event.requestId] = _AgentRequestState.completed;
    final int gen = _activeRequestId == event.requestId
        ? _activeGeneration
        : _generation;
    if (event.requestId == _activeRequestId) _activeRequestId = null;
    if (event.displayText.trim().isNotEmpty) {
      _emit(CoordinatorChatEvent(
        fromUser: false,
        text: event.displayText.trim(),
        generation: gen,
      ));
    }
    final String speechText = event.speechText.trim().isNotEmpty
        ? event.speechText.trim()
        : event.displayText.trim();
    if (speechText.isNotEmpty) {
      _emit(CoordinatorBubbleEvent(
        text: speechText,
        seconds: 14,
        generation: gen,
      ));
      queue.enqueue(SpeechItem(
        id: event.eventId ?? 'resp-${event.requestId}',
        text: speechText,
        priority: SpeechPriority.response,
        requestId: event.requestId,
      ));
    }
    _pumpSpeech(gen, resume: VoiceSessionState.waitingWake);
  }

  void _onAnnouncement(AgentAnnouncementEvent event) {
    final String text = event.speechText.trim().isNotEmpty
        ? event.speechText.trim()
        : event.displayText.trim();
    if (text.isEmpty) return;
    queue.enqueue(SpeechItem(
      id: event.eventId ?? 'ann-${DateTime.now().microsecondsSinceEpoch}',
      text: text,
      priority: SpeechPriority.announcement,
    ));
    _pumpSpeech(_generation, resume: VoiceSessionState.waitingWake);
  }

  void _onAgentError(AgentErrorEvent event) {
    final String? requestId = event.requestId;
    if (requestId != null) {
      if (_agentRequests[requestId] != _AgentRequestState.active) return;
      _agentRequests[requestId] = _AgentRequestState.completed;
    }
    final int gen = requestId == _activeRequestId
        ? _activeGeneration
        : _generation;
    if (requestId != null && requestId == _activeRequestId) {
      _activeRequestId = null;
    }
    _emit(CoordinatorBubbleEvent(
      text: event.message.isEmpty ? '出错了' : event.message,
      seconds: 8,
      generation: gen,
    ));
    if (!_speaking) _settle(gen);
  }

  // -- 播报 ----------------------------------------------------------------

  void _pumpSpeech(int gen, {VoiceSessionState? resume}) {
    if (_disposed || gen != _generation) return;
    if (resume != null) _resumeAfterSpeech = resume;
    if (_speaking) return;
    if (!_speakEnabled()) {
      queue.clear();
      // 播报被关掉时，唤醒应答念不出来，但语音状态机照样要往前走：
      // 直接进入聆听，而不是退回待唤醒（否则「唤醒 → 说指令」整条链在
      // 关闭播报后是断的：说完「小鲸小鲸」就被丢回待机）。
      final VoiceSessionState target = _resumeAfterSpeech;
      if (target == VoiceSessionState.listening) {
        unawaited(_beginListening(gen));
      } else {
        _settle(gen);
      }
      return;
    }
    final SpeechItem? item = queue.take();
    if (item == null) {
      // 没有待播内容：不要让宠物卡在 thinking/speaking。
      if (_state != VoiceSessionState.listening) _settle(gen);
      return;
    }
    _speaking = true;
    _speakingId = item.id;
    _speechGeneration = gen;
    if (_enabled) _setState(VoiceSessionState.speaking);
    _emit(CoordinatorPetStateEvent(state: PetState.speaking, generation: gen));
    // 播报期间闭麦，防止自己把自己唤醒（§7.8）。
    unawaited(engine.stopListening());
    unawaited(
      speech.speak(item.id, item.text).catchError((Object error) {
        _emit(CoordinatorErrorEvent(message: '播报失败：$error', generation: gen));
        _finishUtterance(item.id, gen);
      }).whenComplete(() => _finishUtterance(item.id, gen)),
    );
  }

  void _onSpeechEvent(SpeechOutputEvent event) {
    if (_disposed) return;
    if (event.kind == SpeechOutputEventKind.finished ||
        event.kind == SpeechOutputEventKind.failed) {
      if (event.utteranceId == _speakingId) {
        _finishUtterance(event.utteranceId, _speechGeneration);
      }
    }
  }

  /// 幂等：TTS 的 Future 完成与事件流的 finished 可能都到。
  void _finishUtterance(String id, int gen) {
    if (!_speaking || _speakingId != id || gen != _generation) return;
    _speaking = false;
    _speakingId = null;
    if (!queue.isEmpty) {
      _pumpSpeech(gen);
      return;
    }
    final VoiceSessionState target = _resumeAfterSpeech;
    Timer(speechResumeDelay, () {
      if (_disposed || gen != _generation || _speaking) return;
      if (_enabled && target == VoiceSessionState.listening) {
        _beginListening(gen);
      } else {
        _settle(gen);
      }
    });
  }

  // -- 状态工具 -------------------------------------------------------------

  Future<void> _beginListening(int gen) async {
    if (_disposed || gen != _generation || !enabled) return;
    await engine.startManualListening();
    if (gen != _generation) return;
    _setState(VoiceSessionState.listening);
    _emit(CoordinatorPetStateEvent(state: PetState.listening, generation: gen));
    _armListenTimeout(gen);
  }

  void _armListenTimeout(int gen) {
    _listenTimer?.cancel();
    _listenTimer = Timer(Duration(milliseconds: config.listenTimeoutMs), () {
      if (_disposed || gen != _generation) return;
      if (_state != VoiceSessionState.listening) return;
      _emit(CoordinatorBubbleEvent(
        text: '没听到指令，我先待机啦',
        seconds: 4,
        generation: gen,
      ));
      unawaited(_resumeWake(gen));
    });
  }

  /// 一轮结束后的落点：语音开着就回待唤醒，关着就只把宠物放回待机。
  void _settle(int gen) {
    if (_disposed || gen != _generation) return;
    if (_enabled) {
      unawaited(_resumeWake(gen));
    } else {
      _setState(VoiceSessionState.disabled);
      _emit(CoordinatorPetStateEvent(state: PetState.idle, generation: gen));
    }
  }

  Future<void> _resumeWake(int gen) async {
    if (_disposed || gen != _generation) return;
    _listenTimer?.cancel();
    if (_configDirty && _state != VoiceSessionState.preparing) {
      await _rebuildEngine();
      return;
    }

    if (!_engineReady) {
      _setState(VoiceSessionState.error);
      return;
    }
    await engine.startWakeListening();
    if (gen != _generation) return;
    _setState(VoiceSessionState.waitingWake);
    _emit(CoordinatorPetStateEvent(state: PetState.idle, generation: gen));
  }

  void _setState(VoiceSessionState next) {
    if (_state == next) return;
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  void _emit(CoordinatorEvent event) {
    if (!_events.isClosed) _events.add(event);
  }
}
