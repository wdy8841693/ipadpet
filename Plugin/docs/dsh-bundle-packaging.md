# DSH Host 插件 bundle 打包 / 安装契约

> 任务：task-2（bundle-packaging）。目标：给 iPad 宠物 App 的 Host 插件（局域网 HTTP+WS 网关，内部用 `ctx.speechToText`、驱动 DSH Agent 会话）一份可直接照抄的 bundle 契约。
>
> 本文件是唯一写入物；调研全程只读。DSH 安装根 `/home/dywu/.npm/_npx/b86ed90107c62dab/`，profile `/home/dywu/.dsh/profiles/web`。
> 权威来源按可信度排序：① DSH 安装内实现代码与类型声明；② `cordis-plugin-development` 技能的 `references/host-plugin.md`；③ 已安装的 workspace bundle 实例。

---

## 0. 一页结论（对应 Lead 的 8 个问题）

| # | 问题 | 结论 |
|---|---|---|
| 1 | bundle 最小结构与 package.json 字段 | 目录 5 件套：`package.json` + `cordis.patch.yml` + `index.js` + `locale/{en,zh}.json` + `icon.svg`。必需字段：`name`、`version`、`type:"module"`、`exports["."]`（或 `main`）、`dsh.bundle.patch`。`description`/`private`/`files` 建议有。**不需要** `dsh.client`（那是 Web UI 半区）。 |
| 2 | `cordis.patch.yml` 方言 | 顶层是 patch 数组。`insert`（可带 `id` 指向已有 group）追加行；不带 `insert` 的 patch 用 `id` 改已有行，**只覆盖写出的字段，`config` 整体替换**；`name` 只做断言（不匹配则告警跳过）。层序：`dsh.profile.bundles` 顺序 → profile `cordis.patch.yml` → `--patch`，**后层覆盖前层，所以 profile 覆盖 bundle**。 |
| 3 | 导出形状 | 二选一，不能混用：`export function apply(ctx, config)` + `export const inject`/`export const Config`；或 `export default class extends Service`（`static inject`/`static Config`）。`Config` 必须是 schemastery 之类带 `~standard.validate` 的 schema。生命周期用 `ctx.effect`/`ctx.on`（返回 cleanup）。 |
| 4 | `host-plugin.md` 显示清单 | 安装前必须：locale 里 `meta.title`/`meta.description`（英文 + 用户语言，sentence case）、原创/可再分发 icon、`exports` 暴露 `./locale/*.json` 与 `./icon`、`files` 含全部运行时文件、icon 合法（SVG/PNG/JPEG/WebP ≤256KiB 且在包内）。**Host-only bundle 同样需要**（"A Host-only or configuration-only bundle still has a visible inventory entry"）。 |
| 5 | 最小可安装 Host 插件骨架 | 见 §5：完整目录树 + 可照抄 `package.json` / `cordis.patch.yml` / `index.js` / locale / icon。5 个现有 workspace 插件全部零 npm 依赖、纯 `node:*` + `ctx.*`。 |
| 6 | `install_bundle` 副作用 | **改 profile `package.json`**：pnpm `add` 写 `dependencies`，并把 bundle 追加进 `dsh.profile.bundles`。**不改 profile `cordis.patch.yml`**（只有 `set_plugin` 开关才写它）。卸载 = 反选 + `pnpm remove`。失败自动还原 `package.json` + `pnpm-lock.yaml`。日志用 `ctx.logger.info/warn/error/debug`。 |
| 7 | 依赖已有 `speech-to-text` 行 | 只写 `export const inject = ['speechToText']`（硬依赖）或 `ctx.get('speechToText')`（可选），**绝不 `insert` 那行**；行由 voice-input bundle 提供、profile 只覆盖其 `config`。行顺序不承载加载语义，服务可用性驱动激活。 |
| 8 | 读到自己的 token/配置 | 非机密参数放 Config（bundle patch 里给默认值，profile patch 可覆盖）；**密钥不放 Config**：单一固定环境变量直接 `process.env`；需要落盘/可轮换/可枚举时用 `ctx.credentials`（`modifyRecord`，键 `<scope>/<id>`）。 |

---

## 1. bundle 包最小结构与 `package.json` 必需字段

### 1.1 目录树（最小可安装 + 可显示）

```
dsh-plugin-ipadpet-gateway/          # 目录名随意；包名在 package.json 里定义
├── package.json                     # ① bundle 身份 + dsh.bundle 声明（必需）
├── cordis.patch.yml                 # ② bundle 层 patch，向 Loader 插入插件行（必需，路径由 package.json 指定）
├── index.js                         # ③ 插件实现（apply + inject + Config）
├── locale/
│   ├── en.json                      # ④ 显示元数据英文（meta.title / meta.description）
│   └── zh.json                      # ⑤ 显示元数据中文
├── icon.svg                         # ⑥ 插件图标（也可用 package.json 顶层 "icon" 指向任意包内文件）
└── README.md                        # 可选，人读文档；不参与加载
```

各文件作用：

| 文件 | 作用 | 缺失后果 |
|---|---|---|
| `package.json` | 包名/版本/ESM 入口/`dsh.bundle.patch`；同时提供 `description` 作为 bundle 描述兜底 | 无 `dsh.bundle` → `install_bundle` 报 `not-bundle` 并还原文件（`dsh-plugin-manager/lib/index.js:2842`）|
| `cordis.patch.yml` | Loader 覆盖层：`insert` 插件行（id/name/config） | 文件缺失 → 安装校验阶段抛错，安装失败并还原 `package.json`/`pnpm-lock.yaml`（`lib/index.js:2845-2851`）|
| `index.js` | 默认/命名导出插件；启动时 `apply(ctx, config)` | 加载失败 → 激活失败，安装结果 `application:"failed"`（依赖与选择可能已保存，见 README.md:54）|
| `locale/*.json` | Plugin Manager / Settings **不激活插件**也能读到标题描述（`host-plugin.md:31`）| 回退到 `package.json` `name`/`description`（`dsh-app-boot/lib/index.js:3002-3033`）|
| `icon.svg` | 行/包图标 | 回退面板默认图（`host-plugin.md:51`）|

> `files` 对 **link 安装无效**：`host-plugin.md:35` 明确 "Local directory installation links the checkout instead, so check the files directly; `files` does not filter a linked directory."。但打包/发布时必须列全，否则运行文件缺失。

### 1.2 `package.json` 字段表

| 字段 | 必需 | 说明 / 证据 |
|---|---|---|
| `name` | ✅ | 唯一 npm 名（可用 `@local/...` 私有 scope；profile 现有 `@dywu/*`、`@local/*` 先例）。bundle 名 = 行 `name` 的包说明符。 |
| `version` | ✅ | semver；用于 `list_bundles` 展示、更新判定、exemptions 键。 |
| `type` | ✅ 建议 | `"module"`。缺省时 `.js` 按 CJS 解析，`export` 语法直接报错 → 激活失败。 |
| `main` 和/或 `exports["."]` | ✅ | Loader `import()` 包说明符；ESM 下**必须**有 `exports` 或 `main`（无目录 index 兜底）。现有 5 个插件都写了 `exports["."]`；`main` 可选。 |
| `exports["./locale/*.json"]` | ✅（显示清单）| 显示元数据通过 `<specifier>/locale/en.json` 资源解析（`dsh-app-boot/lib/index.js:3002-3033`）。 |
| `exports["./icon"]` | ✅（显示清单）| 图标通过 `<specifier>/icon` 解析；也可改用 package.json 顶层 `icon`（优先于 `./icon`，`host-plugin.md:51`）。 |
| `exports["./package.json"]` | 可选 | 工具链读取方便；bundle 目录解析**不要求**导出 `./package.json`（`dsh-app-boot/lib/index.js:1774-1783`）。 |
| `files` | 建议 | 发布/打包时过滤；link 安装无效（`host-plugin.md:35`）。 |
| `description` | 建议 | bundle 原始描述（`list_bundles.description`），也是 locale 缺失时的描述兜底。 |
| `private` | 建议 | 防误发布；现有 workspace 插件全部 `private:true`。 |
| `dsh.bundle.patch` | ✅ **bundle 的定义** | 字符串或字符串数组（`dsh-app-boot/lib/index.js:1335-1349`）；读取时 join 到包目录，不要求被 `exports` 暴露。 |
| `dsh.bundle.platforms` | 可选 | Node platform 名非空数组；声明后不匹配的 Host 会隐藏/拒绝（`dsh-app-boot/lib/index.js:1063-1067`）。网关是 Linux 本机服务，**建议省略**。 |
| `dsh.bundle.listedByDefault` | 可选 | 布尔；GUI 默认可见性。非法布尔会报 metadata 诊断（`dsh-plugin-manager/lib/index.js:2217-2220`）。 |
| `dsh.client` | ❌ 本插件不需要 | 只有 **Web UI 半区**（浏览器模块 + slot 注册）才加：`{"platform":"web","immediately":true,"inject":[...]}`（`references/ui-plugin.md:3`；实例：job-collector `package.json:30-33`）。Host-only bundle 不加。 |
| `dependencies` | ❌ 建议不加 | **关键约束**：本地目录安装 pnpm 写 `link:`，pnpm 不会安装 link 包的 dependencies（profile 只有 `pnpm-workspace.yaml` 自身包），所以 bundle 实际能 import 的只有 `node:*`、宿主服务（`ctx.*`）和宿主安装内可拦截解析的包。5 个现有 workspace bundle 均无 `dependencies`。 |
| `peerDependencies` | 条件 | 若确需 `import '@deepseek-ai/schemastery'` 等安装内包，见 §3.5 的拦截机制说明（**未实测**）。 |
| `engines.dsh` / `peerDependencies["@deepseek-ai/dsh*"]` | 可选 | 兼容性闸门：`engines.dsh` 优先，否则检查 `@deepseek-ai/dsh`/`@deepseek-ai/dsh-*` peer 的 semver（`dsh-app-boot/lib/index.js:1129-1160`）。不写就不检查；写错会被 `incompatible-version` 拒绝。 |

