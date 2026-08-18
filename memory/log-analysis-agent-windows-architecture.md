---
name: log-analysis-agent-windows-architecture
description: 日志分析 Agent 服务在 Windows 上的高并发架构设计 — Nginx+Tornado 多进程+ThreadPoolExecutor 异步隔离+Windows TCP 调优
metadata: 
  node_type: memory
  type: project
  originSessionId: [已脱敏]
  modified: 2026-08-10T00:33:00.642Z
---

# 日志分析 Agent — Windows 高并发部署架构

## 核心决策

在 Windows 上部署基于 opencode/Pi Agent 的日志分析服务，通过 Nginx 反向代理 + 手动多 Tornado 进程 + ThreadPoolExecutor 异步隔离，达到生产级高并发稳定性。

## 关键约束

- **Windows 无 fork**: Tornado `fork_processes` 不可用 → 手动启动多进程绑定不同端口
- **Agent 同步阻塞**: opencode/Pi Agent 调用是同步的 → ThreadPoolExecutor 隔离，防止阻塞事件循环
- **分析耗时不均**: 秒级到分钟级 → 三层超时 (Nginx 120s/Tornado 60s/Agent 60s) 逐层兜底

## 架构拓扑

```
Nginx (80) → upstream least_conn → Tornado :8801-:8804
                                       │
                                       ├─ ThreadPoolExecutor (max_workers=8) × 4 processes
                                       │      = 32 并发分析槽位
                                       └─ AgentClient.analyze_log() [同步, 线程池中执行]
                                              │
                                              ├─ opencode CLI (subprocess)
                                              └─ 或 Pi Agent SDK
```

## 与 Fan-Out 的结合

日志分析天然适合 Fan-Out 多维度并行：
- 错误模式识别 + 性能瓶颈分析 + 安全威胁检测 + 时序异常检测
- 各维度只读 → 无冲突 → 可以安全并行
- 汇总阶段交叉验证 → 提升置信度

参见 [[fan-out-subagent-pattern]] 了解防冲突机制和适用条件。

## 三层超时体系

| 层 | 参数 | 值 | 作用 |
|----|------|-----|------|
| Nginx | proxy_read_timeout | 120s | 对客户端不返回 504 |
| Tornado | asyncio.wait_for | 60s | 事件循环不卡死 |
| Agent | AgentClient.timeout | 60s | 线程不永久阻塞 |

**Why:** 外层必须大于内层，否则 Nginx 先超时返回 504，而 Tornado 还在等 Agent → 浪费资源。
**How to apply:** 设计任何同步→异步包装时，从外到内逐层设置超时，每层递减 30-60s。

## 部署文件

- 方案: `plans/log-analysis-agent-windows-plan.md`
- 架构: `docs/log-analysis-agent-architecture.md`
- 部署: `deployments/log-analysis-agent/`

## 关联知识

- [[fan-out-subagent-pattern]] — 日志分析多维度并行分发
- [[opencode-multi-agent-architecture]] — Agent 两层模型
- [[hermes-parallel-task-communication]] — delegate_task vs Kanban 选择
- [[claude-unattended-cross-platform-guide]] — 跨平台部署差异处理
- [[agent-async-isolation-pattern]] — ThreadPoolExecutor 异步隔离通用模式
- [[state-machine-quality-gate-loop]] — 分析结果质量门控
