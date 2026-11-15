import 'dart:collection';

/// 播报内容的优先级（§7.8）。
enum SpeechPriority {
  /// 其它 DSH 会话的全局通知：最低，先让正式回答说完。
  announcement(0),

  /// 「做完了」这类收尾提醒：次于正式回答。
  completion(1),

  /// 宠物自己的正式回答：最高优先级。
  response(2);

  const SpeechPriority(this.weight);

  final int weight;
}

/// 一条待播内容。
class SpeechItem {
  const SpeechItem({
    required this.id,
    required this.text,
    required this.priority,
    this.requestId,
  });

  /// 去重键（`event_id` / `utteranceId`）。
  final String id;

  /// 待播文本（已经是口语化文本）。
  final String text;

  final SpeechPriority priority;

  /// 关联的请求 id，用于「回答已播过就不再念做完了」。
  final String? requestId;

  @override
  String toString() => 'SpeechItem($priority, $id, $text)';
}

/// 播报队列：去重、优先级、以及「回答之后不重复念完成提醒」。
///
/// 纯 Dart，可脱离 Flutter 测试（§12.2 第 5、6、7 条）。
class SpeechQueue {
  SpeechQueue({this.maxPending = 8, this.maxRememberedIds = 200});

  /// 队列上限：防止任务事件刷屏把内存撑爆。
  final int maxPending;

  /// 去重表上限。
  final int maxRememberedIds;

  final List<SpeechItem> _pending = <SpeechItem>[];
  final LinkedHashSet<String> _seenIds = LinkedHashSet<String>();
  final LinkedHashSet<String> _respondedRequestIds = LinkedHashSet<String>();
  String? _lastTakenText;

  /// 待播条数。
  int get length => _pending.length;

  /// 是否为空。
  bool get isEmpty => _pending.isEmpty;

  /// 入队。返回 true 表示真的进了队列。
  ///
  /// 规则：
  ///   1. 同一个 id 只播一次；
  ///   2. 某个请求的正式回答已经入过队，就丢掉它的「做完了」；
  ///   3. 队列满了丢优先级最低的，而不是新来的（新来的往往是重要回答）。
  bool enqueue(SpeechItem item) {
    final String text = item.text.trim();
    if (text.isEmpty) return false;
    if (_seenIds.contains(item.id)) return false;
    _remember(_seenIds, item.id, maxRememberedIds);

    if (item.priority == SpeechPriority.completion) {
      final String? requestId = item.requestId;
      if (requestId != null && _respondedRequestIds.contains(requestId)) {
        return false;
      }
    }
    if (item.priority == SpeechPriority.response && item.requestId != null) {
      _remember(_respondedRequestIds, item.requestId!, maxRememberedIds);
    }

    if (_pending.length >= maxPending) {
      _dropLowestPriority();
    }
    _pending.add(SpeechItem(
      id: item.id,
      text: text,
      priority: item.priority,
      requestId: item.requestId,
    ));
    return true;
  }

  /// 取下一条要播的内容：优先级高的先播，同级按入队顺序。
  SpeechItem? take() {
    if (_pending.isEmpty) return null;
    int bestIndex = 0;
    for (int i = 1; i < _pending.length; i++) {
      if (_pending[i].priority.weight > _pending[bestIndex].priority.weight) {
        bestIndex = i;
      }
    }
    final SpeechItem item = _pending.removeAt(bestIndex);
    _lastTakenText = item.text;
    return item;
  }

  /// 上一条被取走播报的文本（用于跳过紧邻的重复句子）。
  String? get lastTakenText => _lastTakenText;

  /// 清空待播（手动停止、切换语音开关时调用）。
  void clear() {
    _pending.clear();
  }

  void _dropLowestPriority() {
    if (_pending.isEmpty) return;
    int worst = 0;
    for (int i = 1; i < _pending.length; i++) {
      if (_pending[i].priority.weight < _pending[worst].priority.weight) {
        worst = i;
      }
    }
    _pending.removeAt(worst);
  }

  static void _remember(LinkedHashSet<String> set, String value, int limit) {
    set.remove(value);
    set.add(value);
    while (set.length > limit) {
      set.remove(set.first);
    }
  }
}
