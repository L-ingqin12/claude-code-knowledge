---
title: 网络中断无感方案设计
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-07-01
updated: 2026-08-17
status: deprecated
---

# 网络中断无感方案设计

> [!warning] 此文档已废弃，请参考 [[claude-network-resilience-v2]]

See also: [[Claude-Ops-KB-Home]] · [[claude-network-resilience-v2]] · [[claude-network-stability-gate]]

> 聚焦场景：网络中断导致的 Claude 会话崩溃。
> 目标：用户无需输入「继续」或任何关键字，系统自动恢复。
> 非目标：手机重启、Termux 被杀、API key 过期 — 这些作为遗留项。

---

## 一、网络中断的三种形态与覆盖目标

```
形态① 瞬时抖动 (< 3s)
  示例: 丢包、基站切换一瞬间、WiFi 信号波动
  目标: 用户完全无感，Claude 不中断
  机制: 代理自动重试

形态② 短断网 (3-120s)  
  示例: 电梯里没信号、WiFi 重新认证
  目标: 用户无感，Claude 短暂停顿后自动继续
  机制: 代理重试耗尽 → Claude 退出 → 守护检测 → 自动拉起恢复

形态③ 长断网 (> 120s)
  示例: 进入地下车库、飞行模式、DeepSeek 服务宕机
  目标: 网络恢复后自动继续，用户无需手动重启
  机制: 守护检测网络恢复 → 自动拉起 Claude → 从 context-dump 继续
```

---

## 二、之前设计的三个缺口

### 缺口 1：代理 502 后 Claude 的行为不明

**问题**：代理重试 3 次耗尽后返回 HTTP 502。Claude Code 收到 502 后的行为是什么？

```
已知: Claude Code 底层使用 Anthropic Node SDK 调用 API
SDK 行为猜测:
  - HTTP 4xx → 可能作为客户端错误抛出
  - HTTP 5xx → 可能触发 SDK 自带重试，也可能直接抛出
  - Socket 错误 → 直接抛出 "socket closed unexpectedly"

未知: 代理返回的 502 被 SDK 视为什么？
  如果是应用层错误 → Claude 可能优雅处理（显示错误但继续等待）
  如果是连接层错误 → Claude 可能直接崩溃
```

**设计决策**：不依赖对 Claude 内部行为的猜测。**在代理层将该处理的都处理掉，尽量不让 502 到达 Claude。**

具体做法：代理在返回 502 之前，**额外增加一轮更激进的重试**——延长超时、切换 IP 解析、使用 HTTP/1.1 回退。

### 缺口 2：守护脚本 crash-loop

**问题**：如果网络持续中断，守护脚本会不断尝试启动 Claude → Claude 立即因网络不通而崩溃 → 守护再次启动 → 无限循环。

```
crash-loop:
  T+0:  守护尝试启动 Claude
  T+5:  Claude 调用 API → 网络不通 → 崩溃
  T+35: 守护检测到崩溃 → 再次启动
  T+40: Claude 再次崩溃
  ...无限循环，每次浪费 API 调用（即使失败也可能计费）
```

**解决方案**：守护在启动 Claude 之前，**先检测网络连通性**。不通就不启动，用短间隔轮询等待网络恢复。

```bash
# 守护脚本中增加网络预检
check_network() {
    # 检测目标 API 是否可达
    curl -sI --connect-timeout 5 --max-time 10 \
        "https://api.deepseek.com/anthropic/v1/messages" \
        -H "Authorization: Bearer $ANTHROPIC_API_KEY" \
        > /dev/null 2>&1
    return $?
}

# 启动 Claude 前
if ! check_network; then
    log "Network down, waiting..."
    sleep 30   # 短间隔轮询（网络恢复通常在 30-120s 内）
    continue   # 不启动 Claude，回到循环开头
fi

# 网络通了才启动
start_claude_with_recovery
```

效果：
```
网络中断时:
  守护: "网络不通，等 30s..."
  守护: "网络不通，等 30s..."
  守护: "网络不通，等 30s..."
  网络恢复 →
  守护: "网络通了，启动 Claude 恢复任务"
  → Claude 启动，读取 context-dump，继续工作

没有 crash-loop，没有浪费的 API 调用。
```

