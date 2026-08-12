---
name: agent-async-isolation-pattern
description: 同步 Agent 调用的异步隔离通用模式 — ThreadPoolExecutor + asyncio.wait_for + 超时兜底
metadata: 
  node_type: memory
  type: reference
  originSessionId: 682ad952-971a-4380-95da-b2a6a7907ebd
  modified: 2026-08-10T00:33:05.338Z
---

# Agent 同步调用异步隔离模式

## 问题

opencode / Pi Agent / Claude Code 等 Agent 框架的调用接口通常是同步阻塞的（subprocess 调用或同步 SDK）。直接放在 Tornado/FastAPI 的 async handler 中会阻塞事件循环，导致所有请求排队。

## 解决方案

三层包装模式:

```
async handler
  │
  ├─ asyncio.wait_for(future, timeout=T1)     ← L1: 事件循环超时
  │     │
  │     └─ loop.run_in_executor(pool, fn)      ← L2: 线程池隔离
  │           │
  │           └─ AgentClient.method(timeout=T2) ← L3: Agent 自身超时
```

## 关键参数

| 参数 | 推荐值 | 原则 |
|------|--------|------|
| ThreadPoolExecutor.max_workers | 8 per process | 不超过 CPU 核数 × 2 |
| asyncio.wait_for timeout | 60s | 略大于 Agent 超时 |
| AgentClient timeout | 50-60s | Agent 任务的实际时间上限 |

## 注意事项

1. **线程无法被 asyncio 真正取消**: `wait_for` 超时后线程仍在后台运行。AgentClient 内部必须有自己的超时。
2. **线程池大小固定**: 线程池满后新任务排队。通过增加进程数水平扩容，而非增大线程池。
3. **优雅关闭**: `executor.shutdown(wait=True)` 等待正在执行的任务完成。

## 适用场景

- Tornado async handler 中调用同步 Agent
- FastAPI async handler 中调用同步 Agent
- 任何 async web framework + 同步 Agent SDK 的组合

**Why:** Python 的 GIL 意味着 CPU 密集型 Agent 调用必须在线程池中执行才能释放事件循环。这是连接 async web framework 和 sync agent SDK 的桥梁模式。
**How to apply:** 复制 `_run_agent_with_timeout` 方法模板，替换 `AgentClient.analyze_log` 为实际调用。

## 关联

- [[log-analysis-agent-windows-architecture]] — 本模式在日志分析服务中的具体应用
- [[fan-out-subagent-pattern]] — 多维度分析时本模式的并行扩展
- [[claude-interruption-resilience]] — 长任务恢复 (与本模式的超时互补)
