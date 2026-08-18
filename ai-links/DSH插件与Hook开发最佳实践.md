---
title: DSH 插件与 Hook 开发最佳实践
aliases: [DSH插件开发, DSH Hooks, Cordis插件]
tags: [ai/agent, ai/skills, ai/links]
created: 2026-08-17
updated: 2026-08-17
status: review
---

# DSH 插件与 Hook 开发最佳实践

See also: [[AI-Links-KB-Home]] | [[DSH跨框架Skills与MCP加载]] | [[DSH-TUI插件使用手册]] | [[2026-08-16-AI链接综述与归档]] | [[AGENTS]]

> [!abstract] 概述
> 本文整理 DeepSeek Harness（DSH）插件与 Hook 的开发与使用最佳实践，覆盖 Cordis 插件模型、工具/服务/事件开发、hooks 桥接子系统、发布分发与防御性模式。资料来源：官方仓库 deepseek-harness-official（`docs/user/develop/**`、`docs/capability-seams.zh.md`、`docs/defensive-patterns.zh.md`、`docs/subsystems/{tools,approval}.zh.md`、`packages/hooks/**`）、deepseek-harness-desktop-src（`docs/plugin-development.md`、`docs/plugin-ecosystem.md`、`dsh-plugin-desktop/docs/plugin-services.zh.md`、`dsh-community-fabric/docs/research/mature-plugin-frameworks.zh.md`）、`dsh-tui-repo/cordis.patch.yml` 与本机 `C:\Users\28064\.dsh` profile 实测，均为 2026-08 快照。

---

## 一、插件体系基础

> 来源：`docs/user/develop/basic/index.zh.md`、`docs/user/develop/framework/events.zh.md`、`docs/user/develop/framework/service.zh.md`、`docs/event-producer-consumer.zh.md`、`docs/user/develop/basic/publish.zh.md`

### 1.1 插件是什么：导出 `apply(ctx)` 的模块

插件是一个导出 `apply` 函数的 TypeScript 模块。框架在加载时调用 `apply` 并传入 `ctx`（Context 上下文对象），一切能力都通过 `ctx` 注册：

```ts
import type { Context } from '@deepseek-ai/cordis'

export const name = 'my-plugin'

export function apply(ctx: Context) {
  // 在这里注册能力
}
```

| 形态 | 写法 | 适用场景 |
|---|---|---|
| 函数形式 | `export function apply(ctx)` | 绝大多数插件（默认选择） |
| 对象形式 | `export default { name, inject, apply(ctx) }` | 需要携带元数据的模块 |
| 类形式 | `export default class X extends Service` + `super(ctx, 'name')` | 向其他插件**提供服务**时 |

关键约定：

- **自动清理**：通过 `ctx` 注册的任何东西（事件监听、工具、定时器）在插件卸载时自动清理；需要手动清理的资源（如网络连接）用 `ctx.effect(() => { ...; return cleanup })`，返回的清理函数在卸载时执行。
- **`inject` 声明依赖**：`export const inject = ['tools']` 保证 `apply` 执行时依赖服务已就绪；服务未就绪则插件等待，不执行。

### 1.2 事件：生产者-消费者的松耦合扩展点

事件是 Cordis 插件间通信的核心机制，命名遵循 `namespace/action`（如 `agent/step`、`tools/result`、`session/event`）。四种分发模式适用于不同契约：

| 模式 | API | 语义 |
|---|---|---|
| `emit` | `ctx.emit` / `ctx.on` | 广播；监听器同步执行，返回值忽略 |
| `bail` | `ctx.bail` | 短路；第一个非 null/false/undefined 返回值即最终结果 |
| `serial` | `ctx.serial` | 顺序执行并等待异步结果；首个有效返回值终止后续 |
| `waterfall` | `ctx.waterfall` | 流水线；监听器**必须调用 `next()`** 传递下游，不调用即短路（故意设计，用于拦截/网关） |

> [!warning] waterfall 规则
> `waterfall` 监听器不调用 `next()` 会短路整个流水线——这是实现拦截逻辑的**正确**姿势，但忘记调用会意外吞掉下游。

- **类型安全**：用 TypeScript 声明合并扩展 `interface Events`，`ctx.on/emit` 即获得类型推断。
- **监听器即 effect**：`ctx.on()` 注册的监听器随插件卸载自动移除。
- **与持久化会话事件区分**：`turn/*`、`step/*`、`tool/call`、`tool/result`、`compaction/*` 是**持久化的会话事件类型**，不是同名 Cordis 事件；观察它们应监听 `session/event` 并检查 `event.type`。
- 官方维护了事件生产方/消费方矩阵（`docs/event-producer-consumer.zh.md`），例如 `tools/pre-execute` 由 `tools` 派发、被 `hooks-claude-code`/`hooks-codex`/`tool-jobs` 监听——选扩展点前先查该矩阵。

### 1.3 服务：挂载在 ctx 上的命名能力

