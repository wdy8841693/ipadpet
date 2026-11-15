/**
 * 鲸鱼娘 DSH 宠物 · 设置页（浏览器端）
 *
 * 在 DSH 设置里注册一个「鲸鱼娘」节：改性格、唤醒词/应答、其它会话播报，
 * 查看 iPad 连接地址和令牌。数据来自 Host 半边的 /whalepet-api/ 接口
 * （同源 + 一次性令牌握手），保存后立即生效，不需要重启插件。
 */
window.__ModuleLoader__.load({
  id: '@dywu/whalepet-dsh-bridge',
  factory(require) {
    const React = require('react')
    const h = React.createElement
    const { useCallback, useEffect, useRef, useState } = React
    const NS = 'whalepet-settings'

    const zh = {
      nav: '鲸鱼娘',
      title: '鲸鱼娘 DSH 宠物',
      subtitle: '改人设、唤醒词和播报方式；保存后下一次对话立即生效。',
      personaLabel: '性格设定',
      personaHint: '写给模型的人设（system prompt）。回答会被 TTS 念出来，建议保留「口语化、1~3 句、不用 Markdown」这类要求。',
      wakePhraseLabel: '唤醒词',
      wakePhraseHint: 'iPad 上直接喊这个词唤醒；改完需要 iPad 重新连接才生效。',
      wakeAckLabel: '唤醒应答',
      wakeAckHint: '只喊唤醒词时宠物回的一句；留空则不回应。',
      announceLabel: '其它会话播报',
      announceHint: 'GUI / 其它 agent 开的任务开始、结束、需要授权时，也让宠物播报一句。',
      replyCharsLabel: '完成播报字数',
      replyCharsHint: '其它会话任务完成时，播报里带多少字的回复摘要；0 = 只报「做完了」。',
      save: '保存',
      saving: '保存中…',
      saved: '已保存，立即生效',
      reset: '恢复默认',
      resetAll: '全部恢复默认',
      resetDone: '已恢复默认',
      loadError: '设置读取失败',
      saveError: '保存失败',
      retry: '重试',
      loading: '读取中…',
      customized: '已自定义',
      connectionTitle: 'iPad 连接信息',
      connectionHint: '在 iPad 的「设置 → 语音服务器」里填这两个值。',
      addressLabel: '服务器地址',
      tokenLabel: '访问令牌',
      copy: '复制',
      copied: '已复制',
      noAddress: '暂未发现局域网地址（可用本机回环地址测试）',
      wakePhrasePending: '唤醒词改动会在 iPad 下次连接时生效',
      footer: '修改会写入 ~/.dsh/whalepet/settings.json，不影响其它 DSH 会话。',
      version: '插件版本',
    }
    const en = {
      nav: 'Whale girl',
      title: 'Whale girl DSH pet',
      subtitle: 'Tune the persona, wake word and announcements. Saves apply to the next turn immediately.',
      personaLabel: 'Persona',
      personaHint: 'System prompt for the pet. Replies are spoken by TTS, so keep requests such as “spoken Chinese, 1–3 sentences, no Markdown”.',
      wakePhraseLabel: 'Wake word',
      wakePhraseHint: 'Say this on the iPad to wake the pet. Takes effect after the iPad reconnects.',
      wakeAckLabel: 'Wake acknowledgement',
      wakeAckHint: 'One sentence the pet answers to a bare wake word. Leave empty to disable.',
      announceLabel: 'Announce other sessions',
      announceHint: 'Announce start, finish and approval prompts of tasks started in the GUI or by other agents.',
      replyCharsLabel: 'Reply excerpt length',
      replyCharsHint: 'How many characters of the final reply to speak when another session finishes; 0 = name only.',
      save: 'Save',
      saving: 'Saving…',
      saved: 'Saved and applied',
      reset: 'Restore default',
      resetAll: 'Restore all defaults',
      resetDone: 'Defaults restored',
      loadError: 'Failed to load settings',
      saveError: 'Failed to save',
      retry: 'Retry',
      loading: 'Loading…',
      customized: 'customized',
      connectionTitle: 'iPad connection',
      connectionHint: 'Enter these values under “Settings → Voice server” on the iPad.',
      addressLabel: 'Server address',
      tokenLabel: 'Access token',
      copy: 'Copy',
      copied: 'Copied',
      noAddress: 'No LAN address found (loopback works for local tests)',
      wakePhrasePending: 'Wake word changes apply when the iPad reconnects',
      footer: 'Changes are written to ~/.dsh/whalepet/settings.json and do not affect other DSH sessions.',
      version: 'Plugin version',
    }

    async function api(path, opts) {
      let token = window.__WHALEPET_TOKEN__
      const call = async () => {
        const res = await fetch('/whalepet-api/' + path, {
          method: (opts && opts.method) || 'GET',
          headers: { 'x-whalepet-token': token || '', 'content-type': 'application/json' },
          body: opts && opts.body ? JSON.stringify(opts.body) : undefined,
        })
        const data = await res.json().catch(() => ({}))
        return { res, data }
      }
      if (!token) {
        const hs = await fetch('/whalepet-api/handshake')
        const hd = await hs.json().catch(() => ({}))
        token = hd.token
        window.__WHALEPET_TOKEN__ = token
        if (!token) throw new Error('handshake failed')
      }
      let { res, data } = await call()
      if (res.status === 403) {
        // 插件重启后令牌会变：重新握手再试一次。
        window.__WHALEPET_TOKEN__ = undefined
        const hs = await fetch('/whalepet-api/handshake')
        const hd = await hs.json().catch(() => ({}))
        token = hd.token
        window.__WHALEPET_TOKEN__ = token
        if (!token) throw new Error('handshake failed')
        ;({ res, data } = await call())
      }
      if (!res.ok) throw new Error(data.error || 'HTTP ' + res.status)
      return data
    }

    const CSS = `
.wp-root{display:flex;flex-direction:column;gap:16px;padding:2px 2px 28px;color:var(--dsw-alias-label-primary);font-variant-numeric:tabular-nums;animation:wp-in .25s ease both}
.wp-root *{box-sizing:border-box}
@keyframes wp-in{from{opacity:0;transform:translateY(4px)}to{opacity:1;transform:none}}
.wp-head h2{font-size:17px;margin:0 0 4px}
.wp-head p{margin:0;color:var(--dsw-alias-label-secondary);font-size:13px;line-height:1.5}
.wp-card{border:1px solid var(--dsw-alias-border-default,color-mix(in srgb,var(--dsw-alias-label-secondary) 22%,transparent));border-radius:12px;padding:14px 16px;display:flex;flex-direction:column;gap:12px;background:color-mix(in srgb,var(--dsw-alias-label-primary) 2%,transparent)}
.wp-row{display:flex;flex-direction:column;gap:6px}
.wp-row-inline{flex-direction:row;align-items:center;justify-content:space-between;gap:12px}
.wp-label{font-size:13px;font-weight:600;display:flex;align-items:center;gap:8px}
.wp-badge{font-size:11px;font-weight:500;padding:1px 6px;border-radius:8px;background:color-mix(in srgb,var(--dsw-alias-brand-primary,#2f7dd1) 16%,transparent);color:var(--dsw-alias-brand-primary,#2f7dd1)}
.wp-hint{font-size:12px;color:var(--dsw-alias-label-secondary);line-height:1.5}
.wp-input,.wp-textarea{width:100%;border:1px solid var(--dsw-alias-border-default,color-mix(in srgb,var(--dsw-alias-label-secondary) 25%,transparent));border-radius:8px;background:var(--dsw-alias-bg-primary,transparent);color:inherit;font:inherit;font-size:13px;padding:8px 10px;outline:none}
.wp-input:focus,.wp-textarea:focus{border-color:var(--dsw-alias-brand-primary,#2f7dd1);box-shadow:0 0 0 2px color-mix(in srgb,var(--dsw-alias-brand-primary,#2f7dd1) 18%,transparent)}
.wp-textarea{min-height:150px;resize:vertical;line-height:1.6;font-family:inherit}
.wp-grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}
@media (max-width:640px){.wp-grid{grid-template-columns:1fr}}
.wp-actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.wp-btn{appearance:none;border:1px solid var(--dsw-alias-border-default,color-mix(in srgb,var(--dsw-alias-label-secondary) 25%,transparent));background:transparent;color:inherit;border-radius:8px;padding:6px 14px;font-size:13px;cursor:pointer;transition:background .15s,border-color .15s}
.wp-btn:hover{background:color-mix(in srgb,var(--dsw-alias-label-primary) 6%,transparent)}
.wp-btn:disabled{opacity:.5;cursor:default}
.wp-btn-primary{background:var(--dsw-alias-brand-primary,#2f7dd1);border-color:transparent;color:#fff}
.wp-btn-primary:hover{filter:brightness(1.06);background:var(--dsw-alias-brand-primary,#2f7dd1)}
.wp-note{font-size:12px;color:var(--dsw-alias-label-secondary)}
.wp-ok{font-size:12px;color:var(--dsw-alias-status-success,#16a34a)}
.wp-err{font-size:12px;color:var(--dsw-alias-status-danger,#dc2626)}
.wp-mono{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;word-break:break-all}
.wp-conn{display:flex;flex-direction:column;gap:8px}
.wp-conn-row{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.wp-pill{border:1px dashed var(--dsw-alias-border-default,color-mix(in srgb,var(--dsw-alias-label-secondary) 30%,transparent));border-radius:8px;padding:4px 8px;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12px;user-select:all}
.wp-footer{display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap;font-size:12px;color:var(--dsw-alias-label-secondary)}
`

    function WhaleIcon({ size = 16 }) {
      return h('svg', { width: size, height: size, viewBox: '0 0 16 16', fill: 'none', 'aria-hidden': true },
        h('path', { d: 'M2 9.2c0-2.5 2.1-4.4 4.7-4.4 1.6 0 2.9.7 3.8 1.8.5-.3 1.1-.5 1.7-.5 1.4 0 2.4.7 2.8 1.6.2.4-.2.8-.6.7-.5-.1-1 0-1.4.3.5.6.8 1.3.8 2 0 .6-.5 1.1-1.1 1.1H6.4C3.9 11.8 2 10.7 2 9.2Z', fill: 'currentColor' }),
        h('circle', { cx: 10.2, cy: 8.1, r: 0.55, fill: 'var(--dsw-alias-bg-primary,#fff)' }),
        h('path', { d: 'M5 12.2c.9 1 2.2 1.6 3.6 1.6', stroke: 'currentColor', strokeWidth: 1.1, strokeLinecap: 'round', opacity: 0.65 }),
      )
    }

    function Section(props) {
      const t = props.t
      const [data, setData] = useState(null)
      const [form, setForm] = useState(null)
      const [loading, setLoading] = useState(true)
      const [error, setError] = useState('')
      const [saving, setSaving] = useState(false)
      const [toast, setToast] = useState('')
      const [copied, setCopied] = useState('')
      const toastTimer = useRef(null)
      const showToast = useCallback((message) => {
        setToast(message)
        if (toastTimer.current) clearTimeout(toastTimer.current)
        toastTimer.current = setTimeout(() => setToast(''), 2600)
      }, [])
      useEffect(() => () => { if (toastTimer.current) clearTimeout(toastTimer.current) }, [])

      const applyPayload = useCallback((payload) => {
        setData(payload)
        setForm({
          voicePersona: payload.settings.voicePersona ?? '',
          wakePhrase: payload.settings.wakePhrase ?? '',
          wakeAck: payload.settings.wakeAck ?? '',
          announceOtherSessions: payload.settings.announceOtherSessions !== false,
          announceReplyChars: String(payload.settings.announceReplyChars ?? 80),
        })
      }, [])

      const load = useCallback(async () => {
        setLoading(true)
        setError('')
        try {
          applyPayload(await api('settings'))
        } catch (err) {
          setError(String(err && err.message ? err.message : err))
        } finally {
          setLoading(false)
        }
      }, [applyPayload])

      useEffect(() => { void load() }, [load])

      const patch = (key, value) => setForm((prev) => (prev ? { ...prev, [key]: value } : prev))

      const save = useCallback(async () => {
        if (!form || saving) return
        setSaving(true)
        setError('')
        try {
          const payload = await api('settings', {
            method: 'POST',
            body: {
              patch: {
                voicePersona: form.voicePersona,
                wakePhrase: form.wakePhrase,
                wakeAck: form.wakeAck,
                announceOtherSessions: Boolean(form.announceOtherSessions),
                announceReplyChars: Number(form.announceReplyChars) || 0,
              },
            },
          })
          applyPayload(payload)
          showToast(t('saved'))
        } catch (err) {
          setError(String(err && err.message ? err.message : err))
          showToast(t('saveError'))
        } finally {
          setSaving(false)
        }
      }, [form, saving, applyPayload, showToast])

      const resetOne = useCallback(async (key) => {
        setSaving(true)
        try {
          applyPayload(await api('reset', { method: 'POST', body: { keys: [key] } }))
          showToast(t('resetDone'))
        } catch (err) {
          setError(String(err && err.message ? err.message : err))
        } finally {
          setSaving(false)
        }
      }, [applyPayload, showToast])

      const resetAll = useCallback(async () => {
        setSaving(true)
        try {
          applyPayload(await api('reset', { method: 'POST', body: {} }))
          showToast(t('resetDone'))
        } catch (err) {
          setError(String(err && err.message ? err.message : err))
        } finally {
          setSaving(false)
        }
      }, [applyPayload, showToast])

      const copy = useCallback(async (text, tag) => {
        try {
          await navigator.clipboard.writeText(text)
          setCopied(tag)
          setTimeout(() => setCopied(''), 1800)
        } catch {
          // 忽略：用户可手动选中复制
        }
      }, [])

      const overrides = data?.overrides ?? {}
      const connection = data?.connection
      const addresses = connection?.addresses ?? []
      const primaryAddress = addresses[0] || (connection ? `http://${connection.host}:${connection.port}` : '')
      const version = data?.status?.version ?? ''

      if (loading && !form) {
        return h('div', { className: 'wp-root' }, h('p', { className: 'wp-note' }, t('loading')))
      }
      if (!form) {
        return h('div', { className: 'wp-root' },
          h('p', { className: 'wp-err' }, t('loadError') + ': ' + error),
          h('div', { className: 'wp-actions' },
            h('button', { className: 'wp-btn', onClick: () => void load() }, t('retry'))))
      }

      return h('div', { className: 'wp-root' },
        h('style', null, CSS),
        h('div', { className: 'wp-head' },
          h('h2', null, t('title')),
          h('p', null, t('subtitle'))),

        error ? h('p', { className: 'wp-err' }, error) : null,

        h('div', { className: 'wp-card' },
          h('div', { className: 'wp-row' },
            h('div', { className: 'wp-label' }, t('personaLabel'),
              overrides.voicePersona !== undefined ? h('span', { className: 'wp-badge' }, t('customized')) : null),
            h('p', { className: 'wp-hint' }, t('personaHint')),
            h('textarea', {
              className: 'wp-textarea',
              spellCheck: false,
              value: form.voicePersona,
              placeholder: data?.defaults?.voicePersona ?? '',
              onChange: (event) => patch('voicePersona', event.target.value),
            }),
            h('div', { className: 'wp-actions' },
              h('button', { className: 'wp-btn', disabled: saving, onClick: () => void resetOne('voicePersona') }, t('reset'))) ),

          h('div', { className: 'wp-grid' },
            h('div', { className: 'wp-row' },
              h('div', { className: 'wp-label' }, t('wakePhraseLabel'),
                overrides.wakePhrase !== undefined ? h('span', { className: 'wp-badge' }, t('customized')) : null),
              h('input', {
                className: 'wp-input',
                value: form.wakePhrase,
                onChange: (event) => patch('wakePhrase', event.target.value),
              }),
              h('p', { className: 'wp-hint' }, t('wakePhraseHint'))),
            h('div', { className: 'wp-row' },
              h('div', { className: 'wp-label' }, t('wakeAckLabel'),
                overrides.wakeAck !== undefined ? h('span', { className: 'wp-badge' }, t('customized')) : null),
              h('input', {
                className: 'wp-input',
                value: form.wakeAck,
                onChange: (event) => patch('wakeAck', event.target.value),
              }),
              h('p', { className: 'wp-hint' }, t('wakeAckHint'))) ),

          h('div', { className: 'wp-row wp-row-inline' },
            h('div', null,
              h('div', { className: 'wp-label' }, t('announceLabel'),
                overrides.announceOtherSessions !== undefined ? h('span', { className: 'wp-badge' }, t('customized')) : null),
              h('p', { className: 'wp-hint' }, t('announceHint'))),
            h('input', {
              type: 'checkbox',
              checked: Boolean(form.announceOtherSessions),
              style: { width: 18, height: 18, cursor: 'pointer' },
              onChange: (event) => patch('announceOtherSessions', event.target.checked),
            })),

          h('div', { className: 'wp-row' },
            h('div', { className: 'wp-label' }, t('replyCharsLabel')),
            h('input', {
              className: 'wp-input',
              type: 'number',
              min: 0,
              max: 500,
              value: form.announceReplyChars,
              style: { maxWidth: 140 },
              onChange: (event) => patch('announceReplyChars', event.target.value),
            }),
            h('p', { className: 'wp-hint' }, t('replyCharsHint'))),

          h('div', { className: 'wp-actions' },
            h('button', { className: 'wp-btn wp-btn-primary', disabled: saving, onClick: () => void save() },
              saving ? t('saving') : t('save')),
            h('button', { className: 'wp-btn', disabled: saving, onClick: () => void resetAll() }, t('resetAll')),
            toast ? h('span', { className: 'wp-ok' }, toast) : null)),

        h('div', { className: 'wp-card' },
          h('div', { className: 'wp-label' }, t('connectionTitle')),
          h('p', { className: 'wp-hint' }, t('connectionHint')),
          h('div', { className: 'wp-conn' },
            h('div', { className: 'wp-conn-row' },
              h('span', { className: 'wp-note' }, t('addressLabel')),
              addresses.length
                ? addresses.map((address) => h('span', { className: 'wp-pill' }, address))
                : h('span', { className: 'wp-pill' }, primaryAddress),
              addresses.length
                ? h('button', { className: 'wp-btn', onClick: () => void copy(addresses[0], 'address') }, copied === 'address' ? t('copied') : t('copy'))
                : null),
            h('div', { className: 'wp-conn-row' },
              h('span', { className: 'wp-note' }, t('tokenLabel')),
              h('span', { className: 'wp-pill' }, connection?.token || '—'),
              connection?.token
                ? h('button', { className: 'wp-btn', onClick: () => void copy(connection.token, 'token') }, copied === 'token' ? t('copied') : t('copy'))
                : null)),
          h('p', { className: 'wp-hint' }, t('wakePhrasePending'))),

        h('div', { className: 'wp-footer' },
          h('span', null, t('footer')),
          h('span', null, version ? `${t('version')} v${version}` : '')))
    }

    return {
      inject: ['slots', 'locale'],
      apply(ctx) {
        ctx.effect(() => ctx.locale.register(NS, { zh, en }), 'whalepet-settings: dictionaries')
        const t = ctx.locale.bind(NS)
        ctx.slots.inject('settings.section', () => ctx.slots.register({
          name: 'settings.section', id: 'whalepet', order: 27,
          label: () => t('nav'),
          locale: NS,
        }, (props) => h(Section, { ...props, t })))
        ctx.slots.inject('settings.section.icon', () => ctx.slots.register({
          name: 'settings.section.icon', id: 'whalepet',
        }, WhaleIcon))
      },
    }
  },
})