/**
 * 旧音频通道：iPad 的 WS /api/audio 管线（VAD → 转写 → 唤醒 → 命令 → Agent）。
 *
 * 架构依据：docs/CROSS_PLATFORM.md §5 / §8.1
 *   - 这条通道**原样保留**：iPad mini 4 不改代码。
 *   - 它只负责「听到什么、何时唤醒」，执行部分走统一的 AgentCommandService。
 *   - 新客户端走 /api/agent（纯 JSON），两条通道互不影响。
 */

import { WakeMatcher, isValidSessionId } from './textnorm.js'
import { pcm16ToWav } from './wav.js'
import { VoiceSession, PHASE, WAKE } from './session.js'
import { EnergyVad, FrameSplitter, UtteranceSegmenter } from './vad.js'

/** 把 adapter 抛出的错误整理成一句人能读的话。 */
export function describeError(error) {
  if (!error) return '未知错误'
  const message = error instanceof Error ? error.message : String(error)
  return message.length > 300 ? `${message.slice(0, 300)}…` : message
}

/** 单个客户端的语音管线：VAD -> 转写 -> 唤醒/命令 -> Agent。 */
export class VoicePipeline {
  /**
   * @param {object} options
   * @param {import('./ws.js').WebSocketConnection} options.connection
   * @param {object} options.adapter
   * @param {ReturnType<typeof import('./server.js').normalizeBridgeConfig>} options.config
   * @param {{info?: Function, warn?: Function, error?: Function}} [options.logger]
   */
  constructor({ connection, adapter, config, logger, delivery, getSettings }) {
    this.connection = connection
    this.adapter = adapter
    this.config = config
    this.logger = logger ?? {}
    /** 跨连接投递状态（断线重连后补发结果）。 */
    this.delivery = delivery
    /** 运行时设置（设置页可改）：缺省时退回 config。 */
    this.getSettings = typeof getSettings === 'function' ? getSettings : () => config
    this.session = new VoiceSession(this.#wakeMatcher(), config.voice)
    this.vad = new EnergyVad(config.vad)
    this.splitter = new FrameSplitter(config.voice.frameBytes, (frame) => this.#onFrame(frame))
    this.closed = false
    this.capturePaused = false
    this.sessionId = null
    this.listenTimer = null
    this.utteranceChain = Promise.resolve()
    this.generation = 0
    this.currentController = null
    this.helloDone = false
  }

  /** 当前唤醒词（设置页可改，新连接生效）。 */
  #wakePhrase() {
    const settings = this.getSettings?.() ?? {}
    const phrase = typeof settings.wakePhrase === 'string' ? settings.wakePhrase.trim() : ''
    return phrase || this.config.wakePhrase
  }

  /** 只唤醒不说指令时宠物回的一句（空字符串 = 不启用）。 */
  #wakeAck() {
    const settings = this.getSettings?.() ?? {}
    if (typeof settings.wakeAck === 'string') return settings.wakeAck.trim()
    return typeof this.config.wakeAck === 'string' ? this.config.wakeAck.trim() : ''
  }

  #wakeMatcher() {
    return new WakeMatcher({ wakePhrase: this.#wakePhrase(), aliases: this.config.wakeAliases })
  }

  start() {
    this.connection.on('message', (data, isBinary) => {
      if (isBinary) this.feedAudio(data)
      else this.handleControl(data.toString('utf8'))
    })
    this.connection.on('close', () => this.shutdown())
    this.send({
      ok: true,
      type: 'ready',
      wake_phrase: this.#wakePhrase(),
      sample_rate: this.config.voice.sampleRate,
    })
  }

  send(payload) {
    if (this.closed) return
    this.connection.sendJSON(payload)
  }

  // -- 控制消息 ------------------------------------------------------------

  handleControl(raw) {
    const text = String(raw ?? '').trim()
    if (!text) return
    if (text === 'manual_start') {
      this.session.manualStart()
      this.#resetAudio()
      this.send({ type: 'state', value: 'listening' })
      this.#armListenTimeout()
      return
    }
    if (text === 'cancel') {
      this.#cancelCurrent()
      if (this.delivery) {
        this.delivery.running = false
        this.delivery.buffered = null
        this.delivery.pendingApproval = null
      }
      this.session.reset()
      this.#resetAudio()
      this.send({ type: 'state', value: 'waiting' })
      return
    }
    if (text === 'playback_start') {
      // 宠物开始播报：暂停拾音，避免拾到自己的声音。
      this.capturePaused = true
      this.#resetAudio()
      return
    }
    if (text === 'playback_end') {
      this.capturePaused = false
      this.#resetAudio()
      // 唤醒应答（「我在」）说完后继续听指令，不要退回待唤醒；
      // 其它播报（回答/提醒）结束才回到待唤醒。
      if (this.session.phase === PHASE.LISTENING) {
        this.send({ type: 'state', value: 'listening' })
        this.#armListenTimeout()
        return
      }
      this.session.reset()
      this.send({ type: 'state', value: 'waiting' })
      return
    }
    let data
    try {
      data = JSON.parse(text)
    } catch {
      this.send({ type: 'error', message: '无法解析的控制消息' })
      return
    }
    if (data && data.type === 'hello') {
      this.#handleHello(data)
      return
    }
    this.send({ type: 'error', message: '未知控制消息' })
  }

  #handleHello(data) {
    const sessionId = data.session_id
    if (!isValidSessionId(sessionId)) {
      this.send({ type: 'error', message: 'session_id 不合法' })
      this.connection.close(1008, 'bad session id')
      return
    }
    this.sessionId = sessionId
    this.helloDone = true
    if (this.delivery) {
      this.delivery.subscriber = this
      this.#flushDelivery()
    }
    this.logger.info?.(`whalepet: 客户端握手 session=${sessionId}`)
    Promise.resolve()
      .then(() => this.adapter.prepareSession?.(sessionId))
      .catch((error) => {
        this.logger.warn?.(`whalepet: prepareSession 失败: ${error?.message ?? error}`)
      })
  }