`tools`、`llm`、`agents` 都是服务（`ctx.tools`、`ctx.llm`、`ctx.agents`）。任何插件都可以提供服务：

```ts
import { Service, type Context } from '@deepseek-ai/cordis'

declare module '@deepseek-ai/cordis' {
  interface Context { metrics: MetricsService }  // 声明合并获得类型
}

export default class MetricsService extends Service {
  static inject = ['llm']            // 服务也可以依赖其他服务
  constructor(ctx: Context) { super(ctx, 'metrics') }
  record(event: string, value: number) { /* ... */ }
}
```

| 依赖行为 | 规则 |
|---|---|
| 必需依赖 | `inject` 声明；服务缺席 → 插件不加载 |
| 可选依赖 | 不写 inject，用 `ctx.get('metrics')` 查询，判空后使用 |
| 服务消失 | 依赖它的插件自动 dispose；服务重现后自动重载（防止调用已不存在的服务） |
| 服务隔离 | `group: true` + `isolate: { shell: true }` 让不同插件组看到同一服务的不同实例（如两组 Bash 各自超时值） |

> [!tip] 服务清单不要手抄
> 各服务的公开方法、签名由仓库自动生成到子系统页面（如 `docs/subsystems/core.zh.md` 的 `cordis-surface` 区块）与 TypeScript 接口。开发时以生成区块和 TS 类型为准。

### 1.4 bundle 与 patch：配置即组合

安装机制建立在两个概念上，均由 `package.json` 描述，但 `dsh` 键下的 manifest 不同：

| 概念 | manifest | 回答的问题 |
|---|---|---|
| **组合包（bundle）** | `dsh.bundle` | "这个包贡献什么？" —— 一个插入/覆盖插件行的 patch 文件 |
| **profile** | `dsh.profile` | "这套配置由哪些组合包按什么顺序组成？" |

- 组合包是**你编写并分发**的东西（npm 包 + 一个 `cordis.patch.yml` 配置层）；profile 是**用户**用 `dsh --profile <name>` 启动的目录（`$DSH_HOME/profiles/<name>`）。没有东西同时是两者。
- patch 是一个 patch 条目的 YAML 数组：按 `id` 覆盖行、`disabled: true` 禁用行、`insert:` 插入行列表、`!!js` 表达式求值。

> [!warning] patch 覆盖是整行替换
> 后应用层按行胜出，且 patch 替换目标行的**整个 `config` 值**，不深度合并各键。覆盖某行时必须重述该行需要的每一个键，而不是只写改动的那个。

### 1.5 profile 概念与本机实测

生效配置在空根之上按以下顺序逐层组合（后层按行胜出）：

1. profile 的 `dsh.profile.bundles` 列表中的各组合包 patch（按列表顺序，`@deepseek-ai/dsh-base` 永远第一）；
2. profile 自己的 `cordis.patch.yml`（用户补丁层）；
3. home 级 `$DSH_HOME/cordis.patch.yml`（各 profile 共享的机器本地偏好）；
4. 每个 `--patch <path>` overlay（按 argv 顺序）。

> [!info] 本机 profile（`C:\Users\28064\.dsh\profiles`，2026-08 实测）
> | profile | `dsh.profile.bundles` | 备注 |
> |---|---|---|
> | `web` | `@deepseek-ai/dsh-base` → `@deepseek-ai/dsh-web-app` | 浏览器界面 |
> | `tui` | `@deepseek-ai/dsh-base` → `@dsh-tui/dsh-tui` | 终端界面（见 [[DSH-TUI插件使用手册]]） |
> | `desktop` | `@deepseek-ai/dsh-base` → `@deepseek-ai/dsh-web-app` | 桌面壳（bundles 同 web） |
>
> 三个 profile 的 `cordis.patch.yml` 目前均为空数组 `[]`（注释说明其为"应用于每个 bundle 层之后的补丁层"）；web/desktop 无外部依赖，tui 依赖 `@dsh-tui/dsh-tui: ^0.1.2`。

---

## 二、插件开发流程

> 来源：`docs/user/develop/basic/publish.zh.md`、`docs/user/develop/practice/index.zh.md`、`docs/user/develop/basic/config.zh.md`、`docs/capability-seams.zh.md`

### 2.1 声明插件：`dsh.bundle` manifest

组合包目录三件套：

```
hello-plugin/
├── package.json       # 声明 dsh.bundle
├── cordis.patch.yml   # profile 列出此 bundle 时应用的层
└── index.js           # patch 行引用的插件模块
```

```json
{
  "name": "dsh-hello-plugin",
  "version": "0.1.0",
  "type": "module",
  "main": "index.js",
  "files": ["index.js", "cordis.patch.yml"],
  "dsh": { "bundle": { "patch": "./cordis.patch.yml" } }
}
```

```yaml
# cordis.patch.yml —— 与 --patch overlay 同构，但按包名（而非相对源码路径）引用
- insert:
    - id: hello
      name: dsh-hello-plugin
```

