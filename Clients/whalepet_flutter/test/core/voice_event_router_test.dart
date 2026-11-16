import 'package:test/test.dart';
import 'package:whalepet_flutter/core/voice/voice_engine.dart';
import 'package:whalepet_flutter/core/voice/voice_event_router.dart';

void main() {
  const List<String> phrases = <String>['小鲸小鲸', '小金小金'];

  VoiceEventRouter router({VoiceEngineMode mode = VoiceEngineMode.idle}) {
    final VoiceEventRouter r = VoiceEventRouter(wakePhrases: phrases);
    r.setMode(mode);
    return r;
  }

  group('待机模式（唤醒）', () {
    test('命中唤醒词 → 唤醒事件', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.wake);
      final List<VoiceEngineEvent> events =
          r.route(const RawFinalEvent(text: '小鲸小鲸', confidence: 0.9));
      expect(events.length, 1);
      final VoiceEngineEvent event = events.first;
      expect(event, isA<VoiceWakeDetectedEvent>());
      expect((event as VoiceWakeDetectedEvent).keyword, '小鲸小鲸');
    });

    test('partial 不触发唤醒：等句尾判停才知道后面有没有指令（§7.7.4）', () {
      // 用 partial 唤醒会把后半句截断：「小鲸小鲸帮我查天气」在 partial
      // 阶段只看到「小鲸小鲸」，指令就丢了。
      final VoiceEventRouter r = router(mode: VoiceEngineMode.wake);
      expect(r.route(const RawPartialEvent(text: '小鲸小鲸')).isEmpty, isTrue);
      expect(
          r.route(const RawPartialEvent(text: '小鲸小鲸帮我查')).isEmpty, isTrue);
    });

    test('一句话带命令：唤醒事件带上后面那一截', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.wake);
      final List<VoiceEngineEvent> events = r.route(
        const RawFinalEvent(text: '小鲸小鲸，帮我查一下明天的安排', confidence: 0.9),
      );
      expect(events.length, 1);
      final VoiceWakeDetectedEvent wake = events.first as VoiceWakeDetectedEvent;
      expect(wake.keyword, '小鲸小鲸');
      expect(wake.trailingText, '帮我查一下明天的安排');
    });

    test('只说唤醒词时后面为空', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.wake);
      final List<VoiceEngineEvent> events =
          r.route(const RawFinalEvent(text: '小鲸小鲸', confidence: 0.9));
      expect(
          (events.first as VoiceWakeDetectedEvent).trailingText, isEmpty);
    });

    test('别名同样能唤醒', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.wake);
      final List<VoiceEngineEvent> events =
          r.route(const RawFinalEvent(text: '小金小金', confidence: 0.9));
      expect(events.length, 1);
      expect(events.first, isA<VoiceWakeDetectedEvent>());
      expect((events.first as VoiceWakeDetectedEvent).keyword, '小金小金');
    });

    test('没命中唤醒词 → 不产生事件', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.wake);
      expect(r.route(const RawPartialEvent(text: '今天天气不错')).isEmpty, isTrue);
      expect(
          r.route(const RawFinalEvent(text: '帮我查一下天气', confidence: 0.8))
              .isEmpty,
          isTrue);
    });

    test('唤醒后本轮不再产生事件（避免应答播报期间重复触发）', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.wake);
      expect(r.route(const RawFinalEvent(text: '小鲸小鲸', confidence: 1)).length,
          1);
      expect(
          r.route(const RawFinalEvent(text: '小鲸小鲸', confidence: 1)).isEmpty,
          isTrue);
      expect(
          r.route(const RawPartialEvent(text: '小鲸小鲸')).isEmpty,
          isTrue);
    });

    test('重新进入待机模式会清掉已唤醒标记', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.wake);
      expect(r.route(const RawFinalEvent(text: '小鲸小鲸', confidence: 1)).length,
          1);
      r.setMode(VoiceEngineMode.idle);
      r.setMode(VoiceEngineMode.wake);
      expect(r.route(const RawFinalEvent(text: '小鲸小鲸', confidence: 1)).length,
          1);
    });

    test('「没听清」是常态，不上报错误', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.wake);
      final List<VoiceEngineEvent> events = r.route(
        const RawErrorEvent(code: 'no_speech', message: '没听清'),
      );
      expect(events, isEmpty);
    });

    test('致命错误上报为采集错误', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.wake);
      final List<VoiceEngineEvent> events = r.route(
        const RawErrorEvent(
          code: 'permission_denied',
          message: '麦克风权限被拒绝',
          retryable: false,
        ),
      );
      expect(events.length, 1);
      expect(events.first, isA<VoiceCaptureErrorEvent>());
    });
  });

  group('聆听模式（指令）', () {
    test('partial → 中间结果，final → 最终结果', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.listen);
      final List<VoiceEngineEvent> partial =
          r.route(const RawPartialEvent(text: '帮我查一下'));
      expect(partial.length, 1);
      expect(partial.first, isA<VoicePartialTranscriptEvent>());
      expect((partial.first as VoicePartialTranscriptEvent).text, '帮我查一下');

      final List<VoiceEngineEvent> finalEvents =
          r.route(const RawFinalEvent(text: '帮我查一下明天的安排', confidence: 0.7));
      expect(finalEvents.length, 1);
      expect(finalEvents.first, isA<VoiceFinalTranscriptEvent>());
      final VoiceFinalTranscriptEvent done =
          finalEvents.first as VoiceFinalTranscriptEvent;
      expect(done.text, '帮我查一下明天的安排');
      expect(done.confidence, 0.7);
    });

    test('空结果 → 可重试的识别错误', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.listen);
      final List<VoiceEngineEvent> events =
          r.route(const RawFinalEvent(text: '   ', confidence: 0));
      expect(events.length, 1);
      expect(events.first, isA<VoiceRecognitionErrorEvent>());
      final VoiceRecognitionErrorEvent error =
          events.first as VoiceRecognitionErrorEvent;
      expect(error.code, 'empty_result');
      expect(error.retryable, isTrue);
    });

    test('final 之后的收尾错误被丢弃（指令已经发出去了）', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.listen);
      expect(
          r.route(const RawFinalEvent(text: '查一下天气', confidence: 0.9)).length,
          1);
      final List<VoiceEngineEvent> trailing = r.route(
        const RawErrorEvent(code: 'no_speech', message: '没听清'),
      );
      expect(trailing, isEmpty);
    });

    test('可恢复错误不结束这一轮，用户可以接着说', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.listen);
      final List<VoiceEngineEvent> events = r.route(
        const RawErrorEvent(code: 'no_speech', message: '没听清'),
      );
      expect(events.length, 1);
      expect(events.first, isA<VoiceRecognitionErrorEvent>());
      // 这一轮还没结束：后续的识别结果仍然有效。
      expect(
          r.route(const RawFinalEvent(text: '查一下天气', confidence: 0.9)).length,
          1);
    });

    test('致命错误上报为采集错误并结束这一轮', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.listen);
      final List<VoiceEngineEvent> events = r.route(
        const RawErrorEvent(
          code: 'mic_unavailable',
          message: '没有可用的音频输入设备',
          retryable: false,
        ),
      );
      expect(events.length, 1);
      expect(events.first, isA<VoiceCaptureErrorEvent>());
      expect(r.route(const RawFinalEvent(text: '查天气', confidence: 0.9)).isEmpty,
          isTrue);
    });
  });

  group('空闲模式', () {
    test('所有事件都被丢弃', () {
      final VoiceEventRouter r = router();
      expect(r.route(const RawPartialEvent(text: '小鲸小鲸')).isEmpty, isTrue);
      expect(
          r.route(const RawFinalEvent(text: '查天气', confidence: 0.9)).isEmpty,
          isTrue);
      expect(
          r.route(const RawErrorEvent(code: 'no_speech', message: '没听清')).isEmpty,
          isTrue);
    });
  });

  group('唤醒词表', () {
    test('换词后按新词表判定', () {
      final VoiceEventRouter r = router(mode: VoiceEngineMode.wake);
      expect(r.route(const RawFinalEvent(text: '小鲸小鲸', confidence: 1)).length,
          1);
      r.setMode(VoiceEngineMode.idle);
      r.setWakePhrases(const <String>['鲸鱼鲸鱼']);
      r.setMode(VoiceEngineMode.wake);
      expect(
          r.route(const RawFinalEvent(text: '小鲸小鲸', confidence: 1)).isEmpty,
          isTrue);
      expect(
          r.route(const RawFinalEvent(text: '鲸鱼鲸鱼', confidence: 1)).length,
          1);
    });
  });
}
