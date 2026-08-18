---
title: 生产运行诊断与修复 (2026-07-06)
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-07-06
updated: 2026-08-17
status: stable
---

# 生产运行诊断与修复 (2026-07-06)

See also: [[Claude-Ops-KB-Home]] · [[agent-gate-optimization-plan-2026-07-06]] · [[crash-improvement-plan-2026-07-03]]

> 来源: agent-gate 部署后首次生产运行分析
> 修复: 4 项代码变更 + 1 项文档化

---

## 诊断过程

### 采集基线

```
时间: 2026-07-06, 系统运行 ~3 天
Mem: 7.4GB total, 5.5GB used, 1.9GB available
Swap: 8.0GB total, 4.4GB used (55%)
Load: 0.12 (idle)
Claude 进程: 5 个 (含 proxy + permafrost)
```

### 发现路径

`ps aux` → 观察到主 session (PID 10441) STAT=RNl+, nice=19
  → 追溯: prioritize() 在 mark-interactive 时 renice 所有 claude 进程
  → 检查: `$PPID` 在 hook 上下文中 = sh -c 的 PID, 不是 claude PID
  → 根因: 进程树 claude→sh→bash, PPID 穿透失败

`free -h` + `/proc/meminfo`:
  → swap 55% 但 memcheck 返回 GREEN
  → 检查: do_memcheck() 读取 swap% 但未用于决策
  → 根因: swap 仅输出不判断

`ps aux | grep ' D'`:
  → PID 15472 STAT=DNl+ (290MB RSS stuck in disk sleep)
  → 无任何检测/告警机制

统计 hook 触发频率:
  → 单次用户消息触发 5-10 次 mark-interactive
  → 每次写文件 + pgrep + renice
  → 冗余 I/O

---

## 修复清单

| # | 问题 | 机制 | 代码 |
|---|------|------|------|
| 1 | 主 session 降权 | `find_main_claude_pid()` 走进程树 | prioritize + cleanup |
| 2 | 冗余 I/O | `MARK_THROTTLE_SEC=3` 节流 | do_mark_interactive |
| 3 | swap 无视 | `SWAP_RED=70` `SWAP_YELLOW=55` | do_memcheck + do_status |
| 4 | D 状态盲区 | `count_d_state_claude()` | do_status + do_cleanup |
| 5 | 覆盖窄 | 文档化 | resource-patterns.conf |

### 部署后效果

```
修复前: MemLevel=GREEN (无视 swap 55%)
修复后: MemLevel=YELLOW (正确感知 swap 66%)

修复前: mark-interactive 每 tool 写文件
修复后: 第2次起 throttled (节省 N-1 次 I/O)

修复前: 主 session nice=19 (最低优先级)
修复后: 主 session nice=0 (正常优先级)
```

---

## 排查方法论

1. **采集基线** — ps/free//proc/meminfo 快照
2. **逐进程审视** — STAT 标志位 (N=低优先, D=I/O阻塞, t=跟踪停止)
3. **追溯代码路径** — 从生产现象逆向定位到代码行
4. **最小修复** — 只改一个文件，不改 hook 配置
5. **回归验证** — 27 项测试套件 + 专项验证

## 升级检查点

后续升级/部署时优先检查:
- [ ] ps 确认主 session nice=0 (非 19)
- [ ] memcheck 输出含 swap% 且正确分级
- [ ] mark-interactive 第二次调用出现 "throttled"
- [ ] status 输出 D-procs 字段 (有或无)