### 1.3 一个注意点：bundle 包可以「只带 patch 不自带插件」

`@deepseek-ai/dsh-experimental-voice-input-bundle` 就是纯配置 bundle：它的 patch 插入别的包的 4 个行，自己没有行（`.../voice-input-bundle/cordis.patch.yml:1-13`）。我们的场景相反：bundle 包既是 bundle 又是插件，行 `name` 就等于包名（与 job-collector 相同）。

---

## 2. `cordis.patch.yml` 的 Loader 方言与层叠规则

### 2.1 patch 数组的两种形态

文件必须是**顶层 YAML 数组**，每个元素必须是 patch 映射；YAML 解析失败、非数组、条目非映射都会直接抛错（`dsh-app-boot/lib/index.js:4740-4752`）。其余字段合法性由 Loader/Include 侧校验。

**(A) `insert`：向树里追加行**

```yaml
- insert:
    - id: my-row              # 行 id：后续 patch 用 id 指向它；重复 id 会抛 "entry <id> already exists"
      name: '@local/my-pkg'   # 插件包说明符（可带子路径）；相对路径会以 patch 文件所在目录为锚
      config: {}              # 传给插件的原始配置（Config schema 校验）
      disabled: false         # 可选
      inject: {...}           # 可选，行级服务要求/拦截配置
      isolate: {...}          # 可选，服务实例隔离
```

- 带 `id` 的 `insert` 若命中一个**已存在的 `group: true` 行**，rows 会追加进该 group 的 `config` 列表；命中非 group 或不存在的 id → 告警跳过（`cordis-plugin-include/src/patch.ts:65-83`）。
- 不带 `id` → 追加到根列表。

**(B) 无 `insert`：按 id 覆盖已有行**

```yaml
- id: speech-to-text           # 目标行已存在（由别的 bundle 层插入）
  name: '@deepseek-ai/dsh-experimental-speech-to-text'   # 可选断言：truthy 且不相等 → 告警跳过
  config:                      # 整体替换，不深合并（必须复述该行需要的全部字段）
    defaultProvider: sensevoice-local
    language: zh
```

实现：`applyPatches` 对每个 override 只做 `target[key] = value`，**只覆盖本 patch 写出的键**，其中 `config` 是整值替换（`cordis-plugin-include/src/patch.ts:47-109`，关键行 86-105）。所以只改 `disabled` 就只动 `disabled`；写了 `config` 就必须把该行需要的字段**全部复述**。

> 实例：profile `/home/dywu/.dsh/profiles/web/cordis.patch.yml:149-153` 就是「无 insert 的覆盖」，目标 `speech-to-text` 行由 `@deepseek-ai/dsh-experimental-voice-input-bundle` 的 patch 插入——这正面证明「跨 bundle 层的行可以用 id 覆盖，不必重复 insert」。

### 2.2 各字段什么时候用

| 字段 | 语义 | 何时用 | 证据 |
|---|---|---|---|
| `insert` | 追加行（可按 group id 定位父组） | 新 bundle 插入自己的插件行；配置类 bundle 插入依赖行 | patch.ts:65-83 |
| `id` | 行身份；loader 条目 id 在树内唯一 | 所有 patch 都应有；后续覆盖/开关/日志都靠它 | patch.ts:86-94；`cordis-plugin-loader/src/config/tree.ts:153` |
| `name` | 插件包说明符；override 时作断言 | insert 必填；override 时写了就必须与现有行一致 | patch.ts:97-100 |
| `config` | 传给插件的配置；**整值替换** | 需默认配置时放 bundle patch；用户改配置放 profile patch | patch.ts:102-105；`host-plugin.md:3` |
| `disabled` | 布尔 / `null` / `!!js` 表达式；父行禁用会传染子树（group 自身恒启用） | 让某行默认关闭；或覆盖 bundle 里默认关闭的 shipped 行 | `.../loader/src/config/entry.ts:20,76-92`；`dsh-base/cordis.patch.yml:15-30` 的 `!!js` 实例 |
| `group` | `true` + `name: cordis:group` 时，`config` 是嵌套行列表；可被 insert-by-id 追加 | 成组启用/禁用、成组 isolate | `dispatch`/`group` 实例：`dsh-web-app/presets/cordis.patch.yml:47-56` |
| `isolate` | 服务名 → `true`/realm 标签；把 provider 与消费者锁进同一服务实例域 | 同一 profile 需要两份互不干扰的服务实例（preset 常用）| `.../loader/src/config/isolate.ts:8`；`dsh-experimental-session-search/cordis.patch.yml:4-6` |
| `inject` | 行级注入（服务要求或 intercept 配置） | 行级定制激活条件；一般插件用模块级 `export const inject` 就够 | `.../loader/src/config/entry.ts:22` |
| `intercept` | 服务拦截配置（行级） | 替换/包装某个服务；网关插件不需要 | `cordis-composition-reference` 技能 |
| `!!js` | Loader 表达式；`config` 内表达式在该行依赖激活后、对插件自己的 ctx 求值，可写 `ctx.get('x')`、`dshHomePath(...)` | 配置依赖宿主路径/服务/环境时 | composition-reference；`dsh-base/patch:15-30`、voice-input patch:8 |

> 注意：`!!js` 求值上下文是 Loader ctx（`config` 内是插件 ctx）；`process.env` 也可用（profile patch 里已有 `process.getBuiltinModule("fs")` 的例子，`cordis.patch.yml:74-76`），但把密钥写进 patch 等于明文落盘，不推荐（见 §8）。

### 2.3 层叠顺序（bundle patch 与 profile patch 谁赢）

组合流程（`dsh-app-boot/lib/index.js` 的 `loadProfileDirectory` / `composeEntries`）：

```
空根 entry 列表
  → 依 package.json 的 dsh.profile.bundles 顺序，依次叠加每个 bundle 的 patch
  → 叠加 profile 的 cordis.patch.yml（用户层）
  → 叠加 --patch 覆盖层（若有）
= 最终 Loader 树
```

- 叠加算法就是 `applyPatches` 单次遍历，**同一 id 的后层 patch 覆盖前层写出的键**；`config` 整值替换（`dsh-base/cordis.patch.yml:1-6` 的注释原话："Later bundle patches and the user's profile cordis.patch.yml address these rows by id, with the last write winning per row"）。
- 所以：**profile patch 覆盖 bundle patch**；bundle patch 可以覆盖更早 bundle 的行；后选中的 bundle 可以覆盖先选中的 bundle（`set_bundle(enabled)` 追加到末尾会改变优先级，README.md:40）。
- 行顺序**不承载加载顺序**：激活由服务可用性驱动，`cordis-plugin-development` 技能也这么说，`dsh-base/patch:12-13` 原文 "Row order carries no load semantics (activation is service-availability driven)"。

---

## 3. Host 插件导出形状、Config、inject、dispose

### 3.1 两种导出形状（二选一，不可混用）

`host-plugin.md:57-64` 原文："`index.js` exports one of these forms; do not mix them"：

**(A) 函数插件（推荐，DSH 内部绝大多数包这种）**

```js
export const name = 'my-plugin'          // 可选：诊断用
export const inject = ['tools']         // 可选：服务硬依赖
export const Config = z.object({...})   // 可选：配置 schema
export function apply(ctx, config) {}   // 必需
```

**(B) Service 类默认导出**

