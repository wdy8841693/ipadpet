/**
 * ClientHub：多客户端注册表 + 投递路由 + 断线缓存。
 *
 * 架构依据：docs/CROSS_PLATFORM.md §9.2 / §8.5 / §8.7 / §8.9
 *   - clients:      Map<clientId, ClientRecord>   每个安装实例一个 client_id
 *   - requests:     Map<requestId, RequestRecord>  命令幂等记录
 *   - conversations Map<conversationId, ...>       （第一版只有一个宠物会话，先不建表）
 *
 * 关键规则：
 *   - 同一个 client_id 重连时，旧连接必须失效（新连接顶掉旧连接）。
 *   - 私有回答按 requestId → originClientId 单播，绝不广播。
 *   - 全局通知只发给握手里订阅了 announcements 的客户端，且**默认不缓存**。
 *   - 断线只移除在线连接，不删除请求执行状态；可靠事件按客户端隔离缓存，
 *     重连时按 last_received_event_id 补发。
 */

/** 可靠事件缓存条数上限（每客户端）。 */
const DEFAULT_MAX_RELIABLE_EVENTS = 100
/** 可靠事件缓存 TTL（24 小时）。 */
const DEFAULT_RELIABLE_TTL_MS = 24 * 3600 * 1000
/** 幂等记录 TTL（24 小时）。 */
const DEFAULT_REQUEST_TTL_MS = 24 * 3600 * 1000

/** 从 evt-000123 里取出序号（用于比较新旧）。 */
export function parseEventSeq(eventId) {
  const matched = /(\d+)\s*$/.exec(String(eventId ?? ''))
  return matched ? Number(matched[1]) : 0
}

export class ClientHub {
  /**
   * @param {object} [options]
   * @param {() => number} [options.now]
   * @param {number} [options.maxReliableEvents]
   * @param {number} [options.reliableTtlMs]
   * @param {number} [options.requestTtlMs]
   */
  constructor({
    now = Date.now,
    maxReliableEvents = DEFAULT_MAX_RELIABLE_EVENTS,
    reliableTtlMs = DEFAULT_RELIABLE_TTL_MS,
    requestTtlMs = DEFAULT_REQUEST_TTL_MS,
  } = {}) {
    this.now = now
    this.maxReliableEvents = Math.max(1, Number(maxReliableEvents) || DEFAULT_MAX_RELIABLE_EVENTS)
    this.reliableTtlMs = Number(reliableTtlMs) || DEFAULT_RELIABLE_TTL_MS
    this.requestTtlMs = Number(requestTtlMs) || DEFAULT_REQUEST_TTL_MS
    /** @type {Map<string, object>} clientId -> 客户端记录 */
    this.clients = new Map()
    /** @type {Map<object, string>} 连接对象 -> clientId */
    this.connections = new Map()
    /** @type {Map<string, Array<object>>} clientId -> 可靠事件缓存 */
    this.reliable = new Map()
    /** @type {Map<string, object>} requestId -> 幂等记录 */
    this.requests = new Map()
    this.counter = 0
  }

  /** 递增的事件 id（全局唯一、单调递增，便于按序号补发）。 */
  nextEventId(prefix = 'evt') {
    this.counter += 1
    return `${prefix}-${String(this.counter).padStart(6, '0')}`
  }

  /**
   * 注册/重连一个客户端。
   * 同一个 client_id 的旧连接会被顶掉（关闭并从索引里摘掉）。
   *
   * @param {string} clientId
   * @param {{send: Function, close?: Function, closed?: boolean}} connection
   * @param {object} [meta] conversationId / deviceKind / capabilities / subscriptions
   */
  register(clientId, connection, meta = {}) {
    const previous = this.clients.get(clientId)
    if (previous && previous.connection !== connection) {
      // 旧连接失效：先摘掉索引再关闭，避免 close 回调把新连接误删。
      this.connections.delete(previous.connection)
      this.clients.delete(clientId)
      try {
        previous.connection?.close?.(1000, 'replaced by new connection')
      } catch {
        // 忽略
      }
    }
    const record = {
      clientId,
      connection,
      conversationId: typeof meta.conversationId === 'string' ? meta.conversationId : '',
      deviceKind: typeof meta.deviceKind === 'string' ? meta.deviceKind : '',
      capabilities: Array.isArray(meta.capabilities) ? meta.capabilities.map(String) : [],
      subscriptions: {
        announcements: meta.subscriptions?.announcements === true,
      },
      connectedAt: this.now(),
      lastEventSeq: 0,
    }
    this.clients.set(clientId, record)
    this.connections.set(connection, clientId)
    this.#pruneReliable(clientId)
    return record
  }

  /** 连接断开：只移除在线连接，不动请求执行状态。 */
  unregister(connection) {
    const clientId = this.connections.get(connection)
    if (!clientId) return null
    this.connections.delete(connection)
    const record = this.clients.get(clientId)
    if (record && record.connection === connection) {
      this.clients.delete(clientId)
      return record
    }
    return null
  }

  get(clientId) {
    return this.clients.get(clientId) ?? null
  }

  isOnline(clientId) {
    const record = this.clients.get(clientId)
    return Boolean(record && record.connection && !record.connection.closed)
  }

