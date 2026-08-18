---
title: Fan-Out 子智能体分发模式
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-07-01
updated: 2026-08-17
status: stable
---

# Fan-Out 子智能体分发模式

> [!abstract] Fan-Out 扇出模式 — 主智能体并行分发任务到多个子智能体的设计模式与实现方案

See also: [[Claude-Ops-KB-Home]] · [[state-machine-quality-gate-loop]] · [[opencode-multi-agent-architecture]]

## 定义
主智能体将复杂任务分解为 N 个子任务，一次性并行分发给多个子智能体，汇总结果。

## 适用条件
可以 Fan-Out: 操作不同文件、同一文件不同维度、都是只读
不能 Fan-Out: 同一文件且有写权限冲突、B依赖A的输出

## OpenCode 生态方案
| 方案 | 机制 | 并行上限 |
|------|------|:--------:|
| opencode-agent-intercom | spawn() 非阻塞 | 可配置 |
| Ouroboros Bridge | MCP 钩子 | 10 |
| swarm-control | 文件分解 | 4 |
| Ephemeral Team | 原生 team() (提案中) | 可配置 |

## 防冲突
- 有写权限的永不并行同一文件
- 只读可以任意并行
- 汇总阶段交叉验证（同一问题被多个子智能体发现→提升优先级）

## Claude Code 对比
Claude Code 有原生 Agent 工具支持 `run_in_background: true` 实现 Fan-Out，而 OpenCode 依赖插件生态。
