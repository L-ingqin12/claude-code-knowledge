---
title: Vercel 课程 — Build Your Own AI Coding Agent Harness
aliases: [Vercel Agent Harness课程, TeensyCode, 手写Agent框架课程]
tags: [ai/agent, ai/learning, ai/links]
created: 2026-08-18
updated: 2026-08-18
status: review
source_urls:
  - https://vercel.com/academy/build-ai-agent-harness
fetched_at: 2026-08-18
---

# Vercel 课程 — Build Your Own AI Coding Agent Harness

See also: [[2026-08-16-AI链接综述与归档]] | [[DSH插件与Hook开发最佳实践]] | [[Articles-Index]] | [[AI-Links-KB-Home]] | [[AGENTS]]

> [!abstract] 课程定位
> Vercel Academy 免费课程：从零手写一个**能真正干活**的 AI 编码 Agent 框架（Harness），产出项目 **TeensyCode**——紧凑 TypeScript 核心 + 真实工具集 + 多沙箱后端。开篇立意即本书主旨：「三个工具的 tool loop 只是 demo；问题从用它干真活才开始」（5000 行文件常驻上下文、`rm -rf`、只会解释不会动手、长任务挤爆窗口、云沙箱按分钟烧钱且超时丢代码）。

## 一、你将构建什么（TeensyCode 能力清单）

- **主循环**：`ToolLoopAgent`，工具集 `read/grep/write/edit/bash/task/askUser`
- **安全门**：执行级安全（命令白名单）→ 可配置审批（交互/后台/委托三模式）
- **行为提示词**：结构化 system prompt（Agency / Guardrails / Handling Ambiguity 三节）+ `AGENTS.md` 注入实现每项目配置
- **沙箱抽象**：一个 `Sandbox` 接口，两种实现（本地 Node fs+child_process；内存 just-bash + copy-on-write 虚拟文件系统），换后端工具不变
- **上下文管理**：`pruneMessages`、有界工具输出、cache control
- **子代理委派**：Explorer（只读+便宜模型）/ Executor（全工具+强模型）角色，按任务选模型
- **人在回路**：`askUser` 多选 + 「先搜索、再提问、后行动」的歧义协议
- **沙箱生命周期**：状态机、快照/恢复、durable workflow
- **可扩展性**：事件总线、渐进式披露的 Skills、自定义工具注册

## 二、11 模块大纲

| 模块 | 主题 | 关键课 |
|---|---|---|
| 1 | The Agent Loop | 从 Chatbot 到 Agent（一个工具即质变）；工具描述 = 模型选择 API；危险工具加执行级门 |
| 2 | Tool Design | 5 段式描述契约（WHEN TO USE / WHEN NOT / DO NOT USE FOR / EXAMPLES）；工厂+操作分离；审批：布尔→函数→可辨识联合 |
| 3 | The System Prompt | Agency+Guardrails（行动而非解释）；`buildSystemPrompt()` 动态组合；验证门（typecheck/lint/test/build 契约）；`AGENTS.md` 项目上下文 |
| 4 | Sandbox Abstraction | `Sandbox` 接口（readFile/exec/stop）；本地实现；内存实现（just-bash + CoW 覆盖层）；云端实现（远程 VM 权衡）；生命周期钩子（afterStart/beforeStop/onTimeout） |
| 5 | Context Management | token 日志揭示线性增长；`pruneMessages` 剪旧结果；工具输出有界（预防优于清理）；provider cache control 头 |
| 6 | Subagent Delegation | 单 Agent 失败模式；Explorer（只读/便宜/受限探索）；Executor（全工具/强模型/委托信任）；`task` 工具（路由/权限/按角色选模型） |
| 7 | Sandbox Lifecycle（概念课） | 状态机与超时/活动跟踪；快照与恢复（幂等性陷阱）；Vercel Workflow 的 `sleep()`；生产教训 |
| 8 | Human-in-the-Loop | `askUser` 结构化提问 + 歧义协议；审批配置（模式）+ 策略事件 |
| 9 | Planning and Verification | Todo 工具（分解+状态跟踪）；grep 先行、只读将改之处；验证契约（门序列+限定声明） |
| 10 | Surfaces | CLI 入口（args/沙箱工厂/干净退出）；流式与工具渲染；Web 面（同一 Agent 换渲染器） |
| 11 | Extensibility | Skills 渐进式披露（名字进 prompt、正文按需取）；自定义工具注册（不 fork）；扩展点（生命周期事件：subscribe/block/modify） |

