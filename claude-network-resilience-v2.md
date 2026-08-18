# 网络中断无感 v2 — 基于实际场景的修正

> 修正前提：Claude 对话不退出，只是报错后停住等用户输入。
> 之前设计的进程守护/--resume/崩溃检测→全部不需要。

---

## 一、实际场景还原

```
T+0s    Claude 执行工具完毕，发下一个 API 请求
T+1s    请求通过代理 → api.deepseek.com
T+2s    网络抖动，socket 断开
T+2s    Claude 终端输出:
        "Error: The socket connection was closed unexpectedly.
         For more information, pass `verbose: true`..."
T+2s    Claude 会话状态: idle（等待下一个用户输入）
T+2s    用户看到报错 → 输入"继续"或重发上次 prompt
T+3s    Claude 重新发 API 请求 → 通常这次就成功了
```

**关键事实**：
- 进程没死（`kill -0 $PID` 返回 0）
- Session 文件状态变为 `idle`
- 只需要有人替用户输入"重试"——这就是「中断无感」的全部

## 二、两条解决路径

```
路径 A: 让错误不发生
  代理在 socket 错误到达 Claude 之前拦截并重试
  优点: Claude 感知不到任何错误，完全无感
  代价: 需要运行一个本地代理进程

路径 B: 错误发生后自动重试
  检测到 Claude 因 socket 错误进入 idle → 自动注入"重试"指令
  优点: 不改变 Claude 的网络路径
  代价: 需要向 Claude 会话注入输入的机制
```

## 三、路径 A — 代理拦截（推荐，简单可靠）

此路径之前已完整设计，无需修改。代理在 socket 层重试，Claude 感知不到：

```
之前: Claude → fetch("https://api.deepseek.com/...") → socket error → 报错停止
之后: Claude → fetch("http://[IP已脱敏]:8787/...") → 代理 → 上游
                                                   → socket error 
                                                   → 代理自动重试(1/3/8s)
                                                   → 成功 → 返回给 Claude
      Claude 视角: 一次正常的 API 调用，没有任何错误
```

**只需部署两件事：**
```bash
# 1. 启动代理
nohup python3 /root/claude-resilience-proxy.py > /root/.claude/proxy.log 2>&1 &

# 2. 让 Claude 走代理
export ANTHROPIC_BASE_URL=http://[IP已脱敏]:8787/anthropic
claude --permission-mode accept-edits
```

**覆盖范围：** 代理重试超时窗口内的所有 socket 错误（重试最长 1+3+8=12 秒）。手机网络瞬时抖动通常在 3 秒内恢复 → 代理一次重试就成功 → Claude 完全无感。

## 四、路径 B — 自动注入重试（兜底，代理失败时用）

如果代理所有重试都失败了（连续断网 > 12 秒），错误还是会到达 Claude。此时 Claude 报错→停住→等待输入。

**解决方案：监控 Claude 的 stdout，检测到报错模式时，通过 stdin 注入重试指令。**

### 4.1 原理

```
┌──────────────────┐
│ 监控脚本          │ ← 独立进程，tail Claude 的输出
│ 检测到:          │
│ "socket conn..." │ → 触发: 向 Claude 的 stdin 写入 "请重试上次的请求"
│ 或 session idle  │
└──────────────────┘
```

但直接操作另一个进程的 stdin/stdout 在 PRoot 环境下很麻烦。更可行的方式：

### 4.2 利用 session 文件 + daemon

Claude Code daemon 管理所有 session。当一个 session 从 `busy` 变为 `idle`，且最后的输出包含错误关键词时，可以通过 daemon 向该 session 注入消息：

