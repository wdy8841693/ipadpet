#!/usr/bin/env node
/**
 * /api/agent 文本通道的命令行客户端（联调用）。
 *
 * 用途：在没有 iPad / 新客户端的情况下，直接验证插件的新文本通道：
 *   - 握手与 voice_config；
 *   - 一条命令的完整事件序列（queued → started → response → finished）；
 *   - 断线重连后的结果补发（--drop-after <毫秒> 模拟拔线）。
 *
 * 用法：
 *   node Tools/agent/client.js --text "帮我查一下明天的安排"
 *   node Tools/agent/client.js --text "再问一次" --request-id req-001   # 幂等重试
 *   node Tools/agent/client.js --text "慢任务" --drop-after 500        # 拔线后重连补发
 *
 * 参数：
 *   --url       默认 http://127.0.0.1:8787
 *   --token     默认读 ~/.dsh/whalepet/ipad-token
 *   --client-id 默认 agent-cli-<pid>
 *   --text      要发的命令（不填只做握手）
 *   --request-id  指定请求 id（用于验证幂等）
 *   --drop-after 发送命令后多少毫秒断开连接（模拟断线）
 *   --announce  订阅其它会话的全局通知
 */

import net from 'node:net'
import os from 'node:os'
import path from 'node:path'
import fsp from 'node:fs/promises'
import { createHash, randomBytes, randomUUID } from 'node:crypto'

const GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

function parseArgs(argv) {
  const args = {}
  for (let i = 0; i < argv.length; i += 1) {
    const item = argv[i]
    if (!item.startsWith('--')) continue
    const key = item.slice(2)
    const next = argv[i + 1]
    if (next === undefined || next.startsWith('--')) {
      args[key] = true
    } else {
      args[key] = next
      i += 1
    }
  }
  return args
}

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

async function resolveToken(args) {
  if (typeof args.token === 'string' && args.token) return args.token.trim()
  const file = path.join(os.homedir(), '.dsh', 'whalepet', 'ipad-token')
  const token = (await fsp.readFile(file, 'utf8')).trim()
  if (!token) throw new Error(`令牌文件是空的：${file}`)
  return token
}

/** 极简 WS 客户端：握手、发文本、收文本。 */
function connect({ url, token, onMessage }) {
  const parsed = new URL(url)
  const port = Number(parsed.port || (parsed.protocol === 'https:' ? 443 : 80))
  const key = randomBytes(16).toString('base64')
  return new Promise((resolve, reject) => {
    const socket = net.connect(port, parsed.hostname, () => {
      const lines = [
        `GET /api/agent HTTP/1.1`,
        `Host: ${parsed.hostname}:${port}`,
        'Upgrade: websocket',
        'Connection: Upgrade',
        `Sec-WebSocket-Key: ${key}`,
        'Sec-WebSocket-Version: 13',
        `Authorization: Bearer ${token}`,
      ]
      socket.write(`${lines.join('\r\n')}\r\n\r\n`)
    })
    let buffer = Buffer.alloc(0)
    let handshaked = false
    socket.on('error', (error) => {
      if (!handshaked) reject(error)
    })
    socket.on('data', (chunk) => {
      buffer = Buffer.concat([buffer, chunk])
      if (!handshaked) {
        const index = buffer.indexOf('\r\n\r\n')
        if (index < 0) return
        const head = buffer.subarray(0, index).toString('utf8')
        buffer = buffer.subarray(index + 4)
        handshaked = true
        const status = Number(head.split(' ')[1])
        const accept = /sec-websocket-accept:\s*(\S+)/i.exec(head)?.[1]
        const expected = createHash('sha1').update(`${key}${GUID}`).digest('base64')
        if (status !== 101 || accept !== expected) {
          reject(new Error(`握手失败：HTTP ${status}`))
          return
        }
        resolve({
          socket,
          sendJSON(value) {
            socket.write(maskedFrame(0x1, JSON.stringify(value)))
          },
          close() {
            try {
              socket.write(maskedFrame(0x8, Buffer.alloc(0)))
            } catch {
              // 忽略
            }
            socket.end()
          },
        })
      }
      // 只解析未分片的文本帧（服务端推送都是小消息）。
      while (buffer.length >= 2) {
        const opcode = buffer[0] & 0x0f
        let length = buffer[1] & 0x7f
        let offset = 2
        if (length === 126) {
          if (buffer.length < 4) break
          length = buffer.readUInt16BE(2)
          offset = 4
        } else if (length === 127) {
          if (buffer.length < 10) break
          length = Number(buffer.readBigUInt64BE(2))
          offset = 10
        }
        if (buffer.length < offset + length) break
        const payload = buffer.subarray(offset, offset + length)
        buffer = buffer.subarray(offset + length)
        if (opcode === 0x1) {
          try {
            onMessage?.(JSON.parse(payload.toString('utf8')))
          } catch {
            // 忽略非法 JSON
          }
        } else if (opcode === 0x9) {
          socket.write(maskedFrame(0xa, payload))
        }
      }
    })
  })
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const url = typeof args.url === 'string' ? args.url : 'http://127.0.0.1:8787'
  const token = await resolveToken(args)
  const clientId = typeof args['client-id'] === 'string' ? args['client-id'] : `agent-cli-${process.pid}`
  const requestId = typeof args['request-id'] === 'string' ? args['request-id'] : `req-${randomUUID().replace(/-/g, '').slice(0, 20)}`

  const print = (event) => {
    const kind = event?.type ?? 'unknown'
    const extra = event?.state ? ` state=${event.state}` : ''
    const text = event?.text ?? event?.speech_text ?? event?.display_text ?? event?.message ?? ''
    console.log(`[${kind}]${extra}${text ? ` ${text}` : ''}`)
  }

  console.log(`→ 连接 ${url}（client_id=${clientId}）`)
  const first = await connect({ url, token, onMessage: print })
  first.sendJSON({
    type: 'hello',
    protocol: 2,
    client_id: clientId,
    conversation_id: 'whalepet-main',
    device_kind: 'cli',
    capabilities: [],
    subscriptions: { announcements: args.announce === true },
    last_received_event_id: null,
  })
  await new Promise((resolve) => setTimeout(resolve, 300))

  if (typeof args.text !== 'string' || !args.text) {
    console.log('（没有 --text，只做了握手）')
    first.close()
    return
  }

  first.sendJSON({
    type: 'command',
    request_id: requestId,
    client_id: clientId,
    conversation_id: 'whalepet-main',
    text: args.text,
    source: 'cli',
  })

  if (args['drop-after']) {
    const delay = Number(args['drop-after'])
    await new Promise((resolve) => setTimeout(resolve, delay))
    console.log('— 拔线（模拟断线）')
    first.close()
    // 重连：按 last_received_event_id 补发断线期间的结果。
    await new Promise((resolve) => setTimeout(resolve, 500))
    console.log('→ 重连')
    const again = await connect({ url, token, onMessage: print })
    again.sendJSON({
      type: 'hello',
      protocol: 2,
      client_id: clientId,
      conversation_id: 'whalepet-main',
      subscriptions: { announcements: args.announce === true },
      last_received_event_id: null,
    })
    await new Promise((resolve) => setTimeout(resolve, 3000))
    again.close()
    return
  }

  await new Promise((resolve) => setTimeout(resolve, 8000))
  first.close()
}

main().catch((error) => {
  console.error(`失败：${error?.message ?? error}`)
  process.exitCode = 1
})
