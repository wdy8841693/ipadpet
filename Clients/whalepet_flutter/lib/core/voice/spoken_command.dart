/// 「唤醒词后面那句话」是不是一条有效指令（§7.7.4）。
///
/// 判定分两步：
///
/// 1. 去掉句首唤醒词与紧跟的标点（由 `WakeMatcher.strip` 负责）；
/// 2. 去掉「嗯 / 啊 / 请 / 帮我」这类语气词，看还剩下没有实义字。
///
/// 语气词**只用于判定**，不会从发给 DSH 的命令里删掉：
/// 「帮我查一下明天的安排」原样发过去，语义更完整。
library;

/// 只有这些字，说明「其实没说要什么」。
///
/// 「小鲸小鲸，嗯」不该被当成一条命令去问 DSH；应当播「我在」，
/// 让用户把真正的指令再说一遍（§7.7.4）。
const Set<String> kCommandFillers = <String>{
  // 纯语气音
  '嗯', '呃', '啊', '哦', '噢', '喔', '唔', '唉', '诶', '欸', '哈',
  // 指示代词 / 口头禅
  '那个', '这个', '就是', '然后', '对了', '还有', '在吗',
  // 请求前缀
  '请', '帮我', '帮忙', '麻烦', '给我', '我要', '我想', '我', '可以', '好的', '好吧', '行',
  // 客套
  '谢谢', '谢啦', '麻烦了',
  // 语气助词
  '吧', '呢', '嘛', '呀', '啊呀', '哈啊',
  // 呼叫
  '喂', '听得到', '能听到',
};

/// 实义字符：汉字、字母、数字。
final RegExp _meaningfulChar = RegExp(r'[\u4e00-\u9fffA-Za-z0-9]');

/// 标点与空白（判定前先去掉）。
final RegExp _punctuation = RegExp(
    '[\\s,，。、！？!?：:；;～~\\-—…·"“”()（）\\[\\]【】]');

/// 语气词按长度降序：先剥「帮我」再剥「我」，避免把「我要」剥成「要」。
final List<String> _fillersByLength = (kCommandFillers.toList()
  ..sort((String a, String b) => b.length.compareTo(a.length)));

/// 去掉语气词之后是否还剩下实义内容。
///
/// ```text
/// 「帮我查一下明天的安排」 → true
/// 「帮我」                  → false（只有语气词，没有实义）
/// 「嗯，那个」              → false
/// 「查天气」                → true
/// ```
bool hasEffectiveContent(String text) {
  String rest = text.replaceAll(_punctuation, '');
  if (rest.isEmpty) return false;
  bool changed = true;
  while (changed) {
    changed = false;
    for (final String filler in _fillersByLength) {
      if (rest.startsWith(filler)) {
        rest = rest.substring(filler.length);
        changed = true;
        break;
      }
    }
  }
  return _meaningfulChar.hasMatch(rest);
}
