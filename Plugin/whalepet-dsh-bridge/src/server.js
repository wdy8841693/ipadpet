/**
 * WhalePet 局域网网关：HTTP + WebSocket 协议实现（传输层）。
 *
 * 协议与 Server/whalepet_bridge/server.py 完全兼容，iPad App 端不需要改代码，
 * 只要把「服务器地址」指向运行 DSH 的这台机器 + 端口（默认 8787）。
 *
 *   GET  /api/health  -> {"ok":true,"asr":bool,"model":"..."}
 *   POST /api/chat    -> {"session_id","text"} -> {"ok":true,"reply":"..."}
 *   WS   /api/audio   -> hello / manual_start / cancel / playback_start /
 *                        playback_end（文本），二进制 = 16k mono PCM16
 *   服务端事件：ready / state / wake / transcript / thinking / response / error
 *
 * 依赖注入：本文件不 import 任何 DSH 包，只依赖下面这个 adapter 契约，
 * 因此可以用 mock adapter 在普通 node 下跑端到端测试。
 *
 * @typedef {object} BridgeAdapter
 * @property {() => Promise<{ready: boolean, detail?: string}>} health
 * @property {(wav: Buffer, options?: {signal?: AbortSignal}) => Promise<string>} transcribe
 * @property {(sessionId: string, text: string, options?: {signal?: AbortSignal, notify?: (event: {state: string, text?: string}) => void}) => Promise<string>} ask
 * @property {(sessionId: string) => Promise<void>|void} [prepareSession]
 * @property {() => Promise<void>|void} [close]
 */

import { createServer } from 'node:http'
import { appendFile } from 'node:fs/promises'
import { createHash, timingSafeEqual } from 'node:crypto'
import { WakeMatcher, DEFAULT_WAKE_ALIASES, isValidSessionId } from './textnorm.js'
import { pcm16ToWav } from './wav.js'
import { VoiceSession, PHASE, WAKE, voiceConfig } from './session.js'
import { EnergyVad, FrameSplitter, UtteranceSegmenter } from './vad.js'
import { attachWebSocketServer } from './ws.js'

const PLUGIN_VERSION = '0.2.3'
const MAX_HTTP_BODY = 64 * 1024
const MAX_WS_MESSAGE = 512 * 1024

export class BridgeConfigError extends Error {}

/** 常数时间比较（先做 sha256，避免长度差异泄露）。 */
export function tokenEquals(supplied, expected) {
  if (typeof supplied !== 'string' || typeof expected !== 'string' || !expected) return false
  const a = createHash('sha256').update(supplied).digest()
  const b = createHash('sha256').update(expected).digest()
  return timingSafeEqual(a, b)
}

function bearerToken(req) {
  const header = req.headers.authorization ?? ''
  if (typeof header !== 'string' || !header.startsWith('Bearer ')) return ''
  return header.slice('Bearer '.length).trim()
}

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload)
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  })
  res.end(body)
}

async function readBody(req, limit = MAX_HTTP_BODY) {
  const chunks = []
  let total = 0
  for await (const chunk of req) {
    total += chunk.length
    if (total > limit) throw new RangeError('body too large')
    chunks.push(chunk)
  }
  return Buffer.concat(chunks)
}