### 缺口 3：`--resume` 能否真正恢复对话上下文

**问题**：之前设计假设 `claude --resume` 能恢复对话状态。但实际测试：

```bash
# --resume 做了什么？
# 从 session 文件恢复: cwd, shell env, history 文件路径
# 不恢复: 对话内容（需要重新发送 prompt）
```

**验证过的行为**：
- `claude --resume` 恢复 shell 环境（cwd, env vars）
- 不会自动重新发送之前的 prompt
- Claude 以空白上下文启动，只是"知道自己在哪个目录"

**这意味着**：即使守护用 `--resume` 成功拉起 Claude，Claude 也不记得之前在做任务。

**解决方案**：放弃依赖 `--resume` 恢复上下文。改用 **「新会话 + 恢复 Prompt 注入」** 模式：

```bash
# 不是这样:
claude --resume --session-id xxx

# 而是这样:
claude -p "网络中断后恢复。读取 /root/.claude/context-dump.md 了解之前的思维状态，
读取 /root/.claude/task-state.json 了解任务进度。
从第一个 pending 步骤继续。禁止推翻已有的 Decisions。" \
  --permission-mode accept-edits
```

这比 `--resume` 更可靠，因为：
- 不依赖 session 文件的完整性
- 恢复 prompt 直接告诉 Claude 该怎么做
- context-dump.md 提供了比对话历史更精确的恢复信息
- 如果 context-dump 和 task-state 都在，恢复质量与 `--resume` 相同甚至更好

---

## 三、完整恢复链路（仅网络中断场景）

### 3.1 精确时间线

```
正常执行中:
  T-60s  Claude 完成步骤 2
         → 更新 task-state.json: {"completed": [1,2], "pending": [3,4,5]}
         → 更新 context-dump.md: Mental Model + Decisions + Key Findings
  T-58s  Claude 开始步骤 3
  T-55s  Claude 通过代理发送 API 请求

网络中断发生:
  T-50s  WiFi 断开 / 基站切换
  T-50s  代理检测到 socket 错误 (请求发送中或响应接收中)
  T-50s  代理第 1 次重试 (等 1s)
  T-51s  仍然不通
  T-51s  代理第 2 次重试 (等 3s)  
  T-54s  仍然不通
  T-54s  代理第 3 次重试 (等 8s)
  T-62s  仍然不通 → 代理返回 502

Claude 崩溃:
  T-62s  Claude 收到 502 → 进程退出 (exit code ≠ 0)
  T-62s  Claude 进程不再运行

守护检测:
  T-92s  守护例行检查 (每 30s)
         → 发现 session 文件状态异常 / PID 不存在
         → 状态: "进程死了，网络中断导致"
         
网络预检:
  T-92s  守护: curl 检查 api.deepseek.com → 不通
         → 进入等待循环
  T-122s 守护: curl 检查 → 不通
  T-152s 守护: curl 检查 → 通了！
         → 准备恢复

自动恢复:  
  T-152s 守护构建恢复 prompt
  T-153s 守护启动: claude -p "$RECOVERY_PROMPT" --permission-mode accept-edits
  
  Claude 恢复流程:
    T-153s  读取 context-dump.md
            → 恢复 Mental Model: "这是 gomoku 难度选择任务"
            → 恢复 Decisions: "用方案A(限制深度)，不用B(多套评估函数)"
            → 恢复 Key Findings: "game.py:142 是唯一 AI 调用点"
    T-154s  读取 task-state.json  
            → 已完成: 步骤1(分析), 步骤2(修改ai.py)
            → 待完成: 步骤3(修改game.py), 步骤4(测试), 步骤5(提交)
    T-155s  验证 Key Findings 中的锚点 (game.py:142 是否还是之前的代码)
    T-156s  开始执行步骤 3
    T-156s  任务继续，就像什么都没发生

用户视角:
  T-153s 之前: Claude 停顿约 90 秒（网络中断→恢复）
  T-153s 之后: Claude 自动继续执行，输出恢复
  用户需要做的: 0
  ✅ 中断无感（有一个停顿，但不需要用户输入"继续"）
```

### 3.2 数据流图

