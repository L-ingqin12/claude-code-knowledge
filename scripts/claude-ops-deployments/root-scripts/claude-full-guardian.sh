#!/bin/bash
# ─────────────────────────────────────────────────────────
# Claude Code 完整守护脚本 (归档参考方案)
# 状态: ⚠️ 归档 — 当前场景不需要, 保留供后续参考
# 原因: 当前场景中 Claude 不崩溃, 仅报错停止, 不需要进程守护
# 适用: Claude 进程崩溃退出 + 需要自动 --resume 的场景
# 设计文档: claude-interruption-resilience-guide.md
# ─────────────────────────────────────────────────────────

RESUME_LOG="/root/.claude/resume.log"
SESSION_DIR="/root/.claude/sessions"
TASK_STATE="/root/.claude/task-state.json"
MAX_RESTARTS=5
RESTART_COOLDOWN=60

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$RESUME_LOG"
}

# 检查 session 是否存活
check_session_alive() {
    local session_file="$1"
    PID=$(python3 -c "import json; print(json.load(open('$session_file')).get('pid',0))" 2>/dev/null)
    STATUS=$(python3 -c "import json; print(json.load(open('$session_file')).get('status','unknown'))" 2>/dev/null)
    KIND=$(python3 -c "import json; print(json.load(open('$session_file')).get('kind','unknown'))" 2>/dev/null)

    if [ "$KIND" != "interactive" ]; then
        return 0  # 忽略非交互式 session
    fi

    if [ -n "$PID" ] && [ "$PID" != "0" ] && kill -0 "$PID" 2>/dev/null; then
        return 0  # 存活
    fi
    return 1  # 已死
}

# 构建恢复 prompt
build_recovery_prompt() {
    local prompt="会话因网络中断崩溃。读取 /root/.claude/task-state.json 了解任务进度。"

    if [ -f "$TASK_STATE" ]; then
        prompt=$(python3 -c "
import json
state = json.load(open('$TASK_STATE'))
steps_done = len(state.get('completed', []))
task = state.get('task_name', '未知任务')
pending = state.get('pending', [])
next_step = pending[0]['description'] if pending else '完成收尾'
context = state.get('context', {})
print(f'⚠️ 之前的任务「{task}」因网络中断而中止。')
print(f'进度: {steps_done}/{state.get(\"total_steps\",\"?\")} 步骤已完成。')
print(f'下一个步骤: {next_step}')
print(f'上下文: 仓库={context.get(\"repo\",\"?\")}, 分支={context.get(\"branch\",\"?\")}')
print(f'请先读取 task-state.json 获取完整状态，然后从中断点继续。')
print(f'已完成步骤不要重复做。')
" 2>/dev/null)
    fi
    echo "$prompt"
}

# ── 主循环 ──
restart_count=0
last_restart=0

log "Full Guardian started (PID $$)"

while true; do
    LATEST=$(ls -t "$SESSION_DIR"/*.json 2>/dev/null | head -1)

    if [ -z "$LATEST" ]; then
        sleep 30
        continue
    fi

    SESSION_ID=$(basename "$LATEST" .json)

    if check_session_alive "$LATEST"; then
        restart_count=0
        sleep 30
        continue
    fi

    # 进程死了 → 准备恢复
    now=$(date +%s)
    if [ $((now - last_restart)) -lt $RESTART_COOLDOWN ]; then
        sleep $((RESTART_COOLDOWN - (now - last_restart)))
    fi

    restart_count=$((restart_count + 1))

    if [ $restart_count -gt $MAX_RESTARTS ]; then
        log "FATAL: $MAX_RESTARTS consecutive restarts, giving up"
        break
    fi

    log "Session $SESSION_ID dead (restart #$restart_count)"

    RECOVERY_PROMPT=$(build_recovery_prompt)

    # 尝试 --resume
    if claude --resume --permission-mode accept-edits -p "$RECOVERY_PROMPT" 2>&1; then
        log "Session resumed successfully"
        restart_count=0
    else
        # --resume 失败 → 新会话 + 恢复 prompt
        log "--resume failed, starting new session"
        claude --permission-mode accept-edits -p "$RECOVERY_PROMPT" 2>&1
    fi

    last_restart=$now
    sleep 10
done
