# Proxy cancelRetry Hook 事故复盘

> 日期: 2026-06-22 ~ 2026-06-23 | 影响: 多个会话处于 "resuming conversation" / "处理中" 卡死状态

---

## 一、事故现象

- **Jun 23 08:00** 前后，多个 Claude Code 会话卡在 "resuming conversation" 或首条消息持续"处理中"
- 用户端无任何错误提示，表现为无限等待
- `ps aux` 显示一个 claude 进程处于 **D 状态（disk sleep, `_do_fork`）**，另一个处于空闲 S 状态
- **重启 proxy 后恢复** → 确认代理链路为直接原因

## 二、完整时间线

| 时间 | 事件 |
|------|------|
| Jun 22 14:10 | Session `6df16972` 启动："排查后台另一session的API任务一直处于API error原因" |
| Jun 22 下午 | 在 session 中发现 CC 185 新增 `cancelRetry()` 方法 |
| Jun 22 L431 | **Agent 对 `/root/claude-resilience-proxy.js` 执行 Edit**：添加 request ID 计数器 + `clientReq.on('close')` 诊断 hook |
| Jun 22 L443 | 重启 proxy 使诊断代码生效 |
| Jun 22 L445 | **立即出现故障**：首条请求 "Request timed out" |
| Jun 22 L459 | 后续请求出现 "API Error: ConnectionRefused" |
| Jun 22 L479 | **用户回退 proxy.js**："回退原因是你添加的hook部分会造成原有的proxy通路拥塞导致会话可能不可达等问题" |
| Jun 22 L489+ | Agent 改为构建 **diagnostic-relay**（独立外部中继，零侵入） |
| Jun 23 ~08:00 | 会话恢复时再次出现卡死状态（proxy.js 可能在会话间被再次修改试图 hook cancelRetry） |
| Jun 23 08:10 | proxy.js Modify 时间戳 — 问题版本落盘（**未经过 git 追踪**） |
| Jun 23 08:38 | 回退 proxy.js → 重启 proxy → 链路恢复 |

## 三、根因分析

### 3.1 致命 BUG：`clientReq.on('close')` 竞态条件

问题代码（Edit L431 新增部分）：

```javascript
// [诊断] 检测客户端提前断开 — CC cancelRetry() 的直接证据
clientReq.on('close', () => {
    const elapsed = Date.now() - start;
    if (!clientRes.headersSent) {
        clientClosed = true;
        console.error(`[proxy] #${reqId} CLIENT-CLOSED at ${elapsed}ms`);
    }
});

// 后续在 try 块中:
const result = await doRequest({...}, body, RETRIES);  // ✓ 拿到 DeepSeek 响应
// ⚠️ 'close' 事件可能已在此刻触发 → clientClosed = true

if (!clientClosed) {              // ✗ BUG: 竞态条件下 clientClosed 为 true
    clientRes.writeHead(...);      // ← 跳过
    clientRes.end(result.body);    // ← DeepSeek 响应被静默丢弃
}
```

**`clientReq.on('close')` 并非只在"提前断连"时触发**。Node.js 中该事件在以下情况都会触发：

1. 客户端主动断开 TCP 连接 ✓ （cancelRetry 的目标检测场景）
2. 请求正常完成，HTTP 消息体消费完毕 ✗ （正常流程）
3. 底层 socket 因任何原因关闭 ✗

当 `close` 事件恰好在 `await doRequest()` 返回后、`writeHead()` 之前的窗口触发，`clientClosed = true` 导致合法的 DeepSeek 响应被**静默丢弃**。Claude 端永远收不到 API 响应 → 表现为无限 "处理中"。

### 3.2 架构性错误

```
    Claude Code ──▶ proxy.js ──▶ DeepSeek
                        │
                    单点故障
                    所有会话共用同一通路
```

proxy.js 是**所有会话的唯一 API 通路**。在其内部修改控制流（即使是诊断意图），一旦出错：

- 没有备用通路
- 没有进程级隔离
- 错误表现为"卡死"而非"报错"（响应被丢弃，TCP 连接未断开）

### 3.3 流程性错误

1. **无 git 追踪**：问题版本的修改直接发生在 `/root/claude-resilience-proxy.js`（部署路径），而非通过 workspace → deploy.sh 的受控流程
2. **无备份**：deploy.sh 无 `cp proxy.js proxy.js.bak` 步骤
3. **无隔离测试**：诊断代码在唯一生产通路上直接验证
4. **诊断与控制流混合**：`console.error`（诊断）与 `if (!clientClosed)`（控制流）混在同一改动中

## 四、恢复操作

1. 从 workspace 恢复正确版本：`cp ~/workspace/claude-code-knowledge/claude-resilience-proxy.js /root/claude-resilience-proxy.js`
2. 重启 proxy 进程
3. 验证：`curl -sI http://[IP已脱敏]:8787/` 返回正常
4. 确认会话恢复

## 五、教训与规则

### 5.1 硬规则（追加到行动前检查清单）

| # | 规则 |
|---|------|
| 1 | **禁止在部署路径直接编辑生产文件**。所有修改通过 workspace → deploy.sh 流程 |
| 2 | **诊断日志 ≠ 控制流修改**。诊断代码只能 `console.error`，不能引入 `if/else` 分支改变响应路径 |
| 3 | **单点通路的修改必须有逃生通道**。在唯一代理上验证前，先确保 rollback 脚本可用 |
| 4 | **修改前 git commit 当前状态**。确保 `git diff HEAD` 能精确显示改动内容 |
| 5 | **重启代理前验证语法**：`node --check proxy.js && timeout 5 node -e "require('./proxy.js')"` 确保能启动 |
| 6 | **修改代理后先 curl 验证**再让 Claude 会话使用：`curl -s -X POST http://[IP已脱敏]:8787/v1/messages ...` |

### 5.2 正确的诊断架构

```
Claude Code → permafrost :8788 → relay :8789 → proxy :8787 → DeepSeek
                                    │
                              独立外部观察者
                              纯管道转发，零字节修改
                              带 /rollback.sh 逃生
```

`diagnostic-relay` 是正确方向：透明 TCP 中继，不解析/不修改任何字节，记录时间戳后原样转发。

### 5.3 文件部署规程

```bash
# 正确流程
cd ~/workspace/claude-code-knowledge
git add claude-resilience-proxy.js
git commit -m "fix: 描述改动"
cp claude-resilience-proxy.js /root/claude-resilience-proxy.js.$(date +%s).bak  # 备份
cp claude-resilience-proxy.js /root/claude-resilience-proxy.js                   # 部署
node --check /root/claude-resilience-proxy.js                                     # 验证
# 重启 proxy
# curl 验证
```

## 六、相关文件

| 文件 | 说明 |
|------|------|
| `/root/claude-resilience-proxy.js` | 部署路径（事故目标） |
| `~/workspace/claude-code-knowledge/claude-resilience-proxy.js` | 受控版本（md5 一致已回退） |
| `~/workspace/claude-code-knowledge/diagnostic-relay/` | 正确的诊断方案（外部中继） |
| `~/workspace/claude-code-knowledge/claude-proxy-restart-incident.md` | 前次 proxy 重启事故复盘 |
| Session `6df16972` | 事故发生会话（`claude --resume` 可查看完整对话） |

## 七、版本追踪状态

- **问题版本**：未被 git 追踪，已丢失（仅能从 session transcript 还原改动内容）
- **当前版本**：md5 `88ef3fe2a6f5348f160981ec3c8087a5`，与 workspace 一致
- **最近提交**：`eac4572 feat: 零中断重启 + SO_REUSEPORT + 备用端口滚动`
