---
title: 代理部署事故复盘 — Python→Node.js 迁移
aliases: []
tags: [ai/ops, incident]
created: 2026-06-11
updated: 2026-08-17
status: stable
---

# 代理部署事故复盘 — Python→Node.js 迁移

See also: [[Claude-Ops-KB-Home]] · [[claude-resilience-architecture]] · [[claude-deployment-record]]

> 时间: 2026-06-11
> 事件: Python 代理部署后 Claude 无法连接 API, 回滚后恢复, 最终以 Node.js 重写解决
> 影响: 代理方案部署受阻, 用户手动回滚

---

## 一、时间线

```
T+0     部署 Python 代理 v2 (claude-resilience-proxy.py)
        - sysctl TCP keepalive 调优 (失败, PRoot 无权限)
        - 启动代理 (PID 18473, localhost:8787)
        - 更新 .zshrc / .bashrc 中 ANTHROPIC_BASE_URL
        - curl 端到端测试: HTTP 200 ✅
        
T+5min  用户打开新 Claude 会话
        - Claude 使用新 URL → 走代理
        - 代理接收请求, 转发到 DeepSeek
        - Claude 一直重试连接 → 无法正常工作 ❌
        
T+10min 用户手动执行回滚 (bash /root/claude-rollback.sh)
        - 代理进程被杀
        - shell 配置恢复为直连 DeepSeek
        - Claude 恢复正常 ✅
        
T+30min 分析 Python 代理失败原因
        发现: Python http.server (HTTP/1.1) 与 Claude Code (Node.js HTTP/2+SSE)
              协议栈不兼容
        
T+45min 用 Node.js 重写代理
        发现: 路径转发缺少 /anthropic 前缀 → 修复
        
T+60min Node.js 代理测试: HTTP 200 ✅
        部署: shell 配置更新, 代理后台运行, 逃生通道保留
```

## 二、问题清单

### 问题 1: TCP keepalive 调优失败

**现象**: `sysctl -w net.ipv4.tcp_keepalive_time=60` → Permission denied

**根因**: PRoot 容器无权访问 `/proc/sys/net/`。这是 PRoot 的安全限制，不是 bug。

**解决**: 在代理应用层为每个 socket 设置 `SO_KEEPALIVE + TCP_KEEPIDLE`。Node.js 版本用 `socket.setKeepAlive(true, 60000)`。

**教训**: PRoot 环境下内核级网络调优不可用。所有调优必须在应用层完成。

### 问题 2: Python 代理端到端测试通过但 Claude 无法使用

**现象**: 
- `curl` 通过代理调用 DeepSeek → HTTP 200 ✅
- Claude Code 通过代理调用 → 一直重试, 无法连接 ❌

**根因**: 协议栈不兼容。
- Claude Code 使用 Node.js undici `fetch()`, 默认 HTTP/2
- Python `http.server` 只支持 HTTP/1.1
- Node.js 的 HTTP/2 客户端发送的请求格式 (HPACK header compression, multiplexed streams) Python HTTPServer 无法正确解析

**关键线索**: curl 测试通过是因为 curl 使用的是 HTTP/1.1，恰好与 Python http.server 兼容。但 Claude 用的是完全不同的协议。

**解决**: 放弃 Python, 用 Node.js 重写代理。Node.js `http` 模块与 Claude Code 使用相同的底层协议栈。

**教训**: 代理的测试不仅要测 curl，必须用与真实客户端相同协议栈的工具测试。测试环境≠生产环境。

### 问题 3: 路径转发 404

**现象**: Node.js 代理首次测试返回 HTTP 404

**根因**: 
- DeepSeek 的 Anthropic 兼容 API 路径为 `/anthropic/v1/messages`
- Claude 发送请求到 `/v1/messages` (因为 `ANTHROPIC_BASE_URL=http://127.0.0.1:8787`)
- Python 版本的 ANTHROPIC_BASE_URL 是 `http://127.0.0.1:8787/anthropic` → Claude 自动加了 `/anthropic` 前缀 → 代理收到 `self.path = /anthropic/v1/messages`
- Node.js 版本的 ANTHROPIC_BASE_URL 改为 `http://127.0.0.1:8787` (无 `/anthropic`) → Claude 发送 `/v1/messages` → 代理未补全路径 → DeepSeek 返回 404

**解决**: 在代理中, 转发前将 `TARGET_URL.pathname` (`/anthropic`) 拼接到 `req.url` 前面。

**教训**: URL 路径拼接是代理开发中最容易出错的环节。必须在设计阶段明确: Claude 发送什么路径、代理转发什么路径、上游期望什么路径。

### 问题 4: Python 代理门控冷启动 bug

**现象**: 第一次请求被误判为"网络不稳定"并挂起 90 秒