  /** 订阅了全局通知的客户端记录。 */
  subscribers() {
    return [...this.clients.values()].filter((record) => record.subscriptions.announcements === true)
  }

  /**
   * 单播：把事件投给指定客户端。
   * @param {string} clientId
   * @param {object} payload
   * @param {{reliable?: boolean}} [options] reliable=true 时进断线补发缓存
   */
  deliverTo(clientId, payload, { reliable = false } = {}) {
    const record = this.clients.get(clientId)
    const event = { ...payload }
    if (!event.event_id) event.event_id = this.nextEventId()
    if (!event.origin_client_id && record) event.origin_client_id = record.clientId
    if (reliable) {
      this.#cacheReliable(clientId, event)
    }
    if (!record || !record.connection || record.connection.closed) return false
    try {
      // 真连接用 sendJSON（WebSocketConnection），测试替身用 send。
      if (typeof record.connection.sendJSON === 'function') record.connection.sendJSON(event)
      else if (typeof record.connection.send === 'function') record.connection.send(event)
      else return false
      return true
    } catch {
      return false
    }
  }

  /**
   * 广播：只投递给握手里声明订阅的客户端（默认）。
   * @param {object} payload
   * @param {{onlySubscribers?: boolean, reliable?: boolean}} [options]
   */
  broadcast(payload, { onlySubscribers = true, reliable = false } = {}) {
    const targets = onlySubscribers ? this.subscribers() : [...this.clients.values()]
    let delivered = 0
    for (const record of targets) {
      if (this.deliverTo(record.clientId, payload, { reliable })) delivered += 1
    }
    return delivered
  }

  /**
   * 断线补发：返回该客户端还没收到的可靠事件（按 event_id 序号比较）。
   * @param {string} clientId
   * @param {string|null} lastReceivedEventId
   */
  replay(clientId, lastReceivedEventId) {
    const cached = this.reliable.get(clientId)
    if (!cached || cached.length === 0) return []
    const since = parseEventSeq(lastReceivedEventId)
    const now = this.now()
    return cached
      .filter((entry) => entry.seq > since && now - entry.at <= this.reliableTtlMs)
      .map((entry) => entry.payload)
  }

  // -- 命令幂等 -----------------------------------------------------------

  /**
   * 登记一条命令（幂等键 = request_id）。
   * @returns {{state: string, result?: object}} 已存在时返回旧记录
   */
  beginRequest({ requestId, originClientId, conversationId, text } = {}) {
    const existing = this.requests.get(requestId)
    if (existing) {
      // 命中幂等：只更新「最近一次」的时间，状态保持不变。
      existing.at = this.now()
      return existing
    }
    const record = {
      requestId,
      originClientId: originClientId ?? '',
      conversationId: conversationId ?? '',
      text: text ?? '',
      state: 'running',
      result: null,
      at: this.now(),
    }
    this.requests.set(requestId, record)
    this.#pruneRequests()
    return record
  }

  getRequest(requestId) {
    return this.requests.get(requestId) ?? null
  }

  /** 标记请求完成并记住结果（重连后可以原样补发）。 */
  completeRequest(requestId, result) {
    const record = this.requests.get(requestId)
    if (!record) return null
    record.state = 'done'
    record.result = result ?? null
    record.at = this.now()
    return record
  }

  /** 标记请求失败。 */
  failRequest(requestId, error) {
    const record = this.requests.get(requestId)
    if (!record) return null
    record.state = 'failed'
    record.result = { error: String(error?.message ?? error ?? '') }
    record.at = this.now()
    return record
  }

  /** 标记请求已被客户端取消（远程任务可能仍在后台跑）。 */
  cancelRequest(requestId) {
    const record = this.requests.get(requestId)
    if (!record) return null
    record.state = 'cancelled'
    record.at = this.now()
    return record
  }

  /** 某个客户端仍在跑的命令（重连补发「任务还在后台继续」用）。 */
  runningRequests(clientId) {
    return [...this.requests.values()].filter((record) => (
      record.originClientId === clientId && record.state === 'running'
    ))
  }

  // -- 内部 ---------------------------------------------------------------

  #cacheReliable(clientId, event) {
    const list = this.reliable.get(clientId) ?? []
    list.push({ seq: parseEventSeq(event.event_id), event_id: event.event_id, payload: event, at: this.now() })
    // 超上限丢最旧的；过期条目顺手清掉。
    this.reliable.set(clientId, list)
    this.#pruneReliable(clientId)
  }

  #pruneReliable(clientId) {
    const list = this.reliable.get(clientId)
    if (!list) return
    const now = this.now()
    const alive = list.filter((entry) => now - entry.at <= this.reliableTtlMs)
    const trimmed = alive.length > this.maxReliableEvents
      ? alive.slice(alive.length - this.maxReliableEvents)
      : alive
    if (trimmed.length === 0) this.reliable.delete(clientId)
    else this.reliable.set(clientId, trimmed)
  }

  #pruneRequests() {
    const now = this.now()
    for (const [requestId, record] of this.requests) {
      if (now - record.at > this.requestTtlMs) this.requests.delete(requestId)
    }
  }
}
