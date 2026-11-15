/**
 * Host 入口（index.js）集成测试：用假 ctx 提供 DSH 服务，验证
 *   - 插件能起监听、令牌落盘
 *   - 语音/文本请求会正确走 speechToText -> sessionController
 *   - 会话映射持久化、会话被删后自动重建、审批策略设置
 *   - wait() 返回的 assistant 记录能被正确抽取成回复
 *
 * 不依赖真实 DSH 进程；真机联调走另一份「安装后冒烟」脚本。
 */

import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import fsp from 'node:fs/promises'
import os from 'node:os'
import net from 'node:net'
import path from 'node:path'
import { apply, extractText, lastAssistantText, toSpeechText } from '../index.js'
import { TestWebSocketClient } from './ws-client.js'
import { utterance } from './audio-fixture.js'

const TOKEN = 'index-test-token-0123456789'

function notFound() {
  const error = new Error('session/not-found')
  error.code = 'session/not-found'
  return error
}

/** 造一个假 ctx：实现插件注入的四个 Host 服务。 */
function createFakeEnv({ transcripts = [] } = {}) {
  const calls = {
    create: [],
    prompt: [],
    wait: [],
    state: [],
    policies: [],
    prepare: [],
    transcribe: [],
    restore: [],
    persona: [],
    personaDisposed: 0,
    permissionPreset: [],
  }
  const live = new Map() // dshSessionId -> { cursor, pending, replies: string[] }
  const transcriptQueue = [...transcripts]

  const sessionController = {
    async create(request) {
      calls.create.push(request)
      live.set(request.sessionId, { cursor: 0, pending: '', replies: [] })
      return { sessionId: request.sessionId }
    },
    async state(request) {
      calls.state.push(request.sessionId)
      const session = live.get(request.sessionId)
      if (!session) throw notFound()
      return { cursor: session.cursor, active: false, running: false, queue: null, pendingInput: [] }
    },
    async prompt(request) {
      calls.prompt.push(request)
      const session = live.get(request.sessionId)
      if (!session) throw notFound()
      session.pending = request.content.map((part) => part.text).join('')
      session.cursor += 1
      return { accepted: true }
    },
    async wait(request) {
      calls.wait.push(request)
      const session = live.get(request.sessionId)
      if (!session) throw notFound()
      session.cursor += 1
      const text = `收到：${session.pending}`
      return {
        reason: 'idle',
        state: { cursor: session.cursor, active: false, running: false, queue: null, pendingInput: [] },
        output: {
          truncated: false,
          records: [{
            type: 'event',
            event: {
              type: 'assistant/message',
              seq: session.cursor,
              time: Date.now(),
              data: { turn: 1, step: 1, message: { role: 'assistant', content: [{ type: 'text', text }] } },
            },
          }],
        },
      }
    },
    async resolveAgent(sessionId) {
      if (!live.has(sessionId)) throw notFound()
      const agent = {
        id: sessionId,
        session: { id: sessionId },
        ctx: {
          systemPrompt: {
            section(definition) {
              calls.persona.push({ sessionId, definition })
              return () => {
                calls.personaDisposed += 1
              }
            },
          },
        },
      }
      return { agent }
    },
  }

  const speechToText = {
    snapshot() {
      return {
        selection: { providerId: 'sensevoice-local', language: 'zh' },
        providers: [{ id: 'sensevoice-local', preparation: { phase: 'ready' } }],
      }
    },
    prepare(providerId) {
      calls.prepare.push(providerId)
    },
    resolve(request) {
      return { audio: request.audio, language: request.language, provider: {} }
    },
    async transcribe(spec) {
      calls.transcribe.push(spec.audio.length)
      const next = transcriptQueue.shift()
      if (next instanceof Error) throw next
      return { text: next ?? '', audioSeconds: 1, inferenceSeconds: 0.01 }
    },
  }

  const disposers = []
  const permissionPresets = {
    set(session, name) {
      calls.permissionPreset.push({ sessionId: session.id, name })
    },
  }
  const ctx = {
    logger: {
      info(message) {
        calls.logs ??= []
        calls.logs.push(['info', message])
      },
      warn(message) {
        calls.logs ??= []
        calls.logs.push(['warn', message])
      },
      error(message) {
        calls.logs ??= []
        calls.logs.push(['error', message])
      },
    },
    effect(fn) {
      disposers.push(fn())
    },
    get(service) {
      return service === 'permissionPresets' ? permissionPresets : undefined
    },
    speechToText,
    sessionController,
    agents: {
      get(id) {
        return live.has(id) ? { id } : undefined
      },
    },
    approval: {
      setPolicy(agent, policy) {
        calls.policies.push({ agent: agent.id, policy })
      },
    },
  }

  return { ctx, calls, live, disposers, transcriptQueue }
}

