/**
 * 设置存储 + 设置页 HTTP 接口的单元测试。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { EventEmitter } from 'node:events'
import os from 'node:os'
import path from 'node:path'

import { createSettingsStore, sanitizeSettings } from '../src/settings.js'
import { registerSettingsApi, lanAddresses } from '../src/settings-api.js'

const DEFAULTS = {
  voicePersona: '默认人设',
  wakePhrase: '小鲸小鲸',
  wakeAck: '我在',
  announceOtherSessions: true,
  announceReplyChars: 80,
}

async function tempDir() {
  return mkdtemp(path.join(os.tmpdir(), 'whalepet-settings-'))
}

function fakeReq({ method = 'GET', url, headers = {}, body, remote = '127.0.0.1' }) {
  const req = new EventEmitter()
  req.method = method
  req.url = url
  req.headers = headers
  req.socket = { remoteAddress: remote }
  process.nextTick(() => {
    if (body !== undefined) req.emit('data', Buffer.from(body))
    req.emit('end')
  })
  return req
}

function fakeRes() {
  return {
    statusCode: 200,
    headers: {},
    body: '',
    setHeader(key, value) {
      this.headers[key] = value
    },
    end(chunk) {
      this.body += chunk ?? ''
      this.onDone?.()
    },
  }
}

function call(spec, options) {
  return new Promise((resolve, reject) => {
    const res = fakeRes()
    res.onDone = () => resolve({ status: res.statusCode, body: JSON.parse(res.body || '{}') })
    Promise.resolve(spec.handler(fakeReq(options), res)).catch(reject)
  })
}

test('sanitizeSettings：只接受可编辑项并拒绝非法值', () => {
  assert.deepEqual(
    sanitizeSettings({ voicePersona: '  傲娇  ', wakeAck: '', announceReplyChars: 120.9 }),
    { voicePersona: '傲娇', wakeAck: '', announceReplyChars: 120 },
  )
  assert.throws(() => sanitizeSettings({ wakePhrase: '   ' }), /不能为空/)
  assert.throws(() => sanitizeSettings({ announceOtherSessions: 'yes' }), /必须是布尔值/)
  assert.throws(() => sanitizeSettings({ announceReplyChars: -1 }), /不小于 0/)
  assert.throws(() => sanitizeSettings({ port: 9999 }), /未知设置项/)
  assert.throws(() => sanitizeSettings(null), /必须是一个对象/)
})

test('settings store：覆盖默认值、原子持久化、重载后保留、可重置', async () => {
  const dir = await tempDir()
  const store = createSettingsStore({ dataDir: dir, defaults: DEFAULTS })
  await store.load()
  assert.equal(store.current().voicePersona, '默认人设')
  assert.deepEqual(store.overrides(), {})

  await store.update({ voicePersona: '傲娇人设', wakeAck: '' })
  assert.equal(store.current().voicePersona, '傲娇人设')
  assert.equal(store.current().wakeAck, '')
  // 未覆盖的项仍用默认值
  assert.equal(store.current().wakePhrase, '小鲸小鲸')

  const raw = JSON.parse(await readFile(path.join(dir, 'settings.json'), 'utf8'))
  assert.deepEqual(raw, { voicePersona: '傲娇人设', wakeAck: '' })

  // 模拟插件重启：重新读盘
  const again = createSettingsStore({ dataDir: dir, defaults: DEFAULTS })
  await again.load()
  assert.equal(again.current().voicePersona, '傲娇人设')

  // 只重置一项
  await again.reset(['voicePersona'])
  assert.equal(again.current().voicePersona, '默认人设')
  assert.equal(again.current().wakeAck, '')

  // 全部重置
  await again.reset()
  assert.deepEqual(again.overrides(), {})
  assert.equal((await readFile(path.join(dir, 'settings.json'), 'utf8')).trim(), '{}')
})

test('settings store：损坏的 settings.json 不致命，退回默认值', async () => {
  const dir = await tempDir()
  await writeFile(path.join(dir, 'settings.json'), '{oops', 'utf8')
  const store = createSettingsStore({ dataDir: dir, defaults: DEFAULTS })
  await store.load()
  assert.equal(store.current().voicePersona, '默认人设')
})

test('settings store：变更通知会触发（用于刷新人格）', async () => {
  const dir = await tempDir()
  const store = createSettingsStore({ dataDir: dir, defaults: DEFAULTS })
  await store.load()
  const seen = []
  const off = store.onChange((value) => seen.push(value.voicePersona))
  await store.update({ voicePersona: '元气' })
  off()
  await store.update({ voicePersona: '高冷' })
  assert.deepEqual(seen, ['元气'])
})

test('settings API：握手 → 读设置 → 保存 → 重置', async () => {
  const dir = await tempDir()
  await writeFile(path.join(dir, 'ipad-token'), 'lan-token-123', { mode: 0o600 })
  const store = createSettingsStore({ dataDir: dir, defaults: DEFAULTS })
  await store.load()

  let spec = null
  const ctx = {
    get(service) {
      if (service === 'webServer') {
        return {
          register(next) {
            spec = next
            return () => {}
          },
        }
      }
      return undefined
    },
  }
  const dispose = registerSettingsApi({
    ctx,
    store,
    config: { host: '0.0.0.0', port: 8787 },
    dataDir: dir,
    version: '0.3.0',
  })
  assert.equal(typeof dispose, 'function')
  assert.ok(spec, '应注册 /whalepet-api 路由')

  // 非 loopback 不给令牌
  const denied = await call(spec, { url: '/whalepet-api/handshake', remote: '192.168.1.20' })
  assert.equal(denied.status, 403)

  const hs = await call(spec, { url: '/whalepet-api/handshake' })
  assert.equal(hs.status, 200)
  const token = hs.body.token
  assert.ok(token && token.length >= 16)

  // 没带令牌 → 403
  const noAuth = await call(spec, { url: '/whalepet-api/settings' })
  assert.equal(noAuth.status, 403)

  const headers = { 'x-whalepet-token': token }
  const got = await call(spec, { url: '/whalepet-api/settings', headers })
  assert.equal(got.status, 200)
  assert.equal(got.body.settings.voicePersona, '默认人设')
  assert.equal(got.body.defaults.wakePhrase, '小鲸小鲸')
  assert.equal(got.body.connection.token, 'lan-token-123')
  assert.equal(got.body.connection.port, 8787)
  assert.equal(got.body.status.version, '0.3.0')

  // 保存
  const saved = await call(spec, {
    method: 'POST',
    url: '/whalepet-api/settings',
    headers,
    body: JSON.stringify({ patch: { voicePersona: '傲娇', announceReplyChars: 40 } }),
  })
  assert.equal(saved.status, 200)
  assert.equal(saved.body.settings.voicePersona, '傲娇')
  assert.equal(saved.body.settings.announceReplyChars, 40)
  assert.deepEqual(store.overrides(), { voicePersona: '傲娇', announceReplyChars: 40 })

  // 非法值 → 400
  const bad = await call(spec, {
    method: 'POST',
    url: '/whalepet-api/settings',
    headers,
    body: JSON.stringify({ patch: { wakePhrase: '' } }),
  })
  assert.equal(bad.status, 400)

  // 重置全部
  const reset = await call(spec, { method: 'POST', url: '/whalepet-api/reset', headers, body: '{}' })
  assert.equal(reset.status, 200)
  assert.deepEqual(store.overrides(), {})
})

test('lanAddresses 返回非回环 IPv4（可为空）', () => {
  const addresses = lanAddresses()
  assert.ok(Array.isArray(addresses))
  for (const address of addresses) {
    assert.match(address, /^\d+\.\d+\.\d+\.\d+$/)
    assert.ok(!address.startsWith('127.'))
  }
})