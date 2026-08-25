---
title: Anthropic多智能体研究系统拆解
aliases: [Multi-Agent Research System, 编排者-工作者模式拆解]
tags: [ai/links, ai/agent]
created: 2026-08-26
updated: 2026-08-26
status: review
source: Anthropic Engineering《How we built our multi-agent research system》(2025-06) 及多源转述交叉验证
source_urls:
  - https://www.anthropic.com/engineering/multi-agent-research-system
  - https://simonwillison.net/2025/Jun/14/multi-agent-research-system/
  - https://www.zenml.io/llmops-database/building-production-multi-agent-research-systems-with-claude
author: Anthropic（原文）/ 本库拆解
fetched_at: 2026-08-26
---

# Anthropic 多智能体研究系统拆解

> [!abstract] 为什么补这篇
> 文章库此前覆盖 Skill 系统、上下文工程、记忆机制、可解释性，唯独缺**多智能体编排**一组——而这恰是本库当前主线（OpenCode/Pi 基座二开 + LogNet 专家编排）。Anthropic 这篇是生产级 Orchestrator-Worker 模式最完整的一手复盘，其"委派工程/上下文经济学/评测三件套/生产化教训"可直接映射进 [[main-subagent-realtime-interaction]] 的协议设计与 [[opencode-pi-base-development-analysis]] 的基座选型判断。

See also: [[Articles-Index]] · [[AI-Links-KB-Home]] · [[fan-out-subagent-pattern]] · [[state-machine-quality-gate-loop]] · [[lognet-rootcause-multiagent-architecture]]

## 一、架构：Orchestrator-Worker

```
用户研究请求
   │
Lead Agent（编排者，extended thinking）
   ├─ 拆解为可并行的子方向 ──▶ Subagent×3–5（各自独立上下文窗口）
   │        └─ 并行工具调用：搜索/抓取 → 压缩摘要回传
   ├─ 汇总子结论，必要时追加派发（迭代式）
   └─ 引用一致性检查 ▶ 最终带引用报告
Memory/Citation Agent 等专职角色按需挂载
```

- 与 [[Agent驱动Skill迁移设计]] 的单代理 Skill 注入互补：这里是**上下文分区**路线——每个 subagent 独占窗口，主上下文只收摘要
- 关键约束：编排是**同步扇出-汇聚**循环；subagent 数量按查询复杂度弹性伸缩而非固定

## 二、为什么有效：上下文经济学

| 观测 | 数字 | 含义 |
|------|------|------|
| token 放大系数 | 多智能体 ≈ 单对话的 **15×** tokens | 并行买时间与覆盖率，烧钱换质量；预算治理必须前置 |
| 工具调用深度收益 | 子代理工具调用翻倍 → 相对提升 **90.2%** | 收益来自"多试几次"而非更聪明 |
| 并行工具调用 | 启用后相对提升约 14.5% | 同窗口内并发读操作几乎白赚 |

> [!tip] 对齐本库
> 15× 系数正是 [[main-subagent-realtime-interaction]] 里"看门狗+邮箱"存在的理由——放大器越猛，活性监控与打断越关键。

## 三、委派工程（Delegation Engineering）——全文最有复用价值

1. **教编排者如何委派**：lead prompt 明确"何时拆、拆几路、每路给多少努力"
2. **努力分级规则**（写进系统提示词）：
   - 简单事实查证 → 1 agent，3–10 turns
   - 比较/综述 → 2–4 agents 分维度
   - 新颖争议题 → 起步即可 5+ agents，允许迭代加派
3. **子任务描述三要素**：目标（客观可判）→ 输出格式（摘要规格）→ 工具清单（边界）。模糊委派 = 子代理自由发挥 = 回传噪声

> [!note] 与本库对照
> 三要素即 [[fan-out-subagent-pattern]] 的"分发卡"字段集；努力分级表可平移进 OpenCode agent frontmatter 的 description 字段（模型据描述路由，见 [[参考-OpenCode-技术调研报告]] §1.3）。

## 四、评测三件套

| 方法 | 做法 | 防什么 |
|------|------|--------|
| LLM-as-judge | 固定 rubric 打分（引用支撑/覆盖/平衡），与人工评分校准一致性 | 主观漂移 |
| 人工真实任务 | 内部工程师盲测对比单代理基线 | "基准好看但没人用" |
| 生产遥测 | 真实使用率/完成率回归 | 过拟合到评测集 |

本库 [[state-machine-quality-gate-loop]] 的 QA 门控可直接引用该三层结构做 ESCALATE 判据。

## 五、生产化教训（踩坑清单）

1. **状态即债务**：会话中途崩溃 → 需要 checkpoint/resume 才能救长任务；无状态重跑代价 15×
2. **中断恢复**：用户随时打断，必须支持从任意 step 续跑（对应本库 checkpoint 模板）
3. **token 预算治理**：不设上限的 fan-out = 账单事故；编排层要有预算闸门与降级路径
4. **引用保真**：子代理压缩摘要时丢引用 → 最终报告不可溯源；摘要规格里强制保留 URL/出处
5. **同步 vs 异步**：v1 全同步编排简单但延迟线性叠加；异步+事件通知是演进方向（OpenCode issue #5887 同款缺口）

## 六、对本库的直接映射

| Anthropic 教训 | 本库落点 | 差距动作 |
|----------------|----------|---------|
| 努力分级委派 | OpenCode agent frontmatter / Pi extension binding | 写入基座配置模板（Phase 0 交付物之一） |
| 子任务三要素 | fan-out-subagent-pattern 分发卡 | 已对齐 ✓ |
| checkpoint/resume | main-subagent-realtime-interaction T3 恢复原语 | 协议已设计，实现排期 M3 |
| token 预算闸 | opencode-pi-base-development-analysis §会话池背压 | 待在 Sidecar 落地 |
| 引用保真 | LogNet EventNode.raw_offset 可回溯指针 | PoC 已实现（query_logs refs 字段）✓ |

## 七、待确认项

> ① 90.2%/14.5% 两数的精确实验口径（相对/绝对、基准集）；② Lead Agent 是否使用 extended thinking 的 A/B 数据；③ Memory Agent 的持久化形态（原文仅一笔带过）；④ Citation Agent 独立成角色的版本节点。

## Related

- [[main-subagent-realtime-interaction]] · [[fan-out-subagent-pattern]] · [[state-machine-quality-gate-loop]] — 本库协议侧对照
- [[参考-OpenCode-技术调研报告]] · [[参考-Pi-Agent-技术调研报告]] — 基座能力依据
- [[lognet-rootcause-multiagent-architecture]] — 专家编排消费方
- [[上下文工程落地实践-从理论到Claude-Code实现]] — 单代理侧上下文工程姊妹篇