```js
import { Service } from '@deepseek-ai/cordis'
import z from '@deepseek-ai/schemastery'

export default class MyService extends Service {
  static inject = ['sessions']          // 类静态注入
  static Config = z.object({...})       // 类静态 Config
  constructor(ctx, config) {
    super(ctx, 'myService')             // 注册的服务名
    this.config = config
  }
}
```

两种都行：Loader 先 `unwrapExports`（`exports.default ?? exports`，`cordis-plugin-loader/src/index.ts:209-216`），cordis 再接受 function 或 `{apply}` 对象（`cordis/lib/index.js:1605-1610`），并从 `plugin.inject` / `plugin.Config` 取元数据（`cordis/lib/index.js:1691-1704`）。

> 混用陷阱：如果同时写了 `export default` 和命名 `apply`，`exports.default` 胜出，命名导出全部被忽略——不要混。

**本插件选 (A)**：不需要对外提供新服务，只需要消费 `speechToText`、自己监听端口。

### 3.2 `inject` 声明方式

| 写法 | 效果 | 证据 |
|---|---|---|
| 模块级 `export const inject = ['speechToText']` | 硬依赖：服务不在/被卸载时插件不激活或停用；激活后 `ctx.speechToText` 可用 | `cordis/lib/index.js:1691-1704`；Service 契约 `access.hardDependency` |
| 类静态 `static inject = [...]` | 同上（类插件） | `dsh-schedule/lib/index.js:2091` 等 |
| `ctx.get('speechToText')` | 可选依赖：拿不到返回 `undefined`，插件照常启动，自行降级 | `cordis_inspect` 对 `speechToText` 给出的 optional 访问式 `ctx.get("speechToText")` |
| `ctx.inject([...], callback)` | 等价于动态注册一个带注入的插件（少用） | `cordis/lib/index.js:1668-1674` |

推荐：网关的核心能力就是语音转写 → 用**硬依赖** `inject = ['speechToText']`，让 Loader 保证「服务就绪才监听端口」。若希望端口先起、转写不可用时 HTTP 返回 503，则把 STT 改成 `ctx.get('speechToText')` 可选依赖并在请求时判空。

### 3.3 Config 的 schemastery 写法

`Config` 必须是带 `~standard.validate` 的 schema，cordis 在激活前校验，失败抛 `ValidationError`（`cordis/lib/index.js:244-250`）。没有 `Config` 时 config 原样传入、不校验（`resolveConfig` 第一行 `if (!runtime.Config) return config`）。

```js
import z from '@deepseek-ai/schemastery'

export const Config = z.object({
  host: z.string().default('0.0.0.0').description('监听地址'),
  port: z.natural().max(65535).default(8791),
  tokenEnv: z.string().default('IPADPET_GATEWAY_TOKEN'),
  transcriptLanguage: z.string().default('zh').volatile(),   // volatile: 改值不重启
})
```

要点（已用安装内 schemastery 3.19.0 实测）：

- **默认值**：`.default(x)`；schema 不会因为字段缺失而报错，除非 `.required()`（实测 `z.natural().required()` 缺值抛 `ValidationError: $.port missing required value`；不带 `.required()` 时静默给 `undefined`）。
- **`.volatile()`**：字段变成 `Volatile<T>`，必须用 `.get()` 读；只改 volatile 字段时 Loader **不重启**插件，就地提交并触发 `loader/volatile-update`（`cordis/README.md:103-105`；实例 `dsh-experimental-speech-to-text/lib/index.js:8-11,111-112`）。
- **类型参考**：`z.string()/.number()/.natural()/.boolean()/.array()/.object()`，链式 `.min/.max/.step/.description/.default/.required/.volatile`。
- 写 row 的 `config` 前可先用 `cordis_inspect_query {provider:"Config", method:"listConfigs", input:{name}}` 看已安装插件的投影 JSON Schema（同一 schema 机制）。
- **如果不引入 schemastery**：省略 `export const Config`，在 `apply` 里手工校验/补默认值——5 个现有 workspace bundle 全部这么做（下方对比表）。两种都合法。选型见 §3.5。

### 3.4 `dispose` / 生命周期

- 所有资源都用 `ctx.effect` 或 `ctx.on` 注册并返回 cleanup；fiber 卸载、HMR 重载、profile 重新组合时自动回收（`host-plugin.md:64`；`cordis/README.md:61-67`）。
- 异步 cleanup 允许：`ctx.effect(() => async () => {...})`（`dsh-experimental-speech-to-text/lib/index.js:20-24`）。
- 现有实例：
  - 定时器：`ctx.effect(() => { const t = setInterval(...); return () => clearInterval(t) }, 'label')`（job-collector `index.js:1312-1322`）。
  - 工具注册：`ctx.effect(() => tools.register({...}), 'label')`（job-collector `index.js:1333-1352`）。
  - 资源关闭：`ctx.effect(() => () => { store.close() }, 'label')`（job-collector `index.js:1738-1740`）。
  - 路由注册返回 disposer，同样包进 effect（teaching-research 用 `ctx.webServer.register`，apply 内 `const disposeRoute = ...`，`index.js:533-538`）。
- `ctx.effect(fn)` 的 `fn` 内抛错会让插件激活失败；**监听端口/EADDRINUSE 这类运行期错误应在事件回调里捕获**，不要从 `apply` 同步抛。

### 3.5 一个未实测的边界：workspace（link 安装）插件 import `@deepseek-ai/*`

- 运行时解析器会把「DSH 安装自带的包」按需拦截给 linked 包（`dsh-app-boot/lib/index.js` 的 `routeLinked`，:2462 起；`readPeerNames`，:2133-2140；`linkedProfileRoots`，:1439-1461）。
- 具体条件（读码推断）：包名在安装 scope 的解析表里，**且**导入文件某个祖先目录的 `package.json` 把该包列进 `peerDependencies` → 走拦截，从安装解析。
- 链路证据：`@deepseek-ai/dsh` 依赖 voice-input-bundle（`dsh/package.json:100`）→ 它依赖 speech-to-text（`voice-input-bundle/package.json:37`）→ 它依赖 `@deepseek-ai/schemastery`（`speech-to-text/package.json:42`）；因此 schemastery 属于安装 scope；`@deepseek-ai/cordis` 是 `dsh/package.json:23` 直接依赖。
- **但**：workspace 根没有 `node_modules`（已确认 `/home/dywu/Samba/workspace/node_modules` 不存在），且现有 5 个 bundle 均不 import `@deepseek-ai/*`，所以该路径在本环境**没有先例、未实测**。
- 结论：v1 建议**不 import 任何 @deepseek-ai 包**（不写 `Config`、不用 `Service` 基类）；若一定要 `Config`，先做 1 分钟烟测（装一个最小 bundle，`cordis_inspect_query Config.listConfigs` 能看到 schema 即成功），并在 package.json 里 `"peerDependencies": { "@deepseek-ai/schemastery": "*" }` 让拦截条件成立。后备方案：把默认值/校验写进 `apply`（与现有 5 个插件一致）。

---

## 4. `host-plugin.md` 的「安装前必须完成的显示清单」

来源：`.../cordis-plugin-development/references/host-plugin.md:29-55`。Plugin Manager 与 Settings **不激活插件**就读取这些元数据，所以是安装前的硬要求（技术上安装不会因此失败，但交付验收不通过；缺失会静默回退）。

| # | 要求 | 细节 / 证据 |
|---|---|---|
| 1 | `locale/en.json` 的 `meta.title`、`meta.description` | 描述插件能力；`host-plugin.md:33` |
| 2 | 同时提供用户语言（如 `locale/zh.json`）同名字段 | `host-plugin.md:33`；实例 job-collector `locale/en.json:1-5` / `locale/zh.json` 同结构 |
| 3 | 英文标题句首大写（sentence case，只首词与专有名词大写） | `host-plugin.md:33` |
| 4 | 原创图标或可再分发授权，保留归属 | `host-plugin.md:34` |
| 5 | `exports` 暴露 `./locale/*.json` 与 `./icon`，并保留原有运行时导出 | `host-plugin.md:35` |
| 6 | `files` 列入 patch / locale / icon / 全部运行时文件；打包/发布时核对真实文件列表 | `host-plugin.md:35` |
| 7 | icon 合法：SVG/PNG/JPEG/WebP，≤256 KiB，必须是包内相对路径（绝对路径/URL/越界符号链接被拒） | `host-plugin.md:36,51`；`dsh-app-boot/lib/index.js:2863-2896` |
| 8 | 安装后核对：bundle 详情与插件行的标题/描述、图标（英文 + 用户语言）、有无 metadata 诊断/意外回退 | `host-plugin.md:53` |
| 9 | **Host-only / 配置-only bundle 同样需要**（同样有可见清单条目） | `host-plugin.md:55` |

补充细节：

