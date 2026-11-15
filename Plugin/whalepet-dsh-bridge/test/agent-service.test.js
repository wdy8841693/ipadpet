/**
 * AgentCommandService 单元测试：排队、执行、幂等 requestId、授权等待、取消语义。
 *
 * 架构依据：docs/CROSS_PLATFORM.md §9.1 / §9.3 / §8.4 / §8.8
 */

import test from 'node:test'
import assert from 'node:assert/strict'
import { AgentCommandService, isSessionMissing } from '../src/agent-service.js'

function notFound() {
  const error = new Error('session/not-found')
  error.code = 'session/not-found'
  return error
}

/** 假的官方会话服务：可脚本化 wait 的返回。 */
function createFakeSessions({ script = [] } = {}) {
  const calls = { prompt: [], wait: [], state: [] }
  const pending = { text: '', cursor: 0 }
  const sessions = {
    async state() {
      calls.state.push(true)
      return { cursor: pending.cursor }
    },
    async prompt(request) {
      calls.prompt.push(request)
      pending.text = request.content[0].text
      pending.cursor += 1
      return { accepted: true }
    },
    async wait(request) {
      calls.wait.push(request)
      const next = script.shift() ?? {}
      if (next.kind === 'input-required') {
        return {
          reason: 'input-required',
          state: { cursor: pending.cursor, pendingInput: ['approval'] },
          output: { records: [] },
        }
      }
      if (next.delayMs) {
        await new Promise((resolve) => setTimeout(resolve, next.delayMs))
      }
      const text = next.text ?? `收到：${pending.text}`
      return {
        reason: 'idle',
        state: { cursor: pending.cursor },
        output: {
          records: [{
            type: 'event',
            event: {
              type: 'assistant/message',
              data: { message: { content: [{ type: 'text', text }] } },
            },
          }],
        },
      }
    },
  }
  return { sessions, calls, pending }
}

test('execute：返回原始回答与口语文本两套', async () => {
  const { sessions, calls } = createFakeSessions({
    script: [{ text: '## 结果\n\n- 已创建 **hello.txt**' }],
  })
  const service = new AgentCommandService({
    sessions,
    queueKey: () => 'pet-main',
    resolveConversation: async () => ({ sessionId: 'pet-session' }),
  })
  const result = await service.execute({ requestId: 'req-1', conversationId: 'whalepet-main', text: '建文件' })
  assert.equal(result.displayText, '## 结果\n\n- 已创建 **hello.txt**')
  assert.equal(result.speechText, '结果\n已创建 hello.txt')
  assert.equal(calls.prompt.length, 1)
  assert.equal(calls.prompt[0].content[0].text, '建文件')
})

test('execute：prompt 的 requestId 由客户端 request_id 稳定派生（重试不重复 prompt）', async () => {
  const { sessions, calls } = createFakeSessions()
  const service = new AgentCommandService({
    sessions,
    queueKey: () => 'pet-main',
    resolveConversation: async () => ({ sessionId: 'pet-session' }),
  })
  await service.execute({ requestId: 'req-42', conversationId: 'c', text: '第一句' })
  await service.execute({ requestId: 'req-42', conversationId: 'c', text: '第一句' })
  assert.equal(calls.prompt.length, 2)
  assert.equal(calls.prompt[0].requestId, calls.prompt[1].requestId)
  assert.match(calls.prompt[0].requestId, /req-42$/)
})

test('execute：同一会话的命令严格串行（顺序稳定）', async () => {
  const { sessions, calls } = createFakeSessions({
    script: [{ delayMs: 60, text: '第一个' }, { text: '第二个' }],
  })
  const service = new AgentCommandService({
    sessions,
    queueKey: () => 'pet-main',
    resolveConversation: async () => ({ sessionId: 'pet-session' }),
  })
  const first = service.execute({ requestId: 'r1', conversationId: 'c', text: 'A' })
  const second = service.execute({ requestId: 'r2', conversationId: 'c', text: 'B' })
  const [a, b] = await Promise.all([first, second])
  assert.equal(a.displayText, '第一个')
  assert.equal(b.displayText, '第二个')
  // 第二条 prompt 一定发生在第一条 wait 结束之后。
  assert.equal(calls.prompt[0].content[0].text, 'A')
  assert.equal(calls.prompt[1].content[0].text, 'B')
})

test('execute：会话被删后重建同一个 id 并重试一次', async () => {
  const { sessions, calls } = createFakeSessions()
  // 第一次 prompt 报「会话不存在」。
  const originalPrompt = sessions.prompt.bind(sessions)
  let attempts = 0
  sessions.prompt = async (request) => {
    attempts += 1
    if (attempts === 1) throw notFound()
    return originalPrompt(request)
  }
  const resolverCalls = { resolved: 0, prepared: 0, missing: 0, archived: [] }
  const service = new AgentCommandService({
    sessions,
    queueKey: () => 'pet-main',
    resolveConversation: async () => {
      resolverCalls.resolved += 1
      return {
        sessionId: 'pet-session',
        prepare: async () => {
          resolverCalls.prepared += 1
        },
        setArchived: async (archived) => {
          resolverCalls.archived.push(archived)
        },
        markMissing: () => {
          resolverCalls.missing += 1
        },
      }
    },
  })
  const result = await service.execute({ requestId: 'r-del', conversationId: 'c', text: '继续' })
  assert.equal(result.displayText, '收到：继续')
  assert.equal(attempts, 2)
  assert.equal(calls.prompt.length, 1)
  assert.equal(resolverCalls.resolved, 2)
  assert.equal(resolverCalls.missing, 1)
  assert.deepEqual(resolverCalls.archived, [true])
})

test('execute：input-required 时先通知授权，继续等待后返回结果', async () => {
  const { sessions, calls } = createFakeSessions({
    script: [{ kind: 'input-required' }, { text: '整理好了' }],
  })
  const events = []
  const service = new AgentCommandService({
    sessions,
    queueKey: () => 'pet-main',
    resolveConversation: async () => ({ sessionId: 'pet-session' }),
  })
  const result = await service.execute({
    requestId: 'r-approval',
    conversationId: 'c',
    text: '整理资料',
    notify: (event) => events.push(event),
  })
  assert.equal(result.displayText, '整理好了')
  const states = events.map((event) => event.state)
  assert.deepEqual(states, ['started', 'approval'])
  assert.ok(calls.wait.length >= 2)
})

test('execute：调用方取消只中断等待，底层任务继续跑完', async () => {
  const { sessions, calls } = createFakeSessions({ script: [{ delayMs: 120, text: '慢回复' }] })
  const service = new AgentCommandService({
    sessions,
    queueKey: () => 'pet-main',
    resolveConversation: async () => ({ sessionId: 'pet-session' }),
  })
  const controller = new AbortController()
  const pending = service.execute({
    requestId: 'r-cancel',
    conversationId: 'c',
    text: '慢任务',
    signal: controller.signal,
  })
  await new Promise((resolve) => setTimeout(resolve, 20))
  controller.abort(new Error('cancelled'))
  await assert.rejects(pending, (error) => error.name === 'AbortError')
  // 底层 prompt 已经发出，不会因为调用方放弃等待而消失。
  assert.equal(calls.prompt.length, 1)
})

test('isSessionMissing：识别会话不存在', () => {
  assert.equal(isSessionMissing(notFound()), true)
  assert.equal(isSessionMissing(new Error('boom')), false)
})
