import Foundation

/// 中文唤醒词 → sherpa-onnx 关键词串（拼音 token）的映射。
///
/// KWS 模型的建模单元是「声母 + 韵母」（带声调的拼音），所以中文唤醒词要先
/// 转成拼音才能当关键词喂给模型——模型不认识汉字。
///
/// 表里没有的词就用不了真 KWS：这时原生层退回「系统识别 + 文本匹配唤醒」，
/// 功能不会没有，只是待机期要一直跑识别、耗电和延迟都差一些。
///
/// 想支持新的唤醒词，往表里加一行「中文 → 拼音 token」即可（拼音要跟
/// `tokens.txt` 里的写法一致，声母和韵母用空格分开）。
enum WhalePetWakeKeywords {

  /// 唤醒词 → 拼音 token（空格分隔）。
  private static let pinyinTable: [String: String] = [
    "小鲸小鲸": "x iǎo j īng x iǎo j īng",
    "小金小金": "x iǎo j īn x iǎo j īn",
    "小鲸鱼小鲸鱼": "x iǎo j īng y ú x iǎo j īng y ú",
    "小鲸鱼": "x iǎo j īng y ú",
    "鲸鱼鲸鱼": "j īng y ú j īng y ú",
    "小鲸小鲸小鲸小鲸": "x iǎo j īng x iǎo j īng x iǎo j īng x iǎo j īng",
  ]

  /// 把一组中文唤醒词转成 sherpa 的关键词串。
  ///
  /// 多个词之间用 `/` 分隔（sherpa 的多关键词写法）；转不出来的词直接跳过。
  /// 一个都转不出来时返回 nil，表示这台机器/这组词用不了真 KWS。
  static func keywordString(for phrases: [String]) -> String? {
    var parts: [String] = []
    for phrase in phrases {
      let cleaned = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !cleaned.isEmpty, let pinyin = pinyinTable[cleaned] else { continue }
      parts.append("\(pinyin) @\(cleaned)")
    }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: "/")
  }
}
