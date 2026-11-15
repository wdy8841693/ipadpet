/**
 * 极简 WebSocket 服务端（RFC 6455 子集，无第三方依赖）。
 *
 * 只实现本插件需要的部分：
 *  - HTTP Upgrade 握手（校验 Sec-WebSocket-Key）
 *  - 文本/二进制帧、分片重组、close/ping/pong 控制帧
 *  - 单条消息大小上限、断线清理
 *
 * 之所以不引 `ws` 包：插件被安装到 `~/.dsh/profiles/<name>` 后从工作区
 * 真实路径解析依赖，第三方包不一定能在同一 node_modules 里解析到；
 * 手写协议层没有依赖问题，且这一子集足够小、可被单测覆盖。
 *
 * 单测：test/ws.test.js（用 node:net + 手工握手做端到端）
 */

import { createHash } from 'node:crypto'
import { EventEmitter } from 'node:events'

const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'
const OPCODE = Object.freeze({
  CONTINUATION: 0x0,
  TEXT: 0x1,
  BINARY: 0x2,
  CLOSE: 0x8,
  PING: 0x9,
  PONG: 0xa,
})

/** 计算握手应答值。 */
export function acceptKey(secWebSocketKey) {
  return createHash('sha1').update(`${secWebSocketKey}${WS_GUID}`).digest('base64')
}

/** 编码一帧（服务端 -> 客户端，不掩码）。 */
export function encodeFrame(opcode, payload) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(payload ?? '')
  const length = data.length
  let header
  if (length < 126) {
    header = Buffer.alloc(2)
    header[1] = length
  } else if (length < 65536) {
    header = Buffer.alloc(4)
    header[1] = 126
    header.writeUInt16BE(length, 2)
  } else {
    header = Buffer.alloc(10)
    header[1] = 127
    header.writeBigUInt64BE(BigInt(length), 2)
  }
  header[0] = 0x80 | opcode
  return Buffer.concat([header, data])
}

/**
 * 一个已握手的连接。
 * 事件：message(data: Buffer, isBinary: boolean)、close()、error(err)
 */
