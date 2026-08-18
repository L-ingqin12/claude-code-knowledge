# Hermes 并行任务调度与通信机制

> 分析日期: 2026-06-16  
> 分析环境: Raspberry Pi 4B (raspberrypi, aarch64, Debian)  
> Hermes 版本: 最新 (deepseek-v4-pro-260425, custom endpoint)

---

## 一、并行执行能力总览

Hermes 提供两套并行机制，互为补充：

| 维度 | `delegate_task` | Kanban |
|------|:---------------:|:------:|
| **模型** | RPC 调用 (fork→join) | 持久消息队列 + 状态机 |
| **并行方式** | 单次调用多个子任务并发 | Dispatcher 多 worker 并发调度 |
| **最大并行数** | `max_concurrent_children: 3` | 无上限 (由 dispatcher 按资源调度) |
| **嵌套深度** | `max_spawn_depth: 1` (平层: 父→子) | 不限 (通过 link 链可任意深度) |
| **持久性** | ❌ 父 turn 中断则子任务取消 | ✅ SQLite 行持久, 崩溃后 reclaim |
| **人工介入** | ❌ 不支持 | ✅ comment / unblock / reassign |
| **审计追溯** | 丢失于上下文压缩 | 永久保留于 SQLite |
| **适用场景** | 短期推理、并行调研、代码审查 | 跨重启工程、多角色协作、定时任务 |

### 当前配置

```yaml
# delegate_task 配置
delegation:
  max_concurrent_children: 3      # 每批最多 3 个子任务并行
  max_spawn_depth: 1              # 只允许父→子一层
  orchestrator_enabled: true      # orchestrator 角色可再派发
  subagent_auto_approve: false    # 子代理危险命令自动拒绝 (安全)
  max_iterations: 50              # 每个子代理独立 50 轮上限

# Kanban dispatcher 配置
kanban:
  dispatch_in_gateway: true       # dispatcher 内嵌于 gateway 进程
  dispatch_interval_seconds: 60   # 每 60 秒调度一轮
  failure_limit: 2                # 同一任务连续失败 2 次自动 block
```

---

## 二、任务间通信机制详解

```
┌──────────────────────────────────────────────────────────────────┐
│                      delegate_task 通信模型                        │
│                                                                  │
│  Parent ──goal + context──→ Child A  (独立上下文, 隔离工具)       │
│         ←──summary text──── Child A                               │
│                                                                  │
│  Parent ──goal + context──→ Child B                               │
│         ←──summary text──── Child B                               │
│                                                                  │
│  Child A ←────────→ Child B:  ❌ 完全隔离, 互不可见               │
│                                                                  │
│  通信: 单向 — 父传子 (goal+context), 子回父 (summary)             │
│  局限性: 兄弟任务无法共享中间结果, 父必须等待全部完成              │
├──────────────────────────────────────────────────────────────────┤
│                        Kanban 通信模型                             │
│                                                                  │
│  ┌─────────┐  link(parent→child)   ┌─────────┐                   │
│  │ Task A  │ ◄───────────────────► │ Task B  │                   │
│  │ (done)  │  comment (双向互通)    │ (ready) │                   │
│  └────┬────┘                       └────┬────┘                   │
│       │                                 │                        │
│       └── context(B) ──→ B 自动读到 A 的完成结果 ──┘              │
│                                                                  │
│  Worker A 完成时可以写入 metadata:                                │
│    { "exit_code": 0, "files_changed": ["a.py"], "summary": "…" } │
│                                                                  │
│  通信: 多向 — 依赖链 + 评论 + 上下文注入 + 结构化元数据            │
├──────────────────────────────────────────────────────────────────┤
│                     Kanban Swarm 黑板模型                          │
│                                                                  │
│                    ┌──────────────────┐                          │
│                    │   Root Task       │                          │
│                    │  (共享黑板 + 审计) │                          │
│                    └──┬───┬───┬─────┬─┘                          │
│                       │   │   │     │                             │
│              ┌────────┘   │   │     └────────┐                    │
│              ▼            ▼   ▼              ▼                    │
│          Worker₁      Worker₂  Worker₃   Workerₙ (并行)           │
│              │            │     │              │                   │
│              └────────────┴─────┴──────────────┘                   │
│                             │                                     │
│                       Verifier (门禁)                              │
│                             │                                     │
│                       Synthesizer (输出)                           │
│                                                                  │
│  通信: 结构化黑板 — JSON 评论写到 Root, 所有 worker 可读           │
│  Worker 间通过 root 任务的 [swarm:blackboard] 评论了解 sibling 进展│
└──────────────────────────────────────────────────────────────────┘
```

### 通信机制对比

| 机制 | 方向 | 载体 | 持久性 | 机器可读 |
|------|------|------|:------:|:--------:|
| **link** | 父→子 (单向依赖) | `task_links` 表 | ✅ | — |
| **comment** | 任意⇄任意 | `task_comments` 表 | ✅ | — |
| **context** | 被读任务→新 worker | worker 系统提示 (读取时注入) | — | — |
| **completion metadata** | worker→kanban | `tasks.result` JSON 列 | ✅ | ✅ |
| **swarm blackboard** | worker⇄verifier | root 任务的结构化 JSON 评论 | ✅ | ✅ |
| **goal + context** (delegate) | 父→子 | 子代理系统提示 (创建时注入) | ❌ | — |

---

## 三、通信链路详细说明

### 3.1 link — 依赖门控