- locale 里可加 `meta.detail` 指向文档（实例 `voice-input-bundle/locale/en.json:5`）。
- 缺 `title`/`description` 时回退 `package.json.name`/`description`，`title` 最终兜底是完整模块说明符（`dsh-app-boot/lib/index.js:3010-3011,3002-3033`）；图标缺失用面板默认图（`host-plugin.md:51`）。
- 顶层 `icon` 字段优先于 `./icon` 导出，但必须是 manifest 目录内的相对路径（`dsh-app-boot/lib/index.js:2871-2887`）。
- 无法用浏览器验收时，必须报告「已安装资源检查通过但渲染未验证」，不能宣称视觉成功（`host-plugin.md:53`）。

---

## 5. 现有 workspace bundle 对比 + 「最小可安装 Host 插件」完整骨架

### 5.1 5 个现有插件的最小骨架对比

| 插件目录 | 包名 | 入口导出 | 行 id | patch 形态 | profile 引用方式 | npm 依赖 |
|---|---|---|---|---|---|---|
| `dsh-plugin-job-collector` | `@dywu/job-market-collector` | `export const inject = ['tools','webServer']` + `export function apply(ctx, config)`（index.js:1219,1221） | `job-market-collector` | `insert` 1 行，config.dataDir（patch:1-5） | `package.json` 依赖 `link:`（profile:8）+ bundles 列表（profile:42） | 无（`package.json:1-35` 无 deps） |
| `dsh-plugin-teaching-research` | `@dywu/teaching-research-workbench` | `inject = ['webServer']` + `apply`（index.js:506,508） | `teaching-research-workbench` | `insert` 1 行（patch:1-5） | 依赖 `link:`（profile:9）+ bundles（profile:43） | 无（`package.json:1-33`） |
| `dsh-ai-router/dsh-plugin` | `@local/dsh-ai-router-tools` | `export const name` + `inject=['tools']` + `apply`（index.js:16,19,546） | `dsh-ai-router-tools` | `insert` 1 行 + 3 个 config（patch:3-12） | 依赖 `link:`（profile:12），但 **bundles 未选中**（profile:28-44）→ 当前 profile 实际未加载该行（`Config.listConfigs` 核验 0 条） | 无（`package.json:1-28`） |
| `tools/dsh-subagent-settings` | `@local/dsh-subagent-settings` | `name` + `inject=['webServer']` + `apply`（index.js:21,22,273） | `dsh-subagent-settings` | `insert` 1 行（patch:1-6） | 依赖 `link:`（profile:19），但 bundles 未选中；行实际由 **profile patch** 插入（profile cordis.patch.yml:102-106，`Config.listConfigs` 核验存在）→ 证明行不一定来自 bundle | 无 |
| `dsh-ai-router/dsh-plugin-dashboard` | `@local/dsh-ai-router-dashboard` | `name` + `inject=['webServer']` + `apply`（index.js:12,15,71） | `dsh-ai-router-dashboard` | `insert` 1 行（patch:1-10） | 依赖 `link:`（profile:10），但 **bundles 未选中**；行未加载（`Config.listConfigs` 核验 0 条） | 无 |

共同规律：

1. **零 npm 依赖、纯 ESM、无构建步骤**；用 `node:*` 内建 + `ctx.*` 服务。
2. 用**命名导出式函数插件**（无 `Service` 基类，无 `Config` schema）。
3. 资源全部 `ctx.effect` 注册；`ctx.logger` 写日志。
4. `package.json` 里有 `dsh.bundle.patch`，bundle 通过 profile 的 `dsh.profile.bundles` 生效。
5. 既有 `link:` 依赖 + `dsh.profile.bundles` 两条记录，就是 `install_bundle` 之后 profile 里会出现的状态。
6. **依赖安装 ≠ 行已加载**：`dependencies` 只保证包可解析；行是否进入 Loader 树取决于 ① 该 bundle 在 `dsh.profile.bundles` 里被选中，或 ② 某个更后层的 patch（如 profile `cordis.patch.yml`）用 `insert`/override 引入了该行。上表里 ai-router-tools / dashboard 是「装了依赖但未选 bundle」的实例。

> 一个反例说明 profile patch 也能写 insert：`subagent-settings` 的 bundle 没被选进 `dsh.profile.bundles`，它的行完全靠 profile patch 里的一条 insert 提供（`cordis.patch.yml:102-106`）。这种「bundle patch 里也有一条同 id insert、但 bundle 没选中」的状态在本机恰好不冲突；一旦把该 bundle 也选进 bundles，就会出现两处 insert 同 id → Loader 抛 `entry <id> already exists`。**新增插件不要学这个**：要么走 bundle，要么走 profile patch，不要两套。

### 5.2 最小可安装 Host 插件：完整文件清单

建议落在会话工作区内（便于 `install_bundle` 的 target 用绝对路径，且不碰 `~/.dsh`）。目录名/位置可随 Lead 安排调整（例如工作区里已有的 `Plugin/`），**只要安装时 target 用该目录的绝对路径**：

```
/home/dywu/Samba/workspace/ipadpet/dsh-plugin-ipadpet-gateway/
├── package.json
├── cordis.patch.yml
├── index.js
├── locale/en.json
├── locale/zh.json
├── icon.svg
└── README.md          （可选）
```

bundle 包名 = 插件行 `name`：`@local/dsh-ipadpet-gateway-bundle`；行 id：`ipadpet-lan-gateway`。

### 5.3 可照抄的 `package.json`

```json
{
  "name": "@local/dsh-ipadpet-gateway-bundle",
  "version": "0.1.0",
  "private": true,
  "description": "iPad 宠物 App 的局域网 HTTP+WS 网关：把语音转写接到本机 DSH Agent 会话。",
  "type": "module",
  "main": "index.js",
  "exports": {
    ".": "./index.js",
    "./locale/*.json": "./locale/*.json",
    "./icon": "./icon.svg",
    "./package.json": "./package.json"
  },
  "files": [
    "index.js",
    "cordis.patch.yml",
    "locale/*.json",
    "icon.svg",
    "README.md"
  ],
  "dsh": {
    "bundle": {
      "patch": "./cordis.patch.yml"
    }
  }
}
```

说明：

- 不写 `dependencies`（link 安装不会装它们）。
- 不写 `engines.dsh`（避免被 `incompatible-version` 拒绝；当前 DSH 为 `0.2.2-rc.1`，若要写，先确认范围含 prerelease）。
- 不加 `dsh.client`（Host-only）。
- 若采用 schemastery `Config`，再加 `"peerDependencies": { "@deepseek-ai/schemastery": "*" }`（未实测，见 §3.5）。

### 5.4 可照抄的 `cordis.patch.yml`

```yaml
# dsh-ipadpet-gateway-bundle：在 Host 根作用域插入局域网网关一行。
# 本 bundle 只插入自己；speech-to-text 行由 voice-input bundle 提供，不在此重复插入。
- insert:
    - id: ipadpet-lan-gateway
      name: '@local/dsh-ipadpet-gateway-bundle'
      config:
        host: 0.0.0.0
        port: 8791
        tokenEnv: IPADPET_GATEWAY_TOKEN
        transcriptLanguage: zh
```

- 若不想在 bundle 里写死配置，可 `config: {}`，靠 `Config` 默认值或 `apply` 兜底。
- 如果将来需要确保某 shipped 行开启，可另加一条无 insert 的 `- id: <行>  disabled: false`。

### 5.5 可照抄的 `index.js` 骨架（含 Config 与 dispose）

下面这版是 **Plan A：零 import（除 `node:*`）**，与现有 5 个 workspace bundle 一致，安装风险最低。已用 `node --input-type=module --eval` 做过语法/导出冒烟（未在 DSH 内实际加载）。

