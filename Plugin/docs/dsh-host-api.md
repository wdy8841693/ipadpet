# DSH Host 插件 API 契约：语音转写 + 独立 Agent 会话 + HTTP/WS 传输

> 调研任务：task-1（只读调研）。调研时间 2026-11-15。
> 目标读者：要把 `ipadpet/Server`（Python 桥接）替换成**运行在工作 DSH 进程内的 cordis Host 插件**的开发者。
> 每个 API 都标注来源：`文件:行号`（相对 `$DSH` 或 `$PROFILE`，见下方路径别名），或 live service 契约（`cordis_inspect_query` 实测输出）。
> 代码片段是 TS/JS 混排，**语法可直接粘贴**；TS 类型标注只在编译期需要，运行时全部被擦除（插件可以写成纯 `.mjs`，见 §7）。

---

## 0. 路径别名与版本锚点

| 别名 | 实际路径 | 说明 |
|---|---|---|
| `$DSH` | `/home/dywu/.npm/_npx/b86ed90107c62dab/node_modules/@deepseek-ai` | **正在运行**的 DSH 安装树（0.2.2-rc.1） |
| `$DSHROOT` | `/home/dywu/.npm/_npx/b86ed90107c62dab` | 安装根（`package.json` 只依赖 `@deepseek-ai/dsh`） |
| `$PROFILE` | `/home/dywu/.dsh/profiles/web` | 工作 profile（含 `cordis.patch.yml` / `node_modules`） |
| `$OLD` | `/home/dywu/.npm/_npx/1e7f6d9597241db0/node_modules/@deepseek-ai` | **旧的** npx 缓存（0.2.1-rc.5），`$HOME/.dsh/profiles/node_modules/@deepseek-ai/*` 指向它 —— 见 §6.2 的坑 |

版本核对：
- `$DSH/dsh/package.json` → `"version": "0.2.2-rc.1"`；`$DSH/dsh-agent`、`dsh-agent-loop`、`dsh-session`、`dsh-llm`、`dsh-experimental-speech-to-text` 全部 `0.2.2-rc.1`。
- live 进程实测（`cordis_inspect_query(host, Service, listService)`）：`agents` / `agentLoop` / `speechToText` / `sessions` / `webServer` / `approval` / `agentPresets` 全部在线，且签名与 $DSH 下 d.ts 一致 → **读 $DSH 的 d.ts 就是读运行时契约**。
- 已有 profile 行：`$PROFILE/cordis.patch.yml:149-153`（`id: speech-to-text`，`name: @deepseek-ai/dsh-experimental-speech-to-text`，`defaultProvider: sensevoice-local`，`language: zh`）；`$DSH/dsh-experimental-voice-input-bundle/cordis.patch.yml` 还会插入 `speech-to-text-sensevoice`（`dataRoot: dshHomePath('speech-to-text','sensevoice')`）、`api-speech-to-text`、`ui-voice-input`；该 bundle 已在 `$PROFILE/package.json` 的 `dsh.profile.bundles` 里。

本地 SenseVoice 模型缓存已就绪（无需下载）：`/home/dywu/.dsh/speech-to-text/sensevoice/models/` 下有 `sensevoice-onnx/model.int8.onnx`（229 MB）、`tokens.txt`、`silero/silero_vad.onnx`（1.8 MB）。

---

## 1. 结论速览（TL;DR）

| 需求 | 结论 | 关键出处 |
|---|---|---|
| 在插件里建独立 Agent | `ctx.agents.create({ sessionId, agentOptions, meta:{cwd}, setup })` → `{ agent, dispose }` | `$DSH/dsh-agent/lib/types/index.d.ts:292`，`dsh-headless/lib/index.js:336-341` |
| SessionId | 自己造：`` SessionId(`pet-${randomUUID()}`) ``（brand 只影响类型） | `$DSH/dsh-session/lib/types/types.d.ts:5-12`，`dsh-headless/lib/index.js:333` |
| 提交一轮输入 | **`agent.followup(createUserMessage({...}))`** | `$DSH/dsh-agent/lib/types/runtime-types.d.ts:219`，`dsh-headless/lib/index.js:361-367` |
| 等这轮结束 | 监听 `ctx.on('session/event')` 的 `turn/end`（精确）；`agent.whenIdle()` 只能表示"整体空闲" | `dsh-headless/lib/index.js:356-358, 370`；`runtime-types.d.ts:191` |
| 读回复文本 | 监听 `assistant/message` 事件取 `data.message.content` 里的 `text` block；或 `agent.session.deriveMessages()` | `$DSH/dsh-session/lib/types/types.d.ts:338-346`，`dsh-session/lib/types/index.d.ts:343-355` |
| 语音转写 | `ctx.speechToText.resolve({audio})` → `transcribe(spec, signal)`；WAV 必须**严格** 16k/mono/PCM16 canonical | `$DSH/dsh-experimental-speech-to-text/lib/types/index.d.ts:83,90`，`.../wave.js:8-23` |
| 转写前要不要 prepare | 缓存完好时激活即 `standby`，可直接转写；`unprepared` 时必须 `prepare(id)` 并等到 `ready/standby` | `...-sensevoice/lib/index.js:631-663, 822-823` |
| 插件自己监听端口 | **可以**（Node 主进程，`node:http`/`node:net` 都能用） | `$DSH/dsh-host-webserver/lib/index.js:2, 490, 546` |
| `ws` 能否解析 | **能**：installation scope 里就有 `ws@8.22.1`；但插件 `package.json` 必须把 `ws` 和用到的 `@deepseek-ai/*` 写成 **peerDependencies** | 见 §6.2（`createRuntimeResolution` 实测 + `dsh-app-boot/lib/index.js:2462-2516`） |
| 是否复用 GUI 当前会话 | **不要**，见 §9 | `dsh-headless/lib/index.js:249-253` |

---

## 2. 创建 / 释放 Agent

### 2.1 三条创建路径的差别（先看这张表再选）

| API | 签名 | 归属（owner） | 能拿到 handle 吗 | 能传 setup 吗 | 建议 |
|---|---|---|---|---|---|
| **`ctx.agents.create(options)`** | `create(options: CreateAgentOptions): Promise<AgentHandle>` `$DSH/dsh-agent/lib/types/index.d.ts:292` | **调用方上下文的 fiber**（Cordis traced service：`this.ctx` 就是调用者 ctx）`$DSH/dsh-agent/lib/index.js:582-587` + cordis `lib/index.js:84-91`（"Wrap services/functions so method calls see the caller's active context"） | ✅ `{ agent, dispose() }` | ✅ | **推荐**：插件卸载时 agent 自动跟着销毁 |
| `ctx.agentLoop.createAgent(ownerCtx, options)` | `createAgent(ownerCtx: Context, options): Promise<AgentHandle>` `$DSH/dsh-agent-loop/lib/index.js:1668` | 你**显式**传的 `ownerCtx` | ✅ | ✅ | 需要"归属到某个子 context（例如每个 iPad 客户端一个 scope）"时才用 |
| `ctx.agentLoop.create(id, options, meta)` | `create(id, options = {}, meta = {}): Promise<Agent>` `$DSH/dsh-agent-loop/lib/index.js:1609-1630` | **agent-loop 服务自己的 fiber**（`this.ctx`） | ❌ 只有裸 Agent | ❌ | **不要用**：没有 handle、没 setup，agent 会活到进程结束 |

`AgentHandle` 定义：`$DSH/dsh-agent/lib/types/index.d.ts:145-148`

```ts
export interface AgentHandle { agent: Agent; dispose(): Promise<void> }
```

`dispose()` 的语义（同一处 JSDoc，131-144 行）："stops the loop, awaits its exit, unregisters the agent, removes its session from the store, and finally unwinds its scoped world."

### 2.2 `CreateAgentOptions` 全字段

`$DSH/dsh-agent/lib/types/index.d.ts:49-106`（逐条，含 live 校验：inspect 返回的 `CreateAgentOptions` 声明与之一致）：

