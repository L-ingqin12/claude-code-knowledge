---
title: Claude Code 中断恢复方案
aliases: []
tags: [ai/ops, ai/agent]
created: 2026-07-01
updated: 2026-08-17
status: review
---

# Claude Code 中断恢复方案

See also: [[Claude-Ops-KB-Home]] · [[claude-context-continuity-guide]] · [[claude-unattended-operation-plan]]

> 目标：在 API socket 断开等网络中断场景下，让 Claude 以最低开销无缝接续被中断的任务

---

## 一、问题分析

### 1.1 中断发生时发生了什么

```
正常流程:
  Claude 发起 API 请求 → 模型生成 → 返回结果 → Claude 执行工具 → 继续

中断场景:
  Claude 发起 API 请求 → ⚡ Socket closed unexpectedly → Claude 报错退出
  
  后果:
  ✗ 当前会话上下文丢失（不经过正常退出，没有保存）
  ✗ 正在执行的任务进度归零
  ✗ 下次启动时 Claude 不知道之前做到哪了
  ✗ 所有文件都要重新读、所有分析都要重新做 = Token 浪费
```

### 1.2 当前环境的脆弱性

```
你的运行环境:
  Android (手机网络) → Termux → PRoot → Claude Code
  
  特有风险:
  - 手机网络切换 (WiFi ↔ 蜂窝) 会重置 TCP 连接
  - 运营商 NAT 超时比固网更短
  - Android 的 Doze 模式可能延迟/丢弃后台数据包
  - PRoot 层的网络栈多一层间接性
  - API 到海外 (api.anthropic.com) 的跨境链路更长、丢包率更高
```

### 1.3 Claude Code 已有的恢复机制（及局限）

| 机制 | 做什么 | 局限 |
|------|--------|------|
| `claude --resume` | 恢复之前的会话 | 只恢复了 **shell 环境**，不恢复**任务上下文** |
| Session checkpoints | 保存 cwd/env/shell 状态 | 不保存"正在做什么任务" |
| Daemon 自动重启 | 二进制变更后自动拉起 | 不对应网络中断 |
| `history.jsonl` | 完整对话记录 | ❌ 不用于恢复——resume 不会 replay history |
| `scheduled_tasks.json` | 定时任务持久化 | 只存 prompt 字符串，不存中间状态 |

**核心缺口**：没有任何机制把 **"任务做到哪里了"** 持久化到文件系统中。

---

## 二、解决方案总览

```
┌─────────────────────────────────────────────────────────────┐
│  第 3 层: 外部守护 — 检测中断 → 自动重启 → 注入恢复 prompt │
│  第 2 层: 任务结构 — 原子步骤 + 外部状态 + 幂等设计        │
│  第 1 层: Session 恢复 — claude --resume + checkpoint       │
└─────────────────────────────────────────────────────────────┘
```

三层互补：第 1 层处理最好的情况（会话还能 resume），第 2 层是核心——确保即使 resume 失败，重建上下文的成本也极低，第 3 层确保无人值守时中断了能自动拉起来。

---

## 三、第 1 层 — Session 恢复（最优路径）

### 3.1 原理

网络中断有两种结果：
- **A**: Claude 进程崩溃退出，但 session 文件完整 → `--resume` 可用
- **B**: 进程还在但卡死 → 需要 kill 后再 resume
- **C**: session 文件损坏 → 只能走第 2 层方案

### 3.2 自动检测和恢复脚本