```
            ┌─────────────────────────────────────┐
            │         claude-resilience-proxy      │
            │  ┌─────────────────────────────┐    │
请求 ──────→│  │ try: fetch(upstream)         │    │
            │  │ except SocketError:          │    │
            │  │   retry(backoff=1,3,8s)      │    │
            │  │   if all_failed:             │    │
            │  │     retry_aggressive()        │    │
            │  │     if still_failed:         │    │
            │  │       return 502              │    │
            │  └─────────────────────────────┘    │
            └──────────────┬──────────────────────┘
                           │
              ┌────────────▼──────────────────────┐
              │      Claude Code                   │
              │  收到 502 → 进程可能退出             │
              └────────────┬──────────────────────┘
                           │
              ┌────────────▼──────────────────────┐
              │      claude-guardian.sh            │
              │  ┌─────────────────────────────┐  │
              │  │ loop:                        │  │
              │  │   if session_dead():         │  │
              │  │     if !check_network():     │  │
              │  │       sleep(30), continue    │  │
              │  │     build_recovery_prompt()  │  │
              │  │     claude -p "$PROMPT"      │  │
              │  │       --accept-edits         │  │
              │  │     reset_restart_counter()  │  │
              │  │   sleep(30)                  │  │
              │  └─────────────────────────────┘  │
              └───────────────────────────────────┘
```

---

## 四、守护脚本 — 网络中断专用版

```bash
#!/bin/bash
# /root/claude-network-guardian.sh
# 网络中断场景专用守护：检测→等待网络→自动恢复
# 部署: nohup /root/claude-network-guardian.sh > /root/.claude/guardian.log 2>&1 &

GUARDIAN_LOG="/root/.claude/guardian.log"
TASK_STATE="/root/.claude/task-state.json"
CONTEXT_DUMP="/root/.claude/context-dump.md"
RECOVERY_HEADER="/root/.claude/resume-prompt-header.txt"
CHECK_INTERVAL=30       # 30s 检查一次 session 存活
NETWORK_RETRY=30         # 网络不通时 30s 重试
API_CHECK_URL="https://api.deepseek.com/anthropic/v1/messages"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$GUARDIAN_LOG"; }

check_network() {
    # 检测目标 API 是否可达（只需要 TCP+TLS 握手成功即可）
    curl -sI --connect-timeout 5 --max-time 10 "$API_CHECK_URL" > /dev/null 2>&1
}

build_recovery_prompt() {
    local prompt="⚠️ 会话因网络中断恢复。你不是在开始新任务——你在接续一个正在进行的任务。

## 恢复流程（严格按顺序）

### 第一步：加载外部大脑
读取 $CONTEXT_DUMP。
你将获得: Mental Model（代码库理解）、Decisions（已做的决策及理由——禁止推翻）、
Key Findings（费力发现的信息，带 file:line 锚点）、Assumptions（尚待验证的假设）。

### 第二步：加载任务状态
读取 $TASK_STATE。
确认当前步骤和待完成步骤。只做未完成的。已完成的一定不要重做。

### 第三步：验证锚点
快速检查 Key Findings 中提到的 file:line 是否仍然正确。

### 第四步：继续执行
从 task-state.json 的第一个 pending 步骤继续。
严格遵循 context-dump.md 中的 Decisions——不要重新决策。
利用 Mental Model 中的理解——不要重新分析整个代码库。

## 关键规则
1. 禁止推翻 Decisions 表中的任何决策（除非发现新信息明确证明其错误）
2. 禁止重读 Key Findings 中已覆盖的文件——信任之前分析的结果
3. 每完成一个步骤，同时更新 task-state.json 和 context-dump.md"

    echo "$prompt"
}

# ── 主循环 ──
log "Network Guardian started (PID $$)"

while true; do
    # 找最新交互式 session
    LATEST_SESSION=$(ls -t /root/.claude/sessions/*.json 2>/dev/null | head -1)
    
    if [ -z "$LATEST_SESSION" ]; then
        sleep "$CHECK_INTERVAL"
        continue
    fi
    
    # 解析 session 状态
    SESSION_ID=$(basename "$LATEST_SESSION" .json)
    PID=$(python3 -c "import json; print(json.load(open('$LATEST_SESSION')).get('pid',0))" 2>/dev/null)
    STATUS=$(python3 -c "import json; print(json.load(open('$LATEST_SESSION')).get('status','unknown'))" 2>/dev/null)
    
    # 进程活着 → 正常
    if [ -n "$PID" ] && [ "$PID" != "0" ] && kill -0 "$PID" 2>/dev/null; then
        sleep "$CHECK_INTERVAL"
        continue
    fi
    
    # ── 进程死了 → 网络中断导致？──
    log "Session $SESSION_ID dead (PID $PID gone, was $STATUS)"
    
    # 第一步：等网络恢复
    log "Waiting for network to recover..."
    while ! check_network; do
        sleep "$NETWORK_RETRY"
    done
    log "Network is back!"
    
    # 第二步：如果有状态文件，构建恢复 prompt
    if [ -f "$TASK_STATE" ] || [ -f "$CONTEXT_DUMP" ]; then
        RECOVERY_PROMPT=$(build_recovery_prompt)
        log "Launching Claude with recovery prompt..."
        claude -p "$RECOVERY_PROMPT" --permission-mode accept-edits 2>&1
        log "Claude recovery session ended (exit=$?)"
    else
        log "No state files found, cannot auto-recover. Manual intervention needed."
        # 可选：发送通知
    fi
    
    sleep "$CHECK_INTERVAL"
done
```