```bash
# 监控脚本逻辑
while true; do
    for session_file in /root/.claude/sessions/*.json; do
        SESSION_ID=$(basename "$session_file" .json)
        STATUS=$(python3 -c "import json; print(json.load(open('$session_file'))['status'])" 2>/dev/null)
        
        # 如果从 busy 变为 idle 且之前是 busy
        if [ "$STATUS" = "idle" ] && [ "$PREV_STATUS" = "busy" ]; then
            # 可能是报错停止 → 自动注入重试
            # 方式: 启动 claude --resume --session-id $SESSION_ID -p "重试上次操作"
            # 这会在同一个 session 环境下重新发送 prompt
            sleep 2  # 给一点时间让错误完全输出
            claude --resume --session-id "$SESSION_ID" \
                --permission-mode accept-edits \
                -p "重试你上一个被网络中断打断的操作。不要重新分析，直接继续。"
        fi
        PREV_STATUS="$STATUS"
    done
    sleep 5
done
```

**但这有个问题：** 路径 B 实际上创建了一个新的 Claude 进程来做恢复，有点过度。而且如果网络还没恢复，这个新进程也会失败。

### 4.3 更简单的方式：代理返回重试指令

让代理在所有重试失败后，不返回 502，而是返回一个**特殊结构的 JSON 响应**，其中包含一个 `retry_after` 指令。Claude 收到这个 JSON 后（如果它被当作正常的 API 响应），会自然地在对话中显示出来，然后 Claude 可以自己决定重试。

但这依赖于 Claude 如何解析代理返回的 502。这个太难控制。

## 五、结论：只用路径 A 就够

对于「Claude 不崩溃，只是报错停住」的实际场景，**路径 A（代理拦截）是唯一需要的方案**。

```
理由:
1. 网络抖动通常 < 3s → 代理第一次重试(1s)就成功 → Claude 无感
2. 网络短断 < 12s → 代理三次重试覆盖 → Claude 无感
3. 网络长断 > 12s → 代理返回 502 → Claude 报错停住 → 仍需用户输入"继续"
   
   但这种情况（连续断网 > 12s）的概率远低于瞬时抖动。
   而且一旦网络恢复，用户输入"继续"后 Claude 立刻就能继续工作。
   
   如果连这个也要消除 → 代理加一个"无限重试"模式：
   当检测到连续 socket 错误时，不退 502，而是持续重试直到成功。
   代价: Claude 的请求会 hang 住，可能触发 Claude 自身的超时。
```

## 六、最终方案（极简版）

| 组件 | 之前设计 | 修正后 |
|------|----------|--------|
| TCP keepalive | ✅ 保留 | ✅ 保留（减少 NAT 断连概率） |
| 韧性代理 | ✅ 保留 | ✅ **核心组件** |
| ANTHROPIC_BASE_URL | ✅ 保留 | ✅ 指向代理 |
| 守护脚本 | ❌ 移除 | **不需要**！Claude 不会死，不需要 restart |
| --resume 机制 | ❌ 移除 | **不需要**！会话还在，不需要恢复 |
| context-dump.md | ⚠️ 降级 | 仍然有用（如果用户手动重启），但不是网络中断场景的必需品 |
| task-state.json | ⚠️ 降级 | 同上 |

**网络中断无感 = 代理拦截 + TCP keepalive。就这俩。**

## 七、部署即完结

```bash
# 第一步：内核 TCP 调优（减少断连概率）
sysctl -w net.ipv4.tcp_keepalive_time=60
sysctl -w net.ipv4.tcp_keepalive_intvl=10
sysctl -w net.ipv4.tcp_keepalive_probes=3

# 第二步：启动代理
nohup python3 /root/claude-resilience-proxy.py > /root/.claude/proxy.log 2>&1 &

# 第三步：启动 Claude（走代理）
ANTHROPIC_BASE_URL=http://[IP已脱敏]:8787/anthropic \
  claude --permission-mode accept-edits

# 完成。网络抖动不再需要你输入"继续"。
```

## 八、遗留项

这些场景仍需要手动介入，作为已知限制：

| 场景 | 为什么代理搞不定 |
|------|-----------------|
| 连续断网 > 12 秒 | 代理重试耗尽，错误到达 Claude |
| 代理进程自身崩溃 | 没有守护代理的守护 |
| DeepSeek 服务宕机 | 不是 socket 错误，是应用层错误 (5xx) |
