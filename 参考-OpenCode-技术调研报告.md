---
title: 参考-OpenCode 技术调研报告
aliases: [OpenCode调研报告, opencode-research]
tags: [reference, ai/agent, ai/tools]
created: 2026-08-25
updated: 2026-08-26
status: review
source: 基于 web_search 多源交叉验证（官方文档/GitHub/npm/PyPI）
fetched_at: 2026-08-25
---

# OpenCode 技术调研报告（截至 2026-08）

> [!abstract] 调研对象：OpenCode（开源终端 AI 编码 Agent，TypeScript/Bun 实现）。本文所有事实均附来源 URL，不确定处标注**待确认**。相关背景见 [[AI-Dev-KB-Home]]、[[LLM-Agent开发基础]]、[[MCP协议开发实战]]、[[A2A多智能体协作协议]]、[[Claude-Ops-KB-Home]]。

## 0. 项目概况与仓库状态

- **OpenCode 由 SST 团队创建，2026 年 7 月前后品牌迁移至 Anomaly**，主仓库现为 `anomalyco/opencode`，文档站 opencode.ai/docs，源码内文档目录为 `packages/web/src/content/docs/*.mdx`（dev 分支）。[来源](https://oday-bakkour.com/blog/ai-coding-news-july-26-2026)、[来源](https://github.com/numtide/llm-agents.nix/pull/1800)、[来源](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/sdk.mdx)
- ⚠️ **org 归属存在矛盾信号**：OpenRouterLabs/spawn#1948 称 anomalyco 安装 URL "已迁回 sst/opencode"，与上述多数证据（numtide 自动化 PR、各 release 追踪站均指向 anomalyco/opencode 且持续更新到 2026-08）相悖——**最终归属待确认**。[来源](https://github.com/OpenRouterLabs/spawn/issues/1948)、[来源](https://releasealert.dev/feeds/github/anomalyco/opencode?type=atom)
- 中文镜像/教程生态丰富：open-code.ai（官方文档镜像）、learnopencode.com、opencodecn.com 等。[来源](https://open-code.ai/en/docs/agents)、[来源](https://learnopencode.com/5-advanced/13-custom-tools)

## 1. Agent / Subagent 体系

### 1.1 两种 mode

- Agent = 带**独立系统提示词、模型与工具权限**的 AI 人格，用 Markdown + YAML frontmatter 定义；全局放 `~/.config/opencode/agent/<name>.md`，项目放 `.opencode/agent/<name>.md`。[来源](https://opencode.ai/docs/agents)、[来源](https://github.com/anomalyco/opencode/blob/76880dce/packages/web/src/content/docs/agents.mdx)
- **`mode: primary` 是主循环代理（TUI 中 Tab 切换），`mode: subagent` 只能被主代理委派调用，不能直接切换选中**。[来源](https://opencode.ai/docs/agents)
- 调用方式两种：**用户 `@agentname` 显式提及**，或**模型自动调用 task 工具委派给 subagent**。[来源](https://opencode.ai/docs/agents)

### 1.2 内置 agent 清单

- 官方文档内置三件套：**build（默认主力主代理）、plan（规划型主代理，限制写入类工具）、general（通用 subagent，用于检索/多步研究后汇报）**。[来源](https://opencode.ai/docs/agents)、[来源](https://github.com/wesammustafa/opencode-primer/blob/main/docs/agents.md)
- `explore`（只读快速探索 subagent）初检未见于官方 agents 文档，**后经 2026-08-25 实机核验确认存在（native subagent，内置四件套之一，见 §11.2）**（Claude Code 有同名概念，社区套件 oh-my-opencode 提供类似角色）。[来源](https://mintlify.wiki/code-yeongyu/oh-my-opencode/concepts/agents)

### 1.3 frontmatter/config 字段全集

- 已确认字段：**`description`（何时委派的描述，模型据此路由）、`mode`（primary/subagent）、`model`（覆盖默认模型）、`temperature`、`tools`（工具开/关布尔映射，如 `write: false`）、`permission`（agent 级权限覆盖）、`disable`（隐藏/禁用该 agent，含内置）**；Markdown 正文即系统提示词。[来源](https://github.com/anomalyco/opencode/blob/47815645/packages/web/src/content/docs/agents.mdx?plain=1)、[来源](https://opencode.ai/docs/agents)
- `top_p`/maxTokens 等更多采样字段是否存在：**待确认**（文档片段仅见 temperature）。[来源](https://opencode.ai/docs/agents)

### 1.4 subagent 会话隔离语义

- **subagent 在独立上下文窗口中运行，结束后只把最终摘要返回父代理**——这是保护主上下文不被污染的核心设计。[来源](https://opencode.ai/docs/agents)、[来源](https://developer.aliyun.com/article/1743990)
- **无原生流式进度回传**；**后台/异步委派是长期未满足需求**（issue #5887 "True Async/Background Sub-Agent Delegation"），社区靠插件补齐（better-opencode-async-agents、agent-intercom）。[来源](https://github.com/anomalyco/opencode/issues/5887)、[来源](https://www.npmjs.com/package/better-opencode-async-agents)
- **并行**：一次回复中发起多个 task 调用理论上并发，但有"实际被顺序执行"的缺陷报告（#29638）与请求插件化编排层的提案（#20849）——**并行可靠性待确认**。[来源](https://github.com/anomalyco/opencode/issues/29638)、[来源](https://github.com/anomalyco/opencode/issues/20849)
- **递归限制：subagent 默认不能再 spawn subagent**（task 工具不对子代理开放，#9280 为开放此能力的 feature request）。[来源](https://github.com/anomalyco/opencode/issues/9280)
- 子会话不可通过 task 复用/resume（#6584 请求 resumeSessionId 参数）；限制"哪些 subagent 服务于哪个 primary"亦为未实现需求（#2693）。[来源](https://github.com/anomalyco/opencode/issues/6584)、[来源](https://github.com/anomalyco/opencode/issues/2693)

## 2. Plugin / Hook 系统

### 2.1 插件位置与导出形式

- 文件位置：**全局 `~/.config/opencode/plugin/`，项目 `.opencode/plugin/`**；npm 插件装入 package.json 依赖后在 opencode.json 的 `plugin` 数组声明。[来源](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/plugins.mdx)、[来源](https://open-code.ai/en/docs/plugins)
- 导出形式：ESM 模块导出 `Plugin` 函数——**`export const MyPlugin: Plugin = async ({ project, client, $, directory, worktree }) => { return { ...hooks } }`**，`client` 是官方 SDK 客户端、`$` 是 Bun Shell，函数返回 hooks 对象。[来源](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/plugins.mdx)、[来源](https://support.huaweicloud.com/usermanual-codeartssnap/%E5%8D%8E%E4%B8%BA%E4%BA%91%E7%A0%81%E9%81%93%EF%BC%88CodeArts%EF%BC%89%E4%BB%A3%E7%A0%81%E6%99%BA%E8%83%BD%E4%BD%93%20%E7%94%A8%E6%88%B7%E6%8C%87%E5%8D%97%EF%BC%88IDE%EF%BC%89-pdf.pdf)、[来源](https://raw.githubusercontent.com/joshuadavidthomas/opencode-plugins-manual/main/docs/03-plugin-context.md)

### 2.2 Hook 清单及签名（input/output）

以下签名综合官方 plugins 文档与社区手册《opencode-plugins-manual》：

| hook | 输入 | 输出/用途 |
|---|---|---|
| `chat.message` | `{ message }`（含 parts） | 发送前检查/改写消息内容（脱敏、注入记忆等）[来源](https://raw.githubusercontent.com/joshuadavidthomas/opencode-plugins-manual/main/docs/04-hooks-reference.md) |
| `chat.params` | `{ model, provider, message }` | 返回/修改 `{ temperature, topP }` 采样参数 [来源](https://opencode.ai/docs/plugins) |
| `permission.ask` | 权限请求详情（tool/pattern 等） | 返回决策（如 `continue: false` 拒绝）实现程序化审批 [来源](https://github.com/anomalyco/opencode/issues/19927)、[来源](https://github.com/anomalyco/opencode/issues/7006) |
| `tool.execute.before` | `{ tool, sessionID, callID }` | 修改 `{ args }` 再执行 [来源](https://opencode.ai/docs/plugins) |
| `tool.execute.after` | `{ tool, sessionID, callID, args }` | 修改 `{ title, output, metadata }` 结果呈现 [来源](https://opencode.ai/docs/plugins) |

- **experimental.\* 系列（API 不稳定）**：`experimental.chat.system.transform`（变换系统提示 blocks；PR #32474 给其增加 agent 名输入）、`experimental.chat.messages.transform`（变换消息列表）、`experimental.session.compacting`（介入上下文压缩，neotoma/gastown 插件在用）等，其余以源码为准。[来源](https://github.com/anomalyco/opencode/pull/32474)、[来源](https://github.com/anomalyco/opencode/issues/17637)、[来源](https://github.com/darrenhinde/OpenAgentsControl/blob/ef3836ef/.opencode/context/openagents-repo/standards/opencode-typescript.md?plain=1)、[来源](https://github.com/markmhendrickson/neotoma/blob/main/docs/integrations/hooks/opencode.md)
- 已知缺陷：permission.ask 曾"定义未触发"（#7006）、首遇命令绕过（#19927）；插件加载顺序与错误隔离有专门修复 PR（#44895）。[来源](https://github.com/anomalyco/opencode/issues/7006)、[来源](https://github.com/anomalyco/opencode/issues/19927)、[来源](https://github.com/anomalyco/opencode/pull/44895)

### 2.3 event 钩子（Bus 全局事件订阅）

- 插件可返回单个 **`event: async ({ event }) => {}` 钩子，按 `event.type`（及 `event.properties.*`）分支匹配**，而非逐事件名字符串注册；官方示例形如 `if (event.type === "message.updated")`。[来源](https://raw.githubusercontent.com/joshuadavidthomas/opencode-plugins-manual/main/docs/07-events.md)、[来源](https://learnopencode.com/en/5-advanced/12b-plugins-advanced)
- 常见事件名：**message.updated、message.part.updated、session.idle、session.error、installation.updated、file.updated、storage.write、permission.updated** 等（完整枚举随版本演进，见 manual 07-events 与源码 Bus 定义）。[来源](https://raw.githubusercontent.com/joshuadavidthomas/opencode-plugins-manual/main/docs/07-events.md)、[来源](https://github.com/anomalyco/opencode/issues/2021)

## 3. 自定义工具（Custom Tool）

- 在插件内 `import { tool } from "@opencode-ai/plugin/tool"`：**`tool({ description, args: z.object({...}), execute(input, ctx) })`**；参数用 zod schema 声明（可选参数 `.optional()`），`execute` 第二参 ctx 含 **`sessionID`、`abort`（AbortSignal）、`message`、`agent`** 等；返回值即工具结果（字符串或带 metadata 的结构）。[来源](https://learnopencode.com/5-advanced/13-custom-tools)、[来源](https://deepwiki.com/tencent-source/opencode/3.3.3-custom-tools)、[来源](https://github.com/bgauryy/open-docs/blob/main/docs/opencode/06-tool-system.md)
- **与 MCP 工具的区别**：自定义工具是进程内 TypeScript、zod 强类型校验、可直接使用插件 ctx（SDK client/$ shell/abort 信号），随插件生命周期加载；MCP 工具来自外部服务器进程、走 MCP 协议、以服务器键命名空间暴露、可用性受连接状态影响且无法访问插件 ctx。[来源](https://tessl.io/registry/pantheon-ai/opencode-toolkit/files/build-tool/references/plugin-api.md)、[来源](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/mcp-servers.mdx)

## 4. Skills

- 位置：**项目 `.opencode/skill/<name>/SKILL.md`，全局 `~/.config/opencode/skill/<name>/SKILL.md`**；frontmatter **必填 `name` 与 `description`**，正文是按需加载的指令正文。[来源](https://github.com/anomalyco/opencode/blob/c47438068490ab2deb65380c25aa056afd23fdd8/packages/web/src/content/docs/skills.mdx)、[来源](https://docs.opencode.ai/docs/skills/)
- 可选字段沿用 Anthropic Agent Skills 规范（license、allowed-tools、metadata 等）；**allowed-tools 在 OpenCode 中是否被强制执行待确认**。[来源](https://claudskills.com/learn/skill-md-frontmatter-reference/)、[来源](https://mintlify.wiki/vercel-labs/skills/resources/compatibility)
- **渐进式披露**：只有技能的 name+description 常驻注入系统提示，模型判断相关后才读取 SKILL.md 全文——token 高效的可扩展知识层。[来源](https://github.com/anomalyco/opencode/blob/c47438068490ab2deb65380c25aa056afd23fdd8/packages/web/src/content/docs/skills.mdx)、[来源](https://inbounter.com/learn/claude/skills/skills-system)
- **skill vs command**：command（`.opencode/command/*.md`）是用户斜杠显式调用的提示模板（支持 `$ARGUMENTS`、`!shell`、`@file` 注入）；skill 是模型按 description 自主决定加载的能力包。二者互补，长期是否合并**待确认**。[来源](https://opencode.ai/docs/commands)、[来源](https://opencodedocs.com/joshuadavidthomas/opencode-agent-skills/faq/troubleshooting/)

## 5. MCP

- opencode.json(c) 的 `mcp` 字段 schema：**`"<server-key>": { "type": "local", "command": ["bun","x","..."], "environment": {...}, "enabled": true }` 或 `{ "type": "remote", "url": "https://...", "headers": {"Authorization":"Bearer ..."}, "enabled": true }`**。[来源](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/mcp-servers.mdx)、[来源](https://opencode.ai/v2/docs/mcp-servers)
- **工具命名：以服务器键为前缀暴露**（`<server>_<tool>` 形态）——证据：sverklo 出现双重前缀 `sverklo_sverklo_*` 缺陷、上游有"MCP 工具名清洗适配上游 provider"的需求 #31278；`mcp__<server>__<tool>` 双下划线是 Claude Code 惯例而非 OpenCode 文档口径（分隔符精确形态**待确认**）。[来源](https://github.com/sverklo/sverklo/issues/71)、[来源](https://github.com/anomalyco/opencode/issues/31278)
- 注意事项：`enabled:false` 整体停用；本地 stdio 用 command 数组拉起进程；remote 走 Streamable HTTP 并支持 headers 鉴权；专用 timeout 配置项**未见于检索到的文档，待确认**。[来源](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/mcp-servers.mdx)

## 6. 配置体系 opencode.json

- 配置文件为项目根 `opencode.json` / `opencode.jsonc`（支持注释），首行推荐 `"$schema": "https://opencode.ai/config.json"` 获得补全。[来源](https://opencode.ai/docs/config)
- 关键键：**`model`（"provider/model"）、`small_model`（起标题/摘要等廉价任务）、`instructions`(数组，追加 AGENTS.md 等规则文件，支持 glob/URL)**。[来源](https://opencode.ai/docs/rules)、[来源](https://tessl.io/registry/pantheon-ai/opencode-toolkit/files/configure/references/config-schema.md)
- **permission**：`edit` / `bash` / `webfetch` 取 `ask|allow|deny`；bash 用通配模式对象（如 `"git *": "allow"`），**多条规则命中时按文档语义以后匹配者生效（last-match-wins）**；已知缺陷：bash deny 与 `"*": ask` 组合失效 #28682。[来源](https://github.com/anomalyco/opencode/blob/6456350564fd53a7aa93374a5e5d4c529d9a2f0f/packages/web/src/content/docs/docs/permissions.mdx?plain=1)、[来源](https://github.com/anomalyco/opencode/issues/28682)、[来源](https://github.com/anomalyco/opencode/pull/44657)
- 其他键：`formatter`（自定义格式化命令/扩展名）、`keybinds`（leader 等快捷键映射）、`share`、`autoupdate`、`theme`、`provider`、`agent`/`command`/`plugin`/`mcp` 数组。**`linter` 键与 `doom` 权限键均未在官方资料中检索到——待确认（大概率不存在）**。[来源](https://tessl.io/registry/pantheon-ai/opencode-toolkit/files/configure/references/config-schema.md)、[来源](https://opencode.ai/docs/config)

## 7. Server / SDK 无头控制（重点）

### 7.1 opencode serve HTTP API

- **`opencode serve --port 8080 --hostname [IP已脱敏]` 启动无头 HTTP 服务**；`opencode attach <url>` 可把 TUI 接到远端 server（attach + ask 权限会挂起的缺陷 #16367 反证了该链路真实存在）。[来源](https://github.com/marcusquinn/aidevops/pull/6383/files)、[来源](https://opencode.ai/docs/server)、[来源](https://github.com/anomalyco/opencode/issues/16367)
- 能力面（REST + SSE，服务端自带 OpenAPI 规范，`GET /doc`）：**创建会话（POST /session）、会话管理（GET/PATCH/DELETE /session/:id、children、revert/unrevert、share）、发消息触发运行（POST /session/:id/message）、读取消息（GET /session/:id/message）、事件流（GET /event，SSE）、中止当前轮（POST /session/:id/abort）**。[来源](https://deepwiki.com/tencent-source/opencode/2.2.3-api-server)、[来源](https://opencode.io.vn/docs/server)、[来源](https://gitlab.com/gitlab-org/orbit/gkg-evals-harness/-/blob/1c7eb656d9e5c953fee2d623518c782597df3cf1/opencode_sdk/opencode_sdk/api/default/session_abort.py)、[来源](https://github.com/theshadow27/mcp-cli/issues/503)
- 真实消费者佐证：GitLab orbit 评测 harness 直接从 OpenAPI 生成 Python SDK 并调用 `session_abort`；Onyx 产品内置 `serve_client.py` 通过 serve 协议驱动沙箱内 OpenCode。[来源](https://gitlab.com/gitlab-org/orbit/gkg-evals-harness/-/blob/1c7eb656d9e5c953fee2d623518c782597df3cf1/opencode_sdk/opencode_sdk/api/default/session_abort.py)、[来源](https://github.com/onyx-dot-app/onyx/blob/95850b7ce52ba4cdc4748f1393f8efcc0c140940/backend/onyx/server/features/build/sandbox/opencode/serve_client.py)
- 无头化注意：**headless 下 `ask` 权限无人应答会挂起**——编排器要么预置 allow/deny，要么监听 permission 事件程序化作答；SSE 订阅对自定义 fetch/BasicAuth 支持有缺陷 #28180。[来源](https://github.com/anomalyco/opencode/issues/16367)、[来源](https://github.com/anomalyco/opencode/issues/28180)

### 7.2 @opencode-ai/sdk（JS/TS）

- **`createOpencodeClient({ baseUrl })` 返回类型化客户端**（session/app/config/tui/event 等资源方法），SDK 由服务端 OpenAPI 生成；官方内部 TUI 已切到 `@opencode-ai/sdk/v2` 入口，并有专门 PR 暴露实时事件流订阅。[来源](https://github.com/anomalyco/opencode/blob/28a06e52/packages/opencode/src/cli/cmd/tui/context/sdk.tsx)、[来源](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/sdk.mdx)、[来源](https://github.com/anomalyco/opencode/pull/34098)
- 典型编排回路：**client.session.create() → client.session.chat()/message() → 订阅 /event SSE 收 message.part.updated 增量 → 需要时 abort**。[来源](https://www.opencode.asia/zh-cn/sdk/)、[来源](https://learnopencode.com/en/5-advanced/10a-sdk-basics)

### 7.3 Python SDK

- **官方 Python SDK 仓库 `anomalyco/opencode-sdk-python`（"Opencode Python API library"），采用 sync/async 双客户端模式**（同类 Stripe/OpenAI Python SDK 风格）；此前另有社区全功能移植 PR #8688。[来源](https://github.com/anomalyco/opencode-sdk-python/blob/main/README.md)、[来源](https://github.com/anomalyco/opencode/pull/8688)
- 第三方还有 Rust SDK（longcipher/opencode-sdk-rs）、Elixir SDK（opencode-sdk.hexdocs.pm）等，说明 serve 协议已成为事实集成标准。[来源](https://deepwiki.com/longcipher/opencode-sdk-rs/2.3-api-resources-overview)、[来源](https://opencode-sdk.hexdocs.pm/0.1.38/OpenCode.md)

## 8. 社区多智能体生态

- **opencode-agent-intercom**（npm，1.4.x）：让主代理**非阻塞 spawn 工人子代理、完成时收到通知**；配套 `@dataforxyz/agent-intercom-orchestrator`（0.10.x，含工人监督文档）。定位：填补官方异步委派缺口的小型社区包，单人维护、可用但非企业级。[来源](https://security.snyk.io/package/npm/opencode-agent-intercom)、[来源](https://cdn.jsdelivr.net/npm/@dataforxyz/agent-intercom-orchestrator@0.10.0/docs/creating-and-supervising-worker-agents.md)
- **swarm-control**（npm 0.1.13，早期）与 **ZaxbyHub/opencode-swarm**：architect 中心的 hub-and-spoke 群体编排插件（SME 咨询、代码生成、QA 审查），有架构文档；成熟度早期。[来源](https://security.snyk.io/package/npm/swarm-control/0.1.13)、[来源](https://github.com/ZaxbyHub/opencode-swarm/blob/main/README.md)、[来源](https://github.com/ZaxbyHub/opencode-swarm/blob/main/docs/architecture.md)
- **Q00/ouroboros（Ouroboros Bridge）**：specification-first 的 "Agent OS" 工作流引擎，提供 OpenCode runtime 指南与 **opencode-subagent-bridge 桥接指南**，PyPI `ouroboros-ai` 持续发版（0.38.x dev）——三者中工程化程度最高。[来源](https://github.com/Q00/ouroboros/blob/main/docs/guides/opencode-subagent-bridge.md)、[来源](https://github.com/Q00/ouroboros/blob/main/docs/runtime-guides/opencode.md)、[来源](https://pypi.org/project/ouroboros-ai/0.38.3.dev150/)
- 事实标准插件套件 **oh-my-opencode / oh-my-openagent**（code-yeongyu）：hooks/task 工具/agent 配置均有完善文档，社区采用广。[来源](https://mintlify.wiki/code-yeongyu/oh-my-opencode/api/features/hooks)、[来源](https://mintlify.wiki/code-yeongyu/oh-my-opencode/api/tools/task)
- 生态共同点：**都在绕官方缺口做文章**——异步后台（#5887）、嵌套（#9280）、并行调度（#29638）、编排层（#20849）、子会话恢复（#6584）。[来源](https://github.com/anomalyco/opencode/issues/20849)

## 9. 版本与活跃度

- **当前版本：v1.18.22（2026-08-24 发布；本节为调研时快照——核验当日 npm latest 已达 1.18.23，见 §11.3 版本快照更新）**；rebrand 至 Anomaly 时为 v1.18.5（2026-07-26 报道）→ **一个月内 ≥17 个 patch，发布节奏约为每 1–2 天一版，极度活跃**。[来源](https://tsecurity.de/de/3758885/ai-nachrichten/github-release-anomalycoopencode-v11822-24082026/)、[来源](https://oday-bakkour.com/blog/ai-coding-news-july-26-2026)、[来源](https://newreleases.io/project/github/anomalyco/opencode/release/v1.18.16)
- **License：MIT**（仓库含 LICENSE 文件；SignPath Foundation 收录该项目签名）。[来源](https://github.com/anomalyco/opencode/blob/v0.0.52/LICENSE)、[来源](https://signpath.org/projects/opencode/)
- ⚠️ org 归属矛盾信号见第 0 节，**待确认**。[来源](https://github.com/OpenRouterLabs/spawn/issues/1948)

## 10. 对基座二次开发最有价值的扩展点 Top5

1. **Server + SDK 无头控制面（HTTP REST + `/event` SSE + OpenAPI 自描述）**——外部编排器实时控制子 agent 会话（建会话/发消息/流式收件/abort）的唯一官方通道，JS/Python/Rust SDK 生态已成气候，是做上层 Supervisor/无人值守系统的地基。[来源](https://opencode.ai/docs/server)、[来源](https://github.com/anomalyco/opencode-sdk-python/blob/main/README.md)
2. **Plugin hook + event Bus**——不改核心源码注入横切逻辑：chat.params 调采样、tool.execute.before/after 改工具行为、permission.ask 程序化审批、event 钩子接全局遥测/持久化，二开性价比最高。[来源](https://opencode.ai/docs/plugins)、[来源](https://raw.githubusercontent.com/joshuadavidthomas/opencode-plugins-manual/main/docs/04-hooks-reference.md)
3. **permission.ask + opencode.json permission 规则**——把"人工确认"替换成"策略引擎"（自动放行/升级/拒绝），是实现 CI 无人值守与安全护栏的关键闸门。[来源](https://github.com/anomalyco/opencode/pull/44657)、[来源](https://opencode.ai/docs/permissions)
4. **Agent markdown DSL（mode/model/tools/permission frontmatter）**——用纯文本+git 管理角色矩阵，叠加 task/@mention 委派即可搭分层多代理组织；结合 SDK 还能从外部读写会话弥补"无流式回传/不可 resume"短板。[来源](https://opencode.ai/docs/agents)、[来源](https://github.com/anomalyco/opencode/issues/6584)
5. **Skills 渐进披露 + MCP 外挂工具面**——领域知识用 SKILL.md 按需注入不撑爆上下文，长尾能力用 MCP 服务器热插拔并以服务器键命名空间治理，二者组合是不动基座代码的功能扩容路径。[来源](https://docs.opencode.ai/docs/skills/)、[来源](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/mcp-servers.mdx)

> [!question] 主要待确认项汇总（2026-08-25 实机核验后更新）
> ① GitHub org 最终归属（anomalyco vs sst）——**仍待确认**；② 内置 `explore` agent——✅ **已确认存在**（见 §11）；③ agent frontmatter top_p——✅ **已确认支持**（见 §11）；④ skill 的 allowed-tools 是否被执行——⚠️ 二进制中未见 opencode 层执行逻辑（仅命中内嵌 OpenAI/Anthropic SDK 的同名参数），**倾向不生效，仍待源码级确认**；⑤ MCP 工具名分隔符——`mcp__` 未出现于二进制，维持 `<server>_<tool>` 判断；timeout 配置项——✅ **已确认存在**（见 §11）；⑥ `linter`/`doom` 键——**无 linter 键**；"doom" 实为权限键 **`doom_loop`**（另有 `external_directory`），见 §11。

## 11. 实机核验增补（2026-08-25）

> [!info] 核验方法
> npm registry 直连拉取官方包：`@opencode-ai/plugin@1.18.23` 与 `@opencode-ai/sdk@1.18.23` 的 `.d.ts` 类型定义逐条比对 + `opencode-windows-x64@1.18.23` 二进制（171MB Bun 编译产物）内嵌字符串取证。以下结论均为一手证据。

### 11.1 类型层（@opencode-ai/sdk / plugin 1.18.23）

| 项 | 结论 | 证据 |
|----|------|------|
| AgentConfig 字段 | **支持 `top_p?: number`**；另有 `model/temperature/prompt/tools/disable/description/mode/color/maxSteps`；`mode: "subagent"\|"primary"\|"all"`（含 all 双模态） | sdk dist/gen/types.gen.d.ts `AgentConfig` |
| 权限键全集 | `edit / bash(模式映射) / webfetch / doom_loop / external_directory`，取值 ask\|allow\|deny；**无 linter 键** | 同上 Config/Agent permission 段 |
| MCP local 配置 | `{type:"local", command[], environment?, enabled?, **timeout?**(ms, 默认 5000)}` —— timeout 配置项实锤 | 同上 `McpLocalConfig` |
| instructions 数组 | ✅ 存在（"Additional instruction files or patterns"） | 同上 |
| Hook 全集（较本文 §2 增补） | 新增：**chat.headers / command.execute.before / shell.env / tool.definition**（改写发给 LLM 的工具描述与参数）/ experimental.provider.small_model / experimental.compaction.autocontinue / experimental.text.complete；chat.params 输出含 topK 与 maxOutputTokens | plugin dist/index.d.ts `Hooks` |
| 自定义工具 tool() | **zod 契约**（`args extends z.ZodRawShape`）；ToolContext 含 sessionID/messageID/agent/directory/worktree/**abort**/**ask()（工具内程序化触发审批）**/metadata() | plugin dist/tool.d.ts |
| Event 事件名（SDK 官方类型） | message.updated / message.part.updated / message.part.removed / message.removed / **session.idle / session.error** / permission.updated / todo.updated / file.watcher.updated / installation.updated / lsp.updated / pty.updated / vcs.branch.updated 等 | sdk types.gen.d.ts |

### 11.2 二进制取证（opencode.exe 1.18.23）

| 项 | 结论 |
|----|------|
| 内置 agent | **四件套实锤**：`build`（默认主力）、`plan`（"Disallows all edit tools"，含 question/plan_exit/task 子权限）、`general`（通用研究型 subagent）、**`explore`**（native subagent，权限 `*:"deny"` + grep/glob/list/bash/webfetch/websearch/read 白名单，描述 "Fast agent specialized for exploring codebases..."）；task 工具以 `subagent_type` 参数指定 |
| MCP 工具命名 | 二进制中无 `mcp__` 字样 → 维持 `<server>_<tool>` 判断（精确拼接逻辑在编译产物中不可直读，仍留一线待源码确认） |

### 11.3 CLI 运行面实测

`--version` → 1.18.23；命令清单：serve / attach / run / **agent create·list** / **mcp add·list·auth·logout·debug** / **debug config·skill·agent\<name\>·startup** / providers(auth) / models / stats / export / import / github / pr / session / plugin / db / acp / web / upgrade / uninstall。已知沙箱限制：子命令运行需 spawn git（本环境管道捕获受限报 EPERM），`debug skill`、`debug config` 留待开放环境复核。

> 版本快照更新：npm latest 已到 **1.18.23**（核验当日），延续每 1–2 天一版节奏。
