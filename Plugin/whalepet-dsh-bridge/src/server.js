/**
 * WhalePet 局域网网关：HTTP + WebSocket 协议实现（传输层）。
 *
 * 协议与 Server/whalepet_bridge/server.py 完全兼容，iPad App 端不需要改代码，
 * 只要把「服务器地址」指向运行 DSH 的这台机器 + 端口（默认 8787）。
 *
 *   GET  /api/health  -> {"ok":true,"asr":bool,"model":"...","agent":{"ready":true},...}
 *   POST /api/chat    -> {"session_id","text"} -> {"ok":true,"reply":"..."}
 *   WS   /api/audio   -> hello / manual_start / cancel / playback_start /
 *                        playback_end（文本），二进制 = 16k mono PCM16
 *                        服务端事件：ready / state / wake / transcript / thinking /
 *                                  response / error
 *   WS   /api/agent   -> hello / command / cancel（纯 JSON），服务端事件：
 *                        ready / voice_config / task / response / announcement / error
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
import { DEFAULT_WAKE_ALIASES, isValidSessionId } from './textnorm.js'
import { voiceConfig } from './session.js'
import { attachWebSocketServer } from './ws.js'
import { VoicePipeline, describeError } from './legacy-audio.js'
import { AgentChannel } from './agent-channel.js'
import { AGENT_PROTOCOL_VERSION } from './agent-protocol.js'

// 兼容旧引用：VoicePipeline 以前定义在 server.js 里，现在搬到 legacy-audio.js。
export { VoicePipeline }

export const PLUGIN_VERSION = '0.5.0'
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
    /** 只唤醒不说指令时宠物回的一句（空字符串 = 不启用）。 */
    wakeAck: typeof raw.wakeAck === 'string' ? raw.wakeAck.trim() : '我在',
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

/** 稳定的短哈希：用来给语音配置算 revision（内容不变则 revision 不变）。 */
function hashString(text) {
  let hash = 5381
  for (let i = 0; i < text.length; i += 1) {
    hash = ((hash << 5) + hash) ^ text.charCodeAt(i)
  }
  return (hash >>> 0) % 100000
}

/**
 * 创建网关服务器（不自动 listen）。
 * @param {object} options
 * @param {BridgeAdapter} options.adapter 旧音频通道用的适配器
 * @param {ReturnType<typeof normalizeBridgeConfig>} options.config
 * @param {{info?: Function, warn?: Function, error?: Function}} [options.logger]
 * @param {() => object} [options.getSettings] 运行时设置（设置页可改）
 * @param {{service?: object, hub?: object}} [options.agent] 新文本通道的 Agent 服务与客户端中心
 */
export function createBridgeServer({ adapter, config, logger, getSettings, agent }) {
  const log = logger ?? {}
  const accessLog = config.accessLogPath
    ? (line) => {
      const entry = `${new Date().toISOString()} ${line}\n`
      appendFile(config.accessLogPath, entry, { mode: 0o600 }).catch(() => {})
    }
    : () => {}

  /** 下发给新客户端的语音配置（唤醒词等随设置页变化）。 */
  const getVoiceConfig = () => {
    const settings = getSettings?.() ?? {}
    const wakePhrase = typeof settings.wakePhrase === 'string' && settings.wakePhrase.trim()
      ? settings.wakePhrase.trim()
      : config.wakePhrase
    const wakeAck = typeof settings.wakeAck === 'string' ? settings.wakeAck.trim() : config.wakeAck
    const payload = {
      wake_phrase: wakePhrase,
      wake_aliases: config.wakeAliases,
      wake_ack: wakeAck,
      listen_timeout_ms: Math.round(config.voice.listenTimeoutS * 1000),
    }
    // revision 变了客户端才需要重建本地 KWS（§11.3）。
    const revision = hashString(JSON.stringify(payload))
    return { revision, ...payload }
  }
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
          // 旧字段保持不变：iPad 端只看 asr / model。
          asr: Boolean(health.ready),
          model: health.detail ?? '',
          // 版本号：用来确认 iPad 连到的是哪一版插件（排障用）。
          version: PLUGIN_VERSION,
          // 新字段：新客户端只看 agent.ready，不依赖服务端 ASR。
          agent: { ready: true },
          protocols: ['audio-v1', `agent-v${AGENT_PROTOCOL_VERSION}`],
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
  const agentChannels = new Set()
  // 跨连接投递：断线期间完成的任务，等新连接 hello 后补发（宠物只会有一个活动会话）。
  const delivery = {
    subscriber: null,
    running: false,
    buffered: null,
    pendingApproval: null,
    sessionId: null,
  }

  attachWebSocketServer(server, {
    paths: ['/api/audio', '/api/agent'],
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
    onConnection(connection, _req, path) {
      if (path === '/api/agent') {
        if (!agent?.service || !agent?.hub) {
          log.warn?.('whalepet: /api/agent 未装配 Agent 服务，拒绝连接')
          connection.close(1011, 'agent unavailable')
          return
        }
        const channel = new AgentChannel({
          connection,
          service: agent.service,
          hub: agent.hub,
          logger: log,
          getVoiceConfig,
        })
        agentChannels.add(channel)
        connection.on('close', () => agentChannels.delete(channel))
        channel.start()
        log.info?.('whalepet: Agent 文本通道已连接')
        return
      }
      const pipeline = new VoicePipeline({ connection, adapter, config, logger: log, delivery, getSettings })
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
      for (const channel of agentChannels) {
        try {
          channel.dispose()
        } catch {
          // 忽略
        }
      }
      agentChannels.clear()
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