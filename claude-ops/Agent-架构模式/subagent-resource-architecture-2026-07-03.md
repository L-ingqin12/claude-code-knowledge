---
title: Subagent 资源管理体系 — 架构文档
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-07-03
updated: 2026-08-17
status: stable
---

# Subagent 资源管理体系 — 架构文档

See also: [[Claude-Ops-KB-Home]] · [[subagent-lessons-learned-2026-07-03]] · [[interactive-aware-subagent-plan-2026-07-03]]

> 版本: 1.0 | 日期: 2026-07-03 | 状态: Phase 2+2b+2d 完成，待部署
> 用途: 后续升级的架构参考基线

---

## 一、系统概览

### 目标

在 Android Termux + PRoot (7.4GB RAM) 环境下，保障多 subagent 并发时**不崩、不卡、不撞**。

### 三层防护

```
┌─────────────────────────────────────────────────┐
│ L1: 不死 ─ 门禁                                  │
│   进程数上限 + 内存门槛 → 硬拒绝 OOM              │
│   触发点: Agent PreToolUse hook                  │
│   机制: do_check() → count + memcheck             │
├─────────────────────────────────────────────────┤
│ L2: 不卡 ─ 交互感知                              │
│   interactive: subagent nice+19, 降并发           │
│   idle: 恢复 nice 0, 全并发                       │
│   触发点: PreToolUse(全工具) + Stop hooks         │
│   机制: mark-interactive/idle + prioritize        │
├─────────────────────────────────────────────────┤
│ L3: 不撞 ─ 资源调度                              │
│   cpu/io/mem 互斥, net 限2, light 不限            │
│   触发点: Bash PreToolUse hook + Wrapper脚本       │
│   机制: 文件锁 acquire/release + TTL自释放         │
├─────────────────────────────────────────────────┤
│ 快速路径: 非fan-out零开销                         │
│   total_procs ≤ 1 → 跳过所有锁逻辑                │
└─────────────────────────────────────────────────┘
```

---

## 二、组件拓扑

```
settings.local.json (Hook 配置)
    │
    ├─ SessionStart → agent-gate.sh cleanup + mark-idle
    ├─ PreToolUse (全工具) → agent-gate.sh mark-interactive
    ├─ PreToolUse (Agent) → agent-gate.sh check  ← 门禁入口
    ├─ PreToolUse (Bash) → agent-gate.sh acquire auto --try-only
    ├─ PostToolUse (Bash) → agent-gate.sh release acquired
    └─ Stop → agent-gate.sh mark-idle
         │
         ▼
    /root/claude-agent-gate.sh (550+ lines)
         │
         ├─ Phase 2: cleanup, count, memcheck, check
         ├─ Phase 2b: mark-interactive, mark-idle, read-state, prioritize
         └─ Phase 2d: acquire, release, lock-status, detect
              │
              ├─ /root/.claude/session-state.json (交互状态)
              ├─ /tmp/claude-resource-locks/{cpu,io}.lock (资源锁)
              ├─ /tmp/claude-resource-locks/net.count (网络计数)
              └─ /root/.claude/resource-patterns.conf (命令模式)
```

### 文件职责

| 文件 | 部署路径 | 行数 | 职责 |
|------|---------|------|------|
| `claude-agent-gate.sh` | `/root/claude-agent-gate.sh` | 550+ | 核心门控引擎 |
| `claude-gate-bash.sh` | `/root/claude-gate-bash.sh` | 27 | 可选 Bash 透明包装 |
| `resource-patterns.conf` | `/root/.claude/resource-patterns.conf` | 25 | 命令→资源类映射 |
| `session-state.json` | `/root/.claude/session-state.json` | 1行 | 交互状态 (运行时) |
| `hooks-reference.json` | 仓库参考 | 70 | Hook 配置参考 |
| `resource-protocol.md` | 仓库参考 | 75 | Claude 资源使用指南 |
| `agent-gate-test.sh` | 仓库 | 130 | 回归测试套件 |

