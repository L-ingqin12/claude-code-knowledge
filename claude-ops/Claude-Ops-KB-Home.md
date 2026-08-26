---
title: Claude-Ops-KB-Home
aliases: [Claude Code 运维知识库, claude-ops, ClaudeOps]
tags: [moc, ai/ops]
created: 2026-08-17
updated: 2026-08-26
status: stable
---

# Claude-Ops-KB-Home — Claude Code 无人值守运维知识库

> [!abstract] 概述
> 本子库承载远程仓库 `akb-remote`（Claude Code 无人值守知识库，commit `f493130`）的运维知识体系：从现象→根因→方案→部署的完整推导与产出。所有文档均可独立阅读，彼此正交但交叉引用。
> 迁移日期：2026-08-17 · 文档总数：60（54 篇迁移 + 本 MOC + [[MEMORY-INDEX]] + 2026-08-25 新增 4 篇）

See also: [[AGENTS]] · [[AI-Links-KB-Home]] · [[Network-KB-Home]]

## 六层防御架构与阅读顺序

> [!info] 架构全貌（源自远程 README.md）
> 无人值守的完整防御体系分六层，自下而上逐层兜底：

| 层 | 机制 | 说明 | 对应文档 |
|----|------|------|----------|
| Layer 0 | 网络门控 | 不稳不发，等稳定后再发 | [[claude-network-stability-gate]] |
| Layer 1 | HEAD 预检 | 发请求前确认服务器可达 | [[claude-resilience-architecture]] |
| Layer 2 | 连接池+心跳 | 复用连接，45s 保活防 NAT 超时 | [[claude-socket-error-elimination-guide]] |
| Layer 3 | 透明重试 | socket 错误自动重试（3次, 1/3/8s backoff） | [[claude-resilience-usage]] |
| Layer 4 | 外部大脑 | context-dump.md 保存思维状态 | [[claude-context-continuity-guide]] |
| Layer 5 | 中断恢复 | task-state.json + progress.log 保存任务进度 | [[claude-interruption-resilience-guide]] |

**核心方案阅读顺序**（远程 README.md 主题定位）：

| # | 文档 | 回答的问题 |
|---|------|-----------|
| 1 | [[claude-socket-error-elimination-guide]] | Socket 错误为什么会发生？如何从根源消除？ |
| 2 | [[claude-network-resilience-v2]] | 网络中断时如何做到用户无感？为什么不需要守护进程？ |
| 3 | [[claude-network-stability-gate]] | 如何防止网络抖动时发出注定失败的请求？ |
| 4 | [[claude-interruption-resilience-guide]] | 中断后如何以最小开销恢复？三层恢复架构是什么？ |
| 5 | [[claude-context-continuity-guide]] | 恢复后如何保证思路不跑偏？外部大脑如何设计？ |
| 6 | [[claude-unattended-operation-plan]] | Android/Termux/PRoot 环境如何配置无人值守？ |
| 7 | [[claude-unattended-cross-platform-guide]] | 其他平台（Linux/macOS/Windows/Docker/CI）怎么做？ |
| 8 | [[claude-unattended-methodology]] | 这些方案是怎么推导出来的？分析方法论是什么？ |

> [!tip] 环境上下文
> 原始运行环境：`Android (aarch64) → Termux → PRoot → Ubuntu 24.04 → Claude Code v2.1.172`；API 端点 `https://api.deepseek.com/anthropic`。约束：无 systemd、无 tmux、无 cron daemon、移动网络 NAT 超时 30-120s。

## 文档地图

### 1. 运维方案与设计（status: review）

| 文档 | 主题 |
|------|------|
| [[claude-socket-error-elimination-guide]] | Socket 错误根源分析与消除方案 |
| [[claude-network-resilience-v2]] | 网络中断无感 v2（当前版） |
| [[claude-network-stability-gate]] | 网络稳定性门控 |
| [[claude-resilience-architecture]] | 韧性代理架构总览 |
| [[claude-resilience-usage]] | 韧性代理使用手册 |
| [[claude-interruption-resilience-guide]] | 中断恢复三层架构 |
| [[claude-context-continuity-guide]] | 语境连续性 / 外部大脑 |
| [[claude-unattended-operation-plan]] | 无人值守方案（Termux/PRoot） |
| [[claude-unattended-cross-platform-guide]] | 跨平台无人值守指南 |
| [[claude-unattended-methodology]] | 分析链路与推导方法论 |
| [[claude-deployment-record]] | 部署记录与使用手册 |
| [[claude-resource-protocol]] | 资源协议（system prompt injection） |
| [[claude-cache-optimization]] | 缓存命中率优化方案 |
| [[claude-cache-strategy]] | 缓存会话策略 |
| [[claude-cache-proxy-evaluation]] | Proxy 内建缓存评估（结论：已废弃） |
| [[claude-flash-primary-analysis]] | Flash 为主、Pro 为辅可行性分析 |
| [[claude-port-rebind-solution]] | PRoot 端口重启根因与修复 |
| [[claude-streaming-forward-design]] | 流式转发 + Model Router 协同 |
| [[PERMAFROST_MODIFICATIONS]] | Permafrost 本地修改记录 |
| [[pi-vs-termux-guide]] | Pi (systemd) vs Termux (proot) 部署差异 |
| [[hermes-cache-analysis]] | Hermes 缓存现状与优化 |
| [[hermes-parallel-task-report]] | Hermes 并行任务调度与通信 |
| [[hermes-session-optimization-report]] | Hermes 会话优化与模型调度 |
| ~~[[claude-network-resilience-design]]~~ | ⚠️ 已废弃 → [[claude-network-resilience-v2]] |
| ~~[[claude-optimal-resilience-design]]~~ | ⚠️ 已废弃 → [[claude-network-resilience-v2]] |