/** 找一个空闲端口（测试用）。 */
function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer()
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address()
      server.close(() => resolve(port))
    })
  })
}

/** 等网关起来（health 能返回 200）。 */
async function waitForBridge(base, headers) {
  const deadline = Date.now() + 5000
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${base}/api/health`, { headers })
      if (response.status === 200) return await response.json()
    } catch {
      // 还没监听
    }
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
  throw new Error('网关在 5s 内没有起来')
}

async function startPlugin(overrides = {}) {
  const env = createFakeEnv(overrides)
  const dataDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'whalepet-plugin-'))
  const port = await freePort()
  apply(env.ctx, { port, host: '127.0.0.1', token: TOKEN, dataDir, ...overrides.config })
  const base = `http://127.0.0.1:${port}`
  const headers = { Authorization: `Bearer ${TOKEN}` }
  const health = await waitForBridge(base, headers)
  return { ...env, dataDir, port, base, headers, health }
}

test('extractText / lastAssistantText：只取 text 块，跳过 reasoning 与工具事件', () => {
  assert.equal(extractText(' hi '), 'hi')
  assert.equal(extractText([{ type: 'text', text: '你' }, { type: 'reasoning', text: '想想' }, { type: 'text', text: '好' }]), '你好')
  assert.equal(extractText(null), '')

  const records = [
    { type: 'event', event: { type: 'tool/call', data: {} } },
    { type: 'event', event: { type: 'assistant/message', data: { message: { content: [{ type: 'text', text: '最新回复' }] } } } },
    { type: 'event', event: { type: 'assistant/message', data: { message: { content: [{ type: 'text', text: '更早的回复' }] } } } },
  ]
  assert.equal(lastAssistantText(records), '最新回复')
  assert.equal(lastAssistantText([]), '')
  assert.equal(lastAssistantText(null), '')
})

test('插件启动：监听成功、令牌/会话目录落盘', async () => {
  const plugin = await startPlugin()
  try {
    assert.equal(plugin.health.ok, true)
    assert.equal(plugin.health.asr, true)
    assert.equal(plugin.health.model, 'sensevoice-local/ready')
    assert.ok(fs.existsSync(path.join(plugin.dataDir, 'workspace')))
  } finally {
    await plugin.disposers[0]?.()
  }
})

test('插件启动：未配置 token 时自动生成 0600 令牌文件', async () => {
  const env = createFakeEnv()
  const dataDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'whalepet-token-'))
  const port = await freePort()
  apply(env.ctx, { port, host: '127.0.0.1', dataDir })
  try {
    const tokenFile = path.join(dataDir, 'ipad-token')
    const deadline = Date.now() + 5000
    while (!fs.existsSync(tokenFile) && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 50))
    }
    const token = (await fsp.readFile(tokenFile, 'utf8')).trim()
    assert.ok(token.length >= 32)
    const mode = fs.statSync(tokenFile).mode & 0o777
    assert.equal(mode, 0o600)
    const health = await waitForBridge(`http://127.0.0.1:${port}`, { Authorization: `Bearer ${token}` })
    assert.equal(health.ok, true)
  } finally {
    await env.disposers[0]?.()
  }
})

test('chat：建会话 -> prompt -> wait -> 回复；同一 session 复用', async () => {
  const plugin = await startPlugin()
  try {
    const first = await fetch(`${plugin.base}/api/chat`, {
      method: 'POST',
      headers: { ...plugin.headers, 'Content-Type': 'application/json' },
      body: JSON.stringify({ session_id: 'pet-001', text: '你好呀' }),
    })
    assert.equal(first.status, 200)
    assert.deepEqual(await first.json(), { ok: true, reply: '收到：你好呀' })

    assert.equal(plugin.calls.create.length, 1)
    assert.ok(plugin.calls.create[0].sessionId.startsWith('whalepet-session-'))
    assert.ok(plugin.calls.create[0].cwd.endsWith('workspace'))
    assert.equal(plugin.calls.prompt[0].content[0].text, '你好呀')
    assert.equal(plugin.calls.prompt[0].mode, 'queue')
    assert.equal(plugin.calls.wait[0].afterSeq, 0)
    // 权限预设被写进宠物会话（Super Agent 需要能写工作区）。
    assert.deepEqual(plugin.calls.permissionPreset[0], { sessionId: plugin.calls.create[0].sessionId, name: 'workspace-write' })
    // 语音人格只注册一次，且只注册到宠物会话的 scope。
    assert.equal(plugin.calls.persona.length, 1)
    assert.equal(plugin.calls.persona[0].sessionId, plugin.calls.create[0].sessionId)
    assert.match(plugin.calls.persona[0].definition.text, /鲸鱼娘/)

    const second = await fetch(`${plugin.base}/api/chat`, {
      method: 'POST',
      headers: { ...plugin.headers, 'Content-Type': 'application/json' },
      body: JSON.stringify({ session_id: 'pet-001', text: '第二句' }),
    })
    assert.equal(second.status, 200)
    assert.deepEqual(await second.json(), { ok: true, reply: '收到：第二句' })
    // 复用会话：没有第二次 create，wait 的 afterSeq 接在上一次游标之后。
    assert.equal(plugin.calls.create.length, 1)
    assert.equal(plugin.calls.wait[1].afterSeq, 2)

    // 会话映射写进了 sessions.json。
    const persisted = JSON.parse(await fsp.readFile(path.join(plugin.dataDir, 'sessions.json'), 'utf8'))
    assert.ok(persisted['pet-001'].startsWith('whalepet-session-'))
  } finally {
    await plugin.disposers[0]?.()
  }
})