```ts
export interface CreateAgentOptions {
  /** 唯一必需字段：agent 与 session 共用的活身份。 */
  readonly sessionId: SessionId
  /** 运行期父 agent（子 agent 才用）；宠物场景省略 = root agent。 */
  readonly parentAgent?: Agent
  /** 会话创建元数据（持久化，创建后不可改）。 */
  readonly meta?: {
    readonly cwd?: string                 // 必须是绝对路径，SessionStore 会校验
    readonly parentSession?: SessionId    // fork 血缘，宠物不用
    readonly isSeeded?: boolean
    readonly origin?: 'subagent'
    readonly delegationDepth?: number
    readonly agentPreset?: string         // 记录"这个会话由哪个 preset 组成"
  }
  /** fork 继承的事件前缀长度（配合 isSeeded）。 */
  readonly inheritedEventCount?: SessionLogOffset
  /** 回放/分叉种子事件（从 seq 0 连续）。 */
  readonly seed?: readonly SessionEvent[]
  /** 模型路由与输出控制；支持 getter 形式的活值（create 时捕获）。 */
  readonly agentOptions?: AgentOptions
  /** 仅创建期取消信号，返回 handle 前会脱离。 */
  readonly signal?: AbortSignal
  /** 创建期组合 agent 的 scoped world（装 model selection、mount preset、限制工具…）。 */
  readonly setup?: AgentSetup
}
```

`AgentOptions = { provider?, model?, reasoningEffort?, maxTokens? }`：`$DSH/dsh-agent/lib/types/runtime-types.d.ts:27-36`。

`AgentSetup = (agentCtx, agent) => AgentSetupCommit | Promise<...> | void`：`$DSH/dsh-agent/lib/types/index.d.ts:41`。setup 里的注册**全部先于** `agent/created` 与第一次 prompt 组装完成；抛错会整笔回滚（同一处 JSDoc 86-105 行）。

### 2.3 SessionId 怎么来

- 类型与运行时构造器：`$DSH/dsh-session/lib/types/types.d.ts:5-12` → `export type SessionId = Branded<'SessionId'>; export declare function SessionId(id: string): SessionId`。
- `Branded` 纯编译期：`$DSH/dsh-brand/lib/types/index.d.ts:14-28`（`brandString` 不改值）。
- 官方写法（headless 一次性 runner）：`const sessionId = brandString(config.sessionId ?? \`session-${randomUUID()}\`)` —— `$DSH/dsh-headless/lib/index.js:333`。
- Web GUI 的会话创建（最贴近"外部客户端建会话"的先例）：`brandString(\`session-${randomUUID()}\`)` —— `$DSH/dsh-api-session-controller/lib/index.js:421-423`。

**宠物用法**：给每个宠物/设备一个稳定 key（例如 `pet-001`）→ 自己映射成 `SessionId`；**不要**每个请求新建 session（会丢上下文）。重复 id 创建会抛：`session "<id>" already exists`（`$DSH/dsh-session/lib/index.js:1814,1872`）。

### 2.4 cwd

- `meta.cwd` 必须是绝对路径且是"validated absolute cwd"（`$DSH/dsh-agent/lib/types/index.d.ts:55-72`，`dsh-session/lib/types/index.d.ts:418-420`）；`api-session-controller` 还会先 `mkdir(cwd, {recursive:true})`（`$DSH/dsh-api-session-controller/lib/index.js:425-429`）。
- 官方两种取法：
  - headless：`const cwd = fs === undefined ? process.cwd() : fs.processPath(await fs.resolve('.'))`（`$DSH/dsh-headless/lib/index.js:334-335`）；
  - 或直接读布局默认值：`ctx.get('workingDirectory')?.defaultDirectory`（服务在线，签名 `readonly defaultDirectory: string`）。
- **宠物建议**：专用目录（例如 `/home/dywu/Samba/workspace/ipadpet/pet-workspace`），不要指向真实仓库，配合 read-only 权限。

### 2.5 模型选择

三种写法，按推荐顺序：

1. 启动时快照默认模型（headless 做法）：`const selection = ctx.agentDefaultModel.currentSelection(); agentOptions = { ...selection }`（`$DSH/dsh-headless/lib/index.js:322-323`；服务签名 `currentSelection(): ModelSelection`，live 已核对）。
2. getter 活值（GUI 会话做法，跟随用户在设置里改默认模型）：`{ get provider(){...}, get model(){...}, get reasoningEffort(){...} }` —— `$DSH/dsh-api-session-controller/lib/index.js:440-453`。
3. 会话内改：`agent.model.select({provider, model, reasoningEffort?})`（`$DSH/dsh-agent/lib/types/runtime-types.d.ts:47-63`）。`agent.model.current()` 读当前选择。

宠物场景：**推荐 1**（固定行为，可预测、可复现）；要跟随 GUI 默认值就用 2。

### 2.6 preset（可选，但要清楚代价）

- 服务在线：`ctx.get('agentPresets')`。关键方法：
  - `resolve(id?: string): Promise<AgentPreset>` —— 省略 id 取当前默认（`$DSH/dsh-agent-preset-registry/lib/index.js:612-616`，`const wanted = id ?? this.defaultId`）；
  - `mount(ctx: Context, id?: string): Promise<AgentPreset>` —— **只能在未发布的 agentCtx 里调用**，即 setup 回调（同文件 697-708 行）。
- 标准组合（GUI 会话创建完全相同）：`$DSH/dsh-api-session-controller/lib/index.js:264-277`
  （`installModelSelection` 来自 `@deepseek-ai/dsh-agent` —— 同文件 `lib/index.js:12`）

```js
// 摘自 $DSH/dsh-api-session-controller/lib/index.js:264-277（把 this.ctx 换成你的插件 ctx）
async function composeAgent(ctx, presetId) {
  const presets = ctx.get('agentPresets')
  if (presets === undefined) return { setup: (agentCtx) => { installModelSelection(agentCtx) } }
  const resolvedId = (await presets.resolve(presetId)).id
  return {
    agentPreset: resolvedId,
    setup: async (agentCtx) => {
      installModelSelection(agentCtx)
      await presets.mount(agentCtx, resolvedId)
    },
  }
}
```

- 本机可用 preset 有 `anchored-standard` / `router-spec` / `router-standard`（`/home/dywu/.dsh/.agent-presets/`）。
  ⚠️ **宠物不建议 mount 这些 preset**：它们是给编程 agent 的路由/工具编排，语义与"聊天宠物"无关，且 preset 出问题会让 `create()` 直接失败。
- **不 mount preset 的后果**：agent 用的是当前 composition 的基线工具集（dsh-base 那一套：bash/fs/…）。要收缩就用 §2.8 的 `tools.restrict`。

### 2.7 权限 / 审批（read-only）

两层，都要设：

1. **权限预设**（sandbox + approval 打包）：
   - 本部署的预设表（`$DSH/dsh-base/cordis.patch.yml:264-276`）：
     ```yaml
     presets:
       read-only:        { sandbox: read-only,        approval: ask }
       workspace-write:  { sandbox: workspace-write,  approval: ask }
       danger-full-access:{ sandbox: danger-full-access, approval: never }
     ```
     （行 id 是 `permission`，插件包 `@deepseek-ai/dsh-permission-presets`）
   - API：`ctx.permissionPresets.set(session: Session, name: string): void`（`$DSH/dsh-permission-presets/lib/types/index.d.ts:171-177`），`resolve(name)` 取 bundle（162），`current(session)` 读当前（153）。
   - 新建 agent 会自动 pin 默认预设：`ctx.on('agent/created', ...)` → `pinInitialPermission(agent.session)`（`$DSH/dsh-permission-presets/lib/index.js:193-195, 376`）。所以**建完立刻改**：

     ```js
     ctx.permissionPresets.set(agent.session, 'read-only')   // 未知名字会 throw
     ```
