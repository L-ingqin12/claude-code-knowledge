---
title: Agent-Skills技能开发实战
aliases: [Agent Skills 开发, SKILL.md 规范]
tags: [ai, ai/agent, ai/skills]
created: 2026-08-25
updated: 2026-08-25
status: review
---

# Agent-Skills 技能开发实战

> 本文档对应《2026 AI 大模型应用开发工程师【系统课】》第 13 章（课程标注"即将更新"，本篇基于公开规范与社区实践补齐）：回答三个问题——Agent Skill 是什么、SKILL.md 怎么写、如何从单机技能走向跨框架规模化？内容包括：渐进式披露三层加载模型、frontmatter 字段全解、最小可运行 Skill Demo、与 MCP/SubAgent 的分工边界、规模化治理要点。

## 核心概念

| 概念 | 一句话解释 | 关键点 |
|---|---|---|
| Skill | 一个装着"操作手册+脚本+素材"的文件夹，教会 Agent 完成一类任务 | 入口是 `SKILL.md`，本质是**给 Agent 的说明书**而非插件代码 |
| 渐进式披露 | Agent 分三层按需读取技能内容 | 启动时只看 name/description（几十 token）→ 触发才读全文 → 需要才加载附属文件 |
| `SKILL.md` | YAML frontmatter + Markdown 正文 | frontmatter 是机器接口，正文是人/模型可读手册 |
| `scripts/` | 技能自带的可执行脚本 | Agent 用 Bash 执行；比"每次现场写代码"省 token 且稳定 |
| `references/` | 详细文档（API 手册、协议说明） | 正文超载时拆到这里，按需引用 |
| `assets/` | 模板、字体、样板文件 | 供脚本复制修改，避免重复生成 |

## 原理剖析

### 为什么是"说明书"而不是"插件"

传统插件要实现宿主定义的接口（注册函数、监听事件），Skill 则反过来：**把领域知识写成文档交给通用 Agent**。Agent 读完后自然知道该调什么工具、走什么流程。这带来两个后果：

1. **零集成成本**——只要宿主能读文件+执行命令，就能加载任何 Skill；
2. **质量上限=写作质量**——描述含糊的技能永远不会被触发，所以 `description` 是整个技能最重要的字段。

### 渐进式披露的三层加载

```text
层1 预扫描（常驻上下文）
└── 只加载所有已安装技能的 name + description（每个 ~30-60 token）
    Agent 判断当前任务是否命中某个 description
        │ 命中
        ▼
层2 按需展开（触发时）
└── 读取命中技能的 SKILL.md 全文（数百~数千 token）
    正文里的指令进入工作记忆
        │ 正文引用了附属文件
        ▼
层3 自由取用（执行中）
└── 按 Bash Read 读取 references/*.md、执行 scripts/*.py、复制 assets/*
```

这个设计把"N 个技能"的固定开销压到 N×几十 token，**上下文预算与技能数量近似解耦**——这是它能规模化的根本原因。

### frontmatter 字段速查

```yaml
---
name: pdf-report-generator          # 小写连字符；目录名需一致
description: 生成带图表的 PDF 周报。当用户要求"输出周报/PDF 报告"或上传数据文件要求成文时使用。  # 触发条件写在这里！第三人称、含关键词
allowed-tools: Read, Write, Bash     # 可选：收紧该技能可用工具面
---
```

> [!warning] 最常见的失败原因
> `description` 写成名词短语（如"PDF 工具"）而非**使用时机描述**。Agent 靠语义匹配决定是否加载——写清楚"什么时候用"，比写"它是什么"重要十倍。

## 最小 Demo：手写一个可用技能

目标：让 Agent 学会"把 CSV 统计摘要转成 Markdown 表格"。

```text
csv-summary/
├── SKILL.md
└── scripts/
    └── summarize.py
```

`SKILL.md`：