- 没有 `dsh.bundle` 声明的包也可安装，但只作为普通依赖：`dsh plugin` 打印警告且不激活任何层——供插件包 import 的库就用这种格式。

### 2.2 能力三角色：Service Definition / Provider / Consumer

一项能力足够通用、需要可替换提供方时（例如 Bash 执行），harness 区分三种角色；角色需要独立演进或替换时放入不同包：

| 角色 | Bash 实例 | 职责 |
|---|---|---|
| Service Definition | `dsh-shell` | 定义 Cordis 服务与 Request/Result 类型 |
| Service Provider | `dsh-bash-local` | 具体实现（本地执行命令） |
| Consumer | `dsh-tool-bash` | 把能力暴露为模型可调用的工具 |

```ts
// 1. Definition：抽象 Service + 声明合并
export abstract class MyCapService extends Service {
  constructor(ctx: Context) { super(ctx, 'myCap') }
  abstract execute(request: MyCapRequest): Promise<MyCapResult>
}

// 2. Provider：ctx.plugin(MyCapLocal) 挂载实现
// 3. Consumer：inject ['tools', 'myCap']，execute 里调 ctx.myCap.execute(...)
```

设计要点：

- **不要预防性拆分**：只有角色需要独立演进时才分包，简单工具插件无需拆分。
- **Definition 拥有 Request/Result 类型**；Provider 与 Consumer 互不依赖，都只依赖 Definition。
- **显式优于隐式**：实现应通过显式的 `resolve(request): Spec` 处理默认值，而非在 `run()` 里藏 `?? default`。

### 2.3 ctx 服务消费：以 seams 表为准

插件作者可消费的 ctx 服务见 `docs/capability-seams.zh.md`（`seam` = 可替换能力缝、`core` = 核心主干、`bundle` = 组合点）：

| ctx 键 | 角色 | 说明（节选） |
|---|---|---|
| `ctx.tools` | core | 工具注册表 + 受守卫的执行管线 |
| `ctx.skills` | seam | 合并各提供方的 skill 目录 |
| `ctx.llm` | seam | LLM 适配器注册表 |
| `ctx.approval` | seam | 一次性权限决策（`approval/request` waterfall） |
| `ctx.shell` | seam | Bash 执行器（`bash-local`/`bash-sandbox`/`pwsh-local` 可替换） |
| `ctx.fs` / `ctx.sandbox` | seam | 文件系统/进程沙箱提供方 |
| `ctx.sessionPersistence` | seam | 会话持久化（jsonl/sqlite 后端） |
| `ctx.subprocess` / `ctx.jobs` | seam | 子进程 seam / 后台作业注册表 |

> [!note] 不存在 `ctx.hooks` 服务
> 官方 seam 表中**没有** `ctx.hooks`：hooks 桥接插件消费的是 `ctx.shell`（执行 shell hook）与 `ctx.sessionPersistence`（解析 `transcript_path`），其拦截点是 `agent/*`、`tools/*`、`subagent/*` 事件（见第四节）。设计 hook 能力时应沿用这一模式，而非期待一个 hooks 注册表服务。

### 2.4 配置 schema：Schemastery

插件导出一个 `Config` 类型和**同名**的 Schemastery schema，默认值直接写在 schema 中：

```ts
import Schema from '@deepseek-ai/schemastery'

export interface Config {
  greeting: string
  maxRetries: number
  verbose?: boolean
}

export const Config: Schema<Config> = Schema.object({
  greeting: Schema.string().default('Hello'),
  maxRetries: Schema.number().default(3),
  verbose: Schema.boolean().default(false),
})

export function apply(ctx: Context, config: Config) { /* config 已校验并填充默认值 */ }
```

```yaml
- insert:
    - id: hello
      name: './src/my-plugin.ts'
      config:
        greeting: 'Hi there'
        maxRetries: 5
```

- 不要导出普通对象作为 `Config`——不满足 Cordis 要求的 Standard Schema 接口。
- **无硬编码可调参数**：凡不同部署可能取不同值的参数必须定义为配置字段。检验标准："能否在 `cordis.yml` 里改这个值而不改代码？"
- **配置错误要响亮**：schema 表达自身完备约束，无效配置在插件加载时失败并给出明确错误；对服务的引用需要依赖注入。
- **配合 HMR**：修改 `cordis.yml` 中某插件的 `config` 会触发热替换——卸载旧实例、加载新实例，注册皆 effect 会自动清理，不残留旧注册。

---

## 三、工具开发

> 来源：`docs/user/develop/basic/tool.zh.md`、`docs/subsystems/tools.zh.md`、`docs/subsystems/approval.zh.md`

### 3.1 最小工具：`ctx.tools.register(defineTool(...))`

```ts
import { defineTool } from '@deepseek-ai/dsh-tools'

export const name = 'greet-tool'
export const inject = ['tools']   // 让 Cordis 等待工具注册表就绪

export function apply(ctx: Context) {
  ctx.tools.register(defineTool({
    name: 'greet',
    description: 'Greet someone by name.',
    parameters: {
      name: { type: 'string', required: true, description: 'The name to greet' },
    },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(args) {
      return `Hello, ${args.name}!`
    },
  }))
}
```