2. **审批策略**（`ask` | `never`）：`approval.setPolicy(agent: Agent, policy: ApprovalPolicy): void`（live 签名）+ `ApprovalPolicy = 'ask' | 'never'`（`$DSH/dsh-user-approval/lib/types/index.d.ts:54-63`）。
   - 宠物无人值守 → `never`（拒绝一切需要人工审批的调用），并配合 `read-only` 沙箱。

> 顺序注意：`permissionPresets.set` 会同时写 sandbox 与 approval 两个 knob（`$DSH/dsh-permission-presets/lib/types/index.d.ts:171-177`）。所以**先** `set(session,'read-only')`，再按需要 `approval.setPolicy(agent,'never')` 覆盖。

### 2.8 收缩工具面（可选但强烈建议）

`setup(agentCtx)` 里可以只给这个 agent 限制工具：

```js
ctx.tools.restrict({ allow: [] })        // 一个工具都不给（纯聊天）
ctx.tools.restrict({ deny: ['bash'] })   // 或按名字封掉危险工具
```

- 契约：`ctx.tools.restrict(filter: ToolRestriction): () => void`（live 签名）；**必须在 scoped ctx（`agent.ctx`）里调用**，否则抛 `tools.restrict() requires a scoped context`（`$DSH/dsh-tools/lib/index.js:453-455`）。
- 语义：`allow !== undefined && !allow.has(name)` → 拒绝（`$DSH/dsh-tools/lib/index.js:393`），所以 `allow: []` = 全关。
- 限制：命名未知工具会 throw（`$DSH/dsh-tools/lib/index.js:464-466`），所以要么给 `allow` 空数组，要么给确实存在的名字。

### 2.9 释放

三条路，任选且**都要能跑**：

1. **fiber 卸载自动**：因为是用 `ctx.agents.create()` 建的，`createAgent` 内部把它挂在 `ownerCtx.effect(...)` 上（`$DSH/dsh-agent-loop/lib/index.js:1522-1545`，关键行 1531 `unfollowOwner = ownerCtx.effect(function*(){...})`）。插件 row 停用/进程退出 → agent 自己停。
2. **显式**：`await handle.dispose()`。
3. **重启后接着聊**：`ctx.agents.resume({ resumeSessionId, agentOptions, setup })`（`$DSH/dsh-agent/lib/types/index.d.ts:111-130`）。本 profile 同时composed 了 `session-persistence-jsonl`（`$DSH/dsh-base/cordis.patch.yml:138-139`）与 `session-query-sqlite`（157-158），所以 resume 可用。**但**要注意 headless 记录的拒绝条件（`$DSH/dsh-headless/lib/index.js:224-231`）：preset 不匹配、`origin==='subagent'`、header 无 cwd、cwd 与当前不一致都会拒绝 —— 所以宠物 agent 创建时**固定 cwd**、**不 mount preset**，将来 resume 才顺。

> `dispose()` 只把 session 从**内存 store** 移除（JSDoc 131-144），durable jsonl 还在；下次 `resume` 能接着用。

---

## 3. 提交一轮用户输入

### 3.1 `UserMessage` 的确切结构

- 基类 `MessageBase`：`id`（`MessageId`，稳定身份）、`content`（`readonly ContentBlock[]`，模型可见块）、`source`（生产者声明）——`$DSH/dsh-llm/lib/types/message.d.ts:123-133`。
- `UserMessage extends MessageBase { readonly role: 'user' }` —— 同文件 143-146。
- **没有 `createdAt` 字段**（时间由 session 事件信封的 `time` 承担）。
- **`id` 不用自己生成**：用官方工厂 `createUserMessage({ content, source })`，它内部生成 id 并 `freeze`（`$DSH/dsh-llm/lib/types/message.d.ts:208-216`；实现里用 `MessageId(...)`）。手写对象也能跑（brand 只在类型层），但**推荐用工厂**——真实第三方插件也是这么做的：`@openviking/dsh-memory-plugin/capture.mjs:1,10-21`。
- `content` 的 text block：`{ type: 'text', text: string }`（`$DSH/dsh-llm/lib/types/types.d.ts:52-56`）；`ContentBlockMap` 全集见 121-129。
- `source`：`MessageSourceMap` = `{ user: {kind:'user'}, model: {kind,provider,model,...}, tool: {kind,callId}, 'system-prompt': {kind} }`（`$DSH/dsh-llm/lib/types/message.d.ts:101-122`）。**合并可扩展**：producer 可以自定义 `kind`（memory 插件就用 `plugin:openviking-memory`）。
  - 宠物建议 `{ kind: 'user' }`：语义最"正常"，下游（记忆、统计、GUI 展示）都当真人输入处理。
  - 若用自定义 kind，注意有消费者会把非 `user`/`tool` 的 user-role 消息当"合成上下文"跳过（`@openviking/dsh-memory-plugin/capture.mjs:29-39`）——即不写入长期记忆。

### 3.2 四种投递 API 的语义

全部在 `$DSH/dsh-agent/lib/types/runtime-types.d.ts:202-236`（Agent 的 live face）：

| API | 签名 | 语义 | 宠物场景 |
|---|---|---|---|
| **`followup(msg)`** | `followup(message: UserMessage): void`（219） | 排一轮**普通后续 turn** 并唤醒 driver；这条消息成为该 turn 的唯一普通消息。 | ✅ **推荐主路径** |
| `send(msg, target, wakeup)` | `send(message, target: InboxTarget, wakeup: boolean): void`（213） | 最底层：显式指定投递到 `'next-turn'` 或 `'next-step'`，并决定是否唤醒。 | 需要"塞进下一步/不唤醒"时才用 |
| `steer(msg)` | `steer(message): void`（227） | 插到**最近一步**（idle 时会开 turn）；用于打断/纠偏。 | 用户说"不要了/改成…"时用 |
| `inject(msg)` | `inject(message): void`（236） | 只排"下一步的模型上下文"，**不唤醒**；空闲时一直挂着。 | 给 agent 塞宠物人设/环境状态，不触发回答 |

> 语音助手正确姿势：**默认 `followup`**；用户打断/补充 → `steer`；系统级上下文（"现在时间是…"） → `inject`。

### 3.3 代码：造一条用户消息

```js
import { createUserMessage } from '@deepseek-ai/dsh-llm'

export function userTurn(text) {
  return createUserMessage({
    content: [{ type: 'text', text }],
    source: { kind: 'user' },
  })
}
```

---

## 4. 等待本轮结束并读回复

### 4.1 `whenIdle()` 到底保证什么

`$DSH/dsh-agent/lib/types/runtime-types.d.ts:185-191`：

> "Resolve after the current whole-agent activity reaches quiescence. This follows replacement work started before the observed driver retires, **but does not identify the settlement of any particular message**."

即：`whenIdle()` 回来时 agent 确实空闲了（turn 已提交），但如果你在它运行期间又 `followup` 了，它可能等到更晚才返回。headless 还加了一层收敛循环处理子 agent 与竞态（`$DSH/dsh-headless/lib/index.js:368-373`）：

```js
while (true) {
  await agent.whenIdle()
  const idleSeq = agent.session.seq
  if (!await subagents?.waitForChildren(agent) && agent.status === 'idle' && agent.session.seq === idleSeq) break
}
```

宠物场景（单 agent、无子 agent）：`await agent.whenIdle()` 足够 —— 但**要精确对应"我这条消息的回复"**，用 §4.2 的 `turn/end` 更好。

### 4.2 读最后一条 assistant 文本：三种路径

**(A) 推荐：监听 `ctx.on('session/event')`** —— `assistant/message` 累积、`turn/end` 收口。
事件签名：`'session/event'(this: Scoped<Session>, session: Session, event: SessionEvent): void`，post-commit、fire-and-forget（live 契约 + `$DSH/dsh-session` 事件文档）。
`assistant/message` 载荷：`$DSH/dsh-session/lib/types/types.d.ts:338-346`

