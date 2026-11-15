# WhalePet DSH 局域网网关（DSH Host 插件）

把 iPad mini 4 上 **WhalePet（鲸鱼娘）** 的语音/文本请求，直接接进**这台机器上正在运行的 DSH**。

```
iPad App ──WS(16kHz PCM)──▶ 本插件（Host 内，0.0.0.0:8787）
                              ├─ ctx.speechToText    SenseVoice（本地 CPU，官方语音服务）
                              ├─ 唤醒词匹配 / 会话状态机
                              └─ ctx.sessionController  官方会话：create → prompt → wait
                                        │
iPad 本地 TTS ◀── response 文本 ─────────┘（音频不下发）
```

和仓库里 `Server/` 的 Python 桥接相比，这一版的定位完全不同：

| | Python 桥接（Server/） | 本插件 |
|---|---|---|
| 运行形态 | 独立进程 + 独立 `DSH_HOME` | 住在工作 DSH 进程里 |
| 语音识别 | 自带 faster-whisper | 复用 DSH 的 SenseVoice（`ctx.speechToText`） |
| 会话 | 官方 Python SDK 拉起独立 runtime | 官方 `ctx.sessionController`，宠物会话出现在 DSH 会话列表 |
| iPad 协议 | `/api/health` `/api/chat` `WS /api/audio` | **完全一致，iPad 端不用改代码** |

## 安装

在 DSH 里用 `plugin_manager` 安装本目录（绝对路径），或用 Web 侧栏 Plugins 页：

```
plugin_manager { action: "install_bundle",
                 target: "/home/dywu/Samba/workspace/ipadpet/Plugin/whalepet-dsh-bridge" }
```

安装会改 profile 的 `package.json`（加依赖 + bundle 列表），**不会**改 `cordis.patch.yml`；卸载用
`plugin_manager { action: "remove_bundle", target: "@dywu/whalepet-dsh-bridge" }`。

依赖：本 profile 必须启用语音输入 bundle（`speech-to-text` 行、`defaultProvider: sensevoice-local`）与
Web 会话控制器（`@deepseek-ai/dsh-api-session-controller`）。插件只 `inject` 这两项，**不重复插入它们**。

## 配置

`cordis.patch.yml` 里给了默认值，profile 的 patch 可按 id 覆盖：

| 键 | 默认 | 说明 |
|---|---|---|
| `host` | `0.0.0.0` | 监听地址；只想本机调试就改 `127.0.0.1` |
| `port` | `8787` | 与 iPad 设置里的端口一致；0 表示内核分配（测试用） |
| `language` | `zh` | 传给 `ctx.speechToText` 的语言提示 |
| `wakePhrase` / `wakeAliases` | `小鲸小鲸` + 同音别名 | 唤醒词表 |
| `permissionPreset` | `workspace-write` | 宠物会话的权限预设：能读写自己的工作目录、跑命令、检索；写 `''` 表示不改预设 |
| `approvalPolicy` | `never` | 仅在 `permissionPreset` 为空时生效：`never` 自动拒绝审批（语音场景没人点批准） |
| `requestTimeoutMs` | `300000` | 单次 `wait` 的超时（Super Agent 任务可能跑几分钟） |
| `maxWaitMs` | `600000` | 单轮回答最长等待；超时把已生成的部分回复带回来 |
| `voicePersona` | 内置鲸鱼娘人格 | 自定义宠物人格（插在宠物会话自己的 scope 里，不影响其它会话） |
| `progressIntervalMs` | `8000` | 长任务期间给 iPad 发 `thinking` 心跳的间隔；0 关闭 |
| `mainSessionId` | `whalepet-session-main` | 宠物唯一的长期会话 id；所有 iPad 共用、重启复用 |
| `archiveWhenIdle` | `true` | 空闲时归档会话（DSH 列表里看不到），说话前自动取消归档 |
| `sessionTitle` | `🐋 鲸鱼娘（自动维护，不用管）` | 会话标题，只写一次 |
| `dataDir` | `~/.dsh/whalepet` | 令牌、会话映射、宠物会话工作目录的存放位置 |
| `preRollMs` / `silenceMs` / `maxUtteranceS` / `listenTimeoutS` | `300 / 700 / 20 / 10` | VAD 切句与聆听超时 |
| `vadFloorDbfs` / `vadMarginDb` / `vadOnsetFrames` | `-55 / 10 / 2` | 能量 VAD 调参 |
| `token` / `tokenFile` | 空 / `<dataDir>/ipad-token` | 访问令牌；缺省时首次启动自动生成 0600 文件 |

**令牌获取**：首次启动后看 `<dataDir>/ipad-token`（默认 `~/.dsh/whalepet/ipad-token`），
填进 iPad 的「设置 → 访问令牌」。不要在配置里写明文令牌，更不要提交进 git。

## iPad 侧