- `defineTool` 根据 `parameters` 推导并**校验** `args`，`execute` 返回 `output.schema` 声明的规范值，`output.render` 把规范值转为面向模型的内容。
- `register()` 返回精确的 disposer（卸载工具）；作用域内注册**遮蔽**全局同名工具，`run_code` 为保留名。
- `schemas()` 通过显式允许列表构建面向模型的 schema：`output`/`execute`/`finalizeContent`/`timeoutMs`/`isConcurrencySafe`/`presentCall`/`presentResult` **绝不泄漏到模型请求**。

### 3.2 `ToolDefinition` 关键字段

| 字段 | 说明 |
|---|---|
| `output.schema`（必需） | 规范输出的 JSON Schema，对每个成功规范值强制执行 |
| `output.render(args, value)` | 纯投影：规范值 → 模型内容 |
| `execute(args, exec)` | 只返回规范 lossless-JSON 值；异步工作必须观察/转发 `exec.signal` 并等待自有工作完全停稳 |
| `finalizeContent?` | 同步最后一公里变换，对每个归一化结果**恰好调用一次**，必须 total 且不抛异常 |
| `timeoutMs?` | 协作式超时预算（由 `tools/execute` 包装层执行），**绝不下发模型**；声明它即承诺工具把 `exec.signal` 转发给可达到停稳的实现 |
| `isConcurrencySafe?` | 纯同步分类器，仅严格返回 `true` 才可并行；声明后不得修改父级状态 |
| `presentCall?/presentResult?` | UI 展示意图（card 联合类型：generic/terminal/diff/search/read/web），必须纯且无副作用（流式与回放都会调用） |

- 统一 JSON 值 schema DSL：`string/number/integer/boolean/null/array/object/json/oneOf`；显式对象必须声明 `additionalProperties`；类型推断精确到 16 层容器后回退 `JsonValue`。
- 错误路径：参数不匹配抛 `ToolArgsError`（`INVALID_ARGS`）；函数体或后置策略产出无效值抛 `ToolOutputError`（`INVALID_TOOL_OUTPUT`）；未知工具映射为 `UNKNOWN_TOOL`——调用失败但**不终止当前轮次**。

### 3.3 工具执行管线（pre/post-execute seam）

`ctx.tools.execute()` 的调用依次经过：

```
tools/pre-execute（allow/deny/ask waterfall）
  → 单调 guard（只能收紧，不能放宽）
  → tools/execute（环绕分派包装层，只能替换 signal）
  → tools/post-execute（检查/替换结果）
  → finalizeContent（定义自有）
  → tools/result（不可变权威结果，观察者失败被隔离）
```

| 阶段 | 决策类型 | 要点 |
|---|---|---|
| `tools/pre-execute` | `PreToolDecision` = `{kind:'allow'}` / `{kind:'deny'; reason}` / `{kind:'ask'; reason?}` | `ask` 仅在审批返回 `allowed-once` 后执行；无审批通道/服务/agent 时转为拒绝；**参数不可改写**（历史、审计、UI、执行必须一致） |
| guard | `ToolGuard` 返回 reason 即拒绝，`undefined` 放行 | 无 allow 结果 → 监听器顺序无法把拒绝变回允许 |
| `tools/execute` | 环绕包装（超时/重试/度量） | 只能替换 `exec.signal`；注册表在函数体前重新融合调用方 signal，替换无法脱离调用方取消 |
| `tools/post-execute` | `PostToolDecision` = accept（可换 content 或 value，不可同时换）/ block（纠正反馈变 error） | 内容替换是**展示策略而非保密策略**；要隐藏值必须 block 或替换 value |
| `tools/result` | emit 观察 | 执行与结果深冻结；观察者异常被包含 |

### 3.4 审批接入

来源：`docs/subsystems/approval.zh.md`。审批 seam 回答"这个具体操作是否可以继续"：

```ts
type ApprovalOutcome = 'allowed-once' | 'rejected' | 'cancelled' | 'unavailable'
type ApprovalPolicy = 'ask' | 'never'
```

- **闭合结果，失败关闭**：`allowed-once` 仅授权所询问的那一次操作；调用方对 `rejected`/`cancelled`/`unavailable` 一律拒绝。应答者缺失、抛异常或不合规 → `unavailable`（而非放行）。
- `ctx.approval.request(req)`：要求请求所属会话处于未结束的轮次内；追加 `approval/asked` → 取结果 → 追加 `approval/decided`。审计事件仅写日志，不进模型 transcript。
- 分发是 **`approval/request` waterfall**：应答者返回结果即占据唯一决策槽，否则调用 `next()` 委托。UI 通道提供人类应答者；ACP 桥为其 agent 提供一次性机器决策。
- **按会话策略**：`ask`（默认）委托应答者链，链空则 fail-closed `unavailable`；`never` 确定性返回 `rejected` 且**在 waterfall 分发之前**强制执行（后续 prepend 的应答者也无法绕过）——CI/无人值守场景用 `never`。
- `ApprovalRequest` 有意**省略工具参数**：应答者通过 `callId` 把提示挂到已流式输出的工具调用上，避免渲染另一份可能漂移的副本。
- 工具侧接入点：在 `tools/pre-execute` 返回 `{kind:'ask'}`（见 3.3），由注册表调用审批服务闭合结果。

