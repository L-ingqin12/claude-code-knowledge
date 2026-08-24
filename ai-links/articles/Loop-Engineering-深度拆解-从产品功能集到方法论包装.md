---
title: "Loop Engineering 深度拆解 — 从产品功能集到方法论包装"
aliases: [Loop Engineering, Addy Osmani, Loop方法论]
tags: [ai/agent, ai/learning]
created: 2026-06-25
updated: 2026-08-25
status: stable
source: "微信公众号"
source_urls:
  - "https://mp.weixin.qq.com/s/QXW2WbxjSDyOClg-PX2Sng"
author: "靳岩岩"
date: "2026-06-25"
fetched_at: "2026-06-25"
---

# Loop Engineering 深度拆解

See also: [[AI-Links-KB-Home]] | [[Articles-Index]] | [[Claude-Code记忆机制源码拆解]] | [[上下文工程-注意力预算与四层解法]] | [[Agent韧性架构分析-微信转载]]

## 摘要

2026 年 6 月，"Loop Engineering" 一词由 Google Chrome 工程主管 Addy Osmani 推上方法论位置。此前 Peter Steinberger（OpenAI）和 Boris Cherny（Anthropic Claude Code 负责人）已分别在社交媒体上使用 "loop" 一词。但深入对比发现：三个发明者对 "loop" 的定义互不一致，且 Loop Engineering 本质是 **Claude Code 2.1.139 功能集的外包装**——核心本体是 `/loop` 和 `/goal` 两个 slash command（共 10 字符），外围四件（git worktree、SKILL.md、MCP、sub-agents）全是支撑设施。

Addy 的贡献不在于发明新技术，而在于为 AI 工程造了一套三层词汇表：**Context Engineering → Harness Engineering → Loop Engineering**，三者均对应早就存在的旧技术（prompt+RAG / sandbox+system prompt / cron+ReAct），但作为招聘 JD 和立项理由的词汇非常有效。

**核心洞见**：loop 不是工具，是放大器——它放大工程师已有的判断力和勤奋，也放大懒惰和认知投降。Karpathy 的 autoresearch（630 行 Python）是该理念的最小可用证明。

---

## Loop 的四种定义对比

| 提出者 | 定义 | 本质 | 类比对象 |
|--------|------|------|----------|
| **Peter Steinberger** (OpenAI) | "design loops that prompt your agents" | 抽象修辞，表达抽象层级上移 | 一种"工程师姿态" |
| **Boris Cherny** (Anthropic) | 几百个 Claude 实例并行运行，读 GitHub issues/扫 Twitter/翻 Slack | 生产环境多实例编排 | cron + Claude + API |
| **Addy Osmani** (Google Chrome) | "recursive goal where you define a purpose and the AI iterates until complete" | 单 agent 内部的目标驱动循环 | ReAct / AutoGPT |
| **Anthropic 官方** | "/loop: let the model self-pace" | 产品功能——定时触发或自定节奏触发 slash command | 一个 slash command |

---

## Claude Code 的 /loop 本体

- **上线版本**: Claude Code 2.1.139 (2026-05-12)
- **用法一**: `/loop 5m /foo` — 每 5 分钟触发一次 `/foo`
- **用法二**: `/loop`（不带 interval）— 模型自定节奏
- **官方措辞**: "let the model self-pace"

---

## Addy 的五件套拆解

| 组件 | 是不是 loop？ | 来源 | 时间 | 实际作用 |
|------|--------------|------|------|----------|
| `/loop` + `/goal` | **是** — loop 本体 | Claude Code 2.1.139 | 2026-05-12 | 定时触发 or 递归目标直到完成 |
| git worktree | 不是 — 隔离机制 | Git 2.5 | 2015 | 并行 agent 的文件系统隔离 |
| SKILL.md | 不是 — 知识包 | Anthropic | 2025-10 | 项目规则按需注入 agent 上下文 |
| MCP | 不是 — 外部接口 | Anthropic | 2024-11 | agent 连接外部系统（Jira/Slack/DB） |
| Sub-agents | 不是 — 分工 | Anthropic | 2025 年中 | 独立 verifier agent 做验收 |
| STATE.md | 不是 — 记忆 | 附赠 | — | 跨 session 状态持久化 |

> [!note] STATE.md 不在 Addy「五件套」之列，是附赠的第 6 件——仅作跨 session 状态持久化补充，与 loop 本体无关。

**结论**：五件套里只有第一件是 loop 本体，其余四件全是支持设施。五件套最小可用版 = git + python + 验证函数（Karpathy autoresearch，630 行）。

---

## Addy 的三层 AI 工程架构

| 层 | 管什么 | 旧名字 | 招聘 JD |
|----|--------|--------|---------|
| **Context Engineering** | 上下文窗口里放什么 | prompt + RAG | Context Engineer |
| **Harness Engineering** | 单个 agent 跑在什么环境里 | system prompt + sandbox | Harness Engineer |
| **Loop Engineering** | 谁来触发 agent，什么时候停 | cron + ReAct/AutoGPT | Loop Engineer |

**关键观察**：每层对应的"旧技术"早已存在。Addy 的贡献是给 AI 工程造了一套可写在岗位 JD 上的词汇表——三个抽屉，三种 JD，三种立项理由。

---

## Karpathy autoresearch — 最小可用证明

- 开源时间：2026-03-07
- 代码量：约 630 行 Python（3 个文件：prepare.py / train.py / program.md）
- 核心循环：读 program.md → 形成假设 → 改 train.py → 跑 5 分钟 → 看 validation → 改进就 commit/没改进就 revert
- 效果：一小时约 12 个实验，一晚约 100 个；16 块 GPU 集群一晚 910 个实验/$309
- 当前 stars：87,000+
- 对应五件套的方式：
  - `/loop` → `while True` + 五分钟计时
  - worktree → `git commit / git revert`
  - SKILL.md → `program.md`
  - verifier → validation 指标数值
  - STATE.md → git history

---

## 三个工程坑

1. **Verifier 信任问题**: 你信不过 verifier 就得自己看；自己看那 loop 跑了个寂寞。AutoGPT 2023 年典型翻车：search → save → verify → 重复 300 次零产出烧掉 $80。

2. **理解债**: loop 越快交付你没写过的代码，"代码实际上是什么"和"你以为是什么"之间的鸿沟就越大。

3. **认知投降**: loop 运行时人容易放弃自己的判断。"搭 loop 带着判断去做是解药，为了逃避思考去做是助推剂——同一个动作，相反的结果。"

---

## 参考资料

- Addy Osmani 原文: https://addyo.substack.com/p/loop-engineering
- 前作 Harness Engineering: https://addyosmani.com/blog/agent-harness-engineering/
- Peter Steinberger 推文: https://x.com/steipete/status/2063697162748260627
- Karpathy autoresearch: https://github.com/karpathy/autoresearch
- Claude Code 2.1.139: https://www.anthropic.com/product/claude-code
- O'Reilly Radar 联名版: https://www.oreilly.com/radar/loop-engineering/
- TechTalks "loopmaxxing": https://bdtechtalks.com/2026/06/22/ai-loop-engineering/
- 橙皮书（中文）: https://github.com/alchaincyf/loop-engineering-orange-book
- 鹤啸九天技术分析: https://wqw547243068.github.io/loop
