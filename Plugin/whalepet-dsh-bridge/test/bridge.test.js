/**
 * 传输层端到端测试：真 HTTP + 真 WebSocket，adapter 用 mock 替身。
 * 覆盖：鉴权 / health / chat / 语音唤醒 / 一句话带命令 / 命令回复 /
 *       playback 闭麦 / cancel。
 */

import test from 'node:test'
import assert from 'node:assert/strict'
import { createBridgeServer, normalizeBridgeConfig, tokenEquals } from '../src/server.js'
import { TestWebSocketClient } from './ws-client.js'
import { utterance, silenceFrames } from './audio-fixture.js'

const TOKEN = 'test-token-0123456789abcdef'

/** 记录调用并按队列返回结果的假 adapter。 */
function createMockAdapter({ transcripts = [], replies = [] } = {}) {
  const calls = []
  return {
    calls,
    transcripts: [...transcripts],
    replies: [...replies],
    async health() {
      return { ready: true, detail: 'mock-sensevoice' }
    },
    async transcribe(wav) {
      calls.push({ kind: 'transcribe', bytes: wav.length })
      const next = this.transcripts.shift()
      if (next instanceof Error) throw next
      return next ?? ''
    },
    async ask(sessionId, text) {
      calls.push({ kind: 'ask', sessionId, text })
      const next = this.replies.shift()
      if (next instanceof Error) throw next
      return next ?? `收到：${text}`
    },
    async prepareSession(sessionId) {
      calls.push({ kind: 'prepareSession', sessionId })
    },
  }
}

async function startServer(options = {}) {
  const adapter = options.adapter ?? createMockAdapter(options)
  const config = {
    ...normalizeBridgeConfig({ token: TOKEN, ...(options.config ?? {}) }),
    port: 0,
    host: '127.0.0.1',
  }
  const bridge = createBridgeServer({ adapter, config, logger: {} })
  await bridge.listen()
  const port = bridge.server.address().port
  return { bridge, adapter, port, base: `http://127.0.0.1:${port}` }
}

test('tokenEquals: 长度不同的输入也安全，错误令牌为 false', () => {
  assert.equal(tokenEquals(TOKEN, TOKEN), true)
  assert.equal(tokenEquals(`${TOKEN}x`, TOKEN), false)
  assert.equal(tokenEquals('', TOKEN), false)
  assert.equal(tokenEquals(TOKEN, ''), false)
})

test('config: 缺 token / 令牌过短 / 端口非法都会报错', () => {
  assert.throws(() => normalizeBridgeConfig({}), /token/)
  assert.throws(() => normalizeBridgeConfig({ token: 'short' }), /至少 16/)
  assert.throws(() => normalizeBridgeConfig({ token: TOKEN, port: 70000 }), /port/)
  const config = normalizeBridgeConfig({ token: TOKEN, wakePhrase: '小胖小胖' })
  assert.equal(config.wakePhrase, '小胖小胖')
  assert.equal(config.voice.frameBytes, 640) // 20ms @16k 16bit
})

test('HTTP: health 需要鉴权，鉴权后返回 asr 状态', async () => {
  const { bridge, base } = await startServer()
  try {
    const unauthorized = await fetch(`${base}/api/health`)
    assert.equal(unauthorized.status, 401)

    const ok = await fetch(`${base}/api/health`, { headers: { Authorization: `Bearer ${TOKEN}` } })
    assert.equal(ok.status, 200)
    const body = await ok.json()
    // 旧字段保持不变（iPad 只看 asr/model），新字段给跨平台客户端看。
    assert.equal(body.ok, true)
    assert.equal(body.asr, true)
    assert.equal(body.model, 'mock-sensevoice')
    assert.equal(body.version, '0.4.0')
    assert.deepEqual(body.agent, { ready: true })
    assert.deepEqual(body.protocols, ['audio-v1', 'agent-v2'])
  } finally {
    await bridge.close()
  }
})