---

## 五、达成条件清单

要使网络中断场景做到「中断无感」，以下组件必须全部部署：

| # | 组件 | 作用 | 部署方式 |
|---|------|------|----------|
| 1 | `sysctl tcp_keepalive_time=60` | 减少 NAT 空闲断连概率 | 一次性命令 |
| 2 | `claude-resilience-proxy.py` | 吸收瞬时 socket 错误（形态①） | `nohup python3 ... &` |
| 3 | `ANTHROPIC_BASE_URL=http://[IP已脱敏]:8787/anthropic` | 让 Claude 走代理 | `export` 或 shell 配置 |
| 4 | `claude-network-guardian.sh` | 检测崩溃+等网络+自动恢复（形态②③） | `nohup bash ... &` |
| 5 | `resume-prompt-header.txt` | 恢复时注入的正确 prompt | 写入文件 |
| 6 | `task-state.json` + `context-dump.md` | Claude 执行任务时自动维护 | prompt 中嵌入规则 |

### 达成后的效果矩阵

| 网络中断场景 | 中断时长 | Claude 行为 | 用户体验 |
|-------------|----------|------------|----------|
| 瞬时丢包 | < 1s | 代理重试，Claude 不感知 | 完全无感 ✅ |
| 基站切换 | 1-3s | 代理重试，Claude 不感知 | 完全无感 ✅ |
| WiFi 断连重连 | 5-30s | 代理耗尽→502→Claude退出→守护等网络→自动恢复 | 有 30-90s 停顿，但不需操作 ✅ |
| 电梯/地下 | 1-5 min | 守护等网络恢复→自动拉起→读取状态→继续 | 网络恢复后自动继续 ✅ |
| 长时间断网 | >10 min | 守护持续等待网络→网络恢复后自动继续 | 网络恢复后自动继续 ✅ |

### 遗留项（本方案不覆盖）

| 场景 | 原因 |
|------|------|
| 手机重启 | Termux 进程全死，且无开机自启机制 |
| Termux 被系统杀掉 | Android 内存管理，需配合 wake-lock + 电池白名单 |
| API key 过期 | 需外部监控 key 状态 |
| Claude 卡死（不崩溃） | 需 watchdog 超时检测，不是网络问题 |
| 守护脚本自身崩溃 | 需 systemd/cron 兜底（环境不支持） |

---

## 六、总结

```
网络中断场景的终极答案:

  形态① (瞬时) → 代理层吸收 → 0 秒停顿 → 无感
  形态② (短断) → 代理耗尽→守护等网→自动恢复 → 30-90s 停顿 → 无感(不需操作)
  形态③ (长断) → 守护持续等→网通后自动恢复 → 网通后继续 → 无感(不需操作)

  用户需要做的: 零。不需要输入「继续」或任何关键字。
  
  前提: 六项组件全部部署。
  代价: 形态②③会有几十秒到几分钟的停顿（等待网络恢复的时间）。
```
