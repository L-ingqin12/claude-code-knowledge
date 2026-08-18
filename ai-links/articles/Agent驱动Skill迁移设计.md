---
title: "Agent 驱动 Skill 系统迁移设计"
aliases: [Skill迁移设计, Skill审计, Agent驱动迁移]
tags: [ai/skills, ai/learning]
created: 2026-06-22
updated: 2026-08-17
status: review
source: "系统设计"
date: "2026-06-22"
fetched_at: "2026-06-22"
---

# Agent 驱动 Skill 系统迁移设计

See also: [[AI-Links-KB-Home]] | [[Articles-Index]] | [[Skill规模化管理-从渐进式披露到检索式发现]] | [[日志检索分析系统-Skill管理Demo设计]] | [[Claude-Code记忆机制源码拆解]]

## 背景

当前技能体系是**扁平发现式**——所有 skill 元信息列在 system prompt，模型被动匹配。10-50 个 skill 时完全够用，但数量增长后面临三个瓶颈：

1. System prompt 被 skill 元信息淹没（1000 skill × 30 token = 30000 token）
2. Skill 之间隐含的依赖关系靠模型猜测，不可靠
3. 无审计痕迹——skill 的加载、选择、废弃全无记录

目标：设计一个 **Agent 自主完成迁移** 的方案，将旧系统（扁平 skill 列表）迁移到新系统（命名空间 + 依赖声明 + 条件匹配 + 检索式发现），全程可审计。

## 迁移 Agent 设计

### 核心原则

1. **Git 全程追踪**：每一步迁移一个 commit，可回滚、可审计
2. **决策透明**：Agent 的每一个分类/命名/依赖推断决定，都输出到 audit log
3. **人工闸门**：迁移分阶段，每阶段完成后生成 diff review report，人工确认后继续
4. **幂等可重入**：迁移脚本可以安全重跑，不会重复创建或覆盖已迁移的 skill

### 迁移五阶段

```
Phase 1: 发现（Discovery）
  Agent 扫描旧系统 → 输出 Inventory Report
  ├── 列出所有 skill 文件的位置、大小、frontmatter
  ├── 分析每个 skill 的内容语义（调 LLM 做摘要）
  ├── 检测 skill 之间的文本引用关系（反向索引 grep）
  ├── 提取 frontmatter 元信息（name/description/type）
  └── 输出：discovery-report.json + discovery-report.md

Phase 2: 分类（Classification）
  Agent 基于 Discovery 结果做分类决策
  ├── 推断 namespace：根据 skill 内容和名称推断所属领域
  │   - 关键词匹配（规则粗筛）
  │   - LLM 分类（小模型发 skill 摘要，选 namespace）
  │   - 置信度标记（HIGH/MEDIUM/LOW/ESCALATE）
  ├── 推断依赖关系：检测 skill A 的内容是否引用了 skill B 的能力
  │   - 文本引用（grep 交叉引用模式）
  │   - 语义推断（LLM 判断 A 的工作流是否隐含需要 B）
  ├── 生成 paths glob 候选（基于 skill 内容中的文件类型引用）
  ├── 标记冲突：两个 skill 覆盖同一功能但参数不同
  └── 输出：classification-report.json（含置信度）

Phase 3: 审核（Human Review）
  生成可读的 diff preview，人工确认
  ├── 高置信度决策 → 绿色，建议自动执行
  ├── 中置信度决策 → 黄色，建议人工确认
  ├── 低置信度决策 → 红色，必须人工决策
  ├── 极低置信度（<0.2）→ 升级，建议新建 namespace 或重审输入
  ├── 依赖感知：如果 skill B 被拒且 B 是 A 的 includes 依赖，A 自动标记为 blocked
  └── 用户对每项选择：approve / reject / modify

Phase 4: 执行（Migration）
  只执行已审批的迁移决策
  ├── 创建目标目录结构（按 namespace 分层）
  ├── 迁移每个 skill 文件到新位置
  ├── 补全 frontmatter（namespace, paths, includes, optional_includes）
  ├── 更新交叉引用（旧路径→新路径）
  ├── 生成 MEMORY.md 风格的 Skill Registry 索引
  ├── 每次 commit 粒度：单个 namespace（~5-10 skills）
  └── 输出：migration-log.jsonl（每条一行，含 timestamp + action + decision + trace_id）

Phase 5: 验证（Verification）
  Agent 验证迁移正确性
  ├── 依赖链完整性检查（所有 includes 目标存在且可解析）
  ├── 循环依赖检测（拓扑排序验证依赖图无环）
  ├── 条件匹配覆盖检查（paths glob 是否覆盖了 skill 描述的目标文件类型）
  ├── Token 预算对比（旧系统 vs 新系统的 system prompt 开销）
  └── 输出：verification-report.md
```