test('HTTP: /api/chat 校验入参并返回回复', async () => {
  const adapter = createMockAdapter({ replies: ['现在是下午三点'] })
  const { bridge, base } = await startServer({ adapter })
  const headers = { Authorization: `Bearer ${TOKEN}`, 'Content-Type': 'application/json' }
  try {
    const badSession = await fetch(`${base}/api/chat`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ session_id: 'bad id!', text: '你好' }),
    })
    assert.equal(badSession.status, 400)

    const empty = await fetch(`${base}/api/chat`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ session_id: 'pet-001', text: '   ' }),
    })
    assert.equal(empty.status, 400)

    const ok = await fetch(`${base}/api/chat`, {
      method: 'POST',
      headers,
      body: JSON.stringify({ session_id: 'pet-001', text: '几点了' }),
    })
    assert.equal(ok.status, 200)
    assert.deepEqual(await ok.json(), { ok: true, reply: '现在是下午三点' })
    assert.deepEqual(adapter.calls.at(-1), { kind: 'ask', sessionId: 'pet-001', text: '几点了' })
  } finally {
    await bridge.close()
  }
})

test('WS: 未授权升级被拒绝', async () => {
  const { bridge, port } = await startServer()
  try {
    const client = new TestWebSocketClient()
    const handshake = await client.connect({ port })
    assert.equal(handshake.status, 401)
    // 握手失败不是 WebSocket 连接，直接断 TCP，不发 close 帧。
    client.socket?.destroy()
  } finally {
    await bridge.close()
  }
})

test('WS: 完整语音链路（唤醒 -> 聆听 -> 命令 -> 回复）', async () => {
  const adapter = createMockAdapter({
    transcripts: ['小鲸小鲸', '现在几点了'],
    replies: ['现在是下午三点'],
  })
  const { bridge, port } = await startServer({ adapter })
  const client = new TestWebSocketClient()
  try {
    const handshake = await client.connect({ port, headers: { Authorization: `Bearer ${TOKEN}` } })
    assert.equal(handshake.status, 101)
    assert.equal(handshake.accept, handshake.expected)

    const ready = await client.waitFor((event) => event.type === 'ready')
    assert.equal(ready.message.wake_phrase, '小鲸小鲸')
    assert.equal(ready.message.sample_rate, 16000)

    client.sendJSON({ type: 'hello', session_id: 'pet-001', wake_phrase: '小鲸小鲸', sample_rate: 16000 })
    await new Promise((resolve) => setTimeout(resolve, 30))

    // 第一段语音：只说唤醒词。
    client.sendBinary(utterance())
    const wake = await client.waitFor((event) => event.type === 'wake')
    assert.equal(wake.message.phrase, '小鲸小鲸')
    await client.waitFor((event) => event.type === 'state' && event.value === 'listening')
    // 只唤醒时宠物先答一句「我在」，然后继续聆听。
    const ack = await client.waitFor((event) => event.type === 'response' && event.text === '我在')
    assert.equal(ack.message.text, '我在')

    // 第二段语音：命令。
    client.sendBinary(utterance())
    const transcript = await client.waitFor((event) => event.type === 'transcript')
    assert.equal(transcript.message.text, '现在几点了')
    await client.waitFor((event) => event.type === 'state' && event.value === 'thinking')
    const response = await client.waitFor((event) => event.type === 'response' && event.text === '现在是下午三点')
    assert.equal(response.message.text, '现在是下午三点')

    // 握手时应当调用过 prepareSession。
    assert.ok(adapter.calls.some((call) => call.kind === 'prepareSession' && call.sessionId === 'pet-001'))
    // 转写收到的必须是合法 WAV（44 字节头 + PCM）。
    const transcribeCall = adapter.calls.find((call) => call.kind === 'transcribe')
    assert.ok(transcribeCall.bytes > 44)
  } finally {
    client.close()
    await bridge.close()
  }
})

