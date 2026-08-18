---
title: Phase 2d: 资源类别感知调度方案
aliases: []
tags: [ai/ops]
created: 2026-07-03
updated: 2026-08-17
status: deprecated
---

# Phase 2d: 资源类别感知调度方案

> [!warning] 此文档已废弃，请参考 [[subagent-resource-architecture-2026-07-03]]

See also: [[Claude-Ops-KB-Home]] · [[subagent-resource-architecture-2026-07-03]] · [[interactive-aware-subagent-plan-2026-07-03]]

> 日期: 2026-07-03 | 状态: 设计完成，待实施
> 依赖: Phase 2 (agent-gate.sh) 必须存在
> 定位: Phase 2d — 独立于 2b 的正交扩展

---

## 问题定性

subagent 数量只是代理指标。真正原因是**高资源消耗操作的并发冲突**：

- 2 个 subagent 同时 `npm install` → CPU+IO 尖峰 → 终端崩溃
- 1 个 subagent `grep -r /` + 另一个大文件分析 → IO 竞争 → OOM
- 5 个 subagent 只读文件/写编辑 → 完全正常

**本质是资源调度问题，不是数量问题。**

---

## 关键发现：Hook 限制

Claude Code PreToolUse hook 的 `matcher` 只匹配**工具名**（如 "Bash"），无法读取命令参数。因此**不能在 hook 内做命令模式匹配**。

解决方案分两层：
- **Layer 1 (Agent hook)**：spawn 前检查资源锁状态，冲突则 DENY
- **Layer 2 (Wrapper脚本)**：透明包装 Bash，spin-wait 获取锁后执行原命令

---

## 资源类别

| 类别 | 示例 | 并发限制 |
|------|------|---------|
| `cpu` | npm install, cmake, gcc, pip install | 互斥 (1) |
| `io` | grep -r /, find /, rsync, tar | 互斥 (1) |
| `net` | curl -O, wget, git clone | 最大 2 |
| `mem` | python train, ffmpeg, convert | 互斥 (1) |
| `light` | echo, ls, cat, 简单读写 | 不限 |

---

## 文件锁机制

```
/tmp/claude-resource-locks/
  cpu.lock  → "PID EPOCH"  (互斥锁)
  io.lock   → "PID EPOCH"  (互斥锁)
  net.count → 数字 0-2     (计数器)
  mem.flag  → "PID EPOCH"  (互斥锁)
```

- **获取**: `agent-gate.sh acquire <class> [--wait N]` — 自旋等待 N 秒
- **释放**: `agent-gate.sh release <class|all>`
- **过期**: 600s TTL + PID 存活检测 → 自动偷锁
- **重入**: 同 PID 同 class → 立即返回 (幂等)

---

## 命令模式检测

`/root/.claude/resource-patterns.conf`:
```
cpu:(npm|yarn) (install|build)
cpu: pip(3)? install
cpu: cmake|make\b|(gcc|g\+\+)
io: grep\s+-r\s+/|find\s+/
io: rsync|dd\b|tar\s+-[cx]
net: curl\s+.*-[oO]\s|wget\b
net: git\s+(clone|pull)
mem: python3? .*(train|model)
mem: ffmpeg\b|convert\b
```

---

## 新增子命令 (~150 行)

```
agent-gate.sh acquire <class> [--wait N]  — 获取资源锁
agent-gate.sh release <class|all>         — 释放资源锁
agent-gate.sh lock-status [--json]        — 查看锁状态
agent-gate.sh detect <command>            — 检测命令类别
```

**do_check() 修改**: 新增第 6 步 — 资源锁冲突检查
- cpu/io/mem 锁被其他 PID 持有 → DENY
- net.count == 2 → WARN

---

## Wrapper 脚本

`/root/claude-gate-bash.sh` (~35 行):
```bash
#!/bin/bash
# 透明包装: 检测命令类别 → 获取锁 → 执行 → 释放锁
CLASS=$(agent-gate.sh detect "$*")
[ -n "$CLASS" ] && agent-gate.sh acquire "$CLASS" --wait 30
eval "$*"
RC=$?
[ -n "$CLASS" ] && agent-gate.sh release "$CLASS"
exit $RC
```

---

## Hook 配置

新增的 hook (合并到 settings.local.json):

```json
"PreToolUse": [
  {"matcher": "", "hooks": [{"command": "agent-gate.sh mark-interactive"}]},
  {"matcher": "Agent", "hooks": [{"command": "agent-gate.sh check"}]},
  {"matcher": "Bash", "hooks": [{"command": "agent-gate.sh acquire auto --try-only"}]}
],
"PostToolUse": [
  {"matcher": "Bash", "hooks": [{"command": "agent-gate.sh release acquired"}]}
]
```

---

## 三层防护总结

| 层 | 机制 | 保护什么 | 触发时机 |
|----|------|---------|---------|
| L1 | 进程数+内存门禁 | 不崩 (OOM) | Agent spawn 前 |
| L2 | 交互感知 renice | 不卡 (交互) | 每次工具调用 |
| L3 | 资源类锁调度 | 不撞 (重载) | 重量级 Bash 命令 |
