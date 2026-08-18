---
title: Agent-Gate 生产优化计划
aliases: []
tags: [ai/ops]
created: 2026-07-06
updated: 2026-08-17
status: deprecated
---

# Agent-Gate 生产优化计划

> [!warning] 此文档已废弃，请参考 [[production-diagnosis-2026-07-06]]

See also: [[Claude-Ops-KB-Home]] · [[production-diagnosis-2026-07-06]] · [[AGENTS]]

> 日期: 2026-07-06 | 状态: 待实施 | 发现自: 部署后生产运行分析

---

## 5 个生产发现

| # | 问题 | 严重 | 修复 |
|---|------|:--:|------|
| 1 | 主 session 被 renice+19 | 🔴 | `find_main_claude_pid()` 走进程树找真正 claude 祖先 |
| 2 | mark-interactive 每次工具调用都写文件+renice | 🟡 | 3s 节流窗口，已 interactive 则跳过 |
| 3 | 无 swap 压力门控 | 🟡 | memcheck 加 swap>70% RED / >55% YELLOW |
| 4 | D 状态进程未检测 | 🟡 | `count_d_state_claude()` → status + cleanup 暴露 |
| 5 | 仅 Bash 触发 acquire | 🟢 | 文档化，不加新 hook |

## 实施顺序

1→3→2→4→5 (关键优先，诊断后置，文档最后)

## 全部只改一个文件

`claude-agent-gate.sh` — 无需改 hook 配置、settings.local.json、或 wrapper 脚本