---

## 三、数据流

### 3.1 Agent 门控流 (spawn 决策)

```
Claude 准备 spawn subagent
    │
    ▼
PreToolUse (Agent) hook
    │
    ▼
agent-gate.sh check
    │
    ├─ 1. cleanup orphans           (清理僵尸)
    ├─ 2. cooldown check             (5s 冷却防竞态)
    ├─ 3. read-state                 (interactive/idle)
    │      ├─ interactive → max_procs=3 (仅1子代理)
    │      └─ idle → max_procs=4
    ├─ 4. count check                (进程数 ≤ max_procs)
    ├─ 5. memcheck                   (≥800MB 硬门槛)
    ├─ 6. lock conflict              (cpu/io/mem 被持有? net≥2?)
    │      └─ 仅当 total_procs > 1
    └─ 7. OK → set_cooldown → spawn允许
```

### 3.2 交互状态流

```
User sends msg
    │
    ▼
PreToolUse hook (任何工具)
    │
    ▼
agent-gate.sh mark-interactive
    ├─ write_state("interactive", epoch)
    └─ prioritize: renice subagent +19, ionice idle
    │
    ... Claude 处理中 ...
    │
    ▼
Stop hook
    │
    ▼
agent-gate.sh mark-idle
    ├─ write_state("idle", epoch)
    └─ prioritize: renice subagent 0, ionice best-effort
```

状态文件格式:
```json
{"state":"interactive","epoch":1783053600,"hook":"PreToolUse"}
```
TTL: 120s 无更新 → stale → 视为 interactive (保守)

### 3.3 资源锁流

```
Bash 工具执行
    │
    ▼
PreToolUse (Bash) hook
    │
    ▼
agent-gate.sh acquire auto --try-only
    │
    ├─ total_procs ≤ 1? → skip (快速路径)
    ├─ detect(command) → cpu/io/net/mem/light
    ├─ light → skip
    └─ heavy → lock_is_held?
         ├─ free → lock_write(PID, epoch) → 执行命令
         └─ held → 自旋等待 (max 30s) → 超时仍执行
    │
    ▼
命令执行
    │
    ▼
PostToolUse (Bash) hook → agent-gate.sh release acquired
```

锁文件格式:
```
PID EPOCH
```
TTL: 600s 无更新 → 自动清理; PID 死亡 → 自动偷锁

---

## 四、关键配置常量

```bash
# Phase 2 — 进程/内存门禁
MAX_TOTAL_PROCS=4           # idle 最大 claude 进程数
MAX_INTERACTIVE_PROCS=3     # interactive 最大进程数
MIN_MEM_GREEN=1200          # MB, 允许全并发
MIN_MEM_RED=800             # MB, 硬拒绝
ORPHAN_AGE=120              # 孤儿进程最小存活秒数

# Phase 2b — 交互状态
STATE_TTL=120               # 状态过期秒数
COOLDOWN_SEC=5              # spawn 冷却秒数

# Phase 2d — 资源锁
LOCK_TTL=600                # 锁过期秒数 (10min)
NET_MAX=2                   # 网络类最大并发
SPIN_DEFAULT_TIMEOUT=30     # 默认自旋秒数
CPU_LOAD_THRESHOLD=4.0      # loadavg 自动检测阈值
```

---

## 五、Hook 配置基线

```json
{
  "hooks": {
    "SessionStart": [
      {"command": "bash /root/claude-version-hook.sh full || true"},
      {"command": "bash /root/claude-agent-gate.sh cleanup || true"},
      {"command": "bash /root/claude-agent-gate.sh mark-idle || true"}
    ],
    "PreToolUse": [
      {"matcher": "", "command": "bash /root/claude-agent-gate.sh mark-interactive"},
      {"matcher": "Agent", "command": "bash /root/claude-agent-gate.sh check"},
      {"matcher": "Bash", "command": "bash /root/claude-agent-gate.sh acquire auto --try-only"}
    ],
    "PostToolUse": [
      {"matcher": "Bash", "command": "bash /root/claude-agent-gate.sh release acquired"}
    ],
    "Stop": [
      {"command": "bash /root/claude-agent-gate.sh mark-idle"}
    ]
  }
}
```