export class WebSocketConnection extends EventEmitter {
  /**
   * @param {import('node:net').Socket} socket
   * @param {object} options
   * @param {number} [options.maxMessageBytes]
   * @param {number} [options.pingIntervalMs]
   */
  constructor(socket, options = {}) {
    super()
    this.socket = socket
    this.maxMessageBytes = options.maxMessageBytes ?? 512 * 1024
    this.closed = false
    this.closeSent = false
    this.buffer = Buffer.alloc(0)
    this.fragmentOpcode = null
    this.fragmentParts = []
    this.fragmentBytes = 0
    this.lastPongAt = Date.now()
    this.pingTimer = null

    socket.setNoDelay(true)
    socket.on('data', (chunk) => this.#onData(chunk))
    socket.on('error', (error) => this.#emitError(error))
    socket.on('close', () => this.#onSocketClose())
    socket.on('end', () => this.#startClose())

    const interval = options.pingIntervalMs ?? 30000
    if (interval > 0) {
      this.pingTimer = setInterval(() => {
        if (this.closed) return
        // 30s 内没有任何 pong 且对端不响应 -> 认为死链。
        if (Date.now() - this.lastPongAt > interval * 2.5) {
          this.#startClose(1001, 'ping timeout')
          return
        }
        this.#writeFrame(OPCODE.PING, Buffer.alloc(0))
      }, interval)
      this.pingTimer.unref?.()
    }
  }

  /** 发送文本 JSON。 */
  sendText(text) {
    if (!this.closed) this.#writeFrame(OPCODE.TEXT, Buffer.from(String(text), 'utf8'))
  }

  /** 发送 JSON 对象。 */
  sendJSON(object) {
    this.sendText(JSON.stringify(object))
  }

  /** 发送二进制。 */
  sendBinary(data) {
    if (!this.closed) this.#writeFrame(OPCODE.BINARY, Buffer.isBuffer(data) ? data : Buffer.from(data))
  }

  ping() {
    if (!this.closed) this.#writeFrame(OPCODE.PING, Buffer.alloc(0))
  }

  /** 主动关闭。 */
  close(code = 1000, reason = '') {
    this.#startClose(code, reason)
  }

  // -- 内部 ---------------------------------------------------------------

  #writeFrame(opcode, payload) {
    if (this.socket.destroyed || this.socket.writableEnded) return
    try {
      this.socket.write(encodeFrame(opcode, payload))
    } catch (error) {
      this.#emitError(error)
    }
  }

  #emitError(error) {
    // EventEmitter 没有 error 监听时会抛，避免拖垮宿主进程。
    if (this.listenerCount('error') > 0) this.emit('error', error)
  }

  #onData(chunk) {
    if (this.closed) return
    this.buffer = this.buffer.length === 0 ? chunk : Buffer.concat([this.buffer, chunk])
    while (this.#parseOneFrame()) {
      // 继续解析剩余帧
    }
  }

  /** 解析一帧；返回是否消费了数据。 */
  #parseOneFrame() {
    const buf = this.buffer
    if (buf.length < 2) return false
    const fin = (buf[0] & 0x80) !== 0
    const rsv = buf[0] & 0x70
    const opcode = buf[0] & 0x0f
    if (rsv !== 0) {
      this.#startClose(1002, 'RSV must be zero')
      return false
    }
    const masked = (buf[1] & 0x80) !== 0
    let length = buf[1] & 0x7f
    let offset = 2
    if (length === 126) {
      if (buf.length < 4) return false
      length = buf.readUInt16BE(2)
      offset = 4
    } else if (length === 127) {
      if (buf.length < 10) return false
      const big = buf.readBigUInt64BE(2)
      if (big > BigInt(this.maxMessageBytes * 4)) {
        this.#startClose(1009, 'frame too large')
        return false
      }
      length = Number(big)
      offset = 10
    }
    if (length > this.maxMessageBytes * 4) {
      this.#startClose(1009, 'frame too large')
      return false
    }
    const maskOffset = offset
    if (masked) offset += 4
    if (buf.length < offset + length) return false

    let payload
    if (masked) {
      const mask = buf.subarray(maskOffset, maskOffset + 4)
      payload = Buffer.allocUnsafe(length)
      for (let i = 0; i < length; i += 1) payload[i] = buf[offset + i] ^ mask[i % 4]
    } else {
      payload = buf.subarray(offset, offset + length)
    }
    this.buffer = buf.subarray(offset + length)

    const isControl = opcode >= 0x8
    if (isControl) {
      if (!fin || length > 125) {
        this.#startClose(1002, 'bad control frame')
        return false
      }
      this.#handleControl(opcode, payload)
      return true
    }

    if (opcode === OPCODE.CONTINUATION) {
      if (this.fragmentOpcode === null) {
        this.#startClose(1002, 'unexpected continuation')
        return false
      }
      this.fragmentParts.push(payload)
      this.fragmentBytes += payload.length
    } else if (opcode === OPCODE.TEXT || opcode === OPCODE.BINARY) {
      if (this.fragmentOpcode !== null) {
        this.#startClose(1002, 'interleaved data frames')
        return false
      }
      this.fragmentOpcode = opcode
      this.fragmentParts = [payload]
      this.fragmentBytes = payload.length
    } else {
      this.#startClose(1002, `unknown opcode ${opcode}`)
      return false
    }

    if (this.fragmentBytes > this.maxMessageBytes) {
      this.#startClose(1009, 'message too large')
      return false
    }

    if (fin) {
      const message = this.fragmentParts.length === 1
        ? this.fragmentParts[0]
        : Buffer.concat(this.fragmentParts, this.fragmentBytes)
      const op = this.fragmentOpcode
      this.fragmentOpcode = null
      this.fragmentParts = []
      this.fragmentBytes = 0
      this.emit('message', message, op === OPCODE.BINARY)
    }
    return true
  }

