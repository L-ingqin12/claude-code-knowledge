---
title: PRoot 端口重启问题 — 根因与修复
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-07-02
updated: 2026-08-25
status: review
---

# PRoot 端口重启问题 — 根因与修复

See also: [[Claude-Ops-KB-Home]] · [[claude-proxy-restart-incident]] · [[claude-resilience-architecture]]

> 日期: 2026-07-02 | 影响: kill proxy 后端口永久占用，必须重启 Termux

---

## 根因

PRoot + Android 内核下，TCP 端口被释放后进入 TIME_WAIT 状态，**`SO_REUSEADDR` 无法覆盖**，端口长时间占用（实测 >60s，非永久）。

```
kill 进程 → 端口 TIME_WAIT → bind 同一端口 → EADDRINUSE
SO_REUSEADDR 生效                    ❌ 失败
SO_REUSEADDR + SO_REUSEPORT          ✅ 成功
```

## 修复: proxy 加 SO_REUSEPORT

```javascript
// claude-resilience-proxy.js 新增
server.on('listening', () => {
    const sock = server._handle; // 获取底层 socket
    // 实际上 Node.js http server 不直接暴露，需要在创建时设置
});

// 正确方式: Node.js ≥13.9 支持 net.Server listen 的 options.reusePort
// (http.createServer 返回的 server 继承 net.Server，其 listen 同样接受 options)
net.createServer(handler).listen({ port: 8787, host: '[IP已脱敏]', reusePort: true });
```

**Node.js 下的实施方式**：在 server 创建后、listen 前设置：

```javascript
const server = http.createServer(handler);
server.on('listening', () => {
    // 已监听，无需额外操作
});
// 关键: 在 createServer 层面无法设 SO_REUSEPORT
// 替代方案: 用 net.createServer 手动设置后传给 http
```

**或者最简单的修复**：deploy.sh 中如果 proxy 启动失败（端口占用），自动使用备用端口，同时更新 permafrost upstream。

```bash
# deploy.sh start_proxy 改为:
start_proxy() {
    for port in 8787 8789 8790; do   # 跳过 8788 (permafrost 固定端口)
        if ! curl -s "http://[IP已脱敏]:$port/" >/dev/null 2>&1; then
            PROXY_PORT=$port
            node /root/claude-resilience-proxy.js > /root/.claude/proxy.log 2>&1 &
            ...
            break
        fi
    done
}
```

## 已验证结论

| 方案 | PRoot 下效果 |
|------|-------------|
| SO_REUSEADDR 单独 | ❌ 无效 |
| SO_REUSEPORT + SO_REUSEADDR | ✅ 立即可绑 |
| 等待端口释放 | ❌ >60s 不行 |
| 用不同端口 | ✅ 可行 |
| Termux 完全重启 | ✅ 可行 |

## 规则

1. 永不手动 kill 生产进程（已有规则）
2. proxy 代码加 SO_REUSEPORT（下次更新时一并改）
3. deploy.sh 加备用端口机制