  // -- 音频 ----------------------------------------------------------------

  feedAudio(chunk) {
    if (this.closed || this.capturePaused) return
    this.splitter.push(chunk)
  }

  #onFrame(frame) {
    if (this.closed || this.capturePaused) return
    const pcm = this.segmenter?.push(frame) ?? null
    if (pcm) this.#enqueueUtterance(pcm)
  }

  get segmenter() {
    if (!this._segmenter) {
      this._segmenter = new UtteranceSegmenter(this.config.voice, this.session, this.vad)
    }
    return this._segmenter
  }

  #resetAudio() {
    this.splitter.reset()
    this._segmenter?.reset()
    this.vad.reset()
  }

  #enqueueUtterance(pcm) {
    this.utteranceChain = this.utteranceChain
      .then(() => this.#processUtterance(pcm))
      .catch((error) => {
        this.logger.warn?.(`whalepet: 语音处理失败: ${error?.stack ?? error}`)
      })
  }

  async #processUtterance(pcm) {
    if (this.closed || this.capturePaused) return
    const generation = this.generation
    const controller = new AbortController()
    this.currentController = controller
    let text = ''
    try {
      const wav = pcm16ToWav(pcm, this.config.voice.sampleRate)
      text = (await this.adapter.transcribe(wav, { signal: controller.signal }) ?? '').trim()
    } catch (error) {
      if (!this.closed && generation === this.generation) {
        this.send({ type: 'error', message: `语音识别失败：${describeError(error)}` })
      }
      return
    }
    if (this.closed || generation !== this.generation) return
    if (!text) return

    if (this.session.phase === PHASE.WAITING) {
      const { outcome, command } = this.session.feedWaiting(text)
      if (outcome === WAKE.NONE) return // 普通环境人声，忽略
      this.send({ type: 'wake', phrase: text })
      if (outcome === WAKE.WAKE_WITH_COMMAND) {
        await this.#dispatchCommand(command)
      } else {
        this.send({ type: 'state', value: 'listening' })
        this.#armListenTimeout()
        // 「我在」：App 收到 response 会念出来；说完后仍然处于聆听态（见 playback_end）。
        const ack = this.#wakeAck()
        if (ack) this.send({ type: 'response', text: ack })
      }
      return
    }
    const { ok, command } = this.session.feedListening(text)
    if (ok) {
      this.#disarmListenTimeout()
      await this.#dispatchCommand(command)
    }
    // 无效命令继续等待，不额外提示。
  }

  // -- 命令 -> Agent -------------------------------------------------------

  async #dispatchCommand(command) {
    if (!this.sessionId) {
      this.send({ type: 'error', message: '尚未完成 hello 握手' })
      return
    }
    this.send({ type: 'transcript', text: command })
    this.send({ type: 'state', value: 'thinking' })
    const generation = ++this.generation
    const controller = new AbortController()
    this.currentController = controller
    const heartbeat = this.#startThinkingHeartbeat()
    const delivery = this.delivery
    if (delivery) {
      delivery.running = true
      delivery.sessionId = this.sessionId
      delivery.buffered = null
    }
    /** 把事件送给「当前在线的连接」；断线时 approval 先缓存，其余丢弃。 */
    const notify = (event) => {
      if (!event?.state) return
      const target = delivery?.subscriber
      if (target && !target.closed) {
        target.send({
          type: 'task',
          state: String(event.state),
          ...(event.text ? { text: String(event.text) } : {}),
        })
      } else if (event.state === 'approval' && delivery) {
        delivery.pendingApproval = { text: String(event.text ?? '') }
      }
    }
    /** 任务结束：在线就推给当前连接，断线就缓存等重连补发。 */
    const settle = (result) => {
      if (generation !== this.generation) return
      if (delivery) {
        delivery.running = false
        delivery.pendingApproval = null
      }
      const target = delivery?.subscriber
      if (target && !target.closed) {
        if (result.kind === 'error') {
          target.send({ type: 'task', state: 'failed', text: '出错了' })
          target.send({ type: 'error', message: `DSH 出错：${result.message}` })
        } else {
          target.send({ type: 'response', text: result.text })
          target.send({ type: 'task', state: 'finished', text: '做完了' })
        }
        return
      }
      if (delivery) {
        delivery.buffered = result
      }
    }
    try {
      const reply = await this.adapter.ask(this.sessionId, command, {
        signal: controller.signal,
        notify,
      })
      settle({ kind: 'reply', text: String(reply ?? '') })
    } catch (error) {
      if (generation !== this.generation) return
      if (error?.name === 'AbortError') {
        if (delivery) delivery.running = false
        if (!this.closed) this.send({ type: 'state', value: 'waiting' })
        return
      }
      settle({ kind: 'error', message: describeError(error) })
    } finally {
      if (heartbeat) clearInterval(heartbeat)
      if (this.currentController === controller) this.currentController = null
    }
  }

  /** 长任务期间周期性发 thinking 事件：iPad 会一直显示「思考中」，不会以为断线。 */
  #startThinkingHeartbeat() {
    const interval = this.config.progressIntervalMs
    if (!interval || interval <= 0) return null
    const timer = setInterval(() => {
      if (this.closed) return
      this.send({ type: 'thinking' })
    }, interval)
    timer.unref?.()
    return timer
  }

  #cancelCurrent() {
    this.generation += 1
    const controller = this.currentController
    this.currentController = null
    if (controller) controller.abort(new Error('cancelled by client'))
  }

  // -- 聆听超时 ------------------------------------------------------------

  #armListenTimeout() {
    this.#disarmListenTimeout()
    const ms = Math.max(1000, Math.round(this.config.voice.listenTimeoutS * 1000))
    this.listenTimer = setTimeout(() => {
      this.listenTimer = null
      if (this.closed) return
      if (this.session.phase === PHASE.LISTENING) {
        this.session.reset()
        this.send({ type: 'state', value: 'waiting' })
      }
    }, ms)
    this.listenTimer.unref?.()
  }

  #disarmListenTimeout() {
    if (this.listenTimer) {
      clearTimeout(this.listenTimer)
      this.listenTimer = null
    }
  }

  /** 连接断开：停止发送，但**不打断正在跑的任务**——结果留给重连后的新连接。 */
  shutdown() {
    if (this.closed) return
    this.closed = true
    this.#disarmListenTimeout()
    if (this.delivery?.subscriber === this) this.delivery.subscriber = null
  }

  /** 服务端/插件真正关闭时才打断任务。 */
  dispose() {
    this.#cancelCurrent()
    this.shutdown()
  }

  /**
   * 重连后补发断线期间的结果：
   *   pendingApproval -> approval 提醒
   *   buffered        -> task finished + response / task failed + error
   *   仍在跑          -> task interrupted + 持续 thinking
   */
  #flushDelivery() {
    const delivery = this.delivery
    if (!delivery) return
    if (delivery.pendingApproval) {
      const notice = delivery.pendingApproval
      delivery.pendingApproval = null
      this.send({ type: 'task', state: 'approval', text: notice.text })
    }
    if (delivery.buffered) {
      const buffered = delivery.buffered
      delivery.buffered = null
      if (buffered.kind === 'error') {
        this.send({ type: 'task', state: 'failed', text: '出错了' })
        this.send({ type: 'error', message: buffered.message })
      } else {
        this.send({ type: 'task', state: 'finished', text: '刚才断线了，任务已经做完' })
        this.send({ type: 'response', text: buffered.text })
      }
      return
    }
    if (delivery.running) {
      this.send({ type: 'task', state: 'interrupted', text: '连接恢复了，刚才的任务还在后台继续' })
      this.send({ type: 'state', value: 'thinking' })
    }
  }
}