```js
/**
 * ipadpet-lan-gateway：iPad 宠物 App 的局域网 HTTP+WS 网关（Host 插件）。
 *
 * 契约：
 * - 语音转写：ctx.speechToText（服务由 profile 中 id=speech-to-text 的行提供）
 * - Agent 会话：见 task-1 的 host-agent-api.md，此处只在 TODO 处接入
 * - 资源全部挂 ctx.effect，卸载/HMR 时回收
 */
import http from 'node:http'

/** Loader 行使用的插件名（诊断用）。 */
export const name = 'ipadpet-lan-gateway'

/**
 * 硬依赖：语音转写服务。
 * 不重复插入 speech-to-text 行；行不存在时本插件保持未激活，Loader 会报告 missing service。
 */
export const inject = ['speechToText']

const DEFAULTS = {
  host: '0.0.0.0',
  port: 8791,
  tokenEnv: 'IPADPET_GATEWAY_TOKEN',
  transcriptLanguage: 'zh',
}

/** 手工校验/补默认值（不引入 schemastery）。 */
function resolveConfig(raw) {
  const input = raw && typeof raw === 'object' ? raw : {}
  const host = typeof input.host === 'string' && input.host.trim() ? input.host.trim() : DEFAULTS.host
  const port = Number.isInteger(input.port) ? input.port : DEFAULTS.port
  if (port < 1 || port > 65535) throw new Error(`ipadpet-lan-gateway: port 越界：${port}`)
  const tokenEnv =
    typeof input.tokenEnv === 'string' && input.tokenEnv.trim() ? input.tokenEnv.trim() : DEFAULTS.tokenEnv
  const transcriptLanguage =
    typeof input.transcriptLanguage === 'string' && input.transcriptLanguage.trim()
      ? input.transcriptLanguage.trim()
      : DEFAULTS.transcriptLanguage
  return { host, port, tokenEnv, transcriptLanguage }
}

/** 读取网关 token：优先环境变量；需要可轮换/多客户端时改用 ctx.credentials（见 §8）。 */
function readStaticToken(config) {
  const value = process.env[config.tokenEnv]
  return typeof value === 'string' && value.trim() !== '' ? value.trim() : undefined
}

export function apply(ctx, rawConfig) {
  const config = resolveConfig(rawConfig)
  const log = ctx.logger
  const sockets = new Set()

  // ---- HTTP：先只保留一个可验证端点，业务路由按 task-1 契约接入 ----
  const server = http.createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/health') {
      res.writeHead(200, { 'content-type': 'application/json' })
      res.end(
        JSON.stringify({
          ok: true,
          service: 'ipadpet-lan-gateway',
          speech: ctx.get('speechToText') !== undefined,
        }),
      )
      return
    }

    if (readStaticToken(config) !== undefined && req.headers['x-ipadpet-token'] !== readStaticToken(config)) {
      res.writeHead(401, { 'content-type': 'application/json' })
      res.end(JSON.stringify({ error: 'unauthorized' }))
      return
    }

    // TODO(task-1)：/transcribe 走 ctx.speechToText.resolve({audio}) + transcribe(spec, signal)
    // TODO(task-1)：/chat 创建/驱动 Agent 会话并回传 assistant 文本
    res.writeHead(404, { 'content-type': 'application/json' })
    res.end(JSON.stringify({ error: 'not-found' }))
  })

  // 连接句柄给 dispose 用：server.close() 只停止接收新连接，keep-alive 连接要主动销毁
  server.on('connection', (socket) => {
    sockets.add(socket)
    socket.on('close', () => sockets.delete(socket))
  })

  // 运行期错误只记日志，不从 apply 抛（否则一次 EADDRINUSE 就会让安装结果 failed）
  server.on('error', (error) => {
    log.error('ipadpet-lan-gateway: server error: %s', error && error.message ? error.message : String(error))
  })

  // TODO(task-1)：WebSocket。先销毁，等 task-1 定传输方案（原生 ws / 自实现 RFC6455 握手）
  server.on('upgrade', (_req, socket) => {
    socket.destroy()
  })

  server.listen(config.port, config.host, () => {
    log.info('ipadpet-lan-gateway: listening on http://%s:%d', config.host, config.port)
    if (readStaticToken(config) === undefined) {
      log.warn('ipadpet-lan-gateway: 环境变量 %s 未设置，局域网请求在拿到密钥前不可用', config.tokenEnv)
    }
  })

  // 资源回收：插件卸载 / HMR 重载 / profile 重组时执行
  ctx.effect(
    () => () => {
      for (const socket of sockets) socket.destroy()
      sockets.clear()
      return new Promise((resolve) => server.close(() => resolve()))
    },
    'ipadpet-lan-gateway: http',
  )

  ctx.effect(
    () => () => {
      log.info('ipadpet-lan-gateway: disposed')
    },
    'ipadpet-lan-gateway: log',
  )
}
```

如果确定要用 schemastery（Plan B），把 `resolveConfig` 换成：

```js
import z from '@deepseek-ai/schemastery'

export const Config = z.object({
  host: z.string().default('0.0.0.0'),
  port: z.natural().max(65535).default(8791),
  tokenEnv: z.string().default('IPADPET_GATEWAY_TOKEN'),
  transcriptLanguage: z.string().default('zh').volatile(),
})
// apply 里直接用 config（volatile 字段读 config.transcriptLanguage.get()），不再手工 resolveConfig
```

`locale/en.json`：

```json
{
  "meta": {
    "title": "iPad pet LAN gateway",
    "description": "Exposes a LAN HTTP and WebSocket gateway that transcribes iPad pet voice recordings and drives a local DSH agent session."
  }
}
```

`locale/zh.json`：

```json
{
  "meta": {
    "title": "iPad 宠物局域网网关",
    "description": "为 iPad 宠物 App 提供局域网 HTTP 与 WebSocket 网关：转写语音并驱动本机 DSH Agent 会话。"
  }
}
```

`icon.svg`（原创几何图形，可直接落盘）：

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">
  <rect width="64" height="64" rx="14" fill="#1f2937"/>
  <circle cx="24" cy="26" r="7" fill="#f9fafb"/>
  <circle cx="40" cy="26" r="7" fill="#f9fafb"/>
  <circle cx="32" cy="40" r="10" fill="#34d399"/>
  <path d="M10 54h44" stroke="#34d399" stroke-width="4" stroke-linecap="round"/>
