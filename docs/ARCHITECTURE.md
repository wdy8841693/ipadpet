# 架构说明

## 一张图

```
┌──────────────────────────── iPad mini 4 · WhalePet App ────────────────────────────┐
│  SpriteKit 场景（宠物/背景/气泡/HUD）         VoiceController（AVAudioEngine + TTS）  │
│        ▲  状态动画/气泡                          ▲ 事件（ready/wake/state/task/...）  │
│        └──────────── PetScene ◀── PetViewController ──▶ DSHClient（URLSession）      │
└───────────────────────────────────────┬───────────────────────────────────────────┘
                                        │ HTTP: /api/health /api/chat
                                        │ WS  : /api/audio（16k mono PCM16）
                                        ▼
┌──────────────────────── DSH Host 插件 whalepet-bridge（0.0.0.0:8787）──────────────┐
│  传输层 src/server.js   · Bearer 鉴权（常数时间比较）                                 │
│                         · HTTP 路由 / WS 管线 / thinking 心跳 / access.log           │
│  语音层  src/legacy-audio.js + src/vad.js                                            │
│                         · 旧音频通道：能量 VAD + pre-roll 切句（20ms 帧，700ms 判停）│
│  理解层  src/textnorm.js + src/session.js · 唤醒词匹配、waiting/listening 相位机      │
│  新通道  src/agent-channel.js + src/client-hub.js                                    │
│                         · WS /api/agent：纯 JSON 文本命令与事件                      │
│                         · client_id 单播 / 订阅广播 / 断线补发 / request_id 幂等      │
│  执行层  src/agent-service.js · AgentCommandService                                  │
│                         · 新旧两条通道共用：排队 → prompt → wait → 回复提取            │
│  DSH 服务 ctx.speechToText（SenseVoice int8 + Silero VAD，本地 CPU，非流式）          │
│          ctx.sessionController（create / prompt / wait / rename）                    │
                                        ▼
┌──────────────────────────── 工作 DSH（web profile）─────────────────────────────────┐
│  宠物会话 whalepet-session-<日期桶>：完整的 Agent（工具 / 检索 / 文件 / 多步执行）    │
│  会话空闲时归档（列表不可见），说话前自动恢复；永久单会话 + 自动压缩兜底              │
└────────────────────────────────────────────────────────────────────────────────────┘
```

> 跨平台（Android / macOS / Windows）的目标架构见 [CROSS_PLATFORM.md](./CROSS_PLATFORM.md)：
> 新客户端走 `/api/agent` 文本通道，本地做 KWS/ASR/TTS，不再上传持续音频。

## 数据流

1. **唤醒**：App 采集 16kHz PCM 持续发送；插件按 20ms 帧过能量 VAD，切出一句话后送
   `ctx.speechToText.transcribe()`，文本经 `textnorm` 归一化后匹配唤醒词。
2. **命令**：识别文本若是「小鲸小鲸」→ 回 `STATE listening`；若是「小鲸小鲸 + 命令」→ 直接执行；
   聆听态下下一句即命令。
3. **执行**：只说唤醒词时插件先发 `response`「我在」，并在该轮 `playback_end` 后保持聆听态，
   用户可直接说指令；`ctx.sessionController.prompt()` 把命令塞进宠物会话；`wait()` 轮询到本轮结束，
   从 assistant 记录里取文本，经 `toSpeechText()` 去掉 Markdown 后回 `response`。
4. **播报**：App 用 `AVSpeechSynthesizer` 本地播报；播报期间发 `playback_start/end`，
   插件暂停拾音，避免自触发。

## 协议

所有 HTTP/WS 请求带 `Authorization: Bearer <token>`。

