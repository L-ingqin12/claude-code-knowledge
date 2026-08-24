---
title: 终端崩溃改进方案 — 实施计划
aliases: []
tags: [ai/ops]
created: 2026-07-03
updated: 2026-08-25
status: deprecated
---

# 终端崩溃改进方案 — 实施计划

> [!warning] 此文档已废弃，请参考 [[subagent-resource-architecture-2026-07-03]]

See also: [[Claude-Ops-KB-Home]] · [[subagent-resource-architecture-2026-07-03]] · [[subagent-lessons-learned-2026-07-03]]

> 日期: 2026-07-03 | 来源: 多次 agent/subagent 终端崩溃事故分析
> 状态: 设计完成，待实施

---

## 背景

分析 7 起终端崩溃/卡死事故，分两类：

| 类型 | 占比 | 根因 | 故障域 |
|------|------|------|--------|
| A: 代理层单点故障 | 57% (4起) | proxy.js 被直接编辑、诊断代码混入控制流、竞态条件 | TCP/HTTP 代理 |
| B: Agent 资源耗尽 | 43% (3起) | fan out subagents 无并发限制、孤儿进程堆积、OOM | 进程/内存 |

详见 crash-analysis-2026-07-03（⚠️ 原记忆文档未随迁移入库，本库无等价文件，见 [[MEMORY-INDEX]]）

---

## Phase 1: Proxy 变更管控门禁

**依赖**: 无，可独立部署
**目标**: 防止 proxy.js 被直接在生产路径编辑

### 1.1 proxy.js 添加诊断代码隔离声明

- **文件**: `claude-resilience-proxy.js`
- **变更**: 文件头添加 `DO NOT ADD DIAGNOSTIC CODE HERE` 注释块
- **原则**: proxy.js 只做两件事 — 透明转发 + socket 重试

### 1.2 workspace→production 同步门禁 gate.sh

- **新建**: `deployments/proxy-gate/gate.sh`
- **子命令**:
  - `check` — 对比生产 vs 仓库 md5，不匹配则 WARN
  - `sync` — 备份 → 复制仓库版本到生产 → 更新 manifest
  - `guard` — SessionStart 用，静默 warn
- **新建**: `deployments/proxy-gate/rollback.sh`

### 1.3 Pre-commit Hook

- **新建**: `.githooks/pre-commit`
- **逻辑**: proxy.js 有变更时，检查 deploy.sh 存在 + 无诊断代码
- **配置**: `git config core.hooksPath .githooks`

### 1.4 SessionStart 集成

- **修改**: `claude-version-hook.sh` full() 中追加 `gate.sh guard`
- **特性**: 只读检测，失败不阻塞 session

### 验证

| 检查项 | 方法 |
|--------|------|
| 直接编辑 proxy.js 被检测 | `gate.sh check` 返回 WARN |
| workspace→生产同步 | `gate.sh sync` 后 md5 一致 |
| pre-commit 拦截 | 直接改 proxy.js `git commit` 被 hook 阻止 |
| 逃生回滚 | `rollback.sh` 恢复原文件 |

---

## Phase 2: Subagent 孤儿清理 + 并发限制

**依赖**: Phase 1 应先部署（避免混淆故障类型）
**目标**: 防止 agent 并发耗尽内存、孤儿堆积

### 2.1 agent-gate.sh

- **新建**: `/root/claude-agent-gate.sh`
- **子命令**:
  - `cleanup` — 清理孤儿 claude 进程（PPID=1 且运行 >5min）
  - `count` — 计数运行中 claude 进程（默认上限 5）
  - `memcheck` — 读取 `/proc/meminfo`（默认门槛 1GB 可用）
  - `check` — 组合：cleanup → count → memcheck，返回 OK/DENY

### 2.2 SessionStart 孤儿清理

- **修改**: `claude-version-hook.sh` full() 顶部追加 `agent-gate.sh cleanup`
- **特性**: 幂等，多次运行安全

### 2.3 资源指导注入

- **新建**: `/root/.claude/resource-guidance.txt`
- **内容**: delegate_task 前先跑 `agent-gate.sh check`，拒绝则降级为 Kanban

### 2.4 注册为 shell tool

- **修改**: `settings.local.json`
- **变更**: 添加 `agent-gate` tool，Claude 可在 spawn 前直接查询

### 验证

