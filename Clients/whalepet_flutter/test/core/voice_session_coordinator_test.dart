import 'dart:async';

import 'package:test/test.dart';
import 'package:whalepet_flutter/core/agent/agent_protocol.dart';
import 'package:whalepet_flutter/core/pet/pet_state.dart';
import 'package:whalepet_flutter/core/voice/speech_output.dart';
import 'package:whalepet_flutter/core/voice/speech_queue.dart';
import 'package:whalepet_flutter/core/voice/voice_engine.dart';
import 'package:whalepet_flutter/core/voice/voice_session_coordinator.dart';

class FakeVoiceEngine implements VoiceEngineAdapter {
  final StreamController<VoiceEngineEvent> _controller =
      StreamController<VoiceEngineEvent>.broadcast();
  final List<String> log = <String>[];
  VoiceEngineConfig? lastConfig;

  @override
  Stream<VoiceEngineEvent> get events => _controller.stream;

  @override
  Future<void> initialize(VoiceEngineConfig config) async {
    lastConfig = config;
    log.add('init');
  }

  @override
  Future<void> startWakeListening() async => log.add('wake');

  @override
  Future<void> startManualListening() async => log.add('listen');

  @override
  Future<void> stopListening() async => log.add('stop');

  @override
  Future<void> dispose() async => log.add('dispose');

  void emit(VoiceEngineEvent event) => _controller.add(event);
}

class FakeSpeech implements SpeechOutputAdapter {
  final StreamController<SpeechOutputEvent> _controller =
      StreamController<SpeechOutputEvent>.broadcast();
  final List<String> spoken = <String>[];
  final Map<String, Completer<void>> _pending = <String, Completer<void>>{};
  bool autoFinish;

  FakeSpeech({this.autoFinish = true});

  @override
  Stream<SpeechOutputEvent> get events => _controller.stream;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> speak(String utteranceId, String text) async {
    spoken.add(text);
    if (autoFinish) {
      _controller.add(SpeechOutputEvent(
        kind: SpeechOutputEventKind.finished,
        utteranceId: utteranceId,
      ));
      return;
    }
    // 与真实适配层一致：说完了才 Future 完成（播报中是「悬着」的状态）。
    final Completer<void> completer = Completer<void>();
    _pending[utteranceId] = completer;
    await completer.future;
  }

  void finish(String utteranceId) {
    _controller.add(SpeechOutputEvent(
      kind: SpeechOutputEventKind.finished,
      utteranceId: utteranceId,
    ));
    final Completer<void>? completer = _pending.remove(utteranceId);
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {}
}

class Rig {
  Rig({
    bool speakEnabled = true,
    bool autoFinishSpeech = true,
    VoiceEngineConfig config = const VoiceEngineConfig(),
    Duration resumeDelay = Duration.zero,
  }) {
    speech.autoFinish = autoFinishSpeech;
    coordinator = VoiceSessionCoordinator(
      engine: engine,
      speech: speech,
      queue: SpeechQueue(),
      config: config,
      speakEnabled: () => speakEnabled,
      speechResumeDelay: resumeDelay,
      sendCommand: ({
        required String requestId,
        required String text,
        required String source,
      }) async {
        sent.add(<String, String>{
          'request_id': requestId,
          'text': text,
          'source': source,
        });
      },
      cancelCommand: (String requestId) async => cancelled.add(requestId),
    );
    uiEvents = <CoordinatorEvent>[];
    uiSubscription = coordinator.events.listen(uiEvents.add);
  }

  final FakeVoiceEngine engine = FakeVoiceEngine();
  final FakeSpeech speech = FakeSpeech();
  final List<Map<String, String>> sent = <Map<String, String>>[];
  final List<String> cancelled = <String>[];
  late final VoiceSessionCoordinator coordinator;
  late final List<CoordinatorEvent> uiEvents;
  late final StreamSubscription<CoordinatorEvent> uiSubscription;

  Future<void> pump() async {
    for (int i = 0; i < 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 4));
    }
  }

  List<String> get bubbles => uiEvents
      .whereType<CoordinatorBubbleEvent>()
      .map((CoordinatorBubbleEvent e) => e.text)
      .toList(growable: false);

  List<ChatLike> get chatLines => uiEvents
      .whereType<CoordinatorChatEvent>()
      .map((CoordinatorChatEvent e) => ChatLike(e.fromUser, e.text))
      .toList(growable: false);

  Future<void> dispose() async {
    await uiSubscription.cancel();
    await coordinator.dispose();
  }
}