/** 单个客户端的语音管线：VAD -> 转写 -> 唤醒/命令 -> Agent。 */
export class VoicePipeline {
  /**
   * @param {object} options
   * @param {import('./ws.js').WebSocketConnection} options.connection
   * @param {BridgeAdapter} options.adapter
   * @param {ReturnType<typeof normalizeBridgeConfig>} options.config
   * @param {{info?: Function, warn?: Function, error?: Function}} [options.logger]
   */
  constructor({ connection, adapter, config, logger, delivery }) {
    this.connection = connection
    this.adapter = adapter
    this.config = config
    this.logger = logger ?? {}
    /** 跨连接投递状态（断线重连后补发结果）。 */
    this.delivery = delivery
    this.session = new VoiceSession(new WakeMatcher(config), config.voice)
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

  start() {
    this.connection.on('message', (data, isBinary) => {
      if (isBinary) this.feedAudio(data)
      else this.handleControl(data.toString('utf8'))
    })
    this.connection.on('close', () => this.shutdown())
    this.send({
      ok: true,
      type: 'ready',
      wake_phrase: this.config.wakePhrase,
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

/** 把 adapter 抛出的错误整理成一句人能读的话。 */
function describeError(error) {
  if (!error) return '未知错误'
  const message = error instanceof Error ? error.message : String(error)
  return message.length > 300 ? `${message.slice(0, 300)}…` : message
}

/** 归一化 + 校验插件配置。 */
export function normalizeBridgeConfig(raw = {}) {
  const token = typeof raw.token === 'string' ? raw.token.trim() : ''
  if (!token) throw new BridgeConfigError('token 未配置：iPad 需要 Bearer 令牌才能访问')
  if (token.length < 16) throw new BridgeConfigError('token 太短：至少 16 个字符')
  const port = Number(raw.port ?? 8787)
  // 0 表示由内核分配（测试用）；正式配置默认 8787。
  if (!Number.isInteger(port) || port < 0 || port > 65535) {
    throw new BridgeConfigError(`port 不合法: ${raw.port}`)
  }
  const host = typeof raw.host === 'string' && raw.host.trim() ? raw.host.trim() : '0.0.0.0'
  const wakePhrase = typeof raw.wakePhrase === 'string' && raw.wakePhrase.trim()
    ? raw.wakePhrase.trim()
    : '小鲸小鲸'
  const aliases = Array.isArray(raw.wakeAliases) && raw.wakeAliases.length > 0
    ? raw.wakeAliases.filter((value) => typeof value === 'string' && value.trim()).map((value) => value.trim())
    : [...DEFAULT_WAKE_ALIASES]
  const voice = voiceConfig({
    sampleRate: 16000,
    frameMs: clampInt(raw.frameMs, 20, 10, 30),
    preRollMs: clampInt(raw.preRollMs, 300, 0, 1000),
    silenceMs: clampInt(raw.silenceMs, 700, 200, 3000),
    maxUtteranceS: clampNumber(raw.maxUtteranceS, 20, 3, 60),
    listenTimeoutS: clampNumber(raw.listenTimeoutS, 10, 2, 120),
  })
  const vad = {
    floorDbfs: clampNumber(raw.vadFloorDbfs, -55, -80, -20),
    marginDb: clampNumber(raw.vadMarginDb, 10, 3, 30),
    onsetFrames: clampInt(raw.vadOnsetFrames, 2, 1, 10),
  }
  return {
    host,
    port,
    token,
    wakePhrase,
    wakeAliases: aliases,
    language: typeof raw.language === 'string' && raw.language.trim() ? raw.language.trim() : 'zh',
    voice,
    vad,
    /** 长任务期间给宠物发 thinking 心跳的间隔（0 表示关闭）。 */
    progressIntervalMs: clampInt(raw.progressIntervalMs, 8000, 0, 60000),
    /** 访问日志：记 iPad 请求到 dataDir/access.log，排障用；空字符串表示关闭。 */
    accessLogPath: typeof raw.accessLogPath === 'string' ? raw.accessLogPath : '',
  }
}

function clampInt(value, fallback, min, max) {
  const n = Number(value)
  if (!Number.isFinite(n)) return fallback
  return Math.min(max, Math.max(min, Math.round(n)))
}

function clampNumber(value, fallback, min, max) {
  const n = Number(value)
  if (!Number.isFinite(n)) return fallback
  return Math.min(max, Math.max(min, n))
}

/**
 * 创建网关服务器（不自动 listen）。
 * @param {{adapter: BridgeAdapter, config: ReturnType<typeof normalizeBridgeConfig>, logger?: object}} options
 */
export function createBridgeServer({ adapter, config, logger }) {
  const log = logger ?? {}
  const accessLog = config.accessLogPath
    ? (line) => {
      const entry = `${new Date().toISOString()} ${line}\n`
      appendFile(config.accessLogPath, entry, { mode: 0o600 }).catch(() => {})
    }
    : () => {}
  const server = createServer(async (req, res) => {
    try {
      const url = new URL(req.url ?? '/', 'http://127.0.0.1')
      if (url.pathname === '/api/health') {
        const authOk = tokenEquals(bearerToken(req), config.token)
        accessLog(`health ${req.socket.remoteAddress} auth=${authOk ? 'ok' : 'fail'}`)
        if (req.method !== 'GET') {
          sendJson(res, 405, { ok: false, error: '只支持 GET' })
          return
        }
        if (!tokenEquals(bearerToken(req), config.token)) {
          sendJson(res, 401, { ok: false, error: '未授权' })
          return
        }
        let health = { ready: false, detail: 'unknown' }
        try {
          health = await adapter.health()
        } catch (error) {
          log.warn?.(`whalepet: health 检查失败: ${error?.message ?? error}`)
        }
        sendJson(res, 200, {
          ok: true,
          asr: Boolean(health.ready),
          model: health.detail ?? '',
          // 版本号：用来确认 iPad 连到的是哪一版插件（排障用）。
          version: PLUGIN_VERSION,
        })
        return
      }

      if (url.pathname === '/api/chat') {
        const authOk = tokenEquals(bearerToken(req), config.token)
        accessLog(`chat ${req.socket.remoteAddress} auth=${authOk ? 'ok' : 'fail'}`)
        if (req.method !== 'POST') {
          sendJson(res, 405, { ok: false, error: '只支持 POST' })
          return
        }
        if (!tokenEquals(bearerToken(req), config.token)) {
          sendJson(res, 401, { ok: false, error: '未授权' })
          return
        }
        let body
        try {
          body = JSON.parse((await readBody(req)).toString('utf8'))
        } catch {
          sendJson(res, 400, { ok: false, error: '请求体不是合法 JSON' })
          return
        }
        const sessionId = body?.session_id
        const text = typeof body?.text === 'string' ? body.text.trim() : ''
        if (!isValidSessionId(sessionId)) {
          sendJson(res, 400, { ok: false, error: 'session_id 不合法' })
          return
        }
        if (!text) {
          sendJson(res, 400, { ok: false, error: 'text 不能为空' })
          return
        }
        try {
          const reply = await adapter.ask(sessionId, text, {})
          sendJson(res, 200, { ok: true, reply: String(reply ?? '') })
        } catch (error) {
          sendJson(res, 502, { ok: false, error: `DSH 执行失败：${describeError(error)}` })
        }
        return
      }

      sendJson(res, 404, { ok: false, error: 'not found' })
    } catch (error) {
      if (!res.headersSent) sendJson(res, 500, { ok: false, error: describeError(error) })
      else res.end()
    }
  })

  // 服务端运行期错误（accept 失败、句柄耗尽等）只记录，不能让 'error' 事件冒泡成未捕获异常。
  server.on('error', (error) => {
    log.error?.(`whalepet: HTTP 服务出错: ${error?.message ?? error}`)
  })

  const pipelines = new Set()
  // 跨连接投递：断线期间完成的任务，等新连接 hello 后补发（宠物只会有一个活动会话）。
  const delivery = {
    subscriber: null,
    running: false,
    buffered: null,
    pendingApproval: null,
    sessionId: null,
  }

  attachWebSocketServer(server, {
    path: '/api/audio',
    maxMessageBytes: MAX_WS_MESSAGE,
    pingIntervalMs: 25000,
    authorize(req) {
      const authOk = tokenEquals(bearerToken(req), config.token)
      accessLog(`ws-upgrade ${req.socket.remoteAddress} auth=${authOk ? 'ok' : 'fail'}`)
      if (!authOk) {
        return { ok: false, status: 401, message: '未授权' }
      }
      return { ok: true }
    },
    onConnection(connection) {
      const pipeline = new VoicePipeline({ connection, adapter, config, logger: log, delivery })
      pipelines.add(pipeline)
      connection.on('close', () => pipelines.delete(pipeline))
      pipeline.start()
      log.info?.('whalepet: iPad 语音通道已连接')
    },
  })

  return {
    server,
    pipelines,
    /**
     * 把一条事件推给「当前连着的 iPad」（没有连接则丢弃）。
     * 供插件把其它 DSH 会话的任务进度转成宠物播报。
     */
    announce(payload) {
      const target = delivery.subscriber
      if (!target || target.closed) return false
      try {
        target.send(payload)
        return true
      } catch {
        return false
      }
    },
    /** @returns {Promise<string>} 实际监听地址 */
    listen() {
      return new Promise((resolve, reject) => {
        const onError = (error) => reject(error)
        server.once('error', onError)
        server.listen(config.port, config.host, () => {
          server.off('error', onError)
          const address = server.address()
          const actual = typeof address === 'object' && address ? `${address.address}:${address.port}` : `${config.host}:${config.port}`
          resolve(actual)
        })
      })
    },
    async close() {
      for (const pipeline of pipelines) {
        try {
          pipeline.dispose()
        } catch {
          // 忽略
        }
      }
      pipelines.clear()
      await new Promise((resolve) => {
        if (!server.listening) {
          resolve()
          return
        }
        server.close(() => resolve())
        // 主动断开 keep-alive 连接，避免 close 卡住。
        server.closeAllConnections?.()
      })
    },
  }
}