### Phase 5→2 反馈循环

验证发现问题时不直接 git revert 全量回滚：
- Phase 5 标记特定断裂的依赖 edge
- 只对该 edge 涉及的 skill 重跑 Phase 2 分类
- Phase 4 增量迁移只处理被修复的项

### 循环依赖预检

在 Phase 4 执行前增加独立步骤：对完整的 {已批准依赖图} 运行拓扑排序。有环则阻止迁移并报告具体环路径。

## 审计设计

### 审计 trace 粒度

单条决策一条 trace（不是按 phase 记录），每个 namespace 推断、每个依赖推断都独立记录。

### 审计数据结构

```json
{
  "trace_id": "mig-20260622-a3f8",
  "timestamp": "2026-06-22T12:00:00Z",
  "phase": "classification",
  "action": "namespace|dependency|conflict|dedup|paths|rename|content|reject",
  "target": "skill_name.md",
  "source_hash": "sha256:abc123...",
  "decision": {
    "field": "namespace|includes|paths|...",
    "inferred_value": "logs/queries",
    "confidence": 0.87,
    "reasoning": "Agent 的推理过程",
    "implicit_deps": ["old_ref_a", "old_ref_b"],
    "alternatives": ["logs/alerts"],
    "llm_used": "sonnet",
    "prompt_hash": "sha256:..."
  },
  "blocked_by": ["dependency_skill_name"],
  "approval": "pending|approved|rejected|modified",
  "rejection_reason": null,
  "human_override_value": null,
  "git_commit": null,
  "verification": null
}
```

### 审计文件结构

```
migration-session-{id}/
├── audit.jsonl                # 所有阶段决策（追加写入）
├── snapshots/
│   ├── phase-1-registry.json  # Discovery 完整快照
│   ├── phase-2-registry.json  # Classification 完整快照
│   ├── phase-3-decisions.json # 人工审批结果
│   └── phase-4-registry.json  # Migration 完成快照
├── reports/
│   ├── discovery-report.md
│   ├── classification-report.md
│   ├── review-report.md
│   └── verification-report.md
└── git-log.txt                # 每个 phase 的 commit SHA 列表
```

## 置信度阈值（按决策类型拆分）

| 决策类型 | HIGH（自动） | MEDIUM（人工确认） | LOW（必须人工） | ESCALATE（升级） |
|---------|-------------|------------------|---------------|----------------|
| namespace | > 0.9 | 0.7-0.9 | < 0.7 | < 0.2 |
| dependency | > 0.8 | 0.5-0.8 | < 0.5 | < 0.2 |
| paths | — | — | 全部人工审核 | — |
| conflict | > 0.85 | 0.6-0.85 | < 0.6 | — |

## 规模分档

| 技能数量 | 命名空间策略 | 依赖关系策略 |
|---------|-------------|-------------|
| < 50 | 直接 LLM 分类（一次 prompt） | 文本 grep + LLM 验证（O(n)） |
| 50-200 | 规则预筛 + 按 namespace 分组 LLM | 按 namespace 分组推断（O(n×k)，k=每个 namespace 的 skill 数） |
| 200-1000 | embedding 聚类 + LLM 精排 | 向量粗筛 → LLM 精排 |

Phase 1 的跨文件引用检测始终使用反向索引而非 O(n²) grep。

## 回滚机制

- 每次迁移一个 namespace 一个 commit（粒度 ~5-10 skills/commit）
- git revert 只影响单个 namespace，其他已迁移的 namespace 不受影响
- 审计文件同步记录回滚 trace

## 复用现有组件

- **SkillRegistry 数据类**：import `skill-registry.py` 的 `Skill` dataclass 和 `SkillRegistry` 类
- **Phase 5 验证**：直接调用 `reg.resolve_dependencies()` 和 `reg.filter_by_context()`
- **顶层技能识别**：复用 `skill-dependency-viz.py` 中的 top-level 判定逻辑
- **Frontmatter 解析**：复用 `analyze_skills.py` 的 `parse_frontmatter()` 函数