---

## 四、Hooks 机制

> 来源：`packages/hooks/README.zh.md`、`packages/hooks/hook-protocol/README.zh.md`、`packages/hooks/hooks-claude-code/README.zh.md`、`packages/hooks/hooks-codex/README.zh.md`、`docs/capability-seams.zh.md`、[[DSH跨框架Skills与MCP加载]]（dsh-bridges 部分）

### 4.1 定位：桥接 + 共享协议

hooks 子系统让用户像用 Claude Code / Codex 一样，在生命周期节点扩展 agent：把桥接插件指向现有 `hooks.json`，即可忠实运行这些外部 shell 钩子。

| 包 | 职责 | 形态 |
|---|---|---|
| `@deepseek-ai/dsh-hook-protocol` | 共享 shell 钩子协议库（matcher、退出码/stdout codec、`ctx.shell` 执行、最严格合并、`hook/*` 事件） | 库（不是 Cordis 插件） |
| `@deepseek-ai/dsh-hooks-claude-code` | Claude Code 钩子桥接（CC 方言） | 插件 |
| `@deepseek-ai/dsh-hooks-codex` | Codex 钩子桥接（Codex 方言） | 插件 |

> [!important] 桥接只是兼容路径
> "原生钩子"就是 harness 类型化拦截点（`agent/*`、`tools/*`、`subagent/*` 事件）上的**普通 Cordis 插件**，功能更强且有类型化返回、无序列化边界。官方明确建议：**所有定制行为都用原生插件**，桥接只用于复用已存在的 CC/Codex `hooks.json`。

### 4.2 Hook 点 → harness 拦截点映射

Claude Code 桥（CC 30 个事件中支持 7 个）：

| CC hook | harness 点 | 映射 |
|---|---|---|
| `SessionStart` | `agent/session-start`（emit，脱离运行） | `additionalContext` → `agent.inject()` 到新会话（无法阻塞） |
| `UserPromptSubmit` | `agent/pre-step`（waterfall） | `deny` → `PreStepDecision.reject`；仅 additionalContext → 经 `next()` 委托并追加带来源标记的消息 |
| `PreToolUse` | `tools/pre-execute`（waterfall） | `deny` → `deny`；`ask` → `ask` |
| `PostToolUse` | `tools/post-execute`（waterfall） | `deny` → 带反馈的 `block`；additionalContext 前置到下游决策 |
| `Stop` | `agent/turn-stopping`（serial） | 阻塞 → `steer()` 送入原因，强制再执行一步 |
| `SubagentStart` / `SubagentStop` | `subagent/start` / `subagent/end`（emit） | inject 到同进程 child / 只观测 |

Codex 桥（Codex 10 个 hook 点中支持 5 个）：`PreToolUse`、`PostToolUse`、`SessionStart`、`UserPromptSubmit`、`Stop`，差异在——仅正则 matcher、snake_case payload（无尾随换行）、**无 ask/allow 与输入改写路径**（只能 block）。

### 4.3 超时 / 失败策略（fail-open）与合并

| 维度 | 规则 |
|---|---|
| 超时 | 遵循 hook 自身的 `timeoutSec`；未设置时用桥接 `defaultTimeoutMs`（CC 默认 600 000 ms），协议参考默认 `DEFAULT_HOOK_TIMEOUT_MS` = 10 分钟 |
| 阻止条件 | 退出码 2 + stderr 内容 → 阻止执行；**其他失败不阻塞**（fail-open） |
| 基础设施故障 | 执行器拒绝 → `HookOutput` 且 `exitCode: undefined`（非阻塞错误）；`runHook` 绝不抛异常 |
| 多 hook 合并 | 同点匹配的多个 hook 按配置顺序**串行**运行，权限折叠 `deny > ask > allow`；`continue:false` 起 halt 不变，阻塞原因 `\n\n` 连接，additionalContext 顺序累积 |
| 脱离运行 | `SessionStart`/`SubagentStart/Stop` 等 emit 点**没有扩展点等待**；每条运行链被跟踪，dispose 时先 abort 再等待全部结算（完全停稳，见 5.1） |
| 配置失败 | 读取/解析失败被隔离：记录警告且不注册任何内容，不让拼错路径使 agent 停止 |

