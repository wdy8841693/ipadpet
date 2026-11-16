import 'package:test/test.dart';
import 'package:whalepet_flutter/core/voice/speech_queue.dart';

void main() {
  group('SpeechQueue', () {
    test('同一条消息不会播两次', () {
      final SpeechQueue queue = SpeechQueue();
      expect(queue.enqueue(const SpeechItem(
        id: 'evt-1',
        text: '你好',
        priority: SpeechPriority.response,
      )), isTrue);
      expect(queue.enqueue(const SpeechItem(
        id: 'evt-1',
        text: '你好',
        priority: SpeechPriority.response,
      )), isFalse);
      expect(queue.length, 1);
    });

    test('空文本不进队列', () {
      final SpeechQueue queue = SpeechQueue();
      expect(queue.enqueue(const SpeechItem(
        id: 'evt-1',
        text: '   ',
        priority: SpeechPriority.response,
      )), isFalse);
      expect(queue.isEmpty, isTrue);
    });

    test('正式回答优先于任务通知', () {
      final SpeechQueue queue = SpeechQueue();
      queue.enqueue(const SpeechItem(
        id: 'ann-1',
        text: '做完了：整理备课资料',
        priority: SpeechPriority.announcement,
      ));
      queue.enqueue(const SpeechItem(
        id: 'resp-1',
        text: '今天有三件事',
        priority: SpeechPriority.response,
        requestId: 'req-1',
      ));
      expect(queue.take()?.text, '今天有三件事');
      expect(queue.take()?.text, '做完了：整理备课资料');
    });

    test('同级按入队顺序播', () {
      final SpeechQueue queue = SpeechQueue();
      queue.enqueue(const SpeechItem(
        id: 'a',
        text: '第一句',
        priority: SpeechPriority.announcement,
      ));
      queue.enqueue(const SpeechItem(
        id: 'b',
        text: '第二句',
        priority: SpeechPriority.announcement,
      ));
      expect(queue.take()?.text, '第一句');
      expect(queue.take()?.text, '第二句');
    });

    test('回答已经播过，就不再念「做完了」', () {
      final SpeechQueue queue = SpeechQueue();
      queue.enqueue(const SpeechItem(
        id: 'resp-1',
        text: '答案是 42',
        priority: SpeechPriority.response,
        requestId: 'req-1',
      ));
      final bool added = queue.enqueue(const SpeechItem(
        id: 'task-1',
        text: '做完了',
        priority: SpeechPriority.completion,
        requestId: 'req-1',
      ));
      expect(added, isFalse);
      expect(queue.take()?.text, '答案是 42');
      expect(queue.take(), isNull);
    });

    test('没有对应回答时，「做完了」照常播', () {
      final SpeechQueue queue = SpeechQueue();
      expect(queue.enqueue(const SpeechItem(
        id: 'task-2',
        text: '做完了',
        priority: SpeechPriority.completion,
        requestId: 'req-2',
      )), isTrue);
      expect(queue.take()?.text, '做完了');
    });

    test('队列满时丢优先级最低的，而不是丢掉新回答', () {
      final SpeechQueue queue = SpeechQueue(maxPending: 2);
      queue.enqueue(const SpeechItem(
        id: 'ann-1',
        text: '通知一',
        priority: SpeechPriority.announcement,
      ));
      queue.enqueue(const SpeechItem(
        id: 'ann-2',
        text: '通知二',
        priority: SpeechPriority.announcement,
      ));
      queue.enqueue(const SpeechItem(
        id: 'resp-1',
        text: '正式回答',
        priority: SpeechPriority.response,
        requestId: 'req-1',
      ));
      expect(queue.length, 2);
      final List<String?> texts = <String?>[
        queue.take()?.text,
        queue.take()?.text,
      ];
      expect(texts, contains('正式回答'));
    });

    test('清空后不再播残留内容', () {
      final SpeechQueue queue = SpeechQueue();
      queue.enqueue(const SpeechItem(
        id: 'a',
        text: '一',
        priority: SpeechPriority.announcement,
      ));
      queue.clear();
      expect(queue.isEmpty, isTrue);
      expect(queue.take(), isNull);
    });
  });
}