```ts
'assistant/message': {
  turn: number
  step: number
  message: AssistantMessage
  stream: AssistantStreamRecord[]
  usage?: TokenUsage
  interrupted?: true
}
```

抽取文本的官方写法（headless 的 `summarize`）：`$DSH/dsh-headless/lib/index.js:129-132`

```js
const joined = event.data.message.content
  .filter((block) => block.type === 'text')
  .map((block) => block.text)
  .join('')
if (joined !== '') text = joined      // 只记最后一个非空 assistant 文本
```

turn 结束原因：`turn/end` 的 `data.reason` = `{kind:'completed'|'aborted'|'blocked'|'error'|'max-tokens'|'interrupted'|'forked'}`（`TurnEndReasonMap`，live 契约）。

**(B) 拉取式：`agent.session.deriveMessages()`** —— `$DSH/dsh-session/lib/types/index.d.ts:343-355`
"Derive the LLM message history by walking the ordered sequences of message-producing events maintained by `surfaceOp` markers … returns a fresh array of the shared, frozen derived history."
→ `whenIdle()` 之后取最后一个 `role === 'assistant'` 的消息即可。

**(C) 不要用：`session.eventAt(seq)` / `snapshotEvents()` / `ownEvents()`**
这三个在 d.ts 里已明确标 `@deprecated`（`$DSH/dsh-session/lib/types/index.d.ts:210-235`，JSDoc: "new calls are prohibited"）。headless 还在用（`lib/index.js:114-139`），但官方给的替代就是 surface/`deriveMessages()`。新插件别复制这个写法。

### 4.3 实时"打字机"（可选）

`ctx.on('agent/assistant-stream')` 提供过程内流式帧（`$DSH/dsh-agent/lib/types/runtime-types.d.ts:392-404`，`AssistantStreamFrame` = start/chunk/end，chunk 里 `type:'text-delta'` 有 `text`）。headless 用它把推理过程打到 stderr（`$DSH/dsh-headless/lib/index.js:148-198`）。
⚠️ 这些帧是**瞬态**的（可能重试/丢弃），只有 `assistant/message` 里的文本是已提交事实（`$DSH/dsh-headless/lib/json-stream-Dc3g2Bl1.js:6-9` 的模块注释写得很明确）。给 iPad 做"思考中"提示可以，但最终文本必须来自 (A)/(B)。

---

## 5. `ctx.speechToText` 语音转写

### 5.1 服务契约

来源：`$DSH/dsh-experimental-speech-to-text/lib/types/index.d.ts`（live 已核对一致）

```ts
class SpeechToText extends Service {
  listProviders(): readonly SpeechProviderInfo[]                  // :46
  follow(caller: AbortSignal): AsyncIterable<SpeechSnapshot>      // :53
  snapshot(): SpeechSnapshot                                      // :58   ← readiness 在这里
  configure(patch: SpeechSelectionPatch): Promise<void>           // :64   ← 会写 profile，别用
  prepare(id: SpeechProviderId, options?): void                   // :71
  cancelPreparation(id: SpeechProviderId): Promise<void>          // :77
  resolve(request: SpeechRequest): SpeechSpec                     // :83
  transcribe(spec: SpeechSpec, signal: AbortSignal): Promise<Transcript>  // :90
}
```

相关类型：`types.d.ts` 中
- `SpeechRequest { audio: Uint8Array; providerId?: SpeechProviderId; language?: string }`（120-124）
- `SpeechSpec extends SpeechInput { provider: SpeechProvider }`，`SpeechInput { audio: Uint8Array; language: string }`（96-100, 126-128）
- `Transcript { text: string; audioSeconds: number; inferenceSeconds: number }`（102-106，空串 = 没识别到语音）
- `SpeechSnapshot { providers: SpeechProviderView[]; selection: SpeechSelection }`（73-76）
- `SpeechProviderView.preparation: SpeechPreparationState`（59-61），phase 取值见 40-57：
  `unprepared | ready | standby | cancelled | downloading | checking | loading | waking | cancelling | failed`

`resolve()` 实现（`.../lib/types/index.js:150-154`）：按 `request.providerId ?? config.defaultProvider` 与 `request.language ?? config.language` 选 provider，**不支持的语言直接 throw**（`selectedProvider`，114-122）。本 profile 默认 `sensevoice-local` + `zh`，而 sensevoice 接受 `['auto','zh','en','yue','ja','ko']`（`...-sensevoice/lib/index.js:14-21`）→ 不传语言也能跑。

`transcribe()` 实现（`.../lib/types/index.js:161-180`）：只认 resolve 出来的那一个 provider，**不做回退**；provider 被注销则 throw `Resolved speech provider is no longer registered`。

### 5.2 WAV 必须是严格 canonical 16k/mono/PCM16

官方校验函数：`$DSH/dsh-experimental-speech-to-text/lib/types/wave.d.ts:1-8`，导出路径 `@deepseek-ai/dsh-experimental-speech-to-text/wave`（package.json `exports["./wave"]`）。实现 `.../wave.js:8-23` 的逐字节条件（**缺一不可**）：

| 条件 | 值 |
|---|---|
| 总长 | `>= 46` 字节 |
| 0..4 / 8..12 / 12..16 / 36..40 | `'RIFF'` / `'WAVE'` / `'fmt '` / `'data'` |
| fmt chunk 长度（off 16） | `16` |
| audioFormat（20） / channels（22） | `1` / `1` |
| sampleRate（24） / byteRate（28） | `16000` / `32000` |
| blockAlign（32） / bitsPerSample（34） | `2` / `16` |
| RIFF size（4） | `len - 8` |
| data size（40） | `len - 44` |
| 采样字节数 | `(len - 44) % 2 === 0` |
| 时长 | `<= maxDurationSeconds`（官方 API 层默认 120s，`...-api-speech-to-text/lib/index.js:136-139`） |

**权威用法**（官方 API 层，照它抄就不会错）：`$DSH/dsh-experimental-api-speech-to-text/lib/index.js:195-215`

```js
// 摘自 $DSH/dsh-experimental-api-speech-to-text/lib/index.js:203-209
function transcribe(ctx, request, signal) {
  validateWave(request.audio, MAX_AUDIO_SECONDS)
  const spec = ctx.speechToText.resolve({
    audio: request.audio,
    ...(request.providerId === undefined ? {} : { providerId: request.providerId }),
    ...(request.language === undefined ? {} : { language: request.language }),
  })
  return ctx.speechToText.transcribe(spec, signal)
}
```

### 5.3 sensevoice-local 的就绪状态机（重要）

- 插件激活时 `worker.inspect()`（`...-sensevoice/lib/index.js:948`）**只查磁盘缓存，不下载不加载**：
  - 缓存完整 → `phase: 'standby'`（631-663，关键 649-655）
  - 缺失 → `phase: 'unprepared'`
- **`transcribe()` 的前置门槛**（`...-sensevoice/lib/index.js:821-823`）：

  ```js
  const phase = this.state.phase
  if (phase !== 'ready' && phase !== 'standby')
    throw new Error('Prepare the local speech provider before recording')
  ```

  即：`standby` **可以**直接转写（会在转写里唤醒 worker，`waking`，`...-sensevoice/lib/index.js:766-770`、`795`），`unprepared` **必须**先 `prepare()`。
- `prepare()` 不会自己排队等待下载完成，它是"启动或加入"（`...-sensevoice/lib/index.js:668-675`）；要用 `follow()`/`snapshot()` 观察 phase 收敛到 `ready`/`standby`/`failed`。
- 本机缓存已齐（§0），因此正常路径是 `standby` → 直接转写；**但首次（或缓存被清）必须处理 `unprepared`**，否则第一条语音会报上面那句错。

### 5.4 判断"模型已就绪"的准确写法