> [!note] 与 dsh-bridges 的"工具名翻译"
> 社区插件 **dsh-bridges**（见 [[DSH跨框架Skills与MCP加载]]）桥接各 Agent 项目时会把上游 hook 配置中写的工具名**自动翻译为 DSH 工具名**，因此上游 hooks 原样可用；其失败策略同样是 fail-open（hook 超时/失败不阻塞动作），唯一例外是 Cursor 的 `failClosed: true`。

### 4.4 capability seams 概览（写 Hook 前必读）

`docs/capability-seams.zh.md` 给出服务角色全景（`seam` = 可替换能力、`core` = 核心主干、`bundle` = 组合点）。与 hooks 直接相关的组合：桥接消费 `ctx.shell`（执行 hook 命令）与 `ctx.sessionPersistence`（`transcript_path` 解析）；拦截点 `agent/pre-step`、`agent/turn-stopping`、`tools/pre-execute`、`tools/post-execute`、`subagent/start|end` 均按作用域过滤派发（agent-scoped 监听器只收到自己 agent 的事件）。其余常用 seam：`ctx.llm`（适配器注册）、`ctx.fs`、`ctx.sandbox`、`ctx.approval`、`ctx.skills`、`ctx.web` 等——完整表见源文档。

---

## 五、最佳实践清单

> 来源：`docs/defensive-patterns.zh.md`、`dsh-community-fabric/docs/research/mature-plugin-frameworks.zh.md`、`docs/plugin-ecosystem.md`、[[DSH跨框架Skills与MCP加载]]

### 5.1 防御性模式（每条都是实际发布过的缺陷类）

| # | 规则 | 插件开发含义 |
|---|---|---|
| 1 | 正交结果独立上报 | 超时/信号/退出码各自独立上报，不要把标志嵌套在分支里（进程可能"超时却退出码 0"） |
| 2 | 公共约定两侧都要遵守 | 在公共 API 返回前规范化多种表示；在类型定义处记录规范化约定（如 `LlmRuntime.stream()` 只以终止型 finish 暴露模型失败） |
| 3 | 异步状态不是同步状态 | 别把 `agent/status` 或 `whenIdle()` 当作某次 `followup()` 的结果；自动化调用方要显式定义自己的完成区间 |
| 4 | dispose 必须达到完全停稳 | 清理要**等待**子进程退出、关闭监听器注册表，不能只发终止信号就返回（否则留孤儿进程） |
| 5 | 在分发器中隔离回调异常 | 用户监听器抛异常不得 reject 所在 promise 或饿死后续监听器；try/catch 包裹分发循环 |
| 6 | 绝不暴露环境变量/可预测路径给不可信输出 | 启动命令用清理后的 env（移除 `*KEY*/*SECRET*/*TOKEN*/*PASSWORD*`）；临时文件放 0700 私有目录、`'wx'` + `0o600` 独占打开；删除可能是 symlink/junction 的路径先用 `lstatSync()` 判断再 `unlinkSync`（unlink 只删链接、拒绝真实目录） |

### 5.2 跨框架插件设计教训（mature-plugin-frameworks 调研）

对 Koishi / Chrome 扩展 / VS Code 三类成熟系统一手文档的调研结论（Fabric 设计输入）：

| 框架 | 最值得借鉴 | 不应照抄 |
|---|---|---|
| Koishi（Cordis 同源） | Context 同时管理依赖和副作用；激活范围资源所有权；必需/可选服务协商；服务替换 = 明确生命周期变化；多种事件分发模式（并行/串行/取第一个） | 任意查询服务的原始 Context；把 declaration merging 当公开兼容 contract；把同进程服务访问描述成安全权限 |
| Chrome 扩展 | 静态 manifest 作为检查与授权唯一信源；必需/可选权限分离；多运行 face + 可序列化消息；持久状态放 storage 而非全局变量；敏感操作靠近用户动作 | 只复制 manifest 字段不复制隔离边界；URL 匹配规则（Fabric 需要的是 session/workspace/工具执行等 DSH scope） |
| VS Code | 静态 Contribution Points + 按稳定 ID 绑定运行时实现；宿主拥有的强类型 UI 优先，Webview（任意 HTML）谨慎使用；main/browser 分运行 face | Workbench 布局与编辑器对象模型；把任意 HTML 当 UI 默认答案；没有真实需求就引入按需激活（Fabric v0.1 明确不采用） |

Fabric 的组合设计结论（对 DSH 插件作者同样有指导意义）：

- UI 分四层而不是一个万能 renderer：声明式贡献 → 强类型 Provider/命名 Renderer → 隔离富视图 → 宿主专属扩展（`x-*` 命名空间）。
- 业务行为需要多种协议而非一个事件总线：不可变观察流 / 命令与动作（request/result + 取消 + 幂等 + 稳定错误）/ 有序拦截器流程（确定性顺序、超时、失败策略）/ 上下文贡献流程（宿主收集校验排序冻结，插件不能 patch 内部 prompt builder）/ 持久任务与工作流。
- 权限四阶段：支持 / 请求 / 授权 / 强制执行，且在同进程 Node 中 manifest 声明**不是**安全隔离的证据。

