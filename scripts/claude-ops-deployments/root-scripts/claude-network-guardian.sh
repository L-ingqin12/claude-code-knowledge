#!/bin/bash
# ─────────────────────────────────────────────────────────
# Claude Code 网络中断守护脚本 (归档参考方案)
# 状态: ⚠️ 归档 — 见 network-resilience-v2.md 的结论
# 原因: Claude 不崩溃只报错停住, 代理门控已覆盖 99%+ 场景
# 用途: 如果未来环境变化(Claude 会崩溃), 可启用此脚本
# 设计文档: claude-network-resilience-design.md
# ─────────────────────────────────────────────────────────

GUARDIAN_LOG="/root/.claude/guardian.log"
TASK_STATE="/root/.claude/task-state.json"
CONTEXT_DUMP="/root/.claude/context-dump.md"
RECOVERY_HEADER="/root/.claude/resume-prompt-header.txt"
CHECK_INTERVAL=30
NETWORK_RETRY=30
API_CHECK_URL="https://api.deepseek.com/anthropic/v1/messages"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$GUARDIAN_LOG"; }

check_network() {
    curl -sI --connect-timeout 5 --max-time 10 "$API_CHECK_URL" > /dev/null 2>&1
}

build_recovery_prompt() {
    local prompt="⚠️ 会话因网络中断恢复。读取 $CONTEXT_DUMP 了解之前的思维状态。"

    if [ -f "$TASK_STATE" ]; then
        prompt=$(python3 -c "
import json
state = json.load(open('$TASK_STATE'))
steps_done = len(state.get('completed', []))
task = state.get('task_name', '未知任务')
pending = state.get('pending', [])
next_step = pending[0]['description'] if pending else '完成收尾'
print(f'任务「{task}」中断于步骤 {steps_done + 1}。')
print(f'下一步: {next_step}')
print(f'读取 context-dump.md 恢复思维状态。')
print(f'禁止推翻已有 Decisions。只做未完成步骤。')
" 2>/dev/null)
    fi
    echo "$prompt"
}

log "Network Guardian started (PID $$)"

while true; do
    LATEST_SESSION=$(ls -t /root/.claude/sessions/*.json 2>/dev/null | head -1)

    if [ -z "$LATEST_SESSION" ]; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    SESSION_ID=$(basename "$LATEST_SESSION" .json)
    PID=$(python3 -c "import json; print(json.load(open('$LATEST_SESSION')).get('pid',0))" 2>/dev/null)
    STATUS=$(python3 -c "import json; print(json.load(open('$LATEST_SESSION')).get('status','unknown'))" 2>/dev/null)

    if [ -n "$PID" ] && [ "$PID" != "0" ] && kill -0 "$PID" 2>/dev/null; then
        sleep "$CHECK_INTERVAL"
        continue
    fi

    log "Session $SESSION_ID dead (PID $PID gone, was $STATUS)"

    # 等网络恢复
    log "Waiting for network..."
    while ! check_network; do
        sleep "$NETWORK_RETRY"
    done
    log "Network back"

    # 有状态文件 → 构建恢复 prompt 并启动
    if [ -f "$TASK_STATE" ] || [ -f "$CONTEXT_DUMP" ]; then
        RECOVERY_PROMPT=$(build_recovery_prompt)
        log "Launching Claude with recovery..."
        claude -p "$RECOVERY_PROMPT" --permission-mode accept-edits 2>&1
        log "Recovery session ended (exit=$?)"
    else
        log "No state files, cannot auto-recover"
    fi

    sleep "$CHECK_INTERVAL"
done