</svg>
```

### 5.6 profile 侧必须同步的字段（由 `install_bundle` 自动写，不要手改）

| profile 文件 | 字段 | 安装后应有的值 | 谁写 |
|---|---|---|---|
| `/home/dywu/.dsh/profiles/web/package.json` | `dependencies["@local/dsh-ipadpet-gateway-bundle"]` | `link:/home/dywu/Samba/workspace/ipadpet/dsh-plugin-ipadpet-gateway`（本地目录安装时的**预期**形态；`link:`/`file:` 均不影响识别，见 §11-2） | pnpm `add`（`dsh-plugin-manager/lib/index.js:2801-2806`）|
| 同上 | `dsh.profile.bundles[]` 末尾追加 bundle 名 | `@local/dsh-ipadpet-gateway-bundle` | `selectBundle` → `saveManifest`（`lib/index.js:3048-3075`）|
| `cordis.patch.yml` | —— | **不新增任何行** | 安装流程不写它 |

---

## 6. `install_bundle` 的实际流程、副作用、卸载与日志

### 6.1 工具调用与流程

工具入口：`plugin_manager` action=`install_bundle`，`target` 可为 **绝对本地目录** / npm 包名 / git URL / tarball URL；`approvedBuilds` 只在用户明确同意跑构建脚本后传（`dsh-plugin-manager/lib/types/tools.js:74-152`，错误提示 `:7-22`）。

`installBundle` 实序（`dsh-plugin-manager/lib/index.js:2712-2873`）：

1. **目标校验**：空/以 `-` 开头 → `invalid-spec`；HMR 下若包名已在 profile dependencies → `already-installed`（:2729-2733）。
2. **构建脚本授权**（可选）：先落 `approvedBuilds`（:2734-2737）。
3. **快照**：读取 `package.json`、`pnpm-lock.yaml` 原文用于失败还原（`RESTORED_FILES`，:1546；`readRestoredFiles` :3034-3047）。
4. **pnpm add**：在 profile 目录执行 `pnpm add <spec> [--registry ...]`，按 registry 计划逐个尝试，失败时在尝试之间还原快照（:2788-2818）；本地目录会按调用目录解析成绝对路径，通常保存为 `link:`（预期，未实测）。
5. **确认安装结果**：对比 add 前后的 dependencies 差集，必须恰好多出 1 个包，否则 `ambiguous-install`（:2831-2838）；解析出包目录后读 manifest，**无 `dsh.bundle.patch` → `not-bundle` 并还原**（:2840-2842）。
6. **兼容性检查**：`engines.dsh` / DSH peers 不满足且无 exemption → `incompatible-version`，还原（:2843-2844）。
7. **patch 预读校验**：`loadOverlayPatches` 逐个读 bundle 的 patch 文件（YAML 解析/结构错误在此暴露），失败还原（:2845-2851）。
8. **保存选择**：`selectBundle(name, true)` 把 bundle 追加进 `dsh.profile.bundles` 并原子写回 `package.json`（:3048-3075、`saveManifest` :399-405）。
9. **应用**：`publishAndReload(rows)` → HMR 时 `hmr.reconcileProfile(requiredIds)` 就地重组；无 HMR 时返回 `restart-required`（:2858-2863、`reload` :3129-3141）。
10. **结果**：`{changed, application, stage, target, bundle, version, warnings?, packageResult?, registries?, pendingBuilds?, approvedBuilds?, error?}`（类型见 `lib/types/types.d.ts:147-177`）。

### 6.2 会不会改 profile 的 `package.json` / `cordis.patch.yml`？

| profile 文件 | 安装 | 卸载 | 开关（`set_plugin`/`set_bundle`）|
|---|---|---|---|
| `package.json` | **会**：`dependencies` + `dsh.profile.bundles` | **会**：反选 + 删除 dependency | `set_bundle` 只改 bundles 列表（依赖保留）|
| `cordis.patch.yml` | **不会** | **不会** | `set_plugin` **会**：在最后一个匹配 override 里改 `disabled`，或追加 override（README.md:40；`writePluginEnabled` 在 `setPluginEnabled` 内调用，`lib/index.js:2669-2682`）|
| `pnpm-lock.yaml` | 会（pnpm） | 会（pnpm） | 不变 |
| `compatibility.json` | 仅版本豁免操作会写（README.md:79） | 同 | 同 |

注意：插件**自己的配置**也不允许去改写 profile 的 `cordis.patch.yml`；需要运行期改配置用 `ctx.fiber.entry` + `ctx.get('configEditor').edit(entry, ...)`（`host-plugin.md:66-77`）。

### 6.3 卸载与回滚

卸载：`plugin_manager` action=`remove_bundle`，`target` 传**精确包名**（不带版本范围；`tools.js:143-146`）。实现（`lib/index.js:2905-2932`）：

1. 必须是 profile 依赖或已选中的 bundle，且 `removable` 为真，否则 `not-removable`（:2909）。
2. 无 HMR 且该 bundle 的行随进程启动 → `stop-profile`，提示先停 DSH 再跑 `dsh plugin --profile <p> remove <bundle>`（:2910；README.md:179）。
3. 若启用：先 `selectBundle(name,false)` 反选并重载，让行卸载（:2912-2915）。
4. 还有别的层在用同一批行 → `bundle-in-use`（:2916）。
5. `pnpm remove <name>` 删依赖（:2920-2925），再 `publishAndReload()` 重载。

回滚语义：

- **安装失败/取消**：`package.json` + `pnpm-lock.yaml` 自动还原为快照（README.md:68；:2849、`restoreFiles` :3043-3047）。**已下载的包文件可能留在 `node_modules`/pnpm store**（README.md:179）。
- **安装成功但激活失败**：`application:"failed"`，但「saved dependency and selection」可能保留（README.md:54；`change()` 的失败路径 :3176-3182）。修复代码后重启/HMR 自动再试；必要时先 `remove_bundle` 再重装。
- **卸载**：选中的 bundle 先反选、行停止，再删包；工作区源码目录**不受影响**（link 目标只是一个符号链接）。失败删除可能留下部分依赖变化（README.md:179）。
- 诊断日志在 profile 的 `.plugin-manager/logs/operation-*/pnpm.log`（README.md:179；`operations.js:321-325`）。
- 手工回滚 = 手改 profile 文件（不推荐；规则要求由 plugin_manager 执行，且手改 `~/.dsh` 需要单独审批）。

### 6.4 返回值语义

| 字段 | 含义 | 依据 |
|---|---|---|
| `application: "applied"` | 变更已保存且已生效（有 HMR 时就地重组）| types.d.ts:148-151 |
| `application: "restart-required"` | 已保存，但需重启才生效；`restartReason`: `no-hmr` / `package-moved` / `host-module` / `unmanaged-plugin` / `module-comparison` | types.d.ts:152-153；tools.js:35-41 |
| `application: "overridden"` | 已保存，但更高优先级层（如 preset）覆盖，实际不生效 | tools.js:53-54 |
| `application: "failed"` | 失败；`error.code`（`not-bundle`/`invalid-spec`/`incompatible-version`/`already-installed`/`ambiguous-install`/`stop-profile`/`bundle-in-use`/`operation-error`…），`packageResult.kind`（`pnpm-missing`/`timeout`/`not-found`/`network`/`disk-full`/`permission`/`build-blocked`…） | tools.js:7-33,59-64 |
| `application: "cancelled"` | 调用方取消，文件已还原 | types.d.ts:150 |
| `warnings: string[]` | 操作**未处理**的既有 inactive 行（"Pre-existing inactive entries the operation left as they were"）；新增/变化的失败和显式启用目标未激活才会算失败 | types.d.ts:159-160；README.md:130 |
| `pendingBuilds` | pnpm 拦截的构建脚本 key 列表；传 `approvedBuilds` 重试（需用户明确同意）| types.d.ts:166-169；README.md:72 |
| `bundle`/`version` | 安装成功的 bundle 名（单数）与 manifest 版本 | types.d.ts:162-165 |
| `registries` / `failedAt` | 尝试过的 registry 顺序 / 最后一个失败是 registry 还是 spec 主机 | types.d.ts:170-176 |

> `withNextStep` 会给非 applied 的结果补 `nextStep` 文案（tools.js:47-68）——agent 侧按它提示用户即可。

### 6.5 日志

- **插件写日志用 `ctx.logger`**：`ctx.logger.info/warn/error/debug(...)`，printf 风格（`%s`/`%d`），logger 名默认由 fiber 名派生，带 1000 条内存缓冲与 exporter 机制（`cordis/lib/index.js:1161-1230`）。
- 现有写法与兜底：`const log = ctx.logger; log.info('...')`，或 `if (ctx.logger && typeof ctx.logger.error === 'function')`（job-collector `index.js:1224-1228`；teaching-research `index.js:527`）。
- 不要用 `console.log` 作为主日志（Host 进程可能无附着终端）；`console` 仅作最后兜底。

### 6.6 CLI / GUI 等价路径

- CLI：`dsh plugin --profile web <pnpm args>` 把参数转发给 profile 目录里的 pnpm；`add <abs-dir>` 成功后会自动把带 bundle 声明的新依赖追加进 `dsh.profile.bundles`（`runProfilePnpm` → `reconcile`，`operations.js:577`；`dsh/README.md:18`）。运行中的进程要重启才加载新 JS 模块代（README.md:126、176）。
- GUI：Web 侧栏 Plugins 页与 agent 的 `plugin_manager` 调用同一个 service（README.md:31）；本地目录 target 用绝对路径。
- 权限：`plugin_manager` 每个 action 都要求 `danger-full-access` 或一次调用级审批（`tools.js:77,93-100`；README.md:31）。

---

## 7. 依赖同 profile 已有的 `speech-to-text` 行：怎么声明而不重复插入

**事实**（本机已核实）：

- `speech-to-text` 行由 shipped bundle `@deepseek-ai/dsh-experimental-voice-input-bundle` 的 patch 插入（`.../voice-input-bundle/cordis.patch.yml:1-4`），该 bundle 在 profile 的 `dsh.profile.bundles` 里（`/home/dywu/.dsh/profiles/web/package.json:41`）。
- profile 只对它做「无 insert 的 config 覆盖」（`cordis.patch.yml:149-153`）。
- 运行时该行确实活着：`cordis_inspect_query Config.listConfigs` 返回 `{id:"include:speech-to-text", patchId:"speech-to-text"}`。
- `speechToText` 服务确实在手：Service 契约给出 `hardDependency.inject = ["speechToText"]`、`expression: "ctx.speechToText"`，以及 optional 访问 `ctx.get("speechToText")`。

**正确做法**：

```js
export const inject = ['speechToText']
```

- 插件行**只插自己**，patch 里不要出现 `name: '@deepseek-ai/dsh-experimental-speech-to-text'`。
- 行了顺序无关：激活由服务可用性驱动（`dsh-base/cordis.patch.yml:12-13`）。
- 行不存在/被禁用时：硬依赖让插件保持未激活，Loader 启动组合会报告 missing service（`dsh-app-boot` 的 startup composition：`lib/index.js:58-101`），不会假装成功。
- 若希望网关先起、STT 不可用时降级：改 optional（`ctx.get('speechToText')`），在 `/health` 与请求处理里判空并返回 503。

**不要做的事**：

1. 不要在你的 bundle patch 里 `insert` 一个 `id: speech-to-text` 的行——会和 voice-input bundle 的行 id 冲突（Loader 树内重复 id 抛 `entry <id> already exists`，`cordis-plugin-loader/src/config/tree.ts:153`）。
2. 不要为了「保证有语音服务」而在 bundle 里再插一份 provider 行；本场景 provider 已由 voice-input bundle + `sensevoice-local` 负责（`cordis.patch.yml:149-153` 的 `defaultProvider: sensevoice-local`）。
3. 如果确实需要在**别的 profile** 里也成立，那是 profile 选择哪些 bundle 的问题（把 voice-input bundle 加进 `dsh.profile.bundles`），不是本 bundle patch 的职责。

---

## 8. 插件如何读取自己的配置 / 密钥（token）

### 8.1 三档选择

| 数据 | 推荐位置 | 理由 / 证据 |
|---|---|---|
| 非机密参数（监听地址、端口、语言、超时） | 行 `config`（bundle patch 给默认值，profile patch 覆盖） | 有 schema 校验、GUI 可见可编辑；`host-plugin.md:64` |
| 需要运行期改写、且要持久化的参数 | Config + `configEditor.edit(entry, ...)`；热更新字段用 `.volatile()` | `host-plugin.md:66-77`；cordis README:103-111 |
| 单一固定环境变量（如外部注入的 `IPADPET_GATEWAY_TOKEN`） | 直接 `process.env[config.tokenEnv]` | credentials README:32 "If you only need one fixed environment variable, read that variable directly and skip the store."；现有插件也这么读私有账号（profile patch 里 MCP env 传账号文件路径，`cordis.patch.yml:114-127`）|
| 需要落盘、可轮换、多客户端/多 grant、或需要 UI 枚举「已授权」 | `ctx.credentials` 记录（`modifyRecord`/`readRecord`，键 `<scope>/<id>`） | `host-plugin.md:77`；credentials README:63-81；key 语法 `credentialKey('llm-pi-ai','openai-codex')` |

### 8.2 推荐组合（本插件）

1. **配置**：`host`/`port`/`tokenEnv`/`transcriptLanguage` 放 Config（或 Plan A 手工校验）；token **不放** Config。
2. **网关 token**：
   - 首选：由用户/部署方在启动环境里注入 `IPADPET_GATEWAY_TOKEN`，插件用 `process.env[config.tokenEnv]` 读。fail-closed：未设置时拒绝局域网请求（只允许本机调试），并在 `/health` 暴露 `configured:false`。
   - 需要 iPad App 配对后动态下发/轮换：token 存 credentials record：
     ```js
     // 建议 scope 用插件注册名，id 用客户端标识；两段都须匹配 /^[a-z][a-z0-9-]*$/
     // 零依赖写法可直接用字符串键（brandString 是恒等函数）；也可 import credentialKey 辅助校验
     const key = `ipadpet-lan-gateway/${clientId}`
     const hit = await ctx.credentials.readRecord(key)              // 读
     await ctx.credentials.modifyRecord(key, async () => ({ kind: 'grant', payload: { token } }))  // 写
     ```
     声明方式：`export const inject = ['speechToText', 'credentials']`，或 `const credentials = ctx.get('credentials')` 做可选（`host-plugin.md:77`）。
   - 每次请求按需读取/校验，不要跨请求缓存密钥（credentials README:91）。
3. **不要**把 token 明文写进 `cordis.patch.yml`/bundle patch：那是 profile 里长期保存、可被 GUI 展示、会进备份的文本（`host-plugin.md:77` 明确要求 secrets 放 credentials 而不是 configuration）。
4. 若要生成一次性配对码：内存 + `ctx.effect` 定时过期即可，别落配置。

### 8.3 本 profile 的 credentials 可用性（已核实）

- 抽象服务：`cordis_inspect_query Service.listService` 返回 `credentials`。
- 底层存储行已加载：`Config.listConfigs name=@deepseek-ai/dsh-credentials-local` → `{id:"include:credentials", patchId:"credentials", status:"schema", acceptsMissing:true}`，config 接受 `path` / `dshHome` / `watch` / `debounceMs`（缺省用默认凭据文件路径）。
- 因此 `ctx.credentials.modifyRecord/readRecord` 在本 profile 可用；仍建议 `ctx.get('credentials')` 可选读取 + 环境变量回退，避免将来换 profile 时硬失败。

**零 import 使用 credentials 的写法**（与 §5.5 的 Plan A 一致）：

- `credentialKey(scope, id)` 的运行时值就是 `` `${scope}/${id}` ``（`dsh-brand/lib/index.js:20-22` 的 `brandString` 是恒等函数，只做类型标记），所以在 JS 里可以直接传字符串键；
- 两段都必须匹配 `/^[a-z][a-z0-9-]*$/`（`dsh-credentials/lib/index.js:15`），例如 `ipadpet-lan-gateway/client-01`；
- 若坚持用 `credentialKey()` 辅助函数，则需 `import { credentialKey } from '@deepseek-ai/dsh-credentials'`（走 §3.5 的拦截机制，未实测）。

---

## 9. 安装 / 卸载操作清单与风险

### 9.1 安装前检查（1 分钟）

```bash
# 1) JSON / YAML 语法
python3 -c 'import json;json.load(open("package.json"))'
python3 -c 'import yaml;yaml.safe_load(open("cordis.patch.yml"))'
# 2) JS 语法（真实文件）
node --check index.js
# 3) 目录里确有 locale/icon 与 dsh.bundle 声明
ls locale; grep -n '"dsh"' package.json
```

### 9.2 安装

1. 用 agent 工具（需 full access / 审批）：
   `plugin_manager {action:"install_bundle", target:"/home/dywu/Samba/workspace/ipadpet/dsh-plugin-ipadpet-gateway"}`
2. 读结果：`application` 必须是 `applied`。
   - `restart-required` → 按 `nextStep` 提示重启 DSH（本 profile 有 HMR，通常不会）。
   - `failed` → 看 `error.code` + `packageResult.kind` + `.plugin-manager/logs/.../pnpm.log`。
   - `pendingBuilds` → 用户明确同意后带 `approvedBuilds` 重试（本插件无构建脚本，应不会出现）。
3. 验证（不要只看日志）：
   - `cordis_inspect_query {provider:"Config", method:"listConfigs", input:{name:"@local/dsh-ipadpet-gateway-bundle"}}` → 应有 `{patchId:"ipadpet-lan-gateway", status:"schema"}`（若省略 Config，则用 `list_bundles` 或 Plugin Manager 页确认行存在）。
   - `cordis_inspect_query {provider:"Service", method:"listService"}` 不应新增缺失服务。
   - 局域网另一台设备 `curl http://<host>:8791/health`。
   - GUI Plugins 页核对标题/描述/图标（en + zh）；无浏览器控制时报告「资源已检查、渲染未验证」。
