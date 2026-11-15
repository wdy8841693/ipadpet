/**
 * 新 Agent 文本协议（/api/agent）的常量与校验。
 *
 * 架构依据：docs/CROSS_PLATFORM.md §8
 *   - 字段统一 snake_case（与旧协议一致）。
 *   - 标识符限长、限字符集；命令文本限长；单条控制消息限长。
 *   - 设备 ID、DSH 会话 ID、请求 ID 三者**不能**混为一个 session_id。
 */

/** 协议版本。 */
export const AGENT_PROTOCOL_VERSION = 2

/** 标识符：字母数字、下划线、连字符，1~80 字符。 */
export const ID_PATTERN = /^[A-Za-z0-9_-]{1,80}$/

/** 命令文本最大长度（字符）。 */
export const MAX_COMMAND_CHARS = 16000

/** 单条 JSON 控制消息最大字节数。 */
export const MAX_CONTROL_MESSAGE_BYTES = 64 * 1024

/** 默认会话 id：所有设备共享同一个宠物长期会话。 */
export const DEFAULT_CONVERSATION_ID = 'whalepet-main'

/** 私有任务事件的状态集合。 */
export const TASK_STATES = Object.freeze([
  'queued',
  'started',
  'approval',
  'interrupted',
  'finished',
  'failed',
])

/** 客户端能力标识（目前只是声明，不做能力协商）。 */
export const CLIENT_CAPABILITIES = Object.freeze([
  'local-wake',
  'local-asr',
  'local-tts',
])

/** 校验标识符。 */
export function isValidId(value) {
  return typeof value === 'string' && ID_PATTERN.test(value)
}

/** 校验命令文本：去掉首尾空白后非空、且不超过长度上限。 */
export function normalizeCommandText(value) {
  if (typeof value !== 'string') return ''
  const text = value.trim()
  if (!text) return ''
  if (text.length > MAX_COMMAND_CHARS) return ''
  return text
}

/** 校验握手消息。 */
export function validateHello(message) {
  if (!message || typeof message !== 'object') return { ok: false, code: 'bad_request', message: 'hello 必须是对象' }
  const clientId = message.client_id
  if (!isValidId(clientId)) {
    return { ok: false, code: 'bad_client_id', message: 'client_id 不合法（只允许 A-Za-z0-9_-，1~80 字符）' }
  }
  const conversationId = typeof message.conversation_id === 'string' && message.conversation_id.trim()
    ? message.conversation_id.trim()
    : DEFAULT_CONVERSATION_ID
  if (!isValidId(conversationId)) {
    return { ok: false, code: 'bad_conversation_id', message: 'conversation_id 不合法' }
  }
  const protocol = Number.isInteger(message.protocol) ? message.protocol : AGENT_PROTOCOL_VERSION
  if (protocol > AGENT_PROTOCOL_VERSION) {
    return { ok: false, code: 'unsupported_protocol', message: `本服务端只支持 protocol <= ${AGENT_PROTOCOL_VERSION}` }
  }
  const subscriptions = {
    announcements: message.subscriptions?.announcements === true,
  }
  const capabilities = Array.isArray(message.capabilities)
    ? message.capabilities.filter((item) => typeof item === 'string').slice(0, 16)
    : []
  return {
    ok: true,
    value: {
      clientId,
      conversationId,
      deviceKind: typeof message.device_kind === 'string' ? message.device_kind.slice(0, 32) : '',
      capabilities,
      subscriptions,
      lastReceivedEventId: typeof message.last_received_event_id === 'string' ? message.last_received_event_id : null,
    },
  }
}

/** 校验命令消息。 */
export function validateCommand(message) {
  if (!message || typeof message !== 'object') return { ok: false, code: 'bad_request', message: 'command 必须是对象' }
  if (!isValidId(message.request_id)) {
    return { ok: false, code: 'bad_request_id', message: 'request_id 不合法（只允许 A-Za-z0-9_-，1~80 字符）' }
  }
  const text = normalizeCommandText(message.text)
  if (!text) {
    return { ok: false, code: 'empty_command', message: 'text 不能为空' }
  }
  const conversationId = typeof message.conversation_id === 'string' && message.conversation_id.trim()
    ? message.conversation_id.trim()
    : DEFAULT_CONVERSATION_ID
  if (!isValidId(conversationId)) {
    return { ok: false, code: 'bad_conversation_id', message: 'conversation_id 不合法' }
  }
  return {
    ok: true,
    value: {
      requestId: message.request_id,
      conversationId,
      text,
      source: typeof message.source === 'string' ? message.source.slice(0, 32) : 'voice',
      clientId: isValidId(message.client_id) ? message.client_id : '',
    },
  }
}

/** 校验取消消息。 */
export function validateCancel(message) {
  if (!message || typeof message !== 'object') return { ok: false, code: 'bad_request', message: 'cancel 必须是对象' }
  if (!isValidId(message.request_id)) {
    return { ok: false, code: 'bad_request_id', message: 'request_id 不合法' }
  }
  return {
    ok: true,
    value: {
      requestId: message.request_id,
      clientId: isValidId(message.client_id) ? message.client_id : '',
    },
  }
}
