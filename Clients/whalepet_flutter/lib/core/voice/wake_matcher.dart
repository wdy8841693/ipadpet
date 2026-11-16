/// 唤醒词剥离（§7.7 的整段 ASR 兼容逻辑）。
///
/// KWS 常驻时引擎只报「唤醒了」，但整段听写的结果常常把唤醒词也带进来，
/// 例如「小鲸小鲸，帮我查天气」。这里负责：
///   1. 识别句首唤醒词与别名；
///   2. 剥掉它以及紧跟的标点/语气词；
///   3. 剩下的文本才是真正要发给 DSH 的指令。
class WakeMatcher {
  const WakeMatcher(this.phrases);

  /// 唤醒词表（主词 + 别名，长词优先匹配）。
  final List<String> phrases;

  /// 句首标点/语气词：唤醒词后常见的「，」「，请」「，帮我」里的标点部分。
  static final RegExp _leadingNoise =
      RegExp(r'^[\s,，。、！？!?：:；;～~\-—…·]+');

  /// 只用于「是否包含唤醒词」的宽松比较：去空白与标点、ASCII 转小写。
  // 用普通字符串（不是 r''），避免中文引号里的单引号提前结束 raw string。
  static final RegExp _punctuation = RegExp(
      '[\\s,，。、！？!?：:；;～~\\-—…·"“”()（）\\[\\]【】]');

  /// 按长度降序，避免「小鲸」抢在「小鲸小鲸」前面命中。
  List<String> get _sorted {
    final List<String> copy = phrases
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .toList();
    copy.sort((String a, String b) => b.length.compareTo(a.length));
    return copy;
  }

  /// 去掉句首唤醒词，返回剩余指令；没命中则原文返回。
  String strip(String text) {
    final String trimmed = text.trim();
    for (final String phrase in _sorted) {
      if (trimmed.startsWith(phrase)) {
        String rest = trimmed.substring(phrase.length);
        rest = rest.replaceFirst(_leadingNoise, '');
        return rest.trim();
      }
      // 允许词内部有空格/标点（SAPI 有时会把「小鲸小鲸」切成「小 鲸 小 鲸」）。
      final RegExp loose = _loosePattern(phrase);
      final RegExpMatch? match = loose.firstMatch(trimmed);
      if (match != null && match.start == 0) {
        String rest = trimmed.substring(match.end);
        rest = rest.replaceFirst(_leadingNoise, '');
        return rest.trim();
      }
    }
    return trimmed;
  }

  /// 判断文本是否以唤醒词开头。
  bool startsWithWake(String text) {
    final String trimmed = text.trim();
    for (final String phrase in _sorted) {
      if (trimmed.startsWith(phrase)) return true;
      if (_loosePattern(phrase).matchAsPrefix(trimmed) != null) return true;
    }
    return false;
  }

  /// 文本里是否含唤醒词（不限句首）。
  bool contains(String text) {
    final String normalized = _normalize(text);
    for (final String phrase in _sorted) {
      if (normalized.contains(_normalize(phrase))) return true;
    }
    return false;
  }

  /// 是否是「只有唤醒词、没有有效指令」。
  bool isWakeOnly(String text) => strip(text).isEmpty;

  RegExp _loosePattern(String phrase) {
    final String escaped = phrase
        .split('')
        .map((String ch) => RegExp.escape(ch))
        .join(r'[\s,，。、·\-—]*');
    return RegExp('^$escaped', caseSensitive: false);
  }

  static String _normalize(String value) =>
      value.replaceAll(_punctuation, '').toLowerCase();
}