```bash
#!/bin/bash
# /root/auto-resume-claude.sh
# 放在外部 cron 或 while 循环中，定期检查 claude session 是否还活着

RESUME_LOG="/root/.claude/resume.log"
SESSION_DIR="/root/.claude/sessions"

# 找到最近的 session
LATEST_SESSION=$(ls -t "$SESSION_DIR"/*.json 2>/dev/null | head -1)

if [ -z "$LATEST_SESSION" ]; then
    echo "[$(date)] No sessions found, starting new one" >> "$RESUME_LOG"
    claude --permission-mode accept-edits
    exit 0
fi

# 解析 session 状态
SESSION_ID=$(basename "$LATEST_SESSION" .json)
STATUS=$(python3 -c "import json; print(json.load(open('$LATEST_SESSION'))['status'])" 2>/dev/null)
PID=$(python3 -c "import json; print(json.load(open('$LATEST_SESSION'))['pid'])" 2>/dev/null)

echo "[$(date)] Session $SESSION_ID status=$STATUS pid=$PID" >> "$RESUME_LOG"

# 如果进程不在了，但 session 文件说 busy → 崩溃
if ! kill -0 "$PID" 2>/dev/null; then
    echo "[$(date)] Session $SESSION_ID is dead (PID $PID gone), attempting resume..." >> "$RESUME_LOG"
    
    # 检查是否有上次任务的状态文件（第 2 层方案）
    TASK_STATE="/root/.claude/task-state.json"
    if [ -f "$TASK_STATE" ]; then
        RESUME_PROMPT=$(python3 -c "
import json
state = json.load(open('$TASK_STATE'))
print(f'之前的任务「{state[\"task_name\"]}」在步骤 {state[\"current_step\"]}/{state[\"total_steps\"]} 时中断。'
      f'已完成步骤: {\", \".join(state[\"completed\"])}。'
      f'请从步骤「{state[\"pending\"][0] if state[\"pending\"] else \"完成收尾\"}」继续。'
      f'上下文摘要: {state.get(\"context\", \"\")}')
" 2>/dev/null)
        claude --resume --session-id "$SESSION_ID" --permission-mode accept-edits -p "$RESUME_PROMPT"
    else
        claude --resume --session-id "$SESSION_ID" --permission-mode accept-edits
    fi
else
    echo "[$(date)] Session $SESSION_ID is alive (PID $PID), status=$STATUS" >> "$RESUME_LOG"
fi
```

### 3.3 在 daemon 健康检查中使用

```bash
# crontab 或 systemd timer，每 5 分钟检查一次
*/5 * * * * /root/auto-resume-claude.sh
```

---

## 四、第 2 层 — 任务结构化（核心方案）

### 4.1 核心思想

**不要让 Claude 把任务进度只记在"脑子"里。让它在每个步骤边界，把进度写入一个状态文件。**

```
传统方式（脆弱）：
  Claude 在大脑中说 "我要做 A→B→C→D"
  做 A 时中断 → 回到起点，重做 A

结构化方式（鲁棒）：
  Claude 读取 task-state.json → 发现 A 已完成 → 直接做 B
  中断发生在 B → 恢复后读到 B 未完成 → 只重做 B
```

### 4.2 任务状态文件格式

```json
{
  "task_name": "gomoku Python 3.7 兼容性升级",
  "created_at": "2026-06-11T10:00:00+08:00",
  "updated_at": "2026-06-11T10:15:30+08:00",
  "status": "in_progress",
  "current_step": 2,
  "total_steps": 5,
  "completed": [
    {
      "step": 1,
      "description": "分析代码，找出所有 Python 3.8+ 语法",
      "result": "发现 5 个 walrus operator 用法，3 个 f-string = 用法",
      "verified_by": "grep 确认"
    }
  ],
  "pending": [
    {"step": 2, "description": "修改 game.py 中的 walrus operator"},
    {"step": 3, "description": "修改 ai.py 中的 f-string = 语法"},
    {"step": 4, "description": "运行测试套件验证"},
    {"step": 5, "description": "提交并推送"}
  ],
  "context": {
    "repo": "/root/workspace/gomoku_37",
    "branch": "feature/py37-compat",
    "python_version": "3.7.17",
    "last_file_edited": "/root/workspace/gomoku_37/game.py",
    "last_line": 142
  },
  "checkpoint_files": [
    "/root/workspace/gomoku_37/game.py.bak.20260611",
    "/root/workspace/gomoku_37/ai.py.bak.20260611"
  ]
}
```

### 4.3 工作流程

