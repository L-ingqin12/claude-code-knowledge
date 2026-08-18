---
title: 交互感知动态资源分配方案
aliases: []
tags: [ai/ops]
created: 2026-07-03
updated: 2026-08-17
status: deprecated
---

# 交互感知动态资源分配方案

> [!warning] 此文档已废弃，请参考 [[subagent-resource-architecture-2026-07-03]]

See also: [[Claude-Ops-KB-Home]] · [[subagent-resource-architecture-2026-07-03]] · [[resource-class-scheduling-plan-2026-07-03]]

> 日期: 2026-07-03 | 状态: 设计完成，待实施
> 依赖: Phase 2 (agent-gate.sh) 必须先存在
> 定位: Phase 2b — Phase 2 的扩展

---

## 核心问题

当前 subagent 资源管理是**静态**的 — 不区分主 session 是否在交互。用户输入时，subagent 抢占 CPU/内存/IO → 终端卡顿。

## 核心思路

利用 Claude Code Hook 事件检测交互状态，**动态切换资源分配策略**。

```
Timeline of a turn:
  User msg → [thinking] → PreToolUse → tool → PostToolUse → [thinking] → Stop → 等待输入
  ┌─ interactive ──────────────────────────────────────────────────┐  ┌─ idle ─┐
  子代理: max_concurrent=0 (拒绝spawn), nice+19 (已有子代理降权)      子代理全速
```

---

## Hook 状态机

| Hook | 写入状态 | 理由 |
|------|---------|------|
| `SessionStart` | `idle` | 会话初始等待用户 |
| `PreToolUse` | `interactive` | Claude 正在执行工具 → 用户等待中 |
| `Stop` | `idle` | Claude 完成响应 → 等待用户输入 |
| `PostToolUse` | (不写) | 工具执行完后 Claude 继续思考，保持 interactive |

**为什么 PreToolUse 覆盖所有工具**：不管什么工具被调用，都说明用户正在等待结果。

---

## 状态文件

**路径**: `/root/.claude/session-state.json`

```json
{"state":"interactive","ts":"2026-07-03T14:30:00Z","hook":"PreToolUse"}
```

- 单行 JSON，~80 字节
- `grep -oP` 解析，零外部依赖
- 原子写入（`echo > file`）
- 超时：120s 无更新 → `stale` → 视为 `interactive`

---

## 资源分档表

| 状态 | max_concurrent | 内存门槛 | nice | ionice |
|------|:---:|------|------|------|
| **interactive** (任意内存) | 0 (拒绝 spawn) | N/A | +19 (最低) | 3 (idle) |
| **idle** + 内存 ≥1200MB | 2 | 1200MB | 0 | 0 |
| **idle** + 内存 800-1200MB | 1 | 800MB | +5 | 0 |
| **idle** + 内存 <800MB | 0 | <800MB | N/A | N/A |
| **stale/missing** (>120s) | 0 (视为 interactive) | N/A | N/A | N/A |

---

## agent-gate.sh 新增子命令 (~60 行)

```
mark-interactive   → 写 state=interactive + 调 prioritize (renice +19)
mark-idle          → 写 state=idle + 调 prioritize (renice 0)
read-state         → 打印状态 + 过期评估，exit 0=idle, exit 1=interactive/stale
prioritize         → 找到 subagent PID，根据状态 renice/ionice
check (修改)       → 插入 read-state 提前退出: interactive → 直接 DENY
```

**check 流程对比**：

```
修改前: cleanup → count → memcheck → OK/DENY
修改后: cleanup → read-state → interactive? → DENY (提前退出)
                              → idle? → count → memcheck → OK/DENY
```

---

## Hook 配置

```json
{
  "hooks": {
    "SessionStart": [
      {"type": "command", "command": "bash /root/claude-agent-gate.sh mark-idle 2>/dev/null || true"}
    ],
    "PreToolUse": [
      {"type": "command", "command": "bash /root/claude-agent-gate.sh mark-interactive 2>/dev/null || true"}
    ],
    "Stop": [
      {"type": "command", "command": "bash /root/claude-agent-gate.sh mark-idle 2>/dev/null || true"}
    ]
  }
}
```

延迟预算：PreToolUse hook 耗时 ~10ms (< 50ms 上限)

---

## 边缘情况

| 情况 | 行为 | 理由 |
|------|------|------|
| 状态文件缺失 | 视为 interactive | 保守默认 |
| 状态过期 (>120s) | 视为 interactive | Hook 停止 → 可能崩溃 |
| JSON 损坏 | 视为 interactive，覆写 | 自愈 |
| 多终端 | 最后一个 PreToolUse 胜出 | 任何终端活跃都应保守 |
| 已有 subagent 运行中用户发消息 | PreToolUse → renice +19 | 立即生效，无延迟 |
| ionice 不可用 (Android) | `|| true` 跳过 | 尽力而为，不影响正确性 |
| 长工具执行 (30s+) | PostToolUse 不改变状态 | 用户仍在等待 |
| Claude 卡死 (无 crash) | 120s 后 stale → interactive | 不在卡死系统上 spawn |

---

## 与 Phase 3 的交互

| 状态 | 推荐路由 |
|------|---------|
| interactive | 所有工作走 **Kanban**（零 CPU 竞争） |
| idle | delegate_task 短任务 + Kanban 长任务 |

---

## 实施序列

```
Phase 2 (已有): agent-gate.sh (cleanup/count/memcheck/check)
                ↓
Phase 2b (本方案): + mark-interactive, mark-idle, read-state, prioritize
                   + PreToolUse + Stop hooks
                ↓
Phase 3 (未来): Kanban 路由, 内存状态文件, task-routing-guide
```

---

## 验证标准

| 检查项 | 方法 | 预期 |
|--------|------|------|
| interactive 拒绝 spawn | `mark-interactive && check` | DENY |
| idle 允许 spawn | `mark-idle && check` | 走 count+memcheck |
| 状态过期回退 | 写入 timestamp >120s 前，check | DENY (视作 interactive) |
| prioritize 降权 | interactive 时查看 subagent nice 值 | +19 |
| Hook 故障安全 | hook 命令返回非零 | `|| true` 不阻塞 session |
| 延迟基准 | `time agent-gate.sh mark-interactive` | < 50ms |