test('WS: 一句话带命令直接执行，不进入聆听态', async () => {
  const adapter = createMockAdapter({ transcripts: ['小鲸小鲸 讲个笑话'], replies: ['有一只鲸鱼……'] })
  const { bridge, port } = await startServer({ adapter })
  const client = new TestWebSocketClient()
  try {
    await client.connect({ port, headers: { Authorization: `Bearer ${TOKEN}` } })
    await client.waitFor((event) => event.type === 'ready')
    client.sendJSON({ type: 'hello', session_id: 'pet-001' })
    await new Promise((resolve) => setTimeout(resolve, 30))

    client.sendBinary(utterance())
    const wake = await client.waitFor((event) => event.type === 'wake')
    assert.equal(wake.message.phrase, '小鲸小鲸 讲个笑话')
    const transcript = await client.waitFor((event) => event.type === 'transcript')
    assert.equal(transcript.message.text, '讲个笑话')
    const response = await client.waitFor((event) => event.type === 'response')
    assert.equal(response.message.text, '有一只鲸鱼……')
    // 不应出现 listening 状态。
    assert.equal(client.messages.some((message) => message.json?.value === 'listening'), false)
  } finally {
    client.close()
    await bridge.close()
  }
})

test('WS: playback_start 期间丢弃音频，playback_end 回到等待态', async () => {
  const adapter = createMockAdapter({ transcripts: [] })
  const { bridge, port } = await startServer({ adapter })
  const client = new TestWebSocketClient()
  try {
    await client.connect({ port, headers: { Authorization: `Bearer ${TOKEN}` } })
    await client.waitFor((event) => event.type === 'ready')
    client.sendJSON({ type: 'hello', session_id: 'pet-001' })

    client.sendText('playback_start')
    client.sendBinary(utterance())
    await new Promise((resolve) => setTimeout(resolve, 200))
    assert.equal(adapter.calls.filter((call) => call.kind === 'transcribe').length, 0)

    client.sendText('playback_end')
    const waiting = await client.waitFor((event) => event.type === 'state' && event.value === 'waiting')
    assert.ok(waiting)
  } finally {
    client.close()
    await bridge.close()
  }
})

test('WS: cancel 中止进行中的提问', async () => {
  let release
  const adapter = {
    async health() {
      return { ready: true, detail: 'mock' }
    },
    async transcribe() {
      return '小鲸小鲸 讲个长故事'
    },
    ask(_sessionId, _text, { signal } = {}) {
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => resolve('迟到的回复'), 500)
        signal?.addEventListener('abort', () => {
          clearTimeout(timer)
          const error = new Error('aborted')
          error.name = 'AbortError'
          reject(error)
        }, { once: true })
        release = resolve
      })
    },
  }
  const { bridge, port } = await startServer({ adapter })
  const client = new TestWebSocketClient()
  try {
    await client.connect({ port, headers: { Authorization: `Bearer ${TOKEN}` } })
    await client.waitFor((event) => event.type === 'ready')
    client.sendJSON({ type: 'hello', session_id: 'pet-001' })
    await new Promise((resolve) => setTimeout(resolve, 30))

    client.sendBinary(utterance())
    await client.waitFor((event) => event.type === 'state' && event.value === 'thinking')
    client.sendText('cancel')
    await client.waitFor((event) => event.type === 'state' && event.value === 'waiting')
    assert.equal(client.messages.some((message) => message.json?.type === 'response'), false)
    release?.('late')
  } finally {
    client.close()
    await bridge.close()
  }
})

test('WS: 未 hello 就说话 -> 错误提示', async () => {
  const adapter = createMockAdapter({ transcripts: ['小鲸小鲸 你好'] })
  const { bridge, port } = await startServer({ adapter })
  const client = new TestWebSocketClient()
  try {
    await client.connect({ port, headers: { Authorization: `Bearer ${TOKEN}` } })
    await client.waitFor((event) => event.type === 'ready')
    client.sendBinary(utterance())
    const error = await client.waitFor((event) => event.type === 'error')
    assert.match(error.message.message, /握手/)
  } finally {
    client.close()
    await bridge.close()
  }
})

