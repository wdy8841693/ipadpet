/**
 * 新 Agent 文本通道（WS /api/agent）端到端测试。
 *
 * 覆盖架构文档 §12.3 的契约：
 *   - 鉴权、握手、命令、回答、取消；
 *   - 两个客户端同时在线，回答只到发起端；
 *   - 全局通知只到订阅端；
 *   - 同一 request_id 重试只产生一次 DSH prompt；
 *   - A 断线时 B 仍能收到自己的回答；
 *   - A 重连后收到自己的缓存结果，收不到 B 的私有结果；
 *   - 服务端 ASR 未就绪时，文本通道仍健康。
 */

import test from 'node:test'
import assert from 'node:assert/strict'
import { createBridgeServer, normalizeBridgeConfig } from '../src/server.js'
import { ClientHub } from '../src/client-hub.js'
import { TestWebSocketClient } from './ws-client.js'

const TOKEN = 'agent-test-token-0123456789'

/** 假的 Agent 执行服务：记录调用，按需延迟。 */
function createFakeAgentService({ replies = {}, delayMs = 0, notify = true } = {}) {
  const calls = []
  return {
    calls,
    async execute({ requestId, conversationId, text, notify: progress }) {
      calls.push({ requestId, conversationId, text })
      if (notify) progress?.({ state: 'started', text: '开始执行' })
      if (delayMs) await new Promise((resolve) => setTimeout(resolve, delayMs))
      const reply = replies[text] ?? `收到：${text}`
      return { displayText: reply, speechText: reply }
    },
  }
}

async function startServer({ service, adapter, config } = {}) {
  const agentService = service ?? createFakeAgentService()
  const hub = new ClientHub()
  const bridge = createBridgeServer({
    adapter: adapter ?? {
      async health() {
        return { ready: true, detail: 'mock-sensevoice' }
      },
    },
    config: {
      ...normalizeBridgeConfig({ token: TOKEN, ...(config ?? {}) }),
      port: 0,
      host: '127.0.0.1',
    },
    logger: {},
    agent: { service: agentService, hub },
  })
  await bridge.listen()
  const port = bridge.server.address().port
  return { bridge, hub, service: agentService, port }
}

/** 连上 /api/agent 并完成 hello 握手。 */
async function connectAgent(port, { clientId = 'android-1', announcements = false, lastReceivedEventId = null } = {}) {
  const client = new TestWebSocketClient()
  const handshake = await client.connect({
    port,
    path: '/api/agent',
    headers: { Authorization: `Bearer ${TOKEN}` },
  })
  assert.equal(handshake.status, 101)
  client.sendJSON({
    type: 'hello',
    protocol: 2,
    client_id: clientId,
    conversation_id: 'whalepet-main',
    device_kind: 'android',
    capabilities: ['local-wake', 'local-asr', 'local-tts'],
    subscriptions: { announcements },
    last_received_event_id: lastReceivedEventId,
  })
  const ready = await client.waitFor((event) => event.type === 'ready')
  return { client, ready: ready.message }
}

test('/api/agent：未授权升级被拒绝', async () => {
  const { bridge, port } = await startServer()
  const client = new TestWebSocketClient()
  try {
    const handshake = await client.connect({ port, path: '/api/agent' })
    assert.equal(handshake.status, 401)
    client.socket?.destroy()
  } finally {
    await bridge.close()
  }
})

test('/api/agent：握手返回 ready 与 voice_config', async () => {
  const { bridge, port } = await startServer()
  const client = new TestWebSocketClient()
  try {
    const handshake = await client.connect({
      port,
      path: '/api/agent',
      headers: { Authorization: `Bearer ${TOKEN}` },
    })
    assert.equal(handshake.status, 101)
    client.sendJSON({
      type: 'hello',
      protocol: 2,
      client_id: 'android-1',
      conversation_id: 'whalepet-main',
      subscriptions: { announcements: false },
    })
    const ready = await client.waitFor((event) => event.type === 'ready')
    assert.equal(ready.message.protocol, 2)
    assert.equal(ready.message.agent_ready, true)
    assert.equal(ready.message.client_id, 'android-1')
    assert.equal(ready.message.conversation_id, 'whalepet-main')
    assert.ok(ready.message.server_time)

    const voice = await client.waitFor((event) => event.type === 'voice_config')
    assert.equal(voice.message.wake_phrase, '小鲸小鲸')
    assert.equal(voice.message.listen_timeout_ms, 10000)
    assert.ok(Number.isInteger(voice.message.revision))
  } finally {
    client.close()
    await bridge.close()
  }
})

