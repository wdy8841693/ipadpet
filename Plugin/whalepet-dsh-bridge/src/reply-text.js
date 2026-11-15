/**
 * Agent 回复文本处理（纯函数，无 I/O）。
 *
 * 职责边界（见 docs/CROSS_PLATFORM.md §8.6 / §9.1）：
 *   - extractText / lastAssistantText：从 DSH 的 wait() 记录里取出**原始**回复文本；
 *   - toSpeechText：把原始 Markdown 整理成适合 TTS 念的口语文本。
 *
 * 新协议需要同时拿到「原始回答」（display_text，可保留 Markdown）与
 * 「口语文本」（speech_text，给 TTS），所以这里把两者分开：
 *   displayText = lastAssistantText(records)
 *   speechText  = toSpeechText(displayText)
 */

/** 从文本内容块里取下发给模型的那部分文字。 */
export function extractText(content) {
  if (typeof content === 'string') return content.trim()
  if (!Array.isArray(content)) return ''
  return content
    .filter((block) => block && block.type === 'text' && typeof block.text === 'string')
    .map((block) => block.text)
    .join('')
    .trim()
}

/** 从 wait() 的 assistant 记录（新→旧）里取最新一条有文字的回复。 */
export function lastAssistantText(records) {
  if (!Array.isArray(records)) return ''
  for (const record of records) {
    const event = record?.event
    if (!event || event.type !== 'assistant/message') continue
    const text = extractText(event.data?.message?.content)
    if (text) return text
  }
  return ''
}

/**
 * 把 Agent 的 Markdown 回复整理成适合 TTS 念的口语文本。
 * 只做「念出来不难受」所必需的处理，不改写内容。
 */
export function toSpeechText(markdown) {
  if (typeof markdown !== 'string' || !markdown.trim()) return ''
  let text = markdown
  // 围栏代码块：整段丢掉（念代码没有意义），只保留可选的标题行。
  text = text.replace(/```[^\n]*\n([\s\S]*?)```/g, '')
  // 行内代码保留内容，去掉反引号。
  text = text.replace(/`([^`]+)`/g, '$1')
  // Markdown 链接/图片：[文字](url) -> 文字。
  text = text.replace(/!?\[([^\]]*)\]\([^)]*\)/g, '$1')
  // 标题、引用、列表符号。
  text = text.replace(/^\s{0,3}#{1,6}\s+/gm, '')
  text = text.replace(/^\s{0,3}>\s?/gm, '')
  text = text.replace(/^\s{0,3}[-*+]\s+/gm, '')
  text = text.replace(/^\s{0,3}\d+[.)]\s+/gm, '')
  // 粗体/斜体/删除线标记。
  text = text.replace(/(\*\*|__)(.*?)\1/g, '$2')
  text = text.replace(/(\*|_)(.*?)\1/g, '$2')
  text = text.replace(/~~(.*?)~~/g, '$1')
  // 表格竖线与多余空白。
  text = text.replace(/\|/g, ' ')
  text = text.replace(/[ \t]+/g, ' ')
  text = text.replace(/\n{2,}/g, '\n')
  text = text.trim()
  return text
}
