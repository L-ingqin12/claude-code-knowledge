---
title: Agent记忆与上下文系统设计及知识库化策略
aliases: [Memory Context 设计策略, 记忆上下文知识库化, agent-memory-context-design]
tags: [ai/ops, ai/agent]
created: 2026-08-25
updated: 2026-08-26
status: review
---

# Agent 记忆与上下文系统设计及知识库化策略

> [!abstract] 概述
> 为基座与分析系统补齐"记忆什么、上下文装什么、知识放哪里"的三层设计：①**三级记忆模型**——工作上下文（预算制装配）/ 会话状态（checkpoint 文件）/ 长期记忆（案例库·故障模式库）；②**上下文组装五源策略**——稳定前缀优先、渐进披露、控制信息走结构通道；③**外部知识库化**——知识出提示词、出代码，进 git 版本化的文件知识库，本 Vault（[[AGENTS]] 协议）即为可复用的活参考实现。

See also: [[main-subagent-realtime-interaction]] · [[opencode-pi-base-development-analysis]] · [[lognet-rootcause-multiagent-architecture]] · [[Agent-Skills技能开发实战]] · [[Claude-Ops-KB-Home]]

## 一、为什么需要专门设计

没有记忆设计的多 Agent 系统会出现三类慢性病：**每次冷启动重复踩坑**（同样的崩溃模式反复人工定位）、**上下文被垃圾撑爆**（把历史对话、失败尝试全带在身上，token 成本线性上涨且注意力稀释）、**知识锁死在个人提示词里**（专家经验无法共享、无法审计、人走茶凉）。三者分别对应下面三节的设计对象。

## 二、三级记忆模型

| 层级 | 载体 | 生命周期 | 典型内容 | 本库对应实践 |
|------|------|---------|---------|-------------|
| L1 工作上下文 | 模型窗口 | 单 turn～单会话 | system prompt 核心规则、manifest/子图摘要、当前任务指令 | [[pi-agent-constraints-reference]] 800token 极简哲学 |
| L2 会话状态 | 文件（JSON/markdown） | 单任务（跨 worker 可迁移） | checkpoint、frontier/visited、假设树、inbox_cursor | [[claude-interruption-resilience-guide]] task-state 三层恢复 |
| L3 长期记忆 | 版本化知识库 | 跨会话永久（可废弃） | 根因案例、故障模式、错误码词典、判读 SKILL、路由规则 | 本 Vault 全库（MOC+wikilink+frontmatter） |

> [!tip] 分层判定口诀
> **当轮要用的进 L1，打断要续的进 L2，下次还想要的进 L3**。拿不准时降级存放（L3 文件比 L1 提示词便宜得多），但绝不允许越级——把长期知识硬编码进系统提示词是最高频反模式。

## 三、L1：上下文组装策略（五源装配）

```
┌ system prompt      —— 身份+铁律+输出契约（稳定，≤2k tokens）
├ 规范注入            —— AGENTS.md/instructions 数组（半稳定）
├ Skills 渐进披露     —— name+description 常驻，正文按需加载（动态）
├ 工具返回            —— manifest/子图摘要/查询TopN（结构化、有界、带引用指针）
└ 控制消息           —— mailbox 未读/watchdog nudge（独立通道，不混业务流）
```

三条纪律：

1. **前缀稳定性排序**：静态→半静态→动态依次排列，让 provider 前缀缓存最大化命中（省 50-90% 输入费用，教训见 [[cc-cache-hitrate-35pct-postmortem]]）；每轮变化的内容（工具结果）永远放最尾部；
2. **一切有界**：任何单源注入都设 token 上限并写明截断策略（对照 [[DSH跨框架Skills与MCP加载]] 的 32KiB 记忆预算：宽泛的先裁、具体的最先截断）；
3. **数据不进上下文的替代路径**：大对象只注入"引用指针+offset"，原文经工具按需取（[[lognet-rootcause-multiagent-architecture]] 的 manifest+secure_read 即此模式的实例）。

## 四、L2：会话状态与恢复

沿用 [[main-subagent-realtime-interaction]] §五的 checkpoint 协议：状态文件唯一事实源、产物即时落盘、恢复 prompt 模板。补充两条记忆视角的规则：

- **L2 是 L1 的垃圾场**：被打断会话的一切中间思考不必抢救进新窗口，只需保证"结论与进度"在状态文件里；
- **会话结束时的收割钩子**：`session.idle` 事件里跑一次"值得进 L3 吗？"评估（见 §六写入门槛），通过则生成案例草稿待审。

## 五、L3：长期记忆的知识库化（外部知识库）

### 5.1 四类知识形态与载体