```markdown
---
name: csv-summary
description: 将 CSV 数据文件转为统计摘要表。当用户给出 .csv 文件并要求汇总、
  概览、"看看数据"时使用。
allowed-tools: Read, Write, Bash
---

# CSV 摘要生成

## 步骤
1. 运行脚本得到结构化统计：
   !`python scripts/summarize.py {csv_path}`
2. 将输出改写为 Markdown 表格：列名/行数/数值列的 min-max-mean
3. 若存在日期列，额外给出最早与最晚日期

## 注意
- 文件 >100MB 时先抽样 10 万行再统计，并向用户声明
- 不要猜测列含义，歧义时用 AskUserQuestion 确认
```

`scripts/summarize.py`：

```python
#!/usr/bin/env python3
"""CSV 结构化摘要输出器 —— 供 Agent 在技能流程中调用"""
import sys
import pandas as pd


def summarize(path: str) -> str:
    df = pd.read_csv(path)
    lines = [f"rows={len(df)}", f"cols={len(df.columns)}"]
    for col in df.select_dtypes("number").columns:
        s = df[col]
        lines.append(f"{col}|min={s.min():g}|max={s.max():g}|mean={s.mean():.3g}")
    for col in df.select_dtypes(include="object").columns:
        uniq = df[col].nunique()
        if uniq <= 20:
            top = df[col].value_counts().index[0]
            lines.append(f"{col}|unique={uniq}|top={top}")
    return "\n".join(lines)


if __name__ == "__main__":
    print(summarize(sys.argv[1]))
```

安装即用：放入 `~/.claude/skills/csv-summary/`（项目级放 `.claude/skills/`），重启会话后在 Graph/技能列表可见。

### 与 MCP 的分工边界

| 维度 | Skill | MCP Server |
|---|---|---|
| 本质 | 知识/流程文档 + 辅助脚本 | 标准化工具服务进程 |
| 跨宿主 | 弱（依赖宿主读取约定） | 强（JSON-RPC 协议互通） |
| 适合 | 组织内部 SOP、文档型方法论 | 需要**运行时能力**的对接（数据库、浏览器、支付） |
| 组合 | Skill 教 Agent"何时以及如何调用某 MCP 工具" | 提供"能被调用的工具本身" |

一句话：**MCP 给能力，Skill 给打法**。深度对比见 [[DSH跨框架Skills与MCP加载]]。

## 进阶实践与常见坑

| 坑 | 症状 | 解法 |
|---|---|---|
| description 不含触发词 | 技能永不生效 | 把用户可能的**原话关键词**写进 description |
| 正文塞满 API 细节 | 层2 加载后挤爆上下文 | API 细节移入 `references/`，正文只留流程骨架 |
| 脚本无执行位/硬编码路径 | Bash 步骤失败 | 脚本用相对路径 + `sys.argv`，仓库内保留可执行位 |
| 单文件巨型技能 | 维护困难 | 按"一个技能一个任务"拆分（同 [[AGENTS]] 一文档一问题） |

规模化治理（命名空间、检索式发现替代枚举式披露、团队共享）超出本文范围，见 [[Skill规模化管理-从渐进式披露到检索式发现]] 与 [[Anthropic-Skill系统深度分析]]；落地样例见 [[日志检索分析系统-Skill管理Demo设计]] 与 [[Claude-Code实用Skills参考]]。

## 相关文档

- [[AI-Dev-KB-Home]] — 本子库 MOC
- [[AI大模型开发]] — 理论主文件与课程知识地图
- [[LLM-Agent开发基础]] — Agent 循环与工具调用基础
- [[MCP协议开发实战]] — 能力侧的标准服务化方案
- [[Function-Calling工具调用实战]] — 底层 tool_calls 机制

## 参考资料

- [Anthropic: Equipping agents for the real world with Agent Skills](https://www.anthropic.com/engineering/equipping-agents-for-the-real-world-with-agent-skills) — 渐进式披露官方工程阐述
- [Anthropic Docs: Agent Skills 参考](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview) — SKILL.md 字段权威定义
- [anthropics/skills 官方示例仓库](https://github.com/anthropics/skills) — document/pdf/xlsx 等生产级技能源码
- [Agent Skills 开源规范讨论 (skills spec)](https://github.com/anthropics/claude-code/issues) — 跨宿主兼容性演进追踪
