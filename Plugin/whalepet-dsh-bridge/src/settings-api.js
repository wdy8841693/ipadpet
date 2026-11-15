/**
 * 设置页的 Host 侧 HTTP 接口（挂在 DSH 自己的 webServer 上，和 Web UI 同源）。
 *
 * 路由前缀 /whalepet-api：
 *   GET  handshake  → 仅 loopback 可拿一次性令牌（页面首屏用）
 *   GET  settings   → 当前设置 + 默认值 + iPad 连接信息
 *   POST settings   → 保存（只允许 EDITABLE_KEYS），立即生效、不重启插件
 *   POST reset      → 恢复默认（可只重置某些键）
 *
 * 所有业务请求必须带 x-whalepet-token；令牌每次插件启动随机生成。
 */
import { randomBytes } from 'node:crypto'
import { promises as fsp } from 'node:fs'
import { networkInterfaces } from 'node:os'
import path from 'node:path'
import { EDITABLE_KEYS } from './settings.js'

export const API_PREFIX = '/whalepet-api'
const MAX_BODY_BYTES = 64 * 1024

const sendJson = (res, status, body) => {
  res.statusCode = status
  res.setHeader('content-type', 'application/json; charset=utf-8')
  res.setHeader('cache-control', 'no-store')
  res.end(JSON.stringify(body))
}

const isLoopback = (address) => {
  const value = String(address ?? '')
  return value === '' || value === '127.0.0.1' || value === '::1' || value === '::ffff:127.0.0.1'
}

/** 读请求体（限制大小，防止设置页被当成上传口）。 */
const readBody = (req) =>
  new Promise((resolve, reject) => {
    let size = 0
    const chunks = []
    req.on('data', (chunk) => {
      size += chunk.length
      if (size > MAX_BODY_BYTES) {
        reject(new Error('请求体过大'))
        req.destroy()
        return
      }
      chunks.push(chunk)
    })
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString('utf8').trim()
      if (!raw) return resolve({})
      try {
        resolve(JSON.parse(raw))
      } catch {
        reject(new Error('请求体不是合法 JSON'))
      }
    })
    req.on('error', reject)
  })

/** 本机可用于 iPad 连接的 IPv4 地址（排除回环）。 */
export function lanAddresses() {
  const result = []
  try {
    for (const entries of Object.values(networkInterfaces())) {
      for (const entry of entries ?? []) {
        if (entry.family !== 'IPv4' || entry.internal) continue
        result.push(entry.address)
      }
    }
  } catch {
    // 忽略
  }
  return result
}

/**
 * @param {object} options
 * @param {import('@deepseek-ai/cordis').Context} options.ctx
 * @param {ReturnType<import('./settings.js').createSettingsStore>} options.store
 * @param {Record<string, unknown>} options.config  规范化后的插件 config
 * @param {string} options.dataDir
 * @param {string} options.version  插件版本（页面展示）
 * @param {{warn?: Function}} [options.logger]
 * @returns {() => void} disposer
 */
export function registerSettingsApi({ ctx, store, config, dataDir, version, logger }) {
  const webServer = typeof ctx.get === 'function' ? ctx.get('webServer') : undefined
  if (!webServer || typeof webServer.register !== 'function') return () => {}

  const apiToken = randomBytes(18).toString('hex')
  const tokenFile = path.join(dataDir, 'ipad-token')

  const connectionInfo = async () => {
    let token = ''
    try {
      token = (await fsp.readFile(tokenFile, 'utf8')).trim()
    } catch {
      // token 还没生成时留空
    }
    return {
      host: config.host,
      port: config.port,
      addresses: lanAddresses().map((address) => `http://${address}:${config.port}`),
      token,
    }
  }

  const settingsPayload = async () => ({
    settings: store.current(),
    defaults: store.defaults(),
    overrides: store.overrides(),
    editable: EDITABLE_KEYS,
    connection: await connectionInfo(),
    status: { version, pid: process.pid },
  })

  const handler = async (req, res) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1')
    const route = url.pathname.slice(API_PREFIX.length).replace(/^\/+/, '').replace(/\/+$/, '')
    const method = (req.method ?? 'GET').toUpperCase()

    if (route === 'handshake' && method === 'GET') {
      if (!isLoopback(req.socket?.remoteAddress)) return sendJson(res, 403, { error: 'unauthorized' })
      return sendJson(res, 200, { token: apiToken })
    }
    if (req.headers['x-whalepet-token'] !== apiToken) return sendJson(res, 403, { error: 'unauthorized' })

    try {
      if (route === 'settings' && method === 'GET') return sendJson(res, 200, await settingsPayload())

      if (route === 'settings' && method === 'POST') {
        const body = await readBody(req)
        const patch = body && typeof body === 'object' && body.patch && typeof body.patch === 'object'
          ? body.patch
          : body
        await store.update(patch)
        return sendJson(res, 200, { ok: true, ...(await settingsPayload()) })
      }

      if (route === 'reset' && method === 'POST') {
        const body = await readBody(req)
        const keys = Array.isArray(body?.keys) ? body.keys.filter((key) => EDITABLE_KEYS.includes(key)) : undefined
        await store.reset(keys)
        return sendJson(res, 200, { ok: true, ...(await settingsPayload()) })
      }

      return sendJson(res, 404, { error: 'not-found', route })
    } catch (error) {
      logger?.warn?.(`whalepet: 设置接口出错: ${error?.message ?? error}`)
      return sendJson(res, 400, { error: error?.message ?? String(error) })
    }
  }

  return webServer.register({ kind: 'prefix', path: API_PREFIX, handler })
}