  #handleControl(opcode, payload) {
    switch (opcode) {
      case OPCODE.PING:
        this.#writeFrame(OPCODE.PONG, payload)
        break
      case OPCODE.PONG:
        this.lastPongAt = Date.now()
        break
      case OPCODE.CLOSE: {
        let code = 1000
        let reason = ''
        if (payload.length >= 2) {
          code = payload.readUInt16BE(0)
          reason = payload.subarray(2).toString('utf8')
        }
        this.#respondClose(code, reason)
        break
      }
      default:
        this.#startClose(1002, 'unknown control opcode')
    }
  }

  #respondClose(code, reason) {
    if (!this.closeSent) {
      const payload = Buffer.alloc(2 + Buffer.byteLength(reason ?? ''))
      payload.writeUInt16BE(Number.isInteger(code) ? code : 1000, 0)
      payload.write(reason ?? '', 2, 'utf8')
      this.#writeFrame(OPCODE.CLOSE, payload)
      this.closeSent = true
    }
    this.#finish()
  }

  #startClose(code = 1000, reason = '') {
    if (this.closed) return
    this.#respondClose(code, reason)
  }

  #finish() {
    if (this.closed) return
    this.closed = true
    if (this.pingTimer) {
      clearInterval(this.pingTimer)
      this.pingTimer = null
    }
    try {
      this.socket.end()
    } catch {
      // 忽略：对端已断
    }
    this.emit('close')
  }

  #onSocketClose() {
    if (this.closed) return
    this.closed = true
    if (this.pingTimer) {
      clearInterval(this.pingTimer)
      this.pingTimer = null
    }
    this.emit('close')
  }
}

/**
 * 在 node:http server 上挂一个 WS 端点。
 * @param {import('node:http').Server} server
 * @param {object} options
 * @param {string} options.path 只接受该路径的 upgrade
 * @param {(req: import('node:http').IncomingMessage) => {ok: boolean, status?: number, message?: string}} [options.authorize]
 * @param {(conn: WebSocketConnection, req: import('node:http').IncomingMessage) => void} options.onConnection
 * @param {number} [options.maxMessageBytes]
 * @param {number} [options.pingIntervalMs]
 */
export function attachWebSocketServer(server, options) {
  const handleUpgrade = (req, socket) => {
    let done = false
    const abort = (status, message) => {
      if (done) return
      done = true
      const body = message ?? ''
      socket.write(
        `HTTP/1.1 ${status} ${status === 401 ? 'Unauthorized' : 'Bad Request'}\r\n`
        + 'Connection: close\r\n'
        + 'Content-Type: text/plain; charset=utf-8\r\n'
        + `Content-Length: ${Buffer.byteLength(body)}\r\n\r\n${body}`,
      )
      socket.destroy()
    }

    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    if (url.pathname !== options.path) {
      abort(404, 'not found')
      return
    }
    if ((req.headers.upgrade ?? '').toLowerCase() !== 'websocket' || !req.headers['sec-websocket-key']) {
      abort(400, 'websocket upgrade required')
      return
    }
    const decision = options.authorize ? options.authorize(req) : { ok: true }
    if (!decision.ok) {
      abort(decision.status ?? 401, decision.message ?? 'unauthorized')
      return
    }

    socket.write(
      'HTTP/1.1 101 Switching Protocols\r\n'
      + 'Upgrade: websocket\r\n'
      + 'Connection: Upgrade\r\n'
      + `Sec-WebSocket-Accept: ${acceptKey(String(req.headers['sec-websocket-key']))}\r\n`
      + '\r\n',
    )
    socket.setTimeout(0)
    socket.setKeepAlive(true, 30000)
    done = true
    const conn = new WebSocketConnection(socket, {
      maxMessageBytes: options.maxMessageBytes,
      pingIntervalMs: options.pingIntervalMs,
    })
    options.onConnection(conn, req)
  }

  server.on('upgrade', handleUpgrade)
  return () => server.off('upgrade', handleUpgrade)
}