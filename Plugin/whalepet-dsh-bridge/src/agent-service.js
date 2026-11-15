/**
 * AgentCommandService：统一的「一句话 → Agent 执行 → 回复」服务。
 *
 * 架构依据：docs/CROSS_PLATFORM.md §9.1 / §9.3
 *   - 旧音频通道（/api/audio）与新文本通道（/api/agent）**共用**这一份实现，
 *     谁都不许再自己写一套「建会话 → prompt → wait → 取回复」。
 *   - 同一个长期会话（宠物会话）内，所有客户端的命令串行排队，避免两条 prompt
 *     塞进同一 turn。
 *   - prompt 的 requestId 由客户端的 request_id **稳定派生**：
 *     同一个 request_id 重试不会在 DSH 侧产生第二次 prompt。
 *   - 取消只中断「调用方等待」，**不假装**远程 Agent 已被停掉（§8.8）。
 *
 * 会话生命周期（建会话、轮换、归档、人格、权限）由调用方通过
 * `queueKey` / `resolveConversation` 注入，本文件只管「执行 + 排队 + 取回复」。
 */

import { lastAssistantText, toSpeechText } from './reply-text.js'

/** 判断错误是否为「会话不存在」（会话被 GUI 删掉后重建用）。 */
export function isSessionMissing(error) {
  const code = error?.code ?? error?.details?.code ?? ''
  const message = String(error?.message ?? '')
  return String(code).includes('not-found') || /not[- ]?found|不存在/i.test(message)
}

/** 小延迟（等待用户授权时轮询用）。 */
function delay(ms) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms)
    timer.unref?.()
  })
}

/**
 * @typedef {object} AgentCommandResult
 * @property {string} displayText 原始回答（保留 Markdown），给聊天面板/历史记录
 * @property {string} speechText  口语文本（去掉 Markdown），给 TTS
 */

/**
 * @typedef {object} ConversationHandle
 * @property {string} sessionId          DSH 会话 id
 * @property {() => Promise<void>} [prepare] 说话前准备（权限、人格、取消归档）
 * @property {(archived: boolean) => Promise<void>} [setArchived] 归档/取消归档
 * @property {() => void} [markMissing] 会话被删后的本地状态复位
 */

export class AgentCommandService {
  /**
   * @param {object} deps
   * @param {object} deps.sessions ctx.sessionController（官方会话服务）
   * @param {(conversationId: string) => string} deps.queueKey 队列键（同步）
   * @param {(conversationId: string) => Promise<ConversationHandle>} deps.resolveConversation 解析会话
   * @param {number} [deps.requestTimeoutMs] 单次 wait 的超时
   * @param {number} [deps.maxWaitMs] 单轮回答最长等待
   * @param {string} [deps.clientTimeZone]
   * @param {(request: {sessionId: string}) => string} [deps.onQuestion]
   *   需要回答时取「题目 + 选项」的口语文本；拿不到就回落到通用提示。
   * @param {{info?: Function, warn?: Function, error?: Function}} [deps.logger]
   */
  constructor({
    sessions,
    queueKey,
    resolveConversation,
    requestTimeoutMs = 300000,
    maxWaitMs = 600000,
    clientTimeZone = 'Asia/Shanghai',
    onQuestion,
    logger = {},
  }) {
    if (!sessions) throw new TypeError('AgentCommandService 需要 sessions')
    if (typeof queueKey !== 'function') throw new TypeError('AgentCommandService 需要 queueKey')
    if (typeof resolveConversation !== 'function') throw new TypeError('AgentCommandService 需要 resolveConversation')
    this.sessions = sessions
    this.queueKey = queueKey
    this.resolveConversation = resolveConversation
    this.requestTimeoutMs = Math.max(1000, Number(requestTimeoutMs) || 300000)
    this.maxWaitMs = Math.max(this.requestTimeoutMs, Number(maxWaitMs) || 600000)
    this.clientTimeZone = clientTimeZone
    this.onQuestion = typeof onQuestion === 'function' ? onQuestion : undefined
    this.logger = logger
    /** 队列键 -> 上一条任务的尾巴（串行化用）。 */
    this.queues = new Map()
    /** 正在跑的任务的内部控制器（插件卸载时统一中断）。 */
    this.controllers = new Set()
  }

