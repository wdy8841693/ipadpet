import 'package:test/test.dart';
import 'package:whalepet_flutter/core/voice/wake_matcher.dart';

void main() {
  const List<String> phrases = <String>['小鲸小鲸', '小金小金'];
  const WakeMatcher matcher = WakeMatcher(phrases);

  group('WakeMatcher.strip', () {
    test('剥掉句首唤醒词和标点', () {
      expect(matcher.strip('小鲸小鲸，帮我查一下明天的安排'), '帮我查一下明天的安排');
      expect(matcher.strip('小鲸小鲸 帮我查天气'), '帮我查天气');
      expect(matcher.strip('小鲸小鲸！今天几号？'), '今天几号？');
    });

    test('别名同样生效', () {
      expect(matcher.strip('小金小金，打开文件夹'), '打开文件夹');
    });

    test('词内部有空格/标点也能命中', () {
      expect(matcher.strip('小 鲸 小 鲸，帮我查天气'), '帮我查天气');
    });

    test('只有唤醒词时返回空', () {
      expect(matcher.strip('小鲸小鲸'), '');
      expect(matcher.strip('小鲸小鲸……'), '');
      expect(matcher.isWakeOnly('小鲸小鲸，'), isTrue);
    });

    test('没命中唤醒词时原文返回', () {
      expect(matcher.strip('帮我查天气'), '帮我查天气');
      expect(matcher.isWakeOnly('帮我查天气'), isFalse);
    });

    test('长词优先：不会被短前缀截断', () {
      const WakeMatcher nested =
          WakeMatcher(<String>['小鲸', '小鲸小鲸']);
      expect(nested.strip('小鲸小鲸，查天气'), '查天气');
    });
  });

  group('WakeMatcher 判断', () {
    test('startsWithWake', () {
      expect(matcher.startsWithWake('小鲸小鲸，你好'), isTrue);
      expect(matcher.startsWithWake('你好，小鲸小鲸'), isFalse);
    });

    test('contains 忽略标点与大小写', () {
      expect(matcher.contains('嗯……小 鲸 小 鲸！'), isTrue);
      expect(matcher.contains('今天天气不错'), isFalse);
    });
  });
}
