/**
 * 鲸鱼娘 DSH 局域网网关（Host 插件入口）。
 *
 * 作用：把 iPad mini 4 上 WhalePet 的语音/文本请求接进**本机正在运行的 DSH**：
 *   音频(16k PCM) → ctx.speechToText（SenseVoice，本地 CPU）→ 唤醒词匹配
 *   → ctx.sessionController（官方会话：create / prompt / wait）→ 回复文本 → iPad 本地 TTS
 *
 * 宠物会话是**完整的 DSH Agent**（工具、检索、文件、多步执行都可用），
 * 插件在它自己的 scope 里追加一段语音人格提示，并把回复整理成适合 TTS 的口语文本。
 *
 * 网络协议与 Python 桥接完全一致（见 src/server.js 顶部注释），iPad 端不用改代码，
 * 只需把设置里的服务器地址指向运行 DSH 的这台机器（默认端口 8787）。
 */

import fsp from 'node:fs/promises'
import os from 'node:os'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { createBridgeServer, normalizeBridgeConfig, PLUGIN_VERSION } from './src/server.js'
import { createSettingsStore } from './src/settings.js'
import { registerSettingsApi } from './src/settings-api.js'

export const name = 'whalepet-bridge'

/** 依赖的 Host 服务：官方会话控制 + 语音识别 + Agent 注册表 + 审批策略。 */
export const inject = ['sessionController', 'speechToText', 'agents', 'approval']

const DEFAULT_DATA_DIR = path.join(os.homedir(), '.dsh', 'whalepet')

/**
 * 宠物会话的人格与播报风格：插在 Agent 自己的 scope 里，只影响宠物会话。
 * 目标：像 Super Agent 一样真的去查、去做，但**说**出来要短、能念。
 */
export const VOICE_PERSONA = [
  '你是「鲸鱼娘」，住在 iPad 全屏海底世界里，现在通过语音和主人聊天。',
  '你是一个能动手的助手：需要查资料、看文件、执行命令、读写代码时，直接用工具做完再回答，不要说"我做不到"或"我不能访问"。',
  '但回答是给 TTS 念出来的：用口语化中文，1~3 句话说清结论；不要 Markdown、不要链接、不要代码块、不要列表、不要表情符号。',
  '如果任务很长，先说一句你在做什么，做完再用一句话报结果；数字和关键结论要具体。',
].join('\n')

const DEFAULT_REQUEST_TIMEOUT_MS = 300000
const DEFAULT_MAX_WAIT_MS = 600000
const PROGRESS_INTERVAL_MS = 8000

/** 读 JSON（不存在/损坏都返回 fallback）。 */
async function readJson(file, fallback) {
  try {
    return JSON.parse(await fsp.readFile(file, 'utf8'))
  } catch {
    return fallback
  }
}

/** 原子写 JSON。 */
async function writeJson(file, value) {
  await fsp.mkdir(path.dirname(file), { recursive: true })
  const tmp = `${file}.${process.pid}.${Date.now()}.tmp`
  await fsp.writeFile(tmp, `${JSON.stringify(value, null, 2)}\n`, 'utf8')
  await fsp.rename(tmp, file)
}

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

/** 生成/读取 iPad 访问令牌（0600 文件，避免把密钥写进 profile 配置或 git）。 */
async function resolveToken(config, dataDir, logger) {
  if (typeof config.token === 'string' && config.token.trim()) return config.token.trim()
  const tokenFile = typeof config.tokenFile === 'string' && config.tokenFile.trim()
    ? config.tokenFile.trim()
    : path.join(dataDir, 'ipad-token')
  try {
    const existing = (await fsp.readFile(tokenFile, 'utf8')).trim()
    if (existing.length >= 16) return existing
  } catch {
    // 首次运行：下面生成
  }
  const token = randomUUID().replace(/-/g, '')
  await fsp.mkdir(path.dirname(tokenFile), { recursive: true })
  await fsp.writeFile(tokenFile, `${token}\n`, { mode: 0o600 })
  logger.info(`whalepet: 已生成 iPad 访问令牌，保存在 ${tokenFile}`)
  return token
}