| 类型 | 内容举例 | 载体形态 | 加载路径 |
|------|---------|---------|---------|
| 规则类 | 解析器注册表、Router 关键词表、权限白名单 | YAML/JSON（schema 化） | Sidecar 配置热更新 |
| 事实类 | 错误码词典、模块-进程映射、时钟域参数 | Markdown 表格或 YAML | `kb_lookup(code)` MCP 工具 |
| 方法论类 | 各日志类型判读指南、符号化操作手册 | SKILL.md（frontmatter+正文渐进披露） | skill 工具按名加载 |
| 案例类 | 根因案例：症状→证据链→结论→置信度 | Markdown 文件（frontmatter+wikilink 互联） | `kb_search(signals)` 检索注入 |

### 5.2 直接复用本 Vault 的协议作为产品内知识库规范

本知识库本身就是一套经过实战检验的外部知识库参考实现，产品内建库时照抄即可：

| 本 Vault 约定（[[AGENTS]]） | 产品知识库中的对应价值 |
|---------------------------|---------------------|
| frontmatter 强制（title/tags/status/created/updated） | 机器可过滤：按 tag 圈定检索域、按 status 排除草稿 |
| wikilink ≥3 双向链接 + MOC 地图 | 案例自动成网：相似故障经链接跳转，Graph 即关联图谱 |
| 一文档一问题 | 检索单元精准，避免整篇塞入上下文 |
| callout 规范（danger/tip/bug） | 模型可稳定识别警示段与结论段 |
| 禁 Mermaid、图表走 Excalidraw/文字树 | 保证任何渲染器/解析器可读 |
| 六、知识更新协议（新增/修改/废弃流程） | 案例生命周期治理：draft→review→stable→deprecated |
| Dataview 仪表盘（孤立笔记/最近更新检查） | 知识库健康度巡检自动化 |

### 5.3 写入与检索治理

**写入门槛（防污染三闸门）**：

1. QA 门控通过的结论才允许立案例（[[state-machine-quality-gate-loop]] 复用）；
2. 用户确认/实机验证后 draft→review→stable；同一症状已有 stable 案例时改为**增量更新原案例**而非新建（一症状一案）；
3. 废弃不删除：status=deprecated + warning 指向替代案例（历史可追溯）。

**检索策略（混合三段式）**：

```
kb_lookup(错误码/签名)        ← 精确命中，O(1)，优先
  └ miss → kb_search(信号集)  ← FTS 关键词 + 信号重叠度评分
        └ miss → 向量语义检索  ← 可选增强（嵌入库），仅作兜底
```

> [!warning] 案例注入是"参考假设"，不是"既定事实"
> 检索到的历史案例必须以"相似案例供参考，请独立验证"的措辞注入，并要求 Agent 给出匹配/不匹配的证据——否则旧案例会锚定推理，把新问题硬套进旧结论（锚定偏差是多 Agent 复用记忆的第一事故原因）。案例命中后仍走完整证据链展开，只是 frontier 初始化可以偏向案例指向的区域。

## 六、文档化策略

- **设计即文档**：每个子系统一份 ADR 式文档（决策表+理由+备选），与本库 [[log-analysis-agent-architecture]] 同风格；
- **配置即文档**：注册表/路由表 YAML 内强制注释头说明字段含义与修改流程；
- **变更留痕**：知识库改动走 git commit（先仓库后部署，[[deploy-workflow-write-to-repo-first]]）；案例页 updated 字段 + 部署记录双轨追溯；
- **新人上手包**：MOC 入口 + 判读 SKILL 清单 + 案例库 Top10 经典案例，目标半天可上手（对应基座需求维度 6）。

## 七、反模式清单

> [!warning] 五个高频反模式
> 1. **记忆即转储**——所有会话无差别入库，三个月后案例库全是噪声，检索信噪比崩塌；
> 2. **案例锚定**——历史案例以事实口径注入，新问题被硬套旧结论（§5.3 对策）；
> 3. **知识进提示词**——把错误码表写死在 system prompt，每次更新都要发版且撑爆预算；
> 4. **无版本知识库**——知识改动无 commit/无 review，出错无法回滚也无法追责；
> 5. **缓存盲区**——上下文组装不排序，动态内容插在前缀里导致缓存命中率归零（成本×5 起步）。

## Related

- [[main-subagent-realtime-interaction]] — L2 会话状态的 checkpoint 协议来源
- [[lognet-rootcause-multiagent-architecture]] — 五源装配与 kb_lookup/kb_search 的落地场景
- [[Agent-Skills技能开发实战]] — 方法论类知识的 SKILL.md 载体规范
- [[AGENTS]] — 外部知识库化的活参考实现（本文 §5.2 的出处）
- [[cc-cache-hitrate-35pct-postmortem]] — 前缀稳定性排序的成本依据
