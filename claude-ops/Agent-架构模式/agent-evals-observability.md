---
title: Agent 评测与可观测性知识
aliases: [Agent评测, agent-evals, LLM-as-Judge, 可观测性知识]
tags: [ai/ops, ai/agent]
created: 2026-08-26
updated: 2026-08-26
status: review
source: 外部依据：Anthropic Building Effective Agents/Multi-Agent Research System 评测章节、LangSmith trajectory evals 与 online evaluators 文档、LLM-as-Judge 校准实践；内部锚点：质量门控/实时交互/LogNet 各文档
fetched_at: 2026-08-26
---

# Agent 评测与可观测性知识

> [!abstract] 定位
> 库内已有"质量门控状态机"（怎么判 RETRY/ESCALATE），但**评测方法论本身**（判据从哪来、怎么校准、trace 怎么采）无沉淀。本文补齐：评测对象三层次、四层方法栈（含校准与在线评估）、可观测 trace 采集要点、回归门控集成与成本维度。Anthropic 的立场是评测先于复杂度——成功标准不定，一切架构讨论都是空转。

See also: [[state-machine-quality-gate-loop]] · [[agent-harness-anatomy]] · [[Anthropic多智能体研究系统拆解]] · [[main-subagent-realtime-interaction]] · [[Claude-Ops-KB-Home]]

## 一、评测先行（为什么排第一）

Anthropic《Building Effective Agents》的构建顺序是：**定义成功标准 → 建最小评测集 → 再谈架构复杂度**。没有可度量判据时：① 无法判断 workflow→agent 的升级是否为正收益；② 多代理 15× token 放大失去对照基线；③ 质量门控的阈值沦为拍脑袋。
库内映射：[[lognet-rootcause-multiagent-architecture]] §九.3 的 PoC 假设清单就是该原则的实例（每阶段带验收口径）。

## 二、评测对象三层次

| 层次 | 对象 | 典型断言 | 工具形态 |
|------|------|---------|---------|
| L1 单步 | 单次工具调用/单轮回复 | 参数 schema 合法？检索命中？ | 单元式断言集 |
| L2 轨迹 (trajectory) | 整个执行路径 | 步骤顺序合理？没绕路？工具选择对？ | LangSmith [trajectory evals](https://langchain-5e9cc07a.mintlify.app/langsmith/trajectory-evals)：对比参考轨迹或按规则评分 |
| L3 端到端 (outcome) | 最终交付物 | 报告引用保真？根因结论正确？ | rubric 打分 + 人工抽检 |

> [!tip] 本库对应
> LogNet PoC 的 27 项测试 = L1；多代理展开后的"根因命中率"（Doc D §十 M2 口径）= L3；L2 目前缺位——可在 Sidecar 里以结构化 step 日志 + 规则评分补齐（见 §四）。

## 三、方法栈四层（由便宜到贵）

1. **确定性断言**：schema 校验、引用可回溯（如 query_logs refs 指针能 reopen 到原始字节——已在 PoC 测试落地）
2. **LLM-as-Judge + rubric**：固定评分维度（groundedness/覆盖/平衡），few-shot 锚点样例定标；judge 与人类分歧需定期抽样校准（[LangChain 校准实践](https://www.langchain.com/resources/llm-as-a-judge)）
3. **人工盲测**：真实任务对比基线（单代理 vs 多代理），防"基准好看没人用"
4. **在线评估**：生产流量采样跑 evaluator，持续回归（[LangSmith online evaluators](https://langchain-5e9cc07a.mintlify.app/langsmith/online-evaluations-multi-turn)，支持多轮会话级判定）

Anthropic 多代理系统的三件套（rubric judge / 人工真实任务 / 生产遥测）正是 2+3+4 的组合，详见 [[Anthropic多智能体研究系统拆解]] §四。

## 四、可观测性采集要点

- **Trace 结构化**：每次 LLM 调用/工具调用记为 span（输入摘要/输出摘要/token/延迟/错误）；父子关系=委派树。OpenTelemetry GenAI 语义约定可作为字段命名基准（成熟度演进中，**待确认**当前版本号）
- **本库既有实践**：
  - DSH `session.jsonl`（事件级全量回放，本会话重建即靠它）
  - `builder.stats` 结构化统计（解析侧可审计性，见 deployment-log 2026-08-26 条目）
  - job/goal 生命周期事件（后台任务的活性观测原语）
- **多代理特有**：委派边界必须落 span 边界——否则子代理耗时/失败无法归因（[[main-subagent-realtime-interaction]] T0 感知的数据基础）

## 五、回归与门控集成

```
评测分 ──▶ 质量门控状态机（[[state-machine-quality-gate-loop]]）
   ├─ ≥ 阈值A ──▶ PASS 归档
   ├─ A > x ≥ B ──▶ RETRY（换策略重跑，预算内 N 次）
   └─ < B    ──▶ ESCALATE（人工/更强模型）
```

- 阈值必须来自 §三 第 2/3 层的历史分布（分位数定标），不是整数美感
- CI 内置 agent 冒烟：每次 harness 配置变更（提示词/权限/工具面）跑 L1+采样 L2，防止"改一句 prompt 崩一条链路"
- 升级阶梯与看门狗联动：连续 ESCALATE 触发 T2/T3（[[main-subagent-realtime-interaction]]）

## 六、成本维度

- 计量口径统一到 span：tokens/调用次数/墙钟分别入账，才能定位"慢在哪、贵在哪"
- 多代理预算闸在编排层实现（fan-out 前 check 余量），参考 15× 系数做容量规划
- 评测本身也有成本：judge 用小模型 + 分层采样（L1 全量、L2 按失败率采样、L3 定期抽检）

## 七、待确认项

> ① OpenTelemetry GenAI 语义约定的稳定版本号与字段全集；② LangSmith 在线评估对本库私有部署形态的支持方式；③ judge 校准的最小标注样本量经验值（文献口径不一）；④ DSH 侧 trace 导出为 OTLP 的可行性。

## Related

[[agent-harness-anatomy]] · [[state-machine-quality-gate-loop]] · [[Anthropic多智能体研究系统拆解]] · [[main-subagent-realtime-interaction]] · [[lognet-rootcause-multiagent-architecture]] · [[opencode-pi-base-development-analysis]] · [[Claude-Ops-KB-Home]]
