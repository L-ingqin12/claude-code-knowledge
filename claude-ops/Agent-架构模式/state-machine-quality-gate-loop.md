---
title: 状态机式质量门控回环
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-07-01
updated: 2026-08-25
status: stable
---

# 状态机式质量门控回环

> [!abstract] 状态机式质量门控反馈回环 — 多智能体系统可靠性控制的核心模式

See also: [[Claude-Ops-KB-Home]] · [[fan-out-subagent-pattern]] · [[opencode-multi-agent-architecture]]

## 仓库
https://github.com/L-ingqin12/opencode-multi-agent-system

## 核心设计

7 个状态: START → ANALYZE → DELEGATE → VERIFY → INTEGRATE → DONE + ESCALATE（超限上报终态）
2 个分支: RETRY (携带反馈回环) + ESCALATE (超限上报)

> [!note] 勘误 (2026-08-25): 原文标注 7 个状态但列表仅列 6 个；按本文档的 ESCALATE 分支补入超限上报终态。上游仓库 (L-ingqin12/opencode-multi-agent-system) 当前不可达，第 7 状态名待原作者确认。

## 关键规则
- 每个子任务独立状态机，一个 RETRY 不阻塞其他
- 质量门: syntax/completeness/consistency/no_hallucination/specificity/actionable
- 重试上限 3 次，同一失败连续 2 次 → ESCALATE
- 总轮次上限 10，防止无限循环
- 与 Fan-Out 组合: 并行分发 + 每个任务独立回环

## 实现路径
A) 纯 System Prompt (当前可用，依赖 LLM 自律)
B) Hook 插件 (推荐，opencode hook 强制执行)
C) Workflow Engine (等待原生 Ephemeral Team API)

## 相关记忆
- [[opencode-multi-agent-architecture]]
- [[fan-out-subagent-pattern]]
