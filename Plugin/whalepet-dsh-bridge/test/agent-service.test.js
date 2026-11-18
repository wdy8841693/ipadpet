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
      if (next.kind === 'question') {
        return {
          reason: 'input-required',
          state: { cursor: pending.cursor, pendingInput: ['question'] },
          output: { records: [] },
        }
      }
      if (next.kind === 'timeout') {
        // 与真实 gateway 一致：wait 会阻塞到超时（没有 delayMs 时按请求的 timeoutMs）。
        const delay = next.delayMs ?? request.timeoutMs
        if (delay) {
          await new Promise((resolve) => setTimeout(resolve, delay))
        }
        return {
          reason: 'timeout',
          state: { cursor: pending.cursor },
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

test('execute：当前任务失败后不会重新执行第二次', async () => {
  const { sessions } = createFakeSessions()
  const originalPrompt = sessions.prompt.bind(sessions)
  let attempts = 0
  sessions.prompt = async (request) => {
    attempts += 1
    if (attempts === 1) throw new Error('prompt failed')
    return originalPrompt(request)
  }
  const service = new AgentCommandService({
    sessions,
    queueKey: () => 'pet-main',
    resolveConversation: async () => ({ sessionId: 'pet-session' }),
  })
  await assert.rejects(service.execute({
    requestId: 'r-fail-once',
    conversationId: 'c',
    text: '有副作用的命令',
  }), /prompt failed/)
  assert.equal(attempts, 1, '当前任务失败只能执行一次，队列 catch 不得误捕获自身错误')
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

test('execute：长任务执行期按间隔播报进度，结束后给出结果', async () => {
  // 三次 wait：两次 timeout（任务仍在跑）+ 一次给出结果。
  const { sessions } = createFakeSessions({
    script: [
      { kind: 'timeout', delayMs: 80 },
      { kind: 'timeout', delayMs: 80 },
      { text: '整理好了' },
    ],
  })
  const events = []
  const service = new AgentCommandService({
    sessions,
    queueKey: () => 'pet-main',
    resolveConversation: async () => ({ sessionId: 'pet-session' }),
    progressIntervalMs: 50,
  })
  const result = await service.execute({
    requestId: 'r-progress',
    conversationId: 'c',
    text: '整理资料',
    notify: (event) => events.push(event),
  })
  assert.equal(result.displayText, '整理好了')
  const progress = events.filter((event) => event.state === 'progress')
  assert.equal(progress.length, 2, '两次长等待各播一条进度')
  assert.ok(progress.every((event) => typeof event.text === 'string' && event.text.length > 0))
  // queued/started 由 channel 层发；这里只验证 service 的进度心跳。
  assert.deepEqual(events.map((e) => e.state).filter(Boolean), [
    'started', 'progress', 'progress',
  ])
})

test('execute：长等待按进度间隔切片，不会一次 wait 阻塞到 maxWait（回归）', async () => {
  // 真实 gateway 的 wait 会一直阻塞到 timeoutMs。如果仍用 requestTimeoutMs（300s）
  // 作为单次等待，长任务期间一行进度都发不出来——这正是 macOS 桌宠「静默」的根因。
  const { sessions, calls } = createFakeSessions({
    script: [{ kind: 'timeout' }, { kind: 'timeout' }, { text: '整理好了' }],
  })
  const events = []
  const service = new AgentCommandService({
    sessions,
    queueKey: () => 'pet-main',
    resolveConversation: async () => ({ sessionId: 'pet-session' }),
    requestTimeoutMs: 300000,
    maxWaitMs: 600000,
    progressIntervalMs: 60,
  })
  const result = await service.execute({
    requestId: 'r-slice',
    conversationId: 'c',
    text: '整理资料',
    notify: (event) => events.push(event),
  })
  assert.equal(result.displayText, '整理好了')
  assert.ok(
    calls.wait.every((request) => request.timeoutMs <= 60),
    `单次 wait 不能长于进度间隔，实际：${calls.wait.map((r) => r.timeoutMs).join(',')}`,
  )
  assert.equal(events.filter((event) => event.state === 'progress').length, 2)
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

test('execute：需要回答时用 onQuestion 念出题目与选项，然后继续等到结束', async () => {
  const { sessions } = createFakeSessions({
    script: [
      { kind: 'question' },       // 第一次 wait：需要用户选择（只有 question，没有 approval）
      { text: '好的，按第一个方案来' },
    ],
  })
  let asked = 0
  let delivered = 0
  // 让 wait 返回 question 类型的 pendingInput
  const originalWait = sessions.wait.bind(sessions)
  sessions.wait = async (request) => {
    const value = await originalWait(request)
    if (value.reason === 'input-required') {
      return { ...value, state: { ...value.state, pendingInput: ['question'] } }
    }
    return value
  }
  const service = new AgentCommandService({
    sessions,
    queueKey: () => 'pet-main',
    resolveConversation: async () => ({ sessionId: 'pet-session' }),
    onQuestion: () => {
      asked += 1
      return '要把文件保存到哪个目录？选项：第一个 工作区，第二个 桌面；去 DSH 里选一下'
    },
    maxWaitMs: 60000,
  })
  const events = []
  const result = await service.execute({
    requestId: 'req-q1',
    conversationId: 'c',
    text: '保存文件',
    notify: (event) => {
      events.push(event)
      if (event.state === 'approval') delivered += 1
    },
  })
  assert.equal(asked, 1)
  assert.equal(delivered, 1)
  const approval = events.find((event) => event.state === 'approval')
  assert.match(approval.text, /要把文件保存到哪个目录/)
  assert.match(approval.text, /第一个 工作区/)
  assert.equal(result.displayText, '好的，按第一个方案来')
})

test('execute：onQuestion 拿不到题目时回落到通用提示', async () => {
  const { sessions } = createFakeSessions({
    script: [{ kind: 'input-required' }, { text: '完成' }],
  })
  const service = new AgentCommandService({
    sessions,
    queueKey: () => 'pet-main',
    resolveConversation: async () => ({ sessionId: 'pet-session' }),
    onQuestion: () => '',
    maxWaitMs: 60000,
  })
  const events = []
  await service.execute({
    requestId: 'req-q2',
    conversationId: 'c',
    text: '做点事',
    notify: (event) => events.push(event),
  })
  const approval = events.find((event) => event.state === 'approval')
  assert.ok(approval)
  assert.match(approval.text, /需要你/)
  assert.doesNotMatch(approval.text, /选项：/)
})