```
STEP 1: 任务开始
  Claude 读 task-state.json → 不存在 → 创建新的任务计划
  写入 task-state.json（所有步骤标记为 pending）
  Claude 在自己的回复中确认任务计划

STEP 2: 执行步骤 1
  Claude 完成步骤 1 → 立即更新 task-state.json
  将步骤 1 从 pending 移到 completed
  将 current_step 更新为 2

STEP 3: 执行步骤 2
  ...中断发生！

STEP 4: 恢复
  外部守护检测到会话挂了
  重新启动 claude --resume
  Claude 首先读 task-state.json
  发现步骤 1 已完成，步骤 2 未开始
  直接从步骤 2 继续
  只重做了上一步（最多几百 tokens），而不是全部重来
```

### 4.4 Prompt 注入模式

**每次启动无人值守任务时，在 prompt 中嵌入状态管理指令：**

```markdown
## 任务管理规则（必须遵守）

1. **每个步骤开始前**：读取 /root/.claude/task-state.json，了解当前进度
2. **每个步骤完成后**：立即更新 task-state.json，将完成的步骤标记为 completed
3. **如果 task-state.json 不存在**：创建它，列出完整的任务分解（每步必须是原子化、幂等的、可独立验证的）
4. **每个步骤必须可独立验证**：完成后要能用一条命令（如 grep/diff/test）确认该步骤已生效
5. **文件修改前先备份**：保存到同名文件 + .bak 后缀
6. **中断恢复时**：先读 task-state.json，只做未完成的步骤，已完成的一定不要重做

你的实际任务是：
<实际任务描述插入此处>
```

### 4.5 幂等步骤设计原则

| 好的步骤（幂等） | 坏的步骤（非幂等） |
|-------------------|---------------------|
| "确保 game.py 中第 142 行不使用 walrus operator" | "修改 game.py" |
| "运行 pytest 确保 47 个测试全部通过" | "修复测试" |
| "确保 requirements.txt 包含 numpy>=1.19" | "更新依赖" |
| "git log -1 确认最后一次提交的作者是 L-ingqin12" | "提交代码" |

**关键区别**：好的步骤描述的是**目标状态**而非**操作**——无论执行多少次，结果不变。

---

## 五、第 3 层 — 外部守护循环

### 5.1 用于无人值守的完整守护脚本