test('/api/agent：命令 → 任务事件 → 最终回答', async () => {
  const service = createFakeAgentService({ replies: { '帮我查天气': '明天晴，18 度' } })
  const { bridge, port } = await startServer({ service })
  const { client } = await connectAgent(port)
  try {
    client.sendJSON({
      type: 'command',
      request_id: 'req-001',
      client_id: 'android-1',
      conversation_id: 'whalepet-main',
      text: '帮我查天气',
      source: 'voice',
    })
    const response = await client.waitFor((event) => event.type === 'response')
    assert.equal(response.message.request_id, 'req-001')
    assert.equal(response.message.display_text, '明天晴，18 度')
    assert.equal(response.message.speech_text, '明天晴，18 度')
    assert.equal(response.message.final, true)
    assert.ok(response.message.event_id)

    // response 之后才是 task finished。
    const finished = await client.waitFor((event) => event.type === 'task' && event.state === 'finished')
    assert.ok(finished)
    const responseIndex = client.messages.findIndex((message) => message.json?.type === 'response')
    const finishedIndex = client.messages.findIndex((message) => message.json?.state === 'finished')
    assert.ok(responseIndex < finishedIndex)

    const states = client.messages
      .filter((message) => message.json?.type === 'task')
      .map((message) => message.json.state)
    assert.deepEqual(states, ['queued', 'started', 'finished'])
  } finally {
    client.close()
    await bridge.close()
  }
})

test('/api/agent：两个客户端同时在线，回答只到发起端', async () => {
  const service = createFakeAgentService()
  const { bridge, port } = await startServer({ service })
  const a = await connectAgent(port, { clientId: 'android-a' })
  const b = await connectAgent(port, { clientId: 'android-b' })
  try {
    a.client.sendJSON({
      type: 'command',
      request_id: 'req-a',
      client_id: 'android-a',
      text: 'A 的问题',
    })
    const response = await a.client.waitFor((event) => event.type === 'response')
    assert.equal(response.message.request_id, 'req-a')
    assert.equal(response.message.origin_client_id, 'android-a')
    // B 不该收到 A 的私有回答。
    await new Promise((resolve) => setTimeout(resolve, 150))
    assert.equal(b.client.messages.some((message) => message.json?.type === 'response'), false)
  } finally {
    a.client.close()
    b.client.close()
    await bridge.close()
  }
})

test('/api/agent：全局通知只发给订阅者', async () => {
  const { bridge, hub, port } = await startServer()
  const subscriber = await connectAgent(port, { clientId: 'android-sub', announcements: true })
  const silent = await connectAgent(port, { clientId: 'android-silent', announcements: false })
  try {
    hub.broadcast({
      type: 'announcement',
      scope: 'global',
      state: 'finished',
      display_text: '做完了：整理资料',
      speech_text: '做完了：整理资料',
    })
    const notice = await subscriber.client.waitFor((event) => event.type === 'announcement')
    assert.equal(notice.message.scope, 'global')
    assert.equal(notice.message.state, 'finished')
    assert.ok(notice.message.event_id)

    await new Promise((resolve) => setTimeout(resolve, 120))
    assert.equal(silent.client.messages.some((message) => message.json?.type === 'announcement'), false)
  } finally {
    subscriber.client.close()
    silent.client.close()
    await bridge.close()
  }
})

test('/api/agent：同一 request_id 重试只执行一次', async () => {
  const service = createFakeAgentService()
  const { bridge, port } = await startServer({ service })
  const { client } = await connectAgent(port)
  try {
    const command = {
      type: 'command',
      request_id: 'req-dup',
      client_id: 'android-1',
      text: '重复的命令',
    }
    client.sendJSON(command)
    await client.waitFor((event) => event.type === 'response')
    client.sendJSON(command)
    await new Promise((resolve) => setTimeout(resolve, 200))
    // 只真正执行了一次；重试只是把原结果再发一遍。
    assert.equal(service.calls.length, 1)
    const responses = client.messages.filter((message) => message.json?.type === 'response')
    assert.equal(responses.length, 2)
    assert.equal(responses[0].json.event_id, responses[1].json.event_id)
  } finally {
    client.close()
    await bridge.close()
  }
})

test('/api/agent：A 断线时 B 仍能收到自己的回答', async () => {
  const service = createFakeAgentService({ delayMs: 120 })
  const { bridge, port } = await startServer({ service })
  const a = await connectAgent(port, { clientId: 'android-a' })
  const b = await connectAgent(port, { clientId: 'android-b' })
  try {
    a.client.sendJSON({ type: 'command', request_id: 'req-a', client_id: 'android-a', text: 'A 的慢任务' })
    await a.client.waitFor((event) => event.type === 'task' && event.state === 'started')
    a.client.close()

    b.client.sendJSON({ type: 'command', request_id: 'req-b', client_id: 'android-b', text: 'B 的问题' })
    const response = await b.client.waitFor((event) => event.type === 'response', { timeoutMs: 4000 })
    assert.equal(response.message.request_id, 'req-b')
    assert.equal(response.message.origin_client_id, 'android-b')
  } finally {
    a.client.close()
    b.client.close()
    await bridge.close()
  }
})