test('WS: 控制消息与非法 hello', async () => {
  const { bridge, port } = await startServer()
  const client = new TestWebSocketClient()
  try {
    await client.connect({ port, headers: { Authorization: `Bearer ${TOKEN}` } })
    await client.waitFor((event) => event.type === 'ready')

    client.sendText('unknown_command')
    const error = await client.waitFor((event) => event.type === 'error')
    assert.match(error.message.message, /无法解析的控制消息/)

    client.sendJSON({ type: 'nope' })
    const error2 = await client.waitFor((event) => event.type === 'error' && event.message.includes('未知控制消息'))
    assert.ok(error2)

    client.sendJSON({ type: 'hello', session_id: 'bad id!' })
    const error3 = await client.waitFor((event) => event.type === 'error' && event.message.includes('session_id'))
    assert.ok(error3)
  } finally {
    client.close()
    await bridge.close()
  }
})

test('WS: 长任务期间周期性发 thinking 心跳', async () => {
  const adapter = {
    async health() {
      return { ready: true, detail: 'mock' }
    },
    async transcribe() {
      return '小鲸小鲸 帮我做个长任务'
    },
    ask() {
      return new Promise((resolve) => setTimeout(() => resolve('做完了'), 300))
    },
  }
  const { bridge, port } = await startServer({ adapter, config: { progressIntervalMs: 40 } })
  const client = new TestWebSocketClient()
  try {
    await client.connect({ port, headers: { Authorization: `Bearer ${TOKEN}` } })
    await client.waitFor((event) => event.type === 'ready')
    client.sendJSON({ type: 'hello', session_id: 'pet-heartbeat' })
    await new Promise((resolve) => setTimeout(resolve, 30))

    client.sendBinary(utterance())
    await client.waitFor((event) => event.type === 'response')
    const heartbeats = client.messages.filter((message) => message.json?.type === 'thinking').length
    assert.ok(heartbeats >= 3, `心跳数量 ${heartbeats}`)
    // 心跳不应打断最终回复的顺序（response 在最后一条 thinking 之后）。
    const lastThinking = client.messages.findLastIndex((message) => message.json?.type === 'thinking')
    const response = client.messages.findIndex((message) => message.json?.type === 'response')
    assert.ok(response > lastThinking)
  } finally {
    client.close()
    await bridge.close()
  }
})


test('WS: 任务开始 / 需要授权 / 完成 三类提醒事件', async () => {
  const adapter = {
    async health() {
      return { ready: true, detail: 'mock' }
    },
    async transcribe() {
      return '小鲸小鲸 帮我整理一下资料'
    },
    ask(_sessionId, _text, { notify } = {}) {
      notify?.({ state: 'started', text: '开始执行，我这就去办' })
      setTimeout(() => notify?.({ state: 'approval', text: '有个操作需要你授权' }), 40)
      return new Promise((resolve) => setTimeout(() => resolve('整理好了'), 120))
    },
  }
  const { bridge, port } = await startServer({ adapter })
  const client = new TestWebSocketClient()
  try {
    await client.connect({ port, headers: { Authorization: `Bearer ${TOKEN}` } })
    await client.waitFor((event) => event.type === 'ready')
    client.sendJSON({ type: 'hello', session_id: 'pet-task' })
    await new Promise((resolve) => setTimeout(resolve, 30))

    client.sendBinary(utterance())
    await client.waitFor((event) => event.type === 'response')

    const tasks = client.messages
      .filter((message) => message.json?.type === 'task')
      .map((message) => message.json.state)
    assert.deepEqual(tasks, ['started', 'approval', 'finished'])
    const responseIndex = client.messages.findIndex((message) => message.json?.type === 'response')
    const finishedIndex = client.messages.findIndex((message) => message.json?.state === 'finished')
    assert.ok(finishedIndex > responseIndex, 'finished 应在 response 之后')
  } finally {
    client.close()
    await bridge.close()
  }
})