### 5.3 DSH 生态倡议与实操约定

生态倡议三原则（`docs/plugin-ecosystem.md`）：

1. **组合优先**：通过官方 slot、service 和 patch 组合能力，不假设或覆盖其他插件的内部实现（桌面壳本身就是普通插件，无特权）。
2. **声明清晰**：明确声明依赖的 service 与 slot，不依赖运行时巧合。
3. **兼容优先**：升级保持向后兼容，不破坏已有组合。

实操清单（含 bridges 与 Desktop 契约的约定）：

| 关注点 | 最佳实践 |
|---|---|
| 命名冲突 | **原生优先**：重名时原生 DSH 技能（`.dsh/skills`、`.agents/skills`、runtime）遮蔽桥接资产（dsh-bridges）；作用域注册遮蔽全局（tools）；MCP 工具用 `mcp__<server>__<tool>` 命名，重复 serverName 报错回滚 |
| 热更新友好 | 一切注册都是 effect（自动清理）；配置变更触发插件热替换；技能目录/配置文件被 watch，会话内即时生效 |
| 配置分层 | 组合包 patch 只放"用户大概率保留的默认值"，其余交给 schema；用户可在 profile 补丁层覆盖你的行——不要写死部署取值 |
| 失败降级 | fail-open（hooks、MCP 启动失败静默降级 `failOnStartupError: false`）；配置读取失败隔离为警告而非崩溃；消费方闭合结果一律 fail-closed（审批） |
| 避免阻塞主循环 | waterfall 监听器必须 `next()` 且异步 gate 观察 `exec.signal`；脱离运行的 emit 点不等待 hook；dispose 等待完全停稳；桌面 pnpm 操作每次 generation 至多一个、须取消并等待结束 |
| 桌面插件 | 只有用户显式操作才启动 package mutation；`desktopProfiles.current` 是单 generation 快照不可跨重启保留；修改插件一律 `runPlugin()`（非低层 `run()`）；不从头推断 profile（不用 argv/baseUrl/$DSH_HOME） |

---

## 六、发布与分发

> 来源：`docs/user/develop/basic/publish.zh.md`、`dsh-plugin-desktop/docs/plugin-services.zh.md`

### 6.1 三种分发形态与 `dsh plugin` 命令

```sh
dsh plugin --profile demo add ./hello-plugin        # 本地 checkout / 目录
dsh plugin --profile demo add dsh-hello-plugin      # npm 包（预构建代码）
dsh plugin --profile demo add github:you/hello-plugin  # git 源码
dsh plugin --profile demo add ./hello-plugin-0.1.0.tgz  # tarball（pnpm pack 产物）
dsh plugin --profile demo remove dsh-hello-plugin
dsh --profile demo --dump-config   # 先验证层（应出现 "# == dsh-hello-plugin" 层）再启动
```

`dsh plugin --profile <name> <args...>` 在 profile 目录内转发给 pnpm，所有 pnpm 子命令可用；首次使用初始化 profile（`@deepseek-ai/dsh-base` 作为第一个组合包）；声明了 `dsh.bundle` 的包会被追加进 `dsh.profile.bundles`，`remove` 同时移除依赖与对应层。

### 6.2 git 安装：构建脚本与 allowBuilds

> [!danger] allowBuilds = 允许安装时执行代码
> git 安装拉取**源码**（不运行 build，TS 包无 `lib/` 输出会加载失败）。pnpm ≥10 在显式允许前拒绝运行 git 依赖的 `prepare` 脚本，首次 `add` 会失败；修法是把 pnpm 打印的确切包键复制进该 profile 的 `pnpm-workspace.yaml`：
>
> ```yaml
> allowBuilds:
>   dsh-hello-plugin: true
> ```
>
> 这项授权意味着**允许该包代码在安装时于你的机器上执行，且不在 agent 的任何沙箱内**。只对源码可信的包授权，并锁定 commit（`github:you/hello-plugin#<sha>`）。

- **作者侧**：提供自包含的 `prepare` 脚本（pnpm 在 git 安装后运行），不能假设 monorepo checkout 等开发环境上下文；或直接发布构建产物（npm publish 时构建 `lib/`、`pnpm pack` 交付 tarball），这两种形式都不需要用户任何构建权限。

### 6.3 peerDependencies 与内置组合包

- 内置组合包名称（如 `@deepseek-ai/dsh-base`）始终从 dsh 安装目录本身解析；pnpm 只管理树外包，所以你的组合包可放心依赖 `@deepseek-ai/dsh-base` 存在且与安装一致。
- 跨环境（Desktop + 普通 DSH）插件：把 `dsh-plugin-desktop` 作为编译所需 dev dependency；若发布的 declaration 暴露其类型，声明为 **optional peer**。仅探测 service 不需要 runtime import（type-only import 会被 JS 消除）。

---

## 七、实例对照表