test('/api/agent：A 重连后收到自己的缓存结果，收不到 B 的私有结果', async () => {
  const service = createFakeAgentService({ delayMs: 150 })
  const { bridge, port } = await startServer({ service })
  const a = await connectAgent(port, { clientId: 'android-a' })
  const b = await connectAgent(port, { clientId: 'android-b' })
  try {
    a.client.sendJSON({ type: 'command', request_id: 'req-a', client_id: 'android-a', text: 'A 的慢任务' })
    await a.client.waitFor((event) => event.type === 'task' && event.state === 'started')
    a.client.close()

    // 断线期间任务完成：结果进入 A 的离线缓存。
    await new Promise((resolve) => setTimeout(resolve, 300))

    // B 在线，B 自己的结果照常收到。
    b.client.sendJSON({ type: 'command', request_id: 'req-b', client_id: 'android-b', text: 'B 的问题' })
    const bResponse = await b.client.waitFor((event) => event.type === 'response', { timeoutMs: 4000 })
    assert.equal(bResponse.message.request_id, 'req-b')

    // A 重连：补发自己的结果。
    const again = await connectAgent(port, { clientId: 'android-a' })
    const replayed = await again.client.waitFor((event) => event.type === 'response', { timeoutMs: 4000 })
    assert.equal(replayed.message.request_id, 'req-a')
    assert.equal(replayed.message.origin_client_id, 'android-a')
    // A 不该看到 B 的私有结果。
    assert.equal(
      again.client.messages.some((message) => message.json?.request_id === 'req-b'),
      false,
    )
    again.client.close()
  } finally {
    a.client.close()
    b.client.close()
    await bridge.close()
  }
})

test('/api/agent：取消只承诺停止等待，不宣称远程任务已终止', async () => {
  const service = createFakeAgentService({ delayMs: 200 })
  const { bridge, port } = await startServer({ service })
  const { client } = await connectAgent(port)
  try {
    client.sendJSON({ type: 'command', request_id: 'req-cancel', client_id: 'android-1', text: '慢任务' })
    await client.waitFor((event) => event.type === 'task' && event.state === 'started')
    client.sendJSON({ type: 'cancel', request_id: 'req-cancel', client_id: 'android-1' })
    const interrupted = await client.waitFor((event) => event.type === 'task' && event.state === 'interrupted')
    assert.match(interrupted.message.text, /远程任务/)
    // 取消之后不再展示结果。
    await new Promise((resolve) => setTimeout(resolve, 350))
    assert.equal(client.messages.some((message) => message.json?.type === 'response'), false)
  } finally {
    client.close()
    await bridge.close()
  }
})

test('/api/agent：非法参数被拒绝（缺 request_id / 空文本）', async () => {
  const { bridge, port } = await startServer()
  const { client } = await connectAgent(port)
  try {
    client.sendJSON({ type: 'command', request_id: 'bad id!', text: '你好' })
    const badId = await client.waitFor((event) => event.type === 'error' && event.code === 'bad_request_id')
    assert.ok(badId)

    client.sendJSON({ type: 'command', request_id: 'req-empty', text: '   ' })
    const empty = await client.waitFor((event) => event.type === 'error' && event.code === 'empty_command')
    assert.ok(empty)
  } finally {
    client.close()
    await bridge.close()
  }
})

test('/api/agent：服务端 ASR 未就绪时，文本通道仍然健康', async () => {
  const service = createFakeAgentService()
  const { bridge, port } = await startServer({
    service,
    adapter: {
      async health() {
        return { ready: false, detail: 'sensevoice-local/failed' }
      },
    },
  })
  const { client } = await connectAgent(port)
  try {
    const health = await fetch(`http://127.0.0.1:${port}/api/health`, {
      headers: { Authorization: `Bearer ${TOKEN}` },
    })
    const body = await health.json()
    assert.equal(body.asr, false)
    assert.equal(body.agent.ready, true)

    client.sendJSON({ type: 'command', request_id: 'req-asr', client_id: 'android-1', text: '文本也能用' })
    const response = await client.waitFor((event) => event.type === 'response')
    assert.equal(response.message.display_text, '收到：文本也能用')
  } finally {
    client.close()
    await bridge.close()
  }
})
