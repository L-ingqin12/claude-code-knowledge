---
title: Proxy 链路韧性优化方案
aliases: []
tags: [ai/ops]
created: 2026-07-09
updated: 2026-08-25
status: deprecated
---

# Proxy 链路韧性优化方案

> [!warning] 此文档已废弃，请参考 [[claude-resilience-architecture]]

See also: [[Claude-Ops-KB-Home]] · [[claude-resilience-architecture]] · [[claude-proxy-restart-incident]]

> 日期: 2026-07-09 | 状态: 设计完成 | 触发: proxy 进程死亡导致全链路不可用

---

## 事故还原

```
SessionStart → 版本变化 2.1.201→2.1.205
  → version-hook 检测新工具 Monitor
  → 触发 deploy.sh force (permafrost 补丁恢复+重启)
  → proxy 进程在重启过程中死亡 (PID 消失)
  → 8787 端口无监听
  → 所有 API 调用失败
  → "多次 attempt" + "temporarily unavailable"
```

**核心问题**：proxy 是单点，挂了没有任何检测和恢复机制。

---

## 设计

### 1. permafrost 重启时保 proxy（治本）

当前 `deploy.sh force` 流程可能 kill 了 proxy。修改 `claude-permafrost-deploy.sh`：

```bash
# force 重启前检查 proxy 是否独立存活
proxy_pid=$(cat /root/.permafrost/proxy.pid 2>/dev/null)
if [ -n "$proxy_pid" ] && kill -0 "$proxy_pid" 2>/dev/null; then
    # proxy 独立存活，只重启 permafrost
    restart_permafrost_only
else
    # proxy 也死了，完整重启
    restart_full_stack
fi
```

**关键原则**：permafrost 和 proxy 是独立进程，permafrost 重启不应影响 proxy。

### 2. proxy 存活守护（治标）

在 SessionStart hook 中增加端口检测：

```bash
# 检测 proxy :8787 是否存活，挂了自动拉起
check_proxy_alive() {
    if ! curl -s -o /dev/null --max-time 2 http://127.0.0.1:8787/ 2>/dev/null; then
        echo "[gate] proxy :8787 无响应，尝试拉起..."
        bash /root/claude-permafrost-deploy.sh start 2>/dev/null || true
    fi
}
```

**注意**：`deploy.sh start` 有"运行中保护"，需确认不会误判。备选：直接启动 proxy 进程。

### 3. Agent 调用 fail-open 降级

当 auto mode 分类器不可用时，不应完全拒绝 Agent 调用。当前行为是 DENY → 任务被阻塞。

设计 fail-open 策略：

```
Agent 调用前置条件:
  1. agent-gate.sh check → OK (资源充足)
  2. auto mode classifier → 模型可用?

如果 classifier 不可用:
  方案 A: fallback 到 --model haiku 直接执行 (不经过分类器)
  方案 B: 等待 30s 重试 (当前行为)
  方案 C: 降级到 Bash 执行 (用 claude-gate-bash.sh wrapper)

推荐 方案 A — 由 agent-gate.sh check 已做了安全门控，分类器冗余。
```

但这是 Claude Code 内部行为，无法从 hook 层面干预。替代方案：在 resource-protocol.md 中指导 Claude 在遇到 `temporarily unavailable` 时手动 retry 或降级。

### 4. proxy 健康检查端点

在 `claude-resilience-proxy.js` 增加 `/health` 路由：

```javascript
// 在路由分发处 (约第73行后):
if (req.url === '/health') {
    res.writeHead(200, {'Content-Type': 'application/json'});
    res.end(JSON.stringify({
        status: 'ok',
        uptime: process.uptime(),
        pid: process.pid,
        upstream: 'deepseek'
    }));
    return;
}
```

收益：`curl http://127.0.0.1:8787/health` 秒级判断 proxy 状态，不做全量 API 调用。

### 5. 代理链路状态文件

写入 `/tmp/claude-proxy-status.json` 供 agent-gate 和 Claude 读取：

```json
{"proxy":{"port":8787,"status":"ok"},"permafrost":{"port":8788,"status":"ok"},"deepseek":"ok","checked":"2026-07-09T12:00:00Z"}
```

SessionStart hook 更新，agent-gate.sh `status` 展示。

---

## 实施优先级

| 优先级 | 改动 | 影响 | 风险 |
|:--:|------|------|:--:|
| 1 | proxy 存活守护 (2) | 挂了自动拉起，立竿见影 | 低 |
| 2 | proxy 健康检查端点 (4) | 快速诊断 | 低 |
| 3 | permafrost 重启保 proxy (1) | 治本 | 中 (改 deploy.sh) |
| 4 | 链路状态文件 (5) | 全局可见 | 低 |
| 5 | Agent fail-open (3) | 减少任务中断 | 低 (只是文档指导) |

---

## 不做

- 不引入新守护进程（违反 Occam's razor）— 利用现有 SessionStart hook
- 不修改 Claude Code 内部 auto mode 行为 — hook 无法干预
- 不在 proxy 内加复杂的健康检查逻辑 — 只加一个 /health 端点
