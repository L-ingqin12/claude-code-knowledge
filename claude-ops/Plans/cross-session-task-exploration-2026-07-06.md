---
title: 跨 PRoot Session 任务分发 — 预探索方案
aliases: []
tags: [ai/ops]
created: 2026-07-06
updated: 2026-08-17
status: deprecated
---

# 跨 PRoot Session 任务分发 — 预探索方案

> [!warning] 此文档已废弃，请参考 [[multi-session-architecture-2026-07-09]]

See also: [[Claude-Ops-KB-Home]] · [[multi-session-architecture-2026-07-09]] · [[claude-unattended-operation-plan]]

> 日期: 2026-07-06 | 状态: 预探索，待测试验证 | 风险: 🔴 高

---

## 背景

PRoot 下每个 session 的 I/O 路径独立。当前 fan-out 的 Agent 子代理与主 session 共享同一 I/O 路径 → D 状态阻塞传染。将重负载任务分发到独立 proot session，可实现真正的 I/O 隔离。

## 风险矩阵

| 风险 | 概率 | 影响 | 缓解 |
|------|:--:|------|------|
| 跨 session 通信不可靠 | 中 | 高 | 文件轮询 + TTL 超时兜底 |
| Worker session 资源泄漏 | 中 | 中 | 任务级 TTL + 定期清理 |
| 主 session 写入但 worker 未读 | 低 | 中 | 双向确认 (ack 文件) |
| 文件锁跨 session 不一致 | 低 | 中 | 独立锁命名空间 |
| Termux OOM (多 proot) | 低 | 高 | worker 用 haiku 模型 + 内存限制 |

## 测试阶梯 (必须按顺序)

### 阶段 A: 基础连通性 (零风险)

```
目标: 验证跨 session 文件通信可用
测试:
  A1. 主 session 写 /tmp/cross-session-test/hello → worker session 读
  A2. Worker session 写 /tmp/cross-session-test/response → 主 session 读
  A3. 延迟测量: write → detect → read 全链路
  A4. 并发: 同时写 3 个 task, worker 串行处理
  A5. 异常: 主 session 进程被杀 → worker 检测 TTL → 清理

通过条件: 5/5 全过, 延迟 < 5s
```

### 阶段 B: I/O 隔离验证 (低风险)

```
目标: 证明独立 session 不会 D-state 传染
测试:
  B1. Worker 执行 dd if=/dev/urandom of=/tmp/big bs=1M count=100
      同时主 session 执行 echo hello (测量响应时间)
  B2. 对比: Agent 子代理执行同样 dd → 主 session 响应时间
  B3. Worker 内存超限 (填满 /tmp) → 主 session 不受影响

通过条件: B1 响应 <1s, B2 响应显著慢于 B1, B3 主 session 存活
```

### 阶段 C: 最小可行分发 (中风险)

```
目标: 单任务端到端: 主 session 派发 → worker 执行 → 取回结果
设计:
  通信目录: /tmp/claude-cross-session/
  
  任务文件: task-{id}.json
    {"id":"[已脱敏]","prompt":"...","model":"claude-haiku-4-5","ttl":300,"status":"pending"}
  
  结果文件: result-{id}.json  
    {"id":"[已脱敏]","status":"done","output":"...","exit":0}
  
  ack 文件:  ack-{id} (worker 创建, 表示已接手)
  
  流程:
    1. 主 session: write task-001.json → wait ack-001 (max 10s) → wait result-001
    2. Worker:    poll tasks/ → create ack → claude -p → write result
    3. 主 session: read result → 清理 task/ack/result
  
  Worker 守护 (轻量, bash 实现):
    while true; do
      for task in /tmp/claude-cross-session/task-*.json; do
        [ -f "$task" ] || continue
        id=$(basename "$task" .json | sed 's/task-//')
        [ -f "ack-$id" ] && continue  # 已被其他 worker 接手
        touch "ack-$id"
        prompt=$(grep -oP '"prompt":"\K[^"]+' "$task")
        model=$(grep -oP '"model":"\K[^"]+' "$task")
        echo "{\"id\":\"$id\",\"status\":\"done\",\"output\":\"$(claude -p "$prompt" --model "$model" 2>&1 | head -c 5000)\"}" > "result-$id.json"
        rm "$task" "ack-$id"
      done
      sleep 2
    done

通过条件: 派发 3 个独立任务, 全部取回结果, 无超时
```

## 集成点

完成阶段 C 后可集成到现有体系:

```
agent-gate.sh 新增:
  cross-session-dispatch <prompt> [--model haiku]  → 写任务到通信目录
  cross-session-status  <task-id>                   → 查结果
  cross-session-cleanup                             → 清理过期任务

claude-resource-protocol.md 新增:
  重负载任务路由规则:
    短任务 (<10 tool calls)  → Agent 子代理 (低延迟)
    长任务 (≥10 tool calls)  → 跨 session 分发 (I/O 隔离)
    重 I/O 任务 (grep/find)  → 跨 session 分发 (防 D-state)
```

## 逃生通道

```
1. 停止 worker:  kill worker-daemon → 任务堆积在通信目录 (不丢失)
2. 回退到 Agent:  删除通信目录 → 所有未处理任务由主 session Agent 接管
3. 完全卸载:      rm -rf /tmp/claude-cross-session/ + kill worker
```

## 不做的

- 不用 proot-distro login 嵌套 (已验证不可用)
- 不用命名管道/FIFO (PRoot 下不可靠)
- 不用 TCP socket (增加复杂性, 文件通信更简单可审计)
- 不做持久化任务队列 (那是 Kanban 的事)