**Capstone**：对真实项目跑 harness——不是「加个 hello world 端点」而是「给 auth 路由加限流」，观察上下文溢出、选错工具、子代理指令错误，修复暴露的问题。

## 三、技术栈与教学法

| 组件 | 用途 |
|---|---|
| [AI SDK](https://sdk.vercel.ai/) | `ToolLoopAgent`、`tool()`、`stepCountIs`、`pruneMessages`、流式 |
| [AI Gateway](https://vercel.com/ai-gateway) | 模型路由：`"anthropic/claude-haiku-4-5"` 字符串即用，无包装层 |
| [Vercel Sandbox](https://vercel.com/docs/functions/sandbox) | 远程 VM（隔离文件系统/git/npm） |
| [just-bash](https://www.npmjs.com/package/just-bash) | 内存虚拟文件系统 + 模拟 bash |
| [Vercel Workflow](https://vercel.com/docs/workflow) | 沙箱生命周期的 durable workflow |
| [Zod v3](https://zod.dev/) | 工具入参 schema（注意 v4 与 AI SDK v6 类型不兼容） |

- **因果序列教学法**：每步因上一步「坏了」而存在——step1 加 read（看不见文件）→ step2 加 grep（不会搜）→ step3 加 bash（能跑命令了，但也能 rm -rf 了）。
- Module 1-6 全程跟做（写码→运行→验证）；Module 7 纯概念；8-11 混合。
- **前置**：TypeScript/async-await/终端基础；`AI_GATEWAY_API_KEY`；Node 20+ 或 Bun；推荐先学《Building Filesystem Agents》。

## 四、学习价值与本地知识关联

- 学习价值：★★★★★ — 与 [[2026-08-16-AI链接综述与归档]] 的「编码 Agent 解剖」主线（《Pi 的设计艺术》、pi-from-scratch）完全同向，且是**亲手构建**视角的系统课程，覆盖 Harness 全貌（工具契约/审批/沙箱/上下文/子代理/生命周期/界面/扩展）。
- 与本库已有知识的映射：
  - 工具设计与审批 ↔ [[DSH插件与Hook开发最佳实践]]（工具 schema、审批 seam、执行管线）
  - 沙箱抽象/生命周期/快照恢复 ↔ [[Claude-Ops-KB-Home]]（远程运维的沙箱、checkpoint 扛 GPU 丢失等实战教训）
  - 上下文管理/注意力预算 ↔ [[Articles-Index]] 的上下文工程两篇
  - Skills 渐进式披露 ↔ [[Anthropic-Skill系统深度分析]]、[[Skill规模化管理-从渐进式披露到检索式发现]]
  - Module 10 CLI/TUI/Web 多面 ↔ [[DSH-TUI插件使用手册]]（TUI 是渲染策略而非核心）
- 建议学习顺序：先过 [[预训练迷你Kimi-K3实录-章节总结]] 建立「测量优先」心态 → 本课程动手 → 再读 Pi 源码书做对照。

## Related

- [[2026-08-16-AI链接综述与归档]] — 追加条目 #18
- [[DSH插件与Hook开发最佳实践]] — 工具/Hooks 开发对照
- [[Articles-Index]] — 上下文工程/Skill 文章
- [[DSH-TUI插件使用手册]] — 界面层对照
- [[Claude-Ops-KB-Home]] — 沙箱/生命周期实战教训
- [[AI-Links-KB-Home]] — 本子库 MOC