### 2. 事故复盘（status: stable）

| 文档 | 主题 |
|------|------|
| [[claude-cache-incident-postmortem]] | 缓存优化事故复盘（2026-06-16） |
| [[claude-cache-postmortem-2026-06-13]] | 缓存命中率下降排查复盘 |
| [[cc-cache-hitrate-35pct-postmortem]] | 命中率 35.5% 问题排查复盘 |
| [[claude-patch-loss-postmortem]] | Permafrost 补丁丢失事故 |
| [[claude-proxy-deployment-postmortem]] | Python→Node.js 迁移部署事故 |
| [[claude-proxy-restart-incident]] | Proxy 重启事故 |
| [[proxy-cancelretry-hook-incident]] | cancelRetry Hook 卡死事故 |
| [[2026-06-24-hermes-feishu-outage-postmortem]] | Hermes 飞书助手全面瘫痪（P0） |

### 3. Agent-架构模式（status: stable）

| 文档 | 主题 |
|------|------|
| [[agent-async-isolation-pattern]] | Agent 同步调用异步隔离模式 |
| [[deploy-workflow-write-to-repo-first]] | 先仓库后部署工作流规则 |
| [[fan-out-subagent-pattern]] | Fan-Out 扇出分发模式 |
| [[log-analysis-agent-windows-architecture]] | 日志分析 Agent Windows 高并发架构（memory） |
| [[opencode-multi-agent-architecture]] | OpenCode 多智能体协作架构 |
| [[pi-agent-framework-knowledge]] | Pi Agent 框架知识 |
| [[state-machine-quality-gate-loop]] | 状态机质量门控回环 |
| [[log-analysis-agent-architecture]] | 日志分析 Agent 架构参考（ADR） |
| [[multi-session-architecture-2026-07-09]] | 多 PRoot Session 架构 |
| [[pi-agent-constraints-reference]] | Pi Agent 约束与能力参考 |
| [[production-diagnosis-2026-07-06]] | 生产运行诊断与修复 |
| [[subagent-lessons-learned-2026-07-03]] | Subagent 资源管理实施经验 |
| [[subagent-resource-architecture-2026-07-03]] | Subagent 资源管理体系架构 |
| [[main-subagent-realtime-interaction]] | 主Agent与Subagent实时交互方案（心跳/邮箱/打断/恢复，新增 2026-08-25） |
| [[opencode-pi-base-development-analysis]] | 基座开发七维度选型与服务化并发路线图（新增 2026-08-25） |
| [[lognet-rootcause-multiagent-architecture]] | 日志网络根因分析多Agent架构：LogNet/渐进展开/符号化(artget)/可行性（新增 2026-08-25） |
| [[agent-memory-context-knowledge-design]] | 记忆三级模型/上下文五源装配/外部知识库化策略（新增 2026-08-25） |
| [[agent-harness-anatomy]] | Agent Harness 七件套解剖 + Claude Code/OpenCode/Pi/DSH 四家对照 + 构建决策树（新增 2026-08-26） |
| [[agent-evals-observability]] | Agent 评测三层次/四层方法栈(LLM-as-Judge 校准)/trace 采集与门控集成（新增 2026-08-26） |
| [[opencode-深入使用与扩展实战]] | OpenCode 配置体系/自定义 tool 落码/hook 实战/serve-SSE 集成/排障（新增 2026-08-26） |
| [[pi-agent深入使用与扩展实战]] | Pi 三层 API/TypeBox 工具全码/steer-followUp 双队列/RPC 嵌入/JSONL→LogNet 数据源（新增 2026-08-26） |
| [[MEMORY-INDEX]] | memory 索引（含悬空条目说明） |

### 4. Plans（status: deprecated，全部归档）

