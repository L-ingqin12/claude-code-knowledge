---
title: HOME — 知识库全局目录索引
aliases: [知识库首页, 全局索引, KB Home, Vault Home]
tags: [moc, meta]
created: 2026-09-06
updated: 2026-09-06
status: stable
---

# HOME — 知识库全局目录索引

> [!abstract] 定位
> 本文件是整个知识库（Vault）的**全局导航入口**：列出全部子目录、各自的一句话主题与 MOC/入口。
> AI 协作规范与协议见 [[AGENTS]]；各子库内部导航请进入各自 MOC。

## 目录结构速览

| 目录 | 一句话主题 | 入口 / MOC |
|------|-----------|-----------|
| `network/` | 家庭网络优化：WiFi / 小米路由器 / v2rayN 代理 / 排障与复盘 | [[Network-KB-Home]] |
| `ai-dev/` | LLM 应用开发实战：Prompt / RAG / Agent / MCP / 微调 等专题 | [[AI-Dev-KB-Home]] |
| `ai-links/` | AI 链接收藏与调研综述（含 DSH 插件/Hook、编码 Agent 调研报告） | [[AI-Links-KB-Home]] · [[Articles-Index]] |
| `claude-ops/` | Claude Code 无人值守运维：方案设计 / 事故复盘 / Agent 架构模式 | [[Claude-Ops-KB-Home]] · [[MEMORY-INDEX]] |
| `cs-base/` | 计算机基础：语言 / 算法 / 系统 / 数据库 / 工具链 | [[CS-KB-Home]] |
| `typora/` | Typora 无补丁激活复盘与可复用流程 | [[TYPORA-KB-Home]] |
| `diagrams/` | Excalidraw 图表库（绘图规范：禁 Mermaid） | [[ARROW-CHECKLIST]] |
| `scripts/` | 跨库脚本：claude-ops-deployments / dumps / lognet-poc | `scripts/claude-ops-deployments/README.md` |
| `_archive/` | SESSION-ARCHIVE 会话归档（原根目录 SESSION-*.md 已归入） | `_archive/` 目录 |
| `Excalidraw/` | 早期散装 Excalidraw 原图 | — |

## 根目录松散文件

归档后根目录仅剩两个 .md：

- [[AGENTS]] — 知识库 AI 协作规范（按治理约束保留在根目录的唯一原始松散 .md）
- [[HOME]] — 本全局索引文件

> [!note] 根目录非 .md 残留
> 根目录仍存在若干**非知识文档**文件，未纳入本次归档：`SDL2*.dll`、`avcodec-* / avformat-* / swscale-5 / swresample-3 / avutil-56 / avdevice-58 / avfilter-7` 等 DLL（疑似误置于库根的运行时库），以及 gitignore 的临时目录 `__pycache__/`、`_install-tmp/`。建议由人工确认后清理或移动。

## 2026-08 松散文件归档记录

原根目录松散 .md 已按主题归档。库内链接均为 basename 形式 `[[文件名]]`（全库唯一），移动不破坏任何双链。

| 原根目录文件 | 归档去向 |
|---|---|
| `2026-07-21-树莓派网络故障与路由器破解完整复盘.md` | `network/` |
| `参考-VPN代理诊断与优化.md` | `network/` |
| `参考-小米路由器API认证与利用.md` | `network/` |
| `参考-网络路由与代理排障.md` | `network/` |
| `AI大模型开发.md` | `ai-dev/` |
| `参考-Ark-Agent-Plan计费与配置.md` | `ai-dev/` |
| `参考-COM组件框架-Windows集成.md` | `cs-base/` |
| `参考-CPP-CPO定制点与std-execution.md` | `cs-base/` |
| `参考-OpenCode-技术调研报告.md` | `ai-links/` |
| `参考-Pi-Agent-技术调研报告.md` | `ai-links/` |
| `SESSION-ARCHIVE-2026-08-18.md` | `_archive/` |
| `SESSION-ARCHIVE-2026-08-25.md` | `_archive/` |
| `SESSION-ARCHIVE-2026-08-26.md` | `_archive/` |
| `SESSION-ARCHIVE-2026-08-28.md` | `_archive/` |
| `SESSION-ARCHIVE-2026-08-30.md` | `_archive/` |

## 文件导航（按更新时间，点击跳转）

> 最近 10 天修改的知识文档，按日期分组；每条是 [[wikilink]]，点击直达。完整清单可由脚本定期重生成。