4. 等价 CLI（不推荐在运行中会话里做；会绕过 manager 的即时应用）：`dsh plugin --profile web add /abs/dir` 然后重启。

### 9.3 卸载

1. `plugin_manager {action:"remove_bundle", target:"@local/dsh-ipadpet-gateway-bundle"}`
2. 预期：`applied`；profile `package.json` 的 dependencies 项与 bundles 列表项消失；工作区源码目录保留。
3. 若提示 `stop-profile`：先停 DSH，再 `dsh plugin --profile web remove @local/dsh-ipadpet-gateway-bundle`。
4. 若安装曾失败但依赖被保留：先 `remove_bundle` 再重装（`already-installed` 的解法，tools.js:12）。

### 9.4 风险与规避

| 风险 | 影响 | 规避 |
|---|---|---|
| **审批被拒**：本会话 approval 被禁用，`plugin_manager` 的任何 action 都会自动拒绝 | 无法在当前会话安装 | 由 Lead/用户在 full-access 会话或 Web Plugins 页执行；本文档只做契约 |
| 忘写 `type:"module"` | `import` 时语法错误 → 安装 `application:"failed"` | 用 §5.3 模板 |
| patch YAML 结构错误 / 文件缺失 | 安装校验阶段抛错，profile 文件自动还原 | 安装前 `yaml.safe_load` |
| 行 id 与别的 bundle 冲突 | Loader `entry <id> already exists`，激活失败 | 行 id 用 `ipadpet-lan-gateway` 这类唯一前缀 |
| `apply` 内同步抛错（如 listen 同步失败） | 激活失败，依赖/选择可能保留 | 端口错误在事件回调里 catch，只记日志 |
| 端口被占（DSH web 3080 等） | 网关不可用 | 默认 8791，`/health` 报状态；提供配置项 |
| 监听 0.0.0.0 暴露到局域网 | 未鉴权端点可达 | fail-closed token 校验；仅放开必要路径 |
| 本地目录安装 = `link:`，改代码后模块代可能不刷新 | 需重启/HMR 重载；行为与旧代码不一致 | 验证前重启；README.md:176 |
| bundle 加了 npm 依赖却期望被安装 | link 安装不会装依赖，运行时 `ERR_MODULE_NOT_FOUND` | 零依赖（首选），或改成 tarball/registry 安装方式 |
| 写 `engines.dsh` 范围过窄 | `incompatible-version` 直接拒装 | v1 省略；或写 `>=0.2.2-rc.1` 并实测 |
| 手动编辑 `~/.dsh` 文件 | 需审批、易破坏其它插件/注释/`!!js` | 一律走 `plugin_manager` |

---

## 10. 来源索引（文件:行号）

**技能与官方文档**