/** 小延迟（等待用户授权时轮询用）。 */
function delay(ms) {
  return new Promise((resolve) => {
    const timer = setTimeout(resolve, ms)
    timer.unref?.()
  })
}

/** 判断错误是否为「会话不存在」（会话被 GUI 删掉后重建用）。 */
function isNotFound(error) {
  const code = error?.code ?? error?.details?.code ?? ''
  const message = String(error?.message ?? '')
  return String(code).includes('not-found') || /not[- ]?found|不存在/i.test(message)
}

export function apply(ctx, config = {}) {
  // 注意：cordis 的 logger 是「可调用服务代理」，info/warn/error 内部要靠
  // this 拿到当前 fiber 的 Logger（this() -> LoggerService[symbols.invoke]）。
  // 把方法摘下来直接调用会丢 this，报 "TypeError: this is not a function"，
  // 插件加载时抛错会直接把整个 dsh 进程带走（PM2 重启循环 → 3080 端口起不来）。
  // 所以必须以 ctx.logger 的方法形式调用，保留 this；并且再包一层 prevent 宿主崩溃。
  const logger = {
    info: (message) => safeLog(ctx, 'info', message),
    warn: (message) => safeLog(ctx, 'warn', message),
    error: (message) => safeLog(ctx, 'error', message),
  }

  const dataDir = typeof config.dataDir === 'string' && config.dataDir.trim()
    ? path.resolve(config.dataDir.trim())
    : DEFAULT_DATA_DIR
  const sessionDir = path.join(dataDir, 'workspace')
  const requestTimeoutMs = Math.max(10000, Number(config.requestTimeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS) || DEFAULT_REQUEST_TIMEOUT_MS)
  // 宠物只用一个长期会话：不需要用户管理、不按设备/每轮新建，像 Super Agent 一样一直在线。
  const mainSessionId = typeof config.mainSessionId === 'string' && config.mainSessionId.trim()
    ? config.mainSessionId.trim()
    : 'whalepet-session-main'
  const sessionTitle = typeof config.sessionTitle === 'string' && config.sessionTitle.trim()
    ? config.sessionTitle.trim()
    : '🐋 鲸鱼娘（自动维护，不用管）'
  // 自动换新会话：0 = 永远同一个；24 = 每 24 小时换一条（旧的归档）。
  const rotateAfterHours = Math.max(0, Number(config.rotateAfterHours ?? 24) || 0)
  const now = typeof config.now === 'function' ? config.now : Date.now
  // 空闲时把会话归档（列表里看不到），下一次说话前自动取消归档。
  const archiveWhenIdle = config.archiveWhenIdle !== false
  const metaFile = path.join(dataDir, 'session-meta.json')
  const maxWaitMs = Math.max(requestTimeoutMs, Number(config.maxWaitMs ?? DEFAULT_MAX_WAIT_MS) || DEFAULT_MAX_WAIT_MS)
  const approvalPolicy = config.approvalPolicy === 'ask' ? 'ask' : 'never'
  // 默认 workspace-write：宠物像 Super Agent 一样能读能写，但只限它自己的工作目录。
  // 显式传空字符串表示「不动权限预设，只钉审批策略」。
  const permissionPreset = Object.prototype.hasOwnProperty.call(config, 'permissionPreset')
    ? (typeof config.permissionPreset === 'string' ? config.permissionPreset.trim() : '')
    : 'workspace-write'
  const persona = typeof config.voicePersona === 'string' && config.voicePersona.trim()
    ? config.voicePersona.trim()
    : VOICE_PERSONA

  // 设置页可改的项：settings.json（用户改过的） > 这份 config 默认值。
  const settingsStore = createSettingsStore({
    dataDir,
    logger,
    defaults: {
      voicePersona: persona,
      wakePhrase: typeof config.wakePhrase === 'string' && config.wakePhrase.trim()
        ? config.wakePhrase.trim()
        : '小鲸小鲸',
      wakeAck: typeof config.wakeAck === 'string' ? config.wakeAck.trim() : '我在',
      announceOtherSessions: config.announceOtherSessions !== false,
      announceReplyChars: Number.isFinite(Number(config.announceReplyChars))
        ? Math.max(0, Math.trunc(Number(config.announceReplyChars)))
        : 80,
    },
  })

  const speechToText = ctx.speechToText
  const sessions = ctx.sessionController
  const permissionPresets = typeof ctx.get === 'function' ? ctx.get('permissionPresets') : undefined

  const askQueues = new Map()
  const prepared = new Set()
  let sessionReady = false
  /** 当前正在使用的宠物会话 id（rotateAfterHours > 0 时按时间桶滚动）。 */
  let currentSessionId = null

  /** 按时间桶算出该用哪个会话 id；rotateAfterHours = 0 时固定用 mainSessionId。 */
  const desiredSessionId = () => {
    if (rotateAfterHours === 0) return mainSessionId
    const periodMs = rotateAfterHours * 3600 * 1000
    const bucketStart = Math.floor(now() / periodMs) * periodMs
    const stamp = new Date(bucketStart).toISOString().slice(0, 13).replace(/[-:]/g, '')
    return `whalepet-session-${stamp}`
  }
  /** dshSessionId -> 该 Agent scope 内人格 section 的 disposer。 */
  const personaDisposers = new Map()

  // 设置页改了人设/唤醒词等：撤掉已注入的人格 section，下一次 ask 会重新注入。
  ctx.effect(() => settingsStore.onChange(() => {
    for (const dispose of personaDisposers.values()) {
      try {
        dispose()
      } catch {
        // 忽略
      }
    }
    personaDisposers.clear()
  }), 'whalepet.settings-persona-refresh')
  let bridge = null

  const getWorkspaceRegistry = () => (typeof ctx.get === 'function' ? ctx.get('workspaceRegistry') : undefined)

  // ---- 其它 DSH 会话的任务播报（宠物当“前台语音通知器”）--------------------
  // 除了宠物自己发起的任务，会话列表里任何会话开始/结束/需要授权时也播报一句。
  // 这里只负责把事件推给当前连着的 iPad；iPad 不在前台时自然丢弃。
  const sessionTitles = new Map()
  /** 会话的首条用户消息（标题还没生成时用它当名字）。 */
  const sessionPrompts = new Map()
  const sessionRegistry = typeof ctx.get === 'function' ? ctx.get('sessions') : undefined
  const sessionTitleService = typeof ctx.get === 'function' ? ctx.get('sessionTitle') : undefined
  const PET_SESSION_PREFIX = 'whalepet-session-'

  /** 是否是值得播报的「别的会话」。 */
  const shouldAnnounceSession = (sessionId) => {
    if (!settingsStore.current().announceOtherSessions || typeof sessionId !== 'string' || !sessionId) return false
    if (sessionId.startsWith(PET_SESSION_PREFIX)) return false
    try {
      const session = sessionRegistry?.get?.(sessionId)
      if (session?.header?.origin === 'subagent') return false
    } catch {
      // 拿不到会话元信息就照常播报
    }
    return true
  }

  /** 从会话标题服务读当前标题（对重启前就存在的会话也有效）。 */
  const titleFromService = (sessionId) => {
    if (!sessionTitleService) return ''
    try {
      const session = sessionRegistry?.get?.(sessionId)
      if (!session) return ''
      const snapshot = sessionTitleService.get(session)
      const title = typeof snapshot?.title === 'string' ? snapshot.title.trim() : ''
      if (title) sessionTitles.set(sessionId, title)
      return title
    } catch {
      return ''
    }
  }

  /** 把一段用户消息变成短名字（去掉注入的 XML 块/HTML 标签）。 */
  const promptLabel = (text) => {
    const cleaned = String(text ?? '')
      .replace(/<[^>]+>[\s\S]*?<\/[^>]+>/g, ' ')
      .replace(/<[^>]*>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim()
    if (!cleaned) return ''
    return cleaned.length > 20 ? `${cleaned.slice(0, 20)}…` : cleaned
  }

  /** 会话名字（太长截断）：优先标题，标题还没生成时用首条用户消息。 */
  const sessionLabel = (sessionId) => {
    const title = sessionTitles.get(sessionId) || titleFromService(sessionId) || ''
    const source = title || sessionPrompts.get(sessionId) || ''
    const trimmed = String(source).replace(/\s+/g, ' ').trim()
    if (!trimmed) return ''
    return trimmed.length > 24 ? `${trimmed.slice(0, 24)}…` : trimmed
  }

  const announceTask = (state, text) => {
    try {
      bridge?.announce?.({ type: 'task', state, text })
    } catch {
      // 播报失败不影响任务
    }
  }

  /**
   * 用 response 事件播报一句（App 所有版本收到 response 都会 TTS）。
   * 其它会话的「完成」用它，因为宠物自己的任务有真正的回复内容会播，
   * 而 task finished 在 App 端只上气泡不出声。
   */
  const announceSpeech = (text) => {
    try {
      bridge?.announce?.({ type: 'response', text })
    } catch {
      // 播报失败不影响任务
    }
  }

  /** 读某个会话最后一条 assistant 回复，整理成口语摘要（超长截断）。 */
  const readSessionReply = async (sessionId, maxChars = settingsStore.current().announceReplyChars) => {
    if (maxChars <= 0) return ''
    try {
      // timeoutMs 必须是正数（0 会被 gateway 以 bad-request 拒绝）。
      // 会话已经 idle，wait 会立刻返回并带上 newest-first 的 assistant 记录。
      const value = await sessions.wait(
        { sessionId, timeoutMs: 2000, afterSeq: 0 },
        new AbortController().signal,
      )
      const spoken = toSpeechText(lastAssistantText(value?.output?.records ?? []))
      const oneLine = spoken.replace(/\s+/g, ' ').trim()
      if (!oneLine) return ''
      return oneLine.length > maxChars ? `${oneLine.slice(0, maxChars)}…` : oneLine
    } catch (error) {
      safeLog(ctx, 'warn', `whalepet: 读取会话回复失败 session=${sessionId}: ${error?.message ?? error}`)
      return ''
    }
  }

  ctx.effect(() => {
    const offTitle = ctx.on('session/event', (session, event) => {
      try {
        if (event?.type === 'session/title' && typeof event.data?.title === 'string') {
          sessionTitles.set(session.id, event.data.title)
          return
        }
        if (event?.type === 'user/message' && event.data?.source?.kind === 'user') {
          if (sessionPrompts.has(session.id)) return
          const content = event.data.content
          const text = Array.isArray(content)
            ? content.filter((block) => block?.type === 'text').map((block) => block.text).join(' ')
            : ''
          const label = promptLabel(text)
          if (label) sessionPrompts.set(session.id, label)
        }
      } catch {
        // 忽略
      }
    })
    const offStatus = ctx.on('api-session/status', (sessionId, running) => {
      if (!shouldAnnounceSession(sessionId)) return
      const label = sessionLabel(sessionId)
      if (running) {
        announceTask('started', label ? `开始处理：${label}` : '有个任务开始处理了')
        return
      }
      // 完成：把最后一条回复的摘要也念出来（标题可能刚生成，重新取一次）。
      void (async () => {
        const reply = await readSessionReply(sessionId)
        const name = sessionLabel(sessionId) || label
        const head = name ? `做完了：${name}` : '有个任务做完了'
        announceSpeech(reply ? `${head}。${reply}` : head)
      })()
    })
    const offApproval = ctx.on('approval/request', (request, next) => {
      try {
        const sessionId = request?.agent?.session?.id
        if (shouldAnnounceSession(sessionId)) {
          const label = sessionLabel(sessionId)
          announceTask('approval', label ? `有任务需要你授权：${label}` : '有任务需要你授权')
        }
      } catch {
        // 忽略
      }
      return next()
    })
    const offQuestion = ctx.on('user-questions/request', (request, next) => {
      try {
        const sessionId = request?.agent?.session?.id
        if (shouldAnnounceSession(sessionId)) {
          const label = sessionLabel(sessionId)
          announceTask('approval', label ? `有任务需要你回答：${label}` : '有任务需要你回答')
        }
      } catch {
        // 忽略
      }
      return next()
    })
    const offRemoved = ctx.on('api-session/removed', (sessionId) => {
      sessionTitles.delete(sessionId)
    })
    return () => {
      offTitle?.()
      offStatus?.()
      offApproval?.()
      offQuestion?.()
      offRemoved?.()
    }
  }, 'whalepet.announce-other-sessions')

  const setArchived = async (dshSessionId, archived) => {
    const registry = getWorkspaceRegistry()
    if (!registry) return
    try {
      if (archived && typeof registry.archiveSession === 'function') {
        await registry.archiveSession(dshSessionId, { stopActivity: true })
      } else if (!archived && typeof registry.unarchiveSession === 'function') {
        await registry.unarchiveSession(dshSessionId)
      }
    } catch (error) {
      // 归档只是「列表干净」，失败不影响对话。
      logger.warn(`whalepet: ${archived ? '归档' : '取消归档'}宠物会话失败: ${error?.message ?? error}`)
    }
  }

  /** 一次性写宠物会话标题，之后不再改动（避免每轮追加 rename 事件）。 */
  const ensureSessionTitle = async (dshSessionId) => {
    try {
      const meta = await readJson(metaFile, {})
      // 标题按会话记录：24h 轮换后新会话也要重新命名。
      if (meta?.titleAppliedSessionId === dshSessionId) return
      await sessions.rename({ sessionId: dshSessionId, title: sessionTitle })
      await writeJson(metaFile, { ...meta, titleAppliedSessionId: dshSessionId })
    } catch (error) {
      logger.warn(`whalepet: 设置宠物会话标题失败: ${error?.message ?? error}`)
    }
  }

  /**
   * 一次性迁移：把早期随机 id 的宠物会话归档掉（只归档、不删除），
   * 让会话列表里只剩一个「鲸鱼娘」。
   */
  const archiveLegacySessions = async () => {
    try {
      if (typeof sessions.list !== 'function') return
      const registry = getWorkspaceRegistry()
      if (!registry || typeof registry.archiveSession !== 'function') return
      const keep = new Set([mainSessionId, desiredSessionId()])
      const listed = await sessions.list({}, new AbortController().signal)
      const legacy = (listed?.items ?? []).filter((row) => (
        typeof row?.sessionId === 'string'
        && row.sessionId.startsWith('whalepet-session-')
        && !keep.has(row.sessionId)
        && (row.cwd === undefined || row.cwd === sessionDir)
      ))
      for (const row of legacy) {
        try {
          await registry.archiveSession(row.sessionId, { stopActivity: true })
          logger.info(`whalepet: 已归档旧的宠物会话 ${row.sessionId}`)
        } catch {
          // 单个失败不影响其它
        }
      }
    } catch (error) {
      logger.warn(`whalepet: 归档旧宠物会话失败: ${error?.message ?? error}`)
    }
  }

  /**
   * 宠物只有一个长期会话：首次用 resolveAgent 探测，不存在才 create，
   * 之后永远复用同一个 id（插件重启、iPad 重装都一样）。
   */
  const ensureSession = async ({ rotate = true } = {}) => {
    const desired = desiredSessionId()
    if (desired !== currentSessionId) {
      // 握手阶段只做「准备」，不切会话：否则轮换边界上重连会把正在执行的任务归档/停掉。
      // 真正的轮换留到串行化的 ask() 里，保证没有任务在跑。
      if (!rotate && currentSessionId) return currentSessionId
      // 进入新的时间桶（或首次启动）：老会话归档，换新会话。
      const previous = currentSessionId
      if (previous) await setArchived(previous, true)
      currentSessionId = desired
      sessionReady = false
      try {
        const meta = await readJson(metaFile, {})
        await writeJson(metaFile, { ...meta, currentSessionId: desired })
      } catch {
        // 元数据只用于标题/轮换记录，写不了不影响对话
      }
    }
    if (sessionReady) return currentSessionId
    try {
      const resolved = await sessions.resolveAgent(currentSessionId)
      if (resolved?.agent) {
        sessionReady = true
        return currentSessionId
      }
    } catch (error) {
      if (!isNotFound(error)) throw error
    }
    await sessions.create({ sessionId: currentSessionId, cwd: sessionDir })
    await ensureSessionTitle(currentSessionId)
    sessionReady = true
    return currentSessionId
  }

  /**
   * 在宠物 Agent 自己的 scope 里注册语音人格提示；只注册一次。
   * ``agent.ctx.systemPrompt.section`` 按调用方 scope 生效，因此不会污染其它会话。
   */
  const ensurePersona = (agent, dshSessionId) => {
    if (!agent || personaDisposers.has(dshSessionId)) return
    try {
      const dispose = agent.ctx.systemPrompt.section({
        name: 'whalepet:voice-persona',
        order: 900,
        text: persona,
        interpolate: false,
      })
      if (typeof dispose === 'function') personaDisposers.set(dshSessionId, dispose)
    } catch (error) {
      logger.warn(`whalepet: 注册语音人格失败: ${error?.message ?? error}`)
    }
  }

  /** 新会话：权限预设 + 审批策略 + 语音人格。 */
  const applySessionSetup = async (dshSessionId) => {
    if (prepared.has(dshSessionId)) return
    let agent
    try {
      const resolved = await sessions.resolveAgent(dshSessionId)
      agent = resolved?.agent
    } catch (error) {
      logger.warn(`whalepet: 解析会话 Agent 失败: ${error?.message ?? error}`)
      return
    }
    if (!agent) return

    // 权限预设决定沙箱 + 审批的组合；配了就用预设（Super Agent 需要能写工作区），
    // 没配就只把审批策略钉死，避免语音场景挂在等待批准上。
    if (permissionPreset && permissionPresets && typeof permissionPresets.set === 'function') {
      try {
        permissionPresets.set(agent.session, permissionPreset)
      } catch (error) {
        logger.warn(`whalepet: 应用权限预设 ${permissionPreset} 失败: ${error?.message ?? error}`)
      }
    } else {
      try {
        ctx.approval.setPolicy(agent, approvalPolicy)
      } catch (error) {
        logger.warn(`whalepet: 设置审批策略失败: ${error?.message ?? error}`)
      }
    }
    ensurePersona(agent, dshSessionId)
    prepared.add(dshSessionId)
  }

  /**
   * 等宠物 Agent 这一轮结束：允许多次 wait，最长 maxWaitMs。
   * 超时但不是彻底失败时，把已经产生的回复带回（比空白强）。
   *
   * 期间通过 notify 给 iPad 发任务进度事件：
   *   started  —— 任务已提交、开始执行
   *   approval —— 需要用户在 DSH 里授权/回答；继续等，批准后自动接着跑
   */
  const waitForReply = async (dshSessionId, afterSeq, signal, notify) => {
    const startedAt = Date.now()
    let best = ''
    let confirmNotified = false
    for (;;) {
      const slice = Math.max(5000, Math.min(requestTimeoutMs, maxWaitMs - (Date.now() - startedAt)))
      const waited = await sessions.wait({
        sessionId: dshSessionId,
        afterSeq,
        timeoutMs: slice,
      }, signal)
      const text = toSpeechText(lastAssistantText(waited?.output?.records))
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
          const needsApproval = pending.includes('approval') || pending.length === 0
          notify?.({
            state: 'approval',
            text: needsApproval
              ? '有个操作需要你授权，去 DSH 里点一下同意，我再接着做'
              : '有个问题需要你回答，去 DSH 里回一下，我再接着做',
          })
        }
        if (Date.now() - startedAt >= maxWaitMs) {
          if (best) return best
          throw new Error('等你确认后我才能继续（去 DSH 会话列表里点一下）')
        }
        await delay(1500)
        signal?.throwIfAborted?.()
        continue
      }
      // timeout：还在跑就继续等，直到 maxWaitMs。
      if (Date.now() - startedAt >= maxWaitMs) {
        if (best) return best
        throw new Error('DSH 响应超时')
      }
      signal?.throwIfAborted?.()
    }
  }

  const adapter = {
    async health() {
      try {
        const snapshot = speechToText.snapshot()
        const selected = snapshot.selection?.providerId
        const provider = snapshot.providers?.find((entry) => entry.id === selected)
        const phase = provider?.preparation?.phase ?? 'unprepared'
        if (provider && (phase === 'unprepared' || phase === 'standby')) {
          // 首次使用时触发模型加载/下载准备；不阻塞 health 响应。
          try {
            speechToText.prepare(selected)
          } catch {
            // 准备失败会在 transcribe 时给出明确错误
          }
        }
        return {
          ready: phase === 'ready' || phase === 'waking' || phase === 'loading',
          detail: `${selected ?? 'unknown'}/${phase}`,
        }
      } catch (error) {
        return { ready: false, detail: `speechToText 不可用: ${error?.message ?? error}` }
      }
    },

    async transcribe(wav, { signal } = {}) {
      const spec = speechToText.resolve({
        audio: new Uint8Array(wav),
        language: config.language ?? 'zh',
      })
      const transcript = await speechToText.transcribe(spec, signal ?? new AbortController().signal)
      return transcript?.text ?? ''
    },

    async prepareSession() {
      // 握手/重连只做准备：建会话、权限、人格、预热 ASR。
      // 不归档、不轮换——避免把其它客户端正在执行的任务 stopActivity 掉。
      const dshSessionId = await ensureSession({ rotate: false })
      if (!dshSessionId) return
      await applySessionSetup(dshSessionId)
      // 顺手把识别模型预热起来，第一次唤醒能快一点。
      try {
        const { selection } = speechToText.snapshot()
        speechToText.prepare(selection.providerId)
      } catch {
        // 忽略
      }
    },

    ask(petSessionId, text, { signal, notify } = {}) {
      const abortSignal = signal ?? new AbortController().signal

      const askOnce = async (dshSessionId) => {
        await applySessionSetup(dshSessionId)
        let cursor = 0
        try {
          cursor = (await sessions.state({ sessionId: dshSessionId }, abortSignal))?.cursor ?? 0
        } catch {
          // 冷会话读不到被动状态时按 0 处理：wait 会返回当前可见的 assistant 记录。
          cursor = 0
        }
        await sessions.prompt({
          requestId: `whalepet-${randomUUID()}`,
          sessionId: dshSessionId,
          mode: 'queue',
          content: [{ type: 'text', text }],
          clientTimeZone: 'Asia/Shanghai',
        }, abortSignal)
        notify?.({ state: 'started', text: '开始执行，我这就去办' })
        return waitForReply(dshSessionId, cursor, abortSignal, notify)
      }

      const run = async () => {
        let dshSessionId = await ensureSession()
        await setArchived(dshSessionId, false)
        try {
          return await askOnce(dshSessionId)
        } catch (error) {
          if (!isNotFound(error)) throw error
          // 会话在 GUI 里被删了：重建同一个 id，并重试一次。
          logger.warn(`whalepet: 宠物会话 ${dshSessionId} 已不存在，重新创建`)
          sessionReady = false
          prepared.delete(dshSessionId)
          const dispose = personaDisposers.get(dshSessionId)
          personaDisposers.delete(dshSessionId)
          try {
            dispose?.()
          } catch {
            // 忽略
          }
          dshSessionId = await ensureSession()
          await setArchived(dshSessionId, false)
          return askOnce(dshSessionId)
        } finally {
          if (archiveWhenIdle) await setArchived(dshSessionId, true)
        }
      }

      // 宠物只有一个会话，所有客户端/请求都串行，避免把两条 prompt 塞进同一 turn。
      const previous = askQueues.get('main') ?? Promise.resolve()
      const current = previous.then(run, run)
      askQueues.set('main', current.catch(() => {}))
      return current
    },

    async close() {
      // 服务器关闭由 ctx.effect 的 disposer 负责
    },
  }

  // 启动网关（异步初始化；失败只记录日志，不拖垮宿主进程）。
  let settingsApiDisposer = null
  ctx.effect(() => {
    const start = async () => {
      await fsp.mkdir(sessionDir, { recursive: true })
      await settingsStore.load()
      try {
        const meta = await readJson(metaFile, {})
        if (typeof meta?.currentSessionId === 'string' && meta.currentSessionId.startsWith('whalepet-session-')) {
          currentSessionId = rotateAfterHours === 0 ? mainSessionId : meta.currentSessionId
        }
      } catch {
        // 忽略
      }
      if (currentSessionId === null) currentSessionId = desiredSessionId()
      const token = await resolveToken(config, dataDir, logger)
      const bridgeConfig = normalizeBridgeConfig({
        ...config,
        token,
        language: config.language ?? 'zh',
        // 排障用访问日志（iPad 每次 health / chat / WS 升级都会记一行）。
        accessLogPath: config.accessLog === false ? '' : path.join(dataDir, 'access.log'),
      })
      bridge = createBridgeServer({
        adapter,
        config: bridgeConfig,
        logger,
        getSettings: () => settingsStore.current(),
      })
      const address = await bridge.listen()
      const rotation = rotateAfterHours > 0 ? `每 ${rotateAfterHours}h 自动换新会话` : '固定单会话'
      logger.info(`whalepet: iPad 网关已监听 http://${address} （宠物会话 ${currentSessionId}，${rotation}，工作目录 ${sessionDir}）`)
      // 设置页（DSH 设置里新增「鲸鱼娘」）：读写 ~/.dsh/whalepet/settings.json。
      settingsApiDisposer = registerSettingsApi({
        ctx,
        store: settingsStore,
        config: bridgeConfig,
        dataDir,
        version: PLUGIN_VERSION,
        logger,
      })
      void archiveLegacySessions()
    }
    start().catch((error) => {
      logger.error(`whalepet: 网关启动失败: ${error?.stack ?? error}`)
    })
    return async () => {
      if (settingsApiDisposer) {
        try {
          settingsApiDisposer()
        } catch {
          // 忽略
        }
        settingsApiDisposer = null
      }
      const current = bridge
      bridge = null
      if (current) {
        await current.close().catch((error) => logger.warn(`whalepet: 关闭网关出错: ${error?.message ?? error}`))
        logger.info('whalepet: iPad 网关已停止')
      }
      for (const dispose of personaDisposers.values()) {
        try {
          dispose()
        } catch {
          // 忽略
        }
      }
      personaDisposers.clear()
      prepared.clear()
    }
  }, 'whalepet.bridge')
}

/** 调 logger 时绝不抛错：日志失败不能变成宿主进程的致命错误。 */
function safeLog(ctx, level, message) {
  try {
    const target = ctx.logger
    if (target && typeof target[level] === 'function') {
      target[level](message)
      return
    }
  } catch {
    // 落到 console
  }
  const fallback = level === 'error' ? console.error : level === 'warn' ? console.warn : console.info
  try {
    fallback(message)
  } catch {
    // 彻底静默
  }
}

/** 给传输层用：告知「这轮大概要多久/进度」的节奏（每 8s 一次 thinking 心跳）。 */
export const progressIntervalMs = PROGRESS_INTERVAL_MS