### 2026-09-06
- [[逃生回滚导航]]
- [[微调数据工程与模型蒸馏]]
- [[tianshu-cache-aim-plan]]
- [[proxy-cancelretry-hook-incident]]
- [[pi-agent-log-analysis-plan]]
- [[pi-agent-framework-knowledge]]
- [[pi-agent-constraints-reference]]
- [[log-analysis-agent-architecture]]
- [[hermes-parallel-task-report]]
- [[hermes-cache-analysis]]
- [[fan-out-subagent-pattern]]
- [[deployment-log]]
- [[deploy-workflow-write-to-repo-first]]
- [[deepseek-400-mitigation-usage]]
- [[deepseek-400-mitigation-design]]
- [[claude-unattended-operation-plan]]
- [[claude-unattended-methodology]]
- [[claude-unattended-cross-platform-guide]]
- [[claude-streaming-forward-design]]
- [[claude-socket-error-elimination-guide]]
- [[claude-resource-protocol]]
- [[claude-resilience-usage]]
- [[claude-resilience-architecture]]
- [[claude-port-rebind-solution]]
- [[claude-optimal-resilience-design]]
- [[claude-network-stability-gate]]
- [[claude-network-resilience-v2]]
- [[claude-network-resilience-design]]
- [[claude-interruption-resilience-guide]]
- [[claude-flash-primary-analysis]]
- [[claude-deployment-record]]
- [[claude-context-continuity-guide]]
- [[claude-code-auto-mode-classifier-cache]]
- [[claude-cache-strategy]]
- [[claude-cache-relay-design]]
- [[claude-cache-proxy-evaluation]]
- [[claude-cache-optimization]]
- [[agent-async-isolation-pattern]]
- [[Network-KB-Home]]
- [[MEMORY-INDEX]]
- [[HOME]]
- [[Claude-Ops-KB-Home]]
- [[AI大模型开发]]
- [[AI-Links-KB-Home]]
- [[AGENTS]]
- [[2026-08-16-AI链接综述与归档]]
- [[2026-07-21-树莓派网络故障与路由器破解完整复盘]]

### 2026-08-31
- [[设计模式实战]]
- [[给LLM做脑扫描-可解释性技术全景]]
- [[日志检索分析系统-Skill管理Demo设计]]
- [[参考-网络路由与代理排障]]
- [[参考-小米路由器API认证与利用]]
- [[参考-VPN代理诊断与优化]]
- [[参考-Pi-Agent-技术调研报告]]
- [[参考-OpenCode-技术调研报告]]
- [[参考-ClaudeCode网络韧性]]
- [[参考-Ark-Agent-Plan计费与配置]]
- [[上下文工程-注意力预算与四层解法]]
- [[v2rayn-balancer-复盘-2026-08-09]]
- [[state-machine-quality-gate-loop]]
- [[resource-class-scheduling-plan-2026-07-03]]
- [[proxy-resilience-optimization-2026-07-09]]
- [[pi-vs-termux-guide]]
- [[opencode-multi-agent-architecture]]
- [[network-analysis-2026-07-28]]
- [[log-analysis-agent-windows-plan]]
- [[log-analysis-agent-windows-architecture]]
- [[hermes-session-optimization-report]]
- [[explorer-cpu-spin-postmortem-2026-08-28]]
- [[cross-session-task-exploration-2026-07-06]]
- [[crash-improvement-plan-2026-07-03]]
- [[claude-proxy-deployment-postmortem]]
- [[claude-patch-loss-postmortem]]
- [[claude-cache-postmortem-2026-06-13]]
- [[claude-cache-incident-postmortem]]
- [[TYPORA-KB-Home]]
- [[Skill规模化管理-从渐进式披露到检索式发现]]
- [[SESSION-ARCHIVE-2026-08-30]]
- [[SESSION-ARCHIVE-2026-08-28]]
- [[SESSION-ARCHIVE-2026-08-26]]
- [[SESSION-ARCHIVE-2026-08-25]]
- [[SESSION-ARCHIVE-2026-08-18]]
- [[SESSION-ARCHIVE-2026-07-28]]
- [[SAE-视觉特征单义性-NeurIPS2025]]
- [[ROUTER-VIDEO-REMOTE-MONITOR]]
- [[ROUTER-OPTIMIZATION]]
- [[ROUTER-FULL-CAPABILITY]]
- [[ROUTER-DEEP-EXPLORATION]]
- [[Prompt-Engineering入门与Demo]]
- [[PatchSAE-概念重映射-ICLR2025]]
- [[PERMAFROST_MODIFICATIONS]]
- [[OPTIMIZATION-AUDIT]]
- [[MCP协议开发实战]]
- [[Loop-Engineering-深度拆解-从产品功能集到方法论包装]]
- [[LoRA参数高效微调实战]]
- [[LLM推理部署与量化]]
- [[GUIDE]]
- [[Function-Calling工具调用实战]]
- [[FINAL-SUMMARY]]
- [[DSH跨框架Skills与MCP加载]]
- [[DSH插件与Hook开发最佳实践]]
- [[DSH提效与Token插件调研]]
- [[DSH-TUI插件使用手册]]
- [[Claude-Code记忆机制源码拆解]]
- [[Claude-Code实用Skills参考]]
- [[Articles-Index]]
- [[Anthropic-Skill系统深度分析]]
- [[Agent驱动Skill迁移设计]]
- [[Agent韧性架构分析-微信转载]]
- [[ARROW-CHECKLIST]]
- [[ARCHITECTURE]]
- [[2026-08-10-Typora无补丁激活复盘与手册]]
- [[2026-06-24-hermes-feishu-outage-postmortem]]