```js
// phase 白名单见 dsh-experimental-speech-to-text/lib/types/types.d.ts:40-57
const READY = new Set(['ready', 'standby'])

/** 等 provider 就绪；unprepared 时启动准备，failed/cancelled 直接抛。 */
export async function ensureSpeechReady(ctx, providerId, signal) {
  const stt = ctx.speechToText
  for await (const snapshot of stt.follow(signal)) {
    const view = snapshot.providers.find((p) => p.id === providerId)
    if (view === undefined) throw new Error(`speech provider not registered: ${providerId}`)
    const prep = view.preparation
    if (READY.has(prep.phase)) return                    // 可以转写
    if (prep.phase === 'failed') throw new Error(`speech provider failed: ${prep.message}`)
    if (prep.phase === 'cancelled') throw new Error('speech preparation cancelled')
    if (prep.phase === 'unprepared') stt.prepare(providerId)  // 幂等：准备中会 join
    // checking / loading / waking / downloading / cancelling → 等下一帧
  }
  throw new Error('speech readiness observation ended')
}
```

`follow(caller)` 的语义：先给一帧当前快照，之后每次变化给最新快照（`.../lib/types/index.js:65-89`）；`caller` abort 即结束。

---

## 6. 传输层：插件自己开 HTTP + WebSocket

### 6.1 Host 插件能不能自己监听 TCP？——能

- 插件与 `dsh-host-webserver` 跑在**同一个 Node 主进程**；官方 webserver 就是这么干的：
  `$DSH/dsh-host-webserver/lib/index.js:2` `import { createServer } from 'node:http'`；`:490` `this.server = createServer(listener)`；`:546` `this.server.listen(this.config.port, this.config.host, cb)`；`:510` `this.server.on('upgrade', ...)`。
- `node:net` 同理可用（同进程无沙箱限制；本会话的 bash 沙箱只影响文件写入，不影响宿主进程能力）。
- ⚠️ **不要复用 `ctx.webServer` 给 iPad 用**：它的 host/port 来自 `webStartup`（默认 `127.0.0.1:3080`），且该行"rejects wildcard binds"（`$DSH/dsh-web-app/cordis.patch.yml:174-180`）——iPad 在局域网里连不上。
  它的升级挂载能力本身是好的：`ctx.webServer.registerUpgrade({ path, handler })`（live 签名 `WebSocketRouteHandler: (req, socket, head) => void|Promise<void>`，`$DSH/dsh-host-webserver/lib/index.js:384-395`），但仅限回环。
  → **结论：宠物插件自建 `0.0.0.0:8787`（沿用现有 Python 桥端口），iPad 端协议零改动。**

### 6.2 `ws` 包可解析吗？——能，但插件必须声明 peerDependencies

实测（用 DSH 自己的 `createRuntimeResolution` 跑本机真实 profile，只读）：

| 名称 | scope | 版本 | 绝对路径 |
|---|---|---|---|
| `ws` | installation | 8.22.1 | `/home/dywu/.npm/_npx/b86ed90107c62dab/node_modules/ws` |
| `@deepseek-ai/dsh-llm` 等全部 | installation | 0.2.2-rc.1 | `$DSH/<name>` |

上表的路径就是 `$DSHROOT/node_modules/ws`（8.22.1）；另外 `$PROFILE/node_modules/ws` 自带一份 8.21.3（profile 里别的插件在用）。

**解析规则**（`$DSH/dsh-app-boot/lib/index.js`）：
- 每个 profile 进程都会装一个运行时解析拦截器：`PluginPackages` 构造 → `installRuntimeInterception(resolution)`（4247-4257）；该服务由 `dsh` 启动器挂载：`$DSH/dsh/lib/profile-boot-e2mS45fC.js:307` `await hostCtx.plugin(PluginPackages, { resolution: composed.resolution })`。
- 被拦截的 importer 分三类（`findInterceptionLayer`，2123-2131）：
  1. **profile 目录内**（真装进 `$PROFILE/node_modules` 的包）→ 缺包时自动落到 installation 的副本（`routeScoped`，2450-2457）→ **不需要声明依赖**（官方 skill 文档也这么说："Packages shipped with dsh resolve from the dsh installation, so the bundle declares no dependencies on them" —— `$DSH/dsh-agent-preset/skills/cordis-plugin-development/SKILL.md`）。
  2. **linked root**（`link:` 进来的工作区目录，**本机绝大多数本地插件都是这种**）→ 走 `routeLinked`（2462-2516）：**只有当 import 方的 `package.json` 的 `peerDependencies` 里出现该包名**，才把请求路由到 installation 的副本（2470-2476 `readPeerNames(directory).has(name)` → `kind:'interception'`）；否则退化为原生解析（从插件真实路径往上找 `node_modules`）。
  3. 其它 → 原生解析。

- **实测反证**（Node 原生解析、无 DSH 拦截）：用 `/tmp` 下的等价布局复现「源码在别处 + symlink 进 profile」——`import '@deepseek-ai/fakepkg'`（包确实在 profile 的 node_modules 里）仍然 `ERR_MODULE_NOT_FOUND`，锚点是源码 realpath。本机 `/home/dywu/Samba/workspace/**` 一路向上都没有 `node_modules`，`link:` 插件若无 peer 声明就是这个结局。

- **本机真实先例**：`@openviking/dsh-memory-plugin`（profile 内真装）就 `import { createUserMessage } from '@deepseek-ai/dsh-llm'`，并在 package.json 里声明
  `peerDependencies: { "@deepseek-ai/dsh-llm": ">=0.1.0-rc.6 <1.0.0-0", "@deepseek-ai/dsh-mcp-client": ..., "@deepseek-ai/dsh-skill-filesystem": ... }`（该包 `package.json`）。`dsh-local-model` 同样写法。

**结论（插件 `package.json` 必须写）**：

```json
{
  "peerDependencies": {
    "@deepseek-ai/dsh-llm": "0.2.2-rc.1",
    "@deepseek-ai/dsh-session": "0.2.2-rc.1",
    "@deepseek-ai/dsh-agent": "0.2.2-rc.1",
    "@deepseek-ai/dsh-experimental-speech-to-text": "0.2.2-rc.1",
    "ws": "^8"
  }
}
```

- 不要写成 `dependencies`（profile `pnpm-workspace.yaml` 是 `autoInstallPeers: false`，写 deps 会真的去装/或装不上）。
- 想**彻底不依赖解析**：把 `createUserMessage` 换成手写消息对象（§3.1），把 `validateWave` 换成 20 行内联校验（§5.2），只用 `ctx.*` 服务 —— 这样插件一行 `@deepseek-ai/*` 都不用 import（本机 `@dywu/job-market-collector` 就是这样，它只 import `node:*`）。`ws` 仍是唯一外部依赖，但它是通用 npm 包，peer 声明即可。
- ⚠️ **别指望 `$PROFILE/node_modules` 或 `$HOME/.dsh/profiles/node_modules`**：后者的 `@deepseek-ai/*` 是 2026-09 的旧缓存 **0.2.1-rc.5** 的软链（`/home/dywu/.npm/_npx/1e7f6d9597241db0/...`），与运行中的 0.2.2-rc.1 不同版本，混用会出现服务/类型不匹配。

### 6.3 WebSocket 服务端可复用的实现

`$DSH/dsh-api-gateway/lib/index.js` 就是一个现成的"Host 内 WS 服务端"样板：

```js
// $DSH/dsh-api-gateway/lib/index.js:324-327（构造）+ :338-359（升级）
import { WebSocketServer } from 'ws'

const wss = new WebSocketServer({ noServer: true, perMessageDeflate: false })

httpServer.on('upgrade', (req, socket, head) => {
  wss.handleUpgrade(req, socket, head, (websocket) => {
    // websocket.on('message', ...) 里跑你自己的协议
  })
})
```

即：**`noServer: true` + 自己在 `http.Server` 的 `'upgrade'` 事件里把 socket 交出去**（与 6.1 的 webserver 同款模式）。心跳、`clients` 遍历、`terminate` 清理也都在同文件 361-390 行可参考。