```bash
hermes kanban link <parent_id> <child_id>
```

- 子任务在所有父任务 `done` 之前保持 `todo`
- Dispatcher 检查 `task_links` 表，所有 parent done → 子任务 `promoted → ready`
- 防止循环依赖 (创建时检测)
- 适用于链式工作流: A 完成后 B 才能开始

### 3.2 comment — 跨任务消息协议

```bash
hermes kanban comment <task_id> "评论内容" --author <profile>
```

- 任意 profile 可评论任意任务
- Worker 重新 spawn 时完整评论线程作为上下文注入
- 人工可通过 CLI/Dashboard 插入评论
- 适用于需要人审、跨角色协作、状态同步

### 3.3 context — 自动上下文注入

Worker spawn 时，`build_worker_context()` 自动组装并注入:

1. 任务标题 + 正文
2. 所有父任务的完成结果 (`parent_results`)
3. 最近 30 条评论 (`CTX_MAX_COMMENTS`)
4. 附件列表 (文件路径)
5. swarm 协议指令 (如果是 swarm worker)
6. kanban board slug (隔离感知)

### 3.4 completion metadata — 结构化交接

Worker 完成时写入:

```json
{
  "exit_code": 0,
  "summary": "完成了 X, 修改了 Y, 未完成 Z",
  "files_changed": ["src/a.py", "src/b.py"],
  "test_results": "14 passed, 0 failed",
  "handoff_notes": "下一步需要配置环境变量 X"
}
```

下游 worker 通过 `kanban_context` 工具读取这些字段。

### 3.5 swarm blackboard — 并行黑板

```json
// worker₁ 写入 root task 的评论:
[swarm:blackboard] {"key": "api_endpoints", "value": ["GET /users", "POST /login"]}

// worker₂ 写入 root task 的评论:
[swarm:blackboard] {"key": "db_schema", "value": {"users": ["id", "name"], ...}}

// verifier 读取 latest_blackboard(conn, root_id) 得到完整合并结果
```

- `BLACKBOARD_PREFIX = "[swarm:blackboard] "` 标记
- 后写入的同 key 值覆盖前值
- `_authors` 记录每个 key 的写入者

---

## 四、并行拓扑模式

### 4.1 独立并行 (delegate_task)

```
Parent
  ├─→ Child₁: 调研 WebAssembly
  ├─→ Child₂: 调研 RISC-V
  └─→ Child₃: 调研量子计算
       ↓ (全部完成)
Parent 合成报告
```

**适用**: 互不依赖的并行调研、多文件独立修改

### 4.2 链式依赖 (Kanban link)

```
Task A (数据采集) → Task B (数据清洗) → Task C (分析报告)
```

**适用**: 有严格先后顺序的流水线

### 4.3 Swarm 拓扑 (Kanban Swarm)

```
Root (规划黑板)
  ├─ Worker₁ (API 设计)  ──┐
  ├─ Worker₂ (数据库设计) ──┤
  └─ Worker₃ (前端设计)  ──┘
       ↓
  Verifier (评审门禁)
       ↓
  Synthesizer (最终输出)
```

**适用**: 需要交叉协调的复杂并行工程

### 4.4 混合拓扑 (delegate_task + internal Kanban)

```
Parent (kanban orchestrator)
  ├─ delegate_task → Kanban Swarm (子工程 A)
  └─ delegate_task → Kanban Swarm (子工程 B)
```

**适用**: 需要在 delegate_task 内部使用持久队列的场景

---

## 五、约束与限制

| 约束 | 详情 |
|------|------|
| delegate_task 并发上限 | 3 (可通过 `max_concurrent_children` 调高, 无硬上限) |
| 子代理嵌套深度 | 1 (flat only) — 调高需显式设置 `max_spawn_depth` |
| delegate_task 持久性 | 无 — 父 turn 结束则子任务取消 |
| 子代理工具限制 | 不能调用 `delegate_task`(leaf), `clarify`, `memory`, `send_message`, `execute_code` |
| Kanban worker 超时 | 默认 claim TTL 15min, 通过 heartbeat 续期 |
| Kanban 单线程 dispatcher | 同一时刻只一个 dispatcher 扫板 (多 gateway 时仅一个开启 dispatch_in_gateway) |
| delegate_task 同步阻塞 | 父必须等待所有子完成才继续 |

---

## 六、当前运行状态

```
树莓派 [IP已脱敏]:

  model-router v3 (systemd)    ✅ :18888, upstream ARK
  hermes-gateway (default)     ✅ feishu connected
  hermes-gateway-ranzi         ✅ active
  kanban dispatcher            每 60s 轮询
  kanban board                 空 (无活跃任务)
  profiles                     default (idle) + ranzi (idle)

GitHub:
  repo: L-ingqin12/claude-code-knowledge
```

---

## 七、选型决策速查

| 需求 | 推荐方案 |
|------|---------|
| 并行调研/审查, 结果需合并 | delegate_task (≤3 并发) |
| 跨重启长期工程 | Kanban |
| 需要人工审核中间结果 | Kanban + comment |
| 多 worker 需要相互感知进展 | Kanban Swarm (黑板) |
| 有严格先后顺序 | Kanban link |
| 事后审计/回溯 | Kanban (持久 SQLite 行) |
| 短期推理/代码生成 | delegate_task |
| 定时周期性任务 | Kanban + cron |
| 批量处理(>3 并行) | Kanban Swarm |