test('chat：会话在 GUI 被删后自动重建', async () => {
  const plugin = await startPlugin()
  try {
    const send = (text) => fetch(`${plugin.base}/api/chat`, {
      method: 'POST',
      headers: { ...plugin.headers, 'Content-Type': 'application/json' },
      body: JSON.stringify({ session_id: 'pet-002', text }),
    })

    assert.equal((await send('第一句')).status, 200)
    const firstId = plugin.calls.create[0].sessionId

    // 模拟用户在 GUI 里删除了这个会话。
    plugin.live.clear()

    const response = await send('删了之后')
    assert.equal(response.status, 200)
    assert.equal(plugin.calls.create.length, 2)
    assert.notEqual(plugin.calls.create[1].sessionId, firstId)
  } finally {
    await plugin.disposers[0]?.()
  }
})

test('WS：完整语音链路走通 speechToText + 官方会话', async () => {
  const plugin = await startPlugin({ transcripts: ['小鲸小鲸', '帮我看看天气'] })
  const client = new TestWebSocketClient()
  try {
    const handshake = await client.connect({ port: plugin.port, headers: { Authorization: `Bearer ${TOKEN}` } })
    assert.equal(handshake.status, 101)
    await client.waitFor((event) => event.type === 'ready')

    client.sendJSON({ type: 'hello', session_id: 'pet-voice' })
    // hello 会触发 prepareSession（建会话 + 预热识别模型）。
    const deadline = Date.now() + 3000
    while (plugin.calls.create.length === 0 && Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, 20))
    }
    assert.equal(plugin.calls.create.length, 1)
    assert.ok(plugin.calls.prepare.includes('sensevoice-local'))

    client.sendBinary(utterance())
    const wake = await client.waitFor((event) => event.type === 'wake')
    assert.equal(wake.message.phrase, '小鲸小鲸')
    await client.waitFor((event) => event.type === 'state' && event.value === 'listening')

    client.sendBinary(utterance())
    const transcript = await client.waitFor((event) => event.type === 'transcript')
    assert.equal(transcript.message.text, '帮我看看天气')
    const response = await client.waitFor((event) => event.type === 'response')
    assert.equal(response.message.text, '收到：帮我看看天气')

    // 送进 speechToText 的必须是合法 WAV（44 字节头）。
    assert.ok(plugin.calls.transcribe.every((bytes) => bytes > 44))
    assert.equal(plugin.calls.prompt.at(-1).content[0].text, '帮我看看天气')
  } finally {
    client.close()
    await plugin.disposers[0]?.()
  }
})

test('health：识别失败时 asr=false', async () => {
  const env = createFakeEnv()
  env.ctx.speechToText.snapshot = () => ({
    selection: { providerId: 'sensevoice-local', language: 'zh' },
    providers: [{ id: 'sensevoice-local', preparation: { phase: 'failed' } }],
  })
  const dataDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'whalepet-broken-'))
  const port = await freePort()
  apply(env.ctx, { port, host: '127.0.0.1', token: TOKEN, dataDir })
  try {
    const health = await waitForBridge(`http://127.0.0.1:${port}`, { Authorization: `Bearer ${TOKEN}` })
    assert.equal(health.ok, true)
    assert.equal(health.asr, false)
    assert.match(health.model, /failed/)
  } finally {
    await env.disposers[0]?.()
  }
})
test('toSpeechText：Markdown 转成能念的口语文本', () => {
  assert.equal(toSpeechText(''), '')
  assert.equal(toSpeechText(null), '')
  assert.equal(
    toSpeechText('已创建 [hello.txt](hello.txt)，内容为 `hello`。'),
    '已创建 hello.txt，内容为 hello。',
  )
  assert.equal(
    toSpeechText('## 结果\n\n- 第一项\n- 第二项\n\n**结论**：可以。'),
    '结果\n第一项\n第二项\n结论：可以。',
  )
  assert.equal(toSpeechText('```js\nconst a = 1\n```\n正在思考'), '正在思考')
})