**若不想依赖 `ws`**（例如插件被限制成只能 import `node:*`）：手写 RFC6455 服务端 ≈ 120 行（`Sec-WebSocket-Accept = base64(sha1(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))` + 帧解析/掩码 + ping/pong/close）。不建议作为第一版：iPad 侧现有协议用的是真 WS 客户端，帧处理出错难排查。

---

## 7. 可直接粘贴的三段代码

> 以下代码假设插件是 **`link:` 进 profile 的本地目录**（`plugin_manager install_bundle` 对本地目录就是 link），文件是 ESM `.mjs` 或 `.js`（`"type": "module"`），由 `cordis.patch.yml` 插入一行。

### 7.1 代码 A：创建 agent + 提交一轮 + 读回复

```js
// pet-agent.mjs
// 依赖（peerDependencies）：@deepseek-ai/dsh-llm、@deepseek-ai/dsh-session
import { randomUUID } from 'node:crypto'
import { createUserMessage } from '@deepseek-ai/dsh-llm'
import { SessionId } from '@deepseek-ai/dsh-session'

/**
 * 打开（或复用）一个宠物专属 Agent。
 * @param {import('@deepseek-ai/cordis').Context} ctx 插件上下文
 * @param {string} cwd 绝对工作目录
 */
export async function openPetAgent(ctx, cwd) {
  const sessionId = SessionId(`pet-${randomUUID()}`)
  const selection = ctx.agentDefaultModel.currentSelection()   // { provider, model, reasoningEffort? }
  const { agent } = await ctx.agents.create({
    sessionId,
    agentOptions: { ...selection },
    meta: { cwd },
    setup(agentCtx) {
      // 纯聊天宠物：一个工具都不给（allow: [] 语义见 dsh-tools/lib/index.js:393）
      try { agentCtx.tools?.restrict({ allow: [] }) } catch { /* 没有 tools 服务时忽略 */ }
    },
  })
  await agent.whenIdle()

  // 权限：先预设、后审批（§2.7）
  const presets = ctx.get('permissionPresets')
  if (presets !== undefined) presets.set(agent.session, 'read-only')
  const approval = ctx.get('approval')
  if (approval !== undefined) approval.setPolicy(agent, 'never')

  return agent
}

/**
 * 提交一轮用户输入，等这一轮真正结束，返回最后的 assistant 文本。
 * 用 session/event 的 turn/end 收口，比 whenIdle() 更精确（§4.1）。
 */
export function askOnce(ctx, agent, text, signal) {
  const session = agent.session
  const fromSeq = session.seq          // 本轮起点（SessionLogOffset，数字）
  const message = createUserMessage({
    content: [{ type: 'text', text }],
    source: { kind: 'user' },
  })

  return new Promise((resolve, reject) => {
    let lastText = ''
    const offs = []
    const cleanup = () => { for (const off of offs.splice(0)) { try { off() } catch {} } }
    const fail = (error) => { cleanup(); reject(error) }

    if (signal !== undefined) {
      if (signal.aborted) return fail(signal.reason ?? new Error('aborted'))
      const onAbort = () => fail(signal.reason ?? new Error('aborted'))
      signal.addEventListener('abort', onAbort, { once: true })
      offs.push(() => signal.removeEventListener('abort', onAbort))
    }

    offs.push(ctx.on('session/event', (subject, event) => {
      if (subject !== session) return
      if (event.seq < fromSeq) return
      if (event.type === 'assistant/message') {
        const joined = event.data.message.content
          .filter((block) => block.type === 'text')
          .map((block) => block.text)
          .join('')
        if (joined !== '') lastText = joined          // 只保留最后一个非空文本（headless 同法）
        return
      }
      if (event.type === 'turn/end') {
        cleanup()
        resolve({ text: lastText, reason: event.data.reason })
      }
    }))

    try { agent.followup(message) } catch (error) { fail(error) }
  })
}

/**
 * 拉取式兜底：whenIdle 之后从派生历史里取最后一条 assistant 文本。
 * （session.deriveMessages() 是未废弃 API：dsh-session/lib/types/index.d.ts:343-355）
 */
export async function lastAssistantText(agent) {
  await agent.whenIdle()
  const messages = agent.session.deriveMessages()
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i]
    if (m.role !== 'assistant') continue
    const text = m.content.filter((b) => b.type === 'text').map((b) => b.text).join('')
    if (text !== '') return text
  }
  return ''
}
```

### 7.2 代码 B：把一段 16k PCM 转成文本

```js
// pet-speech.mjs
// 依赖（peerDependencies）：@deepseek-ai/dsh-experimental-speech-to-text
import { validateWave } from '@deepseek-ai/dsh-experimental-speech-to-text/wave'

const READY = new Set(['ready', 'standby'])
const MAX_AUDIO_SECONDS = 120          // provider 侧 maxAudioBytes 4MB、时长上限对齐官方 API 层

/** 等 provider 就绪；unprepared 时启动准备；failed/cancelled 抛错。 */
export async function ensureSpeechReady(ctx, providerId, signal) {
  const stt = ctx.speechToText
  for await (const snapshot of stt.follow(signal)) {
    const view = snapshot.providers.find((p) => p.id === providerId)
    if (view === undefined) throw new Error(`speech provider not registered: ${providerId}`)
    const prep = view.preparation
    if (READY.has(prep.phase)) return
    if (prep.phase === 'failed') throw new Error(`speech provider failed: ${prep.message}`)
    if (prep.phase === 'cancelled') throw new Error('speech preparation cancelled')
    if (prep.phase === 'unprepared') stt.prepare(providerId)   // 幂等：准备中会 join
  }
  throw new Error('speech readiness observation ended')
}

/** 16kHz/mono/Int16LE 裸 PCM → canonical WAV（§5.2 的逐字节要求）。 */
export function pcm16ToWav(pcm, sampleRate = 16000) {
  if (pcm.byteLength % 2 !== 0) throw new Error('PCM16 byte length must be even')
  const out = new Uint8Array(44 + pcm.byteLength)
  const v = new DataView(out.buffer)
  const ascii = (offset, s) => { for (let i = 0; i < s.length; i++) v.setUint8(offset + i, s.charCodeAt(i)) }
  ascii(0, 'RIFF'); v.setUint32(4, 36 + pcm.byteLength, true); ascii(8, 'WAVE')
  ascii(12, 'fmt '); v.setUint32(16, 16, true); v.setUint16(20, 1, true); v.setUint16(22, 1, true)
  v.setUint32(24, sampleRate, true); v.setUint32(28, sampleRate * 2, true)
  v.setUint16(32, 2, true); v.setUint16(34, 16, true)
  ascii(36, 'data'); v.setUint32(40, pcm.byteLength, true)
  out.set(pcm, 44)
  return out
}

/**
 * 转写一段 WAV。
 * @param {Uint8Array} wav canonical 16k/mono/PCM16 WAV 字节
 * @returns {Promise<{text: string, audioSeconds: number, inferenceSeconds: number}>}
 */
export async function transcribeWav(ctx, wav, signal, options = {}) {
  validateWave(wav, MAX_AUDIO_SECONDS)                 // 官方校验，不合法直接 throw
  if (options.ensure !== false) {
    await ensureSpeechReady(ctx, options.providerId ?? 'sensevoice-local', signal)
  }
  const spec = ctx.speechToText.resolve({
    audio: wav,
    ...(options.providerId === undefined ? {} : { providerId: options.providerId }),
    ...(options.language === undefined ? {} : { language: options.language }),   // 省略则用 profile 的 zh
  })
  return await ctx.speechToText.transcribe(spec, signal)
}

/** 一步到位：PCM → WAV → 文本。 */
export async function transcribePcm(ctx, pcm, signal, options = {}) {
  return await transcribeWav(ctx, pcm16ToWav(pcm), signal, options)
}
```

只用 `ctx.*`、不 import 任何包的等价写法：把 `validateWave(wav, n)` 换成 §5.2 那张表的 20 行内联校验即可。

