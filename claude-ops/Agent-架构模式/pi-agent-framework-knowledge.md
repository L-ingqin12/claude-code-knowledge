---
title: Pi Agent 框架知识
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-08-10
updated: 2026-08-25
status: stable
---

# Pi Agent 框架知识

> [!abstract] Pi Agent 框架完整知识 — TypeScript monorepo、4原子工具、800token预算、parallel tool execution、programmatic SDK

See also: [[Claude-Ops-KB-Home]] · [[pi-agent-constraints-reference]] · [[pi-agent-log-analysis-plan]]

## 定义

Pi Agent (Mario Zechner/badlogic) 是 TypeScript 编写的 AI Agent 工具包，monorepo 结构: pi-ai (LLM providers) → pi-agent-core (Agent loop) → pi-coding-agent (runtime) → pi-tui (TUI)。

## 核心约束

- **4 原子工具**: read, write, edit, bash (Unix 哲学 — 组合而非新增)
- **~800 token 系统提示词预算** (刻意保持低开销)
- **无 Agent spawn** — 无子 Agent 概念，用 parallel tools 或 多 AgentSession 模拟
- **无内置权限系统** — 依赖 Docker/Gondolin/OpenShell 容器化
- **无原生 HTTP Server** — 需自行包装 (Express/Fastify)

## 关键能力

- **Programmatic SDK**: `createAgentSession({ sessionManager: SessionManager.inMemory() })` 可嵌入 Node.js 服务
- **Parallel tool execution** (默认): `toolExecution: "parallel"` → `Promise.all` 并发执行工具调用 → LLM 自主 Fan-Out
- **Event system**: `session.subscribe()` 订阅流式文本/工具执行/生命周期事件
- **Tree-based JSONL session**: 支持分支/fork/compaction
- **Skills**: 渐进式披露 — `.md` 文件通过 `read` 工具按需加载
- **Extension system**: 25+ 事件类型，beforeToolCall/afterToolCall hooks

## 与 opencode 的关键差异

| 维度 | Pi Agent | opencode |
|------|----------|----------|
| 语言 | TypeScript (Node.js) | TypeScript（TUI 部分为 Go） |
| 工具模型 | 4 原子工具 | 丰富工具集 |
| 并行 | toolExecution: "parallel" (LLM 自主) | 依赖插件 (agent-intercom) |
| 嵌入 | SDK in-process | subprocess / HTTP |
| 系统提示词 | ~800 tokens (强制精简) | 无硬限制 |

## 对日志分析架构的影响

- HTTP 层必须用 Node.js (Express/Fastify)，不能用 Tornado
- 多进程用 Node.js cluster 而非手动多端口
- 分析指令通过 Skills (渐进式) 注入，不占 system prompt
- LLM 自主决定并行维度 → 更灵活但可控性低于代码固定的 ThreadPoolExecutor

**Why:** Pi Agent 和 opencode 是两种完全不同的 Agent 框架范式 — TypeScript SDK 嵌入 vs TypeScript CLI subprocess 调用（TUI 为 Go）。选择哪个决定了整个 HTTP 服务的技术栈。
**How to apply:** 设计基于 Pi Agent 的服务时，始终从 "4 工具 + 800 token + SDK in-process" 的约束出发，不要照搬 opencode 的方案。

## 关联

- [[pi-agent-log-analysis-plan]] — Pi Agent 版日志分析方案
- [[log-analysis-agent-windows-architecture]] — opencode 版方案 (横向对比)
- [[fan-out-subagent-pattern]] — Pi Agent parallel tools 实现 Fan-Out
- [[agent-async-isolation-pattern]] — Node.js 版不适用此 pattern
- [[opencode-multi-agent-architecture]] — opencode 两层模型对比