> 来源：`dsh-tui-repo/cordis.patch.yml`、本机 `C:\Users\28064\.dsh`、[[DSH跨框架Skills与MCP加载]]

### 7.1 mcp-client 配置形态（原生 MCP，每服务器一个实例）

```yaml
- id: mcp-github
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: github
    transport: stdio            # 或 streamable-http
    command: npx
    args: ['-y', '@modelcontextprotocol/server-github']
    env:
      GITHUB_TOKEN: !!js process.env.GITHUB_TOKEN
```

模型看到 `mcp__<serverName>__<rawName>`；`transport: streamable-http` 时改用 `url`/`headers`；`toolCallTimeoutMs` 默认 60000；启动失败默认静默降级。

### 7.2 dsh-bridges 补丁（跨框架桥接，按桥开关）

```yaml
# 例：禁用 Pi 桥 / 关闭 Claude Code 桥
- id: bridges
  config:
    pi:
      enabled: false
```

安装：`dsh plugin --profile web add dsh-bridges`，验证：`dsh --profile web --dump-config | grep -A2 bridges`。

### 7.3 `@dsh-tui/dsh-tui` 的 cordis.patch.yml（组合包 patch 实例）

TUI 本身就是一个 bundle patch 层，展示"覆盖 base 行 + 插入 TUI-only 行"两种条目（摘录）：

```yaml
# 覆盖 base 行（整行 config 重述）：agent 绑定、persona、thinking
- id: agent-loop
  inject: [tuiStartup]
  config:
    agents:
      - id: main
        provider: deepseek-official
        model: deepseek-v4-pro
        cwd: !!js process.cwd()

- id: llm-deepseek
  config:
    thinking: enabled
    reasoningEffort: max

# 插入 TUI-only 行：启动器、存储投影、TUI 本体
- insert:
    - id: tui-startup
      name: '@dsh-tui/dsh-tui/startup'
    - id: tui
      name: '@dsh-tui/dsh-tui'
      inject: [tuiStartup]
      config:
        sessionId: !!js ctx.tuiStartup.sessionId
        showReasoning: true
        maxToolOutputLines: 6
    - id: tool-ask-user
      name: '@deepseek-ai/dsh-tool-ask-user'
```

注意点：`!!js ctx.<service>.<field>` 行需 `inject` 该提供方服务；`llm-deepseek` 行不写 key/endpoint——按请求从 settings、凭据存储与 `$DEEPSEEK_BASE_URL` 解析（配置分层实践）。

### 7.4 本机 profile 的 bundles 结构

```json
// C:\Users\28064\.dsh\profiles\web\package.json
{
  "name": "dsh-profile-web",
  "private": true,
  "dependencies": {},
  "dsh": { "profile": { "bundles": ["@deepseek-ai/dsh-base", "@deepseek-ai/dsh-web-app"] } }
}
```

profile 目录由 `dsh plugin` 创建维护（从不手写）；树外插件依赖由 pnpm 管理；用户自己的补丁层在 `profiles/<name>/cordis.patch.yml`（本机三个 profile 均为空数组）。

---

## 八、局限与时效性提示

> 来源：各 README 的"已知限制与暂缓事项"节、`docs/plugin-ecosystem.md`、[[DSH跨框架Skills与MCP加载]]

- **rc 线快速迭代**：本机 dsh CLI 为 v0.1.0-rc.6（见 [[DSH跨框架Skills与MCP加载]]），文档与接口随 rc 快速演进，字段/事件以上游最新文档与生成区块为准。
- **hooks 桥接是子集**：CC 30 个事件仅支持 7 个、Codex 10 个仅支持 5 个；`updatedInput` 会被解析+警告但**不应用**；`SessionStart` 部分功能；未实现 per-session hook 配置发现（`TODO(per-session-hook-config)`）、`Stop` 连续阻塞上限等。
- **Fabric 仍是 Draft**：dsh-community-fabric 的 manifest/capability/事件模型是社区 RFC Draft，尚不能作为依赖或发布目标；插件市场仍处设计阶段，目录收录 ≠ 安全审核。
- **Desktop 契约边界**：第三方公开 service 仅 `desktopProfiles` 与 `desktopPnpm`；`desktopRuntime`、`desktopPnpmBootstrap`、Electron 细节非兼容 contract；`dshmarket@1.2.3` 早于该契约且缺完整 MIT 文本，Desktop 不预装。
- **mcp-client 限制**：只桥接工具能力，MCP 的 resources/prompts 暂不支持。

---

## Related

- [[DSH跨框架Skills与MCP加载]] — 跨框架 Skills/MCP 桥接（mcp-client / dsh-bridges 详表）
- [[DSH-TUI插件使用手册]] — 本机 TUI profile 的使用手册
- [[2026-08-16-AI链接综述与归档]] — 16 链接调研综述（DeepSeek Harness 生态条目）
- [[TYPORA-KB-Home]] — 插件式扩展机制对照
- [[AGENTS]] — 知识库协作规范