| 检查项 | 方法 |
|--------|------|
| 孤儿清理 | 后台起 claude，杀父进程，cleanup 清理孤儿 |
| 并发上限 | 起 5+ 进程，check 返回 DENY |
| 内存门槛 | 设低阈值，check 返回 DENY |
| SessionStart 自动清理 | session 启动前后 ps 对比 |

---

## Phase 3: 内存看守 + 长任务路由

**依赖**: Phase 2 (agent-gate.sh 可用)
**目标**: 内存自保 + 长任务走 Kanban 持久化

### 3.1 内存状态文件

- **新建**: `/root/.claude/memory.state`
- **更新**: 每次 `agent-gate.sh check` 写入 JSON（timestamp + mem_mb + status）
- **原则**: 无后台 daemon，按需写入

### 3.2 Kanban 路由助手

- **新建**: `/root/claude-kanban-helper.sh`（~50行）
- **功能**: `create`/`swarm`/`link` 薄封装 hermes kanban CLI
- **新建**: `/root/.claude/task-routing-guide.md`
  - delegate_task: 短任务(<50轮)、无需崩溃恢复、最大5并发
  - Kanban: 长任务(>50轮)、跨session、需要人工介入

### 验证

| 检查项 | 方法 |
|--------|------|
| Kanban helper 创建任务 | `kanban-helper.sh create "test" "desc"` |
| 路由指南可注入 | Claude session 询问路由决策规则 |

---

## 风险评估

| 变更 | 风险 | 缓解 |
|------|------|------|
| gate.sh sync | 复制错误文件 | sync 前创建时间戳备份，rollback 可用 |
| pre-commit hook | 拦截合法变更 | `git commit --no-verify` 可绕过 |
| SessionStart 集成 | hook 失败阻塞启动 | `|| true` 保底 |
| agent-gate cleanup | 误杀进程 | 年龄过滤 >5min + PID 排除当前 session |
| 并发检查 | spawn 时竞态窗口 | 非硬锁，checkpoint 式检查，窗口 <100ms |

### 回滚策略

| 组件 | 回滚命令 |
|------|----------|
| Phase 1 (gate) | `bash deployments/proxy-gate/rollback.sh` |
| Phase 2 (agent-gate) | `rm /root/claude-agent-gate.sh` + 移除 hook |
| Phase 3 (Kanban) | `rm /root/claude-kanban-helper.sh /root/.claude/task-routing-guide.md` |

每阶段独立回滚，无跨阶段依赖。

---

## 文件清单

### 新建 (6 文件, ~340 行)

| 文件 | Phase | 行数 |
|------|-------|------|
| `deployments/proxy-gate/gate.sh` | 1 | ~80 |
| `deployments/proxy-gate/rollback.sh` | 1 | ~30 |
| `.githooks/pre-commit` | 1 | ~40 |
| `/root/claude-agent-gate.sh` | 2 | ~100 |
| `/root/.claude/task-routing-guide.md` | 3 | ~40 |
| `/root/claude-kanban-helper.sh` | 3 | ~50 |

### 修改 (3 文件)

| 文件 | Phase | 变更 |
|------|-------|------|
| `claude-resilience-proxy.js` | 1 | 添加诊断隔离声明注释 |
| `claude-version-hook.sh` | 2 | 追加 cleanup + guard 调用 |
| `/root/.claude/settings.local.json` | 2,3 | 注册 agent-gate tool + cleanup hook |

### 零外部依赖

仅使用: `bash`, `pgrep`/`pkill`, `/proc/meminfo`, `md5sum` (全在 PRoot/Android 环境已可用)

---

## 相关记忆

- claude-code-preflight-checklist（⚠️ 原文档未随迁移入库，见 [[MEMORY-INDEX]] 散落条目）— 行动前强制检查清单
- [[claude-socket-error-elimination-guide]] — 四层防御体系
- [[claude-interruption-resilience-guide]] — 中断恢复方案
- [[hermes-parallel-task-report]] — delegate_task vs Kanban 能力边界
- [[interactive-aware-subagent-plan-2026-07-03]] — Phase 2b: 交互感知动态资源分配（PreToolUse/Stop hook 状态机）
- [[resource-class-scheduling-plan-2026-07-03]] — Phase 2d: 资源类别感知调度（cpu/io/net/mem 文件锁 + wrapper 脚本）
