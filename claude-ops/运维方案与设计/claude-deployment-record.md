---
title: Claude Code 韧性代理 — 部署记录与使用手册
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-06-11
updated: 2026-08-17
status: review
---

# Claude Code 韧性代理 — 部署记录与使用手册

See also: [[Claude-Ops-KB-Home]] · [[claude-resilience-architecture]] · [[claude-resilience-usage]]

> 部署日期: 2026-06-11
> 环境: Android aarch64 → Termux → PRoot → Ubuntu 24.04
> Claude Code: v2.1.172

---

## 一、修改清单（所有变更）

### 系统配置文件（2 个文件，各 1 行）

| 文件 | 行号 | 修改前 | 修改后 |
|------|------|--------|--------|
| `/root/.zshrc` | 107 | `export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"` | `export ANTHROPIC_BASE_URL="http://[IP已脱敏]:8787"` |
| `/root/.bashrc` | 150 | `export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"` | `export ANTHROPIC_BASE_URL="http://[IP已脱敏]:8787"` |

### 新增文件（5 个）

| 文件 | 用途 |
|------|------|
| `/root/claude-resilience-proxy.py` | 韧性代理 v2（核心组件，四道防线） |
| `/root/claude-resilience-deploy.sh` | 一键部署/启停脚本 |
| `/root/claude-rollback.sh` | 🚨 逃生通道：一键回滚到部署前状态 |
| `/root/.claude/resume-prompt-header.txt` | 中断恢复协议模板（供 Claude 任务使用） |
| `/root/.claude/proxy.pid` | 代理进程 PID 文件（运行时自动生成） |

### 新增文档（均已在 GitHub）

| 文件 | 说明 |
|------|------|
| `/root/claude-socket-error-elimination-guide.md` | root cause 分析 |
| `/root/claude-network-resilience-v2.md` | v2 简化方案 |
| `/root/claude-network-stability-gate.md` | 门控机制设计 |
| `/root/claude-optimal-resilience-design.md` | 四约束决策推导 |
| `/root/claude-full-guardian.sh` | 完整守护（归档备用） |
| `/root/claude-network-guardian.sh` | 网络守护（归档备用） |

---

## 二、使用手册

### 日常使用（代理已自动生效）

```bash
# 1. 启动 Claude（代理自动生效，无需额外操作）
claude --permission-mode accept-edits

# 2. 带任务启动
claude -p "你的任务" --permission-mode accept-edits
```

**Claude 的所有 API 请求自动经过代理。无需做任何事。**

### 状态检查

```bash
# 查看代理是否运行
bash /root/claude-resilience-deploy.sh status

# 查看代理日志
tail -f /root/.claude/proxy.log

# 查看代理进程
ps -o pid,etime,cmd -p $(cat /root/.claude/proxy.pid 2>/dev/null)
```

### 启停操作

```bash
# 启动（含 TCP 优化 + 代理 + 恢复模板）
bash /root/claude-resilience-deploy.sh start

# 停止代理
bash /root/claude-resilience-deploy.sh stop

# 查看状态
bash /root/claude-resilience-deploy.sh status
```

### 使用中断恢复协议

```bash
# 拼接恢复协议头 + 你的任务
ANTHROPIC_BASE_URL=http://[IP已脱敏]:8787 \
  claude -p "$(cat /root/.claude/resume-prompt-header.txt)

你的任务描述" --permission-mode accept-edits
```

---

## 三、逃生通道

### 🚨 一键回滚（恢复到部署前状态）

```bash
bash /root/claude-rollback.sh
```

这个命令会：
1. 停止代理进程
2. 恢复 `.zshrc` 中 ANTHROPIC_BASE_URL → `https://api.deepseek.com/anthropic`
3. 恢复 `.bashrc` 中 ANTHROPIC_BASE_URL → `https://api.deepseek.com/anthropic`

### 手动回滚（如果脚本不可用）

```bash
# 1. 停止代理
kill $(cat /root/.claude/proxy.pid) 2>/dev/null

# 2. 恢复 .zshrc
sed -i 's|export ANTHROPIC_BASE_URL="http://[IP已脱敏]:8787"|export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"|' /root/.zshrc

# 3. 恢复 .bashrc
sed -i 's|export ANTHROPIC_BASE_URL="http://[IP已脱敏]:8787"|export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"|' /root/.bashrc

# 4. 当前会话生效
export ANTHROPIC_BASE_URL="https://api.deepseek.com/anthropic"
```

### 紧急终止（代理失控时）

```bash
# 直接杀掉代理进程
kill -9 $(cat /root/.claude/proxy.pid)

# 临时绕过代理（当前会话）
unset ANTHROPIC_BASE_URL
# Claude 会使用默认 API 端点
```

---

## 四、代理日志示例

```
[proxy] POST /v1/messages → 200 (400B, 4780ms)
  ↑ 正常: 请求成功, 400字节响应, 4.8秒

[proxy] Gating thinking request (score=0.75), holding...
  ↑ 门控: 网络不稳(75%), 挂起thinking请求等待稳定

[proxy] Gate passed after 12s (score=0.92)
  ↑ 门控通过: 等12秒后网络稳定(92%), 放行

[proxy] Socket error, retry 1/3 in 1s: ...
  ↑ 重试: socket断了, 1秒后重试

[proxy] POST /v1/messages → 502 after 3 retries: ...
  ↑ 失败: 3次重试全部失败, 返回502给Claude
```

## 五、四道防线说明

```
请求到达代理:
  L0 门控（稳定性检查）
    │  不稳 → 挂起等待(最多90s) → 稳了放行
    │  thinking请求门槛更高(0.9 vs 0.8)
    ▼
  L1 预检（HEAD 探测）
    │  确认服务器可达 → 再发送
    ▼
  L2 连接池 + 心跳
    │  复用连接, 每45s保活, 防NAT超时
    ▼
  L3 透明重试
    │  socket错误自动重试3次(1/3/8s)
    ▼
  返回给Claude
```

## 六、当前会话 vs 新会话

| | 当前正在对话的会话 | 新开的 Claude 会话 |
|--|-------------------|-------------------|
| 走代理? | ❌ 否（启动时URL已固定） | ✅ 是（读取 .zshrc 中的新URL） |
| 如何生效 | 需要 `export ANTHROPIC_BASE_URL=...` 然后新开会话 | 自动 |
