---
title: Subagent 资源管理实施经验 (2026-07-03)
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-07-03
updated: 2026-08-17
status: stable
---

# Subagent 资源管理实施经验 (2026-07-03)

See also: [[Claude-Ops-KB-Home]] · [[subagent-resource-architecture-2026-07-03]] · [[resource-class-scheduling-plan-2026-07-03]]

> 从崩溃分析到三层防护体系落地的关键教训

---

## 1. 问题定性演变

| 阶段 | 认知 | 纠正 |
|------|------|------|
| 初判 | subagent 数量太多导致崩溃 | 数量是代理指标，真正原因是资源冲突 |
| 再判 | 应该限制并发数 | 静态限制太粗糙，需要感知交互状态 |
| 最终 | 交互感知 + 资源类调度的三层体系 | 数量门禁(L1) + 交互优先(L2) + 同类互斥(L3) |

核心教训：**不要用 proxy metric（数量）替代 root cause（资源冲突）**。

## 2. Hook 系统能力边界

| 能做到 | 不能做到 |
|--------|---------|
| 匹配工具名（Agent, Bash） | 读取工具参数（Bash 的命令行） |
| PreToolUse 同步执行 | 阻塞/取消工具执行 |
| PostToolUse 清理释放 | 获取 Claude 的"思考"状态 |
| Stop 检测空闲 | 检测用户正在输入 |

核心教训：**Hook 是 advisory 的，不是 enforcement 的。硬约束靠文件锁 + 自旋等待。**

## 3. 快速路径设计

非 fan-out 模式（单 claude 进程）下，所有锁逻辑跳过。实现方式：

```bash
# agent-gate.sh acquire 第一行
total_procs=$(count_claude_procs)
[ "$total_procs" -le 1 ] && { echo "skipped (single)"; return 0; }
```

效果：非 subagent 场景零开销（~0.1s → ~0.01s）。

核心教训：**优化常见路径。单 session 是常态，subagent 是少数。**

## 4. Bug 发现

| Bug | 原因 | 修复 |
|-----|------|------|
| lock_is_held 返回值语义反转 | `lock_is_held` 返回 0=free 但命名暗示 0=held | 统一为 bash 惯例: 0=held (true), 1=free (false) |
| interactive DENY 死循环 | PreToolUse→interactive→Agent check→DENY，用户请求的 spawn 也被拒 | 改为降并发上限，不拒绝 |
| check cooldown 过短 | 连续两次 check 间隔 <5s 被拒绝 | 这是设计意图，但需文档说明 |

## 5. 测试策略

回归测试套件 `tests/agent-gate-test.sh` 覆盖：
- Phase 2: cleanup, count, memcheck, status, check
- Phase 2b: mark-interactive/idle, read-state, prioritize, interactive 降并发
- Phase 2d: detect, acquire, release, lock-status
- 快速路径: 单进程零开销
- 语法和健壮性

**升级前必须跑这个套件。**

## 6. 部署原则

1. 先在仓库编写测试 → 通过 → 用户确认 → 部署
2. 生产路径 `/root/claude-agent-gate.sh` 从仓库 `cp`
3. `settings.local.json` 手动合并 hook 配置
4. 部署后跑回归测试确认