test('断线期间完成的任务，重连 hello 后补发 response', async () => {
  const adapter = {
    async health() {
      return { ready: true, detail: 'mock' }
    },
    async transcribe() {
      return '小鲸小鲸 帮我整理资料'
    },
    ask(_sessionId, _text, { notify } = {}) {
      notify?.({ state: 'started', text: '开始执行' })
      return new Promise((resolve) => setTimeout(() => resolve('断线后完成的结果'), 250))
    },
  }
  const { bridge, port } = await startServer({ adapter })
  const first = new TestWebSocketClient()
  const second = new TestWebSocketClient()
  try {
    await first.connect({ port, headers: { Authorization: `Bearer ${TOKEN}` } })
    await first.waitFor((event) => event.type === 'ready')
    first.sendJSON({ type: 'hello', session_id: 'pet-replay' })
    await new Promise((resolve) => setTimeout(resolve, 30))
    first.sendBinary(utterance())
    await first.waitFor((event) => event.type === 'task' && event.state === 'started')

    // 任务还在跑时拔线。
    first.close()
    await new Promise((resolve) => setTimeout(resolve, 450))

    // 重连：握手后应立即收到补发的结果。
    await second.connect({ port, headers: { Authorization: `Bearer ${TOKEN}` } })
    await second.waitFor((event) => event.type === 'ready')
    second.sendJSON({ type: 'hello', session_id: 'pet-replay' })
    const finished = await second.waitFor((event) => event.type === 'task' && event.state === 'finished')
    assert.match(finished.message.text, /断线/)
    const response = await second.waitFor((event) => event.type === 'response')
    assert.equal(response.message.text, '断线后完成的结果')
  } finally {
    first.close()
    second.close()
    await bridge.close()
  }
})

test('重连时任务仍在跑：通知 interrupted，完成后在同一连接补发结果', async () => {
  const adapter = {
    async health() {
      return { ready: true, detail: 'mock' }
    },
    async transcribe() {
      return '小鲸小鲸 做个慢任务'
    },
    ask(_sessionId, _text, { notify } = {}) {
      notify?.({ state: 'started', text: '开始执行' })
      return new Promise((resolve) => setTimeout(() => resolve('慢任务完成了'), 900))
    },
  }
  const { bridge, port } = await startServer({ adapter })
  const first = new TestWebSocketClient()
  const second = new TestWebSocketClient()
  try {
    await first.connect({ port, headers: { Authorization: `Bearer ${TOKEN}` } })
    await first.waitFor((event) => event.type === 'ready')
    first.sendJSON({ type: 'hello', session_id: 'pet-mid' })
    await new Promise((resolve) => setTimeout(resolve, 30))
    first.sendBinary(utterance())
    await first.waitFor((event) => event.type === 'task' && event.state === 'started')
    first.close()

    await new Promise((resolve) => setTimeout(resolve, 150))
    await second.connect({ port, headers: { Authorization: `Bearer ${TOKEN}` } })
    await second.waitFor((event) => event.type === 'ready')
    second.sendJSON({ type: 'hello', session_id: 'pet-mid' })
    const interrupted = await second.waitFor((event) => event.type === 'task' && event.state === 'interrupted')
    assert.match(interrupted.message.text, /后台/)

    const response = await second.waitFor((event) => event.type === 'response', { timeoutMs: 5000 })
    assert.equal(response.message.text, '慢任务完成了')
    const finished = await second.waitFor((event) => event.type === 'task' && event.state === 'finished')
    assert.ok(finished)
  } finally {
    first.close()
    second.close()
    await bridge.close()
  }
})


test('WS: wakeAck 配置为空时，只唤醒不答话', async () => {
  const adapter = createMockAdapter({ transcripts: ['小鲸小鲸', '现在几点了'], replies: ['三点'] })
  const { bridge, port } = await startServer({ adapter, config: { wakeAck: '' } })
  const client = new TestWebSocketClient()
  try {
    await client.connect({ port, headers: { Authorization: `Bearer ${TOKEN}` } })
    await client.waitFor((event) => event.type === 'ready')
    client.sendJSON({ type: 'hello', session_id: 'pet-noack' })
    await new Promise((resolve) => setTimeout(resolve, 30))
    client.sendBinary(utterance())
    await client.waitFor((event) => event.type === 'wake')
    await client.waitFor((event) => event.type === 'state' && event.value === 'listening')
    // 给服务器 300ms 机会发应答；wakeAck 为空时不应有 response。
    await new Promise((resolve) => setTimeout(resolve, 300))
    assert.ok(!client.messages.some((message) => message.json?.type === 'response'))
  } finally {
    client.close()
    await bridge.close()
  }
})
