/**
 * 文本归一化与唤醒词匹配（纯逻辑，无 I/O）。
 *
 * 移植自 Server/whalepet_bridge/textnorm.py，行为保持逐条对齐：
 *  - NFKC 归一、小写、去汉字间空格、标点折叠为空格；
 *  - 唤醒词按别名集合匹配句首；
 *  - 只说唤醒词 => 等待口令；唤醒词 + 命令 => 一句话带命令。
 *
 * 单测：test/textnorm.test.js
 */

/** 常见同音/近音误识别（可由配置追加）。 */
export const DEFAULT_WAKE_ALIASES = Object.freeze([
  '小鲸小鲸',
  '小金小金',
  '小精小精',
  '小京小京',
  '小今小今',
  '晓鲸晓鲸',
])

// ASR 结果里常见的中文/英文标点，全部折叠为统一空格。
const PUNCT_RE = /[，。！？、；：,.!?;:\s]+/g
// 汉字之间的空格删除（Whisper 等模型的中文输出可能夹空格）。
const HAN_SPACE_RE = /(?<=[\u4e00-\u9fff])\s+(?=[\u4e00-\u9fff])/g
const SPACE_RE = /\s+/g
const HAN_RE = /[\u4e00-\u9fff]/

/** 归一化：用于匹配，不用于展示。 */
export function normalize(text) {
  if (typeof text !== 'string' || !text) return ''
  let out = text.normalize('NFKC').toLowerCase()
  out = out.replace(HAN_SPACE_RE, '')
  out = out.replace(PUNCT_RE, ' ')
  out = out.replace(SPACE_RE, ' ')
  return out.trim()
}

/** 有效命令：归一化后至少 minLen 个字符（过滤空命令与纯标点）。 */
export function isValidCommand(text, minLen = 2) {
  return normalize(text).length >= minLen
}

/** session id 形态限制：避免任意字符串进入 DSH / 文件路径。 */
export function isValidSessionId(sessionId) {
  return typeof sessionId === 'string' && /^[A-Za-z0-9_-]{1,64}$/.test(sessionId)
}

/** 唤醒词匹配器。 */
export class WakeMatcher {
  /**
   * @param {object} [options]
   * @param {string} [options.wakePhrase]
   * @param {string[]} [options.aliases]
   */
  constructor(options = {}) {
    this.wakePhrase = typeof options.wakePhrase === 'string' && options.wakePhrase
      ? options.wakePhrase
      : '小鲸小鲸'
    const aliases = Array.isArray(options.aliases) ? options.aliases : DEFAULT_WAKE_ALIASES
    const forms = new Set()
    for (const candidate of [this.wakePhrase, ...aliases]) {
      const form = normalize(candidate)
      if (form) forms.add(form)
    }
    // 长的优先，避免短别名抢先匹配。
    this.forms = [...forms].sort((a, b) => b.length - a.length)
  }

  /**
   * @param {string} utterance 识别文本
   * @returns {{matched: boolean, command: string}} matched 时 command 为唤醒词后的余量
   */
  match(utterance) {
    const norm = normalize(utterance)
    if (!norm) return { matched: false, command: '' }
    for (const form of this.forms) {
      if (norm === form) return { matched: true, command: '' }
      if (norm.startsWith(form)) {
        const rest = norm.slice(form.length).trim()
        return { matched: true, command: rest }
      }
    }
    return { matched: false, command: '' }
  }
}

/** 中文占比（调试用：判断 ASR 输出是否值得处理）。 */
export function hanRatio(text) {
  const norm = normalize(text).replace(/\s+/g, '')
  if (!norm) return 0
  let han = 0
  for (const ch of norm) if (HAN_RE.test(ch)) han += 1
  return han / [...norm].length
}