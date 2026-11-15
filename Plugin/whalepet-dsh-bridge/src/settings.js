/**
 * 运行时设置存储：把「设置页」里可改的项存成 <dataDir>/settings.json。
 *
 * 这些值在插件运行时被读取（不重启插件），和 bundle patch 里的 config 关系是：
 *   settings.json（用户改过的项） > 插件 config（bundle 默认） > 代码内置默认值
 * 读写都做校验，写盘用「临时文件 + rename」保证原子性，权限 0600。
 */
import { promises as fsp } from 'node:fs'
import path from 'node:path'

export const SETTINGS_FILENAME = 'settings.json'

export const LIMITS = {
  personaChars: 8000,
  wakePhraseChars: 30,
  wakeAckChars: 60,
  replyChars: 500,
}

/** 设置页允许修改的键。 */
export const EDITABLE_KEYS = [
  'voicePersona',
  'wakePhrase',
  'wakeAck',
  'announceOtherSessions',
  'announceReplyChars',
]

const requireText = (key, value, { max = 0, allowEmpty = true } = {}) => {
  if (typeof value !== 'string') throw new Error(`${key} 必须是字符串`)
  const text = value.trim()
  if (!allowEmpty && !text) throw new Error(`${key} 不能为空`)
  if (max > 0 && [...text].length > max) throw new Error(`${key} 最多 ${max} 个字符`)
  return text
}

/**
 * 把外部输入收敛成可持久化的设置补丁；非法值抛错（调用方转成 400）。
 * @param {unknown} patch
 * @returns {Record<string, unknown>}
 */
export function sanitizeSettings(patch) {
  if (!patch || typeof patch !== 'object' || Array.isArray(patch)) {
    throw new Error('设置必须是一个对象')
  }
  const out = {}
  for (const [key, value] of Object.entries(patch)) {
    switch (key) {
      case 'voicePersona':
        out.voicePersona = requireText(key, value, { max: LIMITS.personaChars })
        break
      case 'wakePhrase':
        out.wakePhrase = requireText(key, value, { max: LIMITS.wakePhraseChars, allowEmpty: false })
        break
      case 'wakeAck':
        // 允许空字符串 = 关闭唤醒应答。
        out.wakeAck = requireText(key, value, { max: LIMITS.wakeAckChars })
        break
      case 'announceOtherSessions':
        if (typeof value !== 'boolean') throw new Error(`${key} 必须是布尔值`)
        out[key] = value
        break
      case 'announceReplyChars': {
        const n = Number(value)
        if (!Number.isFinite(n) || n < 0) throw new Error(`${key} 必须是不小于 0 的数字`)
        out[key] = Math.min(LIMITS.replyChars, Math.trunc(n))
        break
      }
      default:
        throw new Error(`未知设置项：${key}`)
    }
  }
  return out
}

/**
 * @param {object} options
 * @param {string} options.dataDir  运行数据目录（~/.dsh/whalepet）
 * @param {Record<string, unknown>} options.defaults  config 层默认值
 * @param {{warn?: Function}} [options.logger]
 */
export function createSettingsStore({ dataDir, defaults, logger }) {
  const file = path.join(dataDir, SETTINGS_FILENAME)
  /** 只存用户显式改过的项。 */
  let overrides = {}
  const listeners = new Set()

  const current = () => ({ ...defaults, ...overrides })

  const notify = () => {
    const value = current()
    for (const listener of listeners) {
      try {
        listener(value)
      } catch (error) {
        logger?.warn?.(`whalepet: 设置变更回调失败: ${error?.message ?? error}`)
      }
    }
  }

  const writeFile = async (value) => {
    await fsp.mkdir(dataDir, { recursive: true })
    const tmp = `${file}.tmp`
    await fsp.writeFile(tmp, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 })
    await fsp.rename(tmp, file)
  }

  return {
    file,
    /** 生效中的设置（config 默认 + 用户覆盖）。 */
    current,
    defaults: () => ({ ...defaults }),
    /** 用户显式改过的项（页面用来显示「已自定义」）。 */
    overrides: () => ({ ...overrides }),

    async load() {
      try {
        const raw = JSON.parse(await fsp.readFile(file, 'utf8'))
        overrides = sanitizeSettings(raw)
      } catch (error) {
        if (error?.code !== 'ENOENT') {
          logger?.warn?.(`whalepet: 读取 settings.json 失败，使用默认设置: ${error?.message ?? error}`)
        }
        overrides = {}
      }
      return current()
    },

    /** 合并保存（只写用户覆盖层），返回生效后的完整设置。 */
    async update(patch) {
      const clean = sanitizeSettings(patch)
      const next = { ...overrides, ...clean }
      await writeFile(next)
      overrides = next
      notify()
      return current()
    },

    /** 恢复默认：keys 省略时清空全部覆盖。 */
    async reset(keys) {
      const next = Array.isArray(keys)
        ? Object.fromEntries(Object.entries(overrides).filter(([key]) => !keys.includes(key)))
        : {}
      await writeFile(next)
      overrides = next
      notify()
      return current()
    },

    /** 订阅设置变更；返回取消订阅函数。 */
    onChange(listener) {
      listeners.add(listener)
      return () => listeners.delete(listener)
    },
  }
}