- Host bundle / 导出形状 / 显示清单 / 配置持久化 / 安装观察：`/home/dywu/.npm/_npx/b86ed90107c62dab/node_modules/@deepseek-ai/dsh-agent-preset/skills/cordis-plugin-development/references/host-plugin.md:3,7-18,20-27,31-36,38-55,57-64,66-77,79-83`
- UI bundle 何时需要 `dsh.client`：`.../references/ui-plugin.md:3-8`
- Loader 方言与层叠概念：`cordis-composition-reference` 技能（已在本会话加载）
- `dsh` CLI 与 profile 结构：`/home/dywu/.npm/_npx/b86ed90107c62dab/node_modules/@deepseek-ai/dsh/README.md:18,37`

**DSH 安装内实现**

- patch 算法：`.../node_modules/@deepseek-ai/cordis-plugin-include/src/patch.ts:5-16`（PatchOptions）、`:47-109`（applyPatches：insert 65-83 / override 86-105）
- 行模型：`.../cordis-plugin-loader/src/config/entry.ts:10-23`（EntryOptions；`disabled` :20、`inject` :22）、`:76-92`（disabled 传染）、`src/config/isolate.ts:8,25,70+`
- 重复行 id：`.../cordis-plugin-loader/src/config/tree.ts:153`
- 模块归一化：`.../cordis-plugin-loader/src/index.ts:209-216`（`exports.default ?? exports`）
- Cordis 插件形状/注入/Config：`.../cordis/lib/index.js:1605-1610,1691-1704,244-250`；生命周期与 volatile：`.../cordis/README.md:45-67,103-115`；Logger：`.../cordis/lib/index.js:1161-1230`
- bundle 识别与 patch 读取：`.../dsh-app-boot/lib/index.js:1335-1349`、`:4708-4752`、`:1774-1783`（resolveBundleDir）
- 显示元数据与图标：`.../dsh-app-boot/lib/index.js:2863-2896`（icon 限制）、`:3002-3033`（locale/meta）
- 兼容性与平台：`.../dsh-app-boot/lib/index.js:1063-1067`、`:1129-1160`
- 层序与 profile 加载：`.../dsh-app-boot/lib/index.js:1795-1860`（`loadProfileDirectory`）；`.../dsh-base/cordis.patch.yml:1-6,12-13`
- 运行时解析（linked 包 + peer 拦截）：`.../dsh-app-boot/lib/index.js:1439-1461,2133-2140,2462+`
- 安装流程：`.../dsh-plugin-manager/lib/index.js:2712-2873`；还原：`:1546,3034-3047`；选择 bundle：`:3048-3075`；重载：`:3129-3141`；change/结果：`:3142-3211`
- 卸载：`.../dsh-plugin-manager/lib/index.js:2905-2932`
- 结果类型：`.../dsh-plugin-manager/lib/types/types.d.ts:147-177`；工具 schema：`.../lib/types/tools.js:7-152`
- 行为说明：`.../dsh-plugin-manager/README.md:31,37,40,44,46,48,50,52,54,60,68,72,79,126,130,176,179`
- CLI pnpm 透传与 reconcile：`.../dsh-plugin-manager/lib/types/operations.js:315-334,577`；`.../dsh/lib/plugin-DscIHF4k.js:58-100`
- 语音服务契约：`.../dsh-experimental-speech-to-text/lib/index.js:7-24,111-112,201`；`package.json:40-46`
- shipped bundle 实例：`.../dsh-experimental-voice-input-bundle/package.json:1-54`、`cordis.patch.yml:1-13`、`locale/en.json:1-7`
- 依赖链（schemastery 属安装 scope）：`.../dsh/package.json:23,100`；`voice-input-bundle/package.json:37`；`speech-to-text/package.json:42`

**本机 profile（只读）**

- `/home/dywu/.dsh/profiles/web/package.json:4-25`（dependencies：`link:`/`file:`/github/registry 范围混合）、`:26-46`（`dsh.profile`, bundles 15 个，voice-input 在 :41）
- `/home/dywu/.dsh/profiles/web/cordis.patch.yml:66-99`（insert 示例）、`:102-106`（insert subagent）、`:145-148`（llm override）、`:149-153`（**无 insert 覆盖 speech-to-text**）、`:154-158`（session-log）、`:159`
- `/home/dywu/.dsh/profiles/web/cordis.yml:1-4`（空根，组合靠 patch 层）
- `/home/dywu/.dsh/profiles/web/pnpm-workspace.yaml:1-9`（`autoInstallPeers:false`、`nodeLinker:hoisted`、`allowBuilds`）
- 运行时核实（`cordis_inspect_query`）：`@deepseek-ai/dsh-hmr` 行存在（`include:hmr`）；`speech-to-text` 行存在（`include:speech-to-text`，patchId `speech-to-text`，status `schema`）；`speechToText` 服务契约（hardDependency `inject:["speechToText"]`）；`credentials` 服务存在且底层 `@deepseek-ai/dsh-credentials-local` 行存在（`include:credentials`，patchId `credentials`）；`plugin-manager` 行存在；**反例**：`@local/dsh-ai-router-tools`、`@local/dsh-ai-router-dashboard` 的 `listConfigs` 返回 0 条（依赖已装但 bundle 未选中 → 行未加载），`@local/dsh-subagent-settings` 有行（由 profile patch 插入）

**workspace 参考插件**

- `/home/dywu/Samba/workspace/dsh-plugin-job-collector/package.json:1-35`、`cordis.patch.yml:1-5`、`index.js:1219-1228,1312-1322,1333-1352,1738-1740`、`locale/en.json:1-5`
- `/home/dywu/Samba/workspace/dsh-plugin-teaching-research/package.json:1-33`、`cordis.patch.yml:1-5`、`index.js:506-527`
- `/home/dywu/Samba/workspace/dsh-ai-router/dsh-plugin/package.json:1-28`、`cordis.patch.yml:1-12`、`index.js:16-19,546`
- `/home/dywu/Samba/workspace/tools/dsh-subagent-settings/package.json:1-39`、`cordis.patch.yml:1-6`、`index.js:21-22,273`
- `/home/dywu/Samba/workspace/dsh-ai-router/dsh-plugin-dashboard/package.json:1-38`、`cordis.patch.yml:1-10`、`index.js:12-15,71`

---

## 11. 不确定 / 未验证清单

1. **workspace（link）插件 import `@deepseek-ai/schemastery` / `@deepseek-ai/cordis`**：拦截机制由 `dsh-app-boot` 源码推断（安装 scope 表 + `peerDependencies` 触发），本环境无 workspace `node_modules`、现有 5 个插件也都不 import `@deepseek-ai/*`，**未实测**。v1 采用零 import 方案；若采用 `Config`，请先做最小烟测（`Config.listConfigs` 能看到 schema）。
2. **本地目录安装后 pnpm 保存的确切 spec**（`link:` vs `file:`）：profile 现有 workspace 依赖全部是 `link:`，但未实测本次 `pnpm add /abs/dir` 的落盘结果；`install_bundle` 靠依赖差集识别包名，两种形式都能处理。
3. **HMR 下新 bundle 是否一定 `applied`**：本 profile 确认 `@deepseek-ai/dsh-hmr` 行存在（`include:hmr`），但未实际安装验证；结果以 `application`/`nextStep` 为准，不做假设。
4. **`dsh plugin --profile web add <abs-dir>` 后运行中进程的生效方式**：文档说需重启加载新模块代（README.md:126,176），未实测与 HMR 交互的细节。
5. **GUI Plugins 页是否接受「本地绝对目录」作为安装 target**：CLI/agent 工具明确支持绝对目录；GUI 安装入口的 spec 输入是否同样接受，未验证。
6. **`ws` npm 包在 DSH 安装内是否可解析、局域网 0.0.0.0 绑定与 WS 升级实现**：属 task-1（host-agent-api.md）范围；本文只用 `node:http` 骨架占位。
7. **`speechToText` 的 `resolve()`/`transcribe()` 精确调用形态与 WAV 16k mono 要求**：属 task-1 范围，本文只声明服务依赖；`SpeechRequest`/`SpeechInput` 类型在 inspect 输出中可见（`audio: Uint8Array`, `language`）。
8. **`dsh.bundle.platforms` / `listedByDefault` 对自建 bundle 的默认 GUI 可见性**：只读到代码路径（README.md:44、`lib/index.js:2217-2220`），未实测默认值。
9. **图标/标题在 GUI 的实际渲染**：本会话无浏览器控制，仅能从安装资源层面核对，渲染未验证（`host-plugin.md:53` 要求如实报告）。
10. **`engines.dsh` 的范围写法**：当前 DSH `0.2.2-rc.1`，satisfies 用 `includePrerelease:true`；`^0.2.2-rc.1` 是否覆盖后续 rc/dev 版本未逐例验证，故建议 v1 省略。
11. **安装/卸载的实际执行**：本会话 approval 被禁用，所有 `plugin_manager` 写操作会自动拒绝，因此本契约的安装/卸载链路只按源码与文档核对，**没有真机执行**。