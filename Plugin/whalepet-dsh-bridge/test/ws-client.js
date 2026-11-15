/**
 * 测试用极简 WebSocket 客户端（node:net 手写，不依赖第三方包）。
 * 只覆盖测试需要：握手、发送文本/二进制、接收服务端帧（不掩码）、关闭。
 */

import net from 'node:net'
import { EventEmitter } from 'node:events'
import { createHash, randomBytes } from 'node:crypto'

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

function maskedFrame(opcode, payload) {
  const data = Buffer.isBuffer(payload) ? payload : Buffer.from(String(payload ?? ''), 'utf8')
  const mask = randomBytes(4)
  let header
  if (data.length < 126) {
    header = Buffer.from([0x80 | opcode, 0x80 | data.length])
  } else if (data.length < 65536) {
    header = Buffer.alloc(4)
    header[0] = 0x80 | opcode
    header[1] = 0x80 | 126
    header.writeUInt16BE(data.length, 2)
  } else {
    header = Buffer.alloc(10)
    header[0] = 0x80 | opcode
    header[1] = 0x80 | 127
    header.writeBigUInt64BE(BigInt(data.length), 2)
  }
  const masked = Buffer.allocUnsafe(data.length)
  for (let i = 0; i < data.length; i += 1) masked[i] = data[i] ^ mask[i % 4]
  return Buffer.concat([header, mask, masked])
}

export class TestWebSocketClient extends EventEmitter {
  constructor() {
    super()
    this.socket = null
    this.buffer = Buffer.alloc(0)
    this.messages = []
    this.waiters = []
    this.closed = false
  }

  /** 连接；返回握手状态码与响应头。 */
  connect({ host = '127.0.0.1', port, path = '/api/audio', headers = {} }) {
    return new Promise((resolve, reject) => {
      const key = randomBytes(16).toString('base64')
      const socket = net.connect(port, host, () => {
        const lines = [
          `GET ${path} HTTP/1.1`,
          `Host: ${host}:${port}`,
          'Upgrade: websocket',
          'Connection: Upgrade',
          `Sec-WebSocket-Key: ${key}`,
          'Sec-WebSocket-Version: 13',
          ...Object.entries(headers).map(([name, value]) => `${name}: ${value}`),
        ]
        socket.write(`${lines.join('\r\n')}\r\n\r\n`)
      })
      this.socket = socket
      let handshakeDone = false
      let raw = Buffer.alloc(0)
      socket.on('error', (error) => {
        if (!handshakeDone) {
          reject(error)
          return
        }
        // 握手失败的连接会被服务端主动关闭；此时不再把 ECONNRESET 当成测试错误。
        if (this.handshakeStatus === 101) this.emit('error', error)
      })
      socket.on('close', () => {
        this.closed = true
        this.emit('close')
      })
      socket.on('data', (chunk) => {
        raw = Buffer.concat([raw, chunk])
        if (!handshakeDone) {
          const index = raw.indexOf('\r\n\r\n')
          if (index < 0) return
          const head = raw.subarray(0, index).toString('utf8')
          raw = raw.subarray(index + 4)
          handshakeDone = true
          const status = Number(head.split(' ')[1])
          this.handshakeStatus = status
          const accept = /sec-websocket-accept:\s*(\S+)/i.exec(head)?.[1]
          const expected = createHash('sha1').update(`${key}${GUID}`).digest('base64')
          resolve({ status, accept, expected, headers: head })
          if (raw.length > 0) this.#onData(raw)
          return
        }
        this.#onData(raw)
        raw = Buffer.alloc(0)
      })
    })
  }

  #onData(chunk) {
    this.buffer = Buffer.concat([this.buffer, chunk])
    while (true) {
      const buf = this.buffer
      if (buf.length < 2) return
      const opcode = buf[0] & 0x0f
      const fin = (buf[0] & 0x80) !== 0
      let length = buf[1] & 0x7f
      let offset = 2
      if (length === 126) {
        if (buf.length < 4) return
        length = buf.readUInt16BE(2)
        offset = 4
      } else if (length === 127) {
        if (buf.length < 10) return
        length = Number(buf.readBigUInt64BE(2))
        offset = 10
      }
      if (buf.length < offset + length) return
      const payload = buf.subarray(offset, offset + length)
      this.buffer = buf.subarray(offset + length)
      if (opcode === 0x1 || opcode === 0x2) {
        const message = { type: opcode === 0x1 ? 'text' : 'binary', fin, data: payload }
        if (opcode === 0x1) {
          try {
            message.json = JSON.parse(payload.toString('utf8'))
          } catch {
            message.json = null
          }
        }
        this.messages.push(message)
        const waiters = this.waiters
        this.waiters = []
        for (const waiter of waiters) waiter()
        this.emit('message', message)
      } else if (opcode === 0x8) {
        this.closed = true
        this.socket.end()
        this.emit('close')
        return
      } else if (opcode === 0x9) {
        // 回 pong
        this.socket.write(maskedFrame(0xa, payload))
      } else if (opcode === 0xa) {
        this.emit('pong')
      }
    }
  }

  sendText(text) {
    this.socket.write(maskedFrame(0x1, text))
  }

  sendJSON(object) {
    this.sendText(JSON.stringify(object))
  }

  sendBinary(data) {
    this.socket.write(maskedFrame(0x2, data))
  }

  /** 等到事件消息满足条件（或超时）。 */
  async waitFor(predicate, { timeoutMs = 3000, fromIndex = 0 } = {}) {
    const deadline = Date.now() + timeoutMs
    let index = fromIndex
    while (true) {
      for (; index < this.messages.length; index += 1) {
        const message = this.messages[index]
        if (message.json && predicate(message.json, message)) return { message: message.json, index }
      }
      const remain = deadline - Date.now()
      if (remain <= 0) throw new Error('waitFor 超时')
      await new Promise((resolve) => {
        const timer = setTimeout(resolve, remain)
        this.waiters.push(() => {
          clearTimeout(timer)
          resolve()
        })
      })
    }
  }

  close() {
    if (this.closed) return
    try {
      this.socket.write(maskedFrame(0x8, Buffer.alloc(0)))
    } catch {
      // 忽略
    }
    this.closed = true
    this.socket.end()
  }
}