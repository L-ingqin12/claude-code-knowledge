---
title: Agent Harness 解剖学与构建决策树
aliases: [Harness解剖学, Agent Harness知识, 编排外壳构建指南]
tags: [ai/ops, ai/agent]
created: 2026-08-26
updated: 2026-08-26
status: review
source: 综合视图文档——外部依据：Anthropic《Building Effective Agents》、Simon Willison 编码代理原理综述、harness engineering 论述；内部依据：本库 OpenCode/Pi/CC 拆解文档（正文逐条挂锚）
fetched_at: 2026-08-26
---

# Agent Harness 解剖学与构建决策树

> [!abstract] 定位
> 库内 harness 相关知识此前散落在调研报告、课程笔记与文章拆解中，缺一张综合视图。本文给出：**harness 的定义谱系**（vs framework/scaffold）、**七件套解剖**（每件挂库内锚点）、**Claude Code / OpenCode / Pi / DSH 四家实现对照**、**从零构建的决策树**（Anthropic 五模式 + start-simple 原则）与反模式清单。所有外部论断附来源，内部论断挂文档锚点。

See also: [[参考-OpenCode-技术调研报告]] · [[参考-Pi-Agent-技术调研报告]] · [[main-subagent-realtime-interaction]] · [[agent-memory-context-knowledge-design]] · [[Claude-Ops-KB-Home]]

## 一、定义与谱系

| 术语 | 含义 | 代表 |
|------|------|------|
| **Framework** | 提供抽象层让"你写 agent"的代码库 | LangChain/LangGraph、Spring AI |
| **Scaffold** | 围绕模型的最小可运行外壳（提示词+循环+工具） | 早期 openai/evals 式脚本 |
| **Harness** | 生产级 scaffold：把系统提示词、工具循环、上下文管理、权限、子代理、扩展点、观测**七件事产品化**的外壳 | Claude Code、OpenCode、Pi、Cursor |

