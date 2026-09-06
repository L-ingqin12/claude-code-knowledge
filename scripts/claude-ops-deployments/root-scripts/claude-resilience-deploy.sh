#!/bin/bash
# Claude Code 韧性代理 — 部署脚本 (Node.js)
# 用法: bash /root/claude-resilience-deploy.sh [start|stop|status]
set -e

PROXY_SCRIPT="/root/claude-resilience-proxy.js"
PROXY_LOG="/root/.claude/proxy.log"
PROXY_PID_FILE="/root/.claude/proxy.pid"
RESUME_HEADER="/root/.claude/resume-prompt-header.txt"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[deploy]${NC} $1"; }
warn() { echo -e "${YELLOW}[deploy]${NC} $1"; }

start_proxy() {
    if [ -f "$PROXY_PID_FILE" ] && kill -0 "$(cat $PROXY_PID_FILE)" 2>/dev/null; then
        warn "Proxy already running (PID $(cat $PROXY_PID_FILE))"
        return 0
    fi
    log "Starting Node.js resilience proxy..."
    node "$PROXY_SCRIPT" > "$PROXY_LOG" 2>&1 &
    local PID=$!
    echo "$PID" > "$PROXY_PID_FILE"
    sleep 2
    if kill -0 "$PID" 2>/dev/null; then
        log "Proxy started (PID $PID)"
        curl -sI --connect-timeout 2 http://127.0.0.1:8787/ > /dev/null 2>&1 && log "Health check: OK" || warn "Health check failed"
    else
        warn "Proxy failed to start. Check $PROXY_LOG"
        return 1
    fi
}

stop_proxy() {
    if [ -f "$PROXY_PID_FILE" ]; then
        PID=$(cat "$PROXY_PID_FILE")
        kill "$PID" 2>/dev/null; sleep 1; kill -9 "$PID" 2>/dev/null
        rm -f "$PROXY_PID_FILE"
        log "Proxy stopped (was PID $PID)"
    fi
    pkill -f "claude-resilience-proxy.js" 2>/dev/null || true
}

proxy_status() {
    if [ -f "$PROXY_PID_FILE" ] && kill -0 "$(cat $PROXY_PID_FILE)" 2>/dev/null; then
        log "Proxy: RUNNING (PID $(cat $PROXY_PID_FILE))"
    else
        warn "Proxy: NOT RUNNING"
    fi
}

create_resume_header() {
    if [ ! -f "$RESUME_HEADER" ]; then
        cat > "$RESUME_HEADER" << 'HEADER'
## ⚠️ 中断恢复协议
此任务运行在网络不稳定环境中。你必须:
### A. 进度: 每步更新 task-state.json + progress.log
### B. 外部大脑: 维护 context-dump.md (Mental Model + Decisions + Findings)
### C. 恢复: 读取 context-dump.md → task-state.json → 验证锚点 → 继续
HEADER
    fi
}

case "${1:-start}" in
    start)
        log "=== Claude Resilience Stack ==="
        create_resume_header
        # 恢复 shell 配置 → 走代理
        PROXY_URL="http://127.0.0.1:8788"
        for rc in /root/.zshrc /root/.bashrc; do
            if grep -q "ANTHROPIC_BASE_URL.*api.deepseek.com" "$rc" 2>/dev/null; then
                sed -i "s|export ANTHROPIC_BASE_URL=\"https://api.deepseek.com/anthropic\"|export ANTHROPIC_BASE_URL=\"$PROXY_URL\"|" "$rc"
                log "Updated $rc → $PROXY_URL"
            fi
        done
        start_proxy
        log "Deploy complete."
        echo ""
        echo "  新Claude会话自动走代理:"
        echo "    claude --permission-mode accept-edits"
        echo ""
        echo "  回滚: bash /root/claude-rollback.sh"
        ;;
    stop)
        stop_proxy
        log "Proxy stopped."
        ;;
    status)
        proxy_status
        echo "Resume header: $([ -f "$RESUME_HEADER" ] && echo 'EXISTS' || echo 'MISSING')"
        echo "Shell URL: $(grep ANTHROPIC_BASE_URL /root/.zshrc 2>/dev/null)"
        ;;
    *) echo "Usage: $0 {start|stop|status}"; exit 1 ;;
esac
