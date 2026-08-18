# Diagnostic Relay — CC cancelRetry() 检测工具

## 架构

```
CC → permafrost :8788 → relay :8789 → proxy :8787 → DeepSeek
```

## 文件

| 文件 | 作用 |
|------|------|
| `relay.js` | 透明 TCP 中继，纯管道转发，零数据修改 |
| `deploy.sh` | 部署：预检 → 启动 relay → 切换 permafrost → E2E 验证 |
| `rollback.sh` | 逃生：切换 permafrost 回直连 → 停止 relay |

## 端口机制

- `reusePort: true` — 零中断重启（与 proxy.js 一致）
- `setKeepAlive(true, 60000)` — 连接保活（与 proxy.js 一致）

## 证据模式

`tail -f relay.log`:

```
[relay] #N CONNECT              ← 请求到达
[relay] #N CLIENT-CLOSED 95s    ← CC 断开
[relay] #N END 150s [CC-GONE-55s — cancelRetry 证据!]  ← 代理成功但 CC 已走
```

时间差 > 5s 才触发告警（过滤正常 TCP 关闭竞态）。

## 部署

```bash
bash deploy.sh    # 部署
bash rollback.sh  # 逃生
```