```bash
#!/bin/bash
# /root/claude-guardian.sh
# 无限循环：监控 claude 会话 → 中断后自动重启 → 注入恢复上下文

TASK_STATE="/root/.claude/task-state.json"
GUARDIAN_LOG="/root/.claude/guardian.log"
MAX_RESTARTS=5          # 连续重启上限，防止死循环
RESTART_COOLDOWN=60     # 两次重启之间最小间隔（秒）
NOTIFY_WEBHOOK="https://ntfy.sh/your-topic"  # 可选：中断通知

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$GUARDIAN_LOG"
}

notify() {
    curl -s -H "Title: Claude Guardian" -H "Priority: high" -H "Tags: warning" \
         -d "$1" "$NOTIFY_WEBHOOK" > /dev/null 2>&1 || true
}

restart_count=0
last_restart=0

while true; do
    # 找到最新的 claude 交互式 session
    LATEST=$(ls -t /root/.claude/sessions/*.json 2>/dev/null | head -1)
    
    if [ -z "$LATEST" ]; then
        log "No session found, starting new claude instance"
        restart_count=0
        claude --permission-mode accept-edits
        continue
    fi
    
    SESSION_ID=$(basename "$LATEST" .json)
    
    # 解析 session 元数据
    eval $(python3 -c "
import json
s = json.load(open('$LATEST'))
print(f'PID={s[\"pid\"]} STATUS={s[\"status\"]} VERSION={s[\"version\"]} KIND={s[\"kind\"]}')
" 2>/dev/null)
    
    PID=${PID:-0}
    STATUS=${STATUS:-unknown}
    KIND=${KIND:-unknown}
    
    # 只监控交互式 session（忽略 bg 和 spare）
    if [ "$KIND" != "interactive" ]; then
        sleep 30
        continue
    fi
    
    # 检查进程是否存活
    if kill -0 "$PID" 2>/dev/null; then
        # 进程活着，重置计数器
        if [ "$STATUS" = "idle" ]; then
            restart_count=0  # idle 是正常的等待状态
        fi
        sleep 30
        continue
    fi
    
    # === 进程已死，准备恢复 ===
    now=$(date +%s)
    elapsed=$((now - last_restart))
    
    if [ $elapsed -lt $RESTART_COOLDOWN ]; then
        log "Rate limit: last restart ${elapsed}s ago, waiting..."
        sleep $((RESTART_COOLDOWN - elapsed))
    fi
    
    restart_count=$((restart_count + 1))
    
    if [ $restart_count -gt $MAX_RESTARTS ]; then
        log "FATAL: $MAX_RESTARTS consecutive restarts, giving up"
        notify "Claude 连续崩溃 $MAX_RESTARTS 次，已放弃自动恢复，需要人工介入"
        break
    fi
    
    log "Session $SESSION_ID is DEAD (PID $PID gone, restart #$restart_count)"
    notify "Claude 会话中断，正在尝试第 $restart_count 次恢复..."
    
    # 构建恢复 prompt
    RESTORE_PROMPT="会话中断，请恢复之前的工作。"

    if [ -f "$TASK_STATE" ]; then
        RESTORE_PROMPT=$(python3 -c "
import json
state = json.load(open('$TASK_STATE'))
steps_done = len(state.get('completed', []))
steps_total = state.get('total_steps', '?')
task = state.get('task_name', '未知任务')
pending = state.get('pending', [])
next_step = pending[0]['description'] if pending else '完成收尾'
context = state.get('context', {})
print(f'⚠️ 之前的任务「{task}」因网络中断而中止。')
print(f'进度: {steps_done}/{steps_total} 步骤已完成。')
print(f'下一个步骤: {next_step}')
print(f'上下文: 仓库={context.get(\"repo\",\"?\")}, 分支={context.get(\"branch\",\"?\")}')
print(f'请先读取 {TASK_STATE} 获取完整状态，然后从中断点继续。')
print(f'重要: 已完成步骤的结果仍然在文件中，只做未完成的部分，不要重复做已完成的工作。')
" 2>/dev/null)
    fi
    
    last_restart=$now
    
    # 尝试恢复
    if claude --resume --permission-mode accept-edits -p "$RESTORE_PROMPT" 2>&1; then
        log "Session resumed successfully"
        restart_count=0
    else
        # --resume 失败，启动新会话
        log "--resume failed, starting new session with restore prompt"
        claude --permission-mode accept-edits -p "$RESTORE_PROMPT" 2>&1
    fi
    
    sleep 10
done
```

### 5.2 部署方式

```bash
# 在 systemd 环境中
# /etc/systemd/system/claude-guardian.service
[Unit]
Description=Claude Code Guardian - Auto-resume on crash
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/bin/bash /root/claude-guardian.sh
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

```bash
# 在当前环境（无 systemd）中
nohup /root/claude-guardian.sh > /root/.claude/guardian-nohup.log 2>&1 &
echo $! > /root/.claude/guardian.pid
```

---

## 六、轻量方案（快速上手）

如果不想搞完整守护系统，以下是**最小可行方案**：

### 6.1 Prompt 模板

把这段加到每个无人值守任务的前面：

```
## 中断恢复规则

⚠️ 此任务在网络不稳定的环境中执行，随时可能因 API socket 断开而中断。

你一定要：
1. 开始每个步骤前，将当前进度追加写入 /root/.claude/progress.log，格式：
   [时间] 开始步骤 N/M: <步骤描述>
2. 完成每个步骤后，追加写入：
   [时间] ✅ 完成步骤 N/M: <验证结果>
3. 如果 progress.log 已存在，先读取最后 5 行，确认哪些步骤已完成
4. 只执行未完成的步骤，禁止重复执行已完成的步骤
5. 文件修改前，先 cp 备份到同名文件.bak.{日期}