### 7.3 代码 C：插件 apply 骨架 + 卸载清理（HTTP/WS + agent）

```js
// index.js —— 插件入口（bundle 的 cordis.patch.yml 插入一行 name:'@local/dsh-pet-bridge'）
// 依赖（peerDependencies）：ws（+ 上面两段代码用到的 @deepseek-ai/*）
import { createServer } from 'node:http'
import { WebSocketServer } from 'ws'
import { openPetAgent } from './pet-agent.mjs'
import { transcribePcm } from './pet-speech.mjs'

export const name = 'pet-bridge'
export const inject = ['agents', 'sessions', 'speechToText']   // 硬依赖 -> ctx.xxx 直接可用

export async function apply(ctx, config) {
  const host = config.host ?? '0.0.0.0'
  const port = config.port ?? 8787
  const providerId = config.providerId ?? 'sensevoice-local'
  const cwd = config.cwd ?? '/home/dywu/Samba/workspace/ipadpet/pet-workspace'

  const agents = new Map()          // sessionKey -> Agent
  const wss = new WebSocketServer({ noServer: true })
  let httpServer
  let agentHandle

  const handler = (req, res) => {
    // ... /api/health、/api/chat 路由（沿用现有 Python 桥的 wire 协议）
    if (req.method === 'GET' && req.url === '/api/health') {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ ok: true, asr: true }))
      return
    }
    res.writeHead(404, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ ok: false, error: 'not found' }))
  }

  httpServer = createServer(handler)
  httpServer.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', 'http://pet')
    if (url.pathname !== '/api/audio') { socket.destroy(); return }
    wss.handleUpgrade(req, socket, head, (ws) => {
      ws.on('message', async (data, isBinary) => {
        // isBinary ? 累积 PCM : 处理 hello/manual_start/cancel/playback_* 控制帧
        // 端点检测出整段语音后：await transcribePcm(ctx, pcm, signal, { providerId })
      })
      ws.on('error', (error) => ctx.logger?.warn?.(error))
    })
  })

  // ① 端口监听：失败要让插件激活失败（async apply 抛错 = row 激活失败）
  await new Promise((resolve, reject) => {
    httpServer.once('error', reject)
    httpServer.listen(port, host, () => {
      httpServer.off('error', reject)
      httpServer.on('error', (error) => ctx.logger?.error?.(error))
      resolve()
    })
  })

  // ② 启动时建好宠物 agent（也可懒创建：第一次语音时再建，handle 存进 Map，清理遍历）
  agentHandle = await ctx.agents.create({ /* ...同 openPetAgent，但保留 handle 以显式释放 */ })

  // ③ 统一清理：注册顺序的逆序执行；unload 会 await 这里
  ctx.effect(() => async () => {
    for (const ws of wss.clients) { try { ws.terminate() } catch {} }
    await new Promise((resolve) => wss.close(() => resolve()))
    if (httpServer !== undefined) {
      const closed = new Promise((resolve) => httpServer.close(() => resolve()))
      httpServer.closeAllConnections()   // 立刻断开 keep-alive / 未升级连接（官方 webserver 同法）
      await closed
    }
    await agentHandle?.dispose()        // 停 loop → 注销 → 移出 session store → 回收 scope
    agentHandle = undefined
    agents.clear()
  }, 'pet-bridge')
}
```

关键点：
- **`apply` 可以是 async**：cordis 的 effect 执行器接受 thenable（`$DSHROOT/node_modules/@deepseek-ai/cordis/lib/index.js:429-461`，`"then" in effect` 分支），loader 会 await；`listen` 失败就在这里抛，row 变 `failed`。
- **清理顺序**：先断开客户端（否则 `server.close()` 会等连接）；再 `close()`+`closeAllConnections()`；最后 `agentHandle.dispose()`。官方 `dsh-host-webserver` 的关闭序列就是 `close()` → `closeAllConnections()` → 逐个 `destroy()` 已升级 socket（`$DSH/dsh-host-webserver/lib/index.js:555-569`），可对照。
- 若 agent 是懒创建的（第一次语音才建），把 handle 存进 Map，并在同一 effect 里遍历 `await h.dispose()`。

---

## 8. 插件形态与安装（与本任务相关的部分）

- Host 插件导出形状：`export function apply(ctx, config) {}` + 可选 `export const inject = [...]` + 可选 `export const Config`；或默认导出一个 Service 类。来源：`$DSH/dsh-agent-preset/skills/cordis-plugin-development/references/host-plugin.md:57-64`。
- 最小 manifest（Host-only 不需要 dependencies/构建）：同文件 5-27。
- 安装：`plugin_manager({action:'install_bundle', target:'<插件目录绝对路径>'})`（同 skill `SKILL.md`），**本地目录是 link 进 profile**（`references/host-plugin.md:35`）——所以 §6.2 的 peerDependencies 规则适用。
- 给插件行留 `config`（`port` / `cwd` / `providerId`），不要硬编码；需要持久化改配置用 `ctx.get('configEditor')`（`references/host-plugin.md:66-77`）。

---

## 9. 「不推荐 / 不可用」的路径与原因

| 路径 | 为什么不要用 |
|---|---|
| **复用 GUI 当前会话的 agent**（`ctx.agents.get(某个 id)` 然后 `followup`） | 你无法独占驱动权：headless 明确拒绝"本进程已存在持有该 id 的存活 Agent"的情况，因为"它的原 owner 可能仍在驱动它"（`$DSH/dsh-headless/lib/index.js:249-253`）。而且宠物消息会出现在用户正在看的 GUI 会话里，权限/审批/模型设置都属于用户那次会话，语义混乱。 |
| `ctx.agentLoop.create(...)`（2 参/3 参便捷版） | 归属 agent-loop 服务 fiber，没有 handle、没有 setup，不会随插件卸载而销毁（`$DSH/dsh-agent-loop/lib/index.js:1609-1630`）。 |
| `ctx.subagents.prompt(...)` 代替 | 它要求已存在的 `parentSessionId` + `childSessionId` + `mode:'continuable'`（`$DSH/dsh-subagent/lib/types/control-types.d.ts:78-95`），是"给已有子 agent 发消息"的远程控制面；`startActivation` 也需要父 Agent（`$DSH/dsh-subagent/lib/types/types.d.ts:25-38`）。宠物插件是 root agent，没有父。 |
| `session.eventAt()/snapshotEvents()/ownEvents()` 读回复 | d.ts 已标 `@deprecated`、"new calls are prohibited"（`$DSH/dsh-session/lib/types/index.d.ts:210-235`）。用 `session/event` 监听或 `deriveMessages()`。 |
| 用 `agent/assistant-stream` 的部分文本当最终回复 | 瞬态帧可能被重试/丢弃，只有 `assistant/message` 是已提交事实（`$DSH/dsh-headless/lib/json-stream-Dc3g2Bl1.js:6-9`、`dsh-agent/lib/types/runtime-types.d.ts:131-162, 392-404`）。 |
| 复用 `ctx.webServer` 给 iPad 供网 | 它绑定 `127.0.0.1:3080` 且拒绝 wildcard bind（`$DSH/dsh-web-app/cordis.patch.yml:174-180`，`dsh-host-webserver` README 同义）。iPad 局域网连不上。 |
| `ctx.speechToText.configure(...)` | 会把选择写进 profile 配置（`.../lib/types/index.js:104-113`，需要 settings 服务与 loader entry），副作用是改用户设置。宠物插件应该**只读**选择（`snapshot().selection` / `resolve()` 默认值）。 |
| 依赖 `$PROFILE/node_modules` 或 `~/.dsh/profiles/node_modules` 里的 `@deepseek-ai/*` | 后者是指向旧 npx 缓存 **0.2.1-rc.5** 的软链；与运行的 0.2.2-rc.1 版本不一致（§6.2）。 |
| 把 `@deepseek-ai/*` / `ws` 写进 `dependencies` 并期待 pnpm 去装 | profile `pnpm-workspace.yaml` 是 `autoInstallPeers: false`，且 link 包不参与 profile 安装；应该写 `peerDependencies` 走运行时拦截。 |
| mount 编程用的 preset（`router-*` / `anchored-standard`）给宠物 | preset 内部是路由/工具编排，与"聊天宠物"目标不符；mount 失败会让 `agents.create()` 整笔失败（§2.6）。 |

