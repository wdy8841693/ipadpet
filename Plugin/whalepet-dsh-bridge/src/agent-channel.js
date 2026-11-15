/**
 * AgentChannel：新客户端的纯 JSON 通道（WS /api/agent）。
 *
 * 架构依据：docs/CROSS_PLATFORM.md §8
 *   - 客户端把「识别后的文本」发过来，服务端负责执行、路由、任务事件与断线补发。
 *   - 私有回答只发给发起设备；全局通知只发给订阅者。
 *   - 断线不主动终止正在运行的 Agent；结果按客户端缓存，重连后按 event_id 补发。
 *
 * 消息类型：hello / command / cancel（客户端 → 服务端）
 *           ready / voice_config / task / response / announcement / error（服务端 → 客户端）
 */

import {
  AGENT_PROTOCOL_VERSION,
  MAX_CONTROL_MESSAGE_BYTES,
  validateCancel,
  validateCommand,
  validateHello,
} from './agent-protocol.js'

export class AgentChannel {
  /**
   * @param {object} options
   * @param {import('./ws.js').WebSocketConnection} options.connection
   * @param {import('./agent-service.js').AgentCommandService} options.service
   * @param {import('./client-hub.js').ClientHub} options.hub
   * @param {{info?: Function, warn?: Function, error?: Function}} [options.logger]
   * @param {() => object|null} [options.getVoiceConfig] 供 voice_config 下发用
   */
  constructor({ connection, service, hub, logger, getVoiceConfig }) {
    this.connection = connection
    this.service = service
    this.hub = hub
    this.logger = logger ?? {}
    this.getVoiceConfig = typeof getVoiceConfig === 'function' ? getVoiceConfig : () => null
    this.closed = false
    this.clientId = null
    this.conversationId = null
    /** 本连接正在跑的请求：requestId -> { cancelled: boolean } */
    this.active = new Map()
  }

  start() {
    this.connection.on('message', (data, isBinary) => {
      if (isBinary) return // 本通道只收文本 JSON
      this.#onText(data.toString('utf8'))
    })
    this.connection.on('close', () => this.shutdown())
  }

  send(payload) {
    if (this.closed) return
    try {
      this.connection.sendJSON(payload)
    } catch {
      // 忽略：连接已经断了
    }
  }

  // -- 收消息 -------------------------------------------------------------