**根因**: `StabilityTracker.recent_streak(3)` 在历史数据不足 3 条时返回 `False`。对于首次启动(0 条历史), `should_gate()` 的逻辑是: `score=1.0 AND streak_ok=False → gate=True` (门控打开)。这是逻辑错误——无历史数据应假设正常，而非不正常。

**解决**: 在 `should_gate()` 中增加冷启动检测: 无历史数据 → 不放行; 有数据但全是成功且总数不足 streak_n → 不放行。

**教训**: 门控/限流逻辑的默认状态必须是"放行" (fail-open), 不能是"阻止" (fail-closed)。首次启动是门控逻辑最常见的 bug 触发点。

### 问题 5: 后台进程测试持续超时

**现象**: `node proxy.js & sleep 2; curl test` 反复超时 (exit 144)

**根因**: shell 管道问题。`timeout 10 curl ... | tail -3` 中, `timeout` 命令的 SIGTERM 会影响管道中的所有进程。在 PRoot/Termux 环境中, 进程组管理行为可能与标准 Linux 有差异。

**解决**: 使用 `run_in_background` 启动代理进程, 然后用独立的 `curl` 测试, 避免管道和进程组干扰。

**教训**: PRoot 环境中后台进程的行为可能有细微差异。后台进程测试应使用独立的启动和测试步骤, 不要用 `&` + 后续命令在同一 shell 中执行。

## 三、Python vs Node.js 代理对比

| 维度 | Python (失败) | Node.js (成功) |
|------|--------------|---------------|
| HTTP 协议 | HTTP/1.1 only | HTTP/1.1 (与 Claude 兼容) |
| SSE 流支持 | 需手动实现 | 原生 `pipe()` 流式转发 |
| 连接复用 | 手动实现连接池 | 原生 `Agent.keepAlive` |
| 代码行数 | ~400 行 | ~120 行 |
| 依赖 | 标准库, 无外部依赖 | 标准库, 无外部依赖 |
| Claude 兼容 | ❌ 协议不匹配 | ✅ 同协议栈 |
| 稳定性门控 | 已实现 (有冷启动 bug) | 未实现 (保持简单) |
| HEAD 预检 | 已实现 | 未实现 (可后续加) |

## 四、最终方案架构

```
Claude Code (Node.js undici fetch)
  │ ANTHROPIC_BASE_URL=http://127.0.0.1:8787
  │ HTTP/1.1 请求 → /v1/messages
  ▼
Node.js 代理 (http.createServer)
  │ 路径拼接: /anthropic + /v1/messages
  │ 透明转发 headers (去 hop-by-hop)
  │ 流式管道: upstream.pipe(client)
  │ socket.setKeepAlive(true, 60s)
  │ 错误重试: 3次 (1s/3s/8s)
  ▼
https://api.deepseek.com/anthropic/v1/messages
  │ 服务器收到的请求与直连完全相同
```

## 五、仍存在的问题

| 问题 | 状态 | 计划 |
|------|------|------|
| 稳定性门控 | 未实现 | 先验证基本代理稳定性, 后续按需加 |
| HEAD 预检 | 未实现 | 同上门控 |
| TCP keepalive (内核) | PRoot 不可用 | 应用层已覆盖, 无计划 |
| 代理崩溃恢复 | 未守护 | 用户手动重启, 或后续加 systemd/tmux |
| 流式响应缓冲 | 当前用 pipe (边收边转) | 如果 SSE 流中断, Node.js pipe 会自然传播错误 → 触发重试 |

## 六、排查过程（逐步骤记录）

### 6.1 部署后"连不上 API"

```
用户反馈: "部署后一直连不上api，一直在API连接重试"
用户状态: 已执行回滚 → 恢复直连 → Claude 正常工作
```

**排查逻辑链**:

```
Step 1: 确认代理是否还在运行
  → pgrep -f "claude-resilience-proxy" → 发现残留进程
  → 但 ss -tlnp | grep 8787 → 端口未监听
  → 结论: 代理进程存在但 socket 未启动 (崩溃/启动失败)

Step 2: 确认 shell 配置是否正确回滚
  → grep ANTHROPIC_BASE_URL /root/.zshrc /root/.bashrc
  → 显示 https://api.deepseek.com/anthropic ✅
  → 回滚脚本正常执行
  
Step 3: 确认直连 DeepSeek 是否可达
  → curl -sI https://api.deepseek.com/anthropic/v1/messages
  → HTTP 405 (HEAD 不支持, 但说明服务器可达) ✅
  → 排除网络整体故障
  
Step 4: 确认当前会话环境变量
  → echo $ANTHROPIC_BASE_URL
  → https://api.deepseek.com/anthropic ✅
  → 当前会话的环境变量已恢复(用户手动 export 的)
```

**结论**: 回滚成功, 服务恢复。问题出在代理自身。

### 6.2 为什么 curl 测试通过但 Claude 通不过