class ChatLike {
  const ChatLike(this.fromUser, this.text);
  final bool fromUser;
  final String text;
}

AgentResponseEvent responseFor(String requestId, {String speech = '结果是晴天'}) =>
    AgentResponseEvent(
      eventId: 'evt-$requestId',
      requestId: requestId,
      displayText: '**结果**：晴天',
      speechText: speech,
      isFinal: true,
      receivedAt: DateTime.now().toUtc(),
    );

AgentTaskEvent taskFor(String requestId, String state, {String? text}) =>
    AgentTaskEvent(
      eventId: 'evt-task-$requestId-$state',
      requestId: requestId,
      state: state,
      text: text ?? state,
      receivedAt: DateTime.now().toUtc(),
    );

void main() {
  group('VoiceSessionCoordinator', () {
    test('完整闭环：唤醒 → 应答 → 聆听 → 命令 → 回答 → 播报 → 回待唤醒', () async {
      final Rig rig = Rig();
      await rig.coordinator.enable();
      expect(rig.coordinator.state, VoiceSessionState.waitingWake);
      expect(rig.engine.log, contains('wake'));

      rig.engine.emit(const VoiceWakeDetectedEvent(keyword: '小鲸小鲸', confidence: 0.8));
      await rig.pump();
      expect(rig.speech.spoken, contains('我在'));
      expect(rig.coordinator.state, VoiceSessionState.listening);
      // 播报期间必须闭麦。
      expect(rig.engine.log, contains('stop'));

      rig.engine.emit(const VoiceFinalTranscriptEvent(
        text: '小鲸小鲸，帮我查天气',
        confidence: 0.8,
      ));
      await rig.pump();
      expect(rig.sent, hasLength(1));
      expect(rig.sent.single['text'], '帮我查天气');
      expect(rig.sent.single['source'], 'voice');

      final String requestId = rig.sent.single['request_id']!;
      rig.coordinator.onAgentEvent(taskFor(requestId, 'started'));
      rig.coordinator.onAgentEvent(responseFor(requestId));
      await rig.pump();
      expect(rig.speech.spoken, contains('结果是晴天'));
      expect(rig.chatLines.where((ChatLike l) => !l.fromUser), hasLength(1));
      expect(rig.coordinator.state, VoiceSessionState.waitingWake);
      expect(rig.engine.log.last, 'wake');
      await rig.dispose();
    });

    test('回答之后再收到 finished，不重复念「做完了」', () async {
      final Rig rig = Rig();
      await rig.coordinator.enable();
      rig.engine.emit(const VoiceWakeDetectedEvent(keyword: '小鲸小鲸', confidence: 0.9));
      await rig.pump();
      rig.engine.emit(const VoiceFinalTranscriptEvent(text: '查天气', confidence: 0.8));
      await rig.pump();
      final String requestId = rig.sent.single['request_id']!;
      rig.coordinator.onAgentEvent(responseFor(requestId));
      await rig.pump();
      rig.coordinator.onAgentEvent(taskFor(requestId, 'finished', text: '做完了'));
      await rig.pump();
      expect(rig.speech.spoken, isNot(contains('做完了')));
      await rig.dispose();
    });

    test('手动麦克风跳过唤醒词', () async {
      final Rig rig = Rig();
      await rig.coordinator.manualListen();
      expect(rig.coordinator.state, VoiceSessionState.listening);
      expect(rig.engine.log, contains('listen'));
      rig.engine.emit(const VoiceFinalTranscriptEvent(text: '几点了', confidence: 0.7));
      await rig.pump();
      expect(rig.sent.single['text'], '几点了');
      await rig.dispose();
    });

    test('连续两轮唤醒都要播「我在」', () async {
      // 应答 id 如果只按 session generation 拼，第二轮就会被播报队列当成
      // 重复项吞掉：真机现象是第一次唤醒有回应，之后每次唤醒都静默聆听。
      final Rig rig = Rig();
      await rig.coordinator.enable();
      rig.engine.emit(const VoiceWakeDetectedEvent(keyword: '小金小金', confidence: 0.9));
      await rig.pump();
      expect(rig.speech.spoken.where((String t) => t == '我在'), hasLength(1));

      rig.engine.emit(const VoiceFinalTranscriptEvent(text: '查天气', confidence: 0.8));
      await rig.pump();
      final String requestId = rig.sent.single['request_id']!;
      rig.coordinator.onAgentEvent(responseFor(requestId));
      await rig.pump();
      expect(rig.coordinator.state, VoiceSessionState.waitingWake);

      rig.engine.emit(const VoiceWakeDetectedEvent(keyword: '小金小金', confidence: 0.9));
      await rig.pump();
      expect(rig.speech.spoken.where((String t) => t == '我在'), hasLength(2));
      await rig.dispose();
    });

    test('待唤醒时唤醒语法拒识不算错误，也不重启引擎', () async {
      final Rig rig = Rig();
      await rig.coordinator.enable();
      final int wakeCalls = rig.engine.log.where((String e) => e == 'wake').length;
      rig.engine.emit(const VoiceRecognitionErrorEvent(
        code: 'rejected',
        message: '识别被拒绝',
        retryable: true,
      ));
      await rig.pump();
      expect(rig.uiEvents.whereType<CoordinatorErrorEvent>(), isEmpty);
      expect(rig.engine.log.where((String e) => e == 'wake').length, wakeCalls);
      expect(rig.coordinator.state, VoiceSessionState.waitingWake);
      await rig.dispose();
    });

    test('空识别允许重说；聆听超时回待唤醒', () async {
      final Rig rig = Rig(
        config: const VoiceEngineConfig(listenTimeoutMs: 30),
      );
      await rig.coordinator.enable();
      await rig.coordinator.manualListen();
      rig.engine.emit(const VoiceFinalTranscriptEvent(
        text: '小鲸小鲸',
        confidence: 0.9,
      ));
      await rig.pump();
      expect(rig.sent, isEmpty);
      expect(rig.bubbles, contains('没听清，再说一遍？'));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await rig.pump();
      expect(rig.coordinator.state, VoiceSessionState.waitingWake);
      await rig.dispose();
    });

    test('引擎侧编号与会话 generation 不同也要照常派发命令（回归）', () async {
      // 真实引擎里 generation 是「第几条控制命令」：唤醒=1、闭麦=2、聆听=3，
      // 而协调器的会话 generation 一次 enable 只 +1。两者一旦被拿来互相比较，
      // 唤醒后的 FINAL 就会被当成迟到事件丢弃——真机表现是「能唤醒、能识别，
      // 但指令永远发不出去」。这个用例锁死这个行为。
      final Rig rig = Rig();
      await rig.coordinator.enable();
      rig.engine.emit(const VoiceWakeDetectedEvent(
        generation: 1,
        keyword: '小金小金',
        confidence: 0.9,
      ));
      await rig.pump();
      expect(rig.coordinator.state, VoiceSessionState.listening);

      rig.engine.emit(const VoiceFinalTranscriptEvent(
        generation: 3,
        text: '孝敬孝敬帮我查一下明天的安排',
        confidence: 0.56,
      ));
      await rig.pump();
      expect(rig.sent, hasLength(1));
      expect(rig.sent.single['text'], '孝敬孝敬帮我查一下明天的安排');
      expect(rig.sent.single['source'], 'voice');
      expect(
        rig.uiEvents.whereType<CoordinatorPetStateEvent>().map(
            (CoordinatorPetStateEvent e) => e.state).toList(),
        contains(PetState.thinking),
      );
      await rig.dispose();
    });

    test('cancel 后迟到的识别事件被丢弃（状态已回待唤醒）', () async {
      final Rig rig = Rig();
      await rig.coordinator.enable();
      await rig.coordinator.manualListen();
      final int staleGeneration = rig.coordinator.generation;
      await rig.coordinator.cancel();
      rig.engine.emit(VoiceFinalTranscriptEvent(
        generation: staleGeneration,
        text: '迟到的指令',
        confidence: 0.9,
      ));
      await rig.pump();
      expect(rig.sent, isEmpty);
      expect(rig.cancelled, isEmpty);
      await rig.dispose();
    });

    test('取消正在跑的命令会向服务端发 cancel', () async {
      final Rig rig = Rig();
      await rig.coordinator.manualListen();
      rig.engine.emit(const VoiceFinalTranscriptEvent(text: '跑个长任务', confidence: 0.8));
      await rig.pump();
      await rig.coordinator.cancel();
      expect(rig.cancelled, hasLength(1));
      await rig.dispose();
    });

    test('语音关闭时文本命令仍然进 Agent 且回答照常播报', () async {
      final Rig rig = Rig();
      await rig.coordinator.submitText('帮我写个邮件');
      expect(rig.sent.single['text'], '帮我写个邮件');
      expect(rig.sent.single['source'], 'text');
      rig.coordinator.onAgentEvent(responseFor(rig.sent.single['request_id']!));
      await rig.pump();
      expect(rig.speech.spoken, contains('结果是晴天'));
      expect(rig.engine.log, isNot(contains('wake')));
      await rig.dispose();
    });

    test('关掉播报时回答只上屏，状态回到待唤醒', () async {
      final Rig rig = Rig(speakEnabled: false);
      await rig.coordinator.enable();
      await rig.coordinator.submitText('查天气');
      rig.coordinator.onAgentEvent(responseFor(rig.sent.single['request_id']!));
      await rig.pump();
      expect(rig.speech.spoken, isEmpty);
      expect(rig.chatLines.where((ChatLike l) => !l.fromUser), hasLength(1));
      expect(rig.coordinator.state, VoiceSessionState.waitingWake);
      await rig.dispose();
    });

    test('麦克风不可用：进入 error，但文本对话仍可用', () async {
      final Rig rig = Rig();
      await rig.coordinator.enable();
      rig.engine.emit(const VoiceCaptureErrorEvent(
        code: 'no-microphone',
        message: '没有默认录音设备',
      ));
      await rig.pump();
      expect(rig.coordinator.state, VoiceSessionState.error);
      expect(
        rig.uiEvents
            .whereType<CoordinatorErrorEvent>()
            .any((CoordinatorErrorEvent e) => e.message.contains('麦克风不可用')),
        isTrue,
      );
      await rig.coordinator.submitText('文字还能用');
      expect(rig.sent.single['text'], '文字还能用');
      await rig.dispose();
    });

    test('播报中收到新语音配置：本轮收尾时重建，不卡在播报', () async {
      // 真机曾经卡在这里：_rebuildEngine 只在 waitingWake 才干活，
      // 一轮结束时把重建交给它，结果引擎既没重建、状态也没回待唤醒，
      // 宠物永远停在「播报中」，之后再也不会响应唤醒。
      final Rig rig = Rig(autoFinishSpeech: false);
      await rig.coordinator.enable();
      await rig.coordinator.submitText('查天气');
      final String requestId = rig.sent.single['request_id']!;
      rig.coordinator.onAgentEvent(responseFor(requestId));
      await rig.pump();
      expect(rig.coordinator.state, VoiceSessionState.speaking);

      rig.coordinator.onAgentEvent(const AgentVoiceConfigEvent(
        revision: 9,
        wakePhrase: '小白小白',
        wakeAliases: <String>['小百小百'],
        wakeAck: '在',
        listenTimeoutMs: 8000,
      ));
      await rig.pump();
      // 播报中不动引擎，等这一轮说完。
      expect(rig.engine.lastConfig?.wakePhrase, isNot('小白小白'));

      rig.speech.finish('evt-$requestId');
      await rig.pump();
      expect(rig.engine.lastConfig?.wakePhrase, '小白小白');
      expect(rig.coordinator.state, VoiceSessionState.waitingWake);
      expect(rig.engine.log.last, 'wake');
      await rig.dispose();
    });

    test('voice_config revision 变化会在安全点重建语法', () async {
      final Rig rig = Rig();
      await rig.coordinator.enable();
      final int before = rig.engine.log.where((String e) => e == 'init').length;
      rig.coordinator.onAgentEvent(const AgentVoiceConfigEvent(
        revision: 7,
        wakePhrase: '小白小白',
        wakeAliases: <String>['小百小百'],
        wakeAck: '在',
        listenTimeoutMs: 8000,
      ));
      await rig.pump();
      expect(rig.coordinator.config.wakePhrase, '小白小白');
      expect(rig.engine.lastConfig?.wakePhrase, '小白小白');
      expect(rig.engine.log.where((String e) => e == 'init').length,
          greaterThan(before));
      await rig.dispose();
    });

    test('宠物立绘状态跟语音流程一致', () async {
      final Rig rig = Rig();
      await rig.coordinator.manualListen();
      await rig.pump();
      final List<PetState> states = rig.uiEvents
          .whereType<CoordinatorPetStateEvent>()
          .map((CoordinatorPetStateEvent e) => e.state)
          .toList();
      expect(states, contains(PetState.listening));
      rig.engine.emit(const VoiceFinalTranscriptEvent(text: '查天气', confidence: 0.8));
      await rig.pump();
      expect(
        rig.uiEvents.whereType<CoordinatorPetStateEvent>().map(
            (CoordinatorPetStateEvent e) => e.state).toList(),
        contains(PetState.thinking),
      );
      await rig.dispose();
    });
  });
}