术语工程化脉络：Simon Willison 把编码代理归纳为"harness 包住模型反复调用工具"的回路（[practitioner guide 转述](https://subagentic.ai/howtos/simon-willison-how-coding-agents-work/)）；"harness engineering" 已被当作独立工程学科讨论（[The Rise of Agentic Engineering Part 5](https://dev.to/raminjafary/the-rise-of-agentic-engineering-part-5-harness-engineering-emerges-2d9o)）；社区甚至出现 100+ harness 的策展清单（[best-of-Agent-Harnesses](https://github.com/RyanAlberts/best-of-Agent-Harnesses)）。Anthropic 官方立场：能 workflow 别 agent，**从最简开始按需加复杂度**（[Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents)）。

> [!info] 与本库的关系
> 本库 AGENTS.md 协议 + DSH 运行时即一个自建 harness 实例；[[Vercel-AI编码Agent-Harness课程]] 是其教学版；[[Loop-Engineering-深度拆解-从产品功能集到方法论包装]] 是对其过度包装倾向的批判视角。

## 二、七件套解剖（每件 = 职责 / 实现 / 库内锚点）

### 1. 系统提示词脚手架
职责：角色定义 + 环境注入 + 渐进披露。
实现：CLAUDE.md/AGENTS.md 分层加载；SKILL.md 按需注入防撑爆窗口。
锚点：[[Claude-Code实用Skills参考]] · [[Skill规模化管理-从渐进式披露到检索式发现]] · Pi ~800 token 预算哲学（[[pi-agent-framework-knowledge]]）

### 2. 工具循环与参数契约
职责：模型↔工具的 ReAct 循环与 schema 校验。
实现：OpenCode 用 zod 契约注册自定义 tool；Pi `defineTool<TParams extends TSchema>` 用 TypeBox；MCP 作为外挂工具总线。
锚点：[[参考-OpenCode-技术调研报告]] §4 · [[参考-Pi-Agent-技术调研报告]] §11.1 · [[MCP协议开发实战]] · [[Function-Calling工具调用实战]]

### 3. 上下文管理与记忆
职责：有限注意力预算下的装配/压缩/持久化。
实现：compaction、三级记忆（L1 窗口/L2 checkpoint/L3 知识库）、前缀稳定排序保 cache 亲和。
锚点：[[agent-memory-context-knowledge-design]] · [[上下文工程-注意力预算与四层解法]] · [[上下文工程落地实践-从理论到Claude-Code实现]]

### 4. 权限与沙箱
职责：工具调用的策略闸门与执行隔离。
实现：OpenCode permission last-match 规则引擎 + 程序化审批 hook（`permission.ask`），权限键实为 doom_loop/external_directory；Pi 无内核权限 → 容器化兜底；Sidecar 场景加命名空间级边界。
锚点：[[参考-OpenCode-技术调研报告]] §8/§11 · [[参考-COM组件框架-Windows集成]] §五安全边界

### 5. 子代理与编排
职责：上下文分区并行 + 委派协议 + 活性监控。
实现：task 委派/subagent_type；fan-out 分发卡三要素；steer/followUp 双队列打断注入；15× token 经济学下的看门狗必要性。
锚点：[[main-subagent-realtime-interaction]] · [[fan-out-subagent-pattern]] · [[Anthropic多智能体研究系统拆解]] · 多代理何时不用见 [Claude 官方 when-and-how](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them)

### 6. Hook 与扩展面
职责：不改内核注入横切逻辑（预处理/审批/遥测/短路）。
实现：OpenCode plugin hooks（chat.params/tool.execute.before/permission.ask/event…）；Pi 25+ 扩展事件 + resources_discover；跨框架差异见 DSH 系列。
锚点：[[DSH插件与Hook开发最佳实践]] · [[DSH跨框架Skills与MCP加载]]

### 7. 可观测与评测
职责：trace 化每次模型/工具调用；以评测分驱动质量门控（RETRY/ESCALATE）。
锚点：详见姊妹篇 [[agent-evals-observability]] · [[state-machine-quality-gate-loop]] · [[Claude-Code记忆机制源码拆解]]（会话文件即观测数据源之一）

## 三、四家实现对照

| 七件套 | Claude Code | OpenCode | Pi | DSH（本库） |
|--------|-------------|----------|----|------------|
| 提示词脚手架 | CLAUDE.md+Skills | agent/*.md frontmatter | manifest+~800 预算 | AGENTS.md 协议 |
| 工具循环 | 内置+MCP | zod 自定义 tool+MCP | TypeBox defineTool | DSH 工具集+MCP |
| 上下文/记忆 | compaction+记忆机制 | 会话文件+SDK 读写 | 树状 JSONL+steer 注入 | session jsonl+goal 工具 |
| 权限/沙箱 | settings allowlist | permission 引擎+ask hook | 无内核→容器化 | approval policy+file sandbox |
| 子代理 | Task/Agent 工具 | task 委派+四内置件 | 无 spawn→多 Session 模拟 | subagent/workflow/ralph |
| Hook 扩展 | hooks 事件 | plugin hooks 总线 | 25+ extension events | hooks+skills 加载器 |
| 观测评测 | transcript jsonl | /event SSE 流 | print/RPC 模式 | job_output/goal 工具闭环 |

（每格均可回溯到 §二 对应锚点文档；OpenCode/Pi 列的事实口径以各自调研报告 §11 实机核验为准）

## 四、从零构建决策树（有依据版）

```
0. 先定成功标准与评测集（Anthropic：evals 先于复杂度）
1. 任务可枚举为固定步骤？ ──是──▶ Workflow：prompt chaining / routing
2. 步骤独立可并行？ ──是──▶ parallelization（并行买覆盖率，注意 token 放大）
3. 需要动态拆解未知路径？ ──是──▶ orchestrator-workers（先读 when-not-to 清单）
4. 结果需迭代打磨且有客观判据？ ──是──▶ evaluator-optimizer 循环
5. 以上都不满足才上自由 Agent loop（工具+环境反馈自主多步）
6. 工具面优先走 MCP 外挂而非改内核；权限闸门第 4 件同步上线
7. 复杂度每加一层，回到第 0 步验证评测增量是否为正
```

依据：[Building Effective Agents](https://www.anthropic.com/engineering/building-effective-agents) 五模式与 start-simple 原则；并行/编排收益数据见 [[Anthropic多智能体研究系统拆解]] §二。

## 五、反模式清单

| 反模式 | 症状 | 解药 |
|--------|------|------|
| 方法论包装先行 | 先造概念体系再找场景 | [[Loop-Engineering-深度拆解-从产品功能集到方法论包装]] 的批判框架 |
| 过早多代理 | 单代理+好工具就能赢的任务上 fan-out | [when not to use multi-agent](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them)；先跑通 workflow |
| 无预算 fan-out | 15× token 账单事故 | 编排层预算闸（[[opencode-pi-base-development-analysis]] 背压节） |
| 提示词万能论 | 把 harness 该做的工程塞进 prompt | 七件套各归其位（本文 §二） |
| 评测后置 | 上线后才定义"成功" | 决策树第 0 步 + [[agent-evals-observability]] |

## 六、待确认项

> ① Cursor/Aider 等 harness 在七件套上的差异未逐项核验（仅入清单未入对照表）；② "harness engineering" 术语的最早提出者考证（当前仅追溯到 2025 年社区论述）；③ DSH ralph 模式的公开对标物。

## Related

[[参考-OpenCode-技术调研报告]] · [[参考-Pi-Agent-技术调研报告]] · [[agent-evals-observability]] · [[Anthropic多智能体研究系统拆解]] · [[agent-memory-context-knowledge-design]] · [[main-subagent-realtime-interaction]] · [[lognet-rootcause-multiagent-architecture]] · [[Claude-Ops-KB-Home]]