| 文档 | 废弃指向 |
|------|----------|
| ~~[[agent-gate-optimization-plan-2026-07-06]]~~ | → [[production-diagnosis-2026-07-06]] |
| ~~[[crash-improvement-plan-2026-07-03]]~~ | → [[subagent-resource-architecture-2026-07-03]] |
| ~~[[cross-session-task-exploration-2026-07-06]]~~ | → [[multi-session-architecture-2026-07-09]] |
| ~~[[interactive-aware-subagent-plan-2026-07-03]]~~ | → [[subagent-resource-architecture-2026-07-03]] |
| ~~[[log-analysis-agent-windows-plan]]~~ | → [[log-analysis-agent-architecture]] |
| ~~[[pi-agent-log-analysis-plan]]~~ | → [[pi-agent-constraints-reference]] |
| ~~[[proxy-resilience-optimization-2026-07-09]]~~ | → [[claude-resilience-architecture]] |
| ~~[[resource-class-scheduling-plan-2026-07-03]]~~ | → [[subagent-resource-architecture-2026-07-03]] |

## 关系图

```
Claude-Ops-KB-Home (HOME)
├─ 运维方案与设计 (OPS) — review × 23 · deprecated × 2
├─ 事故复盘 (INC) — stable × 8
├─ Agent-架构模式 (ARCH) — stable × 14 · review × 4（2026-08-25 新增实时交互、基座选型、日志网络根因、记忆与知识库化）
├─ Plans (PLAN) — deprecated × 8
├─ AGENTS (AG)
└─ AI-Links-KB-Home (AI)

交叉连线:
├─ OPS → INC；INC -.复盘反哺.-> OPS
├─ ARCH → OPS；ARCH → PLAN
├─ PLAN -.归档.-> ARCH
├─ AG -.规范约束.-> HOME
└─ AI -.姊妹子库.-> HOME
```

## 标签索引

| 标签 | 用途 | 文档数 |
|------|------|--------|
| `#ai/ops` | Agent 无人值守运维（本子库全局） | 60 |
| `#ai/agent` | 方案/设计/架构模式类 | 43 |
| `#incident` | 事故复盘 | 8 |
| `#moc` | MOC 首页 | 1 |

## 关键数据

| 指标 | 值 |
|------|-----|
| 迁移文档总数 | 56（54 篇迁移 + MOC + [[MEMORY-INDEX]]）；2026-08-25 起 Agent-架构模式 新增 4 篇（[[main-subagent-realtime-interaction]]、[[opencode-pi-base-development-analysis]]、[[lognet-rootcause-multiagent-architecture]]、[[agent-memory-context-knowledge-design]]），全库总数 60 |
| 迁移日期 | 2026-08-17 |
| 来源仓库 | `akb-remote` @ commit `f493130` |
| status 分布 | review 27 · stable 21 · deprecated 10（不含 MOC/索引 2 篇 stable） |
| 目录分布 | 运维方案与设计 25 · 事故复盘 8 · Agent-架构模式 18（含 MEMORY-INDEX；+4 为 2026-08-25 新增）· Plans 8（合计 59 + 本 MOC = 60） |

## 脚本清单

可执行脚本与配置位于 `scripts/claude-ops-deployments/`：

| 目录 | 内容 |
|------|------|
| `root-scripts/` | 韧性代理 proxy.js/py、deploy/rollback、agent-gate、permafrost 补丁、version-hook 等 |
| `deployment-log.md` | 部署记录（追溯每个变更） |
| `proxy-gate/` · `proxy-timeout-fix/` | 代理网关与超时修复部署 + rollback + backups |
| `cc-version-switch/` · `agent-gate/` · `diagnostic-relay/` | 版本切换、gate hooks、诊断中继 |
| `log-analysis-agent/` · `log-analysis-agent-pi/` | 日志分析 Agent 服务（Windows/Pi 版） |
| `lognet-poc/`（vault 根 scripts/） | [[lognet-rootcause-multiagent-architecture]] M0 数据层 PoC：hilog/kmsg→LogNet(SQLite+FTS5)+query_logs/get_subgraph，27 测试全绿（2026-08-26） |
| `patches/` | permafrost_align / model_router 补丁 |
| `demos/` · `tests/` · `components/` | Demo 脚本、测试与可复用组件 |

> [!tip] 部署四规则（AGENTS.md 五·五）
> 任何部署/脚本变更必须满足：记录可追溯 · 部署前验证 · 逃生机制（rollback）· 日志可审计；代码先入仓库再部署。

## 遗留问题

- 远程 `memory/MEMORY.md` 索引 19 条中 12 条悬空（指向归档中不存在的文件）：6 条已重定向至本库等价文档、6 条无本地等价，详见 [[MEMORY-INDEX]]。
- 远程仓库的 `articles/`、`dumps/`、`deployments/` 等目录不在本次迁移清单内，仍保留于 `_install-tmp/akb-remote/`。
