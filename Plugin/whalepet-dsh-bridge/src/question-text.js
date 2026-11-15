/**
 * 把「需要你选择/回答」的题目整理成一句能念出来的中文。
 *
 * DSH 的 `user-questions/request` 带完整题目（question / options / multiSelect），
 * 但 TTS 只能念一句话，所以这里做三件事：
 *   1. 去掉换行/Markdown，压成一行；
 *   2. 选项用口语序数词念（第一个…第二个…），每个截断到 limit 字；
 *   3. 选项超过 maxOptions 个时只念前面几个，剩下的提示去会话里看。
 */

/** 口语句首，避免念出「1.」「-」这类列表符号。 */
const ORDINALS = ['第一个', '第二个', '第三个', '第四个', '第五个']

const squash = (value) => String(value ?? '').replace(/\s+/g, ' ').trim()

const clip = (value, limit) => {
  const one = squash(value)
  if (!one) return ''
  const chars = [...one]
  return chars.length > limit ? `${chars.slice(0, limit).join('')}…` : one
}

/**
 * @param {object} options
 * @param {string} options.question 题目正文
 * @param {Array<{label?: string}>} [options.options] 选项
 * @param {boolean} [options.multiSelect] 是否多选
 * @param {number} [options.questionChars] 题目最多念多少字
 * @param {number} [options.optionChars] 每个选项最多念多少字
 * @param {number} [options.maxOptions] 最多念几个选项
 * @returns {string} 例如：要选保存目录，选项：第一个 工作区，第二个 桌面；去 DSH 里选一下
 */
export function describeQuestion({
  question,
  options,
  multiSelect = false,
  questionChars = 40,
  optionChars = 12,
  maxOptions = 3,
} = {}) {
  const stem = clip(question, questionChars) || '有个问题需要你回答'
  const list = Array.isArray(options)
    ? options
      .map((option) => clip(option?.label ?? option?.description ?? option, optionChars))
      .filter(Boolean)
    : []
  if (list.length === 0) {
    return `${stem}；去 DSH 里回一下，我再接着做`
  }
  const shown = list.slice(0, Math.max(1, maxOptions))
  const spoken = shown.map((label, index) => `${ORDINALS[index] ?? `第${index + 1}个`} ${label}`).join('，')
  const more = list.length > shown.length ? `，还有 ${list.length - shown.length} 个选项去 DSH 里看` : ''
  const tail = multiSelect ? '；可以多选，去 DSH 里选一下' : '；去 DSH 里选一下'
  return `${stem}。选项：${spoken}${more}${tail}`
}

/** 取请求里的第一道题（DSH 目前一次给一道，多道也只念第一道）。 */
export function firstQuestion(request) {
  const items = Array.isArray(request?.questions) ? request.questions : []
  return items[0] ?? undefined
}