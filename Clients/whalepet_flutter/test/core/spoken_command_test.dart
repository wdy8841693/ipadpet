import 'package:test/test.dart';
import 'package:whalepet_flutter/core/voice/spoken_command.dart';

void main() {
  group('hasEffectiveContent（§7.7.4）', () {
    test('有实义内容 → 有效指令', () {
      expect(hasEffectiveContent('帮我查一下明天的安排'), isTrue);
      expect(hasEffectiveContent('查天气'), isTrue);
      expect(hasEffectiveContent('我想查明天的安排'), isTrue);
      expect(hasEffectiveContent('3'), isTrue);
      expect(hasEffectiveContent('play music'), isTrue);
    });

    test('只有语气词 → 不是有效指令', () {
      // 这些情况下应该播「我在」，让用户把真正的指令再说一遍。
      expect(hasEffectiveContent('帮我'), isFalse);
      expect(hasEffectiveContent('嗯'), isFalse);
      expect(hasEffectiveContent('嗯那个'), isFalse);
      expect(hasEffectiveContent('麻烦'), isFalse);
      expect(hasEffectiveContent('谢谢'), isFalse);
      expect(hasEffectiveContent('在吗'), isFalse);
    });

    test('空串与纯标点 → 不是有效指令', () {
      expect(hasEffectiveContent(''), isFalse);
      expect(hasEffectiveContent('   '), isFalse);
      expect(hasEffectiveContent('！！！'), isFalse);
      expect(hasEffectiveContent('，。、'), isFalse);
    });

    test('语气词只从句首剥，不会削掉指令里的字', () {
      // 「帮我」在句首是语气词，在句中就是实义内容的一部分。
      expect(hasEffectiveContent('查一下帮我的日程'), isTrue);
      expect(hasEffectiveContent('帮我看看我帮谁买了咖啡'), isTrue);
    });

    test('连续语气词会被逐层剥掉', () {
      expect(hasEffectiveContent('嗯嗯那个帮我'), isFalse);
      expect(hasEffectiveContent('嗯嗯那个帮我查天气'), isTrue);
    });
  });
}