1. ⚙️ 设置 → 服务器地址填 `http://<这台机器的局域网 IP>:8787`，令牌填上面的内容。
2. 保存并测试（`GET /api/health` 返回 `{"ok":true,"asr":true,...}` 即通）。
3. 说「小鲸小鲸」唤醒，再说命令；也可以一句话带命令。

宠物会话默认落在 `~/.dsh/whalepet/workspace`，会以普通会话出现在 DSH 会话列表里，可以点进去翻看。

## 协议（与 Python 桥接一致）

所有请求带 `Authorization: Bearer <token>`。

- `GET /api/health` → `{"ok":true,"asr":bool,"model":"sensevoice-local/ready"}`
- `POST /api/chat` `{"session_id":"pet-001","text":"..."}` → `{"ok":true,"reply":"..."}`
- `WS /api/audio`：首条 `{"type":"hello","session_id":"pet-001",...}`；控制消息 `manual_start` /
  `cancel` / `playback_start` / `playback_end`；其余二进制帧 = 16kHz / 单声道 / 小端 Int16 PCM。
  服务端事件：`ready` / `state(waiting|listening|thinking|speaking)` / `wake` / `transcript` /
  `thinking` / `response` / `error`。

## 不用管理会话

宠物**只有一个长期会话**（`whalepet-session-main`），像 Super Agent 一样一直在，没有"新建对话"的概念：

- 所有 iPad / 全部客户端共用这一个会话，历史连续；插件重启也不用重新建；
- 空闲时把会话**归档**：DSH 会话列表里看不到它；下一次说话前自动取消归档，说完再归档；
- 会话标题自动写成「🐋 鲸鱼娘（自动维护，不用管）」，只写一次；
- 早期按设备随机建的 `whalepet-session-<uuid>` 旧会话会被**自动归档**（不删除，可手动恢复）；
- 会话变长由 DSH 的自动压缩处理，不需要人工清理。

## 像 Super Agent 一样工作

宠物会话就是**完整的 DSH Agent**，不是一个小聊天机器人：

- 能调用工具：读写文件、跑命令、检索网页、多步执行，长任务由 `maxWaitMs` 兜住（默认 10 分钟）；
- 权限默认 `workspace-write`：能写的地方只有它自己的工作目录 `~/.dsh/whalepet/workspace`，碰不到系统其它部分；
- 人格提示注册在**宠物 Agent 自己的 scope** 里：要求它用工具真的做完，再用 1~3 句口语汇报；
- 回复会经 `toSpeechText()` 去掉 Markdown/链接/代码块，TTS 念出来是正常中文；
- 长任务期间插件每 8 秒发一个 `thinking` 事件，iPad 上鲸鱼娘会一直保持「思考中」，不会像断线。

## 关键设计

- **零第三方依赖**：只用 `node:*` + 注入的 DSH 服务；WebSocket 是手写的最小 RFC6455 子集（`src/ws.js`），
  避免 link 安装插件解析不到 `ws` 包的问题。
- **不暴露 DSH Web（3080）**：`dsh web` 只监听 loopback 是官方有意为之（避免把 RCE 暴露到网络），
  本插件另开一个**只服务 iPad 协议**的端口，并强制 Bearer 校验（常数时间比较）。
- **官方 API，不碰内部实现**：转写走 `ctx.speechToText`，会话走 `ctx.sessionController`
  （create / prompt / wait），回复从 `wait().output.records` 里的 `assistant/message` 取文本。
- **会话被删自动重建**：映射持久化在 `sessions.json`；`session/not-found` 时换新会话重试一次。
- **串行化**：同一 iPad 会话的提问排队，避免两条语音同时塞进同一轮。

## 测试

```bash
cd Plugin/whalepet-dsh-bridge
node --test test/*.test.js
```

- `textnorm` / `session` / `vad` / `wav`：纯逻辑单测
- `bridge.test.js`：真 HTTP + 真 WebSocket 的传输层端到端（mock adapter）
- `index.test.js`：假 ctx 提供 DSH 服务的插件级集成测试（会话映射 / 审批策略 / 回复抽取 / 重建）

## 已知限制

- **不流式**：官方语音服务只支持整段录音转写，所以按句切分后整句送识别。
- **能量 VAD 而不是 WebRTC VAD**：安静室内够用；嘈杂环境可调 `vadFloorDbfs` / `vadMarginDb`；
  明显比 Python 桥接的 `webrtcvad` 弱一档，这是"零原生依赖"的代价。
- **审批**：默认 `workspace-write` 预设（沙箱限定在工作目录），需要额外批准的操作会落到
  `input-required`，语音端会提示「去 DSH 会话列表确认」。
- **人格 scope**：`agent.ctx.systemPrompt.section(...)` 是按调用方 scope 注册的，只影响宠物会话；
  插件卸载/会话重建时会 dispose。
- **无 TLS**：内网 HTTP + Bearer。要跨不可信网络请用 Tailscale/WireGuard，不要直接暴露公网。