---

## 10. 还没验证 / 不确定（别当事实用）

1. **linked 插件的 `peerDependencies` 拦截没有端到端跑过。** 我验证了：`createRuntimeResolution`（DSH 自己导出的函数，对真实 profile）里 `ws` 与全部 `@deepseek-ai/*` 都是 `scope: "installation"`，且 `routeLinked` 的代码路径（`$DSH/dsh-app-boot/lib/index.js:2462-2516`）只在 `peerDependencies` 命中时路由到 installation 副本。但**没有**真的装一个插件并观察 import 成功（那会改 profile，违反本次任务约束）。实现时建议 10 分钟验证：写完插件 → `install_bundle` → 看激活日志/`cordis_inspect_query` 的 Config 目录里 row 是否 `schema`（能激活=import 成功）。
2. **`ctx.effect` 里 `wss.close()`/`server.close()` 的先后与超时**：Node 的 `server.close()` 在有活跃连接时不会立刻回调；代码里先 `terminate()` 客户端再 close 是照抄官方 webserver 的思路（`$DSH/dsh-host-webserver/lib/index.js:555-575` 的关闭序列），但**没有**在本机跑过。
3. **`agent.followup()` 在 turn 进行中的排队行为**：文档语义是"排一轮普通 turn"（`runtime-types.d.ts:214-219`），但"用户在 agent 说话时又说一句"是排队还是合并，没有实测；宠物要么前端禁用输入，要么用 `steer`。
4. **`ctx.on('session/event')` 对"非本插件创建"的会话也会触发**：需要 `subject !== session` 过滤（代码已写）。但 `Scoped<Session>` 的 scope-filter 语义对"插件级（非 agent 级）上下文"是否还额外过滤，没有反例可测。
5. **VAD / 端点检测要自己做。** `ctx.speechToText` 要的是**一整段完整 WAV**（`SpeechInput.audio` 是完整录音，sensevoice 内部只做分段/静音裁剪）。现有 iPad 客户端是**连续推 16k PCM 流**（`WhalePet/Voice/VoiceController.swift` 持续 `installTap`），端点切分原来在 Python（webrtcvad）。插件里要么写一个能量/RMS 端点检测，要么改 iPad 端"一句一个 WAV 上传"。**质量差异（webrtcvad vs RMS）没评估**。
6. **唤醒词匹配**：现有实现在 Python（`textnorm.py` 的 `DEFAULT_WAKE_ALIASES` + 同音别名表）。插件里要移植同一套规范化/别名逻辑，**没有**现成的 DSH API。
7. **唤醒后回复长度 / 打断**：`Transcript.text` 为空串表示"没识别到语音"（`types.d.ts:101-106`），但"识别到非语音噪声"与"空"在 sensevoice 里如何区分，没测。
8. **`assertAdoptable` 之外，`agents.resume()` 在宠物会话上的完整可行性**：headless 的那些拒绝条件（preset/cwd/origin）是从 headless 视角写的；宠物插件自己 resume 时是否也需要同样检查（例如 cwd 变了），没有官方统一函数可调。
9. **端口/防火墙**：`0.0.0.0:8787` 能不能被 iPad 连上取决于主机防火墙（现有 Python 桥能连，说明端口策略 OK），但没有在插件形态下实测。
10. **`ctx.logger`** 在插件 ctx 上可用（官方包普遍用 `ctx.logger.warn/error`，如 `$DSH/dsh-host-webserver/lib/index.js:540,549`），但方法集没逐个核对。
11. 本机 `permissionPresets` 的 preset 名字来自 `$DSH/dsh-base/cordis.patch.yml:264-276` **静态配置**；运行期是否被 profile 的更高层 patch 覆盖过，没查（`$PROFILE/cordis.patch.yml` 里没有 `permission` 行，所以应以 base 为准，但 `$DSH/home` 级用户层 `$DSH_HOME/cordis.patch.yml` 未检查）。

---

## 11. 文件索引（按需回查）

| 主题 | 文件 | 关键行 |
|---|---|---|
| Agent 注册表 / CreateAgentOptions / AgentHandle | `$DSH/dsh-agent/lib/types/index.d.ts` | 49-106, 145-148, 292, 300 |
| Agent live face（send/followup/steer/inject/whenIdle/cancel） | `$DSH/dsh-agent/lib/types/runtime-types.d.ts` | 27-36, 185-236 |
| `create()` 的 ownerCtx 语义 | `$DSH/dsh-agent/lib/index.js` | 582-587 |
| agent-loop 的 createAgent / create / owner effect | `$DSH/dsh-agent-loop/lib/index.js` | 1522-1545, 1609-1630, 1668-1692 |
| UserMessage / ContentBlock / MessageId | `$DSH/dsh-llm/lib/types/{message,types,brand}.d.ts` | message 123-146, 194-216；types 52-56, 121-133；brand 14-20 |
| Session / SessionStore / assistant·message / deriveMessages | `$DSH/dsh-session/lib/types/{index,types}.d.ts` | types 5-12, 338-346；index 343-355, 422, 494, 502 |
| speechToText 服务 | `$DSH/dsh-experimental-speech-to-text/lib/types/index.d.ts` | 46-90 |
| WAV 校验 | `$DSH/dsh-experimental-speech-to-text/lib/types/wave.{d.ts,js}` | d.ts 1-8；js 8-23 |
| sensevoice 就绪门槛 / 状态机 | `$DSH/dsh-experimental-speech-to-text-sensevoice/lib/index.js` | 631-663, 668-675, 819-823, 886-910, 921-954 |
| 官方转写调用范式 | `$DSH/dsh-experimental-api-speech-to-text/lib/index.js` | 195-215 |
| headless 的 create+followup+whenIdle+读文本 | `$DSH/dsh-headless/lib/index.js` | 114-139, 322-341, 346-383 |
| GUI 会话创建（preset + model） | `$DSH/dsh-api-session-controller/lib/index.js` | 264-277, 421-453 |
| 权限 preset / 审批 | `$DSH/dsh-permission-presets/lib/{index.js,types/index.d.ts}`、`$DSH/dsh-user-approval/lib/types/index.d.ts`、`$DSH/dsh-base/cordis.patch.yml` | preset js 193-195, d.ts 153-177；approval d.ts 54-63；base 264-276 |
| 工具限制 | `$DSH/dsh-tools/lib/index.js` | 393, 453-468 |
| HTTP/WS 监听 | `$DSH/dsh-host-webserver/lib/index.js`、`$DSH/dsh-api-gateway/lib/index.js` | ws 2, 490, 510-546；gw 324-360 |
| 模块解析拦截 | `$DSH/dsh-app-boot/lib/index.js`、`$DSH/dsh/lib/profile-boot-e2mS45fC.js` | 1487-1578, 2091-2140, 2462-2516, 4247-4257；boot 307 |
| 插件开发规范 | `$DSH/dsh-agent-preset/skills/cordis-plugin-development/{SKILL.md,references/host-plugin.md}` | host-plugin 5-27, 57-64, 66-77 |
| cordis effect | `$DSHROOT/node_modules/@deepseek-ai/cordis/lib/{index.js,types/fiber.d.ts}` | js 429-461；d.ts 35-51, 161-163 |
| 第三方先例 | `$PROFILE/node_modules/@openviking/dsh-memory-plugin/{package.json,capture.mjs,index.mjs}`、`$PROFILE/node_modules/dsh-local-model/{package.json,lib/index.js}` | memory capture 1-21；index 10-115 |