import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:whalepet_flutter/core/voice/voice_engine.dart';
import 'package:whalepet_flutter/platform/voice/android_system_voice_engine.dart';

/// Android 语音引擎的行为测试（§7.7 一句话带命令 + §10.1 音频焦点/来电）。
///
/// 原生侧（Kotlin）在这里被模拟：MethodChannel 返回可用/已授权，
/// EventChannel 用来把「识别结果 / 焦点变化 / 音频模式」推进 Dart。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel methods = MethodChannel('whalepet/native');
  const EventChannel events = EventChannel('whalepet/native/events');

  final List<MethodCall> calls = <MethodCall>[];
  MockStreamHandlerEventSink? sink;

  void emit(Map<String, Object?> payload) {
    final MockStreamHandlerEventSink? target = sink;
    expect(target, isNotNull, reason: '事件通道还没建立');
    target!.success(payload);
  }

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (MethodCall call) async {
      calls.add(call);
      switch (call.method) {
        case 'asrAvailable':
        case 'hasMicPermission':
          return true;
        default:
          return null;
      }
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (Object? arguments, MockStreamHandlerEventSink handler) {
          sink = handler;
        },
      ),
    );
  });

  setUp(() {
    calls.clear();
  });

  Future<AndroidSystemVoiceEngine> readyEngine() async {
    final AndroidSystemVoiceEngine engine = AndroidSystemVoiceEngine();
    await engine.initialize(const VoiceEngineConfig());
    // 事件是异步过来的，等一拍再断言。
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return engine;
  }

  group('AndroidSystemVoiceEngine · 一句话带命令（§7.7）', () {
    test('唤醒时把唤醒词后面那一截一起带上来', () async {
      final AndroidSystemVoiceEngine engine = await readyEngine();
      final Future<VoiceEngineEvent> next = engine.events.first;
      await engine.startWakeListening();
      emit(<String, Object?>{
        'type': 'final',
        'text': '小鲸小鲸，帮我查一下明天的安排',
        'confidence': 0.8,
      });
      final VoiceEngineEvent event = await next;
      expect(event, isA<VoiceWakeDetectedEvent>());
      final VoiceWakeDetectedEvent wake = event as VoiceWakeDetectedEvent;
      expect(wake.keyword, '小鲸小鲸');
      expect(wake.trailingText, '帮我查一下明天的安排');
      await engine.dispose();
    });

    test('只说唤醒词时后面为空（走「我在」→ 聆听的第一阶段）', () async {
      final AndroidSystemVoiceEngine engine = await readyEngine();
      final Future<VoiceEngineEvent> next = engine.events.first;
      await engine.startWakeListening();
      emit(<String, Object?>{
        'type': 'final',
        'text': '小鲸小鲸',
        'confidence': 0.9,
      });
      final VoiceEngineEvent event = await next;
      expect(event, isA<VoiceWakeDetectedEvent>());
      expect((event as VoiceWakeDetectedEvent).trailingText, isEmpty);
      await engine.dispose();
    });

    test('别名唤醒同样带上后面的指令', () async {
      final AndroidSystemVoiceEngine engine = await readyEngine();
      final Future<VoiceEngineEvent> next = engine.events.first;
      await engine.startWakeListening();
      emit(<String, Object?>{
        'type': 'final',
        'text': '小金小金，打开文件夹',
        'confidence': 0.7,
      });
      final VoiceEngineEvent event = await next;
      final VoiceWakeDetectedEvent wake = event as VoiceWakeDetectedEvent;
      expect(wake.keyword, '小金小金');
      expect(wake.trailingText, '打开文件夹');
      await engine.dispose();
    });

    test('待机时没命中唤醒词不产生事件（这是常态，不是错误）', () async {
      final AndroidSystemVoiceEngine engine = await readyEngine();
      final List<VoiceEngineEvent> seen = <VoiceEngineEvent>[];
      final StreamSubscription<VoiceEngineEvent> sub =
          engine.events.listen(seen.add);
      await engine.startWakeListening();
      emit(<String, Object?>{'type': 'final', 'text': '今天天气不错'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen, isEmpty);
      await sub.cancel();
      await engine.dispose();
    });

    test('聆听模式：final 走最终识别，partial 走中间结果', () async {
      final AndroidSystemVoiceEngine engine = await readyEngine();
      final List<VoiceEngineEvent> seen = <VoiceEngineEvent>[];
      final StreamSubscription<VoiceEngineEvent> sub =
          engine.events.listen(seen.add);
      await engine.startManualListening();
      emit(<String, Object?>{'type': 'partial', 'text': '帮我查一下'});
      emit(<String, Object?>{'type': 'final', 'text': '帮我查一下天气'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen.whereType<VoicePartialTranscriptEvent>(), hasLength(1));
      expect(seen.whereType<VoiceFinalTranscriptEvent>(), hasLength(1));
      expect(
        seen.whereType<VoiceFinalTranscriptEvent>().single.text,
        '帮我查一下天气',
      );
      await sub.cancel();
      await engine.dispose();
    });
  });

  group('AndroidSystemVoiceEngine · 音频焦点与来电（§10.1）', () {
    test('音频焦点被抢走 → 上报中断', () async {
      final AndroidSystemVoiceEngine engine = await readyEngine();
      final Future<VoiceEngineEvent> next = engine.events.first;
      await engine.startWakeListening();
      emit(<String, Object?>{
        'type': 'audio_focus',
        'state': 'loss',
        'message': '麦克风被其它应用占用',
      });
      final VoiceEngineEvent event = await next;
      expect(event, isA<VoiceInterruptionEvent>());
      final VoiceInterruptionEvent interruption = event as VoiceInterruptionEvent;
      expect(interruption.reason, 'audio_focus');
      expect(interruption.message, '麦克风被其它应用占用');
      await engine.dispose();
    });

    test('焦点回来 → 上报可恢复', () async {
      final AndroidSystemVoiceEngine engine = await readyEngine();
      await engine.startWakeListening();
      final List<VoiceEngineEvent> seen = <VoiceEngineEvent>[];
      final StreamSubscription<VoiceEngineEvent> sub =
          engine.events.listen(seen.add);
      emit(<String, Object?>{
        'type': 'audio_focus',
        'state': 'loss',
        'message': '麦克风被其它应用占用',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      emit(<String, Object?>{'type': 'audio_focus', 'state': 'gain'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen.whereType<VoiceInterruptionEvent>(), hasLength(1));
      expect(seen.whereType<VoiceEngineRecoveredEvent>(), hasLength(1));
      await sub.cancel();
      await engine.dispose();
    });

    test('来电 → 上报 phone_call 中断；挂断后恢复', () async {
      final AndroidSystemVoiceEngine engine = await readyEngine();
      await engine.startWakeListening();
      final List<VoiceEngineEvent> seen = <VoiceEngineEvent>[];
      final StreamSubscription<VoiceEngineEvent> sub =
          engine.events.listen(seen.add);
      emit(<String, Object?>{'type': 'audio_mode', 'mode': 'in_call'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen.whereType<VoiceInterruptionEvent>(), hasLength(1));
      expect(
        seen.whereType<VoiceInterruptionEvent>().single.reason,
        'phone_call',
      );
      emit(<String, Object?>{'type': 'audio_mode', 'mode': 'normal'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen.whereType<VoiceEngineRecoveredEvent>(), hasLength(1));
      await sub.cancel();
      await engine.dispose();
    });

    test('没有中断过时不凭空报恢复', () async {
      final AndroidSystemVoiceEngine engine = await readyEngine();
      await engine.startWakeListening();
      final List<VoiceEngineEvent> seen = <VoiceEngineEvent>[];
      final StreamSubscription<VoiceEngineEvent> sub =
          engine.events.listen(seen.add);
      emit(<String, Object?>{'type': 'audio_mode', 'mode': 'normal'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(seen.whereType<VoiceEngineRecoveredEvent>(), isEmpty);
      await sub.cancel();
      await engine.dispose();
    });
  });

  group('AndroidSystemVoiceEngine · 控制命令', () {
    test('起停会调用原生 asrStart / asrStop', () async {
      final AndroidSystemVoiceEngine engine = await readyEngine();
      await engine.startWakeListening();
      expect(
        calls.any((MethodCall c) =>
            c.method == 'asrStart' &&
            (c.arguments as Map<Object?, Object?>)['wakeMode'] == true),
        isTrue,
      );
      await engine.stopListening();
      expect(
        calls.any((MethodCall c) =>
            c.method == 'asrStop' &&
            (c.arguments as Map<Object?, Object?>)['force'] == true),
        isTrue,
      );
      await engine.dispose();
    });

    test('打断不调 asrStop（保留原生恢复监听）；主动停止才 force', () async {
      final AndroidSystemVoiceEngine engine = await readyEngine();
      await engine.startWakeListening();
      calls.clear();

      emit(<String, Object?>{
        'type': 'audio_focus',
        'state': 'loss',
        'message': '麦克风被其它应用占用',
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls.where((MethodCall c) => c.method == 'asrStop'), isEmpty);

      await engine.stopListening();
      expect(
        calls.any((MethodCall c) =>
            c.method == 'asrStop' &&
            (c.arguments as Map<Object?, Object?>)['force'] == true),
        isTrue,
      );
      await engine.dispose();
    });
  });
}