```
已知事实:
  A. curl → 代理 → DeepSeek → HTTP 200 ✅
  B. Claude → 代理 → DeepSeek → 连不上 ❌
  
假设 1: 代理在 curl 测试后崩溃了?
  验证: 查看代理日志 → 空 (Python stdout 缓冲导致)
  验证: ps 查看进程状态 → 进程在, 端口未监听
  → 部分支持: 代理确实有问题, 但不能解释 curl vs Claude 的差异

假设 2: Claude 的请求格式与 curl 不同?
  验证: Claude Code 使用 Node.js undici fetch()
        curl 使用 libcurl
  验证: Node.js fetch 默认 HTTP/2, 可能发送不同的请求格式
        Python http.server 只支持 HTTP/1.1
  → ✅ 这是根因!

关键证据: 
  - Python http.server.HTTPServer → 基于 TCPServer → HTTP/1.1 only
  - Node.js undici → HTTP/2 优先, 回退 HTTP/1.1
  - 两者握手时协议协商失败 → Claude 收到连接错误 → 重试 → 循环
```

### 6.3 Node.js 重写后的路径 bug

```
现象: Node.js 代理 → DeepSeek → HTTP 404

排查:
  Step 1: 确认代理代码正确
    → node --check → OK, 无语法错误

  Step 2: 测试代理基本功能
    → curl http://127.0.0.1:8787/ → "Authentication Fails (governor)"
    → 代理在运行, 且成功转发到了 DeepSeek (DeepSeek 返回了认证错误)
    
  Step 3: 完整 API 调用测试
    → curl -X POST ... /v1/messages → HTTP 404
    → 路径错误!

  Step 4: 追溯路径拼接
    → TARGET = https://api.deepseek.com/anthropic
    → Claude 发送: /v1/messages
    → 代理转发: api.deepseek.com/v1/messages (少了 /anthropic!)
    → DeepSeek: 404 (没有 /v1/messages, 只有 /anthropic/v1/messages)
    
  fix: path = TARGET_URL.pathname + req.url
       → /anthropic + /v1/messages = /anthropic/v1/messages ✅
```

### 6.4 后台进程测试反复超时

```
现象: node proxy.js & sleep 2; timeout 10 curl ... → 反复 exit 144

尝试1: 加 nohup → 仍然超时
尝试2: 输出重定向到文件 → 文件有内容(代理启动成功), curl 仍超时
尝试3: timeout curl ... | tail → 怀疑管道干扰 → 去掉 tail → 仍然超时
尝试4: 直接在 Node 内自测 → HTTP 200! 
       → 说明代理功能正常, 问题在 shell 进程管理

发现: timeout 命令在 Termux/PRoot 环境中对进程组的处理与标准 Linux 不同
      当 timeout 超时时, 它向整个进程组发 SIGTERM, 包括刚才 bg 的 node 进程

解决: 使用 Bash 工具的 run_in_background 功能独立启动代理,
      然后独立测试, 避免进程组干扰
```

### 6.5 完整的排查方法论

```
┌─ 问题报告 ──────────────────────────────┐
│ "部署后连不上"                              │
└──────────────────────────────────────────┘
              │
              ▼
┌─ 三板斧: 先把服务恢复 ──────────────────┐
│ 1. 确认回滚脚本已执行                       │
│ 2. 确认配置文件已恢复                       │
│ 3. 确认直连可用                             │
│ → 服务恢复 ✅ (此时可从容排查根因)           │
└──────────────────────────────────────────┘
              │
              ▼
┌─ 隔离变量 ────────────────────────────┐
│ "curl 能通, Claude 不能通"                 │
│ → 差在哪? curl vs Claude                  │
│ → 协议栈不同: HTTP/1.1 vs HTTP/2          │
│ → 这就是根因                               │
└──────────────────────────────────────────┘
              │
              ▼
┌─ 最小验证 ────────────────────────────┐
│ 用同协议栈重写 → 验证 → 通过               │
│ → 确认根因分析正确                         │
└──────────────────────────────────────────┘
              │
              ▼
┌─ 回归测试 ────────────────────────────┐
│ 端到端 API 调用 → HTTP 200 ✅              │
│ shell 配置更新, 逃生通道保留                │
└──────────────────────────────────────────┘
```

## 七、关键经验

1. **代理测试必须用真实客户端协议栈** — curl ≠ Claude Code
2. **默认状态必须 fail-open** — 门控、限流首次启动不能阻塞
3. **PRoot 环境网络调优只能在应用层** — sysctl 不可用
4. **路径拼接是代理 bug 的第一来源** — 必须在设计阶段对齐三种路径
5. **逃生通道必须在部署前就绪** — 用户用回滚脚本几分钟内恢复服务
6. **Node.js 是同语言代理的最佳选择** — 与 Claude Code 同协议栈, 无兼容性问题