### Hook 设计原则

1. **全部 `|| true`** — hook 失败不阻塞 session
2. **PreToolUse 同步执行** — 但退出码不影响工具执行 (Claude Code 限制)
3. **快速路径优先** — 单进程时锁逻辑跳过
4. **advisory 非 enforcement** — 锁是 advisory，唯一硬约束是进程数+内存

---

## 六、命令模式分类规则

```
cpu: (npm|yarn|pnpm) (install|build|...) | pip install | cmake | make | gcc | cargo
io:  grep -r / | find / | rsync | dd | tar -[cx]
net: curl -[oO] | wget | git (clone|pull) | pip download
mem: python (train|model) | ffmpeg | convert -resize
light: 其他所有 (echo, ls, cat, ...)
```

配置化: `/root/.claude/resource-patterns.conf` (可编辑, 不触动脚本)

---

## 七、故障模式与恢复

| 故障 | 检测 | 自动恢复 |
|------|------|---------|
| 僵尸锁 (PID死亡) | `kill -0` | 下次 acquire/check 自动清理 |
| 锁过期 (TTL超时) | `now - epoch > 600` | 自动删除 |
| 状态文件损坏 | JSON 解析失败 | 默认 interactive |
| 状态文件过期 | `age > 120s` | 默认 interactive |
| 脚本自身崩溃 | `set +e` | 全部 `|| true` 兜底 |
| Hook 缺失 | 文件不存在 | 所有检查默认 conservative |

---

## 八、升级影响评估

### 升级前检查清单

- [ ] 跑 `tests/agent-gate-test.sh` — 27 项全部通过
- [ ] 确认 `pgrep`, `/proc/meminfo`, `renice` 可用
- [ ] 确认 `/tmp/claude-resource-locks/` 目录可写
- [ ] 确认 `settings.local.json` hook 配置与新基线一致
- [ ] 确认 `cooldown=5s` 与 Claude Code 实际 spawn 频率兼容

### 不兼容变更警示

| 变更 | 影响 |
|------|------|
| `MAX_TOTAL_PROCS` 降低 | 需要更多的 spawn 拒绝 → 可能减慢工作流 |
| `MIN_MEM_RED` 提高 | 更早拒绝 → 更保守 |
| `STATE_TTL` 缩短 | 更频繁进入 interactive 默认 |
| `LOCK_TTL` 缩短 | 更频繁偷锁 → 可能允许冲突 |
| 新增 hook matcher | 可能增加每次工具调用的延迟 (~10ms/hook) |

### 性能预算

| 操作 | 预算 |
|------|------|
| PreToolUse mark-interactive | < 10ms |
| PreToolUse Agent check | < 20ms |
| PreToolUse Bash acquire | < 5ms (单进程快速路径) |
| PostToolUse Bash release | < 2ms |
| Stop mark-idle | < 10ms |

总计每次用户消息额外开销: ~30ms (可忽略)

---

## 九、关联文档

- `plans/crash-improvement-plan-2026-07-03.md` — 总方案
- `plans/interactive-aware-subagent-plan-2026-07-03.md` — Phase 2b 设计
- `plans/resource-class-scheduling-plan-2026-07-03.md` — Phase 2d 设计
- `docs/subagent-lessons-learned-2026-07-03.md` — 经验教训
- `tests/agent-gate-test.sh` — 回归测试
- `deployments/agent-gate/hooks-reference.json` — Hook 配置参考
- `claude-resource-protocol.md` — Claude 资源使用协议
