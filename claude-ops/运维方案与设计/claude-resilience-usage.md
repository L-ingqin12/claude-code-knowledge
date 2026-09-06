---
title: Claude Code 韧性代理 — 使用手册
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-06-11
updated: 2026-08-17
status: review
---

# Claude Code 韧性代理 — 使用手册

See also: [[Claude-Ops-KB-Home]] · [[claude-resilience-architecture]] · [[claude-deployment-record]]

> 最后更新: 2026-06-11
> 当前版本: Node.js 代理

---

## 一、是什么

一个运行在本地的轻量代理 (Node.js, ~120 行)，位于 Claude Code 和 DeepSeek API 之间。自动重试网络抖动、保持连接活跃。

```
Claude Code → 127.0.0.1:8787 → 代理 → api.deepseek.com
```

---

## 二、日常命令

```bash
# 重新启用（回滚后、重启后、首次部署）
bash /root/claude-resilience-deploy.sh start

# 查看当前状态
bash /root/claude-resilience-deploy.sh status

# 停止代理
bash /root/claude-resilience-deploy.sh stop

# 出问题 → 回滚到直连模式
bash /root/claude-rollback.sh
```

---

## 三、如何知道代理在工作

```bash
# 看代理日志
cat /root/.claude/proxy.log

# 正常时应该看到类似:
# [proxy] Listening 127.0.0.1:8787 → https://api.deepseek.com/anthropic
# [proxy] POST /v1/messages → 200 (1234ms)

# 网络抖动被重试时:
# [proxy] Retry in 1000ms (2 left): socket hang up
# [proxy] POST /v1/messages → 200 (3456ms)
```

---

## 四、三种状态及操作

```
状态A: 正常运行
  代理进程: ✓ (PID 在 /root/.claude/proxy.pid)
  shell配置: ANTHROPIC_BASE_URL=http://127.0.0.1:8787
  → 无需操作，Claude 新会话自动走代理

状态B: 回滚后（直连 DeepSeek）
  代理进程: ✗
  shell配置: ANTHROPIC_BASE_URL=https://api.deepseek.com/anthropic
  → bash /root/claude-resilience-deploy.sh start

状态C: 代理挂了
  现象: Claude 连不上 API
  → bash /root/claude-rollback.sh     ← 先恢复服务
  → 检查 /root/.claude/proxy.log     ← 找原因
  → bash /root/claude-resilience-deploy.sh start  ← 修好后重新启用
```

---

## 五、涉及的文件

| 文件 | 作用 | 是否可手动改 |
|------|------|-------------|
| `/root/claude-resilience-proxy.js` | 代理程序 | 是 |
| `/root/claude-resilience-deploy.sh` | 部署/启停 | 是 |
| `/root/claude-rollback.sh` | 逃生回滚 | 不建议 |
| `/root/.zshrc` (line 107) | Claude 启动时读取的 API URL | 是 |
| `/root/.bashrc` (line 150) | 同上 | 是 |
| `/root/.claude/proxy.pid` | 代理进程 PID (自动) | 否 |
| `/root/.claude/proxy.log` | 代理日志 (自动) | 否 |

---

## 六、查看实时日志

```bash
tail -f /root/.claude/proxy.log
```

---

## 七、换个上游（如改用 Anthropic 直连）

```bash
# 停代理
bash /root/claude-resilience-deploy.sh stop

# 以不同上游启动
PROXY_TARGET=https://api.anthropic.com node /root/claude-resilience-proxy.js > /root/.claude/proxy.log 2>&1 &
echo $! > /root/.claude/proxy.pid

# 或改回直连
bash /root/claude-rollback.sh
```

---

## 八、GitHub 完整文档

所有设计文档、推导链路、复盘记录均在此仓库：
https://github.com/L-ingqin12/claude-code-knowledge