  #onText(raw) {
    if (this.closed) return
    if (Buffer.byteLength(raw, 'utf8') > MAX_CONTROL_MESSAGE_BYTES) {
      this.#sendError({ code: 'message_too_large', message: '控制消息太大' })
      return
    }
    let message
    try {
      message = JSON.parse(raw)
    } catch {
      this.#sendError({ code: 'bad_json', message: '不是合法的 JSON' })
      return
    }
    const type = message?.type
    if (type === 'hello') {
      this.#handleHello(message)
      return
    }
    if (type === 'command') {
      this.#handleCommand(message)
      return
    }
    if (type === 'cancel') {
      this.#handleCancel(message)
      return
    }
    this.#sendError({ code: 'unknown_message', message: `未知消息类型：${String(type ?? '')}` })
  }

  // -- 握手 ---------------------------------------------------------------

  #handleHello(message) {
    const validated = validateHello(message)
    if (!validated.ok) {
      this.#sendError({ code: validated.code, message: validated.message })
      this.connection.close(1008, 'bad hello')
      return
    }
    const { clientId, conversationId, deviceKind, capabilities, subscriptions, lastReceivedEventId } = validated.value

    this.clientId = clientId
    this.conversationId = conversationId
    this.hub.register(clientId, this.connection, {
      conversationId,
      deviceKind,
      capabilities,
      subscriptions,
    })
    this.logger.info?.(`whalepet: Agent 通道握手 client=${clientId} conversation=${conversationId}`)

    this.send({
      type: 'ready',
      protocol: AGENT_PROTOCOL_VERSION,
      client_id: clientId,
      conversation_id: conversationId,
      // 新通道不依赖服务端 ASR：语音识别模型没就绪也照样能跑。
      agent_ready: true,
      server_time: new Date().toISOString(),
    })

    // 唤醒词等语音配置随 ready 之后下发（§11.3）。
    const voiceConfig = this.getVoiceConfig?.()
    if (voiceConfig) this.send({ type: 'voice_config', ...voiceConfig })

    // 先补发可靠事件，再补发仍在跑的任务状态。
    for (const event of this.hub.replay(clientId, lastReceivedEventId)) {
      this.send(event)
    }
    for (const record of this.hub.runningRequests(clientId)) {
      this.send({
        type: 'task',
        event_id: this.hub.nextEventId(),
        request_id: record.requestId,
        origin_client_id: clientId,
        task_id: `${record.conversationId}:${record.requestId}`,
        state: 'interrupted',
        text: '连接恢复了，刚才的任务还在后台继续',
      })
    }
  }

  // -- 命令 ---------------------------------------------------------------

  async #handleCommand(message) {
    if (!this.clientId) {
      this.#sendError({ code: 'not_hello', message: '请先完成 hello 握手' })
      return
    }
    const validated = validateCommand(message)
    if (!validated.ok) {
      this.#sendError({ code: validated.code, message: validated.message, request_id: message?.request_id })
      return
    }
    const { requestId, conversationId, text, source } = validated.value
    const clientId = this.clientId

    // 幂等：同一个 request_id 不得重复 prompt（§8.4）。
    const existing = this.hub.getRequest(requestId)
    if (existing) {
      if (existing.originClientId && existing.originClientId !== clientId) {
        this.#sendError({ code: 'request_conflict', message: 'request_id 已被别的设备使用', request_id: requestId })
        return
      }
      if (existing.state === 'done' && existing.result?.response) {
        // 结果已经可靠投递过：原样补发（event_id 不变，客户端可自行去重）。
        this.send(existing.result.response)
        return
      }
      if (existing.state === 'running') {
        this.send({
          type: 'task',
          event_id: this.hub.nextEventId(),
          request_id: requestId,
          origin_client_id: clientId,
          task_id: `${conversationId}:${requestId}`,
          state: 'queued',
          text: '这个命令已经在处理了',
        })
        return
      }
      if (existing.state === 'cancelled') {
        this.send({
          type: 'task',
          event_id: this.hub.nextEventId(),
          request_id: requestId,
          origin_client_id: clientId,
          task_id: `${conversationId}:${requestId}`,
          state: 'interrupted',
          text: '这个命令已经被取消了',
        })
        return
      }
    }

    // 同一客户端第一版只允许一个活动语音命令。
    const busy = [...this.active.entries()].find(([, item]) => !item.cancelled)
    if (busy) {
      this.#sendError({
        code: 'client_busy',
        message: '你还有一个命令在处理中',
        request_id: requestId,
      })
      return
    }

    this.hub.beginRequest({ requestId, originClientId: clientId, conversationId, text })
    const entry = { cancelled: false }
    this.active.set(requestId, entry)

    // 先回一个 queued，让用户知道命令被收到了（共享会话可能正忙）。
    this.#sendTask(clientId, requestId, conversationId, 'queued', '收到，正在排队')

    const notify = (event) => {
      if (entry.cancelled || !event?.state) return
      const state = String(event.state)
      this.#sendTask(clientId, requestId, conversationId, state, event.text, {
        reliable: state === 'approval',
      })
    }

    try {
      const result = await this.service.execute({
        requestId,
        conversationId,
        text,
        notify,
      })
      if (entry.cancelled) {
        // 用户已经取消：不再展示结果（远程任务可能仍在后台跑完）。
        this.hub.completeRequest(requestId, { cancelled: true })
        return
      }
      const response = {
        type: 'response',
        event_id: this.hub.nextEventId(),
        request_id: requestId,
        origin_client_id: clientId,
        task_id: `${conversationId}:${requestId}`,
        display_text: result?.displayText ?? '',
        speech_text: result?.speechText ?? '',
        final: true,
      }
      // 先 response 再 task finished（§8.6）。
      this.hub.deliverTo(clientId, response, { reliable: true })
      this.hub.completeRequest(requestId, { response })
      this.#sendTask(clientId, requestId, conversationId, 'finished', '做完了')
    } catch (error) {
      if (entry.cancelled) {
        this.hub.completeRequest(requestId, { cancelled: true })
        return
      }
      const message = error?.message ?? String(error)
      const aborted = error?.name === 'AbortError'
      this.hub.failRequest(requestId, error)
      if (aborted) {
        this.#sendTask(clientId, requestId, conversationId, 'interrupted', '已停止等待')
        return
      }
      this.#sendTask(clientId, requestId, conversationId, 'failed', '出错了')
      this.#sendError({
        code: 'agent_failed',
        message,
        retryable: true,
        request_id: requestId,
      })
    } finally {
      this.active.delete(requestId)
    }
  }

  // -- 取消 ---------------------------------------------------------------

  #handleCancel(message) {
    const validated = validateCancel(message)
    if (!validated.ok) {
      this.#sendError({ code: validated.code, message: validated.message, request_id: message?.request_id })
      return
    }
    const { requestId, clientId } = validated.value
    if (this.clientId && clientId && clientId !== this.clientId) {
      this.#sendError({ code: 'not_owner', message: '只能取消自己发起的命令', request_id: requestId })
      return
    }
    const entry = this.active.get(requestId)
    if (!entry) {
      this.#sendTask(this.clientId ?? '', requestId, this.conversationId ?? '', 'interrupted', '没有在跑的命令')
      return
    }
    entry.cancelled = true
    this.hub.cancelRequest(requestId)
    // 只承诺「桥接层停止等待并忽略后续展示」，不宣称远程 Agent 已终止（§8.8）。
    this.#sendTask(this.clientId ?? '', requestId, this.conversationId ?? '', 'interrupted', '已停止等待（远程任务可能仍在继续）')
  }

  // -- 发消息 -------------------------------------------------------------

  #sendTask(clientId, requestId, conversationId, state, text, { reliable = false } = {}) {
    if (!clientId) return
    const payload = {
      type: 'task',
      event_id: this.hub.nextEventId(),
      request_id: requestId,
      origin_client_id: clientId,
      task_id: `${conversationId}:${requestId}`,
      state,
    }
    if (text) payload.text = String(text)
    this.hub.deliverTo(clientId, payload, { reliable })
  }

  #sendError({ code, message, retryable = false, request_id } = {}) {
    const payload = {
      type: 'error',
      code: String(code ?? 'error'),
      message: String(message ?? ''),
      retryable: Boolean(retryable),
    }
    if (request_id) payload.request_id = request_id
    this.send(payload)
  }

  /** 连接断开：摘掉在线连接；**不打断**正在跑的任务。 */
  shutdown() {
    if (this.closed) return
    this.closed = true
    this.hub?.unregister(this.connection)
  }

  /** 插件关闭时才中断本连接上的等待。 */
  dispose() {
    for (const entry of this.active.values()) entry.cancelled = true
    this.shutdown()
  }
}