  /**
   * 执行一条命令。
   *
   * @param {object} options
   * @param {string} options.requestId 客户端给的稳定请求 id（幂等键）
   * @param {string} options.conversationId 目标会话（宠物会话下通常只有一个）
   * @param {string} options.text 用户指令
   * @param {AbortSignal} [options.signal] 只中断「本调用方等待」，不动共享任务
   * @param {(event: {state: string, text?: string}) => void} [options.notify] 任务进度回调
   * @returns {Promise<AgentCommandResult>}
   */
  async execute({ requestId, conversationId, text, signal, notify } = {}) {
    const command = String(text ?? '').trim()
    if (!command) throw new Error('命令不能为空')
    const id = String(requestId ?? '').trim() || `req-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`
    const key = this.queueKey(conversationId)

    const previous = this.queues.get(key) ?? Promise.resolve()
    const controller = new AbortController()
    this.controllers.add(controller)
    const job = previous
      .then(() => this.#runJob({ requestId: id, conversationId, text: command, notify }, controller.signal))
      .catch(() => this.#runJob({ requestId: id, conversationId, text: command, notify }, controller.signal))
    // 队列尾巴只关心「有没有卡住」，失败不阻塞后续任务。
    this.queues.set(key, job.catch(() => {}))
    // 控制器跟随**任务**生命周期：调用方放弃等待后，任务仍在后台跑，
    // 插件卸载时依然能把它停掉。
    job.finally(() => this.controllers.delete(controller)).catch(() => {})
    return await this.#race(job, signal)
  }

  /** 中断所有正在跑的任务（插件卸载时用）。 */
  dispose() {
    for (const controller of this.controllers) {
      try {
        controller.abort(new Error('plugin disposed'))
      } catch {
        // 忽略
      }
    }
    this.controllers.clear()
    this.queues.clear()
  }

  /** 队列里还有多少个待执行/执行中的任务（排障用）。 */
  get pendingCount() {
    return this.queues.size
  }

  // -- 内部 ---------------------------------------------------------------

  /** 调用方等待：signal 只让**本调用方**放弃等待，共享任务继续跑。 */
  #race(job, signal) {
    if (!signal) return job
    if (signal.aborted) {
      const error = new Error('aborted')
      error.name = 'AbortError'
      return Promise.reject(error)
    }
    return new Promise((resolve, reject) => {
      const onAbort = () => {
        const error = new Error('aborted')
        error.name = 'AbortError'
        reject(error)
      }
      signal.addEventListener('abort', onAbort, { once: true })
      job.then(
        (value) => {
          signal.removeEventListener('abort', onAbort)
          resolve(value)
        },
        (error) => {
          signal.removeEventListener('abort', onAbort)
          reject(error)
        },
      )
    })
  }

  /** 队列里真正执行的一段：解析会话 → prompt → 等回复。 */
  async #runJob({ requestId, conversationId, text, notify }, signal) {
    let conversation = await this.resolveConversation(conversationId)
    try {
      await conversation.prepare?.()
      try {
        return await this.#promptAndWait(conversation, requestId, text, notify, signal)
      } catch (error) {
        if (!isSessionMissing(error)) throw error
        // 会话在 GUI 里被删了：复位本地状态，用同一个 id 重建，并重试一次。
        this.logger.warn?.(`whalepet: 会话 ${conversation.sessionId} 已不存在，重新创建`)
        conversation.markMissing?.()
        conversation = await this.resolveConversation(conversationId)
        await conversation.prepare?.()
        return await this.#promptAndWait(conversation, requestId, text, notify, signal)
      }
    } finally {
      // 空闲时归档：DSH 列表里看不到宠物会话，说话前再自动恢复。
      try {
        await conversation.setArchived?.(true)
      } catch (error) {
        this.logger.warn?.(`whalepet: 归档宠物会话失败: ${error?.message ?? error}`)
      }
    }
  }