| 端 | 消息 | 说明 |
|---|---|---|
| HTTP | `GET /api/health` | `{"ok":true,"asr":bool,"model":"sensevoice-local/ready","version":"0.4.0","agent":{"ready":true},"protocols":["audio-v1","agent-v2"]}` |
| HTTP | `POST /api/chat` | `{"session_id","text"}` → `{"ok":true,"reply"}`；调试/文本备用通道 |
| WS | `hello`（文本 JSON） | `{"type":"hello","session_id":"pet-xxxx",...}`，触发建会话/预热 |
| WS | `manual_start` / `cancel` / `playback_start` / `playback_end` | 控制消息 |
| WS | 二进制帧 | 16kHz / 单声道 / 小端 Int16 PCM |
| WS→ | `ready` / `state` / `wake` / `transcript` / `thinking` / `response` / `error` | 语音流程事件 |
| WS→ | `task{state, text}` | 任务提醒：`started` / `approval` / `finished` / `failed` |

### 新文本通道 `WS /api/agent`（跨平台客户端）

| 方向 | 消息 | 说明 |
|---|---|---|
| → | `hello` | `{"type":"hello","protocol":2,"client_id":"android-7f2c91a0","conversation_id":"whalepet-main","subscriptions":{"announcements":true},"last_received_event_id":null}` |
| → | `command` | `{"type":"command","request_id":"req-...","client_id":"...","text":"...","source":"voice"}` |
| → | `cancel` | `{"type":"cancel","request_id":"req-...","client_id":"..."}` |
| ← | `ready` | `{"type":"ready","protocol":2,"agent_ready":true,"server_time":"..."}` |
| ← | `voice_config` | 唤醒词等语音配置（带 `revision`，变了才重建本地 KWS） |
| ← | `task{state}` | 私有任务事件：`queued` / `started` / `approval` / `interrupted` / `finished` / `failed` |
| ← | `response` | `{"display_text":"完整回答","speech_text":"适合播报","final":true}` |
| ← | `announcement` | 其它会话的全局通知，只发给订阅了 `announcements` 的客户端 |
| ← | `error` | `{"code":"...","message":"...","retryable":bool}` |

标识符约定：`client_id`（设备）、`conversation_id`（宠物会话）、`request_id`（一次命令）、
`event_id`（服务端事件，去重与补发用）四者**不能混用**。

### 多客户端路由

- **单播**：命令的私有回答、任务事件只发给 `origin_client_id`；`request_id` → 发起设备的映射
  记在 `ClientHub.requests` 里。
- **广播**：其它 DSH 会话的全局通知走 `announcement`，只发给握手里声明订阅的客户端；
  默认不缓存，避免重连时集中念过期通知。
- **幂等**：同一 `request_id` 只产生一次 DSH prompt（prompt 的 requestId 由它稳定派生）；
  重试时原样补发上次结果（`event_id` 不变，客户端可去重）。
- **断线补发**：断线不终止正在跑的 Agent；每客户端单独缓存可靠事件（`response` / `approval`），
  上限 100 条、TTL 24 小时；重连 `hello` 时按 `last_received_event_id` 补发。
- **取消**：只承诺「桥接层停止等待并忽略后续展示」，不向用户宣称远程 Agent 已终止。

## 会话策略

- **单一长期会话**：所有 iPad 共用 `whalepet-session-<时间桶>`，靠 `resolveAgent` 探测存在性，
  删除后用同一 id 重建，不会散出一堆会话。
- **空闲归档**：每轮结束把会话归档（DSH 列表不可见），下次说话前 `unarchiveSession` 恢复。
  归档态不能跑模型步，所以必须先恢复。
- **握手不归档**：`prepareSession()`（WS hello / 重连）只做准备，不轮换、不 archive。
  轮换与归档只在串行化的 `ask()` 内进行，避免重连把其它客户端正在跑的任务 `stopActivity` 掉。
- **默认永久单会话**：`rotateAfterHours: 0` 时始终使用 `mainSessionId`，上下文由
  `compaction-basic`（profile 已启用）自动压缩；把它设成 `>0` 才启用定时轮换（旧会话归档）。
  会话标题按 session id 记录，轮换后的新会话会重新命名。
