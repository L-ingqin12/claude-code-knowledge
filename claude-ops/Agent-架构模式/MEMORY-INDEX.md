---
title: MEMORY-INDEX
aliases: [Memory 索引, memory 知识索引, MEMORY 记忆索引]
tags: [ai/ops, ai/agent]
created: 2026-08-17
updated: 2026-08-26
status: stable
---

# MEMORY-INDEX — Agent-架构模式记忆索引

> [!abstract] 迁移说明
> 本文档由远程 `memory/MEMORY.md` 索引迁移而来。原索引共 **19 条**，其中 7 条指向实际存在的记忆文件（已迁移入本目录）；**12 条悬空**（指向归档中不存在的文件）——6 条在本子库存在等价文档已重定向，6 条内容散落、无本地等价，原始链接已修复不再悬空。

See also: [[Claude-Ops-KB-Home]] · [[AGENTS]] · [[AI-Links-KB-Home]]

## 实际存在的记忆文档（7 条）

| 记忆文档 | 摘要 |
|----------|------|
| [[agent-async-isolation-pattern]] | ThreadPoolExecutor + asyncio.wait_for 三层超时包装同步 Agent 调用 |
| [[deploy-workflow-write-to-repo-first]] | ⚠️ 所有代码变更先在归档仓库编写测试，用户确认后再部署 |
| [[fan-out-subagent-pattern]] | 并行分发 N 个子任务、防冲突机制、OpenCode vs Claude Code 对比 |
| [[log-analysis-agent-windows-architecture]] | Nginx+Tornado 多进程+ThreadPoolExecutor 异步隔离+Windows TCP 调优 |
| [[opencode-multi-agent-architecture]] | Primary/Subagent 两层模型、自规划调度、Fan-Out、权限隔离 |
| [[pi-agent-framework-knowledge]] | TypeScript monorepo、内置工具 9 种（0.84.3 源码核验，含 powershell/edit-diff）、800token 预算、programmatic SDK |
| [[state-machine-quality-gate-loop]] | 7 状态控制流、VERIFY 门/RETRY 回环/ESCALATE、死循环保护 |

## 2026-08-25 新增架构文档（4 篇）

| 新文档 | 摘要 |
|--------|------|
| [[main-subagent-realtime-interaction]] | 主↔子 agent 实时交互四原语：活性感知(4层金字塔)/邮箱通知/打断抢占/checkpoint 恢复 + T0..T3 升级阶梯 |
| [[opencode-pi-base-development-analysis]] | 基座开发七维度选型：OpenCode 交互基座+Sidecar 外挂 vs Pi 嵌入；明文治理 manifest+secure_read；会话池流水排布；跨平台矩阵与 Phase 0-4 路线图 |
| [[lognet-rootcause-multiagent-architecture]] | 日志网络根因分析多Agent架构：LogNet 图+时间线、从问题节点渐进展开、符号化工具链(addr2line/artget)、多包并发与可行性路线 |
| [[agent-memory-context-knowledge-design]] | 记忆三级模型(L1窗口/L2状态/L3知识库)、上下文五源装配与前缀稳定排序、外部知识库化四形态与写入检索治理（复用本库 AGENTS 协议） |

## 2026-08-26 新增（3 篇）

| 新文档 | 摘要 |
|--------|------|
| [[agent-harness-anatomy]] | Agent Harness 七件套解剖(提示词脚手架/工具循环/上下文记忆/权限沙箱/子代理编排/Hook扩展/观测评测)、Claude Code/OpenCode/Pi/DSH 四家实现对照、从零构建决策树(Anthropic 五模式)与反模式清单 |
| [[agent-evals-observability]] | Agent 评测三层次(单步/轨迹/端到端)、四层方法栈(确定性断言→LLM-as-Judge 校准→人工盲测→在线评估)、trace 结构化采集、质量门控 RETRY/ESCALATE 阈值定标与成本计量 |
| [[Anthropic多智能体研究系统拆解]]（articles/） | 编排者-工作者生产复盘：委派工程三要素/努力分级/15× token 经济学/评测三件套，映射本库协议 |

## 悬空条目已重定向（6 条）

| 原索引条目（文件不存在） | 重定向至本库等价文档 |
|--------------------------|----------------------|
| claude-unattended-operation-guide.md | [[claude-unattended-operation-plan]] |
| claude-interruption-resilience.md | [[claude-interruption-resilience-guide]] |
| claude-context-continuity.md | [[claude-context-continuity-guide]] |
| claude-socket-error-elimination.md | [[claude-socket-error-elimination-guide]] |
| hermes-parallel-task-communication.md | [[hermes-parallel-task-report]] |
| claude-cache-permafrost-setup.md | [[PERMAFROST_MODIFICATIONS]]（+ [[claude-cache-strategy]]） |

## 散落条目无本地等价（6 条）

以下条目在原索引中出现，但归档仓库中既无文件、本库也无等价文档，内容散落未存档：

| 原索引条目 | 主题 |
|------------|------|
| occams-razor-principle.md | 如无必要勿增实体——设计全局约束 |
| claude-code-upgrade-incident-2026-06-09.md | v2.1.150→v2.1.169 升级事故与标准流程 |
| claude-code-preflight-checklist.md | ⚠️ 行动前强制检查清单（5 项检查 + 5 条硬规则） |
| claude-code-environment-architecture.md | Termux+PRoot 混合环境、两条 npm 体系、PATH 优先级（最接近本库文档: [[pi-vs-termux-guide]]） |
| claude-code-npm-postinstall-mechanism.md | optionalDependency→原生二进制→linkSync 替换流程 |
| raspberrypi-proxy-ipv6-fix-pending.md | 树莓派代理 IPv6 无路由修复待续 |

> [!bug] 遗留问题
> 以上 6 条记忆源文件不在远程归档中（`_install-tmp/akb-remote/memory/` 仅有 9 个 md：7 条记忆 + 本索引 + README）。如需补全，需回到原始运行环境 `/root/.claude/projects/-root/memory/` 取回。

## 交叉 Wikilink

- 记忆索引 → MOC：[[Claude-Ops-KB-Home]]
- 部署工作流 → 部署记录：[[claude-deployment-record]]
- 异步隔离/日志分析：[[log-analysis-agent-architecture]] · [[agent-async-isolation-pattern]]
- Fan-Out/质量门控/OpenCode：[[fan-out-subagent-pattern]] · [[state-machine-quality-gate-loop]] · [[opencode-multi-agent-architecture]]
- 实时交互/基座选型：[[main-subagent-realtime-interaction]] · [[opencode-pi-base-development-analysis]] · [[lognet-rootcause-multiagent-architecture]] · [[agent-memory-context-knowledge-design]]
- Harness 解剖/评测观测：[[agent-harness-anatomy]] · [[agent-evals-observability]]
- Pi Agent 体系：[[pi-agent-framework-knowledge]] · [[pi-agent-constraints-reference]]
- Hermes 并行机制：[[hermes-parallel-task-report]]