你的实际任务：
<在此插入任务>
```

### 6.2 重启后的一句话恢复

```bash
# 中断后手动恢复（或脚本自动执行）
claude -p "$(cat << 'EOF'
读取 /root/.claude/progress.log，找到最后一个完成的步骤。
从下一个步骤继续执行。只做未完成的部分。
EOF
)" --permission-mode accept-edits
```

### 6.3 progress.log 示例

```
[2026-06-11 10:00] 任务开始: gomoku Python 3.7 兼容性升级（共 5 步）
[2026-06-11 10:02] 开始步骤 1/5: 分析代码中 Python 3.8+ 语法
[2026-06-11 10:05] ✅ 完成步骤 1/5: 发现 game.py(3处), ai.py(2处)
[2026-06-11 10:05] 开始步骤 2/5: 修改 game.py 中的 walrus operator
[2026-06-11 10:10] ✅ 完成步骤 2/5: game.py 3 处已替换，语法检查通过
[2026-06-11 10:10] 开始步骤 3/5: 修改 ai.py 中的 f-string = 语法
[2026-06-11 10:15] ⚡ --- 此处发生中断 ---
```

恢复后 Claude 读到这 7 行，立即知道：步骤 1、2 已完成，步骤 3 正在做但未完成→从步骤 3 重新开始。

---

## 七、开销对比

| 方案 | 中断后恢复开销 | 实现成本 | 可靠性 |
|------|----------------|----------|--------|
| **无任何措施** | 重做 100%（几千~几万 tokens） | 0 | ❌ 完全依赖运气 |
| **progress.log**（轻量） | 重做 1 个步骤（几百 tokens） | 加一段 prompt 模板 | ⭐⭐ |
| **task-state.json**（结构化） | 重做 0 个步骤（几十 tokens 读文件） | 纳入任务设计习惯 | ⭐⭐⭐⭐ |
| **claude-guardian.sh**（守护） | 0 tokens（自动恢复，用户无感） | 部署一次 | ⭐⭐⭐⭐⭐ |

---

## 八、当前环境的快速实施

```bash
# 1. 创建 progress.log 模板 prompt（一次性）
cat > /root/.claude/resume-prompt-header.txt << 'HEADER'
## 中断恢复规则
⚠️ 环境：Android/Termux/PRoot，通过移动网络访问 API，可能随时中断。
你必须遵守以下规则确保中断后可恢复：

1. 读取 /root/.claude/progress.log 的最后 10 行，了解当前进度
2. 如果 progress.log 为空，创建新任务计划，写入步骤分解
3. 每完成一个步骤，立即追加到 progress.log：[时间] ✅ 步骤 N/M: <验证结果>
4. 文件修改前 cp 备份 (.bak)
5. 已完成步骤的产物（修改后的文件、测试结果）仍然在文件系统中
   禁止重复修改已完成的步骤——先检查目标是否已达成

HEADER

# 2. 将 header + 实际任务拼接后传入 claude
task="你的任务描述"
claude -p "$(cat /root/.claude/resume-prompt-header.txt)

实际任务：
$task" --permission-mode accept-edits

# 3. 设置守护 cron（如果 daemon 在运行）
# 每 10 分钟检查一次，发现会话死了就自动 --resume
```

---

## 九、总结

| 策略 | 一句话 |
|------|--------|
| **任务结构化** | 把"脑子里的进度"写到文件里，中断后读文件就知道做到哪了 |
| **幂等步骤** | 每步描述"目标状态"而非"操作"，重复执行也安全 |
| **progress.log** | 最小可行方案：每步追加一行日志，恢复时读最后 5 行 |
| **task-state.json** | 结构化方案：JSON 记录完整任务树，支持复杂依赖 |
| **外部守护** | 脚本检测到会话死掉→自动 `--resume`→注入恢复 prompt |
| **备份先行** | 改文件前先 cp 备份，回滚成本为 0 |

**核心原则**：Claude 无法控制网络质量，但可以通过**外部化任务状态**彻底消除"重头再来"的痛苦。中断的成本从 "几千 tokens 重做" 降为 "几十 tokens 读文件"。