  /** prompt + wait：返回原始文本与口语文本。 */
  async #promptAndWait(conversation, requestId, text, notify, signal) {
    const sessionId = conversation.sessionId
    let cursor = 0
    try {
      cursor = (await this.sessions.state({ sessionId }, signal))?.cursor ?? 0
    } catch {
      // 冷会话读不到被动状态时按 0 处理：wait 会返回当前可见的 assistant 记录。
      cursor = 0
    }
    await this.sessions.prompt({
      // 稳定的 requestId：同一个 request_id 重试不会产生第二次 DSH prompt。
      requestId: `whalepet-${sessionId}-${requestId}`,
      sessionId,
      mode: 'queue',
      content: [{ type: 'text', text }],
      clientTimeZone: this.clientTimeZone,
    }, signal)
    notify?.({ state: 'started', text: '开始执行，我这就去办' })
    const displayText = await this.#waitForReply(sessionId, cursor, signal, notify)
    return { displayText, speechText: toSpeechText(displayText) }
  }

  /**
   * 等宠物 Agent 这一轮结束：允许多次 wait，最长 maxWaitMs。
   * 超时但不是彻底失败时，把已经产生的回复带回（比空白强）。
   */
  async #waitForReply(sessionId, afterSeq, signal, notify) {
    const startedAt = Date.now()
    let best = ''
    let confirmNotified = false
    for (;;) {
      const slice = Math.max(5000, Math.min(this.requestTimeoutMs, this.maxWaitMs - (Date.now() - startedAt)))
      const waited = await this.sessions.wait({
        sessionId,
        afterSeq,
        timeoutMs: slice,
      }, signal)
      const text = lastAssistantText(waited?.output?.records)
      if (text) best = text
      if (waited?.reason === 'idle') {
        if (best) return best
        throw new Error('DSH 没有返回文字回复')
      }
      if (waited?.reason === 'input-required') {
        // 需要授权/回答：通知一次，然后继续等——用户在 GUI 里点完，任务会自动往下跑。
        if (!confirmNotified) {
          confirmNotified = true
          const pending = Array.isArray(waited?.state?.pendingInput) ? waited.state.pendingInput : []
          // 只有问题、没有授权时，才能确定这是「要你选」；题目内容由 onQuestion 钩子补全。
          const questionOnly = pending.length > 0
            && pending.every((kind) => kind === 'question')
            && typeof this.onQuestion === 'function'
          if (questionOnly) {
            const spoken = this.onQuestion({ sessionId })
            if (spoken) {
              notify?.({ state: 'approval', text: spoken })
              await delay(1500)
              signal?.throwIfAborted?.()
              continue
            }
          }
          const needsApproval = pending.includes('approval') || pending.length === 0
          notify?.({
            state: 'approval',
            text: needsApproval
              ? '有个操作需要你授权，去 DSH 里点一下同意，我再接着做'
              : '有个问题需要你回答，去 DSH 里回一下，我再接着做',
          })
        }
        if (Date.now() - startedAt >= this.maxWaitMs) {
          if (best) return best
          throw new Error('等你确认后我才能继续（去 DSH 会话列表里点一下）')
        }
        await delay(1500)
        signal?.throwIfAborted?.()
        continue
      }
      // timeout：还在跑就继续等，直到 maxWaitMs。
      if (Date.now() - startedAt >= this.maxWaitMs) {
        if (best) return best
        throw new Error('DSH 响应超时')
      }
      signal?.throwIfAborted?.()
    }
  }
}
