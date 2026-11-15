/**
 * ClientHub 单元测试：多客户端注册、单播、订阅广播、断线补发缓存、命令幂等。
 *
 * 架构依据：docs/CROSS_PLATFORM.md §9.2 / §8.5 / §8.7 / §8.9
 */

import test from 'node:test'
import assert from 'node:assert/strict'
import { ClientHub, parseEventSeq } from '../src/client-hub.js'

/** 假连接：记录收到的消息。 */
function fakeConnection() {
  return {
    closed: false,
    sent: [],
    send(payload) {
      this.sent.push(payload)
      return true
    },
    close() {
      this.closed = true
    },
  }
}

test('register：同一个 client_id 重连时旧连接失效', () => {
  const hub = new ClientHub()
  const first = fakeConnection()
  const second = fakeConnection()
  hub.register('android-1', first, { conversationId: 'whalepet-main' })
  hub.register('android-1', second, { conversationId: 'whalepet-main' })
  assert.equal(first.closed, true)
  assert.equal(hub.isOnline('android-1'), true)
  // 新连接能收到消息，旧连接收不到。
  hub.deliverTo('android-1', { type: 'response', text: 'hi' })
  assert.equal(second.sent.length, 1)
  assert.equal(first.sent.length, 0)
})

test('unregister：断线只移除在线连接，不删请求记录', () => {
  const hub = new ClientHub()
  const connection = fakeConnection()
  hub.register('android-1', connection, {})
  hub.beginRequest({ requestId: 'req-1', originClientId: 'android-1', text: '干活' })
  hub.unregister(connection)
  assert.equal(hub.isOnline('android-1'), false)
  assert.ok(hub.getRequest('req-1'))
})

test('deliverTo：私有回答只到发起设备', () => {
  const hub = new ClientHub()
  const a = fakeConnection()
  const b = fakeConnection()
  hub.register('android-a', a, {})
  hub.register('android-b', b, {})
  hub.deliverTo('android-a', { type: 'response', text: '只给 A' })
  assert.equal(a.sent.length, 1)
  assert.equal(b.sent.length, 0)
})

test('broadcast：只有订阅 announcements 的客户端收到全局通知', () => {
  const hub = new ClientHub()
  const subscriber = fakeConnection()
  const silent = fakeConnection()
  hub.register('android-a', subscriber, { subscriptions: { announcements: true } })
  hub.register('android-b', silent, { subscriptions: { announcements: false } })
  const delivered = hub.broadcast({ type: 'announcement', scope: 'global', state: 'finished', display_text: '做完了' })
  assert.equal(delivered, 1)
  assert.equal(subscriber.sent.length, 1)
  assert.equal(silent.sent.length, 0)
  assert.ok(subscriber.sent[0].event_id)
})

test('可靠事件：断线后重连按 last_received_event_id 补发', () => {
  const hub = new ClientHub()
  const connection = fakeConnection()
  hub.register('android-a', connection, {})
  hub.deliverTo('android-a', { type: 'response', text: '结果一' }, { reliable: true })
  const firstId = connection.sent[0].event_id
  hub.deliverTo('android-a', { type: 'response', text: '结果二' }, { reliable: true })
  const secondId = connection.sent[1].event_id

  // 断线后又收到一条（离线缓存）。
  hub.unregister(connection)
  hub.deliverTo('android-a', { type: 'response', text: '结果三' }, { reliable: true })

  const replayAll = hub.replay('android-a', null)
  assert.equal(replayAll.length, 3)
  const replayAfterFirst = hub.replay('android-a', firstId)
  assert.equal(replayAfterFirst.length, 2)
  assert.equal(replayAfterFirst[0].event_id, secondId)
  const replayAfterSecond = hub.replay('android-a', secondId)
  assert.equal(replayAfterSecond.length, 1)
  assert.equal(replayAfterSecond[0].display_text ?? replayAfterSecond[0].text, '结果三')
})

test('可靠事件缓存有条数上限', () => {
  const hub = new ClientHub({ maxReliableEvents: 3 })
  const connection = fakeConnection()
  hub.register('android-a', connection, {})
  for (let i = 0; i < 5; i += 1) {
    hub.deliverTo('android-a', { type: 'response', text: `r${i}` }, { reliable: true })
  }
  const replay = hub.replay('android-a', null)
  assert.equal(replay.length, 3)
  assert.equal(replay.at(-1).text, 'r4')
})

test('可靠事件缓存按 TTL 过期', () => {
  let clock = 1000
  const hub = new ClientHub({ now: () => clock, reliableTtlMs: 500 })
  const connection = fakeConnection()
  hub.register('android-a', connection, {})
  hub.deliverTo('android-a', { type: 'response', text: '旧的' }, { reliable: true })
  clock += 1000
  assert.equal(hub.replay('android-a', null).length, 0)
})

test('命令幂等：同一 request_id 只登记一次', () => {
  const hub = new ClientHub()
  const first = hub.beginRequest({ requestId: 'req-1', originClientId: 'android-a', text: '干活' })
  const second = hub.beginRequest({ requestId: 'req-1', originClientId: 'android-a', text: '干活' })
  assert.equal(first, second)
  assert.equal(hub.requests.size, 1)
  hub.completeRequest('req-1', { response: { type: 'response', text: 'done' } })
  assert.equal(hub.getRequest('req-1').state, 'done')
  assert.equal(hub.runningRequests('android-a').length, 0)
})

test('parseEventSeq：从事件 id 里取序号', () => {
  assert.equal(parseEventSeq('evt-000123'), 123)
  assert.equal(parseEventSeq('evt-000001'), 1)
  assert.equal(parseEventSeq(null), 0)
})