- **授权**：`wait()` 返回 `input-required` 时发 `task{approval}` 提醒并**继续等待**；
  用户在 GUI 里点同意后任务自动接着跑，不需要重新下指令。

## 断线恢复

- iPad 端 `DSHClient` 自动重连：health 检查通过后重建 WebSocket，失败按 1/2/4/8/16/30s 退避，
  30s 封顶；恢复后重新握手并重启采集。
- 连续 10 次失败（约 3 分钟）后停止自动重连并转错误态；点麦克风按钮可重新连接
  （`disabled` 与 `error` 两种状态都触发重试）。
- 401/403（令牌错误）不重试，直接进入错误态，避免无意义请求。
- 服务器拒绝 WS 升级时先完整写出 HTTP 响应再关闭连接，避免客户端收到 `ECONNRESET`。
- **断线不丢任务**：连接断开时插件只停止发送、不 abort 正在跑的 ask；任务完成后结果进入
  `delivery.buffered`，新连接 `hello` 后补发 `task finished` + `response`（文案带「刚才断线了」）；
  重连时任务仍在跑则先发 `task interrupted`，完成后直接推给当前连接。

## 权限与安全

- 插件端口是独立的 8787，**不暴露 DSH Web（3080）**；3080 保持 loopback + nginx 反代给浏览器。
- 令牌 0600 落盘在 `~/.dsh/whalepet/ipad-token`，不进 git、不进插件配置。
- 宠物会话默认 `permissionPreset: workspace-write`：能读写 `~/.dsh/whalepet/workspace`，
  越界操作被沙箱拦住；把 `approvalPolicy` / `permissionPreset` 调整可以放宽或收紧。
- 8787 是明文 HTTP，只用于内网/ZeroTier，不要映射到公网。

## 设置页

- 浏览器端：`client.js` 通过 `window.__ModuleLoader__` 注册 `settings.section`（id `whalepet`）
  与对应图标，渲染表单；文案走 Client locale 服务（zh/en）。
- Host 端：`src/settings-api.js` 在 DSH 的 `webServer` 上挂 `/whalepet-api`，
  首屏 `handshake` 只放行 loopback 并返回一次性令牌，其余请求校验 `x-whalepet-token`。
- 存储：`src/settings.js` 把用户改动写进 `~/.dsh/whalepet/settings.json`（原子写、0600），
  运行时读取，优先级 `settings.json` > bundle config > 代码默认；人格变更会撤掉已注入的
  persona section，下一轮重新注入。

## 部署

- DSH 由 PM2 托管时，用 `Tools/deploy/dsh-web.sh` 直连本地安装的 dsh（不再每次 npx 解析 registry），
  `Tools/deploy/pm2-switch.sh` 是一次性切换脚本（带失败回退）。
- 插件通过 `plugin_manager install_bundle` 装进 profile（link 到本仓库目录），
  卸载用 `remove_bundle`。安装/开关会影响 profile 的 `package.json` 与 bundle 列表。

## 排障顺序

1. `ss -tln | grep 8787`：插件是否在监听；
2. `curl -H "Authorization: Bearer $(cat ~/.dsh/whalepet/ipad-token)" http://127.0.0.1:8787/api/health`：
   鉴权、版本、语音模型状态；
3. `~/.dsh/whalepet/access.log`：iPad 每次 health / chat / ws-upgrade 各一行（含来源 IP 与 auth 结果）；
4. `pm2 logs dsh` + `~/.dsh/sessions/--home-dywu-.dsh-whalepet-workspace--/<session>/`：
   会话是否建起来、有没有 turn/assistant 事件；
5. iPad 侧：服务器地址/令牌、本地网络权限、麦克风权限。

新文本通道排障：

```bash
# 不用 iPad 也能验 /api/agent：握手、命令、事件序列
node Tools/agent/client.js --text "帮我查一下明天的安排"
# 模拟拔线后重连补发
node Tools/agent/client.js --text "慢任务" --drop-after 300
```